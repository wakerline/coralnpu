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

import csv
import os
import sys
from pathlib import Path

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture

sys.path.append(str(Path(__file__).resolve().parent.parent))
from pipeline_trace import (  # noqa: E402
    pc_range_symbol_names,
    run_and_trace_pipeline,
    summarize_pipeline_trace,
    symbol_pc_ranges,
    write_pipeline_tables,
)


SCALAR_INSTRUCTIONS = [
    "baseline_nop",
    "lui",
    "auipc",
    "addi",
    "slti",
    "sltiu",
    "xori",
    "ori",
    "andi",
    "slli",
    "srli",
    "srai",
    "add",
    "sub",
    "sll",
    "slt",
    "sltu",
    "xor",
    "srl",
    "sra",
    "or",
    "and",
    "lb",
    "lh",
    "lw",
    "lbu",
    "lhu",
    "sb",
    "sh",
    "sw",
    "beq_taken",
    "bne_not_taken",
    "blt_not_taken",
    "bge_taken",
    "bltu_not_taken",
    "bgeu_taken",
    "jal",
    "jalr",
    "fence",
    "fence_i",
    "csrrw",
    "csrrs",
    "csrrc",
    "csrrwi",
    "csrrsi",
    "csrrci",
    "mul",
    "mulh",
    "mulhsu",
    "mulhu",
    "div",
    "divu",
    "rem",
    "remu",
    "flw",
    "fsw",
    "fadd_s",
    "fsub_s",
    "fmul_s",
    "fdiv_s",
    "fsqrt_s",
    "fsgnj_s",
    "fsgnjn_s",
    "fsgnjx_s",
    "fmin_s",
    "fmax_s",
    "fcvt_w_s",
    "fcvt_wu_s",
    "fmv_x_w",
    "feq_s",
    "flt_s",
    "fle_s",
    "fclass_s",
    "fcvt_s_w",
    "fcvt_s_wu",
    "fmv_w_x",
    "andn",
    "orn",
    "xnor",
    "clz",
    "ctz",
    "cpop",
    "max",
    "maxu",
    "min",
    "minu",
    "sext_b",
    "sext_h",
    "zext_h",
    "rol",
    "ror",
    "rori",
    "orc_b",
    "rev8",
    "fmadd_s",
    "fmsub_s",
    "fnmsub_s",
    "fnmadd_s",
    "ecall",
    "ebreak",
]

SCALAR_BARRIER_ONLY_INSTRUCTIONS = {
    "baseline_nop",
    "lui",
    "auipc",
    "beq_taken",
    "bne_not_taken",
    "blt_not_taken",
    "bge_taken",
    "bltu_not_taken",
    "bgeu_taken",
    "jal",
    "jalr",
    "fence",
    "fence_i",
    "ecall",
    "ebreak",
}


async def _read_u32_array(fixture, symbol, count):
    data = await fixture.read(symbol, count * 4)
    return np.frombuffer(data.tobytes(), dtype=np.uint32, count=count)


def _write_tables(rows, basename):
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", os.getcwd())
    csv_path = os.path.join(out_dir, f"{basename}.csv")
    md_path = os.path.join(out_dir, f"{basename}.md")

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    with open(md_path, "w") as f:
        f.write("| instruction | raw_cycles | adjusted_cycles | retired_instructions | "
                "cpi | measurement_status | serialization_status |\n")
        f.write("| --- | ---: | ---: | ---: | ---: | --- | --- |\n")
        for row in rows:
            f.write(
                f"| {row['instruction']} | {row['raw_cycles']} | "
                f"{row['adjusted_cycles']} | {row['retired_instructions']} | "
                f"{row['cpi']} | {row['measurement_status']} | "
                f"{row['serialization_status']} |\n")
    return csv_path, md_path


