// 功能说明：
// 1. Dispatch 单元从 Uop Queue 接收已经由 DE2 展开的 uop。
// 2. Dispatch 检查结构冒险、uop 间 RAW、uop 与 ROB 间 RAW，并决定本拍哪些 uop 可以发往各执行单元 RS。
// 3. 若源操作数仍在 ROB 中未退休，则通过 ROB bypass 取得数据；否则从 VRF 读口取得向量数据。
// 4. Dispatch 同时为 ROB 分配 entry，并把目的寄存器、byte mask、vector CSR 等信息写入 ROB。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch` -> RVV 后端 DP 阶段。
// - 接口与数据流：
//   * 输入：UQ 中的 uop、ROB 状态、VRF 读数据和各 RS ready。
//   * 处理：结构冒险与 RAW 相关性检查，生成 VRF 读地址、ROB/VRF bypass 选择、RS 操作数和 ROB 分配信息。
//   * 输出：各执行单元 RS valid/data、LSU mapinfo、ROB allocate/write 信息。
// - 调用关系：上层 rvv_backend；下层 rvv_backend_dispatch_bypass(u_bypass), rvv_backend_dispatch_ctrl(u_ctrl), rvv_backend_dispatch_operand(u_operand), rvv_backend_dispatch_opr_byte_type(u_opr_byte_type), rvv_backend_dispatch_raw_uop_rob(u_raw_uop_rob), rvv_backend_dispatch_raw_uop_uop(u_raw_uop_uop), rvv_backend_dispatch_structure_hazard(u_structure_hazard)
// - 端口摘要：输入 clk, rst_n, uop_valid_uop2dp, uop_uop2dp, rs_ready_alu2dp, rs_ready_pmtrdt2dp, rs_ready_mul2dp, rs_ready_div2dp, rs_ready_fma2dp, rs_ready_lsu2dp, mapinfo_ready_lsu2dp, uop_ready_rob2dp；输出 uop_ready_dp2uop, rs_valid_dp2alu, rs_dp2alu, rs_valid_dp2pmtrdt, rs_dp2pmtrdt, rs_valid_dp2mul, rs_dp2mul, rs_valid_dp2div, rs_dp2div, rs_valid_dp2fma, rs_dp2fma, rs_valid_dp2lsu。
// - define/参数阅读重点：
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `NUM_DP_UOP`：3；当前 DISPATCH3 下 Dispatch 每拍最多发射 uop 数，DISPATCH2 时为 2。
//   * `NUM_DP_VRF`：6；当前 DISPATCH3 下 Dispatch 侧 VRF 读口数，DISPATCH2 时为 4。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `ROB_DEPTH`：8；ROB entry 数。
//   * `ROB_DEPTH_WIDTH`：$clog2(`ROB_DEPTH)=3。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VLENW`：`VLEN/32；依赖 VLEN。
//   * `VL_WIDTH`：$clog2(`VLEN)+1；依赖 VLEN。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - Dispatch 主要步骤：
//   * 构造 RAW 检查输入：把当前 uop 的源寄存器与 ROB 中未完成写回、以及同拍更老 uop 的目的寄存器比较。
//   * 结构冒险检查：统计本拍 uop 需要的 VRF 读口和执行单元端口，产生 VRF read index 与 arch_hazard。
//   * 操作数读取/旁路：先从 VRF 取数，再按 raw_uop_rob 从 ROB 中选择更新的数据覆盖 VRF 数据。
//   * 握手控制：dispatch_ctrl 综合 RAW/结构冒险、RS ready、ROB ready、LSU mapinfo ready，产生 ready/valid。
//   * 输出组包：把操作数、byte type、ROB entry、CSR 和 uop 字段分别打包给 ALU/PMT/RDT/MUL/DIV/FMA/LSU/ROB。
// - 阅读建议：按 “RAW 检查 -> 结构冒险/VRF 读口 -> operand+bypass -> dispatch_ctrl -> RS/ROB 输出” 阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch
(
    clk,
    rst_n,
    uop_valid_uop2dp,
    uop_uop2dp,
    uop_ready_dp2uop,
    rs_valid_dp2alu,
    rs_dp2alu,
    rs_ready_alu2dp,
    rs_valid_dp2pmtrdt,
    rs_dp2pmtrdt,
    rs_ready_pmtrdt2dp,
    rs_valid_dp2mul,
    rs_dp2mul,
    rs_ready_mul2dp,
    rs_valid_dp2div,
    rs_dp2div,
    rs_ready_div2dp,
`ifdef ZVE32F_ON
    rs_valid_dp2fma,
    rs_dp2fma,
    rs_ready_fma2dp,
`endif
    rs_valid_dp2lsu,
    rs_dp2lsu,
    rs_ready_lsu2dp,
    mapinfo_valid_dp2lsu,
    mapinfo_dp2lsu,
    mapinfo_ready_lsu2dp,
    uop_valid_dp2rob,
    uop_dp2rob,
    uop_ready_rob2dp,
    rob_entry_rob2dp,
    rd_index_dp2vrf,        
    rd_data_vrf2dp,
    v0_mask_vrf2dp,
    rob_entry
);  
// ---端口定义-------------------------------------------------
// 全局时钟和低有效复位。
    input  logic           clk;
    input  logic           rst_n;

