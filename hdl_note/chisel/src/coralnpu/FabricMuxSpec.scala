// Copyright 2026 Google LLC
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
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

// ============================================================================
// FabricMuxSpec.scala — FabricMux 单元测试 (ChiselSim)
//
// 测试 FabricMux 的三大核心功能:
//   ① 写请求地址路由: 全局地址 → 端口匹配 + 地址偏移 (减去基地址)
//   ② 读请求地址路由 + 读响应延迟 (1拍后从正确端口取回)
//   ③ 反压转发: periBusy → fabricBusy
//   ④ 非法地址: 不在任何 region 内的地址 → 不路由到任何端口
//
// 测试用的 memoryRegions:
//   ITCM:       0x00000 ~ 0x01FFF
//   DTCM:       0x10000 ~ 0x17FFF
//   CSR/Peri:   0x30000 ~ 0x31FFF
// ============================================================================

class FabricMuxSpec extends AnyFreeSpec with ChiselSim {
  var p = new Parameters

  val memoryRegions = Seq(
    new MemoryRegion(0x0000,  0x2000, MemoryRegionType.IMEM),       // ITCM       0x00000~0x01FFF
    new MemoryRegion(0x10000, 0x8000, MemoryRegionType.DMEM),       // DTCM       0x10000~0x17FFF
    new MemoryRegion(0x30000, 0x2000, MemoryRegionType.Peripheral), // CSR/Peri   0x30000~0x31FFF
  )

  // ① 写请求: 验证地址路由 + 地址偏移 + 反压转发 + 非法地址
  "Writes" in {
    simulate(new FabricMux(p, memoryRegions)) { dut =>
      // 测试数据: 每个 region 一个地址
      // inputAddrs  — 全局地址
      // outputAddrs — 期望的偏移后地址 (全局地址 & ~基地址)
      val inputAddrs  = Seq(0x10,    0x10020, 0x30004)          // ITCM偏移0x10, DTCM偏移0x20, CSR偏移0x04
      val outputAddrs = Seq(0x10,    0x20,    0x4)               // ITCM→0x10, DTCM→0x20, CSR→0x04

      for (i <- 0 until memoryRegions.length) {
        // 发送写请求到第 i 个 region
        dut.io.source.readDataAddr.valid.poke(false.B)
        dut.io.source.writeDataAddr.valid.poke(true.B)            // 写请求有效
        dut.io.source.writeDataAddr.bits.poke(inputAddrs(i).U)
        dut.io.source.writeDataBits.poke((123 + i).U)             // 写数据: 123,124,125
        dut.io.source.writeDataStrb.poke((21 + i).U)              // strb: 21,22,23

        // 检查: 仅第 i 个端口收到写请求, 其余端口无请求
        for (j <- 0 until memoryRegions.length) {
          dut.io.ports(j).readDataAddr.valid.expect(0)            // 读端口应全无效
          if (i == j) {
            dut.io.ports(j).writeDataAddr.valid.expect(1)          // 命中端口写有效
            dut.io.ports(j).writeDataAddr.bits.expect(outputAddrs(i)) // 地址已偏移
            dut.io.ports(j).writeDataBits.expect(123 + i)          // 写数据传递正确
            dut.io.ports(j).writeDataStrb.expect(21 + i)           // strb 传递正确
          } else {
            dut.io.ports(j).writeDataAddr.valid.expect(0)          // 非命中端口无效
          }
        }

        // 反压测试: periBusy(i)=1 → fabricBusy=1
        dut.io.periBusy(i).poke(true.B)
        dut.io.fabricBusy.expect(1)                                // 反压应转发
        dut.io.periBusy(i).poke(false.B)
        dut.io.fabricBusy.expect(0)                                // 解除反压
      }

      // 非法地址测试: 0x90000 不在任何 region 内
      dut.io.source.writeDataAddr.bits.poke(0x90000.U)
      dut.io.source.writeDataBits.poke(1123.U)
      dut.io.source.writeDataStrb.poke(11.U)
      for (j <- 0 until memoryRegions.length) {
        dut.io.ports(j).readDataAddr.valid.expect(0)              // 所有端口均应无效
        dut.io.ports(j).writeDataAddr.valid.expect(0)
      }
    }
  }

  // ② 读请求: 验证地址路由 + 1拍延迟 + 反压 + 非法地址
  "Reads" in {
    simulate(new FabricMux(p, memoryRegions)) { dut =>
      val inputAddrs  = Seq(0x10, 0x10020, 0x30004)
      val outputAddrs = Seq(0x10, 0x20, 0x4)

      for (i <- 0 until memoryRegions.length) {
        // 发送读请求
        dut.io.source.readDataAddr.valid.poke(true.B)             // 读请求有效
        dut.io.source.readDataAddr.bits.poke(inputAddrs(i).U)
        dut.io.source.writeDataAddr.valid.poke(false.B)

        // 检查: 仅第 i 个端口收到读请求, 地址已偏移
        for (j <- 0 until memoryRegions.length) {
          dut.io.ports(j).writeDataAddr.valid.expect(0)           // 写端口应全无效
          if (i == j) {
            dut.io.ports(j).readDataAddr.valid.expect(1)           // 命中端口读有效
            dut.io.ports(j).readDataAddr.bits.expect(outputAddrs(i))
          } else {
            dut.io.ports(j).readDataAddr.valid.expect(0)
          }
        }

        // 反压测试
        dut.io.periBusy(i).poke(true.B)
        dut.io.fabricBusy.expect(1)
        dut.io.periBusy(i).poke(false.B)
        dut.io.fabricBusy.expect(0)

        // 推进 1 拍 — 模拟 SRAM 读延迟
        dut.clock.step()

        // 验证读响应: 1 拍后从对应端口取回正确数据
        for (j <- 0 until memoryRegions.length) {
          dut.io.ports(j).readData.valid.poke(false.B)            // 非命中端口数据无效
          dut.io.ports(j).readData.bits.poke((800 + j).U)         // 各端口不同数据 (800,801,802)
        }
        dut.io.ports(i).readData.valid.poke(true.B)               // 仅命中端口数据有效
        dut.io.source.readData.valid.expect(1)                     // 读响应有效
        dut.io.source.readData.bits.expect(800 + i)               // 数据来自正确的端口
      }

      // 非法地址: 0x90000 → 所有端口无请求
      dut.io.source.readDataAddr.valid.poke(true.B)
      dut.io.source.readDataAddr.bits.poke(0x90000.U)
      dut.io.source.writeDataAddr.valid.poke(false.B)
      for (i <- 0 until memoryRegions.length) {
        dut.io.ports(i).readDataAddr.valid.expect(0)
      }
    }
  }
}
