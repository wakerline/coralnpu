// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// Single-macro scheduler for ordered FP and FP-input MX execution.  Up to
// eight independent output cells share one arithmetic pipeline.  A slot may
// issue its next K group only after the preceding result has returned, so the
// architectural reduction order of every cell is identical to the reference
// scheduler.  All slots belong to the one command/snapshot owned by ime_ctrl;
// no ROB identity or architectural state is replicated here.
module ime_fp_ordered_scheduler #(
  parameter int MAX_CONTEXTS = 8,
  localparam int CONTEXT_WIDTH = MAX_CONTEXTS > 1 ?
                                   $clog2(MAX_CONTEXTS) : 1
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              flush_i,
  input  logic                              start_i,
  input  logic [1:0]                        w_log2_i,
  input  logic [`VL_WIDTH-1:0]              m_i,
  input  logic [`VL_WIDTH-1:0]              n_i,
  input  logic [11:0]                       k_eff_i,

  output logic                              issue_valid_o,
  input  logic                              issue_fire_i,
  output logic [CONTEXT_WIDTH-1:0]          issue_context_o,
  output logic [`VL_WIDTH-1:0]              issue_m_index_o,
  output logic [`VL_WIDTH-1:0]              issue_n_index_o,
  output logic [11:0]                       issue_k_index_o,
  output logic                              issue_first_k_o,
  output logic                              issue_last_k_o,

  input  logic                              result_fire_i,
  input  logic [CONTEXT_WIDTH-1:0]          result_context_i,
  input  logic                              result_last_k_i,
  input  logic                              result_forced_cell_done_i,

  output logic                              busy_o,
  output logic                              done_o
);
  localparam int VL_INDEX_WIDTH = `VL_WIDTH;
  localparam int CELL_WIDTH = 5;

  logic active_q;
  logic [1:0] w_log2_q;
  logic [`VL_WIDTH-1:0] n_limit_q;
  logic [11:0] k_limit_q;
  logic [CELL_WIDTH-1:0] total_cells_q;
  logic [CELL_WIDTH-1:0] remaining_cells_q;
  logic [CELL_WIDTH-1:0] next_cell_q;
  logic [CONTEXT_WIDTH-1:0] round_robin_q;
  logic [MAX_CONTEXTS-1:0] slot_valid_q;
  logic [MAX_CONTEXTS-1:0] slot_busy_q;
  logic [MAX_CONTEXTS-1:0][CELL_WIDTH-1:0] slot_cell_q;
  logic [MAX_CONTEXTS-1:0][11:0] slot_k_q;

  logic [CELL_WIDTH-1:0] start_total_cells;
  logic [3:0] start_contexts;
  logic issue_found;
  logic [CONTEXT_WIDTH-1:0] issue_selected;
  logic result_cell_done;
  logic [11:0] k_step;

  function automatic logic [3:0] balanced_contexts(
      input logic [CELL_WIDTH-1:0] cells
  );
    // With VLEN=128 and FP32 accumulation, legal IME geometries contain
    // 2/4/8/12/16 cells.  Choosing a divisor avoids a short final wave while
    // keeping the table bounded at eight entries.  The fallback keeps this
    // module deterministic for defensive unit-level inputs.
    unique case (cells)
      5'd1: balanced_contexts = 4'd1;
      5'd2: balanced_contexts = 4'd2;
      5'd4: balanced_contexts = 4'd4;
      5'd8: balanced_contexts = 4'd8;
      5'd12: balanced_contexts = 4'd6;
      5'd16: balanced_contexts = 4'd8;
      default: balanced_contexts = cells < CELL_WIDTH'(MAX_CONTEXTS) ?
                                   4'(cells) : 4'(MAX_CONTEXTS);
    endcase
  endfunction

  function automatic logic [`VL_WIDTH-1:0] cell_row(
      input logic [CELL_WIDTH-1:0] cell_index,
      input logic [`VL_WIDTH-1:0] columns
  );
    unique case (columns)
      VL_INDEX_WIDTH'(1): cell_row = VL_INDEX_WIDTH'(cell_index);
      VL_INDEX_WIDTH'(2): cell_row = VL_INDEX_WIDTH'(cell_index >> 1);
      VL_INDEX_WIDTH'(3): begin
        if (cell_index >= 5'd9) cell_row = VL_INDEX_WIDTH'(3);
        else if (cell_index >= 5'd6) cell_row = VL_INDEX_WIDTH'(2);
        else if (cell_index >= 5'd3) cell_row = VL_INDEX_WIDTH'(1);
        else cell_row = '0;
      end
      VL_INDEX_WIDTH'(4): cell_row = VL_INDEX_WIDTH'(cell_index >> 2);
      default: cell_row = '0;
    endcase
  endfunction

  function automatic logic [`VL_WIDTH-1:0] cell_column(
      input logic [CELL_WIDTH-1:0] cell_index,
      input logic [`VL_WIDTH-1:0] columns
  );
    logic [`VL_WIDTH-1:0] row;
    begin
      row = cell_row(cell_index, columns);
      unique case (columns)
        VL_INDEX_WIDTH'(1): cell_column = '0;
        VL_INDEX_WIDTH'(2): cell_column = VL_INDEX_WIDTH'(cell_index[0]);
        VL_INDEX_WIDTH'(3): cell_column =
            VL_INDEX_WIDTH'(cell_index) - (row + (row << 1));
        VL_INDEX_WIDTH'(4): cell_column = VL_INDEX_WIDTH'(cell_index[1:0]);
        default: cell_column = '0;
      endcase
    end
  endfunction

  assign start_total_cells = CELL_WIDTH'(m_i) * CELL_WIDTH'(n_i);
  assign start_contexts = balanced_contexts(start_total_cells);
  assign k_step = 12'd1 << w_log2_q;
  assign result_cell_done = result_last_k_i || result_forced_cell_done_i;
  assign busy_o = active_q;
  assign done_o = active_q && result_fire_i && result_cell_done &&
                  (remaining_cells_q == CELL_WIDTH'(1));

  always_comb begin
    issue_found = 1'b0;
    issue_selected = '0;
    for (int offset = 0; offset < MAX_CONTEXTS; offset++) begin
      automatic int candidate = int'(round_robin_q) + offset;
      if (candidate >= MAX_CONTEXTS)
        candidate = candidate - MAX_CONTEXTS;
      if (!issue_found && slot_valid_q[candidate] &&
          !slot_busy_q[candidate]) begin
        issue_found = 1'b1;
        issue_selected = CONTEXT_WIDTH'(candidate);
      end
    end

    issue_valid_o = active_q && issue_found;
    issue_context_o = issue_selected;
    issue_m_index_o = cell_row(slot_cell_q[issue_selected], n_limit_q);
    issue_n_index_o = cell_column(slot_cell_q[issue_selected], n_limit_q);
    issue_k_index_o = slot_k_q[issue_selected];
    issue_first_k_o = slot_k_q[issue_selected] == '0;
    issue_last_k_o = (slot_k_q[issue_selected] + k_step) >= k_limit_q;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_q <= 1'b0;
      w_log2_q <= '0;
      n_limit_q <= '0;
      k_limit_q <= '0;
      total_cells_q <= '0;
      remaining_cells_q <= '0;
      next_cell_q <= '0;
      round_robin_q <= '0;
      slot_valid_q <= '0;
      slot_busy_q <= '0;
      slot_cell_q <= '0;
      slot_k_q <= '0;
    end else if (flush_i) begin
      active_q <= 1'b0;
      remaining_cells_q <= '0;
      next_cell_q <= '0;
      round_robin_q <= '0;
      slot_valid_q <= '0;
      slot_busy_q <= '0;
    end else if (start_i) begin
      active_q <= (start_total_cells != '0) && (k_eff_i != '0);
      w_log2_q <= w_log2_i;
      n_limit_q <= n_i;
      k_limit_q <= k_eff_i;
      total_cells_q <= start_total_cells;
      remaining_cells_q <= start_total_cells;
      next_cell_q <= CELL_WIDTH'(start_contexts);
      round_robin_q <= '0;
      slot_busy_q <= '0;
      for (int slot = 0; slot < MAX_CONTEXTS; slot++) begin
        slot_valid_q[slot] <= slot < int'(start_contexts);
        slot_cell_q[slot] <= CELL_WIDTH'(slot);
        slot_k_q[slot] <= '0;
      end
    end else begin
      if (issue_fire_i) begin
        slot_busy_q[issue_selected] <= 1'b1;
        round_robin_q <= issue_selected == CONTEXT_WIDTH'(MAX_CONTEXTS - 1) ?
                         '0 : issue_selected + 1'b1;
      end

      if (result_fire_i) begin
        slot_busy_q[result_context_i] <= 1'b0;
        if (result_cell_done) begin
          remaining_cells_q <= remaining_cells_q - 1'b1;
          if (remaining_cells_q == CELL_WIDTH'(1)) begin
            active_q <= 1'b0;
            slot_valid_q[result_context_i] <= 1'b0;
          end else if (next_cell_q < total_cells_q) begin
            slot_cell_q[result_context_i] <= next_cell_q;
            slot_k_q[result_context_i] <= '0;
            next_cell_q <= next_cell_q + 1'b1;
          end else begin
            slot_valid_q[result_context_i] <= 1'b0;
          end
        end else begin
          slot_k_q[result_context_i] <= slot_k_q[result_context_i] + k_step;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (MAX_CONTEXTS == 8)
        else $error("IME ordered FP scheduler currently requires eight slots");
  end

  always_ff @(posedge clk) begin
    if (rst_n && !flush_i) begin
      if (start_i) begin
        assert (start_total_cells inside {5'd2, 5'd4, 5'd8, 5'd12, 5'd16})
            else $error("IME ordered FP scheduler received unsupported geometry");
        assert (n_i >= 1 && n_i <= 4);
      end
      if (issue_fire_i) begin
        assert (issue_valid_o && !slot_busy_q[issue_selected]);
      end
      if (result_fire_i) begin
        assert (active_q && int'(result_context_i) < MAX_CONTEXTS &&
                slot_valid_q[result_context_i] &&
                slot_busy_q[result_context_i])
            else $error("IME ordered FP result returned to an idle slot");
      end
      assert (!(done_o && (remaining_cells_q != CELL_WIDTH'(1))));
    end
  end
`endif
endmodule
