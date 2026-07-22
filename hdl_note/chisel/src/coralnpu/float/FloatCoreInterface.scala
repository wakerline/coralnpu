// Copyright 2025 Google LLC
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
// FloatCoreInterface.scala — 浮点核心 IO 接口定义 (FloatCoreIO)
// FloatCoreInterface.scala 做了三件事：
// 1. 定义 FloatInstruction：
//    把 RISC-V 浮点指令整理成内部格式，包括 opcode、funct5、fmt、rs1/rs2/rs3、rm、rd、PC、标量/浮点寄存器标记。
// 2. 实现 FloatInstruction.decode：
//    根据 inst[6:2]、fmt、funct5 等字段识别 LOADFP、STOREFP、OPFP、FMA 类指令，
//    并检查 FP32 / Zfbfmin / load-store width 合法性。
// 3. 定义 FloatCoreIO：
//    连接 Decode、FRegfile、Regfile、CSR 和 LSU，
//    支持浮点计算、浮点 load 回写、整数-浮点转换、fflags 提交和 frm 读取。
// ============================================================================

package coralnpu.float

import common.{MakeWireBundle, MakeValid, MakeInvalid}
import chisel3._
import chisel3.util._
import coralnpu.{FRegfileRead, FRegfileWrite, RegfileReadDataIO, RegfileWriteDataIO, Parameters}

class CsrFloatIO(p: Parameters) extends Bundle {
  // FloatCore 写回 CSR 的浮点异常标志。
  val in = new Bundle {
    // fflags 对应 RISC-V 浮点异常累计标志，Valid 表示本拍有异常标志需要提交。
    val fflags = Valid(UInt(5.W))
  }
  // CSR 提供给 FloatCore 的浮点控制状态。
  val out = Input(new Bundle {
    // frm 为 CSR 中保存的动态舍入模式。
    val frm = UInt(3.W)
  })
}

object FpFormat extends ChiselEnum {
    // 当前支持 FP32；FP16ALT 用于 BF16/Zfbfmin 相关转换路径。
    val FP32 = Value(0.U(3.W))
    val FP16ALT = Value(4.U(3.W))
}

// 浮点主 opcode，来自指令 bits(6,2)。
object FloatOpcode extends ChiselEnum {
    // 浮点 load/store、普通 OP-FP 以及四类 fused multiply-add 指令。
    val LOADFP = Value
    val STOREFP = Value
    val OPFP = Value
    val MADD = Value
    val MSUB = Value
    val NMADD = Value
    val NMSUB = Value
}

class FloatInstruction extends Bundle {
    // 译码后的浮点主操作类型。
    val opcode = FloatOpcode()
    // funct5 用于区分 OP-FP 内部的 add/sub/mul/div/convert/class 等操作。
    val funct5 = UInt(5.W)
    // 源/目的浮点格式，普通路径为 FP32，BF16 转换会使用 FP16ALT。
    val src_fmt = FpFormat()
    val dst_fmt = FpFormat()
    // 三源浮点/FMA 指令使用的 rs3/rs2/rs1 字段。
    val rs3 = UInt(5.W)
    val rs2 = UInt(5.W)
    val rs1 = UInt(5.W)
    // 指令携带的舍入模式；111 表示使用 CSR.frm。
    val rm = UInt(3.W)
    // 原始指令和 PC，用于执行、异常和调试路径。
    val inst = UInt(32.W)
    val pc = UInt(32.W)
    // 标记该浮点指令是否会写标量 rd。
    val scalar_rd = Bool()
    // 标记 rs1 是否来自标量寄存器堆。
    val scalar_rs1 = Bool()
    // 标记 rs1 是否来自浮点寄存器堆。
    val float_rs1 = Bool()
    // 目的寄存器编号，可能对应浮点 rd 或标量 rd。
    val rd = UInt(5.W)
    // 标记是否实际使用 rs3/rs2，供 Decode 阶段做读端口和 scoreboard 判断。
    val uses_rs3 = Bool()
    val uses_rs2 = Bool()

    def valid_frm(csr_rm: UInt): Bool = {
      assert(csr_rm.getWidth == 3)
      (rm <= 4.U) ||                          // 指令内 rm 本身合法
      ((rm === "b111".U) && (csr_rm <= 4.U)) // 使用动态舍入时 CSR.frm 合法
    }

