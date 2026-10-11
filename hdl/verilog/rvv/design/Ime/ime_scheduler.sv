// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Block scheduler for C=A*B^T+C.  Integer execution visits an M_PAR by N_PAR
// output block and advances K_PAR terms per cycle.  FP/MX deliberately keeps
// one output cell active so the established per-dot-product reduction order is
// unchanged; independent-cell FP parallelism can be added behind FP_LANES once
// the numerical equivalence is separately proven.
module ime_scheduler #(
  parameter int M_PAR = 1,
  parameter int N_PAR = 1,
  parameter int K_PAR = 1,
  parameter int FP_LANES = 1
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              flush_i,
  input  logic                              start_i,
  input  logic                              is_fp_i,
  input  logic                              is_integer_mx_i,
  input  logic [1:0]                        w_log2_i,
  input  logic [`VL_WIDTH-1:0]              m_i,
  input  logic [`VL_WIDTH-1:0]              n_i,
  input  logic [11:0]                       k_eff_i,
  input  logic                              step_fire_i,
  input  logic                              fp_forced_cell_done_i,
  output logic                              busy_o,
  output logic                              done_o,

  output logic [M_PAR-1:0][`VL_WIDTH-1:0]   int_m_index_o,
  output logic [N_PAR-1:0][`VL_WIDTH-1:0]   int_n_index_o,
  output logic [K_PAR-1:0][11:0]            int_k_index_o,
  output logic [M_PAR*N_PAR-1:0]            int_lane_active_o,
  output logic [K_PAR-1:0]                  int_term_active_o,

  output logic [`VL_WIDTH-1:0]              fp_m_index_o,
  output logic [FP_LANES-1:0][`VL_WIDTH-1:0] fp_n_index_o,
  output logic [FP_LANES-1:0]               fp_lane_active_o,
  output logic [11:0]                       fp_k_index_o
);
  logic active_q;
  logic is_fp_q;
  logic is_integer_mx_q;
  logic [1:0] w_log2_q;
  logic [`VL_WIDTH-1:0] m_limit_q;
  logic [`VL_WIDTH-1:0] n_limit_q;
  logic [11:0] k_limit_q;
  logic [`VL_WIDTH-1:0] m_base_q;
  logic [`VL_WIDTH-1:0] n_base_q;
  logic [11:0] k_base_q;

  logic int_k_last;
  logic int_n_last;
  logic int_m_last;
  logic fp_k_last;
  logic fp_n_last;
  logic fp_m_last;
  logic [11:0] fp_k_step;
  // VL_WIDTH is defined as the expression "$clog2(VLEN)+1".  Do not use
  // that macro directly as a sized-cast prefix: after preprocessing,
  // `VL_WIDTH'(x) would parse as $clog2(VLEN) + 1'(x), not as an
  // VL_WIDTH-bit cast.  Naming the evaluated constant makes every cast
  // unambiguous for simulation and synthesis.
  localparam int VL_INDEX_WIDTH = `VL_WIDTH;
  localparam logic [11:0] K_PAR_STEP = 12'(K_PAR);
  localparam logic [`VL_WIDTH-1:0] M_PAR_STEP = VL_INDEX_WIDTH'(M_PAR);
  localparam logic [`VL_WIDTH-1:0] N_PAR_STEP = VL_INDEX_WIDTH'(N_PAR);
  localparam logic [`VL_WIDTH-1:0] FP_LANES_STEP =
      VL_INDEX_WIDTH'(FP_LANES);

  assign busy_o = active_q;
  assign fp_k_step = is_integer_mx_q ? 12'd1 : (12'd1 << w_log2_q);
  assign int_k_last = (k_base_q + K_PAR_STEP) >= k_limit_q;
  assign int_n_last = (n_base_q + N_PAR_STEP) >= n_limit_q;
  assign int_m_last = (m_base_q + M_PAR_STEP) >= m_limit_q;
  assign fp_k_last = fp_forced_cell_done_i ||
                     ((k_base_q + fp_k_step) >= k_limit_q);
  assign fp_n_last = (n_base_q + FP_LANES_STEP) >= n_limit_q;
  assign fp_m_last = (m_base_q + 1'b1) >= m_limit_q;
  assign done_o = active_q && step_fire_i &&
      (is_fp_q ? (fp_k_last && fp_n_last && fp_m_last) :
                 (int_k_last && int_n_last && int_m_last));

  always_comb begin
    for (int row = 0; row < M_PAR; row++) begin
      int_m_index_o[row] = m_base_q + VL_INDEX_WIDTH'(row);
    end
    for (int column = 0; column < N_PAR; column++) begin
      int_n_index_o[column] = n_base_q + VL_INDEX_WIDTH'(column);
    end
    for (int term = 0; term < K_PAR; term++) begin
      int_k_index_o[term] = k_base_q + 12'(term);
      int_term_active_o[term] = active_q && !is_fp_q &&
          ((k_base_q + 12'(term)) < k_limit_q);
    end
    for (int row = 0; row < M_PAR; row++) begin
      for (int column = 0; column < N_PAR; column++) begin
        int_lane_active_o[row*N_PAR+column] = active_q && !is_fp_q &&
            ((m_base_q + VL_INDEX_WIDTH'(row)) < m_limit_q) &&
            ((n_base_q + VL_INDEX_WIDTH'(column)) < n_limit_q);
      end
    end

    fp_m_index_o = m_base_q;
    fp_k_index_o = k_base_q;
    for (int lane = 0; lane < FP_LANES; lane++) begin
      fp_n_index_o[lane] = n_base_q + VL_INDEX_WIDTH'(lane);
      fp_lane_active_o[lane] = active_q && is_fp_q &&
          ((n_base_q + VL_INDEX_WIDTH'(lane)) < n_limit_q);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_q <= 1'b0;
      is_fp_q <= 1'b0;
      is_integer_mx_q <= 1'b0;
      w_log2_q <= '0;
      m_limit_q <= '0;
      n_limit_q <= '0;
      k_limit_q <= '0;
      m_base_q <= '0;
      n_base_q <= '0;
      k_base_q <= '0;
    end else if (flush_i) begin
      active_q <= 1'b0;
      m_base_q <= '0;
      n_base_q <= '0;
      k_base_q <= '0;
    end else if (start_i) begin
      active_q <= (m_i != '0) && (n_i != '0) && (k_eff_i != '0);
      is_fp_q <= is_fp_i;
      is_integer_mx_q <= is_integer_mx_i;
      w_log2_q <= w_log2_i;
      m_limit_q <= m_i;
      n_limit_q <= n_i;
      k_limit_q <= k_eff_i;
      m_base_q <= '0;
      n_base_q <= '0;
      k_base_q <= '0;
    end else if (active_q && step_fire_i) begin
      if (is_fp_q) begin
        if (fp_k_last) begin
          k_base_q <= '0;
          if (fp_n_last) begin
            n_base_q <= '0;
            if (fp_m_last) begin
              active_q <= 1'b0;
            end else begin
              m_base_q <= m_base_q + 1'b1;
            end
          end else begin
            n_base_q <= n_base_q + FP_LANES_STEP;
          end
        end else begin
          k_base_q <= k_base_q + fp_k_step;
        end
      end else begin
        if (int_k_last) begin
          k_base_q <= '0;
          if (int_n_last) begin
            n_base_q <= '0;
            if (int_m_last) begin
              active_q <= 1'b0;
            end else begin
              m_base_q <= m_base_q + M_PAR_STEP;
            end
          end else begin
            n_base_q <= n_base_q + N_PAR_STEP;
          end
        end else begin
          k_base_q <= k_base_q + K_PAR_STEP;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (M_PAR inside {1, 2, 4});
    assert (N_PAR inside {1, 2, 4});
    assert (K_PAR inside {1, 2, 4});
    // Current FP/MX disclosure is intentionally single-lane.  This assertion
    // prevents a build option from silently changing reduction/NaN behavior.
    assert (FP_LANES == 1);
  end
`endif
endmodule
