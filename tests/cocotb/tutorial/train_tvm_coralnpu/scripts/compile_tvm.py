#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tarfile
from pathlib import Path
from typing import Any, Dict, Tuple

import numpy as np

from coral_fakequant_codegen import (
    emit_coral_arc_fault_wrapper,
    extract_coral_arc_fault_spec,
    write_spec_json,
)
from ti_fakequant_relay import rewrite_ti_fakequant_for_rvv


CORAL_RVV_LLVM_TARGET = (
    "llvm "
    "-mtriple=riscv32-unknown-elf "
    "-mcpu=generic-rv32 "
    "-mabi=ilp32 "
    "-fast-math-contract=0 "
    "-mattr=+m,+f,+zve32x,+zbb,+zvl128b"
)


def add_tvm_paths(tvm_root: Path) -> None:
    python_dir = tvm_root / "python"
    if str(python_dir) not in sys.path:
        sys.path.insert(0, str(python_dir))


def _load_frontend(path: Path, sample: np.ndarray, model_format: str):
    import tvm
    from tvm import relay

    fmt = model_format
    if fmt == "auto":
        suffix = path.suffix.lower()
        if suffix == ".onnx":
            fmt = "onnx"
        elif suffix == ".tflite":
            fmt = "tflite"
        elif suffix in {".pt", ".pth", ".torchscript"}:
            fmt = "pytorch"
        else:
            raise ValueError(f"Cannot infer model format from {path}; pass --model-format.")

    if fmt == "onnx":
        import onnx

        model = onnx.load(str(path))
        input_name = _onnx_input_name(model)
        return (relay.frontend.from_onnx(model, freeze_params=True), input_name)

    if fmt == "tflite":
        try:
            import tflite
        except ImportError as exc:
            raise RuntimeError("TFLite frontend requires the tflite Python package.") from exc

        buf = path.read_bytes()
        model = tflite.Model.GetRootAsModel(buf, 0)
        return relay.frontend.from_tflite(
            model,
            shape_dict={"input": tuple(sample.shape)},
            dtype_dict={"input": str(sample.dtype)},
        ), "input"

    if fmt == "pytorch":
        import torch

        scripted = torch.jit.load(str(path), map_location="cpu")
        return relay.frontend.from_pytorch(scripted, [("input", tuple(sample.shape))]), "input"

    raise ValueError(f"Unsupported model format: {model_format}")


def _onnx_input_name(model) -> str:
    initializer_names = {init.name for init in model.graph.initializer}
    for value in model.graph.input:
        if value.name not in initializer_names:
            return value.name
    raise ValueError("ONNX model has no non-initializer graph input")


def _shape_product(shape) -> int:
    out = 1
    for dim in shape:
        out *= int(dim)
    return int(out)


def _resolve_sample_path(root: Path, model_path: Path, sample_arg: str) -> Path:
    sample_path = (root / sample_arg).resolve()
    if sample_arg == "generated/sample_io.npz":
        colocated = model_path.with_name("sample_io.npz")
        if colocated.exists():
            return colocated.resolve()
    return sample_path


def _host_graph_build(mod, params: Dict[str, Any], sample: np.ndarray, input_name: str, opt_level: int):
    import tvm
    from tvm import relay
    from tvm.contrib import graph_executor

    with tvm.transform.PassContext(opt_level=opt_level):
        lib = relay.build(mod, target="llvm", params=params)

    dev = tvm.cpu(0)
    module = graph_executor.create(lib.get_graph_json(), lib.get_lib(), dev)
    module.load_params(relay.save_param_dict(lib.get_params()))
    module.set_input(input_name, tvm.nd.array(sample.astype("float32")))
    module.run()
    return lib, module.get_output(0).numpy()


