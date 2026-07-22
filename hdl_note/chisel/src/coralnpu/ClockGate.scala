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
// ClockGate.scala — 时钟门控 Chisel BlackBox 封装
// 关联 verilog/ClockGate.sv: 基于锁存器的无毛刺时钟门控, te=测试模式旁路
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._

/** 时钟门控 BlackBox — clk_i + enable → clk_o (enable=1通,0断) */
class ClockGate extends BlackBox with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk_i  = Input(Clock())
    val enable = Input(Bool())  // '1' passthrough, '0' disable.
    val te     = Input(Bool())
    val clk_o  = Output(Clock())
  })
  addResource("ClockGate.sv")
}
