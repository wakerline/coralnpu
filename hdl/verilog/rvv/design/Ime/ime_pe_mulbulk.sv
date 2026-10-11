// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// IME multiply/bulk-normalization stage, copied from the organization of
// zvt_pe_mulbulk.  Integer and floating-point work share one handshake, tag
// and output pipeline; IME geometry only changes the lane payload.
module ime_pe_mulbulk #(
  parameter int M_PAR = 1,
  parameter int N_PAR = 1,
  parameter int K_PAR = 1,
  parameter int FP_LANES = 1,
  parameter bit INT_PREEXT_OPT = 1'b0,
  parameter bit FP_EXACT_REDUCTION = !`IME_FP_PSM,
  parameter int NUM_PIPE_REGS = 3,
  parameter type TAG_TYPE = logic,
  localparam int CELLS = M_PAR * N_PAR
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  input  logic [M_PAR-1:0][K_PAR-1:0][31:0]    a_i,
  input  logic [N_PAR-1:0][K_PAR-1:0][31:0]    b_i,
  input  logic [K_PAR-1:0]                      term_active_i,
  input  logic [CELLS-1:0]                      lane_active_i,
  input  logic                                  is_fp_i,
  input  logic [CELLS-1:0][1:0][63:0]           fp_operands_i,
  input  logic [CELLS-1:0][7:0]                 fp_mask_i,
  input  fpnew_pkg::roundmode_e                 rnd_mode_i,
  input  fpnew_pkg::fp_format_e                 fp_src_fmt_i,
  input  fpnew_pkg::fp_format_e                 fp_dst_fmt_i,
  input  logic                                  signed_a_i,
  input  logic                                  signed_b_i,
  input  logic [2:0]                            eew_log2_i,
  input  logic [2:0]                            sew_i,
  input  TAG_TYPE                               in_tag_i,
  input  logic                                  in_valid_i,
  output logic                                  in_ready_o,
  input  logic                                  flush_i,
  output logic [CELLS-1:0][31:0]                partial_o,
  output fpnew_pkg::status_t [CELLS-1:0]        status_o,
  output TAG_TYPE                               out_tag_o,
  output logic                                  out_valid_o,
  input  logic                                  out_ready_i,
  output logic                                  busy_o
);
  localparam int NUM_INP_REGS = 1;
  localparam int NUM_MID_REGS = 1;
  localparam int NUM_OUT_REGS = 1;

  logic [NUM_PIPE_REGS-1:0] reg_enable;
  handshake_multistage_ctrl #(
    .NUM_PIPE_REGS(NUM_PIPE_REGS),
    .REMV_PIPE_BUBBLE(1)
  ) u_handshake (
    .clk(clk),
    .rst_n(rst_n),
    .flush(flush_i),
    .up_valid(in_valid_i),
    .up_ready(in_ready_o),
    .down_valid(out_valid_o),
    .down_ready(out_ready_i),
    .reg_enable(reg_enable),
    .valids(),
    .busy(busy_o)
  );

  TAG_TYPE [0:NUM_PIPE_REGS] tag_pipe;
  assign tag_pipe[0] = in_tag_i;
  assign out_tag_o = tag_pipe[NUM_PIPE_REGS];
  for (genvar stage = 0; stage < NUM_PIPE_REGS; stage++) begin : gen_tag_pipe
    edff #(.T(TAG_TYPE)) u_tag_reg (
      .q(tag_pipe[stage+1]),
      .d(tag_pipe[stage]),
      .e(reg_enable[stage]),
      .clk(clk),
      .rst_n(rst_n)
    );
  end

  typedef struct packed {
    logic [M_PAR-1:0][K_PAR-1:0][31:0] a;
    logic [N_PAR-1:0][K_PAR-1:0][31:0] b;
    logic [K_PAR-1:0]                   term_active;
    logic [CELLS-1:0]                   lane_active;
    logic                               is_fp;
    logic [CELLS-1:0][1:0][63:0]        fp_operands;
    logic [CELLS-1:0][7:0]              fp_mask;
    fpnew_pkg::roundmode_e              rnd_mode;
    fpnew_pkg::fp_format_e              fp_src_fmt;
    fpnew_pkg::fp_format_e              fp_dst_fmt;
    logic                               signed_a;
    logic                               signed_b;
    logic [2:0]                         eew_log2;
    logic [2:0]                         sew;
  } input_reg_t;
  input_reg_t [0:NUM_INP_REGS] input_pipe;
  always_comb begin
    input_pipe[0].a = a_i;
    input_pipe[0].b = b_i;
    input_pipe[0].term_active = term_active_i;
    input_pipe[0].lane_active = lane_active_i;
    input_pipe[0].is_fp = is_fp_i;
    input_pipe[0].fp_operands = fp_operands_i;
    input_pipe[0].fp_mask = fp_mask_i;
    input_pipe[0].rnd_mode = rnd_mode_i;
    input_pipe[0].fp_src_fmt = fp_src_fmt_i;
    input_pipe[0].fp_dst_fmt = fp_dst_fmt_i;
    input_pipe[0].signed_a = signed_a_i;
    input_pipe[0].signed_b = signed_b_i;
    input_pipe[0].eew_log2 = eew_log2_i;
    input_pipe[0].sew = sew_i;
  end
  edff #(.T(input_reg_t)) u_input_reg (
    .q(input_pipe[1]),
    .d(input_pipe[0]),
    .e(reg_enable[0]),
    .clk(clk),
    .rst_n(rst_n)
  );

  // A is shared by every physical column and B by every physical row.  The
  // baseline performs the same runtime EEW/sign extension inside every
  // output lane.  The optional Stage-42 path computes each distinct operand
  // once at the existing input-register boundary and fans out only the
  // resulting 33-bit two's-complement value.  No pipeline stage or arithmetic
  // ordering changes.
  function automatic logic [32:0] extend_integer_operand(
      input logic [31:0] operand,
      input logic        operand_signed,
      input logic [2:0]  eew_log2
  );
    logic [32:0] extended;
    begin
      extended = '0;
      unique case (eew_log2)
        3'd2: extended = operand_signed ?
            {{29{operand[3]}}, operand[3:0]} : {29'b0, operand[3:0]};
        3'd3: extended = operand_signed ?
            {{25{operand[7]}}, operand[7:0]} : {25'b0, operand[7:0]};
        3'd4: extended = operand_signed ?
            {{17{operand[15]}}, operand[15:0]} : {17'b0, operand[15:0]};
        3'd5: extended = operand_signed ?
            {operand[31], operand} : {1'b0, operand};
        default: ;
      endcase
      return extended;
    end
  endfunction

  logic [M_PAR-1:0][K_PAR-1:0][32:0] int_a_extended;
  logic [N_PAR-1:0][K_PAR-1:0][32:0] int_b_extended;
  if (INT_PREEXT_OPT) begin : gen_shared_integer_extension
    always_comb begin
      for (int m = 0; m < M_PAR; m++) begin
        for (int k = 0; k < K_PAR; k++) begin
          int_a_extended[m][k] = extend_integer_operand(
              input_pipe[1].a[m][k], input_pipe[1].signed_a,
              input_pipe[1].eew_log2);
        end
      end
      for (int n = 0; n < N_PAR; n++) begin
        for (int k = 0; k < K_PAR; k++) begin
          int_b_extended[n][k] = extend_integer_operand(
              input_pipe[1].b[n][k], input_pipe[1].signed_b,
              input_pipe[1].eew_log2);
        end
      end
    end
  end else begin : gen_no_shared_integer_extension
    assign int_a_extended = '0;
    assign int_b_extended = '0;
  end

  logic [CELLS-1:0][31:0] fp_result;
  logic [CELLS-1:0][31:0] int_result;
  fpnew_pkg::status_t [CELLS-1:0] fp_status;
  fpnew_pkg::status_t [CELLS-1:0] int_status;
  logic [CELLS-1:0] fp_valid;
  wire [NUM_MID_REGS-1:0] mid_reg_enable =
      reg_enable[NUM_INP_REGS +: NUM_MID_REGS];

  for (genvar m = 0; m < M_PAR; m++) begin : gen_m
    for (genvar n = 0; n < N_PAR; n++) begin : gen_n
      localparam int LANE = m * N_PAR + n;
`ifdef ZVVFMM_ON
      if (LANE < FP_LANES) begin : gen_fp_lane
        ime_pe_mulbulk_fp_lane #(
          // FP32, FP16, FP8(E5M2), and BF16. FP64 is intentionally disabled
          // because the current CoralNPU option exposes Zve32f.
          .FP_FMT_CONFIG(5'b10111),
          .NUM_MID_REGS(NUM_MID_REGS),
          .OPERAND_WIDTH(64),
          .EXACT_REDUCTION(FP_EXACT_REDUCTION)
        ) u_fp_lane (
          .clk(clk),
          .rst_n(rst_n),
          .reg_enable(mid_reg_enable),
          .up_valid(input_pipe[1].is_fp &&
                    input_pipe[1].lane_active[LANE]),
          .operands(input_pipe[1].fp_operands[LANE]),
          .rnd_mode(input_pipe[1].rnd_mode),
          .mask(input_pipe[1].fp_mask[LANE]),
          .src_fmt(input_pipe[1].fp_src_fmt),
          .dst_fmt(input_pipe[1].fp_dst_fmt),
          .result(fp_result[LANE]),
          .status(fp_status[LANE]),
          .down_valid(fp_valid[LANE])
        );
      end else begin : gen_no_fp_lane
        assign fp_result[LANE] = '0;
        assign fp_status[LANE] = '0;
        assign fp_valid[LANE] = 1'b0;
      end
