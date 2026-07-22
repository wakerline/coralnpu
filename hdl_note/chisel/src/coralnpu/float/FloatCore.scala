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
// FloatCore.scala — 浮点运算核心 (FP32 FMA + Div + Sqrt)
// 可选 PULP 或 E906 Div/Sqrt 实现, 3读2写端口与 FRegfile 交互
// ============================================================================

package coralnpu.float

import common._
import chisel3._
import chisel3.util._
import coralnpu.{RegfileWriteDataIO, Parameters}

object FloatCore {
    // 便捷构造函数，外部按 Parameters 实例化 FloatCore。
    def apply(p: Parameters): FloatCore = {
        return Module(new FloatCore(p))
    }
}

// TODO(atv): 研究是否能从 fpnew RTL 中直接导入这些配置常量。
object FpNewConfig {
    val NUM_OPERANDS = 3                                // FPNEW 最多 3 个操作数(FMA)
    val WIDTH = 32                                      // 当前只接 FP32 数据路径
    val OP_BITS = 4                                     // FPNEW 操作枚举位宽
}

// 对应的 SystemVerilog operation_e/opgroup 相关定义位于
// external/cvfpu/src/fpnew_pkg.sv。
object FpNewOperation extends ChiselEnum {
  val FMADD    = Value(0.U(FpNewConfig.OP_BITS.W))      // 融合乘加
  val FNMSUB   = Value(1.U(FpNewConfig.OP_BITS.W))      // 融合取负乘减
  val ADD      = Value(2.U(FpNewConfig.OP_BITS.W))      // 加/减
  val MUL      = Value(3.U(FpNewConfig.OP_BITS.W))      // 乘法
  val DIV      = Value(4.U(FpNewConfig.OP_BITS.W))      // 除法
  val SQRT     = Value(5.U(FpNewConfig.OP_BITS.W))      // 平方根
  val SGNJ     = Value(6.U(FpNewConfig.OP_BITS.W))      // 符号注入/搬运
  val MINMAX   = Value(7.U(FpNewConfig.OP_BITS.W))      // 最小/最大
  val CMP      = Value(8.U(FpNewConfig.OP_BITS.W))      // 比较
  val CLASSIFY = Value(9.U(FpNewConfig.OP_BITS.W))      // 分类
  val F2F      = Value(10.U(FpNewConfig.OP_BITS.W))     // 浮点到浮点转换
  val F2I      = Value(11.U(FpNewConfig.OP_BITS.W))     // 浮点到整数转换
  val I2F      = Value(12.U(FpNewConfig.OP_BITS.W))     // 整数到浮点转换
  val CPKAB    = Value(13.U(FpNewConfig.OP_BITS.W))     // packed cast 操作，当前未用
  val CPKCD    = Value(14.U(FpNewConfig.OP_BITS.W))     // packed cast 操作，当前未用
  // 这不是 FPNEW 的真实 operation，不能直接送进核心，只作为 FloatCore 内部占位。
  val STORE    = Value(15.U(FpNewConfig.OP_BITS.W))     // 内部占位: 浮点 store 不送入 FPNEW
}


// 对应的 SystemVerilog roundmode_e 位于 external/cvfpu/src/fpnew_pkg.sv。
// 舍入模式语义可参考 RISC-V Unprivileged spec 第 20.2 节。
object FpNewRoundingMode extends ChiselEnum {
  val RNE = Value(0.U(3.W)) // 就近舍入，正好居中时取偶数
  val RTZ = Value(1.U(3.W)) // 向 0 舍入
  val RDN = Value(2.U(3.W)) // 向下舍入，趋向负无穷
  val RUP = Value(3.U(3.W)) // 向上舍入，趋向正无穷
  val RMM = Value(4.U(3.W)) // 就近舍入，正好居中时取最大幅值
  val DYN = Value(7.U(3.W)) // 动态舍入模式，使用 CSR.frm
}

