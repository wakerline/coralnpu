// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Small parameterized IME array derived from the zvt_pe_array -> zvt_pe_block
// hierarchy.  Unlike Zvt, M/N/K are physical implementation parameters and
// the array has no architectural MT storage or fixed 16x16 shape.
module ime_pe_array #(
  parameter int M_PAR = 1,
  parameter int N_PAR = 1,
  parameter int K_PAR = 1,
  parameter int FP_LANES = 1,
  parameter bit INT_STREAM = 1'b0,
  parameter bit INT_PREEXT_OPT = 1'b0,
  parameter bit FP_ORDERED = 1'b0,
  parameter type TAG_TYPE = logic,
  localparam int CELLS = M_PAR * N_PAR
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  input  logic [M_PAR-1:0][K_PAR-1:0][31:0]    a_i,
  input  logic [N_PAR-1:0][K_PAR-1:0][31:0]    b_i,
  input  logic [K_PAR-1:0]                      term_active_i,
  input  logic [CELLS-1:0]                      lane_active_i,
  input  logic [CELLS-1:0][31:0]                accumulator_i,
  input  logic                                  int_first_k_i,
  input  logic                                  is_fp_i,
  input  logic                                  ordered_fp_i,
  input  logic                                  scaled_i,
  input  logic [CELLS-1:0][31:0]                scale_i,
  input  fpnew_pkg::status_t [CELLS-1:0]        scale_status_i,
  input  logic [CELLS-1:0]                      scale_nan_i,
  input  logic [CELLS-1:0][1:0][63:0]           fp_operands_i,
  input  logic [CELLS-1:0][7:0]                 fp_mask_i,
  input  fpnew_pkg::roundmode_e                 rnd_mode_i,
  input  fpnew_pkg::roundmode_e                 final_rnd_mode_i,
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
  output logic [CELLS-1:0][31:0]                result_o,
  output fpnew_pkg::status_t [CELLS-1:0]        status_o,
  output TAG_TYPE                               out_tag_o,
  output logic                                  forced_scale_nan_o,
  output logic                                  out_valid_o,
  input  logic                                  out_ready_i,
  output logic                                  busy_o
);
  ime_pe_block #(
    .M_PAR(M_PAR),
    .N_PAR(N_PAR),
    .K_PAR(K_PAR),
    .FP_LANES(FP_LANES),
    .INT_STREAM(INT_STREAM),
    .INT_PREEXT_OPT(INT_PREEXT_OPT),
    .FP_ORDERED(FP_ORDERED),
    .TAG_TYPE(TAG_TYPE)
  ) u_block (
    .clk(clk),
    .rst_n(rst_n),
    .a_i(a_i),
    .b_i(b_i),
    .term_active_i(term_active_i),
    .lane_active_i(lane_active_i),
    .accumulator_i(accumulator_i),
    .int_first_k_i(int_first_k_i),
    .is_fp_i(is_fp_i),
    .ordered_fp_i(ordered_fp_i),
    .scaled_i(scaled_i),
    .scale_i(scale_i),
    .scale_status_i(scale_status_i),
    .scale_nan_i(scale_nan_i),
    .fp_operands_i(fp_operands_i),
    .fp_mask_i(fp_mask_i),
    .rnd_mode_i(rnd_mode_i),
    .final_rnd_mode_i(final_rnd_mode_i),
    .fp_src_fmt_i(fp_src_fmt_i),
    .fp_dst_fmt_i(fp_dst_fmt_i),
    .signed_a_i(signed_a_i),
    .signed_b_i(signed_b_i),
    .eew_log2_i(eew_log2_i),
    .sew_i(sew_i),
    .in_tag_i(in_tag_i),
    .in_valid_i(in_valid_i),
    .in_ready_o(in_ready_o),
    .flush_i(flush_i),
    .result_o(result_o),
    .status_o(status_o),
    .out_tag_o(out_tag_o),
    .forced_scale_nan_o(forced_scale_nan_o),
    .out_valid_o(out_valid_o),
    .out_ready_i(out_ready_i),
    .busy_o(busy_o)
  );
endmodule
