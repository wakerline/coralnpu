#include "coral_rvv_fakequant_runtime.h"

#include <riscv_vector.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "sw/utils/utils.h"

namespace coralnpu_v2::tutorial::train_tvm_coralnpu {

namespace {

inline int32_t Clip(int32_t value, int32_t clip_min, int32_t clip_max) {
  return std::min(std::max(value, clip_min), clip_max);
}

inline int32_t FloorDivPow2(int32_t value, uint8_t shift_bits) {
  if (shift_bits == 0) {
    return value;
  }
  if (value >= 0) {
    return value >> shift_bits;
  }
  const int64_t numerator = static_cast<int64_t>(-value) + ((int64_t{1} << shift_bits) - 1);
  return -static_cast<int32_t>(numerator >> shift_bits);
}

inline int8_t StoreCentered(int32_t value, int32_t output_zero_point) {
  return static_cast<int8_t>(value - output_zero_point);
}

inline int32_t LoadCentered(int8_t value, int32_t input_zero_point) {
  return static_cast<int32_t>(value) + input_zero_point;
}

inline int32_t Requantize(
    int32_t acc,
    int32_t bias,
    uint8_t shift_bits,
    int32_t clip_min,
    int32_t clip_max) {
  return Clip(FloorDivPow2(acc + bias, shift_bits), clip_min, clip_max);
}

inline vint32m4_t RequantizeVector(
    vint32m4_t acc,
    int32_t bias,
    uint8_t shift_bits,
    int32_t clip_min,
    int32_t clip_max,
    int32_t output_zero_point,
    size_t vl) {
  acc = __riscv_vadd_vx_i32m4(acc, bias, vl);
  if (shift_bits != 0) {
    acc = __riscv_vsra_vx_i32m4(acc, shift_bits, vl);
  }
  acc = __riscv_vmax_vx_i32m4(acc, clip_min, vl);
  acc = __riscv_vmin_vx_i32m4(acc, clip_max, vl);
  if (output_zero_point != 0) {
    acc = __riscv_vadd_vx_i32m4(acc, -output_zero_point, vl);
  }
  return acc;
}

int32_t Conv3x1ScalarAt(
    const int8_t* input,
    const Conv3x1Spec& spec,
    int out_channel,
    int pos) {
  const int8_t* weights = spec.weights + out_channel * (spec.in_channels * 3);
  int32_t acc = 0;
  for (int ic = 0; ic < spec.in_channels; ++ic) {
    for (int k = 0; k < 3; ++k) {
      const int sample_pos = pos + k - 1;
      int32_t sample = 0;
      if (sample_pos >= 0 && sample_pos < spec.length) {
        sample = LoadCentered(input[ic * spec.length + sample_pos], spec.input_zero_point);
      }
      acc += sample * static_cast<int32_t>(weights[k * spec.in_channels + ic]);
    }
  }
  return acc;
}

}  // namespace

uint64_t ReadCycles() { return mcycle_read(); }

void QuantizeInput(const float* input, const InputQuantSpec& spec, int8_t* out) {
  for (int i = 0; i < spec.length; ++i) {
    float value = (input[i] + spec.add_offset) * spec.multiply * spec.shift_multiply;
    int32_t quantized = static_cast<int32_t>(std::floor(value));
    quantized = Clip(quantized, spec.clip_min, spec.clip_max);
    out[i] = static_cast<int8_t>(quantized);
  }
}

void Conv1x1PerChannel(const int8_t* input, const Conv1x1Spec& spec, int8_t* out) {
  alignas(16) int32_t accum0[16];
  alignas(16) int32_t accum1[16];
  alignas(16) int32_t accum2[16];
  alignas(16) int32_t accum3[16];
  if (spec.out_channels == 4) {
    int pos = 0;
    while (pos < spec.length) {
      size_t vl = __riscv_vsetvl_e8m1(spec.length - pos);
      vint8m1_t x8 = __riscv_vle8_v_i8m1(input + pos, vl);
      vint16m2_t x16 = __riscv_vsext_vf2_i16m2(x8, vl);
      if (spec.input_zero_point != 0) {
        x16 = __riscv_vadd_vx_i16m2(x16, spec.input_zero_point, vl);
      }
      vint32m4_t acc0 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc1 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc2 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc3 = __riscv_vmv_v_x_i32m4(0, vl);
      acc0 = __riscv_vwmacc_vx_i32m4(acc0, spec.weights[0], x16, vl);
      acc1 = __riscv_vwmacc_vx_i32m4(acc1, spec.weights[1], x16, vl);
      acc2 = __riscv_vwmacc_vx_i32m4(acc2, spec.weights[2], x16, vl);
      acc3 = __riscv_vwmacc_vx_i32m4(acc3, spec.weights[3], x16, vl);
      acc0 = RequantizeVector(
          acc0, spec.bias[0], spec.shift_bits[0], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      acc1 = RequantizeVector(
          acc1, spec.bias[1], spec.shift_bits[1], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      acc2 = RequantizeVector(
          acc2, spec.bias[2], spec.shift_bits[2], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      acc3 = RequantizeVector(
          acc3, spec.bias[3], spec.shift_bits[3], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      __riscv_vse32_v_i32m4(accum0, acc0, vl);
      __riscv_vse32_v_i32m4(accum1, acc1, vl);
      __riscv_vse32_v_i32m4(accum2, acc2, vl);
      __riscv_vse32_v_i32m4(accum3, acc3, vl);
      for (size_t lane = 0; lane < vl; ++lane) {
        const int index = pos + static_cast<int>(lane);
        out[index] = static_cast<int8_t>(accum0[lane]);
        out[spec.length + index] = static_cast<int8_t>(accum1[lane]);
        out[(2 * spec.length) + index] = static_cast<int8_t>(accum2[lane]);
        out[(3 * spec.length) + index] = static_cast<int8_t>(accum3[lane]);
      }
      pos += static_cast<int>(vl);
    }
    return;
  }

  alignas(16) int32_t accum[16];
  for (int oc = 0; oc < spec.out_channels; ++oc) {
    int pos = 0;
    while (pos < spec.length) {
      size_t vl = __riscv_vsetvl_e8m1(spec.length - pos);
      vint8m1_t x8 = __riscv_vle8_v_i8m1(input + pos, vl);
      vint16m2_t x16 = __riscv_vsext_vf2_i16m2(x8, vl);
      if (spec.input_zero_point != 0) {
        x16 = __riscv_vadd_vx_i16m2(x16, spec.input_zero_point, vl);
      }
      vint32m4_t acc = __riscv_vmv_v_x_i32m4(0, vl);
      acc = __riscv_vwmacc_vx_i32m4(acc, spec.weights[oc], x16, vl);
      __riscv_vse32_v_i32m4(accum, acc, vl);
      for (size_t lane = 0; lane < vl; ++lane) {
        int32_t value =
            Requantize(accum[lane], spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max);
        out[oc * spec.length + pos + static_cast<int>(lane)] =
            StoreCentered(value, spec.output_zero_point);
      }
      pos += static_cast<int>(vl);
    }
  }
}

void Conv3x1PerChannel(const int8_t* input, const Conv3x1Spec& spec, int8_t* out) {
  alignas(16) int32_t accum0[16];
  alignas(16) int32_t accum1[16];
  alignas(16) int32_t accum2[16];
  alignas(16) int32_t accum3[16];
  if (spec.out_channels == 4 && spec.in_channels == 4) {
    for (int oc = 0; oc < spec.out_channels; ++oc) {
      int32_t edge0 = Conv3x1ScalarAt(input, spec, oc, 0);
      int32_t edge1 = Conv3x1ScalarAt(input, spec, oc, spec.length - 1);
      out[oc * spec.length] = StoreCentered(
          Requantize(edge0, spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max),
          spec.output_zero_point);
      out[oc * spec.length + (spec.length - 1)] = StoreCentered(
          Requantize(edge1, spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max),
          spec.output_zero_point);
    }

    int pos = 1;
    while (pos < spec.length - 1) {
      size_t vl = __riscv_vsetvl_e8m1((spec.length - 1) - pos);
      vint32m4_t acc0 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc1 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc2 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc3 = __riscv_vmv_v_x_i32m4(0, vl);
      for (int ic = 0; ic < spec.in_channels; ++ic) {
        const int8_t* channel = input + ic * spec.length;
        for (int k = 0; k < 3; ++k) {
          vint8m1_t x8 = __riscv_vle8_v_i8m1(channel + pos + k - 1, vl);
          vint16m2_t x16 = __riscv_vsext_vf2_i16m2(x8, vl);
          if (spec.input_zero_point != 0) {
            x16 = __riscv_vadd_vx_i16m2(x16, spec.input_zero_point, vl);
          }
          const int weight_index = (k * spec.in_channels) + ic;
          acc0 = __riscv_vwmacc_vx_i32m4(acc0, spec.weights[weight_index], x16, vl);
          acc1 = __riscv_vwmacc_vx_i32m4(
              acc1, spec.weights[(spec.in_channels * 3) + weight_index], x16, vl);
          acc2 = __riscv_vwmacc_vx_i32m4(
              acc2, spec.weights[(2 * spec.in_channels * 3) + weight_index], x16, vl);
          acc3 = __riscv_vwmacc_vx_i32m4(
              acc3, spec.weights[(3 * spec.in_channels * 3) + weight_index], x16, vl);
        }
      }
      acc0 = RequantizeVector(
          acc0, spec.bias[0], spec.shift_bits[0], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      acc1 = RequantizeVector(
          acc1, spec.bias[1], spec.shift_bits[1], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      acc2 = RequantizeVector(
          acc2, spec.bias[2], spec.shift_bits[2], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      acc3 = RequantizeVector(
          acc3, spec.bias[3], spec.shift_bits[3], spec.clip_min, spec.clip_max, spec.output_zero_point, vl);
      __riscv_vse32_v_i32m4(accum0, acc0, vl);
      __riscv_vse32_v_i32m4(accum1, acc1, vl);
      __riscv_vse32_v_i32m4(accum2, acc2, vl);
      __riscv_vse32_v_i32m4(accum3, acc3, vl);
      for (size_t lane = 0; lane < vl; ++lane) {
        const int index = pos + static_cast<int>(lane);
        out[index] = static_cast<int8_t>(accum0[lane]);
        out[spec.length + index] = static_cast<int8_t>(accum1[lane]);
        out[(2 * spec.length) + index] = static_cast<int8_t>(accum2[lane]);
        out[(3 * spec.length) + index] = static_cast<int8_t>(accum3[lane]);
      }
      pos += static_cast<int>(vl);
    }
    return;
  }

  alignas(16) int32_t accum[16];
  for (int oc = 0; oc < spec.out_channels; ++oc) {
    int32_t edge0 = Conv3x1ScalarAt(input, spec, oc, 0);
    int32_t edge1 = Conv3x1ScalarAt(input, spec, oc, spec.length - 1);
    out[oc * spec.length] = StoreCentered(
        Requantize(edge0, spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max),
        spec.output_zero_point);

    int pos = 1;
    while (pos < spec.length - 1) {
      size_t vl = __riscv_vsetvl_e8m1((spec.length - 1) - pos);
      vint32m4_t acc = __riscv_vmv_v_x_i32m4(0, vl);
      for (int ic = 0; ic < spec.in_channels; ++ic) {
        const int8_t* channel = input + ic * spec.length;
        const int8_t* weights = spec.weights + oc * (spec.in_channels * 3);
        for (int k = 0; k < 3; ++k) {
          vint8m1_t x8 = __riscv_vle8_v_i8m1(channel + pos + k - 1, vl);
          vint16m2_t x16 = __riscv_vsext_vf2_i16m2(x8, vl);
          if (spec.input_zero_point != 0) {
            x16 = __riscv_vadd_vx_i16m2(x16, spec.input_zero_point, vl);
          }
          acc = __riscv_vwmacc_vx_i32m4(acc, weights[k * spec.in_channels + ic], x16, vl);
        }
      }
      __riscv_vse32_v_i32m4(accum, acc, vl);
      for (size_t lane = 0; lane < vl; ++lane) {
        int32_t value =
            Requantize(accum[lane], spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max);
        out[oc * spec.length + pos + static_cast<int>(lane)] =
            StoreCentered(value, spec.output_zero_point);
      }
      pos += static_cast<int>(vl);
    }

    out[oc * spec.length + (spec.length - 1)] = StoreCentered(
        Requantize(edge1, spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max),
        spec.output_zero_point);
  }
}

void ReduceSumAndAffine(const int8_t* input, const ReduceSpec& spec, uint8_t* out) {
  for (int c = 0; c < spec.channels; ++c) {
    int32_t sum = 0;
    const int8_t* channel = input + c * spec.length;
    for (int i = 0; i < spec.length; ++i) {
      sum += LoadCentered(channel[i], 128);
    }
    int32_t value = Requantize(sum, spec.add_offset, spec.shift_bits, spec.clip_min, spec.clip_max);
    out[c] = static_cast<uint8_t>(value);
  }
}

void DensePerTensor(const uint8_t* input, const DenseSpec& spec, int8_t* out) {
  for (int oc = 0; oc < spec.output_dim; ++oc) {
    int32_t acc = 0;
    for (int i = 0; i < spec.input_dim; ++i) {
      const int8_t weight = spec.weights[i * spec.output_dim + oc];
      acc += static_cast<int32_t>(input[i]) * static_cast<int32_t>(weight);
    }
    int32_t value = Requantize(acc, spec.bias[oc], spec.shift_bits[oc], spec.clip_min, spec.clip_max);
    out[oc] = static_cast<int8_t>(value);
  }
}

}  // namespace coralnpu_v2::tutorial::train_tvm_coralnpu
