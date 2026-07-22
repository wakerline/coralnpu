// 功能说明：
// 1. `rvv_backend_dispatch_raw_uop_uop` 是 `rvv_backend_dispatch` 的子模块。
// 2. 本模块检查同一个 dispatch 周期内，较年轻 uop（suc_uop）是否 RAW 依赖本拍更老的 uop（pre_uop）。
// 3. 若当前 uop 的源向量寄存器命中更老 uop 的目的向量寄存器，且更老 uop 的写回结果尚未有效，则输出 wait，阻止当前 uop 继续发射。
//

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_raw_uop_uop` -> DP 阶段内部的同拍 uop-vs-uop RAW 检查单元。
// - 接口与数据流：
//   * 输入：`suc_uop` 是当前待判断的较年轻 uop 的源寄存器摘要。
//   * 输入：`pre_uop` 是本拍位于它之前、已经尝试发射的更老 uop 的目的寄存器摘要，数量由 `PREUOP_NUM` 决定。
//   * 处理：分别检查 vs1、vs2、vd-as-vs3、v0 mask 是否依赖前序 uop 的 VRF 写回。
//   * 输出：`RAW_UOP_UOP_t` 只给出 wait 位；dispatch 控制逻辑据此阻止相关 uop 同拍越过尚未产生结果的前序 uop。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 suc_uop, pre_uop；输出 raw_uop_uop。
// - 与 `rvv_backend_dispatch_raw_uop_rob` 的区别：
//   * uop-vs-ROB 可以在 ROB 条目 ready 时选择旁路数据。
//   * uop-vs-uop 面对的是同拍更老 uop，结果通常尚未进入可旁路状态，因此命中未有效写回时只能等待。
// - define/参数阅读重点：
//   * `V0_INDEX`：5'b00000；v0 mask 寄存器编号。
//   * `PREUOP_NUM`：本实例需要比较的同拍更老 uop 个数；在多发射 dispatch 中，不同 lane 的该值通常不同。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 阅读建议：结合 dispatch 顶层中各 lane 对本模块的实例化，按 lane 序号理解“更老 uop”的范围。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_raw_uop_uop
(
    raw_uop_uop,
    suc_uop,
    pre_uop
);

// ---parameter definition--------------------------------------------
    // 需要检查的前序 uop 数量。
    // 例如多发射 dispatch 中，lane0 前面没有同拍更老 uop，lane1 只需看 lane0，lane2 需看 lane0/lane1。
    parameter PREUOP_NUM = 1;

// ---port definition-------------------------------------------------
    output  RAW_UOP_UOP_t     raw_uop_uop; // 输出给 dispatch 控制的 RAW 等待结果，每个源操作数对应一个 wait 位。
    input   SUC_UOP_RAW_t     suc_uop;     // 较年轻 uop 的源寄存器信息，包括 vs1/vs2/vs3/v0 mask 使用情况。
    input   PRE_UOP_RAW_t [PREUOP_NUM-1:0]  pre_uop; // 本拍更老 uop 的目的寄存器写回摘要。

// ---internal signal definition--------------------------------------
    // *_cmp：仅表示寄存器编号相等，还没有考虑源操作数是否真的被使用、前序 uop 是否有效、写回类型是否为 VRF。
    logic [PREUOP_NUM-1:0]    vs1_cmp;  // suc_uop.vs1_index 与各 pre_uop.w_index 的比较结果。
    logic [PREUOP_NUM-1:0]    vs2_cmp;  // suc_uop.vs2_index 与各 pre_uop.w_index 的比较结果。
    logic [PREUOP_NUM-1:0]    vd_cmp;   // suc_uop.vd_index 在 vs3 语义下与各 pre_uop.w_index 的比较结果。
    logic [PREUOP_NUM-1:0]    v0_cmp;   // v0 mask 寄存器与各 pre_uop.w_index 的比较结果。

    // *_hit：确认存在真实 RAW 相关，即编号相等、当前源操作数有效、前序 uop 有效，且前序写回目标是 VRF。
    logic [PREUOP_NUM-1:0]    vs1_hit;  // 前序 uop 目的寄存器是当前 uop 的 vs1 源寄存器。
    logic [PREUOP_NUM-1:0]    vs2_hit;  // 前序 uop 目的寄存器是当前 uop 的 vs2 源寄存器。
    logic [PREUOP_NUM-1:0]    vd_hit;   // 前序 uop 目的寄存器是当前 uop 的 vs3 源寄存器；字段名沿用 vd_index。
    logic [PREUOP_NUM-1:0]    v0_hit;   // 当前 uop 需要 mask（vm=0）时，前序 uop 写 v0 形成 mask RAW 相关。

    // *_wait：RAW 命中且前序 uop 的写回值还不可用时置位。
    // 在常见同拍发射场景下，前序 uop 结果尚未执行产生，因此命中会转化为等待。
    logic  [PREUOP_NUM-1:0]   vs1_wait;
    logic  [PREUOP_NUM-1:0]   vs2_wait;
    logic  [PREUOP_NUM-1:0]   vd_wait;
    logic  [PREUOP_NUM-1:0]   v0_wait;
// ---code start------------------------------------------------------
    genvar i;
    generate
        for (i=0; i<PREUOP_NUM; i++) begin : gen_compare_result
            // 第一步：按寄存器编号做并行比较。
            // 这里只判断“可能相关”，后续 hit 阶段再结合 valid/type 过滤。
            assign vs1_cmp[i] = (suc_uop.vs1_index == pre_uop[i].w_index);
            assign vs2_cmp[i] = (suc_uop.vs2_index == pre_uop[i].w_index);
            assign vd_cmp[i]  = (suc_uop.vd_index  == pre_uop[i].w_index);
            assign v0_cmp[i]  = (`V0_INDEX         == pre_uop[i].w_index);
        end
    endgenerate

