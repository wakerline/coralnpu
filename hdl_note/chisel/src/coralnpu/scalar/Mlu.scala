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
// Mlu.scala — 乘法单元 (RV32M: MUL/MULH/MULHSU/MULHU)
// 多周期流水线, 1 个 MLU 供 4 lane 共享
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import _root_.circt.stage.{ChiselStage,FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

object Mlu {
  def apply(p: Parameters): Mlu = {
    return Module(new Mlu(p))
  }
}

object MluOp extends ChiselEnum {
  val MUL = Value                                      // 取乘积低 32 位: rs1 * rs2
  val MULH = Value                                     // 有符号 x 有符号, 取高 32 位
  val MULHSU = Value                                   // 有符号 x 无符号, 取高 32 位
  val MULHU = Value                                    // 无符号 x 无符号, 取高 32 位
  val Entries = Value                                  // 枚举数量占位
}

// Dispatch 送入 MLU 的乘法命令。
class MluCmd extends Bundle {
  val addr = UInt(5.W)                                 // 目的寄存器 rd
  val op = MluOp()                                     // 乘法操作类型
}

// Stage1: 记录仲裁后的指令信息和被选中的 lane。
class MluStage1(p: Parameters) extends Bundle {
  val rd = UInt(5.W)                                   // 目的寄存器
  val op = MluOp()                                     // 操作类型
  val sel = UInt(p.instructionLanes.W)                 // one-hot lane 选择
}

// Stage2: 保存乘法结果, Stage3 再选择高/低 32 位写回。
class MluStage2(p: Parameters) extends Bundle {
  val rd = UInt(5.W)                                   // 目的寄存器
  val op = MluOp()                                     // 操作类型, 用于决定取高位还是低位
  val prod = SInt(66.W)                                // 扩展后的 33x33 乘积
}

class Mlu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Decode cycle: 每个 instruction lane 都可请求共享 MLU。
    val req = Vec(p.instructionLanes, Flipped(Decoupled(new MluCmd))) // lane 输入请求

    // Execute cycle: 从 Regfile 读源操作数, 最终写回一个 rd。
    val rs1 = Vec(p.instructionLanes, Flipped(new RegfileReadDataIO)) // rs1 读数据
    val rs2 = Vec(p.instructionLanes, Flipped(new RegfileReadDataIO)) // rs2 读数据
    val rd  = Decoupled(Flipped(new RegfileWriteDataIO))              // 乘法结果写回端口
  })

  // ---- Stage 1: lane 仲裁 + 命令锁存 ----
  // p.instructionLanes 个 lane 共享 1 个 MLU, Arbiter 每次选择一个有效请求进入流水线。
  // lane0 > lane1 > lane2 > lane3
  val arb = Module(new Arbiter(new MluCmd, p.instructionLanes)) // 多 lane 请求仲裁器
  arb.io.in <> io.req                                           // req ready/valid 直接接入仲裁器

  val stage1 = Wire(Decoupled(new MluStage1(p)))        // Stage1 输出
  stage1.valid := arb.io.out.valid                      // 仲裁器输出有效即 Stage1 有效
  stage1.bits.rd := arb.io.out.bits.addr                // 保存 rd
  stage1.bits.op := arb.io.out.bits.op                  // 保存 op
  stage1.bits.sel := UIntToOH(arb.io.chosen)            // 保存被选 lane 的 one-hot 编码
  arb.io.out.ready := stage1.ready                      // 下游可接收才消耗仲裁结果
  val stage2Input = Queue(stage1, 1, true)              // 1 深度流水队列, pipe=true 允许直通

  // ---- Stage 2: 选择源操作数 + 执行乘法 ----
  val valid2in = stage2Input.valid                      // Stage2 输入有效
  val op2in = stage2Input.bits.op                       // Stage2 操作类型
  val addr2in = stage2Input.bits.rd                     // Stage2 目的寄存器
  val sel2in = stage2Input.bits.sel                     // Stage2 被选 lane

  // 根据 sel2in 从对应 lane 的 Regfile 读口取 rs1/rs2。
  // MuxOR 对未选 lane 置零, reduce OR 后得到唯一被选 lane 的数据。
  val rs1 = (0 until p.instructionLanes).map(x => MuxOR(valid2in & sel2in(x), io.rs1(x).data)).reduce(_ | _)
  val rs2 = (0 until p.instructionLanes).map(x => MuxOR(valid2in & sel2in(x), io.rs2(x).data)).reduce(_ | _)

  // MULH/MULHSU/MULHU 的差异只在符号扩展; MUL 低 32 位对符号不敏感。
  val rs2signed = op2in.isOneOf(MluOp.MULH)             // rs2 只有 MULH 需要符号扩展
  val rs1signed = op2in.isOneOf(MluOp.MULHSU) || rs2signed // rs1 在 MULH/MULHSU 需要符号扩展
  val rs1s = Cat(rs1signed && rs1(31), rs1).asSInt      // 扩展成 33 位有符号数
  val rs2s = Cat(rs2signed && rs2(31), rs2).asSInt      // 扩展成 33 位有符号数
  val prod = rs1s * rs2s                                // 33x33 -> 66 位乘积
  assert(prod.getWidth == 66)                           // 确认乘积位宽符合预期

  val stage2 = Wire(Decoupled(new MluStage2(p)))        // Stage2 输出
  stage2.valid := valid2in
  stage2.bits.rd := addr2in                             // 继续携带 rd
  stage2.bits.op := op2in                               // 继续携带 op
  stage2.bits.prod := prod                              // 保存完整66乘积
  stage2Input.ready := stage2.ready                     // 乘法结果可进入下游才接收输入

  val stage3Input = Queue(stage2, 1, true)              // Stage2→Stage3 流水队列
  val op3in = stage3Input.bits.op                       // Stage3 操作类型
  val prod3in = stage3Input.bits.prod                   // Stage3 完整乘积

  // To be guarded by stage3Input.valid.
  // MUL 取低 32 位; 其它 MULH 类指令取高 32 位。
  val mul = Mux(
      op3in === MluOp.MUL,
      prod3in(31, 0),  // MUL
      prod3in(63,32)   // MULH, MULHSU, MULHU
  )

  // ---- Stage 3: 写回结果 ----
  // Multiplier has a registered output: 下游 rd ready 反压 Stage3 队列。
  stage3Input.ready := io.rd.ready

  io.rd.valid     := stage3Input.valid                  // 写回有效
  io.rd.bits.addr := stage3Input.bits.rd                // 写回 rd
  io.rd.bits.data := mul                                // 写回乘法结果

  // ---- 基本一致性检查 ----
  // 被选中的 lane 进入 Stage2 时, 对应 rs1/rs2 必须已经有效。
  for (i <- 0 until p.instructionLanes) {
    assert(!(valid2in && sel2in(i) && !io.rs1(i).valid))
    assert(!(valid2in && sel2in(i) && !io.rs2(i).valid))
  }
}

@nowarn
object EmitMlu extends App {
  val p = new Parameters
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new Mlu(p))) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
