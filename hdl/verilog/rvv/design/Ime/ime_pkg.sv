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

`ifndef HDL_VERILOG_RVV_DESIGN_IME_IME_PKG_SV
`define HDL_VERILOG_RVV_DESIGN_IME_IME_PKG_SV

// Zvvm compute instruction fields. RVVCmd.bits contains instruction[31:7].
`define IME_RVV_OPCODE          2'b10
`define IME_OPIVV               3'b000
`define IME_OPFVV               3'b001
`define IME_VMMACC_FUNCT6       6'b111000
`define IME_VWMMACC_FUNCT6      6'b111001
`define IME_VQMMACC_FUNCT6      6'b111010
`define IME_V8WMMACC_FUNCT6     6'b111011
`define IME_VFMMACC_FUNCT6      6'b010100
`define IME_VFWMMACC_FUNCT6     6'b010101
`define IME_VFQMMACC_FUNCT6     6'b010110
`define IME_VF8WMMACC_FUNCT6    6'b010111

// Bitmap positions for IME illegal-instruction diagnostics. The bitmap is
// debug information only; legal_o is the architectural decision.
`define IME_ILLEGAL_FEATURE_OFF        0
`define IME_ILLEGAL_BAD_VTYPE          1
`define IME_ILLEGAL_BAD_LAMBDA         2
`define IME_ILLEGAL_BAD_SEW_W          3
`define IME_ILLEGAL_BAD_LMUL           4
`define IME_ILLEGAL_BAD_VL             5
`define IME_ILLEGAL_BAD_EMUL_C         6
`define IME_ILLEGAL_BAD_GROUP_ALIGN    7
`define IME_ILLEGAL_GROUP_OVERFLOW     8
`define IME_ILLEGAL_BAD_VSTART         9
`define IME_ILLEGAL_BAD_MX            10
`define IME_ILLEGAL_RESERVED_TYPE_CELL 11
`define IME_ILLEGAL_REASON_WIDTH       12

