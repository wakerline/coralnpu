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

import cocotb
from bazel_tools.tools.python.runfiles import runfiles
from cocotb.triggers import RisingEdge
from coralnpu_test_utils.sim_test_fixture import Fixture


CASES = [
    {
        "case": "scalar_load_then_vector_load",
        "group": "scalar_vector_memory",
        "purpose": "scalar memory and vector memory overlap",
        "first": "rvv_scalar_case0_scalar_load",
        "second": "rvv_scalar_case0_vector_load",
        "expected": "independent_can_overlap",
    },
    {
        "case": "vector_load_then_scalar_load",
        "group": "scalar_vector_memory",
        "purpose": "scalar memory and vector memory overlap",
        "first": "rvv_scalar_case1_vector_load",
        "second": "rvv_scalar_case1_scalar_load",
        "expected": "independent_can_overlap",
    },
    {
        "case": "vector_load_then_vector_compute",
        "group": "vector_memory_compute",
        "purpose": "independent vector memory and vector compute overlap",
        "first": "rvv_scalar_case2_vector_load",
        "second": "rvv_scalar_case2_vector_compute",
        "expected": "independent_can_overlap",
    },
    {
        "case": "vector_compute_then_vector_load",
        "group": "vector_memory_compute",
        "purpose": "independent vector compute and vector memory overlap",
        "first": "rvv_scalar_case3_vector_compute",
        "second": "rvv_scalar_case3_vector_load",
        "expected": "independent_can_overlap",
    },
    {
        "case": "scalar_load_then_scalar_compute",
        "group": "scalar_memory_compute",
        "purpose": "independent scalar memory and scalar compute overlap",
        "first": "rvv_scalar_case4_scalar_load",
        "second": "rvv_scalar_case4_scalar_compute",
        "expected": "independent_can_overlap",
    },
    {
        "case": "scalar_compute_then_scalar_load",
        "group": "scalar_memory_compute",
        "purpose": "independent scalar compute and scalar memory overlap",
        "first": "rvv_scalar_case5_scalar_compute",
        "second": "rvv_scalar_case5_scalar_load",
        "expected": "independent_can_overlap",
    },
    {
        "case": "vector_load_then_dependent_vector_compute",
        "group": "vector_dependency_control",
        "purpose": "RAW-dependent vector compute should not prove independent overlap",
        "first": "rvv_scalar_case6_vector_load",
        "second": "rvv_scalar_case6_vector_compute_dep",
        "expected": "raw_dependency_should_serialize",
    },
    {
        "case": "scalar_load_then_dependent_scalar_compute",
        "group": "scalar_dependency_control",
        "purpose": "RAW-dependent scalar compute should not prove independent overlap",
        "first": "rvv_scalar_case7_scalar_load",
        "second": "rvv_scalar_case7_scalar_compute_dep",
        "expected": "raw_dependency_should_serialize",
    },
]

