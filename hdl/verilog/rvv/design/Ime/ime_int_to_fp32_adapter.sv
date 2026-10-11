// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// Exact signed-integer encoding adapter for the integer-input MX block sum.
// The supported IME blocks are bounded by 32 signed int8 products, so the
// magnitude is below 2^24 and is exactly representable in binary32.  This is
// encoding logic only; scale multiplication and C accumulation use Zvt FP
// primitives.
module ime_int_to_fp32_adapter (
  input  logic signed [31:0] value_i,
  output logic [31:0]        fp32_o
);
  logic sign;
  logic [31:0] magnitude;
  integer lead;
  logic found;
  logic [7:0] exponent;
  logic [22:0] mantissa;

  always_comb begin
    sign = value_i < 0;
    magnitude = sign ? 32'(-value_i) : 32'(value_i);
    lead = 0;
    found = 1'b0;
    exponent = '0;
    mantissa = '0;
    if (magnitude != '0) begin
      for (int bit_index = 31; bit_index >= 0; bit_index--) begin
        if (!found && magnitude[bit_index]) begin
          found = 1'b1;
          lead = bit_index;
        end
      end
      exponent = 8'(lead + 127);
      if (lead <= 23)
        mantissa = 23'((magnitude << (23 - lead)) & 32'h007f_ffff);
      else
        mantissa = magnitude[lead-1 -: 23];
    end
    fp32_o = {sign, exponent, mantissa};
  end

`ifndef SYNTHESIS
  always_comb begin
    // Exact extrema for a 32-element signed-int8 block dot product:
    //   min = 32 * (-128 * 127), max = 32 * (-128 * -128).
    assert ((value_i >= -32'sd520192) && (value_i <= 32'sd524288));
  end
`endif
endmodule
