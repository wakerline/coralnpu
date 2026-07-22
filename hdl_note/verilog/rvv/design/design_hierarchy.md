# RvvCore (`RvvCore.sv`)

- 说明：本文件按 `hdl_note/verilog/rvv/design` 目录内的 SystemVerilog module 实例化关系展开。
- 记号：括号内为定义文件；`实例` 后列出父模块中的实例名；同一子模块多次实例化时合并显示。
- `include` 关系在文末单独汇总。

## RvvFrontEnd (`RvvFrontEnd.sv`)

- 实例：`frontend`

### Aligner (`Aligner.sv`)

- 实例：`cmd_aligner`

## rvv_backend (`rvv_backend.sv`)

- 实例：`backend`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

### rvv_backend_alu (`rvv_backend_alu.sv`)

- 实例：`u_alu`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

#### rvv_backend_alu_unit (`rvv_backend_alu_unit.sv`)

- 实例：`u_alu_cmp_unit`, `u_alu_unit`
- 头文件：`rvv_backend.svh`

##### rvv_backend_alu_unit_addsub (`rvv_backend_alu_unit_addsub.sv`)

- 实例：`u_alu_addsub`
- 头文件：`rvv_backend.svh`, `rvv_backend_alu.svh`

##### rvv_backend_alu_unit_execution_p1 (`rvv_backend_alu_unit_execution_p1.sv`)

- 实例：`u_alu_p1`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_alu_unit_mask (`rvv_backend_alu_unit_mask.sv`)

- 实例：`u_alu_mask`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_alu_unit_other (`rvv_backend_alu_unit_other.sv`)

- 实例：`u_alu_other`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_alu_unit_shift (`rvv_backend_alu_unit_shift.sv`)

- 实例：`u_alu_shift`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

### rvv_backend_arb (`rvv_backend_arb.sv`)

- 实例：`u_arb`
- 头文件：`rvv_backend.svh`

### rvv_backend_decode (`rvv_backend_decode.sv`)

- 实例：`u_decode_de1`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

#### rvv_backend_decode_unit (`rvv_backend_decode_unit.sv`)

- 实例：`u_decode_unit`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_decode_unit_ari (`rvv_backend_decode_unit_ari.sv`)

- 实例：`u_ari_decode`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_decode_unit_lsu (`rvv_backend_decode_unit_lsu.sv`)

- 实例：`u_lsu_decode`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

### rvv_backend_decode_de2 (`rvv_backend_decode_de2.sv`)

- 实例：`u_decode_de2`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

#### rvv_backend_decode_ctrl (`rvv_backend_decode_ctrl.sv`)

- 实例：`u_decode_ctrl`
- 头文件：`rvv_backend.svh`

#### rvv_backend_decode_unit_de2 (`rvv_backend_decode_unit_de2.sv`)

- 实例：`u_decode_unit0_de2`, `u_decode_unit_de2`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_decode_unit_ari_de2 (`rvv_backend_decode_unit_ari_de2.sv`)

- 实例：`u_ari_decode_de2`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_decode_unit_lsu_de2 (`rvv_backend_decode_unit_lsu_de2.sv`)

- 实例：`u_lsu_decode_de2`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

### rvv_backend_dispatch (`rvv_backend_dispatch.sv`)

- 实例：`u_dispatch`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_bypass (`rvv_backend_dispatch_bypass.sv`)

- 实例：`u_bypass`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_ctrl (`rvv_backend_dispatch_ctrl.sv`)

- 实例：`u_ctrl`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_operand (`rvv_backend_dispatch_operand.sv`)

- 实例：`u_operand`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_opr_byte_type (`rvv_backend_dispatch_opr_byte_type.sv`)

- 实例：`u_opr_byte_type`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_raw_uop_rob (`rvv_backend_dispatch_raw_uop_rob.sv`)

- 实例：`u_raw_uop_rob`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_raw_uop_uop (`rvv_backend_dispatch_raw_uop_uop.sv`)

- 实例：`u_raw_uop_uop`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

#### rvv_backend_dispatch_structure_hazard (`rvv_backend_dispatch_structure_hazard.sv`)

