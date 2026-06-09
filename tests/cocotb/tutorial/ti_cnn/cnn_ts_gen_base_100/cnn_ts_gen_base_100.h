// Generated from training/base/model.onnx and golden_vectors/test_vector.c.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef CNN_TS_GEN_BASE_100_H
#define CNN_TS_GEN_BASE_100_H

#define CNN_TS_GEN_BASE_100_INPUT_CH 1
#define CNN_TS_GEN_BASE_100_INPUT_LEN 256
#define CNN_TS_GEN_BASE_100_CONV1_OUT_CH 4
#define CNN_TS_GEN_BASE_100_CONV2_OUT_CH 4
#define CNN_TS_GEN_BASE_100_CONV1_K 1
#define CNN_TS_GEN_BASE_100_CONV2_K 3
#define CNN_TS_GEN_BASE_100_FC_IN 4
#define CNN_TS_GEN_BASE_100_OUTPUT_CH 2
#define CNN_TS_GEN_BASE_100_ONNX_INITIALIZER_VALUES 74
#define CNN_TS_GEN_BASE_100_THRESHOLD 0.0001f

void cnn_ts_gen_base_100(void);
const float *cnn_ts_gen_base_100_output(void);
const float *cnn_ts_gen_base_100_golden_output(void);

#endif