GROUP_CASES = [
    {
        "case": "two_vector_loads_then_two_computes",
        "group": "vector_load_compute_group",
        "purpose": "exclude same-cycle load+compute dual dispatch by issuing load group first",
        "loads": [
            "rvv_scalar_case8_vector_load0",
            "rvv_scalar_case8_vector_load1",
        ],
        "computes": [
            "rvv_scalar_case8_vector_compute0",
            "rvv_scalar_case8_vector_compute1",
        ],
        "expected_order": "loads_before_computes",
    },
    {
        "case": "two_computes_then_two_vector_loads",
        "group": "vector_load_compute_group",
        "purpose": "exclude same-cycle compute+load dual dispatch by issuing compute group first",
        "loads": [
            "rvv_scalar_case9_vector_load0",
            "rvv_scalar_case9_vector_load1",
        ],
        "computes": [
            "rvv_scalar_case9_vector_compute0",
            "rvv_scalar_case9_vector_compute1",
        ],
        "expected_order": "computes_before_loads",
    },
    {
        "case": "vector_load_compute_load_compute",
        "group": "vector_load_compute_group",
        "purpose": "observe mixed scheduling when load and compute alternate in program order",
        "loads": [
            "rvv_scalar_case10_vector_load0",
            "rvv_scalar_case10_vector_load1",
        ],
        "computes": [
            "rvv_scalar_case10_vector_compute0",
            "rvv_scalar_case10_vector_compute1",
        ],
        "expected_order": "mixed",
    },
    {
        "case": "vector_compute_load_compute_load",
        "group": "vector_load_compute_group",
        "purpose": "observe mixed scheduling when compute and load alternate in program order",
        "loads": [
            "rvv_scalar_case11_vector_load0",
            "rvv_scalar_case11_vector_load1",
        ],
        "computes": [
            "rvv_scalar_case11_vector_compute0",
            "rvv_scalar_case11_vector_compute1",
        ],
        "expected_order": "mixed",
    },
    {
        "case": "four_vector_loads_then_four_computes",
        "group": "vector_load_compute_group",
        "purpose": "test four vector loads followed by four independent vector computes",
        "loads": [
            "rvv_scalar_case12_vector_load0",
            "rvv_scalar_case12_vector_load1",
            "rvv_scalar_case12_vector_load2",
            "rvv_scalar_case12_vector_load3",
        ],
        "computes": [
            "rvv_scalar_case12_vector_compute0",
            "rvv_scalar_case12_vector_compute1",
            "rvv_scalar_case12_vector_compute2",
            "rvv_scalar_case12_vector_compute3",
        ],
        "expected_order": "loads_before_computes",
    },
    {
        "case": "four_computes_then_four_vector_loads",
        "group": "vector_load_compute_group",
        "purpose": "test four independent vector computes followed by four vector loads",
        "loads": [
            "rvv_scalar_case13_vector_load0",
            "rvv_scalar_case13_vector_load1",
            "rvv_scalar_case13_vector_load2",
            "rvv_scalar_case13_vector_load3",
        ],
        "computes": [
            "rvv_scalar_case13_vector_compute0",
            "rvv_scalar_case13_vector_compute1",
            "rvv_scalar_case13_vector_compute2",
            "rvv_scalar_case13_vector_compute3",
        ],
        "expected_order": "computes_before_loads",
    },
]


def _bit(signal):
    return int(signal.value) != 0


def _u32(signal):
    return int(signal.value) & 0xFFFFFFFF


def _write_tables(rows):
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", os.getcwd())
    csv_path = os.path.join(out_dir, "rvv_scalar_interaction.csv")
    md_path = os.path.join(out_dir, "rvv_scalar_interaction.md")

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    with open(md_path, "w") as f:
        f.write("| case | group | expected | first | second | dispatch_delta | "
                "same_cycle_dispatch | adjacent_dispatch | overlap_cycles | "
                "independent_overlap_supported | control_check | evidence_level | note |\n")
        f.write("| --- | --- | --- | --- | --- | ---: | --- | --- | ---: | --- | --- | --- | --- |\n")
        for row in rows:
            f.write(
                f"| {row['case']} | {row['group']} | {row['expected']} | "
                f"{row['first']} | {row['second']} | "
                f"{row['dispatch_delta_cycles']} | {row['same_cycle_dispatch']} | "
                f"{row['adjacent_cycle_dispatch']} | {row['overlap_cycles']} | "
                f"{row['independent_overlap_supported']} | {row['control_check']} | "
                f"{row['evidence_level']} | {row['note']} |\n")
    return csv_path, md_path


def _write_group_tables(rows):
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", os.getcwd())
    csv_path = os.path.join(out_dir, "rvv_scalar_group_interaction.csv")
    md_path = os.path.join(out_dir, "rvv_scalar_group_interaction.md")

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    with open(md_path, "w") as f:
        f.write("| case | expected_order | load_dispatch_cycles | compute_dispatch_cycles | "
                "cross_group_same_cycle | group_dispatch_separated | lifetime_overlap | "
                "dual_dispatch_excluded_overlap | note |\n")
        f.write("| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n")
        for row in rows:
            f.write(
                f"| {row['case']} | {row['expected_order']} | "
                f"{row['load_dispatch_cycles']} | {row['compute_dispatch_cycles']} | "
                f"{row['cross_group_same_cycle']} | {row['group_dispatch_separated']} | "
                f"{row['lifetime_overlap']} | {row['dual_dispatch_excluded_overlap']} | "
                f"{row['note']} |\n")
    return csv_path, md_path


def _event_template(pc, name):
    return {
        "pc": pc,
        "name": name,
        "dispatch": None,
        "dispatch_lane": None,
        "retire": None,
        "retire_slot": None,
    }


