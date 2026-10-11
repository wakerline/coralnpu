// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Head-owned multi-register C commit.  The result buffer is non-architectural;
// no byte is exposed to VRF until the macro token is the actual ROB head.
module ime_commit #(
  parameter int MAX_C_REGS = 16
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              flush_i,
  input  logic                              start_i,
  input  logic [4:0]                        vd_i,
  input  logic [4:0]                        emul_c_i,
  input  logic [`PC_WIDTH-1:0]              pc_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]       rob_tag_i,
  input  logic                              rob_head_valid_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]       rob_head_tag_i,
  input  logic [MAX_C_REGS*`VLEN-1:0]       result_data_i,
  input  logic [MAX_C_REGS*`VLENB-1:0]      result_strobe_i,
  output logic                              busy_o,
  output logic                              last_valid_o,
  output logic                              done_o,
  output logic [`ROB_DEPTH_WIDTH-1:0]       rob_tag_o,
  output logic [`NUM_RT_UOP-1:0]            commit_valid_o,
  output RT2VRF_t [`NUM_RT_UOP-1:0]         commit_data_o,
  input  logic                              commit_ready_i
);
  logic active_q;
  logic [4:0] commit_index_q;
  logic [4:0] vd_q;
  logic [4:0] emul_c_q;
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0] pc_q;
`endif
  logic [`ROB_DEPTH_WIDTH-1:0] rob_tag_q;
  logic last_beat;
`ifndef TB_SUPPORT
  logic _unused_pc;
  assign _unused_pc = ^pc_i;
`endif

  assign busy_o = active_q;
  assign rob_tag_o = rob_tag_q;
  assign last_beat =
      ({1'b0, commit_index_q} + `NUM_RT_UOP) >= {1'b0, emul_c_q};
  assign last_valid_o = active_q && (commit_valid_o != '0) && last_beat;
  assign done_o = last_valid_o && commit_ready_i;

  always_comb begin
    commit_valid_o = '0;
    commit_data_o = '0;
    if (active_q && !flush_i && rob_head_valid_i &&
        (rob_head_tag_i == rob_tag_q)) begin
      for (int lane = 0; lane < `NUM_RT_UOP; lane++) begin
        automatic int unsigned slot = int'(commit_index_q) + lane;
        if (slot < int'(emul_c_q)) begin
          commit_valid_o[lane] = 1'b1;
          commit_data_o[lane].rt_index =
              vd_q + `REGFILE_INDEX_WIDTH'(slot);
          commit_data_o[lane].rt_data =
              result_data_i[slot*`VLEN +: `VLEN];
          commit_data_o[lane].rt_strobe =
              result_strobe_i[slot*`VLENB +: `VLENB];
`ifdef TB_SUPPORT
          commit_data_o[lane].uop_pc = pc_q;
`endif
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_q <= 1'b0;
      commit_index_q <= '0;
      vd_q <= '0;
      emul_c_q <= '0;
`ifdef TB_SUPPORT
      pc_q <= '0;
`endif
      rob_tag_q <= '0;
    end else if (flush_i) begin
      active_q <= 1'b0;
      commit_index_q <= '0;
    end else if (start_i) begin
      active_q <= 1'b1;
      commit_index_q <= '0;
      vd_q <= vd_i;
      emul_c_q <= emul_c_i;
`ifdef TB_SUPPORT
      pc_q <= pc_i;
`endif
      rob_tag_q <= rob_tag_i;
    end else if (active_q && (commit_valid_o != '0) && commit_ready_i) begin
      if (last_beat) begin
        active_q <= 1'b0;
      end else begin
        commit_index_q <= commit_index_q + `NUM_RT_UOP;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else if (commit_valid_o != '0) begin
      assert (rob_head_valid_i && (rob_head_tag_i == rob_tag_q))
          else $error("IME committed without matching ROB-head ownership");
      assert (!flush_i)
          else $error("IME commit overlapped backend flush");
    end
  end
`endif
endmodule
