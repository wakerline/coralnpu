// 功能说明：
// 1. PMTRDT 执行簇顶层，承接 PMT/RDT RS 发来的 uop，并把执行结果送回 ROB。
// 2. 覆盖三类向量指令：
//    a. compare 类指令：归在 PMT/RDT 执行簇中处理。
//    b. reduction 类指令：整数规约与 mask 规约由 reduction 单元处理。
//    c. permutation 类指令：slide/gather/compress 等重排由 permutation 单元处理。
// 3. 当前 `NUM_PMTRDT` 通常为 1，因此这里的 generate 循环更多是为配置扩展保留。
// 4. 对 compare/reduction 来说，目标寄存器 EMUL 固定为 1；compress 是 permutation 的特殊形式。
// 5. 每个子单元采用 valid/ready 结果回压：只有 ROB 对应通道 ready 时，结果才允许被消费。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
module rvv_backend_pmtrdt
(
  clk,
  rst_n,

  pop_ex2rs,
  pmtrdt_uop_rs2ex,
  fifo_almost_empty_rs2ex,

  rd_index_pmt2vrf,
  rd_data_vrf2pmt,

  result_valid_ex2rob,
  result_ex2rob,
  result_ready_rob2ex,

  rob_entry_rob2rt,
  trap_flush_rvv
);
// ---端口定义--------------------------------------------------------
// 全局时钟/复位。
  input   logic           clk;
  input   logic           rst_n;

// PMTRDT RS 到执行单元：
// fifo_almost_empty_rs2ex 取反后作为 uop_valid，uop_ready 成功时 pop RS。
  output  logic        [`NUM_PMTRDT-1:0]  pop_ex2rs;
  input   PMT_RDT_RS_t [`NUM_PMTRDT-1:0]  pmtrdt_uop_rs2ex;
  input   logic        [`NUM_PMTRDT-1:0]  fifo_almost_empty_rs2ex;

// permutation 需要额外读 vd/源寄存器数据，用于 gather/slide/compress 的跨寄存器取数。
  output logic [`REGFILE_INDEX_WIDTH-1:0] rd_index_pmt2vrf;
  input  logic [`VLEN-1:0]                rd_data_vrf2pmt;

// 执行结果写回 ROB。每个 PMTRDT lane 对应一组 valid/data/ready。
  output  logic        [`NUM_PMTRDT-1:0]  result_valid_ex2rob;
  output  PU2ROB_t     [`NUM_PMTRDT-1:0]  result_ex2rob;
  input   logic        [`NUM_PMTRDT-1:0]  result_ready_rob2ex;

// 当前 ROB 退役读指针，permutation 中用于限制 first uop 的执行顺序。
  input   logic [`ROB_DEPTH_WIDTH-1:0]    rob_entry_rob2rt;
// RVV trap/flush 清空内部流水寄存器。
  input   logic                           trap_flush_rvv;

// ---内部信号--------------------------------------------------------
// 与子单元之间的 uop 和结果握手。
  logic         [`NUM_PMTRDT-1:0] pmtrdt_uop_valid;
  PMT_RDT_RS_t  [`NUM_PMTRDT-1:0] pmtrdt_uop;
  logic         [`NUM_PMTRDT-1:0] pmtrdt_uop_ready;

  logic         [`NUM_PMTRDT-1:0] pmtrdt_res_valid;
  PU2ROB_t      [`NUM_PMTRDT-1:0] pmtrdt_res;
  logic         [`NUM_PMTRDT-1:0] pmtrdt_res_ready;

  genvar i;
// ---主逻辑----------------------------------------------------------
  generate
    for (i=0; i<`NUM_PMTRDT; i++) begin : gen_pmtrdt_uop  //1
      // RS 本身只提供队头 uop，是否有效由 FIFO empty 状态决定。
      assign pmtrdt_uop[i]          = pmtrdt_uop_rs2ex[i];
      assign pmtrdt_uop_valid[i]    = ~fifo_almost_empty_rs2ex[i];
      assign pop_ex2rs[i]           = pmtrdt_uop_valid[i] & pmtrdt_uop_ready[i];

      // 顶层不改写结果，只把子单元结果透传给 ROB。
      assign result_valid_ex2rob[i] = pmtrdt_res_valid[i];
      assign result_ex2rob[i]       = pmtrdt_res[i];
      assign pmtrdt_res_ready[i]    = result_ready_rob2ex[i]; 
    end
  endgenerate

// 实例化 PMTRDT lane。参数打开整数规约与 permutation；ZVE32F_ON 时额外打开浮点规约。
  generate
    for (i=0; i<`NUM_PMTRDT; i++) begin : gen_pmtrdt_unit
        rvv_backend_pmtrdt_unit #(
          .GEN_RDT      (1'b1),  //整数规约
        `ifdef ZVE32F_ON
          .GEN_FRDT     (1'b1), //浮点规约
        `endif
          .GEN_PMT      (1'b1)  //permutation重排
        ) u_pmtrdt_unit0 (
          .clk                (clk),
          .rst_n              (rst_n),
          .pmtrdt_uop_valid   (pmtrdt_uop_valid[i]),
          .pmtrdt_uop         (pmtrdt_uop[i]),
          .pmtrdt_uop_ready   (pmtrdt_uop_ready[i]),
          .pmtrdt_res_valid   (pmtrdt_res_valid[i]),
          .pmtrdt_res         (pmtrdt_res[i]),
          .pmtrdt_res_ready   (pmtrdt_res_ready[i]),
          .rd_index_pmt2vrf   (rd_index_pmt2vrf),
          .rd_data_vrf2pmt    (rd_data_vrf2pmt),
          .rob_rptr           (rob_entry_rob2rt),
          .trap_flush_rvv     (trap_flush_rvv)
        );
    end
  endgenerate

endmodule
