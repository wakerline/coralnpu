// Generated from training/base/model.onnx and golden_vectors/test_vector.c.
//
// SPDX-License-Identifier: Apache-2.0

#include <math.h>
#include <stdint.h>

#include "cnn_ts_gen_base_100.h"

static const float input[CNN_TS_GEN_BASE_100_INPUT_LEN] = {
    62.401f,    -16.8298f,  -25.74177f, -29.06075f, -35.98484f, -34.93666f,
    -39.86277f, -47.21265f, -45.72035f, -42.00366f, -40.74589f, -46.50341f,
    -44.64326f, -38.93894f, -37.26744f, -37.15226f, -47.35748f, -38.733f,
    -35.47284f, -42.98681f, -46.41013f, -34.31169f, -36.16649f, -40.52965f,
    -42.83549f, -43.52114f, -49.38081f, -42.05112f, -38.46977f, -48.67854f,
    -50.0226f,  -37.79711f, -42.62538f, -51.35846f, -41.42831f, -37.70721f,
    -38.16212f, -40.94509f, -38.66374f, -31.99173f, -5.68525f,  -16.70057f,
    -41.56294f, -39.17891f, -42.5677f,  -52.06409f, -44.62558f, -34.65514f,
    -20.60854f, -26.8026f,  -33.3611f,  -32.78099f, -34.51886f, -30.48566f,
    -21.17476f, -39.56922f, -31.34608f, -36.7699f,  -27.1579f,  -29.03361f,
    -30.45731f, -41.09315f, -40.94209f, -27.87967f, -25.08901f, -23.83533f,
    -19.08925f, -25.94698f, -27.70375f, -25.61339f, -35.14465f, -31.36435f,
    -38.93974f, -32.48412f, -35.40714f, -39.94679f, -33.69729f, -26.97363f,
    -31.14348f, -25.22417f, -1.86617f,  33.61106f,  19.59876f,  -19.13266f,
    -34.91121f, -38.15493f, -41.73987f, -45.06572f, -36.07053f, -33.76778f,
    -36.53106f, -40.11384f, -42.54525f, -41.00509f, -42.68184f, -37.5282f,
    -44.23491f, -41.31235f, -21.74336f, -18.82953f, -44.10083f, -45.4917f,
    -51.2521f,  -44.3514f,  -39.545f,   -37.65795f, -45.80119f, -45.76612f,
    -50.27196f, -43.6688f,  -45.59604f, -40.79634f, -39.60427f, -42.50239f,
    -38.05163f, -34.55683f, -38.71121f, -48.95049f, -43.9486f,  -41.32521f,
    -40.78787f, -40.236f,   -26.86186f, -41.19314f, -39.84297f, -37.80497f,
    -35.09292f, -32.17271f, -39.19514f, -38.4567f,  -43.68582f, -37.52511f,
    -46.77162f, -49.36292f, -42.53583f, -37.993f,   -44.31609f, -39.36327f,
    -43.81793f, -41.4463f,  -44.81101f, -38.06522f, -35.55544f, -36.19005f,
    -41.56467f, -46.39028f, -43.52416f, -39.84182f, -48.80027f, -44.12954f,
    -40.08447f, -43.81773f, -42.08279f, -42.49906f, -42.156f,   -34.0194f,
    -35.76618f, -37.8485f,  -41.58066f, -47.39361f, -43.2402f,  -31.29188f,
    -36.18055f, -36.16502f, -46.49256f, -46.06241f, -47.21326f, -39.29979f,
    -42.3671f,  -40.40448f, -37.55257f, -40.06887f, -48.91926f, -37.7207f,
    -46.97581f, -45.30804f, -43.96205f, -43.78742f, -41.99677f, -43.22562f,
    -47.31613f, -40.0272f,  -35.90044f, -39.60769f, -43.53564f, -51.5279f,
    -43.77048f, -39.38173f, -37.38592f, -42.17138f, -40.62964f, -36.24864f,
    -36.14519f, -40.17747f, -40.75797f, -45.53737f, -42.43708f, -41.85097f,
    -42.93471f, -38.97448f, -48.2168f,  -41.57532f, -56.35165f, -48.60902f,
    -38.57921f, -49.25028f, -46.0f,     -43.20602f, -41.93163f, -37.95707f,
    -37.70412f, -42.06585f, -41.46507f, -33.28157f, -31.68233f, -35.75881f,
    -39.40682f, -38.88776f, -36.49477f, -39.26462f, -44.575f,   -41.16656f,
    -46.57994f, -39.6181f,  -41.78556f, -48.62601f, -40.26388f, -41.0081f,
    -37.41832f, -41.2495f,  -45.6367f,  -34.8781f,  -38.41913f, -43.1186f,
    -44.0361f,  -40.15155f, -39.07704f, -39.99901f, -49.125f,   -46.10237f,
    -40.46542f, -43.80891f, -47.69695f, -36.00615f, -29.51554f, -21.73601f,
    -39.87917f, -36.28254f, -35.28069f, -45.58899f, -40.09543f, -39.4064f,
    -44.63426f, -38.00006f, -38.41741f, -43.90728f};

