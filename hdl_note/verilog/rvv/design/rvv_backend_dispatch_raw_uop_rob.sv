// 功能说明：
// 1. `rvv_backend_dispatch_raw_uop_rob` 是 `rvv_backend_dispatch` 的 RAW 检查子模块。
// 2. 它比较当前待 dispatch uop 的源寄存器，与 ROB 中未退休 uop 的目的寄存器。
// 3. 若命中且 ROB 数据已有效，则后续 bypass 单元可从 ROB 取最新数据；若命中但数据未有效，则 dispatch 必须等待。
//

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_raw_uop_rob` -> RVV 后端 DP 阶段的 uop-vs-ROB RAW 检查单元。
// - 接口与数据流：
//   * 输入：`suc_uop`，表示当前较年轻/待发射 uop 的源寄存器需求。
//   * 输入：`pre_uop`，表示 ROB 中较老 uop 的目的寄存器、写回类型、写回有效状态。
//   * 处理：分别检查 vs1、vs2、vd-as-vs3、v0 是否命中 ROB 中尚未退休的 VRF 写回。
//   * 输出：`raw_uop_rob.*_hit` 供 ROB bypass 选数；`*_wait` 供 dispatch_ctrl 判断是否需要阻塞。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 suc_uop, pre_uop；输出 raw_uop_rob。
// - define/参数阅读重点：
//   * `ROB_DEPTH`：8；ROB entry 数。
//   * `V0_INDEX`：5'b00000；v0 mask 寄存器编号。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - hit/wait 语义：
//   * hit：当前源寄存器与某个 ROB entry 的目的寄存器相同，且该 ROB entry 是有效 VRF 写回。
//   * wait：hit 后发现该 ROB entry 的 `w_valid=0`，说明生产者结果还没准备好，当前 uop 不能发射。
//   * hit 但不 wait：生产者结果已在 ROB 中有效，后续 `dispatch_bypass` 可以直接旁路。
//   * v0 只有在当前 uop 使用 mask 时才检查；代码中 `~suc_uop.vm` 表示 vm=0，需要读取 v0。
// - 阅读建议：按 “寄存器编号比较 -> hit 生成 -> wait 生成 -> 输出打包” 阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_raw_uop_rob
(
    raw_uop_rob,
    suc_uop,
    pre_uop
);

// ---端口定义-------------------------------------------------
    // 输出 RAW 检查结果：每个源操作数的 ROB 命中向量和是否需要等待。
    output  RAW_UOP_ROB_t     raw_uop_rob;
    // 当前待 dispatch 的 uop 源寄存器摘要。
    input   SUC_UOP_RAW_t     suc_uop;
    // ROB 中所有较老 uop 的目的寄存器摘要。
    input   PRE_UOP_RAW_t [`ROB_DEPTH-1:0]  pre_uop;

// ---内部信号定义--------------------------------------------
    // *_cmp[i] 只表示寄存器编号相等，还没有考虑 valid、源是否真的需要读取、写回类型等条件。
    logic [`ROB_DEPTH-1:0]    vs1_cmp;
    logic [`ROB_DEPTH-1:0]    vs2_cmp;
    logic [`ROB_DEPTH-1:0]    vd_cmp;
    logic [`ROB_DEPTH-1:0]    v0_cmp;

    // *_hit[i] 表示当前源操作数可以从第 i 个 ROB entry 旁路。
    logic [`ROB_DEPTH-1:0]    vs1_hit;
    logic [`ROB_DEPTH-1:0]    vs2_hit;  
    logic [`ROB_DEPTH-1:0]    vd_hit;   
    logic [`ROB_DEPTH-1:0]    v0_hit;   

    // *_wait[i] 表示命中的 ROB entry 结果尚未有效，需要阻塞当前 uop。
    logic  [`ROB_DEPTH-1:0]   vs1_wait;
    logic  [`ROB_DEPTH-1:0]   vs2_wait;  
    logic  [`ROB_DEPTH-1:0]   vd_wait;   
    logic  [`ROB_DEPTH-1:0]   v0_wait;   
// ---代码开始-------------------------------------------------
    genvar i;
    generate
        // 1. 先只做寄存器编号比较。
        // vd_cmp 用于“vd 作为 vs3 源”的 uop，例如乘加/访存 store 数据源等。
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_compare_result
            assign vs1_cmp[i] = (suc_uop.vs1_index == pre_uop[i].w_index);
            assign vs2_cmp[i] = (suc_uop.vs2_index == pre_uop[i].w_index);
            assign vd_cmp[i]  = (suc_uop.vd_index  == pre_uop[i].w_index);
            assign v0_cmp[i]  = (`V0_INDEX         == pre_uop[i].w_index);
        end
    endgenerate

// 2. 生成 RAW hit。
// RAW 成立需要同时满足：
// a. 源寄存器号等于 ROB entry 的目的寄存器号；
// b. 当前 uop 确实需要读取该源操作数；
// c. ROB entry 有效，并且写回类型是 VRF。
    generate
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_hit_result
            // vs1/vs2 是普通向量源。
            assign vs1_hit[i] = vs1_cmp[i] & suc_uop.vs1_valid & pre_uop[i].valid & (pre_uop[i].w_type==VRF);  //这个 ROB slot 里确实有一条未退休 uop
            assign vs2_hit[i] = vs2_cmp[i] & suc_uop.vs2_valid & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
            // vd_hit 实际表示当前 uop 需要把 vd 当作 vs3 源读取。
            assign vd_hit[i]  = vd_cmp[i]  & suc_uop.vs3_valid & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
            // vm=0 表示指令使用 v0 mask，因此需要检查 v0 的 RAW。
            assign v0_hit[i]  = v0_cmp[i]  & (~suc_uop.vm)     & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
        end
    endgenerate

    // 3. 生成 wait。
    // | 状态 | valid | w_valid | 含义             |
    // | --   | ----- | ------- | -------------- |
    // | 空槽 | 0     | x       | ROB slot empty |
    // | 在途 | 1     | 0       | 还在执行           |
    // | 完成 | 1     | 1       | 可 bypass       |
    // hit 但 producer 的 w_valid=0，说明不能 bypass，dispatch_ctrl 必须阻塞该 uop。
    generate
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_wait_result
            assign vs1_wait[i] = vs1_hit[i] & (~pre_uop[i].w_valid);  //该 ROB entry 的 VRF 写回数据已经就绪（可以 bypass）
            assign vs2_wait[i] = vs2_hit[i] & (~pre_uop[i].w_valid);
            assign vd_wait[i]  = vd_hit[i]  & (~pre_uop[i].w_valid);
            assign v0_wait[i]  = v0_hit[i]  & (~pre_uop[i].w_valid);
        end
    endgenerate

// 4. 输出打包。
// hit 保留 ROB_DEPTH bit 向量，供 bypass 选择具体 ROB entry；
// wait 聚合成单 bit，供 dispatch_ctrl 判断是否 stall。
    assign raw_uop_rob.vs1_hit = vs1_hit;
    assign raw_uop_rob.vs2_hit = vs2_hit;
    assign raw_uop_rob.vd_hit  = vd_hit;
    assign raw_uop_rob.v0_hit  = v0_hit;
    assign raw_uop_rob.vs1_wait = |vs1_wait;  //每个 cycle 都重新做 RAW check
    assign raw_uop_rob.vs2_wait = |vs2_wait;
    assign raw_uop_rob.vd_wait  = |vd_wait;
    assign raw_uop_rob.v0_wait  = |v0_wait;

endmodule
