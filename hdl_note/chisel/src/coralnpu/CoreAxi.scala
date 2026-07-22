// ============================================================================
// CoreAxi.scala — 完整 CoralNPU AXI 系统顶层 (RawModule)
//
// CoreAxi 是完整的 CoralNPU AXI 系统顶层。内部包含:
//   - 时钟/复位管理: RstSync(异步复位同步) → ClockGate(门控时钟) → Core
//   - ITCM/DTCM: TCM128 + SRAM + FabricArbiter(3口: core/debug/axi_slave)
//   - CSR: CoreCSR 挂载在 FabricMux 第三个端口
//   - ibus 双路径: 地址在 ITCM 内走快速 SRAM 路径，否则走 IBus2Axi→AXI 外部
//   - ebus→DBus2Axi→AXI Master (写独占, 读与 ibus 通过 readAddrArb 仲裁)
//   - Debug Module: dmReqArbiter + inflight Queue 路由请求/响应
//   - AxiSlave: 外部 AXI Master→内部 Fabric 协议转换
//
//                          ┌─────────────────────────────────────────────────────┐
//                          │                     CoreAxi                         │
//                          │                                                     │
//  aclk/aresetn/te ───────►│ RstSync ──► global_reset ═══════════════════════╗   │
//                          │   │                                            ║   │
//                          │   └─► clk_o ──► ClockGate ──► cg.clk_o ───┐    ║   │
//                          │                                             │    ║   │
//                          │   ┌─ CoreCSR ◄── boot_addr                 │    ║   │
//                          │   │    │  reset/cg/pcStart                 │    ║   │
//                          │   │    │  debug.req/rsp ◄──────┐           │    ║   │
//                          │   │    └─ fabric ──► FabricMux │           │    ║   │
//                          │   │                    port2   │           │    ║   │
//                          │   │                            │           │    ║   │
//                          │   ├─ DebugModule               │           │    ║   │
//                          │   │    dmReqArbiter(0=外部DM,  │           │    ║   │
//                          │   │       1=CSR内部) +Queue(1) │           │    ║   │
//                          │   │    响应: rspId=0→io.dm     │           │    ║   │
//                          │   │           rspId=1→csr.debug│           │    ║   │
//                          │   │    itcm/dtcm ─────────┐    │           │    ║   │
//                          │   │                       │    │           │    ║   │
//                          │   │                       │    │           │    ║   │
//                          │   └─ Core ──────────────┐ │    │           │    ║   │
//                          │       │ ibus  dbus ebus  │ │    │           │    ║   │
//                          │       │                  │ │    │           │    ║   │
//                          │   ┌───┘       ┌──────────┘ │    │           │    ║   │
//                          │   │           │            │    │           │    ║   │
//                          │   │ inItcm?   │            │    │           │    ║   │
//                          │   │ ┌─YES─┐   │       ┌────┘    │           │    ║   │
//                          │   │ │ITCM │   │       │DBus2Axi │           │    ║   │
//                          │   │ │ path│   │       │ id=0    │           │    ║   │
//                          │   │ │     │   │       └──┬─────┘           │    ║   │
//                          │   │ │TCM128   │          │axi.write ──────┼───►│
//                          │   │ │ ↕       │          │axi.read ───┐   │    ║   │
//                          │   │ │SRAM     │    ┌─────▼──────┐     │   │    ║   │
//                          │   │ │ ↕       │    │  DTCM      │     │   │    ║   │
//                          │   │ │Fabric   │    │  TCM128    │     │   │    ║   │
//                          │   │ │Arbiter  │    │  ↕SRAM     │     │   │    ║   │
//                          │   │ │port0    │    │  ↕Fabric   │     │   │    ║   │
//                          │   │ └────┬───┘    │  Arbiter   │     │   │    ║   │
//                          │   │      │        │  port0     │     │   │    ║   │
//                          │   │      │inItcmReg└────┬──────┘     │   │    ║   │
//                          │   │   ┌──┴──────┐       │            │   │    ║   │
//                          │   │   │ Mux rdata│      │            │   │    ║   │
//                          │   │   │ /ready   │      │            │   │    ║   │
//                          │   │   └─────────┘      │            │   │    ║   │
//                          │   │                    │            │   │    ║   │
//                          │   └─ NO ──► IBus2Axi ──┘            │   │    ║   │
//                          │              id=1    axi.addr ───┐  │   │    ║   │
//                          │                                  │  │   │    ║   │
//                          │              ┌───────────────────┘  │   │    ║   │
//                          │              │ readAddrArb(0=ebus,  ├───┘    ║   │
//                          │              │            1=ibus)   │        ║   │
//                          │              │ 仲裁后 → axi_master  │        ║   │
//                          │              │   .read.addr         │        ║   │
//                          │              │                      │        ║   │
//                          │              │  读数据 ID 路由:     │        ║   │
//                          │              │   id=0→ebus2axi     │        ║   │
//                          │              │   id=1→ibus2axi     │        ║   │
//                          │              └──────────────────────┘        ║   │
//                          │                                                     │
//  axi_slave ─────────────►│ AxiSlave ──► fabricMux.source                      │
//                          │               │                                     │
//                          │               ├─ port0 → ITCM Arbiter port1         │
//                          │               ├─ port1 → DTCM Arbiter port1         │
//                          │               └─ port2 → CoreCSR.fabric             │
//                          │                                                     │
//                          │  DM.itcm/dtcm → ITCM/DTCM Arbiter port2             │
//                          │                                                     │
//                          ╚══════════════ withClockAndReset ═══════════════════╝
//                          └─────────────────────────────────────────────────────┘
// ============================================================================
// Copyright 2024 Google LLC
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

