import os

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture


TI_CNN_MODELS = [
    ("cnn_ts_gen_base_100", "float"),
    ("cnn_ts_gen_base_100_int8", "int8"),
    ("rvv_cnn_ts_gen_base_100", "float"),
    ("rvv_cnn_ts_gen_base_100_int8", "int8"),
    ("cnn_ts_gen_base_1k", "float"),
    ("cnn_ts_gen_base_1k_int8", "int8"),
    ("rvv_cnn_ts_gen_base_1k", "float"),
    ("rvv_cnn_ts_gen_base_1k_int8", "int8"),
    ("cnn_ts_gen_base_4k", "float"),
    ("cnn_ts_gen_base_4k_int8", "int8"),
    ("rvv_cnn_ts_gen_base_4k", "float"),
    ("rvv_cnn_ts_gen_base_4k_int8", "int8"),
    ("cnn_ts_gen_base_6k", "float"),
    ("cnn_ts_gen_base_6k_int8", "int8"),
    ("rvv_cnn_ts_gen_base_6k", "float"),
    ("rvv_cnn_ts_gen_base_6k_int8", "int8"),
    ("cnn_ts_gen_base_13k", "float"),
    ("cnn_ts_gen_base_13k_int8", "int8"),
    ("rvv_cnn_ts_gen_base_13k", "float"),
    ("rvv_cnn_ts_gen_base_13k_int8", "int8"),
]


def _env_int(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default
    return int(raw.replace("_", ""), 0)


@cocotb.test()
async def test_ti_cnn_models(dut):
    r = runfiles.Create()
    only = os.environ.get("TI_CNN_ONLY")
    timeout_cycles = _env_int("TI_CNN_TIMEOUT_CYCLES", 200_000_000)
    for model_name, kind in TI_CNN_MODELS:
        if only and model_name != only:
            continue
        fixture = await Fixture.Create(dut, highmem=True)
        elf = r.Rlocation(f"coralnpu_hw/tests/cocotb/tutorial/ti_cnn/{model_name}.elf")
        await fixture.load_elf_and_lookup_symbols(
            elf,
            [
                "ti_cnn_status",
                "ti_cnn_cycles_lo",
                "ti_cnn_cycles_hi",
                "ti_cnn_macs",
                "ti_cnn_operations",
                "ti_cnn_performance",
                "ti_cnn_utilization",
                "ti_cnn_output_count",
                "ti_cnn_output_f32" if kind == "float" else "ti_cnn_output_i8",
                "ti_cnn_golden_f32" if kind == "float" else "ti_cnn_golden_i8",
            ],
        )
        await fixture.run_to_halt(timeout_cycles=timeout_cycles)
        status = (await fixture.read("ti_cnn_status", 4)).view(np.uint32)
        count = (await fixture.read("ti_cnn_output_count", 4)).view(np.uint32)
        cycles_lo = (await fixture.read("ti_cnn_cycles_lo", 4)).view(np.uint32)
        cycles_hi = (await fixture.read("ti_cnn_cycles_hi", 4)).view(np.uint32)
        macs = (await fixture.read("ti_cnn_macs", 4)).view(np.uint32)
        operations = (await fixture.read("ti_cnn_operations", 4)).view(np.uint32)
        performance = (await fixture.read("ti_cnn_performance", 4)).view(np.float32)
        utilization = (await fixture.read("ti_cnn_utilization", 4)).view(np.float32)
        n = int(count[0])
        cycles = (int(cycles_hi[0]) << 32) | int(cycles_lo[0])
        if kind == "float":
            output = (await fixture.read("ti_cnn_output_f32", n * 4)).view(np.float32)
            golden = (await fixture.read("ti_cnn_golden_f32", n * 4)).view(np.float32)
            assert np.allclose(output, golden, atol=5e-4, rtol=0), (
                model_name,
                output,
                golden,
            )
        else:
            output = (await fixture.read("ti_cnn_output_i8", n)).view(np.int8)
            golden = (await fixture.read("ti_cnn_golden_i8", n)).view(np.int8)
            assert (output == golden).all(), (model_name, output, golden)
        assert int(status[0]) == 1, (
            model_name,
            int(status[0]),
            cycles,
            "fault",
            bool(fixture.fault()),
        )
        dut._log.info(
            "%s passed: cycles=%d macs=%d operations=%d performance=%.6f OP/cycle utilization=%.6f%% output=%s",
            model_name,
            cycles,
            int(macs[0]),
            int(operations[0]),
            float(performance[0]),
            float(utilization[0]),
            output,
        )
