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


RVV_INSTRUCTIONS = [
    "baseline_nop",
    "vsetvli",
    "vsetivli",
    "vle8_v",
    "vle16_v",
    "vle32_v",
    "vse8_v",
    "vse16_v",
    "vse32_v",
    "vlse8_v",
    "vlse16_v",
    "vlse32_v",
    "vsse8_v",
    "vsse16_v",
    "vsse32_v",
    "vluxei8_v",
    "vluxei16_v",
    "vluxei32_v",
    "vsuxei8_v",
    "vsuxei16_v",
    "vsuxei32_v",
    "vadd_vv",
    "vadd_vx",
    "vadd_vi",
    "vsub_vv",
    "vsub_vx",
    "vrsub_vx",
    "vrsub_vi",
    "vand_vv",
    "vand_vx",
    "vand_vi",
    "vor_vv",
    "vor_vx",
    "vor_vi",
    "vxor_vv",
    "vxor_vx",
    "vxor_vi",
    "vsll_vv",
    "vsll_vx",
    "vsll_vi",
    "vsrl_vv",
    "vsrl_vx",
    "vsrl_vi",
    "vsra_vv",
    "vsra_vx",
    "vsra_vi",
    "vminu_vv",
    "vmin_vv",
    "vmaxu_vv",
    "vmax_vv",
    "vmseq_vv",
    "vmsne_vv",
    "vmsltu_vv",
    "vmslt_vv",
    "vmsleu_vv",
    "vmsle_vv",
    "vmsgtu_vx",
    "vmsgt_vx",
    "vmul_vv",
    "vmulh_vv",
    "vmulhu_vv",
    "vmulhsu_vv",
    "vdivu_vv",
    "vdiv_vv",
    "vremu_vv",
    "vrem_vv",
    "vmerge_vvm",
    "vmv_v_v",
    "vmv_v_x",
    "vmv_v_i",
    "vslideup_vx",
    "vslidedown_vx",
    "vslide1up_vx",
    "vslide1down_vx",
    "vrgather_vv",
    "vrgather_vx",
    "vrgather_vi",
    "vcompress_vm",
    "vredsum_vs",
    "vredmaxu_vs",
    "vredmax_vs",
    "vredminu_vs",
    "vredmin_vs",
    "vredand_vs",
    "vredor_vs",
    "vredxor_vs",
    "vcpop_m",
    "vfirst_m",
    "vmsbf_m",
    "vmsof_m",
    "vmsif_m",
    "viota_m",
    "vwadd_vv",
    "vwaddu_vv",
    "vwsub_vv",
    "vwsubu_vv",
    "vnsrl_wv",
    "vnsra_wv",
    "vsetvl",
    "vlm_v",
    "vsm_v",
    "vloxei8_v",
    "vloxei16_v",
    "vloxei32_v",
    "vsoxei8_v",
    "vsoxei16_v",
    "vsoxei32_v",
    "vl1re32_v",
    "vl2re32_v",
    "vl4re32_v",
    "vl8re32_v",
    "vs1r_v",
    "vs2r_v",
    "vs4r_v",
    "vs8r_v",
    "vle8ff_v",
    "vle16ff_v",
    "vle32ff_v",
    "vmseq_vx",
    "vmseq_vi",
    "vmsne_vx",
    "vmsne_vi",
    "vmsltu_vx",
    "vmslt_vx",
    "vmsleu_vx",
    "vmsleu_vi",
    "vmsle_vx",
    "vmsle_vi",
    "vmsgtu_vi",
    "vmsgt_vi",
    "vminu_vx",
    "vmin_vx",
    "vmaxu_vx",
    "vmax_vx",
    "vmul_vx",
    "vmulh_vx",
    "vmulhu_vx",
    "vmulhsu_vx",
    "vdivu_vx",
    "vdiv_vx",
    "vremu_vx",
    "vrem_vx",
    "vadc_vvm",
    "vmadc_vvm",
    "vsbc_vvm",
    "vmsbc_vvm",
    "vwaddu_vx",
    "vwadd_vx",
    "vwsubu_vx",
    "vwsub_vx",
    "vwaddu_wv",
    "vwaddu_wx",
    "vwadd_wv",
    "vwadd_wx",
    "vwsubu_wv",
    "vwsubu_wx",
    "vwsub_wv",
    "vwsub_wx",
    "vnsrl_wx",
    "vnsrl_wi",
    "vnsra_wx",
    "vnsra_wi",
    "vzext_vf2",
    "vzext_vf4",
    "vzext_vf8",
    "vsext_vf2",
    "vsext_vf4",
    "vsext_vf8",
    "vwmulu_vv",
    "vwmulu_vx",
    "vwmul_vv",
    "vwmul_vx",
    "vwmulsu_vv",
    "vwmulsu_vx",
    "vmacc_vv",
    "vmacc_vx",
    "vnmsac_vv",
    "vnmsac_vx",
    "vmadd_vv",
    "vmadd_vx",
    "vnmsub_vv",
    "vnmsub_vx",
    "vwmaccu_vv",
    "vwmaccu_vx",
    "vwmacc_vv",
    "vwmacc_vx",
    "vwmaccsu_vv",
    "vwmaccsu_vx",
    "vwmaccus_vx",
    "vsaddu_vv",
    "vsaddu_vx",
    "vsaddu_vi",
    "vsadd_vv",
    "vsadd_vx",
    "vsadd_vi",
    "vssubu_vv",
    "vssubu_vx",
    "vssub_vv",
    "vssub_vx",
    "vaaddu_vv",
    "vaaddu_vx",
    "vaadd_vv",
    "vaadd_vx",
    "vasubu_vv",
    "vasubu_vx",
    "vasub_vv",
    "vasub_vx",
    "vsmul_vv",
    "vsmul_vx",
    "vssrl_vv",
    "vssrl_vx",
    "vssrl_vi",
    "vssra_vv",
    "vssra_vx",
    "vssra_vi",
    "vnclipu_wv",
    "vnclipu_wx",
    "vnclipu_wi",
    "vnclip_wv",
    "vnclip_wx",
    "vnclip_wi",
    "vmand_mm",
    "vmnand_mm",
    "vmandnot_mm",
    "vmxor_mm",
    "vmor_mm",
    "vmnor_mm",
    "vmornot_mm",
    "vmxnor_mm",
    "vmv_x_s",
    "vmv_s_x",
    "vmv1r_v",
    "vmv2r_v",
    "vmv4r_v",
    "vmv8r_v",
    "vmerge_vxm",
    "vmerge_vim",
    "vslideup_vi",
    "vslidedown_vi",
    "vrgatherei16_vv",
    "vid_v",
    "vwredsumu_vs",
    "vwredsum_vs",
    "vlseg2e32_v",
    "vsseg2e32_v",
    "vlsseg2e32_v",
    "vssseg2e32_v",
    "vluxseg2ei32_v",
    "vsuxseg2ei32_v",
    "vloxseg2ei32_v",
    "vsoxseg2ei32_v",
]

