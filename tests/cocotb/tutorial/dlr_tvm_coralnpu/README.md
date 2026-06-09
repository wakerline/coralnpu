# DLR + TVM + CoralNPU TI ONNX Flow

This directory stitches together three flows:

1. Train/export TI ModelMaker ONNX, based on `../ti_onnx_model_quant/train_quantize_ti_modelmaker.sh`.
2. Compile the ONNX with TVM for both DLR graph runtime artifacts and CoralNPU AOT/CRT bare-metal artifacts.
3. Run DLR inference from a RISC-V ELF and run the same model through the CoralNPU cocotb harness.

Typical usage:

```bash
cd /home/wangyy/002_research/coralnpu/tests/cocotb/tutorial/dlr_tvm_coralnpu

./run.sh train
MODEL_MODE=quant ./run.sh prepare-sample
MODEL_MODE=quant ./run.sh compile-coral
MODEL_MODE=quant ./run.sh compile-dlr
MODEL_MODE=quant ./run.sh build-dlr-elf
MODEL_MODE=quant ./run.sh cocotb
```

Useful environment variables:

```bash
MODEL_MODE=quant              # quant or float
MODEL_NAME=dlr_ti_model       # DLR output/ELF basename
TVM_ROOT=/home/wangyy/001_research/tvm_v18
DLR_DIR=/home/wangyy/001_research/001_riscv_tvm_gem5
CORALNPU_ROOT=/home/wangyy/002_research/coralnpu
TRAIN_CONDA_ENV=ti
TVM_CONDA_ENV=tvm_v18
```

The cocotb target is:

```bash
bazel --batch test //tests/cocotb/tutorial/dlr_tvm_coralnpu:cocotb_dlr_tvm_coralnpu_model \
  --test_output=streamed \
  --test_arg=--simulator=verilator
```