- 实例：`u_structure_hazard`
- 头文件：`rvv_backend.svh`, `rvv_backend_dispatch.svh`

### rvv_backend_div (`rvv_backend_div.sv`)

- 实例：`u_div`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

#### rvv_backend_div_unit (`rvv_backend_div_unit.sv`)

- 实例：`u_div_unit`
- 头文件：`rvv_backend.svh`, `rvv_backend_div.svh`, `rvv_backend_sva.svh`

##### rvv_backend_div_unit_divider (`rvv_backend_div_unit_divider.sv`)

- 实例：`divider_8bit`, `divider_16bit`, `divider_32bit`
- 头文件：`rvv_backend.svh`, `rvv_backend_div.svh`, `rvv_backend_sva.svh`

#### rvv_backend_fdiv_wrapper (`rvv_backend_fdiv_wrapper.sv`)

- 实例：`u_fdiv_unit`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

### rvv_backend_fma (`rvv_backend_fma.sv`)

- 实例：`u_fma`
- 头文件：`rvv_backend.svh`

#### rvv_backend_fma_wrapper (`rvv_backend_fma_wrapper.sv`)

- 实例：`fma_uop_unit`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

##### rvv_backend_sqrt7_rec7 (`rvv_backend_sqrt7_rec7.sv`)

- 实例：`tbl`, `tbl`

### rvv_backend_lsu_remap (`rvv_backend_lsu_remap.sv`)

- 实例：`u_lsu_remap`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

### rvv_backend_mulmac (`rvv_backend_mulmac.sv`)

- 实例：`u_mulmac`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

#### rvv_backend_mac_unit (`rvv_backend_mac_unit.sv`)

- 实例：`u_mac`
- 头文件：`rvv_backend.svh`

##### rvv_backend_mul_unit_mul8 (`rvv_backend_mul_unit_mul8.sv`)

- 实例：`u_mul8`

### rvv_backend_pmtrdt (`rvv_backend_pmtrdt.sv`)

- 实例：`u_pmtrdt`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

#### rvv_backend_pmtrdt_unit (`rvv_backend_pmtrdt_unit.sv`)

- 实例：`u_pmtrdt_unit0`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`

##### rvv_backend_freduction (`rvv_backend_freduction.sv`)

- 实例：`u_frdt`
- 头文件：`rvv_backend.svh`

##### rvv_backend_pmtrdt_unit_permutation (`rvv_backend_pmtrdt_unit_permutation.sv`)

- 实例：`u_pmt`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`

##### rvv_backend_pmtrdt_unit_reduction (`rvv_backend_pmtrdt_unit_reduction.sv`)

- 实例：`u_rdt`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`

###### rvv_backend_pmtrdt_unit_reduction_alu (`rvv_backend_pmtrdt_unit_reduction_alu.sv`)

- 实例：`u_alu_t0`, `u_alu_t1`, `u_alu_t2`, `u_alu_t3`, `u_alu_t4`, `u_alu_dst_32b`, `u_alu_16b`, `u_alu_dst_16b`, `u_alu_8b_0`, `u_alu_8b_1`, `u_alu_8b_2`, `u_alu_dst_8b`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`

### rvv_backend_retire (`rvv_backend_retire.sv`)

- 实例：`u_retire`
- 头文件：`rvv_backend.svh`

#### rvv_backend_retire_waw (`rvv_backend_retire_waw.sv`)

- 实例：`u_process_waw`
- 头文件：`rvv_backend.svh`

### rvv_backend_rob (`rvv_backend_rob.sv`)

- 实例：`u_rob`
- 头文件：`rvv_backend.svh`

### rvv_backend_vrf (`rvv_backend_vrf.sv`)

- 实例：`u_vrf`
- 头文件：`rvv_backend.svh`

#### rvv_backend_vrf_reg (`rvv_backend_vrf_reg.sv`)

- 实例：`vrf_reg`
- 头文件：`rvv_backend.svh`, `rvv_backend_sva.svh`

## 其他未挂到 `RvvCore` 主树的 design 模块

