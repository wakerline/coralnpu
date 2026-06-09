from __future__ import annotations

import math
from fractions import Fraction
from typing import Optional

import numpy as np
import tvm
from tvm import IRModule, relay


def rewrite_ti_fakequant_for_rvv(mod: IRModule) -> IRModule:
    """Rewrite TI fake-quant Relay graphs into a mixed int/float form.

    The rewrite is intentionally conservative:
    - heavy conv blocks are lowered to int8/uint8 -> int32 convs plus integer
      fixed-point requantization, so TVM's RVV-aware int8 conv schedules can fire
    - graph tails that are awkward to represent exactly in integer arithmetic
      (for example avg_pool over raw activation codes or custom round logic)
      are cast back to float32 and left in their original form
    """

    mod = relay.transform.InferType()(mod)
    rewriter = _TiFakeQuantRewriter(mod)
    rewritten = IRModule.from_expr(rewriter.visit(mod["main"]))
    return relay.transform.InferType()(rewritten)


def _is_call(expr, op_name: str) -> bool:
    return isinstance(expr, relay.Call) and getattr(expr.op, "name", None) == op_name


def _const_array(expr: relay.Expr) -> Optional[np.ndarray]:
    if not isinstance(expr, relay.Constant):
        return None
    return np.array(expr.data.numpy())


def _const_scalar(expr: relay.Expr) -> Optional[float]:
    value = _const_array(expr)
    if value is None or value.size != 1:
        return None
    return float(value.reshape(()))


def _dtype_name(expr: relay.Expr) -> str:
    try:
        checked_type = expr.checked_type
    except ValueError:
        return ""
    if checked_type is None:
        return ""
    return str(checked_type.dtype)


def _dtype_hint(expr: relay.Expr) -> str:
    dtype = _dtype_name(expr)
    if dtype:
        return dtype
    if not isinstance(expr, relay.Call):
        return ""
    op_name = getattr(expr.op, "name", "")
    if op_name == "cast":
        return str(expr.attrs.dtype)
    if op_name in {"nn.max_pool2d", "reshape", "nn.batch_flatten", "nn.relu", "clip"}:
        return _dtype_hint(expr.args[0])
    return ""


def _clip_output_dtype(a_min: float, a_max: float) -> Optional[str]:
    if a_min == -128.0 and a_max == 127.0:
        return "int8"
    if a_min == 0.0 and a_max == 255.0:
        return "uint8"
    return None


def _is_integer_like(array: np.ndarray, tol: float = 1e-5) -> bool:
    return np.allclose(array, np.round(array), atol=tol, rtol=0.0)


def _to_int_const(expr: relay.Expr, dtype: str) -> Optional[relay.Constant]:
    array = _const_array(expr)
    if array is None or not _is_integer_like(array):
        return None
    return relay.const(np.round(array).astype(dtype))


def _dyadic_int_params(array: np.ndarray, max_shift: int = 30) -> Optional[tuple[np.ndarray, np.ndarray]]:
    multipliers = np.empty(array.shape, dtype="int32")
    shifts = np.empty(array.shape, dtype="int32")
    for index in np.ndindex(array.shape):
        value = float(array[index])
        fraction = Fraction(value).limit_denominator(1 << max_shift)
        denom = fraction.denominator
        if denom <= 0 or denom & (denom - 1):
            return None
        shift = int(math.log2(denom))
        if shift > max_shift:
            return None
        multipliers[index] = int(fraction.numerator)
        shifts[index] = shift
    return multipliers, shifts


def _cast_if_needed(expr: relay.Expr, dtype: str) -> relay.Expr:
    if _dtype_name(expr) == dtype:
        return expr
    return relay.cast(expr, dtype)


