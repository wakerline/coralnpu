# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import cocotb
import numpy as np

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_algo_2x2(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    inputs = np.array([1, 2, 3, 4], dtype=np.int32)
    expected = (inputs * 3) - 2

    with open(
        r.Rlocation("coralnpu_hw/tests/cocotb/tutorial/algo_2x2_test.elf"),
        "rb",
    ) as f:
        entry_point = await core_mini_axi.load_elf(f)
        input_addr = core_mini_axi.lookup_symbol(f, "input_data")
        output_addr = core_mini_axi.lookup_symbol(f, "output_data")
        done_addr = core_mini_axi.lookup_symbol(f, "done")
        halt_addr = core_mini_axi.lookup_symbol(f, "halt")
        status_addr = core_mini_axi.lookup_symbol(f, "status")

        await core_mini_axi.write(input_addr, inputs)
        await core_mini_axi.execute_from(entry_point)

    timeout_cycles = 10000
    for _ in range(timeout_cycles):
        done = (await core_mini_axi.read_word(done_addr)).view(np.int32)[0]
        if done == 1:
            break
        await ClockCycles(dut.io_aclk, 1)
    else:
        assert False, f"Timeout: algorithm did not complete within {timeout_cycles} cycles."

    done = (await core_mini_axi.read_word(done_addr)).view(np.int32)[0]
    status = (await core_mini_axi.read_word(status_addr)).view(np.int32)[0]
    outputs = (await core_mini_axi.read(output_addr, 16)).view(np.int32)
    await core_mini_axi.write_word(halt_addr, 1)
    await core_mini_axi.halt()

    print(f"algo_2x2 inputs   = {inputs.tolist()}", flush=True)
    print(f"algo_2x2 expected = {expected.tolist()}", flush=True)
    print(f"algo_2x2 outputs  = {outputs.tolist()}", flush=True)
    print(f"algo_2x2 done={int(done)} status={int(status)}", flush=True)

    assert done == 1
    assert status == 0
    assert (outputs == expected).all()
