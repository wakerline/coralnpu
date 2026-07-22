`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

`ifdef ZVE32F_ON
//------------------------------------------------------------------------------
// rvv_backend_fdiv_wrapper
//------------------------------------------------------------------------------
// 功能定位：
// 1. 浮点除法/平方根 wrapper，仅在 `ZVE32F_ON` 打开时编译。
// 2. 输入来自 DIV reservation station 的 `DIV_RS_t`，但只处理浮点 FDIV 类 uop。
// 3. 每个 32-bit lane 实例化一个 `fpnew_divsqrt_th_64_multi`，所以整条向量
//    的 FP32 除法/平方根可以按 `VLENW` 个 lane 并行提交给 fpnew。
// 4. 支持 VFDIV、VFRDIV、VFSQRT：
//    - VFDIV：vs2 / vs1 或 vs2 / scalar。
//    - VFRDIV：scalar / vs2。
//    - VFSQRT：sqrt(vs2)，通过 fpnew 的 SQRT op 实现。
// 5. 本模块只保存 ROB entry 和可选 PC；浮点异常状态由每个 lane 的
//    `fpnew_pkg::status_t` 拼到 `PU2ROB_t.fpexp`。
//
// 宏阅读提示：
// - `WORD_WIDTH`=32；本 wrapper 固定按 FP32 lane 处理。
// - `VLENW`=`VLEN/32`，`VLEN` 由 VLEN_128/256/512/1024 等编译宏决定。

module rvv_backend_fdiv_wrapper(
  clk,
  rst_n,
  fdiv_uop_valid,
  fdiv_uop,
  fdiv_uop_ready,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);
  // 全局时钟/复位。
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS 到 FDIV wrapper 的 valid/ready 握手和 uop 内容。
  input   logic     fdiv_uop_valid;
  input   DIV_RS_t  fdiv_uop;
  output  logic     fdiv_uop_ready;

  // FDIV wrapper 输出给 ROB 写回通路的结果。
  output  logic     result_valid;
  output  PU2ROB_t  result;
  input   logic     result_ready;

  // RVV trap/flush，传给 fpnew 并清除 busy/uop 信息。
  input   logic     trap_flush_rvv;

//
// 内部信号
//
  fpnew_pkg::operation_e              op_type;
  logic [`VLEN-1:0]                   src2;
  logic [`VLEN-1:0]                   src1;
  logic                               fdiv_busy_e;
  logic                               fdiv_busy;
  FDIV_RES_t                          uop_info;
  FDIV_RES_t                          uop_info_d1;
  fpnew_pkg::roundmode_e              frm;
  logic [`VLENW-1:0]                  fdiv_ready32;
  logic [`VLEN-1:0]                   sub_result;
  logic [`VLENW-1:0]                  sub_result_vld;
  fpnew_pkg::status_t  [`VLENW-1:0]   sub_fpexp;
  genvar                              i;
  
  // 准备 fpnew 操作类型和两个源操作数。
  // fpnew 的 operands_i 连接顺序是 {src1, src2}；这里的 src2/src1 命名
  // 沿用 RVV 指令源寄存器语义，因此 VFRDIV 需要显式交换成 scalar / vs2。
  always_comb begin
    op_type = fpnew_pkg::DIV;
    src2    = 'b0;
    src1    = 'b0;

    case(fdiv_uop.uop_funct6.ari_funct6)
      VFDIV: begin
        op_type = fpnew_pkg::DIV;
        src2    = fdiv_uop.vs2_data;

        if(fdiv_uop.uop_funct3==OPFVV) 
          src1  = fdiv_uop.vs1_data;
        else 
          src1  = {`VLENW{fdiv_uop.vs1_data[`WORD_WIDTH-1:0]}};
      end
      VFRDIV: begin
        op_type = fpnew_pkg::DIV;
        src2    = {`VLENW{fdiv_uop.vs1_data[`WORD_WIDTH-1:0]}};
        src1    = fdiv_uop.vs2_data;
      end
      VFUNARY1: begin
        op_type = fpnew_pkg::SQRT;
        src2    = fdiv_uop.vs2_data;
      end
    endcase
  end

  // wrapper 一次只跟踪一条 FDIV uop：空闲时可接收；若上一条结果本周期被
  // ROB 接收，也允许同周期接收下一条。
  assign fdiv_uop_ready = !fdiv_busy || result_valid&result_ready;

  // busy 置位条件是接收了新 uop；清除条件是当前结果被消费或 trap flush。
  assign fdiv_busy_e = fdiv_busy ? result_valid&result_ready : fdiv_uop_valid;

  cdffr
  is_busy
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (fdiv_busy_e),
    .c      (trap_flush_rvv),
    .d      (fdiv_busy_e&fdiv_uop_valid),
    .q      (fdiv_busy)
  );

  // 保存 uop 元信息，等待 fpnew 多周期结果返回后拼回 PU2ROB_t。
