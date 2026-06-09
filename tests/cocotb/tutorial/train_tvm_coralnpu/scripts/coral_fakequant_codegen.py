from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
import onnx
from onnx import numpy_helper


def _scalar(array: np.ndarray) -> float:
    return float(np.asarray(array).reshape(-1)[0])


def _flatten_i8(array: np.ndarray) -> list[int]:
    out = np.rint(array).astype(np.int32).reshape(-1)
    if np.any(out < -128) or np.any(out > 127):
        raise ValueError("expected int8-range tensor")
    return [int(x) for x in out]


def _flatten_i32(array: np.ndarray) -> list[int]:
    out = np.rint(array).astype(np.int64).reshape(-1)
    if np.any(out < np.iinfo(np.int32).min) or np.any(out > np.iinfo(np.int32).max):
        raise ValueError("expected int32-range tensor")
    return [int(x) for x in out]


def _scale_to_shift_bits(scale: float) -> int:
    if scale <= 0.0:
        raise ValueError(f"scale must be positive, got {scale}")
    shift = int(round(-math.log2(scale)))
    if not math.isclose(scale, 2.0 ** (-shift), rel_tol=0.0, abs_tol=1e-9):
        raise ValueError(f"scale {scale} is not an exact power-of-two reciprocal")
    return shift


def _c_array(items: list[int], ctype: str, name: str) -> str:
    body = ", ".join(str(x) for x in items)
    return f"static const {ctype} {name}[{len(items)}] = {{{body}}};\n"


@dataclass(frozen=True)
class InputQuantSpec:
    length: int
    add_offset: float
    multiply: float
    shift_multiply: float
    clip_min: int
    clip_max: int


@dataclass(frozen=True)
class Conv1x1Spec:
    length: int
    input_zero_point: int
    output_zero_point: int
    clip_min: int
    clip_max: int
    out_channels: int
    weights: list[int]
    bias: list[int]
    shift_bits: list[int]


@dataclass(frozen=True)
class Conv3x1Spec:
    length: int
    input_zero_point: int
    output_zero_point: int
    clip_min: int
    clip_max: int
    in_channels: int
    out_channels: int
    weights: list[int]
    bias: list[int]
    shift_bits: list[int]


@dataclass(frozen=True)
class ReduceSpec:
    length: int
    channels: int
    add_offset: int
    shift_bits: int
    clip_min: int
    clip_max: int


@dataclass(frozen=True)
class DenseSpec:
    input_dim: int
    output_dim: int
    clip_min: int
    clip_max: int
    weights: list[int]
    bias: list[int]
    shift_bits: list[int]


@dataclass(frozen=True)
class CoralArcFaultSpec:
    input_name: str
    input_quant: InputQuantSpec
    conv1: Conv1x1Spec
    conv2: Conv3x1Spec
    reduce: ReduceSpec
    dense: DenseSpec


