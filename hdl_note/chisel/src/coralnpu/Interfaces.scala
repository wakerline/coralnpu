// ============================================================================
// Interfaces.scala — CoralNPU 全部硬件接口 Bundle 定义
//
// 本文件是理解整个 CoralNPU 模块间通信的"接口词典"。定义了 20+ 个 Bundle:
//
//   ---- 核内总线 ----
//   IBusIO     — 取指总线 (valid/ready + 256-bit rdata + fault)
//   DBusIO     — 数据总线 (读/写 + byte mask + AXI size 编码)
//   EBusIO     — 扩展总线 (DBus + internal 标志 + fault)
//   FabricIO   — 内部 SRAM 交叉开关协议 (读地址/数据 + 写地址/数据/strb/响应)
//
//   ---- 寄存器文件 ----
//   RegfileReadDataIO / RegfileWriteAddrIO / RegfileWriteDataIO
//   RegfileBusPortIO / RegfileLinkPortIO
//   FRegfileRead / FRegfileWrite — 浮点寄存器读写
//   VectorWriteDataIO — 向量寄存器写回
//
//   ---- CSR / 调试 / 控制 ----
//   CsrInIO / CsrOutIO / CsrInOutIO / CsrCmd / CsrOp / CsrTraceIO
//   CoreDMIO — Debug Module 与核心接口
//   DebugIO — 硬件调试观测信号 (PC/指令/寄存器/退役缓冲)
//   RetirementBufferDebugIO — 退役缓冲区全部状态快照
//   FaultInfo / FaultManagerOutput — 故障/异常信息
//
//   ---- 流水线控制 ----
//   FetchInstruction / FetchIO / FetchUnit — 取指输出
//   IFlushIO / DFlushIO — 指令/数据流水线刷新
//   BranchTakenIO — 分支反馈
//
//   ---- SRAM ----
//   SRAM128 — 128-bit 宽 SRAM BlackBox 接口
//
// 设计模式: 所有 Bundle 继承自 chisel3.Bundle; Flipped() 翻转端口方向;
//          Option.when() 实现条件编译; Valid/Decoupled 包裹握手信号。
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

import common.Fp32
import chisel3._
import chisel3.util._

// ---- CSR 接口 ----

/** CSR 输入 — csrInCount 个 32-bit 信号，从核外传入 (如中断状态、计数器) */
class CsrInIO(p: Parameters) extends Bundle { //Bundle 的作用就是：把多个相关信号打包成一个接口
  val value = Input(Vec(p.csrInCount, UInt(32.W)))
}

/** CSR 输出 — csrOutCount 个 32-bit 信号，从核内传出 (如异常地址、状态标志) */
class CsrOutIO(p: Parameters) extends Bundle {
  val value = Output(Vec(p.csrOutCount, UInt(32.W)))
}

/** CSR 双向接口 — 合并输入输出为一个 Bundle */
class CsrInOutIO(p: Parameters) extends Bundle {
  val in  = new CsrInIO(p)
  val out = new CsrOutIO(p)
}

// ---- 分支接口 ----

/** 分支跳转信号 — 执行单元通知取指单元: valid=发生分支, value=目标 PC */
class BranchTakenIO(p: Parameters) extends Bundle {
  val valid = Output(Bool())
  val value = Output(UInt(p.programCounterBits.W))
}

// ---- 寄存器文件接口 ----

/** 寄存器文件链接端口 — 在流水线级间传递寄存器值 (如 bypass 网络输入) */
class RegfileLinkPortIO extends Bundle {
  val valid = Output(Bool())
  val value = Output(UInt(32.W))
}

/** 寄存器文件总线端口 — 多 lane 并行的寄存器读地址/数据 */
class RegfileBusPortIO(p: Parameters) extends Bundle {
  val addr = Vec(p.instructionLanes, UInt(32.W))  // 各 lane 的源寄存器地址
  val data = Vec(p.instructionLanes, UInt(32.W))  // 各 lane 读出的寄存器数据
}

// ---- 取指总线 (Instruction Bus) ----

/** 取指总线 — 核心与指令存储器之间的 valid/ready 握手协议。
 *  valid 有效后 addr 必须保持稳定直到 ready 握手完成。
 *  控制阶段: valid/ready/addr; 读取阶段: rdata/fault */
class IBusIO(p: Parameters) extends Bundle {
  // Control Phase.
  val valid = Output(Bool())
  val ready = Input(Bool())
  val addr = Output(UInt(p.fetchAddrBits.W))
  // Read Phase.
  val rdata = Input(UInt(p.fetchDataBits.W))
  // Fault information.
  val fault = Input(Valid(new FaultInfo(p)))

