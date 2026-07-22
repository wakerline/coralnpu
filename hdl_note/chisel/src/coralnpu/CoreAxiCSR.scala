// ============================================================================
// CoreAxiCSR.scala — CoreAxi 的 CSR 子系统
//
// CoreCsrAddrs — 调试寄存器地址常量定义
// CoreCSR — 片上 CSR 模块 (Fabric 接口), 实现:
//   - 复位/时钟门控控制 (resetReg bit0/bit1)
//   - PC 启动地址 (pcStartReg, 从 boot_addr 捕获)
//   - 内核状态 (statusReg: fault+halted)
//   - Debug Module 接口: 请求/响应队列 + 调试寄存器读写
//   - 通过 FabricIO 暴露内部 CSR 寄存器供外部 AXI Slave 访问
// CoreAxiCSR — CoreCSR 的 AXI 封装版 (AxiSlave → CoreCSR)
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

import bus.AxiMasterIO

/** CoreCsrAddrs — 调试寄存器地址定义 (Fabric 地址空间内) */
object CoreCsrAddrs {
  val DbgReqAddr = 0x800.U // 0x800: 调试请求地址寄存器 (32-bit)
  val DbgReqData = 0x804.U // 0x804: 调试请求数据寄存器 (32-bit)
  val DbgReqOp   = 0x808.U // 0x808: 调试请求操作码寄存器 (32-bit, 枚举值)
  val DbgRspData = 0x80c.U // 0x80c: 调试响应数据寄存器 (32-bit)
  val DbgRspOp   = 0x810.U // 0x810: 调试响应操作码寄存器 (32-bit, 枚举值)
  val DbgStatus  = 0x814.U // 0x814: 调试状态寄存器 (32-bit, bit0=RspValid, bit1=ReqReady)
}

/** CoreCSR — 片上 CSR 模块 (挂在 FabricMux port2)
 *
 *  IO:
 *   fabric     — Fabric 读写接口 (来自 FabricMux→AxiSlave)
 *   internal   — 1=内部核访问, 0=外部 AXI 访问 (仅外部可写 CSR, 防止核内篡改)
 *   reset/cg   — 复位/时钟门控 控制信号 → Core
 *   pcStart    — PC 启动地址 → Core
 *   bootAddr   — 从外部传入的启动地址
 *   halted/fault — 核状态 (来自 Core)
 *   coralnpu_csr — 核内 CSR 输出 (只读暴露给外部)
 *   debug      — Debug Module 请求/响应接口 */