def extract_coral_arc_fault_spec(model_path: Path) -> CoralArcFaultSpec:
    model = onnx.load(str(model_path))
    init = {x.name: numpy_helper.to_array(x) for x in model.graph.initializer}
    nodes = list(model.graph.node)

    if len(nodes) != 33:
        raise ValueError(f"expected 33 nodes, found {len(nodes)}")

    input_name = nodes[0].input[0]
    input_spec = InputQuantSpec(
        length=256,
        add_offset=_scalar(init["oss_1.offset"]),
        multiply=_scalar(init["oss_1.mult"]),
        shift_multiply=_scalar(init["oss_1.shift_mult"]),
        clip_min=int(round(_scalar(init["/oss_1/Constant_output_0"]))),
        clip_max=int(round(_scalar(init["/oss_1/Constant_1_output_0"]))),
    )

    conv1_weights = init["model.features.1.0.0.weight"]
    conv1_bias = init["model.features.1.0.1.offset"]
    conv1_scale = init["model.features.1.0.1.mult"] * init["model.features.1.0.1.shift_mult"]
    conv1 = Conv1x1Spec(
        length=256,
        input_zero_point=0,
        output_zero_point=128,
        clip_min=0,
        clip_max=int(round(_scalar(init["/features.1.0/features.1.0.1/Constant_1_output_0"]))),
        out_channels=int(conv1_weights.shape[0]),
        weights=_flatten_i8(conv1_weights),
        bias=_flatten_i32(conv1_bias),
        shift_bits=[_scale_to_shift_bits(float(x)) for x in conv1_scale.reshape(-1)],
    )

    conv2_weights = init["model.features.2.0.0.weight"]
    conv2_bias = init["model.features.2.0.1.offset"]
    conv2_scale = init["model.features.1.0.1.mult"] * init["model.features.2.0.1.shift_mult"]
    conv2 = Conv3x1Spec(
        length=256,
        input_zero_point=128,
        output_zero_point=128,
        clip_min=0,
        clip_max=int(round(_scalar(init["/features.1.0/features.1.0.1/Constant_1_output_0"]))),
        in_channels=int(conv2_weights.shape[1]),
        out_channels=int(conv2_weights.shape[0]),
        weights=_flatten_i8(np.transpose(conv2_weights, (0, 2, 3, 1))),
        bias=_flatten_i32(conv2_bias),
        shift_bits=[_scale_to_shift_bits(float(x)) for x in conv2_scale.reshape(-1)],
    )

    reduce_scale = _scalar(init["/features.3/Reshape_1_output_0"]) * _scalar(
        init["/features.3/Reshape_2_output_0"]
    )
    reduce = ReduceSpec(
        length=256,
        channels=4,
        add_offset=int(round(_scalar(init["/features.3/Reshape_output_0"]))),
        shift_bits=_scale_to_shift_bits(reduce_scale),
        clip_min=0,
        clip_max=int(round(_scalar(init["/features.1.0/features.1.0.1/Constant_1_output_0"]))),
    )

    dense_scale = init["model.features.5.1.mult"] * init["model.features.5.1.shift_mult"]
    dense = DenseSpec(
        input_dim=int(init["onnx::MatMul_140"].shape[0]),
        output_dim=int(init["onnx::MatMul_140"].shape[1]),
        clip_min=int(round(_scalar(init["/oss_1/Constant_output_0"]))),
        clip_max=int(round(_scalar(init["/oss_1/Constant_1_output_0"]))),
        weights=_flatten_i8(init["onnx::MatMul_140"]),
        bias=_flatten_i32(init["model.features.5.1.offset"]),
        shift_bits=[_scale_to_shift_bits(float(x)) for x in dense_scale.reshape(-1)],
    )

    return CoralArcFaultSpec(
        input_name=input_name,
        input_quant=input_spec,
        conv1=conv1,
        conv2=conv2,
        reduce=reduce,
        dense=dense,
    )


def write_spec_json(path: Path, spec: CoralArcFaultSpec) -> None:
    path.write_text(json.dumps(asdict(spec), indent=2) + "\n", encoding="utf-8")


