// Generated from training/quantization/model.onnx and
// golden_vectors/test_vector.c.
//
// SPDX-License-Identifier: Apache-2.0

#include <math.h>
#include <stdint.h>

#include "cnn_ts_gen_base_100_int8.h"

static const float input[CNN_TS_GEN_BASE_100_INT8_INPUT_LEN]
    __attribute__((unused)) = {
        62.40171f,  -16.48348f, -27.06583f, -30.90532f, -45.60642f, -32.83871f,
        -36.89949f, -48.9502f,  -38.31466f, -37.68603f, -35.47908f, -40.39796f,
        -37.80908f, -39.23488f, -43.717f,   -37.53047f, -39.55383f, -40.43825f,
        -36.96111f, -50.40835f, -39.83159f, -41.70859f, -42.44573f, -43.15535f,
        -43.98126f, -41.55548f, -43.0297f,  -49.61991f, -44.83294f, -61.53513f,
        -42.37318f, -41.5178f,  -38.44868f, -38.27445f, -57.56592f, -42.85658f,
        -42.73112f, -42.00269f, -37.77743f, -32.25219f, -9.03143f,  -20.2772f,
        -36.08117f, -44.36416f, -37.99189f, -45.67393f, -39.57305f, -23.05361f,
        -24.09034f, -32.12758f, -33.57732f, -33.39095f, -28.73519f, -24.7897f,
        -31.97506f, -31.79913f, -39.6418f,  -34.87302f, -27.68829f, -29.11716f,
        -30.81506f, -29.67283f, -35.95022f, -28.59722f, -29.78435f, -26.97378f,
        -45.92195f, -34.99557f, -24.23533f, -28.47068f, -38.06516f, -31.42168f,
        -35.55739f, -37.09931f, -32.55295f, -38.20074f, -37.06677f, -39.72587f,
        -30.89476f, -25.08186f, -1.56716f,  33.86651f,  19.85716f,  -18.8103f,
        -32.33613f, -33.61828f, -34.03866f, -44.83046f, -39.11053f, -29.86028f,
        -38.42902f, -33.02311f, -42.7218f,  -37.94871f, -42.45908f, -43.46736f,
        -36.14531f, -38.24864f, -20.47455f, -19.29291f, -40.29852f, -40.8472f,
        -44.46055f, -44.80095f, -49.99406f, -43.21223f, -41.78769f, -44.78436f,
        -41.3723f,  -42.66779f, -47.36713f, -45.57813f, -46.45288f, -41.39572f,
        -41.89342f, -41.37815f, -35.18194f, -47.60094f, -42.19918f, -40.73451f,
        -45.91304f, -45.86631f, -24.60745f, -28.79864f, -38.73832f, -42.9434f,
        -36.05093f, -32.18958f, -35.44058f, -41.34708f, -46.41652f, -46.01289f,
        -40.15277f, -38.09269f, -41.34202f, -43.87149f, -43.49602f, -39.75299f,
        -44.61594f, -43.66012f, -46.72506f, -42.52509f, -37.12066f, -39.31185f,
        -43.75805f, -42.17318f, -52.53361f, -41.91204f, -43.65399f, -42.09334f,
        -40.60848f, -36.40095f, -44.03506f, -52.00204f, -44.35969f, -39.72857f,
        -42.62533f, -51.05286f, -46.61447f, -42.1597f,  -36.16274f, -46.47298f,
        -37.66808f, -35.44715f, -53.20711f, -54.62084f, -41.58973f, -42.06163f,
        -37.2656f,  -45.79028f, -37.82604f, -35.85235f, -38.46509f, -44.03185f,
        -43.26971f, -43.29342f, -42.38493f, -50.54574f, -41.60111f, -40.44766f,
        -49.76213f, -42.17174f, -40.32869f, -34.79422f, -48.02673f, -45.33436f,
        -43.79141f, -45.30027f, -37.31344f, -38.23837f, -53.93037f, -33.57379f,
        -35.17818f, -43.06915f, -38.70632f, -44.28445f, -36.20761f, -39.47888f,
        -43.12376f, -37.03499f, -44.16454f, -53.05626f, -42.33189f, -43.17476f,
        -37.54348f, -39.9759f,  -42.43349f, -48.06214f, -43.7779f,  -46.0745f,
        -44.87861f, -35.68887f, -36.41846f, -35.3899f,  -35.94836f, -35.56985f,
        -37.91615f, -41.67033f, -38.30199f, -41.06789f, -41.64373f, -43.95486f,
        -41.96013f, -42.76593f, -40.99801f, -43.62931f, -33.16311f, -39.26149f,
        -46.23984f, -45.48988f, -37.14768f, -39.47659f, -47.29124f, -42.46942f,
        -42.38224f, -44.82988f, -37.46356f, -40.14903f, -39.91003f, -34.83122f,
        -44.91535f, -41.17717f, -39.63206f, -47.03059f, -35.49366f, -24.67752f,
        -46.97864f, -45.51504f, -46.83727f, -37.79542f, -32.9388f,  -46.1204f,
        -36.24167f, -42.07196f, -33.78332f, -37.5643f};

