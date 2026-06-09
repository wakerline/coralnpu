# PyTorch to TensorFlow cocotb tutorial

This directory keeps the TensorFlow/TFLite-based variant of the PyTorch-trained
MLP tutorial.

Flow:

1. PyTorch trains the floating point model offline.
2. Quantized weights and one sample input are stored in
   `pytorch_tensorflow_mlp_model.py`.
3. cocotb writes those tensors into the ELF data symbols.
4. `pytorch_tensorflow_mlp_test.cc` runs both TFLite Micro reference
   fully-connected kernels and Coral NPU litert-micro optimized fully-connected
   kernels.
5. cocotb checks that optimized output matches the TensorFlow/TFLite reference.

Run:

```sh
bazel test //tests/cocotb/tutorial/pytorch_tensorflow:cocotb_pytorch_tensorflow_mlp_test_pytorch_tensorflow_mlp
```
