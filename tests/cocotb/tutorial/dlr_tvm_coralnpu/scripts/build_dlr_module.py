#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np


DLR_CORALNPU_RV32_TARGET = (
    "llvm --mtriple=riscv32-unknown-elf -mcpu=generic-rv32 "
    "-mabi=ilp32 -mattr=+m,+f,+zve32x,+zbb,+zvl128b"
)


def add_tvm_paths(tvm_root: Path) -> None:
    python_dir = tvm_root / "python"
    if str(python_dir) not in sys.path:
        sys.path.insert(0, str(python_dir))


def _onnx_input_name(model) -> str:
    initializer_names = {init.name for init in model.graph.initializer}
    for value in model.graph.input:
        if value.name not in initializer_names:
            return value.name
    raise ValueError("ONNX model has no non-initializer graph input")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["float", "quant"], default="quant")
    parser.add_argument("--model", default=None)
    parser.add_argument("--sample", default="generated/sample_io.npz")
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--model-name", default="dlr_ti_model")
    parser.add_argument("--tvm-root", default="/home/wangyy/001_research/tvm_v18")
    parser.add_argument("--target", default=DLR_CORALNPU_RV32_TARGET)
    parser.add_argument("--opt-level", type=int, default=3)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    add_tvm_paths(Path(args.tvm_root).resolve())

    import onnx
    import tvm
    from tvm import relay
    from tvm.contrib import graph_executor

    model_path = Path(args.model) if args.model else root / "onnx" / args.mode / "model.onnx"
    if not model_path.is_absolute():
        model_path = root / model_path
    sample_path = Path(args.sample)
    if not sample_path.is_absolute():
        sample_path = root / sample_path
    out_dir = Path(args.out_dir) if args.out_dir else root / f"{args.model_name}.output"
    if not out_dir.is_absolute():
        out_dir = root / out_dir
    log_dir = root / "logs"
    out_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    sample_npz = np.load(sample_path)
    sample = sample_npz["input"].astype("float32")
    model = onnx.load(str(model_path))
    input_name = _onnx_input_name(model)
    shape_dict = {input_name: tuple(sample.shape)}
    mod, params = relay.frontend.from_onnx(model, shape=shape_dict, freeze_params=True)

    (log_dir / "dlr_onnx_model.txt").write_text(str(model), encoding="utf-8")
    (log_dir / "dlr_relay.txt").write_text(str(mod), encoding="utf-8")

    target = tvm.target.Target(args.target)
    runtime = tvm.relay.backend.Runtime("cpp", {"system-lib": True})
    with tvm.transform.PassContext(opt_level=args.opt_level, config={"relay.backend.use_auto_scheduler": False}):
        built = relay.build(mod, target=target, runtime=runtime, params=params)

    with tvm.transform.PassContext(opt_level=args.opt_level):
        opt_mod, opt_params = relay.optimize(mod, target=target, params=params)

    lib = built.get_lib()
    graph_json = built.get_graph_json()
    params_blob = relay.save_param_dict(built.get_params())

    ll_path = out_dir / f"{args.model_name}.ll"
    graph_path = out_dir / f"{args.model_name}.graph"
    params_path = out_dir / f"{args.model_name}.params"
    ll_path.write_text(lib.get_source(), encoding="utf-8")
    graph_path.write_text(graph_json, encoding="utf-8")
    params_path.write_bytes(params_blob)
    (out_dir / f"{args.model_name}.opt_mod").write_text(opt_mod.astext(show_meta_data=True), encoding="utf-8")
    (out_dir / f"{args.model_name}.opt_params").write_bytes(relay.save_param_dict(opt_params))

    host_lib = relay.build(mod, target="llvm", params=params)
    dev = tvm.cpu(0)
    module = graph_executor.create(host_lib.get_graph_json(), host_lib.get_lib(), dev)
    module.load_params(relay.save_param_dict(host_lib.get_params()))
    module.set_input(input_name, tvm.nd.array(sample))
    module.run()
    host_output = module.get_output(0).numpy()
    np.save(out_dir / "host_output.npy", host_output)

    report = {
        "model": str(model_path),
        "mode": args.mode,
        "model_name": args.model_name,
        "input_name": input_name,
        "input_shape": list(sample.shape),
        "output_shape": list(host_output.shape),
        "target": args.target,
        "graph": str(graph_path),
        "params": str(params_path),
        "ll": str(ll_path),
        "host_output": str(out_dir / "host_output.npy"),
    }
    (out_dir / "dlr_compile_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
