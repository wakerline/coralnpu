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
// SramNx128.scala — 128-bit 宽 SRAM 模块 (BlackBox 封装)
//
// Sram_Nx128 是 ITCM/DTCM 底层 SRAM 的统一封装。它不直接对应物理 SRAM IP，
// 而是将任意深度的 128-bit 存储需求拆分到多个 SramBlock 上:
//
//   - blockSize 选择策略: 优先使用 2048 深度的 block, 用不完则 512, 最少 128
//   - 多模块时: 高位地址选片 (chip select) + MuxLookup 读数据 + RegNext 1拍延迟
//   - 单模块时: 直连, 无需选片逻辑
//
// 参数:
//   tcmEntries      — SRAM 深度 (行数)
//   globalBaseAddr  — 全局基地址 (传给 SramBlock 用于 Verilog $readmemh 初始化)
//
// 读延迟: 2 拍 (1拍 SRAM + 1拍 RegNext 选片稳定)
// ============================================================================


package coralnpu

import chisel3._
import chisel3.util._

/** Sram_Nx128 — 128-bit 宽 SRAM, 参数化深度
 *  选择最大可用 block 尺寸 (2048→512→128) 拼接多块 SramBlock */
class Sram_Nx128(tcmEntries: Int, globalBaseAddr: Int = 0) extends Module {
  override val desiredName = "SRAM_" + tcmEntries + "x128"
  val addrBits = log2Ceil(tcmEntries)                            // 总地址位宽
  val io = IO(new Bundle {
    val addr   = Input(UInt(addrBits.W))                         // 行地址
    val enable = Input(Bool())                                    // 使能
    val write  = Input(Bool())                                    // 写使能
    val wdata  = Input(UInt(128.W))                              // 写数据 (128-bit)
    val wmask  = Input(UInt(16.W))                               // 写字节掩码 (16-bit)
    val rdata  = Output(UInt(128.W))                             // 读数据
    val rvalid = Output(Bool())                                   // 读有效
  })

  // ---- ① 确定 block 拆分方案 ----
  // 选择最大可用 block 尺寸使模块数最少: 2048 → 512 → 128
  // 例: tcmEntries=4096 → blockSize=2048, nSramModules=2
  val blockSize =
    if (tcmEntries % 2048 == 0) 2048                             // 首选 2048 深度
    else if (tcmEntries % 512 == 0) 512                           // 其次 512
    else 128                                                       // 最少 128

  val nSramModules   = tcmEntries / blockSize                    // 需要多少个 SramBlock
  val sramAddrBits   = log2Ceil(blockSize)                       // 每个 block 的地址位宽
  val sramSelectBits = addrBits - sramAddrBits                   // 选片所需的高位地址位数
                                                                 // 例: addrBits=9, sramAddrBits=8 → 1bit 选片 (2个block)


  assert(sramSelectBits >= 0)  // 地址位宽必须足够支持至少一个 block

  // ---- ② 实例化 SramBlock (每个 block 关联一个 Sram.v 实例) ----
  // subModuleAddr: 每个 block 的全局基地址 = globalBaseAddr + (block序号 × block深度 × 16字节/行)
  val sramModules = (0 until nSramModules).map(x => {
    val subModuleAddr = globalBaseAddr + x * blockSize * 16  
    Module(new SramBlock(blockSize, subModuleAddr))              // BlackBox → verilog/Sram.v
  })

  // ---- ③ 连接输入 / 多路复用读输出 ----
  if (nSramModules == 1) {
    // 单模块: 直连, 无选片开销
    sramModules(0).io.clock  := clock
    sramModules(0).io.addr   := io.addr
    sramModules(0).io.enable := io.enable
    sramModules(0).io.write  := io.write
    sramModules(0).io.wdata  := io.wdata
    sramModules(0).io.wmask  := io.wmask
    io.rdata                 := sramModules(0).io.rdata  // 直接连接读数据
  } else {
    // 多模块: 高位地址选片, 低位地址送子模块
    // selectedSram = addr 的高 sramSelectBits 位 → 选择第几个 block
    val selectedSram = io.addr(addrBits - 1, sramAddrBits)  // 例: addrBits=9, sramAddrBits=8 → selectedSram = addr(8) 选第0/1个 block
    for (i <- 0 until nSramModules) {
      sramModules(i).io.clock  := clock
      sramModules(i).io.addr   := io.addr(sramAddrBits - 1, 0)  // 低位地址送子模块
      sramModules(i).io.enable := (selectedSram === i.U) && io.enable  // 仅选中 block 使能
      sramModules(i).io.write  := io.write
      sramModules(i).io.wdata  := io.wdata
      sramModules(i).io.wmask  := io.wmask
    }
    // 读数据: 延迟 1 拍选回 (SRAM 读延迟 + 选片信号稳定)
    // RegNext 选片信号, MuxLookup 多路复用读数据
    val selectedSramRead = RegNext(selectedSram, 0.U(sramSelectBits.W))// 选片信号寄存器, 初始值为 0 (默认选第一个 block)
    io.rdata := MuxLookup(selectedSramRead, 0.U(128.W))(         // 根据上一拍的选片信号决定读哪个 block
      (0 until nSramModules).map(i => i.U -> sramModules(i).io.rdata)  // 例: selectedSramRead=0 → 读第0个 block 的 rdata; selectedSramRead=1 → 读第1个 block 的 rdata
    )
  }
  // rvalid: enable 延迟 1 拍 (匹配 SRAM 的 1-cycle 读延迟)
  io.rvalid := RegNext(io.enable)
}
