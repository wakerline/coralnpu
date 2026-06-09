#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib
import json
from pathlib import Path
import sys
from typing import Iterable, Tuple

import numpy as np
import torch
from torch import nn


def parse_shape(value: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in value.replace("x", ",").split(",") if part)


def load_symbol(spec: str):
    module_name, func_name = spec.split(":", 1)
    return getattr(importlib.import_module(module_name), func_name)


def default_batches(input_shape, num_classes, batches, batch_size):
    feature_shape = input_shape[1:]
    for _ in range(batches):
        x = torch.randn((batch_size, *feature_shape), dtype=torch.float32)
        y = torch.randint(0, num_classes, (batch_size,), dtype=torch.long)
        yield x, y


def train(model: nn.Module, data: Iterable, epochs: int, lr: float) -> None:
    model.train()
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    loss_fn = nn.CrossEntropyLoss()
    for _ in range(epochs):
        for x, y in data:
            opt.zero_grad(set_to_none=True)
            loss = loss_fn(model(x), y)
            loss.backward()
            opt.step()


def export_onnx(model: nn.Module, sample: torch.Tensor, output: Path, opset: int) -> None:
    model.eval()
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        model,
        sample,
        output,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
        opset_version=opset,
    )


def quantize_onnx(fp32_path: Path, quant_path: Path) -> None:
    try:
        from onnxruntime.quantization import QuantType, quantize_dynamic
    except ImportError as exc:
        raise SystemExit(
            "onnxruntime is required for ONNX quantization. "
            "Install onnxruntime or pass --quantize none."
        ) from exc
    quantize_dynamic(str(fp32_path), str(quant_path), weight_type=QuantType.QInt8)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-factory", default="models.default_model:create_model")
    parser.add_argument("--data-factory", default="")
    parser.add_argument("--input-shape", default="1,16")
    parser.add_argument("--num-classes", type=int, default=4)
    parser.add_argument("--epochs", type=int, default=2)
    parser.add_argument("--batches", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--opset", type=int, default=17)
    parser.add_argument("--quantize", choices=["dynamic", "none"], default="dynamic")
    parser.add_argument("--out-dir", default="generated")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root))
    out_dir = (root / args.out_dir).resolve()
    input_shape = parse_shape(args.input_shape)

    factory = load_symbol(args.model_factory)
    built = factory()
    if isinstance(built, tuple):
        model, factory_shape = built
        input_shape = tuple(factory_shape)
    else:
        model = built

    if args.data_factory:
        data = load_symbol(args.data_factory)()
    else:
        data = default_batches(input_shape, args.num_classes, args.batches, args.batch_size)
    train(model, data, args.epochs, args.lr)

    sample = torch.randn(input_shape, dtype=torch.float32)
    fp32_onnx = out_dir / "model.fp32.onnx"
    export_onnx(model, sample, fp32_onnx, args.opset)

    final_onnx = fp32_onnx
    if args.quantize == "dynamic":
        final_onnx = out_dir / "model.quant.onnx"
        quantize_onnx(fp32_onnx, final_onnx)

    np.savez(out_dir / "sample_io.npz", input=sample.numpy())
    metadata = {
        "input_name": "input",
        "output_name": "output",
        "input_shape": list(input_shape),
        "fp32_onnx": str(fp32_onnx),
        "onnx": str(final_onnx),
        "quantize": args.quantize,
    }
    (out_dir / "train_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
