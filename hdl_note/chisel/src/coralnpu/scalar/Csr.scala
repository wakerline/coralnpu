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
// Csr.scala — 控制状态寄存器单元 (CSR)
// 维护 RISC-V CSR: mstatus/mcause/mepc/mtvec/mie/mip 等
// 支持 CSRRW/CSRRS/CSRRC 指令 + 中断/异常硬件响应 + 调试模式
// ============================================================================

package coralnpu

import common.{MakeInvalid, MakeValid, MuxUpTo1H}
import chisel3._
import chisel3.util._
import coralnpu.float.{CsrFloatIO}

class CsrRvvIO(p: Parameters) extends Bundle {
  // To Csr from RvvCore: RVV 核维护的只读/状态 CSR 值。
  val vstart = Input(UInt(log2Ceil(p.rvvVlen).W))       // 当前向量起始元素
  val vl = Input(UInt(log2Ceil(p.rvvVlen).W))           // 当前向量长度
  val vtype = Input(UInt(32.W))                         // 当前向量类型配置
  val vxrm = Input(UInt(2.W))                           // 向量定点舍入模式
  val vxsat = Input(Bool())                             // 向量定点饱和标志
  // From Csr to RvvCore: 标量 CSR 指令写 RVV CSR 时, 通过 valid 脉冲转发给 RVV 核。
  val vstart_write = Output(Valid(UInt(log2Ceil(p.rvvVlen).W))) // 写 vstart
  val vxrm_write = Output(Valid(UInt(2.W)))             // 写 vxrm
  val vxsat_write = Output(Valid(Bool()))               // 写 vxsat
  val frm = Output(UInt(3.W))                           // 浮点/向量共享舍入模式
}

object Csr {
  def apply(p: Parameters): Csr = {
    return Module(new Csr(p))
  }
}

object CsrAddress extends ChiselEnum {
  // Per spec, this is not allocated. We use this internally to
  // represent an invalid address.
  val RESERVED  = Value(0x000.U(12.W))                  // 内部保留: 非法 CSR 地址
  // Floating-point CSRs.
  val FFLAGS    = Value(0x001.U(12.W))
  val FRM       = Value(0x002.U(12.W))
  val FCSR      = Value(0x003.U(12.W))
  // Vector CSRs.
  val VSTART    = Value(0x008.U(12.W))
  val VXSAT     = Value(0x009.U(12.W))
  val VXRM      = Value(0x00A.U(12.W))
  // Machine-mode trap/status CSRs.
  val MSTATUS   = Value(0x300.U(12.W))
  val MISA      = Value(0x301.U(12.W))
  val MIE       = Value(0x304.U(12.W))
  val MTVEC     = Value(0x305.U(12.W))
  val MSTATUSH  = Value(0x310.U(12.W))
  val MSCRATCH  = Value(0x340.U(12.W))
  val MEPC      = Value(0x341.U(12.W))
  val MCAUSE    = Value(0x342.U(12.W))
  val MTVAL     = Value(0x343.U(12.W))
  val MIP       = Value(0x344.U(12.W))
  // Debug trigger CSRs.
  val TSELECT   = Value(0x7A0.U(12.W))
  val TDATA1    = Value(0x7A1.U(12.W))
  val TDATA2    = Value(0x7A2.U(12.W))
  val TINFO     = Value(0x7A4.U(12.W))
  // Debug-mode CSRs.
  val DCSR      = Value(0x7B0.U(12.W))
  val DPC       = Value(0x7B1.U(12.W))
  val DSCRATCH0 = Value(0x7B2.U(12.W))
  val DSCRATCH1 = Value(0x7B3.U(12.W))
  // CoralNPU machine context CSRs.
  val MCONTEXT0 = Value(0x7C0.U(12.W))
  val MCONTEXT1 = Value(0x7C1.U(12.W))
  val MCONTEXT2 = Value(0x7C2.U(12.W))
  val MCONTEXT3 = Value(0x7C3.U(12.W))
  val MCONTEXT4 = Value(0x7C4.U(12.W))
  val MCONTEXT5 = Value(0x7C5.U(12.W))
  val MCONTEXT6 = Value(0x7C6.U(12.W))
  val MCONTEXT7 = Value(0x7C7.U(12.W))
  val MPC       = Value(0x7E0.U(12.W))
  val MSP       = Value(0x7E1.U(12.W))
  // Machine-mode counters.
  val MCYCLE    = Value(0xB00.U(12.W))
  val MINSTRET  = Value(0xB02.U(12.W))
  val MCYCLEH   = Value(0xB80.U(12.W))
  val MINSTRETH = Value(0xB82.U(12.W))
  // RVV read-only CSRs.
  val VL        = Value(0xC20.U(12.W))
  val VTYPE     = Value(0xC21.U(12.W))
  val VLENB     = Value(0xC22.U(12.W))
  // Machine information CSRs.
  val MVENDORID = Value(0xF11.U(12.W))
  val MARCHID   = Value(0xF12.U(12.W))
  val MIMPID    = Value(0xF13.U(12.W))
  val MHARTID   = Value(0xF14.U(12.W))
  // CoralNPU custom CSRs.
  val KISA      = Value(0xFC0.U(12.W))
  val KSCM0     = Value(0xFC4.U(12.W))
  val KSCM1     = Value(0xFC8.U(12.W))
  val KSCM2     = Value(0xFCC.U(12.W))
  val KSCM3     = Value(0xFD0.U(12.W))
  val KSCM4     = Value(0xFD4.U(12.W))
}

