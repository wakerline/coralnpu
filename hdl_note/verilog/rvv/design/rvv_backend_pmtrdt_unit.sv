// 功能说明：
// 1. 单个 PMTRDT lane 的执行单元，负责把来自 RS 的 uop 分流到 reduction、permutation，
//    以及可选的 float reduction 子单元。
// 2. 子单元是否生成由参数控制：
//    GEN_RDT  打开整数规约/mask 规约；
//    GEN_PMT  打开 slide/gather/compress 等 permutation；
//    GEN_FRDT 在 ZVE32F_ON 下打开浮点规约。
// 3. reduction 延迟随 VLENB 的规约树级数变化：VLENB=16/32/64/128 时大致为 3/4/5/6 cycle。
// 4. permutation 延迟取决于每个 byte 需要读取的 VRF bank/寄存器位置，可能需要多拍收集完整数据。
// 5. 多个子单元结果同时有效时，使用 round-robin 仲裁，只把被 grant 的结果向 ROB 暴露。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif
module rvv_backend_pmtrdt_unit
(
  clk,
  rst_n,

  pmtrdt_uop_valid,
  pmtrdt_uop,
  pmtrdt_uop_ready,

  pmtrdt_res_valid,
  pmtrdt_res,
  pmtrdt_res_ready,

  rd_index_pmt2vrf,
  rd_data_vrf2pmt,

  rob_rptr,
  trap_flush_rvv
);
// ---参数定义--------------------------------------------------------
  parameter GEN_RDT = 1'b0; // 默认不生成整数 reduction 单元。
  parameter GEN_PMT = 1'b0; // 默认不生成 permutation 单元。
  parameter GEN_FRDT= 1'b0; // 默认不生成浮点 reduction 单元。

// ---端口定义--------------------------------------------------------
// 全局时钟/复位。
  input logic       clk;
  input logic       rst_n;

// 来自 PMTRDT RS 的队头 uop。ready 由实际目标子单元反压决定。
  input               pmtrdt_uop_valid;
  input PMT_RDT_RS_t  pmtrdt_uop;
  output logic        pmtrdt_uop_ready;

// 子单元仲裁后的统一结果出口。
  output logic        pmtrdt_res_valid;
  output PU2ROB_t     pmtrdt_res;
  input               pmtrdt_res_ready;

// permutation 独有的 VRF 读端口，用于按 byte 收集重排源数据。
  output logic [`REGFILE_INDEX_WIDTH-1:0] rd_index_pmt2vrf;
  input  logic [`VLEN-1:0]                rd_data_vrf2pmt;

