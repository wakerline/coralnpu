// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Thin IME execution-unit wrapper.
//
// Instruction recognition and instruction-specific legality are authoritative
// in backend DE1.  This module consumes only legal IME_RS_t entries.  It
// reconstructs execution geometry from the captured architectural snapshot;
// it deliberately does not instantiate ime_decode or ime_tls_decode and does
// not make a second legal/illegal decision.
module ime (
  input  logic                          clk,
  input  logic                          rst_n,

  input  logic                          rs_valid_i,
  input  IME_RS_t                       rs_i,
  output logic                          rs_ready_o,
  input  logic                          flush_i,

  input  logic                          rob_head_valid_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]   rob_head_tag_i,

  output logic                          result_valid_o,
  output PU2ROB_t                       result_o,
  input  logic                          result_ready_i,

  output logic [31:0]                   read_lock_mask_o,
  output logic [31:0]                   write_lock_mask_o,

  output logic                          vrf_read_req_valid_o,
  input  logic                          vrf_read_req_ready_i,
  output logic [`REGFILE_INDEX_WIDTH-1:0] vrf_read_index_o,
  output logic [1:0]                    vrf_read_operand_o,
  output logic [4:0]                    vrf_read_group_o,
  input  logic                          vrf_read_rsp_valid_i,
  output logic                          vrf_read_rsp_ready_o,
  input  logic [`VLEN-1:0]              vrf_read_data_i,
  input  logic [1:0]                    vrf_read_rsp_operand_i,
  input  logic [4:0]                    vrf_read_rsp_group_i,

  output logic [`NUM_RT_UOP-1:0]        commit_valid_o,
  output RT2VRF_t [`NUM_RT_UOP-1:0]     commit_data_o,
  input  logic                          commit_ready_i,
  output logic [`ROB_DEPTH_WIDTH-1:0]   commit_rob_tag_o,
  output logic                          commit_fflags_valid_o,
  output logic [4:0]                    commit_fflags_o,

  output logic                          busy_o
);
  IME_ARI_DECODE_t ari_decode;

  logic [6:0] geometry_lambda;
  logic [3:0] geometry_lmul;
  logic [4:0] geometry_emul_c;
  logic [`VL_WIDTH-1:0] geometry_m;
  logic [`VL_WIDTH-1:0] geometry_n;
  logic [11:0] geometry_k_eff;

  ime_geometry #(
    .VLEN(`VLEN),
    .VL_WIDTH(`VL_WIDTH)
  ) u_geometry (
    .lambda_encoding_i(rs_i.cmd.arch_state.ime_lambda),
    .sew_i(rs_i.cmd.arch_state.sew),
    .lmul_i(rs_i.cmd.arch_state.lmul_orig),
    .w_log2_i(rs_i.meta.w_log2),
    .vl_i(rs_i.cmd.arch_state.vl),
    .vs1_i(rs_i.meta.vs1),
    .vs2_i(rs_i.meta.vs2),
    .vd_i(rs_i.meta.vd),
    .lambda_o(geometry_lambda),
    .lmul_o(geometry_lmul),
    .emul_c_o(geometry_emul_c),
    .m_o(geometry_m),
    .n_o(geometry_n),
    .k_eff_o(geometry_k_eff),
    .read_mask_o(),
    .write_mask_o(),
    .lambda_valid_o(),
    .integer_lmul_o(),
    .vl_multiple_o(),
    .n_within_m_o(),
    .emul_c_valid_o(),
    .group_aligned_o(),
    .group_in_bounds_o()
  );

  always_comb begin
    ari_decode = '0;
    ari_decode.is_fp = rs_i.meta.is_fp;
    ari_decode.is_mx = rs_i.meta.is_mx;
    ari_decode.is_integer_mx = rs_i.meta.is_integer_mx;
    ari_decode.vs1 = rs_i.meta.vs1;
    ari_decode.vs2 = rs_i.meta.vs2;
    ari_decode.vd = rs_i.meta.vd;
    ari_decode.signed_a = rs_i.meta.signed_a;
    ari_decode.signed_b = rs_i.meta.signed_b;
    ari_decode.w_log2 = rs_i.meta.w_log2;
    ari_decode.eew_log2 = rs_i.meta.eew_log2;
    ari_decode.lambda = geometry_lambda;
    ari_decode.lmul = geometry_lmul;
    ari_decode.emul_c = geometry_emul_c;
    ari_decode.m = geometry_m;
    ari_decode.n = geometry_n;
    ari_decode.k_eff = geometry_k_eff;
    ari_decode.read_mask = rs_i.meta.read_mask;
    ari_decode.write_mask = rs_i.meta.write_mask;
  end

  logic compute_cmd_ready;
  logic compute_busy;
  logic compute_done_valid;
  logic [`ROB_DEPTH_WIDTH-1:0] compute_done_tag;
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0] active_pc_q;
`endif
  logic [31:0] compute_read_lock;
  logic [31:0] compute_write_lock;
  logic compute_vrf_req_valid;
  logic [`REGFILE_INDEX_WIDTH-1:0] compute_vrf_index;
  logic [1:0] compute_vrf_operand;
  logic [4:0] compute_vrf_group;
  logic compute_vrf_rsp_ready;
  logic [`NUM_RT_UOP-1:0] compute_commit_valid;
  RT2VRF_t [`NUM_RT_UOP-1:0] compute_commit_data;
  logic compute_fflags_valid;
  logic [4:0] compute_fflags;

  logic accept_compute;
  logic execution_slot_free;
  logic result_pending_q;
  logic [`ROB_DEPTH_WIDTH-1:0] result_tag_q;
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0] result_pc_q;
`endif
  // Do not admit the next macro until the previous completion has
  // crossed the PU arbiter; otherwise prolonged arbiter backpressure could
  // let a later completion overwrite the pending ROB tag.
  assign execution_slot_free = !compute_busy && !result_pending_q;
  assign rs_ready_o = execution_slot_free && compute_cmd_ready;
  assign accept_compute = rs_valid_i && rs_ready_o;

`ifdef TB_SUPPORT
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_pc_q <= '0;
    end else if (flush_i) begin
      active_pc_q <= '0;
    end else begin
      if (accept_compute) begin
        active_pc_q <= rs_i.cmd.inst_pc;
      end
    end
  end
`endif

  ime_subsystem u_compute (
    .clk(clk),
    .rst_n(rst_n),
`ifdef IME_OPERAND_RS
    .snapshot_valid_i(rs_i.operand_rs),
    .snapshot_a_i(rs_i.a_snapshot),
    .snapshot_b_i(rs_i.b_snapshot),
    .snapshot_c_i(rs_i.c_snapshot),
`endif
    .cmd_valid_i(accept_compute),
    .cmd_i(rs_i.cmd),
    .decode_i(ari_decode),
    .cmd_rob_tag_i(rs_i.rob_entry),
    .cmd_ready_o(compute_cmd_ready),
    .flush_i(flush_i),
    .rob_head_valid_i(rob_head_valid_i),
    .rob_head_tag_i(rob_head_tag_i),
    .done_valid_o(compute_done_valid),
    .done_rob_tag_o(compute_done_tag),
    .read_lock_mask_o(compute_read_lock),
    .write_lock_mask_o(compute_write_lock),
    .vrf_read_req_valid_o(compute_vrf_req_valid),
    .vrf_read_req_ready_i(vrf_read_req_ready_i),
    .vrf_read_index_o(compute_vrf_index),
    .vrf_read_operand_o(compute_vrf_operand),
    .vrf_read_group_o(compute_vrf_group),
    .vrf_read_rsp_valid_i(vrf_read_rsp_valid_i),
    .vrf_read_rsp_ready_o(compute_vrf_rsp_ready),
    .vrf_read_data_i(vrf_read_data_i),
    .vrf_read_rsp_operand_i(vrf_read_rsp_operand_i),
    .vrf_read_rsp_group_i(vrf_read_rsp_group_i),
    .commit_valid_o(compute_commit_valid),
    .commit_data_o(compute_commit_data),
    .commit_ready_i(commit_ready_i),
    .commit_fflags_valid_o(compute_fflags_valid),
    .commit_fflags_o(compute_fflags),
    .busy_o(compute_busy)
  );

  assign vrf_read_req_valid_o = compute_vrf_req_valid;
  assign vrf_read_index_o = compute_vrf_index;
  assign vrf_read_operand_o = compute_vrf_operand;
  assign vrf_read_group_o = compute_vrf_group;
  assign vrf_read_rsp_ready_o = compute_vrf_rsp_ready;
  assign commit_valid_o = compute_commit_valid;
  assign commit_data_o = compute_commit_data;
  assign commit_rob_tag_o = compute_done_tag;
  assign commit_fflags_valid_o = compute_fflags_valid;
  assign commit_fflags_o = compute_fflags;

  // Include the queued RS entry in the lock set.  This closes the cycle gap
  // between Dispatch acceptance and the execution engine capturing operands.
  assign read_lock_mask_o = compute_read_lock |
      (rs_valid_i ? rs_i.meta.read_mask : 32'b0);
  assign write_lock_mask_o = compute_write_lock |
      (rs_valid_i ? rs_i.meta.write_mask : 32'b0);

  // Processor-unit completion uses the ordinary PU->arbiter->ROB path.  The
  // compute engine emits a one-cycle done pulse, so retain it in
  // a one-entry skid register until the arbiter accepts it.
  logic completion_valid;
  logic [`ROB_DEPTH_WIDTH-1:0] completion_tag;
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0] completion_pc;
`endif

  assign completion_valid = compute_done_valid;
  assign completion_tag = compute_done_tag;
`ifdef TB_SUPPORT
  assign completion_pc = active_pc_q;
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result_pending_q <= 1'b0;
      result_tag_q <= '0;
`ifdef TB_SUPPORT
      result_pc_q <= '0;
`endif
    end else if (flush_i) begin
      result_pending_q <= 1'b0;
    end else begin
      if (result_pending_q && result_ready_i)
        result_pending_q <= 1'b0;
      if (completion_valid) begin
        result_pending_q <= 1'b1;
        result_tag_q <= completion_tag;
`ifdef TB_SUPPORT
        result_pc_q <= completion_pc;
`endif
      end
    end
  end

  assign result_valid_o = result_pending_q;
  always_comb begin
    result_o = '0;
`ifdef TB_SUPPORT
    result_o.uop_pc = result_pc_q;
`endif
    result_o.rob_entry = result_tag_q;
    result_o.w_valid = 1'b0;
  end

  assign busy_o = compute_busy || rs_valid_i || result_pending_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
      assert (!(completion_valid && result_pending_q))
          else $error("IME completion skid register overflow");
      if (rs_valid_i) begin
        assert (!rs_i.meta.illegal)
            else $error("Illegal IME command entered the execution RS");
        assert (!rs_i.meta.is_tile)
            else $error("Tile memory command entered the IME compute RS");
      end
    end
  end
`endif
endmodule