// Uop Queue -> Dispatch。
// valid/data 是候选 uop；ready 回传给 Uop Queue，表示该 uop 本拍被 DP 接收/发射。
    input  logic        [`NUM_DP_UOP-1:0]         uop_valid_uop2dp;
    input  UOP_QUEUE_t  [`NUM_DP_UOP-1:0]         uop_uop2dp;
    output logic        [`NUM_DP_UOP-1:0]         uop_ready_dp2uop;  //接收后拉高

// Dispatch -> ALU/CMP reservation station。
// rs_* 表示 reservation station；valid 由 dispatch_ctrl 产生，payload 在本模块末尾组包。
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2alu;
    output ALU_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2alu;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_alu2dp;

// Dispatch -> PMT/RDT reservation station，覆盖 permutation、reduction 等单元。
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2pmtrdt;
    output PMT_RDT_RS_t   [`NUM_DP_UOP-1:0]       rs_dp2pmtrdt;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_pmtrdt2dp;

// Dispatch -> MUL/MAC reservation station。
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2mul;
    output MUL_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2mul;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_mul2dp;

// Dispatch -> DIV/FDIV reservation station。
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2div;
    output DIV_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2div;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_div2dp;

`ifdef ZVE32F_ON
// Dispatch -> FMA/Floating-point reservation station。
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2fma;
    output FMA_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2fma;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_fma2dp;
`endif

// Dispatch -> LSU。
    // 访存 uop 的数据通路发往 LSU RS。
    // 它携带 index vector、store data、v0 mask/strobe 等
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2lsu;
    output UOP_RVV2LSU_t  [`NUM_DP_UOP-1:0]       rs_dp2lsu;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_lsu2dp;
    // LSU mapinfo 提供 ROB entry、load/store 类型和写回寄存器映射。
    output logic          [`NUM_DP_UOP-1:0]       mapinfo_valid_dp2lsu;
    output LSU_MAP_INFO_t [`NUM_DP_UOP-1:0]       mapinfo_dp2lsu;
    input  logic          [`NUM_DP_UOP-1:0]       mapinfo_ready_lsu2dp;

// Dispatch -> ROB。
// Dispatch 会为需要进入 ROB 的 uop 分配 entry。
// pshrob_valid 的 uop 会分配 ROB entry；ROB 返回当前可分配起始 entry。
    output logic          [`NUM_DP_UOP-1:0]       uop_valid_dp2rob;  //当前 uop 是否要分配 ROB entry
    output DP2ROB_t       [`NUM_DP_UOP-1:0]       uop_dp2rob;        //携带写回目的寄存器、byte type、CSR、last uop 等信息。
    input  logic          [`NUM_DP_UOP-1:0]       uop_ready_rob2dp;  //ROB 对第 i 个可入 ROB 的 uop 是否有空间
    input  logic          [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2dp;  //ROB 返回的当前可分配起始 entry。后续多个 uop 的 ROB 地址在 Dispatch 内部递增生成。

// Dispatch -> VRF。
// structure_hazard 子模块根据本拍 uop 的源寄存器需求生成读地址；VRF 同周期返回读数据。
    output logic [`NUM_DP_VRF-1:0][`REGFILE_INDEX_WIDTH-1:0] rd_index_dp2vrf;  //Dispatch 生成的 VRF 读地址
    input  logic [`NUM_DP_VRF-1:0][`VLEN-1:0]                rd_data_vrf2dp;   //VRF 返回的读数据
    input  logic [`VLEN-1:0]                                 v0_mask_vrf2dp;   //v0 mask 数据，单独从 VRF 或 mask 读路径返回

