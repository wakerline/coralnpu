// Generated from TI TimeSeries Generic model.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef CNN_TS_GEN_BASE_1K_H
#define CNN_TS_GEN_BASE_1K_H

#define CNN_TS_GEN_BASE_1K_INPUT_CH 1
#define CNN_TS_GEN_BASE_1K_INPUT_LEN 256
#define CNN_TS_GEN_BASE_1K_OUTPUT_CH 2
#define CNN_TS_GEN_BASE_1K_MAX_ACT 2048
#define CNN_TS_GEN_BASE_1K_FC_IN 64
#define CNN_TS_GEN_BASE_1K_MACS 140752
#define CNN_TS_GEN_BASE_1K_ONNX_INITIALIZER_VALUES 910
#define CNN_TS_GEN_BASE_1K_THRESHOLD 0.0001f

void cnn_ts_gen_base_1k(void);
const float *cnn_ts_gen_base_1k_output(void);
const float *cnn_ts_gen_base_1k_golden_output(void);

#endif
