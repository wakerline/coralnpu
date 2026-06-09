// Generated from TI TimeSeries Generic quantized ONNX.
//
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "cnn_ts_gen_base_1k_int8.h"

static const int16_t input_q[CNN_TS_GEN_BASE_1K_INT8_INPUT_LEN] = {
    119, 6,   -8,  -18, -22, -24, -24, -24, -32, -27, -18, -31, -40, -37, -31,
    -20, -27, -31, -24, -28, -29, -33, -40, -31, -34, -26, -29, -41, -43, -38,
    -32, -19, -20, -24, -22, -24, -25, -34, -35, -16, 21,  3,   -33, -42, -28,
    -36, -25, -18, -17, -26, -15, -4,  10,  -21, -6,  5,   -2,  -27, -27, -11,
    -10, -22, -19, -11, -5,  -19, -14, -22, -2,  -15, -31, -18, -17, -34, -39,
    -27, -23, -21, -22, -6,  27,  78,  58,  3,   -20, -33, -39, -26, -33, -44,
    -39, -31, -34, -40, -37, -30, -38, -41, 2,   4,   -36, -28, -28, -39, -36,
    -29, -18, -25, -30, -27, -23, -29, -27, -23, -47, -33, -35, -25, -27, -40,
    -24, -31, -7,  -22, -31, -28, -42, -17, -22, -39, -30, -36, -30, -42, -41,
    -34, -33, -47, -24, -18, -25, -26, -22, -21, -33, -18, -33, -37, -45, -34,
    -31, -37, -38, -35, -33, -34, -25, -32, -24, -30, -32, -27, -28, -41, -39,
    -39, -28, -31, -45, -29, -25, -40, -25, -31, -26, -37, -28, -33, -26, -27,
    -30, -36, -36, -34, -31, -24, -27, -40, -30, -22, -34, -18, -15, -30, -31,
    -36, -26, -32, -33, -35, -33, -38, -20, -28, -20, -36, -24, -26, -42, -23,
    -38, -29, -24, -15, -21, -26, -34, -21, -31, -44, -29, -29, -30, -38, -40,
    -29, -26, -29, -24, -26, -28, -30, -29, -29, -33, -34, -22, -23, -33, -35,
    -24, -34, -42, -25, -29, -3,  -28, -38, -39, -23, -33, -37, -41, -40, -32,
    -22};

static const int8_t conv0_weight[40] = {
    36,  -56, 55,  67,  32,  86,   -61, -35, 95,  -33, 32,  -43, 97, 55,
    -14, -5,  31,  -50, -9,  -103, -78, 71,  -32, -30, -60, 44,  29, 42,
    67,  -48, -39, 2,   112, -49,  100, -13, -88, 11,  48,  -93};
static const int32_t conv0_offset[8] = {167, 69, 154, 96, -97, 99, 100, 101};
static const uint32_t conv0_shift[8] = {7, 6, 7, 7, 7, 7, 7, 7};

