from __future__ import annotations

import torch
from torch import nn


class TinyQuantMLP(nn.Module):
    def __init__(self, input_dim: int = 16, hidden_dim: int = 32, num_classes: int = 4):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, num_classes),
        )

    def forward(self, x):
        return self.net(x.reshape(x.shape[0], -1))


def create_model(input_dim: int = 16, hidden_dim: int = 32, num_classes: int = 4):
    return TinyQuantMLP(input_dim=input_dim, hidden_dim=hidden_dim, num_classes=num_classes)
