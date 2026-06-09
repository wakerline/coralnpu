#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORALNPU_ROOT="${CORALNPU_ROOT:-$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)}"

MODEL_MODE="${1:-${MODEL_MODE:-quant}}"
if [[ "${MODEL_MODE}" != "quant" && "${MODEL_MODE}" != "float" ]]; then
  echo "Usage: $0 [quant|float]" >&2
  exit 1
fi

MODEL_MODE="${MODEL_MODE}" "${SCRIPT_DIR}/compile_onnx_tvm_for_coralnpu.sh"

cd "${CORALNPU_ROOT}"

if [[ "${MODEL_MODE}" == "quant" ]]; then
  BINARY_TARGET="//tests/cocotb/tutorial/pytorch_onnx_model_quant:pytorch_onnx_model_quant_test.elf"
  TEST_TARGET="//tests/cocotb/tutorial/pytorch_onnx_model_quant:cocotb_pytorch_onnx_model_quant_test_pytorch_onnx_model_quant"
else
  BINARY_TARGET="//tests/cocotb/tutorial/pytorch_onnx_model_quant:pytorch_onnx_model_float_test.elf"
  TEST_TARGET="//tests/cocotb/tutorial/pytorch_onnx_model_quant:cocotb_pytorch_onnx_model_float_test_pytorch_onnx_model_quant"
fi

bazel --batch build \
  "${BINARY_TARGET}"

bazel --batch test --test_output=all \
  "${TEST_TARGET}"