object GenerateCoreShimSource {
    def apply(p: Parameters): String = {
        // 生成一个 SystemVerilog wrapper, 把 Chisel 侧平铺端口接到 fpnew_top 的 packed 端口。
        var moduleInterface = """
        |module FloatCoreWrapper(
        |  input logic clk_i,
        |  input logic rst_ni,
        |""".stripMargin

        moduleInterface += "  input logic in_valid_i,\n"
        moduleInterface += "  output logic in_ready_o,\n"
        for (i <- 0 until FpNewConfig.NUM_OPERANDS) {
            moduleInterface += "  input logic [WIDTH-1:0] operands_i_GENI,\n"
                .replaceAll("GENI", i.toString)
                .replaceAll("WIDTH", FpNewConfig.WIDTH.toString)
        }
        moduleInterface += "  input logic[OP_BITS-1:0] op_i,\n".replaceAll("OP_BITS", FpNewConfig.OP_BITS.toString)
        moduleInterface += "  input logic op_mod_i,\n"
        moduleInterface += "  input logic[2:0] rnd_mode_i,\n"
        moduleInterface += "  input logic[2:0] src_fmt_i,\n"
        moduleInterface += "  input logic[2:0] dst_fmt_i,\n"
        moduleInterface += "  input logic flush_i,\n"
        moduleInterface += "  output logic out_valid_o,\n"
        moduleInterface += "  input logic out_ready_i,\n"
        moduleInterface += "  output logic[WIDTH-1:0] result_o,\n".replaceAll("WIDTH", FpNewConfig.WIDTH.toString)
        for (i <- 0 until 5) {
            moduleInterface += "  output logic status_o_GENI,\n".replaceAll("GENI", i.toString)
        }
        moduleInterface += "  output logic busy_o,\n"
        moduleInterface += "  output logic early_valid_o\n"
        moduleInterface += ");\n\n"

        var coreInstantiation = "  logic [NUM_OPERANDS-1:0][WIDTH-1:0] operands_i;\n"
            .replaceAll("NUM_OPERANDS", FpNewConfig.NUM_OPERANDS.toString)
            .replaceAll("WIDTH", FpNewConfig.WIDTH.toString)

        for (i <- 0 until FpNewConfig.NUM_OPERANDS) {
            // 把 Chisel 生成的 operands_i_0/1/2 平铺端口重新拼成 FPNEW packed 数组。
            coreInstantiation += "  assign operands_i[GENI] = operands_i_GENI;\n".replaceAll("GENI", i.toString)
        }

        coreInstantiation += "  fpnew_pkg::status_t status_o_pkg;\n"
        for (i <- 0 until 5) {
            // FPNEW status_t 展开成 5 个 fflags bit。
            coreInstantiation += "  assign status_o_GENI = status_o_pkg[GENI];\n".replaceAll("GENI", i.toString)
        }

        // FPNEW 实现配置: ADD/MUL、NONCOMP、CONV 并行, DIV/SQRT 合并, 分布式流水。
        coreInstantiation += """  localparam fpnew_pkg::fpu_implementation_t impl = '{
        |  PipeRegs:   '{default: 'd3},
        |  UnitTypes:  '{'{default: fpnew_pkg::PARALLEL}, // ADDMUL
        |                '{default: fpnew_pkg::MERGED},   // DIVSQRT
        |                '{default: fpnew_pkg::PARALLEL}, // NONCOMP
        |                '{default: fpnew_pkg::MERGED}},  // CONV
        |  PipeConfig: fpnew_pkg::DISTRIBUTED
        |};
        |""".stripMargin

        coreInstantiation += """  fpnew_top#(
        |      .Features(FEATURES),
        |      .Implementation(impl),
        |      .DivSqrtSel(DIVSQRT_SEL)
        |    ) core(
        |    .clk_i(clk_i),
        |    .rst_ni(rst_ni),
        |    .operands_i(operands_i),
        |    .rnd_mode_i(fpnew_pkg::roundmode_e'(rnd_mode_i)),
        |    .op_i(fpnew_pkg::operation_e'(op_i)),
        |    .op_mod_i(op_mod_i),
        |    .src_fmt_i(fpnew_pkg::fp_format_e'(src_fmt_i)),
        |    .dst_fmt_i(fpnew_pkg::fp_format_e'(dst_fmt_i)),
        |    .int_fmt_i(fpnew_pkg::INT32),
        |    .vectorial_op_i(1'b0),
        |    .tag_i(1'b0),
        |    .simd_mask_i(1'b0),
        |    .in_valid_i(in_valid_i),
        |    .flush_i(flush_i),
        |    .out_ready_i(out_ready_i),
        |    .in_ready_o(in_ready_o),
        |    .result_o(result_o),
        |    .status_o(status_o_pkg),
        |    .tag_o(),
        |    .out_valid_o(out_valid_o),
        |    .busy_o(busy_o),
        |    .early_valid_o(early_valid_o)
        |  );
        |""".replaceAll("DIVSQRT_SEL", if (p.floatPulpDivsqrt != 0 || p.enableZfbfmin) "fpnew_pkg::PULP" else "fpnew_pkg::TH32")
            .replaceAll("FEATURES", if (p.enableZfbfmin) """fpnew_pkg::fpu_features_t'{
        |  Width:         32,
        |  EnableVectors: 1'b0,
        |  EnableNanBox:  1'b1,
        |  FpFmtMask:     5'b10001,
        |  IntFmtMask:    4'b0010
        |}""" else "fpnew_pkg::RV32F").stripMargin

        moduleInterface + coreInstantiation + "endmodule\n"
    }
}

