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
// FabricArbiterSpec.scala — FabricArbiter 单元测试 (ChiselSim)
//
// 测试 FabricArbiter 的核心功能:
//   ① 固定优先级仲裁: source(0) > source(1) > ... → 输出选第一个有效的源
//   ② 反压: fabricBusy(i) 在更高优先级源有效时为 1
//   ③ 响应广播: 读数据/写响应同时发送给所有源
//   ④ 读写独立仲裁: 读请求和写请求被同等对待 (只判断是否有效)
//   ⑤ 全无效: 所有源无效时输出也为无效
//
// 测试场景命名: "源0状态 - 源1状态"
//   例: "CoralNPU Read - AXI Slave Any" = 源0=读, 源1=任意(读/写/无)
// ============================================================================

class FabricArbiterSpec extends AnyFreeSpec with ChiselSim {
  var p = new Parameters

  // ---- 场景①: 源0=读 (固定), 源1=无/读/写 (遍历) ----
  // 验证: 源0优先 → 无论源1发什么, 输出都是源0的读请求
  //        fabricBusy(1) 始终=1 (被源0阻塞)
  "CoralNPU Read - AXI Slave Any" in {
    simulate(new FabricArbiter(p)) { dut =>
      // 源0: 读请求 (固定, 最高优先)
      dut.io.source(0).readDataAddr.valid.poke(true.B)
      dut.io.source(0).readDataAddr.bits.poke(0x8080.U)
      dut.io.source(0).writeDataAddr.valid.poke(false.B)

      // 源1: 预设数据 (valid 在循环中变化)
      dut.io.source(1).readDataAddr.bits.poke(0x4080.U)
      dut.io.source(1).writeDataAddr.bits.poke(0x4080.U)
      dut.io.source(1).writeDataBits.poke(0x5080.U)
      dut.io.source(1).writeDataStrb.poke(0x1.U)

      for (i <- 0 until 3) {
        if (i == 0) {                                              // 源1 = 无请求
          dut.io.source(1).readDataAddr.valid.poke(false.B)
          dut.io.source(1).writeDataAddr.valid.poke(false.B)
        } else if (i == 1) {                                       // 源1 = 读请求
          dut.io.source(1).readDataAddr.valid.poke(true.B)
          dut.io.source(1).writeDataAddr.valid.poke(false.B)
        } else {                                                   // 源1 = 写请求
          dut.io.source(1).readDataAddr.valid.poke(false.B)
          dut.io.source(1).writeDataAddr.valid.poke(true.B)
        }

        // 验证: 输出始终是源0的读请求 (源1被屏蔽)
        dut.io.fabricBusy(1).expect(1)                             // 源1被阻塞 (源0有效)
        dut.io.port.readDataAddr.valid.expect(1)                   // 读请求通过
        dut.io.port.writeDataAddr.valid.expect(0)                  // 写请求不应出现
        dut.io.port.readDataAddr.bits.expect(0x8080)              // 地址=源0的地址

        dut.clock.step()                                           // 等待读响应

        // 验证: 读响应广播回源0
        dut.io.port.readData.valid.poke(true.B)
        dut.io.port.readData.bits.poke(300 + i)                   // 每次不同数据
        dut.io.source(0).readData.valid.expect(1)                  // 源0收到响应
        dut.io.source(0).readData.bits.expect(300 + i)             // 数据正确
      }
    }
  }