// ROB -> Dispatch。
// Dispatch 查看所有 ROB entry，用于判断源操作数是否需要从未退休的 ROB 结果旁路。
// 1. RAW 检查：当前 uop 源寄存器是否命中 ROB 中未退休的目的寄存器
// 2. ROB bypass：如果命中且数据已产生，可以从 ROB 旁路取得最新值
    input  ROB2DP_t     [`ROB_DEPTH-1:0]          rob_entry;

// ---内部信号定义--------------------------------------
    // 当前待发 uop 的源寄存器摘要，用于 RAW 检查。
    SUC_UOP_RAW_t       [`NUM_DP_UOP-1:0]   suc_uop;
    // ROB 中所有未完成写回的目的寄存器摘要。
    PRE_UOP_RAW_t       [`ROB_DEPTH-1:0]    pre_uop_rob;
    // 同拍更老 uop 的目的寄存器摘要，用于 uop 间 RAW 检查。
    PRE_UOP_RAW_t       [`NUM_DP_UOP-2:0]   pre_uop_uop;
    // 当前 uop 与 ROB 的 RAW/旁路匹配结果。
    RAW_UOP_ROB_t       [`NUM_DP_UOP-1:0]   raw_uop_rob; 
    // uop0 是本拍最老 uop，不需要与同拍更老 uop 做 RAW 检查。
    RAW_UOP_UOP_t       [`NUM_DP_UOP-1:1]   raw_uop_uop; 

    // 结构冒险检查输入与结果，主要描述 VRF 读口/执行资源冲突。
    STRCT_UOP_t         [`NUM_DP_UOP-1:0]   strct_uop;
    ARCH_HAZARD_t                           arch_hazard;

    // uop_operand 是最终送 RS 的操作数；vrf_byp 是 VRF 原始读数；rob_byp 是 ROB 可旁路数据。
    UOP_OPN_t           [`NUM_DP_UOP-1:0]   uop_operand;
    UOP_OPN_t           [`NUM_DP_UOP-1:0]   vrf_byp;
    ROB_BYP_t           [`ROB_DEPTH-1:0]    rob_byp;

    // 控制子模块只需要执行单元和是否入 ROB/LSU 的摘要。
    UOP_CTRL_t          [`NUM_DP_UOP-1:0]   uop_ctrl;

    // byte_type 描述向量每个 byte 是否 active/tail/inactive，用于写回 mask、tail policy 和 ROB byte merge。
    UOP_INFO_t          [`NUM_DP_UOP-1:0]   uop_info;
    UOP_OPN_BYTE_TYPE_t [`NUM_DP_UOP-1:0]   uop_operand_byte_type;

    // vlmax 主要供 PMT/RDT 等需要知道当前 LMUL/SEW 最大元素数的单元使用。
    logic [`NUM_DP_UOP-1:0][`VL_WIDTH-1:0]          vlmax;
    logic [`NUM_DP_UOP-1:0][$clog2(`VL_WIDTH)-1:0]  vlmax_shift;

    // 每个本拍可入 ROB 的 uop 对应的 ROB entry 地址。
    logic [`NUM_DP_UOP-1:0][`ROB_DEPTH_WIDTH-1:0]   rob_address;

// ---代码开始------------------------------------------------------
    genvar i;

    // vlmax = LMUL * VLEN / SEW。
    // 这里通过 shift 计算，兼容 fractional LMUL 的编码形式。
    // VLmax​=2^(log2​(VLENB)+log2​(LMUL)−log2​(SEW))
    generate
      for (i=0; i<`NUM_DP_UOP; i++) begin : gen_vlmax
        assign vlmax_shift[i] = ($clog2(`VL_WIDTH))'(uop_uop2dp[i].vector_csr.lmul[1:0]) 
                                + $clog2(`VLENB) 
                                - ($clog2(`VL_WIDTH))'(uop_uop2dp[i].vector_csr.sew) 
                                - {{($clog2(`VL_WIDTH)-3){1'b0}},uop_uop2dp[i].vector_csr.lmul[2],2'b0};  // 这里的 lmul[2] 是 fractional LMUL 的标志位，表示 LMUL=1/8 或 1/4。进行修正
        assign vlmax[i] = (`VL_WIDTH)'(1) << vlmax_shift[i];
      end
    endgenerate

    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_suc_uop
            //suc_uop 是当前待发 uop 的源操作数摘要，主要供 RAW 检查使用。
            // suc_uop 只保留 RAW 检查需要的源寄存器字段。
            // 注意 vd_index 在这里表示可能作为 vs3 读取的寄存器，也可能是目的寄存器字段。
            assign suc_uop[i].vs1_index = uop_uop2dp[i].vs1;
            assign suc_uop[i].vs1_valid = uop_uop2dp[i].vs1_valid;
            assign suc_uop[i].vs2_index = uop_uop2dp[i].vs2_index;
            assign suc_uop[i].vs2_valid = uop_uop2dp[i].vs2_valid;
            assign suc_uop[i].vd_index  = uop_uop2dp[i].dst_index;
            assign suc_uop[i].vs3_valid = uop_uop2dp[i].vs3_valid;
            assign suc_uop[i].vm        = uop_uop2dp[i].vm;
        end
    endgenerate

// 当前 uop 与 ROB 中未退休写回之间的 RAW 检查。
// 如果源寄存器命中某个 ROB entry 的目的寄存器，后续 bypass 会优先取 ROB 数据。
    generate
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_pre_uop_rob
            assign pre_uop_rob[i].w_index = rob_entry[i].w_index;
            assign pre_uop_rob[i].w_type  = rob_entry[i].w_type;
            assign pre_uop_rob[i].w_valid = rob_entry[i].w_valid;
            assign pre_uop_rob[i].valid   = rob_entry[i].valid;
        end
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_raw_uop_rob  //每个uop都需要和rob的ROB_DEPTH歌数据进行对比
            rvv_backend_dispatch_raw_uop_rob #(  //对本拍每个 uop，都检查它的源寄存器是否命中 ROB 中某个未退休目的寄存器。
                                                 //如果命中，则后续 bypass 可能从 ROB 取数据，而不是用 VRF 旧值。
            ) u_raw_uop_rob (
                .raw_uop_rob  (raw_uop_rob[i]),  //输出hit、wait hit 向量给 bypass 单元选 ROB 数据；wait 单 bit 给 dispatch_ctrl 决定是否 stall。
                .suc_uop      (suc_uop[i]),
                .pre_uop      (pre_uop_rob)      //输入，ROB 中所有未完成写回的目的寄存器摘要
            );
        end
    endgenerate

// 同拍 uop 之间的 RAW 检查。
// 只有后面的 uop 需要检查前面更老 uop；uop0 没有同拍更老 uop，因此没有 raw_uop_uop[0]。
    generate
        for (i=0; i<`NUM_DP_UOP-1; i++) begin : gen_pre_uop_uop
            // 这里只记录更老 uop 的目的寄存器；当前实现只把写 VRF 的 uop 纳入同拍 RAW 检查。
            // 这段把同拍更老 uop 的写回摘要取出来。
            // 例如 NUM_DP_UOP=3：
            // uop0 是最老
            // uop1 需要检查是否依赖 uop0
            // uop2 需要检查是否依赖 uop0/uop1
            assign pre_uop_uop[i].w_index = uop_uop2dp[i].dst_index;
            assign pre_uop_uop[i].w_valid = 1'b0;
            assign pre_uop_uop[i].w_type  = uop_uop2dp[i].vd_valid ? VRF : XRF;
            assign pre_uop_uop[i].valid   = uop_uop2dp[i].vd_valid & uop_valid_uop2dp[i];
        end
        for (i=1; i<`NUM_DP_UOP; i++) begin : gen_raw_uop_uop  //i=0时不存在
            rvv_backend_dispatch_raw_uop_uop #(  //进行raw检查
                .PREUOP_NUM (i)
            ) u_raw_uop_uop (
                .raw_uop_uop  (raw_uop_uop[i]),     //输出wait
                .suc_uop      (suc_uop[i]),         //读取当前 uop 的源寄存器
                .pre_uop      (pre_uop_uop[i-1:0])  //同拍更老 uop 的目的寄存器，最后一个不需要
            );
        end
    endgenerate

// 结构冒险检查并生成 VRF 读地址。
// structure_hazard 会根据每个 uop 的 uop_class/vs valid/exe unit 判断本拍 VRF 读口是否够用，
// 同时填出 rd_index_dp2vrf，供 VRF 在当前周期返回 rd_data_vrf2dp。
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_strct_uop
            assign strct_uop[i].vs1_index = uop_uop2dp[i].vs1;
            assign strct_uop[i].vs1_valid = uop_uop2dp[i].vs1_valid;
            assign strct_uop[i].vs2_index = uop_uop2dp[i].vs2_index;
            assign strct_uop[i].vs2_valid = uop_uop2dp[i].vs2_valid;
            assign strct_uop[i].vd_index  = uop_uop2dp[i].dst_index;
            assign strct_uop[i].vs3_valid = uop_uop2dp[i].vs3_valid;
            assign strct_uop[i].uop_exe_unit = uop_uop2dp[i].uop_exe_unit;
            assign strct_uop[i].uop_class = uop_uop2dp[i].uop_class;
        end
    endgenerate
    // DISPATCH3：
    //   3 条 uop，6 个 VRF 读口。
    //   默认给 uop0/uop1 各预留 3 个读口。
    //   再根据 uop0/uop1 的 uop_class，把 uop2 的 0/1/2/3 个源塞进空闲读口。
    //   塞不下则 arch_hazard.vr_limit=1。
    // DISPATCH2：
    //   2 条 uop，4 个 VRF 读口。
    //   用固定规则分配 rd0~rd3。
    //   若两条 uop 的组合需要 5 或 6 个读口，则 arch_hazard.vr_limit=1。
    rvv_backend_dispatch_structure_hazard #(  //1. 判断 VRF 读口是否够用，生成 arch_hazard
                                              //2. 生成 VRF 读地址 rd_index_dp2vrf
    ) u_structure_hazard (   
        .rd_index     (rd_index_dp2vrf), //输出 vrf寄存器编号到外部vreg
        .arch_hazard  (arch_hazard),     //输出 结构冒险结果；当前结构体只有 vr_limit
        .strct_uop    (strct_uop)        //根据每个 uop 的 uop_class/vs valid/exe unit 判断本拍 VRF 读口是否够用，同时给出 rd_index_dp2vrf，供 VRF 在当前周期返回 rd_data_vrf2dp
    );

// 为 uop 源操作数准备 VRF/ROB bypass 数据。
    generate
      for (i=0; i<`ROB_DEPTH; i++) begin : gen_rob_byp
        // ROB entry 中保存的是还未退休、但可能已经完成的写回数据。
        // AGNOSTIC_ONE 打开时，tail/inactive byte 可直接用 1 填充，配合 byte_type 使用。
        assign rob_byp[i].w_data    = rob_entry[i].w_data;     //ROB 中保存的写回数据
        assign rob_byp[i].byte_type = rob_entry[i].byte_type;  //每个 byte 的 active/tail/inactive 信息

        `ifdef AGNOSTIC_ONE
          assign rob_byp[i].tail_one  = rob_entry[i].vector_csr.vtype.vta;
          assign rob_byp[i].inactive_one = rob_entry[i].vector_csr.vtype.vma;
        `else
          assign rob_byp[i].tail_one  = 1'b0;
          assign rob_byp[i].inactive_one = 1'b0;
        `endif
      end
      
      //基于rvv_backend_dispatch_structure_hazard产生rd_index_dp2vrf策略进行重组
      rvv_backend_dispatch_operand  
      u_operand
      (
        // 先把 VRF 返回数据整理为 v0/vs1/vs2/vd 四类操作数。
        .vrf_byp        (vrf_byp       ),  //输出
        .uop_uop2dp     (uop_uop2dp    ),  //输入，当前待发 uop
        .rd_data_vrf2dp (rd_data_vrf2dp),  //输入，VRF 返回的读数据
        .v0_mask_vrf2dp (v0_mask_vrf2dp)   //输入，v0 mask 数据，单独从 VRF 或 mask 读路径返回
      );

      for (i=0;i<`NUM_DP_UOP;i++) begin: gen_bypass_data
        rvv_backend_dispatch_bypass 
        #(
        ) 
        u_bypass (
          // 再根据 raw_uop_rob 从 ROB 中选择最新数据覆盖 VRF 读数。
          .uop_operand  (uop_operand[i]),  //最终操作数
          .rob_byp      (rob_byp),         //输入，所有 ROB entry 的可旁路数据
          .vrf_byp      (vrf_byp[i]),      //输入，VRF 读出的原始操作数
          .raw_uop_rob  (raw_uop_rob[i])   //输入，当前 uop 哪些源命中了 ROB
        );
      end
    endgenerate

