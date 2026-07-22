
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode` -> DE1 阶段：识别 RVV/LSU 指令类别，生成 LCMD 或 decode 控制信息。
// - 接口与数据流：
//   * 输入：RVVCmd 或 LCMD。
//   * 处理：按 opcode/funct/vtype/LMUL/SEW 识别指令类型，拆分为算术或访存 uop。
//   * 输出：LCMD、UOP_QUEUE_t 或 decode 控制字段。
// - 调用关系：上层 rvv_backend；下层 rvv_backend_decode_unit(u_decode_unit)
// - 端口摘要：输入 inst_valid, inst；输出 lcmd_valid, lcmd。
// - define/参数阅读重点：
//   * `NUM_DE_INST`：3'd2；DE1/DE2 每拍处理的命令条数。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module rvv_backend_decode
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd
);
//
// interface signals
//
  input   logic   [`NUM_DE_INST-1:0]  inst_valid; 
  input   RVVCmd  [`NUM_DE_INST-1:0]  inst; 

  output  logic   [`NUM_DE_INST-1:0]  lcmd_valid;
  output  LCMD_t  [`NUM_DE_INST-1:0]  lcmd;

//
// decode
//
  genvar                              i;

  // decode unit
  generate 
    for (i=0;i<`NUM_DE_INST;i=i+1) begin: DECODE_UNIT
      rvv_backend_decode_unit u_decode_unit
      (
        .inst_valid   (inst_valid[i]),
        .inst         (inst[i]),
        .lcmd_valid   (lcmd_valid[i]),
        .lcmd         (lcmd[i])  
      );    
    end
  endgenerate
  
endmodule