class FloatCoreWrapper(p: Parameters) extends BlackBox with HasBlackBoxInline
                                                       with HasBlackBoxResource {
    val io = IO(new Bundle {
        val clk_i = Input(Clock())                       // FPNEW 时钟
        val rst_ni = Input(AsyncReset())                 // FPNEW 低有效复位
        val in_valid_i = Input(Bool())                   // 输入操作有效
        val in_ready_o = Output(Bool())                  // FPNEW 可接收输入
        val operands_i = Input(Vec(FpNewConfig.NUM_OPERANDS, UInt(FpNewConfig.WIDTH.W))) // 3 个 32-bit 操作数
        val op_i = Input(UInt(FpNewConfig.OP_BITS.W))    // FPNEW 操作类型
        val op_mod_i = Input(Bool())                     // add/sub、符号/取反等修饰位
        val rnd_mode_i = Input(UInt(3.W))                // 舍入模式
        val src_fmt_i = Input(UInt(3.W))                 // 源 FP 格式
        val dst_fmt_i = Input(UInt(3.W))                 // 目标 FP 格式
        val flush_i = Input(Bool())                      // FPNEW flush, 当前 FloatCore 固定不使用

        val out_valid_o = Output(Bool())                 // 输出结果有效
        val out_ready_i = Input(Bool())                  // 下游可接收输出
        val result_o = Output(UInt(FpNewConfig.WIDTH.W)) // FPNEW 结果
        val status_o = Output(Vec(5, Bool()))            // fflags 异常标志
        val busy_o = Output(Bool())                      // FPNEW 忙状态
        val early_valid_o = Output(Bool())               // FPNEW 提前有效提示
    })
    // FPNEW 及其依赖的 SystemVerilog 资源。
    addResource("external/common_cells/include/common_cells/registers.svh")
    addResource("external/common_cells/src/cf_math_pkg.sv")
    addResource("external/common_cells/src/lzc.sv")
    addResource("external/common_cells/src/rr_arb_tree.sv")
    addResource("external/cvfpu/src/fpnew_pkg.sv")
    addResource("external/cvfpu/src/fpnew_cast_multi.sv")
    addResource("external/cvfpu/src/fpnew_classifier.sv")
    if (p.floatPulpDivsqrt == 0 && !p.enableZfbfmin) {
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v")
        addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v")
        addResource("external/cvfpu/src/fpnew_divsqrt_th_32.sv")
    } else {
        addResource("external/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/control_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv")
        addResource("external/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv")
        addResource("external/cvfpu/src/fpnew_divsqrt_multi.sv")
    }
    addResource("external/cvfpu/src/fpnew_fma.sv")
    addResource("external/cvfpu/src/fpnew_fma_multi.sv")
    addResource("external/cvfpu/src/fpnew_noncomp.sv")
    addResource("external/cvfpu/src/fpnew_opgroup_block.sv")
    addResource("external/cvfpu/src/fpnew_opgroup_fmt_slice.sv")
    addResource("external/cvfpu/src/fpnew_opgroup_multifmt_slice.sv")
    addResource("external/cvfpu/src/fpnew_rounding.sv")
    addResource("external/cvfpu/src/fpnew_top.sv")
    setInline("FloatCoreWrapper.sv", GenerateCoreShimSource(p))
}

class FloatCore(p: Parameters) extends Module {
    val io = IO(new FloatCoreIO(p))

    // ---- 指令入口队列 ----
    // 1 深度队列把 Dispatch 发来的浮点指令保存到 FPNEW 可接收/输出完成为止。
    val instQueue = Module(new Queue(new FloatInstruction, 1))
    instQueue.io.enq <> MakeDecoupled(io.inst.valid, instQueue.io.count === 0.U, io.inst.bits)
    val inst = instQueue.io.deq                          // 当前等待执行/完成的浮点指令
    io.inst.ready := (instQueue.io.count === 0.U)         // 队列为空时才能接收新指令

