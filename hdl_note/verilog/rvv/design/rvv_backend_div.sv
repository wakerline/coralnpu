
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_div
//------------------------------------------------------------------------------
// 功能定位：
// 1. DIV/FDIV 执行单元的顶层封装，位于 RVV 后端 EX 执行层。
// 2. 输入来自 DIV reservation station 的 `DIV_RS_t`；根据 `uop.is_div`
//    将指令分流到整数除法 `rvv_backend_div_unit` 或浮点除法/开方
//    `rvv_backend_fdiv_wrapper`。
// 3. `pop[i]` 表示第 i 个 DIV RS entry 已被某个子单元接收，可从 RS 弹出。
// 4. 输出是 `PU2ROB_t`，送到后端结果仲裁器或直接写 ROB。
// 5. 当前宏配置里 `NUM_DIV`=1，因此代码虽然写成 generate，但实际只有一路。
//
// 指令范围：
// - 整数路径：VDIVU/VDIV/VREMU/VREM。
// - `ZVE32F_ON` 打开时浮点路径：VFDIV/VFRDIV/VFSQRT 等由 FDIV 执行单元处理。

module rvv_backend_div
( 
  clk,
  rst_n,
  pop,
  uop_valid,
  uop,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);

//
// 接口信号
//
  // 全局时钟/复位。
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS 到本执行单元的 uop 输入；pop 反馈给 RS 作为消费信号。
  input   logic     [`NUM_DIV-1:0]  uop_valid;
  input   DIV_RS_t  [`NUM_DIV-1:0]  uop;
  output  logic     [`NUM_DIV-1:0]  pop;

  // DIV/FDIV 结果输出到 ROB 写回通路。
  output  logic     [`NUM_DIV-1:0]  result_valid;
  output  PU2ROB_t  [`NUM_DIV-1:0]  result;
  input   logic     [`NUM_DIV-1:0]  result_ready;
  
  // RVV trap/flush，传给整数和浮点子单元清除内部状态。
  input   logic                     trap_flush_rvv;  

//
// 内部信号
//
  // 整数 DIV 子路径信号。
  logic             [`NUM_DIV-1:0]  x_uop_vld;
  logic             [`NUM_DIV-1:0]  x_uop_rdy;
  logic             [`NUM_DIV-1:0]  x_result_vld;
  PU2ROB_t          [`NUM_DIV-1:0]  x_result;
  logic             [`NUM_DIV-1:0]  x_result_rdy;

`ifdef ZVE32F_ON
  // 浮点 FDIV/FSQRT 子路径信号，依赖 fpnew divsqrt 模块。
  logic             [`NUM_DIV-1:0]  fp_uop_vld;
  logic             [`NUM_DIV-1:0]  fp_uop_rdy;
  logic             [`NUM_DIV-1:0]  fp_result_vld;
  PU2ROB_t          [`NUM_DIV-1:0]  fp_result;
  logic             [`NUM_DIV-1:0]  fp_result_rdy;

  logic                      [1:0]  arb_req;
  logic                      [1:0]  arb_grt;
`endif

  // generate 循环变量。
  genvar                            i;

//
// 实例化整数 DIV 和可选浮点 FDIV
//
  generate
    for (i=0;i<`NUM_DIV;i++) begin: DIV_UNIT
      // `is_div=1` 表示整数除法/取余，进入 rvv_backend_div_unit。
      assign x_uop_vld[i] = uop_valid[i] & uop[i].is_div; 

      rvv_backend_div_unit u_div_unit
        (
          .clk            (clk),
          .rst_n          (rst_n),
          .div_uop_valid  (x_uop_vld[i]),
          .div_uop        (uop[i]),
          .div_uop_ready  (x_uop_rdy[i]),
          .result_valid   (x_result_vld[i]),
          .result         (x_result[i]),
          .result_ready   (x_result_rdy[i]),
          .trap_flush_rvv (trap_flush_rvv)
        );

    `ifdef ZVE32F_ON
      // `is_div=0` 且分派到 DIV 单元的 uop 是浮点除法/开方，进入 fpnew wrapper。
      assign fp_uop_vld[i] = uop_valid[i] & !uop[i].is_div; 

      rvv_backend_fdiv_wrapper u_fdiv_unit
        (
          .clk            (clk),
          .rst_n          (rst_n),
          .fdiv_uop_valid (fp_uop_vld[i]),
          .fdiv_uop       (uop[i]),
          .fdiv_uop_ready (fp_uop_rdy[i]),
          .result_valid   (fp_result_vld[i]),
          .result         (fp_result[i]),
          .result_ready   (fp_result_rdy[i]),
          .trap_flush_rvv (trap_flush_rvv)
        );
    `endif
    end

    // 子单元 valid 且 ready 时，本级可以 pop DIV RS。
    // 开启 ZVE32F_ON 后，整数或浮点任一路接收都能 pop。
    assign pop[0] = x_uop_vld[0]&x_uop_rdy[0] 
                  `ifdef ZVE32F_ON
                    || fp_uop_vld[0]&fp_uop_rdy[0]
                  `endif
                    ;
  endgenerate

`ifdef ZVE32F_ON
  // 整数 DIV 和浮点 FDIV 共用同一个后端 DIV 结果端口，因此两路结果
  // 同时 valid 时用 round-robin 公平选择。
  assign arb_req = {fp_result_vld[0], x_result_vld[0]};
  arb_round_robin #(.REQ_NUM(2)) arb2rob (.clk(clk), .rst_n(rst_n), .req(arb_req), .grant(arb_grt));

  assign result_valid[0]  = |arb_req;
  assign result[0]        = arb_grt[0] ? x_result[0]: fp_result[0];
  // 只有被选中的子路径才看到 result_ready，从而保持另一条结果不被提前消费。
  assign x_result_rdy[0]  = arb_grt[0] & result_ready[0];
  assign fp_result_rdy[0] = arb_grt[1] & result_ready[0];
`else
  // 未开启浮点时，整数 DIV 结果直接作为本单元输出。
  assign result_valid[0]  = x_result_vld[0];
  assign result[0]        = x_result[0];
  assign x_result_rdy[0]  = result_ready[0];
`endif

endmodule
