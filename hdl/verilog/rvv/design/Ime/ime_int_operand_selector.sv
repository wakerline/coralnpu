// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Ordinary-integer IME operand delivery.  The legacy branch preserves the
// original full-snapshot variable-shift implementation.  The optimized branch
// shares power-of-two geometry predecode and selects only the active element
// width.  Both branches consume the same architectural operand snapshot.
module ime_int_operand_selector #(
  parameter int M_PAR = `IME_M_PAR,
  parameter int N_PAR = `IME_N_PAR,
  parameter int K_PAR = `IME_K_PAR,
  parameter int MAX_LMUL = 8,
  parameter int MAX_C_REGS = `IME_MAX_C_REGS,
  parameter int VLEN = `VLEN,
  parameter bit OPT = 1'b0,
  localparam int C_INDEX_WIDTH = $clog2(MAX_C_REGS * (VLEN / 8))
) (
  input  logic [MAX_LMUL*VLEN-1:0]        a_data_i,
  input  logic [MAX_LMUL*VLEN-1:0]        b_data_i,
  input  logic [MAX_C_REGS*VLEN-1:0]      c_data_i,
  input  logic [M_PAR-1:0][`VL_WIDTH-1:0] m_index_i,
  input  logic [N_PAR-1:0][`VL_WIDTH-1:0] n_index_i,
  input  logic [K_PAR-1:0][11:0]          k_index_i,
  input  logic [M_PAR*N_PAR-1:0]          lane_active_i,
  input  logic [K_PAR-1:0]                term_active_i,
  input  logic [2:0]                      eew_log2_i,
  input  logic [2:0]                      sew_i,
  input  logic [6:0]                      lambda_i,
  input  logic [3:0]                      lmul_i,
  input  logic [4:0]                      emul_c_i,
  input  logic [`VL_WIDTH-1:0]            m_i,
  input  logic [11:0]                     k_eff_i,
  input  logic                            select_valid_i,
  output logic [M_PAR-1:0][K_PAR-1:0][31:0] a_o,
  output logic [N_PAR-1:0][K_PAR-1:0][31:0] b_o,
  output logic [M_PAR*N_PAR-1:0][31:0]       c_seed_o,
  output logic [M_PAR*N_PAR-1:0][C_INDEX_WIDTH-1:0]
                                               c_flat_index_o
);
  logic [3:0] lambda_log2;
  logic [3:0] lmul_log2;
  logic [3:0] emul_c_log2;
  logic [3:0] m_log2;
  logic [3:0] k_eff_log2;
  logic [3:0] a_elements_log2;
  logic [3:0] c_elements_log2;

  always_comb begin
    lambda_log2 = ime_pkg::ime_power_of_two_log2({2'b0, lambda_i});
    lmul_log2 = ime_pkg::ime_power_of_two_log2({5'b0, lmul_i});
    emul_c_log2 = ime_pkg::ime_power_of_two_log2({4'b0, emul_c_i});
    m_log2 = ime_pkg::ime_power_of_two_log2(9'(m_i));
    k_eff_log2 = ime_pkg::ime_power_of_two_log2(9'(k_eff_i));
    a_elements_log2 = ime_pkg::ime_power_of_two_log2(
        9'(VLEN >> eew_log2_i));
    c_elements_log2 = ime_pkg::ime_power_of_two_log2(
        9'(VLEN >> (3 + sew_i)));
  end

  function automatic logic [31:0] select_ab_legacy(
      input logic [MAX_LMUL*VLEN-1:0] data,
      input logic [15:0] flat_index,
      input logic [2:0] eew_log2
  );
    select_ab_legacy = 32'(data >> (flat_index << eew_log2));
  endfunction

  function automatic logic [31:0] select_c_legacy(
      input logic [MAX_C_REGS*VLEN-1:0] data,
      input logic [15:0] flat_index,
      input logic [2:0] sew
  );
    unique case (sew)
      3'd0: select_c_legacy = 32'(data >> (flat_index << 3));
      3'd1: select_c_legacy = 32'(data >> (flat_index << 4));
      3'd2: select_c_legacy = 32'(data >> (flat_index << 5));
      default: select_c_legacy = '0;
    endcase
  endfunction

  function automatic logic [31:0] select_ab_narrow(
      input logic [MAX_LMUL*VLEN-1:0] data,
      input logic [15:0] flat_index,
      input logic [2:0] eew_log2
  );
    int unsigned bit_index;
    begin
      bit_index = int'(flat_index) << eew_log2;
      unique case (eew_log2)
        3'd2: select_ab_narrow = {28'd0, data[bit_index +: 4]};
        3'd3: select_ab_narrow = {24'd0, data[bit_index +: 8]};
        3'd4: select_ab_narrow = {16'd0, data[bit_index +: 16]};
        3'd5: select_ab_narrow = data[bit_index +: 32];
        default: select_ab_narrow = '0;
      endcase
    end
  endfunction

  function automatic logic [31:0] select_c_narrow(
      input logic [MAX_C_REGS*VLEN-1:0] data,
      input logic [15:0] flat_index,
      input logic [2:0] sew
  );
    int unsigned bit_index;
    begin
      bit_index = int'(flat_index) << (3 + sew);
      unique case (sew)
        3'd0: select_c_narrow = {24'd0, data[bit_index +: 8]};
        3'd1: select_c_narrow = {16'd0, data[bit_index +: 16]};
        3'd2: select_c_narrow = data[bit_index +: 32];
        default: select_c_narrow = '0;
      endcase
    end
  endfunction

  function automatic logic [31:0] ab_element_mask(
      input logic [2:0] eew_log2
  );
    unique case (eew_log2)
      3'd2: ab_element_mask = 32'h0000_000f;
      3'd3: ab_element_mask = 32'h0000_00ff;
      3'd4: ab_element_mask = 32'h0000_ffff;
      3'd5: ab_element_mask = 32'hffff_ffff;
      default: ab_element_mask = '0;
    endcase
  endfunction

  function automatic logic [31:0] c_element_mask(
      input logic [2:0] sew
  );
    unique case (sew)
      3'd0: c_element_mask = 32'h0000_00ff;
      3'd1: c_element_mask = 32'h0000_ffff;
      3'd2: c_element_mask = 32'hffff_ffff;
      default: c_element_mask = '0;
    endcase
  endfunction

  always_comb begin : select_operands
    a_o = '0;
    b_o = '0;
    c_seed_o = '0;
    c_flat_index_o = '0;
    for (int row = 0; row < M_PAR; row++) begin
      for (int term = 0; term < K_PAR; term++) begin
        automatic logic [15:0] sequential;
        automatic logic [15:0] flat;
        if (OPT) begin
          sequential = ime_pkg::ime_row_major_index_pow2(
              16'(m_index_i[row]), 16'(k_index_i[term]), k_eff_log2);
          flat = ime_pkg::ime_tile_reg_index_predecoded(
              sequential, lmul_log2, lambda_log2, a_elements_log2);
          a_o[row][term] = select_ab_narrow(a_data_i, flat, eew_log2_i);
        end else begin
          sequential = ime_pkg::ime_row_major_index(
              16'(m_index_i[row]), 16'(k_index_i[term]), 16'(k_eff_i));
          flat = ime_pkg::ime_tile_reg_index(
              sequential, {1'b0, lmul_i}, lambda_i,
              9'(VLEN >> eew_log2_i));
          a_o[row][term] = select_ab_legacy(a_data_i, flat, eew_log2_i);
        end
      end
    end
    for (int column = 0; column < N_PAR; column++) begin
      for (int term = 0; term < K_PAR; term++) begin
        automatic logic [15:0] sequential;
        automatic logic [15:0] flat;
        if (OPT) begin
          sequential = ime_pkg::ime_row_major_index_pow2(
              16'(n_index_i[column]), 16'(k_index_i[term]), k_eff_log2);
          flat = ime_pkg::ime_tile_reg_index_predecoded(
              sequential, lmul_log2, lambda_log2, a_elements_log2);
          b_o[column][term] = select_ab_narrow(b_data_i, flat, eew_log2_i);
        end else begin
          sequential = ime_pkg::ime_row_major_index(
              16'(n_index_i[column]), 16'(k_index_i[term]), 16'(k_eff_i));
          flat = ime_pkg::ime_tile_reg_index(
              sequential, {1'b0, lmul_i}, lambda_i,
              9'(VLEN >> eew_log2_i));
          b_o[column][term] = select_ab_legacy(b_data_i, flat, eew_log2_i);
        end
      end
    end
    for (int row = 0; row < M_PAR; row++) begin
      for (int column = 0; column < N_PAR; column++) begin
        automatic int lane = row * N_PAR + column;
        automatic logic [15:0] sequential;
        automatic logic [15:0] flat;
        if (OPT) begin
          sequential = ime_pkg::ime_row_major_index_pow2(
              16'(m_index_i[row]), 16'(n_index_i[column]), m_log2);
          flat = ime_pkg::ime_tile_reg_index_predecoded(
              sequential, emul_c_log2, lambda_log2, c_elements_log2);
          c_seed_o[lane] = select_c_narrow(c_data_i, flat, sew_i);
        end else begin
          sequential = ime_pkg::ime_row_major_index(
              16'(m_index_i[row]), 16'(n_index_i[column]), 16'(m_i));
          flat = ime_pkg::ime_tile_reg_index(
              sequential, emul_c_i, lambda_i, 9'(VLEN >> (3 + sew_i)));
          c_seed_o[lane] = select_c_legacy(c_data_i, flat, sew_i);
        end
        c_flat_index_o[lane] = C_INDEX_WIDTH'(flat);
      end
    end
  end

`ifndef SYNTHESIS
  // The legacy full-width shift exposes adjacent packed elements above the
  // selected EEW/SEW.  The integer PE consumes only the selected low element,
  // and the optimized branch deliberately zeroes the unused high bits.  Prove
  // equivalence over exactly that semantic interface for every active lane.
  always_comb begin : verify_optimized_mapping
    if (OPT && (select_valid_i === 1'b1)) begin
      for (int row = 0; row < M_PAR; row++) begin
        for (int term = 0; term < K_PAR; term++) begin
          automatic logic row_active = 1'b0;
          automatic logic [15:0] legacy_sequential;
          automatic logic [15:0] legacy_flat;
          for (int column = 0; column < N_PAR; column++)
            row_active |= lane_active_i[row*N_PAR + column];
          legacy_sequential = ime_pkg::ime_row_major_index(
              16'(m_index_i[row]), 16'(k_index_i[term]), 16'(k_eff_i));
          legacy_flat = ime_pkg::ime_tile_reg_index(
              legacy_sequential, {1'b0, lmul_i}, lambda_i,
              9'(VLEN >> eew_log2_i));
          if (row_active && term_active_i[term]) begin
            assert ((a_o[row][term] & ab_element_mask(eew_log2_i)) ==
                    (select_ab_legacy(a_data_i, legacy_flat, eew_log2_i) &
                     ab_element_mask(eew_log2_i)))
                else $error("IME optimized A selector mismatch");
          end
        end
      end
      for (int column = 0; column < N_PAR; column++) begin
        for (int term = 0; term < K_PAR; term++) begin
          automatic logic column_active = 1'b0;
          automatic logic [15:0] legacy_sequential;
          automatic logic [15:0] legacy_flat;
          for (int row = 0; row < M_PAR; row++)
            column_active |= lane_active_i[row*N_PAR + column];
          legacy_sequential = ime_pkg::ime_row_major_index(
              16'(n_index_i[column]), 16'(k_index_i[term]), 16'(k_eff_i));
          legacy_flat = ime_pkg::ime_tile_reg_index(
              legacy_sequential, {1'b0, lmul_i}, lambda_i,
              9'(VLEN >> eew_log2_i));
          if (column_active && term_active_i[term]) begin
            assert ((b_o[column][term] & ab_element_mask(eew_log2_i)) ==
                    (select_ab_legacy(b_data_i, legacy_flat, eew_log2_i) &
                     ab_element_mask(eew_log2_i)))
                else $error("IME optimized B selector mismatch");
          end
        end
      end
      for (int row = 0; row < M_PAR; row++) begin
        for (int column = 0; column < N_PAR; column++) begin
          automatic int lane = row * N_PAR + column;
          automatic logic [15:0] legacy_sequential;
          automatic logic [15:0] legacy_flat;
          legacy_sequential = ime_pkg::ime_row_major_index(
              16'(m_index_i[row]), 16'(n_index_i[column]), 16'(m_i));
          legacy_flat = ime_pkg::ime_tile_reg_index(
              legacy_sequential, emul_c_i, lambda_i,
              9'(VLEN >> (3 + sew_i)));
          if (lane_active_i[lane]) begin
            assert ((c_seed_o[lane] & c_element_mask(sew_i)) ==
                    (select_c_legacy(c_data_i, legacy_flat, sew_i) &
                     c_element_mask(sew_i)))
                else $error("IME optimized C selector mismatch");
          end
        end
      end
    end
  end
`endif
endmodule
