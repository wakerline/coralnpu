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

#include <algorithm>
#include <cstdint>

#include "sw/utils/utils.h"

namespace {
constexpr int kInputDepth = 16;
constexpr int kHiddenDepth = 8;
constexpr int kOutputDepth = 4;

int8_t ClampInt8(int32_t value) {
  return static_cast<int8_t>(std::max<int32_t>(-128, std::min<int32_t>(127, value)));
}

int8_t Requantize(int32_t value, int32_t scale_divisor) {
  return ClampInt8(value / scale_divisor);
}

template <int kInputSize, int kOutputSize>
void FullyConnectedReference(const int8_t* input_data,
                             const int8_t* filter_data,
                             const int32_t* bias_data,
                             int8_t* output_data,
                             int32_t scale_divisor) {
  for (int out = 0; out < kOutputSize; ++out) {
    int32_t acc = bias_data[out];
    for (int in = 0; in < kInputSize; ++in) {
      acc += static_cast<int32_t>(input_data[in]) *
             static_cast<int32_t>(filter_data[out * kInputSize + in]);
    }
    output_data[out] = Requantize(acc, scale_divisor);
  }
}

void Relu(int8_t* data, int size) {
  for (int i = 0; i < size; ++i) {
    data[i] = std::max<int8_t>(data[i], 0);
  }
}
}  // namespace

extern "C" {
int32_t scale_divisor __attribute__((section(".data")));

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
  uint64_t start = mcycle_read();
  FullyConnectedReference<kInputDepth, kHiddenDepth>(
      input_data, fc1_filter_data, fc1_bias_data, hidden_data, scale_divisor);
  Relu(hidden_data, kHiddenDepth);
  FullyConnectedReference<kHiddenDepth, kOutputDepth>(
      hidden_data, fc2_filter_data, fc2_bias_data, output_data, scale_divisor);
  ref_cycles = mcycle_read() - start;
}

void run_optimized() {
  uint64_t start = mcycle_read();
  FullyConnectedReference<kInputDepth, kHiddenDepth>(
      input_data, fc1_filter_data, fc1_bias_data, hidden_data, scale_divisor);
  Relu(hidden_data, kHiddenDepth);
  FullyConnectedReference<kHiddenDepth, kOutputDepth>(
      hidden_data, fc2_filter_data, fc2_bias_data, output_data, scale_divisor);
  opt_cycles = mcycle_read() - start;
}

void (*impl)() __attribute__((section(".data"))) = run_optimized;

int main(void) {
  impl();
  return 0;
}
}
