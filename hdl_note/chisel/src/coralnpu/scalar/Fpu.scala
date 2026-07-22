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
// Fpu.scala — 标量浮点单元 (FPU: RV32F/D + Zfbfmin BF16)
// 通过 FRegfile 访问浮点寄存器, 与 FloatCore 交互执行 FMA/Div/Sqrt
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common.Fp32
import common.Fma
import common.FmaCmd

object FpuOptype extends ChiselEnum {
  val FpuAdd = Value                                    // a + c, 通过 b=1 转成 FMA
  val FpuSub = Value                                    // a - c, 通过 b=1 且 c 取反
  val FpuMul = Value                                    // a * b, 通过 c=0 转成 FMA
  val FpuFma = Value                                    // a * b + c
  val FpuFms = Value                                    // a * b - c
  val FpuFnma = Value                                   // -(a * b) + c
  val FpuFnms = Value                                   // -(a * b) - c
}

// 送入 FPU 的统一浮点命令。
// 该模块内部只实例化 FMA datapath, 所以 ADD/SUB/MUL 都会被改写成等价 FMA 形式。
class FpuCmd extends Bundle {
  val optype = FpuOptype()                              // 运算类型
  val ina = new Fp32                                    // 操作数 a
  val inb = new Fp32                                    // 操作数 b
  val inc = new Fp32                                    // 操作数 c
  val waddr = UInt(5.W)                                 // 目的浮点寄存器地址
}

object FpuCmd {
  def ToFmaCmd(fpuCmd: FpuCmd): WithAddr[FmaCmd] = {
    // FNMA/FNMS 对乘积项取负, 等价于将 a 取反后送入 FMA。
    val invert_ab = (fpuCmd.optype === FpuOptype.FpuFnma) ||
                    (fpuCmd.optype === FpuOptype.FpuFnms)
    // SUB/FMS/FNMS 对加数 c 取负。
    val invert_c = (fpuCmd.optype === FpuOptype.FpuSub) ||
                   (fpuCmd.optype === FpuOptype.FpuFms) ||
                   (fpuCmd.optype === FpuOptype.FpuFnms)

    val fmaCmd = Wire(WithAddr(5, new FmaCmd))          // 带写回地址的 FMA 命令
    fmaCmd.bits.ina := Mux(invert_ab, fpuCmd.ina.negate(), fpuCmd.ina) // 乘积符号修正
    fmaCmd.bits.inb := Mux((fpuCmd.optype === FpuOptype.FpuAdd) ||
                           (fpuCmd.optype === FpuOptype.FpuSub),
                           // ADD/SUB 通过 b=1.0 实现 a*1 +/- c。
                           Fp32(false.B, 127.U(8.W), 0.U(23.W)),
                           fpuCmd.inb)
    fmaCmd.bits.inc := Mux((fpuCmd.optype === FpuOptype.FpuMul),
                           // MUL 通过 c=+0.0 实现 a*b+0。
                           Fp32.fromWord(0.U(32.W)),
                           Mux(invert_c, fpuCmd.inc.negate(), fpuCmd.inc))
    fmaCmd.addr := fpuCmd.waddr                         // 保留写回地址穿过流水线
    fmaCmd
  }
}

class Fpu extends Module {
  val io = IO(new Bundle {
    val cmd = Flipped(Decoupled(new FpuCmd))            // 输入浮点命令
    val output = Decoupled(WithAddr(5, new Fp32))       // 输出结果 + 目的寄存器地址
  })

  // ---- FMA 三段流水 ----
  // Decoupled.map 保持 ready/valid 握手, LiftAddr 保留 waddr 随数据穿过每级流水。
  val fmaCmd = io.cmd.map(FpuCmd.ToFmaCmd)              // FpuCmd 归一化为 FmaCmd
  val state1 = fmaCmd.map(LiftAddr(5, Fma.FmaStage1))   // Stage1: FMA 前处理/部分积准备
  val state2 = Queue(state1, 1, true).map(LiftAddr(5, Fma.FmaStage2)) // Stage2: 中间流水寄存
  io.output <> Queue(state2, 1, true).map(LiftAddr(5, Fma.FmaStage3)) // Stage3: 舍入/输出
}