def _aot_crt_build(
    mod,
    params: Dict[str, Any],
    out_dir: Path,
    opt_level: int,
    tir_vectorize: bool,
    codegen: str,
):
    import tvm
    from tvm import relay
    from tvm.micro import export_model_library_format
    from tvm.relay.backend import Executor, Runtime

    executor = Executor(
        "aot",
        {
            "interface-api": "c",
            "unpacked-api": True,
            "workspace-byte-alignment": 16,
            "constant-byte-alignment": 16,
        },
    )
    runtime = Runtime("crt", {"system-lib": True})

    pass_config = {"tir.disable_vectorize": not tir_vectorize}
    target = "c" if codegen == "c" else CORAL_RVV_LLVM_TARGET
    with tvm.transform.PassContext(opt_level=opt_level, config=pass_config):
        factory = relay.build(
            mod,
            target=target,
            executor=executor,
            runtime=runtime,
            params=params,
            mod_name="default",
        )

    aot_dir = out_dir / "aot"
    if aot_dir.exists():
        shutil.rmtree(aot_dir)
    aot_dir.mkdir(parents=True, exist_ok=True)

    tar_path = out_dir / "model_aot_crt.tar"
    export_model_library_format(factory, str(tar_path))
    with tarfile.open(tar_path) as tar:
        tar.extractall(aot_dir)
    if codegen == "llvm-rvv":
        _emit_c_interface_shim(mod, params, out_dir, aot_dir, executor, runtime, opt_level)
    _sanitize_aot_c_interface_sources(aot_dir)
    _sanitize_aot_const_struct_sources(aot_dir)
    if codegen == "c" and tir_vectorize:
        _sanitize_gnu_vector_sources(aot_dir)
    return factory, tar_path, aot_dir


def _coral_extern_build(
    model_path: Path,
    out_dir: Path,
    sample: np.ndarray,
    golden: np.ndarray,
):
    if model_path.suffix.lower() != ".onnx":
        raise ValueError("coral-rvv-extern currently supports ONNX inputs only")

    spec = extract_coral_arc_fault_spec(model_path)
    spec_path = out_dir / "coral_rvv_spec.json"
    write_spec_json(spec_path, spec)

    aot_dir = out_dir / "aot"
    if aot_dir.exists():
        shutil.rmtree(aot_dir)
    (aot_dir / "codegen" / "host" / "src").mkdir(parents=True, exist_ok=True)
    (aot_dir / "codegen" / "host" / "lib").mkdir(parents=True, exist_ok=True)
    (aot_dir / "codegen" / "host" / "include").mkdir(parents=True, exist_ok=True)
    (aot_dir / "runtime" / "include").mkdir(parents=True, exist_ok=True)

    wrapper = emit_coral_arc_fault_wrapper(aot_dir, spec, sample, golden)
    return spec_path, wrapper, aot_dir


def _emit_c_interface_shim(
    mod,
    params: Dict[str, Any],
    out_dir: Path,
    aot_dir: Path,
    executor,
    runtime,
    opt_level: int,
) -> None:
    import tvm
    from tvm import relay
    from tvm.micro import export_model_library_format

    with tvm.transform.PassContext(opt_level=opt_level, config={"tir.disable_vectorize": True}):
        c_factory = relay.build(
            mod,
            target="c",
            executor=executor,
            runtime=runtime,
            params=params,
            mod_name="default",
        )

    shim_tar_path = out_dir / "model_aot_crt_c_interface.tar"
    shim_dir = out_dir / "aot_c_interface"
    if shim_dir.exists():
        shutil.rmtree(shim_dir)
    shim_dir.mkdir(parents=True, exist_ok=True)
    export_model_library_format(c_factory, str(shim_tar_path))
    with tarfile.open(shim_tar_path) as tar:
        tar.extractall(shim_dir)

    shim_src = shim_dir / "codegen" / "host" / "src" / "default_lib0.c"
    if not shim_src.exists():
        raise RuntimeError(f"Could not find C interface shim at {shim_src}")
    dst_dir = aot_dir / "codegen" / "host" / "src"
    dst_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(shim_src, dst_dir / "default_lib0.c")


