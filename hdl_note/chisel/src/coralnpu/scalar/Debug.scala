// Copyright 2025 Google LLC
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
// Debug.scala — RISC-V 调试模块 (Debug Module, Spec 0.13.2)
//
// 实现 RISC-V 外部调试标准, 支持:
//   - halt/resume: 暂停/恢复核心运行
//   - Abstract Command: 通过 abstractcs/command 寄存器访问核内寄存器/CSR/内存
//   - System Bus Access (SBA): 通过 sbcs 直接读写 ITCM/DTCM 内存 (FabricIO)
//   - dmcontrol/dmstatus/hartinfo: 标准调试寄存器
//
// 工作流程:
//   外部调试器 → AXI Slave → CoreAxi DM Arbiter → DebugModule → Core/SCore/TCM
//   请求: DebugModuleReqIO → 解析地址/命令 → halt/CSR访问/寄存器读写/内存访问
//   响应: DebugModuleRspIO ← 根据命令完成状态返回 SUCCESS/FAILED/BUSY
// DebugModule 的核心逻辑：
// 1. 外部通过 ext.req 访问 DebugModule 寄存器。
// 2. 写 dmcontrol 控制 halt/resume/reset。
// 3. 写 command 触发 abstract command。
// 4. cmdtype=0 访问 CSR/标量寄存器/浮点寄存器。
// 5. cmdtype=2 访问 ITCM/DTCM。
// 6. data0 保存写入参数或读回结果。
// 7. data1 保存内存访问地址。
// 8. abstractcs.busy 表示命令未完成。
// 9. abstractcs.cmderr 表示错误。
// 10. ext.rsp 返回 SUCCESS/FAILED/BUSY 和读数据。
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._

// ---- 调试协议枚举和常量 (RISC-V Debug Spec 0.13.2) ----

/** DmReqOp — 调试模块请求操作: NOP(空操作)/READ(读寄存器)/WRITE(写寄存器) */
object DmReqOp extends ChiselEnum {
    val NOP   = Value(0.U(2.W))
    val READ  = Value(1.U(2.W))
    val WRITE = Value(2.U(2.W))
}

/** DmRspOp — 调试模块响应操作: SUCCESS(成功)/FAILED(失败)/BUSY(忙,需重试) */
object DmRspOp extends ChiselEnum {
    val SUCCESS = Value(0.U(2.W))
    val FAILED  = Value(2.U(2.W))
    val BUSY    = Value(3.U(2.W))
}

/** DebugModuleAddress — RISC-V Debug Spec 定义的调试寄存器地址 */
/** DebugModuleAddress — 调试寄存器地址 (RISC-V Debug Spec 0.13.2 定义) */
object DebugModuleAddress {
  def Data0       = 0x4.U(32.W)    // 数据寄存器 0 (arg0/result)
  def Data1       = 0x5.U(32.W)    // 数据寄存器 1 (arg1)
  def Dmcontrol   = 0x10.U(32.W)   // 调试模块控制 (haltreq/resumereq/hartsel等)
  def Dmstatus    = 0x11.U(32.W)   // 调试模块状态 (allhalted/anyrunning等)
  def Hartinfo    = 0x12.U(32.W)   // HART 信息 (nscratch/datasize/dataaddr)
  def Abstractcs  = 0x16.U(32.W)   // 抽象命令控制状态 (cmderr/busy/datacount)
  def Command     = 0x17.U(32.W)   // 抽象命令 (cmdtype/access register/memory)
  def Sbcs        = 0x38.U(32.W)   // 系统总线访问控制 (SBA)
}

/** AccessRegisterCommand — 抽象命令类型: 访问寄存器 (cmdtype=0) */
object AccessRegisterCommand {
  def Cmdtype   = 0.U(8.W)
}
/** AccessMemoryCommand — 抽象命令类型: 访问内存 (cmdtype=2) */
object AccessMemoryCommand {
    def Cmdtype = 2.U(8.W)
}

// ---- 调试请求/响应/IO Bundle ----

/** DebugModuleReqIO — 调试模块请求 (地址+数据+操作码) */
class DebugModuleReqIO(p: Parameters) extends Bundle {
    val address = UInt(32.W)                                     // 调试寄存器地址
    val data    = UInt(32.W)                                     // 写入数据
    val op      = DmReqOp()                                      // READ/WRITE/NOP

