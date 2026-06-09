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

"""Train a tiny PyTorch MLP and print quantized arrays for pytorch_mlp_model.py."""

import argparse

import numpy as np
import torch


class TinyMlp(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.net = torch.nn.Sequential(
            torch.nn.Linear(16, 8),
            torch.nn.ReLU(),
            torch.nn.Linear(8, 4),
        )

    def forward(self, x):
        return self.net(x)


def quantize_to_int8(array, scale):
    return np.clip(np.round(array / scale), -128, 127).astype(np.int8)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--scale", type=float, default=0.05)
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    model = TinyMlp()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.02)
    loss_fn = torch.nn.CrossEntropyLoss()

    x = torch.randn(128, 16)
    y = ((x[:, 0] + x[:, 2] - x[:, 5] + 0.5 * x[:, 8]) > 0).long()
    y = (y + ((x[:, 1] - x[:, 3]) > 0).long()) % 4

    for _ in range(args.epochs):
        optimizer.zero_grad()
        loss = loss_fn(model(x), y)
        loss.backward()
        optimizer.step()

    fc1 = model.net[0]
    fc2 = model.net[2]
    print("FC1_FILTER_DATA =", quantize_to_int8(fc1.weight.detach().numpy(), args.scale).flatten().tolist())
    print("FC1_BIAS_DATA =", np.round(fc1.bias.detach().numpy() / (args.scale * args.scale)).astype(np.int32).tolist())
    print("FC2_FILTER_DATA =", quantize_to_int8(fc2.weight.detach().numpy(), args.scale).flatten().tolist())
    print("FC2_BIAS_DATA =", np.round(fc2.bias.detach().numpy() / (args.scale * args.scale)).astype(np.int32).tolist())


if __name__ == "__main__":
    main()
