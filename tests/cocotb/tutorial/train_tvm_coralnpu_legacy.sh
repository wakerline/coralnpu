#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORALNPU_ROOT="${CORALNPU_ROOT:-$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)}"
WORKFLOW_DIR="${WORKFLOW_DIR:-${SCRIPT_DIR}/pytorch_onnx_model_quant}"

TRAIN_CONDA_ENV="${TRAIN_CONDA_ENV:-ti}"
COMPILE_CONDA_ENV="${COMPILE_CONDA_ENV:-tvm_v18}"
TVM_SOURCE_ROOT="${TVM_SOURCE_ROOT:-/home/wangyy/001_research/tvm_v18}"
TVM_PYTHON_PACKAGE_DIR="${TVM_PYTHON_PACKAGE_DIR:-/home/wangyy/001_research/tvm_v18/python/tvm}"
TVM_SIM_VENV="${TVM_SIM_VENV:-/home/wangyy/001_research/virtualenv/tvm18-py3_10/bin/activate}"

MODEL_MODE="quant"
RUN_TRAIN=1
RUN_COMPILE=1
RUN_SIM=1
SIMULATOR=""
TRAIN_ARGS=()

usage() {
  cat <<'EOF'
Usage: train_tvm_coralnpu [options] [-- train_args...]

Options:
  --mode <quant|float>     Select ONNX/TVM/simulation mode. Default: quant
  --train-only             Run only PyTorch training + ONNX export
  --compile-only           Run only TVM compilation
  --sim-only               Run only CoralNPU cocotb simulation
  --skip-train             Skip training stage
  --skip-compile           Skip compilation stage
  --skip-sim               Skip simulation stage
  --simulator <name>       Forward Bazel --test_arg=--simulator=<name>
  -h, --help               Show this help

Environment overrides:
  TRAIN_CONDA_ENV          Conda env for PyTorch export, default: ti
  COMPILE_CONDA_ENV        Conda env for TVM compilation, default: tvm_v18
  TVM_SOURCE_ROOT          TVM source tree, default: /home/wangyy/001_research/tvm_v18
  TVM_PYTHON_PACKAGE_DIR   Extra TVM python path, default: /home/wangyy/001_research/tvm_v18/python/tvm
  TVM_SIM_VENV             Virtualenv for cocotb simulation, default:
                           /home/wangyy/001_research/virtualenv/tvm18-py3_10/bin/activate
  WORKFLOW_DIR             ONNX/TVM example directory, default:
                           tests/cocotb/tutorial/pytorch_onnx_model_quant
EOF
}

