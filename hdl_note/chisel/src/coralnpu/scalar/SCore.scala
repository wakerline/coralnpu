// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


// ============================================================================
// SCore.scala — 标量 RISC-V 核心顶层 (Scalar Core)
//
// 这是 CoralNPU 最核心的文件 — 实例化并连接所有标量流水线组件。
//
// 流水线: Fetch → DispatchV2 → ALU/BRU/MLU/DVU/LSU/FPU → RetirementBuffer
//                                        ↓                       ↓
//                                     Regfile(写回)        FaultManager
//
// 实例化的功能单元:
//   Fetch / UncachedFetch    — 取指 (含 L0 ICache)
//   DispatchV2               — 译码 + 多 lane 发射
//   Alu(×4) / Bru(×4)       — 算术/分支 (每 lane 各一个)
//   Mlu / Dvu                — 乘法/除法 (多 lane 共享)
//   Lsu                      — Load/Store
//   FloatCore / FRegfile     — 浮点 (条件: enableFloat)
//   Regfile                  — 整数寄存器文件 + Scoreboard
//   Csr                      — 控制状态寄存器
//   FaultManager             — 异常收集/仲裁
//   RetirementBuffer         — 指令退役 (按序提交)
//   RvvCore (条件)           — 向量核
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.float.{FloatCore}
import coralnpu.rvv.{RvvCoreIO}
import _root_.circt.stage.ChiselStage

object SCore {
  def apply(p: Parameters): SCore = Module(new SCore(p))
}

class SCore(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val csr     = new CsrInOutIO(p)                              // CSR 输入/输出
    val halted  = Output(Bool())                                  // 核心已暂停
    val fault   = Output(Bool())                                  // 核心异常标志
    val wfi     = Output(Bool())                                  // 等待中断 (WFI)
    val irq     = Input(Bool())                                   // 外部中断请求
    val dm      = new CoreDMIO(p)                                 // 调试模块接口
    val timer_irq    = Input(Bool())                              // 定时器中断
    val software_irq = Input(Bool())                              // 软件中断

    val ibus = new IBusIO(p)                                      // 取指总线
    val dbus = new DBusIO(p)                                      // 数据总线
    val ebus = new EBusIO(p)                                      // 扩展总线

    val rvvcore = Option.when(p.enableRvv)(Flipped(new RvvCoreIO(p))) // RVV 协处理接口 (条件)

    val iflush = new IFlushIO(p)                                  // 指令流水线刷新
    val dflush = new DFlushIO(p)                                  // 数据流水线刷新

    val debug = new DebugIO(p)                                    // 调试观测
  })

  // ---- 功能单元实例化 ----
  val regfile  = Regfile(p)                                       // 整数寄存器文件 (8读6写)
  val fetch    = if (p.enableFetchL0) { Fetch(p) } else { Module(new UncachedFetch(p)) }

  val csr      = Csr(p)                                           // 控制和状态寄存器
  val dispatch = Module(new DispatchV2(p))                        // 译码+发射

  val lsu             = Lsu(p)                                    // Load/Store 单元
  val fault_manager   = Module(new FaultManager(p))               // 异常管理
  val retirement_buffer = Module(new RetirementBuffer(p, mini = !p.useRetirementBuffer))//仅在验证模式下使用完整版，非验证模式使用简化版 (mini=true) 省面积。
  val rob_io = retirement_buffer.io                               // 退役缓冲区 IO 别名

  // ---- 退役缓冲区输入: 从 Dispatch 接收指令信息 ----
  rob_io.inst               := dispatch.io.inst                  // 发射的指令
  rob_io.jump               := dispatch.io.jump                   // 是否跳转
  rob_io.branch             := dispatch.io.branch                 // 是否分支
  rob_io.writeAddrScalar    := dispatch.io.rdMark                 // 标量寄存器写地址
  (0 until p.instructionLanes + 2).foreach(i => {
    rob_io.writeDataScalar(i) := regfile.io.writeData(i)          // 标量写回数据 (+2: MLU/DVU + LSU)
  })
