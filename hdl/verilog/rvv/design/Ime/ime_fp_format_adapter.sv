// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// IME-only input-format mapper.  This module performs no floating-point
// arithmetic: it rewrites an input encoding into an exactly equivalent
// fpnew format so the copied Zvt mulbulk lane can consume mixed fmt_A/fmt_B
// cells through one common format.
//
//   EEW=32: IEEE binary32                    -> FP32
//   EEW=16: IEEE binary16 or bfloat16        -> FP32
//   EEW=8 : OCP E4M3 or E5M2                 -> FP16
//   EEW=4 : OCP E2M1                         -> FP8 (E5M2 container)
//
// Every finite source value is exactly representable in its destination.
// IEEE signaling/quiet state is retained for FP16 and bfloat16.  OCP FP8
// does not distinguish signaling and quiet NaNs, so its NaNs map to a quiet
// binary16 NaN.  E2M1 has neither infinity nor NaN encodings.
module ime_fp_format_adapter (
  input  logic [31:0]             raw_i,
  input  logic [2:0]              eew_log2_i,
  input  logic                    altfmt_i,
  output logic [31:0]             normalized_o
);
  logic sign;
  logic [4:0] exp5;
  logic [3:0] exp4;
  logic [1:0] exp2;
  logic [9:0] mant10;
  logic [2:0] mant3;
  logic [1:0] mant2;
  logic mant1;
  logic found;
  integer lead;
  logic [7:0] fp32_exp;
  logic [22:0] fp32_mant;
  logic [4:0] fp16_exp;
  logic [9:0] fp16_mant;
  logic [4:0] fp8_exp;
  logic [1:0] fp8_mant;

  always_comb begin
    normalized_o = '0;
    sign = raw_i[31];
    exp5 = '0;
    exp4 = '0;
    exp2 = '0;
    mant10 = '0;
    mant3 = '0;
    mant2 = '0;
    mant1 = '0;
    found = 1'b0;
    lead = 0;
    fp32_exp = '0;
    fp32_mant = '0;
    fp16_exp = '0;
    fp16_mant = '0;
    fp8_exp = '0;
    fp8_mant = '0;

    unique case (eew_log2_i)
      3'd5: begin
        // altfmt is architecturally ignored for a 32-bit input cell.
        normalized_o = raw_i;
      end

      3'd4: begin
        sign = raw_i[15];
        if (altfmt_i) begin
          // bfloat16 has the same exponent and bias as binary32.
          normalized_o = {sign, raw_i[14:7], raw_i[6:0], 16'b0};
        end else begin
          exp5 = raw_i[14:10];
          mant10 = raw_i[9:0];
          if (exp5 == 5'h1f) begin
            fp32_exp = 8'hff;
            // Preserve the IEEE quiet/signaling bit and payload.
            fp32_mant = {mant10, 13'b0};
          end else if (exp5 != '0) begin
            fp32_exp = 8'(exp5) + 8'd112;
            fp32_mant = {mant10, 13'b0};
          end else if (mant10 != '0) begin
            // binary16 subnormal: value = mant10 * 2^-24.
            for (int bit_index = 9; bit_index >= 0; bit_index--) begin
              if (!found && mant10[bit_index]) begin
                found = 1'b1;
                lead = bit_index;
              end
            end
            fp32_exp = 8'(lead + 103);
            fp32_mant = (23'(mant10) - (23'(1) << lead)) <<
                        (23 - lead);
          end
          normalized_o = {sign, fp32_exp, fp32_mant};
        end
      end

      3'd3: begin
        sign = raw_i[7];
        if (altfmt_i) begin
          // OCP E5M2 and IEEE binary16 share exponent bias 15.
          exp5 = raw_i[6:2];
          mant2 = raw_i[1:0];
          fp16_exp = exp5;
          fp16_mant = {mant2, 8'b0};
          if ((exp5 == 5'h1f) && (mant2 != '0)) begin
            // OCP FP8 has one undifferentiated NaN class.
            fp16_mant[9] = 1'b1;
          end
        end else begin
          // OCP E4M3 finite-only, bias 7.  0x7f/0xff are NaN.
          exp4 = raw_i[6:3];
          mant3 = raw_i[2:0];
          if ((exp4 == 4'hf) && (mant3 == 3'h7)) begin
            fp16_exp = 5'h1f;
            fp16_mant = 10'h200;
          end else if (exp4 != '0) begin
            fp16_exp = 5'(exp4) + 5'd8;
            fp16_mant = {mant3, 7'b0};
          end else if (mant3 != '0) begin
            // E4M3 subnormal: value = mant3 * 2^-9.
            found = 1'b0;
            for (int bit_index = 2; bit_index >= 0; bit_index--) begin
              if (!found && mant3[bit_index]) begin
                found = 1'b1;
                lead = bit_index;
              end
            end
            fp16_exp = 5'(lead + 6);
            fp16_mant = (10'(mant3) - (10'(1) << lead)) <<
                        (10 - lead);
          end
        end
        normalized_o[15:0] = {sign, fp16_exp, fp16_mant};
      end

      3'd2: begin
        // OCP E2M1, bias 1, has no Inf/NaN encodings.  FP8 E5M2 is
        // an exact container for all eight E2M1 values per sign.
        sign = raw_i[3];
        exp2 = raw_i[2:1];
        mant1 = raw_i[0];
        if (exp2 == '0) begin
          if (mant1) begin
            fp8_exp = 5'd14;  // 0.5
            fp8_mant = '0;
          end
        end else begin
          fp8_exp = 5'(exp2) + 5'd14;
          fp8_mant = {mant1, 1'b0};
        end
        normalized_o[7:0] = {sign, fp8_exp, fp8_mant};
      end

      default: begin
        normalized_o = '0;
      end
    endcase
  end
endmodule
