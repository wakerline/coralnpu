`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

// rvv_backend — RVV 后端顶层。
//
// 数据主路径可以按如下方式阅读：
//   RvvFrontEnd -> Command Queue(CQ) -> DE1 -> Legal Command Queue(LCQ)
//   -> DE2 -> Uop Queue(UQ) -> Dispatch -> 各类 RS -> 执行单元
//   -> 结果回填 ROB -> Retire -> VRF/XRF/FRF/VCSR。
//
// 该模块还负责两类全局控制：
//   1. trap_flush_rvv 清空 CQ/LCQ/UQ/RS/执行结果缓冲，保证 trap 后后端流水线被刷新；
//   2. remaining_count_cq2rvs 把 CQ 剩余空间反馈给前端，用于 decode/RVS 反压。
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend` -> 后端顶层：CQ -> DE1 -> LCQ -> DE2 -> UQ -> Dispatch -> RS/EX -> ROB -> Retire。
// - 接口与数据流：
//   * 输入：前端 RVVCmd、LSU 返回结果、retire ready、trap 注入握手。
//   * 内部：命令队列和 uop 队列解耦各流水段；RS 解耦不同执行单元；ROB 保证按序 retire。
//   * 输出：LSU uop、ROB/retire 写回、VCSR/VXSAT 更新、rvv_idle。
// - 调用关系：上层 RvvCore；下层 rvv_backend_alu(u_alu), rvv_backend_arb(u_arb), rvv_backend_decode(u_decode_de1), rvv_backend_decode_de2(u_decode_de2), rvv_backend_dispatch(u_dispatch), rvv_backend_div(u_div), rvv_backend_fma(u_fma), rvv_backend_lsu_remap(u_lsu_remap), rvv_backend_mulmac(u_mulmac), rvv_backend_pmtrdt(u_pmtrdt) ...
// - 端口摘要：输入 clk, rst_n, insts_valid_rvs2cq, insts_rvs2cq, uop_lsu_ready_lsu2rvv, uop_lsu_valid_lsu2rvv, uop_lsu_lsu2rvv, rt_rvs_ready_rvs2rvv, async_frd_ready, wr_vxsat_ready, fcsr2rt_write_ready, trap_valid_rvs2rvv；输出 insts_ready_cq2rvs, remaining_count_cq2rvs, uop_lsu_valid_rvv2lsu, uop_lsu_rvv2lsu, uop_lsu_ready_rvv2lsu, rt_xrf_valid_rvv2rvs, rt_rvs_rvv2rvs, async_frd_valid, async_frd_addr, async_frd_data, wr_vxsat_valid, wr_vxsat。
// - define/参数阅读重点：
//   * `ALU_RS_DEPTH`：8；当前 DISPATCH3 下 ALU RS 深度，DISPATCH2 时为 4。
//   * `CQ_DEPTH`：8；Command Queue 深度。
//   * `DIV_RS_DEPTH`：4；DIV RS 深度。
//   * `FMA_RS_DEPTH`：8；当前 DISPATCH3 下 FMA RS 深度，DISPATCH2 时为 4。
//   * `ISSUE_LANE`：4；标量/RVS 到 RVV 前端或 CQ 的发射 lane 数。
//   * `LCQ_DEPTH`：8；Legal Command Queue 深度。
//   * `LSU_RS_DEPTH`：4；LSU RS 和 LSU mapinfo 队列深度。
//   * `MUL_RS_DEPTH`：8；当前 DISPATCH3 下 MUL RS 深度，DISPATCH2 时为 4。
//   * `NUM_ALU`：2；ALU 执行 lane 数。
//   * `NUM_DE_INST`：3'd2；DE1/DE2 每拍处理的命令条数。
//   * `NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
//   * `NUM_DIV`：1；DIV 执行单元数量。
//   * `NUM_DP_UOP`：3；当前 DISPATCH3 下 Dispatch 每拍最多发射 uop 数，DISPATCH2 时为 2。
//   * `NUM_DP_VRF`：6；当前 DISPATCH3 下 Dispatch 侧 VRF 读口数，DISPATCH2 时为 4。
//   * `NUM_FMA`：0；当前未开启 ZVE32F_ON，开启 ZVE32F_ON 时为 2。
//   * `NUM_LSU`：2；RVV 与 LSU 之间的 lane 数。
//   * `NUM_MUL`：2；MUL/MAC 执行 lane 数。
//   * `NUM_PMTRDT`：1；置换/规约执行单元数量。
//   * 其余 12 个宏请结合上方自动梳理块和 include 文件继续确认。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
//   * 浮点相关宏受 `ZVE32F_ON` 控制；当前配置文件未开启，所以 NUM_FMA=0、FP_RDT_TAG_WIDTH=0。
//   * 断言宏来自 `rvv_backend_sva.svh`，只有相关编译开关打开时才会参与仿真检查。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module rvv_backend
(
    clk,
    rst_n,

    insts_valid_rvs2cq,
    insts_rvs2cq,
    insts_ready_cq2rvs,
    remaining_count_cq2rvs,

    uop_lsu_valid_rvv2lsu,
    uop_lsu_rvv2lsu,
    uop_lsu_ready_lsu2rvv,

    uop_lsu_valid_lsu2rvv,
    uop_lsu_lsu2rvv,
    uop_lsu_ready_rvv2lsu,

    rt_xrf_valid_rvv2rvs,
    rt_rvs_rvv2rvs,
    rt_rvs_ready_rvs2rvv,

`ifdef ZVE32F_ON
    async_frd_valid,
    async_frd_addr,
    async_frd_data,
    async_frd_ready,
`endif

    wr_vxsat_valid,
    wr_vxsat,
    wr_vxsat_ready,

`ifdef ZVE32F_ON
    rt2fcsr_write_valid,
    rt2fcsr_write_data,
    fcsr2rt_write_ready,
`endif

    trap_valid_rvs2rvv,
    trap_ready_rvv2rvs,    

    vcsr_valid,
    vector_csr,
    vcsr_ready,

    rd_valid_rob2rt_o,
    rd_rob2rt_o,

    rvv_idle
);
// 全局时钟/复位。
    input   logic                                 clk;
    input   logic                                 rst_n;

// 前端送入的 RVVCmd。ISSUE_LANE 表示 CQ 一拍最多接收的命令条数。
    input   logic         [`ISSUE_LANE-1:0]       insts_valid_rvs2cq;
    input   RVVCmd        [`ISSUE_LANE-1:0]       insts_rvs2cq;
    output  logic         [`ISSUE_LANE-1:0]       insts_ready_cq2rvs;  
    output  logic         [$clog2(`CQ_DEPTH):0]   remaining_count_cq2rvs; 

// 向量 LSU 接口。
  // RVV 后端把向量访存 uop 发给标量 LSU/RVS 侧。
    output  logic         [`NUM_LSU-1:0]          uop_lsu_valid_rvv2lsu;
    output  UOP_RVV2LSU_t [`NUM_LSU-1:0]          uop_lsu_rvv2lsu;
    input   logic         [`NUM_LSU-1:0]          uop_lsu_ready_lsu2rvv;
  // LSU 把访存完成结果回传给 RVV 后端。
    input   logic         [`NUM_LSU-1:0]          uop_lsu_valid_lsu2rvv;
    input   UOP_LSU2RVV_t [`NUM_LSU-1:0]          uop_lsu_lsu2rvv;
    output  logic         [`NUM_LSU-1:0]          uop_lsu_ready_rvv2lsu;