    def isRead:  Bool = (op === DmReqOp.READ)                   // 是否为读请求
    def isWrite: Bool = (op === DmReqOp.WRITE)                  // 是否为写请求
    def isOp:    Bool = op.isOneOf(DmReqOp.READ, DmReqOp.WRITE)// 是否为有效操作
    // 标准调试寄存器地址判断
    def isAddrData0:       Bool = (address === DebugModuleAddress.Data0)
    def isAddrData1:       Bool = (address === DebugModuleAddress.Data1)
    def isAddrDmcontrol:   Bool = (address === DebugModuleAddress.Dmcontrol)
    def isAddrDmstatus:    Bool = (address === DebugModuleAddress.Dmstatus)
    def isAddrHartinfo:    Bool = (address === DebugModuleAddress.Hartinfo)
    def isAddrAbstractcs:  Bool = (address === DebugModuleAddress.Abstractcs)
    def isAddrCommand:     Bool = (address === DebugModuleAddress.Command)
    def isAddrSbcs:        Bool = (address === DebugModuleAddress.Sbcs)

    // ---- Abstract Command 字段解析 (RISC-V Debug Spec 3.6) ----
    def cmdtype: UInt = data(31,24)                              // 命令类型 (0=寄存器, 2=内存)
    def write: Bool   = data(16)                                  // 写标志 (1=写, 0=读)

    // ---- Access Register 命令字段 (cmdtype=0) ----
    def aarsize: UInt = data(22,20)                              // 访问宽度 (2=32-bit)
    def regno: UInt   = data(15,0)                               // 寄存器编号

    // ---- Access Memory 命令字段 (cmdtype=2) ----
    def aamvirtual: UInt       = data(23)                        // 虚拟地址标志
    def aamsize: UInt          = data(22,20)                     // 访问宽度
    def aampostincrement: UInt = data(19)                        // 访问后地址自增
}

/** DebugModuleRspIO — 调试模块响应 (数据+状态) */
class DebugModuleRspIO(p: Parameters) extends Bundle {
    val data = UInt(32.W)                                        // 读回数据
    val op   = DmRspOp()                                         // SUCCESS/FAILED/BUSY
}

/** DebugModuleIO — 调试模块外部接口 (请求/响应, Decoupled 握手) */
class DebugModuleIO(p: Parameters) extends Bundle {
    val req = Flipped(Decoupled(new DebugModuleReqIO(p)))        // 调试请求输入
    val rsp = Decoupled(new DebugModuleRspIO(p))                 // 调试响应输出
}

/** DebugModule — RISC-V Debug Spec 0.13.2 调试模块实现 (单 HART)
 *
 *  IO 说明:
 *   ext        — 外部调试请求/响应 (来自 CoreAxi 的 dmReqArbiter)
 *   csr        — 向核内 CSR 单元发出访问命令
 *   scalar_rd/rs — 标量寄存器读写 (连接到 Regfile)
 *   float_rd/rs  — 浮点寄存器读写 (条件: enableFloat)
 *   itcm/dtcm   — 通过 FabricIO 直接读写 ITCM/DTCM 内存
 *   haltreq/resumereq — 暂停/恢复请求 (→ Core)
 *   halted/running    — 核心状态 (← Core) */
class DebugModule(p: Parameters) extends Module {
    val nHart = 1                                                // HART 数量 (当前仅支持单核)
    val io = IO(new Bundle {
        val ext       = new DebugModuleIO(p)                     // 外部调试接口
        val csr       = Output(Valid(new CsrCmd))                // CSR 访问命令
        val csr_rs1   = Output(UInt(32.W))                       // CSR 写数据 (rs1 值)
        val csr_rd    = Input(Valid(UInt(32.W)))                // CSR 读回数据
        val scalar_rd = Decoupled(new RegfileWriteDataIO)        // 标量寄存器写 (DM→Regfile)
        val scalar_rs = new Bundle {                              // 标量寄存器读
            val idx  = Output(UInt(5.W))                          // 寄存器编号
            val data = Input(UInt(32.W))                          // 读回值
        }
        val float_rd = Option.when(p.enableFloat)(Flipped(new FRegfileWrite))  // 浮点寄存器写
        val float_rs = Option.when(p.enableFloat)(Flipped(new FRegfileRead))   // 浮点寄存器读
        val itcm = new FabricIO(p)                               // ITCM 调试访问
        val dtcm = new FabricIO(p)                               // DTCM 调试访问

        val haltreq   = Output(Vec(nHart, Bool()))               // 暂停请求
        val resumereq = Output(Vec(nHart, Bool()))               // 恢复请求
        val resumeack = Input(Vec(nHart, Bool()))                // 恢复确认

        val ndmreset  = Output(Bool())                            // 非调试模块复位
        val halted    = Input(Vec(nHart, Bool()))                // 核心已暂停
        val running   = Input(Vec(nHart, Bool()))                // 核心运行中
        val havereset = Input(Vec(nHart, Bool()))                // 核心已复位
    })
    val req = Queue(io.ext.req, 1)                               // 缓冲1拍, 切断外部时序路径

