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

// Decode and complete pre-execution legality for CoralNPU's ELEN=32 IME
// profile.  The optional Zvvfmm profile deliberately exposes only FP32
// accumulator cells: FP32, FP16/BF16, OFP8 and OFP4 inputs, plus the FP/MX
// and integer-input MX cells whose C format is FP32.  Narrow accumulator
// cells remain illegal until a separately verified implementation exists.
module ime_decode #(
  parameter int VLEN = 128,
  parameter int VL_WIDTH = $clog2(VLEN) + 1,
  parameter bit ENABLE_IME = 1'b1,
  parameter bit ENABLE_FP = 1'b0,
  parameter logic [6:0] LAMBDA_MASK_SEW8 = 7'b0,
  parameter logic [6:0] LAMBDA_MASK_SEW16 = 7'b0,
  parameter logic [6:0] LAMBDA_MASK_SEW32 = 7'b000_0011
) (
  input  logic [1:0]          cmd_opcode_i,
  input  logic [24:0]         cmd_bits_i,
  input  logic                vill_i,
  input  logic [2:0]          sew_i,
  input  logic [2:0]          lmul_i,
  input  logic [VL_WIDTH-1:0] vl_i,
  input  logic [VL_WIDTH-2:0] vstart_i,
  input  logic [2:0]          lambda_encoding_i,
  input  logic                bs_i,
  input  logic                altfmt_a_i,
  input  logic                altfmt_b_i,
  input  logic                altfmt_c_i,
  input  logic [2:0]          frm_i,

  output logic                is_ime_o,
  output logic                is_supported_integer_o,
  output logic                is_supported_fp_o,
  output logic                is_mx_o,
  output logic                is_integer_mx_o,
  output logic                legal_o,
  output logic [`IME_ILLEGAL_REASON_WIDTH-1:0] illegal_reason_o,
  output logic [4:0]          vs1_o,
  output logic [4:0]          vs2_o,
  output logic [4:0]          vd_o,
  output logic                signed_a_o,
  output logic                signed_b_o,
  output logic [1:0]          w_log2_o,
  output logic [2:0]          eew_log2_o,
  output logic [6:0]          lambda_o,
  output logic [3:0]          lmul_o,
  output logic [4:0]          emul_c_o,
  output logic [VL_WIDTH-1:0] m_o,
  output logic [VL_WIDTH-1:0] n_o,
  output logic [11:0]         k_eff_o,
  output logic [31:0]         read_mask_o,
  output logic [31:0]         write_mask_o
);
  logic [5:0] funct6;
  logic vm;
  logic [2:0] funct3;
  logic is_integer_family;
  logic is_fp_family;
  logic ordinary_integer_type;
  logic fp32_accumulator_cell;
  logic fp_input_cell;
  logic fp_mx_cell;
  logic integer_mx_cell;
  logic fp_rounding_mode_valid;
  logic microscaling_legal;
  logic overlaps_v0;
  logic lambda_supported;
  logic lambda_valid;
  logic integer_lmul;
  logic vl_multiple;
  logic n_within_m;
  logic emul_c_valid;
  logic group_aligned;
  logic group_in_bounds;
  logic [6:0] lambda_mask;
  logic [11:0] decode_lmul_for_mx;
  logic [31:0] geometry_read_mask;

  assign funct6 = cmd_bits_i[24:19];
  assign vm = cmd_bits_i[18];
  assign vs2_o = cmd_bits_i[17:13];
  assign vs1_o = cmd_bits_i[12:8];
  assign funct3 = cmd_bits_i[7:5];
  assign vd_o = cmd_bits_i[4:0];

  assign is_integer_family =
      (cmd_opcode_i == `IME_RVV_OPCODE) &&
      (funct3 == `IME_OPIVV) &&
      (funct6 >= `IME_VMMACC_FUNCT6) &&
      (funct6 <= `IME_V8WMMACC_FUNCT6);
  assign is_fp_family =
      (cmd_opcode_i == `IME_RVV_OPCODE) &&
      (funct3 == `IME_OPFVV) &&
      (funct6 >= `IME_VFMMACC_FUNCT6) &&
      (funct6 <= `IME_VF8WMMACC_FUNCT6);
  assign is_ime_o = is_integer_family || is_fp_family;

  // funct6 advances with log2(W): W={1,2,4,8}. Table 88 reserves cells whose
  // input EEW would be below four bits. CoralNPU implements every non-reserved
  // vm=1 integer cell with SEW <= 32; SEW=64 remains unavailable because the
  // base vector implementation is Zve32x/Zve32f.
  assign w_log2_o = funct6[1:0];
  assign eew_log2_o = (3'd3 + sew_i) - {1'b0, w_log2_o};
  assign ordinary_integer_type =
      (sew_i <= 3'd2) &&
      ((w_log2_o == 2'd0) ||
       (w_log2_o == 2'd1) ||
       ((w_log2_o == 2'd2) && (sew_i >= 3'd1)) ||
       ((w_log2_o == 2'd3) && (sew_i == 3'd2)));
  assign is_supported_integer_o =
      is_integer_family && vm && ordinary_integer_type;

  // Zve32f-backed first FP profile.  Table 87 cells with SEW=32 and
  // altfmt(C)=0 are implemented for every non-reserved widening factor:
  //   W=1 FP32, W=2 FP16/BF16, W=4 E4M3/E5M2, W=8 E2M1.
  // For four-bit inputs altfmt_A/B=1 is reserved.  For FP32 inputs the two
  // input altfmt fields are ignored by the ISA.
  assign fp32_accumulator_cell = (sew_i == 3'd2) && !altfmt_c_i;
  always_comb begin
    fp_input_cell = 1'b0;
    unique case (w_log2_o)
      2'd0: fp_input_cell = fp32_accumulator_cell;
      2'd1: fp_input_cell = fp32_accumulator_cell;
      2'd2: fp_input_cell = fp32_accumulator_cell;
      2'd3: fp_input_cell =
          fp32_accumulator_cell && !altfmt_a_i && !altfmt_b_i;
      default: ;
    endcase
  end

  // Table 87 permits FP-input MX at the FP32 accumulator width for OFP8
  // (W=4) and E2M1 (W=8).  W=1 has no MX encoding and the FP16/BF16->FP32
  // W=2 row has no MX extension cell.
  assign fp_mx_cell =
      is_fp_family && !vm && fp32_accumulator_cell &&
      (((w_log2_o == 2'd2)) ||
       ((w_log2_o == 2'd3) && !altfmt_a_i && !altfmt_b_i));

  // Table 89 permits signed Int8->FP32 (W=4) and signed Int4->FP32 (W=8).
  // altfmt_A/B=1 is reserved for every integer-input MX instruction.
  assign integer_mx_cell =
      is_integer_family && !vm && fp32_accumulator_cell &&
      !altfmt_a_i && !altfmt_b_i &&
      ((w_log2_o == 2'd2) || (w_log2_o == 2'd3));

  assign is_mx_o = fp_mx_cell || integer_mx_cell;
  assign is_integer_mx_o = integer_mx_cell;
  assign fp_rounding_mode_valid = frm_i <= 3'd4;
  assign is_supported_fp_o =
      ENABLE_FP && fp_rounding_mode_valid &&
      ((is_fp_family && vm && fp_input_cell) || is_mx_o);

  // Section 36.7.3: E8M0 pairs are 16 bits, and bs=1 additionally requires
  // W*LMUL <= SEW.  Every MX source/destination group must exclude v0.
  assign microscaling_legal =
      (({5'b0, lambda_o} << (3 + sew_i)) >= 12'd16) &&
      (!bs_i || ((decode_lmul_for_mx << w_log2_o) <=
                  (12'd8 << sew_i)));
  assign overlaps_v0 = is_mx_o && geometry_read_mask[0];
  assign read_mask_o = geometry_read_mask | (is_mx_o ? 32'b1 : 32'b0);

  always_comb begin
    unique case (sew_i)
      3'd0: lambda_mask = LAMBDA_MASK_SEW8;
      3'd1: lambda_mask = LAMBDA_MASK_SEW16;
      3'd2: lambda_mask = LAMBDA_MASK_SEW32;
      default: lambda_mask = 7'b0;
    endcase

    unique case (lambda_encoding_i)
      3'd1: lambda_supported = lambda_mask[0];
      3'd2: lambda_supported = lambda_mask[1];
      3'd3: lambda_supported = lambda_mask[2];
      3'd4: lambda_supported = lambda_mask[3];
      3'd5: lambda_supported = lambda_mask[4];
      3'd6: lambda_supported = lambda_mask[5];
      3'd7: lambda_supported = lambda_mask[6];
      default: lambda_supported = 1'b0;
    endcase
  end

  ime_geometry #(
    .VLEN(VLEN),
    .VL_WIDTH(VL_WIDTH)
  ) u_geometry (
    .lambda_encoding_i(lambda_encoding_i),
    .sew_i(sew_i),
    .lmul_i(lmul_i),
    .w_log2_i(w_log2_o),
    .vl_i(vl_i),
    .vs1_i(vs1_o),
    .vs2_i(vs2_o),
    .vd_i(vd_o),
    .lambda_o(lambda_o),
    .lmul_o(lmul_o),
    .emul_c_o(emul_c_o),
    .m_o(m_o),
    .n_o(n_o),
    .k_eff_o(k_eff_o),
    .read_mask_o(geometry_read_mask),
    .write_mask_o(write_mask_o),
    .lambda_valid_o(lambda_valid),
    .integer_lmul_o(integer_lmul),
    .vl_multiple_o(vl_multiple),
    .n_within_m_o(n_within_m),
    .emul_c_valid_o(emul_c_valid),
    .group_aligned_o(group_aligned),
    .group_in_bounds_o(group_in_bounds)
  );

  // Integer signedness is independent for A and B. bs is intentionally not
  // consumed by the ordinary vm=1 integer form.
  assign signed_a_o = !altfmt_a_i;
  assign signed_b_o = !altfmt_b_i;

  always_comb begin
    illegal_reason_o = '0;
    if (is_ime_o) begin
      illegal_reason_o[`IME_ILLEGAL_FEATURE_OFF] = !ENABLE_IME;
      illegal_reason_o[`IME_ILLEGAL_BAD_VTYPE] = vill_i;
      illegal_reason_o[`IME_ILLEGAL_BAD_LAMBDA] =
          !lambda_valid || !lambda_supported;
      illegal_reason_o[`IME_ILLEGAL_BAD_SEW_W] =
          is_integer_family && vm && !ordinary_integer_type;
      illegal_reason_o[`IME_ILLEGAL_BAD_LMUL] = !integer_lmul;
      illegal_reason_o[`IME_ILLEGAL_BAD_VL] =
          !vl_multiple || !n_within_m;
      illegal_reason_o[`IME_ILLEGAL_BAD_EMUL_C] = !emul_c_valid;
      illegal_reason_o[`IME_ILLEGAL_BAD_GROUP_ALIGN] =
          !group_aligned;
      illegal_reason_o[`IME_ILLEGAL_GROUP_OVERFLOW] =
          !group_in_bounds;
      illegal_reason_o[`IME_ILLEGAL_BAD_VSTART] = vstart_i != '0;
      illegal_reason_o[`IME_ILLEGAL_BAD_MX] =
          ((!vm) && (!ENABLE_FP || !is_mx_o)) ||
          (is_mx_o && (!microscaling_legal || overlaps_v0));
      illegal_reason_o[`IME_ILLEGAL_RESERVED_TYPE_CELL] =
          !(is_supported_integer_o || is_supported_fp_o);
    end
  end

  assign legal_o =
      (is_supported_integer_o || is_supported_fp_o) &&
      (illegal_reason_o == '0);

  assign decode_lmul_for_mx = {{8{1'b0}}, lmul_o};

endmodule
