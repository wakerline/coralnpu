// Generated from TI TimeSeries Generic model.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef CNN_TS_GEN_BASE_13K_H
#define CNN_TS_GEN_BASE_13K_H

#define CNN_TS_GEN_BASE_13K_INPUT_CH 1
#define CNN_TS_GEN_BASE_13K_INPUT_LEN 256
#define CNN_TS_GEN_BASE_13K_OUTPUT_CH 2
#define CNN_TS_GEN_BASE_13K_MAX_ACT 1024
#define CNN_TS_GEN_BASE_13K_FC_IN 256
#define CNN_TS_GEN_BASE_13K_MACS 321872
#define CNN_TS_GEN_BASE_13K_ONNX_INITIALIZER_VALUES 12646
#define CNN_TS_GEN_BASE_13K_THRESHOLD 0.0001f

void cnn_ts_gen_base_13k(void);
const float *cnn_ts_gen_base_13k_output(void);
const float *cnn_ts_gen_base_13k_golden_output(void);

#endif
