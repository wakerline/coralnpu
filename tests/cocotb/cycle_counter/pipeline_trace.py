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
from collections import defaultdict, deque

import numpy as np
from cocotb.triggers import RisingEdge


def _u32(signal):
    return int(signal.value) & 0xFFFFFFFF


def _bit(signal):
    return int(signal.value) != 0


def _sig(dut, name):
    return getattr(dut, name)


def pc_range_symbol_names(count):
    names = []
    for i in range(count):
        names.append(f"cycle_counter_test_{i}_start")
        names.append(f"cycle_counter_test_{i}_end")
    return names


def symbol_pc_ranges(fixture, count):
    return [
        (
            fixture.symbols[f"cycle_counter_test_{i}_start"],
            fixture.symbols[f"cycle_counter_test_{i}_end"],
        )
        for i in range(count)
    ]


def pc_to_index(pc, pc_ranges):
    for i, (start, end) in enumerate(pc_ranges):
        if start <= pc < end:
            return i
    return None


def _add_note(inst, note):
    if not note:
        return
    inst.setdefault("notes", set()).add(note)


def _is_memory_instruction(name):
    if name in {
            "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw",
            "flw", "fsw"}:
        return True
    return (
        name.startswith(("vle", "vse")) and len(name) > 3 and name[3].isdigit()
        or name.startswith(("vlse", "vsse")) and len(name) > 4 and name[4].isdigit()
        or name.startswith(("vluxei", "vsuxei")) and len(name) > 6 and name[6].isdigit()
    )


def summarize_pipeline_trace(samples, names):
    rows = []
    for i, name in enumerate(names):
        inst_samples = samples.get(i, [])
        if not inst_samples:
            rows.append({
                "instruction": name,
                "samples": 0,
                "fetch_to_retire_min": "NA",
                "fetch_to_retire_avg": "NA",
                "dispatch_to_complete_min": "NA",
                "dispatch_to_complete_avg": "NA",
                "mem_req_to_retire_min": "NA",
                "mem_req_to_retire_avg": "NA",
                "note": "no dynamic sample",
            })
            continue

        def values(key):
            return [s[key] for s in inst_samples if s.get(key) is not None]

        def fmt_avg(vals):
            return "NA" if not vals else f"{sum(vals) / len(vals):.4f}"

        def fmt_min(vals):
            return "NA" if not vals else str(min(vals))

        total = values("fetch_to_retire")
        execute = values("dispatch_to_complete")
        mem = values("mem_req_to_retire")
        notes = sorted({
            note.strip()
            for s in inst_samples
            for note in s.get("note", "").split(";")
            if note.strip()
        })

        rows.append({
            "instruction": name,
            "samples": len(inst_samples),
            "fetch_to_retire_min": fmt_min(total),
            "fetch_to_retire_avg": fmt_avg(total),
            "dispatch_to_complete_min": fmt_min(execute),
            "dispatch_to_complete_avg": fmt_avg(execute),
            "mem_req_to_retire_min": fmt_min(mem),
            "mem_req_to_retire_avg": fmt_avg(mem),
            "note": "; ".join(notes),
        })
    return rows


def write_pipeline_tables(rows, basename):
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", os.getcwd())
    csv_path = os.path.join(out_dir, f"{basename}.csv")
    md_path = os.path.join(out_dir, f"{basename}.md")

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    with open(md_path, "w") as f:
        f.write("| instruction | samples | fetch_to_retire_min | fetch_to_retire_avg | "
                "dispatch_to_complete_min | dispatch_to_complete_avg | "
                "mem_req_to_retire_min | mem_req_to_retire_avg | note |\n")
        f.write("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n")
        for row in rows:
            f.write(
                f"| {row['instruction']} | {row['samples']} | "
                f"{row['fetch_to_retire_min']} | {row['fetch_to_retire_avg']} | "
                f"{row['dispatch_to_complete_min']} | {row['dispatch_to_complete_avg']} | "
                f"{row['mem_req_to_retire_min']} | {row['mem_req_to_retire_avg']} | "
                f"{row['note']} |\n")
    return csv_path, md_path


