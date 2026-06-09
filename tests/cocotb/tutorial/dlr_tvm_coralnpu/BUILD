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
        "-Itests/cocotb/tutorial/dlr_tvm_coralnpu/generated/tvm/aot",
        "-Itests/cocotb/tutorial/dlr_tvm_coralnpu/generated/tvm/aot/codegen/host/include",
        "-Itests/cocotb/tutorial/dlr_tvm_coralnpu/generated/tvm/aot/runtime/include",
    ],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
)

cocotb_test_suite(
    name = "cocotb_dlr_tvm_coralnpu_model",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_dlr_tvm_coralnpu_model_highmem",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["tests/cocotb_dlr_tvm_coralnpu.py"],
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
