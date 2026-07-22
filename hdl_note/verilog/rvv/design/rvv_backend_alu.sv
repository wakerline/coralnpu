// 功能说明：
// 1. `rvv_backend_alu` 是 RVV 后端的整数/逻辑/比较类 ALU 执行单元顶层。
// 2. 本模块从 ALU 保留站接收最多 `NUM_ALU` 条 uop，把 uop 分配给内部 `rvv_backend_alu_unit`，
//    再把每条 ALU lane 的执行结果以 `PU2ROB_t` 形式送往 ROB 写回仲裁。
// 3. 当前 `NUM_ALU=2`：lane0 实例打开 `CMP_SUPPORT`，可执行比较类 uop；lane1 不支持比较类 uop，
//    因此调度逻辑会避免把 `is_cmp` uop 派到 lane1。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_alu` -> RVV 后端 EX 执行层的 ALU wrapper，位于 ALU RS 与 ROB 写回仲裁之间。
// - 接口与数据流：
//   * 输入：ALU RS 给出的 `uop_valid/uop`，每个 uop 已经包含操作数、mask、CSR 控制、ROB entry 等信息。
//   * 输入：`result_ready` 来自后级 ROB/仲裁路径，表示对应 ALU 结果口是否可接收新结果。
//   * 处理：根据 `result_ready` 和 `is_cmp` 选择 uop 到 lane0/lane1，生成 RS pop，并实例化 ALU unit 执行。
//   * 输出：每个 lane 的 `result_valid/result`，最终写回 ROB entry。
// - 调用关系：上层 rvv_backend；下层 rvv_backend_alu_unit(u_alu_cmp_unit, u_alu_unit)
// - 端口摘要：输入 clk, rst_n, uop_valid, uop, result_ready, trap_flush_rvv；输出 pop, result_valid, result。
// - define/参数阅读重点：
//   * `NUM_ALU`：2；ALU 执行 lane 数。
//   * `VLEN`：向量寄存器宽度，决定 PU2ROB_t.w_data 位宽。
//   * `TB_SUPPORT`：打开时结果结构体中携带 uop_pc，便于仿真追踪。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 阅读建议：先看本文件的 lane 分配，再看 `rvv_backend_alu_unit.sv` 的 p0/p1 内部流水和 ROB 输出仲裁。
// 详细中文注释（自动梳理）END

module rvv_backend_alu
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
  input   logic                         clk;
  input   logic                         rst_n;
  // ALU RS -> ALU：`uop_valid` 表示 RS 对应出口有有效 uop，`pop` 表示本周期 ALU 接收并弹出该 uop。
  output  logic       [`NUM_ALU-1:0]    pop;
  input   logic       [`NUM_ALU-1:0]    uop_valid;    
  input   ALU_RS_t    [`NUM_ALU-1:0]    uop;
  // ALU -> ROB：每个 ALU lane 产生一个写回结果口；后级不 ready 时 unit 内部会保持结果。
  output  logic       [`NUM_ALU-1:0]    result_valid;
  output  PU2ROB_t    [`NUM_ALU-1:0]    result;
  input   logic       [`NUM_ALU-1:0]    result_ready;
  // trap flush：清掉执行单元内部尚未提交的结果，避免异常/中断刷新后旧结果继续写 ROB。
  input   logic                         trap_flush_rvv; 