static const int8_t conv1_weight[320] = {
    -17, -37, -13,  -2,   6,    -47,  -10, 5,   49,   -53,  45,  7,   -27,  11,
    -41, 30,  -46,  -53,  -3,   -45,  2,   -4,  32,   -15,  -2,  -54, -57,  11,
    -56, 21,  51,   -32,  -13,  -50,  15,  -1,  -27,  -46,  -46, 49,  15,   69,
    80,  76,  -71,  -110, 77,   -91,  6,   64,  106,  -94,  62,  -65, -102, 55,
    -28, -28, -118, 30,   77,   -40,  14,  61,  -105, 100,  -51, -80, 1,    105,
    -40, 7,   -83,  89,   103,  -35,  5,   -88, -92,  -41,  -13, -69, 24,   -74,
    -15, 34,  -3,   -25,  27,   -64,  3,   48,  -55,  -19,  -38, -16, 26,   75,
    -47, 27,  -57,  2,    67,   -41,  53,  9,   -73,  -22,  -15, -43, 43,   21,
    38,  -11, -33,  19,   35,   61,   -13, -21, -66,  21,   58,  -73, 62,   41,
    60,  -58, -77,  57,   -17,  14,   26,  -15, 69,   45,   -63, -72, 15,   0,
    70,  47,  47,   17,   6,    -46,  -97, -59, -6,   -70,  -30, -12, 59,   -45,
    -47, 30,  59,   4,    -4,   15,   19,  62,  36,   85,   114, -18, 90,   -12,
    -35, -52, 85,   -6,   51,   30,   -21, 67,  37,   47,   29,  -69, -30,  4,
    -66, -9,  43,   30,   -8,   69,   -51, 11,  52,   -51,  50,  -71, -6,   36,
    59,  27,  -52,  -69,  -49,  -92,  -93, -55, 58,   -61,  24,  -58, -47,  38,
    -38, -97, -5,   67,   55,   -29,  34,  -37, 78,   -80,  -72, -51, -52,  -55,
    -18, -77, -95,  -20,  -29,  -43,  -37, 49,  14,   44,   -59, 86,  -86,  -65,
    -64, -67, -65,  70,   -49,  -31,  -61, 5,   50,   16,   -82, 85,  55,   47,
    -87, 77,  -47,  55,   -114, -29,  -10, -64, -9,   -111, 15,  -92, -12,  -61,
    -97, 91,  65,   26,   80,   18,   -33, -13, -78,  -25,  -13, -99, -41,  -63,
    56,  6,   -44,  -49,  2,    -58,  4,   14,  -55,  -82,  -74, 61,  24,   73,
    60,  -37, -104, 16,   -120, -116, -16, 16,  47,   28,   41,  -48, 62,   -11,
    -76, -16, 14,   9,    24,   -94,  39,  -4,  -18,  -52,  -88, 37};
static const int32_t conv1_offset[8] = {6667,  2480,  2438, 862,
                                        -7345, 15342, 9303, 7860};
static const uint32_t conv1_shift[8] = {6, 7, 7, 7, 7, 7, 7, 6};

static const int8_t conv2_weight[384] = {
    -16, 1,    -2,   -32, 73,  13,   -15, -31,  17,  79,  -51, -77, 80,   -18,
    63,  -47,  64,   -24, -1,  -17,  -48, -44,  1,   7,   -81, 115, -47,  -6,
    18,  3,    -85,  -67, 69,  86,   23,  -29,  77,  35,  -78, 72,  -63,  7,
    -87, -38,  -96,  -30, 100, -91,  8,   37,   43,  -11, 19,  16,  -13,  41,
    -4,  42,   -24,  20,  -7,  15,   -63, 19,   -15, -60, 2,   15,  13,   -66,
    -55, -63,  -13,  -63, 28,  58,   38,  61,   -44, 18,  -88, -57, -45,  -6,
    55,  -62,  62,   13,  -42, -51,  5,   20,   44,  -54, 65,  -83, -111, -83,
    104, 35,   -106, 100, -54, -71,  -73, -108, -30, 4,   -27, 114, -10,  -98,
    -27, -104, -78,  -90, 29,  -37,  -32, 106,  -86, -72, -83, 20,  -16,  109,
    0,   -10,  41,   2,   -26, -108, 51,  24,   62,  -67, 109, -21, 53,   -94,
    -9,  -67,  111,  -29, 37,  -15,  -63, -26,  -41, 27,  -55, -14, -36,  -5,
    -9,  -46,  62,   17,  31,  -24,  44,  -46,  -29, 12,  -48, 12,  58,   -7,
    -11, 3,    -44,  52,  -39, 17,   -62, 43,   -7,  -11, 52,  -32, 45,   16,
    52,  11,   -68,  57,  -15, -27,  -49, 13,   -56, -66, -46, -7,  -40,  -65,
    -68, -30,  -3,   38,  43,  47,   8,   1,    -27, 19,  7,   -40, 12,   -49,
    11,  -61,  46,   38,  0,   -17,  -11, -51,  -2,  19,  -55, -43, 57,   -54,
    -29, -35,  67,   18,  -64, 43,   -50, -6,   -56, -41, -13, 49,  -62,  9,
    1,   -57,  -17,  74,  -10, -85,  85,  -69,  -29, -45, -47, 47,  71,   25,
    -68, -37,  44,   19,  2,   -54,  50,  65,   26,  19,  15,  78,  -38,  -35,
    15,  56,   7,    14,  -14, -4,   -76, -6,   25,  -4,  -61, -4,  28,   61,
    -35, -54,  66,   -59, -38, 55,   44,  34,   -72, 94,  44,  -95, -3,   33,
    -73, -45,  41,   -1,  62,  -67,  -5,  40,   -92, -22, 78,  -74, -34,  95,
    106, 24,   -28,  28,  14,  -18,  91,  -51,  51,  -61, -22, 89,  4,    -62,
    -9,  94,   -97,  3,   65,  68,   -20, 113,  82,  81,  98,  -28, -1,   -26,
    45,  48,   -48,  40,  -51, -31,  -41, -18,  -88, 57,  -42, 72,  -57,  60,
    26,  -68,  8,    52,  64,  73,   18,  -70,  40,  47,  80,  25,  -52,  -19,
    2,   -64,  -60,  -80, -90, -22,  -95, 20,   -74, 27,  -58, -6,  110,  -102,
    35,  -100, -28,  -16, -49, -36};