def _sanitize_aot_c_interface_sources(aot_dir: Path) -> None:
    lib0 = aot_dir / "codegen" / "host" / "src" / "default_lib0.c"
    if not lib0.exists():
        return
    source = lib0.read_text(encoding="utf-8")
    marker = '#include "tvm/runtime/c_runtime_api.h"'
    start = source.find(marker)
    if start <= 0:
        return
    lib0.write_text(source[start:], encoding="utf-8")


def _sanitize_aot_const_struct_sources(aot_dir: Path) -> None:
    src_dir = aot_dir / "codegen" / "host" / "src"
    if not src_dir.exists():
        return
    for src_path in sorted(src_dir.glob("*.c")):
        source = src_path.read_text(encoding="utf-8")
        updated = source.replace("__attribute__((packed, aligned(16)))", "__attribute__((aligned(16)))")
        if updated != source:
            src_path.write_text(updated, encoding="utf-8")


def _sanitize_gnu_vector_sources(aot_dir: Path) -> None:
    src_dir = aot_dir / "codegen" / "host" / "src"
    for src_path in sorted(src_dir.glob("*.c")):
        source = src_path.read_text(encoding="utf-8")
        vector_types = sorted(
            {
                match.group(0)
                for match in re.finditer(
                    r"\b(?:(?:float|double|int|uint)(?:2|3|4|8|16|32)|(?:u?int(?:8|16|32|64)_t)(?:2|3|4|8|16|32))\b",
                    source,
                )
            }
        )
        if not vector_types:
            continue

        typedefs = []
        float_lanes = []
        for type_name in vector_types:
            fixed_width_match = re.match(r"(u?int(?:8|16|32|64)_t)(\d+)", type_name)
            if fixed_width_match:
                base, lanes_text = fixed_width_match.groups()
            else:
                base_match = re.match(r"(float|double|int|uint)(\d+)", type_name)
                if not base_match:
                    continue
                base, lanes_text = base_match.groups()
            lanes = int(lanes_text)
            if base == "float":
                c_type = "float"
                elem_bytes = 4
                float_lanes.append(lanes)
            elif base == "double":
                c_type = "double"
                elem_bytes = 8
            elif base == "int":
                c_type = "int32_t"
                elem_bytes = 4
            else:
                c_type = "uint32_t" if base == "uint" else base
                elem_bytes = int(re.search(r"(\d+)", c_type).group(1)) // 8
            typedefs.append(
                f"typedef {c_type} {type_name} __attribute__((vector_size({lanes * elem_bytes})));"
            )
        for lanes in sorted(set(float_lanes)):
            mask_type = f"int{lanes}"
            if mask_type not in vector_types:
                typedefs.append(
                    f"typedef int32_t {mask_type} __attribute__((vector_size({lanes * 4})));"
                )

        source = _rewrite_gnu_vector_constructors(source, vector_types)
        source = _rewrite_opencl_vector_swizzles(source)
        source = _rewrite_simple_vector_selects(source, vector_types)
        source = _rewrite_integer_vector_constructors(source)
        source = _rewrite_integer_vector_casts(source)
        source = _rewrite_integer_vector_bitpacks(source)

        helpers, macros = _gnu_vector_math_helpers(sorted(set(float_lanes)))
        header = "#include <stdint.h>\n#include <math.h>\n" + "\n".join(typedefs) + "\n" + helpers
        if "typedef float float4 __attribute__((vector_size(16)))" not in source:
            source = header + source
        source = _insert_vector_macros_after_forward_decls(source, macros)
        src_path.write_text(source, encoding="utf-8")


def _rewrite_gnu_vector_constructors(source: str, vector_types: list[str]) -> str:
    for type_name in sorted(vector_types, key=len, reverse=True):
        source = _rewrite_constructor_pattern(source, f"({type_name})(", f"({type_name}){{")
        source = _rewrite_constructor_pattern(source, f"{type_name}(", f"({type_name}){{")
    return source