  // ---- 场景②: 源0=写 (固定), 源1=无/读/写 (遍历) ----
  // 验证: 源0优先 → 输出始终是源0的写请求
  "CoralNPU Write - AXI Slave Any" in {
    simulate(new FabricArbiter(p)) { dut =>
      // 源0: 写请求 (固定)
      dut.io.source(0).readDataAddr.valid.poke(false.B)
      dut.io.source(0).writeDataAddr.valid.poke(true.B)
      dut.io.source(0).writeDataAddr.bits.poke(0x80B0.U)
      dut.io.source(0).writeDataBits.poke(0x50B0.U)
      dut.io.source(0).writeDataStrb.poke(0xF.U)

      // 源1: 预设数据
      dut.io.source(1).readDataAddr.bits.poke(0x40B0.U)
      dut.io.source(1).writeDataAddr.bits.poke(0x40B0.U)
      dut.io.source(1).writeDataBits.poke(0x60B0.U)
      dut.io.source(1).writeDataStrb.poke(0x12.U)

      for (i <- 0 until 3) {
        if (i == 0) { dut.io.source(1).readDataAddr.valid.poke(false.B); dut.io.source(1).writeDataAddr.valid.poke(false.B) }
        else if (i == 1) { dut.io.source(1).readDataAddr.valid.poke(true.B); dut.io.source(1).writeDataAddr.valid.poke(false.B) }
        else { dut.io.source(1).readDataAddr.valid.poke(false.B); dut.io.source(1).writeDataAddr.valid.poke(true.B) }

        // 验证: 输出始终是源0的写请求
        dut.io.fabricBusy(1).expect(1)                             // 源1被阻塞
        dut.io.port.readDataAddr.valid.expect(0)
        dut.io.port.writeDataAddr.valid.expect(1)                  // 写请求通过
        dut.io.port.writeDataAddr.bits.expect(0x80B0)             // 地址=源0
        dut.io.port.writeDataBits.expect(0x50B0)                  // 写数据=源0
        dut.io.port.writeDataStrb.expect(0xF)                     // strb=源0
      }
    }
  }

  // ---- 场景③: 源0=无, 源1=读 ----
  // 验证: 源0无效时, 源1的请求可以通过; fabricBusy(1)=0
  "CoralNPU None - AXI Slave Read" in {
    simulate(new FabricArbiter(p)) { dut =>
      dut.io.source(0).readDataAddr.valid.poke(false.B)            // 源0: 无请求
      dut.io.source(0).writeDataAddr.valid.poke(false.B)

      dut.io.source(1).readDataAddr.valid.poke(true.B)             // 源1: 读请求
      dut.io.source(1).readDataAddr.bits.poke(0x40B0.U)
      dut.io.source(1).writeDataAddr.valid.poke(false.B)

      dut.io.fabricBusy(1).expect(0)                               // 源1不被阻塞 (无更高优先)
      dut.io.port.readDataAddr.valid.expect(1)                     // 读请求通过
      dut.io.port.readDataAddr.bits.expect(0x40B0)
      dut.io.port.writeDataAddr.valid.expect(0)

      dut.clock.step()                                             // 等读响应

      dut.io.port.readData.valid.poke(true.B)
      dut.io.port.readData.bits.poke(777)
      dut.io.source(1).readData.valid.expect(1)                    // 响应回源1
      dut.io.source(1).readData.bits.expect(777)
    }
  }

  // ---- 场景④: 源0=无, 源1=写 ----
  "CoralNPU None - AXI Slave Write" in {
    simulate(new FabricArbiter(p)) { dut =>
      dut.io.source(0).readDataAddr.valid.poke(false.B)
      dut.io.source(0).writeDataAddr.valid.poke(false.B)

      dut.io.source(1).readDataAddr.valid.poke(false.B)
      dut.io.source(1).writeDataAddr.valid.poke(true.B)            // 源1: 写请求
      dut.io.source(1).writeDataAddr.bits.poke(0xB0B0.U)
      dut.io.source(1).writeDataBits.poke(0xA0B0.U)
      dut.io.source(1).writeDataStrb.poke(0xA.U)

      dut.io.fabricBusy(1).expect(0)                               // 源1不被阻塞
      dut.io.port.readDataAddr.valid.expect(0)
      dut.io.port.writeDataAddr.valid.expect(1)
      dut.io.port.writeDataAddr.bits.expect(0xB0B0)
    }
  }

