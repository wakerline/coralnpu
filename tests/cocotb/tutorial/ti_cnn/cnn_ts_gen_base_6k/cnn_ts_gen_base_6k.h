// Generated from TI TimeSeries Generic model.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef CNN_TS_GEN_BASE_6K_H
#define CNN_TS_GEN_BASE_6K_H

#define CNN_TS_GEN_BASE_6K_INPUT_CH 1
#define CNN_TS_GEN_BASE_6K_INPUT_LEN 256
#define CNN_TS_GEN_BASE_6K_OUTPUT_CH 2
#define CNN_TS_GEN_BASE_6K_MAX_ACT 1024
#define CNN_TS_GEN_BASE_6K_FC_IN 64
#define CNN_TS_GEN_BASE_6K_MACS 103952
#define CNN_TS_GEN_BASE_6K_ONNX_INITIALIZER_VALUES 6374
#define CNN_TS_GEN_BASE_6K_THRESHOLD 0.0001f

void cnn_ts_gen_base_6k(void);
const float *cnn_ts_gen_base_6k_output(void);
const float *cnn_ts_gen_base_6k_golden_output(void);

#endif