// Retire 写回标量整数寄存器堆 XRF。
    output  logic         [`NUM_RT_UOP-1:0]       rt_xrf_valid_rvv2rvs;
    output  RT2RVS_t      [`NUM_RT_UOP-1:0]       rt_rvs_rvv2rvs;
    input   logic         [`NUM_RT_UOP-1:0]       rt_rvs_ready_rvs2rvv;

// Retire 写回标量浮点寄存器堆 FRF。
`ifdef ZVE32F_ON
    output  logic [`NUM_RT_UOP-1:0]                           async_frd_valid;
    output  logic [`NUM_RT_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] async_frd_addr;
    output  logic [`NUM_RT_UOP-1:0][`XLEN-1:0]                async_frd_data;
    input   logic [`NUM_RT_UOP-1:0]                           async_frd_ready;
`endif

// Retire 更新 VCSR.vxsat。
    output  logic                                 wr_vxsat_valid;
    output  logic         [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;
    input   logic                                 wr_vxsat_ready;

`ifdef ZVE32F_ON
// Retire 更新 FCSR。
    output  logic                                 rt2fcsr_write_valid;
    output  RVFEXP_t                              rt2fcsr_write_data;
    input   logic                                 fcsr2rt_write_ready;
`endif

// 异常/trap 处理接口。
  // 标量侧向 RVV 后端注入 trap 的握手。
    input   logic                                 trap_valid_rvs2rvv;  //未连接
    output  logic                                 trap_ready_rvv2rvs;    
  // 上一拍最后退役 uop 对应的 VCSR 状态。
    output  logic                                 vcsr_valid;
    output  RVVConfigState                        vector_csr;
    input   logic                                 vcsr_ready;

// ROB 到 Retire 的观察输出，供顶层/调试侧查看退役信息。
    output  logic     [`NUM_RT_UOP-1:0]               rd_valid_rob2rt_o;
    output  ROB2RT_t  [`NUM_RT_UOP-1:0]               rd_rob2rt_o;

// 后端空闲指示：主要队列和 ROB 为空时拉高。
    output  logic                                 rvv_idle;


// --- 内部信号定义 ----------------------------------------------------
  // RVV 前端到命令队列 CQ。
    logic         [`ISSUE_LANE-1:0]       cq_almost_full;
    logic         [`ISSUE_LANE-1:0]       insts_ready;  
    logic         [$clog2(`CQ_DEPTH):0]   used_count_cq; 
  // 命令队列到 DE1 decode。
    logic         [`NUM_DE_INST-1:0]      inst_valid_cq2de;
    RVVCmd        [`NUM_DE_INST-1:0]      inst_cq2de;
    logic                                 fifo_empty_cq2de;
    logic         [`NUM_DE_INST-1:0]      fifo_almost_empty_cq2de;
    logic         [`NUM_DE_INST-1:0]      pop_de2cq;

    logic         [`NUM_DE_INST-1:0]      lcmd_valid_de2lcq;
    LCMD_t        [`NUM_DE_INST-1:0]      lcmd_de2lcq;
  // LCQ 保存 DE1 产生的合法命令，供 DE2 继续展开为 uop。
    logic         [`NUM_DE_INST-1:0]      lcmd_valid_lcq2de;
    LCMD_t        [`NUM_DE_INST-1:0]      lcmd_lcq2de;
    logic                                 fifo_empty_lcq2de;
    logic         [`NUM_DE_INST-1:0]      fifo_almost_empty_lcq2de;
    logic         [`NUM_DE_INST-1:0]      fifo_almost_full_lcq2de;
    logic         [`NUM_DE_INST-1:0]      pop_de2lcq;
  // DE2 到 uop queue：一条命令可能展开成多条微操作。
    logic         [`NUM_DE_UOP-1:0]       push_de2uq;
    UOP_QUEUE_t   [`NUM_DE_UOP-1:0]       uop_de2uq;
    logic         [`NUM_DE_UOP-1:0]       fifo_almost_full_uq2de;
    logic         [`NUM_DE_UOP-1:0]       uq_ready;
  // uop queue 到 dispatch。
    logic                                 uq_empty;
    logic         [`NUM_DP_UOP-1:0]       uq_almost_empty;
    logic         [`NUM_DP_UOP-1:0]       uop_valid_uop2dp;
    UOP_QUEUE_t   [`NUM_DP_UOP-1:0]       uop_uop2dp;
    logic         [`NUM_DP_UOP-1:0]       uop_ready_dp2uop;

  // Dispatch 到各类保留站 RS。
    // ALU_RS
    logic         [`NUM_DP_UOP-1:0]       alu_rs_almost_full;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2alu;
    ALU_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2alu;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_alu2dp;
    // PMTRDT_RS  
    logic         [`NUM_DP_UOP-1:0]       pmtrdt_rs_almost_full;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2pmtrdt;
    PMT_RDT_RS_t  [`NUM_DP_UOP-1:0]       rs_dp2pmtrdt;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_pmtrdt2dp;
    // MUL_RS
    logic         [`NUM_DP_UOP-1:0]       mul_rs_almost_full;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2mul;
    MUL_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2mul;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_mul2dp;
    // DIV_RS
    logic         [`NUM_DP_UOP-1:0]       div_rs_almost_full;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2div;
    DIV_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2div;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_div2dp;
`ifdef ZVE32F_ON
    // FMA_RS
    logic         [`NUM_DP_UOP-1:0]       fma_rs_almost_full;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2fma;
    FMA_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2fma;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_fma2dp;
`endif
    // LSU_RS
    logic         [`NUM_DP_UOP-1:0]       lsu_rs_almost_full;
    logic                                 lsu_rs_empty;
    logic         [`NUM_LSU-1:0]          lsu_rs_almost_empty;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2lsu;
    UOP_RVV2LSU_t [`NUM_DP_UOP-1:0]       rs_dp2lsu;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_lsu2dp;
    // LSU map info 保存访存 uop 与 ROB entry 的对应关系，供 LSU 返回结果后重映射。
    logic         [`NUM_DP_UOP-1:0]       mapinfo_almost_full;
    logic         [`NUM_DP_UOP-1:0]       mapinfo_valid_dp2lsu;
    LSU_MAP_INFO_t  [`NUM_DP_UOP-1:0]     mapinfo_dp2lsu;
    logic         [`NUM_DP_UOP-1:0]       mapinfo_ready_lsu2dp;
  // Dispatch 同时为 uop 分配 ROB entry。
    logic         [`NUM_DP_UOP-1:0]       uop_valid_dp2rob;
    DP2ROB_t      [`NUM_DP_UOP-1:0]       uop_dp2rob;
    logic         [`NUM_DP_UOP-1:0]       uop_ready_rob2dp;
    logic         [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2dp;
  
  // RS 到执行单元。
  // ALU_RS 到 ALU。
    logic         [`NUM_ALU-1:0]          pop_alu2rs;
    logic         [`NUM_ALU-1:0]          uop_valid_rs2alu;
    ALU_RS_t      [`NUM_ALU-1:0]          uop_rs2alu;
    logic         [`NUM_ALU-1:0]          fifo_almost_empty_rs2alu;
  // PMTRDT_RS to PMTRDT
    logic         [`NUM_PMTRDT-1:0]       pop_pmtrdt2rs;
    PMT_RDT_RS_t  [`NUM_PMTRDT-1:0]       uop_rs2pmtrdt;
    logic         [`NUM_PMTRDT-1:0]       fifo_almost_empty_rs2pmtrdt;
  // MUL_RS to MUL
    logic         [`NUM_MUL-1:0]          pop_mul2rs;
    MUL_RS_t      [`NUM_MUL-1:0]          uop_rs2mul;
    logic                                 fifo_empty_rs2mul;
    logic         [`NUM_MUL-1:0]          fifo_almost_empty_rs2mul;
  // DIV_RS to DIV
    logic         [`NUM_DIV-1:0]          pop_div2rs;
    logic         [`NUM_DIV-1:0]          uop_valid_rs2div;
    DIV_RS_t      [`NUM_DIV-1:0]          uop_rs2div;
    logic         [`NUM_DIV-1:0]          fifo_almost_empty_rs2div;
`ifdef ZVE32F_ON
  // FMA_RS to FMA
    logic         [`NUM_FMA-1:0]          pop_fma2rs;
    logic         [`NUM_FMA-1:0]          uop_valid_rs2fma;
    FMA_RS_t      [`NUM_FMA-1:0]          uop_rs2fma;
    logic         [`NUM_FMA-1:0]          fifo_almost_empty_rs2fma;
`endif
  // LSU mapinfo
    logic         [`NUM_LSU-1:0]          mapinfo_valid;
    LSU_MAP_INFO_t  [`NUM_LSU-1:0]        mapinfo;
    logic         [`NUM_LSU-1:0]          pop_mapinfo;
    logic                                 mapinfo_empty;
    logic         [`NUM_LSU-1:0]          mapinfo_almost_empty;
  // LSU result
    logic         [`NUM_LSU-1:0]          lsu_res_valid;
    UOP_LSU_t     [`NUM_LSU-1:0]          lsu_res;
    logic         [`NUM_LSU-1:0]          pop_lsu_res;
    logic                                 lsu_res_empty;
    logic         [`NUM_LSU-1:0]          lsu_res_almost_full;
    logic         [`NUM_LSU-1:0]          lsu_res_almost_empty;
    logic         [`NUM_LSU-1:0]          uop_lsu_valid;
    UOP_LSU_t     [`NUM_LSU-1:0]          uop_lsu;
    logic         [`NUM_LSU-1:0]          uop_lsu_ready;
    logic                                 trap_valid_rmp2rob;
    logic         [`ROB_DEPTH_WIDTH-1:0]  trap_rob_entry_rmp2rob;

  // execution unit submit result to ROB
  // PU to ARB
    logic         [`NUM_PU-1:0]           res_valid_pu2arb;
    PU2ROB_t      [`NUM_PU-1:0]           res_pu2arb;
    logic         [`NUM_PU-1:0]           res_ready_arb2pu;
  // ARB
  `ifdef ARBITER_ON
    logic         [`NUM_PU-1:`NUM_LSU]    req_ari;
    logic         [`NUM_PU-1:0]           req_arb;
    logic         [`NUM_PU-1:0]           grant_arb;
    PU2ROB_t      [`NUM_PU-1:`NUM_LSU]    item_ari; 
    PU2ROB_t      [`NUM_PU-1:0]           item_arb; 
    logic         [`NUM_PU-1:`NUM_LSU]    res_ff_full;
    logic         [`NUM_PU-1:`NUM_LSU]    res_ff_empty;
  `endif
  // ARB to ROB
    logic         [`NUM_SMPORT-1:0]       res_valid_arb2rob;
    PU2ROB_t      [`NUM_SMPORT-1:0]       res_arb2rob;
  // ALU result
    logic         [`NUM_ALU-1:0]          res_valid_alu;
    PU2ROB_t      [`NUM_ALU-1:0]          res_alu;
    logic         [`NUM_ALU-1:0]          res_ready_alu;
  // PMTRDT result
    logic         [`NUM_PMTRDT-1:0]       res_valid_pmtrdt;
    PU2ROB_t      [`NUM_PMTRDT-1:0]       res_pmtrdt;
    logic         [`NUM_PMTRDT-1:0]       res_ready_pmtrdt;
  // MUL result
    logic         [`NUM_MUL-1:0]          res_valid_mul;
    PU2ROB_t      [`NUM_MUL-1:0]          res_mul;
    logic         [`NUM_MUL-1:0]          res_ready_mul;
  // DIV result
    logic         [`NUM_DIV-1:0]          res_valid_div;
    PU2ROB_t      [`NUM_DIV-1:0]          res_div;
    logic         [`NUM_DIV-1:0]          res_ready_div;
`ifdef ZVE32F_ON
  // FMA result
    logic         [`NUM_FMA-1:0]          res_valid_fma;
    PU2ROB_t      [`NUM_FMA-1:0]          res_fma;
    logic         [`NUM_FMA-1:0]          res_ready_fma;
`endif
  // LSU result
    logic         [`NUM_LSU-1:0]          res_valid_lsu;
    PU2ROB_t      [`NUM_LSU-1:0]          res_lsu;
    logic         [`NUM_LSU-1:0]          res_ready_lsu;
  // DP to VRF
    logic [`NUM_DP_VRF-1:0][`REGFILE_INDEX_WIDTH-1:0] rd_index_dp2vrf;          
    logic [`NUM_DP_VRF-1:0][`VLEN-1:0]                rd_data_vrf2dp;
    logic [`VLEN-1:0]                                 v0_mask_vrf2dp;
  // PMT to VRF
    logic [`REGFILE_INDEX_WIDTH-1:0]      rd_index_pmt2vrf;          
    logic [`VLEN-1:0]                     rd_data_vrf2pmt;
  // ROB to dispatch
    ROB2DP_t      [`ROB_DEPTH-1:0]        uop_rob2dp;
    logic                                 rob_empty;
  // ROB to RT
    logic         [`NUM_RT_UOP-1:0]       rd_valid_rob2rt;
    ROB2RT_t      [`NUM_RT_UOP-1:0]       rd_rob2rt;
    logic         [`NUM_RT_UOP-1:0]       rd_ready_rt2rob;
    logic         [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2rt;
  // RT to VRF
    logic         [`NUM_RT_UOP-1:0]       wr_valid_rt2vrf;
    RT2VRF_t      [`NUM_RT_UOP-1:0]       wr_data_rt2vrf;
  
  // trap handler
    logic                                 trap_en;
    logic                                 is_trapping;
    logic                                 trap_ready_rob2rmp;   
    logic                                 trap_flush_rvv;
  
    genvar                                i;

// --- 逻辑主体 --------------------------------------------------------
  // Command Queue(CQ)：接收前端一拍最多 ISSUE_LANE 条 RVVCmd，
  // DE1 侧按 NUM_DE_INST 条/拍读取。trap_flush_rvv 会清空队列。
    multi_fifo #(
        .T            (RVVCmd),
        .M            (`ISSUE_LANE),   //4
        .N            (`NUM_DE_INST),  //2
        .ASYNC_RSTN   (1'b1),
        .DEPTH        (`CQ_DEPTH)      //8
    ) u_command_queue (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (insts_valid_rvs2cq & insts_ready_cq2rvs),
        .datain       (insts_rvs2cq),
      // read
        .pop          (pop_de2cq),
        .dataout      (inst_cq2de),  //输出不打拍
      // fifo status
        .full         (),
        .almost_full  (cq_almost_full),
        .empty        (fifo_empty_cq2de),
        .almost_empty (fifo_almost_empty_cq2de),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  (used_count_cq)  //fifo内有效数据个数
    );

    // almost_full 按 lane 给出，前端必须保持低 lane 连续入队。
    // CQ 近满时反压前端，停止接收新命令。
    assign insts_ready = ~cq_almost_full;
    // 正在 trap 处理时停止继续接收新命令。
    assign insts_ready_cq2rvs = is_trapping ? 'b0 : insts_ready;  //外部未连接
    
    // 输出 CQ 剩余空间，RvvFrontEnd 用它计算可继续接受多少条输入指令。
    assign remaining_count_cq2rvs = is_trapping ? 'b0 : `CQ_DEPTH - used_count_cq;

  `ifdef ASSERT_ON
    PushToCMDQueue: `rvv_expect((insts_valid_rvs2cq & insts_ready_cq2rvs) inside {4'b1111, 4'b0111, 4'b0011, 4'b0001, 4'b0000})
      else $error("Push to command queue out-of-order: %4b.", $sampled(insts_valid_rvs2cq & insts_ready_cq2rvs));
  `endif // ASSERT_ON

  // DE1 decode：从 CQ 取 RVVCmd，转换成 LCMD。
  // 当 CQ 近空或 LCQ 近满时停止 pop，避免读无效数据或压爆下游。
    assign inst_valid_cq2de = ~(fifo_almost_empty_cq2de | fifo_almost_full_lcq2de);  //N路
    assign pop_de2cq = inst_valid_cq2de;  //传到fifo，fifo_almost_empty_cq2de为1时不pop，防止读无效数据
    
    rvv_backend_decode #(
    ) u_decode_de1 (
      .inst_valid         (inst_valid_cq2de),
      .inst               (inst_cq2de),
      .lcmd_valid         (lcmd_valid_de2lcq),
      .lcmd               (lcmd_de2lcq)
    );
  
  // Legal Command Queue(LCQ)：缓存 DE1 输出，为 DE2 提供解耦。
  // CHAOS_PUSH 允许输入 valid 不完全连续，便于接收 decode 过滤后的合法命令。
    multi_fifo #(
        .T                (LCMD_t),
        .M                (`NUM_DE_INST),
        .N                (`NUM_DE_INST),
        .ASYNC_RSTN       (1'b1),
        .DEPTH            (`LCQ_DEPTH),
        .CHAOS_PUSH       (1'b1)
    ) u_legal_command_queue (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (lcmd_valid_de2lcq),
        .datain           (lcmd_de2lcq),
      // read
        .pop              (pop_de2lcq),
        .dataout          (lcmd_lcq2de),
      // fifo status
        .full             (),
        .almost_full      (fifo_almost_full_lcq2de),
        .empty            (fifo_empty_lcq2de),
        .almost_empty     (fifo_almost_empty_lcq2de),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );

  // DE2 decode：把 LCMD 展开成具体 uop，并根据 UQ ready 产生 pop/push。
    assign lcmd_valid_lcq2de = ~fifo_almost_empty_lcq2de;  //上一级fifo不为空有效

    rvv_backend_decode_de2 #(
    ) u_decode_de2 (
      .clk                (clk),
      .rst_n              (rst_n),
      .lcmd_valid         (lcmd_valid_lcq2de),
      .lcmd               (lcmd_lcq2de), 
      .pop                (pop_de2lcq),  //输出 pop 回给 LCQ，表示对应 LCMD 已经被 DE2 完整接收/展开，可以从队列弹出。
      .push               (push_de2uq),  //输出 写入 Uop Queue 的一维 uop 流；push[i] 与 uop[i] 一一对应。
      .uop                (uop_de2uq),   //输出
      .uq_ready           (uq_ready),    //输入 下级流水线反压，只有 ready 时才会 push。
      .trap_flush_rvv     (trap_flush_rvv)
    );

  // Uop Queue(UQ)：保存 DE2 展开的微操作，供 Dispatch 按 NUM_DP_UOP 宽度读取。
    multi_fifo #(
        .T                (UOP_QUEUE_t),
        .M                (`NUM_DE_UOP),
        .N                (`NUM_DP_UOP),
        .ASYNC_RSTN       (1'b1),
        .DEPTH            (`UQ_DEPTH)
    ) u_uop_queue (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (push_de2uq),
        .datain           (uop_de2uq),
      // read
        .pop              (uop_valid_uop2dp & uop_ready_dp2uop),
        .dataout          (uop_uop2dp),
      // fifo status
        .full             (),
        .almost_full      (fifo_almost_full_uq2de),
        .empty            (uq_empty),
        .almost_empty     (uq_almost_empty),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );
   
    // UQ 近满时反压 DE2；近空标志直接转为 dispatch 侧 valid。
    assign uq_ready = ~fifo_almost_full_uq2de;
    assign uop_valid_uop2dp = ~uq_almost_empty;

  `ifdef ASSERT_ON
    `ifdef  DISPATCH3
      PushToUopQueue: `rvv_expect(push_de2uq inside {6'b111111, 6'b011111, 6'b001111, 6'b000111, 6'b000011, 6'b000001, 6'b000000})
        else $error("Push to uops queue out-of-order:      0", $sampled(push_de2uq));

      PopFromUopQueue: `rvv_expect((uop_valid_uop2dp & uop_ready_dp2uop) inside {3'b111, 3'b011, 3'b001,3'b000})
        else $error("Pop from uops queue out-of-order:   0", $sampled(uop_valid_uop2dp & uop_ready_dp2uop));
    `else // DISPATCH2
      PushToUopQueue: `rvv_expect(push_de2uq inside {4'b1111, 4'b0111, 4'b0011, 4'b0001, 4'b0000})
        else $error("Push to uops queue out-of-order:    0", $sampled(push_de2uq));

      PopFromUopQueue: `rvv_expect((uop_valid_uop2dp & uop_ready_dp2uop) inside {2'b11, 2'b01, 2'b00})
        else $error("Pop from uops queue out-of-order:  0", $sampled(uop_valid_uop2dp & uop_ready_dp2uop));
    `endif
  `endif // ASSERT_ON

  // Dispatch：读取 UQ，完成 VRF 读索引生成、ROB entry 分配，并把 uop 分发到对应 RS。
  // 同一条 uop 会同时携带写 ROB 的元信息和发往执行单元的操作数/控制信息。
    rvv_backend_dispatch #(
    ) u_dispatch (
      // global
        .clk                  (clk),
        .rst_n                (rst_n),
      // Uop queue to dispatch
        .uop_valid_uop2dp     (uop_valid_uop2dp),
        .uop_uop2dp           (uop_uop2dp),
        .uop_ready_dp2uop     (uop_ready_dp2uop),
      // Dispatch to RS
        // ALU_RS
        .rs_valid_dp2alu      (rs_valid_dp2alu),
        .rs_dp2alu            (rs_dp2alu),
        .rs_ready_alu2dp      (rs_ready_alu2dp),
        // PMTRDT_RS 
        .rs_valid_dp2pmtrdt   (rs_valid_dp2pmtrdt),
        .rs_dp2pmtrdt         (rs_dp2pmtrdt),
        .rs_ready_pmtrdt2dp   (rs_ready_pmtrdt2dp),
        // MUL_RS
        .rs_valid_dp2mul      (rs_valid_dp2mul),
        .rs_dp2mul            (rs_dp2mul),
        .rs_ready_mul2dp      (rs_ready_mul2dp),
        // DIV_RS
        .rs_valid_dp2div      (rs_valid_dp2div),
        .rs_dp2div            (rs_dp2div),
        .rs_ready_div2dp      (rs_ready_div2dp),
        `ifdef ZVE32F_ON
        // FMA_RS
        .rs_valid_dp2fma      (rs_valid_dp2fma),
        .rs_dp2fma            (rs_dp2fma),
        .rs_ready_fma2dp      (rs_ready_fma2dp),
        `endif
        // LSU_RS
        .rs_valid_dp2lsu      (rs_valid_dp2lsu),
        .rs_dp2lsu            (rs_dp2lsu),
        .rs_ready_lsu2dp      (rs_ready_lsu2dp),
        // LSU MAP INFO
        .mapinfo_valid_dp2lsu (mapinfo_valid_dp2lsu),
        .mapinfo_dp2lsu       (mapinfo_dp2lsu),
        .mapinfo_ready_lsu2dp (mapinfo_ready_lsu2dp),
      // Dispatch to ROB
        .uop_valid_dp2rob     (uop_valid_dp2rob),
        .uop_dp2rob           (uop_dp2rob),
        .uop_ready_rob2dp     (uop_ready_rob2dp),
        .rob_entry_rob2dp     (rob_entry_rob2dp),
      // VRF to dispatch
        .rd_index_dp2vrf      (rd_index_dp2vrf),
        .rd_data_vrf2dp       (rd_data_vrf2dp),
        .v0_mask_vrf2dp       (v0_mask_vrf2dp),
      // ROB to dispatch
        .rob_entry            (uop_rob2dp)
    );

  // RS, Reserve Station：各执行单元前的独立小队列，用于吸收不同执行单元 ready 的差异。
    // ALU RS：普通整数/逻辑向量运算。
    multi_fifo #(
        .T            (ALU_RS_t),
        .M            (`NUM_DP_UOP),    //`NUM_DP_UOP`：3；当前 DISPATCH3 下 Dispatch 每拍最多发射 uop 数，DISPATCH2 时为 2。
        .N            (`NUM_ALU),       //alu执行lane数量: 2 , fifo输出
        .DEPTH        (`ALU_RS_DEPTH),  //`ALU_RS_DEPTH`：8；当前 DISPATCH3 下 ALU RS 深度，DISPATCH2 时为 4。
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1)
    ) u_alu_rs (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (rs_valid_dp2alu),
        .datain       (rs_dp2alu),
      // read
        .pop          (pop_alu2rs),
        .dataout      (uop_rs2alu),
      // fifo status
        .full         (),
        .almost_full  (alu_rs_almost_full),
        .empty        (),
        .almost_empty (fifo_almost_empty_rs2alu),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

    assign rs_ready_alu2dp = ~alu_rs_almost_full;

  `ifdef ASSERT_ON
    PopFromAluRSQueue: `rvv_expect((pop_alu2rs) inside {2'b11, 2'b01, 2'b00})
      else $error("Pop from ALU Reservation Station out-of-order:  0", $sampled(pop_alu2rs));
  `endif // ASSERT_ON

    // PMTRDT RS：Permutation + Reduction 类指令。
    multi_fifo #(
        .T                (PMT_RDT_RS_t),
        .M                (`NUM_DP_UOP),
        .N                (`NUM_PMTRDT),  //1
        .ASYNC_RSTN       (1'b1),
        .DEPTH            (`PMTRDT_RS_DEPTH),  //4或8
        .CHAOS_PUSH       (1'b1)
    ) u_pmtrdt_rs (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (rs_valid_dp2pmtrdt),
        .datain           (rs_dp2pmtrdt),
      // read
        .pop              (pop_pmtrdt2rs),
        .dataout          (uop_rs2pmtrdt),
      // fifo status
        .full             (),
        .almost_full      (pmtrdt_rs_almost_full),
        .empty            (),
        .almost_empty     (fifo_almost_empty_rs2pmtrdt),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );

    assign rs_ready_pmtrdt2dp = ~pmtrdt_rs_almost_full;

  `ifdef ASSERT_ON
     PopFromPmtrdtRSQueue: `rvv_expect((pop_pmtrdt2rs) inside {1'b1, 1'b0})
       else $error("Pop from PMTRDT Reservation Station out-of-order: 0", $sampled(pop_pmtrdt2rs));
  `endif // ASSERT_ON

    // MUL RS：Multiply + Multiply-accumulate 类指令。
    multi_fifo #(
        .T              (MUL_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_MUL),  //2
        .ASYNC_RSTN     (1'b1),
        .DEPTH          (`MUL_RS_DEPTH),  //4或8
        .CHAOS_PUSH     (1'b1)
    ) u_mul_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2mul),
        .datain         (rs_dp2mul),
      // read
        .pop            (pop_mul2rs),
        .dataout        (uop_rs2mul),
      // fifo status
        .full           (),
        .almost_full    (mul_rs_almost_full),
        .empty          (fifo_empty_rs2mul),
        .almost_empty   (fifo_almost_empty_rs2mul),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

    assign rs_ready_mul2dp = ~mul_rs_almost_full;

  `ifdef ASSERT_ON
     PopFromMulRSQueue: `rvv_expect((pop_mul2rs) inside {2'b11, 2'b01, 2'b00})
       else $error("Pop from MUL Reservation Station out-of-order: %2b", $sampled(pop_mul2rs));
  `endif // ASSERT_ON

    // DIV RS：除法类指令，通常执行延迟更长。
    multi_fifo #(
        .T              (DIV_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_DIV),       //1
        .ASYNC_RSTN     (1'b1),
        .DEPTH          (`DIV_RS_DEPTH),  //恒为4
        .CHAOS_PUSH     (1'b1)
    ) u_div_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2div),
        .datain         (rs_dp2div),
      // read
        .pop            (pop_div2rs),
        .dataout        (uop_rs2div),
      // fifo status
        .full           (),
        .almost_full    (div_rs_almost_full),
        .empty          (),
        .almost_empty   (fifo_almost_empty_rs2div),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

    assign rs_ready_div2dp = ~div_rs_almost_full;

  `ifdef ASSERT_ON
     PopFromDivRSQueue: `rvv_expect((pop_div2rs) inside {1'b1, 1'b0})
       else $error("Pop from DIV Reservation Station out-of-order: 0", $sampled(pop_div2rs));
  `endif // ASSERT_ON

  `ifdef ZVE32F_ON
    // FMA RS：浮点向量 FMA 类指令。
    multi_fifo #(
        .T              (FMA_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_FMA),     //2
        .ASYNC_RSTN     (1'b1),
        .DEPTH          (`FMA_RS_DEPTH),  //4或8
        .CHAOS_PUSH     (1'b1)
    ) u_fma_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2fma),
        .datain         (rs_dp2fma),
      // read
        .pop            (pop_fma2rs),       
        .dataout        (uop_rs2fma),       
      // fifo status
        .full           (),
        .almost_full    (fma_rs_almost_full),
        .empty          (),
        .almost_empty   (fifo_almost_empty_rs2fma),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

    assign rs_ready_fma2dp  = ~fma_rs_almost_full;
  `endif

    // LSU RS：向量访存 uop 队列。输出侧要求从 lane0 开始顺序弹出，
    // 后一个 LSU lane 只有在前一个 lane 已经 valid 且被 LSU ready 接收时才 valid。
    logic [`NUM_LSU-1:0] lsu_rs_pop;
    generate
        for (i=0; i<`NUM_LSU; i++) begin: gen_lsu_rs_pop
            if (i==0) begin: gen_first
                assign lsu_rs_pop[i] = uop_lsu_valid_rvv2lsu[i] & uop_lsu_ready_lsu2rvv[i];
            end else begin: gen_i
                assign lsu_rs_pop[i] = lsu_rs_pop[i-1] & uop_lsu_valid_rvv2lsu[i] & uop_lsu_ready_lsu2rvv[i];
            end
        end
    endgenerate

    multi_fifo #(
        .T            (UOP_RVV2LSU_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_LSU),       //2
        .ASYNC_RSTN   (1'b1),
        .DEPTH        (`LSU_RS_DEPTH),  //恒为4
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_rs (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (rs_valid_dp2lsu),
        .datain       (rs_dp2lsu),
      // read
        .pop          (lsu_rs_pop),
        .dataout      (uop_lsu_rvv2lsu),  //直接传出IO
      // fifo status
        .full         (),
        .almost_full  (lsu_rs_almost_full),
        .empty        (lsu_rs_empty),
        .almost_empty (lsu_rs_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );
    // LSU RS 满信号返回给 dispatch，用于阻塞新的访存 uop。
    assign rs_ready_lsu2dp = ~lsu_rs_almost_full;

    // 输出给 LSU 的 valid/data，同样保持低 lane 连续，防止乱序缺口。
    logic [`NUM_LSU-1:0] lsu_rs_valid_pre;
    assign lsu_rs_valid_pre = ~lsu_rs_almost_empty;
    generate
        for (i=0; i<`NUM_LSU; i++) begin: gen_lsu_valid
            if (i==0) begin: gen_first
                assign uop_lsu_valid_rvv2lsu[i] = lsu_rs_valid_pre[i];
            end else begin: gen_i
                assign uop_lsu_valid_rvv2lsu[i] = lsu_rs_valid_pre[i] & (uop_lsu_valid_rvv2lsu[i-1] & uop_lsu_ready_lsu2rvv[i-1]);
            end
        end
    endgenerate

    // LSU MAP INFO 与 LSU RS 并行入队，记录访存结果回来时需要写回的 ROB entry 等映射信息。
    // 这样 LSU 返回的数据可以在 lsu_remap 阶段重新对齐到 ROB。
    multi_fifo #(
        .T            (LSU_MAP_INFO_t),
        .M            (`NUM_DP_UOP), 
        .N            (`NUM_LSU),       //2
        .ASYNC_RSTN   (1'b1),
        .DEPTH        (`LSU_RS_DEPTH),  //恒为4
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_map_info (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (mapinfo_valid_dp2lsu),
        .datain       (mapinfo_dp2lsu),
      // read
        .pop          (pop_mapinfo),
        .dataout      (mapinfo),
      // fifo status
        .full         (),
        .almost_full  (mapinfo_almost_full),
        .empty        (mapinfo_empty),
        .almost_empty (mapinfo_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

    assign mapinfo_ready_lsu2dp = ~mapinfo_almost_full;

  // trap handler
    // trap_en 只在 LSU 本拍没有普通返回、LSU_RES_FIFO 还有空间、且当前不在 trapping 时置位。
    // 这样可以确保 trap 之前的 LSU 结果先进入 LSU_RES_FIFO，trap 事件再作为一条特殊 LSU 结果插入。
    // trap_valid_rvs2rvv标量注入
    // uop_lsu_valid_lsu2rvv是lsu结果写回有效使能
    // lsu_res_almost_full是ex级lsu的fifo满信号，trap_en 时 lane0 注入 trap_valid=1 的特殊结果，其余 lane 不产生 trap。
    assign trap_en = trap_valid_rvs2rvv & (uop_lsu_valid_lsu2rvv=='b0) & (!lsu_res_almost_full[0]) & (!is_trapping);

    cdffr
    trap_valid
    (
      .clk            (clk),
      .rst_n          (rst_n),
      .e              (trap_en),             //有效时q=d=1
      .c              (trap_ready_rvv2rvs),  //有效时q=0 ，信号来自rob
      .d              (1'b1),
      .q              (is_trapping)
    );

  // LSU feedback result：普通 LSU 返回结果与 trap 事件共用 UOP_LSU_t FIFO。
  // trap_en 时 lane0 注入 trap_valid=1 的特殊结果，其余 lane 不产生 trap。
    assign uop_lsu_valid = trap_en ? 'b1 : uop_lsu_valid_lsu2rvv;
    
    generate
      assign uop_lsu[0].trap_valid = trap_en;
      assign uop_lsu[0].uop_lsu2rvv = trap_en ? 'b0 : uop_lsu_lsu2rvv[0];
      
      for (i=1;i<`NUM_LSU;i++) begin: get_uop_lsu
        assign uop_lsu[i].trap_valid = 'b0;
        assign uop_lsu[i].uop_lsu2rvv = uop_lsu_lsu2rvv[i];  //lsu返回结果
      end
    endgenerate

    multi_fifo #(  //lsu返回结果的fifo
        .T            (UOP_LSU_t),
        .M            (`NUM_LSU),
        .N            (`NUM_LSU),
        .ASYNC_RSTN   (1'b1),
        .DEPTH        (`NUM_LSU*2),
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_res (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (uop_lsu_valid&uop_lsu_ready_rvv2lsu),
        .datain       (uop_lsu),
      // read
        .pop          (pop_lsu_res),
        .dataout      (lsu_res),
      // fifo status
        .full         (),
        .almost_full  (lsu_res_almost_full),
        .empty        (lsu_res_empty),
        .almost_empty (lsu_res_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );
    // LSU 返回通道 ready；进入 trapping 后停止继续接收普通 LSU 返回。
    assign uop_lsu_ready = ~lsu_res_almost_full;
    assign uop_lsu_ready_rvv2lsu = is_trapping ? 'b0 : uop_lsu_ready;

  // PU, Process Unit：各类执行单元从 RS 取 uop，结果最终写回 ROB。
    // ALU：普通整数/逻辑/比较等向量运算。
    assign uop_valid_rs2alu = ~fifo_almost_empty_rs2alu;
    rvv_backend_alu #(
    ) u_alu (
      // ALU_RS to ALU
        .clk                        (clk),
        .rst_n                      (rst_n),
        .pop                        (pop_alu2rs),
        .uop_valid                  (uop_valid_rs2alu),
        .uop                        (uop_rs2alu),
      // ALU 执行结果写回 ROB。
        .result_valid               (res_valid_alu),
        .result                     (res_alu),
        .result_ready               (res_ready_alu),
      // trap flush 时清空/取消执行单元内部未提交结果。
        .trap_flush_rvv             (trap_flush_rvv)
    );

    // PMTRDT：置换/规约执行单元，额外读取 VRF 中的源向量数据。
    rvv_backend_pmtrdt #(
    ) u_pmtrdt (
        .clk                        (clk),
        .rst_n                      (rst_n),
      // PMTRDT_RS to PMTRDT
        .pop_ex2rs                  (pop_pmtrdt2rs),
        .pmtrdt_uop_rs2ex           (uop_rs2pmtrdt),
        .fifo_almost_empty_rs2ex    (fifo_almost_empty_rs2pmtrdt),
      // PMT to VRF
        .rd_index_pmt2vrf           (rd_index_pmt2vrf),
        .rd_data_vrf2pmt            (rd_data_vrf2pmt),
      // PMTRDT 执行结果写回 ROB。
        .result_valid_ex2rob        (res_valid_pmtrdt),
        .result_ex2rob              (res_pmtrdt),
        .result_ready_rob2ex        (res_ready_pmtrdt),
      // MISC
        .rob_entry_rob2rt           (rob_entry_rob2rt),
      // trap flush 时清空/取消执行单元内部未提交结果。
        .trap_flush_rvv             (trap_flush_rvv)
    );
    
    // MULMAC：乘法和乘加执行单元。
    rvv_backend_mulmac #(
    ) u_mulmac (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .trap_flush_rvv             (trap_flush_rvv),
        .uop_valid_rs2ex            (~fifo_almost_empty_rs2mul),
        .mac_uop_rs2ex              (uop_rs2mul),
        .pop                        (pop_mul2rs),
        .res_valid_ex2rob           (res_valid_mul),
        .res_ex2rob                 (res_mul),
        .res_ready_rob2ex           (res_ready_mul)
    );
    
    // DIV：除法执行单元。
    assign uop_valid_rs2div = ~fifo_almost_empty_rs2div;
    rvv_backend_div u_div
    (  
      .clk                          (clk),
      .rst_n                        (rst_n),
      // DIV_RS to DIV
      .pop                          (pop_div2rs),
      .uop_valid                    (uop_valid_rs2div),
      .uop                          (uop_rs2div),
      // DIV 执行结果写回 ROB。
      .result_valid                 (res_valid_div),
      .result                       (res_div),
      .result_ready                 (res_ready_div),
      // trap flush 时清空/取消执行单元内部未提交结果。
      .trap_flush_rvv               (trap_flush_rvv)
    );

  `ifdef ZVE32F_ON
    // FMA：浮点向量乘加执行单元。
    assign uop_valid_rs2fma = ~fifo_almost_empty_rs2fma;
    rvv_backend_fma u_fma
    (  
      .clk                          (clk),
      .rst_n                        (rst_n),
      // FMA_RS to FMA
      .pop                          (pop_fma2rs),
      .uop_valid                    (uop_valid_rs2fma),
      .uop                          (uop_rs2fma),
      // FMA 执行结果写回 ROB。
      .result_valid                 (res_valid_fma),
      .result                       (res_fma),
      .result_ready                 (res_ready_fma),
      // trap flush 时清空/取消执行单元内部未提交结果。
      .trap_flush_rvv               (trap_flush_rvv)
    );
   `endif

    // LSU remap：把 LSU 返回结果与之前保存的 mapinfo 配对，生成写 ROB 的 PU2ROB_t。
    // 如果 LSU/trap 路径报告异常，则输出 trap_valid_rmp2rob 和对应 ROB entry。
    assign mapinfo_valid = ~mapinfo_almost_empty;
    assign lsu_res_valid = ~lsu_res_almost_empty;
    rvv_backend_lsu_remap
    u_lsu_remap
    (
      .mapinfo_valid                (mapinfo_valid),
      .mapinfo                      (mapinfo),
      .pop_mapinfo                  (pop_mapinfo),
      .lsu_res_valid                (lsu_res_valid),
      .lsu_res                      (lsu_res),
      .pop_lsu_res                  (pop_lsu_res),
      .result_valid                 (res_valid_lsu),
      .result                       (res_lsu),      
      .result_ready                 (res_ready_lsu),
      .trap_valid_rmp2rob           (trap_valid_rmp2rob),
      .trap_rob_entry_rmp2rob       (trap_rob_entry_rmp2rob),
      .trap_ready_rob2rmp           (trap_ready_rob2rmp)  
    );

    assign res_valid_pu2arb = {
                              `ifdef ZVE32F_ON
                               res_valid_fma,
                              `endif
                               res_valid_div,
                               res_valid_pmtrdt,  
                               res_valid_mul,
                               res_valid_alu,
                               res_valid_lsu
                              };
                             
    assign res_pu2arb = {
                        `ifdef ZVE32F_ON
                         res_fma,
                        `endif
                         res_div,
                         res_pmtrdt,
                         res_mul,
                         res_alu,
                         res_lsu
                        };

    assign {
           `ifdef ZVE32F_ON
            res_ready_fma,
           `endif
            res_ready_div,
            res_ready_pmtrdt,
            res_ready_mul,
            res_ready_alu,
            res_ready_lsu 
           } = res_ready_arb2pu;
//ARBITER_ON 的核心作用：把多个执行单元结果源压到固定 4 个 ROB 写端口上，否则 ROB 写端口数会等于所有 PU 数量。NUM_PU = 10
`ifdef ARBITER_ON  
    // 可选结果仲裁：非 LSU 执行单元先进入 1 深度结果 FIFO，再和 LSU 结果一起仲裁写 ROB。
    // 执行单元结果全部压进fifo，lsu未压进去
    generate
      for(i=`NUM_LSU;i<`NUM_PU;i++) begin : gen_res_ff  //lsu未压进去
        multi_fifo #(
            .T            (PU2ROB_t),
            .M            (1),
            .N            (1),
            .ASYNC_RSTN   (1'b1),
            .DEPTH        (2)
        ) u_res_ff (
          // global
            .clk          (clk),
            .rst_n        (rst_n),
          // write
            .push         (res_valid_pu2arb[i] & res_ready_arb2pu[i]),
            .datain       (res_pu2arb[i]),
          // read
            .pop          (grant_arb[i]),
            .dataout      (item_ari[i]),  //未输出lsu
          // fifo status
            .full         (res_ff_full[i]),
            .almost_full  (),
            .empty        (res_ff_empty[i]),
            .almost_empty (),
            .clear        (trap_flush_rvv),
            .fifo_data    (),
            .wptr         (),
            .rptr         (),
            .entry_count  ()
        );

        assign res_ready_arb2pu[i] = !res_ff_full[i]; 
        assign req_ari[i]          = !res_ff_empty[i];
      end
    endgenerate

    assign res_ready_arb2pu[`NUM_LSU-1:0] = ~res_valid_lsu | grant_arb[`NUM_LSU-1:0];

    assign req_arb  = {req_ari,res_valid_lsu};
    assign item_arb = {item_ari, res_lsu};  //ari输出，lsu返回fifo后remap后

    rvv_backend_arb 
    u_arb(
      .clk          (clk),
      .rst_n        (rst_n),
      .req          (req_arb),
      .item         (item_arb),
      .grant        (grant_arb),  //输出pop
      .result_valid (res_valid_arb2rob),
      .result       (res_arb2rob)
    );

`else
    // 未开启仲裁时，各执行单元结果直接并行接入 ROB。
    assign res_valid_arb2rob = res_valid_pu2arb;
    assign res_arb2rob       = res_pu2arb;
    assign res_ready_arb2pu  = '1;
`endif

  // ROB, Re-Order Buffer：按 dispatch 顺序分配 entry，执行单元可乱序写回结果，
  // retire 侧仍按 ROB 顺序读出，从而在正常路径上保持顺序提交。
    rvv_backend_rob #(
    ) u_rob (
      // global signal
        .clk                    (clk),
        .rst_n                  (rst_n),
      // Dispatch to ROB
        .uop_valid_dp2rob       (uop_valid_dp2rob),
        .uop_dp2rob             (uop_dp2rob),
        .uop_ready_rob2dp       (uop_ready_rob2dp),
        .rob_empty              (rob_empty),
        .rob_entry_rob2dp       (rob_entry_rob2dp),
      // PU to ROB
        .wr_valid_pu2rob        (res_valid_arb2rob),
        .wr_pu2rob              (res_arb2rob),
      // ROB to RT
        .rd_valid_rob2rt        (rd_valid_rob2rt),
        .rd_rob2rt              (rd_rob2rt),
        .rd_ready_rt2rob        (rd_ready_rt2rob),
        .rob_entry_rob2rt       (rob_entry_rob2rt),
      // ROB to DP
        .uop_rob2dp             (uop_rob2dp),
      //不是完全只来自 LSU，但进入 RVV backend ROB 并触发 trap_flush_rvv 的主路径基本只有 LSU/remap 这一路。
      //另外还有一个“外部/标量注入 trap”入口，但当前 RvvCore.sv 里被 tie-off 了
      // Trap：只由LSU remap/外部 trap 确认后，由 ROB 产生 trap_flush_rvv 刷新后端流水线。
        .trap_valid_rmp2rob     (trap_valid_rmp2rob),
        .trap_rob_entry_rmp2rob (trap_rob_entry_rmp2rob),  
        .trap_ready_rob2rmp     (trap_ready_rob2rmp),
        .trap_ready_rvv2rvs     (trap_ready_rvv2rvs),
        .trap_flush_rvv         (trap_flush_rvv)
    );

  // RT, Retire：消费 ROB 顺序输出，分发到 VRF/XRF/FRF/VCSR/FCSR 等写回端口。
    rvv_backend_retire #(
    ) u_retire (
      // ROB to RT
        .rob2rt_write_valid     (rd_valid_rob2rt),
        .rob2rt_write_data      (rd_rob2rt),
        .rt2rob_write_ready     (rd_ready_rt2rob),
      // RT to RVS.XRF/FRF
        .rt2xrf_write_valid     (rt_xrf_valid_rvv2rvs),
        .rt2rvs_write_data      (rt_rvs_rvv2rvs),
        .rvs2rt_write_ready     (rt_rvs_ready_rvs2rvv),
      `ifdef ZVE32F_ON
        .rt2frf_write_valid     (async_frd_valid),
        .frf2rt_write_ready     (async_frd_ready),
      `endif
      // RT to VRF
        .rt2vrf_write_valid     (wr_valid_rt2vrf),
        .rt2vrf_write_data      (wr_data_rt2vrf),
      // 更新 vxsat。
        .rt2vxsat_write_valid   (wr_vxsat_valid),
        .rt2vxsat_write_data    (wr_vxsat),
        .vxsat2rt_write_ready   (wr_vxsat_ready),
      `ifdef ZVE32F_ON
      // 更新 FCSR。
        .rt2fcsr_write_valid    (rt2fcsr_write_valid),
        .rt2fcsr_write_data     (rt2fcsr_write_data),
        .fcsr2rt_write_ready    (fcsr2rt_write_ready),
      `endif
      // 写回最新 vector CSR。
        .rt2vcsr_write_valid    (vcsr_valid),
        .rt2vcsr_write_data     (vector_csr),
        .vcsr2rt_write_ready    (vcsr_ready)
    );
    
  `ifdef ZVE32F_ON
    // 写回 FRF 的地址和数据复用 retire 给 RVS 的标量写回 bundle。
    generate
      for(i=0; i<`NUM_RT_UOP; i++) begin: gen_rt_frf
        assign async_frd_addr[i] = rt_rvs_rvv2rvs[i].rt_index;
        assign async_frd_data[i] = rt_rvs_rvv2rvs[i].rt_data;
      end
    endgenerate
  `endif

  // VRF, Vector Register File：dispatch/PMTRDT 读，retire 写。
    rvv_backend_vrf #(
    ) u_vrf (
      // global signal
        .clk             (clk),
        .rst_n           (rst_n),
      // DP to VRF
        .dp2vrf_rd_index (rd_index_dp2vrf),
      // VRF to DP
        .vrf2dp_rd_data  (rd_data_vrf2dp),
        .vrf2dp_v0_data  (v0_mask_vrf2dp),
      // PMT to VRF
        .pmt2vrf_rd_index (rd_index_pmt2vrf),
      // VRF to PMT
        .vrf2pmt_rd_data  (rd_data_vrf2pmt),
      // RT to VRF
        .rt2vrf_wr_valid (wr_valid_rt2vrf),
        .rt2vrf_wr_data  (wr_data_rt2vrf)
    );
  
  // 对外导出实际完成握手的 retire 信息。
  assign rd_valid_rob2rt_o = rd_valid_rob2rt & rd_ready_rt2rob;
  assign rd_rob2rt_o       = rd_rob2rt;

  // 后端空闲条件：CQ/LCQ/UQ/ROB 为空。RS/执行单元内部活动通过 ROB/队列间接约束。
  assign rvv_idle = fifo_empty_cq2de&fifo_empty_lcq2de&uq_empty&rob_empty;

endmodule