`ifdef TB_SUPPORT
  assign uop_info.uop_pc    = fdiv_uop.uop_pc;
`endif
  assign uop_info.rob_entry = fdiv_uop.rob_entry;

  edff #(
    .T      (FDIV_RES_t)
  ) uop_information
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (fdiv_uop_valid&fdiv_uop_ready),
    .d      (uop_info),
    .q      (uop_info_d1)
  );

  // 将 RVV frm 编码转换为 fpnew roundmode 编码。
  always_comb begin
    case(fdiv_uop.frm)
      FRNE:    frm = fpnew_pkg::RNE;
      FRTZ:    frm = fpnew_pkg::RTZ;
      FRDN:    frm = fpnew_pkg::RDN;
      FRUP:    frm = fpnew_pkg::RUP;
      FRMM:    frm = fpnew_pkg::RMM;
      default: frm = fpnew_pkg::DYN;
    endcase
  end

  generate
    for(i=0;i<`VLENW;i++) begin:fdiv
      // 每个 32-bit 元素一个 fpnew divsqrt 实例。
      // NumPipeRegs=1 且 PipeConfig=BEFORE：入口前放 1 级流水寄存器，
      // divsqrt 本体仍可能是多周期迭代单元。
      fpnew_divsqrt_th_64_multi #(
        .FpFmtConfig        (5'b10000),
        .NumPipeRegs        (1),
        .PipeConfig         (fpnew_pkg::BEFORE)
      )
      fdiv(
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // 输入操作数和控制信息。
        .operands_i         ({src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]}), // 两个 FP32 操作数。
        .is_boxed_i         ('1), // RVV FP32 lane 视为已 NaN-box。
        .rnd_mode_i         (frm),
        .op_i               (op_type),
        .dst_fmt_i          (fpnew_pkg::FP32),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        .vectorial_op_i     ('0),
        // 输入握手：只有 wrapper 接收 uop 的周期才向所有 lane 同步发起。
        .in_valid_i         (fdiv_uop_valid&fdiv_uop_ready),
        .in_ready_o         (),
        .divsqrt_done_o     (),
        .simd_synch_done_i  ('0),
        .divsqrt_ready_o    (),
        .simd_synch_rdy_i   ('0),
        .flush_i            (trap_flush_rvv),
        // 输出结果和浮点异常状态。
        .result_o           (sub_result[i*`WORD_WIDTH +: `WORD_WIDTH]),
        .status_o           (sub_fpexp[i]),
        .extension_bit_o    (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // 输出握手：整条向量结果 valid 且 ROB ready 后消费所有 lane。
        .out_valid_o        (sub_result_vld[i]),
        .out_ready_i        (result_valid&result_ready),
        // fpnew 内部 busy 未用于外部仲裁，本 wrapper 用 fdiv_busy 自行限流。
        .busy_o             (),
        // 外部寄存器使能覆盖未使用。
        .reg_ena_i          ('0),
        // early valid 未用于结构冒险预测。
        .early_out_valid_o  ()
      );

      // 每个 lane 的 fpnew status_t 扩展/复制到 fpexp 对应 4-bit 位置。
      assign result.fpexp[i*4+:4] = {4{sub_fpexp[i]}};
    end
    // 所有 32-bit lane 都有结果后，整条向量 FDIV 结果才 valid。
    assign result_valid     = &sub_result_vld;  //全部结果有效后
  `ifdef TB_SUPPORT
    assign result.uop_pc    = uop_info_d1.uop_pc;
  `endif
    // 组装最终 PU2ROB_t。
    assign result.rob_entry = uop_info_d1.rob_entry;
    assign result.w_data    = sub_result;
    assign result.w_valid   = 'b1;
    assign result.vsaturate = 'b0;
  endgenerate

endmodule
`endif // ZVE32F_ON
