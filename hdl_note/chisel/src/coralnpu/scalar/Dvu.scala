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
// Dvu.scala — 除法单元 (RV32M: DIV/DIVU/REM/REMU)
// 多周期流水线, 仅在 lane0 使用 (lane1~3 恒为 not ready)
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import _root_.circt.stage.ChiselStage

object Dvu {
  def apply(p: Parameters): Dvu = {
    return Module(new Dvu(p))
  }
}

object DvuOp extends ChiselEnum {
  val DIV  = Value                                      // 有符号除法, 写回商
  val DIVU = Value                                      // 无符号除法, 写回商
  val REM  = Value                                      // 有符号除法, 写回余数
  val REMU = Value                                      // 无符号除法, 写回余数
}

// Dispatch 送入 DVU 的除法/取余命令。
class DvuCmd extends Bundle {
  val addr = UInt(5.W)                                  // 目的寄存器 rd
  val op = DvuOp()                                      // DIV/DIVU/REM/REMU 操作类型
}

class Dvu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Decode cycle: Dispatch 发来的除法请求。
    val req = Flipped(Decoupled(new DvuCmd))            // DVU 一次只接收一个请求

    // Execute cycle: 读取源操作数, 多周期迭代后写回 rd。
    val rs1 = Flipped(new RegfileReadDataIO)            // 被除数
    val rs2 = Flipped(new RegfileReadDataIO)            // 除数
    val rd  = Decoupled(new RegfileWriteDataIO)         // 商/余数写回端口
  })

  // This implemention differs to common::idiv by supporting early termination,
  // and only performs one bit per cycle.

  // 单步无符号恢复除法:
  //   将 prvDivide 的最高 bit 移入 remainder, 尝试减 denom;
  //   若结果非负, quotient 低位补 1, remainder 更新为减法结果;
  //   若结果为负, quotient 低位补 0, remainder 保持移位后的值。
  def Divide(prvDivide: UInt, prvRemain: UInt, denom: UInt): (UInt, UInt) = {
    val shfRemain = Cat(prvRemain(30,0), prvDivide(31)) // remainder 左移并带入 quotient 最高位
    val subtract = shfRemain -& denom                   // 33 位减法, 最高位表示是否借位
    assert(subtract.getWidth == 33)                     // 确认减法保留 borrow/sign 位
    val divDivide = Wire(UInt(32.W))                    // 下一拍 quotient/divide 寄存器
    val divRemain = Wire(UInt(32.W))                    // 下一拍 remainder 寄存器

    when (!subtract(32)) {
      divDivide := Cat(prvDivide(30,0), 1.U(1.W))       // 减法成功, 当前商 bit = 1
      divRemain := subtract(31,0)                       // remainder = remainder - denom
    } .otherwise {
      divDivide := Cat(prvDivide(30,0), 0.U(1.W))       // 减法失败, 当前商 bit = 0
      divRemain := shfRemain                            // remainder 恢复为减法前的值
    }

    (divDivide, divRemain)
  }
  // Idle
  //   ↓ req.fire
  // Active / Init
  //   ↓
  // Compute Loop
  //   ↓ count reaches 32
  // Result Valid
  //   ↓ rd.fire
  // Idle
  // ---- 控制状态 ----
  val active = RegInit(false.B)                         // 当前是否有除法请求处于前半段/迭代准备中
  val compute = RegInit(false.B)                        // active 延迟一拍后真正开始迭代

  val addr1    = RegInit(0.U(5.W))                      // 请求阶段保存 rd
  val signed1  = RegInit(false.B)                       // 请求是否为有符号操作
  val divide1  = RegInit(false.B)                       // 请求是否写回商(DIV/DIVU)
  val addr2    = RegInit(0.U(5.W))                      // 计算阶段保存 rd
  val signed2d = RegInit(false.B)                       // 商结果是否需要取负
  val signed2r = RegInit(false.B)                       // 余数结果是否需要取负
  val divide2  = RegInit(false.B)                       // 最终选择商还是余数

  val count  = RegInit(0.U(6.W))                        // 迭代计数; count(5)=1 表示结果有效

  val divide = RegInit(0.U(32.W))                       // 迭代中的 quotient/dividend 移位寄存器
  val remain = RegInit(0.U(32.W))                       // 迭代中的 remainder
  val denom  = RegInit(0.U(32.W))                       // 取绝对值后的除数

  val divByZero = io.rs2.data === 0.U                   // 除零检测

  io.req.ready := !active && !compute && !count(5)      // 空闲且没有待写回结果时可接收新请求

  // This is not a Clz, one value too small.
  // 返回最高有效位之前的前导零数量, 用于把被除数左移后减少迭代次数。
  def Clz1(bits: UInt): UInt = {
    val msb = bits.getWidth - 1
    Mux(bits(msb), 0.U, PriorityEncoder(Reverse(bits(msb - 1, 0)))) // MSB 已为 1 时无需提前跳过
  }

  // Disable active second to last cycle.
  when (io.req.valid && io.req.ready) {
    active := true.B                                    // 接收请求后进入 active
  } .elsewhen (count === 30.U) {
    active := false.B                                   // 倒数第二拍撤 active, 方便 ready 时序
  }

  // Compute is delayed by one cycle.
  compute := active                                     // active 延迟一拍后驱动 Divide 迭代

  // ---- 请求信息锁存 ----
  addr1   := Mux(io.req.fire, io.req.bits.addr, addr1)  // 保存 rd
  signed1 := Mux(
      io.req.fire, io.req.bits.op.isOneOf(DvuOp.DIV, DvuOp.REM), signed1) // DIV/REM 为有符号
  divide1 := Mux(
      io.req.fire, io.req.bits.op.isOneOf(DvuOp.DIV, DvuOp.DIVU), divide1) // DIV/DIVU 写回商

  when (active && !compute) {
    // ---- 迭代初始化 ----
    addr2    := addr1                                   // rd 传入计算阶段
    signed2d := signed1 && (io.rs1.data(31) =/= io.rs2.data(31)) && !divByZero // 商符号 = rs1^rs2
    signed2r := signed1 && io.rs1.data(31)              // 余数符号跟随被除数
    divide2  := divide1                                 // 保存最终写回商/余数选择

    val inp = Mux(signed1 && io.rs1.data(31), ~io.rs1.data + 1.U, io.rs1.data) // 被除数取绝对值

    // The divBy0 uses full latency to simplify logic.
    // Count the leading zeroes, which is one less than the priority encoding.
    val clz = Mux(io.rs2.data === 0.U, 0.U, Clz1(inp))  // 除零不提前结束, 走完整延迟

    denom  := Mux(signed1 && io.rs2.data(31), ~io.rs2.data + 1.U, io.rs2.data) // 除数取绝对值
    divide := inp << clz                                // 左移被除数, 跳过前导零迭代
    remain := 0.U                                       // remainder 清零
    count  := clz                                       // 从 clz 位置开始计数
  } .elsewhen (compute && count < 32.U) {
    // ---- 逐 bit 迭代 ----
    val (div, rem) = Divide(divide, remain, denom)       // 每拍产生 1 bit 商
    divide := div                                       // 更新 quotient/divide
    remain := rem                                       // 更新 remainder
    count := count + 1.U                                // 迭代计数加一
  } .elsewhen (io.rd.valid && io.rd.ready) {
    count := 0.U                                        // 写回握手完成, 返回空闲
  }

  // ---- 结果符号修正 + 写回 ----
  val div = Mux(signed2d, ~divide + 1.U, divide)         // 有符号商按需取负
  val rem = Mux(signed2r, ~remain + 1.U, remain)         // 有符号余数按需取负

  io.rd.valid := count(5)                               // count 达到 32 后结果有效
  io.rd.bits.addr := addr2                              // 写回 rd
  io.rd.bits.data := Mux(divide2, div, rem)             // DIV/DIVU 写商, REM/REMU 写余数
}

object EmitDvu extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new Dvu(p), args)
}
