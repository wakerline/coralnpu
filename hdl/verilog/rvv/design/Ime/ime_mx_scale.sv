// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// Lightweight OCP MX E8M0 scale-pair adapter.  E8M0 encodes 2^(e-127),
// except 8'hff which is NaN.  The exact positive scale product is encoded in
// the FP32 accumulator format here; all subsequent multiply/add arithmetic is
// performed by the copied Zvt FP lanes.
module ime_mx_scale (
  input  logic [7:0]                 scale_a_i,
  input  logic [7:0]                 scale_b_i,
  input  fpnew_pkg::roundmode_e      rnd_mode_i,
  output logic [31:0]                scale_o,
  output fpnew_pkg::status_t         status_o,
  output logic                       is_nan_o
);
  integer unbiased_exp;

  always_comb begin
    scale_o = 32'h0000_0000;
    status_o = '0;
    is_nan_o = (scale_a_i == 8'hff) || (scale_b_i == 8'hff);
    unbiased_exp = int'(scale_a_i) + int'(scale_b_i) - 254;

    if (is_nan_o) begin
      scale_o = 32'h7fc0_0000;
    end else if (unbiased_exp > 127) begin
      // IEEE overflow of a positive exact value.
      status_o.OF = 1'b1;
      status_o.NX = 1'b1;
      unique case (rnd_mode_i)
        fpnew_pkg::RTZ,
        fpnew_pkg::RDN: scale_o = 32'h7f7f_ffff;
        default:        scale_o = 32'h7f80_0000;
      endcase
    end else if (unbiased_exp >= -126) begin
      scale_o[30:23] = 8'(unbiased_exp + 127);
    end else if (unbiased_exp >= -149) begin
      // A power of two in the binary32 subnormal range is exact.
      scale_o[unbiased_exp + 149] = 1'b1;
    end else begin
      // The smallest possible pair is 2^-254, far below half-minsub.
      status_o.UF = 1'b1;
      status_o.NX = 1'b1;
      // 2^-150 is exactly halfway between zero and binary32 min-subnormal.
      // RMM chooses the endpoint with greater magnitude; smaller magnitudes
      // still round to zero.  RUP selects min-subnormal for every positive
      // non-zero discarded value.
      if ((rnd_mode_i == fpnew_pkg::RUP) ||
          ((rnd_mode_i == fpnew_pkg::RMM) && (unbiased_exp == -150)))
        scale_o = 32'h0000_0001;
    end
  end
endmodule
