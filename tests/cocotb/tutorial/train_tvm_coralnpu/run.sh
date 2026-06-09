#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORALNPU_ROOT="${CORALNPU_ROOT:-/home/wangyy/002_research/coralnpu}"
TVM_ROOT="${TVM_ROOT:-/home/wangyy/001_research/tvm_v18}"
TRAIN_CONDA_ENV="${TRAIN_CONDA_ENV:-ti}"
TVM_CONDA_ENV="${TVM_CONDA_ENV:-tvm_v18}"

usage() {
  cat <<'USAGE'
Usage:
  ./run.sh all [run.sh options] [-- stage args]
  ./run.sh train [run.sh options] [-- train args]
  ./run.sh modelmaker [run.sh options] [-- TI ModelMaker args]
  ./run.sh compile [run.sh options] [-- compile args]
  ./run.sh sim [run.sh options] [-- sim args]

run.sh options:
  --model-preset PRESET   Model preset: 100 or 1k
  --model-name NAME       Full TI ModelMaker model name, e.g. TimeSeries_Generic_1k_t
  --model-out-dir DIR     Artifact dir under this tutorial, e.g. generated/modelmaker_1k
  --prefer KIND           ModelMaker artifact to prefer: quantization or base
  --timeout-cycles N      RTL timeout for cocotb generated-model test

Environment:
  TRAIN_CONDA_ENV  Conda env for PyTorch/ONNX export. Default: ti
  TVM_CONDA_ENV    Conda env for TVM compilation. Default: tvm_v18
  TVM_ROOT         TVM source root. Default: /home/wangyy/001_research/tvm_v18
  CORALNPU_ROOT    CoralNPU checkout. Default: /home/wangyy/002_research/coralnpu
USAGE
}

has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

append_if_missing() {
  local flag="$1"
  local value="$2"
  shift 2
  if ! has_arg "${flag}" "$@"; then
    STAGE_ARGS+=("${flag}" "${value}")
  fi
}

load_conda() {
  set +u
  if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
  elif [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
  elif [[ -f "${HOME}/anaconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/anaconda3/etc/profile.d/conda.sh"
  else
    echo "conda is required for this workflow" >&2
    exit 1
  fi
  set -u
}

stage="${1:-}"
if [[ -z "${stage}" || "${stage}" == "-h" || "${stage}" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

MODEL_PRESET=""
MODEL_NAME=""
MODEL_OUT_DIR=""
MODEL_PREFER=""
SIM_TIMEOUT_CYCLES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-preset)
      MODEL_PRESET="${2:?missing value for --model-preset}"
      shift 2
      ;;
    --model-name)
      MODEL_NAME="${2:?missing value for --model-name}"
      shift 2
      ;;
    --model-out-dir)
      MODEL_OUT_DIR="${2:?missing value for --model-out-dir}"
      shift 2
      ;;
    --prefer)
      MODEL_PREFER="${2:?missing value for --prefer}"
      shift 2
      ;;
    --timeout-cycles)
      SIM_TIMEOUT_CYCLES="${2:?missing value for --timeout-cycles}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

case "${MODEL_PRESET}" in
  "")
    ;;
  100)
    : "${MODEL_NAME:=TimeSeries_Generic_100_t}"
    : "${MODEL_OUT_DIR:=generated/modelmaker}"
    : "${MODEL_PREFER:=quantization}"
    ;;
  1k)
    : "${MODEL_NAME:=TimeSeries_Generic_1k_t}"
    : "${MODEL_OUT_DIR:=generated/modelmaker_1k}"
    : "${MODEL_PREFER:=quantization}"
    ;;
  *)
    echo "Unsupported --model-preset: ${MODEL_PRESET}" >&2
    exit 2
    ;;
esac

STAGE_ARGS=("$@")

apply_modelmaker_defaults() {
  if [[ -n "${MODEL_NAME}" ]]; then
    append_if_missing "--model-name" "${MODEL_NAME}" "${STAGE_ARGS[@]}"
  fi
  if [[ -n "${MODEL_OUT_DIR}" ]]; then
    append_if_missing "--out-dir" "${MODEL_OUT_DIR}" "${STAGE_ARGS[@]}"
  fi
  if [[ -n "${MODEL_PREFER}" ]]; then
    append_if_missing "--prefer" "${MODEL_PREFER}" "${STAGE_ARGS[@]}"
  fi
}

apply_compile_defaults() {
  if [[ -n "${MODEL_OUT_DIR}" ]]; then
    append_if_missing "--model" "${MODEL_OUT_DIR}/model.onnx" "${STAGE_ARGS[@]}"
    append_if_missing "--sample" "${MODEL_OUT_DIR}/sample_io.npz" "${STAGE_ARGS[@]}"
    append_if_missing "--model-format" "onnx" "${STAGE_ARGS[@]}"
  fi
}

run_train() {
  load_conda
  conda activate "${TRAIN_CONDA_ENV}"
  PYTHONPATH="${SCRIPT_DIR}:${PYTHONPATH:-}" \
    python "${SCRIPT_DIR}/scripts/train_export_onnx.py" "$@"
}

run_compile() {
  load_conda
  conda activate "${TVM_CONDA_ENV}"
  PYTHONPATH="${TVM_ROOT}/python:${PYTHONPATH:-}" \
    python "${SCRIPT_DIR}/scripts/compile_tvm.py" --tvm-root "${TVM_ROOT}" "$@"
}

run_modelmaker() {
  load_conda
  conda activate "${TRAIN_CONDA_ENV}"
  apply_modelmaker_defaults
  PYTHONPATH="/home/wangyy/001_research/ti/tinyml-tensorlab/tinyml-modelmaker:${PYTHONPATH:-}" \
    python "${SCRIPT_DIR}/scripts/run_ti_modelmaker.py" "${STAGE_ARGS[@]}"
}

run_sim() {
  local cmd=(
    python "${SCRIPT_DIR}/scripts/sim_rvv_highmem.py"
    --coralnpu-root "${CORALNPU_ROOT}"
  )
  if [[ -n "${SIM_TIMEOUT_CYCLES}" ]]; then
    cmd+=(--timeout-cycles "${SIM_TIMEOUT_CYCLES}")
  fi
  cmd+=("${STAGE_ARGS[@]}")
  "${cmd[@]}"
}

case "${stage}" in
  train)
    run_train "${STAGE_ARGS[@]}"
    ;;
  modelmaker)
    run_modelmaker
    ;;
  compile)
    apply_compile_defaults
    run_compile "${STAGE_ARGS[@]}"
    ;;
  sim)
    run_sim
    ;;
  all)
    if [[ -n "${MODEL_NAME}" || -n "${MODEL_OUT_DIR}" || -n "${MODEL_PREFER}" ]]; then
      apply_modelmaker_defaults
      run_modelmaker
      STAGE_ARGS=()
      apply_compile_defaults
      STAGE_ARGS+=(--target rvv --codegen llvm-rvv)
      run_compile "${STAGE_ARGS[@]}"
      STAGE_ARGS=()
      run_sim
    else
      run_train "${STAGE_ARGS[@]}"
      run_compile --model generated/model.fp32.onnx --model-format onnx --target host
      run_sim
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
