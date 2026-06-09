#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def _parse_first_array(text: str, name: str) -> list[float]:
    match = re.search(rf"{name}\[[^\]]+\]\s*=\s*\{{([^}}]+)\}}", text, re.S)
    if not match:
        raise ValueError(f"Could not find {name} in golden vector")
    return [float(item) for item in re.findall(r"[-+]?\d+(?:\.\d+)?", match.group(1))]


def _c_float_array(name: str, values: np.ndarray) -> str:
    flat = values.astype(np.float32).reshape(-1)
    def literal(value: float) -> str:
        text = f"{float(value):.8g}"
        if "." not in text and "e" not in text.lower():
            text += ".0"
        return f"{text}f"

    body = ", ".join(literal(float(x)) for x in flat)
    return f"static float {name}[{flat.size}] = {{ {body} }};\n"


def _c_int8_array(name: str, values: np.ndarray) -> str:
    flat = values.astype(np.int8).reshape(-1)
    body = ", ".join(str(int(x)) for x in flat)
    return f"static signed char {name}[{flat.size}] = {{ {body} }};\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["float", "quant"], default="quant")
    parser.add_argument("--input-shape", default="1,1,256,1")
    args = parser.parse_args()

    vector_path = ROOT / "golden_vectors" / f"{args.mode}_test_vector.c"
    if not vector_path.exists():
        raise FileNotFoundError(f"Golden vector not found: {vector_path}")

    text = vector_path.read_text(encoding="utf-8")
    input_values = np.asarray(_parse_first_array(text, "model_test_input"), dtype=np.float32)
    output_is_int8 = args.mode == "quant"
    golden_dtype = np.int8 if output_is_int8 else np.float32
    golden_values = np.asarray(_parse_first_array(text, "golden_output"), dtype=golden_dtype)
    shape = tuple(int(x) for x in args.input_shape.split(",") if x)
    if int(np.prod(shape)) != input_values.size:
        raise ValueError(f"Input shape {shape} does not match {input_values.size} values")

    out_dir = ROOT / "generated"
    out_dir.mkdir(parents=True, exist_ok=True)
    sample = input_values.reshape(shape)
    np.savez(out_dir / f"sample_io_{args.mode}.npz", input=sample, golden_output=golden_values)
    np.savez(out_dir / "sample_io.npz", input=sample, golden_output=golden_values)

    header = out_dir / "dlr_model_data.h"
    header.write_text(
        "#ifndef TESTS_COCOTB_TUTORIAL_DLR_TVM_CORALNPU_DLR_MODEL_DATA_H_\n"
        "#define TESTS_COCOTB_TUTORIAL_DLR_TVM_CORALNPU_DLR_MODEL_DATA_H_\n"
        "#include <stddef.h>\n"
        + _c_float_array("kDlrModelInput", input_values)
        + _c_int8_array("kDlrGoldenOutputInt8", golden_values)
        + _c_float_array("kDlrGoldenOutputFloat", golden_values)
        + f"static const size_t kDlrModelInputSize = {input_values.size};\n"
        + f"static const size_t kDlrGoldenOutputSize = {golden_values.size};\n"
        + f"static const int kDlrOutputIsInt8 = {1 if output_is_int8 else 0};\n"
        + "#endif\n",
        encoding="utf-8",
    )

    meta = {
        "mode": args.mode,
        "vector_path": str(vector_path),
        "input_shape": list(shape),
        "input_size": int(input_values.size),
        "golden_output_size": int(golden_values.size),
        "golden_output_dtype": "int8" if output_is_int8 else "float32",
        "sample_npz": str(out_dir / "sample_io.npz"),
        "dlr_header": str(header),
    }
    (out_dir / "sample_io.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