async def _trace_interaction(fixture, dut, pc_to_name, timeout_cycles=200000):
    events = {pc: _event_template(pc, name) for pc, name in pc_to_name.items()}
    outstanding_by_pc = defaultdict(deque)
    cycle = 0

    await fixture.core_mini_axi.execute_from(fixture.entry_point)
    while cycle < timeout_cycles:
        await RisingEdge(dut.io_aclk)
        cycle += 1

        for lane in range(4):
            if _bit(getattr(dut, f"io_debug_dispatch_{lane}_instFire")):
                pc = _u32(getattr(dut, f"io_debug_dispatch_{lane}_instAddr"))
                if pc in events:
                    event = events[pc]
                    if event["dispatch"] is None:
                        event["dispatch"] = cycle
                        event["dispatch_lane"] = lane
                    outstanding_by_pc[pc].append(event)

        for slot in range(8):
            if _bit(getattr(dut, f"io_debug_rb_inst_{slot}_valid")):
                pc = _u32(getattr(dut, f"io_debug_rb_inst_{slot}_bits_pc"))
                if pc in events:
                    event = outstanding_by_pc[pc].popleft() if outstanding_by_pc[pc] else events[pc]
                    if event["retire"] is None:
                        event["retire"] = cycle
                        event["retire_slot"] = slot

        if _bit(dut.io_halted):
            break

    if cycle >= timeout_cycles:
        raise AssertionError(f"rvv_scalar interaction trace timed out after {timeout_cycles} cycles")

    missing = [event["name"] for event in events.values()
               if event["dispatch"] is None or event["retire"] is None]
    if missing:
        raise AssertionError(f"missing dispatch/retire events for: {', '.join(missing)}")

    return events


def _overlap(first, second):
    start = max(first["dispatch"], second["dispatch"])
    end = min(first["retire"], second["retire"])
    return max(0, end - start)


def _summarize(events_by_name):
    rows = []
    for case in CASES:
        first = events_by_name[case["first"]]
        second = events_by_name[case["second"]]
        dispatch_delta = second["dispatch"] - first["dispatch"]
        same_cycle = dispatch_delta == 0
        adjacent = abs(dispatch_delta) == 1
        overlap_cycles = _overlap(first, second)
        observed_overlap = same_cycle or overlap_cycles > 0
        independent_case = case["expected"] == "independent_can_overlap"
        independent_overlap_supported = independent_case and observed_overlap
        control_check = "not_applicable"
        if not independent_case:
            control_check = "serialized" if not same_cycle else "co_dispatched_despite_raw"
        note = []
        if same_cycle:
            note.append("co-dispatched in the same cycle")
        elif adjacent:
            note.append("dispatched in adjacent cycles")
        if overlap_cycles > 0:
            note.append("dispatch-to-retire windows overlap")
        if not note:
            note.append("serialized by observed dispatch/retire windows")
        if not independent_case:
            note.append("RAW dependency control; do not count as independent overlap")

        rows.append({
            "case": case["case"],
            "group": case["group"],
            "expected": case["expected"],
            "purpose": case["purpose"],
            "first": first["name"],
            "second": second["name"],
            "first_dispatch_cycle": first["dispatch"],
            "second_dispatch_cycle": second["dispatch"],
            "dispatch_delta_cycles": dispatch_delta,
            "first_dispatch_lane": first["dispatch_lane"],
            "second_dispatch_lane": second["dispatch_lane"],
            "same_cycle_dispatch": "yes" if same_cycle else "no",
            "adjacent_cycle_dispatch": "yes" if adjacent else "no",
            "first_retire_cycle": first["retire"],
            "second_retire_cycle": second["retire"],
            "overlap_cycles": overlap_cycles,
            "observed_overlap_or_coissue": "yes" if observed_overlap else "no",
            "independent_overlap_supported": "yes" if independent_overlap_supported else "no",
            "control_check": control_check,
            "evidence_level": "top_level_dispatch_and_retire_debug",
            "note": "; ".join(note),
        })
    return rows


def _cycles(events_by_name, names, key):
    return [events_by_name[name][key] for name in names]


def _any_same_cycle(a_cycles, b_cycles):
    return bool(set(a_cycles) & set(b_cycles))


def _window_overlap(a_dispatch, a_retire, b_dispatch, b_retire):
    return max(0, min(max(a_retire), max(b_retire)) - max(min(a_dispatch), min(b_dispatch)))