    def requires_frm(): Bool = {
      // FMA 和需要舍入的 OP-FP 指令依赖 rm/CSR.frm。
      opcode.isOneOf(FloatOpcode.MADD,
                     FloatOpcode.MSUB,
                     FloatOpcode.NMSUB,
                     FloatOpcode.NMADD) ||
      ((opcode === FloatOpcode.OPFP) && (
        (funct5 === "b00000".U) || // fadd
        (funct5 === "b00001".U) || // fsub
        (funct5 === "b00010".U) || // fmul
        (funct5 === "b00011".U) || // fdiv
        (funct5 === "b00100".U) || // fsqrt
        (funct5 === "b11010".U)    // fcvt，包含浮点到整数和整数到浮点
      ))
    }

    // 检查指令是否有合法舍入模式；不依赖舍入模式的指令直接视为合法。
    def validate_csrfrm(csr_rm: UInt): Bool = {
      !requires_frm() || valid_frm(csr_rm)
    }
}

object FloatInstruction {
  def decode(p: Parameters, inst: UInt, addr: UInt): Valid[FloatInstruction] = {
    // 拆出 RISC-V 浮点指令常用字段。
    val in_opcode = inst(6,2)
    // fmt 为 0 表示 FP32；开启 Zfbfmin 时，fmt 为 2 表示 BF16。
    val fmt = inst(26,25)
    val funct5 = inst(31,27)
    val rs3 = inst(31,27)
    val rs2 = inst(24,20)
    val rs1 = inst(19,15)
    val rm = inst(14,12)
    val rd = inst(11,7)

    // load/store 通过 width 字段检查合法性；该字段复用 rm 位置。
    // 其他取值保留给 D/Q/V 等扩展。
    val load_store_rm_valid = (rm === "b01".U) || (rm === "b10".U)
    // 根据主 opcode 识别浮点指令类型，非法编码返回 invalid。
    val opcode = MuxLookup(in_opcode, MakeInvalid(FloatOpcode()))(Seq(
        "b00001".U -> Mux(load_store_rm_valid, MakeValid(FloatOpcode.LOADFP), MakeInvalid(FloatOpcode())),
        "b01001".U -> Mux(load_store_rm_valid, MakeValid(FloatOpcode.STOREFP), MakeInvalid(FloatOpcode())),
        "b10100".U -> MakeValid(FloatOpcode.OPFP),
        "b10000".U -> MakeValid(FloatOpcode.MADD),
        "b10001".U -> MakeValid(FloatOpcode.MSUB),
        "b10010".U -> MakeValid(FloatOpcode.NMSUB),
        "b10011".U -> MakeValid(FloatOpcode.NMADD),
    ))

    val fcvt_s_bf16 = (funct5 === "b01000".U) && (rs2 === "b01000".U) && (fmt === 2.U)
    val fcvt_bf16_s = (funct5 === "b01000".U) && (rs2 === "b01001".U) && (fmt === 2.U)
    val is_zfbfmin = (fcvt_s_bf16 || fcvt_bf16_s) && p.enableZfbfmin.B

    // TODO(atv): 将 scalar_rd 和 scalar_rs1 接入标量 scoreboard。
    // TODO(atv): FMV 与 FCLASS 的 funct5 相同，是否还需要检查 rm？
    val scalar_rd = MuxLookup(funct5, false.B)(Seq(
        "b11100".U -> true.B, // FMV.X.W
        "b10100".U -> true.B, // FEQ, FLT, FLE
        "b11100".U -> true.B, // FCLASS
        "b11000".U -> true.B, // FCVT.W.S
    )) && (opcode.bits === FloatOpcode.OPFP)

    val scalar_rs1 = MuxLookup(funct5, false.B)(Seq(
        "b11110".U -> true.B, // FMV.W.X
        "b11010".U -> true.B, // FCVT.S.W
    ))

    // FMA 类指令使用 rs3；store/FMA/大多数 OP-FP 指令使用 rs2。
    val uses_rs3 = opcode.bits.isOneOf(FloatOpcode.MADD, FloatOpcode.MSUB, FloatOpcode.NMADD, FloatOpcode.NMSUB)
    val uses_rs2 = opcode.bits.isOneOf(FloatOpcode.STOREFP,
                                       FloatOpcode.MADD,
                                       FloatOpcode.MSUB,
                                       FloatOpcode.NMADD,
                                       FloatOpcode.NMSUB) ||
                   ((opcode.bits === FloatOpcode.OPFP) && MuxLookup(funct5, true.B)(Seq(
                     "b11100".U -> false.B, // FMV.X.W
                     "b11100".U -> false.B, // FCLASS
                     "b11000".U -> false.B, // FCVT.W.S
                     "b11110".U -> false.B, // FMV.W.X
                     "b11010".U -> false.B, // FCVT.S.W
                     "b01011".U -> false.B, // FSQRT.W
                     "b01000".U -> false.B, // FCVT.S.BF16 / FCVT.BF16.S
                   )))
    // 除 load、store、fmv.w.x 和 fcvt.s.w 外，其余浮点指令都使用浮点 rs1。
    val float_rs1 = !opcode.bits.isOneOf(FloatOpcode.STOREFP, FloatOpcode.LOADFP) && !scalar_rs1

    // BF16 转换需要调整源/目的格式；普通路径保持 FP32。
    val src_fmt = Mux(fcvt_bf16_s, FpFormat.FP32, Mux(fcvt_s_bf16, FpFormat.FP16ALT, FpFormat.FP32))
    val dst_fmt = Mux(fcvt_bf16_s, FpFormat.FP16ALT, Mux(fcvt_s_bf16, FpFormat.FP32, FpFormat.FP32))

    MakeWireBundle[ValidIO[FloatInstruction]](
      Valid(new FloatInstruction),
      // 非 load/store 指令要求 fmt == 0 (FP32)；若开启 Zfbfmin，也允许 fmt == 2 (BF16)。
      _.valid -> (opcode.valid && (opcode.bits === FloatOpcode.LOADFP || opcode.bits === FloatOpcode.STOREFP || (fmt === 0.U(2.W)) || is_zfbfmin)),
      _.bits.opcode -> opcode.bits,
      _.bits.funct5 -> funct5,
      _.bits.src_fmt -> src_fmt,
      _.bits.dst_fmt -> dst_fmt,
      _.bits.rs3 -> rs3,
      _.bits.rs2 -> rs2,
      _.bits.rs1 -> rs1,
      _.bits.rm -> rm,
      _.bits.inst -> inst,
      _.bits.pc -> addr,
      _.bits.scalar_rd -> scalar_rd,
      _.bits.scalar_rs1 -> scalar_rs1,
      _.bits.float_rs1 -> float_rs1,
      _.bits.rd -> rd,
      _.bits.uses_rs3 -> uses_rs3,
      _.bits.uses_rs2 -> uses_rs2,
    )
  }
}