def _rewrite_constructor_pattern(source: str, pattern: str, replacement: str) -> str:
    out = []
    pos = 0
    while True:
        start = source.find(pattern, pos)
        if start < 0:
            out.append(source[pos:])
            break
        if start > 0 and (source[start - 1].isalnum() or source[start - 1] == "_"):
            out.append(source[pos : start + len(pattern)])
            pos = start + len(pattern)
            continue
        arg_start = start + len(pattern)
        depth = 1
        i = arg_start
        while i < len(source) and depth:
            if source[i] == "(":
                depth += 1
            elif source[i] == ")":
                depth -= 1
            i += 1
        if depth != 0:
            out.append(source[pos:])
            break
        out.append(source[pos:start])
        out.append(replacement)
        out.append(source[arg_start : i - 1])
        out.append("}")
        pos = i
    return "".join(out)


def _rewrite_opencl_vector_swizzles(source: str) -> str:
    return re.sub(r"\.s([0-9a-fA-F])\b", lambda m: f"[{int(m.group(1), 16)}]", source)


def _rewrite_simple_vector_selects(source: str, vector_types: list[str]) -> str:
    vector_pattern = "|".join(re.escape(t) for t in vector_types)
    simple_select = re.compile(
        r"\((?P<a>[A-Za-z_][A-Za-z0-9_]*)\)\s*"
        r"(?P<cmp>[<>])\s*"
        r"\((?P<b>[A-Za-z_][A-Za-z0-9_]*)\)\s*"
        r"\?\s*\((?P<t>[A-Za-z_][A-Za-z0-9_]*)\)\s*:\s*\((?P<f>[A-Za-z_][A-Za-z0-9_]*)\)"
    )
    rewritten = []
    for line in source.splitlines(keepends=True):
        if not re.search(rf"\b(?:{vector_pattern})\b", line):
            rewritten.append(line)
            continue

        def replace(match: re.Match[str]) -> str:
            a, b = match.group("a"), match.group("b")
            t, f = match.group("t"), match.group("f")
            if t == a and f == b:
                return f"tvm_vselect(({a}) {match.group('cmp')} ({b}), ({a}), ({b}))"
            return match.group(0)

        rewritten.append(simple_select.sub(replace, line))
    return "".join(rewritten)


def _split_top_level_args(expr: str) -> list[str]:
    args = []
    start = 0
    depth = 0
    for idx, ch in enumerate(expr):
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(expr[start:idx].strip())
            start = idx + 1
    tail = expr[start:].strip()
    if tail:
        args.append(tail)
    return args


def _rewrite_integer_vector_constructors(source: str) -> str:
    pattern = re.compile(r"\(int32_t4\)\{\((?P<inner>int8_t4|uint8_t4)\)\{(?P<body>[^{}]+)\}\}")

    def replace(match: re.Match[str]) -> str:
        args = _split_top_level_args(match.group("body"))
        if len(args) != 4:
            return match.group(0)
        return "(int32_t4){" + ", ".join(f"(int32_t)({arg})" for arg in args) + "}"

    rewritten = pattern.sub(replace, source)
    for vector_type, helper in [("uint8_t4", "tvm_narrow_u8x4"), ("float4", "tvm_cast_i32x4_to_f32x4")]:
        rewritten = _rewrite_single_expr_vector_cast(rewritten, vector_type, helper)
    return rewritten


def _rewrite_single_expr_vector_cast(source: str, vector_type: str, helper: str) -> str:
    pattern = f"(({vector_type}){{"
    out = []
    pos = 0
    while True:
        start = source.find(pattern, pos)
        if start < 0:
            out.append(source[pos:])
            break
        body_start = start + len(pattern)
        depth = 1
        i = body_start
        while i < len(source) and depth:
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
            i += 1
        if depth != 0 or i >= len(source) or source[i] != ")":
            out.append(source[pos:])
            break
        body = source[body_start : i - 1]
        args = _split_top_level_args(body)
        out.append(source[pos:start])
        if len(args) == 1:
            out.append(f"{helper}({args[0]})")
        else:
            out.append(source[start : i + 1])
        pos = i + 1
    return "".join(out)