    val rstn = (!reset.asBool).asAsyncReset               // FPNEW wrapper 使用低有效异步复位
    val floatCoreWrapper = Module(new FloatCoreWrapper(p)) // FPNEW BlackBox wrapper

    floatCoreWrapper.io.clk_i := clock
    floatCoreWrapper.io.rst_ni := rstn

    // ---- RISC-V OP-FP funct5 → FPNEW operation 映射 ----
    val opfp_operation = MuxLookup(inst.bits.funct5, FpNewOperation.ADD)(Seq(
        // FPNEW 对 add/sub 使用相同 operation，通过 op_mod_i 区分加法和减法。
        "b00000".U -> FpNewOperation.ADD,               // FADD
        "b00001".U -> FpNewOperation.ADD,               // FSUB, 通过 op_mod 区分
        "b00010".U -> FpNewOperation.MUL,               // FMUL
        "b00011".U -> FpNewOperation.DIV,               // FDIV
        "b01011".U -> FpNewOperation.SQRT,              // FSQRT
        "b00100".U -> FpNewOperation.SGNJ,              // FSGNJ/FSGNJN/FSGNJX
        "b00101".U -> FpNewOperation.MINMAX,            // FMIN/FMAX
        "b11000".U -> FpNewOperation.F2I,               // FCVT.W.S / FCVT.WU.S
        "b10100".U -> FpNewOperation.CMP,               // FEQ/FLT/FLE
        "b11100".U -> FpNewOperation.CLASSIFY,          // FCLASS 或 FMV.X.W 特例
        "b11010".U -> FpNewOperation.I2F,               // FCVT.S.W / FCVT.S.WU
        "b01000".U -> FpNewOperation.F2F,               // FP 格式转换
    ))
    val opfp_mod = MuxLookup(inst.bits.funct5, 0.U(1.W))(Seq(
        "b00000".U -> 0.U(1.W), // ADD
        "b00001".U -> 1.U(1.W), // SUB
        "b00100".U -> 1.U(1.W), // SGNJ/Nan-boxing 相关修饰
        "b11000".U -> inst.bits.rs2(0), // F2I: 0 为有符号，1 为无符号
        "b11010".U -> inst.bits.rs2(0), // I2F: 符号选择规则同上
    ))

    // opcode 决定是普通 OP-FP、FMA 族还是 store 占位。
    val op_i = MuxLookup(inst.bits.opcode, FpNewOperation.ADD)(Seq(
        FloatOpcode.OPFP -> opfp_operation,             // 普通浮点算术/转换/比较
        FloatOpcode.MADD -> FpNewOperation.FMADD,       // FMADD
        FloatOpcode.MSUB -> FpNewOperation.FMADD,       // FMSUB, 通过 op_mod 区分
        FloatOpcode.NMADD -> FpNewOperation.FNMSUB,     // FNMADD
        FloatOpcode.NMSUB -> FpNewOperation.FNMSUB,     // FNMSUB
        FloatOpcode.STOREFP -> FpNewOperation.STORE,    // 浮点 store 不送 FPNEW
    ))
    val op_mod_i = MuxLookup(inst.bits.opcode, 0.U(1.W))(Seq(
        FloatOpcode.OPFP -> opfp_mod,                   // OP-FP 内部修饰位
        FloatOpcode.MADD -> 0.U(1.W),                   // +a*b+c
        FloatOpcode.MSUB -> 1.U(1.W),                   // +a*b-c
        FloatOpcode.NMADD -> 1.U(1.W),                  // -(a*b+c) 语义由 FPNEW FNMSUB+mod 实现
        FloatOpcode.NMSUB -> 0.U(1.W),
    ))

