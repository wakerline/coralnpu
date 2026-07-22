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
// Axi.scala — AXI4 总线协议 Bundle 定义 (ARM IHI 0022E)
//
// AXI4 有 5 个独立通道:
//   写地址通道  (Write Address)     → AxiAddress
//   写数据通道  (Write Data)        → AxiWriteData
//   写响应通道  (Write Response)    → AxiWriteResponse
//   读地址通道  (Read Address)      → AxiAddress (复用)
//   读数据通道  (Read Data)         → AxiReadData
//
// AXI4-Lite (简化版): 无突发, 数据宽度固定 → AxiLite*
// ============================================================================

package bus

import chisel3._
import chisel3.util._

// ---- 枚举类型 ----

/** AxiResponseType — AXI 写响应/读响应码 (2-bit)
 *  OKAY(0):   正常访问成功
 *  EXOKAY(1): 独占访问成功
 *  SLVERR(2): 从设备错误 (如 FIFO 满)
 *  DECERR(3): 地址译码错误 (无此地址) */
object AxiResponseType extends ChiselEnum {
  val OKAY   = Value(0.U(2.W))
  val EXOKAY = Value(1.U(2.W))
  val SLVERR = Value(2.U(2.W))
  val DECERR = Value(3.U(2.W))
}

/** AxiBurstType — AXI 突发类型 (2-bit)
 *  FIXED(0): 固定地址 (如 FIFO 访问)
 *  INCR(1):  递增地址 (最常用)
 *  WRAP(2):  回绕地址 (到达边界后回到起始) */
object AxiBurstType extends ChiselEnum {
  val FIXED = Value(0.U)
  val INCR  = Value(1.U)
  val WRAP  = Value(2.U)
}

// ---- AXI4 通道 Bundle (ARM IHI 0022E 标准) ----

/** AxiAddress — 写地址通道和读地址通道 (A2.2 / A2.5)
 *  必选: addr(地址), prot(保护类型)
 *  可选: id/len/size/burst/lock/cache/qos/region
 *  size 编码: 0=1B, 1=2B, 2=4B, 3=8B, ... */
