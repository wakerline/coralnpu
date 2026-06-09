import json
import os

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from cocotb.triggers import ClockCycles

from coralnpu_test_utils.sim_test_fixture import Fixture


async def wait_for_model_status(fixture, timeout_cycles, poll_cycles):
    elapsed = 0
    last_status = 0
    while elapsed < timeout_cycles:
        status = (await fixture.read("model_status", 4)).view(np.int32)
        last_status = int(status[0])
        if last_status not in (0, 10, 20):
            return elapsed, last_status
        step = min(poll_cycles, timeout_cycles - elapsed)
        await ClockCycles(fixture.core_mini_axi.dut.io_aclk, step)
        elapsed += step
    status = (await fixture.read("model_status", 4)).view(np.int32)
    return elapsed, int(status[0])


@cocotb.test()
async def test_dlr_tvm_coralnpu_model_highmem(dut):
    fixture = await Fixture.Create(dut, highmem=True)
    r = runfiles.Create()
    base = "coralnpu_hw/tests/cocotb/tutorial/dlr_tvm_coralnpu"
    elf = r.Rlocation(f"{base}/coralnpu_model_highmem.elf")
    io_json = r.Rlocation(f"{base}/generated/tvm/model_io.json")
    with open(io_json, "r", encoding="utf-8") as f:
        io = json.load(f)

    await fixture.load_elf_and_lookup_symbols(
        elf,
        ["model_input", "model_output", "model_status", "model_cycles"],
    )

    model_input = np.asarray(io["input"], dtype=np.float32)
    golden = np.asarray(io["golden_output"], dtype=np.float32)
    await fixture.write("model_input", model_input)
    await fixture.write("model_output", np.zeros_like(golden))
    await fixture.write("model_status", np.array([0], dtype=np.int32))
    await fixture.write("model_cycles", np.array([0], dtype=np.uint32))
    await fixture.core_mini_axi.execute_from(fixture.entry_point)
    timeout_cycles = int(os.getenv("DLR_TVM_CORALNPU_TIMEOUT_CYCLES", "5000000"))
    poll_cycles = int(os.getenv("DLR_TVM_CORALNPU_POLL_CYCLES", "1000"))
    rtl_cycles, polled_status = await wait_for_model_status(
        fixture, timeout_cycles=timeout_cycles, poll_cycles=poll_cycles
    )

    output = (await fixture.read("model_output", golden.size * 4)).view(np.float32)
    status = (await fixture.read("model_status", 4)).view(np.int32)
    cycles = (await fixture.read("model_cycles", 4)).view(np.uint32)

    print(
        "dlr_tvm_coralnpu "
        f"rtl_cycles={int(rtl_cycles)} "
        f"model_cycles_symbol={int(cycles[0])} "
        f"status={int(status[0])} "
        f"polled_status={int(polled_status)} "
        f"output={output.tolist()} "
        f"golden={golden.tolist()}",
        flush=True,
    )

    assert int(status[0]) == 1, f"model_status={int(status[0])}, cycles={int(cycles[0])}"
    assert int(cycles[0]) > 0
    np.testing.assert_allclose(output, golden, rtol=1e-5, atol=1e-5)