static const int16_t input_q_init[CNN_TS_GEN_BASE_100_INT8_INPUT_LEN] = {
    119, 6,   -10, -15, -36, -18, -24, -41, -26, -25, -22, -29, -25, -27, -34,
    -25, -28, -29, -24, -43, -28, -31, -32, -33, -34, -31, -33, -42, -35, -59,
    -32, -30, -26, -26, -54, -32, -32, -31, -25, -17, 16,  0,   -23, -35, -25,
    -36, -28, -4,  -5,  -17, -19, -19, -12, -6,  -17, -16, -28, -21, -11, -13,
    -15, -13, -22, -12, -14, -10, -37, -21, -6,  -12, -25, -16, -22, -24, -18,
    -26, -24, -28, -15, -7,  27,  78,  58,  2,   -17, -19, -20, -35, -27, -14,
    -26, -18, -32, -25, -32, -33, -23, -26, 0,   1,   -29, -29, -35, -35, -43,
    -33, -31, -35, -30, -32, -39, -36, -38, -30, -31, -30, -21, -39, -31, -29,
    -37, -37, -6,  -12, -26, -33, -23, -17, -22, -30, -37, -37, -28, -26, -30,
    -34, -33, -28, -35, -34, -38, -32, -24, -27, -34, -31, -46, -31, -34, -31,
    -29, -23, -34, -46, -35, -28, -32, -44, -38, -31, -23, -38, -25, -22, -47,
    -49, -31, -31, -24, -37, -25, -22, -26, -34, -33, -33, -32, -43, -31, -29,
    -42, -31, -29, -21, -40, -36, -34, -36, -24, -26, -48, -19, -21, -33, -26,
    -34, -23, -28, -33, -24, -34, -47, -32, -33, -25, -28, -32, -40, -34, -37,
    -35, -22, -23, -22, -22, -22, -25, -31, -26, -30, -31, -34, -31, -32, -30,
    -33, -18, -27, -37, -36, -24, -28, -39, -32, -32, -35, -25, -28, -28, -21,
    -35, -30, -28, -38, -22, -6,  -38, -36, -38, -25, -18, -37, -23, -31, -19,
    -25};

static const int8_t conv1_weight[CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH] = {
    126, 125, -126, -68};

static const int32_t conv1_offset[CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH] = {
    453, -193, -37, 149};

static const uint32_t conv1_shift[CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH] = {
    6, 6, 6, 5};

static const int8_t conv2_weight[CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH *
                                 CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH *
                                 CNN_TS_GEN_BASE_100_INT8_CONV2_K] = {
    -55, -48, -3,   79,  58, -31, 16,   -5,  73, -6,   87,  14,
    31,  73,  -106, 81,  60, 4,   -27,  -61, 3,  -78,  15,  104,
    66,  16,  -27,  -65, 25, 66,  -105, -47, -3, -109, 4,   -81,
    -75, -90, -32,  3,   39, 45,  40,   -11, 37, 121,  -18, 45};

static const int32_t conv2_offset[CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH] = {
    -2825, -4032, 12475, 203};

static const uint32_t conv2_shift[CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH] = {
    6, 7, 7, 7};

