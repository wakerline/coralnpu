#!/usr/bin/env python3
"""Generate a DC-friendly filelist and patch GUI variables for CoralNPU.

This tool accepts either:
  1. An RTL generation label via --bazel-target/--top-module
  2. A VCS cocotb test label, for example:
       //tests/cocotb/tutorial:vcs_algo_2x2_test_algo_2x2
     which is resolved back to the underlying RTL target and top module.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent

DEFAULT_DC_ROOT = REPO_ROOT / "dc" / "v1-dc"
DEFAULT_BAZEL_TARGET = "//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_emit_verilog"
DEFAULT_TOP = "RvvCoreMiniHighmemAxi"
DEFAULT_DEFINES = [
    "SYNTHESIS",
    "VLEN_128",
    "ZVE32F_ON",
    "TB_SUPPORT",
]
DEFAULT_INCLUDE_DIRS = [
    REPO_ROOT / "hdl" / "verilog" / "rvv" / "inc",
    REPO_ROOT / "hdl" / "verilog" / "rvv" / "design" / "FPnew" / "common_cells" / "inc",
]


def run(cmd: list[str], cwd: Path, stream: bool = False) -> subprocess.CompletedProcess[str]:
    print(f"+ (cd {cwd} && {' '.join(cmd)})", flush=True)
    if stream:
        completed = subprocess.run(
            cmd,
            cwd=str(cwd),
            text=True,
            check=True,
        )
        return completed
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        capture_output=True,
        check=True,
    )


def label_to_package(label: str) -> str:
    if not label.startswith("//") or ":" not in label:
        raise ValueError(f"Unsupported Bazel label: {label}")
    return label[2:].split(":", 1)[0]


def split_label(label: str) -> tuple[str, str]:
    if not label.startswith("//") or ":" not in label:
        raise ValueError(f"Unsupported Bazel label: {label}")
    return tuple(label[2:].split(":", 1))


def build_top_sv_path(bazel_target: str, top_module: str) -> Path:
    package = label_to_package(bazel_target)
    return REPO_ROOT / "bazel-bin" / package / f"{top_module}.sv"


def maybe_bazel_build(bazel_target: str, bazel_config: str, skip_build: bool) -> None:
    if skip_build:
        return
    cmd = ["bazel", "build"]
    if bazel_config:
        cmd.append(f"--config={bazel_config}")
    cmd.append(bazel_target)
    run(cmd, REPO_ROOT, stream=True)


def write_filelist(
    output_path: Path,
    top_sv: Path,
    defines: list[str],
    include_dirs: list[Path],
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    for item in defines:
        lines.append(f"+define+{item}\n")
    for path in include_dirs:
        lines.append(f"+incdir+{path}\n")
    lines.append(f"{top_sv}\n")
    output_path.write_text("".join(lines), encoding="utf-8")


def replace_tcl_var(contents: str, var_name: str, value: str) -> str:
    pattern = re.compile(rf'(?m)^set\s+{re.escape(var_name)}\s+"[^"]*"')
    replacement = f'set {var_name}\t\t\t"{value}"'
    if pattern.search(contents):
        return pattern.sub(replacement, contents, count=1)
    if not contents.endswith("\n"):
        contents += "\n"
    return contents + replacement + "\n"


def _find_macro_blocks(text: str, macro_name: str) -> list[str]:
    blocks: list[str] = []
    needle = f"{macro_name}("
    cursor = 0
    while True:
        start = text.find(needle, cursor)
        if start == -1:
            break
        index = start + len(needle)
        depth = 1
        while index < len(text) and depth > 0:
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
            index += 1
        blocks.append(text[start:index])
        cursor = index
    return blocks


def _extract_first(block: str, pattern: str) -> Optional[str]:
    match = re.search(pattern, block, re.DOTALL)
    return match.group(1) if match else None


def _parse_cocotb_suites(build_path: Path) -> list[dict[str, str]]:
    text = build_path.read_text(encoding="utf-8")
    suites: list[dict[str, str]] = []
    for block in _find_macro_blocks(text, "cocotb_test_suite"):
        name = _extract_first(block, r'name\s*=\s*"([^"]+)"')
        hdl_toplevel = _extract_first(block, r'"hdl_toplevel"\s*:\s*"([^"]+)"')
        vcs_verilog_source = _extract_first(
            block,
            r'vcs_verilog_sources\s*=\s*\[\s*"([^"]+)"',
        )
        if name and hdl_toplevel and vcs_verilog_source:
            suites.append(
                {
                    "name": name,
                    "hdl_toplevel": hdl_toplevel,
                    "vcs_verilog_source": vcs_verilog_source,
                }
            )
    return suites


def resolve_from_test_label(label: str) -> tuple[str, str]:
    package, target = split_label(label)
    if not target.startswith("vcs_"):
        raise ValueError(
            f"Expected a VCS cocotb test label, got target '{target}' from {label}"
        )

    build_path = REPO_ROOT / package / "BUILD"
    if not build_path.exists():
        raise FileNotFoundError(f"BUILD file not found for {label}: {build_path}")

    suites = _parse_cocotb_suites(build_path)
    matches: list[dict[str, str]] = []
    for suite in suites:
        suite_target = f"vcs_{suite['name']}"
        if target == suite_target or target.startswith(f"{suite_target}_"):
            matches.append(suite)

    if not matches:
        raise ValueError(
            f"Could not map test label {label} to a cocotb_test_suite in {build_path}"
        )

    suite = max(matches, key=lambda item: len(item["name"]))
    return suite["vcs_verilog_source"], suite["hdl_toplevel"]


def render_gui_setup(gui_path: Path, design_name: str, vcs_option: str, backup: bool) -> None:
    original = gui_path.read_text(encoding="utf-8")
    if backup:
        backup_path = gui_path.with_suffix(gui_path.suffix + ".orig")
        if not backup_path.exists():
            shutil.copyfile(gui_path, backup_path)

    rendered = replace_tcl_var(original, "GUI_DESIGN_NAME", design_name)
    rendered = replace_tcl_var(rendered, "GUI_VCS_OPTION", vcs_option)
    gui_path.write_text(rendered, encoding="utf-8")


def build_defines(sram_impl: str, extra_defines: list[str]) -> list[str]:
    defines = list(DEFAULT_DEFINES)

    if sram_impl == "generic":
        defines.append("USE_GENERIC")
    elif sram_impl == "tsmc28":
        defines.append("USE_TSMC28")
    else:
        raise ValueError(f"Unsupported SRAM implementation: {sram_impl}")

    for item in extra_defines:
        if item not in defines:
            defines.append(item)

    if "USE_TSMC28" in defines and "USE_GENERIC" in defines:
        defines = [item for item in defines if item != "USE_GENERIC"]

    return defines


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "label",
        nargs="?",
        help=(
            "Optional Bazel label. If a VCS cocotb test label is provided, "
            "the script resolves the corresponding synthesis RTL target "
            "and top module automatically."
        ),
    )
    parser.add_argument("--bazel-target", default=DEFAULT_BAZEL_TARGET)
    parser.add_argument("--bazel-config", default="synthesis")
    parser.add_argument("--top-module", default=DEFAULT_TOP)
    parser.add_argument("--gui-path", default="")
    parser.add_argument("--filelist", default="")
    parser.add_argument(
        "--sram-impl",
        choices=["generic", "tsmc28"],
        default="tsmc28",
        help="Select which SRAM implementation macro is emitted into the filelist.",
    )
    parser.add_argument("--define", action="append", default=[])
    parser.add_argument("--extra-include-dir", action="append", default=[])
    parser.add_argument("--skip-bazel-build", action="store_true")
    parser.add_argument("--no-backup", action="store_true")
    parser.add_argument("--run-dc", action="store_true")
    parser.add_argument(
        "--dc-cmd",
        default="run.cmd",
        help="Command/script to launch inside <dc-root>/run when --run-dc is set.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    bazel_target = args.bazel_target
    top_module = args.top_module
    resolved_from_label = False

    if args.label:
        if args.label.startswith("//") and ":vcs_" in args.label:
            bazel_target, top_module = resolve_from_test_label(args.label)
            resolved_from_label = True
        elif args.label.startswith("//"):
            bazel_target = args.label

    dc_root = DEFAULT_DC_ROOT.resolve()
    gui_path = Path(args.gui_path).resolve() if args.gui_path else dc_root / "global_scripts" / "synopsys_dc.setup.gui"
    run_dir = dc_root / "run"
    filelist = Path(args.filelist).resolve() if args.filelist else run_dir / "coralnpu_dc.f"
    top_sv = build_top_sv_path(bazel_target, top_module)

    maybe_bazel_build(bazel_target, args.bazel_config, args.skip_bazel_build)

    if not top_sv.exists():
        print(f"Top-level SystemVerilog file not found: {top_sv}", file=sys.stderr)
        return 1

    defines = build_defines(args.sram_impl, args.define)

    include_dirs = list(DEFAULT_INCLUDE_DIRS)
    for path in args.extra_include_dir:
        include_dirs.append(Path(path).resolve())

    write_filelist(filelist, top_sv, defines, include_dirs)
    vcs_option = f"-f {filelist.name}"
    render_gui_setup(gui_path, top_module, vcs_option, backup=not args.no_backup)

    if resolved_from_label:
        print(f"Resolved test label: {args.label}")
    print(f"RTL target        : {bazel_target}")
    print(f"Top module        : {top_module}")
    print(f"Generated filelist: {filelist}")
    print(f"Patched GUI file: {gui_path}")
    print(f"GUI_DESIGN_NAME={top_module}")
    print(f"GUI_VCS_OPTION={vcs_option}")

    if args.run_dc:
        cmd = ["bash", args.dc_cmd]
        print(f"+ (cd {run_dir} && {' '.join(cmd)})", flush=True)
        completed = subprocess.run(cmd, cwd=str(run_dir))
        return completed.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