async def run_and_trace_pipeline(fixture, dut, pc_ranges, instruction_names,
                                 timeout_cycles=2000000):
    by_pc = defaultdict(list)
    outstanding_rd = defaultdict(deque)
    outstanding_mem = deque()
    cycle = 0

    await fixture.core_mini_axi.execute_from(fixture.entry_point)
    while cycle < timeout_cycles:
        await RisingEdge(dut.io_aclk)
        cycle += 1

        if _bit(dut.io_halted):
            break

        fetch_en = int(_sig(dut, "io_debug_en").value)
        for lane in range(4):
            if fetch_en & (1 << lane):
                pc = _u32(_sig(dut, f"io_debug_addr_{lane}"))
                for inst in by_pc[pc]:
                    inst.setdefault("fetch", cycle)
                if not by_pc[pc]:
                    by_pc[pc].append({"pc": pc, "fetch": cycle})

        for lane in range(4):
            if _bit(_sig(dut, f"io_debug_dispatch_{lane}_instFire")):
                pc = _u32(_sig(dut, f"io_debug_dispatch_{lane}_instAddr"))
                inst = {"pc": pc, "dispatch": cycle}
                by_pc[pc].append(inst)
                if _bit(_sig(dut, f"io_debug_regfile_writeAddr_{lane}_valid")):
                    rd = int(_sig(dut, f"io_debug_regfile_writeAddr_{lane}_bits").value)
                    if rd != 0:
                        outstanding_rd[("x", rd)].append(inst)
                if hasattr(dut, "io_debug_float_writeAddr_valid") and _bit(dut.io_debug_float_writeAddr_valid):
                    rd = int(dut.io_debug_float_writeAddr_bits.value)
                    outstanding_rd[("f", rd)].append(inst)

        for port in range(6):
            if _bit(_sig(dut, f"io_debug_regfile_writeData_{port}_valid")):
                rd = int(_sig(dut, f"io_debug_regfile_writeData_{port}_bits_addr").value)
                q = outstanding_rd.get(("x", rd))
                if q:
                    q.popleft()["complete"] = cycle

        if hasattr(dut, "io_debug_float_writeData_0_valid"):
            for port in range(2):
                if _bit(_sig(dut, f"io_debug_float_writeData_{port}_valid")):
                    rd = int(_sig(dut, f"io_debug_float_writeData_{port}_bits_addr").value) & 0x1F
                    q = outstanding_rd.get(("f", rd))
                    if q:
                        q.popleft()["complete"] = cycle

        if _bit(dut.io_debug_dbus_valid):
            # The current public debug bus does not carry PC, so match memory
            # requests conservatively to the oldest dispatched but unretired
            # memory instruction. Samples that cannot be attributed this way are
            # left as NA instead of inventing a latency.
            matched = False
            for insts in by_pc.values():
                for inst in insts:
                    if matched:
                        break
                    if "dispatch" not in inst or "retire" in inst or "mem_req" in inst:
                        continue
                    idx = pc_to_index(inst["pc"], pc_ranges)
                    if idx is None:
                        continue
                    name = instruction_names[idx]
                    if _is_memory_instruction(name):
                        inst["mem_req"] = cycle
                        _add_note(inst, "memory request PC inferred from issue order")
                        outstanding_mem.append(inst)
                        matched = True
                if matched:
                    break

        for slot in range(8):
            if _bit(_sig(dut, f"io_debug_rb_inst_{slot}_valid")):
                pc = _u32(_sig(dut, f"io_debug_rb_inst_{slot}_bits_pc"))
                candidates = [x for x in by_pc.get(pc, []) if "retire" not in x]
                inst = candidates[0] if candidates else {"pc": pc}
                inst["retire"] = cycle
                if "complete" not in inst:
                    inst["complete"] = cycle
                    _add_note(inst, "complete approximated by retire")
                if "fetch" not in inst:
                    inst["fetch"] = inst.get("dispatch", cycle)
                    _add_note(inst, "fetch not observed; used dispatch")
                if inst not in by_pc[pc]:
                    by_pc[pc].append(inst)

    if cycle >= timeout_cycles:
        raise AssertionError(f"pipeline trace timed out after {timeout_cycles} cycles")

    samples = defaultdict(list)
    for pc, insts in by_pc.items():
        idx = pc_to_index(pc, pc_ranges)
        if idx is None:
            continue
        for inst in insts:
            if "retire" not in inst:
                continue
            samples[idx].append({
                "fetch_to_retire": inst["retire"] - inst.get("fetch", inst["retire"]),
                "dispatch_to_complete": (
                    inst.get("complete") - inst.get("dispatch")
                    if "dispatch" in inst and "complete" in inst else None),
                "mem_req_to_retire": (
                    inst["retire"] - inst["mem_req"] if "mem_req" in inst else None),
                "note": "; ".join(sorted(inst.get("notes", []))),
            })
    return samples