def _rewrite_integer_vector_casts(source: str) -> str:
    source = source.replace("((int32_t4)*(int8_t4*)", "tvm_widen_i8x4(*(int8_t4*)")
    source = source.replace("((int32_t4)*(uint8_t4*)", "tvm_widen_u8x4(*(uint8_t4*)")
    return source


def _rewrite_integer_vector_bitpacks(source: str) -> str:
    pattern = re.compile(
        r"uint8_t4\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
        r"\(\(0x000000ff << 0\) & \((?P<base>[A-Za-z_][A-Za-z0-9_]*)\[(?P<idx>[A-Za-z_][A-Za-z0-9_]*)\[0\]\] << 0\)\)\|"
        r"\(\(0x000000ff << 8\) & \((?P=base)\[(?P=idx)\[1\]\] << 8\)\)\|"
        r"\(\(0x000000ff << 16\) & \((?P=base)\[(?P=idx)\[2\]\] << 16\)\)\|"
        r"\(\(0x000000ff << 24\) & \((?P=base)\[(?P=idx)\[3\]\] << 24\)\);"
    )
    return pattern.sub(
        lambda m: (
            f"uint8_t4 {m.group('name')} = "
            f"(uint8_t4){{{m.group('base')}[{m.group('idx')}[0]], {m.group('base')}[{m.group('idx')}[1]], "
            f"{m.group('base')}[{m.group('idx')}[2]], {m.group('base')}[{m.group('idx')}[3]]}};"
        ),
        source,
    )


def _gnu_vector_math_helpers(lanes_values: list[int]) -> tuple[str, str]:
    lines = []
    for lanes in lanes_values:
        lines.extend(
            [
                f"static inline float{lanes} tvm_fabsf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = fabsf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_floorf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = floorf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_ceilf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = ceilf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_roundf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = roundf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_truncf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = truncf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_sqrtf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = sqrtf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_expf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = expf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_logf{lanes}(float{lanes} x) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = logf(x[i]); return r; }}",
                f"static inline float{lanes} tvm_fmodf{lanes}(float{lanes} x, float{lanes} y) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = fmodf(x[i], y[i]); return r; }}",
                f"static inline float{lanes} tvm_vselect_float{lanes}(int{lanes} m, float{lanes} a, float{lanes} b) {{ float{lanes} r; for (int i = 0; i < {lanes}; ++i) r[i] = m[i] ? a[i] : b[i]; return r; }}",
            ]
        )
    lines.extend(
        [
            "static inline int32_t4 tvm_widen_i8x4(int8_t4 x) { return (int32_t4){(int32_t)x[0], (int32_t)x[1], (int32_t)x[2], (int32_t)x[3]}; }",
            "static inline int32_t4 tvm_widen_u8x4(uint8_t4 x) { return (int32_t4){(int32_t)x[0], (int32_t)x[1], (int32_t)x[2], (int32_t)x[3]}; }",
            "static inline uint8_t4 tvm_narrow_u8x4(int32_t4 x) { return (uint8_t4){(uint8_t)x[0], (uint8_t)x[1], (uint8_t)x[2], (uint8_t)x[3]}; }",
            "static inline float4 tvm_cast_i32x4_to_f32x4(int32_t4 x) { return (float4){(float)x[0], (float)x[1], (float)x[2], (float)x[3]}; }",
            "static inline int32_t4 tvm_vselect_int32_t4(int32_t4 m, int32_t4 a, int32_t4 b) { int32_t4 r; for (int i = 0; i < 4; ++i) r[i] = m[i] ? a[i] : b[i]; return r; }",
            "static inline uint8_t4 tvm_vselect_uint8_t4(uint8_t4 m, uint8_t4 a, uint8_t4 b) { uint8_t4 r; for (int i = 0; i < 4; ++i) r[i] = m[i] ? a[i] : b[i]; return r; }",
        ]
    )
    generic_unary = {
        "fabsf": "tvm_fabsf",
        "floorf": "tvm_floorf",
        "ceilf": "tvm_ceilf",
        "roundf": "tvm_roundf",
        "truncf": "tvm_truncf",
        "sqrtf": "tvm_sqrtf",
        "expf": "tvm_expf",
        "logf": "tvm_logf",
    }
    macro_lines = []
    for fn, helper_prefix in generic_unary.items():
        choices = ", ".join(f"float{lanes}: {helper_prefix}{lanes}" for lanes in lanes_values)
        macro_lines.append(f"#define {fn}(x) _Generic((x), {choices}, default: {fn})(x)")
    fmod_choices = ", ".join(f"float{lanes}: tvm_fmodf{lanes}" for lanes in lanes_values)
    select_choices = ", ".join(
        [*(f"float{lanes}: tvm_vselect_float{lanes}" for lanes in lanes_values), "int32_t4: tvm_vselect_int32_t4", "uint8_t4: tvm_vselect_uint8_t4"]
    )
    if fmod_choices:
        macro_lines.append(f"#define fmodf(x, y) _Generic((x), {fmod_choices}, default: fmodf)(x, y)")
    macro_lines.append(f"#define tvm_vselect(m, a, b) _Generic((a), {select_choices})(m, a, b)")
    return "\n".join(lines) + "\n", "\n".join(macro_lines) + "\n"


