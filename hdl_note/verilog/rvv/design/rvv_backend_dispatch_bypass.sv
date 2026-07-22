`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_bypass` -> RVV 后端 DP 阶段的 ROB bypass 数据选择单元。
// - 接口与数据流：
//   * 输入：`vrf_byp` 是 VRF 当前周期读出的原始 vs1/vs2/vd/v0 数据。
//   * 输入：`rob_byp` 是所有 ROB entry 可旁路的写回数据、byte_type 和 agnostic 填充值策略。
//   * 输入：`raw_uop_rob` 是 RAW 检查结果，指出当前 uop 的各源操作数命中了哪些 ROB entry。
//   * 输出：`uop_operand` 是最终送往 RS 的操作数；默认来自 VRF，命中 ROB 时按 byte 被 ROB 数据覆盖。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 rob_byp, vrf_byp, raw_uop_rob；输出 uop_operand。
// - define/参数阅读重点：
//   * `BYTE_WIDTH`：8。
//   * `ROB_DEPTH`：8；ROB entry 数。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 旁路规则：
//   * 每个源操作数 vs1/vs2/vd/v0 独立选择，命中哪个 ROB entry 就从该 entry 的 w_data 取数。
//   * 选择粒度是 byte，因为 mask/tail/不同 EEW 写回可能只更新向量寄存器的一部分 byte。
//   * `BODY_ACTIVE` byte 直接使用 ROB 写回数据。
//   * `BODY_INACTIVE` 且 inactive_one=1，或 `TAIL` 且 tail_one=1 时，按 agnostic-one 语义填 8'hFF。
//   * 未命中 ROB 或 byte 不应被 ROB 覆盖时，保留 VRF 原始读数。
// - 阅读建议：先看 `gen_data_sel` 生成每个 ROB entry/byte 的选择信号，再看 `bypass` 循环如何逐 byte 覆盖操作数。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_bypass
(
    uop_operand,
    rob_byp,
    vrf_byp,
    raw_uop_rob
);
// ---端口定义-------------------------------------------------
    // 最终输出给 RS 的四类向量操作数。
    output UOP_OPN_t                  uop_operand;
    // ROB 可旁路数据。数组下标对应 ROB entry 编号。
    input  ROB_BYP_t [`ROB_DEPTH-1:0] rob_byp;
    // VRF 读出的原始操作数。没有 ROB 命中时直接使用这些数据。
    input  UOP_OPN_t                  vrf_byp;
    // 当前 uop 与 ROB 的 RAW 命中结果；每个 *_hit 都是 ROB_DEPTH bit 的 one-hot/多 bit 命中向量。
    input  RAW_UOP_ROB_t              raw_uop_rob;

// ---内部信号定义--------------------------------------
    // *_sel[i][j] 表示第 i 个 ROB entry 的第 j 个 byte 是否应该覆盖对应源操作数。
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] vs1_sel;
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] vs2_sel;
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] vd_sel;
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] v0_sel;
    // agnostic[i][j]=1 时，不使用 ROB w_data，而是按 agnostic-one 填 8'hFF。
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] agnostic;

// ---代码开始------------------------------------------------------
    genvar i,j;
    generate
        // 对每个 ROB entry、每个 byte 生成旁路选择条件。
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_data_sel  //需要对比rob中8个结果
            for (j=0; j<`VLENB; j++) begin  //每个寄存器，需要处理inactive/tail byte
                // 对普通 active byte，只要源操作数命中该 ROB entry，就可以从 ROB 取该 byte。
                // 对 inactive/tail byte，只有 ROB entry 指明 inactive_one/tail_one 时才覆盖为 1。
                assign vs1_sel[i][j]  = (raw_uop_rob.vs1_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign vs2_sel[i][j]  = (raw_uop_rob.vs2_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign vd_sel[i][j]   = (raw_uop_rob.vd_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign v0_sel[i][j]   = (raw_uop_rob.v0_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                // agnostic byte 不需要使用真实写回数据，直接输出全 1。
                assign agnostic[i][j] = (rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                        rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);
            end
        end

        // 对每个 byte 独立选择最终操作数：
        // 1. 先默认取 VRF 读数；
        // 2. 再按 ROB entry 顺序检查旁路命中，命中则覆盖该 byte。
        for (j=0; j<`VLENB; j++) begin: bypass
            always_comb begin
                uop_operand.vs1[`BYTE_WIDTH*j+:`BYTE_WIDTH] = vrf_byp.vs1[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                uop_operand.vs2[`BYTE_WIDTH*j+:`BYTE_WIDTH] = vrf_byp.vs2[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                uop_operand.vd[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = vrf_byp.vd[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                uop_operand.v0[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = vrf_byp.v0[`BYTE_WIDTH*j+:`BYTE_WIDTH];

                for(int i=0;i<`ROB_DEPTH;i++) begin
                    // 若多个 ROB entry 同时命中同一 byte，循环中较后 entry 会覆盖较前 entry。
                    // 这要求 raw_uop_rob 的命中编码已经按最新 producer 组织，或者设计保证不会多重冲突。
                    if(vs1_sel[i][j]) 
                        uop_operand.vs1[`BYTE_WIDTH*j+:`BYTE_WIDTH] = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                    if(vs2_sel[i][j]) 
                        uop_operand.vs2[`BYTE_WIDTH*j+:`BYTE_WIDTH] = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                    if(vd_sel[i][j]) 
                        uop_operand.vd[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                    if(v0_sel[i][j]) 
                        uop_operand.v0[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                end
            end
        end
    endgenerate

endmodule