static const int32_t conv2_offset[16] = {
    1481, 8370,  4569,  5392, 22563, 3572,   6094,  5811,
    7481, 13715, -6164, 381,  -1920, -15822, -4715, 23984};
static const uint32_t conv2_shift[16] = {7, 7, 7, 8, 8, 8, 7, 7,
                                         7, 7, 7, 7, 7, 7, 7, 7};

static const int8_t fc_weight[128] = {
    -2,  15,  -25, 67,  19,  -6,  -3,  -9,  30,  -31, 5,   -21, 0,   -22, 11,
    7,   57,  -31, 63,  -34, 44,  -22, 12,  -43, -39, 20,  -78, 59,  -52, -4,
    -26, 22,  4,   -10, -12, 49,  20,  9,   -7,  0,   -9,  -12, -38, 26,  -31,
    8,   -20, -16, 2,   -5,  -65, 43,  3,   32,  9,   16,  7,   26,  -18, 34,
    33,  -30, -7,  -29, 40,  -4,  45,  -60, 64,  -90, 64,  -40, 5,   -46, 15,
    -33, 43,  -64, 58,  -67, 22,  26,  -2,  -13, -16, 46,  -35, 26,  -11, 41,
    -14, 25,  -50, 43,  -7,  12,  -17, 13,  -8,  -21, -37, 22,  -23, 11,  25,
    25,  16,  -30, -49, 0,   -57, 3,   -3,  20,  -27, 45,  -46, 25,  -38, 27,
    -13, -30, 16,  -35, -4,  15,  32,  23};
static const int32_t fc_offset[2] = {2971, -1452};
static const uint32_t fc_shift[2] = {9, 9};
static const int8_t golden_output[2] = {93, -95};

static int16_t act0[CNN_TS_GEN_BASE_1K_INT8_MAX_ACT]
    __attribute__((aligned(128), section(".l2")));
static int16_t act1[CNN_TS_GEN_BASE_1K_INT8_MAX_ACT]
    __attribute__((aligned(128), section(".l2")));
static float features[CNN_TS_GEN_BASE_1K_INT8_FC_IN]
    __attribute__((aligned(128), section(".l2")));
static int8_t output[2] __attribute__((aligned(128), section(".l2")));

static inline __attribute__((always_inline)) int32_t clamp_i32(int32_t value, int32_t lo, int32_t hi) {
  if (value < lo)
    return lo;
  if (value > hi)
    return hi;
  return value;
}

static inline __attribute__((always_inline)) int32_t floor_div_pow2(int32_t value, uint32_t shift) {
  int32_t denom = 1 << shift;
  if (value >= 0)
    return value >> shift;
  return -(((-value) + denom - 1) >> shift);
}

