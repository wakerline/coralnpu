// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// IME compute composition.  This module contains no command-lifecycle FSM;
// ime_ctrl, ime_operand_fetch, ime_scheduler, ime_acc_bank,
// ime_result_packer and ime_commit own their respective state.  Integer and
// FP/MX work share the source-copied Zvt-style ime_pe_array hierarchy.  FP/MX
// remains one lane so the disclosed K reduction order is unchanged.
`ifndef IME_INT_PREEXT_OPT
`define IME_INT_PREEXT_OPT 1'b0
`endif

module ime_subsystem #(
  parameter int M_PAR = `IME_M_PAR,
  parameter int N_PAR = `IME_N_PAR,
  parameter int K_PAR = `IME_K_PAR,
  parameter int FP_LANES = `IME_FP_LANES,
  parameter bit INT_OPT = `IME_INT_OPT,
  parameter bit INT_STREAM = `IME_INT_STREAM,
  parameter bit ODN_OPT = `IME_ODN_OPT,
  parameter bit RESULT_INDEX_OPT = `IME_RESULT_INDEX_OPT,
  parameter bit INT_PREEXT_OPT = `IME_INT_PREEXT_OPT,
  parameter bit FETCH_PIPELINE = `IME_FETCH_PIPELINE,
  parameter bit FP_ORDERED = `IME_FP_ORDERED,
  parameter int MAX_M = `IME_MAX_M,
  parameter int MAX_C_REGS = `IME_MAX_C_REGS
) (
  input  logic                            clk,
  input  logic                            rst_n,
`ifdef IME_OPERAND_RS
  input logic snapshot_valid_i,
  input logic [8*`VLEN-1:0] snapshot_a_i, snapshot_b_i,
  input logic [MAX_C_REGS*`VLEN-1:0] snapshot_c_i,
`endif
  input  logic                            cmd_valid_i,
  input  RVVCmd                           cmd_i,
  input  IME_ARI_DECODE_t                 decode_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]     cmd_rob_tag_i,
  output logic                            cmd_ready_o,
  input  logic                            flush_i,

  input  logic                            rob_head_valid_i,
  input  logic [`ROB_DEPTH_WIDTH-1:0]     rob_head_tag_i,
  output logic                            done_valid_o,
  output logic [`ROB_DEPTH_WIDTH-1:0]     done_rob_tag_o,
  output logic [31:0]                     read_lock_mask_o,
  output logic [31:0]                     write_lock_mask_o,

  output logic                            vrf_read_req_valid_o,
  input  logic                            vrf_read_req_ready_i,
  output logic [`REGFILE_INDEX_WIDTH-1:0] vrf_read_index_o,
  output logic [1:0]                      vrf_read_operand_o,
  output logic [4:0]                      vrf_read_group_o,
  input  logic                            vrf_read_rsp_valid_i,
  output logic                            vrf_read_rsp_ready_o,
  input  logic [`VLEN-1:0]                vrf_read_data_i,
  input  logic [1:0]                      vrf_read_rsp_operand_i,
  input  logic [4:0]                      vrf_read_rsp_group_i,

  output logic [`NUM_RT_UOP-1:0]          commit_valid_o,
  output RT2VRF_t [`NUM_RT_UOP-1:0]       commit_data_o,
  input  logic                            commit_ready_i,
  output logic                            commit_fflags_valid_o,
  output logic [4:0]                      commit_fflags_o,
  output logic                            busy_o
);
  localparam int MAX_LMUL = 8;
  localparam int INT_CELLS = M_PAR * N_PAR;
  localparam int EXEC_LANES = (INT_CELLS > FP_LANES) ? INT_CELLS : FP_LANES;
  localparam int MAX_CELLS = MAX_M * MAX_M;
  localparam int ACC_INDEX_WIDTH = $clog2(MAX_CELLS);
  localparam int C_INDEX_WIDTH = $clog2(MAX_C_REGS * `VLENB);
  localparam int RESULT_INDEX_WIDTH =
      (ACC_INDEX_WIDTH > C_INDEX_WIDTH) ? ACC_INDEX_WIDTH : C_INDEX_WIDTH;
  localparam int VL_INDEX_WIDTH = `VL_WIDTH;
`ifdef ZVVFMM_ON
  // FP/MX retains the reference accumulator even when ordinary integer uses
  // the optimized lane-local path.
  localparam bit NEED_GLOBAL_ACC = 1'b1;
`else
  // In an integer-only build INT_OPT makes every legal compute command local,
  // so the 256-entry multi-port accumulator is statically unreachable.
  localparam bit NEED_GLOBAL_ACC = !INT_OPT;
`endif

  RVVCmd active_cmd;
  IME_ARI_DECODE_t active_decode;
  logic _unused_snapshot_bits;
  assign _unused_snapshot_bits = ^{active_cmd[130:40],
                                   active_decode[129:120],
                                   active_decode[63:0]};
  logic [`ROB_DEPTH_WIDTH-1:0] active_rob_tag;
  logic cmd_accept;
  logic fetch_done;
  logic init_valid;
  logic [`VL_WIDTH-1:0] init_m_index;
  logic [`VL_WIDTH-1:0] init_n_index;
  logic compute_start;
  logic scheduler_done;
  logic compute_done;
  logic pack_start;
  logic pack_done;
  logic commit_start;
  logic commit_done;

  ime_ctrl #(
    .INT_OPT(INT_OPT)
  ) u_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .flush_i(flush_i),
    .cmd_valid_i(cmd_valid_i),
    .cmd_i(cmd_i),
    .decode_i(decode_i),
    .cmd_rob_tag_i(cmd_rob_tag_i),
    .cmd_ready_o(cmd_ready_o),
    .cmd_accept_o(cmd_accept),
    .cmd_o(active_cmd),
    .decode_o(active_decode),
    .rob_tag_o(active_rob_tag),
    .fetch_done_i(fetch_done),
    .init_valid_o(init_valid),
    .init_m_index_o(init_m_index),
    .init_n_index_o(init_n_index),
    .compute_start_o(compute_start),
    .compute_done_i(compute_done),
    .pack_start_o(pack_start),
    .pack_done_i(pack_done),
    .rob_head_valid_i(rob_head_valid_i),
    .rob_head_tag_i(rob_head_tag_i),
    .commit_start_o(commit_start),
    .commit_done_i(commit_done),
    .done_valid_o(done_valid_o),
    .done_rob_tag_o(done_rob_tag_o),
    .read_lock_mask_o(read_lock_mask_o),
    .write_lock_mask_o(write_lock_mask_o),
    .busy_o(busy_o)
  );

  logic [MAX_LMUL*`VLEN-1:0] a_buffer;
  logic [MAX_LMUL*`VLEN-1:0] b_buffer;
  logic [MAX_C_REGS*`VLEN-1:0] c_buffer;
  logic [`VLEN-1:0] scale_buffer;
  logic fetch_busy;
  ime_operand_fetch #(
    .MAX_LMUL(MAX_LMUL),
    .MAX_C_REGS(MAX_C_REGS),
    .FETCH_PIPELINE(FETCH_PIPELINE)
  ) u_operand_fetch (
    .clk(clk),
    .rst_n(rst_n),
    .flush_i(flush_i),
`ifdef IME_OPERAND_RS
    .snapshot_valid_i(snapshot_valid_i),
    .snapshot_a_i(snapshot_a_i),
    .snapshot_b_i(snapshot_b_i),
    .snapshot_c_i(snapshot_c_i),
`endif
    .start_i(cmd_accept),
    .vs1_i(decode_i.vs1),
    .vs2_i(decode_i.vs2),
    .vd_i(decode_i.vd),
    .lmul_i(decode_i.lmul),
    .emul_c_i(decode_i.emul_c),
    .capture_scale_i(decode_i.is_mx),
    .busy_o(fetch_busy),
    .done_o(fetch_done),
    .vrf_read_req_valid_o(vrf_read_req_valid_o),
    .vrf_read_req_ready_i(vrf_read_req_ready_i),
    .vrf_read_index_o(vrf_read_index_o),
    .vrf_read_operand_o(vrf_read_operand_o),
    .vrf_read_group_o(vrf_read_group_o),
    .vrf_read_rsp_valid_i(vrf_read_rsp_valid_i),
    .vrf_read_rsp_ready_o(vrf_read_rsp_ready_o),
    .vrf_read_data_i(vrf_read_data_i),
    .vrf_read_rsp_operand_i(vrf_read_rsp_operand_i),
    .vrf_read_rsp_group_i(vrf_read_rsp_group_i),
    .a_data_o(a_buffer),
    .b_data_o(b_buffer),
    .c_data_o(c_buffer),
    .scale_data_o(scale_buffer)
  );

  logic scheduler_busy;
  logic reference_scheduler_busy;
  logic reference_scheduler_done;
  logic [M_PAR-1:0][`VL_WIDTH-1:0] int_m_index;
  logic [N_PAR-1:0][`VL_WIDTH-1:0] int_n_index;
  logic [K_PAR-1:0][11:0] int_k_index;
  logic [INT_CELLS-1:0] int_lane_active;
  logic [K_PAR-1:0] int_term_active;
  logic [`VL_WIDTH-1:0] reference_fp_m_index;
  logic [FP_LANES-1:0][`VL_WIDTH-1:0] reference_fp_n_index;
  logic [FP_LANES-1:0] reference_fp_lane_active;
  logic [11:0] reference_fp_k_index;
  logic [`VL_WIDTH-1:0] fp_m_index;
  logic [FP_LANES-1:0][`VL_WIDTH-1:0] fp_n_index;
  logic [FP_LANES-1:0] fp_lane_active;
  logic [11:0] fp_k_index;
  logic fp_forced_cell_done;
  logic scheduler_step_fire;
  logic ordered_fp_active;
  logic ordered_scheduler_busy;
  logic ordered_scheduler_done;
  logic ordered_issue_valid;
  logic ordered_issue_fire;
  logic [2:0] ordered_issue_context;
  logic [`VL_WIDTH-1:0] ordered_fp_m_index;
  logic [`VL_WIDTH-1:0] ordered_fp_n_index;
  logic [11:0] ordered_fp_k_index;
  logic ordered_fp_first_k;
  logic ordered_fp_last_k;

  // The ordered scheduler consumes PE return metadata.  Keep these
  // declarations ahead of that instance so synthesis frontends do not infer
  // implicit wires before seeing the intended SystemVerilog types.
  typedef struct packed {
    logic [INT_CELLS-1:0] lane_active;
    logic [INT_CELLS-1:0][RESULT_INDEX_WIDTH-1:0] result_index;
    logic result_index_is_physical;
    logic first_k;
    logic last_k;
    logic macro_last;
    logic [2:0] fp_context;
  } ime_int_step_tag_t;

  ime_int_step_tag_t int_step_tag_in;
  ime_int_step_tag_t int_step_tag_out;
  logic int_pe_out_valid;
  logic pe_forced_scale_nan;

  assign ordered_fp_active = FP_ORDERED && active_decode.is_fp &&
                             !active_decode.is_integer_mx;

  ime_scheduler #(
    .M_PAR(M_PAR),
    .N_PAR(N_PAR),
    .K_PAR(K_PAR),
    .FP_LANES(FP_LANES)
  ) u_scheduler (
    .clk(clk),
    .rst_n(rst_n),
    .flush_i(flush_i),
    .start_i(compute_start && !ordered_fp_active),
    .is_fp_i(active_decode.is_fp),
    .is_integer_mx_i(active_decode.is_integer_mx),
    .w_log2_i(active_decode.w_log2),
    .m_i(active_decode.m),
    .n_i(active_decode.n),
    .k_eff_i(active_decode.k_eff),
    .step_fire_i(scheduler_step_fire),
    .fp_forced_cell_done_i(fp_forced_cell_done),
    .busy_o(reference_scheduler_busy),
    .done_o(reference_scheduler_done),
    .int_m_index_o(int_m_index),
    .int_n_index_o(int_n_index),
    .int_k_index_o(int_k_index),
    .int_lane_active_o(int_lane_active),
    .int_term_active_o(int_term_active),
    .fp_m_index_o(reference_fp_m_index),
    .fp_n_index_o(reference_fp_n_index),
    .fp_lane_active_o(reference_fp_lane_active),
    .fp_k_index_o(reference_fp_k_index)
  );

  ime_fp_ordered_scheduler #(
    .MAX_CONTEXTS(8)
  ) u_fp_ordered_scheduler (
    .clk(clk),
    .rst_n(rst_n),
    .flush_i(flush_i),
    .start_i(compute_start && ordered_fp_active),
    .w_log2_i(active_decode.w_log2),
    .m_i(active_decode.m),
    .n_i(active_decode.n),
    .k_eff_i(active_decode.k_eff),
    .issue_valid_o(ordered_issue_valid),
    .issue_fire_i(ordered_issue_fire),
    .issue_context_o(ordered_issue_context),
    .issue_m_index_o(ordered_fp_m_index),
    .issue_n_index_o(ordered_fp_n_index),
    .issue_k_index_o(ordered_fp_k_index),
    .issue_first_k_o(ordered_fp_first_k),
    .issue_last_k_o(ordered_fp_last_k),
    .result_fire_i(int_pe_out_valid && ordered_fp_active),
    .result_context_i(int_step_tag_out.fp_context),
    .result_last_k_i(int_step_tag_out.last_k),
    .result_forced_cell_done_i(pe_forced_scale_nan),
    .busy_o(ordered_scheduler_busy),
    .done_o(ordered_scheduler_done)
  );

  always_comb begin
    scheduler_busy = reference_scheduler_busy;
    scheduler_done = reference_scheduler_done;
    fp_m_index = reference_fp_m_index;
    fp_n_index = reference_fp_n_index;
    fp_lane_active = reference_fp_lane_active;
    fp_k_index = reference_fp_k_index;
    if (ordered_fp_active) begin
      scheduler_busy = ordered_scheduler_busy;
      scheduler_done = ordered_scheduler_done;
      fp_m_index = ordered_fp_m_index;
      fp_n_index = '0;
      fp_n_index[0] = ordered_fp_n_index;
      fp_lane_active = '0;
      fp_lane_active[0] = ordered_issue_valid;
      fp_k_index = ordered_fp_k_index;
    end
  end

  // Accumulator bank read/write ports.  The final read port belongs to the
  // sequential result packer; the others are execution lanes.
  logic [EXEC_LANES:0][ACC_INDEX_WIDTH-1:0] acc_read_index;
  logic [ACC_INDEX_WIDTH-1:0] pack_acc_read_index;
  logic [EXEC_LANES:0][31:0] acc_read_data;
  logic [EXEC_LANES-1:0] acc_write_valid;
  logic [EXEC_LANES-1:0][ACC_INDEX_WIDTH-1:0] acc_write_index;
  logic [EXEC_LANES-1:0][31:0] acc_write_data;

  if (NEED_GLOBAL_ACC) begin : gen_global_acc
    ime_acc_bank #(
      .MAX_M(MAX_M),
      .READ_PORTS(EXEC_LANES + 1),
      .WRITE_PORTS(EXEC_LANES)
    ) u_acc_bank (
      .clk(clk),
      .read_index_i(acc_read_index),
      .read_data_o(acc_read_data),
      .write_valid_i(acc_write_valid),
      .write_index_i(acc_write_index),
      .write_data_i(acc_write_data)
    );
  end else begin : gen_no_global_acc
    assign acc_read_data = '0;
  end

  logic [8:0] a_elements_per_register;
  logic [8:0] c_elements_per_register;
  logic [15:0] init_sequential_index;
  logic [15:0] init_c_flat_index;
  logic [31:0] init_acc_data;
  always_comb begin
    a_elements_per_register = `VLEN >> active_decode.eew_log2;
    c_elements_per_register = `VLEN >> (3 + active_cmd.arch_state.sew);
    // Freeze 13.9.2: C has a fixed physical M-by-M shape.  N selects active
    // columns only and therefore must not compress the physical row stride.
    init_sequential_index = ime_pkg::ime_row_major_index(
        16'(init_m_index), 16'(init_n_index), 16'(active_decode.m));
    init_c_flat_index = ime_pkg::ime_tile_reg_index(
        init_sequential_index, active_decode.emul_c, active_decode.lambda,
        c_elements_per_register);
    unique case (active_cmd.arch_state.sew)
      3'd0: init_acc_data = 32'(c_buffer >> (init_c_flat_index << 3));
      3'd1: init_acc_data = 32'(c_buffer >> (init_c_flat_index << 4));
      3'd2: init_acc_data = 32'(c_buffer >> (init_c_flat_index << 5));
      default: init_acc_data = '0;
    endcase
  end

  logic [M_PAR-1:0][K_PAR-1:0][31:0] int_a;
  logic [N_PAR-1:0][K_PAR-1:0][31:0] int_b;
  logic [INT_CELLS-1:0][31:0] int_acc_in;
  logic [INT_CELLS-1:0][31:0] int_c_seed;
  logic [INT_CELLS-1:0][C_INDEX_WIDTH-1:0] int_c_flat_index;
  logic [INT_CELLS-1:0][31:0] int_local_acc_q;
  logic ordinary_int_opt;
  logic ordinary_int_stream;
  logic int_result_is_direct;
  logic int_first_k;
  logic int_last_k;
  logic int_macro_last;
  logic pe_first_k;
  logic pe_last_k;
`ifdef ZVVFMM_ON
  assign ordinary_int_opt = INT_OPT && !active_decode.is_fp;
`else
  assign ordinary_int_opt = INT_OPT;
`endif
  assign ordinary_int_stream = INT_STREAM && ordinary_int_opt;
  // With RESULT_INDEX_OPT enabled the packet-carried semantic bit is the
  // authoritative return-path selector.  The REF build preserves the
  // existing command-level routing bit-for-bit.
  assign int_result_is_direct = RESULT_INDEX_OPT ?
      int_step_tag_out.result_index_is_physical : ordinary_int_opt;
  assign int_first_k = int_k_index[0] == '0;
  assign int_last_k = (int_k_index[0] + 12'(K_PAR)) >=
                      active_decode.k_eff;
  assign int_macro_last = int_last_k &&
      ((int_m_index[0] + VL_INDEX_WIDTH'(M_PAR)) >= active_decode.m) &&
      ((int_n_index[0] + VL_INDEX_WIDTH'(N_PAR)) >= active_decode.n);
  assign pe_first_k = ordered_fp_active ? ordered_fp_first_k : int_first_k;
  assign pe_last_k = ordered_fp_active ? ordered_fp_last_k : int_last_k;

  ime_int_operand_selector #(
    .M_PAR(M_PAR),
    .N_PAR(N_PAR),
    .K_PAR(K_PAR),
    .MAX_LMUL(MAX_LMUL),
    .MAX_C_REGS(MAX_C_REGS),
    .VLEN(`VLEN),
    .OPT(ODN_OPT)
  ) u_int_operand_selector (
    .a_data_i(a_buffer),
    .b_data_i(b_buffer),
    .c_data_i(c_buffer),
    .m_index_i(int_m_index),
    .n_index_i(int_n_index),
    .k_index_i(int_k_index),
    .lane_active_i(int_lane_active),
    .term_active_i(int_term_active),
    .eew_log2_i(active_decode.eew_log2),
    .sew_i(active_cmd.arch_state.sew),
    .lambda_i(active_decode.lambda),
    .lmul_i(active_decode.lmul),
    .emul_c_i(active_decode.emul_c),
    .m_i(active_decode.m),
    .k_eff_i(active_decode.k_eff),
    .select_valid_i(scheduler_busy && !active_decode.is_fp),
    .a_o(int_a),
    .b_o(int_b),
    .c_seed_o(int_c_seed),
    .c_flat_index_o(int_c_flat_index)
  );

  always_comb begin
    for (int lane = 0; lane < INT_CELLS; lane++) begin
      if (ordinary_int_stream)
        int_acc_in[lane] = int_c_seed[lane];
      else if (ordinary_int_opt)
        int_acc_in[lane] = int_first_k ? int_c_seed[lane] :
                                       int_local_acc_q[lane];
      else
        int_acc_in[lane] = acc_read_data[lane];
    end
  end

  logic int_step_inflight_q;
  logic int_pe_in_valid;
  logic int_pe_in_ready;
  logic int_pe_in_fire;
  logic int_pe_busy;
  logic [INT_CELLS-1:0][31:0] int_pe_result;
  fpnew_pkg::status_t [INT_CELLS-1:0] pe_status;
  logic [INT_CELLS-1:0] pe_lane_active;
  logic [INT_CELLS-1:0][1:0][63:0] pe_fp_operands;
  logic [INT_CELLS-1:0][7:0] pe_fp_mask;
  fpnew_pkg::fp_format_e pe_fp_src_fmt;
  fpnew_pkg::fp_format_e pe_fp_dst_fmt;

  logic [FP_LANES-1:0][7:0][31:0] fp_raw_a;
  logic [FP_LANES-1:0][7:0][31:0] fp_raw_b;
  logic [FP_LANES-1:0][7:0][31:0] fp_normalized_a;
  logic [FP_LANES-1:0][7:0][31:0] fp_normalized_b;
  logic [FP_LANES-1:0][7:0] mx_scale_a;
  logic [FP_LANES-1:0][7:0] mx_scale_b;
  logic [FP_LANES-1:0][31:0] mx_scale;
  fpnew_pkg::status_t [FP_LANES-1:0] mx_scale_status;
  logic [FP_LANES-1:0] mx_scale_nan;
  logic [INT_CELLS-1:0][31:0] pe_scale;
  fpnew_pkg::status_t [INT_CELLS-1:0] pe_scale_status;
  logic [INT_CELLS-1:0] pe_scale_nan;
  fpnew_pkg::roundmode_e pe_round_mode;

