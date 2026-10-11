// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// IME counterpart of zvt_pe_adder_int_lane.  It retains the Zvt enabled
// mid-pipeline shell and replaces the fixed int32 add with modulo-SEW C update.
module ime_pe_adder_int_lane #(
  parameter int NUM_MID_REGS = 1
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic [NUM_MID_REGS-1:0]      reg_enable,
  input  logic                         up_valid,
  input  logic [31:0]                  accumulator_i,
  input  logic [31:0]                  partial_i,
  input  logic [2:0]                   sew_i,
  output logic [31:0]                  result,
  output fpnew_pkg::status_t           status
);
  logic [31:0] sum;
  always_comb begin
    unique case (sew_i)
      3'd0: sum = {24'b0, accumulator_i[7:0] + partial_i[7:0]};
      3'd1: sum = {16'b0, accumulator_i[15:0] + partial_i[15:0]};
      3'd2: sum = accumulator_i + partial_i;
      default: sum = '0;
    endcase
  end

  typedef struct packed {
    logic        en;
    logic [31:0] result;
  } mid_reg_t;
  mid_reg_t [0:NUM_MID_REGS] mid_pipe;
  assign mid_pipe[0].en = up_valid;
  assign mid_pipe[0].result = sum;

  for (genvar stage = 0; stage < NUM_MID_REGS; stage++) begin : gen_mid_pipeline
    edff #(.T(mid_reg_t)) u_mid_reg (
      .q(mid_pipe[stage+1]),
      .d(mid_pipe[stage]),
      .e(reg_enable[stage] && mid_pipe[stage].en),
      .clk(clk),
      .rst_n(rst_n)
    );
  end

  assign result = mid_pipe[NUM_MID_REGS].result;
  assign status = '0;
endmodule