static inline __attribute__((always_inline)) int16_t requant_u8(int32_t value, uint32_t shift) {
  return (int16_t)clamp_i32(floor_div_pow2(value, shift), 0, 255);
}

static inline __attribute__((always_inline)) int8_t requant_i8_float(float value, uint32_t shift) {
  int32_t q = (int32_t)__builtin_floorf(value * (1.0f / (float)(1u << shift)));
  return (int8_t)clamp_i32(q, -128, 127);
}

static inline __attribute__((always_inline)) void conv1d_relu_i8(int16_t *out, const int16_t *in, uint64_t in_ch,
                           uint64_t in_len, uint64_t out_ch, uint64_t k_len,
                           uint64_t stride, uint64_t pad, uint64_t group,
                           const int8_t *weight, const int32_t *offset,
                           const uint32_t *shift) {
  const uint64_t icpg = in_ch / group;
  const uint64_t ocpg = out_ch / group;
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  uint64_t first_valid = (pad + stride - 1) / stride;
  uint64_t last_valid = 0;
  if (in_len + pad >= k_len)
    last_valid = (in_len + pad - k_len) / stride;
  if (first_valid > out_len)
    first_valid = out_len;
  if (last_valid >= out_len)
    last_valid = out_len - 1;
  if (last_valid + 1 < first_valid)
    first_valid = out_len;

  for (uint64_t oc = 0; oc < out_ch; ++oc) {
    const uint64_t g = oc / ocpg;
    const uint64_t in_base_ch = g * icpg;

    for (uint64_t t = 0; t < first_valid; ++t) {
      int32_t acc = 0;
      for (uint64_t icg = 0; icg < icpg; ++icg) {
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len) {
            uint64_t widx = (oc * icpg + icg) * k_len + k;
            acc += (int32_t)in[(in_base_ch + icg) * in_len + (uint64_t)it] *
                   (int32_t)weight[widx];
          }
        }
      }
      out[oc * out_len + t] = requant_u8(acc + offset[oc], shift[oc]);
    }

    if (first_valid < out_len) {
      for (uint64_t t = first_valid; t <= last_valid; ++t) {
        int32_t acc = 0;
        const uint64_t base = t * stride - pad;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          const int16_t *in_ch_ptr = in + (in_base_ch + icg) * in_len + base;
          for (uint64_t k = 0; k < k_len; ++k) {
            uint64_t widx = (oc * icpg + icg) * k_len + k;
            acc += (int32_t)in_ch_ptr[k] * (int32_t)weight[widx];
          }
        }
        out[oc * out_len + t] = requant_u8(acc + offset[oc], shift[oc]);
      }
    }

    const uint64_t tail_start = first_valid < out_len ? last_valid + 1 : out_len;
    for (uint64_t t = tail_start; t < out_len; ++t) {
      int32_t acc = 0;
      for (uint64_t icg = 0; icg < icpg; ++icg) {
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len) {
            uint64_t widx = (oc * icpg + icg) * k_len + k;
            acc += (int32_t)in[(in_base_ch + icg) * in_len + (uint64_t)it] *
                   (int32_t)weight[widx];
          }
        }
      }
      out[oc * out_len + t] = requant_u8(acc + offset[oc], shift[oc]);
    }
  }
}

