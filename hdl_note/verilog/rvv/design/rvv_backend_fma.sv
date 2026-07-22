`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

`ifdef ZVE32F_ON
//------------------------------------------------------------------------------
// rvv_backend_fma
//------------------------------------------------------------------------------
// 功能定位：
// 1. 浮点 FMA/FCMP/FCVT/FTBL 执行单元顶层，仅在 `ZVE32F_ON` 打开时编译。
// 2. 输入来自 FMA reservation station 的 `FMA_RS_t`，本层先按 `uop_exe_unit`
//    将 uop 分类成 add/mul、compare/class/sign/minmax、convert、table 近似四类。
// 3. 每个 `rvv_backend_fma_wrapper` 内部再实例化 fpnew 子单元和 table 子单元。
// 4. 当前配置下 `NUM_FMA` 在打开 `ZVE32F_ON` 时为 2，因此本模块支持两路
//    FMA RS uop 进入两个 wrapper；结果直接作为两路 `PU2ROB_t` 写回 ROB。
// 5. 本层只做分流、简单双发射调度和结果透传，不改变 ROB entry，也不合并结果。
//
// 调度策略：
// - uop0 年龄更老，优先尝试进入 wrapper0。
// - 若 wrapper0 对 uop0 对应类型不 ready，再尝试把 uop0 送入 wrapper1。
// - 只有 uop0 能被接收后，才考虑 uop1；这样避免年轻 uop 越过无法发射的老 uop。

