`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_mulmac
//------------------------------------------------------------------------------
// 功能定位：
// 1. MUL/MAC 执行顶层，连接 MUL reservation station 与两个 `rvv_backend_mac_unit`。
// 2. 虽然实例名是 MAC unit，但 `rvv_backend_mac_unit` 同时覆盖纯乘法 VMUL/VMULH/
//    VWMUL/VSMUL，以及乘加/乘减 VMACC/VMADD/VNMSAC/VWMACC 等指令。
// 3. 当前 `NUM_MUL`=2，本模块提供两个结果槽位给 ROB。
// 4. 本层不做算术，只负责根据每个结果槽是否空闲，把 RS 的 uop0/uop1
//    分配到可用 MAC pipeline，并产生 pop 信号。
//
// 调度策略：
// - `mac_ready[i]` 表示第 i 条 MAC pipeline 当前结果槽为空，或结果本周期被 ROB 接收。
// - 若只有一个 pipeline ready，只发射年龄更老的 uop0 到该 pipeline。
// - 若两个 pipeline 都 ready，则 uop0/uop1 分别进入 pipeline0/1。
// - 若没有 pipeline ready，则不 pop RS。

module rvv_backend_mulmac (
  clk,
  rst_n,
  trap_flush_rvv,
  uop_valid_rs2ex,
  mac_uop_rs2ex,
  pop,
  res_valid_ex2rob,
  res_ex2rob,
  res_ready_rob2ex
);

// 全局信号。
input   logic                     clk;
input   logic                     rst_n;
input   logic                     trap_flush_rvv;

// MUL RS 到 MUL/MAC 执行单元。
input   logic     [`NUM_MUL-1:0]  uop_valid_rs2ex;
input   MUL_RS_t  [`NUM_MUL-1:0]  mac_uop_rs2ex;
output  logic     [`NUM_MUL-1:0]  pop;

// MUL/MAC 执行结果输出到 ROB 写回通路。
output  logic     [`NUM_MUL-1:0]  res_valid_ex2rob;
output  PU2ROB_t  [`NUM_MUL-1:0]  res_ex2rob;
input   logic     [`NUM_MUL-1:0]  res_ready_rob2ex;

// 内部调度信号。
logic             [`NUM_MUL-1:0]  mac_valid;
MUL_RS_t          [`NUM_MUL-1:0]  mac_uop;
logic             [`NUM_MUL-1:0]  mac_ready;
logic             [`NUM_MUL-1:0]  mac_pipe_vld_en;
logic             [`NUM_MUL-1:0]  mac_pipe_data_en;

genvar                            i;

// pipeline ready：结果槽无有效结果，或者 ROB 本周期接收该结果。
assign mac_ready = ~res_valid_ex2rob | res_ready_rob2ex;

always_comb begin
  case(mac_ready)
    2'b01: begin
      // 只有 pipeline0 可接收：只发射 uop0，保持顺序。
      mac_valid[0]  = uop_valid_rs2ex[0];
      mac_valid[1]  = 'b0;
      mac_uop[0]    = mac_uop_rs2ex[0];
      mac_uop[1]    = 'b0;
      pop[0]        = uop_valid_rs2ex[0];
      pop[1]        = 'b0;
    end
    2'b10: begin
      // 只有 pipeline1 可接收：uop0 改发到 pipeline1，uop1 不越过。
      mac_valid[0]  = 'b0;
      mac_valid[1]  = uop_valid_rs2ex[0];
      mac_uop[0]    = 'b0;
      mac_uop[1]    = mac_uop_rs2ex[0];
      pop[0]        = uop_valid_rs2ex[0];
      pop[1]        = 'b0;
    end
    2'b11: begin
      // 两条 pipeline 都可接收：双发射 uop0/uop1。
      mac_valid[0]  = uop_valid_rs2ex[0];
      mac_valid[1]  = uop_valid_rs2ex[1];
      mac_uop[0]    = mac_uop_rs2ex[0];
      mac_uop[1]    = mac_uop_rs2ex[1];
      pop[0]        = uop_valid_rs2ex[0];
      pop[1]        = uop_valid_rs2ex[1];
    end
    default: begin
      // 没有可用 pipeline：不发射、不 pop。
      mac_valid[0]  = 'b0;
      mac_valid[1]  = 'b0;
      mac_uop[0]    = 'b0;
      mac_uop[1]    = 'b0;
      pop[0]        = 'b0;
      pop[1]        = 'b0;
    end
  endcase
end

// pipeline 寄存器使能：
// - valid 寄存器在接收新 uop 或清掉已被 ROB 接收的旧结果时更新。
// - data 寄存器只在接收新 uop 时更新。
assign mac_pipe_vld_en  = mac_valid | res_valid_ex2rob&res_ready_rob2ex;
assign mac_pipe_data_en = mac_valid;

// 实例化两条 MAC/MUL pipeline。
generate
  for(i=0;i<`NUM_MUL;i++) begin: INST_MAC
    rvv_backend_mac_unit #(
    ) u_mac (
      // 输出到 ROB。
      .mac2rob_uop_valid  (res_valid_ex2rob[i]),
      .mac2rob_uop_data   (res_ex2rob[i]),
      // 输入 uop 和流水控制。
      .clk                (clk), 
      .rst_n              (rst_n), 
      .rs2mac_uop_valid   (mac_valid[i]), 
      .rs2mac_uop_data    (mac_uop[i]),
      .mac_pipe_vld_en    (mac_pipe_vld_en[i]),
      .mac_pipe_data_en   (mac_pipe_data_en[i]),
      .trap_flush_rvv     (trap_flush_rvv)
    );
  end

endgenerate

endmodule
