// ============================================================================
// IBus2Axi.scala — 取指总线 (IBus) → AXI4 只读 Master 协议转换
//
// 简化的单地址单数据缓冲状态机:
//   - saddrReg/sdata/sresp/sdataValid 缓存最近 AXI 读结果
//   - addrMatch: 新地址==旧地址 → 直接返回缓存数据 (避免重复 AXI 读)
//   - 地址改变 → 发起新 AXI 读事务 (addr.fire → sraddrActive)
//   - 检测 AXI RESP ≠ 0 时报告取指故障
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

import bus.AxiMasterReadIO

object IBus2Axi {
  def apply(p: Parameters, id: Int = 0): IBus2Axi = {
    return Module(new IBus2Axi(p, id))
  }
}

/** IBus2Axi — 取指总线→AXI4 只读 Master 转换。
 *  简化的单地址缓冲状态机: 缓存最近一次 AXI 读结果, 地址不变时直接返回。 */
class IBus2Axi(p: Parameters, id: Int = 0) extends Module {
  val io = IO(new Bundle {
    val ibus = Flipped(new IBusIO(p))                              // 取指总线输入
    val axi  = new AxiMasterReadIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)
  })
  io.axi.defaults()                                                // AXI 未使用信号取安全默认值

  val linebit = log2Ceil(p.lsuDataBits / 8)                       // 缓存行位宽 (5 → 32B行)

  // ---- 状态寄存器: 缓存最近一次 AXI 读事务 ----
  val sraddrActive = RegInit(false.B)                              // AXI 读地址已发, 等待数据
  val saddrReg     = RegInit(0.U(p.axi2AddrBits.W))               // 当前缓存行保存的地址 (行对齐)
  val sdata         = RegInit(0.U(p.axi2DataBits.W))              // 缓存的读数据
  val sresp         = RegInit(0.U(2.W))                            // 缓存的 AXI 响应码
  val sdataValid    = RegInit(false.B)                             // 缓存数据有效

  // 新请求的缓存行地址 (行对齐)
  val saddr = Cat(io.ibus.addr(31, linebit), 0.U(linebit.W))    //当前 IBus 请求地址所在的行地址
  val addrMatch = saddr === saddrReg                               // 地址命中缓存行?

  // IBus 握手: 数据已就绪 (AXI刚响应 或 有缓存) 且 地址匹配
  io.ibus.ready := (io.axi.data.valid && sraddrActive || sdataValid) && addrMatch
  io.ibus.rdata := sdata                                           // 取指单元期望 ready 后下一拍数据有效

  // ---- AXI 读地址通道 ----
  // 可以发起新取指: 不在等待数据 且 (无有效缓存 或 地址不匹配)
  val canStartNext = !sraddrActive && (!sdataValid || !addrMatch)
  io.axi.addr.valid := io.ibus.valid && canStartNext
  io.axi.addr.bits.addr := saddr                                   // 行对齐地址
  io.axi.addr.bits.id := id.U                                      // 事务 ID (区分 ibus=1 / ebus=0)
  io.axi.addr.bits.prot := 2.U

  // ---- 状态机更新 ----
  // sraddrActive: data.fire→清除, addr.fire→设置
  //   Idle
  //   ├── addr.fire → Waiting AXI data
  // Waiting
  //   └── data.fire → Idle
  sraddrActive := Mux(io.axi.data.fire, false.B,
                   Mux(io.axi.addr.fire, true.B, sraddrActive))
  // sdata/sresp: AXI 数据到达时更新
  sdata  := Mux(io.axi.data.fire, io.axi.data.bits.data, sdata)
  sresp  := Mux(io.axi.data.fire, io.axi.data.bits.resp, sresp)
  // sdataValid: data.fire且ibus未消费→保持; ibus消费或新addr发出→清除
  sdataValid := Mux(io.axi.data.fire, !io.ibus.ready,  // 数据到达且ibus未消费时保持有效
                 Mux((io.ibus.ready && io.ibus.valid) || io.axi.addr.fire,  //  ibus消费或新地址发出时无效
                   false.B, sdataValid))
  saddrReg := Mux(io.axi.addr.fire, io.axi.addr.bits.addr, saddrReg)

  assert(!io.axi.data.fire || sraddrActive)                        // 数据到达时必在等待

  io.axi.data.ready := true.B                                      // 始终准备接收 AXI 读数据

  // ---- 故障报告: AXI RESP ≠ 0 (非 OKAY) 时 ----
  io.ibus.fault.valid := io.ibus.ready &&
      (Mux(io.axi.data.valid, io.axi.data.bits.resp, sresp) =/= 0.U)
  io.ibus.fault.bits.write := false.B                              // 取指总是读
  io.ibus.fault.bits.addr := saddrReg
  io.ibus.fault.bits.epc := io.ibus.addr
}