// Uop Queue <-> Dispatch、Dispatch <-> RS/ROB/LSU 的握手机制。
// dispatch_ctrl 会综合 RAW hazard、结构冒险、各 RS ready、ROB ready 和 LSU mapinfo ready，
// 只有所有必要资源都可用时，才允许对应 uop 从 Uop Queue 出队并发往目标单元。
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_uop_ctrl
            assign uop_ctrl[i].uop_exe_unit = uop_uop2dp[i].uop_exe_unit;  
            assign uop_ctrl[i].pshrob_valid = uop_uop2dp[i].pshrob_valid;  //
            assign uop_ctrl[i].pshlsu_valid = uop_uop2dp[i].pshlsu_valid;
        end
    endgenerate

    // 只有当所有相关资源都可用时，
    // Dispatch 才会让 Uop Queue 出队，
    // 同时向目标 RS / ROB / LSU mapinfo 发 valid。
    rvv_backend_dispatch_ctrl #(
    ) u_ctrl (
      // 控制输入：RAW/结构冒险和 uop 目标单元摘要。
        .raw_uop_rob            (raw_uop_rob),  //当前 uop 与 ROB 未退休写回之间的 RAW 等待/命中信息。
        .raw_uop_uop            (raw_uop_uop),  //当前 uop 与同拍更老 uop 之间的 RAW 等待信息；uop0 没有该项。
        .arch_hazard            (arch_hazard),  //结构冒险结果，目前主要包含 VRF 读口限制。
        .uop_ctrl               (uop_ctrl),     //每个 uop 的目标执行单元，以及是否需要入 ROB/LSU。
      // 握手输出/输入：对 Uop Queue、各 RS、LSU mapinfo、ROB 分别产生 valid/ready。
        .uop_valid_uop2dp       (uop_valid_uop2dp),  //上级fifo有效
        .uop_ready_dp2uop       (uop_ready_dp2uop),  //消耗上级fifo
        .rs_valid_dp2alu        (rs_valid_dp2alu),  //可以发给下级alu
        .rs_ready_alu2dp        (rs_ready_alu2dp),  //alu已经准备好
        .rs_valid_dp2pmtrdt     (rs_valid_dp2pmtrdt),
        .rs_ready_pmtrdt2dp     (rs_ready_pmtrdt2dp),
        .rs_valid_dp2mul        (rs_valid_dp2mul),
        .rs_ready_mul2dp        (rs_ready_mul2dp),
        .rs_valid_dp2div        (rs_valid_dp2div),
        .rs_ready_div2dp        (rs_ready_div2dp),
      `ifdef ZVE32F_ON
        .rs_valid_dp2fma        (rs_valid_dp2fma),
        .rs_ready_fma2dp        (rs_ready_fma2dp),
      `endif
        .rs_valid_dp2lsu        (rs_valid_dp2lsu),
        .rs_ready_lsu2dp        (rs_ready_lsu2dp),
        .mapinfo_valid_dp2lsu   (mapinfo_valid_dp2lsu),
        .mapinfo_ready_lsu2dp   (mapinfo_ready_lsu2dp),
        // Dispatch -> ROB 的 valid/ready。pshrob_valid=0 的 uop 不需要真正写 ROB。
        .uop_valid_dp2rob       (uop_valid_dp2rob),
        .uop_ready_rob2dp       (uop_ready_rob2dp)
    );

