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
    model_path = Path(__file__).with_name("pytorch_tensorflow_mlp_model.py")
    spec = importlib.util.spec_from_file_location("pytorch_tensorflow_mlp_model", model_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


model = _load_model_data()


class PytorchTensorflowMlpTester:
    def __init__(self):
        r = runfiles.Create()
        self.elf_file = r.Rlocation(
            "coralnpu_hw/tests/cocotb/tutorial/pytorch_tensorflow/pytorch_tensorflow_mlp_test.elf"
        )
        self.fixture = None

    async def setup(self, dut):
        self.fixture = await Fixture.Create(dut, highmem=True)
        await self.fixture.load_elf_and_lookup_symbols(
            self.elf_file,
            [
                "impl",
                "run_ref",
                "run_optimized",
                "output_multiplier",
                "output_shift",
                "input_dims",
                "hidden_dims",
                "output_dims",
                "fc1_filter_dims",
                "fc1_bias_dims",
                "fc2_filter_dims",
                "fc2_bias_dims",
                "input_data",
                "fc1_filter_data",
                "fc1_bias_data",
                "fc2_filter_data",
                "fc2_bias_data",
                "hidden_data",
                "output_data",
                "ref_cycles",
                "opt_cycles",
            ],
        )

        await self.fixture.write_word("output_multiplier", 1073741824)
        await self.fixture.write("output_shift", np.array([-1], dtype=np.int32))
        await self.fixture.write("input_dims", model.INPUT_DIMS)
        await self.fixture.write("hidden_dims", model.HIDDEN_DIMS)
        await self.fixture.write("output_dims", model.OUTPUT_DIMS)
        await self.fixture.write("fc1_filter_dims", model.FC1_FILTER_DIMS)
        await self.fixture.write("fc1_bias_dims", model.FC1_BIAS_DIMS)
        await self.fixture.write("fc2_filter_dims", model.FC2_FILTER_DIMS)
        await self.fixture.write("fc2_bias_dims", model.FC2_BIAS_DIMS)
        await self.fixture.write("input_data", model.INPUT_DATA)
        await self.fixture.write("fc1_filter_data", model.FC1_FILTER_DATA)
        await self.fixture.write("fc1_bias_data", model.FC1_BIAS_DATA)
        await self.fixture.write("fc2_filter_data", model.FC2_FILTER_DATA)
        await self.fixture.write("fc2_bias_data", model.FC2_BIAS_DATA)

    async def run(self, func_ptr, timeout_cycles=5000000):
        await self.fixture.write_ptr("impl", func_ptr)
        await self.fixture.write("hidden_data", np.zeros([8], dtype=np.int8))
        await self.fixture.write("output_data", np.zeros([4], dtype=np.int8))
        await self.fixture.run_to_halt(timeout_cycles=timeout_cycles)
        output = (await self.fixture.read("output_data", 4)).view(np.int8)
        cycle_symbol = "ref_cycles" if func_ptr == "run_ref" else "opt_cycles"
        cycles = (await self.fixture.read(cycle_symbol, 8)).view(np.uint64)[0]
        return output, cycles

    async def test(self):
        ref_output, ref_cycles = await self.run("run_ref")
        opt_output, opt_cycles = await self.run("run_optimized")
        print(f"ref_output={ref_output.tolist()} ref_cycles={ref_cycles}", flush=True)
        print(f"opt_output={opt_output.tolist()} opt_cycles={opt_cycles}", flush=True)

        assert np.array_equal(opt_output, ref_output)
        assert int(np.argmax(opt_output)) == model.EXPECTED_CLASS


@cocotb.test()
async def test_pytorch_tensorflow_mlp(dut):
    tester = PytorchTensorflowMlpTester()
    await tester.setup(dut)
    await tester.test()
