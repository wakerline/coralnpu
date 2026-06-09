#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import numpy as np
import yaml


DEFAULT_CONFIG = (
    "/home/wangyy/001_research/ti/tinyml-tensorlab/tinyml-modelmaker/"
    "examples/dc_arc_fault/config_dsk.yaml"
)
DEFAULT_MODELMAKER_ROOT = "/home/wangyy/001_research/ti/tinyml-tensorlab/tinyml-modelmaker"


def _deep_set(config: dict[str, Any], dotted_key: str, value: Any) -> None:
    cur = config
    parts = dotted_key.split(".")
    for key in parts[:-1]:
        cur = cur.setdefault(key, {})
    cur[parts[-1]] = value


def _read_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def _write_yaml(path: Path, config: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(config, f, sort_keys=False)


def _onnx_shape_dtype(path: Path):
    import onnx

    model = onnx.load(str(path))
    initializer_names = {init.name for init in model.graph.initializer}
    for value in model.graph.input:
        if value.name in initializer_names:
            continue
        tensor_type = value.type.tensor_type
        shape = [dim.dim_value if dim.dim_value > 0 else 1 for dim in tensor_type.shape.dim]
        return value.name, tuple(shape), tensor_type.elem_type
    raise ValueError(f"No data input found in {path}")


def _make_sample(path: Path, sample_path: Path) -> dict[str, Any]:
    import onnx

    input_name, shape, elem_type = _onnx_shape_dtype(path)
    dtype = np.float32
    if elem_type != onnx.TensorProto.FLOAT:
        raise ValueError(f"Only float32 ONNX input is currently supported, got elem_type={elem_type}")
    rng = np.random.default_rng(42)
    sample = rng.normal(0.0, 0.25, size=shape).astype(dtype)
    sample_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(sample_path, input=sample)
    return {"input_name": input_name, "input_shape": list(shape), "sample": str(sample_path)}


def _find_latest_onnx(root: Path, dataset_name: str, model_name: str, prefer: str) -> Path:
    run_root = root / "data" / "projects" / dataset_name / "run"
    candidates = sorted(run_root.glob(f"*/{model_name}/training/{prefer}/model.onnx"))
    if candidates:
        return candidates[-1]
    fallback = "base" if prefer == "quantization" else "quantization"
    candidates = sorted(run_root.glob(f"*/{model_name}/training/{fallback}/model.onnx"))
    if candidates:
        return candidates[-1]
    raise FileNotFoundError(f"No model.onnx found under {run_root} for model {model_name}")


def _sibling_model(path: Path, sibling: str) -> Path | None:
    parts = list(path.parts)
    if "training" not in parts:
        return None
    idx = parts.index("training")
    candidate = Path(*parts[: idx + 1], sibling, "model.onnx")
    return candidate if candidate.exists() else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--modelmaker-root", default=DEFAULT_MODELMAKER_ROOT)
    parser.add_argument("--out-dir", default="generated/modelmaker")
    parser.add_argument("--run-name", default="coralnpu_dc_arc_fault")
    parser.add_argument(
        "--model-name",
        default=None,
        help="Override training.model_name, for example TimeSeries_Generic_1k_t.",
    )
    parser.add_argument("--prefer", choices=["quantization", "base"], default="quantization")
    parser.add_argument("--skip-run", action="store_true", help="Reuse the newest existing ModelMaker ONNX.")
    parser.add_argument("--training-epochs", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=None)
    parser.add_argument("--num-gpus", type=int, default=0)
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Override YAML values, for example training.quantization=2.",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    config_path = Path(args.config).resolve()
    modelmaker_root = Path(args.modelmaker_root).resolve()
    out_dir = (root / args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    config = _read_yaml(config_path)
    config["common"]["run_name"] = args.run_name
    if args.model_name:
        config["training"]["model_name"] = args.model_name
    config["training"]["num_gpus"] = args.num_gpus
    if args.training_epochs is not None:
        config["training"]["training_epochs"] = args.training_epochs
    if args.batch_size is not None:
        config["training"]["batch_size"] = args.batch_size
    for item in args.set:
        key, sep, value = item.partition("=")
        if not sep:
            raise ValueError(f"--set expects KEY=VALUE, got {item!r}")
        _deep_set(config, key, yaml.safe_load(value))

    adapted_config = out_dir / "config_modelmaker_coralnpu.yaml"
    _write_yaml(adapted_config, config)

    dataset_name = config["dataset"]["dataset_name"]
    model_name = config["training"]["model_name"]

    if not args.skip_run:
        cmd = [
            "python",
            "tinyml_modelmaker/run_tinyml_modelmaker.py",
            str(adapted_config),
        ]
        env = os.environ.copy()
        env["PYTHONPATH"] = f".:{env.get('PYTHONPATH', '')}"
        subprocess.run(cmd, cwd=modelmaker_root, check=True, env=env)

    selected = _find_latest_onnx(modelmaker_root, dataset_name, model_name, args.prefer)
    selected_copy = out_dir / "model.onnx"
    shutil.copy2(selected, selected_copy)

    copied = {"selected": str(selected), "model": str(selected_copy)}
    for kind in ("base", "quantization"):
        sibling = _sibling_model(selected, kind)
        if sibling is not None:
            dst = out_dir / f"model.{kind}.onnx"
            shutil.copy2(sibling, dst)
            copied[kind] = str(dst)

    sample_info = _make_sample(selected_copy, out_dir / "sample_io.npz")
    manifest = {
        "source_config": str(config_path),
        "adapted_config": str(adapted_config),
        "modelmaker_root": str(modelmaker_root),
        "dataset_name": dataset_name,
        "model_name": model_name,
        "prefer": args.prefer,
        "onnx": copied,
        **sample_info,
        "next_compile_command": (
            f"./run.sh compile -- --model {args.out_dir}/model.onnx "
            f"--sample {args.out_dir}/sample_io.npz --model-format onnx"
        ),
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
