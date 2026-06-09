// Shared performance helpers for TI CNN cocotb examples.
// SPDX-License-Identifier: Apache-2.0

#ifndef TI_CNN_PERF_H_
#define TI_CNN_PERF_H_

#include <stdint.h>

#ifndef TI_CNN_CORALNPU_PEAK_OPS_PER_CYCLE
#define TI_CNN_CORALNPU_PEAK_OPS_PER_CYCLE 8.0f
#endif

#define TI_CNN_CONV3_SAME_MACS(out_ch, in_ch, len, k)                          \
  ((out_ch) * (in_ch) * (((len) - 2) * (k) + 4))

static inline uint64_t ti_cnn_read_cycle64(void) {
  uint32_t hi0, lo, hi1;
  do {
    __asm__ volatile("csrr %0, mcycleh" : "=r"(hi0));
    __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
    __asm__ volatile("csrr %0, mcycleh" : "=r"(hi1));
  } while (hi0 != hi1);
  return ((uint64_t)hi0 << 32) | lo;
}

static inline void ti_cnn_record_perf(
    uint64_t cycles, uint32_t macs, volatile uint32_t *macs_out,
    volatile uint32_t *operations_out, volatile float *performance_out,
    volatile float *utilization_out) {
  const uint32_t operations = 2u * macs;
  *macs_out = macs;
  *operations_out = operations;
  if (cycles == 0) {
    *performance_out = 0.0f;
    *utilization_out = 0.0f;
    return;
  }
  const float performance = (float)operations / (float)cycles;
  *performance_out = performance;
  *utilization_out = 100.0f * performance / TI_CNN_CORALNPU_PEAK_OPS_PER_CYCLE;
}

#endif  // TI_CNN_PERF_H_
