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
// RvvDecode.scala — RVV 向量指令译码 (V 扩展指令→微操作)
// ============================================================================

package coralnpu.rvv

import chisel3._
import chisel3.util._
import common.{ForceZero, MakeInvalid, MakeValid, MakeWireBundle, MuxUpTo1H}


object RvvCompressedOpcode extends ChiselEnum {
  // 压缩后的内部 opcode：保留原始 RVV load/store/ALU 三类主操作。
  val RVVLOAD = Value(0.U)
  val RVVSTORE = Value(1.U)
  val RVVALU = Value(2.U)
}

object RvvAddressingMode extends ChiselEnum {
  // RVV load/store 的 mop 寻址模式。
  val UNIT_STRIDE = Value(0.U(2.W))
  val INDEXED_UNORDERED = Value(1.U(2.W))
  val STRIDED = Value(2.U(2.W))
  val INDEXED_ORDERED = Value(3.U(2.W))
}

class RvvCompressedInstruction extends Bundle {
  // 原始 PC，用于异常/退役关联。
  val pc = UInt(32.W)
  // 压缩后的内部主 opcode。
  val opcode = RvvCompressedOpcode()
  // 原指令去掉低 7 位 opcode 后剩余的 25 bit。
  val bits = UInt(25.W)

  // 还原为原始 32-bit 指令编码，便于调试、异常和后端复用。
  def originalEncoding(): UInt = {
    val lower7bits = MuxLookup(opcode, 0.U)(Seq(
        RvvCompressedOpcode.RVVLOAD  -> "b0000111".U,
        RvvCompressedOpcode.RVVSTORE -> "b0100111".U,
        RvvCompressedOpcode.RVVALU   -> "b1010111".U,
    ))
    Cat(bits, lower7bits)
  }

  def funct6(): UInt = {
    bits(24, 19)
  }

  def vs1(): UInt = {
    bits(12, 8)
  }

  def funct3(): UInt = {
    bits(7, 5)
  }

  // 这些指令要求 vstart 为 0；若 vstart 非 0，需要触发异常。
  // 其中包含所有 reduction 指令，以及部分 mask/压缩类指令。
  def requireZeroVstart(): Bool = {
    (opcode === RvvCompressedOpcode.RVVALU) && (funct3() === "b010".U) &&
        // OPMVV 类指令。
        MuxLookup(funct6(), false.B)(Seq(
            "b000000".U -> true.B,  // vredsum
            "b000001".U -> true.B,  // vredand
            "b000010".U -> true.B,  // vredor
            "b000011".U -> true.B,  // vredxor
            "b000100".U -> true.B,  // vredminu
            "b000101".U -> true.B,  // vredmin
            "b000110".U -> true.B,  // vredmaxu
            "b000111".U -> true.B,  // vredmax
            "b010000".U -> MuxLookup(vs1(), false.B)(Seq(  // VWXUNARY0
                "b10000".U -> true.B,  // vcpop
                "b10001".U -> true.B,  // vfirst
            )),
            "b010100".U -> MuxLookup(vs1(), false.B)(Seq(  // VMUNARY0
                "b00001".U -> true.B,  // vmsbf
                "b00010".U -> true.B,  // vmsof
                "b00011".U -> true.B,  // vmsif
                "b10000".U -> true.B,  // viota
            )),
            "b010111".U -> true.B,  // vcompress
            "b110000".U -> true.B,  // vwredsumu
            "b110001".U -> true.B,  // vwredsum
        ))
  }

  // load/store 的寻址模式，来自 RVV Spec 7.2 节的 mop 字段。
  def mop: RvvAddressingMode.Type = {
    RvvAddressingMode(bits(20, 19))
  }

  // 判断是否为 vsetvli/vsetivli/vsetvl 配置指令。
  def isVset(): Bool = {
    (opcode === RvvCompressedOpcode.RVVALU && funct3() === "b111".U)
  }

  def isLoadStore(): Bool = {
    opcode.isOneOf(RvvCompressedOpcode.RVVLOAD, RvvCompressedOpcode.RVVSTORE)
  }

  def readsRs1(): Bool = {
    isLoadStore() ||
    (funct3() === "b100".U) ||  // OPIVX
    (funct3() === "b110".U) ||  // OPMVX
    ((funct3() === "b111".U) && (bits(24, 23) =/= "b11".U))  // vsetvl 和 vsetvli
  }