static inline __attribute__((always_inline)) void maxpool1d_i16(int16_t *out, const int16_t *in, uint64_t channels,
                          uint64_t in_len, uint64_t k_len, uint64_t stride,
                          uint64_t pad) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  if (pad == 1 && k_len == 3 && stride == 2) {
    for (uint64_t c = 0; c < channels; ++c) {
      const int16_t *in_c = in + c * in_len;
      int16_t *out_c = out + c * out_len;
      int16_t m0 = in_c[0];
      if (in_c[1] > m0)
        m0 = in_c[1];
      out_c[0] = m0;
      for (uint64_t t = 1; t < out_len; ++t) {
        const int16_t *p = in_c + 2 * t - 1;
        int16_t maxv = p[0];
        if (p[1] > maxv)
          maxv = p[1];
        if (p[2] > maxv)
          maxv = p[2];
        out_c[t] = maxv;
      }
    }
    return;
  }
  if (pad == 0) {
    for (uint64_t c = 0; c < channels; ++c) {
      const int16_t *in_c = in + c * in_len;
      int16_t *out_c = out + c * out_len;
      for (uint64_t t = 0; t < out_len; ++t) {
        const int16_t *p = in_c + t * stride;
        int16_t maxv = p[0];
        for (uint64_t k = 1; k < k_len; ++k) {
          int16_t v = p[k];
          if (v > maxv)
            maxv = v;
        }
        out_c[t] = maxv;
      }
    }
    return;
  }
  for (uint64_t c = 0; c < channels; ++c) {
    for (uint64_t t = 0; t < out_len; ++t) {
      int16_t maxv = -32768;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len) {
          int16_t v = in[c * in_len + (uint64_t)it];
          if (v > maxv)
            maxv = v;
        }
      }
      out[c * out_len + t] = maxv;
    }
  }
}

static inline __attribute__((always_inline)) void avgpool1d_i16_to_f32(float *out, const int16_t *in,
                                 uint64_t channels, uint64_t in_len,
                                 uint64_t k_len, uint64_t stride,
                                 uint64_t pad) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  if (pad == 0) {
    const float inv_count = 1.0f / (float)k_len;
    for (uint64_t c = 0; c < channels; ++c) {
      const int16_t *in_c = in + c * in_len;
      float *out_c = out + c * out_len;
      for (uint64_t t = 0; t < out_len; ++t) {
        const int16_t *p = in_c + t * stride;
        int32_t sum = 0;
        for (uint64_t k = 0; k < k_len; ++k)
          sum += p[k];
        out_c[t] = (float)sum * inv_count;
      }
    }
    return;
  }
  for (uint64_t c = 0; c < channels; ++c) {
    for (uint64_t t = 0; t < out_len; ++t) {
      int32_t sum = 0;
      uint64_t count = 0;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len) {
          sum += in[c * in_len + (uint64_t)it];
          ++count;
        }
      }
      out[c * out_len + t] = (float)sum / (float)count;
    }
  }
}



static inline __attribute__((always_inline)) void linear_i8(int8_t *out, const float *in) {
  for (uint64_t o = 0; o < 2; ++o) {
    float acc = (float)fc_offset[o];
    for (uint64_t i = 0; i < CNN_TS_GEN_BASE_1K_INT8_FC_IN; ++i)
      acc += in[i] * (float)fc_weight[i * 2 + o];
    out[o] = requant_i8_float(acc, fc_shift[o]);
  }
}

void cnn_ts_gen_base_1k_int8(void) {
  int16_t *a = act0;
  int16_t *b = act1;
  int16_t *tmp;
  for (uint64_t i = 0; i < CNN_TS_GEN_BASE_1K_INT8_INPUT_LEN; ++i)
    a[i] = input_q[i];
  conv1d_relu_i8(b, a, 1, 256, 8, 5, 1, 2, 1, conv0_weight, conv0_offset,
                 conv0_shift);
  tmp = a;
  a = b;
  b = tmp;
  conv1d_relu_i8(b, a, 8, 256, 8, 5, 1, 2, 1, conv1_weight, conv1_offset,
                 conv1_shift);
  tmp = a;
  a = b;
  b = tmp;
  maxpool1d_i16(b, a, 8, 256, 3, 2, 1);
  tmp = a;
  a = b;
  b = tmp;
  conv1d_relu_i8(b, a, 8, 128, 16, 3, 1, 1, 1, conv2_weight, conv2_offset,
                 conv2_shift);
  tmp = a;
  a = b;
  b = tmp;
  avgpool1d_i16_to_f32(features, a, 16, 128, 32, 32, 0);
  linear_i8(output, features);
}

const int8_t *cnn_ts_gen_base_1k_int8_output(void) { return output; }
const int8_t *cnn_ts_gen_base_1k_int8_golden_output(void) {
  return golden_output;
}