object CsrMode extends ChiselEnum {
  val Machine = Value(0.U(2.W))                         // 正常机器模式
  val Debug = Value(2.U(2.W))                           // RISC-V Debug 模式
}

/* For details, see The RISC-V Debug Specification v1.0, chapter 4.9.1 */
class Dcsr extends Bundle {
  val debugver = UInt(4.W)                              // Debug spec 版本
  val extcause = UInt(3.W)                              // 扩展 debug cause
  val cetrig = Bool()                                   // control-transfer trigger
  val pelp = Bool()                                     // previous expected landing pad
  val ebreakvs = Bool()                                 // VS-mode ebreak 进入 debug
  val ebreakvu = Bool()                                 // VU-mode ebreak 进入 debug
  val ebreakm = Bool()                                  // M-mode ebreak 进入 debug
  val ebreaks = Bool()                                  // S-mode ebreak 进入 debug
  val ebreaku = Bool()                                  // U-mode ebreak 进入 debug
  val stepie = Bool()                                   // single-step 时是否允许中断
  val stopcount = Bool()                                // debug 模式停止计数
  val stoptime = Bool()                                 // debug 模式停止 time
  val cause = UInt(3.W)                                 // 进入 debug 的原因
  val v = Bool()                                        // virtualized debug
  val mprven = Bool()                                   // debug 下 MPRV 使能
  val nmip = Bool()                                     // NMI pending
  val step = Bool()                                     // 单步执行使能
  val prv = UInt(2.W)                                   // 进入 debug 前的特权级

  def asWord: UInt = {
    // 按 Debug Spec 的 DCSR 位布局打包成 32-bit CSR 读值。
    val ret = Cat(debugver, 0.U(1.W), extcause, 0.U(4.W), cetrig, pelp, ebreakvs, ebreakvu, ebreakm, 0.U(1.W),
                  ebreaks, ebreaku, stepie, stopcount, stoptime, cause, v, mprven, nmip, step, prv)
    assert(ret.getWidth == 32)
    ret
  }
}

/* For details, see The RISC-V Debug Specification v1.0, chapter 5.7.2 */
class Tdata1 extends Bundle {
  val data = UInt(32.W)                                 // trigger 配置原始位
  def _type: UInt = data(31,28)                         // trigger 类型字段
  def asWord: UInt = {
    data.asUInt
  }
  def isTrigger6: Bool = {
    _type === 6.U(4.W)                                  // type=6: mcontrol6 trigger
  }
  def m: Bool = data(6)                                 // M-mode trigger 使能
}

// Cause types for the dcsr `cause` field.
// See Table 8 in Chapter 4.9.1 of the Debug Specification.
// These are sorted in priority order.
object DebugCause extends ChiselEnum {
  val resethaltreq = 5.U(3.W)                           // reset halt request
  val haltgroup = 6.U(3.W)                              // halt group
  val haltreq = 3.U(3.W)                                // 外部 debug halt 请求
  val trigger = 2.U(3.W)                                // trigger 命中
  val ebreak = 1.U(3.W)                                 // ebreak 进入 debug
  val step = 4.U(3.W)                                   // 单步完成
  val other = 7.U(3.W)                                  // 其它原因
}

class CsrCounters(p: Parameters) extends Bundle {
  val nRetired = UInt(log2Ceil(p.retirementBufferSize + 1).W) // 本周期退役指令数
}