    // ---- halt/resume 状态机 ----
    val haltreq   = RegInit(VecInit.fill(nHart)(false.B))       // 暂停请求 (置1→暂停核心)
    val resumereq = RegInit(VecInit.fill(nHart)(false.B))       // 恢复请求 (置1→恢复核心)
    val resumeack = RegInit(VecInit.fill(nHart)(false.B))       // 恢复确认 (跟踪 resume 握手)
    io.haltreq   := haltreq
    io.resumereq := resumereq

    // ---- 调试寄存器 ----
    val dmcontrol = RegInit(1.U(32.W))                           // dmcontrol 寄存器 (复位后 dmactive=1)
    val dmactive  = dmcontrol(0)                                  // bit0: 调试模块使能

    val data0  = RegInit(0.U(32.W))                              // 数据寄存器 0 (arg0/result)
    val data1  = RegInit(0.U(32.W))                              // 数据寄存器 1 (arg1)
    val cmderr = RegInit(0.U(32.W))                              // 抽象命令错误码

    // dmcontrol 写有效: 命中地址 + 写操作 + 握手成功
    val dmcontrol_wvalid = (req.fire && req.bits.isAddrDmcontrol && req.bits.isWrite)

    // haltreq: bit31(haltreq) 写1时暂停核心, 否则保持
    // resumereq: bit30(resumereq) 写1时恢复核心, resumeack后清零
    // resumeack: haltreq期间保持0, resumeack后保持1
    for (i <- 0 until nHart) {
        haltreq(i) := MuxCase(haltreq(i), Seq(
            dmcontrol_wvalid -> req.bits.data(31),               // bit31=haltreq
        ))
        val resumereq_i = MuxOR(dmcontrol_wvalid, req.bits.data(30))
        resumereq(i) := MuxCase(resumereq(i), Seq(
            dmcontrol_wvalid -> resumereq_i,                      // bit30=resumereq
            io.resumeack(i) -> false.B,                           // 收到ack后清零
        ))
        resumeack(i) := MuxCase(resumeack(i), Seq(
            haltreq(i) -> false.B,                                // haltreq 期间不跟踪
            io.resumeack(i) -> true.B,                            // 收到ack
        ))
    }

    /** LegalizeDmcontrol — 写 dmcontrol 时做字段级更新, 保留未写字段的当前值 */
    def LegalizeDmcontrol(in: UInt): UInt = {
        assert(in.getWidth == 32)
        val new_dmcontrol = Wire(UInt(32.W))
        val ndmreset = req.bits.data(1)                           // bit1: 非调试复位
        val dmactive  = req.bits.data(0)                          // bit0: 调试使能
        val hartsel   = Min(req.bits.data(25,6), 1.U(20.W))     // bit25:6: HART选择 (限制≤nHart)
        new_dmcontrol := Cat(dmcontrol(31,26), hartsel, dmcontrol(5,2), ndmreset, dmactive)
        new_dmcontrol
    }
    dmcontrol := MuxCase(dmcontrol, Seq(
        dmcontrol_wvalid -> LegalizeDmcontrol(req.bits.data)
    ))
    io.ndmreset := dmcontrol(1)                                   // 非调试复位→Core