`else
      assign fp_result[LANE] = '0;
      assign fp_status[LANE] = '0;
      assign fp_valid[LANE] = 1'b0;
`endif

      ime_pe_mulbulk_int_lane #(
        .K_PAR(K_PAR),
        .NUM_MID_REGS(NUM_MID_REGS),
        .PREEXT_OPT(INT_PREEXT_OPT)
      ) u_int_lane (
        .clk(clk),
        .rst_n(rst_n),
        .reg_enable(mid_reg_enable),
        .up_valid(!input_pipe[1].is_fp && input_pipe[1].lane_active[LANE]),
        .a_i(input_pipe[1].a[m]),
        .b_i(input_pipe[1].b[n]),
        .a_extended_i(int_a_extended[m]),
        .b_extended_i(int_b_extended[n]),
        .term_active_i(input_pipe[1].term_active),
        .signed_a_i(input_pipe[1].signed_a),
        .signed_b_i(input_pipe[1].signed_b),
        .eew_log2_i(input_pipe[1].eew_log2),
        .sew_i(input_pipe[1].sew),
        .result(int_result[LANE]),
        .status(int_status[LANE])
      );
    end
  end

  typedef struct packed {
    logic [CELLS-1:0][31:0] result;
    fpnew_pkg::status_t [CELLS-1:0] status;
  } output_reg_t;
  output_reg_t output_in;
  output_reg_t output_q;
  always_comb begin
    for (int lane = 0; lane < CELLS; lane++) begin
      output_in.result[lane] = fp_valid[lane] ? fp_result[lane] :
                                                      int_result[lane];
      output_in.status[lane] = fp_valid[lane] ? fp_status[lane] :
                                                      int_status[lane];
    end
  end
  edff #(.T(output_reg_t)) u_output_reg (
    .q(output_q),
    .d(output_in),
    .e(reg_enable[NUM_INP_REGS+NUM_MID_REGS]),
    .clk(clk),
    .rst_n(rst_n)
  );

  assign partial_o = output_q.result;
  assign status_o = output_q.status;

`ifndef SYNTHESIS
  initial begin
    assert (NUM_PIPE_REGS == NUM_INP_REGS + NUM_MID_REGS + NUM_OUT_REGS);
    assert (M_PAR inside {1, 2, 4});
    assert (N_PAR inside {1, 2, 4});
    assert (K_PAR inside {1, 2, 4});
    assert (FP_LANES >= 1 && FP_LANES <= CELLS);
  end
`endif
endmodule
