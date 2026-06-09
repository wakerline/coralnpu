# train_tvm_coralnpu

Self-contained model-to-RTL workflow for CoralNPU highmem simulation.

The implemented path follows this architecture:

```text
ONNX / TFLite / PyTorch
        |
        v
TVM 0.18 frontend
        |
        v
Relay / TIR optimization
        |
        v
AOT + CRT C codegen
        |
        v
Coral bare-metal wrapper main()
        |
        v
riscv32 Coral toolchain compile / link
        |
        v
program.elf
        |
        v
CoralNPU Verilator RTL simulator
        |
        v
read output symbol / verify result / cycle / VCD
```

This folder does not import older tutorial implementations. It only uses the
shared CoralNPU Bazel rules, cocotb fixture utilities, and the local TVM source
tree requested for compilation.

## Layout

- `run.sh`: stage runner for train, compile, and sim.
- `scripts/train_export_onnx.py`: PyTorch training and ONNX export.
- `scripts/compile_tvm.py`: frontend import, Relay/TIR build, AOT/CRT MLF export,
  bare-metal wrapper generation, and golden IO metadata.
- `scripts/sim_rvv_highmem.py`: Bazel wrapper for `RvvCoreMiniHighmemAxi`.
- `models/default_model.py`: tiny default model used when no user model is passed.
- `runtime/tvm_coralnpu_smoke.cc`: minimal ELF smoke program.
- `tests/cocotb_generated_model.py`: RTL test that loads the AOT ELF, writes
  `model_input`, reads `model_output/model_status/model_cycles`, and checks
  against host TVM golden output.

## Quick Start

```bash
cd /home/wangyy/002_research/coralnpu/tests/cocotb/tutorial/train_tvm_coralnpu
./run.sh all
```

The compile stage activates `tvm_v18` by default, imports TVM from
`/home/wangyy/001_research/tvm_v18/python`, emits host validation artifacts under
`generated/tvm`, exports `generated/tvm/model_aot_crt.tar`, extracts TVM AOT C
sources into `generated/tvm/aot`, and generates `coral_baremetal_main.cc`.

## Model Entry

The default train stage emits ONNX. The compile stage also accepts TFLite and
TorchScript directly:

```bash
./run.sh compile -- --model path/to/model.onnx --model-format onnx
./run.sh compile -- --model path/to/model.tflite --model-format tflite
./run.sh compile -- --model path/to/model.pt --model-format pytorch
```

For PyTorch training, pass your own model factory:

```bash
./run.sh train -- \
  --model-factory my_pkg.my_model:create_model \
  --input-shape 1,3,224,224 \
  --num-classes 1000
```

## TI ModelMaker DC Arc Fault

The `modelmaker` stage adapts the TI TinyML ModelMaker configuration at:

```text
/home/wangyy/001_research/ti/tinyml-tensorlab/tinyml-modelmaker/examples/dc_arc_fault/config_dsk.yaml
```

It runs, or reuses, the `arc_fault_example_dsk / TimeSeries_Generic_100_t`
training output, copies ONNX artifacts into `generated/modelmaker`, and creates
`sample_io.npz` for the TVM stage.

Reuse the newest existing ModelMaker run without retraining:

```bash
./run.sh modelmaker -- --skip-run --model-name TimeSeries_Generic_100_t --prefer quantization
```

Run ModelMaker training from the adapted config:

```bash
./run.sh modelmaker -- --run-name coralnpu_dc_arc_fault \
  --model-name TimeSeries_Generic_100_t --training-epochs 10 --prefer quantization
```

Compile the exported model through TVM AOT/CRT:

```bash
./run.sh compile -- --model generated/modelmaker/model.onnx \
  --sample generated/modelmaker/sample_io.npz --model-format onnx --target rvv
./run.sh sim
```

The ModelMaker quantization ONNX is copied to both
`generated/modelmaker/model.onnx` and
`generated/modelmaker/model.quantization.onnx`. `model.base.onnx` is still kept
as a scalar/base fallback. `--model-name` can select any ModelMaker model that
already has, or can generate, an ONNX run under the configured dataset.

## RTL Path

`coralnpu_model_highmem` builds the TVM-generated AOT C sources plus the Coral
bare-metal wrapper with `coralnpu_v2_binary`, producing
`coralnpu_model_highmem.elf`. The cocotb test loads that ELF into
`RvvCoreMiniHighmemAxi`, writes input through the exported `model_input` symbol,
runs to halt, then reads and verifies the output symbols.

The default AOT/CRT build enables TVM TIR vectorization. The generated C vector
types are converted to GNU vector extensions for the Coral RISC-V compiler; the
resulting ELF has RVV instructions such as `vsetvli`, `vle8.v`, and `vse8.v`.
Use `--disable-tir-vectorize` on the compile stage as a portability fallback.
