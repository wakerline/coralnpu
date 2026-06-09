// Generated from TI TimeSeries Generic model.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef CNN_TS_GEN_BASE_4K_H
#define CNN_TS_GEN_BASE_4K_H

#define CNN_TS_GEN_BASE_4K_INPUT_CH 1
#define CNN_TS_GEN_BASE_4K_INPUT_LEN 256
#define CNN_TS_GEN_BASE_4K_OUTPUT_CH 2
#define CNN_TS_GEN_BASE_4K_MAX_ACT 1024
#define CNN_TS_GEN_BASE_4K_FC_IN 128
#define CNN_TS_GEN_BASE_4K_MACS 66896
#define CNN_TS_GEN_BASE_4K_ONNX_INITIALIZER_VALUES 3574
#define CNN_TS_GEN_BASE_4K_THRESHOLD 0.0001f

void cnn_ts_gen_base_4k(void);
const float *cnn_ts_gen_base_4k_output(void);
const float *cnn_ts_gen_base_4k_golden_output(void);

#endif
