// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// IME-private sign/magnitude adder derived from Zvt fp_absaddsub.  Keeping the
// corrected magnitude ordering here prevents IME correctness fixes from
// changing the mutually-exclusive VME implementation.
module ime_fp_absaddsub #(
  parameter int unsigned IN_WIDTH = 32'd24,
  // The split path is used by the wide psm=0 reduction.  Its caller guarantees
  // that the larger magnitude has zeroes in the low slice.
  parameter int unsigned VALID_HIGH_BITS = IN_WIDTH,
  parameter logic PARALLEL_ADDSUB = 1'b1
) (
  input  logic [IN_WIDTH-1:0] a,
  input  logic [IN_WIDTH-1:0] b,
  input  logic                do_subtract,
  output logic [IN_WIDTH:0]   sum,
  // True exactly when |b|>|a| for a subtract operation.
  output logic                sum_negative
);
  localparam int unsigned LOW_BITS = IN_WIDTH - VALID_HIGH_BITS;

  generate
    if (LOW_BITS == 0) begin : g_no_split
      wire [IN_WIDTH-1:0] b_complement = do_subtract ? ~b : b;
      wire [IN_WIDTH:0] raw_sum =
          {1'b0, a} + {1'b0, b_complement} + do_subtract;
      wire a_lt_b = do_subtract && !raw_sum[IN_WIDTH];

      assign sum_negative = a_lt_b;
      if (PARALLEL_ADDSUB) begin : g_parallel
        assign sum = !do_subtract ? raw_sum :
                     a_lt_b ? {1'b0, b - a} : {1'b0, a - b};
      end else begin : g_single
        assign sum = !do_subtract ? raw_sum :
                     a_lt_b ? -raw_sum : {1'b0, raw_sum[IN_WIDTH-1:0]};
      end
    end else begin : g_split
      wire [VALID_HIGH_BITS-1:0] a_high =
          a[IN_WIDTH-1 -: VALID_HIGH_BITS];
      wire [VALID_HIGH_BITS-1:0] b_high =
          b[IN_WIDTH-1 -: VALID_HIGH_BITS];
      wire [LOW_BITS-1:0] a_low = a[LOW_BITS-1:0];
      wire [LOW_BITS-1:0] b_low = b[LOW_BITS-1:0];
      wire [LOW_BITS-1:0] nonzero_low = a_low | b_low;
      wire [LOW_BITS-1:0] low_result =
          do_subtract ? (~nonzero_low + 1'b1) : nonzero_low;

      wire carry_in_ab = do_subtract && !(|b_low);
      wire [VALID_HIGH_BITS-1:0] b_high_complement =
          do_subtract ? ~b_high : b_high;
      wire [VALID_HIGH_BITS:0] ab_high =
          {1'b0, a_high} + {1'b0, b_high_complement} + carry_in_ab;
      wire a_lt_b = do_subtract && !ab_high[VALID_HIGH_BITS];

      assign sum_negative = a_lt_b;
      if (PARALLEL_ADDSUB) begin : g_parallel
        wire carry_in_ba = do_subtract && !(|a_low);
        wire [VALID_HIGH_BITS-1:0] a_high_complement =
            do_subtract ? ~a_high : a_high;
        wire [VALID_HIGH_BITS:0] ba_high =
            {1'b0, b_high} + {1'b0, a_high_complement} + carry_in_ba;
        wire [VALID_HIGH_BITS-1:0] magnitude_high =
            a_lt_b ? ba_high[VALID_HIGH_BITS-1:0] :
                     ab_high[VALID_HIGH_BITS-1:0];
        assign sum = !do_subtract ? {ab_high, low_result} :
                                    {{1'b0, magnitude_high}, low_result};
      end else begin : g_single
        wire low_is_zero = !(|nonzero_low);
        wire [VALID_HIGH_BITS-1:0] ba_high =
            ~ab_high[VALID_HIGH_BITS-1:0] + low_is_zero;
        wire [VALID_HIGH_BITS-1:0] magnitude_high =
            a_lt_b ? ba_high : ab_high[VALID_HIGH_BITS-1:0];
        assign sum = !do_subtract ? {ab_high, low_result} :
                                    {{1'b0, magnitude_high}, low_result};
      end
    end
  endgenerate

`ifndef SYNTHESIS
  initial begin
    assert (VALID_HIGH_BITS > 0 && VALID_HIGH_BITS <= IN_WIDTH);
  end
`endif
endmodule
