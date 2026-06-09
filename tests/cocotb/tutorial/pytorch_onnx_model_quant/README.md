# PyTorch ONNX model cocotb tutorial

This directory is the generic PyTorch counterpart to `ti_onnx_model_quant`.
It keeps the same ONNX + TVM + Coral NPU cocotb shape, but uses
`train_quantize_pytorch.sh` as the training and export entry point.

## Flow

1. `train_quantize_pytorch.sh` trains a small PyTorch MLP and exports
   `onnx/float/model.onnx`.
2. Without `--skip-quant`, it also uses ONNX Runtime quantization to write
   `onnx/quant/model.onnx`.
3. `compile_onnx_tvm_for_coralnpu.sh` compiles `MODEL_MODE=float` or
   `MODEL_MODE=quant` into the active `mod.a` and `tvmgen_default.h`.
4. `run_full_experiment.sh float|quant` builds the matching Coral NPU ELF and
   runs the cocotb test.

## Commands

```sh
tests/cocotb/tutorial/pytorch_onnx_model_quant/train_quantize_pytorch.sh --skip-quant
tests/cocotb/tutorial/pytorch_onnx_model_quant/run_full_experiment.sh float
```

For quantized export, install ONNX Runtime in the active Python environment:

```sh
tests/cocotb/tutorial/pytorch_onnx_model_quant/train_quantize_pytorch.sh
tests/cocotb/tutorial/pytorch_onnx_model_quant/run_full_experiment.sh quant
```
