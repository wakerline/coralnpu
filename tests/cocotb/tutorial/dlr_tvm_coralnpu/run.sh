#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORALNPU_ROOT="${CORALNPU_ROOT:-/home/wangyy/002_research/coralnpu}"
TVM_ROOT="${TVM_ROOT:-/home/wangyy/001_research/tvm_v18}"
DLR_DIR="${DLR_DIR:-/home/wangyy/001_research/001_riscv_tvm_gem5}"
TRAIN_CONDA_ENV="${TRAIN_CONDA_ENV:-ti}"
TVM_CONDA_ENV="${TVM_CONDA_ENV:-tvm_v18}"
MODEL_MODE="${MODEL_MODE:-quant}"

usage() {
  cat <<'USAGE'
Usage:
  ./run.sh train [-- TI ModelMaker args]
  ./run.sh prepare-sample
  ./run.sh compile-coral [-- compile_tvm.py args]
  ./run.sh compile-dlr [-- build_dlr_module.py args]
  ./run.sh build-dlr-elf
  ./run.sh cocotb [-- extra bazel args]
  ./run.sh all

Environment:
  MODEL_MODE       quant or float. Default: quant
  TVM_ROOT         TVM source root. Default: /home/wangyy/001_research/tvm_v18
  DLR_DIR          riscv_tvm_gem5/DLR checkout. Default: /home/wangyy/001_research/001_riscv_tvm_gem5
  CORALNPU_ROOT    CoralNPU checkout. Default: /home/wangyy/002_research/coralnpu
  TRAIN_CONDA_ENV  Conda env for TI ModelMaker. Default: ti
  TVM_CONDA_ENV    Conda env for TVM compilation. Default: tvm_v18
USAGE
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
    echo "conda is required; set the relevant env or install conda." >&2
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
if [[ "${1:-}" == "--" ]]; then
  shift
fi

case "${stage}" in
  train)
    TRAIN_CONDA_ENV="${TRAIN_CONDA_ENV}" "${SCRIPT_DIR}/train_quantize_ti_modelmaker.sh" "$@"
    ;;
  prepare-sample)
    python3 "${SCRIPT_DIR}/scripts/prepare_sample_io.py" --mode "${MODEL_MODE}"
    ;;
  compile-coral)
    load_conda
    conda activate "${TVM_CONDA_ENV}"
    "${SCRIPT_DIR}/scripts/compile_for_coralnpu.sh" "$@"
    ;;
  compile-dlr)
    load_conda
    conda activate "${TVM_CONDA_ENV}"
    PYTHONPATH="${TVM_ROOT}/python:${PYTHONPATH:-}" \
      python "${SCRIPT_DIR}/scripts/build_dlr_module.py" \
        --tvm-root "${TVM_ROOT}" \
        --mode "${MODEL_MODE}" \
        "$@"
    ;;
  build-dlr-elf)
    "${SCRIPT_DIR}/scripts/build_dlr_elf.sh"
    ;;
  cocotb)
    cd "${CORALNPU_ROOT}"
    bazel --batch test \
      //tests/cocotb/tutorial/dlr_tvm_coralnpu:cocotb_dlr_tvm_coralnpu_model \
      --test_output=streamed \
      --test_arg=--simulator=verilator \
      "$@"
    ;;
  all)
    "${SCRIPT_DIR}/run.sh" train
    "${SCRIPT_DIR}/run.sh" prepare-sample
    "${SCRIPT_DIR}/run.sh" compile-coral
    "${SCRIPT_DIR}/run.sh" compile-dlr
    "${SCRIPT_DIR}/run.sh" build-dlr-elf
    "${SCRIPT_DIR}/run.sh" cocotb
    ;;
  *)
    usage
    exit 2
    ;;
esac