class _TiFakeQuantRewriter(relay.ExprMutator):
    def __init__(self, mod: IRModule) -> None:
        super().__init__()
        self.mod = mod

    def _infer(self, expr: relay.Expr) -> relay.Expr:
        return relay.transform.InferType()(IRModule.from_expr(expr))["main"].body

    def visit_call(self, call: relay.Call) -> relay.Expr:
        new_call = super().visit_call(call)

        rewritten = self._rewrite_conv_activation_block(new_call)
        if rewritten is not None:
            return rewritten

        rewritten = self._rewrite_conv_call(new_call)
        if rewritten is not None:
            return rewritten

        rewritten = self._cast_int_tail_inputs(new_call)
        if rewritten is not None:
            return rewritten

        return new_call

    def _rewrite_conv_call(self, call: relay.Call) -> Optional[relay.Expr]:
        if not _is_call(call, "nn.conv2d"):
            return None

        data, weight = call.args
        data_dtype = _dtype_hint(data)
        if data_dtype not in {"int8", "uint8"}:
            quantized_data = self._rewrite_input_quant_to_int(data)
            if quantized_data is None:
                return None
            data = quantized_data
            data_dtype = _dtype_hint(data)

        if data_dtype not in {"int8", "uint8"}:
            return None

        int_weight = _to_int_const(weight, "int8")
        if int_weight is None:
            return None

        attrs = {key: call.attrs[key] for key in call.attrs.keys()}
        attrs["out_dtype"] = "int32"
        return self._infer(relay.nn.conv2d(data, int_weight, **attrs))

    def _rewrite_conv_activation_block(self, call: relay.Call) -> Optional[relay.Expr]:
        spec = self._extract_activation_block(call)
        if spec is None or not _is_call(spec["base"], "nn.conv2d"):
            return None

        int_conv = self._rewrite_conv_call(spec["base"])
        if int_conv is None:
            return None

        offset_const = _to_int_const(spec["offset"], "int32")
        if offset_const is None:
            return None

        scale_array = _const_array(spec["scale"])
        if scale_array is None:
            return None
        dyadic = _dyadic_int_params(scale_array.astype("float64"))
        if dyadic is None:
            return None
        multiplier_array, shift_array = dyadic

        expr = relay.add(int_conv, relay.const(offset_const.data.numpy().astype("int32")))
        if not np.all(multiplier_array == 1):
            expr = relay.multiply(expr, relay.const(multiplier_array))
        if np.any(shift_array):
            expr = relay.right_shift(expr, relay.const(shift_array))

        expr = relay.clip(expr, spec["clip_min"], spec["clip_max"])
        expr = relay.cast(expr, spec["out_dtype"])
        return self._infer(expr)

    def _cast_int_tail_inputs(self, call: relay.Call) -> Optional[relay.Expr]:
        op_name = getattr(call.op, "name", "")
        if op_name not in {"nn.avg_pool2d", "sum", "nn.dense"}:
            return None
        if not call.args:
            return None
        first_dtype = _dtype_hint(call.args[0])
        if first_dtype not in {"int8", "uint8", "int32"}:
            return None

        new_args = list(call.args)
        new_args[0] = relay.cast(new_args[0], "float32")
        return self._infer(relay.Call(call.op, new_args, call.attrs, call.type_args, call.span))

    def _rewrite_input_quant_to_int(self, expr: relay.Expr) -> Optional[relay.Expr]:
        if not _is_call(expr, "clip"):
            return None
        a_min = float(expr.attrs.a_min)
        a_max = float(expr.attrs.a_max)
        out_dtype = _clip_output_dtype(a_min, a_max)
        if out_dtype not in {"int8", "uint8"}:
            return None
        if not _is_call(expr.args[0], "floor"):
            return None
        return self._infer(relay.cast(expr, out_dtype))

    def _extract_activation_block(self, expr: relay.Expr) -> Optional[dict]:
        if not _is_call(expr, "clip"):
            return None

        outer_min = float(expr.attrs.a_min)
        outer_max = float(expr.attrs.a_max)
        arg = expr.args[0]

        if outer_min == 0.0 and outer_max == 255.0 and _is_call(arg, "nn.relu"):
            inner = arg.args[0]
            if not _is_call(inner, "clip"):
                return None
            quant = self._extract_simple_quant(inner)
            if quant is None:
                return None
            quant["clip_min"] = 0.0
            quant["clip_max"] = 255.0
            quant["out_dtype"] = "uint8"
            return quant

        quant = self._extract_simple_quant(expr)
        if quant is None:
            return None

        out_dtype = _clip_output_dtype(outer_min, outer_max)
        if out_dtype is None:
            return None
        quant["clip_min"] = outer_min
        quant["clip_max"] = outer_max
        quant["out_dtype"] = out_dtype
        return quant

    def _extract_simple_quant(self, expr: relay.Expr) -> Optional[dict]:
        if not _is_call(expr, "clip"):
            return None
        floor_call = expr.args[0]
        if not _is_call(floor_call, "floor"):
            return None

        outer_mul = floor_call.args[0]
        if not _is_call(outer_mul, "multiply"):
            return None
        inner_mul, scale_rhs = outer_mul.args
        if not _is_call(inner_mul, "multiply"):
            return None
        add_call, scale_lhs = inner_mul.args
        if not _is_call(add_call, "add"):
            return None

        base, offset = add_call.args
        scale_a = _const_array(scale_lhs)
        scale_b = _const_array(scale_rhs)
        if scale_a is None or scale_b is None:
            return None

        return {
            "base": base,
            "offset": offset,
            "scale": relay.const((scale_a * scale_b).astype("float32")),
        }
