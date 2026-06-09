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

#include <cstdint>

#include "sw/utils/utils.h"
#include "tests/cocotb/tutorial/ti_onnx_model_quant/model_abi.h"
#include "tests/cocotb/tutorial/ti_onnx_model_quant/tvmgen_default.h"

extern "C" {
#if defined(TI_ONNX_MODEL_FLOAT)
using ModelValue = float;
#else
using ModelValue = int8_t;
#endif

ModelValue model_input[256] __attribute__((section(".data"), aligned(16)));
ModelValue model_output[2] __attribute__((section(".data"), aligned(16)));
ModelValue golden_output[2] __attribute__((section(".data"), aligned(16)));

int32_t inference_status __attribute__((section(".data")));
uint64_t inference_cycles __attribute__((section(".data")));

__attribute__((used, retain)) void run_model() {
  tvmgen_default_inputs inputs = {
      .TVMGEN_DEFAULT_INPUT_FIELD = model_input,
  };
  tvmgen_default_outputs outputs = {
      .output = model_output,
  };

  uint64_t start = mcycle_read();
  inference_status = tvmgen_default_run(&inputs, &outputs);
  inference_cycles = mcycle_read() - start;
}

int main(void) {
  run_model();
  return 0;
}
}
