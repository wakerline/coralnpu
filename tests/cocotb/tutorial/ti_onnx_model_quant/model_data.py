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

from pathlib import Path
import importlib.util
import re

import numpy as np

_DATA_DIR = Path(__file__).with_name("golden_vectors")
_VECTOR_FILES = {
    "float": _DATA_DIR / "float_test_vector.c",
    "quant": _DATA_DIR / "quant_test_vector.c",
}


def _parse_first_array(text, name):
    match = re.search(rf"{name}\[[^\]]+\]\s*=\s*\{{([^}}]+)\}}", text, re.S)
    if not match:
        raise ValueError(f"Could not find {name} in golden vector")
    return [float(item) for item in re.findall(r"[-+]?\d+(?:\.\d+)?", match.group(1))]


def _load_vectors(mode):
    if mode not in _VECTOR_FILES:
        raise ValueError(f"Unsupported model mode: {mode}")
    text = _VECTOR_FILES[mode].read_text()
    input_values = np.array(_parse_first_array(text, "model_test_input"), dtype=np.float32)
    if mode == "float":
        output_values = np.array(_parse_first_array(text, "golden_output"), dtype=np.float32)
    else:
        output_values = np.array(_parse_first_array(text, "golden_output"), dtype=np.int8)
    return input_values, output_values


def _load_model_abi():
    model_abi_path = Path(__file__).with_name("model_abi.py")
    spec = importlib.util.spec_from_file_location("ti_onnx_model_quant_abi", model_abi_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def quantized_input():
    model_abi = _load_model_abi()
    if model_abi.BIAS is None or model_abi.SCALE is None or model_abi.SHIFT is None:
        raise ValueError("Quantized model ABI does not provide input normalization parameters")
    float_input, _ = _load_vectors("quant")
    scaled = np.floor((float_input + np.float32(model_abi.BIAS)) * np.int32(model_abi.SCALE)).astype(np.int32)
    shifted = scaled >> int(model_abi.SHIFT)
    return np.clip(shifted, -128, 127).astype(np.int8)


def model_input(mode):
    if mode == "float":
        float_input, _ = _load_vectors("float")
        return float_input
    if mode == "quant":
        return quantized_input()
    raise ValueError(f"Unsupported model mode: {mode}")


def golden_output(mode):
    _, output = _load_vectors(mode)
    return output
