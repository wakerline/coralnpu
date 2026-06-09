# TI ONNX model cocotb tutorial

This directory ports the ONNX + TVM + gem5 experiment at
`/home/wangyy/001_research/002_riscv_tvm18_gem5/example/ti_onnx_model_quant`
to the Coral NPU cocotb flow.

## Flow

1. `onnx/float/model.onnx` and `onnx/quant/model.onnx` are the float and
   quantized ONNX input models.
2. `train_quantize_ti_modelmaker.sh` can refresh both from TI TinyML
   ModelMaker using
   `/home/wangyy/001_research/ti/tinyml-tensorlab/tinyml-modelmaker/examples/dc_arc_fault/config_dsk.yaml`.
   It defaults to `CONDA_ENV=ti` and `MODEL_NAME=TimeSeries_Generic_1k_t`.
3. `compile_onnx_tvm_for_coralnpu.sh` compiles the selected ONNX model for the
   Coral NPU RV32 toolchain.
4. `run_full_experiment.sh float|quant` builds the matching Coral NPU ELF and
   runs the cocotb test.

## Commands

```sh
tests/cocotb/tutorial/ti_onnx_model_quant/train_quantize_ti_modelmaker.sh
tests/cocotb/tutorial/ti_onnx_model_quant/run_full_experiment.sh quant
tests/cocotb/tutorial/ti_onnx_model_quant/run_full_experiment.sh float
```

To compare another TI model size:

```sh
MODEL_NAME=TimeSeries_Generic_100_t tests/cocotb/tutorial/ti_onnx_model_quant/train_quantize_ti_modelmaker.sh
```

The active `mod.a` and `tvmgen_default.h` are overwritten by the most recent
`MODEL_MODE`. The original gem5 artifact was RV64, so this experiment always
regenerates TVM artifacts for the Coral NPU RV32 toolchain before simulation.