class FloatCoreIO(p: Parameters) extends Bundle {
  // Decode 阶段接口。
  // Decode 送入已压缩/整理好的浮点指令；FloatCore 通过 ready 产生反压。
  val inst = Flipped(Decoupled(new FloatInstruction))
  // 浮点寄存器堆读端口，最多支持 rs1/rs2/rs3 三个源。
  val read_ports = Flipped(Vec(3, new FRegfileRead))
  // 浮点寄存器堆写端口，支持执行结果和 LSU 返回结果等写回来源。
  val write_ports = Flipped(Vec(2, new FRegfileWrite))

  // Execute 阶段接口。
  // 标量 rs1/rs2 读数据用于 FMV/FCVT 等跨整数-浮点路径。
  val rs1 = Flipped(new RegfileReadDataIO)
  val rs2 = Flipped(new RegfileReadDataIO)
  // 写回标量寄存器堆的结果，例如比较、分类或浮点到整数转换。
  val scalar_rd = Decoupled(new RegfileWriteDataIO)
  // 与 CSR 的 fflags/frm 交互接口。
  val csr = new CsrFloatIO(p)//LSU 返回的浮点 load 数据通过这个接口进入 FloatCore，再由 FloatCore 或其写回路径写入 FRegfile。
  // LSU 返回的浮点 load 数据，经该接口进入 FloatCore 写回路径。
  val lsu_rd = Flipped(Valid(new RegfileWriteDataIO))
}
