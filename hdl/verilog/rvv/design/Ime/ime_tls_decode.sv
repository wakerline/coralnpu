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

// Decode and pre-execution legality for Zvvmtls/Zvvmttls.  This module is
// deliberately independent of the ordinary RVV LSU decode.  Tile memory uses
// width=111 with its own element ordering and permits nonzero vstart.
module ime_tls_decode #(
  parameter int VLEN = 128,
  parameter int VL_WIDTH = $clog2(VLEN) + 1,
  parameter bit ENABLE_TLS = 1'b0,
  parameter bit ENABLE_TTLS = 1'b0,
  parameter logic [6:0] LAMBDA_MASK_SEW8 = 7'b0,
  parameter logic [6:0] LAMBDA_MASK_SEW16 = 7'b0,
  parameter logic [6:0] LAMBDA_MASK_SEW32 = 7'b0
) (
  input  logic [31:0]         inst_i,
  input  logic                vill_i,
  input  logic [2:0]          sew_i,
  input  logic [2:0]          lmul_i,
  input  logic [VL_WIDTH-1:0] vl_i,
  input  logic [2:0]          dynamic_lambda_encoding_i,

  output logic                is_tile_ls_o,
  output logic                is_load_o,
  output logic                is_store_o,
  output logic                transpose_o,
  output logic                vm_o,
  output logic [4:0]          vector_base_o,
  output logic [4:0]          rs1_o,
  output logic [4:0]          rs2_o,
  output logic [2:0]          effective_lambda_encoding_o,
  output logic [6:0]          effective_lambda_o,
  output logic [3:0]          lmul_o,
  output logic [31:0]         group_mask_o,
  output logic                legal_o,
  output logic [7:0]          illegal_reason_o
);
  localparam int ILLEGAL_FEATURE = 0;
  localparam int ILLEGAL_VTYPE = 1;
  localparam int ILLEGAL_LAMBDA = 2;
  localparam int ILLEGAL_LMUL = 3;
  localparam int ILLEGAL_VL = 4;
  localparam int ILLEGAL_GROUP_ALIGN = 5;
  localparam int ILLEGAL_GROUP_BOUNDS = 6;
  localparam int ILLEGAL_MASK_OVERLAP = 7;

  logic is_order;
  logic is_transpose;
  logic feature_enabled;
  logic [2:0] immediate_lambda_encoding;
  logic [6:0] lambda_mask;
  logic lambda_supported;
  logic integer_lmul;
  logic vl_multiple;
  logic group_aligned;
  logic group_in_bounds;
  logic masked_load_v0_overlap;
  logic [VL_WIDTH:0] line_size;

  assign is_load_o = inst_i[6:0] == 7'b0000111;
  assign is_store_o = inst_i[6:0] == 7'b0100111;
  assign is_order = inst_i[28:26] == 3'b100;
  assign is_transpose = inst_i[28:26] == 3'b101;
  assign is_tile_ls_o = (is_load_o || is_store_o) &&
      (inst_i[14:12] == 3'b111) && (is_order || is_transpose);
  assign transpose_o = is_transpose;
  assign vm_o = inst_i[25];
  assign vector_base_o = inst_i[11:7];
  assign rs1_o = inst_i[19:15];
  assign rs2_o = inst_i[24:20];
  assign immediate_lambda_encoding = inst_i[31:29];
  assign effective_lambda_encoding_o =
      (immediate_lambda_encoding != 3'd0) ?
          immediate_lambda_encoding : dynamic_lambda_encoding_i;
  assign feature_enabled = (is_order && ENABLE_TLS) ||
      (is_transpose && ENABLE_TTLS);

  always_comb begin
    effective_lambda_o = '0;
    if (effective_lambda_encoding_o != 3'd0)
      effective_lambda_o = 7'd1 << (effective_lambda_encoding_o - 1'b1);

    unique case (sew_i)
      3'd0: lambda_mask = LAMBDA_MASK_SEW8;
      3'd1: lambda_mask = LAMBDA_MASK_SEW16;
      3'd2: lambda_mask = LAMBDA_MASK_SEW32;
      default: lambda_mask = 7'b0;
    endcase

    lambda_supported = 1'b0;
    if (effective_lambda_encoding_o != 3'd0)
      lambda_supported = lambda_mask[effective_lambda_encoding_o - 1'b1];

    integer_lmul = lmul_i <= 3'd3;
    lmul_o = integer_lmul ? (4'd1 << lmul_i[1:0]) : 4'd0;
    line_size = effective_lambda_o * lmul_o;
    // lambda and integer LMUL are powers of two, so the multiple check is a
    // mask operation and does not infer a divider.
    vl_multiple = (line_size != '0) &&
        ((vl_i & (line_size[VL_WIDTH-1:0] - 1'b1)) == '0);

    unique case (lmul_o)
      4'd1: group_aligned = 1'b1;
      4'd2: group_aligned = vector_base_o[0] == 1'b0;
      4'd4: group_aligned = vector_base_o[1:0] == 2'b0;
      4'd8: group_aligned = vector_base_o[2:0] == 3'b0;
      default: group_aligned = 1'b0;
    endcase
    group_in_bounds = ({1'b0, vector_base_o} + {2'b0, lmul_o}) <= 6'd32;
    masked_load_v0_overlap = is_load_o && !vm_o &&
        (vector_base_o == 5'd0);

    group_mask_o = '0;
    unique case (lmul_o)
      4'd1: group_mask_o = 32'h0000_0001 << vector_base_o;
      4'd2: group_mask_o = 32'h0000_0003 << vector_base_o;
      4'd4: group_mask_o = 32'h0000_000f << vector_base_o;
      4'd8: group_mask_o = 32'h0000_00ff << vector_base_o;
      default: ;
    endcase

    illegal_reason_o = '0;
    if (is_tile_ls_o) begin
      illegal_reason_o[ILLEGAL_FEATURE] = !feature_enabled;
      illegal_reason_o[ILLEGAL_VTYPE] = vill_i;
      illegal_reason_o[ILLEGAL_LAMBDA] =
          (effective_lambda_encoding_o == 3'd0) || !lambda_supported;
      illegal_reason_o[ILLEGAL_LMUL] = !integer_lmul;
      illegal_reason_o[ILLEGAL_VL] = !vl_multiple;
      illegal_reason_o[ILLEGAL_GROUP_ALIGN] = !group_aligned;
      illegal_reason_o[ILLEGAL_GROUP_BOUNDS] = !group_in_bounds;
      illegal_reason_o[ILLEGAL_MASK_OVERLAP] = masked_load_v0_overlap;
    end
  end

  assign legal_o = is_tile_ls_o && (illegal_reason_o == '0);

endmodule