`ifdef ZVE32F_ON
  assign pe_round_mode = fpnew_pkg::roundmode_e'(active_cmd.arch_state.frm);
`else
  assign pe_round_mode = fpnew_pkg::RNE;
`endif

`ifdef ZVVFMM_ON
  for (genvar fp_lane = 0; fp_lane < FP_LANES; fp_lane++) begin : gen_fp_adapter_lane
    for (genvar fp_term = 0; fp_term < 8; fp_term++) begin : gen_fp_adapter_term
      ime_fp_format_adapter u_format_a (
        .raw_i(fp_raw_a[fp_lane][fp_term]),
        .eew_log2_i(active_decode.eew_log2),
        .altfmt_i(active_cmd.arch_state.ime_altfmt_a),
        .normalized_o(fp_normalized_a[fp_lane][fp_term])
      );
      ime_fp_format_adapter u_format_b (
        .raw_i(fp_raw_b[fp_lane][fp_term]),
        .eew_log2_i(active_decode.eew_log2),
        .altfmt_i(active_cmd.arch_state.ime_altfmt_b),
        .normalized_o(fp_normalized_b[fp_lane][fp_term])
      );
    end
    ime_mx_scale u_mx_scale (
      .scale_a_i(mx_scale_a[fp_lane]),
      .scale_b_i(mx_scale_b[fp_lane]),
      .rnd_mode_i(pe_round_mode),
      .scale_o(mx_scale[fp_lane]),
      .status_o(mx_scale_status[fp_lane]),
      .is_nan_o(mx_scale_nan[fp_lane])
    );
  end