//
// 内部信号
//
  // wrapper 内部重新分配后的 ALU lane 输入。
  logic               [`NUM_ALU-1:0]    alu_valid; // 送入各 ALU unit 的 valid。
  ALU_RS_t            [`NUM_ALU-1:0]    alu_uop;   // 送入各 ALU unit 的 uop。
  logic               [`NUM_ALU-1:0]    alu_pop;   // 各 ALU unit 对其输入 uop 的接收反馈。
  // generate 循环变量。
  genvar                                i;

//
// 实例化并分配 2 个 rvv_backend_alu_unit。
// lane0：支持比较类指令；lane1：普通 ALU lane，不接收 `is_cmp` uop。
// 这里使用 `result_ready` 作为后压条件，只有后级结果口有接收能力时才给对应 lane 送入新 uop。
// NUM_ALU = 2
// lane0：支持 ALU + CMP
// lane1：只支持普通 ALU，不支持 CMP
  always_comb begin
    case(result_ready)  //来自后级 ROB/仲裁路径，表示对应 ALU 结果口是否可接收新结果
      2'b01: begin
        // 只有 lane0 的结果口 ready：只尝试派发 RS 出口 0 到 lane0。
        alu_valid[0]  = uop_valid[0]; 
        alu_valid[1]  = 'b0; 
        alu_uop[0]    = uop[0];
        alu_uop[1]    = 'b0;
        pop[0]        = alu_pop[0]; 
        pop[1]        = 'b0; 
      end
      2'b10: begin
        // 只有 lane1 的结果口 ready：把 RS 出口 0 派到 lane1，但比较类 uop 必须留给 lane0。
        alu_valid[0]  = 'b0; 
        alu_valid[1]  = uop_valid[0] & (!uop[0].is_cmp);   //不能是比较类
        alu_uop[0]    = 'b0;
        alu_uop[1]    = uop[0];
        pop[0]        = alu_pop[1];  //上级fifo按照lane顺序发出，所以只能pop出lane0
        pop[1]        = 'b0; 
      end
      2'b11: begin
        // 两个结果口都 ready：lane0 接收 RS 出口 0；lane1 接收 RS 出口 1，且 lane1 过滤比较类 uop。
        alu_valid[0]  = uop_valid[0]; 
        alu_valid[1]  = uop_valid[1] & (!uop[1].is_cmp);  //非比较类指令
        alu_uop[0]    = uop[0];
        alu_uop[1]    = uop[1];
        pop[0]        = alu_pop[0]; 
        pop[1]        = alu_pop[1]; 
      end
      default: begin
        // 后级两个结果口都不 ready：不弹出 RS，也不向 ALU unit 发新 uop。
        alu_valid[0]  = 'b0; 
        alu_valid[1]  = 'b0; 
        alu_uop[0]    = 'b0;
        alu_uop[1]    = 'b0;
        pop[0]        = 'b0; 
        pop[1]        = 'b0; 
      end
    endcase
  end
  
  // lane0 打开 CMP_SUPPORT，用于比较/生成 mask 等需要比较支持的 ALU uop。
  rvv_backend_alu_unit #(
    .CMP_SUPPORT    (1'b1)  //lane0支持cmp
  ) u_alu_cmp_unit (
    // 输入
    .clk            (clk),
    .rst_n          (rst_n),
    .alu_uop_valid  (alu_valid[0]),
    .alu_uop        (alu_uop[0]),
    .result_ready   (result_ready[0]),
    // 输出
    .pop_rs         (alu_pop[0]),
    .result_valid   (result_valid[0]),
    .result         (result[0]),
    // trap 刷新
    .trap_flush_rvv (trap_flush_rvv)
  );

  // 其余 ALU lane 使用默认 CMP_SUPPORT=0，只执行非比较类 ALU uop。
  generate
    for (i=1;i<`NUM_ALU;i=i+1) begin: ALU_UNIT
      rvv_backend_alu_unit u_alu_unit
        (
          // 输入
          .clk            (clk),
          .rst_n          (rst_n),
          .alu_uop_valid  (alu_valid[i]),
          .alu_uop        (alu_uop[i]),
          .result_ready   (result_ready[i]),
          // 输出
          .pop_rs         (alu_pop[i]),
          .result_valid   (result_valid[i]),
          .result         (result[i]),
          // trap 刷新
          .trap_flush_rvv (trap_flush_rvv)
        );
    end
  endgenerate

endmodule
