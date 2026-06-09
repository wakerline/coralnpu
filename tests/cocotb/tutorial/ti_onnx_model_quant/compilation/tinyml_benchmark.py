#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import argparse

from references.common import compilation as compile_scr


def main():
    parser = argparse.ArgumentParser(
        description="Run compilation script",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # -------------------------
    # required / important
    # -------------------------
    parser.add_argument("--model_path", type=str, required=True,
                        help="Path to ONNX model file")
    parser.add_argument("--compilation_path", type=str, required=True,
                        help="Compilation output directory")

    # -------------------------
    # toolchain / target
    # -------------------------
    parser.add_argument("--cross_compiler", type=str, required=True,
                        help="Cross compiler path")
    parser.add_argument("--cross_compiler_options", type=str, required=True,
                        help="Cross compiler options string")
    parser.add_argument("--target", type=str, required=True,
                        help="TVM target")
    parser.add_argument("--target_c_mcpu", type=str, required=True,
                        help="TVM target mcpu for C backend")

    # -------------------------
    # misc
    # -------------------------
    parser.add_argument("--keep_libc_files", action="store_true",
                        help="Keep libc files")
    parser.add_argument("--generic_model", type=str, default="1",
                        help="Pass-through to compilation: --generic-model")
    parser.add_argument("--log_file", type=str, default="",
                        help="Path to run.log (default: <compilation_path>/run.log)")

    args = parser.parse_args()

    # check model file
    if not os.path.exists(args.model_path):
        raise FileNotFoundError(f"model_path not found: {args.model_path}")

    # prepare dirs
    os.makedirs(args.compilation_path, exist_ok=True)

    # default log file
    log_file_path = args.log_file if args.log_file else os.path.join(args.compilation_path, "run.log")

    # build argv for compile_scr
    argv = [
        "--FILE", args.model_path,
        "--output_dir", args.compilation_path,
        "--config", args.compilation_path,
        "--cross_compiler", args.cross_compiler,
        "--cross_compiler_options", args.cross_compiler_options,
        "--target", args.target,
        "--target_c_mcpu", args.target_c_mcpu,
        "--keep_libc_files" if args.keep_libc_files else "--no-keep_libc_files",
        "--lis", log_file_path,
        "--generic-model", args.generic_model,
    ]

    # run compilation
    compile_args = compile_scr.get_args_parser().parse_args(argv)
    exit_flag = compile_scr.run(compile_args)

    return exit_flag


if __name__ == "__main__":
    raise SystemExit(main())