def _summarize_group_cases(events_by_name):
    rows = []
    for case in GROUP_CASES:
        load_dispatch = _cycles(events_by_name, case["loads"], "dispatch")
        load_retire = _cycles(events_by_name, case["loads"], "retire")
        compute_dispatch = _cycles(events_by_name, case["computes"], "dispatch")
        compute_retire = _cycles(events_by_name, case["computes"], "retire")

        cross_same = _any_same_cycle(load_dispatch, compute_dispatch)
        separated = not cross_same
        lifetime_overlap = _window_overlap(
            load_dispatch, load_retire, compute_dispatch, compute_retire)

        loads_before = max(load_dispatch) < min(compute_dispatch)
        computes_before = max(compute_dispatch) < min(load_dispatch)
        order_ok = (
            (case["expected_order"] == "loads_before_computes" and loads_before)
            or (case["expected_order"] == "computes_before_loads" and computes_before)
            or case["expected_order"] == "mixed"
        )
        dual_dispatch_excluded_overlap = separated and lifetime_overlap > 0 and order_ok

        note = []
        if cross_same:
            note.append("at least one load and compute co-dispatched")
        else:
            note.append("no load/compute pair co-dispatched in the same cycle")
        if lifetime_overlap > 0:
            note.append("load-group and compute-group dispatch-to-retire windows overlap")
        else:
            note.append("load-group and compute-group windows did not overlap")
        if loads_before:
            note.append("all loads dispatched before computes")
        elif computes_before:
            note.append("all computes dispatched before loads")
        else:
            note.append("load/compute dispatch order is mixed")

        rows.append({
            "case": case["case"],
            "group": case["group"],
            "purpose": case["purpose"],
            "expected_order": case["expected_order"],
            "loads": ";".join(case["loads"]),
            "computes": ";".join(case["computes"]),
            "load_dispatch_cycles": ";".join(str(x) for x in load_dispatch),
            "compute_dispatch_cycles": ";".join(str(x) for x in compute_dispatch),
            "load_retire_cycles": ";".join(str(x) for x in load_retire),
            "compute_retire_cycles": ";".join(str(x) for x in compute_retire),
            "cross_group_same_cycle": "yes" if cross_same else "no",
            "group_dispatch_separated": "yes" if separated else "no",
            "lifetime_overlap": lifetime_overlap,
            "dual_dispatch_excluded_overlap": (
                "yes" if dual_dispatch_excluded_overlap else "no"),
            "evidence_level": "top_level_dispatch_and_retire_debug",
            "note": "; ".join(note),
        })
    return rows


@cocotb.test()
async def rvv_scalar_interaction_test(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut, highmem=True)
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/cycle_counter/rvv_scalar/rvv_scalar_interaction.elf")
    symbol_names = sorted(
        {case["first"] for case in CASES}
        | {case["second"] for case in CASES}
        | {name for case in GROUP_CASES for name in case["loads"]}
        | {name for case in GROUP_CASES for name in case["computes"]}
    )
    await fixture.load_elf_and_lookup_symbols(elf_path, symbol_names)

    pc_to_name = {fixture.symbols[name]: name for name in symbol_names}
    events_by_pc = await _trace_interaction(fixture, dut, pc_to_name)
    events_by_name = {event["name"]: event for event in events_by_pc.values()}
    rows = _summarize(events_by_name)
    csv_path, md_path = _write_tables(rows)
    group_rows = _summarize_group_cases(events_by_name)
    group_csv_path, group_md_path = _write_group_tables(group_rows)

    dut._log.info("RVV/scalar interaction table: %s", csv_path)
    dut._log.info("RVV/scalar interaction markdown: %s", md_path)
    dut._log.info("RVV/scalar group interaction table: %s", group_csv_path)
    dut._log.info("RVV/scalar group interaction markdown: %s", group_md_path)
    for row in rows:
        print(
            f"{row['case']}: delta={row['dispatch_delta_cycles']} "
            f"same={row['same_cycle_dispatch']} overlap={row['overlap_cycles']} "
            f"independent_result={row['independent_overlap_supported']} "
            f"control={row['control_check']}")
    for row in group_rows:
        print(
            f"{row['case']}: load_dispatch={row['load_dispatch_cycles']} "
            f"compute_dispatch={row['compute_dispatch_cycles']} "
            f"cross_same={row['cross_group_same_cycle']} "
            f"overlap={row['lifetime_overlap']} "
            f"dual_dispatch_excluded={row['dual_dispatch_excluded_overlap']}")
