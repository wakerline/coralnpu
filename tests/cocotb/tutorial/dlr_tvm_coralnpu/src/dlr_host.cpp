#include <dlr.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <exception>
#include <string>
#include <vector>

#include "dlr_model_data.h"
#include "kernel.inc"

extern "C" unsigned int __atomic_fetch_add_4(volatile void *ptr, unsigned int val, int) {
  volatile unsigned int *typed = static_cast<volatile unsigned int *>(ptr);
  unsigned int old = *typed;
  *typed = old + val;
  return old;
}

extern "C" unsigned int __atomic_fetch_sub_4(volatile void *ptr, unsigned int val, int) {
  volatile unsigned int *typed = static_cast<volatile unsigned int *>(ptr);
  unsigned int old = *typed;
  *typed = old - val;
  return old;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    std::printf("Usage: %s <graph.json> <params.bin> <lib>\n", argv[0]);
    return 2;
  }

  dlr::DLR dlr;
  try {
    dlr.Build(argv[1], argv[2], argv[3], DLRBackend::kBAREMETAL);
    dlr.InitOp();
  } catch (const std::exception &e) {
    std::printf("DLR init failed: %s\n", e.what());
    return 3;
  }

  std::vector<int> input_shape = {1, 1, static_cast<int>(kDlrModelInputSize), 1};
  dlr.SetInputPtr(0, reinterpret_cast<char *>(kDlrModelInput), input_shape);
  dlr.Run();

  float max_abs_err = 0.0f;
  std::printf("DLR output:");
  if (kDlrOutputIsInt8) {
    signed char *output = reinterpret_cast<signed char *>(dlr.GetOutputPtr(0));
    for (size_t i = 0; i < kDlrGoldenOutputSize; ++i) {
      max_abs_err = std::max(
          max_abs_err,
          std::fabs(static_cast<float>(output[i] - kDlrGoldenOutputInt8[i])));
      std::printf(" %d", static_cast<int>(output[i]));
    }
    std::printf("\nGolden:");
    for (size_t i = 0; i < kDlrGoldenOutputSize; ++i) {
      std::printf(" %d", static_cast<int>(kDlrGoldenOutputInt8[i]));
    }
  } else {
    float *output = reinterpret_cast<float *>(dlr.GetOutputPtr(0));
    for (size_t i = 0; i < kDlrGoldenOutputSize; ++i) {
      max_abs_err = std::max(max_abs_err, std::fabs(output[i] - kDlrGoldenOutputFloat[i]));
      std::printf(" %.6f", output[i]);
    }
    std::printf("\nGolden:");
    for (size_t i = 0; i < kDlrGoldenOutputSize; ++i) {
      std::printf(" %.6f", kDlrGoldenOutputFloat[i]);
    }
  }
  std::printf("\nmax_abs_err=%.6f\n", max_abs_err);

  return max_abs_err < 1e-3f ? 0 : 1;
}