def _insert_vector_macros_after_forward_decls(source: str, macros: str) -> str:
    if not macros or "#define tvm_vselect" in source:
        return source
    lines = source.splitlines(keepends=True)
    insert_at = None
    for idx, line in enumerate(lines):
        if line.rstrip().endswith("{") and "TVM_DLL" in line:
            insert_at = idx
            break
    if insert_at is None:
        return source + "\n" + macros
    return "".join(lines[:insert_at]) + macros + "".join(lines[insert_at:])


def _parse_tvmgen_fields(header_path: Path, struct_name: str) -> list[str]:
    header = header_path.read_text(encoding="utf-8")
    match = re.search(rf"struct\s+{re.escape(struct_name)}\s*\{{(?P<body>.*?)\}};", header, re.S)
    if not match:
        raise ValueError(f"Could not find {struct_name} in {header_path}")
    fields = re.findall(r"\bvoid\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*;", match.group("body"))
    if not fields:
        raise ValueError(f"{struct_name} has no void* tensor fields in {header_path}")
    return fields


def _emit_baremetal_wrapper(aot_dir: Path, sample: np.ndarray, golden: np.ndarray) -> Path:
    input_flat = sample.astype("float32").reshape(-1)
    output_flat = golden.astype("float32").reshape(-1)
    cc_path = aot_dir / "coral_baremetal_main.cc"
    header_path = aot_dir / "codegen" / "host" / "include" / "tvmgen_default.h"
    input_fields = _parse_tvmgen_fields(header_path, "tvmgen_default_inputs")
    output_fields = _parse_tvmgen_fields(header_path, "tvmgen_default_outputs")
    input_inits = "\n".join(f"    .{field} = model_input," for field in input_fields)
    output_inits = "\n".join(f"    .{field} = model_output," for field in output_fields)
    cc_path.write_text(
        f"""#include <cstdint>

#include "tvmgen_default.h"

extern "C" {{
float model_input[{input_flat.size}] __attribute__((section(".data"), aligned(16))) = {{0}};
float model_output[{output_flat.size}] __attribute__((section(".data"), aligned(16))) = {{0}};
volatile int32_t model_status __attribute__((section(".data"))) = 0;
volatile uint32_t model_cycles __attribute__((section(".data"))) = 0;
}}

extern "C" void CoralNPUModelRun() {{
  model_status = 10;
  struct tvmgen_default_inputs inputs = {{
{input_inits}
  }};
  struct tvmgen_default_outputs outputs = {{
{output_inits}
  }};

  model_status = 20;
  int32_t rc = tvmgen_default_run(&inputs, &outputs);
  model_cycles = TVMGEN_DEFAULT_WORKSPACE_SIZE + sizeof(model_input) + sizeof(model_output);
  model_status = (rc == 0) ? 1 : -rc;
}}

int main() {{
  CoralNPUModelRun();
  return 0;
}}
""",
        encoding="utf-8",
    )
    return cc_path


