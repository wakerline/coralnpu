# PyTorch cocotb tutorial

This directory shows the recommended shape for testing a PyTorch-trained neural
network on the Coral NPU cocotb flow.

The cocotb test runs a tiny quantized two-layer MLP without TensorFlow or
TFLite headers:

1. PyTorch trains the floating point model offline.
2. The weights and one sample input are quantized into `pytorch_mlp_model.py`.
3. numpy computes the golden output in `pytorch_mlp_model.py`.
4. cocotb writes the tensors into the ELF data symbols.
5. `pytorch_mlp_test.cc` runs a pure C++ integer MLP reference implementation.
6. cocotb checks that the C++ output matches the numpy golden output and that
   the predicted class is the expected PyTorch-trained class.

Run the cocotb test with:

```sh
bazel test //tests/cocotb/tutorial/pytorch:cocotb_pytorch_mlp_test_pytorch_trained_mlp
```

To regenerate weights from a local PyTorch install:

```sh
python3 tests/cocotb/tutorial/pytorch/train_pytorch_mlp.py
```

Copy the printed arrays into `pytorch_mlp_model.py`, then update
`EXPECTED_CLASS` for the selected test input.
