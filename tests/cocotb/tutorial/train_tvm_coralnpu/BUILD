load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("@rules_cc//cc:defs.bzl", "cc_library")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "coral_rvv_fakequant_runtime",
    srcs = ["runtime/coral_rvv_fakequant_runtime.cc"],
    hdrs = ["runtime/coral_rvv_fakequant_runtime.h"],
    deps = [
        "//sw/opt:rvv_opt",
        "//sw/utils:utils",
    ],
)

coralnpu_v2_binary(
    name = "tvm_coralnpu_smoke_highmem",
    srcs = ["runtime/tvm_coralnpu_smoke.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
)

coralnpu_v2_binary(
    name = "coralnpu_model_highmem",
    srcs = glob([
        "generated/tvm/aot/codegen/host/src/*.c",
        "generated/tvm/aot/coral_baremetal_main.cc",
    ]),
    hdrs = glob([
        "generated/tvm/aot/codegen/host/include/**/*.h",
        "generated/tvm/aot/runtime/include/**/*.h",
    ]),
    objects = glob([
        "generated/tvm/aot/codegen/host/lib/*.o",
    ]),
    copts = [
        "-Itests/cocotb/tutorial/train_tvm_coralnpu",
        "-Itests/cocotb/tutorial/train_tvm_coralnpu/generated/tvm/aot",
        "-Itests/cocotb/tutorial/train_tvm_coralnpu/generated/tvm/aot/codegen/host/include",
        "-Itests/cocotb/tutorial/train_tvm_coralnpu/generated/tvm/aot/runtime/include",
    ],
    deps = [":coral_rvv_fakequant_runtime"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
)

cocotb_test_suite(
    name = "cocotb_tvm_coralnpu",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_tvm_coralnpu_smoke_highmem",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["tests/cocotb_tvm_coralnpu.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": [
            ":tvm_coralnpu_smoke_highmem.elf",
        ],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":tvm_coralnpu_smoke_highmem.elf",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)

cocotb_test_suite(
    name = "cocotb_coralnpu_model",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_generated_model_on_rvv_highmem",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["tests/cocotb_generated_model.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": [
            ":coralnpu_model_highmem.elf",
        ] + glob(["generated/tvm/model_io.json"]),
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":coralnpu_model_highmem.elf",
        "//tests/cocotb:coverage_exclude.cfg",
    ] + glob(["generated/tvm/model_io.json"]),
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)