    // ---- FRegfile 读端口使能 ----
    // FPNEW operand0/1/2 对不同操作的使用方式不同, 这里只对真正需要的源寄存器发起读。
    // 具体端口约定来自 fpnew README，这里按 operation 生成三个读端口的 valid。
    // | 读端口             | 默认含义                 | 特殊情况                                  |
    // | --------------- | -------------------- | ------------------------------------- |
    // | `read_ports(0)` | operand0 / rs1       | I2F 时 operand0 来自整数 `rs1.data`        |
    // | `read_ports(1)` | operand1 / rs2 或 rs1 | ADD/SUB 时 operand1 使用 rs1             |
    // | `read_ports(2)` | operand2 / rs3 或 rs2 | ADD/SUB 时 operand2 使用 rs2；FMA 时使用 rs3 |
    val read_port_0_valid =
        MuxOR(op_i =/= FpNewOperation.ADD, true.B) // 除 ADD/SUB 外，其余操作都使用 operand0
    val read_port_1_valid = op_i.isOneOf(FpNewOperation.FMADD, FpNewOperation.FNMSUB) ||
    (
        inst.bits.opcode === FloatOpcode.OPFP &&
        !opfp_operation.isOneOf(FpNewOperation.SQRT, FpNewOperation.CLASSIFY, FpNewOperation.F2I, FpNewOperation.I2F, FpNewOperation.F2F)
    )
    val read_port_2_valid = op_i.isOneOf(FpNewOperation.FMADD, FpNewOperation.FNMSUB) ||
                            (inst.bits.opcode === FloatOpcode.OPFP && opfp_operation === FpNewOperation.ADD)
    val read_ports_valid = VecInit(Seq(
        read_port_0_valid,
        read_port_1_valid,
        read_port_2_valid,
    ))
    for (i <- 0 until FpNewConfig.NUM_OPERANDS) {
        io.read_ports(i).valid := read_ports_valid(i) && inst.valid // 对 FRegfile 的读请求
        if (i == 0) {
            // I2F 的 operand0 来自整数 rs1, 其它操作来自浮点寄存器读端口。
            floatCoreWrapper.io.operands_i(0) :=
                Mux((inst.bits.opcode === FloatOpcode.OPFP) && (opfp_operation === FpNewOperation.I2F),
                    io.rs1.data,
                    io.read_ports(0).data.asWord)
        } else {
            floatCoreWrapper.io.operands_i(i) := io.read_ports(i).data.asWord // operand1/2 来自 FRegfile
        }
    }

    // FMV.X.W / FMV.W.X 是 bit move, 不需要经过 FPNEW 运算。
    val fmv_x_w = inst.valid && (inst.bits.opcode === FloatOpcode.OPFP) && (inst.bits.funct5 === "b11100".U) && (inst.bits.rm === "b000".U)
    val fmv_w_x = inst.valid && (inst.bits.opcode === FloatOpcode.OPFP) && (inst.bits.funct5 === "b11110".U) && (inst.bits.rm === "b000".U)
    val fmv = (fmv_x_w || fmv_w_x)                      // 任一 FMV 特例
    val storefp = (inst.valid && (inst.bits.opcode === FloatOpcode.STOREFP)) // 浮点 store 只读 FRegfile/LSU

    val op0_addr = inst.bits.rs1                        // operand0 默认读 rs1
    val op1_addr = Mux(op_i === FpNewOperation.ADD, inst.bits.rs1, inst.bits.rs2) // ADD/SUB 的 operand1 使用 rs1
    val op2_addr = Mux(op_i === FpNewOperation.ADD, inst.bits.rs2, inst.bits.rs3) // ADD/SUB 的 operand2 使用 rs2
    io.read_ports(0).addr := op0_addr                   // FRegfile 读端口 0 地址
    io.read_ports(1).addr := op1_addr                   // FRegfile 读端口 1 地址
    io.read_ports(2).addr := op2_addr                   // FRegfile 读端口 2 地址

    // ---- FPNEW 控制信号 ----
    floatCoreWrapper.io.op_i := op_i.asUInt             // FPNEW 操作类型
    floatCoreWrapper.io.op_mod_i := op_mod_i            // FPNEW 操作修饰位
    floatCoreWrapper.io.src_fmt_i := inst.bits.src_fmt.asUInt // 源格式
    floatCoreWrapper.io.dst_fmt_i := inst.bits.dst_fmt.asUInt // 目标格式
    val (inst_rm, inst_rm_valid) = FpNewRoundingMode.safe(inst.bits.rm) // 指令 rm 字段
    val (csr_rm, csr_rm_valid) = FpNewRoundingMode.safe(io.csr.out.frm) // CSR frm 字段
    // DYN 表示使用 CSR.frm; 非法 rm 会让 rnd_mode.valid=false, 阻止送入 FPNEW。
    val rnd_mode = MuxCase(MakeValid(false.B, inst_rm), Seq(
        !inst_rm_valid -> MakeValid(false.B, inst_rm),
        (inst_rm =/= FpNewRoundingMode.DYN) -> MakeValid(true.B, inst_rm),
        !csr_rm_valid -> MakeValid(false.B, csr_rm),
        (csr_rm_valid && (csr_rm === FpNewRoundingMode.DYN)) -> MakeValid(false.B, csr_rm),
        csr_rm_valid -> MakeValid(true.B, csr_rm),
    ))
    floatCoreWrapper.io.rnd_mode_i := rnd_mode.bits.asUInt // 最终舍入模式

