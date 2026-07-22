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
// Bru.scala — 分支解析单元 (Branch Unit)
//
// 条件分支: BEQ/BNE/BLT/BGE/BLTU/BGEU; 无条件: JAL/JALR
// 每 lane 一个 Bru, lane0 额外承担 FaultManager 和 CSR 交互
// 输出: BranchTakenIO 反馈取指单元 + rd 写回地址
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._

object Bru {
  def apply(p: Parameters, first: Boolean): Bru = {
    return Module(new Bru(p, first))
  }
}

object BruOp extends ChiselEnum {
  val JAL  = Value                                      // 无条件跳转, rd 写 pc+4
  val JALR = Value                                      // 寄存器间接跳转, 目标来自 Regfile target 端口
  val BEQ  = Value                                      // rs1 == rs2 时跳转
  val BNE  = Value                                      // rs1 != rs2 时跳转
  val BLT  = Value                                      // 有符号 rs1 < rs2 时跳转
  val BGE  = Value                                      // 有符号 rs1 >= rs2 时跳转
  val BLTU = Value                                      // 无符号 rs1 < rs2 时跳转
  val BGEU = Value                                      // 无符号 rs1 >= rs2 时跳转
  val EBREAK = Value                                    // 调试/断点异常, 仅 lane0 解码
  val ECALL = Value                                     // 环境调用异常, 仅 lane0 解码
  val MPAUSE = Value                                    // CoralNPU 暂停指令, 仅 lane0 解码
  val MRET = Value                                      // 异常返回, 目标为 CSR.mepc, 仅 lane0 解码
  val WFI = Value                                       // 等待中断, 仅 lane0 解码
  val FAULT = Value                                     // FaultManager 注入的异常跳转
}

// Decode 阶段送入 BRU 的命令。
// fwd 表示 Fetch 已经预测/顺序前推到 target, Execute 阶段会用实际结果校验是否需要重定向。
class BruCmd(p: Parameters) extends Bundle {
  // fwd = 0：
  //   前端当前按顺序 pc+4 继续取指。
  //   如果 Execute 判断真实 taken，则需要重定向到 target。
  // fwd = 1：
  //   前端已经前推到 target。
  //   如果 Execute 判断真实 not-taken，则需要重定向回 pc+4。
  val fwd = Bool()                                      // Fetch/Dispatch 认为已经前推到目标
  val op = BruOp()                                      // 分支/跳转/系统操作类型
  val pc = UInt(p.programCounterBits.W)                 // 当前指令 PC
  val target = UInt(p.programCounterBits.W)             // Decode 计算出的分支/JAL 目标
  val link = UInt(5.W)                                  // JAL/JALR 写回寄存器, 0 表示不写
  val inst = UInt(32.W)                                 // 原始指令, 异常上报时使用
}

// BRU 的一拍流水状态: Decode 输入被锁存后, 下一拍结合 rs1/rs2 与 CSR/Fault 信息完成判定。
class BranchState(p: Parameters) extends Bundle {
  val fwd = Bool()                                      // Decode/Fetch 侧的前推方向
  val op = BruOp()                                      // 锁存后的 BRU 操作
  val target = UInt(p.programCounterBits.W)             // BRU 最终重定向目标
  val originalTarget = UInt(p.programCounterBits.W)     // 未被异常/JALR 修正前的目标
  val linkValid = Bool()                                // 是否需要写 rd=pc+4
  val linkAddr = UInt(5.W)                              // link 写回地址
  val linkData = UInt(p.programCounterBits.W)           // link 写回数据, 即 pc+4
  val pcEx = UInt(32.W)                                 // Execute 阶段使用的指令 PC
  val inst = UInt(32.W)                                 // 原始指令备份
}

object BranchState {
  def default(p: Parameters): BranchState = {
    // BRU 流水寄存器复位/空闲默认值; valid=false 时这些字段不会被消费。
    val result = Wire(new BranchState(p))
    result.fwd := false.B
    result.op := BruOp.JAL
    result.target := 0.U
    result.originalTarget := 0.U
    result.linkValid := false.B
    result.linkAddr := 0.U
    result.linkData := 0.U
    result.pcEx := 0.U
    result.inst := 0.U
    result
  }
}

/** 分支解析单元:
 * 计算分支/JAL/JALR 是否 taken, 产生 Fetch 重定向目标, 并在 lane0 处理 CSR/异常/中断。
 * @param p     核心参数。
 * @param first 是否为 lane0 BRU; lane0 额外拥有 CSR/FaultManager/interlock 端口。
 */
