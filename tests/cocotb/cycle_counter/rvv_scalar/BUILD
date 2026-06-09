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

package(default_visibility = ["//visibility:public"])

coralnpu_v2_binary(
    name = "rvv_scalar_interaction",
    srcs = ["rvv_scalar_interaction.S"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
)

TEST_CASES = [
    "rvv_scalar_interaction_test",
]

cocotb_test_suite(
    name = "cocotb_rvv_scalar_interaction_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = TEST_CASES,
    testcases_vname = "TEST_CASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "test_module": ["cocotb_rvv_scalar_interaction.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":rvv_scalar_interaction",
        ],
        "size": "large",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":rvv_scalar_interaction.elf",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)
