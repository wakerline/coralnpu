#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TVM_ROOT="${TVM_ROOT:-/home/wangyy/001_research/tvm_v18}"
CORAL_COMPILE_PY="${CORAL_COMPILE_PY:-/home/wangyy/002_research/coralnpu/tests/cocotb/tutorial/train_tvm_coralnpu/scripts/compile_tvm.py}"
MODEL_MODE="${MODEL_MODE:-quant}"
MODEL_PATH="${MODEL_PATH:-${ROOT}/onnx/${MODEL_MODE}/model.onnx}"
SAMPLE_PATH="${SAMPLE_PATH:-${ROOT}/generated/sample_io.npz}"
OUT_DIR="${OUT_DIR:-${ROOT}/generated/tvm}"

if [[ ! -f "${MODEL_PATH}" ]]; then
  echo "ONNX model not found: ${MODEL_PATH}" >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/prepare_sample_io.py" --mode "${MODEL_MODE}"

PYTHONPATH="${TVM_ROOT}/python:${PYTHONPATH:-}" \
  python "${CORAL_COMPILE_PY}" \
    --tvm-root "${TVM_ROOT}" \
    --model "${MODEL_PATH}" \
    --sample "${SAMPLE_PATH}" \
    --out-dir "${OUT_DIR}" \
    --target rvv \
    --codegen c \
    "$@"