static const float bn_weight[1] __attribute__((unused)) = {0.998934925f};

static const float bn_bias[1] __attribute__((unused)) = {1.3181477e-09f};

static const float bn_running_mean[1] __attribute__((unused)) = {-20.8085194f};

static const float bn_running_var[1] __attribute__((unused)) = {490.120422f};

static const float bn_scale[1] __attribute__((unused)) = {0.0451217353f};

static const float conv1_weight[CNN_TS_GEN_BASE_100_CONV1_OUT_CH]
    __attribute__((unused)) = {0.981742144f, 0.972327471f, -0.980774164f,
                               -1.06133318f};

static const float conv1_bias[CNN_TS_GEN_BASE_100_CONV1_OUT_CH]
    __attribute__((unused)) = {0.102102987f, -0.0557702295f, -0.0199323054f,
                               0.0523947552f};

static const float conv1_fused_weight[CNN_TS_GEN_BASE_100_CONV1_OUT_CH] = {
    0.0442979092f, 0.0438731028f, -0.0442542322f, -0.0478891948f};

static const float conv1_fused_bias[CNN_TS_GEN_BASE_100_CONV1_OUT_CH] = {
    1.02387689f, 0.857164082f, -0.940797356f, -0.944108486f};

static const float conv2_weight[CNN_TS_GEN_BASE_100_CONV2_OUT_CH *
                                CNN_TS_GEN_BASE_100_CONV1_OUT_CH *
                                CNN_TS_GEN_BASE_100_CONV2_K] = {
    -0.868948162f,  -0.758172274f,  -0.0435598195f, 1.2385323f,
    0.91185075f,    -0.494415104f,  0.249307111f,   -0.0936086327f,
    1.14412725f,    -0.0957369879f, 1.36331809f,    0.204829648f,
    0.238127932f,   0.568355203f,   -0.8226524f,    0.632052481f,
    0.467767f,      0.0269644018f,  -0.213197827f,  -0.477799565f,
    0.0272607207f,  -0.602976441f,  0.117334008f,   0.811314285f,
    0.511224926f,   0.120081618f,   -0.216505229f,  -0.514010787f,
    0.186641738f,   0.507514596f,   -0.824679792f,  -0.366620213f,
    -0.0201943219f, -0.856631219f,  0.0296144336f,  -0.62979275f,
    -0.585128069f,  -0.701492786f,  -0.253221899f,  0.0197672229f,
    0.303924859f,   0.351540238f,   0.311918467f,   -0.0898870304f,
    0.288364649f,   0.942681611f,   -0.146945f,     0.350472182f};

static const float conv2_bias[CNN_TS_GEN_BASE_100_CONV2_OUT_CH] = {
    -0.716420114f, -0.499633372f, 1.50315475f, 0.0143293142f};