class CoreCSR(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val fabric   = Flipped(new FabricIO(p))                    // Fabric 读写接口
    val internal = Input(Bool())                                // 1=内部, 0=外部 (仅外部可写)
    val reset    = Output(Bool())                               // 复位控制 (→ CoreAxi 复位逻辑)
    val cg       = Output(Bool())                               // 时钟门控控制
    val pcStart  = Output(UInt(p.fetchAddrBits.W))             // PC 启动地址 (→ Core csr.in)
    val bootAddr = Input(UInt(p.fetchAddrBits.W))              // 外部启动地址
    val halted   = Input(Bool())                                // 核已暂停
    val fault    = Input(Bool())                                // 核发生异常
    val coralnpu_csr = Input(new CsrOutIO(p))                  // 核内 CSR 只读值
    val debug    = Flipped(new DebugModuleIO(p))               // 调试模块接口
  })

  // ---- 核心控制寄存器 ----
  // resetReg: bit0=reset(高有效), bit1=clock gate(高有效)
  // 复位后默认值=3 (bit0=1, bit1=1) → 保持复位状态 + 时钟门控关断
  val resetReg = RegInit(3.U(p.fetchAddrBits.W))
  // pcStartReg: 复位后第一个时钟周期锁存 boot_addr
  val pcStartReg     = RegInit(0.U(p.fetchAddrBits.W))
  val bootAddrCapture = RegInit(true.B)                         // 首次捕获标志 (true=待捕获)
  // statusReg: bit0=halted, bit1=fault (只读)
  val statusReg = RegInit(0.U(p.fetchAddrBits.W))

  // ---- 调试寄存器 (Debug Module 通过 AXI 访问) ----
  val debugReqAddrReg = RegInit(0.U(32.W))                     // 调试请求地址
  val debugReqDataReg = RegInit(0.U(32.W))                     // 调试请求数据
  val debugReqOpReg   = RegInit(DmReqOp.NOP.asUInt)            // 调试请求操作码

  // 写使能: 仅外部 AXI 可写 (!io.internal 防核内篡改)
  val writeEn   = io.fabric.writeDataAddr.valid && !io.internal
  val writeAddr = io.fabric.writeDataAddr.bits                  // 写地址 (字节偏移)
  val writeData = io.fabric.writeDataBits                       // 写数据 (256-bit)

  // ---- 调试模块请求/响应处理 ----
  // 响应队列: Debug Module 的响应缓冲 1 拍
  val rsp_queue = Module(new Queue(new DebugModuleRspIO(p), 1))  // 深度 1 的队列
  rsp_queue.io.enq <> io.debug.rsp  // 调试模块响应入队

  // 请求脉冲: 写 DbgReqOp 寄存器时, 生成单周期 valid 脉冲
  val req_valid_pulse = RegInit(false.B)
  val write_to_op_reg = writeEn && writeAddr === CoreCsrAddrs.DbgReqOp
  req_valid_pulse := Mux(write_to_op_reg && io.debug.req.ready, true.B, false.B) // 仅当写入操作码寄存器且调试模块准备好时生成脉冲
  io.debug.req.valid := req_valid_pulse  // 请求有效: 仅在写入操作码寄存器且调试模块准备好时有效

  // 将寄存的地址/数据/操作码发送给 Debug Module
  io.debug.req.bits.address := debugReqAddrReg
  io.debug.req.bits.data    := debugReqDataReg
  val (req_op, req_op_valid) = DmReqOp.safe(debugReqOpReg)     // 安全转换枚举值
  io.debug.req.bits.op := Mux(req_op_valid, req_op, DmReqOp.NOP)

  // 响应出队: 写 DbgStatus 寄存器时, 消费响应队列中的一项
  val write_to_status_reg = writeEn && writeAddr === CoreCsrAddrs.DbgStatus
  rsp_queue.io.deq.ready := write_to_status_reg

  // ---- 读地址处理 ----
  val readAddr = io.fabric.readDataAddr.bits                    // 原始读地址
  // 地址对齐: 对齐到 AXI 数据总线宽度 (如 256-bit → 32B 对齐)
  val alignedAddr = readAddr & ~((p.axi2DataBytes - 1).U(readAddr.getWidth.W))

  val kRegWidthBits  = 32                                       // 每个寄存器 32-bit
  val kRegWidthBytes = kRegWidthBits / 8                        // 4 bytes
  val kCsrBaseAddr   = 0x100                                    // 核内 CSR 寄存器基地址

  // ---- 读数据组装: 256-bit 总线按 32-bit lane 组织 ----
  val regsPerBus = p.axi2DataBits / kRegWidthBits              // 每总线周期多少个32-bit寄存器 (如256/32=8)
  val readData = Wire(Vec(regsPerBus, UInt(kRegWidthBits.W)))   // 8 lane × 32-bit = 256-bit 读数据
  for (i <- 0 until regsPerBus) { readData(i) := 0.U }          // 默认全 0

  // ---- 寄存器映射表 (地址偏移 → 寄存器值) ----
  // 核心控制寄存器
  val coreRegMap = Map(
    0x0 -> resetReg,                                            // offset 0x0: 复位/时钟门控
    0x4 -> pcStartReg,                                          // offset 0x4: PC 启动地址
    0x8 -> statusReg,                                           // offset 0x8: 故障/暂停状态
  )

  // 核内 CSR 寄存器 (从 Core 读取, 只读, 基地址 0x100)
  val csrRegs   = io.coralnpu_csr.value                         // csrOutCount 个 32-bit 值
  val csrRegMap = (0 until p.csrOutCount).map { i =>
    (kCsrBaseAddr + i * kRegWidthBytes) -> csrRegs(i)           // 0x100, 0x104, 0x108, ...
  }.toMap

  // 调试寄存器 (0x800~0x814)
  val debugStatusReg = Cat(rsp_queue.io.deq.valid, io.debug.req.ready) // bit0=RspValid, bit1=ReqReady
  val debugReadMap = Seq(
    CoreCsrAddrs.DbgReqAddr -> debugReqAddrReg,                  // 0x800: 调试请求地址
    CoreCsrAddrs.DbgReqData -> debugReqDataReg,                  // 0x804: 调试请求数据
    CoreCsrAddrs.DbgReqOp   -> debugReqOpReg,                    // 0x808: 调试请求操作码
    CoreCsrAddrs.DbgRspData -> rsp_queue.io.deq.bits.data,      // 0x80c: 调试响应数据
    CoreCsrAddrs.DbgRspOp   -> rsp_queue.io.deq.bits.op.asUInt, // 0x810: 调试响应操作码
    CoreCsrAddrs.DbgStatus  -> debugStatusReg,                   // 0x814: 调试状态
  ).map { case (k, v) => k.litValue.toInt -> v }.toMap

  // 合并所有寄存器映射
  val allReadRegs = coreRegMap ++ csrRegMap ++ debugReadMap

  // 按对齐地址分组: 同一总线宽度的寄存器被归到一组, 一次 Fabric 读可返回多个
  // 例: 256-bit 总线 → offset 0x0/0x4/0x8/0xc 分为 4 个 32-bit lane
  val groupedRegs = allReadRegs.groupBy { case (offset, _) =>
    offset & ~(p.axi2DataBytes - 1)                              // 按总线宽度对齐分组
  }

  // 生成读逻辑: 每个对齐基地址一个 when 分支
  for ((base, regs) <- groupedRegs) {
    when(alignedAddr === base.U) {
      for ((offset, reg) <- regs) {
        // 将寄存器值放入正确的 32-bit lane
        // 例: offset=0x4 → lane 1; offset=0x8 → lane 2
        readData((offset % p.axi2DataBytes) / kRegWidthBytes) := reg
      }
    }
  }

  // 读数据有效: 仅当地址命中寄存器映射表时才有效
  val readDataValid = MuxLookup(readAddr, false.B)(
    allReadRegs.keys.map(addr => (addr.U -> true.B)).toSeq
  )

  // 读数据延迟 1 拍输出 (改善时序, 匹配 Fabric 读延迟)
  val readDataNext = Pipe(readDataValid, readData.asUInt, 1)
  io.fabric.readData := readDataNext

  // ---- 输出到 CoreAxi ----
  io.reset   := resetReg(0)                                     // bit0 = reset
  io.cg      := resetReg(1)                                     // bit1 = clock gate
  io.pcStart := Mux(bootAddrCapture, io.bootAddr, pcStartReg)   // 首次用 bootAddr, 后续用寄存器值
  statusReg  := Cat(io.fault, io.halted)                        // 更新状态

  // ---- 寄存器写逻辑: 按地址写入对应寄存器 ----
  // resetReg: offset 0x0, 低 32-bit
  resetReg := Mux(writeEn && writeAddr === 0x0.U, writeData(31,0), resetReg)
  // pcStartReg: offset 0x4, 次低 32-bit (写地址 0x4, 数据在 63:32)
  pcStartReg := Mux(bootAddrCapture, io.bootAddr,
                    Mux(writeEn && writeAddr === 0x4.U, writeData(63,32), pcStartReg))
  bootAddrCapture := false.B                                    // 首次捕获后永久置 false
  // 调试寄存器: 分别映射到 32-bit lane 0/1/2
  debugReqAddrReg := Mux(writeEn && writeAddr === CoreCsrAddrs.DbgReqAddr, writeData(31,0), debugReqAddrReg)
  debugReqDataReg := Mux(writeEn && writeAddr === CoreCsrAddrs.DbgReqData, writeData(63,32), debugReqDataReg)
  debugReqOpReg   := Mux(writeEn && writeAddr === CoreCsrAddrs.DbgReqOp, writeData(95,64), debugReqOpReg)

  // ---- 写响应: 仅合法地址返回成功 ----
  // 0x8 statusReg 只读，不在 allWriteRegs 中。
  // 0x80c / 0x810 response data/op 只读，不在 allWriteRegs 中。