static const int8_t fc_weight[CNN_TS_GEN_BASE_100_INT8_FC_IN *
                              CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {
    43, -124, 0, 18, -72, 89, 53, -74};

static const int32_t fc_offset[CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {-1146,
                                                                     2646};

static const uint32_t fc_shift[CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {7, 8};

static const int8_t golden_output[CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {68,
                                                                        -74};

static const float input_offset __attribute__((unused)) = 20.6774864f;
static const float input_mult __attribute__((unused)) = 184.0f;
static const float input_shift_mult __attribute__((unused)) = 0.0078125f;

static int16_t conv1_out[CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH *
                         CNN_TS_GEN_BASE_100_INT8_INPUT_LEN]
    __attribute__((aligned(128), section(".l2")));
static int16_t gap_out[CNN_TS_GEN_BASE_100_INT8_FC_IN]
    __attribute__((aligned(128), section(".l2")));
static int8_t output[CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH]
    __attribute__((aligned(128), section(".l2")));

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

static inline __attribute__((always_inline)) int16_t requant_i16(int32_t value, uint32_t shift, int32_t lo,
                           int32_t hi) {
  return (int16_t)clamp_i32(floor_div_pow2(value, shift), lo, hi);
}

static inline __attribute__((always_inline)) int8_t requant_i8(int32_t value, uint32_t shift) {
  return (int8_t)clamp_i32(floor_div_pow2(value, shift), -128, 127);
}

static inline __attribute__((always_inline)) void conv1x1_i8(int16_t *out, const int16_t *in) {
  for (uint64_t oc = 0; oc < CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH; ++oc) {
    for (uint64_t t = 0; t < CNN_TS_GEN_BASE_100_INT8_INPUT_LEN; ++t) {
      int32_t acc = (int32_t)in[t] * (int32_t)conv1_weight[oc];
      out[oc * CNN_TS_GEN_BASE_100_INT8_INPUT_LEN + t] =
          requant_i16(acc + conv1_offset[oc], conv1_shift[oc], 0, 255);
    }
  }
}

static inline __attribute__((always_inline)) void conv3x1_reduce_i8(int16_t *out, const int16_t *in) {
  for (uint64_t oc = 0; oc < CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH; ++oc) {
    int32_t sum = 0;
    for (uint64_t t = 0; t < CNN_TS_GEN_BASE_100_INT8_INPUT_LEN; ++t) {
      int32_t acc = 0;
      for (uint64_t ic = 0; ic < CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH; ++ic) {
        for (uint64_t k = 0; k < CNN_TS_GEN_BASE_100_INT8_CONV2_K; ++k) {
          int64_t it = (int64_t)t + (int64_t)k - 1;
          if (it >= 0 && it < CNN_TS_GEN_BASE_100_INT8_INPUT_LEN) {
            uint64_t w_idx = (oc * CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH + ic) *
                                 CNN_TS_GEN_BASE_100_INT8_CONV2_K +
                             k;
            acc +=
                (int32_t)
                    in[ic * CNN_TS_GEN_BASE_100_INT8_INPUT_LEN + (uint64_t)it] *
                (int32_t)conv2_weight[w_idx];
          }
        }
      }
      sum += requant_i16(acc + conv2_offset[oc], conv2_shift[oc], 0, 255);
    }
    out[oc] = requant_i16(sum + 128, 8, 0, 255);
  }
}

static inline __attribute__((always_inline)) void linear_i8(int8_t *out, const int16_t *in) {
  for (uint64_t o = 0; o < CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH; ++o) {
    int32_t acc = fc_offset[o];
    for (uint64_t i = 0; i < CNN_TS_GEN_BASE_100_INT8_FC_IN; ++i)
      acc += (int32_t)in[i] *
             (int32_t)fc_weight[i * CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH + o];
    out[o] = requant_i8(acc, fc_shift[o]);
  }
}

void cnn_ts_gen_base_100_int8(void) {
  conv1x1_i8(conv1_out, input_q_init);
  conv3x1_reduce_i8(gap_out, conv1_out);
  linear_i8(output, gap_out);
}

const int8_t *cnn_ts_gen_base_100_int8_output(void) { return output; }
const int8_t *cnn_ts_gen_base_100_int8_golden_output(void) {
  return golden_output;
}
