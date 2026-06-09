// Generated from training/quantization/model.onnx and
// golden_vectors/test_vector.c.
//
// SPDX-License-Identifier: Apache-2.0

#include <riscv_vector.h>
#include <stdint.h>

#include "rvv_cnn_ts_gen_base_100_int8.h"

static const int16_t input_q_init[RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN] = {
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

static const int8_t conv1_weight[RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH] = {
    126, 125, -126, -68};

static const int32_t conv1_offset[RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH] = {
    453, -193, -37, 149};

static const uint32_t conv1_shift[RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH] = {
    6, 6, 6, 5};

static const int8_t conv2_weight[RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH *
                                 RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH *
                                 RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_K] = {
    -55, -48, -3,   79,  58, -31, 16,   -5,  73, -6,   87,  14,
    31,  73,  -106, 81,  60, 4,   -27,  -61, 3,  -78,  15,  104,
    66,  16,  -27,  -65, 25, 66,  -105, -47, -3, -109, 4,   -81,
    -75, -90, -32,  3,   39, 45,  40,   -11, 37, 121,  -18, 45};

static const int32_t conv2_offset[RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH] = {
    -2825, -4032, 12475, 203};

static const uint32_t conv2_shift[RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH] = {
    6, 7, 7, 7};

static const int8_t fc_weight[RVV_CNN_TS_GEN_BASE_100_INT8_FC_IN *
                              RVV_CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {
    43, -124, 0, 18, -72, 89, 53, -74};

static const int32_t fc_offset[RVV_CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {-1146,
                                                                         2646};

static const uint32_t fc_shift[RVV_CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {7, 8};

static const int8_t golden_output[RVV_CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] = {
    68, -74};

static int16_t conv1_out[RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH *
                         RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN]
    __attribute__((aligned(128), section(".l2")));
static int16_t conv2_out[RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH *
                         RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN]
    __attribute__((aligned(128), section(".l2")));
static int16_t gap_out[RVV_CNN_TS_GEN_BASE_100_INT8_FC_IN]
    __attribute__((aligned(128), section(".l2")));
static int8_t output[8] __attribute__((aligned(128), section(".l2")));

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

static vint16m1_t requant_i16_vec(vint32m2_t value, uint32_t shift, int32_t lo,
                                  int32_t hi, size_t vl) {
  vint16m1_t narrowed = __riscv_vnsra_wx_i16m1(value, shift, vl);
  narrowed = __riscv_vmax_vx_i16m1(narrowed, lo, vl);
  return __riscv_vmin_vx_i16m1(narrowed, hi, vl);
}

static inline __attribute__((always_inline)) void conv1x1_i8(int16_t *out, const int16_t *in) {
  int16_t *out0 = out;
  int16_t *out1 = out + RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
  int16_t *out2 = out + 2 * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
  int16_t *out3 = out + 3 * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
  uint64_t avl = RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
  uint64_t t = 0;
  while (avl > 0) {
    size_t vl = __riscv_vsetvl_e16m1(avl);
    vint16m1_t vin = __riscv_vle16_v_i16m1(in + t, vl);
    vint32m2_t a0 = __riscv_vwmul_vx_i32m2(vin, conv1_weight[0], vl);
    vint32m2_t a1 = __riscv_vwmul_vx_i32m2(vin, conv1_weight[1], vl);
    vint32m2_t a2 = __riscv_vwmul_vx_i32m2(vin, conv1_weight[2], vl);
    vint32m2_t a3 = __riscv_vwmul_vx_i32m2(vin, conv1_weight[3], vl);
    a0 = __riscv_vadd_vx_i32m2(a0, conv1_offset[0], vl);
    a1 = __riscv_vadd_vx_i32m2(a1, conv1_offset[1], vl);
    a2 = __riscv_vadd_vx_i32m2(a2, conv1_offset[2], vl);
    a3 = __riscv_vadd_vx_i32m2(a3, conv1_offset[3], vl);
    __riscv_vse16_v_i16m1(out0 + t, requant_i16_vec(a0, conv1_shift[0], 0, 255, vl), vl);
    __riscv_vse16_v_i16m1(out1 + t, requant_i16_vec(a1, conv1_shift[1], 0, 255, vl), vl);
    __riscv_vse16_v_i16m1(out2 + t, requant_i16_vec(a2, conv1_shift[2], 0, 255, vl), vl);
    __riscv_vse16_v_i16m1(out3 + t, requant_i16_vec(a3, conv1_shift[3], 0, 255, vl), vl);
    t += vl;
    avl -= vl;
  }
}

static inline __attribute__((always_inline)) void conv3x1_i8(int16_t *out, const int16_t *in) {
  for (uint64_t oc = 0; oc < RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH; oc += 2) {
    const uint64_t oc1 = oc + 1;
    int16_t *out0 = out + oc * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
    int16_t *out1 = out + oc1 * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
    for (uint64_t edge = 0; edge < 2; ++edge) {
      uint64_t t = edge == 0 ? 0 : RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN - 1;
      int32_t acc0 = 0;
      int32_t acc1 = 0;
      for (uint64_t ic = 0; ic < RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH; ++ic) {
        for (uint64_t k = 0; k < RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_K; ++k) {
          int64_t it = (int64_t)t + (int64_t)k - 1;
          if (it >= 0 && it < RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN) {
            const int32_t x = in[ic * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN + (uint64_t)it];
            uint64_t w0 = (oc * RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH + ic) *
                          RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_K + k;
            uint64_t w1 = (oc1 * RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH + ic) *
                          RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_K + k;
            acc0 += x * (int32_t)conv2_weight[w0];
            acc1 += x * (int32_t)conv2_weight[w1];
          }
        }
      }
      out0[t] = requant_i16(acc0 + conv2_offset[oc], conv2_shift[oc], 0, 255);
      out1[t] = requant_i16(acc1 + conv2_offset[oc1], conv2_shift[oc1], 0, 255);
    }

    uint64_t avl = RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN - 2;
    uint64_t t = 1;
    while (avl > 0) {
      size_t vl = __riscv_vsetvl_e16m1(avl);
      vint32m2_t acc0 = __riscv_vmv_v_x_i32m2(0, vl);
      vint32m2_t acc1 = __riscv_vmv_v_x_i32m2(0, vl);
      for (uint64_t ic = 0; ic < RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH; ++ic) {
        const int16_t *in_ch = in + ic * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN + t;
        uint64_t wbase0 = (oc * RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH + ic) *
                          RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_K;
        uint64_t wbase1 = (oc1 * RVV_CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH + ic) *
                          RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_K;
        vint16m1_t left = __riscv_vle16_v_i16m1(in_ch - 1, vl);
        vint16m1_t mid = __riscv_vle16_v_i16m1(in_ch, vl);
        vint16m1_t right = __riscv_vle16_v_i16m1(in_ch + 1, vl);
        acc0 = __riscv_vwmacc_vx_i32m2(acc0, (int16_t)conv2_weight[wbase0 + 0], left, vl);
        acc1 = __riscv_vwmacc_vx_i32m2(acc1, (int16_t)conv2_weight[wbase1 + 0], left, vl);
        acc0 = __riscv_vwmacc_vx_i32m2(acc0, (int16_t)conv2_weight[wbase0 + 1], mid, vl);
        acc1 = __riscv_vwmacc_vx_i32m2(acc1, (int16_t)conv2_weight[wbase1 + 1], mid, vl);
        acc0 = __riscv_vwmacc_vx_i32m2(acc0, (int16_t)conv2_weight[wbase0 + 2], right, vl);
        acc1 = __riscv_vwmacc_vx_i32m2(acc1, (int16_t)conv2_weight[wbase1 + 2], right, vl);
      }
      acc0 = __riscv_vadd_vx_i32m2(acc0, conv2_offset[oc], vl);
      acc1 = __riscv_vadd_vx_i32m2(acc1, conv2_offset[oc1], vl);
      vint16m1_t vout0 = requant_i16_vec(acc0, conv2_shift[oc], 0, 255, vl);
      vint16m1_t vout1 = requant_i16_vec(acc1, conv2_shift[oc1], 0, 255, vl);
      __riscv_vse16_v_i16m1(out0 + t, vout0, vl);
      __riscv_vse16_v_i16m1(out1 + t, vout1, vl);
      t += vl;
      avl -= vl;
    }
  }
}

static void reduce_sum_requant(int16_t *out, const int16_t *in) {
  for (uint64_t c = 0; c < RVV_CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH; ++c) {
    const int16_t *p = in + c * RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
    size_t acc_vl = __riscv_vsetvl_e16m1(RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN);
    vint32m2_t vacc = __riscv_vmv_v_x_i32m2(0, acc_vl);
    uint64_t avl = RVV_CNN_TS_GEN_BASE_100_INT8_INPUT_LEN;
    while (avl > 0) {
      size_t vl = __riscv_vsetvl_e16m1(avl);
      vint16m1_t x = __riscv_vle16_v_i16m1(p, vl);
      vacc = __riscv_vwadd_wv_i32m2(vacc, x, vl);
      p += vl;
      avl -= vl;
    }
    vint32m1_t zero = __riscv_vmv_v_x_i32m1(0, 1);
    vint32m1_t reduced = __riscv_vredsum_vs_i32m2_i32m1(vacc, zero, acc_vl);
    int32_t sum = __riscv_vmv_x_s_i32m1_i32(reduced);
    out[c] = requant_i16(sum + 128, 8, 0, 255);
  }
}

static inline __attribute__((always_inline)) void linear_i8(int8_t *out, const int16_t *in) {
  for (uint64_t o = 0; o < RVV_CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH; ++o) {
    int32_t acc = fc_offset[o];
    for (uint64_t i = 0; i < RVV_CNN_TS_GEN_BASE_100_INT8_FC_IN; ++i)
      acc += (int32_t)in[i] *
             (int32_t)fc_weight[i * RVV_CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH + o];
    out[o] = requant_i8(acc, fc_shift[o]);
  }
}

void rvv_cnn_ts_gen_base_100_int8(void) {
  conv1x1_i8(conv1_out, input_q_init);
  conv3x1_i8(conv2_out, conv1_out);
  reduce_sum_requant(gap_out, conv2_out);
  linear_i8(output, gap_out);
}

const int8_t *rvv_cnn_ts_gen_base_100_int8_output(void) { return output; }
const int8_t *rvv_cnn_ts_gen_base_100_int8_golden_output(void) {
  return golden_output;
}
