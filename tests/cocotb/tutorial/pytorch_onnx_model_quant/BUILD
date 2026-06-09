# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

cc_library(
    name = "tvm_model",
    srcs = ["mod.a"],
    hdrs = [
        "model_abi.h",
        "tvmgen_default.h",
    ],
)

coralnpu_v2_binary(
    name = "pytorch_onnx_model_quant_test",
    srcs = ["pytorch_onnx_model_quant_test.cc"],
    defines = ["PYTORCH_ONNX_MODEL_QUANT"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        ":tvm_model",
        "//sw/utils",
    ],
)

coralnpu_v2_binary(
    name = "pytorch_onnx_model_float_test",
    srcs = ["pytorch_onnx_model_quant_test.cc"],
    defines = ["PYTORCH_ONNX_MODEL_FLOAT"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        ":tvm_model",
        "//sw/utils",
    ],
)

cocotb_test_suite(
    name = "cocotb_pytorch_onnx_model_quant",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_pytorch_onnx_model_quant",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["cocotb_pytorch_onnx_model_quant.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": [
            ":pytorch_onnx_model_quant_test.elf",
            "model_abi.py",
            "model_data.py",
            "golden_vectors/quant_test_vector.c",
        ],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":pytorch_onnx_model_quant_test.elf",
        "model_abi.py",
        "model_data.py",
        "golden_vectors/quant_test_vector.c",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)

cocotb_test_suite(
    name = "cocotb_pytorch_onnx_model_float",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_pytorch_onnx_model_quant",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["cocotb_pytorch_onnx_model_quant.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": [
            ":pytorch_onnx_model_float_test.elf",
            "model_abi.py",
            "model_data.py",
            "golden_vectors/float_test_vector.c",
        ],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":pytorch_onnx_model_float_test.elf",
        "model_abi.py",
        "model_data.py",
        "golden_vectors/float_test_vector.c",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)
