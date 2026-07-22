// ============================================================================
// TCM.scala — 紧耦合内存 (Tightly Coupled Memory) 的 Chisel 封装
//
// TCM128: 128-bit 宽 TCM，封装 Sram_Nx128 BlackBox 供 ITCM/DTCM 使用
//   tcmEntries = tcmSizeBytes / 16 (每行 16 字节)
//   tcmSubEntries = 128 / tcmSubEntryWidth (默认 8-bit → 16 个子条目)
//   通过 Cat/UIntToVec 实现 Vec↔UInt 转换
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
import common._

/** TCM128 — 128-bit 宽紧耦合内存 (ITCM/DTCM 的底层存储模块)
 *  @param tcmSizeBytes     总容量 (字节)
 *  @param tcmSubEntryWidth 子条目位宽 (默认 8 = 字节粒度)
 *  @param globalBaseAddr   全局基地址 (地址译码用) */
class TCM128(tcmSizeBytes: Int, tcmSubEntryWidth: Int, globalBaseAddr: Int = 0) extends Module {
  val tcmWidth      = 128                                        // TCM 数据位宽固定 128-bit
  val tcmEntries    = tcmSizeBytes / (tcmWidth / 8)             // SRAM 行数 = 总字节 / 16
  val tcmSubEntries = tcmWidth / tcmSubEntryWidth               // 每行子条目数 = 128/8 = 16

  val io = IO(new Bundle {
    val addr   = Input(UInt(log2Ceil(tcmEntries).W))             // 行地址 (如 512 行 → 9-bit)
    val enable = Input(Bool())                                    // 使能
    val write  = Input(Bool())                                    // 写使能
    val wdata  = Input(Vec(tcmSubEntries, UInt(tcmSubEntryWidth.W))) // 写数据 (子条目向量)
    val wmask  = Input(Vec(tcmSubEntries, Bool()))               // 写掩码 (子条目级)
    val rdata  = Output(Vec(tcmSubEntries, UInt(tcmSubEntryWidth.W)))// 读数据
  })

  // 实例化底层 128-bit SRAM BlackBox
  val sram = Module(new Sram_Nx128(tcmEntries, globalBaseAddr)) //
  sram.io.addr   := io.addr                                     // 行地址直连
  sram.io.enable := io.enable                                    // 使能直连
  sram.io.write  := Cat(io.write)                                // Bool → UInt(1.W)
  // Cat(io.wdata.reverse): Vec 高位在前 → 拼接为 128-bit UInt
  sram.io.wdata  := Cat(io.wdata.reverse)
  sram.io.wmask  := Cat(io.wmask.reverse)                        // Vec → 16-bit 掩码
  // UIntToVec: 128-bit UInt → 拆分为 Vec(tcmSubEntryWidth 宽)
  io.rdata := UIntToVec(sram.io.rdata, tcmSubEntryWidth).reverse  //
}