module rvv_backend_fma( 
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

  // 全局时钟/复位。
  input   logic                         clk;
  input   logic                         rst_n;
  // FMA RS 到本执行单元的 uop 输入；pop 反馈给 RS 作为消费信号。
  output  logic       [`NUM_FMA-1:0]    pop;
  input   logic       [`NUM_FMA-1:0]    uop_valid;    
  input   FMA_RS_t    [`NUM_FMA-1:0]    uop;
  // FMA wrapper 输出给 ROB 写回通路的结果。
  output  logic       [`NUM_FMA-1:0]    result_valid;
  output  PU2ROB_t    [`NUM_FMA-1:0]    result;
  input   logic       [`NUM_FMA-1:0]    result_ready;
  // RVV trap/flush，传递给 wrapper 内部 fpnew/table 子单元。
  input   logic                         trap_flush_rvv; 

//
// 内部信号
//
  // uop 类型分类：bit0 addmul，bit1 cmp/class/sign/minmax，bit2 cvt，bit3 table。
  logic     [`NUM_FMA-1:0]      uop_addmul;
  logic     [`NUM_FMA-1:0]      uop_cmp;
  logic     [`NUM_FMA-1:0]      uop_cvt;
  logic     [`NUM_FMA-1:0]      uop_tbl;
  logic     [`NUM_FMA-1:0][3:0] uop_type;
  logic     [`NUM_FMA-1:0][3:0] fma_uop_type;

  logic     [`NUM_FMA-1:0]      fma_uop_vld;
  logic     [`NUM_FMA-1:0][3:0] fma_uop_rdy;
  FMA_RS_t  [`NUM_FMA-1:0]      fma_uop;

  logic     [`NUM_FMA-1:0]      fma_result_vld;
  logic     [`NUM_FMA-1:0]      fma_result_rdy;
  PU2ROB_t  [`NUM_FMA-1:0]      fma_result;

  genvar                        i;

//
// uop 分类
//
  // wrapper0 额外允许 FCMP 使用 compare 子路径的 ready 反馈；FNCMP 是普通非 mask 比较。
  assign uop_addmul[0]  = uop[0].uop_exe_unit==FMA;
  assign uop_cmp[0]     = uop[0].uop_exe_unit==FNCMP || ((uop[0].uop_exe_unit==FCMP)&fma_uop_rdy[0][1]);
  assign uop_cvt[0]     = uop[0].uop_exe_unit==FCVT;
  assign uop_tbl[0]     = uop[0].uop_exe_unit==FTBL;
  assign uop_type[0]    = {uop_tbl[0], uop_cvt[0], uop_cmp[0], uop_addmul[0]};

  generate
    for(i=1;i<`NUM_FMA;i++) begin
      assign uop_addmul[i]  = uop[i].uop_exe_unit==FMA;
      assign uop_cmp[i]     = uop[i].uop_exe_unit==FNCMP;
      assign uop_cvt[i]     = uop[i].uop_exe_unit==FCVT;
      assign uop_tbl[i]     = uop[i].uop_exe_unit==FTBL;
      assign uop_type[i]    = {uop_tbl[i], uop_cvt[i], uop_cmp[i], uop_addmul[i]};
    end
  endgenerate

  // 双 wrapper 发射选择：
  // - wrapper0 可接收 uop0 时，uop0 固定送 wrapper0，再尝试 uop1 -> wrapper1。
  // - wrapper0 不可接收 uop0 时，尝试 uop0 -> wrapper1；若成功，再尝试 uop1 -> wrapper0。
  // - 若 uop0 两边都发不出去，则全阻塞，保证老 uop 不被年轻 uop 越过。
  always_comb
  begin
    fma_uop       = '0;
    fma_uop_vld   = '0;
    fma_uop_type  = '0;
    pop           = '0;

    // wrapper0 可以接收 uop0 对应类型。
    if(|(uop_type[0]&fma_uop_rdy[0])) begin
      fma_uop[0]      = uop[0];
      fma_uop_vld[0]  = uop_valid[0];
      fma_uop_type[0] = uop_type[0];
      pop[0]          = uop_valid[0];           
      // wrapper1 可以接收 uop1 对应类型。
      if(|(uop_type[1]&fma_uop_rdy[1])) begin
        fma_uop[1]      = uop[1];
        fma_uop_vld[1]  = uop_valid[1];
        fma_uop_type[1] = uop_type[1];
        pop[1]          = uop_valid[1];
      end
    end
    else begin // wrapper0 无法接收 uop0。
      // 因为 uop0 年龄更老，先检查 wrapper1 是否能接收 uop0。
      if(|(uop_type[0]&fma_uop_rdy[1])) begin
        fma_uop[1]      = uop[0];
        fma_uop_vld[1]  = uop_valid[0];
        fma_uop_type[1] = uop_type[0];
        pop[0]          = uop_valid[0];           
        // uop0 已送 wrapper1 后，再检查 wrapper0 是否能接收 uop1。
        if(|(uop_type[1]&fma_uop_rdy[0])) begin
          fma_uop[0]      = uop[1];
          fma_uop_vld[0]  = uop_valid[1];
          fma_uop_type[0] = uop_type[1];
          pop[1]          = uop_valid[1];
        end
      end
    end
  end

  // FMA wrapper 结果可乱序写回 ROB；ROB 根据 rob_entry 完成后续顺序退休。
  assign result_valid   = fma_result_vld;
  assign result         = fma_result;
  assign fma_result_rdy = result_ready;

  generate
    for(i=0;i<`NUM_FMA;i++) begin:uop_unit
      rvv_backend_fma_wrapper #() 
      fma_uop_unit(
        // 全局信号。
        .clk                  (clk),
        .rst_n                (rst_n),
        // FMA RS 输入。
        .fma_uop_vld          (fma_uop_vld[i]),
        .fma_uop              (fma_uop[i]),
        // 本 uop 命中的子路径类型 one-hot。
        .fma_type             (fma_uop_type[i]),
        // wrapper 各子路径 ready，供上面的双发射选择使用。
        .fma_uop_addmul_rdy   (fma_uop_rdy[i][0]),
        .fma_uop_cmp_rdy      (fma_uop_rdy[i][1]),
        .fma_uop_cvt_rdy      (fma_uop_rdy[i][2]),
        .fma_uop_tbl_rdy      (fma_uop_rdy[i][3]),
        // trap/flush。
        .trap_flush_rvv       (trap_flush_rvv),
        // wrapper 到 ROB 写回通路的结果。
        .fma_result_vld       (fma_result_vld[i]),
        .fma_result           (fma_result[i]),
        // ROB/后端结果通路 ready。
        .fma_result_rdy       (fma_result_rdy[i])
      );
    end
  endgenerate

endmodule
`endif // ZVE32F_ON