    // dmstatus: 只读状态寄存器, 反映当前 HART 运行/暂停状态
    val dmstatus = Wire(UInt(32.W))
    dmstatus := Cat(
        0.U(14.W),                                                // reserved
        resumeack.reduce(_&_).asUInt,                             // allresumeack
        resumeack.reduce(_&_).asUInt,                             // anyresumeack
        0.U(4.W),                                                 // nonexistent/unavail (全部为0)
        io.running.reduce(_&_).asUInt,                            // allrunning
        io.running.reduce(_|_).asUInt,                            // anyrunning
        io.halted.reduce(_&_).asUInt,                             // allhalted
        io.halted.reduce(_|_).asUInt,                             // anyhalted
        1.U(1.W),                                                 // authenticated
        0.U(3.W),                                                 // reserved
        3.U(4.W)                                                  // version (0.13)
    )

    // hartinfo: HART 信息寄存器
    val hartinfo = Wire(UInt(32.W))
    hartinfo := Cat(
        0.U(8.W),                                                 // reserved
        2.U(4.W),     /* nscratch */                              // 2个 scratch 寄存器
        0.U(3.W),                                                 // reserved
        0.U(1.W),     /* dataaccess */                            // 不支持抽象数据访问
        0.U(4.W),     /* datasize */                              // 数据大小
        "x7B4".U(12.W)/* dataaddr */                              // data 寄存器地址基址
    )

    // ---- Abstract Command 解析 ----
    val abstractCmdValid = req.valid && req.bits.isWrite && req.bits.isAddrCommand
    // 命令类型: 0=访问寄存器, 2=访问内存
    val cmdtypeIsAccessRegister = (req.bits.cmdtype === AccessRegisterCommand.Cmdtype)
    val cmdtypeIsAccessMemory   = (req.bits.cmdtype === AccessMemoryCommand.Cmdtype)
    // 寄存器编号范围: 0x0000~0x0FFF=CSR, 0x1000~0x101F=标量, 0x1020~0x103F=浮点
    val regnoIsCsr     = (req.bits.regno >= 0.U(16.W)) && (req.bits.regno < "x1000".U(16.W))
    val regnoIsScalar  = (req.bits.regno >= "x1000".U(16.W)) && (req.bits.regno < "x1020".U(16.W))
    val regnoIsFloat   = (req.bits.regno >= "x1020".U(16.W) && (req.bits.regno < "x1040".U(16.W)))
    val regnoInvalid   = !regnoIsCsr && !regnoIsScalar && !regnoIsFloat   // 非法寄存器号
    val sizeInvalid    = (req.bits.aarsize =/= 2.U(3.W))                  // 仅支持 32-bit 访问

    // ---- 内存地址路由: 根据 data1 确定目标区域 ----
    // 遍历所有 MemoryRegion, 判断 data1 落在 ITCM/DTCM/Peripheral/External 哪个区域
    val itcm = p.m.filter(_.memType == MemoryRegionType.IMEM)
                  .map(_.contains(data1)).reduceOption(_ || _).getOrElse(false.B)
    val dtcm = p.m.filter(_.memType == MemoryRegionType.DMEM)
                  .map(_.contains(data1)).reduceOption(_ || _).getOrElse(false.B)
    val peri = p.m.filter(_.memType == MemoryRegionType.Peripheral)
                  .map(_.contains(data1)).reduceOption(_ || _).getOrElse(false.B)
    val ext  = !(itcm || dtcm || peri)                            // 不在任何已知区域→外部 (暂不支持)

    // ---- Abstract Command 完成条件 ----
    // 浮点访问完成 (条件: enableFloat)
    val abstractCmdCompleteFloat = (if (p.enableFloat) {
        Seq(
            (cmdtypeIsAccessRegister && regnoIsFloat && req.bits.write &&
             io.float_rd.map(_.valid).getOrElse(true.B)) -> true.B,
            (cmdtypeIsAccessRegister && regnoIsFloat && !req.bits.write) -> true.B,
        )
    } else { Seq() })