RVV_SKIPPED_INSTRUCTIONS = {
    "vwsub_wx",
    "vzext_vf4",
    "vzext_vf8",
    "vsext_vf2",
    "vsext_vf4",
    "vsext_vf8",
}

RVV_BARRIER_ONLY_INSTRUCTIONS = {
    "baseline_nop",
    "vsetvli",
    "vsetivli",
    "vsetvl",
    "vlm_v",
    "vsm_v",
    "vle8_v",
    "vle16_v",
    "vle32_v",
    "vse8_v",
    "vse16_v",
    "vse32_v",
    "vlse8_v",
    "vlse16_v",
    "vlse32_v",
    "vsse8_v",
    "vsse16_v",
    "vsse32_v",
    "vluxei8_v",
    "vluxei16_v",
    "vluxei32_v",
    "vsuxei8_v",
    "vsuxei16_v",
    "vsuxei32_v",
    "vloxei8_v",
    "vloxei16_v",
    "vloxei32_v",
    "vsoxei8_v",
    "vsoxei16_v",
    "vsoxei32_v",
    "vl1re32_v",
    "vl2re32_v",
    "vl4re32_v",
    "vl8re32_v",
    "vs1r_v",
    "vs2r_v",
    "vs4r_v",
    "vs8r_v",
    "vle8ff_v",
    "vle16ff_v",
    "vle32ff_v",
    "vlseg2e32_v",
    "vsseg2e32_v",
    "vlsseg2e32_v",
    "vssseg2e32_v",
    "vluxseg2ei32_v",
    "vsuxseg2ei32_v",
    "vloxseg2ei32_v",
    "vsoxseg2ei32_v",
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
async def rvv_instruction_cycle_counter_test(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut, highmem=True)
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/cycle_counter/rvv/rvv_cycle_counter.elf")
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        [
            "cycle_counter_num_tests",
            "cycle_counter_repeat_count",
            "cycle_counter_overhead_cycles_lo",
            "cycle_counter_overhead_cycles_hi",
            "cycle_counter_serial_barrier_cycles_lo",
            "cycle_counter_serial_barrier_cycles_hi",
            "cycle_counter_current_test",
            "cycle_counter_cycles_lo",
            "cycle_counter_cycles_hi",
            "cycle_counter_instret_lo",
            "cycle_counter_instret_hi",
        ] + pc_range_symbol_names(len(RVV_INSTRUCTIONS)),
    )

    num_tests = int((await fixture.read_word("cycle_counter_num_tests")).view(np.uint32)[0])
    repeat_count = int((await fixture.read_word("cycle_counter_repeat_count")).view(np.uint32)[0])
    assert num_tests == len(RVV_INSTRUCTIONS)
    pc_ranges = symbol_pc_ranges(fixture, num_tests)
    try:
        pipeline_samples = await run_and_trace_pipeline(
            fixture,
            dut,
            pc_ranges,
            RVV_INSTRUCTIONS,
            timeout_cycles=100000,
        )
    except AssertionError as err:
        current = int((await fixture.read_word("cycle_counter_current_test")).view(np.uint32)[0])
        name = RVV_INSTRUCTIONS[current] if current < len(RVV_INSTRUCTIONS) else "unknown"
        raise AssertionError(f"{err}; RVV current index {current}: {name}")

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
    for i, instruction in enumerate(RVV_INSTRUCTIONS):
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
                "skipped_core_hangs"
                if instruction in RVV_SKIPPED_INSTRUCTIONS else "measured"),
            "serialization_status": (
                "serializing_barrier_only"
                if instruction in RVV_BARRIER_ONLY_INSTRUCTIONS else
                "raw_chain_or_barrier_serialized"),
        })

    csv_path, md_path = _write_tables(rows, "rvv_instruction_cycles")
    pipeline_rows = summarize_pipeline_trace(pipeline_samples, RVV_INSTRUCTIONS)
    pipeline_csv_path, pipeline_md_path = write_pipeline_tables(
        pipeline_rows, "rvv_pipeline_cycles")
    dut._log.info("RVV instruction cycle table: %s", csv_path)
    dut._log.info("RVV instruction cycle markdown: %s", md_path)
    dut._log.info("RVV pipeline cycle table: %s", pipeline_csv_path)
    dut._log.info("RVV pipeline cycle markdown: %s", pipeline_md_path)
    for row in rows:
        print(
            f"RVV {row['instruction']}: cycles={row['adjusted_cycles']} "
            f"repeat={repeat_count} cpi={row['cpi']}",
            flush=True)
