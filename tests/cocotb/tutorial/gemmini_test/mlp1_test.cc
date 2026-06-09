#include <stddef.h>
#include <stdint.h>

#include "mlp1_data.h"

extern "C" {

// 控制/状态
volatile uint32_t status = 0;
volatile uint32_t cycles = 0;

// 入口函数指针槽：cocotb 会往这里写 run_ref / run_opt 的地址
volatile uintptr_t impl = 0;

// 形状信息（可选，方便后续扩展）
volatile uint32_t input_size = MLP1_IN_DIM;
volatile uint32_t hidden_size = MLP1_HIDDEN_DIM;
volatile uint32_t output_size = MLP1_OUT_DIM;

// 输入/权重/偏置/输出
alignas(16) int8_t input_data[MLP1_INPUT_SIZE];
alignas(16) int8_t weights_0[MLP1_W0_SIZE];
alignas(16) int32_t bias_0[MLP1_B0_SIZE];

alignas(16) int8_t hidden_data[MLP1_HIDDEN_DIM];

alignas(16) int8_t weights_1[MLP1_W1_SIZE];
alignas(16) int32_t bias_1[MLP1_B1_SIZE];

alignas(16) int8_t output_data[MLP1_OUTPUT_SIZE];

void run_ref();
void run_opt();
}

namespace {

static inline int8_t SatInt8(int32_t x) {
  if (x > 127) return 127;
  if (x < -128) return -128;
  return static_cast<int8_t>(x);
}

static void FullyConnected(
    const int8_t* input,
    const int8_t* weight,
    const int32_t* bias,
    int8_t* output,
    int in_dim,
    int out_dim,
    bool relu) {
  for (int o = 0; o < out_dim; ++o) {
    int32_t acc = bias ? bias[o] : 0;
    for (int i = 0; i < in_dim; ++i) {
      acc += static_cast<int32_t>(input[i]) *
             static_cast<int32_t>(weight[o * in_dim + i]);
    }
    if (relu && acc < 0) acc = 0;
    output[o] = SatInt8(acc);
  }
}

}  // namespace

extern "C" void run_ref() {
  status = 0;
  cycles = 0;

  FullyConnected(
      input_data,
      weights_0,
      bias_0,
      hidden_data,
      MLP1_IN_DIM,
      MLP1_HIDDEN_DIM,
      /*relu=*/true);

  FullyConnected(
      hidden_data,
      weights_1,
      bias_1,
      output_data,
      MLP1_HIDDEN_DIM,
      MLP1_OUT_DIM,
      /*relu=*/false);

  status = 1;
}

extern "C" void run_opt() {
  // 第一阶段先复用参考实现，先把入口切换/ELF/cocotb 路跑通
  run_ref();
}

int main() {
  status = 0;
  cycles = 0;

  using entry_fn_t = void (*)();

  if (impl != 0) {
    reinterpret_cast<entry_fn_t>(impl)();
  } else {
    run_ref();
  }

  return 0;
}