@cocotb.test()
async def scalar_instruction_cycle_counter_test(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut, highmem=True)
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/cycle_counter/scalar/scalar_cycle_counter.elf")
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        [
            "cycle_counter_num_tests",
            "cycle_counter_repeat_count",
            "cycle_counter_overhead_cycles_lo",
            "cycle_counter_overhead_cycles_hi",
            "cycle_counter_serial_barrier_cycles_lo",
            "cycle_counter_serial_barrier_cycles_hi",
            "cycle_counter_cycles_lo",
            "cycle_counter_cycles_hi",
            "cycle_counter_instret_lo",
            "cycle_counter_instret_hi",
        ] + pc_range_symbol_names(len(SCALAR_INSTRUCTIONS)),
    )

    num_tests = int((await fixture.read_word("cycle_counter_num_tests")).view(np.uint32)[0])
    repeat_count = int((await fixture.read_word("cycle_counter_repeat_count")).view(np.uint32)[0])
    assert num_tests == len(SCALAR_INSTRUCTIONS)
    pc_ranges = symbol_pc_ranges(fixture, num_tests)
    pipeline_samples = await run_and_trace_pipeline(
        fixture,
        dut,
        pc_ranges,
        SCALAR_INSTRUCTIONS,
        timeout_cycles=1000000,
    )

    overhead_lo = int((await fixture.read_word("cycle_counter_overhead_cycles_lo")).view(np.uint32)[0])
    overhead_hi = int((await fixture.read_word("cycle_counter_overhead_cycles_hi")).view(np.uint32)[0])
    overhead = (overhead_hi << 32) | overhead_lo
    barrier_lo = int((await fixture.read_word("cycle_counter_serial_barrier_cycles_lo")).view(np.uint32)[0])
    barrier_hi = int((await fixture.read_word("cycle_counter_serial_barrier_cycles_hi")).view(np.uint32)[0])
    serial_barrier_overhead = (barrier_hi << 32) | barrier_lo
    cycles_lo = await _read_u32_array(fixture, "cycle_counter_cycles_lo", num_tests)
    cycles_hi = await _read_u32_array(fixture, "cycle_counter_cycles_hi", num_tests)
    instret_lo = await _read_u32_array(fixture, "cycle_counter_instret_lo", num_tests)
    instret_hi = await _read_u32_array(fixture, "cycle_counter_instret_hi", num_tests)

    rows = []
    for i, instruction in enumerate(SCALAR_INSTRUCTIONS):
        raw_cycles = (int(cycles_hi[i]) << 32) | int(cycles_lo[i])
        raw_instret = (int(instret_hi[i]) << 32) | int(instret_lo[i])
        adjusted_cycles = max(0, raw_cycles - overhead - serial_barrier_overhead)
        cpi = adjusted_cycles / repeat_count
        rows.append({
            "instruction": instruction,
            "raw_cycles": raw_cycles,
            "adjusted_cycles": adjusted_cycles,
            "retired_instructions": raw_instret,
            "repeat_count": repeat_count,
            "csr_read_overhead_cycles": overhead,
            "serial_barrier_overhead_cycles": serial_barrier_overhead,
            "cpi": f"{cpi:.4f}",
            "measurement_status": (
                "exception_path" if instruction in {"ecall", "ebreak"} else "measured"),
            "serialization_status": (
                "serializing_barrier_only"
                if instruction in SCALAR_BARRIER_ONLY_INSTRUCTIONS else
                "raw_chain_or_barrier_serialized"),
        })

    csv_path, md_path = _write_tables(rows, "scalar_instruction_cycles")
    pipeline_rows = summarize_pipeline_trace(pipeline_samples, SCALAR_INSTRUCTIONS)
    pipeline_csv_path, pipeline_md_path = write_pipeline_tables(
        pipeline_rows, "scalar_pipeline_cycles")
    dut._log.info("Scalar instruction cycle table: %s", csv_path)
    dut._log.info("Scalar instruction cycle markdown: %s", md_path)
    dut._log.info("Scalar pipeline cycle table: %s", pipeline_csv_path)
    dut._log.info("Scalar pipeline cycle markdown: %s", pipeline_md_path)
    for row in rows:
        print(
            f"SCALAR {row['instruction']}: cycles={row['adjusted_cycles']} "
            f"repeat={repeat_count} cpi={row['cpi']}",
            flush=True)
