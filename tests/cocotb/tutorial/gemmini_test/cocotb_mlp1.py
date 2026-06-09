import cocotb
import numpy as np

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture


IN_DIM = 16
HIDDEN_DIM = 12
OUT_DIM = 8


def sat_int8(x: np.ndarray) -> np.ndarray:
    return np.clip(x, -128, 127).astype(np.int8)


def fc_ref(x: np.ndarray, w: np.ndarray, b: np.ndarray, relu: bool) -> np.ndarray:
    acc = b.astype(np.int32) + w.astype(np.int32) @ x.astype(np.int32)
    if relu:
        acc = np.maximum(acc, 0)
    return sat_int8(acc)


def mlp_ref(x: np.ndarray,
            w0: np.ndarray,
            b0: np.ndarray,
            w1: np.ndarray,
            b1: np.ndarray) -> np.ndarray:
    h = fc_ref(x, w0, b0, relu=True)
    y = fc_ref(h, w1, b1, relu=False)
    return y


@cocotb.test()
async def test_mlp1_smoke(dut):
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/tutorial/gemmini_port/mlp1_test.elf"
    )

    fixture = await Fixture.Create(dut, highmem=True)
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        [
            "impl",
            "run_ref",
            "run_opt",
            "status",
            "cycles",
            "input_size",
            "hidden_size",
            "output_size",
            "input_data",
            "weights_0",
            "bias_0",
            "hidden_data",
            "weights_1",
            "bias_1",
            "output_data",
        ],
    )

    rng = np.random.default_rng(42)

    x = rng.integers(-8, 8, size=(IN_DIM,), dtype=np.int8)
    w0 = rng.integers(-4, 4, size=(HIDDEN_DIM, IN_DIM), dtype=np.int8)
    b0 = rng.integers(-32, 32, size=(HIDDEN_DIM,), dtype=np.int32)
    w1 = rng.integers(-4, 4, size=(OUT_DIM, HIDDEN_DIM), dtype=np.int8)
    b1 = rng.integers(-32, 32, size=(OUT_DIM,), dtype=np.int32)

    golden = mlp_ref(x, w0, b0, w1, b1)

    await fixture.write_word("input_size", IN_DIM)
    await fixture.write_word("hidden_size", HIDDEN_DIM)
    await fixture.write_word("output_size", OUT_DIM)

    await fixture.write("input_data", x)
    await fixture.write("weights_0", w0.reshape(-1))
    await fixture.write("bias_0", b0)
    await fixture.write("weights_1", w1.reshape(-1))
    await fixture.write("bias_1", b1)
    await fixture.write("output_data", np.zeros((OUT_DIM,), dtype=np.int8))

    # run_ref
    await fixture.write_ptr("impl", "run_ref")
    ref_cycles = await fixture.run_to_halt(timeout_cycles=200000)
    ref_output = (await fixture.read("output_data", OUT_DIM)).view(np.int8)

    assert (ref_output == golden).all(), (
        f"run_ref mismatch\\nexpected={golden}\\nactual={ref_output}"
    )

    # run_opt
    await fixture.write("output_data", np.zeros((OUT_DIM,), dtype=np.int8))
    await fixture.write_ptr("impl", "run_opt")
    opt_cycles = await fixture.run_to_halt(timeout_cycles=200000)
    opt_output = (await fixture.read("output_data", OUT_DIM)).view(np.int8)

    assert (opt_output == golden).all(), (
        f"run_opt mismatch\\nexpected={golden}\\nactual={opt_output}"
    )

    cocotb.log.info(
        f"MLP1 smoke passed: ref_cycles={ref_cycles}, opt_cycles={opt_cycles}"
    )