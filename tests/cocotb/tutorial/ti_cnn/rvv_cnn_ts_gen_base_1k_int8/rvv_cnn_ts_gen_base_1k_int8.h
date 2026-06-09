// Generated from TI TimeSeries Generic model.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef RVV_CNN_TS_GEN_BASE_1K_INT8_H
#define RVV_CNN_TS_GEN_BASE_1K_INT8_H

#include <stdint.h>

#define RVV_CNN_TS_GEN_BASE_1K_INT8_INPUT_CH 1
#define RVV_CNN_TS_GEN_BASE_1K_INT8_INPUT_LEN 256
#define RVV_CNN_TS_GEN_BASE_1K_INT8_OUTPUT_CH 2
#define RVV_CNN_TS_GEN_BASE_1K_INT8_MAX_ACT 2048
#define RVV_CNN_TS_GEN_BASE_1K_INT8_FC_IN 64
#define RVV_CNN_TS_GEN_BASE_1K_INT8_MACS 140752
#define RVV_CNN_TS_GEN_BASE_1K_INT8_ONNX_INITIALIZER_VALUES 976

void rvv_cnn_ts_gen_base_1k_int8(void);
const int8_t *rvv_cnn_ts_gen_base_1k_int8_output(void);
const int8_t *rvv_cnn_ts_gen_base_1k_int8_golden_output(void);

#endif