load_conda() {
  export QT_XCB_GL_INTEGRATION="${QT_XCB_GL_INTEGRATION:-}"
  set +u
  if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
  elif [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
  elif [[ -f "${HOME}/anaconda3/etc/profile.d/conda.sh" ]]; then
    source "${HOME}/anaconda3/etc/profile.d/conda.sh"
  else
    echo "conda is not available; cannot activate requested environments." >&2
    exit 1
  fi
  set -u
}

ensure_paths() {
  if [[ ! -d "${WORKFLOW_DIR}" ]]; then
    echo "Workflow directory not found: ${WORKFLOW_DIR}" >&2
    exit 1
  fi

  if [[ ! -d "${TVM_SOURCE_ROOT}" ]]; then
    echo "TVM source root not found: ${TVM_SOURCE_ROOT}" >&2
    exit 1
  fi

  if [[ ! -d "${TVM_SOURCE_ROOT}/python" ]]; then
    echo "TVM python directory not found: ${TVM_SOURCE_ROOT}/python" >&2
    exit 1
  fi

  if [[ ! -d "${TVM_PYTHON_PACKAGE_DIR}" ]]; then
    echo "TVM python package directory not found: ${TVM_PYTHON_PACKAGE_DIR}" >&2
    exit 1
  fi

  if [[ "${RUN_SIM}" == "1" && ! -f "${TVM_SIM_VENV}" ]]; then
    echo "Simulation virtualenv activation script not found: ${TVM_SIM_VENV}" >&2
    exit 1
  fi
}

train_model() {
  echo "[train] Exporting ${MODEL_MODE} ONNX from PyTorch in conda env ${TRAIN_CONDA_ENV}"
  (
    load_conda
    conda activate "${TRAIN_CONDA_ENV}"
    cd "${WORKFLOW_DIR}"
    python "${WORKFLOW_DIR}/train_quantize_pytorch.py" "${TRAIN_ARGS[@]}"
  )
}

compile_model() {
  local model_path output_dir log_dir bazel_output_base toolchain_dir cross_compiler
  local cross_compiler_options tvm_target tvm_target_c_mcpu input_field bias_value
  local scale_value shift_value

  model_path="${WORKFLOW_DIR}/onnx/${MODEL_MODE}/model.onnx"
  output_dir="${WORKFLOW_DIR}/generated/tvm_rv32_${MODEL_MODE}"
  log_dir="${WORKFLOW_DIR}/logs"

  if [[ ! -f "${model_path}" ]]; then
    echo "ONNX model not found: ${model_path}" >&2
    exit 1
  fi

  bazel_output_base="$(cd "${CORALNPU_ROOT}" && bazel --batch info output_base)"
  toolchain_dir="${CORALNPU_RV32_TOOLCHAIN_DIR:-${bazel_output_base}/external/toolchain_coralnpu_v2/bin}"
  cross_compiler="${CROSS_COMPILER:-${toolchain_dir}/riscv32-unknown-elf-gcc}"
  cross_compiler_options="${CROSS_COMPILER_OPTIONS:-"-O3 -v -march=rv32imf_zve32x_zicsr -mabi=ilp32 -I. -Iartifacts"}"
  tvm_target_c_mcpu="${TVM_TARGET_C_MCPU:-rootbed}"

  if [[ "${MODEL_MODE}" == "quant" ]]; then
    tvm_target="${TVM_TARGET:-c, rootbed-npu type=soft skip_normalize=true output_int=true}"
  else
    tvm_target="${TVM_TARGET:-c, rootbed-npu type=soft skip_normalize=false output_int=false}"
  fi

  mkdir -p "${output_dir}" "${log_dir}"

  if [[ ! -x "${cross_compiler}" ]]; then
    echo "Coral NPU RV32 cross compiler not found: ${cross_compiler}" >&2
    exit 1
  fi

  echo "[compile] Building TVM artifacts for ${MODEL_MODE} in conda env ${COMPILE_CONDA_ENV}"
  (
    load_conda
    conda activate "${COMPILE_CONDA_ENV}"
    export TVM_HOME="${TVM_SOURCE_ROOT}"
    export PYTHONPATH="${TVM_SOURCE_ROOT}/python:${TVM_PYTHON_PACKAGE_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
    if [[ -d "${TVM_SOURCE_ROOT}/build" ]]; then
      export TVM_LIBRARY_PATH="${TVM_SOURCE_ROOT}/build"
      export LD_LIBRARY_PATH="${TVM_SOURCE_ROOT}/build${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    fi
    cd "${WORKFLOW_DIR}"
    python "${WORKFLOW_DIR}/compilation/tinyml_benchmark.py" \
      --model_path "${model_path}" \
      --compilation_path "${output_dir}" \
      --cross_compiler "${cross_compiler}" \
      --cross_compiler_options "${cross_compiler_options}" \
      --target "${tvm_target}" \
      --target_c_mcpu "${tvm_target_c_mcpu}" \
      --keep_libc_files \
      --log_file "${log_dir}/tvm_compile.log"
  )

  cp "${output_dir}/artifacts/mod.a" "${WORKFLOW_DIR}/mod.a"
  cp "${output_dir}/artifacts/tvmgen_default.h" "${WORKFLOW_DIR}/tvmgen_default.h"

  input_field="$(awk '
    /struct tvmgen_default_inputs/ { in_inputs = 1; next }
    in_inputs && /};/ { exit }
    in_inputs && /void\*/ { gsub(";", "", $2); print $2; exit }
  ' "${WORKFLOW_DIR}/tvmgen_default.h")"

  bias_value="$(sed -n 's/.*tvmgen_default_bias_data.*{\([^}]*\)}.*/\1/p' "${WORKFLOW_DIR}/tvmgen_default.h" | cut -d',' -f1 | xargs || true)"
  scale_value="$(sed -n 's/.*tvmgen_default_scale_data.*{\([^}]*\)}.*/\1/p' "${WORKFLOW_DIR}/tvmgen_default.h" | cut -d',' -f1 | xargs || true)"
  shift_value="$(sed -n 's/.*tvmgen_default_shift_data.*{\([^}]*\)}.*/\1/p' "${WORKFLOW_DIR}/tvmgen_default.h" | cut -d',' -f1 | xargs || true)"

  if [[ -z "${input_field}" ]]; then
    echo "Could not derive TVM input field from ${WORKFLOW_DIR}/tvmgen_default.h" >&2
    exit 1
  fi

  cat >"${WORKFLOW_DIR}/model_abi.h" <<EOF
#ifndef TESTS_COCOTB_TUTORIAL_PYTORCH_ONNX_MODEL_QUANT_MODEL_ABI_H_
#define TESTS_COCOTB_TUTORIAL_PYTORCH_ONNX_MODEL_QUANT_MODEL_ABI_H_
#define TVMGEN_DEFAULT_INPUT_FIELD ${input_field}
#endif
EOF

  cat >"${WORKFLOW_DIR}/model_abi.py" <<EOF
# Generated by train_tvm_coralnpu
INPUT_FIELD = "${input_field}"
BIAS = ${bias_value:-None}
SCALE = ${scale_value:-None}
SHIFT = ${shift_value:-None}
EOF

  echo "[compile] Updated ${WORKFLOW_DIR}/mod.a and ${WORKFLOW_DIR}/tvmgen_default.h"
}