package coralnpu

import chisel3._
import chisel3.util._

import bus._
import common._

/** CoreAxi — 完整 CoralNPU AXI 系统顶层 (RawModule, 非 Module) */
class CoreAxi(p: Parameters, coreModuleName: String) extends RawModule {
  override val desiredName = coreModuleName + "Axi"
  val memoryRegions = p.m                                       // 内存区域列表 (ITCM/DTCM/CSR)
  val io = IO(new Bundle {
    val aclk    = Input(Clock())                                 // AXI 时钟
    val aresetn = Input(AsyncReset())                            // AXI 异步复位 (低有效)
    val axi_slave  = Flipped(new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits))  // 外部→内部
    val axi_master = new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)           // 内部→外部
    val halted     = Output(Bool())                              // 核心已暂停
    val fault      = Output(Bool())                              // 核心发生异常
    val wfi        = Output(Bool())                              // 核心等待中断
    val irq        = Input(Bool())                               // 外部中断
    val boot_addr  = Input(UInt(p.fetchAddrBits.W))             // 启动地址 (复位时加载到 pcStartReg)
    val timer_irq    = Input(Bool())                             // 定时器中断
    val software_irq = Input(Bool())                             // 软件中断
    val debug = new DebugIO(p)                                   // 调试观测
    val dm    = new DebugModuleIO(p)                             // 调试模块
    val te    = Input(Bool())                                    // 测试使能 (旁路复位同步/时钟门控)
  })
  dontTouch(io)                                                  // 防止 Chisel 优化掉顶层 IO (RawModule 不会自动保留)

  // ---- 时钟/复位管理: RstSync → ClockGate ----
  val rst_sync = Module(new RstSync())                           // 复位同步器
  rst_sync.io.clk_i  := io.aclk
  rst_sync.io.rstn_i := io.aresetn                              // 异步复位输入 (低有效)
  rst_sync.io.clk_en := true.B                                   // 时钟始终使能 (RstSync 内部通过 clk_en_int 门控)
  rst_sync.io.te     := io.te                                    // 测试模式: te=1 旁路同步器, 直通原始复位和时钟

  // global_reset 计算链 (从内到外逐步看):
  //   ① Mux(te, aresetn, rstn_o) — te=1: 旁路同步器, 直通原始复位; te=0: 用同步后的复位
  //   ② .asBool                  — Chisel 类型转换: AsyncReset → Bool
  //   ③ !                        — 取反: 低有效 → 高有效 (Chisel 的 withClockAndReset 要求高有效)
  //   ④ .asAsyncReset            — Chisel 类型转换: Bool → AsyncReset
  val global_reset = (!Mux(io.te, io.aresetn, rst_sync.io.rstn_o).asBool).asAsyncReset

  // {} 内所有 Module/Reg 都使用同步后的时钟和复位
  withClockAndReset(rst_sync.io.clk_o, global_reset) {

    // ---- CSR 子系统 ----
    val csr = Module(new CoreCSR(p))                             // 片上 CSR (复位/时钟/启动控制)
    csr.io.internal := false.B                                   // 来自外部 AXI (非内部)
    csr.io.bootAddr := io.boot_addr

    // ---- 时钟门控 + 调试模块 ----
    val cg = Module(new ClockGate)                               // 时钟门控
    cg.io.clk_i := rst_sync.io.clk_o
    cg.io.te    := io.te

    val dm = Module(new DebugModule(p))                          // RISC-V 调试模块 (Spec 0.13)
        dontTouch(dm.io)                                          // 保留调试模块 IO (即使未被外部连接)
    val dmEnable = RegInit(false.B)                              // 延迟1拍使能 (等待复位释放, 防止虚假事务)
    dmEnable := true.B
    // 调试请求仲裁: Round-Robin 在 port0(外部DM) 和 port1(CSR内部) 间选择
    // GateDecoupled: enable=0 时阻断 valid 传播, 防止复位前发出请求
    val dmReqArbiter = Module(new CoralNPURRArbiter(new DebugModuleReqIO(p), 2))
    dmReqArbiter.io.in(0) <> GateDecoupled(io.dm.req, dmEnable)        // port0: 外部 Debug 请求
    dmReqArbiter.io.in(1) <> GateDecoupled(csr.io.debug.req, dmEnable)  // port1: CSR 内部 Debug 请求

    // inflight Queue: 记录请求来源 ID, 用于响应路由
    val inflight = Module(new Queue(UInt(1.W), 1))
    dm.io.ext.req.bits  := dmReqArbiter.io.out.bits
    dm.io.ext.req.valid := dmReqArbiter.io.out.valid && inflight.io.enq.ready
    dmReqArbiter.io.out.ready := dm.io.ext.req.ready && inflight.io.enq.ready

    inflight.io.enq.bits  := dmReqArbiter.io.chosen              // 记录来源: 0=DM, 1=CSR
    inflight.io.enq.valid := dmReqArbiter.io.out.valid && dm.io.ext.req.ready

    val rspId = inflight.io.deq.bits                             // 取出请求来源 ID
    inflight.io.deq.ready := dm.io.ext.rsp.fire

    // 响应按 ID 路由: rspId=1→CSR, rspId=0→外部DM
    csr.io.debug.rsp.bits := dm.io.ext.rsp.bits// 其他字段直接连接, 仅 valid 由 dm.io.ext.rsp.valid 和 rspId 决定
    io.dm.rsp.bits := dm.io.ext.rsp.bits// 其他字段直接连接, 仅 valid 由 dm.io.ext.rsp.valid 和 rspId 决定
    csr.io.debug.rsp.valid := dm.io.ext.rsp.valid && inflight.io.deq.valid && (rspId === 1.U)// 仅当响应来源为 CSR 时才有效
    io.dm.rsp.valid := dm.io.ext.rsp.valid && inflight.io.deq.valid && (rspId === 0.U)// 仅当响应来源为 DM 时才有效
    dm.io.ext.rsp.ready := inflight.io.deq.valid &&
        Mux(rspId === 1.U, csr.io.debug.rsp.ready, io.dm.rsp.ready)

    // ---- Core 实例化 (门控时钟 + CSR/dm 控制的复位) ----
    // Core 使用独立的时钟 (cg.io.clk_o: 可门控) 和复位 (core_reset: CSR 或 DM 可控)
    val core_reset = Mux(io.te,
        (!io.aresetn.asBool).asAsyncReset,                       // te=1 (测试): 直通原始复位
        (csr.io.reset || dm.io.ndmreset).asAsyncReset)           // te=0 (正常): CSR软件复位 或 DM非调试复位
    val core = withClockAndReset(cg.io.clk_o, core_reset) { Core(p, coreModuleName) }

    // ---- 中断: RegNext 打断从 IO 到 ibus 的长组合路径 (改善时序) ----
    val irq_reg = RegNext(io.irq, false.B)
    val timer_irq_reg = RegNext(io.timer_irq, false.B)
    val software_irq_reg = RegNext(io.software_irq, false.B)

    // 时钟门控使能条件 (任意一个为真时保持时钟):
    //   有中断请求 或 CSR 未请求关时钟 且 核心未在 WFI 或 DM 请求 halt
    cg.io.enable := irq_reg || timer_irq_reg || software_irq_reg ||
                    (!csr.io.cg && !core.io.wfi) || dm.io.haltreq(0)
    io.halted := core.io.halted
    io.fault  := core.io.fault
    io.wfi    := core.io.wfi
    core.io.irq := irq_reg || dm.io.haltreq(0)
    core.io.timer_irq := timer_irq_reg
    core.io.software_irq := software_irq_reg
    csr.io.halted := core.io.halted
    csr.io.fault  := core.io.fault
    csr.io.coralnpu_csr := core.io.csr.out                      // 核内 CSR→CSR 子系统
    core.io.debug_req := true.B
    core.io.csr.in.value(0) := csr.io.pcStart                    // CSR→Core: PC 启动地址
    for (i <- 1 until p.csrInCount) { core.io.csr.in.value(i) := 0.U }  //其他CSR清零
    io.debug <> core.io.debug
    core.io.dflush.ready := true.B                               // 无 DCache, flush 恒就绪
    core.io.iflush.ready := true.B

    // ---- Debug Modulef ↔ Core 连接 ----
    core.io.dm.debug_req  := dm.io.haltreq(0)  //请求 core 停止
    core.io.dm.resume_req := dm.io.resumereq(0)  //请求 core 恢复
    dm.io.resumeack(0) := !core.io.dm.debug_mode && RegNext(core.io.dm.debug_mode, false.B) // core 从 debug 模式恢复时发出 resume ack
    dm.io.halted(0)    := core.io.dm.debug_mode // core 进入 debug 模式时认为已 halted
    dm.io.running(0)   := !core.io.dm.debug_mode  // core 运行时认为未 halted
    dm.io.havereset(0) := false.B // core 的复位由 CSR 直接控制, DM 无需监控复位状态
    core.io.dm.csr     := dm.io.csr  // DM 访问 CSR 的请求/响应
    core.io.dm.csr_rs1 := dm.io.csr_rs1  // DM 访问 CSR 的 rs1 寄存器值
    dm.io.csr_rd := core.io.dm.csr_rd  // DM 读取 CSR 的返回数据
    dm.io.scalar_rd <> core.io.dm.scalar_rd  // DM 访问 Core 标量寄存器的读数据
    dm.io.scalar_rs <> core.io.dm.scalar_rs  // DM 访问 Core 标量寄存器的 rs1/rs2 值
    if (p.enableFloat) {  // 如果启用浮点, 连接 DM 的浮点寄存器接口
      dm.io.float_rd.get <> core.io.dm.float_rd.get
      dm.io.float_rs.get <> core.io.dm.float_rs.get
    }

    // ===================================================================
    // TCM 存储子系统
    // TCM 3 端口仲裁: port0=core, port1=AXI_slave, port2=DebugModule
    //                  ┌────────────────┐
    // Core port0 ─────►│                │
    // AXI  port1 ─────►│ FabricArbiter  │──► SRAM wrapper ─► TCM128
    // DM   port2 ─────►│                │
    //                  └────────────────┘
    // ===================================================================
    val tcmPortCount = 3

    // ---- ITCM: 指令紧耦合内存 ----
    val itcmSizeBytes     = 1024 * p.itcmSizeKBytes             // 总字节数
    val itcmSubEntryWidth = 8                                    // 子条目 8-bit (字节粒度)
    val itcmWidth         = p.axi2DataBits                       // 数据宽度
    val itcmEntries       = itcmSizeBytes / (itcmWidth / 8)     // SRAM 行数
    val itcm = Module(new TCM128(itcmSizeBytes, itcmSubEntryWidth, memoryRegions(0).memStart))  // ITCM128 模块 (128-bit 数据总线, 内部自动适配子条目宽度)
    dontTouch(itcm.io)                                           // 保留 ITCM IO (防止综合优化)
    val itcmWrapper = Module(new SRAM(p, log2Ceil(itcmEntries))) // Fabric↔SRAM↔TCM128包装器
    itcm.io.addr   := itcmWrapper.io.sram.address
    itcm.io.enable := itcmWrapper.io.sram.enable
    itcm.io.write  := itcmWrapper.io.sram.isWrite
    itcm.io.wdata  := itcmWrapper.io.sram.writeData
    itcm.io.wmask  := itcmWrapper.io.sram.mask
    itcmWrapper.io.sram.readData := itcm.io.rdata
    val itcmArbiter = Module(new FabricArbiter(p, tcmPortCount)) // 3口仲裁
    itcmArbiter.io.port <> itcmWrapper.io.fabric

    // ibus 双路径: 地址在 ITCM 内→SRAM快速; 否则→IBus2Axi→AXI外部
    assert(memoryRegions(0).memType === MemoryRegionType.IMEM)
    val inItcm = memoryRegions(0).contains(core.io.ibus.addr)   // 地址命中 ITCM?

    // ITCM 路径 (port0): 仅当地址在 ITCM 内时发读
    itcmArbiter.io.source(0).readDataAddr := MakeValid(core.io.ibus.valid && inItcm, core.io.ibus.addr)// 读地址有效且命中 ITCM 时发出
    itcmArbiter.io.source(0).writeDataAddr := MakeInvalid(UInt(p.axi2AddrBits.W))// 该端口仅用于读, 写地址无效
    itcmArbiter.io.source(0).writeDataBits := 0.U  // 无写数据
    itcmArbiter.io.source(0).writeDataStrb := 0.U  // 无写掩码

    // AXI 外部路径 (id=1): 地址不在 ITCM 时走 IBus2Axi
    val ibus2axi = IBus2Axi(p, id = 1)  // ibus→AXI 转换器 (id=1 区分于 ebus 的 id=0)
    ibus2axi.io.ibus.valid := core.io.ibus.valid && !inItcm  // 读地址有效且不命中 ITCM 时发出
    ibus2axi.io.ibus.addr  := core.io.ibus.addr   

    // 结果 Mux: inItcmReg 打断组合环 (addr→inItcm→rdata→core→addr)
    val inItcmReg = RegNext(inItcm, true.B)
    core.io.ibus.rdata := Mux(inItcmReg, itcmArbiter.io.source(0).readData.bits, ibus2axi.io.ibus.rdata)
    core.io.ibus.ready := Mux(inItcm, inItcmReg, ibus2axi.io.ibus.ready)
    core.io.ibus.fault := ibus2axi.io.ibus.fault// 仅外部访问可能发生故障, 内部访问 ITCM 不会

    // ---- DTCM: 数据紧耦合内存 ----
    val dtcmSizeBytes     = 1024 * p.dtcmSizeKBytes
    val dtcmEntries       = dtcmSizeBytes / (p.axi2DataBits / 8)
    val dtcmSubEntryWidth = 8
    val dtcm = Module(new TCM128(dtcmSizeBytes, dtcmSubEntryWidth, memoryRegions(1).memStart))
    dontTouch(dtcm.io)                                           // 保留 DTCM IO
    val dtcmWrapper = Module(new SRAM(p, log2Ceil(dtcmEntries)))
    dtcm.io.addr   := dtcmWrapper.io.sram.address
    dtcm.io.enable := dtcmWrapper.io.sram.enable
    dtcm.io.write  := dtcmWrapper.io.sram.isWrite
    dtcm.io.wdata  := dtcmWrapper.io.sram.writeData
    dtcm.io.wmask  := dtcmWrapper.io.sram.mask
    dtcmWrapper.io.sram.readData := dtcm.io.rdata
    val dtcmArbiter = Module(new FabricArbiter(p, tcmPortCount))
    dtcmArbiter.io.port <> dtcmWrapper.io.fabric

    // DTCM port0: core 的 dbus 读/写
    dtcmArbiter.io.source(0).readDataAddr := MakeValid( 
        core.io.dbus.valid && !core.io.dbus.write, core.io.dbus.addr)  
    dtcmArbiter.io.source(0).writeDataAddr := MakeValid(
        core.io.dbus.valid && core.io.dbus.write, core.io.dbus.addr)
    dtcmArbiter.io.source(0).writeDataBits := core.io.dbus.wdata
    dtcmArbiter.io.source(0).writeDataStrb := core.io.dbus.wmask
    core.io.dbus.rdata := dtcmArbiter.io.source(0).readData.bits
    core.io.dbus.ready := true.B                                 // DTCM 始终就绪

    // ---- FabricMux: ITCM/DTCM/CSR 三路地址路由 ----
    val fabricMux = Module(new FabricMux(p, memoryRegions))
    fabricMux.io.ports(0) <> itcmArbiter.io.source(1)           // ITCM port1→Fabric port0
    fabricMux.io.periBusy(0) := itcmArbiter.io.fabricBusy(1)
    fabricMux.io.ports(1) <> dtcmArbiter.io.source(1)           // DTCM port1→Fabric port1
    fabricMux.io.periBusy(1) := dtcmArbiter.io.fabricBusy(1)
    fabricMux.io.ports(2) <> csr.io.fabric                       // CSR→Fabric port2
    fabricMux.io.periBusy(2) := false.B

    // DM 调试访问 ITCM/DTCM (port2)
    itcmArbiter.io.source(2) <> dm.io.itcm
    dtcmArbiter.io.source(2) <> dm.io.dtcm

    // ---- AXI Slave: 外部 AXI→内部 Fabric ----
    val axiSlave = Module(new AxiSlave(p))
    val axiSlaveEnable = RegInit(false.B)                        // 延迟使能 (复位后启动)
    axiSlaveEnable := true.B
    axiSlave.io.fabric   <> fabricMux.io.source
    axiSlave.io.periBusy := fabricMux.io.fabricBusy
    // GateDecoupled: 门控 AXI 通道防止复位前的虚假事务
    axiSlave.io.axi.write.addr <> GateDecoupled(io.axi_slave.write.addr, axiSlaveEnable)
    axiSlave.io.axi.write.data <> GateDecoupled(io.axi_slave.write.data, axiSlaveEnable)
    io.axi_slave.write.resp    <> GateDecoupled(axiSlave.io.axi.write.resp, axiSlaveEnable)
    axiSlave.io.axi.read.addr  <> GateDecoupled(io.axi_slave.read.addr, axiSlaveEnable)
    io.axi_slave.read.data     <> GateDecoupled(axiSlave.io.axi.read.data, axiSlaveEnable)

    // ---- AXI Master: 内部 ebus→外部 AXI (id=0, 区分于 ibus 的 id=1) ----
    val ebus2axi = DBus2Axi(p, id = 0)                           // ebus→AXI 转换器
    ebus2axi.io.dbus  <> core.io.ebus.dbus                       // ebus DBus ↔ DBus2Axi
    ebus2axi.io.fault <> core.io.ebus.fault                      // AXI 故障 ↔ ebus 故障

    // 写通道: 仅 ebus 使用 (ibus 是只读的)
    io.axi_master.write <> ebus2axi.io.axi.write

    // 读通道仲裁: ebus(id=0) vs ibus(id=1), Round-Robin
    val readAddrArb = Module(new CoralNPURRArbiter(
        new AxiAddress(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits), 2))
    readAddrArb.io.in(0) <> ebus2axi.io.axi.read.addr            // port0: ebus 读地址
    readAddrArb.io.in(1) <> ibus2axi.io.axi.addr                 // port1: ibus 读地址
    io.axi_master.read.addr <> readAddrArb.io.out                 // 仲裁后发出

    // 读数据按 AXI ID 路由: id=0→ebus2axi, id=1→ibus2axi (由 DBus2Axi/IBus2Axi 的 id 参数决定)
    ebus2axi.io.axi.read.data.valid := io.axi_master.read.data.valid &&
        io.axi_master.read.data.bits.id === 0.U  // 仅 id=0 的数据有效
    ebus2axi.io.axi.read.data.bits := io.axi_master.read.data.bits
    ibus2axi.io.axi.data.valid := io.axi_master.read.data.valid &&
        io.axi_master.read.data.bits.id === 1.U  // 仅 id=1 的数据有效
    ibus2axi.io.axi.data.bits := io.axi_master.read.data.bits
    io.axi_master.read.data.ready := Mux(
        io.axi_master.read.data.bits.id === 1.U,
        ibus2axi.io.axi.data.ready, ebus2axi.io.axi.read.data.ready)
  }
}