// 当前 ROB 退役指针；permutation 需要它判断 first uop 是否可以开始。
  input  logic [`ROB_DEPTH_WIDTH-1:0]     rob_rptr;
// RVV trap/flush 清空内部流水。
  input               trap_flush_rvv;

// ---内部信号--------------------------------------------------------
  // reduction 子单元握手。
  logic               rdt_uop_valid;
  PMT_RDT_RS_t        rdt_uop;
  logic               rdt_uop_ready;

  logic               rdt_res_valid;
  PU2ROB_t            rdt_res;
  logic               rdt_res_ready;

  // permutation 子单元握手。
  logic               pmt_uop_valid;
  PMT_RDT_RS_t        pmt_uop;
  logic               pmt_uop_ready;

  logic               pmt_res_valid;
  PU2ROB_t            pmt_res;
  logic               pmt_res_ready;

`ifdef ZVE32F_ON
  logic               frdt_uop_valid;
  PMT_RDT_RS_t        frdt_uop;
  logic               frdt_uop_ready;

  logic               frdt_res_valid;
  PU2ROB_t            frdt_res;
  logic               frdt_res_ready;

  // 结果仲裁请求：bit0=rdt，bit1=pmt，bit2=frdt。
  logic [2:0]         pmtrdt_req;
  logic [2:0]         pmtrdt_grant;
`else
  // 结果仲裁请求：bit0=rdt，bit1=pmt。
  logic [1:0]         pmtrdt_req;
  logic [1:0]         pmtrdt_grant;
`endif

  genvar i;

// ---主逻辑----------------------------------------------------------
// 按 uop_exe_unit/funct3 把同一个输入 uop 分流到对应子单元。
  assign rdt_uop = pmtrdt_uop;
  assign pmt_uop = pmtrdt_uop;
  assign pmt_uop_valid = pmtrdt_uop_valid &&  pmtrdt_uop.uop_exe_unit == PMT;
`ifdef ZVE32F_ON
  assign frdt_uop= pmtrdt_uop;
  assign rdt_uop_valid  = pmtrdt_uop_valid && pmtrdt_uop.uop_exe_unit != PMT && pmtrdt_uop.uop_funct3 != OPFVV;
  assign frdt_uop_valid = pmtrdt_uop_valid && pmtrdt_uop.uop_exe_unit != PMT && pmtrdt_uop.uop_funct3 == OPFVV;
  assign pmtrdt_uop_ready = pmtrdt_uop.uop_exe_unit == PMT ? pmt_uop_ready :
                           (pmtrdt_uop.uop_funct3 == OPFVV)? frdt_uop_ready: rdt_uop_ready;
`else
  assign rdt_uop_valid = pmtrdt_uop_valid && pmtrdt_uop.uop_exe_unit != PMT;
  assign pmtrdt_uop_ready = pmtrdt_uop.uop_exe_unit == PMT ? pmt_uop_ready : rdt_uop_ready;
`endif

// 整数 reduction/mask reduction 单元。未生成时 ready/valid 固定为 0。
  generate
    if (GEN_RDT == 1'b1) begin
      rvv_backend_pmtrdt_unit_reduction u_rdt (
        .clk      (clk),
        .rst_n    (rst_n),
        .rdt_uop_valid  (rdt_uop_valid),
        .rdt_uop        (rdt_uop),
        .rdt_uop_ready  (rdt_uop_ready),
        .rdt_res_valid  (rdt_res_valid),
        .rdt_res        (rdt_res),
        .rdt_res_ready  (rdt_res_ready),
        .trap_flush_rvv (trap_flush_rvv)
      );
    end else begin
      assign rdt_uop_ready = 1'b0;
      assign rdt_res_valid = 1'b0;
      assign rdt_res = '0;
    end
  endgenerate

`ifdef ZVE32F_ON
// 浮点 reduction 单元，仅 ZVE32F_ON 时可用。
  generate
    if (GEN_FRDT == 1'b1) begin
      rvv_backend_freduction u_frdt (
        .clk      (clk),
        .rst_n    (rst_n),
        .uop_valid      (frdt_uop_valid),
        .uop            (frdt_uop),
        .uop_ready      (frdt_uop_ready),
        .result_valid   (frdt_res_valid),
        .result         (frdt_res),
        .result_ready   (frdt_res_ready),
        .trap_flush_rvv (trap_flush_rvv)
      );
      // 浮点异常/更多控制若需要扩展，应在 freduction 内部或这里统一补齐。
    end else begin
      assign frdt_uop_ready = 1'b0;
      assign frdt_res_valid = 1'b0;
      assign frdt_res = '0;
    end
  endgenerate
`endif

// permutation 单元，负责 slide/gather/compress，并驱动额外 VRF 读地址。
  generate
    if (GEN_PMT == 1'b1) begin
      rvv_backend_pmtrdt_unit_permutation u_pmt (
        .clk      (clk),
        .rst_n    (rst_n),
        .pmt_uop_valid  (pmt_uop_valid),
        .pmt_uop        (pmt_uop),
        .pmt_uop_ready  (pmt_uop_ready),
        .pmt_res_valid  (pmt_res_valid),
        .pmt_res        (pmt_res),
        .pmt_res_ready  (pmt_res_ready),  //输入
        .rd_index_pmt2vrf (rd_index_pmt2vrf),
        .rd_data_vrf2pmt  (rd_data_vrf2pmt),
        .rob_rptr         (rob_rptr),
        .trap_flush_rvv   (trap_flush_rvv)
      );
    end else begin
      assign pmt_uop_ready = 1'b0;
      assign pmt_res_valid = 1'b0;
      assign pmt_res = '0;
      assign rd_index_pmt2vrf = '0;
    end
  endgenerate

`ifdef ZVE32F_ON
  assign pmtrdt_req = {frdt_res_valid, pmt_res_valid, rdt_res_valid};
`else
  assign pmtrdt_req = {pmt_res_valid, rdt_res_valid};  //会轮询仲裁输出
`endif
  // 子单元结果可能同时 valid，round-robin 保证长期公平；最终仍受 pmtrdt_res_ready 回压。
  arb_round_robin #(
`ifdef ZVE32F_ON
    .REQ_NUM(3)
`else
    .REQ_NUM(2)
`endif
  ) arb_pmtrdt (
    .clk    (clk),
    .rst_n  (rst_n),
    .req    (pmtrdt_req),
    .grant  (pmtrdt_grant)
  );

  always_comb begin
    pmtrdt_res_valid = 1'b0;
    pmtrdt_res  = '0;
    // 只透传被 grant 的子单元结果；默认路径是 rdt，对应 grant[0]。
    case (1'b1)
      pmtrdt_grant[1]: begin
        pmtrdt_res_valid = pmt_res_valid;
        pmtrdt_res = pmt_res;
      end
    `ifdef ZVE32F_ON 
      pmtrdt_grant[2]: begin
        pmtrdt_res_valid = frdt_res_valid;
        pmtrdt_res = frdt_res;
      end 
    `endif
      default: begin
        pmtrdt_res_valid = rdt_res_valid;
        pmtrdt_res = rdt_res;
      end
    endcase
  end

  always_comb begin
    rdt_res_ready = 1'b0;
    pmt_res_ready = 1'b0;
  `ifdef ZVE32F_ON
    frdt_res_ready= 1'b0;
  `endif
    // 只有被 grant 的子单元接收统一出口 ready，避免未被选中的结果被提前消费。
    case (1'b1)
      pmtrdt_grant[1]: pmt_res_ready  = pmtrdt_res_ready;
    `ifdef ZVE32F_ON
      pmtrdt_grant[2]: frdt_res_ready = pmtrdt_res_ready;
    `endif
      default:         rdt_res_ready  = pmtrdt_res_ready;
    endcase
  end

endmodule