run_simulation() {
  local binary_target test_target

  if [[ "${MODEL_MODE}" == "quant" ]]; then
    binary_target="//tests/cocotb/tutorial/pytorch_onnx_model_quant:pytorch_onnx_model_quant_test.elf"
    test_target="//tests/cocotb/tutorial/pytorch_onnx_model_quant:cocotb_pytorch_onnx_model_quant_test_pytorch_onnx_model_quant"
  else
    binary_target="//tests/cocotb/tutorial/pytorch_onnx_model_quant:pytorch_onnx_model_float_test.elf"
    test_target="//tests/cocotb/tutorial/pytorch_onnx_model_quant:cocotb_pytorch_onnx_model_float_test_pytorch_onnx_model_quant"
  fi

  echo "[sim] Running ${test_target} on RvvCoreMiniHighmemAxi with ${TVM_SIM_VENV}"
  (
    set +u
    source "${TVM_SIM_VENV}"
    set -u
    export TVM_HOME="${TVM_SOURCE_ROOT}"
    export PYTHONPATH="${TVM_SOURCE_ROOT}/python:${TVM_PYTHON_PACKAGE_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
    if [[ -d "${TVM_SOURCE_ROOT}/build" ]]; then
      export TVM_LIBRARY_PATH="${TVM_SOURCE_ROOT}/build"
      export LD_LIBRARY_PATH="${TVM_SOURCE_ROOT}/build${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    fi
    cd "${CORALNPU_ROOT}"
    bazel --batch build "${binary_target}"
    if [[ -n "${SIMULATOR}" ]]; then
      bazel --batch test --test_output=all "${test_target}" --test_arg="--simulator=${SIMULATOR}"
    else
      bazel --batch test --test_output=all "${test_target}"
    fi
  )
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODEL_MODE="${2:-}"
      shift 2
      ;;
    --train-only)
      RUN_TRAIN=1
      RUN_COMPILE=0
      RUN_SIM=0
      shift
      ;;
    --compile-only)
      RUN_TRAIN=0
      RUN_COMPILE=1
      RUN_SIM=0
      shift
      ;;
    --sim-only)
      RUN_TRAIN=0
      RUN_COMPILE=0
      RUN_SIM=1
      shift
      ;;
    --skip-train)
      RUN_TRAIN=0
      shift
      ;;
    --skip-compile)
      RUN_COMPILE=0
      shift
      ;;
    --skip-sim)
      RUN_SIM=0
      shift
      ;;
    --simulator)
      SIMULATOR="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      TRAIN_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${MODEL_MODE}" != "quant" && "${MODEL_MODE}" != "float" ]]; then
  echo "--mode must be either quant or float, got: ${MODEL_MODE}" >&2
  exit 1
fi

if [[ "${RUN_TRAIN}" == "0" && "${RUN_COMPILE}" == "0" && "${RUN_SIM}" == "0" ]]; then
  echo "Nothing to do. Enable at least one stage." >&2
  exit 1
fi

ensure_paths

echo "[info] Workflow directory: ${WORKFLOW_DIR}"
echo "[info] Model mode: ${MODEL_MODE}"
echo "[info] Stages: train=${RUN_TRAIN} compile=${RUN_COMPILE} sim=${RUN_SIM}"

if [[ "${RUN_TRAIN}" == "1" ]]; then
  train_model
fi

if [[ "${RUN_COMPILE}" == "1" ]]; then
  compile_model
fi

if [[ "${RUN_SIM}" == "1" ]]; then
  run_simulation
fi
