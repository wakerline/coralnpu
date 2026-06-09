import json
import os

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture


DEFAULT_TIMEOUT_CYCLES = 2_000_000


@cocotb.test()
async def test_generated_model_on_rvv_highmem(dut):
    fixture = await Fixture.Create(dut, highmem=True)
    r = runfiles.Create()
    elf = r.Rlocation(
        "coralnpu_hw/tests/cocotb/tutorial/train_tvm_coralnpu/"
        "coralnpu_model_highmem.elf"
    )
    io_json = r.Rlocation(
        "coralnpu_hw/tests/cocotb/tutorial/train_tvm_coralnpu/"
        "generated/tvm/model_io.json"
    )
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
    timeout_cycles = int(os.environ.get("CORAL_TUTORIAL_TIMEOUT_CYCLES", DEFAULT_TIMEOUT_CYCLES))
    rtl_cycles = await fixture.run_to_halt(timeout_cycles=timeout_cycles)

    output = (await fixture.read("model_output", golden.size * 4)).view(np.float32)
    status = (await fixture.read("model_status", 4)).view(np.int32)
    cycles = (await fixture.read("model_cycles", 4)).view(np.uint32)

    print(
        "generated_model "
        f"rtl_cycles={int(rtl_cycles)} "
        f"model_cycles_symbol={int(cycles[0])} "
        f"status={int(status[0])} "
        f"output={output.tolist()} "
        f"golden={golden.tolist()}",
        flush=True,
    )

    assert int(status[0]) == 1, f"model_status={int(status[0])}, cycles={int(cycles[0])}"
    assert int(cycles[0]) > 0
    np.testing.assert_allclose(output, golden, rtol=1e-5, atol=1e-5)