def _emit_io_json(out_dir: Path, sample: np.ndarray, golden: np.ndarray, metadata: Dict[str, Any]) -> Path:
    io_path = out_dir / "model_io.json"
    payload = {
        "input": [float(x) for x in sample.astype("float32").reshape(-1)],
        "golden_output": [float(x) for x in golden.astype("float32").reshape(-1)],
        "input_dtype": "float32",
        "output_dtype": "float32",
        "input_shape": list(sample.shape),
        "output_shape": list(golden.shape),
        "input_dim": _shape_product(sample.shape),
        "output_dim": _shape_product(golden.shape),
        "compile_report": metadata,
    }
    io_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return io_path


def _write_compile_report(path: Path, metadata: Dict[str, Any]) -> None:
    path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def _collect_aot_objects(aot_dir: Path) -> list[str]:
    lib_dir = aot_dir / "codegen" / "host" / "lib"
    if not lib_dir.exists():
        return []
    return [str(path) for path in sorted(lib_dir.glob("*.o"))]


def _collect_aot_sources(aot_dir: Path) -> list[str]:
    src_dir = aot_dir / "codegen" / "host" / "src"
    if not src_dir.exists():
        return []
    return [str(path) for path in sorted(src_dir.glob("*.[cC]"))]


def _write_relay_dump(out_dir: Path, name: str, mod) -> Path:
    path = out_dir / name
    path.write_text(str(mod), encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", default="generated/model.fp32.onnx", help="Backward compatible alias for --model.")
    parser.add_argument("--model", default=None)
    parser.add_argument("--model-format", choices=["auto", "onnx", "tflite", "pytorch"], default="auto")
    parser.add_argument("--sample", default="generated/sample_io.npz")
    parser.add_argument("--out-dir", default="generated/tvm")
    parser.add_argument("--tvm-root", default="/home/wangyy/001_research/tvm_v18")
    parser.add_argument("--target", choices=["host", "rvv"], default="host")
    parser.add_argument(
        "--codegen",
        choices=["c", "llvm-rvv", "coral-rvv-extern"],
        default="c",
        help=(
            "Operator backend. llvm-rvv emits RISC-V objects from TVM/LLVM. "
            "coral-rvv-extern emits a Coral RVV wrapper for the supported TI fake-quant graph."
        ),
    )
    parser.add_argument("--opt-level", type=int, default=3)
    parser.add_argument(
        "--disable-tir-vectorize",
        action="store_false",
        dest="tir_vectorize",
        default=True,
        help="Disable TVM TIR vectorization for maximum C portability.",
    )
    parser.add_argument(
        "--enable-tir-vectorize",
        action="store_true",
        dest="tir_vectorize",
        help="Enable TVM TIR vectorization for Coral RVV-oriented builds.",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    tvm_root = Path(args.tvm_root).resolve()
    add_tvm_paths(tvm_root)

    model_path = (root / (args.model or args.onnx)).resolve()
    sample_path = _resolve_sample_path(root, model_path, args.sample)
    out_dir = (root / args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    sample = np.load(sample_path)["input"].astype("float32")
    (mod, params), input_name = _load_frontend(model_path, sample, args.model_format)
    frontend_relay_path = _write_relay_dump(out_dir, "frontend.relay", mod)

    rvv_fakequant_rewrite = False
    if args.target == "rvv" and args.codegen == "c":
        rewritten_mod = rewrite_ti_fakequant_for_rvv(mod)
        if str(rewritten_mod) != str(mod):
            mod = rewritten_mod
            rvv_fakequant_rewrite = True
    relay_path = _write_relay_dump(out_dir, "compile_input.relay", mod)

    host_lib, host_output = _host_graph_build(mod, params, sample, input_name, args.opt_level)
    np.save(out_dir / "host_output.npy", host_output)

    lib_path = out_dir / "libmodel.so"
    graph_path = out_dir / "graph.json"
    params_path = out_dir / "params.bin"
    host_lib.export_library(str(lib_path))
    graph_path.write_text(host_lib.get_graph_json(), encoding="utf-8")
    from tvm import relay

    params_path.write_bytes(relay.save_param_dict(host_lib.get_params()))

    if args.codegen in {"llvm-rvv", "coral-rvv-extern"} and args.target != "rvv":
        raise ValueError(f"--codegen {args.codegen} requires --target rvv")

    tar_path = None
    coral_spec_path = None
    if args.codegen == "coral-rvv-extern":
        coral_spec_path, wrapper, aot_dir = _coral_extern_build(model_path, out_dir, sample, host_output)
        aot_sources = [str(wrapper)]
        aot_objects = []
    else:
        _factory, tar_path, aot_dir = _aot_crt_build(
            mod, params, out_dir, args.opt_level, args.tir_vectorize, args.codegen
        )
        wrapper = _emit_baremetal_wrapper(aot_dir, sample, host_output)
        aot_sources = _collect_aot_sources(aot_dir)
        aot_objects = _collect_aot_objects(aot_dir)
        if args.codegen == "llvm-rvv" and not aot_objects:
            raise RuntimeError(f"LLVM/RVV codegen did not emit object files under {aot_dir}")

    metadata = {
        "architecture": [
            "ONNX/TFLite/PyTorch frontend",
            "TVM 0.18 Relay/TIR optimization",
            f"AOT executor + CRT system-lib {args.codegen} codegen",
            "Coral bare-metal wrapper main()",
            "riscv32 Coral toolchain ELF",
            "RvvCoreMiniHighmemAxi Verilator RTL simulation",
            "symbol output check / software cycle counter / optional VCD",
        ],
        "model": str(model_path),
        "model_format": args.model_format,
        "host_library": str(lib_path),
        "host_graph": str(graph_path),
        "host_params": str(params_path),
        "frontend_relay": str(frontend_relay_path),
        "compile_input_relay": str(relay_path),
        "aot_mlf": str(tar_path) if tar_path is not None else "",
        "aot_dir": str(aot_dir),
        "aot_codegen": args.codegen,
        "aot_sources": aot_sources,
        "aot_objects": aot_objects,
        "baremetal_wrapper": str(wrapper),
        "coral_spec": str(coral_spec_path) if coral_spec_path is not None else "",
        "input_shape": list(sample.shape),
        "input_name": input_name,
        "output_shape": list(host_output.shape),
        "tvm_root": str(tvm_root),
        "rtl_target": "RvvCoreMiniHighmemAxi",
        "riscv_isa": "rv32imf_zve32x_zicsr_zifencei_zbb",
        "tvm_target": (
            CORAL_RVV_LLVM_TARGET
            if args.codegen == "llvm-rvv"
            else ("coral-rvv-extern" if args.codegen == "coral-rvv-extern" else "c")
        ),
        "tir_vectorize": bool(args.tir_vectorize),
        "rvv_fakequant_rewrite": rvv_fakequant_rewrite,
        "riscv_acceleration_note": (
            "C codegen uses TVM AOT/CRT C as the source of truth and lets the Coral RISC-V "
            "compiler lower GNU vector extensions. llvm-rvv codegen asks TVM/LLVM to emit "
            "RISC-V ELF objects directly for the Coral RV32IMF_Zve32x target. "
            "coral-rvv-extern keeps the TVM frontend/host verification flow but emits a "
            "Coral RVV wrapper for the supported TI fake-quant 1D CNN graph."
        ),
    }
    io_path = _emit_io_json(out_dir, sample, host_output, metadata)
    metadata["model_io"] = str(io_path)
    _write_compile_report(out_dir / "compile_report.json", metadata)
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
