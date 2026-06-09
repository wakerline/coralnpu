#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coralnpu-root", default="/home/wangyy/002_research/coralnpu")
    parser.add_argument("--target", default="//tests/cocotb/tutorial/train_tvm_coralnpu:cocotb_coralnpu_model")
    parser.add_argument("--simulator", default="verilator")
    parser.add_argument("--testcase", default="test_generated_model_on_rvv_highmem")
    parser.add_argument("--timeout-cycles", type=int, default=None)
    parser.add_argument("--extra-arg", action="append", default=[])
    args = parser.parse_args()

    cmd = [
        "bazel",
        "--batch",
        "test",
        args.target,
        "--test_output=streamed",
        f"--test_arg=--simulator={args.simulator}",
        f"--test_arg=--testcase={args.testcase}",
    ] + args.extra_arg
    if args.timeout_cycles is not None:
        cmd.append(f"--test_env=CORAL_TUTORIAL_TIMEOUT_CYCLES={args.timeout_cycles}")
    print(" ".join(cmd))
    return subprocess.call(cmd, cwd=Path(args.coralnpu_root))


if __name__ == "__main__":
    raise SystemExit(main())