def emit_coral_arc_fault_wrapper(
    out_dir: Path,
    spec: CoralArcFaultSpec,
    sample: np.ndarray,
    golden: np.ndarray,
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    cc_path = out_dir / "coral_baremetal_main.cc"

    input_size = int(np.asarray(sample).size)
    output_size = int(np.asarray(golden).size)

    source = f"""#include <cstdint>

#include "runtime/coral_rvv_fakequant_runtime.h"

namespace runtime = coralnpu_v2::tutorial::train_tvm_coralnpu;

{_c_array(spec.conv1.weights, "int8_t", "kConv1Weights")}
{_c_array(spec.conv1.bias, "int32_t", "kConv1Bias")}
{_c_array(spec.conv1.shift_bits, "uint8_t", "kConv1ShiftBits")}
{_c_array(spec.conv2.weights, "int8_t", "kConv2Weights")}
{_c_array(spec.conv2.bias, "int32_t", "kConv2Bias")}
{_c_array(spec.conv2.shift_bits, "uint8_t", "kConv2ShiftBits")}
{_c_array(spec.dense.weights, "int8_t", "kDenseWeights")}
{_c_array(spec.dense.bias, "int32_t", "kDenseBias")}
{_c_array(spec.dense.shift_bits, "uint8_t", "kDenseShiftBits")}

static const runtime::InputQuantSpec kInputQuant = {{
    {spec.input_quant.length},
    {spec.input_quant.add_offset:.9f}f,
    {spec.input_quant.multiply:.9f}f,
    {spec.input_quant.shift_multiply:.9f}f,
    {spec.input_quant.clip_min},
    {spec.input_quant.clip_max},
}};

static const runtime::Conv1x1Spec kConv1 = {{
    {spec.conv1.length},
    {spec.conv1.input_zero_point},
    {spec.conv1.output_zero_point},
    {spec.conv1.clip_min},
    {spec.conv1.clip_max},
    {spec.conv1.out_channels},
    kConv1Weights,
    kConv1Bias,
    kConv1ShiftBits,
}};

static const runtime::Conv3x1Spec kConv2 = {{
    {spec.conv2.length},
    {spec.conv2.input_zero_point},
    {spec.conv2.output_zero_point},
    {spec.conv2.clip_min},
    {spec.conv2.clip_max},
    {spec.conv2.in_channels},
    {spec.conv2.out_channels},
    kConv2Weights,
    kConv2Bias,
    kConv2ShiftBits,
}};

static const runtime::ReduceSpec kReduce = {{
    {spec.reduce.length},
    {spec.reduce.channels},
    {spec.reduce.add_offset},
    {spec.reduce.shift_bits},
    {spec.reduce.clip_min},
    {spec.reduce.clip_max},
}};

static const runtime::DenseSpec kDense = {{
    {spec.dense.input_dim},
    {spec.dense.output_dim},
    {spec.dense.clip_min},
    {spec.dense.clip_max},
    kDenseWeights,
    kDenseBias,
    kDenseShiftBits,
}};

extern "C" {{
float model_input[{input_size}] __attribute__((section(".data"), aligned(16))) = {{0}};
float model_output[{output_size}] __attribute__((section(".data"), aligned(16))) = {{0}};
volatile int32_t model_status __attribute__((section(".data"))) = 0;
volatile uint32_t model_cycles __attribute__((section(".data"))) = 0;
}}

alignas(16) static int8_t g_input_quant[{spec.input_quant.length}];
alignas(16) static int8_t g_conv1_out[{spec.conv1.length * spec.conv1.out_channels}];
alignas(16) static int8_t g_conv2_out[{spec.conv2.length * spec.conv2.out_channels}];
static uint8_t g_pooled[{spec.reduce.channels}];
static int8_t g_dense_out[{spec.dense.output_dim}];

extern "C" void CoralNPUModelRun() {{
  model_status = 10;
  const uint64_t start_cycles = runtime::ReadCycles();
  runtime::QuantizeInput(model_input, kInputQuant, g_input_quant);
  runtime::Conv1x1PerChannel(g_input_quant, kConv1, g_conv1_out);
  runtime::Conv3x1PerChannel(g_conv1_out, kConv2, g_conv2_out);
  runtime::ReduceSumAndAffine(g_conv2_out, kReduce, g_pooled);
  runtime::DensePerTensor(g_pooled, kDense, g_dense_out);
  for (int i = 0; i < {spec.dense.output_dim}; ++i) {{
    model_output[i] = static_cast<float>(g_dense_out[i]);
  }}
  model_cycles = static_cast<uint32_t>(runtime::ReadCycles() - start_cycles);
  model_status = 1;
}}

int main() {{
  CoralNPUModelRun();
  return 0;
}}
"""
    cc_path.write_text(source, encoding="utf-8")
    return cc_path
