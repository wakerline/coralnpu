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
// Alu.scala — 算术逻辑单元 (RV32I + Zbb 位操作扩展)
//
// AluOp: ADD/SUB/SLT/SLTU/XOR/OR/AND/SLL/SRL/SRA/LUI + ANDN/ORN/XNOR/CLZ/CTZ...
// 单周期完成, 每 lane 一个 Alu 实例
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import _root_.circt.stage.{ChiselStage,FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

object Alu {
  def apply(p: Parameters): Alu = {
    return Module(new Alu(p))
  }
}

/** AluOp — ALU 操作码枚举 (RV32I + Zbb 位操作扩展)
 *  RV32I: ADD/SUB/SLT/SLTU/XOR/OR/AND/SLL/SRL/SRA/LUI
 *  Zbb:   ANDN/ORN/XNOR/CLZ/CTZ/CPOP/MAX/MAXU/MIN/MINU/SEXTB/SEXTH/ROL/ROR/ORCB/REV8/ZEXTH */
object AluOp extends ChiselEnum {
  val ADD  = Value         // 加法
  val SUB  = Value         // 减法
  val SLT  = Value         // 有符号小于置位
  val SLTU = Value         // 无符号小于置位
  val XOR  = Value         // 异或
  val OR   = Value         // 或
  val AND  = Value         // 与
  val SLL  = Value         // 逻辑左移
  val SRL  = Value         // 逻辑右移
  val SRA  = Value         // 算术右移
  val LUI  = Value         // 加载立即数高位 (rs2 直通)
  // Zbb 位操作扩展
  val ANDN  = Value        // 与非
  val ORN   = Value        // 或非
  val XNOR  = Value        // 同或
  val CLZ   = Value        // 前导零计数
  val CTZ   = Value        // 尾随零计数
  val CPOP  = Value        // 计数 (PopCount)
  val MAX   = Value        // 有符号最大值
  val MAXU  = Value        // 无符号最大值
  val MIN   = Value        // 有符号最小值
  val MINU  = Value        // 无符号最小值
  val SEXTB = Value        // 字节符号扩展 (8→32)
  val SEXTH = Value        // 半字符号扩展 (16→32)
  val ROL   = Value        // 循环左移
  val ROR   = Value        // 循环右移
  val ORCB  = Value        // 每字节 OR Combine (检查每字节是否非零)
  val REV8  = Value        // 字节反转
  val ZEXTH = Value        // 零扩展半字 (低16位)
}

/** AluCmd — ALU 命令 (译码阶段→执行阶段) */
class AluCmd extends Bundle {
  val addr = UInt(5.W)     // 目标寄存器号 (rd)
  val op   = AluOp()       // 操作码
}

/** Alu — 算术逻辑单元。单周期完成, 每 lane 一个实例。 */
class Alu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val req = Flipped(Valid(new AluCmd))                         // 译码阶段: 操作码+目标寄存器
    val rs1 = Flipped(new RegfileReadDataIO)                     // 源操作数1 (执行阶段)
    val rs2 = Flipped(new RegfileReadDataIO)                     // 源操作数2
    val rd  = Valid(Flipped(new RegfileWriteDataIO))             // 写回: 目标寄存器+数据
  })

  // Cycle N:
  //   Dispatch 发出 ALU req，包括 op 和 rd
  //   Dispatch 同时给 Regfile 发 rs1/rs2 读地址
  
  // Cycle N+1:
  //   Regfile 输出 rs1/rs2 数据
  //   ALU 使用上一拍保存的 op/rd addr
  //   ALU 组合计算结果
  //   io.rd.valid = 1
  val valid = RegInit(false.B)                                    // 操作有效 (req 的延迟1拍)
  val addr  = RegInit(0.U(5.W))                                  // 目标寄存器地址
  val op    = RegInit(AluOp.ADD)                                 // 当前操作码

  valid := io.req.valid                                          // 延迟 1 拍生效
  // 仅在 req 有效时更新 addr/op, 避免空闲周期输出翻转 (与 Regfile 行为一致)
  when (io.req.valid) {
    addr := io.req.bits.addr
    op   := io.req.bits.op
  }

  val rs1   = io.rs1.data                                        // 源操作数 1
  val rs2   = io.rs2.data                                        // 源操作数 2
  val shamt = rs2(4,0)                                           // 移位量 (低5位)

  io.rd.valid := valid
  io.rd.bits.addr  := addr

  val r2IsGreater = rs1.asSInt < rs2.asSInt
  val r2IsGreaterU = rs1 < rs2

  val rsWidth  = 32
  val rsWidthH = 32/2

  /** SignExtend — 符号扩展 x 到 length 位宽 (通过 SInt 中间类型) */
  def SignExtend(x: UInt, length: Int): UInt = {
    val ext = Wire(SInt(length.W))
    ext := x.asSInt                                              // UInt→SInt 自动符号扩展
    ext.asUInt
  }

  /** Orcb — 每字节 OR Combine: 检查每字节是否非零, 返回 0x00 或 0xFF */
  def Orcb(x: UInt, length: Int): UInt = {
    val orcb = Wire(UInt(length.W))
    orcb := Cat((0 until length by 8).reverse.map(i =>           // 遍历每 8 位
      Mux(x(i+7, i) === 0.U, 0x0.U(8.W), 0xFF.U(8.W))           // 全0→0x00, 否则→0xFF
    ))
    orcb
  }

  // MuxLookup: 根据 op 选择运算结果, 默认值 0
  io.rd.bits.data  := MuxLookup(op, 0.U)(Seq(
    AluOp.ADD  -> (rs1 + rs2),                                    // 加法
    AluOp.SUB  -> (rs1 - rs2),                                    // 减法
    AluOp.SLT  -> (r2IsGreater),                                  // 有符号比较: rs1 < rs2 → 1
    AluOp.SLTU -> (r2IsGreaterU),                                 // 无符号比较
    AluOp.XOR  -> (rs1 ^ rs2),                                    // 按位异或
    AluOp.OR   -> (rs1 | rs2),                                    // 按位或
    AluOp.AND  -> (rs1 & rs2),                                    // 按位与
    AluOp.SLL  -> ((rs1 << shamt)(31,0)),                        // 逻辑左移 (低5位移位量)
    AluOp.SRL  -> ((rs1 >> shamt)(31,0)),                        // 逻辑右移
    AluOp.SRA  -> (((rs1.asSInt >> shamt).asUInt)(31,0)),        // 算术右移 (asSInt 保持符号)
    AluOp.LUI  -> rs2,                                            // LUI: rs2 直通 (立即数已在 rs2 中)
    // ---- Zbb 位操作扩展 ----
    AluOp.ANDN -> (rs1 & ~rs2),
    AluOp.ORN  -> (rs1 | ~rs2),
    AluOp.XNOR -> ~(rs1 ^ rs2),
    AluOp.CLZ  -> Clz(rs1),                                       // 前导零计数 (来自 Library.scala)
    AluOp.CTZ  -> Ctz(rs1),                                       // 尾随零计数
    AluOp.CPOP -> PopCount(rs1),                                  // 人口计数 (Chisel 内置)
    AluOp.MAX  -> Mux(r2IsGreater,  rs2, rs1),                   // 有符号取大
    AluOp.MAXU -> Mux(r2IsGreaterU, rs2, rs1),                   // 无符号取大
    AluOp.MIN  -> Mux(r2IsGreater,  rs1, rs2),                   // 有符号取小
    AluOp.MINU -> Mux(r2IsGreaterU, rs1, rs2),                   // 无符号取小
    AluOp.SEXTB -> SignExtend(rs1(7, 0), rsWidth),               // 字节→32位符号扩展
    AluOp.SEXTH -> SignExtend(rs1(rsWidthH-1,0), rsWidth),       // 半字→32位符号扩展
    AluOp.ROL -> rs1.rotateLeft(shamt),                           // 循环左移
    AluOp.ROR -> rs1.rotateRight(shamt),                          // 循环右移
    AluOp.ORCB -> Orcb(rs1, rsWidth),                             // 每字节非零检测 (展开为 0x00/0xFF)
    AluOp.REV8 -> Cat(UIntToVec(rs1, 8)),                        // 字节反转 (Vec 顺序反转)
    AluOp.ZEXTH -> rs1(rsWidthH - 1, 0),                          // 零扩展半字
  ))

  // ---- 硬件断言: 确保操作数 valid 时序正确 ----
  // rs1Only: 仅需 rs1 的操作 (不需要 rs2)
  val rs1Only = op.isOneOf(
    AluOp.CLZ, AluOp.CTZ, AluOp.CPOP,
    AluOp.ZEXTH, AluOp.SEXTH, AluOp.SEXTB,
    AluOp.ORCB, AluOp.REV8,
  )
  assert(!(valid && !io.rs1.valid && !op.isOneOf(AluOp.LUI)))   // 需要 rs1 但 rs1 无效 (LUI 除外)
  assert(!(valid && !io.rs2.valid && !rs1Only))                  // 需要 rs2 但 rs2 无效
}

@nowarn
object EmitAlu extends App {
  val p = new Parameters
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new Alu(p))) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