// RAW 命中条件：
// a. 当前源寄存器编号等于前序目的寄存器编号；
// b. 当前 uop 确实需要该源向量寄存器，即对应 *_valid 置位，或 mask 指令 vm=0 需要读取 v0；
// c. 前序 uop 本身有效；
// d. 前序 uop 的写回类型是 VRF。若写 GPR/CSR/无写回，则不会影响向量源寄存器读取。
    generate
        for (i=0; i<PREUOP_NUM; i++) begin : gen_hit_result
            assign vs1_hit[i] = vs1_cmp[i] & suc_uop.vs1_valid & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
            assign vs2_hit[i] = vs2_cmp[i] & suc_uop.vs2_valid & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
            assign vd_hit[i]  = vd_cmp[i]  & suc_uop.vs3_valid & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
            assign v0_hit[i]  = v0_cmp[i]  & (~suc_uop.vm)     & pre_uop[i].valid & (pre_uop[i].w_type==VRF);
        end
    endgenerate

    generate
        for (i=0; i<PREUOP_NUM; i++) begin : gen_wait_result
            // 第二步：RAW 命中后，如果前序 uop 的写回值尚未有效，则当前源操作数必须等待。
            // 这里没有输出旁路选择；同拍前序 uop 的结果不在本模块中被直接转发。
            assign vs1_wait[i] = vs1_hit[i] & (~pre_uop[i].w_valid);
            assign vs2_wait[i] = vs2_hit[i] & (~pre_uop[i].w_valid);
            assign vd_wait[i]  = vd_hit[i]  & (~pre_uop[i].w_valid);
            assign v0_wait[i]  = v0_hit[i]  & (~pre_uop[i].w_valid);
        end
    endgenerate

// 输出结果：
// 任意一个前序 uop 对同一源操作数造成未满足 RAW，即对该源输出 wait=1。
// dispatch 控制逻辑会把这些 wait 汇总到 lane 的可发射判断中。
    assign raw_uop_uop.vs1_wait = |vs1_wait;
    assign raw_uop_uop.vs2_wait = |vs2_wait;
    assign raw_uop_uop.vd_wait  = |vd_wait;
    assign raw_uop_uop.v0_wait  = |v0_wait;

endmodule