// 计算每个 uop 各向量操作数的 byte 类型。
// byte_type 会标出 active/tail/inactive 区域，供执行单元和 ROB 写回按 mask/tail policy 处理。
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_opr_bype_type
            // segment LSU 使用 seg_field_index 计算当前 field 的 byte 类型，其余指令使用普通 uop_index。
            assign uop_info[i].uop_index  = (uop_uop2dp[i].uop_exe_unit==LSU)&(uop_uop2dp[i].uop_funct6.lsu_funct6.lsu_is_seg==IS_SEGMENT)? 
                                            uop_uop2dp[i].seg_field_index : uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];
            assign uop_info[i].uop_exe_unit = uop_uop2dp[i].uop_exe_unit;
            assign uop_info[i].vd_eew     = uop_uop2dp[i].vd_eew;
            assign uop_info[i].vs1_eew    = uop_uop2dp[i].vs1_eew;
            assign uop_info[i].vs2_eew    = uop_uop2dp[i].vs2_eew;
            assign uop_info[i].vstart     = uop_uop2dp[i].vector_csr.vstart;
            assign uop_info[i].vl         = uop_uop2dp[i].vs_evl;
            assign uop_info[i].vm         = uop_uop2dp[i].vm;
            assign uop_info[i].ignore_vma = uop_uop2dp[i].ignore_vma;
            assign uop_info[i].ignore_vta = uop_uop2dp[i].ignore_vta;

            //不标注 vs1 不是“被写的对象”
            // 它会标注：
            //vd：writeback target → 必须精确 byte control
            //vs2：可能参与 narrowing/widening → 需要 split
            //v0：mask control → 必须展开
            //           ┌──────────────┐
            // vs1  ───► │ scalar/vector │ ──► register read only
            //           └──────────────┘
            //           ┌──────────────┐
            // vs2  ───► │ vector source │ ──► sliced (tile + mask + vstart + vl)
            //           └──────────────┘
            //           ┌──────────────┐
            // vd   ───► │ vector dest   │ ──► writeback semantic target
            //           └──────────────┘
            //           ┌──────────────┐
            // v0   ───► │ mask/control  │ ──► execution gating (per element/byte)
            //           └──────────────┘
            // - 特殊规则：
            //   * vs2 主要描述源操作数是否可用；vd 描述目的/写回 byte 的类型。
            //   * RDT/FRDT 规约写回只使用低元素，其余 byte 标为 tail。
            //   * narrowing/widening 与 indexed LSU 会让 vs2/vd 的 EEW 不同，因此需要分别计算元素起点和 v0 对齐范围。
            //   * `ignore_vma/ignore_vta` 同时为 1 时，本模块把相关 byte 直接视为 BODY_ACTIVE。
            rvv_backend_dispatch_opr_byte_type #(
            ) u_opr_byte_type (
                .operand_byte_type (uop_operand_byte_type[i]),  //后续执行单元和 ROB 会使用这些 byte mask 来做部分写回、tail/inactive merge。
                .uop_info          (uop_info[i]),
                .v0_data           (uop_operand[i].v0)
            );
        end
    endgenerate