// |          地址 | 名称                     | 读 | 写 | 说明                     |
// | ------------: | ----------------------- | - | - | ---------------------- |
// |       `0x000` | `resetReg`              | 是 | 是 | bit0 reset，bit1 cg     |
// |       `0x004` | `pcStartReg`            | 是 | 是 | Core 启动 PC             |
// |       `0x008` | `statusReg`             | 是 | 否 | bit0 halted，bit1 fault |
// | `0x100 + 4*i` | `coralnpu_csr.value(i)` | 是 | 否 | Core 内部 CSR 输出，只读      |
// |       `0x800` | `DbgReqAddr`            | 是 | 是 | Debug 请求地址             |
// |       `0x804` | `DbgReqData`            | 是 | 是 | Debug 请求数据             |
// |       `0x808` | `DbgReqOp`              | 是 | 是 | 写入后触发 Debug 请求         |
// |       `0x80c` | `DbgRspData`            | 是 | 否 | Debug 响应数据             |
// |       `0x810` | `DbgRspOp`              | 是 | 否 | Debug 响应操作码            |
// |       `0x814` | `DbgStatus`             | 是 | 是 | 读状态；写入时弹出响应队列          |

  val debugWriteValidMap = Map(
    CoreCsrAddrs.DbgReqAddr.litValue.toInt -> true.B,
    CoreCsrAddrs.DbgReqData.litValue.toInt -> true.B,
    CoreCsrAddrs.DbgReqOp.litValue.toInt   -> true.B,
    CoreCsrAddrs.DbgStatus.litValue.toInt  -> true.B,
  )
  val allWriteRegs = Map(0x0 -> true.B, 0x4 -> true.B) ++ debugWriteValidMap
  io.fabric.writeResp := writeEn && MuxLookup(writeAddr, false.B)(
    allWriteRegs.map { case (k, v) => k.U -> v }.toSeq
  )
}