class Bru(p: Parameters, first: Boolean) extends Module {
  val io = IO(new Bundle {
    // Decode cycle: Dispatch 发来的 BRU 请求。
    //BRU 没有 req.ready。Dispatch 只要把 req.valid 拉高，BRU 就会在本周期接收并打一拍。
    val req = Flipped(Valid(new BruCmd(p)))             // Decode 阶段有效请求

    // Execute cycle: 使用 Regfile 数据计算真实 taken/target, 并反馈 Fetch。
    val csr = Option.when(first)(new CsrBruIO(p))       // lane0 专属 CSR 读写口
    val rs1 = Input(new RegfileReadDataIO)              // 源操作数1
    val rs2 = Input(new RegfileReadDataIO)              // 源操作数2
    val rd  = Valid(Flipped(new RegfileWriteDataIO))    // JAL/JALR link 写回端口
    val taken = new BranchTakenIO(p)                    // 需要 Fetch 重定向时置 valid
    val actually_taken = Output(Bool())                 // 分支真实是否 taken
    val real_target = Output(UInt(p.programCounterBits.W)) // 调试/校验用真实目标
    val pc = Output(UInt(p.programCounterBits.W))       // 当前 BRU 指令 PC
    val target = Flipped(new RegfileBranchTargetIO)     // JALR 目标地址旁路/读口
    //用于系统指令/异常时阻塞 Dispatch，避免后续指令在 CSR/异常状态尚未稳定时继续推进。
    val interlock = Option.when(first)(Output(Bool()))  // lane0 系统指令导致 Dispatch 互锁

    val fault_manager = Option.when(first)(Input(Valid(Flipped(new FaultManagerOutput)))) // lane0 接收异常仲裁结果
  })

  // ---- Decode → Execute 状态准备 ----
  // first=false 的普通 lane 不参与 CSR 模式切换, 因此 mode 固定为 Machine。
  //// 如果是 lane0，读取当前 CSR privilege mode。非 lane0 固定视为 Machine
  val mode = if (first) { io.csr.get.out.mode } else { CsrMode.Machine } 
  val fault_manager_valid = io.fault_manager.map(_.valid).getOrElse(false.B) // 只有 lane0 可能收到异常

  val pcDe  = io.req.bits.pc                            // Decode 阶段 PC
  // 1. JAL/JALR link 写回值；
  // 2. fwd=true 且预测错误时恢复顺序取指；
  // 3. WFI 顺序目标。
  val pc4De = io.req.bits.pc + 4.U                      // link 写回值

  val stateReg = RegInit(MakeValid(false.B, BranchState.default(p))) // 一拍 BRU 流水寄存器
  val nextState = Wire(new BranchState(p))              // 下一拍 Execute 使用的状态
  // | 条件                | 含义               |
  // | ----------------- | ---------------- |
  // | `io.req.valid`    | 当前有 BRU 请求       |
  // | `link != 0`       | rd 不是 x0         |
  // | `op` 是 `JAL/JALR` | 只有跳转链接指令写 `pc+4` |
  nextState.linkValid := io.req.valid && (io.req.bits.link =/= 0.U) &&
               (io.req.bits.op.isOneOf(BruOp.JAL, BruOp.JALR))

  nextState.op := Mux(fault_manager_valid, BruOp.FAULT, io.req.bits.op) // 异常优先转成 FAULT
  nextState.fwd := io.req.valid && io.req.bits.fwd       // 记录前端是否已按 taken 方向前推

  nextState.linkAddr := io.req.bits.link                 // JAL/JALR 的 rd地址
  nextState.linkData := pc4De                            // rd 数据 = pc+4
  nextState.pcEx := pcDe                                 // Execute 阶段 PC
  nextState.inst := io.req.bits.inst                     // 原始指令
  nextState.originalTarget := io.req.bits.target          // Decode 原始目标