    // 命令完成 = (有效命令 且 满足完成条件) 或 核心未暂停
    val abstractCmdComplete = (abstractCmdValid && MuxCase(false.B, Seq(
        (cmdtypeIsAccessRegister && regnoInvalid) -> true.B,      // 非法寄存器→立即完成(报错)
        (cmdtypeIsAccessRegister && regnoIsCsr && io.csr_rd.valid) -> true.B,  // CSR读回
        (cmdtypeIsAccessRegister && regnoIsScalar && req.bits.write && io.scalar_rd.fire) -> true.B,
        (cmdtypeIsAccessRegister && regnoIsScalar && !req.bits.write) -> true.B,
        (cmdtypeIsAccessMemory && (io.itcm.readData.valid)) -> true.B,          // ITCM读回
        (cmdtypeIsAccessMemory && (io.dtcm.readData.valid)) -> true.B,          // DTCM读回
        (cmdtypeIsAccessMemory && req.bits.write) -> true.B,                    // 内存写完成
        (cmdtypeIsAccessMemory && !(itcm || dtcm)) -> true.B,                   // 外部地址→完成(报错)
    ) ++ abstractCmdCompleteFloat)) || !io.halted(0)              // 未暂停→不允许抽象命令

    // ---- CSR 访问 (通过 csr 通道发送到核内 CSR 单元) ----
    io.csr.valid       := io.halted(0) && abstractCmdValid && cmdtypeIsAccessRegister && regnoIsCsr
    io.csr.bits.addr  := 0.U(5.W)                                 // 内部 CSR 地址
    io.csr.bits.index := req.bits.regno                            // RISC-V CSR 编号 (12-bit)
    io.csr.bits.op    := Mux(req.bits.write, CsrOp.CSRRW, CsrOp.CSRRC) // 写=CSRRW, 读=CSRRC
    io.csr.bits.rs1   := 0.U
    io.csr_rs1 := MuxOR(req.bits.write, data0)                    // 写操作时 data0 作为 rs1 值

    // ---- abstractcs 寄存器 ----
    val abstractcs_wvalid = (req.fire && req.bits.isAddrAbstractcs && req.bits.isWrite)
    // cmderr 更新:
    //   abstractcs写: W1C (Write-1-to-Clear) 清除对应位
    //   命令有效但未halted: error=4 (halt/resume)
    //   不支持的大小: error=2 (not supported)
    //   外部地址: error=5 (bus error)
    //   dmactive=0: 清零
    cmderr := MuxCase(cmderr, Seq(
        abstractcs_wvalid -> (cmderr & ~(req.bits.data(10,8))),   // cmderr bit[10:8] W1C
        (abstractCmdValid && !io.halted(0)) -> 4.U(3.W),           // error=4: halt/resume
        (abstractCmdValid && req.bits.isAddrCommand &&
         cmdtypeIsAccessRegister && req.bits.isOp && sizeInvalid) -> 2.U(3.W),
        (abstractCmdValid && req.bits.isAddrCommand &&
         cmdtypeIsAccessMemory && !(itcm || dtcm)) -> 5.U(3.W),    // error=5: bus error
        !dmactive -> 0.U(3.W),                                     // 调试未激活→清零
    ))
    val busy = abstractCmdValid && !abstractCmdComplete            // 命令执行中
    val abstractcs = Wire(UInt(32.W))
    abstractcs := Cat(
        0.U(3.W),                                                  // reserved
        0.U(5.W),                                                  // progbufsize (0: 无程序缓冲)
        0.U(11.W),                                                 // reserved
        busy,                                                      // busy (1=命令执行中)
        0.U(1.W),                                                  // relaxedpriv
        cmderr,                                                    // cmderr (3-bit 错误码)
        0.U(4.W),                                                  // reserved
        1.U(4.W)                                                   // datacount (1: 每命令最多1个数据)
    )