// Standalone unit tests may compile IME modules without the Chisel-generated
// backend config.  Keep the architectural low-area profile as the fallback;
// production builds override every value from GenerateBackendConfig.
`ifndef IME_M_PAR
`define IME_M_PAR 1
`endif
`ifndef IME_N_PAR
`define IME_N_PAR 1
`endif
`ifndef IME_K_PAR
`define IME_K_PAR 1
`endif
`define IME_INT_LANES (`IME_M_PAR * `IME_N_PAR * `IME_K_PAR)
`ifndef IME_FP_LANES
`define IME_FP_LANES 1
`endif
`ifndef IME_FP_PSM
`define IME_FP_PSM 1'b0
`endif
`ifndef IME_INT_OPT
`define IME_INT_OPT 1'b0
`endif
`ifndef IME_INT_STREAM
`define IME_INT_STREAM 1'b0
`endif
`ifndef IME_ODN_OPT
`define IME_ODN_OPT 1'b0
`endif
`ifndef IME_RESULT_INDEX_OPT
`define IME_RESULT_INDEX_OPT 1'b0
`endif
`ifndef IME_FETCH_PIPELINE
`define IME_FETCH_PIPELINE 1'b0
`endif
`ifndef IME_FP_ORDERED
`define IME_FP_ORDERED 1'b0
`endif
`ifndef IME_MAX_M
`define IME_MAX_M 16
`endif
`ifndef IME_MAX_C_REGS
`define IME_MAX_C_REGS 16
`endif

// Canonical IME tile-layout helpers.  These functions only translate already
// decoded geometry; instruction legality remains authoritative in DE1.
package ime_pkg;
  function automatic logic ime_is_power_of_two(
      input logic [8:0] value
  );
    ime_is_power_of_two = (value != '0) &&
                          ((value & (value - 1'b1)) == '0);
  endfunction

  function automatic logic [3:0] ime_power_of_two_log2(
      input logic [8:0] value
  );
    unique case (value)
      9'd1:   ime_power_of_two_log2 = 4'd0;
      9'd2:   ime_power_of_two_log2 = 4'd1;
      9'd4:   ime_power_of_two_log2 = 4'd2;
      9'd8:   ime_power_of_two_log2 = 4'd3;
      9'd16:  ime_power_of_two_log2 = 4'd4;
      9'd32:  ime_power_of_two_log2 = 4'd5;
      9'd64:  ime_power_of_two_log2 = 4'd6;
      9'd128: ime_power_of_two_log2 = 4'd7;
      9'd256: ime_power_of_two_log2 = 4'd8;
      default: ime_power_of_two_log2 = 4'd0;
    endcase
  endfunction

  // Map a row-major tile element into the IME striping across a vector
  // register group.  lambda, group_multiplier, and elements_per_register are
  // powers of two for every legal command.
  function automatic logic [15:0] ime_tile_reg_index(
      input logic [15:0] sequential_index,
      input logic [4:0] group_multiplier,
      input logic [6:0] lambda,
      input logic [8:0] elements_per_register
  );
    int unsigned lambda_log2;
    int unsigned group_log2;
    int unsigned elements_per_register_log2;
    int unsigned line_size_log2;
    int unsigned line_size_mask;
    int unsigned lambda_mask;
    int unsigned line;
    int unsigned element_in_line;
    int unsigned register_offset;
    int unsigned element_offset;
    begin
      lambda_log2 = int'(ime_power_of_two_log2({2'b0, lambda}));
      group_log2 =
          int'(ime_power_of_two_log2({4'b0, group_multiplier}));
      elements_per_register_log2 =
          int'(ime_power_of_two_log2(elements_per_register));
      line_size_log2 = lambda_log2 + group_log2;
      line_size_mask = (32'd1 << line_size_log2) - 1;
      lambda_mask = (32'd1 << lambda_log2) - 1;
      line = int'(sequential_index) >> line_size_log2;
      element_in_line = int'(sequential_index) & line_size_mask;
      register_offset = element_in_line >> lambda_log2;
      element_offset = (line << lambda_log2) +
                       (element_in_line & lambda_mask);
      ime_tile_reg_index = 16'(
          (register_offset << elements_per_register_log2) + element_offset);
    end
  endfunction

  function automatic logic [15:0] ime_row_major_index(
      input logic [15:0] row,
      input logic [15:0] column,
      input logic [15:0] row_stride
  );
    ime_row_major_index = 16'(row * row_stride + column);
  endfunction

  // Equivalent row-major mapping for an already validated power-of-two
  // stride.  Keeping the logarithm explicit lets the optimized operand
  // selector share geometry predecode instead of replicating multipliers.
  function automatic logic [15:0] ime_row_major_index_pow2(
      input logic [15:0] row,
      input logic [15:0] column,
      input logic [3:0] row_stride_log2
  );
    ime_row_major_index_pow2 =
        16'((row << row_stride_log2) + column);
  endfunction

  // Same striping map as ime_tile_reg_index, with the power-of-two logarithms
  // supplied once per command by the optimized operand selector.
  function automatic logic [15:0] ime_tile_reg_index_predecoded(
      input logic [15:0] sequential_index,
      input logic [3:0] group_log2,
      input logic [3:0] lambda_log2,
      input logic [3:0] elements_per_register_log2
  );
    logic [4:0] line_size_log2;
    logic [15:0] line_size_mask;
    logic [15:0] lambda_mask;
    logic [15:0] line;
    logic [15:0] element_in_line;
    logic [15:0] register_offset;
    logic [15:0] element_offset;
    begin
      line_size_log2 = {1'b0, lambda_log2} + {1'b0, group_log2};
      line_size_mask = 16'((17'd1 << line_size_log2) - 1'b1);
      lambda_mask = 16'((17'd1 << lambda_log2) - 1'b1);
      line = sequential_index >> line_size_log2;
      element_in_line = sequential_index & line_size_mask;
      register_offset = element_in_line >> lambda_log2;
      element_offset = (line << lambda_log2) +
                       (element_in_line & lambda_mask);
      ime_tile_reg_index_predecoded =
          16'((register_offset << elements_per_register_log2) +
              element_offset);
    end
  endfunction
endpackage

`endif  // HDL_VERILOG_RVV_DESIGN_IME_IME_PKG_SV
