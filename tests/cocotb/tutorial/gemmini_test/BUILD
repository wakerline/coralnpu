load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")

package(default_visibility = ["//visibility:public"])

coralnpu_v2_binary(
    name = "mlp1_test",
    srcs = ["mlp1_test.cc"],
    hdrs = ["mlp1_data.h"],
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
)

cocotb_test_suite(
    name = "gemmini_port_mlp1",
    simulators = ["verilator"],
    testcases = [
        "test_mlp1_smoke",
    ],
    testcases_vname = "GEMMINI_PORT_MLP1_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["cocotb_mlp1.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":mlp1_test.elf",
        ],
        "size": "large",
    },
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)