class AxiAddress(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Bundle {
  val addr   = UInt(addrWidthBits.W)                              // 地址 (字节粒度)
  val prot   = UInt(3.W)                                          // 保护类型 [2]=指令/数据, [1]=特权/用户, [0]=安全/非安全
  val id     = UInt(idBits.W)                                     // 事务 ID (用于多主设备响应路由)
  val len    = UInt(8.W)                                          // 突发长度-1 (0=1拍, 1=2拍, ..., 255=256拍)
  val size   = UInt(3.W)                                          // 每拍传输字节数: 0=1B, 1=2B, 2=4B, ...
  val burst  = UInt(2.W)                                          // 突发类型: 0=FIXED, 1=INCR, 2=WRAP
  val lock   = UInt(1.W)                                          // 原子访问锁 (通常=0)
  val cache  = UInt(4.W)                                          // Cache 属性
  val qos    = UInt(4.W)                                          // QoS 优先级
  val region = UInt(4.W)                                          // 区域标识

  /** 设置未使用可选字段的安全默认值 (防止 X 传播) */
  def defaults() = {
    id     := 0.U                                                 // 单主设备时 ID=0
    len    := 0.U                                                 // 单拍传输
    size   := log2Ceil(dataWidthBits / 8).U                       // 默认=总线宽度
    burst  := 1.U                                                 // INCR (递增)
    lock   := 0.U                                                 // 正常访问
    cache  := 0.U
    qos    := 0.U
    region := 0.U
  }
}

/** AxiWriteData — 写数据通道 (A2.3)
 *  必选: data(写数据), last(最后一拍标志)
 *  可选: strb(字节使能, 每位对应一个字节) */
class AxiWriteData(dataWidthBits: Int, idBits: Int) extends Bundle {
  val data = UInt(dataWidthBits.W)                                // 写数据
  val last = Bool()                                                // 突发最后一拍 (last=1 表示传输完成)
  val strb = UInt((dataWidthBits/8).W)                            // 字节使能: bit[i]=1 表示 byte[i] 有效

  /** 默认 strb=全1 (所有字节有效) */
  def defaults() = {
    strb := ((1 << (dataWidthBits/8)) - 1).U
  }
}

/** AxiWriteResponse — 写响应通道 (A2.4)
 *  id:   事务 ID (与 AxiAddress.id 对应)
 *  resp: 响应码 (OKAY/EXOKAY/SLVERR/DECERR) */
class AxiWriteResponse(idBits: Int) extends Bundle {
  val id   = UInt(idBits.W)                                       // 事务 ID
  val resp = UInt(2.W)                                            // 响应码

  def defaults() = { id := 0.U; resp := 0.U }                   // 默认 OKAY
  def defaultsFlipped() = { defaults() }
}

/** AxiReadData — 读数据通道 (A2.6)
 *  data: 读回数据
 *  id:   事务 ID (与 AxiAddress.id 对应)
 *  resp: 响应码
 *  last: 突发最后一拍 */
class AxiReadData(dataWidthBits: Int, idBits: Int) extends Bundle {
  val data = UInt(dataWidthBits.W)                                // 读数据
  val id   = UInt(idBits.W)                                       // 事务 ID
  val resp = UInt(2.W)                                            // 响应码
  val last = Bool()                                                // 突发最后一拍

  def defaults() = { id := 0.U; resp := 0.U; last := false.B }
  def defaultsFlipped() = { defaults() }
}

// ---- AXI4-Lite 简化通道 (无突发, 无 ID) ----

/** AxiLiteAddress — AXI4-Lite 地址通道 (仅 addr + prot) */
class AxiLiteAddress(addrWidthBits: Int) extends Bundle {
  val addr = UInt(addrWidthBits.W)
  val prot = UInt(3.W)
}

/** AxiLiteWriteData — AXI4-Lite 写数据通道 */
class AxiLiteWriteData(dataWidthBits: Int) extends Bundle {
  val data = UInt(dataWidthBits.W)
  val strb = UInt((dataWidthBits/8).W)
}

/** AxiLiteReadData — AXI4-Lite 读数据通道 */
class AxiLiteReadData(dataWidthBits: Int) extends Bundle {
  val data = UInt(dataWidthBits.W)
  val resp = UInt(2.W)
}

// ---- AXI4 Master 顶层 Bundle (写+读) ----

/** AxiMasterIO — AXI4 Master 完整接口: 写通道 + 读通道
 *  使用前必须调用 defaults() 设置安全默认值 (防止无效驱动) */
class AxiMasterIO(addrWidthBits: Int, dataWidthBits: Int, idBits: Int)
    extends Bundle {
  val write = new AxiMasterWriteIO(addrWidthBits, dataWidthBits, idBits)  // 写地址+写数据+写响应
  val read  = new AxiMasterReadIO(addrWidthBits, dataWidthBits, idBits)   // 读地址+读数据

  def defaults()       = { write.defaults(); read.defaults() }
  def defaultsFlipped() = { write.defaultsFlipped(); read.defaultsFlipped() }
}

/** AxiMasterWriteIO — AXI4 Master 写通道:
 *   addr (输出): 写地址
 *   data (输出): 写数据
 *   resp (输入): 写响应 (Flipped 表示从外部输入) */
class AxiMasterWriteIO(addrWidthBits: Int, dataWidthBits: Int, idBits: Int)
    extends Bundle {
  val addr = Decoupled(new AxiAddress(addrWidthBits, dataWidthBits, idBits))  // Master→Slave
  val data = Decoupled(new AxiWriteData(dataWidthBits, idBits))               // Master→Slave
  val resp = Flipped(Decoupled(new AxiWriteResponse(idBits)))                 // Slave→Master

  /** 设置 Master 侧安全默认值: valid=false, ready=true */
  def defaults() = {
    addr.bits.defaults(); addr.valid := false.B
    data.bits.defaults(); data.valid := false.B
    resp.ready := true.B
  }
  /** 设置 Slave 侧安全默认值 (Flipped 时使用): ready=false, valid=false */
  def defaultsFlipped() = {
    addr.ready := false.B; data.ready := false.B
    resp.valid := false.B; resp.bits.defaultsFlipped()
  }
}

/** AxiMasterReadIO — AXI4 Master 读通道:
 *   addr (输出): 读地址
 *   data (输入): 读数据 (Flipped 表示从外部输入) */
class AxiMasterReadIO(addrWidthBits: Int, dataWidthBits: Int, idBits: Int)
    extends Bundle {
  val addr = Decoupled(new AxiAddress(addrWidthBits, dataWidthBits, idBits))  // Master→Slave
  val data = Flipped(Decoupled(new AxiReadData(dataWidthBits, idBits)))       // Slave→Master

  def defaults() = {
    addr.bits.defaults(); addr.valid := false.B
    data.ready := false.B
  }
  def defaultsFlipped() = {
    addr.ready := false.B
    data.valid := false.B; data.bits.defaultsFlipped()
  }
}

// ---- AXI4-Lite Master 顶层 Bundle ----

class AxiLiteMasterIO(val addrWidthBits: Int, val dataWidthBits: Int) extends Bundle {
  val read  = new AxiLiteMasterReadIO(addrWidthBits, dataWidthBits)
  val write = new AxiLiteMasterWriteIO(addrWidthBits, dataWidthBits)
}

class AxiLiteMasterWriteIO(val addrWidthBits: Int, val dataWidthBits: Int) extends Bundle {
  val addr = Decoupled(new AxiLiteAddress(addrWidthBits))
  val data = Decoupled(new AxiLiteWriteData(dataWidthBits))
  val resp = Flipped(Decoupled(UInt(2.W)))                        // 仅 resp 码, 无 ID
}

class AxiLiteMasterReadIO(addrWidthBits: Int, dataWidthBits: Int)
    extends Bundle {
  val addr = Decoupled(new AxiLiteAddress(addrWidthBits))
  val data = Flipped(Decoupled(new AxiLiteReadData(dataWidthBits)))
}