// | 端口| 来源                                             |
// | -: | ---------------------------------------------- |
// |  0 | lane0 ALU/BRU/CSR/RVV                          |
// |  1 | lane1 ALU/BRU/RVV                              |
// |  2 | lane2 ALU/BRU/RVV                              |
// |  3 | lane3 ALU/BRU/RVV                              |
// |  4 | MLU/DVU/RVV async/Float scalar/Debug scalar 仲裁 |
// |  5 | LSU load 写回                                    |

  // 退役缓冲区反压到 Dispatch: 告知剩余槽位/是否为空/是否有异常等待处理
  // 如果 RetirementBuffer 快满，则 Dispatch 减少或停止发射；
  // 如果 trapPending，则 Dispatch 可能停止发射，等待异常提交。
  dispatch.io.retirement_buffer_nSpace := rob_io.nSpace
  dispatch.io.retirement_buffer_empty  := rob_io.empty
  dispatch.io.retirement_buffer_trap_pending := rob_io.trapPending

  // ---- RVV 向量写回 (条件) ----
  if (p.enableRvv) {
    rob_io.writeAddrVector.get := dispatch.io.rvvRdMark.get//Dispatch 译码/发射阶段产生的 RVV 目的寄存器标记
    (0 until p.instructionLanes).foreach(i => {
      rob_io.writeDataVector.get(i).valid            := io.rvvcore.get.rd_rob2rt_o(i).valid
      rob_io.writeDataVector.get(i).bits.addr        := io.rvvcore.get.rd_rob2rt_o(i).w_index
      rob_io.writeDataVector.get(i).bits.data        := io.rvvcore.get.rd_rob2rt_o(i).w_data
      rob_io.writeDataVector.get(i).bits.uop_pc      := io.rvvcore.get.rd_rob2rt_o(i).uop_pc
      rob_io.writeDataVector.get(i).bits.last_uop_valid := io.rvvcore.get.rd_rob2rt_o(i).last_uop_valid
    })
  }
  rob_io.fault         := fault_manager.io.out                   // 异常信息
  rob_io.storeComplete := lsu.io.storeComplete                   // 存储完成通知

  // ---- 调试控制: single_step / debug_mode / debug_pc ----
  dispatch.io.single_step := csr.io.dm.single_step || csr.io.dm.dcsr_step
  dispatch.io.debug_mode  := csr.io.dm.debug_mode  //Dispatch 需要停止正常发射或按 debug 规则处理。
  fetch.io.debug_pc       := csr.io.dm.debug_pc//如果从 debug 模式恢复或跳到 debug 指定 PC，Fetch 需要知道新的取指地址

  // 执行单元: 每 lane 一个 ALU/BRU, MLU/DVU 共享
  val alu = Seq.fill(p.instructionLanes)(Alu(p))                 // 4 个 ALU 并行
  //lane0 BRU 额外负责 CSR / trap / mret / debug 相关控制；其他 lane BRU 只负责普通分支判断。
  val bru = (0 until p.instructionLanes).map(x => Seq(Bru(p, x == 0))).reduce(_ ++ _) // lane0=first
  val mlu = Mlu(p)                                               // 1 个 MLU 共享
  val dvu = Dvu(p)                                               // 1 个 DVU 共享

  // branchTaken: 任意 lane 发生了分支则置 1，用于阻止/刷新分支后的错误路径指令
  val branchTaken = bru.map(x => x.io.taken.valid).reduce(_||_)

  // ---- Flush 逻辑: LSU 发起, 分 DFlush(数据) 和 IFlush(指令,FENCE.I) ----
  io.dflush.valid := lsu.io.flush.valid && !lsu.io.flush.fencei  // 数据 flush → DFlush
  io.dflush.all   := lsu.io.flush.all
  io.dflush.clean := lsu.io.flush.clean

  io.iflush.valid  := lsu.io.flush.valid && lsu.io.flush.fencei  // FENCE.I → IFlush
  io.iflush.pcNext := lsu.io.flush.pcNext // FENCE.I 需要刷新指令流水线，下一条取指 PC 由 LSU 提供
  fetch.io.iflush.valid := lsu.io.flush.valid && lsu.io.flush.fencei
  fetch.io.iflush.pcNext := lsu.io.flush.pcNext

  // LSU flush 就绪条件: fencei→取指单元ready, 否则→DFlush ready
  lsu.io.flush.ready := lsu.io.flush.valid &&
      Mux(lsu.io.flush.fencei, fetch.io.iflush.ready, io.dflush.ready)

  // ---- Fetch: CSR 输入 + 分支反馈 + 寄存器链接端口 ----
  fetch.io.csr := io.csr.in
  for (i <- 0 until p.instructionLanes) {
    fetch.io.branch(i) := bru(i).io.taken                        // 每个 lane 的分支反馈，需要pc重定向
  }
  fetch.io.linkPort := regfile.io.linkPort   //寄存器链接 (用于 JALR 计算返回地址)

  // ---- Decode/Dispatch: 取指输出 → 译码发射 ----
  dispatch.io.inst <> fetch.io.inst.lanes                         // 指令流: Fetch→Dispatch
  dispatch.io.halted := csr.io.halted || csr.io.wfi || csr.io.dm.debug_mode // 暂停条件
  dispatch.io.mactive := false.B                                  // 机器模式始终活跃
  dispatch.io.lsuActive := lsu.io.active                          // LSU 忙 → 阻止新访存指令
  dispatch.io.lsuQueueCapacity := lsu.io.queueCapacity            // LSU 队列剩余空间
  dispatch.io.scoreboard.comb := regfile.io.scoreboard.comb       // 寄存器组合依赖,可能用于当前周期旁路/冲突判断
  dispatch.io.scoreboard.regd := regfile.io.scoreboard.regd       // 寄存器已发射依赖,表示哪些寄存器等待写回
  dispatch.io.branchTaken := branchTaken                          // 分支发生了 → 刷新后续指令
  //lane0 BRU 产生的互锁，例如 CSR/trap/特殊控制流
  //LSU 正在发 flush，Dispatch 暂停
  dispatch.io.interlock := bru(0).io.interlock.get || lsu.io.flush.valid // 互锁条件

  // ---- FaultManager 连接: 各异常源 → FaultManager ----