  // lane0 可处理系统控制流: ECALL/FAULT 进 mtvec, MRET 回 mepc, WFI 顺序到 pc+4。
  // | 操作      | 目标                   |
  // | ------- | -------------------- |
  // | 默认      | `io.req.bits.target` |
  // | `ECALL` | `mtvec`              |
  // | `MRET`  | `mepc`               |
  // | `WFI`   | `pc+4`               |
  // ECALL:进入异常入口 mtvec。
  // MRET:从异常返回到 mepc。
  // WFI:当前实现把控制流前进到 pc+4，同时设置 CSR wfi 状态。
  val mtvec = if (first) { Cat(io.csr.get.out.mtvec(31,2), 0.U(2.W)) } else { 0.U(32.W )}
  val pipeline0Target = if (first) {
    val mret = (io.req.bits.op === BruOp.MRET)
    val ecall = io.req.bits.op === BruOp.ECALL
    MuxCase(io.req.bits.target, Seq(
      ecall -> mtvec,
      mret -> io.csr.get.out.mepc,
      (io.req.bits.op === BruOp.WFI) -> pc4De,
    ))
  } else { io.req.bits.target }
  // | 条件                    | `nextState.target`    | 含义                             |
  // | --------------------- | --------------------- | ------------------------------ |
  // | `fault_manager_valid` | `mtvec`               | 异常跳转到异常入口                      |
  // | `io.req.bits.fwd`     | `pc+4`                | 前端已去 target，如果发现不该 taken，则恢复顺序 |
  // | `op == JALR`          | `io.target.data & ~1` | JALR 实际目标，最低位清零                |
  // 如果 fwd=true，说明前端已经前推到 target。此时如果 Execute 发现分支不成立，需要重定向回 pc+4，所以 target 被设成 pc+4。
  // 如果 fwd=false，说明前端没有去 target。此时如果 Execute 发现分支成立，需要重定向到 target。
  nextState.target := MuxCase(pipeline0Target, Seq(
      // Faults: 异常统一跳向 mtvec。
      fault_manager_valid -> mtvec,
      // Normal operation: fwd 表示前端已去 target, miss 时重定向回 pc+4; JALR 低位清零。
      io.req.bits.fwd -> pc4De,
      ((io.req.bits.op === BruOp.JALR)) -> (io.target.data & "xFFFFFFFE".U),
  ))
  val stateRegValid = io.req.valid || fault_manager_valid // 普通请求或异常注入都会占用 BRU 一拍
  stateReg.valid := stateRegValid
  stateReg.bits := Mux(stateRegValid, nextState, stateReg.bits)

  // This mux sits on the critical path.
  // val rs1 = Mux(readRs, io.rs1.data, 0.U)
  // val rs2 = Mux(readRs, io.rs2.data, 0.U)
  val rs1 = io.rs1.data                                  // 组合读出的 rs1
  val rs2 = io.rs2.data                                  // 组合读出的 rs2

  // ---- 分支条件比较 ----
  val eq  = rs1 === rs2                                  // BEQ
  val neq = !eq                                          // BNE
  val lt  = rs1.asSInt < rs2.asSInt                      // BLT: 有符号比较
  val ge  = !lt                                          // BGE
  val ltu = rs1 < rs2                                    // BLTU: 无符号比较
  val geu = !ltu                                         // BGEU

  // io.req.bits.op 是 Decode 阶段 op；
  // stateReg.bits.op 是 Execute 阶段 op。
  val op = stateReg.bits.op
  // 这些系统/异常类操作只能在 pipeline0(lane0) 解码; 其它 lane 只允许普通分支/跳转。
  if (!first) {
    assert(!op.isOneOf(
      BruOp.EBREAK,
      BruOp.ECALL,
      BruOp.MPAUSE,
      BruOp.MRET,
      BruOp.WFI,
    ))
  }

  // ---- lane0 中断/系统指令 taken 判定 ----
  // 中断只在可中断的普通 BRU 指令上插入, ECALL/MRET/EBREAK/FAULT 自身不再被异步中断覆盖。
  // 中断触发条件：
  // 条件	              含义
  // stateReg.valid    	当前有有效 BRU 指令
  // csr.out.interrupt	CSR 表示有 pending interrupt
  // interruptible	    当前 op 可以被中断覆盖
  val interrupt_taken = if (first) {
    val interruptible = !op.isOneOf(BruOp.ECALL, BruOp.MRET, BruOp.EBREAK, BruOp.FAULT)//不可中断
    stateReg.valid && io.csr.get.out.interrupt && interruptible
  } else { false.B }

