// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

// IME-private FP add front end, structurally copied from Zvt fp_addfront.
// The only architectural difference is the corrected magnitude ordering and
// exact post-add normalization required by the IME accumulator path.
module ime_fp_addfront #(
  parameter int unsigned IN_EXP_BITS = 32'd8,
  parameter int unsigned IN_MANT_BITS = 32'd23,
  parameter int unsigned OUT_EXP_BITS = 32'd9,
  parameter int unsigned OUT_SIG_BITS = 32'd24,
  localparam int unsigned IN_SIG_BITS = IN_MANT_BITS + 1
) (
  input  logic                       a_sign,
  input  logic [IN_EXP_BITS-1:0]     a_exponent,
  input  logic [IN_MANT_BITS-1:0]    a_mantissa,
  input  logic                       b_sign,
  input  logic [IN_EXP_BITS-1:0]     b_exponent,
  input  logic [IN_MANT_BITS-1:0]    b_mantissa,
  input  logic                       do_subtract,
  output logic                       result_sign,
  output logic [OUT_EXP_BITS-1:0]    result_exponent,
  output logic [OUT_SIG_BITS-1:0]    result_significand,
  output logic                       result_round_bit,
  output logic                       result_sticky_bit,
  output logic                       result_sticky_msb,
  output logic                       special_nan,
  output logic                       special_inf,
  output logic                       special_inf_sign,
  output logic                       special_invalid,
  output logic                       align_overflow
);
  logic b_is_nan, a_is_nan;
  logic b_is_signal_nan, a_is_signal_nan;
  logic b_is_inf, a_is_inf;
  logic b_implicit_bit, a_implicit_bit;

  fp_classifier #(
    .NUM_OP(2),
    .EXP_BITS(IN_EXP_BITS),
    .MAN_BITS(IN_MANT_BITS)
  ) u_classifier (
    .exponent({b_exponent, a_exponent}),
    .mantissa({b_mantissa, a_mantissa}),
    .is_nan({b_is_nan, a_is_nan}),
    .is_signal_nan({b_is_signal_nan, a_is_signal_nan}),
    .is_inf({b_is_inf, a_is_inf}),
    .is_subnormal(),
    .is_zero(),
    .implicit_bit({b_implicit_bit, a_implicit_bit})
  );

  always_comb begin
    special_nan = 1'b0;
    special_invalid = 1'b0;
    special_inf = 1'b0;
    special_inf_sign = 1'b0;
    if (a_is_inf && b_is_inf && (a_sign ^ b_sign ^ do_subtract)) begin
      special_nan = 1'b1;
      special_invalid = 1'b1;
    end else if (a_is_nan || b_is_nan) begin
      special_nan = 1'b1;
      special_invalid = a_is_signal_nan || b_is_signal_nan;
    end else if (a_is_inf || b_is_inf) begin
      special_inf = 1'b1;
      special_inf_sign = a_is_inf ? a_sign : (b_sign ^ do_subtract);
    end
  end

  wire [IN_EXP_BITS-1:0] max_exponent =
      a_exponent > b_exponent ? a_exponent : b_exponent;
  wire [IN_EXP_BITS-1:0] subnormal_fix_align_exp =
      max_exponent > 1 ? max_exponent : IN_EXP_BITS'(1);
  wire signed [1:0][IN_EXP_BITS:0] in_exponents;
  assign in_exponents[0] =
      {1'b0, a_exponent[IN_EXP_BITS-1:1],
       a_exponent[0] | !a_implicit_bit};
  assign in_exponents[1] =
      {1'b0, b_exponent[IN_EXP_BITS-1:1],
       b_exponent[0] | !b_implicit_bit};

  wire [1:0][IN_SIG_BITS-1:0] in_significands;
  assign in_significands[0] = {a_implicit_bit, a_mantissa};
  assign in_significands[1] = {b_implicit_bit, b_mantissa};

  wire [1:0][IN_EXP_BITS-1:0] aligned_exponents;
  wire [1:0][OUT_SIG_BITS+1:0] aligned_significands;
  wire [1:0] aligned_round_bits;
  wire [1:0] aligned_sticky_bits;
  wire [1:0] input_align_overflow;

  for (genvar operand = 0; operand < 2; operand++) begin : gen_input_align
    fp_align #(
      .IN_EXP_BITS(IN_EXP_BITS + 1),
      .IN_SIG_BITS(IN_SIG_BITS),
      .OUT_EXP_BITS(IN_EXP_BITS),
      .OUT_SIG_BITS(OUT_SIG_BITS + 2),
      .USE_EXT_LZC(1'b0),
      .USE_LZA_POSTFIX(1'b0)
    ) u_align (
      .in_exponent(in_exponents[operand]),
      .in_significand(in_significands[operand]),
      .ext_lzc_cnt('0),
      .ext_in_zero(1'b0),
      .align_minimum_exponent(subnormal_fix_align_exp),
      .align_trimmed_exponent(max_exponent),
      .out_exponent(aligned_exponents[operand]),
      .out_significand(aligned_significands[operand]),
      .out_round_bit(aligned_round_bits[operand]),
      .out_sticky_bit(aligned_sticky_bits[operand]),
      .out_sticky_msb(),
      .overflow(input_align_overflow[operand])
    );
  end

  localparam int unsigned SUM_INPUT_WIDTH = OUT_SIG_BITS + 4;
  localparam int unsigned SUM_TOTAL_WIDTH = SUM_INPUT_WIDTH + 1;
  wire [OUT_SIG_BITS+2:0] sum_significand;
  wire sum_round_bit;
  wire sum_sticky_bit;
  wire sum_negative;

  ime_fp_absaddsub #(
    .IN_WIDTH(SUM_INPUT_WIDTH)
  ) u_addsub (
    .a({aligned_significands[0],
        aligned_round_bits[0], aligned_sticky_bits[0]}),
    .b({aligned_significands[1],
        aligned_round_bits[1], aligned_sticky_bits[1]}),
    .do_subtract(a_sign ^ b_sign ^ do_subtract),
    .sum({sum_significand, sum_round_bit, sum_sticky_bit}),
    .sum_negative(sum_negative)
  );

  wire [SUM_TOTAL_WIDTH-1:0] sum_value =
      {sum_significand, sum_round_bit, sum_sticky_bit};
  wire [$clog2(SUM_TOTAL_WIDTH)-1:0] sum_lzc_cnt;
  wire sum_is_zero;
  lzc #(.WIDTH(SUM_TOTAL_WIDTH), .MODE(1)) u_sum_lzc (
    .in_i   (sum_value),
    .cnt_o  (sum_lzc_cnt),
    .empty_o(sum_is_zero));
  logic [OUT_EXP_BITS-1:0] aligned_result_exponent;
  logic [OUT_SIG_BITS-1:0] aligned_result_significand;
  logic aligned_result_round_bit;
  logic aligned_result_sticky_bit;
  logic aligned_result_sticky_msb;
  logic aligned_result_overflow;
  fp_align #(
    .IN_EXP_BITS(IN_EXP_BITS + 2),
    .IN_SIG_BITS(SUM_TOTAL_WIDTH),
    .OUT_EXP_BITS(OUT_EXP_BITS),
    .OUT_SIG_BITS(OUT_SIG_BITS),
    .USE_EXT_LZC(1'b1),
    .USE_LZA_POSTFIX(1'b0)
  ) u_sum_align (
    // Use the same reference exponent as the input alignment.  For an
    // all-subnormal pair this is one (not max_exponent==zero), preserving the
    // carry from minsub + minsub at the post-add normalization boundary.
    .in_exponent(signed'({2'b0, subnormal_fix_align_exp}) + 1'b1),
    .in_significand(sum_value),
    .ext_lzc_cnt(sum_lzc_cnt),
    .ext_in_zero(sum_is_zero),
    .align_minimum_exponent(OUT_EXP_BITS'(1)),
    .align_trimmed_exponent('0),
    .out_exponent(aligned_result_exponent),
    .out_significand(aligned_result_significand),
    .out_round_bit(aligned_result_round_bit),
    .out_sticky_bit(aligned_result_sticky_bit),
    .out_sticky_msb(aligned_result_sticky_msb),
    .overflow(aligned_result_overflow)
  );

  // fp_align treats a zero significand's exponent as don't-care.  At this
  // architectural boundary zero must instead be encoded canonically before
  // the IEEE sign rule is applied by ime_pe_adder_fp_lane.
  assign result_exponent   = sum_is_zero ? '0 : aligned_result_exponent;
  assign result_significand = sum_is_zero ? '0 : aligned_result_significand;
  assign result_round_bit  = sum_is_zero ? 1'b0 : aligned_result_round_bit;
  assign result_sticky_bit = sum_is_zero ? 1'b0 : aligned_result_sticky_bit;
  assign result_sticky_msb = sum_is_zero ? 1'b0 : aligned_result_sticky_msb;
  assign align_overflow    = sum_is_zero ? 1'b0 : aligned_result_overflow;

  assign result_sign = a_sign ^ sum_negative;

`ifndef SYNTHESIS
  always_comb begin
    assert (!(|input_align_overflow));
    // NaN/Inf payloads bypass the finite sum below; their aligned exponent is
    // deliberately don't-care and must not trip a finite-datapath invariant.
    if (!(a_is_nan || b_is_nan || a_is_inf || b_is_inf) &&
        (max_exponent != '0)) begin
      assert (aligned_exponents[0] == max_exponent);
      assert (aligned_exponents[1] == max_exponent);
    end
  end
`endif
endmodule
