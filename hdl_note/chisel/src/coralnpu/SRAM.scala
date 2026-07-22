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

// ============================================================================
// SRAM.scala — SRAM 的 FabricIO 接口封装
//
// Fabric 协议使用简化的地址/数据/响应信号, 但底层 SRAM (TCM128→Sram_Nx128→SramBlock)
// 需要的是标准 SRAM 时序 (addr/enable/write/wdata/wmask/rdata)。
// SRAM 模块填补了这两者之间的差距。
//
// 连接关系 (以 ITCM 为例):
//   CoreAxi → FabricArbiter → FabricMux → SRAM → TCM128 → Sram_Nx128 → SramBlock(Sram.v)
//                       FabricIO 协议                SRAM 时序       128-bit 接口
//
// 关键设计:
//   - 读优先: 读请求和写请求同时到达时, 读优先 (addr 使用读地址)
//   - 读延迟适配: Fabric 的 readData 需要 1 拍后才有效 (SRAM 读延迟),
//                 用 readIssued 寄存器标记上拍是否发了读请求
//   - 写直通: 写操作在当前周期直接送到 SRAM, 写响应恒为 true
//   - 掩码管理: 写时用 Fabric 的 strb, 读时用全1掩码 (读全部字节)
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._

import common._

// ---- SRAMIO — 标准 SRAM 时序接口 ----

/** SRAMIO — 简化 SRAM 时序接口 (面向 TCM128)
 *
 *  address  — 行地址 (已去掉行内偏移的低位)
 *  enable   — SRAM 使能 (读或写时均为1)
 *  isWrite  — 写使能 (1=写, 0=读)
 *  readData — 读数据输入 (Vec(byte)格式, 来自SRAM)
 *  writeData— 写数据输出 (Vec(byte)格式, 送往SRAM)
 *  mask     — 字节写掩码 (true=写入该字节) */
class SRAMIO(p: Parameters, sramAddressWidth: Int) extends Bundle {
  val address   = Output(UInt(sramAddressWidth.W))               // 行地址
  val enable    = Output(Bool())                                  // 使能 (1=访问中)
  val isWrite   = Output(Bool())                                  // 写使能 (1=写, 0=读)
  val readData  = Input(Vec(p.axi2DataBits / 8, UInt(8.W)))     // 读数据 (byte粒度, 如 32×8-bit)
  val writeData = Output(Vec(p.axi2DataBits / 8, UInt(8.W)))    // 写数据
  val mask      = Output(Vec(p.axi2DataBits / 8, Bool()))        // 字节掩码
}

// ============================================================================
// SRAM — Fabric 协议 ↔ SRAM 时序转换
//
// 数据流:
//   Fabric readDataAddr  ──→ address提取 + issueRead ──→ 1拍后 Fabric readData 返回
//   Fabric writeDataAddr ──→ address提取 + 直通 ──→ SRAM writeData/writeMask
//   SRAM readData        ──→ Cat(byte拼接) ──→ Fabric readData.bits
// ============================================================================
class SRAM(p: Parameters, sramAddressWidth: Int) extends Module {
  val io = IO(new Bundle{
    val fabric = Flipped(new FabricIO(p))                        // Fabric 协议输入 (来自 FabricArbiter)
    val sram   = new SRAMIO(p, sramAddressWidth)                 // SRAM 时序输出 (送往 TCM128)
  })

  // ---- 地址提取: 从 Fabric 地址取出行地址 ----
  // Fabric 地址是字节地址 (如 32-bit), SRAM 需要行地址 (如 9-bit for 512 rows)
  // lsb = log2Ceil(32bytes) = 5 → 去掉低5位 (行内偏移)
  // 保留 sramAddressWidth 位作为行地址
  // 读优先: MuxUpTo1H 中读地址的优先级高于写地址 (写=0, 读=1 按顺序)
  val lsb = log2Ceil(p.axi2DataBits / 8)                        // 行地址 LSB (256-bit→5, 表示32B/行)
  io.sram.address := MuxUpTo1H(0.U, Seq(  // 读优先: 同时有读写请求时, 地址使用读地址
    io.fabric.writeDataAddr.valid ->                             // 写优先? 不, MuxUpTo1H 按顺序
      io.fabric.writeDataAddr.bits(sramAddressWidth + lsb - 1, lsb),  //
    io.fabric.readDataAddr.valid  ->  
      io.fabric.readDataAddr.bits(sramAddressWidth + lsb - 1, lsb)
  ))

  // ===================================================================
  // 读路径: readIssued 寄存器实现 1 拍延迟
  //
  // Fabric 的 readData 需要在 readDataAddr 发出后 1 拍才有效。
  // 这是 SRAM 的固有读延迟: addr 在周期 N, rdata 在周期 N+1。
  //
  // 时序:
  //   周期 N:   readDataAddr.valid=1 → issueRead=1 → readIssued:=1
  //   周期 N+1: readIssued=1 → readData.valid=1 + readData.bits=SRAM数据
  // ===================================================================
  val readData   = Cat(io.sram.readData)                         // Vec(byte) → UInt (如 32×8-bit → 256-bit)
  val readIssued = RegInit(false.B)                              // 标记: 上周期发了读请求
  // issueRead: 仅当是纯读请求时发读 (写请求时发读会读到错误数据)
  val issueRead  = io.fabric.readDataAddr.valid && !io.fabric.writeDataAddr.valid
  readIssued := issueRead
  io.fabric.readData.bits  := Mux(readIssued, readData, 0.U)    // 1拍后返回 SRAM 读数据
  io.fabric.readData.valid := readIssued                          // 仅当上拍发了读请求时有效

  // ===================================================================
  // 写路径: 直通 (当前周期立即写入)
  //
  // SRAM 写没有延迟, 地址/数据/掩码在同一个周期送到 SRAM 即可。
  // writeResp 恒为 true (假设 SRAM 写永远成功, 不做错误检测)。
  // ===================================================================
  io.sram.enable  := (io.fabric.readDataAddr.valid || io.fabric.writeDataAddr.valid)
  io.sram.isWrite := io.fabric.writeDataAddr.valid               // 1=写, 0=读

  // Fabric 数据格式: UInt(256-bit) → SRAM 格式: Vec(32, UInt(8.W))
  val writeDataVec  = UIntToVec(io.fabric.writeDataBits, 8)      // 拆分为字节向量
  val writeMaskData = VecInit(io.fabric.writeDataStrb.asBools)   // strb → Vec(Bool) 掩码

  // 写时: 使用 Fabric 的写数据; 读时: 输出0 (读不需要写数据)
  io.sram.writeData := Mux(io.fabric.writeDataAddr.valid, writeDataVec,
                           0.U.asTypeOf(writeDataVec))

  // 掩码: 写时用 Fabric 的 strb (支持部分字节写入);
  //       读时用全1掩码 (读全部字节, 不需要掩码);
  //       readMaskData 用 RegInit 初始化为全 true
  val readMaskData  = RegInit(VecInit(Seq.fill(io.fabric.writeDataBits.getWidth / 8)(true.B)))
  val maskData      = Mux(io.fabric.writeDataAddr.valid, writeMaskData, readMaskData)
  io.sram.mask := maskData

  io.fabric.writeResp := true.B                                  // 写响应: 假设 SRAM 写总是成功
}