  // pipeline0Taken 覆盖 lane0 专属操作: ECALL/MRET/WFI 都需要改变控制流。
  // | op        | `pipeline0Taken` | 含义                        |
  // | --------- | ---------------: | ------------------------- |
  // | `EBREAK`  |                0 | 不跳转，后面触发 usage fault/halt |
  // | `ECALL`   |                1 | 跳转到 `mtvec`               |
  // | `MPAUSE`  |                0 | 暂停，不跳转                    |
  // | `MRET`    |                1 | 跳转到 `mepc`                |
  // | `WFI`     |                1 | 跳到 `pc+4` 并进入 wfi         |
  // | interrupt |                1 | 跳转到 `mtvec`               |
  val pipeline0Taken = if (first) {
    MuxLookup(op, false.B)(Seq(
      BruOp.EBREAK -> false.B,
      BruOp.ECALL  -> true.B,
      BruOp.MPAUSE -> false.B,
      BruOp.MRET   -> true.B,
      BruOp.WFI    -> true.B,
    )) || interrupt_taken
  } else { false.B }

  // isTaken 是指令语义上的真实 taken, 用于 actually_taken/调试观测。
  // | op          | `isTaken`        |
  // | ----------- | ---------------- |
  // | `JAL/JALR`  | 一定 true          |
  // | `BEQ`       | `rs1 == rs2`     |
  // | `BNE`       | `rs1 != rs2`     |
  // | `BLT/BGE`   | 有符号比较            |
  // | `BLTU/BGEU` | 无符号比较            |
  // | `FAULT`     | 一定 true          |
  // | 系统类默认       | `pipeline0Taken` |
  val isTaken = MuxLookup(op, pipeline0Taken)(Seq(
    BruOp.JAL    -> true.B,
    BruOp.JALR   -> true.B,
    BruOp.BEQ    -> eq,
    BruOp.BNE    -> neq,
    BruOp.BLT    -> lt,
    BruOp.BGE    -> ge,
    BruOp.BLTU   -> ltu,
    BruOp.BGEU   -> geu,
    BruOp.FAULT  -> true.B,
  ))
// isTaken 是真实分支结果；
// io.taken.valid 是是否需要重定向 Fetch。

  // taken.valid 表示需要纠正 Fetch PC:
  //   fwd=false 时, 真实 taken 才需要跳转到 target;
  //   fwd=true  时, 真实 not-taken 才需要跳回 pc+4。
  // | 真实 taken | `fwd` | 是否需要重定向 |
  // | -------: | ----: | ------: |
  // |        0 |     0 |       0 |
  // |        1 |     0 |       1 |
  // |        0 |     1 |       1 |
  // |        1 |     1 |       0 |
  io.taken.valid := stateReg.valid && (interrupt_taken || MuxLookup(op, pipeline0Taken)(Seq(//是否重定向
    BruOp.JAL    -> (true.B =/= stateReg.bits.fwd),
    BruOp.JALR   -> (true.B =/= stateReg.bits.fwd),
    BruOp.BEQ    -> (eq  =/= stateReg.bits.fwd),
    BruOp.BNE    -> (neq =/= stateReg.bits.fwd),
    BruOp.BLT    -> (lt  =/= stateReg.bits.fwd),
    BruOp.BGE    -> (ge  =/= stateReg.bits.fwd),
    BruOp.BLTU   -> (ltu =/= stateReg.bits.fwd),
    BruOp.BGEU   -> (geu =/= stateReg.bits.fwd),
    BruOp.FAULT  -> true.B,
  )))
  //当前 Execute 阶段这条分支/跳转/系统控制流，语义上是否 taken。
  io.actually_taken := stateReg.valid && isTaken
  // real_target 保留指令真实目标: 如果前端已 fwd, miss 时 target 需要恢复为原始方向/JALR 实际地址。
  io.real_target := Mux(stateReg.bits.fwd,
                        Mux(stateReg.bits.op === BruOp.JALR,
                            io.target.data & "xFFFFFFFE".U,
                            stateReg.bits.originalTarget),
                        stateReg.bits.target)
  io.pc := stateReg.bits.pcEx                           // 对外暴露 Execute 阶段指令 PC

  io.taken.value := Mux(interrupt_taken, mtvec, stateReg.bits.target) // Fetch 重定向 PC

  io.rd.valid := stateReg.valid && stateReg.bits.linkValid // JAL/JALR link 写回
  io.rd.bits.addr := stateReg.bits.linkAddr             // link rd 地址
  io.rd.bits.data := stateReg.bits.linkData             // link rd 数据 = pc+4

