#ifndef TESTS_COCOTB_TUTORIAL_TRAIN_TVM_CORALNPU_RUNTIME_CORAL_RVV_FAKEQUANT_RUNTIME_H_
#define TESTS_COCOTB_TUTORIAL_TRAIN_TVM_CORALNPU_RUNTIME_CORAL_RVV_FAKEQUANT_RUNTIME_H_

#include <cstddef>
#include <cstdint>

namespace coralnpu_v2::tutorial::train_tvm_coralnpu {

struct InputQuantSpec {
  int length;
  float add_offset;
  float multiply;
  float shift_multiply;
  int32_t clip_min;
  int32_t clip_max;
};

struct Conv1x1Spec {
  int length;
  int32_t input_zero_point;
  int32_t output_zero_point;
  int32_t clip_min;
  int32_t clip_max;
  int out_channels;
  const int8_t* weights;
  const int32_t* bias;
  const uint8_t* shift_bits;
};

struct Conv3x1Spec {
  int length;
  int32_t input_zero_point;
  int32_t output_zero_point;
  int32_t clip_min;
  int32_t clip_max;
  int in_channels;
  int out_channels;
  const int8_t* weights;
  const int32_t* bias;
  const uint8_t* shift_bits;
};

struct ReduceSpec {
  int length;
  int channels;
  int32_t add_offset;
  uint8_t shift_bits;
  int32_t clip_min;
  int32_t clip_max;
};

struct DenseSpec {
  int input_dim;
  int output_dim;
  int32_t clip_min;
  int32_t clip_max;
  const int8_t* weights;
  const int32_t* bias;
  const uint8_t* shift_bits;
};

uint64_t ReadCycles();

void QuantizeInput(const float* input, const InputQuantSpec& spec, int8_t* out);

void Conv1x1PerChannel(const int8_t* input, const Conv1x1Spec& spec, int8_t* out);

void Conv3x1PerChannel(const int8_t* input, const Conv3x1Spec& spec, int8_t* out);

void ReduceSumAndAffine(const int8_t* input, const ReduceSpec& spec, uint8_t* out);

void DensePerTensor(const uint8_t* input, const DenseSpec& spec, int8_t* out);

}  // namespace coralnpu_v2::tutorial::train_tvm_coralnpu

#endif  // TESTS_COCOTB_TUTORIAL_TRAIN_TVM_CORALNPU_RUNTIME_CORAL_RVV_FAKEQUANT_RUNTIME_H_