// 组装发往各 RS、LSU mapinfo 和 ROB 的输出 payload。
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_output_sig
          // ROB entry 地址：本拍第 0 个可入 ROB 的 uop 使用 rob_entry_rob2dp，
          // 后续 uop 按前一个 uop 是否 pshrob_valid 累加。
          // 第 0 个 uop 的 ROB entry = ROB 返回的起始 entry
          // 后续 uop 的 ROB entry = 前一个地址 + 前一个 uop 是否需要入 ROB
          // | uop  | `pshrob_valid` | `rob_address` |
          // | ---- | -------------: | ------------: |
          // | uop0 |              1 |          base |
          // | uop1 |              0 |        base+1 |
          // | uop2 |              1 |        base+1 |
          // 如果 uop1 不入 ROB，则 uop2 仍然使用 base+1
            if (i==0) begin : gen_rob_address_0
              assign rob_address[0] = rob_entry_rob2dp;
            end else begin : gen_rob_address_i
              assign rob_address[i] = rob_address[i-1] + (`ROB_DEPTH_WIDTH)'(uop_uop2dp[i-1].pshrob_valid);
            end

          // ALU/CMP RS payload。
          `ifdef TB_SUPPORT
            assign rs_dp2alu[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2alu[i].rob_entry       = rob_address[i];  //流水传到rob
            assign rs_dp2alu[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2alu[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2alu[i].is_cmp          = uop_uop2dp[i].uop_exe_unit==CMP;  //比较类，否则普通ALU类
            assign rs_dp2alu[i].vstart          = uop_uop2dp[i].vector_csr.vstart;
            assign rs_dp2alu[i].vl              = uop_uop2dp[i].vs_evl;
            assign rs_dp2alu[i].vm              = uop_uop2dp[i].vm;
            assign rs_dp2alu[i].vxrm            = uop_uop2dp[i].vector_csr.xrm;
            assign rs_dp2alu[i].v0_data         = uop_operand[i].v0;
            assign rs_dp2alu[i].v0_data_valid   = uop_uop2dp[i].v0_valid;
            assign rs_dp2alu[i].vd_data         = uop_operand[i].vd;
            assign rs_dp2alu[i].vd_data_valid   = uop_uop2dp[i].vs3_valid;
            assign rs_dp2alu[i].vd_eew          = uop_uop2dp[i].vd_eew;
            assign rs_dp2alu[i].vs1             = uop_uop2dp[i].vs1;
            // 如果是 vector-vector，vs1_data 来自 VRF/bypass 的 vs1
            // 如果是 vector-scalar 或 immediate，vs1_data 用 rs1_data 扩展成 VLEN 位
            assign rs_dp2alu[i].vs1_data        = uop_uop2dp[i].vs1_valid ? uop_operand[i].vs1 : (`VLEN)'(uop_uop2dp[i].rs1_data);
            assign rs_dp2alu[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2alu[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2alu[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2alu[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
            assign rs_dp2alu[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2alu[i].first_uop_valid = uop_uop2dp[i].first_uop_valid;
            assign rs_dp2alu[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2alu[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];

          // PMT/RDT RS payload。
          `ifdef TB_SUPPORT
            assign rs_dp2pmtrdt[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2pmtrdt[i].rob_entry       = rob_address[i]; 
            assign rs_dp2pmtrdt[i].uop_exe_unit    = uop_uop2dp[i].uop_exe_unit;  //需要 uop_exe_unit 进一步区分当前是 PMT 还是 RDT
            assign rs_dp2pmtrdt[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2pmtrdt[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2pmtrdt[i].vl              = uop_uop2dp[i].vs_evl;
            assign rs_dp2pmtrdt[i].vm              = uop_uop2dp[i].vm;
            assign rs_dp2pmtrdt[i].vlmax           = vlmax[i];  //PMT/RDT 需要知道最大元素数，尤其是 slide/gather/reduction 这类跨元素操作。
            assign rs_dp2pmtrdt[i].v0_data         = uop_operand[i].v0;
            assign rs_dp2pmtrdt[i].vs1_data        = uop_operand[i].vs1;
            assign rs_dp2pmtrdt[i].vs1_eew         = uop_uop2dp[i].vs1_eew;
            assign rs_dp2pmtrdt[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2pmtrdt[i].vs2_index       = uop_uop2dp[i].vs2_index;
            assign rs_dp2pmtrdt[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2pmtrdt[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2pmtrdt[i].vs2_type        = uop_operand_byte_type[i].vs2;  //用于告诉 PMT/RDT：
                                                                                    //哪些 byte 是 active
                                                                                    //哪些是 mask inactive
                                                                                    //哪些是 tail
                                                                                    //哪些需要保持不变
            assign rs_dp2pmtrdt[i].vd_eew          = uop_uop2dp[i].vd_eew;
            assign rs_dp2pmtrdt[i].dst_index       = uop_uop2dp[i].dst_index;  //给 PMT/RDT 知道最终目标寄存器编号。
            assign rs_dp2pmtrdt[i].rs1_data        = uop_uop2dp[i].rs1_data;
            assign rs_dp2pmtrdt[i].first_uop_valid = uop_uop2dp[i].first_uop_valid;
            assign rs_dp2pmtrdt[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2pmtrdt[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];
          `ifdef ZVE32F_ON
            assign rs_dp2pmtrdt[i].frm             = uop_uop2dp[i].vector_csr.frm;
          `endif
            
          // MUL/MAC RS payload。
          `ifdef TB_SUPPORT
            assign rs_dp2mul[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            //乘加类指令通常需要旧 vd 作为累加输入，所以 vd 被作为 vs3_data 送入 MUL/MAC RS。
            assign rs_dp2mul[i].rob_entry       = rob_address[i]; 
            assign rs_dp2mul[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2mul[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2mul[i].vxrm            = uop_uop2dp[i].vector_csr.xrm;
            assign rs_dp2mul[i].vs1_data        = uop_uop2dp[i].vs1_valid ? uop_operand[i].vs1 : (`VLEN)'(uop_uop2dp[i].rs1_data);
            assign rs_dp2mul[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2mul[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2mul[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2mul[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
            assign rs_dp2mul[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2mul[i].vs3_data        = uop_operand[i].vd;  //旧 vd 是累加输入，因此在执行单元内部把它当作 vs3 使用。
            assign rs_dp2mul[i].vs3_data_valid  = uop_uop2dp[i].vs3_valid;
            assign rs_dp2mul[i].uop_index       = uop_uop2dp[i].uop_index[0];  //MUL/MAC 单元内部可能只需要区分低位奇偶切片，而不是完整 EMUL index。
                                                                               //只有2倍关系

          // DIV/FDIV RS payload。
          `ifdef TB_SUPPORT
            assign rs_dp2div[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2div[i].rob_entry       = rob_address[i]; 
            assign rs_dp2div[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2div[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2div[i].is_div          = uop_uop2dp[i].uop_exe_unit==DIV;  //整数div
            assign rs_dp2div[i].vs1_data        = uop_uop2dp[i].vs1_valid ? uop_operand[i].vs1 : (`VLEN)'(uop_uop2dp[i].rs1_data);
            assign rs_dp2div[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2div[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2div[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2div[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2div[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
          `ifdef ZVE32F_ON
            assign rs_dp2div[i].frm             = uop_uop2dp[i].vector_csr.frm;
            assign rs_dp2div[i].vs1             = uop_uop2dp[i].vs1;
          `endif

          `ifdef ZVE32F_ON
          // FMA/浮点执行 RS payload。
          `ifdef TB_SUPPORT
            assign rs_dp2fma[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2fma[i].rob_entry       = rob_address[i]; 
            assign rs_dp2fma[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2fma[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2fma[i].uop_exe_unit    = uop_uop2dp[i].uop_exe_unit;
            assign rs_dp2fma[i].vstart          = uop_uop2dp[i].vector_csr.vstart;
            assign rs_dp2fma[i].vl              = uop_uop2dp[i].vs_evl;
            assign rs_dp2fma[i].vm              = uop_uop2dp[i].vm;
            assign rs_dp2fma[i].frm             = uop_uop2dp[i].vector_csr.frm;
            assign rs_dp2fma[i].v0_data         = uop_operand[i].v0[`VLENW*`EMUL_MAX-1:0];  //FMA 的 v0 可能只需要按 32-bit lane 组织的 mask 宽度，因此取 VLENW*EMUL_MAX 位。
            assign rs_dp2fma[i].v0_data_valid   = uop_uop2dp[i].v0_valid;
            assign rs_dp2fma[i].vs1             = uop_uop2dp[i].vs1;
            assign rs_dp2fma[i].vs1_data        = uop_operand[i].vs1;
            assign rs_dp2fma[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2fma[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2fma[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
            assign rs_dp2fma[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2fma[i].vs3_data        = uop_operand[i].vd;
            assign rs_dp2fma[i].vs3_data_valid  = uop_uop2dp[i].vs3_valid;
            assign rs_dp2fma[i].rs1_data        = uop_uop2dp[i].rs1_data;
            assign rs_dp2fma[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2fma[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2fma[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];            
          `endif

          // LSU RS payload：包含 index 向量、store 数据向量和 v0 strobe。
          `ifdef TB_SUPPORT
            assign rs_dp2lsu[i].uop_pc              = uop_uop2dp[i].uop_pc; 
          `endif
            // | 字段           | 含义                 |
            // | ------------ | ------------------ |
            // | `vidx_valid` | 是否有 index vector   |
            // | `vidx_addr`  | index vector 寄存器编号 |
            // | `vidx_data`  | index vector 数据    |
            assign rs_dp2lsu[i].vidx_valid          = uop_uop2dp[i].vs2_valid;
            assign rs_dp2lsu[i].vidx_addr           = uop_uop2dp[i].vs2_index;  
            assign rs_dp2lsu[i].vidx_data           = uop_operand[i].vs2;          //index vector
            //store data
            assign rs_dp2lsu[i].vregfile_read_valid = uop_uop2dp[i].vs3_valid;
            assign rs_dp2lsu[i].vregfile_read_addr  = uop_uop2dp[i].dst_index;
            assign rs_dp2lsu[i].vregfile_read_data  = uop_operand[i].vd;
            ////LSU 拿到的是经过 byte type 处理后的 v0 strobe，而不是原始 v0 bitstream。
            assign rs_dp2lsu[i].v0_valid            = uop_uop2dp[i].v0_valid;
            assign rs_dp2lsu[i].v0_data             = uop_operand_byte_type[i].v0_strobe;  

          // LSU MAP INFO：把 LSU uop 与 ROB entry、load/store 类型和 VRF 写回地址关联起来。
          `ifdef TB_SUPPORT
            assign mapinfo_dp2lsu[i].uop_pc              = uop_uop2dp[i].uop_pc; 
          `endif
            // LSU 不只需要执行数据，还需要一份映射信息 mapinfo。
            // 它把 LSU 请求和 ROB/写回目标绑定起来：
            // | 字段                    | 含义                    |
            // | --------------------- | --------------------- |
            // | `valid`               | 当前 mapinfo 是否有效       |
            // | `rob_entry`           | LSU 完成后对应哪个 ROB entry |
            // | `lsu_class`           | load 还是 store         |
            // | `vregfile_write_addr` | load 写回哪个向量寄存器        |
            // 因为 load 可能晚于 dispatch 完成。完成时 LSU 需要告诉 ROB：
            // 这个 load 的数据属于哪个 ROB entry
            assign mapinfo_dp2lsu[i].valid               = mapinfo_valid_dp2lsu[i];
            assign mapinfo_dp2lsu[i].rob_entry           = rob_address[i];
            assign mapinfo_dp2lsu[i].lsu_class           = uop_uop2dp[i].uop_funct6.lsu_funct6.lsu_is_store;
            assign mapinfo_dp2lsu[i].vregfile_write_addr = uop_uop2dp[i].dst_index;

          // ROB payload：记录目的寄存器类型、byte_type、CSR 和 last_uop，用于后续完成/退休。
          `ifdef TB_SUPPORT
            assign uop_dp2rob[i].uop_pc         = uop_uop2dp[i].uop_pc; 
          `endif
            // 这一段组装写入 ROB 的信息
            assign uop_dp2rob[i].w_index        = uop_uop2dp[i].dst_index;
            assign uop_dp2rob[i].w_type         = uop_uop2dp[i].vd_valid ? VRF : 
          `ifdef ZVE32F_ON
                                                  uop_uop2dp[i].fd_valid ? FRF :
          `endif
                                                  XRF;
            // ROB 需要 byte_type，因为写回不是简单整寄存器覆盖。
            // byte_type 告诉 ROB：
            // 哪些 byte 是 BODY_ACTIVE，需要写回
            // 哪些 byte 是 BODY_INACTIVE，按 vma 策略处理
            // 哪些 byte 是 TAIL，按 vta 策略处理
            // 哪些 byte 是 NOT_CHANGE，需要保留旧值
            // vector_csr 用于后续退休/写回时解释 tail/mask policy。
            // last_uop_valid 用于判断这一条原始 RVV 指令是否已经到最后一个 uop。
            assign uop_dp2rob[i].byte_type      = uop_operand_byte_type[i].vd;
            assign uop_dp2rob[i].vector_csr     = uop_uop2dp[i].vector_csr;
            assign uop_dp2rob[i].last_uop_valid = uop_uop2dp[i].last_uop_valid;
        end
    endgenerate

endmodule