// | 输入类别             | 代码来源                      | 进入 FaultManager 的信号                |
// | ---------------- | ------------------------- | ---------------------------------- |
// | CSR 异常           | Dispatch                  | `csrFault(i)`                      |
// | JAL 异常           | Dispatch                  | `jalFault(i)`                      |
// | JALR 异常          | Dispatch + Regfile target | `jalrFault(i)` + `target`          |
// | Branch 异常        | Dispatch                  | `bxxFault(i)`                      |
// | 非法指令             | Dispatch + Fetch inst     | `undefFault(i)` + `inst`           |
// | 指令 PC            | Fetch                     | `fetch.io.inst.lanes(i).bits.addr` |
// | JAL target       | Dispatch                  | `bruTarget(i)`                     |
// | LSU 访存异常         | LSU                       | `lsu.io.fault`                     |
// | RVV decode 异常    | Dispatch                  | `rvvFault(i)`                      |
// | RVV execute trap | RVV Core                  | `rvvcore.trap`                     |
// | FaultManager 输出  | FaultManager              | 送给 `bru(0)` 和前面的 `rob_io.fault`    |

  for (i <- 0 until p.instructionLanes) {
    // 译码阶段异常: CSR/JAL/JALR/Bxx/未定义
    fault_manager.io.in.fault(i).csr   := dispatch.io.csrFault(i)//译码阶段产生的 CSR 访问异常
    fault_manager.io.in.fault(i).jal   := dispatch.io.jalFault(i)//译码阶段产生的 JAL 相关异常
    fault_manager.io.in.fault(i).jalr  := dispatch.io.jalrFault(i)//译码阶段产生的 JALR 相关异常,target = rs1 + imm
    fault_manager.io.in.fault(i).bxx   := dispatch.io.bxxFault(i)//译码阶段产生的分支相关异常
    fault_manager.io.in.fault(i).undef := dispatch.io.undefFault(i)//译码阶段产生的未定义指令异常
    if (p.enableRvv) {
      fault_manager.io.in.fault(i).rvv.get := dispatch.io.rvvFault.get(i) //译码阶段产生的 RVV 相关异常
    }
    // 异常上下文: PC / JALR目标 / 未定义指令 / JAL目标
    fault_manager.io.in.pc(i).pc         := fetch.io.inst.lanes(i).bits.addr//异常指令的 PC
    fault_manager.io.in.jalr(i).target   := regfile.io.target(i).data//JALR 目标地址 (从 Regfile 读端口)
    fault_manager.io.in.undef(i).inst    := fetch.io.inst.lanes(i).bits.inst//未定义指令的原始编码,这通常用于写入 mtval = 非法指令编码
    fault_manager.io.in.jal(i).target    := dispatch.io.bruTarget(i)//分支单元计算的目标地址,JAL 目标可能在译码阶段就能计算出来，因为 JAL 是 PC-relative 立即数跳转
  }
  fault_manager.io.in.memory_fault := lsu.io.fault               // LSU 访存异常
  if (p.enableRvv) {
    // RVV 异常: 从向量核的 trap 口接收
    fault_manager.io.in.rvv_fault.get.valid         := io.rvvcore.get.trap.valid//vill 状态下，普通向量指令非法，由RvvFrontEnd检测出来，同步流水线输出
    fault_manager.io.in.rvv_fault.get.bits.mepc     := io.rvvcore.get.trap.bits.pc//mepc 是 RISC-V trap 里保存异常 PC 的 CSR。
    fault_manager.io.in.rvv_fault.get.bits.mcause   := 2.U(32.W) // mcause=2: 非法指令
    fault_manager.io.in.rvv_fault.get.bits.mtval    := io.rvvcore.get.trap.bits.originalEncoding()//mtval 记录异常附加信息。这里填的是：RVV trap 对应的原始指令编码
    fault_manager.io.in.rvv_fault.get.bits.decode   := false.B//这个 RVV fault 来自 RVV Core 执行/内部 trap，而不是 SCore Dispatch decode。
  }
  // lane0 的 BRU 可访问异常信息 (用于 MRET 等)
  bru(0).io.fault_manager.get := fault_manager.io.out//只有 lane0 的 BRU 连接 FaultManager 输出。

  // ---- ALU: 每 lane 独立连接 ----
  for (i <- 0 until p.instructionLanes) {
    alu(i).io.req := dispatch.io.alu(i)                           // 操作码+目标寄存器
    alu(i).io.rs1 := regfile.io.readData(2 * i + 0)              // 源操作数1 (从 Regfile 读端口)
    alu(i).io.rs2 := regfile.io.readData(2 * i + 1)              // 源操作数2
  }

  // ---- BRU: 分支单元, lane0 额外承担 CSR 交互 + FaultManager ----
  for (i <- 0 until p.instructionLanes) {
    bru(i).io.req    := dispatch.io.bru(i)                        // 分支操作码
    bru(i).io.rs1    := regfile.io.readData(2 * i + 0)            // 源操作数1 (从 Regfile 读端口)
    bru(i).io.rs2    := regfile.io.readData(2 * i + 1)            // 源操作数2
    bru(i).io.target := regfile.io.target(i)                      // JALR 目标地址,JALR target = rs1 + imm
    dispatch.io.jalrTarget(i) := regfile.io.target(i)
    rob_io.targets(i)     := dispatch.io.bruTarget(i)             // BRU 计算的目标 → 退役缓冲,JAL / branch:通常由 PC + immediate 计算，Dispatch 可得到
    rob_io.jalrTargets(i) := regfile.io.target(i).data            //JALR:来自寄存器 rs1 + immediate，需要 Regfile target
  }
  // mret
  // dret
  // ecall/ebreak 跳转
  // 异常返回
  // debug 入口/返回
  // 特权级 PC 重定向
  bru(0).io.csr.get <> csr.io.bru                                // lane0: BRU↔CSR 交互

  csr.io.counters.nRetired := rob_io.nRetired                     // 本周期退役了的指令数 → CSR 计数器

  // ---- CSR 单元: 指令 CSR 访问 + 调试模块 CSR 访问的仲裁 ----
  // Csr 模块有两个访问来源：
  // 1、正常指令流：csrrw/csrrs/csrrc 等 CSR 指令
  // 2、DebugModule：外部调试器读写 CSR
  csr.io.csr <> io.csr
  csr.io.csr.in.value(12) := fetch.io.pc                          // CSR 输入 #12 = 当前 PC

  // CSR 请求仲裁: Dispatch(port0) vs Debug Module(port1)
  // 标准 Arbiter 是固定优先级，通常 in(0) 优先于 in(1)。
  // 不过在 debug 模式下，Dispatch 通常会暂停正常发射，所以 DebugModule CSR 请求一般不会被长期挡住。
  val csrReqArbiter = Module(new Arbiter(new CsrCmd, 2))//2个请求端口的仲裁器，输入是 CSR 请求命令 (包含地址/数据/读写标志等)，输出连接到 CSR 模块的请求接口。
  csrReqArbiter.io.in(0).bits  := dispatch.io.csr.bits            // 指令 CSR 访问
  csrReqArbiter.io.in(0).valid := dispatch.io.csr.valid
  csrReqArbiter.io.in(1).valid := io.dm.csr.valid                 // 调试模块 CSR 访问
  csrReqArbiter.io.in(1).bits  := io.dm.csr.bits
  csrReqArbiter.io.out.ready := true.B                            // 总是就绪,Csr 模块这一侧不会反压外部CSR 请求。
  csr.io.req.bits  := csrReqArbiter.io.out.bits
  csr.io.req.valid := csrReqArbiter.io.out.valid

  // CSR rs1 选择: 指令 CSR(用 Regfile), DM CSR(用 dm.csr_rs1)
  val dmRs1 = Wire(new RegfileReadDataIO)
  dmRs1.valid := true.B  //DebugModule 提供的 rs1 数据恒有效。
  dmRs1.data  := io.dm.csr_rs1
  csr.io.rs1 := Mux(RegNext(dispatch.io.csr.valid, false.B), regfile.io.readData(0), dmRs1)//打一拍，Dispatch 发出 CSR 请求后一拍，regfile.io.readData(0) 才对应该 CSR 指令的 rs1。
  io.dm.csr_rd := MakeValid(csr.io.rd.valid, csr.io.rd.bits.data)//把 CSR 读结果返回给 DebugModule。

  // ---- 单步调试 (Single Step) ----
  val bruTaken   = bru(0).io.actually_taken                       // 实际发生了分支
  val realTarget = bru(0).io.real_target                          // 实际分支目标
  // 单步模式: 在指令执行前中断, nextInstPC 指向该指令地址以便恢复后执行
  val nextInstPC = Mux(bruTaken, realTarget, dispatch.io.inst(0).bits.addr)
  csr.io.dm.current_pc := dispatch.io.inst(0).bits.addr//有可能这里的 dispatch.io.inst(0).bits.addr 已经表示下一条待执行地址???
  csr.io.dm.next_pc    := nextInstPC//单步执行后进入 debug，恢复时需要知道下一步从哪里继续执行。

  // stepTriggered: !debug_mode + dcsr_step + 指令发射 → 触发单步
  val stepTriggered    = (!csr.io.dm.debug_mode && csr.io.dm.dcsr_step && dispatch.io.inst(0).fire)
  val stepTriggeredReg = RegNext(stepTriggered, false.B)//把单步触发信号延迟一拍。让当前指令先真正发射/执行，下一拍再请求进入 debug。
  csr.io.dm.debug_req  := io.dm.debug_req || stepTriggeredReg     // 外部 DebugModule 请求 halt/debug 或 单步触发
  csr.io.dm.resume_req := io.dm.resume_req  // 外部调试器请求核心从 debug/halt 状态恢复运行。
  io.dm.debug_mode := csr.io.dm.debug_mode  // 把当前 debug 模式状态返回给 DebugModule,确定Core 当前是否已经进入 debug mode。

  // ---- 核心状态输出 ----
  io.halted := csr.io.halted
  io.fault  := csr.io.fault
  io.wfi    := csr.io.wfi
  csr.io.irq := io.irq
  csr.io.timer_irq := io.timer_irq
  csr.io.software_irq := io.software_irq

  // ---- LSU: 寄存器总线端口 + RVV 协处理接口 ----
  //这个 busPort 通常用于 store 指令读取写入内存的数据。
  lsu.io.busPort := regfile.io.busPort                            // 寄存器总线端口 (store 数据)
  lsu.io.req <> dispatch.io.lsu                                    // LSU 操作请求
  if (p.enableRvv) {
    lsu.io.rvvState.get := io.rvvcore.get.configState             // RVV 配置 (VL/VTYPE等)
    lsu.io.lsu2rvv.get <> io.rvvcore.get.lsu2rvv                  // LSU→RVV: 向量写回
    io.rvvcore.get.rvv2lsu <> lsu.io.rvv2lsu.get                  // RVV→LSU: 向量访存请求
  }

  // ---- MLU: 每 lane 一个请求端口, 共享一个 MLU ----
  //虽然 MLU 只有一个模块，但它有多个请求入口
  for (i <- 0 until p.instructionLanes) {
    mlu.io.req(i) <> dispatch.io.mlu(i)
    mlu.io.rs1(i) := regfile.io.readData(2 * i)
    mlu.io.rs2(i) := regfile.io.readData((2 * i) + 1)
  }

  // ---- DVU: 仅 lane0 可用, lane1~3 恒 not ready ----
  dvu.io.req <> dispatch.io.dvu(0)
  dvu.io.rs1 := regfile.io.readData(0)
  dvu.io.rs2 := regfile.io.readData(1)
  dvu.io.rd.ready := !mlu.io.rd.valid          // MLU 结果优先于 DVU,MLU 和 DVU 会共享一个额外 Regfile 写端口
  for (i <- 1 until p.instructionLanes) {
    dispatch.io.dvu(i).ready := false.B                           // lane1~3 禁止 DVU
  }

  // ---- Register File: 读/写端口连接 + 多源写回仲裁 ----
  for (i <- 0 until p.instructionLanes) {
    // 读端口: 2×instructionLanes 个 (每 lane 2 个源操作数)
    regfile.io.readAddr(2 * i + 0) := dispatch.io.rs1Read(i)//读地址0: rs1
    regfile.io.readAddr(2 * i + 1) := dispatch.io.rs2Read(i)//读地址1: rs2
    regfile.io.readSet(2 * i + 0)  := dispatch.io.rs1Set(i)//告诉 Regfile/scoreboard：这个读端口当前是否真的要读。
    regfile.io.readSet(2 * i + 1)  := dispatch.io.rs2Set(i)
    regfile.io.writeAddr(i) := dispatch.io.rdMark(i)              // 写地址,避免后续指令过早读取旧值
    regfile.io.busAddr(i)   := dispatch.io.busRead(i)             // 通常用于 LSU store 数据或特殊总线读。

    regfile.io.debugBusPort <> io.dm.scalar_rs                    // 调试模块读寄存器

    // 写回源选择,CSR 指令的写回结果只接到 lane0 的写回通路。
    val csr0Valid = if (i == 0) csr.io.rd.valid else false.B
    val csr0Addr  = if (i == 0) csr.io.rd.bits.addr else 0.U
    val csr0Data  = if (i == 0) csr.io.rd.bits.data else 0.U

    // RVV 向量写回 (条件)
    val rvvCoreRdValid = io.rvvcore.map(_.rd(i).valid).getOrElse(false.B)//如果 RVV 存在，取 rvvcore.rd(i).valid；
    val rvvCoreRdAddr  = MuxOR(rvvCoreRdValid, io.rvvcore.map(_.rd(i).bits.addr).getOrElse(0.U))//如果 rvvCoreRdValid=1，输出 addr；
    val rvvCoreRdData  = MuxOR(rvvCoreRdValid, io.rvvcore.map(_.rd(i).bits.data).getOrElse(0.U))//如果 rvvCoreRdValid=1，输出 data


  // | 来源                   | 是否每 lane 都有 | 说明              |
  // | -------------------- | ----------- | --------------- |
  // | `csr0Valid`          | 只有 lane0    | CSR 指令写回        |
  // | `alu(i).io.rd.valid` | 每 lane      | ALU 写回          |
  // | `bru(i).io.rd.valid` | 每 lane      | BRU/JAL/JALR 写回 |
  // | `rvvCoreRdValid`     | 条件存在        | RVV 标量写回        |

    // 写回 valid: CSR / ALU / BRU / RVV 任一有效 (MuxOR 保证互斥)
    regfile.io.writeData(i).valid := csr0Valid ||
                                     alu(i).io.rd.valid || bru(i).io.rd.valid ||
                                     rvvCoreRdValid
    // 写回地址: 多源 | 合并 (MuxOR: 仅一个源有效时输出该源的值)
    regfile.io.writeData(i).bits.addr :=
        MuxOR(csr0Valid, csr0Addr) |
        MuxOR(alu(i).io.rd.valid, alu(i).io.rd.bits.addr) |
        MuxOR(bru(i).io.rd.valid, bru(i).io.rd.bits.addr) |
        rvvCoreRdAddr
    // 写回数据: 同上
    regfile.io.writeData(i).bits.data :=
        MuxOR(csr0Valid, csr0Data) |
        MuxOR(alu(i).io.rd.valid, alu(i).io.rd.bits.data) |
        MuxOR(bru(i).io.rd.valid, bru(i).io.rd.bits.data) |
        rvvCoreRdData

    // 断言: 同一周期最多一个源写回同一寄存器 (硬件保证互斥)
    if (p.enableRvv) {
      assert((csr0Valid +& alu(i).io.rd.valid +& bru(i).io.rd.valid +&
              io.rvvcore.get.rd(i).valid) <= 1.U)
    } else {
      assert((csr0Valid +& alu(i).io.rd.valid +& bru(i).io.rd.valid) <= 1.U)
    }
  }

  // ---- 浮点扩展 (RV32F): FloatCore + FRegfile (条件: enableFloat) ----
  val floatCore = Option.when(p.enableFloat)(FloatCore(p))       // FP32 FMA+Div+Sqrt
  val floatReadPorts  = 3
  val floatWritePorts = 2