  def readsRs2(): Bool = {
    (isLoadStore() && (mop === RvvAddressingMode.STRIDED)) ||
        ((funct3() === "b111".U) && (bits(24, 18) === "b1000000".U))
  }

  def readsFloatRs1(): Bool = {
    // OPFVF 类指令读取浮点 rs1。
    opcode === RvvCompressedOpcode.RVVALU && funct3() === "b101".U
  }

  def writesRd(): Bool = {
    isVset() ||
    // OPMVV / VWXUNARY0 类标量写回：vmv.x.s、vcpop、vfirst。
    (opcode === RvvCompressedOpcode.RVVALU && funct3() === "b010".U && funct6() === "b010000".U)
  }

  def writesFrd(): Bool = {
    // OPFVV / VWRFUNARY0 类浮点写回：vfmv.f.s。
    opcode === RvvCompressedOpcode.RVVALU && funct3() === "b001".U && funct6() === "b010000".U
  }

  def writesVectorRegister(): Bool = {
    // load 或 ALU 类向量指令会写向量寄存器。
    // store 不写向量寄存器；vset* 写标量 rd；
    // 标量/浮点写回类指令 vmv.x.s、vcpop、vfirst、vfmv.f.s 也不写向量寄存器。
    opcode === RvvCompressedOpcode.RVVLOAD ||
        (opcode === RvvCompressedOpcode.RVVALU && !writesRd() && !writesFrd())
  }

  override def toPrintable: Printable = {
    cf"[opcode=$opcode, bits=$bits%b]"
  }
}

object RvvCompressedInstruction {
  def from_uncompressed(inst: UInt, pc: UInt): Valid[RvvCompressedInstruction] = {
    val old_opcode = inst(6, 0)
    val bits = inst(31, 7)

    // load/store 合法时 mew 必须为 0。
    val mew = inst(28)
    // RVVLOAD/RVVSTORE 与 F 扩展复用 opcode，通过 width 字段区分是否为向量访存。
    val width = inst(14, 12)
    val validWidth = !mew && MuxLookup(width, false.B)(Seq(
      "b000".U -> true.B,  // 8b
      "b101".U -> true.B,  // 16b
      "b110".U -> true.B,  // 32b
      // "b111".U -> true.B,  // 64b，CoralNPU 当前未使用
    ))

    val new_opcode = MuxLookup(old_opcode, MakeInvalid(RvvCompressedOpcode()))(Seq(
      "b0000111".U -> MakeValid(validWidth, RvvCompressedOpcode.RVVLOAD),
      "b0100111".U -> MakeValid(validWidth, RvvCompressedOpcode.RVVSTORE),
      "b1010111".U -> MakeValid(RvvCompressedOpcode.RVVALU),
    ))

    // 用 MakeWireBundle 组装 Valid 输出，避免手写中间 Wire。
    MakeWireBundle[ValidIO[RvvCompressedInstruction]](
      Valid(new RvvCompressedInstruction),
      _.valid -> new_opcode.valid,
      _.bits.opcode -> new_opcode.bits,
      _.bits.pc -> pc,
      _.bits.bits -> bits,
    )
  }
}

class RvvS1DecodeInstructionBase {
  // 默认返回非法 S1 译码结果。
  def invalid() = MakeInvalid(new RvvS1DecodedInstruction)

