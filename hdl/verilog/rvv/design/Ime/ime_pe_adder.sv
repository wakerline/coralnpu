// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// IME accumulator stage derived from zvt_pe_adder.  Integer and FP C updates
// use the same handshake/tag pipeline and differ only in their arithmetic lane.
module ime_pe_adder #(
  parameter int CELLS = 1,
  parameter int FP_LANES = 1,
  parameter int NUM_PIPE_REGS = 3,
  parameter type TAG_TYPE = logic
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic [CELLS-1:0][31:0]       accumulator_i,
  input  logic [CELLS-1:0][31:0]       partial_i,
  input  fpnew_pkg::status_t [CELLS-1:0] partial_status_i,
  input  logic [CELLS-1:0]             lane_active_i,
  input  logic                         is_fp_i,
  input  fpnew_pkg::roundmode_e        rnd_mode_i,
  input  logic [2:0]                   sew_i,
  input  TAG_TYPE                      in_tag_i,
  input  logic                         in_valid_i,
  output logic                         in_ready_o,
  input  logic                         flush_i,
  output logic [CELLS-1:0][31:0]       result_o,
  output fpnew_pkg::status_t [CELLS-1:0] status_o,
  output TAG_TYPE                      out_tag_o,
  output logic                         out_valid_o,
  input  logic                         out_ready_i,
  output logic                         busy_o
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
    logic [CELLS-1:0][31:0] accumulator;
    logic [CELLS-1:0][31:0] partial;
    fpnew_pkg::status_t [CELLS-1:0] partial_status;
    logic [CELLS-1:0]              lane_active;
    logic                         is_fp;
    fpnew_pkg::roundmode_e        rnd_mode;
    logic [2:0]                   sew;
  } input_reg_t;
  input_reg_t input_d;
  input_reg_t input_q;
  always_comb begin
    input_d.accumulator = accumulator_i;
    input_d.partial = partial_i;
    input_d.partial_status = partial_status_i;
    input_d.lane_active = lane_active_i;
    input_d.is_fp = is_fp_i;
    input_d.rnd_mode = rnd_mode_i;
    input_d.sew = sew_i;
  end
  edff #(.T(input_reg_t)) u_input_reg (
    .q(input_q),
    .d(input_d),
    .e(reg_enable[0]),
    .clk(clk),
    .rst_n(rst_n)
  );

  wire [NUM_MID_REGS-1:0] mid_reg_enable =
      reg_enable[NUM_INP_REGS +: NUM_MID_REGS];
  logic [CELLS-1:0][31:0] fp_result;
  logic [CELLS-1:0][31:0] int_result;
  fpnew_pkg::status_t [CELLS-1:0] fp_status;
  fpnew_pkg::status_t [CELLS-1:0] int_status;
  logic [CELLS-1:0] fp_valid;

  // The arithmetic lanes contain one mid register.  Carry the incoming
  // product flags through an identical register so status collection never
  // observes the following transaction's input_q.
  typedef struct packed {
    fpnew_pkg::status_t [CELLS-1:0] partial_status;
  } mid_meta_t;
  mid_meta_t mid_meta_q;
  mid_meta_t mid_meta_d;
  assign mid_meta_d.partial_status = input_q.partial_status;
  edff #(.T(mid_meta_t)) u_mid_meta_reg (
    .q(mid_meta_q),
    .d(mid_meta_d),
    .e(mid_reg_enable[0]),
    .clk(clk),
    .rst_n(rst_n)
  );

  for (genvar lane = 0; lane < CELLS; lane++) begin : gen_lane
`ifdef ZVVFMM_ON
    if (lane < FP_LANES) begin : gen_fp_lane
      ime_pe_adder_fp_lane #(
        .NUM_MID_REGS(NUM_MID_REGS)
      ) u_fp_lane (
        .clk(clk),
        .rst_n(rst_n),
        .reg_enable(mid_reg_enable),
        .up_valid(input_q.is_fp && input_q.lane_active[lane]),
        .operands({input_q.partial[lane], input_q.accumulator[lane]}),
        .do_subtract(1'b0),
        .rnd_mode(input_q.rnd_mode),
        .result(fp_result[lane]),
        .status(fp_status[lane]),
        .down_valid(fp_valid[lane])
      );
    end else begin : gen_no_fp_lane
      assign fp_result[lane] = '0;
      assign fp_status[lane] = '0;
      assign fp_valid[lane] = 1'b0;
    end
`else
    assign fp_result[lane] = '0;
    assign fp_status[lane] = '0;
    assign fp_valid[lane] = 1'b0;
`endif

    ime_pe_adder_int_lane #(
      .NUM_MID_REGS(NUM_MID_REGS)
    ) u_int_lane (
      .clk(clk),
      .rst_n(rst_n),
      .reg_enable(mid_reg_enable),
      // Every integer cell returns a defined value.  An inactive physical
      // lane performs accumulator + 0, preserving its seed exactly; the
      // architectural write mask still suppresses that lane downstream.
      // This avoids stale pipeline data at the PE-array boundary without
      // adding another accumulator metadata pipeline.
      .up_valid(!input_q.is_fp),
      .accumulator_i(input_q.accumulator[lane]),
      .partial_i(input_q.lane_active[lane] ? input_q.partial[lane] : '0),
      .sew_i(input_q.sew),
      .result(int_result[lane]),
      .status(int_status[lane])
    );
  end

  typedef struct packed {
    logic [CELLS-1:0][31:0] result;
    fpnew_pkg::status_t [CELLS-1:0] status;
  } output_reg_t;
  output_reg_t output_d;
  output_reg_t output_q;
  always_comb begin
    for (int lane = 0; lane < CELLS; lane++) begin
      output_d.result[lane] = fp_valid[lane] ? fp_result[lane] :
                                                    int_result[lane];
      output_d.status[lane] = mid_meta_q.partial_status[lane];
      if (fp_valid[lane]) begin
        output_d.status[lane].NV |= fp_status[lane].NV;
        output_d.status[lane].DZ |= fp_status[lane].DZ;
        output_d.status[lane].OF |= fp_status[lane].OF;
        output_d.status[lane].UF |= fp_status[lane].UF;
        output_d.status[lane].NX |= fp_status[lane].NX;
      end else begin
        output_d.status[lane] = int_status[lane];
      end
    end
  end
  edff #(.T(output_reg_t)) u_output_reg (
    .q(output_q),
    .d(output_d),
    .e(reg_enable[NUM_INP_REGS+NUM_MID_REGS]),
    .clk(clk),
    .rst_n(rst_n)
  );

  assign result_o = output_q.result;
  assign status_o = output_q.status;

`ifndef SYNTHESIS
  initial assert (NUM_PIPE_REGS ==
                  NUM_INP_REGS + NUM_MID_REGS + NUM_OUT_REGS);
  initial assert (FP_LANES >= 1 && FP_LANES <= CELLS);
`endif
endmodule
