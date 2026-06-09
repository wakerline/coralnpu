// Generated from TI TimeSeries Generic model.
//
// SPDX-License-Identifier: Apache-2.0

#ifndef RVV_CNN_TS_GEN_BASE_13K_INT8_H
#define RVV_CNN_TS_GEN_BASE_13K_INT8_H

#include <stdint.h>

#define RVV_CNN_TS_GEN_BASE_13K_INT8_INPUT_CH 1
#define RVV_CNN_TS_GEN_BASE_13K_INT8_INPUT_LEN 256
#define RVV_CNN_TS_GEN_BASE_13K_INT8_OUTPUT_CH 2
#define RVV_CNN_TS_GEN_BASE_13K_INT8_MAX_ACT 1024
#define RVV_CNN_TS_GEN_BASE_13K_INT8_FC_IN 256
#define RVV_CNN_TS_GEN_BASE_13K_INT8_MACS 321872
#define RVV_CNN_TS_GEN_BASE_13K_INT8_ONNX_INITIALIZER_VALUES 12944

void rvv_cnn_ts_gen_base_13k_int8(void);
const int8_t *rvv_cnn_ts_gen_base_13k_int8_output(void);
const int8_t *rvv_cnn_ts_gen_base_13k_int8_golden_output(void);

#endif
