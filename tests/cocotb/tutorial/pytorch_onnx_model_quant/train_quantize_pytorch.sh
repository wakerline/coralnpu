#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_ENV="${CONDA_ENV:-ti}"
PYTHON_BIN="${PYTHON_BIN:-python}"
COMPILE_AFTER_TRAIN="${COMPILE_AFTER_TRAIN:-0}"

if [[ -n "${CONDA_ENV}" ]]; then
  export QT_XCB_GL_INTEGRATION="${QT_XCB_GL_INTEGRATION:-}"
  set +u
  if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
  elif [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
  elif [[ -f "${HOME}/anaconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/anaconda3/etc/profile.d/conda.sh"
  else
    echo "conda is not available; set CONDA_ENV= to skip activation." >&2
    exit 1
  fi
  conda activate "${CONDA_ENV}"
  set -u
fi

"${PYTHON_BIN}" "${SCRIPT_DIR}/train_quantize_pytorch.py" "$@"

if [[ "${COMPILE_AFTER_TRAIN}" == "1" ]]; then
  MODEL_MODE=quant "${SCRIPT_DIR}/compile_onnx_tvm_for_coralnpu.sh"
fi
