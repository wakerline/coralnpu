#include <cstdint>

extern "C" volatile uint32_t tvm_coralnpu_input[16];
extern "C" volatile uint32_t tvm_coralnpu_output[16];
extern "C" volatile uint32_t tvm_coralnpu_done;

volatile uint32_t tvm_coralnpu_input[16]
    __attribute__((section(".data"), aligned(16))) = {0};
volatile uint32_t tvm_coralnpu_output[16]
    __attribute__((section(".data"), aligned(16))) = {0};
volatile uint32_t tvm_coralnpu_done __attribute__((section(".data"))) = 0;

int main() {
  uint32_t acc = 0;
  for (int i = 0; i < 16; ++i) {
    acc += tvm_coralnpu_input[i];
    tvm_coralnpu_output[i] = tvm_coralnpu_input[i] + 1;
  }
  tvm_coralnpu_output[0] = acc;
  tvm_coralnpu_done = 1;
  return 0;
}
