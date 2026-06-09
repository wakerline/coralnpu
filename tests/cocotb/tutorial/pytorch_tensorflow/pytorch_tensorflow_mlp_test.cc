// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "sw/opt/litert-micro/fully_connected.h"

#include <algorithm>
#include <cstdint>

#include "sw/utils/utils.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/fully_connected.h"

namespace {
constexpr int kInputDepth = 16;
constexpr int kHiddenDepth = 8;
constexpr int kOutputDepth = 4;

tflite::FullyConnectedParams MakeParams(int32_t output_multiplier,
                                        int32_t output_shift) {
  return {
      .input_offset = 0,
      .weights_offset = 0,
      .output_offset = 0,
      .output_multiplier = output_multiplier,
      .output_shift = output_shift,
      .quantized_activation_min = -128,
      .quantized_activation_max = 127,
  };
}

void Relu(int8_t* data, int size) {
  for (int i = 0; i < size; ++i) {
    data[i] = std::max<int8_t>(data[i], 0);
  }
}
}  // namespace

extern "C" {
int32_t output_multiplier __attribute__((section(".data")));
int32_t output_shift __attribute__((section(".data")));

int32_t input_dims[4] __attribute__((section(".data")));
int32_t hidden_dims[4] __attribute__((section(".data")));
int32_t output_dims[4] __attribute__((section(".data")));
int32_t fc1_filter_dims[4] __attribute__((section(".data")));
int32_t fc1_bias_dims[1] __attribute__((section(".data")));
int32_t fc2_filter_dims[4] __attribute__((section(".data")));
int32_t fc2_bias_dims[1] __attribute__((section(".data")));

int8_t input_data[kInputDepth] __attribute__((section(".data"), aligned(16)));
int8_t fc1_filter_data[kHiddenDepth * kInputDepth]
    __attribute__((section(".data"), aligned(16)));
int32_t fc1_bias_data[kHiddenDepth]
    __attribute__((section(".data"), aligned(16)));
int8_t fc2_filter_data[kOutputDepth * kHiddenDepth]
    __attribute__((section(".data"), aligned(16)));
int32_t fc2_bias_data[kOutputDepth]
    __attribute__((section(".data"), aligned(16)));
int8_t hidden_data[kHiddenDepth] __attribute__((section(".data"), aligned(16)));
int8_t output_data[kOutputDepth] __attribute__((section(".data"), aligned(16)));

uint64_t ref_cycles __attribute__((section(".data")));
uint64_t opt_cycles __attribute__((section(".data")));

void run_ref() {
  const tflite::FullyConnectedParams params =
      MakeParams(output_multiplier, output_shift);
  uint64_t start = mcycle_read();
  tflite::reference_integer_ops::FullyConnected(
      params, tflite::RuntimeShape(4, input_dims), input_data,
      tflite::RuntimeShape(4, fc1_filter_dims), fc1_filter_data,
      tflite::RuntimeShape(1, fc1_bias_dims), fc1_bias_data,
      tflite::RuntimeShape(4, hidden_dims), hidden_data);
  Relu(hidden_data, kHiddenDepth);
  tflite::reference_integer_ops::FullyConnected(
      params, tflite::RuntimeShape(4, hidden_dims), hidden_data,
      tflite::RuntimeShape(4, fc2_filter_dims), fc2_filter_data,
      tflite::RuntimeShape(1, fc2_bias_dims), fc2_bias_data,
      tflite::RuntimeShape(4, output_dims), output_data);
  ref_cycles = mcycle_read() - start;
}

void run_optimized() {
  const tflite::FullyConnectedParams params =
      MakeParams(output_multiplier, output_shift);
  uint64_t start = mcycle_read();
  coralnpu_v2::opt::litert_micro::FullyConnected(
      params, tflite::RuntimeShape(4, input_dims), input_data,
      tflite::RuntimeShape(4, fc1_filter_dims), fc1_filter_data,
      tflite::RuntimeShape(1, fc1_bias_dims), fc1_bias_data,
      tflite::RuntimeShape(4, hidden_dims), hidden_data);
  Relu(hidden_data, kHiddenDepth);
  coralnpu_v2::opt::litert_micro::FullyConnected(
      params, tflite::RuntimeShape(4, hidden_dims), hidden_data,
      tflite::RuntimeShape(4, fc2_filter_dims), fc2_filter_data,
      tflite::RuntimeShape(1, fc2_bias_dims), fc2_bias_data,
      tflite::RuntimeShape(4, output_dims), output_data);
  opt_cycles = mcycle_read() - start;
}

void (*impl)() __attribute__((section(".data"))) = run_optimized;

int main(void) {
  impl();
  return 0;
}
}