static const float
    fc_weight[CNN_TS_GEN_BASE_100_OUTPUT_CH * CNN_TS_GEN_BASE_100_FC_IN] = {
        0.677565217f, -0.00659020245f, -1.1273849f,  0.830585301f,
        -0.96919018f, 0.136846617f,    0.690473258f, -0.579433262f};

static const float fc_bias[CNN_TS_GEN_BASE_100_OUTPUT_CH] = {-0.295130789f,
                                                            0.307057142f};

static const float golden_output[CNN_TS_GEN_BASE_100_OUTPUT_CH] = {1.920814f,
                                                                  -2.080154f};

static float
    conv1_out[CNN_TS_GEN_BASE_100_CONV1_OUT_CH * CNN_TS_GEN_BASE_100_INPUT_LEN]
    __attribute__((aligned(128), section(".l2")));
static float gap_out[CNN_TS_GEN_BASE_100_FC_IN]
    __attribute__((aligned(128), section(".l2")));
static float output[CNN_TS_GEN_BASE_100_OUTPUT_CH]
    __attribute__((aligned(128), section(".l2")));

static inline __attribute__((always_inline)) void conv1x1(float *out, const float *in) {
  for (uint64_t oc = 0; oc < CNN_TS_GEN_BASE_100_CONV1_OUT_CH; ++oc) {
    for (uint64_t t = 0; t < CNN_TS_GEN_BASE_100_INPUT_LEN; ++t) {
      float value = in[t] * conv1_fused_weight[oc] + conv1_fused_bias[oc];
      out[oc * CNN_TS_GEN_BASE_100_INPUT_LEN + t] = value < 0.0f ? 0.0f : value;
    }
  }
}

static inline __attribute__((always_inline)) void conv3x1_same_gap(float *out, const float *in) {
  for (uint64_t oc = 0; oc < CNN_TS_GEN_BASE_100_CONV2_OUT_CH; ++oc) {
    float sum = 0.0f;
    for (uint64_t t = 0; t < CNN_TS_GEN_BASE_100_INPUT_LEN; ++t) {
      float acc = conv2_bias[oc];
      for (uint64_t ic = 0; ic < CNN_TS_GEN_BASE_100_CONV1_OUT_CH; ++ic) {
        for (uint64_t k = 0; k < CNN_TS_GEN_BASE_100_CONV2_K; ++k) {
          int64_t it = (int64_t)t + (int64_t)k - 1;
          if (it >= 0 && it < CNN_TS_GEN_BASE_100_INPUT_LEN) {
            uint64_t w_idx = (oc * CNN_TS_GEN_BASE_100_CONV1_OUT_CH + ic) *
                                 CNN_TS_GEN_BASE_100_CONV2_K +
                             k;
            acc += in[ic * CNN_TS_GEN_BASE_100_INPUT_LEN + (uint64_t)it] *
                   conv2_weight[w_idx];
          }
        }
      }
      sum += acc < 0.0f ? 0.0f : acc;
    }
    out[oc] = sum / (float)CNN_TS_GEN_BASE_100_INPUT_LEN;
  }
}

static inline __attribute__((always_inline)) void linear(float *out, const float *in) {
  for (uint64_t o = 0; o < CNN_TS_GEN_BASE_100_OUTPUT_CH; ++o) {
    float acc = fc_bias[o];
    for (uint64_t i = 0; i < CNN_TS_GEN_BASE_100_FC_IN; ++i)
      acc += in[i] * fc_weight[o * CNN_TS_GEN_BASE_100_FC_IN + i];
    out[o] = acc;
  }
}

void cnn_ts_gen_base_100(void) {
  conv1x1(conv1_out, input);
  conv3x1_same_gap(gap_out, conv1_out);
  linear(output, gap_out);
}

const float *cnn_ts_gen_base_100_output(void) { return output; }
const float *cnn_ts_gen_base_100_golden_output(void) { return golden_output; }