    // ---- 标量寄存器访问 ----
    val scalarRegno = req.bits.regno(4,0)                        // 标量寄存器号 (0~31)
    io.scalar_rd.valid := io.halted(0) && abstractCmdValid &&
        (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsScalar && req.bits.write
    io.scalar_rd.bits.addr := scalarRegno                         // 目标寄存器号
    io.scalar_rd.bits.data := data0                               // 写入值 = data0
    io.scalar_rs.idx := MuxOR(                                    // 读: 请求读指定寄存器
        io.halted(0) && abstractCmdValid &&
        (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsScalar && !req.bits.write,
        scalarRegno)

    // ---- 浮点寄存器访问 (条件: enableFloat) ----
    if (p.enableFloat) {
        val floatRegno = req.bits.regno(4,0)                     // 浮点寄存器号 (0~31)
        io.float_rd.get.valid := io.halted(0) && abstractCmdValid &&
            (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsFloat && req.bits.write
        io.float_rd.get.addr := floatRegno
        io.float_rd.get.data := Fp32.fromWord(data0)              // UInt→Fp32 转换
        io.float_rs.get.valid := io.halted(0) && abstractCmdValid &&
            (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsFloat && !req.bits.write
        io.float_rs.get.addr := floatRegno
    }

    // ---- data0 读取: ITCM 128-bit 中按字偏移选择 32-bit ----
    val data0ItcmReadData =
            MuxCase(0.U(32.W), Seq(
                (data1(3,2) === 0.U) -> io.itcm.readData.bits(31, 0),     // 字0
                (data1(3,2) === 1.U) -> io.itcm.readData.bits(63, 32),    // 字1
                (data1(3,2) === 2.U) -> io.itcm.readData.bits(95, 64),    // 字2
                (data1(3,2) === 3.U) -> io.itcm.readData.bits(127, 96),   // 字3
            ))
    val data0DtcmReadData =
            MuxCase(0.U(32.W), Seq(
                (data1(3,2) === 0.U) -> io.dtcm.readData.bits(31, 0),
                (data1(3,2) === 1.U) -> io.dtcm.readData.bits(63, 32),
                (data1(3,2) === 2.U) -> io.dtcm.readData.bits(95, 64),
                (data1(3,2) === 3.U) -> io.dtcm.readData.bits(127, 96),
            ))
    // data0 更新:
    //   直接写 data0 → 抽象命令读回 (CSR/标量/浮点/内存) → dmactive=0时清零
    val data0Priv = RegNext(data0, 0.U(32.W))                   // 上一拍 data0 (调试用)
    data0 := MuxCase(data0, Seq(
        (req.valid && req.bits.isAddrData0 && req.bits.isWrite) -> req.bits.data,           // 直接写 data0
        (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(0) &&
         req.valid && !req.bits.write && regnoIsCsr && io.csr_rd.valid) -> io.csr_rd.bits,  // CSR 读回
        (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(0) &&
         req.valid && !req.bits.write && regnoIsScalar) -> io.scalar_rs.data,               // 标量寄存器读回
        (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(0) &&
         req.valid && !req.bits.write && regnoIsFloat) ->
            io.float_rs.map(_.data).getOrElse(Fp32.Zero(false.B)).asWord,                    // 浮点寄存器读回
        (abstractCmdComplete && cmdtypeIsAccessMemory && io.halted(0) &&
         req.valid && !req.bits.write && io.itcm.readData.valid) ->
            data0ItcmReadData.rotateRight(data1(1,0) * 8.U),                                 // ITCM 读回 (按字节偏移旋转)
        (abstractCmdComplete && cmdtypeIsAccessMemory && io.halted(0) &&
         req.valid && !req.bits.write && io.dtcm.readData.valid) ->
            data0DtcmReadData.rotateRight(data1(1,0) * 8.U),                                 // DTCM 读回
        !dmactive -> 0.U(32.W),                                                              // 调试未激活→清零
    ))

    // data1 更新: 直接写或内存访问后自动递增 (post-increment)
    data1 := MuxCase(data1, Seq(
        (req.valid && req.bits.isAddrData1 && req.bits.isWrite) -> req.bits.data,            // 直接写 data1
        (req.valid && (req.bits.aampostincrement === 1.U) && abstractCmdComplete &&
         cmdtypeIsAccessMemory && io.halted(0)) ->
            (data1 + (1.U << req.bits.aamsize)),                                              // 自动递增
    ))

    // ---- 构建响应: req.map 将请求转为响应 (保持请求-响应配对) ----
    val rsp = req.map(reqBits => {
        val rspBits = Wire(new DebugModuleRspIO(p))
        // 响应状态: 大多数寄存器访问=SUCCESS, 非法寄存器=FAILED, 默认=BUSY
        rspBits.op := MuxCase(DmRspOp.BUSY, Seq(
            (req.bits.isAddrData0 && req.bits.isOp)       -> DmRspOp.SUCCESS,
            (req.bits.isAddrData1 && req.bits.isOp)       -> DmRspOp.SUCCESS,
            (req.bits.isAddrDmcontrol && req.bits.isOp)   -> DmRspOp.SUCCESS,
            (req.bits.isAddrDmstatus && req.bits.isOp)    -> DmRspOp.SUCCESS,
            (req.bits.isAddrHartinfo && req.bits.isOp)    -> DmRspOp.SUCCESS,
            (req.bits.isAddrAbstractcs && req.bits.isOp)  -> DmRspOp.SUCCESS,
            (req.bits.isAddrSbcs && req.bits.isOp)         -> DmRspOp.SUCCESS,
            (req.bits.isAddrCommand && cmdtypeIsAccessRegister &&
             req.bits.isOp && regnoInvalid)                -> DmRspOp.FAILED,     // 非法寄存器号
            (req.bits.isAddrCommand && cmdtypeIsAccessRegister &&
             req.bits.isOp)                                -> DmRspOp.SUCCESS,    // 合法寄存器访问
            // 内存访问: 总返回 SUCCESS (实际错误通过 cmderr 报告)
            (req.bits.isAddrCommand && cmdtypeIsAccessMemory) -> DmRspOp.SUCCESS,
        ))
        // 响应数据: 根据读地址返回对应寄存器值
        rspBits.data := MuxCase(0.U(32.W), Seq(
            (req.bits.isAddrData0 && req.bits.isRead)      -> data0,
            (req.bits.isAddrData1 && req.bits.isRead)      -> data1,
            (req.bits.isAddrDmcontrol && req.bits.isRead)  -> dmcontrol,
            (req.bits.isAddrDmstatus && req.bits.isRead)   -> dmstatus,
            (req.bits.isAddrHartinfo && req.bits.isRead)   -> hartinfo,
            (req.bits.isAddrAbstractcs && req.bits.isRead) -> abstractcs,
            (req.bits.isAddrSbcs && req.bits.isRead)       -> 0.U(32.W),
            (req.bits.isAddrCommand && req.bits.isRead)    -> 0.U(32.W),
        ))
        rspBits
    })
    // 握手: 普通寄存器访问→立即响应; 抽象命令→等完成
    rsp.valid := req.valid && (!abstractCmdValid || abstractCmdComplete)
    req.ready := rsp.ready && (!abstractCmdValid || abstractCmdComplete)
    io.ext.rsp <> Queue(rsp, 1)                                  // 缓冲1拍后输出

    // ---- ITCM/DTCM 内存访问 (System Bus Access via FabricIO) ----
    // 读/写地址 = data1 (目标内存地址)
    io.itcm.readDataAddr.valid  := (abstractCmdValid && cmdtypeIsAccessMemory &&
                                     !req.bits.write && itcm)
    io.itcm.readDataAddr.bits   := data1
    io.itcm.writeDataAddr.valid := (abstractCmdValid && cmdtypeIsAccessMemory &&
                                     req.bits.write && itcm)
    io.itcm.writeDataAddr.bits  := data1

    io.dtcm.readDataAddr.valid  := (abstractCmdValid && cmdtypeIsAccessMemory &&
                                     !req.bits.write && dtcm)
    io.dtcm.readDataAddr.bits   := data1
    io.dtcm.writeDataAddr.valid := (abstractCmdValid && cmdtypeIsAccessMemory &&
                                     req.bits.write && dtcm)
    io.dtcm.writeDataAddr.bits  := data1

    // 写数据: data0 按字节偏移移位 + strobe 掩码控制访问宽度
    val byteOffsetBits = log2Ceil(p.axi2DataBits / 8)            // 字节偏移位宽
    val byteOffset     = data1(byteOffsetBits - 1, 0)            // 地址的低位字节偏移
    val strobe = MuxCase(~0.U((p.axi2DataBits / 8).W), Seq(      // 默认 32-bit 全写
      (req.bits.aamsize === 0.U) -> ("b0001".U << byteOffset),   // 1-byte
      (req.bits.aamsize === 1.U) -> ("b0011".U << byteOffset),   // 2-byte
      (req.bits.aamsize === 2.U) -> ("b1111".U << byteOffset),   // 4-byte
    ))
    val writeDataBits = data0.asTypeOf(UInt(p.axi2DataBits.W)) << (byteOffset * 8.U)
    io.dtcm.writeDataBits := writeDataBits
    io.dtcm.writeDataStrb := strobe
    io.itcm.writeDataBits := writeDataBits
    io.itcm.writeDataStrb := strobe
}
