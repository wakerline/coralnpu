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

import cocotb
import importlib.util
import numpy as np
from pathlib import Path
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture


def _load_model_data():
    model_path = Path(__file__).with_name("model_data.py")
    spec = importlib.util.spec_from_file_location("pytorch_onnx_model_quant_data", model_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


model_data = _load_model_data()


def _resolve_elf_and_mode(r):
    base = "coralnpu_hw/tests/cocotb/tutorial/pytorch_onnx_model_quant"
    candidates = [
        ("quant", "pytorch_onnx_model_quant_test.elf"),
        ("float", "pytorch_onnx_model_float_test.elf"),
    ]
    for mode, elf_name in candidates:
        elf_file = r.Rlocation(f"{base}/{elf_name}")
        if elf_file and Path(elf_file).exists():
            return elf_file, mode
    raise FileNotFoundError("Could not find quant or float test ELF in runfiles")


@cocotb.test()
async def test_pytorch_onnx_model_quant(dut):
    r = runfiles.Create()
    elf_file, model_mode = _resolve_elf_and_mode(r)
    fixture = await Fixture.Create(dut, highmem=True)
    await fixture.load_elf_and_lookup_symbols(
        elf_file,
        [
            "model_input",
            "model_output",
            "golden_output",
            "inference_status",
            "inference_cycles",
        ],
    )

    model_input = model_data.model_input(model_mode)
    golden_output = model_data.golden_output(model_mode)
    await fixture.write("model_input", model_input)
    await fixture.write("model_output", np.zeros([2], dtype=model_input.dtype))
    await fixture.write("golden_output", golden_output)

    await fixture.run_to_halt(timeout_cycles=5000000)

    status = (await fixture.read("inference_status", 4)).view(np.int32)[0]
    output_bytes = 8 if model_mode == "float" else 2
    output_dtype = np.float32 if model_mode == "float" else np.int8
    output = (await fixture.read("model_output", output_bytes)).view(output_dtype)
    cycles = (await fixture.read("inference_cycles", 8)).view(np.uint64)[0]
    print(
        f"mode={model_mode} status={int(status)} output={output.tolist()} "
        f"golden={golden_output.tolist()} cycles={int(cycles)}",
        flush=True,
    )

    assert int(status) == 0
    if model_mode == "float":
        np.testing.assert_allclose(output, golden_output, rtol=1e-4, atol=1e-4)
    else:
        assert np.array_equal(output, golden_output)
