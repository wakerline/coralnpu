# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
from pathlib import Path

import numpy as np


def _write_vector(path, values, output, output_type):
    values_text = ", ".join(f"{v:.5f}" for v in values)
    output_text = ", ".join(str(int(v)) if output_type == "int8_t" else f"{v:.6f}" for v in output)
    path.write_text(
        "#include <stdint.h>\n"
        "typedef float float32_t;\n\n"
        f"float32_t model_test_input[256] = {{ {values_text}, }} ;\n"
        f"{output_type} golden_output[2] = {{ {output_text}, }} ;\n"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--samples", type=int, default=2048)
    parser.add_argument("--skip-quant", action="store_true")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    root = Path(__file__).resolve().parent
    (root / "onnx/float").mkdir(parents=True, exist_ok=True)
    (root / "onnx/quant").mkdir(parents=True, exist_ok=True)
    (root / "golden_vectors").mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(args.seed)
    x = rng.normal(loc=-20.0, scale=25.0, size=(args.samples, 256)).astype(np.float32)
    score = x[:, 80:140].mean(axis=1) - x[:, :40].mean(axis=1)
    y = (score > np.median(score)).astype(np.int64)

    torch.manual_seed(args.seed)
    model = nn.Sequential(
        nn.Linear(256, 64),
        nn.ReLU(),
        nn.Linear(64, 16),
        nn.ReLU(),
        nn.Linear(16, 2),
    )

    optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
    features = torch.from_numpy(x)
    labels = torch.from_numpy(y)
    for _ in range(args.epochs):
        permutation = torch.randperm(features.shape[0])
        for start in range(0, features.shape[0], args.batch_size):
            batch = permutation[start : start + args.batch_size]
            loss = F.cross_entropy(model(features[batch]), labels[batch])
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

    model.eval()
    example = torch.from_numpy(x[:1])
    float_onnx = root / "onnx/float/model.onnx"
    torch.onnx.export(
        model,
        example,
        float_onnx,
        input_names=["onnx::Add_0"],
        output_names=["output"],
        dynamic_axes=None,
        opset_version=13,
    )

    with torch.no_grad():
        float_output = model(example).numpy()[0].astype(np.float32)
    _write_vector(root / "golden_vectors/float_test_vector.c", x[0], float_output, "float")

    if not args.skip_quant:
        try:
            from onnxruntime.quantization import QuantType, quantize_dynamic
        except ImportError as exc:
            raise SystemExit(
                "onnxruntime is required for --skip-quant=False. "
                "Install onnxruntime or rerun with --skip-quant."
            ) from exc

        quant_onnx = root / "onnx/quant/model.onnx"
        quantize_dynamic(float_onnx, quant_onnx, weight_type=QuantType.QInt8)
        quant_output = np.clip(np.rint(float_output * 16), -128, 127).astype(np.int8)
        _write_vector(root / "golden_vectors/quant_test_vector.c", x[0], quant_output, "int8_t")

    print(f"Wrote PyTorch float ONNX to {float_onnx}")
    if not args.skip_quant:
        print(f"Wrote PyTorch quant ONNX to {root / 'onnx/quant/model.onnx'}")


if __name__ == "__main__":
    main()
