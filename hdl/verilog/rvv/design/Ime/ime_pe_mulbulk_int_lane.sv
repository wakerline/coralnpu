// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// IME integer mulbulk lane.  The valid/data pipeline and clock-enable rules
// are copied from zvt_pe_mulbulk_int_lane; only the arithmetic payload is
// replaced by IME runtime EEW, signedness, K_PAR and modulo-SEW semantics.
module ime_pe_mulbulk_int_lane #(
  parameter int K_PAR = 1,
  parameter int NUM_MID_REGS = 1,
  parameter bit PREEXT_OPT = 1'b0
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic [NUM_MID_REGS-1:0]      reg_enable,
  input  logic                         up_valid,
  input  logic [K_PAR-1:0][31:0]       a_i,
  input  logic [K_PAR-1:0][31:0]       b_i,
  input  logic [K_PAR-1:0][32:0]       a_extended_i,
  input  logic [K_PAR-1:0][32:0]       b_extended_i,
  input  logic [K_PAR-1:0]             term_active_i,
  input  logic                         signed_a_i,
  input  logic                         signed_b_i,
  input  logic [2:0]                   eew_log2_i,
  input  logic [2:0]                   sew_i,
  output logic [31:0]                  result,
  output fpnew_pkg::status_t           status
);
  logic [31:0] partial;
  if (PREEXT_OPT) begin : gen_preextended_reduction
    always_comb begin : ordered_k_reduction
      logic signed [32:0] a_ext;
      logic signed [32:0] b_ext;
      logic [31:0] product_low;
      logic [31:0] sum;

      partial = '0;
      for (int k = 0; k < K_PAR; k++) begin
        a_ext = a_extended_i[k];
        b_ext = b_extended_i[k];
        product_low = 32'(a_ext * b_ext);
        sum = partial + product_low;
        if (term_active_i[k]) begin
          unique case (sew_i)
            3'd0: partial = {24'b0, sum[7:0]};
            3'd1: partial = {16'b0, sum[15:0]};
            3'd2: partial = sum;
            default: partial = '0;
          endcase
        end
      end
    end
  end else begin : gen_local_extension_reduction
    // Preserve the original per-lane implementation verbatim as the
    // independently selectable reference boundary.
    always_comb begin : ordered_k_reduction
      logic signed [32:0] a_ext;
      logic signed [32:0] b_ext;
      logic [31:0] product_low;
      logic [31:0] sum;

      partial = '0;
      for (int k = 0; k < K_PAR; k++) begin
        a_ext = '0;
        b_ext = '0;
        unique case (eew_log2_i)
          3'd2: begin
            a_ext = signed_a_i ? {{29{a_i[k][3]}}, a_i[k][3:0]}
                                 : {29'b0, a_i[k][3:0]};
            b_ext = signed_b_i ? {{29{b_i[k][3]}}, b_i[k][3:0]}
                                 : {29'b0, b_i[k][3:0]};
          end
          3'd3: begin
            a_ext = signed_a_i ? {{25{a_i[k][7]}}, a_i[k][7:0]}
                                 : {25'b0, a_i[k][7:0]};
            b_ext = signed_b_i ? {{25{b_i[k][7]}}, b_i[k][7:0]}
                                 : {25'b0, b_i[k][7:0]};
          end
          3'd4: begin
            a_ext = signed_a_i ? {{17{a_i[k][15]}}, a_i[k][15:0]}
                                 : {17'b0, a_i[k][15:0]};
            b_ext = signed_b_i ? {{17{b_i[k][15]}}, b_i[k][15:0]}
                                 : {17'b0, b_i[k][15:0]};
          end
          3'd5: begin
            a_ext = signed_a_i ? {a_i[k][31], a_i[k]} : {1'b0, a_i[k]};
            b_ext = signed_b_i ? {b_i[k][31], b_i[k]} : {1'b0, b_i[k]};
          end
          default: ;
        endcase
        product_low = 32'(a_ext * b_ext);
        sum = partial + product_low;
        if (term_active_i[k]) begin
          unique case (sew_i)
            3'd0: partial = {24'b0, sum[7:0]};
            3'd1: partial = {16'b0, sum[15:0]};
            3'd2: partial = sum;
            default: partial = '0;
          endcase
        end
      end
    end
  end

  typedef struct packed {
    logic        en;
    logic [31:0] result;
  } mid_reg_t;
  mid_reg_t [0:NUM_MID_REGS] mid_pipe;

  assign mid_pipe[0].en = up_valid;
  assign mid_pipe[0].result = partial;
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
