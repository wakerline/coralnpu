// Migrated from /home/wangyy/003_research/ara/apps/cnn_ts_gen_base_100_int8.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "../ti_cnn_perf.h"
#include "cnn_ts_gen_base_100_int8.h"

volatile uint32_t ti_cnn_status __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_cycles_lo __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_cycles_hi __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_macs __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_operations __attribute__((section(".data"))) = 0;
volatile float ti_cnn_performance __attribute__((section(".data"))) = 0.0f;
volatile float ti_cnn_utilization __attribute__((section(".data"))) = 0.0f;
volatile uint32_t ti_cnn_output_count __attribute__((section(".data"))) = CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH;
volatile int8_t ti_cnn_output_i8[CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] __attribute__((section(".data")));
volatile int8_t ti_cnn_golden_i8[CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH] __attribute__((section(".data")));


int main(void) {
  ti_cnn_status = 0;
  uint64_t start = ti_cnn_read_cycle64();
  cnn_ts_gen_base_100_int8();
  uint64_t end = ti_cnn_read_cycle64();
  uint64_t delta = end - start;
  ti_cnn_cycles_lo = (uint32_t)delta;
  ti_cnn_cycles_hi = (uint32_t)(delta >> 32);
  ti_cnn_record_perf(delta, (uint32_t)(CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH * CNN_TS_GEN_BASE_100_INT8_INPUT_LEN + TI_CNN_CONV3_SAME_MACS(CNN_TS_GEN_BASE_100_INT8_CONV2_OUT_CH, CNN_TS_GEN_BASE_100_INT8_CONV1_OUT_CH, CNN_TS_GEN_BASE_100_INT8_INPUT_LEN, CNN_TS_GEN_BASE_100_INT8_CONV2_K) + CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH * CNN_TS_GEN_BASE_100_INT8_FC_IN), &ti_cnn_macs,
                     &ti_cnn_operations, &ti_cnn_performance,
                     &ti_cnn_utilization);

  const int8_t *got = cnn_ts_gen_base_100_int8_output();
  const int8_t *golden = cnn_ts_gen_base_100_int8_golden_output();
  uint32_t error = 0;
  for (uint32_t i = 0; i < CNN_TS_GEN_BASE_100_INT8_OUTPUT_CH; ++i) {
    ti_cnn_output_i8[i] = got[i];
    ti_cnn_golden_i8[i] = golden[i];
    if (got[i] != golden[i])
      error = 1;
  }
  ti_cnn_status = error ? 2u : 1u;
  return error ? 1 : 0;
}