// fRegfile负责:
// f0~f31 浮点寄存器
// 浮点 scoreboard
// 浮点读端口
// 浮点写端口
// Debug 浮点读写
// LSU 浮点 load/store 接口
  val fRegfile = Option.when(p.enableFloat)(Module(new FRegfile(p, floatReadPorts, floatWritePorts)))
  if (p.enableFloat) {
    lsu.io.busPort_flt.get := fRegfile.get.io.busPort  //浮点 store：fsw f1, offset(x2)
    fRegfile.get.io.busPortAddr := dispatch.io.fbusPortAddr.get  //浮点 store：fsw f1, offset(x2)
    fRegfile.get.io.scoreboard_set :=
      MuxOR(dispatch.io.rdMark_flt.get.valid, UIntToOH(dispatch.io.rdMark_flt.get.addr))//Dispatch 发射浮点写寄存器指令时，FRegfile scoreboard 把目标 f 寄存器标记为 busy。
    // Mux input to read port 0
    // 等价于：
    // valid = io.dm.float_rs.valid ||
    //         floatCore.read_ports(0).valid ||
    //         dispatch.frs1Read(0).valid
    // 优先级按 MuxCase 顺序
    fRegfile.get.io.read_ports(0).valid := MuxCase(false.B, Seq(
      io.dm.float_rs.get.valid -> true.B,  //DebugModule 读浮点寄存器
      floatCore.get.io.read_ports(0).valid -> true.B,  //FloatCore 内部读取浮点操作数
      dispatch.io.frs1Read.get(0).valid -> true.B,  //Dispatch 阶段读取 frs1，可用于rvv读
    ))
    fRegfile.get.io.read_ports(0).addr := MuxCase(0.U, Seq(
      io.dm.float_rs.get.valid -> io.dm.float_rs.get.addr,
      floatCore.get.io.read_ports(0).valid -> floatCore.get.io.read_ports(0).addr,
      dispatch.io.frs1Read.get(0).valid -> dispatch.io.frs1Read.get(0).addr,
    ))
    floatCore.get.io.read_ports(0).data := fRegfile.get.io.read_ports(0).data

    // Connect read ports 1 and 2 to floatCore
    for (j <- 1 until 3) {
      fRegfile.get.io.read_ports(j).valid := floatCore.get.io.read_ports(j).valid
      fRegfile.get.io.read_ports(j).addr := floatCore.get.io.read_ports(j).addr
      floatCore.get.io.read_ports(j).data := fRegfile.get.io.read_ports(j).data
    }

    // Broadcast data back from read port 0 to debug interface
    io.dm.float_rs.get.data := fRegfile.get.io.read_ports(0).data

    // Mux input to write port
    fRegfile.get.io.write_ports(0).valid := MuxCase(false.B, Seq(
      io.dm.float_rd.get.valid -> true.B,//DebugModule 写浮点寄存器
      floatCore.get.io.write_ports(0).valid -> true.B,//FloatCore 内部写回浮点结果
    ))
    fRegfile.get.io.write_ports(0).addr := MuxCase(0.U, Seq(
      io.dm.float_rd.get.valid -> io.dm.float_rd.get.addr,
      floatCore.get.io.write_ports(0).valid -> floatCore.get.io.write_ports(0).addr,
    ))
    fRegfile.get.io.write_ports(0).data := MuxCase(Fp32.Zero(false.B), Seq(
      io.dm.float_rd.get.valid -> io.dm.float_rd.get.data,
      floatCore.get.io.write_ports(0).valid -> floatCore.get.io.write_ports(0).data,
    ))
    fRegfile.get.io.dm_write_valid := io.dm.float_rd.get.valid

    // Route RVV async FP writeback (vfmv.f.s) through fRegfile write port 1.
    // The LSU FP-load (floatCore.write_ports(1)) takes priority; async_frd
    // uses the port only when LSU isn't writing. The scoreboard is pre-marked
    // via rdMark_flt (see Decode.scala), so clearing on this write doesn't
    // trip FRegfile's scoreboard_error assertion.
    // Port 1: Arbitrate between LSU FP-load and RVV async writeback.
    // LSU takes priority; RVV is stalled if LSU is writing.
    val lsuWriting = floatCore.get.io.write_ports(1).valid//判断 LSU FP-load 是否正在写浮点寄存器。
    if (p.enableRvv) {
      val asyncFrd = io.rvvcore.get.async_frd//RVV 异步写回 (vfmv.f.s) 通过 fRegfile 写端口 1。LSU FP-load 优先级更高；当 LSU 正在写时，async_frd 会被阻塞。
      asyncFrd.ready := !lsuWriting//当 LSU 正在写时，asyncFrd.ready = false，RVV 异步写回被阻塞。
      fRegfile.get.io.write_ports(1).valid := lsuWriting || asyncFrd.valid
      fRegfile.get.io.write_ports(1).addr := Mux(lsuWriting,
        floatCore.get.io.write_ports(1).addr,
        asyncFrd.bits.addr)
      fRegfile.get.io.write_ports(1).data := Mux(lsuWriting,
        floatCore.get.io.write_ports(1).data,
        Fp32.fromWord(asyncFrd.bits.data))
    } else {
      fRegfile.get.io.write_ports(1) := floatCore.get.io.write_ports(1)
    }//LSU 的浮点 load 结果先接到 FloatCore,然后由 FloatCore 再通过 write_ports(1) 写 FRegfile。

    floatCore.get.io.inst <> dispatch.io.float.get
    dispatch.io.fscoreboard.get := fRegfile.get.io.scoreboard//Dispatch 需要知道哪些 f 寄存器正等待写回，以避免发射依赖未完成的浮点指令。
    dispatch.io.csrFrm.get := csr.io.float.get.out.frm//Dispatch 需要它来确定浮点指令使用的舍入模式
    floatCore.get.io.csr <> csr.io.float.get//FloatCore 需要访问 CSR 里的浮点控制寄存器 (frm/fcsr)。
    floatCore.get.io.rs1 := regfile.io.readData(0)//整数寄存器
    floatCore.get.io.rs2 := regfile.io.readData(1)//整数寄存器
    // Memory
    //   ↓
    // LSU.rd_flt
    //   ↓
    // FloatCore.lsu_rd
    //   ↓
    // FloatCore.write_ports(1)
    //   ↓
    // FRegfile.write_ports(1)
    floatCore.get.io.lsu_rd.valid := lsu.io.rd_flt.valid//LSU 浮点 load 写回 valid 送给 FloatCore。
    floatCore.get.io.lsu_rd.bits.addr := lsu.io.rd_flt.bits.addr
    floatCore.get.io.lsu_rd.bits.data := lsu.io.rd_flt.bits.data

    rob_io.writeAddrFloat.get := dispatch.io.rdMark_flt.get
    (0 until 2).foreach(i => {//RetirementBuffer 记录浮点写回数据
      rob_io.writeDataFloat.get(i).valid := fRegfile.get.io.write_ports(i).valid
      rob_io.writeDataFloat.get(i).bits.addr := fRegfile.get.io.write_ports(i).addr
      rob_io.writeDataFloat.get(i).bits.data := fRegfile.get.io.write_ports(i).data.asWord
    })
  }

  // ---- MLU / DVU / RVV async / Float scalar / Debug scalar写回仲裁: 共享一个 Arbiter → Regfile 写端口 offset ----
  val mluDvuOffset = p.instructionLanes                           // port4,写端口偏移 (避开 lane 0~3)
  val mluDvuInputs = Seq(mlu.io.rd, dvu.io.rd) ++                // MLU + DVU
                     io.rvvcore.map(x => Seq(x.async_rd)).getOrElse(Seq()) ++  // RVV 异步写回
                     floatCore.map(x => Seq(x.io.scalar_rd)).getOrElse(Seq()) ++ // 浮点标量写回
                     Seq(io.dm.scalar_rd)                         // dm调试模块写回
  //固定优先级：MLU > DVU > RVV async_rd > Float scalar_rd > Debug scalar_rd
  val arb = Module(new Arbiter(new RegfileWriteDataIO, mluDvuInputs.length))
  arb.io.in <> mluDvuInputs                                       // 所有源接入仲裁
  arb.io.out.ready := true.B                                      // 总是就绪
  regfile.io.writeData(mluDvuOffset).valid    := arb.io.out.valid
  regfile.io.writeData(mluDvuOffset).bits.addr := arb.io.out.bits.addr
  regfile.io.writeData(mluDvuOffset).bits.data := arb.io.out.bits.data
  //因为分支错误路径屏蔽主要针对 lane0~lane3 的同周期普通发射指令结果。
  //MLU/DVU 这类多周期单元的写回通常已经与发射 lane 解耦，
  //不能简单按当前周期的 branchTaken 去屏蔽，否则可能错误屏蔽之前正确路径发出的乘除法结果。
  regfile.io.writeMask(p.instructionLanes).valid := false.B       // MLU/DVU 端口不屏蔽

  // LSU 写回: 使用独立的写端口 (instructionLanes + 1)
  val lsuOffset = p.instructionLanes + 1                         //port5
  regfile.io.writeData(lsuOffset).valid    := lsu.io.rd.valid
  regfile.io.writeData(lsuOffset).bits.addr := lsu.io.rd.bits.addr
  regfile.io.writeData(lsuOffset).bits.data := lsu.io.rd.bits.data
  regfile.io.writeMask(lsuOffset).valid := lsu.io.fault.valid     // LSU 异常时屏蔽写回

  // 分支发生时屏蔽后续 lane 的写回 (writeMask 防止错误结果写入 Regfile)
  val writeMask = bru.map(_.io.taken.valid).scan(false.B)(_||_)//扫描累积，生成每个 lane 的写回屏蔽信号。只要前面有分支 taken，后续 lane 就屏蔽写回。
  for (i <- 0 until p.instructionLanes) {
    regfile.io.writeMask(i).valid := writeMask(i)//针对bru分支写回
  }
  regfile.io.debugWriteValid := io.dm.scalar_rd.valid//告诉 Regfile 当前 DebugModule 是否正在写整数寄存器。

  // ---- RVV 向量扩展 (条件: enableRvv) ----
  if (p.enableRvv) {
    // Dispatch → RVV: 指令下发 + 状态反馈
    dispatch.io.rvv.get <> io.rvvcore.get.inst
    //因为译码和发射 RVV 指令时，dispatch需要知道当前向量配置是否合法
    dispatch.io.rvvState.get        := io.rvvcore.get.configState   // VL/VTYPE 等配置
    // Dispatch 可以用它判断：
    // 是否可以继续发射新的 RVV 指令；
    // 是否可以处理依赖 RVV 空闲的控制指令；
    // 是否可以安全处理 trap/flush/debug 等状态。
    dispatch.io.rvvIdle.get         := io.rvvcore.get.rvv_idle      // RVV 空闲标志
    //RVV Core 还能接收多少条 RVV 指令。如果 RVV Core 队列快满，Dispatch 不能继续向 RVV 发射
    dispatch.io.rvvQueueCapacity.get := io.rvvcore.get.queue_capacity// RVV 内部队列容量 (用于调度)

    // 标量寄存器 → RVV (rs1/rs2 操作数)
    // Dispatch 设置 Regfile 读地址
    //   ↓
    // Regfile 输出 readData
    //   ↓
    // SCore 把 readData 整组送给 RVV Core
    io.rvvcore.get.rs := regfile.io.readData//默认 4 lane 时有 8 个读端口

    // 浮点寄存器 → RVV (frs 操作数, 条件: enableFloat)
    // FRegfile 的读数据和 RVV 指令发射之间存在 1 拍时序关系，需要打一拍对齐。
    if (p.enableFloat) {
      val rvvFrsReg = Reg(Vec(p.instructionLanes, UInt(32.W)))// RVV frs 寄存器缓存,用于延迟 1 拍匹配 Regfile 时序
      for (i <- 0 until p.instructionLanes) {
        rvvFrsReg(i) := Mux(dispatch.io.frs1Read.get(i).valid,
          fRegfile.get.io.read_ports(0).data.asWord, rvvFrsReg(i))// RVV frs1 取自 FRegfile 读端口0 (frs1Read)
        io.rvvcore.get.frs(i) := rvvFrsReg(i)                     // 延迟1拍 (匹配 Regfile 时序)
      }
    } else {
      for (i <- 0 until p.instructionLanes) {
        io.rvvcore.get.frs(i) := 0.U                               // 无浮点时输出0
      }
    }

    // CSR ↔ RVV: vstart/vxrm/vxsat 读写 + frm 只读
    // CSR 指令写 vstart
    //   ↓
    // csr.io.rvv.vstart_write
    //   ↓
    // RVV Core csr.vstart_write
    io.rvvcore.get.csr.vstart_write <> csr.io.rvv.get.vstart_write
    io.rvvcore.get.csr.vxrm_write  <> csr.io.rvv.get.vxrm_write
    io.rvvcore.get.csr.vxsat_write <> csr.io.rvv.get.vxsat_write
    io.rvvcore.get.csr.frm := csr.io.rvv.get.frm
    //状态返回 CSR 模块
    csr.io.rvv.get.vstart := io.rvvcore.get.csr.vstart
    csr.io.rvv.get.vl     := io.rvvcore.get.configState.bits.vl
    csr.io.rvv.get.vtype  := io.rvvcore.get.configState.bits.vtype
    csr.io.rvv.get.vxrm   := io.rvvcore.get.csr.vxrm
    csr.io.rvv.get.vxsat  := io.rvvcore.get.csr.vxsat
  }

  // ---- 取指异常有效性条件: 仅在流水线完全空闲时才报告取指异常 ----
  //只有当整个流水线基本排空，并且没有分支刷新、没有未完成整数/浮点/RVV/LSU 操作时，
  //Fetch fault 才被认为是真正可提交的取指异常。
  val isBranching = bru.map(_.io.taken.valid).reduce(_||_)        // 有分支?
  val hasFetchedInstructions = fetch.io.inst.lanes.map(_.valid).reduce(_||_)
  val floatIdle = if (p.enableFloat) { fRegfile.get.io.scoreboard === 0.U } else { true.B }
  val rvvIdle   = if (p.enableRvv)   { io.rvvcore.get.rvv_idle } else { true.B }
  // 取指异常仅在以下条件全部满足时才有效 (确保不是虚假异常):
  val fetchFaultValid = fetch.io.fault.valid &&
      !isBranching &&                                             // 无分支 (分支会刷新流水线)
      (regfile.io.scoreboard.regd === 0.U) &&                    // 无待写标量操作
      floatIdle &&                                                // 浮点空闲
      rvvIdle &&                                                  // RVV 空闲
      !lsu.io.active &&                                           // LSU 空闲 (LSU 可能故障)
      !hasFetchedInstructions                                     // 无已取指指令
  fault_manager.io.in.fetchFault := MakeValid(fetchFaultValid, fetch.io.fault.bits)//只有当 fetchFaultValid 条件满足时，fetch.io.fault.bits 中的异常信息才被认为有效并传递给 fault_manager。

  // ---- IBus 仲裁: LSU (优先) 和 Fetch 共享同一 IBus ----
  // LSU 访问指令存储器优先 (如 FENCE.I 后的指令同步)
  // Fetch 正常取指；
  // LSU 在特殊情况下访问指令侧通路，例如 FENCE.I 或指令同步相关操作。
  io.ibus.valid := Mux(lsu.io.ibus.valid, lsu.io.ibus.valid, fetch.io.ibus.valid)
  io.ibus.addr  := Mux(lsu.io.ibus.valid, lsu.io.ibus.addr, fetch.io.ibus.addr)
  // ready 分发: LSU 优先, Fetch 仅在 LSU 不请求时得到
  lsu.io.ibus.ready   := Mux(lsu.io.ibus.valid, io.ibus.ready, false.B)
  fetch.io.ibus.ready := Mux(lsu.io.ibus.valid, false.B, io.ibus.ready)
  // fault: Fetch 需要, LSU 不需要
  fetch.io.ibus.fault := Mux(lsu.io.ibus.valid, MakeInvalid(new FaultInfo(p)), io.ibus.fault)
  lsu.io.ibus.rdata   := io.ibus.rdata                           // rdata 广播
  fetch.io.ibus.rdata := io.ibus.rdata
  lsu.io.ibus.fault := MakeInvalid(new FaultInfo(p))             // LSU 不使用 ibus fault

  // ---- 数据总线: 直连 LSU ----
  io.dbus <> lsu.io.dbus
  io.ebus <> lsu.io.ebus

  // ---- DEBUG: 调试观测信号输出 ----
  io.debug.cycles := csr.io.csr.out.value(4)                     // 周期计数器

  // debugEn: 哪些 lane 当前有指令发射 (valid+ready 且非分支)
  val debugEn   = RegInit(0.U(p.instructionLanes.W))//每条 lane 的调试有效标志
  val debugAddr = RegInit(VecInit.fill(p.instructionLanes)(0.U(32.W)))
  val debugInst = RegInit(VecInit.fill(p.instructionLanes)(0.U(32.W)))

  // debugBrch: scanRight OR → 分支发生点之后的所有 lane 都被标记
  val debugBrch = Cat(bru.map(_.io.taken.valid).scanRight(false.B)(_ || _))
  // debugEn 仅在 lane 有指令发射且不是分支时有效。分支指令的 debugEn 也为 1，但它后面的指令（即使发射了）也被 debugBrch 屏蔽掉。
  debugEn := Cat(fetch.io.inst.lanes.map(x => x.valid && x.ready && !branchTaken))

  for (i <- 0 until p.instructionLanes) {
    debugAddr(i) := Mux(debugEn(i), fetch.io.inst.lanes(i).bits.addr, debugAddr(i))
    debugInst(i) := Mux(debugEn(i), fetch.io.inst.lanes(i).bits.inst, debugInst(i))
  }

  io.debug.en := debugEn & ~debugBrch                              // 屏蔽分支后的无效指令
  io.debug.addr <> debugAddr
  io.debug.inst <> debugInst

  // DBus 调试观测
  io.debug.dbus.valid      := io.dbus.valid
  io.debug.dbus.bits.addr  := io.dbus.addr
  io.debug.dbus.bits.wdata := io.dbus.wdata
  io.debug.dbus.bits.write := io.dbus.write

  // Dispatch 调试观测 (每条 lane 的发射情况)
  for (i <- 0 until p.instructionLanes) {
    io.debug.dispatch(i).instFire := dispatch.io.inst(i).fire
    io.debug.dispatch(i).instAddr := dispatch.io.inst(i).bits.addr
    io.debug.dispatch(i).instInst := dispatch.io.inst(i).bits.inst
  }

  // Regfile 写地址/写数据调试观测
  // regfile 的写回数据来源多样，调试观测时直接观察最终写回 Regfile 的地址和数据更有意义，
  // 而不是单纯观察某个源的写回信号。
  for (i <- 0 until p.instructionLanes) {
    io.debug.regfile.writeAddr(i).valid := regfile.io.writeAddr(i).valid
    io.debug.regfile.writeAddr(i).bits  := regfile.io.writeAddr(i).addr
  }
  // regfile.io.writeData(i) 已经包含了最终写回 Regfile 的 valid/addr/data，直接观察它即可。
  for (i <- 0 until p.instructionLanes + 2) {
    io.debug.regfile.writeData(i) := regfile.io.writeData(i)
  }

  // 浮点调试观测 (条件)
  if (p.enableFloat) {
    io.debug.float.get.writeAddr.valid := dispatch.io.rdMark_flt.get.valid
    io.debug.float.get.writeAddr.bits  := dispatch.io.rdMark_flt.get.addr
    for (i <- 0 until 2) {
      io.debug.float.get.writeData(i).valid    := fRegfile.get.io.write_ports(i).valid
      io.debug.float.get.writeData(i).bits.addr := fRegfile.get.io.write_ports(i).addr
      io.debug.float.get.writeData(i).bits.data := fRegfile.get.io.write_ports(i).data.asWord
    }
  }

  // 退役缓冲区调试观测
  io.debug.rb := rob_io.debug

  // RVVI 验证跟踪 (仅 useRetirementBuffer 时启用)
  if (p.useRetirementBuffer) {
    val rvvi = Module(new RvviTrace(p))
    rvvi.io.rb  := rob_io.debug
    rvvi.io.csr := csr.io.trace
  }
}

/** EmitSCore — Standalone Verilog 生成入口 (调试用) */
object EmitSCore extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new SCore(p), args)
}
