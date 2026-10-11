// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// IME-private rounding stage copied from Zvt fp_rounding.  IME selects
// post-round overflow by destination format; keeping that correction private
// leaves the mutually-exclusive VME implementation unchanged.
module ime_fp_rounding #(
  parameter fpnew_pkg::fmt_logic_t FP_FMT_CONFIG = 5'b10001,
  localparam int unsigned WIDTH = fpnew_pkg::max_fp_width(FP_FMT_CONFIG),
  localparam fpnew_pkg::fp_encoding_t SUPER_FORMAT =
      fpnew_pkg::super_format(FP_FMT_CONFIG),
  localparam int unsigned SUPER_EXP_BITS = SUPER_FORMAT.exp_bits,
  localparam int unsigned SUPER_MAN_BITS = SUPER_FORMAT.man_bits,
  localparam int unsigned NUM_FORMATS = fpnew_pkg::NUM_FP_FORMATS
) (
  input  fpnew_pkg::fp_format_e dst_fmt,
  input  fpnew_pkg::roundmode_e rnd_mode,
  input  logic                  exact_zero_keep_sign,
  input  logic                  preround_sign,
  input  logic [SUPER_EXP_BITS:0] preround_exponent,
  input  logic [SUPER_MAN_BITS-1:0] preround_mantissa,
  input  logic                  round_bit,
  input  logic                  sticky_bit,
  input  logic                  sticky_msb,
  output logic [WIDTH-1:0]      round_normal_result,
  output fpnew_pkg::status_t    status
);
  wire preround_overflow = preround_exponent[SUPER_EXP_BITS] ||
                           &preround_exponent[SUPER_EXP_BITS-1:0];
  wire input_is_zero = (preround_exponent == '0) &&
                       !(|{preround_mantissa, round_bit, sticky_bit});
  wire [SUPER_MAN_BITS+1:0] preround_visible_bits =
      preround_overflow ? '0 :
      {preround_mantissa, round_bit, sticky_msb};

  logic [NUM_FORMATS-1:0] fmt_guard_bit;
  logic [NUM_FORMATS-1:0] fmt_round_bit;
  logic [NUM_FORMATS-1:0] fmt_sticky_bit;
  logic [NUM_FORMATS-1:0] fmt_sticky_msb;
  for (genvar format = 0; format < NUM_FORMATS; format++) begin : gen_format_bits
    localparam int MAN_WIDTH = fpnew_pkg::FP_ENCODINGS[format].man_bits;
    if (!FP_FMT_CONFIG[format]) begin : g_disabled
      assign fmt_guard_bit[format] = 1'b0;
      assign fmt_round_bit[format] = 1'b0;
      assign fmt_sticky_bit[format] = 1'b0;
      assign fmt_sticky_msb[format] = 1'b0;
    end else begin : g_enabled
      assign fmt_guard_bit[format] =
          preround_visible_bits[SUPER_MAN_BITS + 2 - MAN_WIDTH];
      assign fmt_round_bit[format] =
          preround_visible_bits[SUPER_MAN_BITS + 1 - MAN_WIDTH];
      assign fmt_sticky_msb[format] =
          preround_visible_bits[SUPER_MAN_BITS - MAN_WIDTH];
      assign fmt_sticky_bit[format] =
          |{preround_visible_bits[SUPER_MAN_BITS-MAN_WIDTH:0], sticky_bit};
    end
  end

  wire result_guard_bit = fmt_guard_bit[dst_fmt];
  wire result_round_bit = fmt_round_bit[dst_fmt];
  wire result_sticky_bit = fmt_sticky_bit[dst_fmt];
  wire result_sticky_msb = fmt_sticky_msb[dst_fmt];
  logic round_up;
  always_comb begin
    unique case (rnd_mode)
      fpnew_pkg::RNE: begin
        unique case ({result_round_bit, result_sticky_bit})
          2'b00, 2'b01: round_up = 1'b0;
          2'b10: round_up = result_guard_bit;
          2'b11: round_up = 1'b1;
          default: round_up = fpnew_pkg::DONT_CARE;
        endcase
      end
      fpnew_pkg::RTZ: round_up = 1'b0;
      fpnew_pkg::RDN: round_up =
          (result_round_bit || result_sticky_bit) && preround_sign;
      fpnew_pkg::RUP: round_up =
          (result_round_bit || result_sticky_bit) && !preround_sign;
      fpnew_pkg::RMM: round_up = result_round_bit;
      fpnew_pkg::ROD: round_up = !result_guard_bit &&
          (result_round_bit || result_sticky_bit);
      default: round_up = fpnew_pkg::DONT_CARE;
    endcase
  end

  localparam int unsigned ROUND_VALUE_BITS =
      SUPER_EXP_BITS + SUPER_MAN_BITS + 1;
  logic [NUM_FORMATS-1:0][ROUND_VALUE_BITS-1:0] fmt_carry_in_bits;
  for (genvar format = 0; format < NUM_FORMATS; format++) begin : gen_carry
    assign fmt_carry_in_bits[format] =
        ROUND_VALUE_BITS'(FP_FMT_CONFIG[format]) <<
        (SUPER_MAN_BITS - fpnew_pkg::FP_ENCODINGS[format].man_bits);
  end
  wire [ROUND_VALUE_BITS-1:0] carry_in_bits =
      round_up ? fmt_carry_in_bits[dst_fmt] : '0;

  logic [SUPER_MAN_BITS-1:0] round_mantissa;
  logic [SUPER_EXP_BITS-1:0] round_exponent;
  logic [ROUND_VALUE_BITS-1:0] rounded_value;
  assign rounded_value =
      {preround_exponent, preround_mantissa} + carry_in_bits;
  // Drop only the extra pre-round overflow bit; retain an increment of one
  // ULP at the destination format's least significant mantissa bit.
  assign {round_exponent, round_mantissa} =
      rounded_value[ROUND_VALUE_BITS-2:0];

  logic [NUM_FORMATS-1:0] fmt_postround_overflow;
  for (genvar format = 0; format < NUM_FORMATS; format++) begin : gen_overflow
    localparam int EXP_BITS = fpnew_pkg::FP_ENCODINGS[format].exp_bits;
    if (FP_FMT_CONFIG[format]) begin : g_enabled
      assign fmt_postround_overflow[format] =
          round_exponent[EXP_BITS-1:0] == '1;
    end else begin : g_disabled
      assign fmt_postround_overflow[format] = 1'b1;
    end
  end
  wire postround_overflow = fmt_postround_overflow[dst_fmt];
  wire any_overflow = preround_overflow || postround_overflow;
  wire postround_underflow = round_exponent == 0 ||
      ((preround_exponent == 0) && (round_exponent == 1) &&
       (!(result_round_bit && result_sticky_bit) ||
        (!result_sticky_msb &&
         (rnd_mode == fpnew_pkg::RNE || rnd_mode == fpnew_pkg::RMM))));
  wire result_inexact = result_round_bit || result_sticky_bit;

  wire result_sign = input_is_zero && !exact_zero_keep_sign ?
                     1'b0 : preround_sign;
  assign round_normal_result = {result_sign, round_exponent, round_mantissa};
  assign status.NV = 1'b0;
  assign status.DZ = 1'b0;
  assign status.OF = any_overflow;
  // A single destination-format rounding cannot be both an overflow and an
  // underflow.  The extra pre-round exponent bit is intentionally dropped
  // above; without this guard an overflowing exponent can wrap to zero and
  // spuriously satisfy postround_underflow.
  assign status.UF = !any_overflow && postround_underflow && result_inexact;
  assign status.NX = result_inexact;
endmodule