  // OPIVV: 向量-向量整数操作译码。
  private def s1decode_opivv(f6vm: UInt, vs2: UInt, vs1: UInt, vd: UInt): Valid[RvvS1DecodedInstruction] = {
    // gather/重排类指令要求目的寄存器不与源寄存器重叠。
    val no_overlap = (vd =/= vs1 && vd =/= vs2)
    val op = MuxUpTo1H(MakeInvalid(RvvAluOp()), Seq(
      // 除非规范明确要求，否则这里默认指令可带 mask 或不带 mask。
      (f6vm === BitPat("b000000_?")) -> MakeValid(RvvAluOp.VADD),
      (f6vm === BitPat("b000010_?")) -> MakeValid(RvvAluOp.VSUB),
      // OPIVV 不支持 VRSUB。
      (f6vm === BitPat("b000100_?")) -> MakeValid(RvvAluOp.VMINU),
      (f6vm === BitPat("b000101_?")) -> MakeValid(RvvAluOp.VMIN),
      (f6vm === BitPat("b000110_?")) -> MakeValid(RvvAluOp.VMAXU),
      (f6vm === BitPat("b000111_?")) -> MakeValid(RvvAluOp.VMAX),
      (f6vm === BitPat("b001001_?")) -> MakeValid(RvvAluOp.VAND),
      (f6vm === BitPat("b001010_?")) -> MakeValid(RvvAluOp.VOR),
      (f6vm === BitPat("b001011_?")) -> MakeValid(RvvAluOp.VXOR),
      (f6vm === BitPat("b001100_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHER),
      (f6vm === BitPat("b001110_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHEREI16),
      // OPIVV 不支持 VSLIDEUP。
      // OPIVV 不支持 VSLIDEDOWN。
      (f6vm === "b010000_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VADC),  // 必须带 mask
      (f6vm === BitPat("b010001_?")) -> MakeValid(RvvAluOp.VMADC),
      (f6vm === "b010010_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VSBC),  // 必须带 mask
      (f6vm === BitPat("b010011_?")) -> MakeValid(RvvAluOp.VMSBC),
      (f6vm === "b010111_0".U) -> MakeValid(RvvAluOp.VMERGE),  // 必须带 mask
      (f6vm === "b010111_1".U) -> MakeValid(RvvAluOp.VMV),  // 不允许带 mask
      (f6vm === "b011000_0".U) -> MakeValid(RvvAluOp.VMSEQ),  // 必须带 mask
      (f6vm === "b011001_0".U) -> MakeValid(RvvAluOp.VMSNE),  // 必须带 mask
      (f6vm === "b011010_0".U) -> MakeValid(RvvAluOp.VMSLTU),  // 必须带 mask
      (f6vm === "b011011_0".U) -> MakeValid(RvvAluOp.VMSLT),  // 必须带 mask
      (f6vm === "b011100_0".U) -> MakeValid(RvvAluOp.VMSLEU),  // 必须带 mask
      (f6vm === "b011101_0".U) -> MakeValid(RvvAluOp.VMSLE),  // 必须带 mask
      // OPIVV 不支持 VMSGTU。
      // OPIVV 不支持 VMSGT。
      (f6vm === BitPat("b100000_?")) -> MakeValid(RvvAluOp.VSADDU),
      (f6vm === BitPat("b100001_?")) -> MakeValid(RvvAluOp.VSADD),
      (f6vm === BitPat("b100010_?")) -> MakeValid(RvvAluOp.VSSUBU),
      (f6vm === BitPat("b100011_?")) -> MakeValid(RvvAluOp.VSSUB),
      (f6vm === BitPat("b100101_?")) -> MakeValid(RvvAluOp.VSLL),
      (f6vm === BitPat("b100111_?")) -> MakeValid(RvvAluOp.VSMUL),
      // OPIVV 不支持整寄存器组搬运。
      (f6vm === BitPat("b101000_?")) -> MakeValid(RvvAluOp.VSRL),
      (f6vm === BitPat("b101001_?")) -> MakeValid(RvvAluOp.VSRA),
      (f6vm === BitPat("b101010_?")) -> MakeValid(RvvAluOp.VSSRL),
      (f6vm === BitPat("b101011_?")) -> MakeValid(RvvAluOp.VSSRA),
      (f6vm === BitPat("b101100_?")) -> MakeValid(RvvAluOp.VNSRL),
      (f6vm === BitPat("b101101_?")) -> MakeValid(RvvAluOp.VNSRA),
      (f6vm === BitPat("b101110_?")) -> MakeValid(RvvAluOp.VNCLIPU),
      (f6vm === BitPat("b101111_?")) -> MakeValid(RvvAluOp.VNCLIP),
    ))

    ForceZero(MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
      Valid(new RvvS1DecodedInstruction),
      _.valid -> op.valid,
      _.bits.op -> op.bits,
    ))
  }

  // OPIVX: 向量-标量整数操作译码。
  private def s1decode_opivx(f6vm: UInt, vs2: UInt, rs1: UInt, vd: UInt): Valid[RvvS1DecodedInstruction] = {
    // 重排类指令要求目的寄存器不与 vs2 重叠。
    val no_overlap = (vd =/= vs2)
    val op = MuxUpTo1H(MakeInvalid(RvvAluOp()), Seq(
      (f6vm === BitPat("b000000_?")) -> MakeValid(RvvAluOp.VADD),
      (f6vm === BitPat("b000010_?")) -> MakeValid(RvvAluOp.VSUB),
      (f6vm === BitPat("b000011_?")) -> MakeValid(RvvAluOp.VRSUB),
      (f6vm === BitPat("b000100_?")) -> MakeValid(RvvAluOp.VMINU),
      (f6vm === BitPat("b000101_?")) -> MakeValid(RvvAluOp.VMIN),
      (f6vm === BitPat("b000110_?")) -> MakeValid(RvvAluOp.VMAXU),
      (f6vm === BitPat("b000111_?")) -> MakeValid(RvvAluOp.VMAX),
      (f6vm === BitPat("b001001_?")) -> MakeValid(RvvAluOp.VAND),
      (f6vm === BitPat("b001010_?")) -> MakeValid(RvvAluOp.VOR),
      (f6vm === BitPat("b001011_?")) -> MakeValid(RvvAluOp.VXOR),
      (f6vm === BitPat("b001100_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHER),
      // OPIVX 不支持 VRGATHEREI16。
      (f6vm === BitPat("b001110_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEUP),
      (f6vm === BitPat("b001111_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEDOWN),
      (f6vm === "b010000_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VADC),  // 必须带 mask
      (f6vm === BitPat("b010001_?")) -> MakeValid(RvvAluOp.VMADC),
      (f6vm === "b010010_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VSBC),  // 必须带 mask
      (f6vm === BitPat("b010011_?")) -> MakeValid(RvvAluOp.VMSBC),
      (f6vm === "b010111_0".U) -> MakeValid(RvvAluOp.VMERGE),  // 必须带 mask
      (f6vm === "b010111_1".U) -> MakeValid(vs2 === "b00000".U, RvvAluOp.VMV),  // 不允许带 mask
      (f6vm === "b011000_0".U) -> MakeValid(RvvAluOp.VMSEQ),  // 必须带 mask
      (f6vm === "b011001_0".U) -> MakeValid(RvvAluOp.VMSNE),  // 必须带 mask
      (f6vm === "b011010_0".U) -> MakeValid(RvvAluOp.VMSLTU),  // 必须带 mask
      (f6vm === "b011011_0".U) -> MakeValid(RvvAluOp.VMSLT),  // 必须带 mask
      (f6vm === "b011100_0".U) -> MakeValid(RvvAluOp.VMSLEU),  // 必须带 mask
      (f6vm === "b011101_0".U) -> MakeValid(RvvAluOp.VMSLE),  // 必须带 mask
      (f6vm === "b011110_0".U) -> MakeValid(RvvAluOp.VMSGTU),  // 必须带 mask
      (f6vm === "b011111_0".U) -> MakeValid(RvvAluOp.VMSGT),  // 必须带 mask
      (f6vm === BitPat("b100000_?")) -> MakeValid(RvvAluOp.VSADDU),
      (f6vm === BitPat("b100001_?")) -> MakeValid(RvvAluOp.VSADD),
      (f6vm === BitPat("b100010_?")) -> MakeValid(RvvAluOp.VSSUBU),
      (f6vm === BitPat("b100011_?")) -> MakeValid(RvvAluOp.VSSUB),
      (f6vm === BitPat("b100101_?")) -> MakeValid(RvvAluOp.VSLL),
      (f6vm === BitPat("b100111_?")) -> MakeValid(RvvAluOp.VSMUL),
      // OPIVX 不支持整寄存器组搬运。
      (f6vm === BitPat("b101000_?")) -> MakeValid(RvvAluOp.VSRL),
      (f6vm === BitPat("b101001_?")) -> MakeValid(RvvAluOp.VSRA),
      (f6vm === BitPat("b101010_?")) -> MakeValid(RvvAluOp.VSSRL),
      (f6vm === BitPat("b101011_?")) -> MakeValid(RvvAluOp.VSSRA),
      (f6vm === BitPat("b101100_?")) -> MakeValid(RvvAluOp.VNSRL),
      (f6vm === BitPat("b101101_?")) -> MakeValid(RvvAluOp.VNSRA),
      (f6vm === BitPat("b101110_?")) -> MakeValid(RvvAluOp.VNCLIPU),
      (f6vm === BitPat("b101111_?")) -> MakeValid(RvvAluOp.VNCLIP),
    ))

    ForceZero(MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
      Valid(new RvvS1DecodedInstruction),
      _.valid -> op.valid,
      _.bits.op -> op.bits,
    ))
  }

  // OPIVI: 向量-立即数整数操作译码。
  private def s1decode_opivi(f6vm: UInt, vs2: UInt, imm5: UInt, vd: UInt): Valid[RvvS1DecodedInstruction] = {
    val no_overlap = (vd =/= vs2)
    // 整寄存器组搬运要求源/目的寄存器按寄存器组大小对齐。
    val unary_align2 = (vd === BitPat("b????0")) && (vs2 === BitPat("b????0"))
    val unary_align4 = (vd === BitPat("b???00")) && (vs2 === BitPat("b???00"))
    val unary_align8 = (vd === BitPat("b??000")) && (vs2 === BitPat("b??000"))
    val op = MuxUpTo1H(MakeInvalid(RvvAluOp()), Seq(
      (f6vm === BitPat("b000000_?")) -> MakeValid(RvvAluOp.VADD),
      // OPIVI 不支持 VSUB。
      (f6vm === BitPat("b000011_?")) -> MakeValid(RvvAluOp.VRSUB),
      // OPIVI 不支持 min/max 类操作。
      (f6vm === BitPat("b001001_?")) -> MakeValid(RvvAluOp.VAND),
      (f6vm === BitPat("b001010_?")) -> MakeValid(RvvAluOp.VOR),
      (f6vm === BitPat("b001011_?")) -> MakeValid(RvvAluOp.VXOR),
      (f6vm === BitPat("b001100_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHER),
      // OPIVI 不支持 VRGATHEREI16。
      (f6vm === BitPat("b001110_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEUP),
      (f6vm === BitPat("b001111_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEDOWN),
      (f6vm === "b010000_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VADC),  // 必须带 mask
      (f6vm === BitPat("b010001_?")) -> MakeValid(RvvAluOp.VMADC),
      // OPIVI 不支持 VSBC/VMSBC。
      (f6vm === "b010111_0".U) -> MakeValid(RvvAluOp.VMERGE),  // 必须带 mask
      (f6vm === "b010111_1".U) -> MakeValid(vs2 === "b00000".U, RvvAluOp.VMV),  // 不允许带 mask
      (f6vm === "b011000_0".U) -> MakeValid(RvvAluOp.VMSEQ),  // 必须带 mask
      (f6vm === "b011001_0".U) -> MakeValid(RvvAluOp.VMSNE),  // 必须带 mask
      // OPIVI 不支持 VMSLTU/VMSLT。
      (f6vm === "b011100_0".U) -> MakeValid(RvvAluOp.VMSLEU),  // 必须带 mask
      (f6vm === "b011101_0".U) -> MakeValid(RvvAluOp.VMSLE),  // 必须带 mask
      (f6vm === "b011110_0".U) -> MakeValid(RvvAluOp.VMSGTU),  // 必须带 mask
      (f6vm === "b011111_0".U) -> MakeValid(RvvAluOp.VMSGT),  // 必须带 mask
      (f6vm === BitPat("b100000_?")) -> MakeValid(RvvAluOp.VSADDU),
      (f6vm === BitPat("b100001_?")) -> MakeValid(RvvAluOp.VSADD),
      // OPIVI 不支持 VSSUBU/VSSUB。
      (f6vm === BitPat("b100101_?")) -> MakeValid(RvvAluOp.VSLL),
      // OPIVI 不支持 VSMUL。
      // TODO(davidgao): 下面 4 项写法较重复，可考虑合并成一个辅助函数。
      (f6vm === "b100111_1".U && imm5 === "b00000".U) -> MakeValid(RvvAluOp.VMV1R),  // 不允许带 mask
      (f6vm === "b100111_1".U && imm5 === "b00001".U) -> MakeValid(unary_align2, RvvAluOp.VMV2R),  // 不允许带 mask
      (f6vm === "b100111_1".U && imm5 === "b00011".U) -> MakeValid(unary_align4, RvvAluOp.VMV4R),  // 不允许带 mask
      (f6vm === "b100111_1".U && imm5 === "b00111".U) -> MakeValid(unary_align8, RvvAluOp.VMV8R),  // 不允许带 mask
      (f6vm === BitPat("b101000_?")) -> MakeValid(RvvAluOp.VSRL),
      (f6vm === BitPat("b101001_?")) -> MakeValid(RvvAluOp.VSRA),
      (f6vm === BitPat("b101010_?")) -> MakeValid(RvvAluOp.VSSRL),
      (f6vm === BitPat("b101011_?")) -> MakeValid(RvvAluOp.VSSRA),
      (f6vm === BitPat("b101100_?")) -> MakeValid(RvvAluOp.VNSRL),
      (f6vm === BitPat("b101101_?")) -> MakeValid(RvvAluOp.VNSRA),
      (f6vm === BitPat("b101110_?")) -> MakeValid(RvvAluOp.VNCLIPU),
      (f6vm === BitPat("b101111_?")) -> MakeValid(RvvAluOp.VNCLIP),
    ))

    ForceZero(MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
      Valid(new RvvS1DecodedInstruction),
      _.valid -> op.valid,
      _.bits.op -> op.bits,
    ))
  }

  protected def s1decode_opv(bits: UInt): Valid[RvvS1DecodedInstruction] = {
    // 低 7 位 opcode 已经在上一级消费，这里只解剩余 25 位。
    val vd = bits(4, 0)  // 某些指令中该字段也可作为 rd。
    val mode = bits(7, 5)
    val vs1 = bits(12, 8)  // 根据模式也可表示 rs1 或 imm5。
    val vs2 = bits(17, 13)  // 对部分配置指令无意义。
    val f6vm = bits(24, 18)  // 对配置指令无意义。
    // TODO: 配置指令需要单独处理 bits(24,13)。

    MuxLookup(mode, invalid())(Seq(
      "b000".U -> s1decode_opivv(f6vm, vs2, vs1, vd),
      "b011".U -> s1decode_opivi(f6vm, vs2, vs1, vd),
      "b100".U -> s1decode_opivx(f6vm, vs2, vs1, vd),
    ))
  }
}

object RvvS1DecodeInstruction extends RvvS1DecodeInstructionBase {
  // RVV 是扩展译码器，不直接负责处理未定义/非法指令的全局异常。
  def apply(inst: UInt): Valid[RvvS1DecodedInstruction] = {
    // RVV 指令固定 32 位，低 7 位为主 opcode。
    val opcode = inst(6, 0)
    val bits = inst(31, 7)
    MuxLookup(opcode, invalid())(Seq(
      "b1010111".U -> s1decode_opv(bits),
      "b0000111".U -> invalid(),  // TODO LOAD-FP
      "b0100111".U -> invalid(),  // TODO STORE-FP
    ))
  }
}


object RvvS1DecodeCompressedInstruction extends RvvS1DecodeInstructionBase {
  // RVV 是扩展译码器，不直接负责处理未定义/非法指令的全局异常。
  // 该压缩格式只在部分内部 core 中使用，不暴露给软件。
  def apply(inst: RvvCompressedInstruction): Valid[RvvS1DecodedInstruction] = {
    // 内部压缩格式由 2-bit opcode 加 25-bit 译码字段组成。
    MuxLookup(inst.opcode, invalid())(Seq(
      RvvCompressedOpcode.RVVLOAD -> invalid(),  // TODO: implement this
      RvvCompressedOpcode.RVVSTORE -> invalid(),  // TODO: implement this
      RvvCompressedOpcode.RVVALU -> s1decode_opv(inst.bits),
    ))
  }

  def apply(inst: Valid[RvvCompressedInstruction]): Valid[RvvS1DecodedInstruction] = {
    // 包装 Valid 输入；输入无效时直接输出 invalid。
    Mux(inst.valid, apply(inst.bits), MakeInvalid(new RvvS1DecodedInstruction))
  }
}
