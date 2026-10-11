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

// Pure combinational Zvvm tile-geometry derivation. This module intentionally
// has no dependency on the existing VME/Zvt types or state.
module ime_geometry #(
  parameter int VLEN = 128,
  parameter int VL_WIDTH = $clog2(VLEN) + 1
) (
  input  logic [2:0]          lambda_encoding_i,
  input  logic [2:0]          sew_i,
  input  logic [2:0]          lmul_i,
  input  logic [1:0]          w_log2_i,
  input  logic [VL_WIDTH-1:0] vl_i,
  input  logic [4:0]          vs1_i,
  input  logic [4:0]          vs2_i,
  input  logic [4:0]          vd_i,

  output logic [6:0]          lambda_o,
  output logic [3:0]          lmul_o,
  output logic [4:0]          emul_c_o,
  output logic [VL_WIDTH-1:0] m_o,
  output logic [VL_WIDTH-1:0] n_o,
  output logic [11:0]         k_eff_o,
  output logic [31:0]         read_mask_o,
  output logic [31:0]         write_mask_o,
  output logic                lambda_valid_o,
  output logic                integer_lmul_o,
  output logic                vl_multiple_o,
  output logic                n_within_m_o,
  output logic                emul_c_valid_o,
  output logic                group_aligned_o,
  output logic                group_in_bounds_o
);
  localparam int VLEN_LOG2 = $clog2(VLEN);

  logic [2:0] lambda_log2;
  logic [1:0] lmul_log2;
  logic [3:0] sew_log2;
  logic [4:0] vl_divisor_log2;
  logic [4:0] m_divisor_log2;
  logic [4:0] emul_divisor_log2;
  logic [VL_WIDTH-1:0] vl_divisor;
  logic [3:0] k_shift;
  logic [31:0] vs1_mask;
  logic [31:0] vs2_mask;
  logic [31:0] vd_mask;

  function automatic logic [31:0] reg_group_mask(
      input logic [4:0] base,
      input logic [4:0] count
  );
    unique case (count)
      5'd1:  reg_group_mask = 32'h0000_0001 << base;
      5'd2:  reg_group_mask = 32'h0000_0003 << base;
      5'd4:  reg_group_mask = 32'h0000_000f << base;
      5'd8:  reg_group_mask = 32'h0000_00ff << base;
      5'd16: reg_group_mask = 32'h0000_ffff << base;
      default: reg_group_mask = 32'b0;
    endcase
  endfunction

  function automatic logic reg_group_aligned(
      input logic [4:0] base,
      input logic [4:0] count
  );
    unique case (count)
      5'd1:  reg_group_aligned = ({1'b0, base} + 6'd1) <= 6'd32;
      5'd2:  reg_group_aligned = base[0] == 1'b0;
      5'd4:  reg_group_aligned = base[1:0] == 2'b0;
      5'd8:  reg_group_aligned = base[2:0] == 3'b0;
      5'd16: reg_group_aligned = base[3:0] == 4'b0;
      default: reg_group_aligned = 1'b0;
    endcase
  endfunction

  function automatic logic reg_group_in_bounds(
      input logic [4:0] base,
      input logic [4:0] count
  );
    reg_group_in_bounds = ({1'b0, base} + {1'b0, count}) <= 6'd32;
  endfunction

  always_comb begin
    lambda_o = 7'b0;
    lambda_log2 = 3'b0;
    lambda_valid_o = lambda_encoding_i != 3'd0;
    if (lambda_valid_o) begin
      lambda_log2 = lambda_encoding_i - 3'd1;
      lambda_o = 7'd1 << lambda_log2;
    end

    lmul_o = 4'b0;
    lmul_log2 = 2'b0;
    integer_lmul_o = lmul_i <= 3'd3;
    if (integer_lmul_o) begin
      lmul_log2 = lmul_i[1:0];
      lmul_o = 4'd1 << lmul_log2;
    end

    // vsew encoding follows base V: SEW = 8 << vsew.
    sew_log2 = 4'd3 + {1'b0, sew_i};
    vl_divisor_log2 = {2'b0, lambda_log2} + {3'b0, lmul_log2};
    m_divisor_log2 = {1'b0, sew_log2} + {2'b0, lambda_log2};
    emul_divisor_log2 =
        {1'b0, sew_log2} + ({2'b0, lambda_log2} << 1);

    m_o = '0;
    if (lambda_valid_o && (int'(m_divisor_log2) <= VLEN_LOG2)) begin
      m_o = VL_WIDTH'(VLEN >> m_divisor_log2);
    end

    emul_c_o = '0;
    if (lambda_valid_o && (int'(emul_divisor_log2) <= VLEN_LOG2)) begin
      emul_c_o = 5'(VLEN >> emul_divisor_log2);
    end
    emul_c_valid_o =
        (emul_c_o == 5'd1) || (emul_c_o == 5'd2) ||
        (emul_c_o == 5'd4) || (emul_c_o == 5'd8) ||
        (emul_c_o == 5'd16);

    vl_divisor = '0;
    n_o = '0;
    vl_multiple_o = 1'b0;
    if (lambda_valid_o && integer_lmul_o &&
        (int'(vl_divisor_log2) <= VL_WIDTH)) begin
      vl_divisor = VL_WIDTH'(1) << vl_divisor_log2;
      n_o = vl_i >> vl_divisor_log2;
      vl_multiple_o =
          (vl_i & (vl_divisor - 1'b1)) == '0;
    end
    n_within_m_o = n_o <= m_o;

    k_eff_o = '0;
    k_shift = {1'b0, lambda_log2} + {2'b0, lmul_log2} +
              {2'b0, w_log2_i};
    if (lambda_valid_o && integer_lmul_o &&
        (k_shift < 4'd12)) begin
      // K_eff = lambda * W * LMUL for every matrix-MAC width.
      k_eff_o = 12'd1 << k_shift;
    end

    vs1_mask = reg_group_mask(vs1_i, {1'b0, lmul_o});
    vs2_mask = reg_group_mask(vs2_i, {1'b0, lmul_o});
    vd_mask = reg_group_mask(vd_i, emul_c_o);
    read_mask_o = vs1_mask | vs2_mask | vd_mask;
    write_mask_o = vd_mask;

    group_aligned_o =
        reg_group_aligned(vs1_i, {1'b0, lmul_o}) &&
        reg_group_aligned(vs2_i, {1'b0, lmul_o}) &&
        reg_group_aligned(vd_i, emul_c_o);
    group_in_bounds_o =
        reg_group_in_bounds(vs1_i, {1'b0, lmul_o}) &&
        reg_group_in_bounds(vs2_i, {1'b0, lmul_o}) &&
        reg_group_in_bounds(vd_i, emul_c_o);
  end

endmodule