// ===================================================================
// CoreAxiCSR — CoreCSR 的 AXI 封装版
//
// 内部实例化 AxiSlave (AXI→Fabric) + CoreCSR (Fabric→寄存器)
// 可选 AXI 读通道延迟 (通过 Queue 插入流水级, 改善时序)
//
// 连接: io.axi → AxiSlave → CoreCSR(fabric) → 寄存器 + Debug Module
// ===================================================================
/** CoreAxiCSR — AXI Slave 封装版 CoreCSR
 *  @param axiReadAddrDelay AXI 读地址通道的 Queue 深度 (0=直通, >0=延迟)
 *  @param axiReadDataDelay AXI 读数据通道的 Queue 深度 */
class CoreAxiCSR(p: Parameters,
                    axiReadAddrDelay: Int = 0,
                    axiReadDataDelay: Int = 0) extends Module {
  val io = IO(new Bundle {
    val axi      = Flipped(new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)) // AXI 从接口
    val internal = Input(Bool())                                // 内部/外部标志
    val reset    = Output(Bool())                               // 复位输出 (→ Core)
    val cg       = Output(Bool())                               // 时钟门控输出
    val pcStart  = Output(UInt(p.fetchAddrBits.W))             // PC 启动地址
    val bootAddr = Input(UInt(p.fetchAddrBits.W))              // 启动地址输入
    val halted   = Input(Bool())                                // 核已暂停
    val fault    = Input(Bool())                                // 核异常标志
    val coralnpu_csr = Input(new CsrOutIO(p))                  // 核内 CSR 值
    val debug    = Flipped(new DebugModuleIO(p))               // 调试模块接口
  })

  // AxiSlave: 转换 AXI 到 Fabric 协议
  val axi = Module(new AxiSlave(p))
  io.axi.write <> axi.io.axi.write                              // 写通道直连
  // 读通道可选延迟: Queue 插入流水级改善时序 (打破单周期读路径)
  axi.io.axi.read.addr <> Queue(io.axi.read.addr, axiReadAddrDelay)
  io.axi.read.data <> Queue(axi.io.axi.read.data, axiReadDataDelay)

  axi.io.periBusy := false.B                                    // 永不反压 (AXI Slave 始终就绪)

  // CoreCSR: Fabric 接口 → 寄存器
  val csr = Module(new CoreCSR(p))
  csr.io.fabric   <> axi.io.fabric
  csr.io.internal := io.internal

  io.reset   := csr.io.reset
  io.cg      := csr.io.cg
  io.pcStart := csr.io.pcStart
  csr.io.bootAddr := io.bootAddr
  csr.io.halted   := io.halted
  csr.io.fault    := io.fault
  csr.io.coralnpu_csr := io.coralnpu_csr
  io.debug <> csr.io.debug
}