  /** 一次成功的总线事务: valid && ready 同时为真 */
  def fire: Bool = valid && ready
}

// ---- 取指输出 ---

/** 取指指令 — 单条指令字 + 元数据: addr=PC, inst=32-bit指令, brchFwd=分支前向标志 */
class FetchInstruction(p: Parameters) extends Bundle {
  val addr = UInt(p.programCounterBits.W)
  val inst = UInt(p.instructionBits.W)
  val brchFwd = Bool()
}

/** 取指输出接口 — instructionLanes(默认4) 条指令，每条 Decoupled 握手 */
class FetchIO(p: Parameters) extends Bundle {
  val lanes = Vec(p.instructionLanes, Decoupled(new FetchInstruction(p)))
}

/** 取指单元抽象基类 — 定义所有取指实现的公共 IO (Cache / Uncached 皆继承此) */
abstract class FetchUnit(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val csr = new CsrInIO(p)
    val debug_pc = Flipped(Valid(UInt(p.fetchAddrBits.W)))
    val ibus = new IBusIO(p)
    val inst = new FetchIO(p)
    val branch = Flipped(Vec(p.instructionLanes, new BranchTakenIO(p)))
    val linkPort = Flipped(new RegfileLinkPortIO)
    val iflush = Flipped(new IFlushIO(p))
    val pc = UInt(p.fetchAddrBits.W)
    val fault = Output(Valid(UInt(32.W)))
  })
}

// ---- SRAM 黑盒接口 ----

/** 128-bit 宽 SRAM BlackBox — 用于 ITCM/DTCM 等紧耦合存储。
 *  numEntries=深度, globalBaseAddr=全局基地址(地址译码用)。 */
abstract class SRAM128(numEntries: Int, globalBaseAddr: Int = 0) extends BlackBox(Map(
  "NUM_ENTRIES" -> chisel3.experimental.IntParam(numEntries),
  "GLOBAL_BASE_ADDR" -> chisel3.experimental.IntParam(globalBaseAddr)
)) {
  val addrWidth = log2Ceil(numEntries)
  val io = IO(new Bundle {
    val clock    = Input(Clock())
    val enable   = Input(Bool())
    val write    = Input(Bool())
    val addr     = Input(UInt(addrWidth.W))
    val wdata    = Input(UInt(128.W))
    val wmask    = Input(UInt(16.W))
    val rdata    = Output(UInt(128.W))
    val rvalid   = Output(Bool())
  })
}

// ---- 总线故障信息 ----

/** 总线故障 — write=写故障, addr=故障地址, epc=异常PC */
class FaultInfo(p: Parameters) extends Bundle {
  val write = Bool()
  val addr = UInt(p.programCounterBits.W)
  val epc  = UInt(p.programCounterBits.W)
}

// ---- 数据总线 (Data Bus) ----

/** 数据总线 — 核心与数据存储器 (DTCM/Cache) 之间的通信。
 *  支持按字节粒度读写, 使用 valid/ready 握手。
 *  bank=true 时地址位宽减1 (L1 DCache 双bank模式)。 */
class DBusIO(p: Parameters, bank: Boolean = false) extends Bundle {
  // ------ 控制阶段 ------
  val valid = Output(Bool())                                        // 访存请求有效
  val ready = Input(Bool())                                         // 存储器就绪
  val write = Output(Bool())                                        // 读(0)/写(1)
  val pc   = Output(UInt(32.W))                                     // 触发该访存的指令 PC
  val addr = Output(UInt((p.lsuAddrBits - (if (bank) 1 else 0)).W)) // 访存地址 (bank模式去最低位)
  val adrx = Output(UInt((p.lsuAddrBits - (if (bank) 1 else 0)).W)) // 额外地址/索引
  val size = Output(UInt(p.dbusSize.W))                              // 传输大小 (AXI size 编码)
  val wdata = Output(UInt(p.lsuDataBits.W))                          // 写数据 (256-bit)
  val wmask = Output(UInt((p.lsuDataBits / 8).W))                   // 写字节掩码 (32-bit)
  // ------ 读取阶段 ------
  val rdata = Input(UInt(p.lsuDataBits.W))                           // 读回数据
}

