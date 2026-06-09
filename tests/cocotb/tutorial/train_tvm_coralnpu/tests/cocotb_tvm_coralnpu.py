import numpy as np
import cocotb
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture


@cocotb.test()
async def test_tvm_coralnpu_smoke_highmem(dut):
    fixture = await Fixture.Create(dut, highmem=True)
    r = runfiles.Create()
    elf = r.Rlocation(
        "coralnpu_hw/tests/cocotb/tutorial/train_tvm_coralnpu/"
        "tvm_coralnpu_smoke_highmem.elf"
    )
    await fixture.load_elf_and_lookup_symbols(
        elf,
        ["tvm_coralnpu_input", "tvm_coralnpu_output", "tvm_coralnpu_done"],
    )

    data = np.arange(16, dtype=np.uint32)
    await fixture.write("tvm_coralnpu_input", data)
    await fixture.write("tvm_coralnpu_output", np.zeros(16, dtype=np.uint32))
    await fixture.write("tvm_coralnpu_done", np.array([0], dtype=np.uint32))
    await fixture.run_to_halt(timeout_cycles=200000)

    result = (await fixture.read("tvm_coralnpu_output", 16 * 4)).view(np.uint32)
    done = (await fixture.read("tvm_coralnpu_done", 4)).view(np.uint32)
    assert int(done[0]) == 1
    assert int(result[0]) == int(data.sum())
    assert (result[1:] == data[1:] + 1).all()