  if (first) {
    // ---- lane0 CSR / Fault 写入 ----
    // 系统指令和异常会阻塞 Dispatch, 等待 CSR/异常状态被稳定提交。
    io.interlock.get := stateReg.valid &&
      op.isOneOf(
        BruOp.EBREAK, BruOp.ECALL,
        BruOp.MPAUSE, BruOp.MRET, BruOp.FAULT)
    // Usage Fault: 当前仅 EBREAK 作为需要 halt 的用法异常处理。
    val usageFault = stateReg.valid && op.isOneOf(BruOp.EBREAK)

    io.csr.get.in.mode.valid := stateReg.valid && (op === BruOp.MRET) // MRET 恢复机器模式
    io.csr.get.in.mode.bits := CsrMode.Machine

    // mepc: ECALL/中断记录当前 PC; 外部 FaultManager 提供更精确的 fault PC。
    // | 情况                 | `mepc` 作用   |
    // | ------------------ | ----------- |
    // | `ECALL`            | 记录当前 PC     |
    // | interrupt          | 记录被中断指令 PC  |
    // | FaultManager fault | 记录 fault PC |
    io.csr.get.in.mepc.valid :=
      (stateReg.valid && (op === BruOp.ECALL)) ||
      interrupt_taken ||
      io.fault_manager.get.valid
    io.csr.get.in.mepc.bits := MuxCase(stateReg.bits.pcEx, Seq(
      io.fault_manager.get.valid -> io.fault_manager.get.bits.mepc,
    ))

    // mcause 优先级: FaultManager > ECALL > usageFault > interrupt。
    // | 情况                 | 是否写 mcause |
    // | ------------------ | ---------: |
    // | usageFault/EBREAK  |          是 |
    // | ECALL              |          是 |
    // | interrupt          |          是 |
    // | FaultManager valid |          是 |
    io.csr.get.in.mcause.valid := (stateReg.valid &&
      (
        usageFault ||
        (op === BruOp.ECALL)
      ) || interrupt_taken || io.fault_manager.get.valid
    )

    // | 优先级 | 来源                | mcause                      |
    // | --: | ----------------- | --------------------------- |
    // |   1 | FaultManager      | `fault_manager.bits.mcause` |
    // |   2 | ECALL             | `11`                        |
    // |   3 | usageFault/EBREAK | `25`                        |
    // |   4 | interrupt         | `csr.out.interrupt_cause`   |
    io.csr.get.in.mcause.bits := MuxCase(0.U, Seq(
        // RISC-V standard exceptions: 外部异常/ECALL 走标准编码。
        io.fault_manager.get.valid -> io.fault_manager.get.bits.mcause,
        (op === BruOp.ECALL)  -> 11.U,
        // CoralNPU-specific things: 自定义 fault 使用保留编码区。
        usageFault            -> (24 + 1).U,
        // Asynchronous: 异步中断优先级最低。
        interrupt_taken       -> io.csr.get.out.interrupt_cause,
    ))

    // mtval: usageFault 默认填 PC; FaultManager 可覆盖为具体 fault value。
    // | 情况           | mtval                |
    // | ------------ | -------------------- |
    // | usageFault   | 默认当前 PC              |
    // | FaultManager | fault-specific mtval |
    io.csr.get.in.mtval.valid :=
      (stateReg.valid && usageFault) || io.fault_manager.get.valid
    io.csr.get.in.mtval.bits := MuxCase(stateReg.bits.pcEx, Seq(
      io.fault_manager.get.valid -> io.fault_manager.get.bits.mtval,
    ))

    // Pipeline will be halted: MPAUSE 或不可恢复 fault 会暂停核心。
    io.csr.get.in.halt := (stateReg.valid && (op === BruOp.MPAUSE)) ||
                      io.csr.get.in.fault
    // Faults that should halt the processor:
    // 可由软件异常例程处理的 fault 不在这里置 fault, 只通过 CSR trap 流程处理。
    //当前只有 EBREAK 作为 usage fault 触发 fault。
    io.csr.get.in.fault := usageFault
    io.csr.get.in.wfi := stateReg.valid && (op === BruOp.WFI) // 进入等待中断状态
  }

  // ---- 基本一致性检查 ----
  // JAL/JALR/系统/异常类操作不一定需要两个 rs 源操作数; 条件分支必须保证 rs1/rs2 有效。
  val ignore = op.isOneOf(BruOp.JAL, BruOp.JALR, BruOp.EBREAK, BruOp.ECALL,
                          BruOp.MPAUSE, BruOp.MRET, BruOp.WFI, BruOp.FAULT)

  assert(!(stateReg.valid && !io.rs1.valid) || ignore)
  assert(!(stateReg.valid && !io.rs2.valid) || ignore)
}
