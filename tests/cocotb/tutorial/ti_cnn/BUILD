load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

package(default_visibility = ["//visibility:public"])

TI_CNN_CORALNPU_COPTS = [
    "-march=rv32imf_zve32x_zicsr_zifencei_zbb",
]

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_100",
    srcs = ["cnn_ts_gen_base_100/main.c", "cnn_ts_gen_base_100/cnn_ts_gen_base_100.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_100/cnn_ts_gen_base_100.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_100_int8",
    srcs = ["cnn_ts_gen_base_100_int8/main.c", "cnn_ts_gen_base_100_int8/cnn_ts_gen_base_100_int8.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_100_int8/cnn_ts_gen_base_100_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_100",
    srcs = ["rvv_cnn_ts_gen_base_100/main.c", "rvv_cnn_ts_gen_base_100/rvv_cnn_ts_gen_base_100.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_100/rvv_cnn_ts_gen_base_100.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_100_int8",
    srcs = ["rvv_cnn_ts_gen_base_100_int8/main.c", "rvv_cnn_ts_gen_base_100_int8/rvv_cnn_ts_gen_base_100_int8.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_100_int8/rvv_cnn_ts_gen_base_100_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_1k",
    srcs = ["cnn_ts_gen_base_1k/main.c", "cnn_ts_gen_base_1k/cnn_ts_gen_base_1k.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_1k/cnn_ts_gen_base_1k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_1k_int8",
    srcs = ["cnn_ts_gen_base_1k_int8/main.c", "cnn_ts_gen_base_1k_int8/cnn_ts_gen_base_1k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_1k_int8/cnn_ts_gen_base_1k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_1k",
    srcs = ["rvv_cnn_ts_gen_base_1k/main.c", "rvv_cnn_ts_gen_base_1k/rvv_cnn_ts_gen_base_1k.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_1k/rvv_cnn_ts_gen_base_1k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_1k_int8",
    srcs = ["rvv_cnn_ts_gen_base_1k_int8/main.c", "rvv_cnn_ts_gen_base_1k_int8/rvv_cnn_ts_gen_base_1k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_1k_int8/rvv_cnn_ts_gen_base_1k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_4k",
    srcs = ["cnn_ts_gen_base_4k/main.c", "cnn_ts_gen_base_4k/cnn_ts_gen_base_4k.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_4k/cnn_ts_gen_base_4k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_4k_int8",
    srcs = ["cnn_ts_gen_base_4k_int8/main.c", "cnn_ts_gen_base_4k_int8/cnn_ts_gen_base_4k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_4k_int8/cnn_ts_gen_base_4k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_4k",
    srcs = ["rvv_cnn_ts_gen_base_4k/main.c", "rvv_cnn_ts_gen_base_4k/rvv_cnn_ts_gen_base_4k.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_4k/rvv_cnn_ts_gen_base_4k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_4k_int8",
    srcs = ["rvv_cnn_ts_gen_base_4k_int8/main.c", "rvv_cnn_ts_gen_base_4k_int8/rvv_cnn_ts_gen_base_4k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_4k_int8/rvv_cnn_ts_gen_base_4k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_6k",
    srcs = ["cnn_ts_gen_base_6k/main.c", "cnn_ts_gen_base_6k/cnn_ts_gen_base_6k.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_6k/cnn_ts_gen_base_6k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_6k_int8",
    srcs = ["cnn_ts_gen_base_6k_int8/main.c", "cnn_ts_gen_base_6k_int8/cnn_ts_gen_base_6k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_6k_int8/cnn_ts_gen_base_6k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_6k",
    srcs = ["rvv_cnn_ts_gen_base_6k/main.c", "rvv_cnn_ts_gen_base_6k/rvv_cnn_ts_gen_base_6k.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_6k/rvv_cnn_ts_gen_base_6k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_6k_int8",
    srcs = ["rvv_cnn_ts_gen_base_6k_int8/main.c", "rvv_cnn_ts_gen_base_6k_int8/rvv_cnn_ts_gen_base_6k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_6k_int8/rvv_cnn_ts_gen_base_6k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_13k",
    srcs = ["cnn_ts_gen_base_13k/main.c", "cnn_ts_gen_base_13k/cnn_ts_gen_base_13k.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_13k/cnn_ts_gen_base_13k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "cnn_ts_gen_base_13k_int8",
    srcs = ["cnn_ts_gen_base_13k_int8/main.c", "cnn_ts_gen_base_13k_int8/cnn_ts_gen_base_13k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "cnn_ts_gen_base_13k_int8/cnn_ts_gen_base_13k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_13k",
    srcs = ["rvv_cnn_ts_gen_base_13k/main.c", "rvv_cnn_ts_gen_base_13k/rvv_cnn_ts_gen_base_13k.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_13k/rvv_cnn_ts_gen_base_13k.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

coralnpu_v2_binary(
    name = "rvv_cnn_ts_gen_base_13k_int8",
    srcs = ["rvv_cnn_ts_gen_base_13k_int8/main.c", "rvv_cnn_ts_gen_base_13k_int8/rvv_cnn_ts_gen_base_13k_int8.c"],
    hdrs = ["ti_cnn_perf.h", "rvv_cnn_ts_gen_base_13k_int8/rvv_cnn_ts_gen_base_13k_int8.h"],
    copts = TI_CNN_CORALNPU_COPTS,
    itcm_size_kbytes = 1024,
    dtcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
)

TI_CNN_ELFS = [
    ":cnn_ts_gen_base_100.elf",
    ":cnn_ts_gen_base_100_int8.elf",
    ":rvv_cnn_ts_gen_base_100.elf",
    ":rvv_cnn_ts_gen_base_100_int8.elf",
    ":cnn_ts_gen_base_1k.elf",
    ":cnn_ts_gen_base_1k_int8.elf",
    ":rvv_cnn_ts_gen_base_1k.elf",
    ":rvv_cnn_ts_gen_base_1k_int8.elf",
    ":cnn_ts_gen_base_4k.elf",
    ":cnn_ts_gen_base_4k_int8.elf",
    ":rvv_cnn_ts_gen_base_4k.elf",
    ":rvv_cnn_ts_gen_base_4k_int8.elf",
    ":cnn_ts_gen_base_6k.elf",
    ":cnn_ts_gen_base_6k_int8.elf",
    ":rvv_cnn_ts_gen_base_6k.elf",
    ":rvv_cnn_ts_gen_base_6k_int8.elf",
    ":cnn_ts_gen_base_13k.elf",
    ":cnn_ts_gen_base_13k_int8.elf",
    ":rvv_cnn_ts_gen_base_13k.elf",
    ":rvv_cnn_ts_gen_base_13k_int8.elf",
]

filegroup(
    name = "ti_cnn_elfs",
    srcs = TI_CNN_ELFS,
)

cocotb_test_suite(
    name = "cocotb_ti_cnn",
    simulators = ["verilator", "vcs"],
    testcases = ["test_ti_cnn_models"],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["test_ti_cnn.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": TI_CNN_ELFS,
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = TI_CNN_ELFS + ["//tests/cocotb:coverage_exclude.cfg"],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)