`else
  assign fp_normalized_a = '0;
  assign fp_normalized_b = '0;
  assign mx_scale = '0;
  assign mx_scale_status = '0;
  assign mx_scale_nan = '0;
`endif

  logic signed [31:0] integer_mx_sum_q [FP_LANES-1:0];
  logic signed [31:0] integer_mx_product [FP_LANES-1:0];
  logic signed [31:0] integer_mx_total [FP_LANES-1:0];
  logic [FP_LANES-1:0][31:0] integer_mx_fp32;
  logic integer_mx_block_last;
  logic integer_mx_advance;
  logic [11:0] integer_mx_block_size;
  logic [11:0] integer_mx_block_mask;
  assign integer_mx_block_size = active_cmd.arch_state.ime_bs ?
                                 12'd16 : 12'd32;
  assign integer_mx_block_mask = integer_mx_block_size - 1'b1;
  assign integer_mx_block_last =
      (((fp_k_index + 12'd1) & integer_mx_block_mask) == 0) ||
      ((fp_k_index + 12'd1) == active_decode.k_eff);
`ifdef ZVVFMM_ON
  for (genvar fp_lane = 0; fp_lane < FP_LANES; fp_lane++) begin : gen_int_mx_cast
    ime_int_to_fp32_adapter u_int_to_fp32 (
      .value_i(integer_mx_total[fp_lane]),
      .fp32_o(integer_mx_fp32[fp_lane])
    );
  end
`else
  assign integer_mx_fp32 = '0;
`endif

  always_comb begin
    int_step_tag_in = '0;
    int_step_tag_in.lane_active = pe_lane_active;
    int_step_tag_in.first_k = pe_first_k;
    int_step_tag_in.last_k = pe_last_k;
    int_step_tag_in.macro_last = int_macro_last;
    int_step_tag_in.fp_context = ordered_issue_context;
    int_step_tag_in.result_index_is_physical =
        RESULT_INDEX_OPT && ordinary_int_opt;
    for (int lane = 0; lane < INT_CELLS; lane++) begin
      if (RESULT_INDEX_OPT && ordinary_int_opt)
        int_step_tag_in.result_index[lane] =
            RESULT_INDEX_WIDTH'(int_c_flat_index[lane]);
      else
        int_step_tag_in.result_index[lane] =
            RESULT_INDEX_WIDTH'(acc_read_index[lane]);
    end
  end

  // The scheduler holds one architectural k-step until the copied Zvt-style
  // mulbulk -> adder pipeline returns it.  This keeps the external transient
  // accumulator single-versioned and is the lowest-area RAW-safe schedule.
  assign integer_mx_advance = scheduler_busy && active_decode.is_integer_mx &&
                              !int_step_inflight_q &&
                              !integer_mx_block_last;
  assign int_pe_in_valid = ordered_fp_active ? ordered_issue_valid :
      (scheduler_busy &&
       (ordinary_int_stream || !int_step_inflight_q) &&
       (!active_decode.is_integer_mx || integer_mx_block_last));
  assign int_pe_in_fire = int_pe_in_valid && int_pe_in_ready;
  assign ordered_issue_fire = ordered_fp_active && int_pe_in_fire;
  assign scheduler_step_fire = integer_mx_advance ||
      (ordinary_int_stream ? int_pe_in_fire : int_pe_out_valid);
  // In streaming mode scheduler_done marks the final issue, not completion.
  // Keep the macro in CTRL_COMPUTE until that exact packet returns and has
  // written the direct result buffer.
  assign compute_done = ordered_fp_active ? ordered_scheduler_done :
      (ordinary_int_stream ?
       (int_pe_out_valid && int_step_tag_out.macro_last) : scheduler_done);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      int_step_inflight_q <= 1'b0;
    end else if (flush_i || compute_start) begin
      int_step_inflight_q <= 1'b0;
    end else begin
      if (!ordinary_int_stream && !ordered_fp_active) begin
        if (int_pe_in_fire)
          int_step_inflight_q <= 1'b1;
        if (int_pe_out_valid)
          int_step_inflight_q <= 1'b0;
      end
    end
  end

  // With the Stage-1 OPT schedule only one step is in flight, so each physical
  // output lane is a complete local accumulation context for the current
  // M_PAR-by-N_PAR block.  first_k ignores stale bits; no reset tree is needed.
  always_ff @(posedge clk) begin
    if (!flush_i && ordinary_int_opt && !ordinary_int_stream &&
        int_pe_out_valid) begin
      for (int lane = 0; lane < INT_CELLS; lane++) begin
        if (int_step_tag_out.lane_active[lane])
          int_local_acc_q[lane] <= int_pe_result[lane];
      end
    end
  end


  // This transient sum is valid only while the scheduler owns an integer-MX
  // command.  compute_start initializes every lane before scheduler_busy can
  // consume it, so the data bits need no reset tree.
  always_ff @(posedge clk) begin
    if (flush_i || compute_start) begin
      for (int lane = 0; lane < FP_LANES; lane++)
        integer_mx_sum_q[lane] <= '0;
    end else if (scheduler_busy && active_decode.is_integer_mx &&
                 !int_step_inflight_q) begin
      for (int lane = 0; lane < FP_LANES; lane++) begin
        if (integer_mx_block_last) begin
          if (int_pe_in_valid && int_pe_in_ready)
            integer_mx_sum_q[lane] <= '0;
        end else begin
          integer_mx_sum_q[lane] <= integer_mx_total[lane];
        end
      end
    end
  end

  ime_pe_array #(
    .M_PAR(M_PAR),
    .N_PAR(N_PAR),
    .K_PAR(K_PAR),
    .FP_LANES(FP_LANES),
    .INT_STREAM(INT_STREAM),
    .INT_PREEXT_OPT(INT_PREEXT_OPT),
    .FP_ORDERED(FP_ORDERED),
    .TAG_TYPE(ime_int_step_tag_t)
  ) u_pe_array (
    .clk(clk),
    .rst_n(rst_n),
    .a_i(int_a),
    .b_i(int_b),
    .term_active_i(int_term_active),
    .lane_active_i(pe_lane_active),
    .is_fp_i(active_decode.is_fp),
    .ordered_fp_i(ordered_fp_active),
    .scaled_i(active_decode.is_mx),
    .scale_i(pe_scale),
    .scale_status_i(pe_scale_status),
    .scale_nan_i(pe_scale_nan),
    .fp_operands_i(pe_fp_operands),
    .fp_mask_i(pe_fp_mask),
    .rnd_mode_i(`IME_FP_PSM ? fpnew_pkg::ROD : pe_round_mode),
    .final_rnd_mode_i(pe_round_mode),
    .fp_src_fmt_i(pe_fp_src_fmt),
    .fp_dst_fmt_i(pe_fp_dst_fmt),
    .accumulator_i(int_acc_in),
    .int_first_k_i(pe_first_k),
    .signed_a_i(active_decode.signed_a),
    .signed_b_i(active_decode.signed_b),
    .eew_log2_i(active_decode.eew_log2),
    .sew_i(active_cmd.arch_state.sew),
    .in_tag_i(int_step_tag_in),
    .in_valid_i(int_pe_in_valid),
    .in_ready_o(int_pe_in_ready),
    .flush_i(flush_i),
    .result_o(int_pe_result),
    .status_o(pe_status),
    .out_tag_o(int_step_tag_out),
    .forced_scale_nan_o(pe_forced_scale_nan),
    .out_valid_o(int_pe_out_valid),
    .out_ready_i(1'b1),
    .busy_o(int_pe_busy)
  );

  // IME independently normalizes fmt_A/fmt_B encodings into one common fpnew
  // format, then packs exactly one W-term sub-dot-product into 64 bits:
  //   W=1: 1xFP32, W=2: 2xFP32, W=4: 4xFP16, W=8: 8xFP8.
  // The mapper is encoding-only; multiplication/reduction remains entirely
  // inside the copied Zvt FP lane and its shared FP primitives.
  always_comb begin : extract_fp_operands
    fp_raw_a = '0;
    fp_raw_b = '0;
    mx_scale_a = '0;
    mx_scale_b = '0;
    integer_mx_product = '{default: '0};
    integer_mx_total = '{default: '0};
    for (int lane = 0; lane < FP_LANES; lane++) begin
      for (int term = 0; term < 8; term++) begin
        automatic logic [11:0] scalar_k = fp_k_index + 12'(term);
        automatic logic [15:0] a_sequential =
            ime_pkg::ime_row_major_index(
                16'(fp_m_index), 16'(scalar_k),
                16'(active_decode.k_eff));
        automatic logic [15:0] b_sequential =
            ime_pkg::ime_row_major_index(
                16'(fp_n_index[lane]), 16'(scalar_k),
                16'(active_decode.k_eff));
        automatic logic [15:0] a_flat = ime_pkg::ime_tile_reg_index(
            a_sequential, {1'b0, active_decode.lmul}, active_decode.lambda,
            a_elements_per_register);
        automatic logic [15:0] b_flat = ime_pkg::ime_tile_reg_index(
            b_sequential, {1'b0, active_decode.lmul}, active_decode.lambda,
            a_elements_per_register);
        fp_raw_a[lane][term] = 32'(
            a_buffer >> (a_flat << active_decode.eew_log2));
        fp_raw_b[lane][term] = 32'(
            b_buffer >> (b_flat << active_decode.eew_log2));
      end
      begin
        automatic int unsigned block_shift =
            active_cmd.arch_state.ime_bs ? 4 : 5;
        automatic int unsigned block_index =
            int'(fp_k_index) >> block_shift;
        automatic int unsigned scale_stride =
            (int'(active_decode.lambda) <<
             (3 + int'(active_cmd.arch_state.sew))) >> 4;
        automatic int unsigned pair_a_index =
            int'(fp_m_index) * scale_stride + block_index;
        automatic int unsigned pair_b_index =
            int'(fp_n_index[lane]) * scale_stride + block_index;
        automatic logic signed [31:0] integer_a = '0;
        automatic logic signed [31:0] integer_b = '0;
        mx_scale_a[lane] = 8'(scale_buffer >> (pair_a_index << 4));
        mx_scale_b[lane] =
            8'(scale_buffer >> ((pair_b_index << 4) + 8));
        unique case (active_decode.eew_log2)
          3'd2: begin
            integer_a = {{28{fp_raw_a[lane][0][3]}},
                         fp_raw_a[lane][0][3:0]};
            integer_b = {{28{fp_raw_b[lane][0][3]}},
                         fp_raw_b[lane][0][3:0]};
          end
          3'd3: begin
            integer_a = {{24{fp_raw_a[lane][0][7]}},
                         fp_raw_a[lane][0][7:0]};
            integer_b = {{24{fp_raw_b[lane][0][7]}},
                         fp_raw_b[lane][0][7:0]};
          end
          default: ;
        endcase
        integer_mx_product[lane] = integer_a * integer_b;
        integer_mx_total[lane] = integer_mx_sum_q[lane] +
                                 integer_mx_product[lane];
      end
    end
  end

  always_comb begin : prepare_pe_operands
    pe_lane_active = int_lane_active;
    pe_fp_operands = '0;
    pe_fp_mask = '0;
    pe_scale = '0;
    pe_scale_status = '0;
    pe_scale_nan = '0;
    pe_fp_dst_fmt = fpnew_pkg::FP32;
    unique case (active_decode.eew_log2)
      3'd5: pe_fp_src_fmt = fpnew_pkg::FP32;
      3'd4: pe_fp_src_fmt = fpnew_pkg::FP32;
      3'd3: pe_fp_src_fmt = fpnew_pkg::FP16;
      default: pe_fp_src_fmt = fpnew_pkg::FP8;
    endcase

    if (active_decode.is_fp) begin
      pe_lane_active = '0;
      for (int lane = 0; lane < FP_LANES; lane++) begin
        pe_lane_active[lane] = fp_lane_active[lane];
        pe_scale[lane] = mx_scale[lane];
        pe_scale_status[lane] = mx_scale_status[lane];
        pe_scale_nan[lane] = mx_scale_nan[lane];
      end
    end

    for (int lane = 0; lane < FP_LANES; lane++) begin
      for (int term = 0; term < 8; term++) begin
        automatic logic [11:0] scalar_k = fp_k_index + 12'(term);
        if ((term < (1 << active_decode.w_log2)) &&
            (scalar_k < active_decode.k_eff)) begin
          unique case (active_decode.eew_log2)
            3'd5, 3'd4: begin
              pe_fp_operands[lane][0][term*32 +: 32] =
                  fp_normalized_a[lane][term];
              pe_fp_operands[lane][1][term*32 +: 32] =
                  fp_normalized_b[lane][term];
              pe_fp_mask[lane][term*4 +: 4] = 4'b1111;
            end
            3'd3: begin
              pe_fp_operands[lane][0][term*16 +: 16] =
                  fp_normalized_a[lane][term][15:0];
              pe_fp_operands[lane][1][term*16 +: 16] =
                  fp_normalized_b[lane][term][15:0];
              pe_fp_mask[lane][term*2 +: 2] = 2'b11;
            end
            default: begin
              pe_fp_operands[lane][0][term*8 +: 8] =
                  fp_normalized_a[lane][term][7:0];
              pe_fp_operands[lane][1][term*8 +: 8] =
                  fp_normalized_b[lane][term][7:0];
              pe_fp_mask[lane][term] = 1'b1;
            end
          endcase
        end
      end
      if (active_decode.is_integer_mx) begin
        pe_fp_operands[lane][0][31:0] = integer_mx_fp32[lane];
        pe_fp_operands[lane][1][31:0] = 32'h3f80_0000;
        pe_fp_mask[lane][3:0] = {4{fp_lane_active[lane]}};
        pe_fp_src_fmt = fpnew_pkg::FP32;
      end
    end
  end
  assign fp_forced_cell_done = pe_forced_scale_nan;

  // Keep asynchronous accumulator read addressing independent from the
  // execution write-data mux.  Combining them in one always_comb creates an
  // artificial read-address -> read-data -> PE -> write-data -> sensitivity
  // loop in simulators, even though the bank writes only on the clock edge.
  always_comb begin
    acc_read_index = '0;
    for (int row = 0; row < M_PAR; row++) begin
      for (int column = 0; column < N_PAR; column++) begin
        automatic int lane = row * N_PAR + column;
        acc_read_index[lane] = (ACC_INDEX_WIDTH)'(
            ime_pkg::ime_row_major_index(
                16'(int_m_index[row]), 16'(int_n_index[column]),
                16'(MAX_M)));
      end
    end
    if (active_decode.is_fp) begin
      for (int lane = 0; lane < FP_LANES; lane++) begin
        acc_read_index[lane] = (ACC_INDEX_WIDTH)'(
            ime_pkg::ime_row_major_index(
                16'(fp_m_index), 16'(fp_n_index[lane]), 16'(MAX_M)));
      end
    end
    acc_read_index[EXEC_LANES] = pack_acc_read_index;
  end

  // Execution and initialization share accumulator write ports, but the
  // controller makes the phases mutually exclusive.
  always_comb begin
    acc_write_valid = '0;
    acc_write_index = '0;
    acc_write_data = '0;
    for (int lane = 0; lane < INT_CELLS; lane++) begin
      if (int_pe_out_valid && !int_result_is_direct &&
          int_step_tag_out.lane_active[lane]) begin
        acc_write_valid[lane] = 1'b1;
        acc_write_index[lane] =
            ACC_INDEX_WIDTH'(int_step_tag_out.result_index[lane]);
        acc_write_data[lane] = int_pe_result[lane];
      end
    end
    if (init_valid) begin
      acc_write_valid = '0;
      acc_write_valid[0] = 1'b1;
      acc_write_index[0] = (ACC_INDEX_WIDTH)'(
          ime_pkg::ime_row_major_index(
              16'(init_m_index), 16'(init_n_index), 16'(MAX_M)));
      acc_write_data[0] = init_acc_data;
    end
  end

  logic [MAX_C_REGS*`VLEN-1:0] result_data;
  logic [MAX_C_REGS*`VLENB-1:0] result_strobe;
  logic pack_busy;
  ime_result_packer #(
    .MAX_M(MAX_M),
    .MAX_C_REGS(MAX_C_REGS),
    .DIRECT_LANES(INT_CELLS),
    .DIRECT_OPT(INT_OPT),
    .DIRECT_INDEX_PREMAPPED(RESULT_INDEX_OPT)
  ) u_result_packer (
    .clk(clk),
    .rst_n(rst_n),
    .flush_i(flush_i),
    .start_i(pack_start),
    .m_i(active_decode.m),
    .n_i(active_decode.n),
    .sew_i(active_cmd.arch_state.sew),
    .lambda_i(active_decode.lambda),
    .emul_c_i(active_decode.emul_c),
    .c_data_i(c_buffer),
    .busy_o(pack_busy),
    .done_o(pack_done),
    .acc_read_index_o(pack_acc_read_index),
    .acc_read_data_i(acc_read_data[EXEC_LANES]),
    .direct_start_i(compute_start && ordinary_int_opt),
    .direct_write_valid_i(int_pe_out_valid && int_result_is_direct &&
                          int_step_tag_out.last_k),
    .direct_lane_active_i(int_step_tag_out.lane_active),
    .direct_index_is_physical_i(
        int_step_tag_out.result_index_is_physical),
    .direct_cell_index_i(int_step_tag_out.result_index),
    .direct_write_data_i(int_pe_result),
    .result_data_o(result_data),
    .result_strobe_o(result_strobe)
  );

  logic [`ROB_DEPTH_WIDTH-1:0] commit_rob_tag;
  logic commit_busy;
  logic commit_last_valid;
  ime_commit #(
    .MAX_C_REGS(MAX_C_REGS)
  ) u_commit (
    .clk(clk),
    .rst_n(rst_n),
    .flush_i(flush_i),
    .start_i(commit_start),
    .vd_i(active_decode.vd),
    .emul_c_i(active_decode.emul_c),
    .pc_i(active_cmd.inst_pc),
    .rob_tag_i(active_rob_tag),
    .rob_head_valid_i(rob_head_valid_i),
    .rob_head_tag_i(rob_head_tag_i),
    .result_data_i(result_data),
    .result_strobe_i(result_strobe),
    .busy_o(commit_busy),
    .last_valid_o(commit_last_valid),
    .done_o(commit_done),
    .rob_tag_o(commit_rob_tag),
    .commit_valid_o(commit_valid_o),
    .commit_data_o(commit_data_o),
    .commit_ready_i(commit_ready_i)
  );

  logic [4:0] fflags_q;
  logic [4:0] fp_fflags_or;
  always_comb begin
    fp_fflags_or = '0;
    for (int lane = 0; lane < INT_CELLS; lane++) begin
      if (int_pe_out_valid && int_step_tag_out.lane_active[lane]) begin
        fp_fflags_or |= {pe_status[lane].NV, pe_status[lane].DZ,
                         pe_status[lane].OF, pe_status[lane].UF,
                         pe_status[lane].NX};
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fflags_q <= '0;
    end else if (flush_i || cmd_accept) begin
      fflags_q <= '0;
    end else if (|fp_fflags_or) begin
      fflags_q <= fflags_q | fp_fflags_or;
    end
  end
  // Present accrued flags with the final architectural write beat.  Retire
  // still updates FCSR only when that beat fires; valid must not depend on
  // commit_ready_i (and no separate fflags-ready protocol is introduced).
  assign commit_fflags_valid_o = commit_last_valid && active_decode.is_fp &&
                                 (|fflags_q);
  assign commit_fflags_o = fflags_q;

`ifndef SYNTHESIS
  initial begin
    assert (MAX_C_REGS <= 16);
    assert (!INT_STREAM || INT_OPT)
        else $error("IME INT_STREAM requires the Stage-1 INT_OPT datapath");
    assert (!ODN_OPT || INT_STREAM)
        else $error("IME ODN_OPT requires the Stage-2 INT_STREAM datapath");
    assert (!RESULT_INDEX_OPT || ODN_OPT)
        else $error("IME RESULT_INDEX_OPT requires the optimized ODN");
    assert (!INT_PREEXT_OPT || INT_STREAM)
        else $error("IME INT_PREEXT_OPT requires integer streaming");
`ifndef ZVVFMM_ON
    assert (!FP_ORDERED)
        else $error("IME FP_ORDERED requires the Zvvfmm datapath");
`endif
  end
  logic [3:0] int_stream_inflight_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      int_stream_inflight_q <= '0;
    end else if (flush_i || compute_start) begin
      int_stream_inflight_q <= '0;
    end else if (ordinary_int_stream) begin
      unique case ({int_pe_in_fire, int_pe_out_valid})
        2'b10: int_stream_inflight_q <= int_stream_inflight_q + 1'b1;
        2'b01: int_stream_inflight_q <= int_stream_inflight_q - 1'b1;
        default: ;
      endcase
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
      if (int_pe_out_valid) begin
        if (int_step_tag_out.result_index_is_physical) begin
          assert (RESULT_INDEX_OPT)
              else $error("IME physical result index without OPT profile");
          for (int lane = 0; lane < INT_CELLS; lane++) begin
            if (int_step_tag_out.lane_active[lane]) begin
              assert (int_step_tag_out.result_index[lane] <
                      MAX_C_REGS * `VLENB)
                  else $error("IME physical result index out of range");
            end
          end
        end else begin
          for (int lane = 0; lane < INT_CELLS; lane++) begin
            if (int_step_tag_out.lane_active[lane]) begin
              assert (int_step_tag_out.result_index[lane] < MAX_CELLS)
                  else $error("IME logical result index out of range");
            end
          end
        end
      end
      if (cmd_accept) begin
        assert (ime_pkg::ime_is_power_of_two(
                    {5'b0, decode_i.lmul}) &&
                ime_pkg::ime_is_power_of_two(
                    {4'b0, decode_i.emul_c}) &&
                ime_pkg::ime_is_power_of_two(
                    {2'b0, decode_i.lambda}) &&
                ime_pkg::ime_is_power_of_two(
                    9'(`VLEN >> decode_i.eew_log2)) &&
                (cmd_i.arch_state.sew <= 3'd2) &&
                ime_pkg::ime_is_power_of_two(
                    9'(`VLEN >> (3 + cmd_i.arch_state.sew))))
            else $error("IME subsystem received non-power-of-two geometry");
`ifndef ZVVFMM_ON
        assert (!decode_i.is_fp)
            else $error("FP/MX command reached an integer-only IME build");
`endif
      end
      if (done_valid_o) begin
        assert (commit_done && (done_rob_tag_o == commit_rob_tag))
            else $error("IME macro completion did not follow final C commit");
      end
      if (int_pe_out_valid) begin
        assert (ordered_fp_active ? ordered_scheduler_busy :
                (ordinary_int_stream ? (int_stream_inflight_q != '0) :
                                       int_step_inflight_q))
            else $error("IME PE returned a result without an in-flight step");
        if (ordinary_int_stream && int_step_tag_out.macro_last) begin
          assert (int_stream_inflight_q == 1)
              else $error("IME final stream packet did not drain the macro");
        end
      end
      if (ordinary_int_opt) begin
        assert (!(init_valid || pack_start || (|acc_write_valid)))
            else $error("IME integer OPT activated REF accumulator/result state");
      end
      if (fetch_busy || int_pe_busy || pack_busy || commit_busy) begin
        assert (busy_o)
            else $error("IME child remained active without macro busy ownership");
      end
      for (int lhs = 0; lhs < EXEC_LANES; lhs++) begin
        for (int rhs = lhs + 1; rhs < EXEC_LANES; rhs++) begin
          assert (!(acc_write_valid[lhs] && acc_write_valid[rhs] &&
                    (acc_write_index[lhs] == acc_write_index[rhs])))
              else $error("IME accumulator write-port collision");
        end
      end
    end
  end
`endif
endmodule
