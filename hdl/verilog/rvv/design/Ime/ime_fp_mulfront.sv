// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// IME-private copy of the Zvt multiply front end.  Unlike the Zvt source
// formats, IME FP16/FP8 products are rebased into the FP32 accumulator
// exponent domain.  The exported raw exponent must therefore be sized from
// OUT_EXP_BITS rather than IN_EXP_BITS, otherwise narrow source formats wrap
// before the batch-normalization maximum is selected.
module ime_fp_mulfront #(
  parameter int unsigned IN_EXP_BITS  = 32'd8,
  parameter int unsigned IN_MANT_BITS = 32'd23,
  parameter int unsigned OUT_EXP_BITS = 32'd9,
  parameter int unsigned OUT_SIG_BITS = 32'd24,
  parameter int signed   BIAS = 32'(2**(IN_EXP_BITS-1)-1),

  localparam int unsigned IN_SIG_BITS  = IN_MANT_BITS + 1,
  localparam int unsigned RAW_EXP_BITS = OUT_EXP_BITS + 1
) (
  input  logic                           a_sign,
  input  logic [IN_EXP_BITS-1:0]         a_exponent,
  input  logic [IN_MANT_BITS-1:0]        a_mantissa,
  input  logic                           b_sign,
  input  logic [IN_EXP_BITS-1:0]         b_exponent,
  input  logic [IN_MANT_BITS-1:0]        b_mantissa,

  output logic signed [RAW_EXP_BITS-1:0] prod_exponent_raw,
  input  logic [OUT_EXP_BITS-1:0]        align_minimum_exponent,
  input  logic [OUT_EXP_BITS-1:0]        align_trimmed_exponent,

  output logic                           prod_sign,
  output logic [OUT_EXP_BITS-1:0]        prod_exponent,
  output logic [OUT_SIG_BITS-1:0]        prod_significand,
  output logic                           prod_round_bit,
  output logic                           prod_sticky_bit,
  output logic                           prod_sticky_msb,

  output logic                           special_nan,
  output logic                           special_inf,
  output logic                           special_invalid,
  output logic                           align_overflow
);
  localparam logic signed [RAW_EXP_BITS-1:0] BIAS_VALUE =
      RAW_EXP_BITS'(BIAS);
  localparam logic signed [RAW_EXP_BITS-1:0] ONE_VALUE =
      RAW_EXP_BITS'(1);

  initial begin
    assert (OUT_EXP_BITS >= IN_EXP_BITS + 1);
  end

  assign prod_sign = a_sign ^ b_sign;

  logic b_is_nan, a_is_nan;
  logic b_is_signal_nan, a_is_signal_nan;
  logic b_is_inf, a_is_inf;
  logic b_is_subnormal, a_is_subnormal;
  logic b_is_zero, a_is_zero;
  logic b_implicit_bit, a_implicit_bit;
  fp_classifier #(
    .NUM_OP  (32'd2),
    .EXP_BITS(IN_EXP_BITS),
    .MAN_BITS(IN_MANT_BITS)
  ) u_classifier (
    .exponent     ({b_exponent,       a_exponent      }),
    .mantissa     ({b_mantissa,       a_mantissa      }),
    .is_nan       ({b_is_nan,         a_is_nan        }),
    .is_signal_nan({b_is_signal_nan,  a_is_signal_nan }),
    .is_inf       ({b_is_inf,         a_is_inf        }),
    .is_subnormal ({b_is_subnormal,   a_is_subnormal  }),
    .is_zero      ({b_is_zero,        a_is_zero       }),
    .implicit_bit ({b_implicit_bit,   a_implicit_bit  })
  );

  always_comb begin
    special_inf = 1'b0;
    special_nan = 1'b0;
    special_invalid = 1'b0;
    if ((a_is_inf && b_is_zero) || (b_is_inf && a_is_zero)) begin
      special_nan = 1'b1;
      special_invalid = 1'b1;
    end else if (a_is_nan || b_is_nan) begin
      special_nan = 1'b1;
      special_invalid = a_is_signal_nan | b_is_signal_nan;
    end else if (a_is_inf || b_is_inf) begin
      special_inf = 1'b1;
    end
  end

  wire [IN_SIG_BITS-1:0] a_significand = {a_implicit_bit, a_mantissa};
  wire [IN_SIG_BITS-1:0] b_significand = {b_implicit_bit, b_mantissa};

  logic [$clog2(IN_SIG_BITS)-1:0] lzc_a_cnt, lzc_b_cnt;
  logic a_zero, b_zero;
  lzc #(.WIDTH(IN_SIG_BITS), .MODE(1)) u_lzc_a (
    .in_i(a_significand), .cnt_o(lzc_a_cnt), .empty_o(a_zero));
  lzc #(.WIDTH(IN_SIG_BITS), .MODE(1)) u_lzc_b (
    .in_i(b_significand), .cnt_o(lzc_b_cnt), .empty_o(b_zero));

  wire [IN_SIG_BITS*2-1:0] prod_significand_raw =
      {(IN_SIG_BITS)'('b0), a_significand} *
      {(IN_SIG_BITS)'('b0), b_significand};

  logic signed [RAW_EXP_BITS-1:0] a_exponent_raw;
  logic signed [RAW_EXP_BITS-1:0] b_exponent_raw;
  always_comb begin
    // The leading zero makes the source exponent unsigned before it is
    // widened into the signed raw-exponent arithmetic domain.
    a_exponent_raw = $signed(RAW_EXP_BITS'({1'b0, a_exponent}));
    b_exponent_raw = $signed(RAW_EXP_BITS'({1'b0, b_exponent}));
    if (a_is_subnormal)
      a_exponent_raw = a_exponent_raw + ONE_VALUE;
    if (b_is_subnormal)
      b_exponent_raw = b_exponent_raw + ONE_VALUE;
    prod_exponent_raw =
        a_exponent_raw + b_exponent_raw - BIAS_VALUE + ONE_VALUE;
  end

  localparam int unsigned RAW_LZC_WIDTH = 32'($clog2(IN_SIG_BITS*2));
  wire [RAW_LZC_WIDTH-1:0] lza_scnt =
      {1'b0, lzc_a_cnt} + {1'b0, lzc_b_cnt} + 1'b1;

  // lza_scnt is either the exact product LZC or one larger.  Resolve that
  // single-bit ambiguity without a second product-wide LZC.  IME's bounded
  // psm=1 path can align a finite product entirely below its 27-bit window;
  // the shared Zvt fp_align shift expression is unsigned in that corner and
  // would otherwise discard the required sticky contribution.
  // lza_scnt includes the explicit +1 above, so express P-lza as
  // (P-1)-(lza-1).  The latter never needs to encode the out-of-range value P
  // and therefore has exactly the raw product index width, including when P
  // itself is a power of two.
  wire [RAW_LZC_WIDTH-1:0] lza_probe_index =
      RAW_LZC_WIDTH'(IN_SIG_BITS*2 - 1) -
      (lza_scnt - RAW_LZC_WIDTH'(1));
  wire [RAW_LZC_WIDTH-1:0] exact_lzc_cnt =
      prod_significand_raw[lza_probe_index] ?
      lza_scnt - RAW_LZC_WIDTH'(1) : lza_scnt;
  localparam int unsigned ALIGN_CALC_BITS = RAW_EXP_BITS + 2;
  wire signed [ALIGN_CALC_BITS-1:0] align_window =
      ALIGN_CALC_BITS'($signed(prod_exponent_raw)) -
      ALIGN_CALC_BITS'($signed({1'b0, align_minimum_exponent})) +
      ALIGN_CALC_BITS'(OUT_SIG_BITS + 1);
  wire product_too_tiny = !(a_zero || b_zero) &&
      (align_window < ALIGN_CALC_BITS'($signed({1'b0, exact_lzc_cnt})));

  logic [OUT_EXP_BITS-1:0] aligned_exponent;
  logic [OUT_SIG_BITS-1:0] aligned_significand;
  logic aligned_round_bit, aligned_sticky_bit, aligned_sticky_msb;

  fp_align #(
    .IN_EXP_BITS    (RAW_EXP_BITS),
    .IN_SIG_BITS    (IN_SIG_BITS*2),
    .OUT_EXP_BITS   (OUT_EXP_BITS),
    .OUT_SIG_BITS   (OUT_SIG_BITS),
    .USE_EXT_LZC    (1'b1),
    .USE_LZA_POSTFIX(1'b1)
  ) u_align (
    .in_exponent              (prod_exponent_raw),
    .in_significand           (prod_significand_raw),
    .ext_lzc_cnt              (lza_scnt),
    .ext_in_zero              (a_zero | b_zero),
    .align_minimum_exponent   (align_minimum_exponent),
    .align_trimmed_exponent   (align_trimmed_exponent),
    .out_exponent             (aligned_exponent),
    .out_significand          (aligned_significand),
    .out_round_bit            (aligned_round_bit),
    .out_sticky_bit           (aligned_sticky_bit),
    .out_sticky_msb           (aligned_sticky_msb),
    .overflow                 (align_overflow)
  );

  assign prod_exponent   = aligned_exponent;
  assign prod_significand = product_too_tiny ? '0 : aligned_significand;
  assign prod_round_bit   = product_too_tiny ? 1'b0 : aligned_round_bit;
  assign prod_sticky_bit  = product_too_tiny ? 1'b1 : aligned_sticky_bit;
  assign prod_sticky_msb  = product_too_tiny ? 1'b0 : aligned_sticky_msb;

`ifdef ASSERT_ON
  logic [RAW_LZC_WIDTH-1:0] ref_lzc_cnt;
  logic ref_lzc_empty;
  lzc #(.WIDTH(IN_SIG_BITS*2), .MODE(1)) u_ref_lzc (
    .in_i(prod_significand_raw),
    .cnt_o(ref_lzc_cnt),
    .empty_o(ref_lzc_empty));
  `rvv_expect(ref_lzc_empty || (lza_scnt == ref_lzc_cnt) ||
      (lza_scnt == ref_lzc_cnt + 1'b1))
    else $warning("lza_scnt does not follow LZA condition of lzc_cnt");
  `rvv_expect(ref_lzc_empty || exact_lzc_cnt == ref_lzc_cnt)
    else $warning("exact_lzc_cnt does not match product leading-zero count");
`endif
endmodule
