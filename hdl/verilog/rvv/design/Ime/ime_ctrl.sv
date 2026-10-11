// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Compute-command lifecycle control.  Datapath state lives in the fetch,
// scheduler, accumulator, packer and commit modules; this FSM only sequences
// those independently testable blocks and owns the macro ROB identity.
module ime_ctrl #(
  parameter bit INT_OPT = 1'b0
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            flush_i,
  input  logic                            cmd_valid_i,
  input  RVVCmd                           cmd_i,
  input  IME_ARI_DECODE_t                 decode_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]     cmd_rob_tag_i,
  output logic                            cmd_ready_o,
  output logic                            cmd_accept_o,
  output RVVCmd                           cmd_o,
  output IME_ARI_DECODE_t                 decode_o,
  output logic [`ROB_DEPTH_WIDTH-1:0]     rob_tag_o,

  input  logic                            fetch_done_i,
  output logic                            init_valid_o,
  output logic [`VL_WIDTH-1:0]            init_m_index_o,
  output logic [`VL_WIDTH-1:0]            init_n_index_o,
  output logic                            compute_start_o,
  input  logic                            compute_done_i,
  output logic                            pack_start_o,
  input  logic                            pack_done_i,
  input  logic                            rob_head_valid_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]     rob_head_tag_i,
  output logic                            commit_start_o,
  input  logic                            commit_done_i,

  output logic                            done_valid_o,
  output logic [`ROB_DEPTH_WIDTH-1:0]     done_rob_tag_o,
  output logic [31:0]                     read_lock_mask_o,
  output logic [31:0]                     write_lock_mask_o,
  output logic                            busy_o
);
  typedef enum logic [3:0] {
    CTRL_IDLE,
    CTRL_FETCH,
    CTRL_INIT,
    CTRL_COMPUTE,
    CTRL_PACK,
    CTRL_WAIT_HEAD,
    CTRL_COMMIT,
    CTRL_COMPLETE
  } ctrl_state_e;

  ctrl_state_e state_q;
  RVVCmd cmd_q;
  IME_ARI_DECODE_t decode_q;
  logic [`ROB_DEPTH_WIDTH-1:0] rob_tag_q;
  logic [`VL_WIDTH-1:0] init_m_q;
  logic [`VL_WIDTH-1:0] init_n_q;
  logic init_last;
  logic direct_integer;

  assign cmd_ready_o = state_q == CTRL_IDLE;
  assign cmd_accept_o = cmd_valid_i && cmd_ready_o;
  assign cmd_o = cmd_q;
  assign decode_o = decode_q;
  assign rob_tag_o = rob_tag_q;
  assign busy_o = state_q != CTRL_IDLE;
`ifdef ZVVFMM_ON
  // A full FP/MX build selects the optimized path per command.  FP/MX keeps
  // the reference accumulator and arithmetic ordering.
  assign direct_integer = INT_OPT && !decode_q.is_fp;
`else
  // Without Zvvfmm every command that can legally reach this engine is an
  // ordinary integer command.  Keep the compile-time option visible here so
  // synthesis does not have to propagate a constant through decode_q.
  assign direct_integer = INT_OPT;
`endif
  // The OPT ordinary-integer path uses CTRL_INIT as a single preparation
  // cycle after the final C snapshot, but does not walk the global accumulator.
  assign init_valid_o = (state_q == CTRL_INIT) && !direct_integer;
  assign init_m_index_o = init_m_q;
  assign init_n_index_o = init_n_q;
  assign init_last = (init_m_q == (decode_q.m - 1'b1)) &&
                     (init_n_q == (decode_q.n - 1'b1));
  assign compute_start_o = (state_q == CTRL_INIT) &&
                           (direct_integer || init_last);
  assign pack_start_o = !direct_integer &&
      (((state_q == CTRL_COMPUTE) && compute_done_i) ||
       ((state_q == CTRL_FETCH) && fetch_done_i &&
        ((decode_q.m == '0) || (decode_q.n == '0))));
  assign commit_start_o = (state_q == CTRL_WAIT_HEAD) &&
      rob_head_valid_i && (rob_head_tag_i == rob_tag_q);
  assign done_valid_o = (state_q == CTRL_COMMIT) && commit_done_i;
  assign done_rob_tag_o = rob_tag_q;
  assign read_lock_mask_o = (state_q == CTRL_FETCH) ?
                            decode_q.read_mask : 32'b0;
  assign write_lock_mask_o = (state_q != CTRL_IDLE) ?
                             decode_q.write_mask : 32'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= CTRL_IDLE;
      cmd_q <= '0;
      decode_q <= '0;
      rob_tag_q <= '0;
      init_m_q <= '0;
      init_n_q <= '0;
    end else if (flush_i) begin
      state_q <= CTRL_IDLE;
      init_m_q <= '0;
      init_n_q <= '0;
    end else begin
      unique case (state_q)
        CTRL_IDLE: begin
          if (cmd_valid_i) begin
            cmd_q <= cmd_i;
            decode_q <= decode_i;
            rob_tag_q <= cmd_rob_tag_i;
            init_m_q <= '0;
            init_n_q <= '0;
            state_q <= CTRL_FETCH;
          end
        end
        CTRL_FETCH: begin
          if (fetch_done_i) begin
            init_m_q <= '0;
            init_n_q <= '0;
            if (direct_integer)
              state_q <= CTRL_INIT;
            else
              state_q <= ((decode_q.m == '0) || (decode_q.n == '0)) ?
                         CTRL_PACK : CTRL_INIT;
          end
        end
        CTRL_INIT: begin
          if (direct_integer) begin
            state_q <= ((decode_q.m == '0) || (decode_q.n == '0)) ?
                       CTRL_WAIT_HEAD : CTRL_COMPUTE;
          end else if (init_last) begin
            state_q <= CTRL_COMPUTE;
          end else if (init_n_q == (decode_q.n - 1'b1)) begin
            init_n_q <= '0;
            init_m_q <= init_m_q + 1'b1;
          end else begin
            init_n_q <= init_n_q + 1'b1;
          end
        end
        CTRL_COMPUTE: begin
          if (compute_done_i)
            state_q <= direct_integer ? CTRL_WAIT_HEAD : CTRL_PACK;
        end
        CTRL_PACK: begin
          if (pack_done_i)
            state_q <= CTRL_WAIT_HEAD;
        end
        CTRL_WAIT_HEAD: begin
          if (rob_head_valid_i && (rob_head_tag_i == rob_tag_q))
            state_q <= CTRL_COMMIT;
        end
        CTRL_COMMIT: begin
          if (commit_done_i)
            state_q <= CTRL_COMPLETE;
        end
        CTRL_COMPLETE: begin
          if (!rob_head_valid_i || (rob_head_tag_i != rob_tag_q))
            state_q <= CTRL_IDLE;
        end
        default: state_q <= CTRL_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
      assert (!(cmd_valid_i && !cmd_ready_o))
          else $error("IME compute command presented while busy");
      if (cmd_accept_o) begin
        assert ((decode_i.lmul != '0) && (decode_i.emul_c != '0))
            else $error("Only a backend-decoded legal IME command may execute");
      end
      if (commit_start_o || commit_done_i) begin
        assert (rob_head_valid_i && (rob_head_tag_i == rob_tag_q))
            else $error("IME commit lifecycle lost ROB-head ownership");
      end
      assert (!(direct_integer && (init_valid_o || pack_start_o)))
          else $error("IME integer OPT entered the REF INIT/PACK datapath");
    end
  end
`endif
endmodule
