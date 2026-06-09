// Generated from training/quantization/model.onnx and
// golden_vectors/test_vector.c.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef CNN_TS_GEN_BASE_100_INT8_H
#define CNN_TS_GEN_BASE_100_INT8_H

#include <stdint.h>

#define CNN_TS_GEN_BASE_100_INT8_INPUT_CH 1
#define CNN_TS_GEN_BASE_100_INT8_INPUT_LEN 256
#define CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH 4
#define CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH 4
#define CNN_TS_GEN_BASE_100_INT8_CONV1_K 1
#define CNN_TS_GEN_BASE_100_INT8_CONV2_K 3
#define CNN_TS_GEN_BASE_100_INT8_FC_IN 4
#define CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH 2
#define CNN_TS_GEN_BASE_100_INT8_ONNX_INITIALIZER_VALUES 99

void cnn_ts_gen_base_100_int8(void);
const int8_t *cnn_ts_gen_base_100_int8_output(void);
const int8_t *cnn_ts_gen_base_100_int8_golden_output(void);

#endif