/** 扩展总线 — DBus 的超集: +internal(1=内部SRAM/0=外部AXI) + fault */
class EBusIO(p: Parameters) extends Bundle {
  val dbus = new DBusIO(p)
  val internal = Output(Bool())                    // 1=内部SRAM, 0=外部AXI (用于Fabric路由)
  val fault = Flipped(Valid(new FaultInfo(p)))     // 总线故障返回
}

// ---- 流水线刷新 ----

/** 指令流水线刷新 — valid=刷新请求, pcNext=刷新后重取PC, ready=完成 */
class IFlushIO(p: Parameters) extends Bundle {
  val valid = Output(Bool())
  val pcNext = Output(UInt(32.W))
  val ready = Input(Bool())
}

/** 数据流水线刷新 — all=1刷新全部, clean=1写回脏数据再刷新 */
class DFlushIO(p: Parameters) extends Bundle {
  val valid = Output(Bool())
  val ready = Input(Bool())
  val all   = Output(Bool())  // 是否全部刷新，all=0: 仅刷新指定行(见 dbus.addr)
  val clean = Output(Bool())  // clean and flush
}

// ---- 退役缓冲区调试 ----

/** 退役缓冲区调试接口 — 暴露所有在飞指令的完整状态 (RVVI 验证跟踪用)。
 *  每条指令: pc/inst/idx/data/vecWrites(向量写回)/trap */
class RetirementBufferDebugIO(p: Parameters) extends Bundle {
  val inst = Vec(p.retirementBufferSize, Valid(new Bundle {
    val pc = UInt(32.W)
    val inst = UInt(32.W)
    val idx = UInt(p.retirementBufferIdxWidth.W)  //写回目标索引
    val data = if (p.enableRvv) UInt(p.rvvVlen.W) else UInt(32.W)  //写回数据
    val vecWrites = Option.when(p.enableRvv)(Vec(8, Valid(new Bundle {  //RVV 情况下多个向量写回// 8个向量写端口
      val data = UInt(p.rvvVlen.W)
      val idx = UInt(5.W)
    })))
    val trap = Bool()
  }))
}

// ---- 硬件调试 ----

/** 调试观测接口 — 暴露处理器内部关键信号 (HDL 开发/波形观测用)。
 *  包含: 当前指令(en/addr/inst)、DBus活动、指令发射、寄存器写回、退役缓冲 */
class DebugIO(p: Parameters) extends Bundle {
  val en = Output(UInt(4.W))
  val addr = Vec(p.instructionLanes, UInt(32.W))
  val inst = Vec(p.instructionLanes, UInt(32.W))
  val cycles = Output(UInt(32.W))

  val dbus = Valid(new Bundle {
    val addr = UInt(32.W)
    val wdata = UInt(p.axi2DataBits.W)
    val write = Bool()
  })

  val dispatch = Vec(p.instructionLanes, new Bundle {
    val instFire = Bool()  //instFire = 1 表示这一 lane 本周期有指令发射
    val instAddr = UInt(32.W)
    val instInst = UInt(32.W)
  })

  val regfile = new Bundle {
    // At decode time, what registers the instructions will write to.
    val writeAddr = Vec(p.instructionLanes, Valid(UInt(5.W)))
    // Writeback to the register file.//instructionLanes + 2 表示除了 4 个主 lane，还可能有额外写回通道，例如 load/CSR/其他单元。
    val writeData = Vec(p.instructionLanes + 2, Valid(new Bundle {
      val addr = UInt(5.W)
      val data = UInt(32.W)
    }))
  }

  val float = Option.when(p.enableFloat)(new Bundle {
    // Decode
    val writeAddr = Valid(UInt(5.W))
    // Execute
    val writeData = Vec(2, Valid(new Bundle {
      val addr = UInt(32.W)
      val data = UInt(32.W)
    }))
  })
  //把整个退役缓冲区状态输出给 debug。
  val rb = Output(new RetirementBufferDebugIO(p))
}

// ---- 寄存器文件读写 ----

/** 寄存器读数据 — valid 握手 + 32-bit 数据 */
class RegfileReadDataIO extends Bundle {
  val valid = Output(Bool())
  val data  = Output(UInt(32.W))
}
/** 寄存器写地址 — 5-bit 地址 (32 个寄存器) */
class RegfileWriteAddrIO extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(5.W))
}
/** 寄存器写数据 — 5-bit 地址 + 32-bit 数据 */
class RegfileWriteDataIO extends Bundle {
  val addr  = Input(UInt(5.W))
  val data  = Input(UInt(32.W))
}
/** 向量寄存器写数据 — VLEN-bit + uOP PC + 最后一条标志 (RVV用) */
class VectorWriteDataIO(p: Parameters) extends Bundle {
  val addr  = Input(UInt(5.W))                    // 向量寄存器编号
  val data  = Input(UInt(p.lsuDataBits.W))         // 向量数据 (128-bit)
  val uop_pc = Input(UInt(32.W))                   // 对应微操作 PC
  val last_uop_valid = Input(Bool())               // 最后一条微操作有效
}

