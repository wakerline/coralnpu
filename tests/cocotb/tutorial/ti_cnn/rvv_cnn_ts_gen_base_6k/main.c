// Migrated from /home/wangyy/003_research/ara/apps/rvv_cnn_ts_gen_base_6k.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "../ti_cnn_perf.h"
#include "rvv_cnn_ts_gen_base_6k.h"

volatile uint32_t ti_cnn_status __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_cycles_lo __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_cycles_hi __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_macs __attribute__((section(".data"))) = 0;
volatile uint32_t ti_cnn_operations __attribute__((section(".data"))) = 0;
volatile float ti_cnn_performance __attribute__((section(".data"))) = 0.0f;
volatile float ti_cnn_utilization __attribute__((section(".data"))) = 0.0f;
volatile uint32_t ti_cnn_output_count __attribute__((section(".data"))) = RVV_CNN_TS_GEN_BASE_6K_OUTPUT_CH;
volatile float ti_cnn_output_f32[RVV_CNN_TS_GEN_BASE_6K_OUTPUT_CH] __attribute__((section(".data")));
volatile float ti_cnn_golden_f32[RVV_CNN_TS_GEN_BASE_6K_OUTPUT_CH] __attribute__((section(".data")));

static float abs_f32(float x) { return x < 0.0f ? -x : x; }


int main(void) {
  ti_cnn_status = 0;
  uint64_t start = ti_cnn_read_cycle64();
  rvv_cnn_ts_gen_base_6k();
  uint64_t end = ti_cnn_read_cycle64();
  uint64_t delta = end - start;
  ti_cnn_cycles_lo = (uint32_t)delta;
  ti_cnn_cycles_hi = (uint32_t)(delta >> 32);
  ti_cnn_record_perf(delta, (uint32_t)(RVV_CNN_TS_GEN_BASE_6K_MACS), &ti_cnn_macs,
                     &ti_cnn_operations, &ti_cnn_performance,
                     &ti_cnn_utilization);

  const float *got = rvv_cnn_ts_gen_base_6k_output();
  const float *golden = rvv_cnn_ts_gen_base_6k_golden_output();
  uint32_t error = 0;
  for (uint32_t i = 0; i < RVV_CNN_TS_GEN_BASE_6K_OUTPUT_CH; ++i) {
    ti_cnn_output_f32[i] = got[i];
    ti_cnn_golden_f32[i] = golden[i];
    if (abs_f32(got[i] - golden[i]) > 0.0005f)
      error = 1;
  }
  ti_cnn_status = error ? 2u : 1u;
  return error ? 1 : 0;
}
