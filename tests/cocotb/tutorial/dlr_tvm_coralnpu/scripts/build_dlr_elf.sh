#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DLR_DIR="${DLR_DIR:-/home/wangyy/001_research/001_riscv_tvm_gem5}"
MODEL_NAME="${MODEL_NAME:-dlr_ti_model}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/${MODEL_NAME}.output}"
LOG_DIR="${LOG_DIR:-${ROOT}/logs}"
CORALNPU_TOOLCHAIN_DIR="${CORALNPU_TOOLCHAIN_DIR:-/home/wangyy/.cache/bazel/_bazel_wangyy/f5fc6ae1de374dadc178c2e803fe3ac1/external/toolchain_coralnpu_v2/bin}"
RISCV_INSTALL_DIR="${RISCV_INSTALL_DIR:-${DLR_DIR}/install-riscv-coralnpu-rv32}"
KERNEL_DUMP="${KERNEL_DUMP:-${DLR_DIR}/install-x86/bin/DumpKernel}"
RISCV_ISA="${RISCV_ISA:-rv32imf_zve32x_zicsr_zifencei_zbb}"
RISCV_ABI="${RISCV_ABI:-ilp32}"
CXX="${CORALNPU_TOOLCHAIN_DIR}/riscv32-unknown-elf-g++"
CLANG="${CORALNPU_TOOLCHAIN_DIR}/clang"
OBJDUMP="${CORALNPU_TOOLCHAIN_DIR}/riscv32-unknown-elf-objdump"

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

for path in \
  "${OUTPUT_DIR}/${MODEL_NAME}.ll" \
  "${OUTPUT_DIR}/${MODEL_NAME}.graph" \
  "${OUTPUT_DIR}/${MODEL_NAME}.params" \
  "${ROOT}/generated/dlr_model_data.h" \
  "${KERNEL_DUMP}" \
  "${CLANG}" \
  "${CXX}" \
  "${OBJDUMP}" \
  "${RISCV_INSTALL_DIR}/lib/libDLR.a"; do
  if [[ ! -e "${path}" ]]; then
    echo "Required file not found: ${path}" >&2
    exit 1
  fi
done

"${KERNEL_DUMP}" \
  "${OUTPUT_DIR}/${MODEL_NAME}.graph" \
  "${OUTPUT_DIR}/${MODEL_NAME}.params" \
  "${OUTPUT_DIR}/${MODEL_NAME}.ll" \
  > "${ROOT}/src/kernel.inc"

"${CLANG}" \
  --target=riscv32-unknown-elf \
  -march="${RISCV_ISA}" -mabi="${RISCV_ABI}" \
  -mcmodel=medany \
  -c \
  "${OUTPUT_DIR}/${MODEL_NAME}.ll" \
  -o "${OUTPUT_DIR}/${MODEL_NAME}.o"

"${CXX}" -v \
  -march="${RISCV_ISA}" -mabi="${RISCV_ABI}" \
  -std=c++17 \
  -I"${ROOT}/src" \
  -I"${ROOT}/generated" \
  -I"${RISCV_INSTALL_DIR}/include" \
  -mcmodel=medany \
  -fpermissive \
  -Wl,--whole-archive \
  "${RISCV_INSTALL_DIR}/lib/libDLR.a" \
  -Wno-invalid-constexpr -Wl,--no-whole-archive \
  -g "${ROOT}/src/dlr_host.cpp" \
  "${OUTPUT_DIR}/${MODEL_NAME}.o" \
  -lm \
  -o "${ROOT}/${MODEL_NAME}" \
  > "${LOG_DIR}/build_dlr_elf.log" 2>&1

"${OBJDUMP}" -dC "${ROOT}/${MODEL_NAME}" \
  > "${OUTPUT_DIR}/${MODEL_NAME}.dis"

echo "Built ${ROOT}/${MODEL_NAME}"
