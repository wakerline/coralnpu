#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENSORLAB_ROOT="${TENSORLAB_ROOT:-/home/wangyy/001_research/ti/tinyml-tensorlab}"
MODELMAKER_ROOT="${MODELMAKER_ROOT:-${TENSORLAB_ROOT}/tinyml-modelmaker}"
TI_CONFIG="${TI_CONFIG:-${MODELMAKER_ROOT}/examples/dc_arc_fault/config_dsk.yaml}"
MODEL_NAME="${MODEL_NAME:-TimeSeries_Generic_1k_t}"
CONDA_ENV="${TRAIN_CONDA_ENV:-${CONDA_ENV:-ti}}"
RUN_NAME="${RUN_NAME:-}"

if [[ ! -d "${MODELMAKER_ROOT}" ]]; then
  echo "tinyml-modelmaker root not found: ${MODELMAKER_ROOT}" >&2
  exit 1
fi

if [[ ! -f "${TI_CONFIG}" ]]; then
  echo "TI modelmaker config not found: ${TI_CONFIG}" >&2
  exit 1
fi

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

mkdir -p "${SCRIPT_DIR}/generated/ti_modelmaker" \
  "${SCRIPT_DIR}/onnx/float" \
  "${SCRIPT_DIR}/onnx/quant" \
  "${SCRIPT_DIR}/golden_vectors"
cp "${TI_CONFIG}" "${SCRIPT_DIR}/generated/ti_modelmaker/config_dsk.yaml"

pushd "${MODELMAKER_ROOT}" >/dev/null
export PYTHONPATH=".:${PYTHONPATH:-}"
MODELMAKER_ARGS=("${TI_CONFIG}" --model_name "${MODEL_NAME}")
if [[ -n "${RUN_NAME}" ]]; then
  MODELMAKER_ARGS+=(--run_name "${RUN_NAME}")
fi
python tinyml_modelmaker/run_tinyml_modelmaker.py "${MODELMAKER_ARGS[@]}"
popd >/dev/null

LATEST_RUN_DIR="$(find "${MODELMAKER_ROOT}/data/projects/arc_fault_example_dsk/run" \
  -path "*/${MODEL_NAME}/training/base/model.onnx" \
  -printf "%T@ %h\n" | sort -nr | head -1 | cut -d' ' -f2-)"

if [[ -z "${LATEST_RUN_DIR}" ]]; then
  echo "Could not locate TI ModelMaker training/base/model.onnx output for ${MODEL_NAME}" >&2
  exit 1
fi

MODEL_ROOT="$(dirname "${LATEST_RUN_DIR}")"
cp "${MODEL_ROOT}/base/model.onnx" "${SCRIPT_DIR}/onnx/float/model.onnx"
cp "${MODEL_ROOT}/base/model_aux.h" "${SCRIPT_DIR}/onnx/float/model_aux.h"
cp "${MODEL_ROOT}/base/golden_vectors/test_vector.c" "${SCRIPT_DIR}/golden_vectors/float_test_vector.c"

if [[ -f "${MODEL_ROOT}/quantization/model.onnx" ]]; then
  cp "${MODEL_ROOT}/quantization/model.onnx" "${SCRIPT_DIR}/onnx/quant/model.onnx"
  cp "${MODEL_ROOT}/quantization/model_aux.h" "${SCRIPT_DIR}/onnx/quant/model_aux.h"
  cp "${MODEL_ROOT}/quantization/golden_vectors/test_vector.c" "${SCRIPT_DIR}/golden_vectors/quant_test_vector.c"
else
  echo "TI ModelMaker did not emit training/quantization/model.onnx." >&2
fi

echo "Imported TI ModelMaker outputs from ${MODEL_ROOT}"
