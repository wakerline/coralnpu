
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_unit` -> DE1 阶段：识别 RVV/LSU 指令类别，生成 LCMD 或 decode 控制信息。
// - 接口与数据流：
//   * 输入：RVVCmd 或 LCMD。
//   * 处理：按 opcode/funct/vtype/LMUL/SEW 识别指令类型，拆分为算术或访存 uop。
//   * 输出：LCMD、UOP_QUEUE_t 或 decode 控制字段。
// - 调用关系：上层 rvv_backend_decode；下层 rvv_backend_decode_unit_ari(u_ari_decode), rvv_backend_decode_unit_lsu(u_lsu_decode)
// - 端口摘要：输入 inst_valid, inst；输出 lcmd_valid, lcmd。
// - define/参数阅读重点：
//   * 本文件没有直接使用反引号宏。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module rvv_backend_decode_unit
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd
);
//
// interface signals
//
  // CQ to Decoder unit signals
  input   logic                 inst_valid;
  input   RVVCmd                inst;
  
  // Decoder unit to VCQ
  output  logic                 lcmd_valid;
  output  LCMD_t                lcmd;

//
// internal signals
//
  logic                         valid_ari;
  logic                         valid_lsu;
  // decoded arithmetic uops
  logic                         lcmd_valid_ari;
  LCMD_t                        lcmd_ari;
  // decoded LSU uops
  logic                         lcmd_valid_lsu;
  LCMD_t                        lcmd_lsu;

//
// decode
//
  // decode opcode
  assign valid_lsu    = inst_valid & ((inst.opcode==LOAD) | (inst.opcode==STORE));
  assign valid_ari    = inst_valid & (inst.opcode==RVV);
  
  // decode LSU instruction 
  rvv_backend_decode_unit_lsu u_lsu_decode
  (
    .inst_valid        (valid_lsu),
    .inst              (inst),
    .lcmd_valid        (lcmd_valid_lsu),
    .lcmd              (lcmd_lsu)
  );

  // decode arithmetic instruction
  rvv_backend_decode_unit_ari u_ari_decode
  (
    .inst_valid        (valid_ari),
    .inst              (inst),
    .lcmd_valid        (lcmd_valid_ari),
    .lcmd              (lcmd_ari)
  );

  // output
  always_comb begin 
    lcmd_valid     = 'b0;
    lcmd           = 'b0;
    
    case(1'b1)
      valid_lsu: begin
        lcmd_valid = lcmd_valid_lsu;
        lcmd       = lcmd_lsu;
      end
  
      valid_ari: begin
        lcmd_valid = lcmd_valid_ari;
        lcmd       = lcmd_ari;
      end
    endcase
  end

endmodule