    // 跟踪指令是否已经被 FPNEW 输入侧接收。
    // 这样 Dispatch 可以在 FPNEW 接收后尽早解除输入反压，
    // 同时 FloatCore 仍等待可能多周期执行的指令完成，例如 DIV/SQRT。
    // | 事件                 | `fpuActive` |
    // | ------------------ | ----------- |
    // | FPNEW 接收输入         | 置 1         |
    // | 当前指令完成 `inst.fire` | 清 0         |
    // | 无事件                | 保持          |
    val fpuActive = RegInit(false.B)                    // FPNEW 已接收指令但尚未输出完成
    fpuActive := MuxCase(fpuActive, Seq(
        inst.fire -> false.B,                           // 当前指令完成并出队
        (floatCoreWrapper.io.in_valid_i && floatCoreWrapper.io.in_ready_o) -> true.B, // FPNEW 接收输入
    ))
    floatCoreWrapper.io.flush_i := false.B              // 当前不主动刷新 FPNEW
    floatCoreWrapper.io.in_valid_i := (inst.valid && !fmv) && !fpuActive && rnd_mode.valid // FMV 不送 FPNEW

    // ---- 浮点寄存器写回 ----
    // write_ports(0): FPNEW 结果或 FMV.W.X 写 FRegfile。
    // 标量写回类指令不写 FRegfile，store 指令也不写 FRegfile。
    io.write_ports(0).valid := ((floatCoreWrapper.io.out_valid_o && inst.fire && !inst.bits.scalar_rd) || fmv_w_x) && !storefp
    io.write_ports(0).addr := inst.bits.rd              // 浮点 rd
    io.write_ports(0).data := Fp32.fromWord(Mux(fmv_w_x, io.rs1.data, floatCoreWrapper.io.result_o)) // FMV.W.X 用整数 rs1

    // write_ports(1): LSU load-fp 返回写 FRegfile。
    io.write_ports(1).valid := io.lsu_rd.valid
    io.write_ports(1).addr := io.lsu_rd.bits.addr       // load 目标 freg
    io.write_ports(1).data := Fp32.fromWord(io.lsu_rd.bits.data) // load 数据转 FP32

    // FPNEW 状态输出直接汇入 CSR.fflags；FMV 不产生 fflags。
    io.csr.in.fflags.valid := (floatCoreWrapper.io.out_valid_o && inst.fire && !fmv)
    io.csr.in.fflags.bits := floatCoreWrapper.io.status_o.asUInt

    // ---- 标量寄存器写回 ----
    // F2I/CMP/CLASSIFY/FMV.X.W 等写整数 rd, 通过 scalar_rd 管道返回 SCore Regfile。
    val scalar_rd_pre_pipe = Wire(Decoupled(new RegfileWriteDataIO))
    scalar_rd_pre_pipe.valid := (((floatCoreWrapper.io.in_valid_i && floatCoreWrapper.io.in_ready_o) || fpuActive) && floatCoreWrapper.io.out_valid_o && floatCoreWrapper.io.out_ready_i && inst.bits.scalar_rd) || (fmv_x_w)
    scalar_rd_pre_pipe.bits.addr := inst.bits.rd         // 整数 rd
    scalar_rd_pre_pipe.bits.data := Mux(fmv_x_w, io.read_ports(0).data.asWord, floatCoreWrapper.io.result_o) // FMV.X.W 直接搬运 FP bits

    val scalar_rd_pipe = Queue(scalar_rd_pre_pipe, 2, false) // 标量写回加 2 深度队列解耦
    io.scalar_rd <> scalar_rd_pipe

    // FPNEW 输出 ready：标量写回要等 scalar pipe ready，浮点写回只要求 inst 有效。
    floatCoreWrapper.io.out_ready_i := (inst.valid && inst.bits.scalar_rd && scalar_rd_pre_pipe.ready) || (inst.valid && !inst.bits.scalar_rd)
    // 当前指令完成条件:
    //   FPNEW 输入已被接收或已处于 active，输出 valid 且可接收；
    //   或者是 FMV 特例，可直接完成。
    inst.ready := (((floatCoreWrapper.io.in_ready_o && floatCoreWrapper.io.in_valid_i) || fpuActive) && floatCoreWrapper.io.out_ready_i && floatCoreWrapper.io.out_valid_o) || fmv
}