class CsrBruIO(p: Parameters) extends Bundle {
  val in = new Bundle {
    val mode   = Valid(CsrMode())                       // BRU/MRET 请求更新特权模式
    val mcause = Valid(UInt(32.W))                      // trap cause 写入
    val mepc   = Valid(UInt(32.W))                      // trap PC 写入
    val mtval  = Valid(UInt(32.W))                      // trap value 写入
    val halt   = Output(Bool())                         // MPAUSE/fault 请求暂停核心
    val fault  = Output(Bool())                         // 不可恢复 fault 标志
    val wfi    = Output(Bool())                         // WFI 进入等待中断状态
  }
  val out = new Bundle {
    val mode  = Input(CsrMode())                        // 当前 CSR 模式
    val mepc  = Input(UInt(32.W))                       // MRET 返回地址
    val mtvec = Input(UInt(32.W))                       // trap 入口地址
    val interrupt = Input(Bool())                       // 当前是否有可响应中断
    val interrupt_cause = Input(UInt(32.W))             // 中断 cause 编码
  }
  def defaults() = {
    out.mode := CsrMode.Machine
    out.mepc := 0.U
    out.mtvec := 0.U
    out.interrupt := false.B
    out.interrupt_cause := 0.U
  }
}

class Csr(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Reset and shutdown.
    val csr = new CsrInOutIO(p)                         // SoC/核心外部 CSR 初始化和观测口

    // Decode cycle.
    val req = Flipped(Valid(new CsrCmd))                // CSR 指令请求

    // Execute cycle.
    val rs1 = Flipped(new RegfileReadDataIO)            // CSRRS/CSRRC/CSRRW 的 rs1 数据
    val rd  = Valid(Flipped(new RegfileWriteDataIO))    // CSR 旧值写回 rd
    val bru = Flipped(new CsrBruIO(p))                  // BRU trap/MRET/WFI/中断交互
    val float = Option.when(p.enableFloat) { Flipped(new CsrFloatIO(p)) } // 浮点 CSR/fflags 交互
    val rvv = Option.when(p.enableRvv) { new CsrRvvIO(p) } // RVV CSR 交互

    val counters = Input(new CsrCounters(p))            // 退役计数输入

    // Pipeline Control.
    val halted = Output(Bool())                         // 核心已暂停
    val fault  = Output(Bool())                         // 核心不可恢复异常
    val wfi    = Output(Bool())                         // 核心处于 WFI
    val irq    = Input(Bool())                          // 外部中断
    val dm = new Bundle {
      val debug_req = Input(Bool())                     // Debug Module 请求 halt
      val resume_req = Input(Bool())                    // Debug Module 请求 resume
      val debug_mode = Output(Bool())                   // 当前/即将进入 debug 模式
      val single_step = Output(Bool())                  // trigger 单步/断点控制
      val dcsr_step = Output(Bool())                    // DCSR.step 输出给 Dispatch
      val current_pc = Input(UInt(32.W))                // 当前执行 PC, 写入 dpc
      val next_pc = Input(UInt(32.W))                   // 单步完成后的下一 PC
      val debug_pc = Valid(UInt(p.fetchAddrBits.W))     // debug 模式写 dpc 后重定向 Fetch
    }
    val timer_irq = Input(Bool())                       // 机器定时器中断
    val software_irq = Input(Bool())                    // 机器软件中断
    val trace = Output(new CsrTraceIO(p))               // CSR 写 trace
  })

  def LegalizeTdata1(wdata: UInt): Tdata1 = {
    assert(wdata.getWidth == 32)
    val newWdata = Wire(new Tdata1)
    // 只保留本实现支持的 mcontrol6 字段, 不支持/保留位清零。
    newWdata.data := Cat(
      6.U(4.W),   // type
      wdata(27), // dmode
      0.U(11.W),
      wdata(15,12) & 1.U(4.W), // action
      0.U(5.W),
      wdata(6),  // m
      (wdata(5,0) & 4.U(6.W)) // !uncertainen, !s, !u, execute, !store, !load
    )
    newWdata
  }

  // Control registers. CsrAddress.RESERVED is used for invalid values.
  val req = RegInit(MakeInvalid(new CsrCmd))            // CSR 请求打一拍进入执行阶段
  req := MakeValid(io.req.valid, io.req.bits, bitsWhenInvalid=req.bits)

  // Pipeline Control.
  val halted = RegInit(false.B)                         // MPAUSE/fault 后保持暂停
  val fault  = RegInit(false.B)                         // 不可恢复 fault sticky 标志
  val wfi    = RegInit(false.B)                         // WFI sticky, 中断/debug_req 唤醒

  // Machine(0)/Debug(2) Mode.
  val mode = RegInit(CsrMode.Machine)                   // 当前执行模式

  // CSRs parallel loaded when(reset).
  val mpc       = RegInit(0.U(32.W))                    // CoralNPU 自定义 machine PC
  val msp       = RegInit(0.U(32.W))                    // CoralNPU 自定义 machine SP
  val mcause    = RegInit(0.U(32.W))                    // trap cause
  val mtval     = RegInit(0.U(32.W))                    // trap value
  val mcontext0 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 0
  val mcontext1 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 1
  val mcontext2 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 2
  val mcontext3 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 3
  val mcontext4 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 4
  val mcontext5 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 5
  val mcontext6 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 6
  val mcontext7 = RegInit(0.U(32.W))                    // 自定义上下文寄存器 7

  // Debug mode CSRs
  val dcsr      = RegInit(0.U.asTypeOf(new Dcsr))       // debug control/status
  val dpc       = RegInit(0.U(32.W))                    // debug 返回 PC
  val dscratch0 = RegInit(0.U(32.W))                    // debug scratch 0
  val dscratch1 = RegInit(0.U(32.W))                    // debug scratch 1
  // Trigger CSRs
  val tselect   = RegInit(0.U(32.W))                    // trigger 选择, 当前单 trigger
  val tdata1    = RegInit("x60000000".U.asTypeOf(new Tdata1)) // trigger 配置, 默认 type=6
  val tdata2    = RegInit(0.U(32.W))                    // trigger 匹配 PC
  /* For details, see The RISC-V Debug Specification v1.0, chapter 5.7.5 */
  val tinfo     = RegInit(0x01000040.U(32.W))           // 声明支持 mcontrol6

  // CSRs with initialization.
  val fflags    = RegInit(0.U(5.W))                     // 浮点 accrued exception flags
  val frm       = RegInit(0.U(3.W))                     // 浮点舍入模式
  val mstatus_mie  = RegInit(false.B)                   // machine interrupt enable
  val mstatus_mpie = RegInit(false.B)                   // trap 前的 mie 备份
  val mie       = RegInit(0.U(32.W))                    // machine interrupt enable bits
  val mtvec     = RegInit(0.U(32.W))                    // trap vector base
  val mscratch  = RegInit(0.U(32.W))                    // machine scratch
  val mepc      = RegInit(0.U(32.W))                    // exception PC
  val mhartid   = RegInit(p.hartId.U(32.W))             // hart id

  val mcycle    = RegInit(0.U(64.W))                    // cycle counter
  val minstret  = RegInit(0.U(64.W))                    // retired instruction counter

  // 32-bit MXLEN, I,M,X extensions
  val misa      = RegInit(((
      0x40001100 |
      (if (p.enableRvv) { 1 << 21 /* 'V' */ } else { 0 }) |
      (if (p.enableFloat) { 1 << 5 /* 'F' */ } else { 0 })
  ).U)(32.W))
  // CoralNPU-specific ISA register.
  val kisa      = RegInit(0.U(32.W))                    // CoralNPU 自定义 ISA 能力寄存器
  // SCM Revision (spread over 5 indices)
  val kscm      = RegInit(((new ScmInfo).revision).U(160.W)) // SCM revision 分布到 KSCM0..4

  // 0x426 - Google's Vendor ID
  val mvendorid = RegInit(0x426.U(32.W))                // Google vendor ID

  // Unimplemented -- explicitly return zero.
  val marchid   = RegInit(0.U(1.W))                     // 未实现, 读 0
  val mimpid    = RegInit(0.U(1.W))                     // 未实现, 读 0

  val fcsr = Cat(frm, fflags)                           // FCSR = frm[7:5] + fflags[4:0]

  // TODO(b/452672880): Implement the dirty feature for fs and vs.
  val fs = if (p.enableFloat) 1.U(2.W) else 0.U(2.W)    // 浮点状态: Initial/Off 简化编码
  val vs = if (p.enableRvv) 1.U(2.W) else 0.U(2.W)      // 向量状态: Initial/Off 简化编码

  // Decode the Index.
  val (csr_address, csr_address_valid) = CsrAddress.safe(req.bits.index) // 12-bit CSR index 解码
  assert(!(req.valid && !csr_address_valid))
  // 每个 CSR 地址生成一个 one-hot 风格使能, 后续读写共用。
  val fflagsEn    = csr_address === CsrAddress.FFLAGS   // 浮点异常标志
  val frmEn       = csr_address === CsrAddress.FRM
  val fcsrEn      = csr_address === CsrAddress.FCSR
  val vstartEn    = Option.when(p.enableRvv) { csr_address === CsrAddress.VSTART }
  val vlEn        = Option.when(p.enableRvv) { csr_address === CsrAddress.VL }
  val vtypeEn     = Option.when(p.enableRvv) { csr_address === CsrAddress.VTYPE }
  val vxrmEn      = Option.when(p.enableRvv) { csr_address === CsrAddress.VXRM }
  val vxsatEn     = Option.when(p.enableRvv) { csr_address === CsrAddress.VXSAT }
  val mstatusEn   = csr_address === CsrAddress.MSTATUS
  val misaEn      = csr_address === CsrAddress.MISA
  val mieEn       = csr_address === CsrAddress.MIE
  val mtvecEn     = csr_address === CsrAddress.MTVEC
  val mstatushEn  = csr_address === CsrAddress.MSTATUSH
  val mscratchEn  = csr_address === CsrAddress.MSCRATCH
  val mepcEn      = csr_address === CsrAddress.MEPC
  val mcauseEn    = csr_address === CsrAddress.MCAUSE
  val mtvalEn     = csr_address === CsrAddress.MTVAL
  val mipEn       = csr_address === CsrAddress.MIP
  // Debug CSRs.
  val tselectEn   = csr_address === CsrAddress.TSELECT
  val tdata1En    = csr_address === CsrAddress.TDATA1
  val tdata2En    = csr_address === CsrAddress.TDATA2
  val tinfoEn     = csr_address === CsrAddress.TINFO
  val dcsrEn      = csr_address === CsrAddress.DCSR
  val dpcEn       = csr_address === CsrAddress.DPC
  val dscratch0En = csr_address === CsrAddress.DSCRATCH0
  val dscratch1En = csr_address === CsrAddress.DSCRATCH1
  val mcontext0En = csr_address === CsrAddress.MCONTEXT0
  val mcontext1En = csr_address === CsrAddress.MCONTEXT1
  val mcontext2En = csr_address === CsrAddress.MCONTEXT2
  val mcontext3En = csr_address === CsrAddress.MCONTEXT3
  val mcontext4En = csr_address === CsrAddress.MCONTEXT4
  val mcontext5En = csr_address === CsrAddress.MCONTEXT5
  val mcontext6En = csr_address === CsrAddress.MCONTEXT6
  val mcontext7En = csr_address === CsrAddress.MCONTEXT7
  val mpcEn       = csr_address === CsrAddress.MPC
  val mspEn       = csr_address === CsrAddress.MSP
  // M-mode performance CSRs.
  val mcycleEn    = csr_address === CsrAddress.MCYCLE
  val minstretEn  = csr_address === CsrAddress.MINSTRET
  val mcyclehEn   = csr_address === CsrAddress.MCYCLEH
  val minstrethEn = csr_address === CsrAddress.MINSTRETH
  // Vector CSRs.
  val vlenbEn     = Option.when(p.enableRvv) { csr_address === CsrAddress.VLENB }
  // M-mode information CSRs.
  val mvendoridEn = csr_address === CsrAddress.MVENDORID
  val marchidEn   = csr_address === CsrAddress.MARCHID
  val mimpidEn    = csr_address === CsrAddress.MIMPID
  val mhartidEn   = csr_address === CsrAddress.MHARTID
  // Start of custom CSRs.
  val kisaEn      = csr_address === CsrAddress.KISA
  val kscm0En     = csr_address === CsrAddress.KSCM0
  val kscm1En     = csr_address === CsrAddress.KSCM1
  val kscm2En     = csr_address === CsrAddress.KSCM2
  val kscm3En     = csr_address === CsrAddress.KSCM3
  val kscm4En     = csr_address === CsrAddress.KSCM4

  // Pipeline Control.
  when (io.bru.in.halt) {
    halted := true.B                                    // BRU 请求暂停后保持 halted
  }

  when (io.bru.in.fault) {
    fault := true.B                                     // 不可恢复 fault sticky
  }

  val mtip_pending = io.timer_irq && mie(7)             // machine timer interrupt pending
  val meip_pending = io.irq && mie(11)                  // machine external interrupt pending
  val msip_pending = io.software_irq && mie(3)          // machine software interrupt pending
  // WFI 在任意已使能中断或 debug_req 到来时退出; 否则由 BRU 的 WFI 指令置位。
  wfi := Mux(wfi, !(mtip_pending || meip_pending || msip_pending || io.dm.debug_req), io.bru.in.wfi)

  io.halted := halted                                   // 输出核心暂停状态
  io.fault  := fault                                    // 输出 fault 状态
  io.wfi    := wfi                                      // 输出 WFI 状态

  assert(!(io.fault && !io.halted && !io.wfi))

  // Register state.
  val rs1 = io.rs1.data                                 // CSR 写入源操作数

  // ---- CSR 读数据选择 ----
  // MuxUpTo1H 默认返回 0, 只有命中的 CSR 使能会选择对应寄存器值。
  val rdata = MuxUpTo1H(0.U(32.W), Seq(
      fflagsEn    -> Cat(0.U(27.W), fflags),
      frmEn       -> Cat(0.U(29.W), frm),
      fcsrEn      -> Cat(0.U(24.W), fcsr),
      mstatusEn   -> Cat(0.U(17.W), fs, 3.U(2.W), vs, 0.U(1.W), mstatus_mpie, 0.U(3.W), mstatus_mie, 0.U(3.W)),
      misaEn      -> misa,
      mieEn       -> mie,
      mipEn       -> Cat(0.U(20.W), io.irq, 0.U(3.W), io.timer_irq, 0.U(3.W), io.software_irq, 0.U(3.W)),
      mtvecEn     -> mtvec,
      mstatushEn  -> 0.U(32.W),
      mscratchEn  -> mscratch,
      mepcEn      -> mepc,
      mcauseEn    -> mcause,
      mtvalEn     -> mtval,
      mcontext0En -> mcontext0,
      mcontext1En -> mcontext1,
      mcontext2En -> mcontext2,
      mcontext3En -> mcontext3,
      mcontext4En -> mcontext4,
      mcontext5En -> mcontext5,
      mcontext6En -> mcontext6,
      mcontext7En -> mcontext7,
      mpcEn       -> mpc,
      mspEn       -> msp,
      mcycleEn    -> mcycle(31,0),
      mcyclehEn   -> mcycle(63,32),
      minstretEn  -> minstret(31,0),
      minstrethEn -> minstret(63,32),
      mvendoridEn -> mvendorid,
      marchidEn   -> Cat(0.U(31.W), marchid),
      mimpidEn    -> Cat(0.U(31.W), mimpid),
      mhartidEn   -> mhartid,
      kisaEn      -> kisa,
      kscm0En     -> kscm(31,0),
      kscm1En     -> kscm(63,32),
      kscm2En     -> kscm(95,64),
      kscm3En     -> kscm(127,96),
      kscm4En     -> kscm(159,128),
    ) ++
      Option.when(p.enableRvv) {
        Seq(
          vstartEn.get -> io.rvv.get.vstart,
          vlEn.get     -> io.rvv.get.vl,
          vtypeEn.get  -> io.rvv.get.vtype,
          vxrmEn.get   -> io.rvv.get.vxrm,
          vxsatEn.get  -> io.rvv.get.vxsat,
          vlenbEn.get -> 16.U(32.W),  // Vector length in Bytes
        )
      }.getOrElse(Seq())
      ++
      Seq(
        tselectEn   -> tselect,
        tdata1En    -> tdata1.asWord,
        tdata2En    -> tdata2,
        tinfoEn     -> tinfo,
        dcsrEn      -> dcsr.asWord,
        dpcEn       -> dpc,
        dscratch0En -> dscratch0,
        dscratch1En -> dscratch1,
      )
  )

  // CSR 指令写数据:
  //   CSRRW: 写 rs1
  //   CSRRS: 置位 rdata | rs1
  //   CSRRC: 清位 rdata & ~rs1
  val wdata = MuxLookup(req.bits.op, 0.U)(Seq(
      CsrOp.CSRRW -> rs1,
      CsrOp.CSRRS -> (rdata | rs1),
      CsrOp.CSRRC -> (rdata & ~rs1)
  ))

  // ---- CSR 软件写入 ----
  when (req.valid) {
    when (fflagsEn)     { fflags    := wdata }          // 写 fflags
    when (frmEn)        { frm       := wdata }          // 写 frm
    when (fcsrEn)       { fflags    := wdata(4,0)
                          frm       := wdata(7,5) }     // 写 fcsr 同时拆分 fflags/frm
    when (mstatusEn)    { mstatus_mie := wdata(3); mstatus_mpie := wdata(7) } // 只实现 MIE/MPIE
    when (mieEn)        { mie       := wdata & "h888".U } // 只允许 MSIE/MTIE/MEIE
    when (mtvecEn)      { mtvec     := wdata }          // 写 trap vector
    //Writes to mstatush are ignored (hardwired zero)
    when (mscratchEn)   { mscratch  := wdata }
    when (mepcEn)       { mepc      := wdata }
    when (mcauseEn)     { mcause    := wdata }
    when (mtvalEn)      { mtval     := wdata }
    when (mpcEn)        { mpc       := wdata }
    when (mspEn)        { msp       := wdata }
    when (mcontext0En)  { mcontext0 := wdata }
    when (mcontext1En)  { mcontext1 := wdata }
    when (mcontext2En)  { mcontext2 := wdata }
    when (mcontext3En)  { mcontext3 := wdata }
    when (mcontext4En)  { mcontext4 := wdata }
    when (mcontext5En)  { mcontext5 := wdata }
    when (mcontext6En)  { mcontext6 := wdata }
    when (mcontext7En)  { mcontext7 := wdata }
    when (dscratch0En)  { dscratch0 := wdata }
    when (dscratch1En)  { dscratch1 := wdata }
    when (tdata1En)     { tdata1 := LegalizeTdata1(wdata) }
    when (tdata2En)     { tdata2 := wdata }
  }

  if (p.enableRvv) {
    // RVV CSR 的状态寄存在 RvvCore 内, CSR 模块只把写脉冲和数据转发过去。
    io.rvv.get.vstart_write.valid := req.valid && vstartEn.get
    io.rvv.get.vstart_write.bits  := wdata(log2Ceil(p.rvvVlen)-1, 0)
    io.rvv.get.vxrm_write.valid   := req.valid && vxrmEn.get
    io.rvv.get.vxrm_write.bits    := wdata(1,0)
    io.rvv.get.vxsat_write.valid  := req.valid && vxsatEn.get
    io.rvv.get.vxsat_write.bits   := wdata(0)
    io.rvv.get.frm                := frm                // RVV 也需要当前 frm
  }

  // CSRRS/CSRRC 且 rs1=x0 时只读不写; 其它情况视为 CSR 写。
  val is_csr_write = req.valid && !(req.bits.op.isOneOf(CsrOp.CSRRS, CsrOp.CSRRC) && req.bits.rs1 === 0.U)

  // mcycle implementation
  // If one of the enable signals for
  // the register are true, overwrite the enabled half
  // of the register.
  // Increment the value of mcycle by 1.
  val mcycle_th = Mux(mcyclehEn, wdata, mcycle(63,32))  // 写 MCYCLEH 时替换高 32 位
  val mcycle_tl = Mux(mcycleEn, wdata, mcycle(31,0))    // 写 MCYCLE 时替换低 32 位
  val mcycle_t = Cat(mcycle_th, mcycle_tl)              // 合成写后的 64-bit mcycle
  val mcycle_written = is_csr_write && (mcycleEn || mcyclehEn)
  mcycle := Mux(mcycle_written, mcycle_t, mcycle + 1.U) // 未写时每周期 +1


  val minstret_th = Mux(minstrethEn, wdata, minstret(63,32)) // 写 MINSTRETH 高半
  val minstret_tl = Mux(minstretEn, wdata, minstret(31,0))   // 写 MINSTRET 低半
  val minstret_t = Cat(minstret_th, minstret_tl)
  val minstret_written = is_csr_write && (minstretEn || minstrethEn)
  val minstretThisCycle = io.counters.nRetired          // 本周期实际退役条数
  minstret := Mux(minstret_written, minstret_t, minstret + minstretThisCycle)

  // ---- Debug trigger / debug mode 状态机 ----
  val trigger_enabled = tdata1.isTrigger6 && tdata1.m   // 只支持 M-mode mcontrol6 execute trigger
  val trigger_match = trigger_enabled && io.dm.current_pc === tdata2 // 当前 PC 命中 trigger

  val entering_debug_mode = (mode =/= CsrMode.Debug) && (io.dm.debug_req || trigger_match)
  val exiting_debug_mode = (mode === CsrMode.Debug) && (io.dm.resume_req)
  mode := MuxCase(mode, Seq(
    entering_debug_mode -> CsrMode.Debug,               // haltreq/trigger 进入 debug
    exiting_debug_mode -> CsrMode.Machine,              // resume 退出 debug
    io.bru.in.mode.valid -> io.bru.in.mode.bits,        // MRET 等 BRU 请求更新模式
  ))
  io.dm.debug_mode := (mode === CsrMode.Debug) || entering_debug_mode
  val newCause = MuxCase(DebugCause.other, Seq(
        (io.dm.debug_req && !io.dm.dcsr_step) -> DebugCause.haltreq,
        trigger_match -> DebugCause.trigger,
        io.dm.dcsr_step -> DebugCause.step,
      ))
  dcsr := MuxCase(dcsr, Seq(
    entering_debug_mode -> {
      val newDcsr = Wire(new Dcsr)
      newDcsr := dcsr
      newDcsr.extcause := false.B                       // 不使用扩展 cause
      newDcsr.cause := newCause                         // 记录进入 debug 原因
      newDcsr.prv := 3.U(2.W)                           // 记录进入前特权级, 当前按 M-mode
      newDcsr
    },
    (req.valid && dcsrEn) -> wdata.asTypeOf(new Dcsr),  // 软件写 DCSR
  ))
  val dpc_value = Mux(newCause === DebugCause.step, io.dm.next_pc, io.dm.current_pc) // 单步用 next_pc
  dpc := MuxCase(dpc, Seq(
    (req.valid && dpcEn) -> wdata,                      // debug 模式软件写 DPC
    entering_debug_mode -> dpc_value,                   // 进入 debug 时保存返回 PC
  ))
  io.dm.debug_pc := MuxCase(MakeInvalid(UInt(p.fetchAddrBits.W)), Seq(
    (req.valid && dpcEn && mode === CsrMode.Debug) -> MakeValid(wdata), // 写 DPC 后重定向 Fetch
  ))

  io.dm.dcsr_step := dcsr.step                          // DCSR.step 控制单步执行
  io.dm.single_step := trigger_enabled                  // trigger 使 Dispatch 进入单步/互锁模式

  // High bit of mcause is set for an external interrupt.
  val interrupt = mcause(31)                            // mcause[31]=1 表示中断

  when (io.bru.in.mcause.valid) {
    mcause := io.bru.in.mcause.bits                     // BRU/FaultManager 写 trap cause
  }

  when (io.bru.in.mtval.valid) {
    mtval := io.bru.in.mtval.bits                       // 写 trap value
  }

  when (io.bru.in.mepc.valid) {
    mepc := io.bru.in.mepc.bits                         // 写 trap PC
  }

  if (p.enableFloat) {
    when (io.float.get.in.fflags.valid) {
      fflags := io.float.get.in.fflags.bits | fflags    // 浮点异常 flags sticky OR
    }
  }

  // ---- Interrupt generation ----
  val in_debug = mode === CsrMode.Debug                 // debug 模式屏蔽普通中断
  val interrupt_pending = (mtip_pending || meip_pending || msip_pending) && mstatus_mie && !in_debug

  io.bru.out.interrupt := interrupt_pending
  io.bru.out.interrupt_cause := MuxCase(0.U, Seq(
    meip_pending -> "x8000000B".U(32.W),                // machine external interrupt
    msip_pending -> "x80000003".U(32.W),                // machine software interrupt
    mtip_pending -> "x80000007".U(32.W),                // machine timer interrupt
  ))

  // Trap entry: save mstatus on trap (ecall, ebreak-trap, fault, or interrupt)
  val trap_taken = io.bru.in.mcause.valid               // BRU 写 mcause 表示 trap 已提交
  when (trap_taken) {
    mstatus_mpie := mstatus_mie                         // 保存 trap 前 MIE
    mstatus_mie  := false.B                             // trap 后关闭中断
  }

  // MRET: restore mstatus
  when (io.bru.in.mode.valid) {
    mstatus_mie  := mstatus_mpie                        // MRET 恢复 MIE
    mstatus_mpie := true.B                              // MPIE 置 1
  }

  // ---- Forwarding ----
  io.bru.out.mode  := mode                              // 当前模式转发给 BRU
  io.bru.out.mepc  := Mux(mepcEn && req.valid, wdata, mepc)   // CSR 写 mepc 当拍旁路给 MRET
  io.bru.out.mtvec := Mux(mtvecEn && req.valid, wdata, mtvec) // CSR 写 mtvec 当拍旁路给 trap

  if (p.enableFloat) {
    io.float.get.out.frm := Mux(frmEn && req.valid, wdata(2,0), frm) // frm 当拍旁路给 FPU
  }

  // 外部 CSR 观测/初始化接口输出。
  io.csr.out.value(0) := io.csr.in.value(12)            // reset PC 透传/保留
  io.csr.out.value(1) := mepc
  io.csr.out.value(2) := mtval
  io.csr.out.value(3) := mcause
  io.csr.out.value(4) := mcycle(31,0)
  io.csr.out.value(5) := mcycle(63,32)
  io.csr.out.value(6) := minstret(31,0)
  io.csr.out.value(7) := minstret(63,32)
  io.csr.out.value(8) := mcontext0

  // Write port.
  io.rd.valid := req.valid                              // CSR 指令写回旧 CSR 值
  io.rd.bits.addr  := req.bits.addr                     // 写回 rd
  io.rd.bits.data  := rdata                             // 写回读出的 CSR 旧值

  io.trace.valid := req.valid && !(req.bits.op.isOneOf(CsrOp.CSRRS, CsrOp.CSRRC) && req.bits.rs1 === 0.U) // 只追踪真实写
  io.trace.addr := req.bits.index                         // CSR 地址
  io.trace.data := wdata                                  // CSR 写数据

  // Assertions.
  assert(!(req.valid && !io.rs1.valid))                 // 有 CSR 请求时 rs1 必须有效
}