- `MultiFifo` (`MultiFifo.sv`)：只被 `MultiFifo_tb` 实例化；主后端使用的是 common 目录中的小写 `multi_fifo`。
- `rvv_backend_alu_unit_mask_viota32` (`rvv_backend_alu_unit_mask_viota.sv`)：目录内未发现来自主树的实例化。
- `rvv_backend_alu_unit_mask_viota4` (`rvv_backend_alu_unit_mask_viota.sv`)：被 `rvv_backend_alu_unit_mask_viota32`、`rvv_backend_alu_unit_mask_viota7` 使用，但未挂到主树。
- `rvv_backend_alu_unit_mask_viota7` (`rvv_backend_alu_unit_mask_viota.sv`)：被 `rvv_backend_alu_unit_mask_viota32`、`rvv_backend_alu_unit_mask_viota4` 使用，但未挂到主树。
- `rvv_backend_mul_unit` (`rvv_backend_mul_unit.sv`)：目录内未发现来自主树的实例化；主树中 `rvv_backend_mac_unit` 直接实例化 `rvv_backend_mul_unit_mul8`。

## Testbench / 工具模块

- `Aligner_tb` (`Aligner_tb.sv`)：实例化 `Aligner`。
- `MultiFifo_tb` (`MultiFifo_tb.sv`)：实例化 `MultiFifo`。
- `MultiFifo` (`MultiFifo.sv`)：CamelCase FIFO 工具模块，未被 `RvvCore` 主树实例化。

## 目录外 common 依赖

- `multi_fifo`：被 `rvv_backend.sv`、`rvv_backend_rob.sv` 多处实例化，定义在 `../common/multi_fifo.sv`。
- `cdffr`：被多个 design 模块实例化，定义在 `../common/cdffr.sv`。

## `include` 关系汇总

- `rvv_backend.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_alu.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_alu_unit.sv` -> `rvv_backend.svh`
- `rvv_backend_alu_unit_addsub.sv` -> `rvv_backend.svh`, `rvv_backend_alu.svh`
- `rvv_backend_alu_unit_execution_p1.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_alu_unit_mask.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_alu_unit_other.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_alu_unit_shift.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_arb.sv` -> `rvv_backend.svh`
- `rvv_backend_decode.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_ctrl.sv` -> `rvv_backend.svh`
- `rvv_backend_decode_de2.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_unit.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_unit_ari.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_unit_ari_de2.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_unit_de2.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_unit_lsu.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_decode_unit_lsu_de2.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_dispatch.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_bypass.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_ctrl.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_operand.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_opr_byte_type.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_raw_uop_rob.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_raw_uop_uop.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_dispatch_structure_hazard.sv` -> `rvv_backend.svh`, `rvv_backend_dispatch.svh`
- `rvv_backend_div.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_div_unit.sv` -> `rvv_backend.svh`, `rvv_backend_div.svh`, `rvv_backend_sva.svh`
- `rvv_backend_div_unit_divider.sv` -> `rvv_backend.svh`, `rvv_backend_div.svh`, `rvv_backend_sva.svh`
- `rvv_backend_fdiv_wrapper.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_fma.sv` -> `rvv_backend.svh`
- `rvv_backend_fma_wrapper.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_freduction.sv` -> `rvv_backend.svh`
- `rvv_backend_lsu_remap.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_mac_unit.sv` -> `rvv_backend.svh`
- `rvv_backend_mul_unit.sv` -> `rvv_backend.svh`
- `rvv_backend_mulmac.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_pmtrdt.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
- `rvv_backend_pmtrdt_unit.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`
- `rvv_backend_pmtrdt_unit_permutation.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`
- `rvv_backend_pmtrdt_unit_reduction.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`
- `rvv_backend_pmtrdt_unit_reduction_alu.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`, `rvv_backend_pmtrdt.svh`
- `rvv_backend_retire.sv` -> `rvv_backend.svh`
- `rvv_backend_retire_waw.sv` -> `rvv_backend.svh`
- `rvv_backend_rob.sv` -> `rvv_backend.svh`
- `rvv_backend_vrf.sv` -> `rvv_backend.svh`
- `rvv_backend_vrf_reg.sv` -> `rvv_backend.svh`, `rvv_backend_sva.svh`