// ---- Fabric 内部互联 ----

/** Fabric IO — 内部 SRAM 交叉开关的端口协议。
 *  约朿: 同一周期只能进行读或写 (不能同时)。 */
class FabricIO(p: Parameters) extends Bundle {
    val readDataAddr = Output(Valid(UInt(p.axi2AddrBits.W)))    // 读请求 (地址)
    val readData = Input(Valid(UInt(p.axi2DataBits.W)))         // 读响应 (数据)
    val writeDataAddr = Output(Valid(UInt(p.axi2AddrBits.W)))   // 写请求 (地址)
    val writeDataBits = Output(UInt(p.axi2DataBits.W))          // 写数据
    val writeDataStrb = Output(UInt((p.axi2DataBits / 8).W))    // 写字节使能
    val writeResp = Input(Bool())                                // 写响应 (1=成功)
}

// ---- CSR 操作 ----

/** CSR 操作类型: CSRRW(原子读写), CSRRS(读后置位), CSRRC(读后清除) */
object CsrOp extends ChiselEnum {
  val CSRRW = Value
  val CSRRS = Value
  val CSRRC = Value
}
/** CSR 命令 — 译码阶段产生的 CSR 操作 */
class CsrCmd extends Bundle {
  val addr = UInt(5.W)    // 内部 CSR 地址
  val index = UInt(12.W)  // RISC-V CSR 索引 (如 0x300=mstatus)
  val rs1 = UInt(5.W)     // 源寄存器 rs1 编号
  val op = CsrOp()        // 操作类型
}

// ---- 浮点寄存器 ----

/** 浮点寄存器读端口 */
class FRegfileRead extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(5.W))
  val data  = Output(new Fp32)
}
/** 浮点寄存器写端口 */
class FRegfileWrite extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(5.W))
  val data  = Input(new Fp32)
}

// ---- Debug Module 接口 ----

/** Core Debug Module IO — RISC-V 调试模块与处理器核的接口。
 *  支持: halt/resume, CSR命令访问, 标量/浮点寄存器读写。 */
class CoreDMIO(p: Parameters) extends Bundle {
  val debug_req  = Input(Bool())                                // 请求进入调试模式
  val resume_req = Input(Bool())                                // 请求恢复运行
  val csr        = Input(Valid(new CsrCmd))                     // CSR 访问命令 (调试器→核)
  val csr_rs1    = Input(UInt(32.W))                            // CSR 操作的 rs1 值
  val csr_rd     = Output(Valid(UInt(32.W)))                    // CSR 读回值 (核→调试器)
  val scalar_rd  = Flipped(Decoupled(new RegfileWriteDataIO))   // 标量寄存器写 (调试器→核)
  val scalar_rs  = new Bundle {
    val idx  = Input(UInt(5.W))                                 // 要读取的寄存器编号
    val data = Output(UInt(32.W))                               // 读出的寄存器值
  }
  val float_rd = Option.when(p.enableFloat)(new FRegfileWrite)  // 浮点寄存器写 (条件: enableFloat)
  val float_rs = Option.when(p.enableFloat)(new FRegfileRead)   // 浮点寄存器读 (条件: enableFloat)
  val debug_mode = Output(Bool())                                // 当前是否处于调试模式
}

// ---- CSR 跟踪 ----

/** CSR 跟踪接口 — 记录 CSR 变化供 RVVI 验证跟踪 (valid/addr/data) */
class CsrTraceIO(p: Parameters) extends Bundle {
  val valid = Bool()
  val addr = UInt(12.W)   // 12-bit RISC-V CSR 地址
  val data = UInt(32.W)   // CSR 写入值
}

// ---- 故障管理器 ----

/** 故障管理器输出 — 异常/中断的完整信息。
 *  mepc=异常返回地址, mtval=附加信息(如错误地址), mcause=原因码, decode=译码阶段异常 */
class FaultManagerOutput extends Bundle {
  val mepc = UInt(32.W)
  val mtval = UInt(32.W)
  val mcause = UInt(32.W)
  val decode = Bool()
}