  // ---- 场景⑤: 两个源都无效 ----
  "Both None" in {
    simulate(new FabricArbiter(p)) { dut =>
      dut.io.source(0).readDataAddr.valid.poke(false.B)
      dut.io.source(0).writeDataAddr.valid.poke(false.B)
      dut.io.source(1).readDataAddr.valid.poke(false.B)
      dut.io.source(1).writeDataAddr.valid.poke(false.B)

      dut.io.fabricBusy(1).expect(0)                               // 不反压
      dut.io.port.readDataAddr.valid.expect(0)                     // 输出无效
      dut.io.port.writeDataAddr.valid.expect(0)
    }
  }

  // ---- 场景⑥: 3端口优先级测试 (完整验证) ----
  // 逐步增加活跃源, 验证优先级链: source(0) > source(1) > source(2)
  "3-Port Arbiter Priority" in {
    simulate(new FabricArbiter(p, n = 3)) { dut =>
      // Case 0: 全无效 → 输出无效, 所有 busy=0
      for (i <- 0 until 3) {
        dut.io.source(i).readDataAddr.valid.poke(false.B)
        dut.io.source(i).writeDataAddr.valid.poke(false.B)
      }
      dut.io.fabricBusy(0).expect(0)
      dut.io.fabricBusy(1).expect(0)
      dut.io.fabricBusy(2).expect(0)
      dut.io.port.readDataAddr.valid.expect(0)

      // Case 1: 仅源2有效 (最低优先) → 源2独占, 所有 busy=0
      dut.io.source(2).readDataAddr.valid.poke(true.B)
      dut.io.source(2).readDataAddr.bits.poke(0x2000.U)
      dut.io.fabricBusy(0).expect(0)
      dut.io.fabricBusy(1).expect(0)
      dut.io.fabricBusy(2).expect(0)                               // 没有比它更高的活跃源
      dut.io.port.readDataAddr.valid.expect(1)
      dut.io.port.readDataAddr.bits.expect(0x2000.U)              // 源2的地址

      // Case 2: 源1和源2 → 源1胜 (高优先), 源2被阻塞
      dut.io.source(1).readDataAddr.valid.poke(true.B)
      dut.io.source(1).readDataAddr.bits.poke(0x1000.U)
      dut.io.fabricBusy(0).expect(0)
      dut.io.fabricBusy(1).expect(0)                               // 没有比源1更高的
      dut.io.fabricBusy(2).expect(1)                               // 源2被源1阻塞!
      dut.io.port.readDataAddr.valid.expect(1)
      dut.io.port.readDataAddr.bits.expect(0x1000.U)              // 源1的地址 (非源2!)

      // Case 3: 全部三个源 → 源0胜 (最高优先), 源1/2被阻塞
      dut.io.source(0).readDataAddr.valid.poke(true.B)
      dut.io.source(0).readDataAddr.bits.poke(0x0000.U)
      dut.io.fabricBusy(0).expect(0)                               // 最高优先, 永不阻塞
      dut.io.fabricBusy(1).expect(1)                               // 源1被源0阻塞
      dut.io.fabricBusy(2).expect(1)                               // 源2被源0阻塞
      dut.io.port.readDataAddr.valid.expect(1)
      dut.io.port.readDataAddr.bits.expect(0x0000.U)              // 源0的地址

      // 响应广播: 所有源都看到相同的读数据
      dut.clock.step()
      dut.io.port.readData.valid.poke(true.B)
      dut.io.port.readData.bits.poke(0xDEADBEEFL.U)
      dut.io.source(0).readData.valid.expect(1)                    // 源0收到
      dut.io.source(0).readData.bits.expect(0xDEADBEEFL.U)
      dut.io.source(1).readData.valid.expect(1)                    // 源1也收到 (广播)
      dut.io.source(1).readData.bits.expect(0xDEADBEEFL.U)
      dut.io.source(2).readData.valid.expect(1)                    // 源2也收到 (广播)
      dut.io.source(2).readData.bits.expect(0xDEADBEEFL.U)
    }
  }
}
