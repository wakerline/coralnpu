// 功能说明：
// 1. `rvv_backend_dispatch_ctrl` 是 Dispatch 阶段的握手控制中心。
// 2. 它根据 RAW 等待、结构冒险、各执行单元 RS ready、ROB ready 和 LSU mapinfo ready，
//    决定哪些 uop 可以从 Uop Queue 出队，并向对应 RS/ROB/LSU 发出 valid。
// 3. 本模块只产生控制 valid/ready，不搬运具体操作数；操作数 payload 在 rvv_backend_dispatch.sv 中组包。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_ctrl` -> RVV 后端 DP 阶段的 dispatch 握手控制器。
// - 接口与数据流：
//   * 输入：RAW 检查结果、结构冒险结果、uop 目标执行单元摘要、Uop Queue valid 和各下游 ready。
//   * 处理：形成按程序顺序连续发射的 uop_valid 前缀，并用下游 ready 决定是否真正出队。
//   * 输出：Uop Queue ready、各 RS valid、ROB valid、LSU mapinfo valid。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 raw_uop_rob, raw_uop_uop, arch_hazard, uop_ctrl, uop_valid_uop2dp, rs_ready_alu2dp, rs_ready_pmtrdt2dp, rs_ready_mul2dp, rs_ready_div2dp, rs_ready_fma2dp, rs_ready_lsu2dp, mapinfo_ready_lsu2dp；输出 uop_ready_dp2uop, rs_valid_dp2alu, rs_valid_dp2pmtrdt, rs_valid_dp2mul, rs_valid_dp2div, rs_valid_dp2fma, rs_valid_dp2lsu, mapinfo_valid_dp2lsu, uop_valid_dp2rob。
// - define/参数阅读重点：
//   * `NUM_DP_UOP`：3；当前 DISPATCH3 下 Dispatch 每拍最多发射 uop 数，DISPATCH2 时为 2。
// - 不确定/条件宏提示：
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - 控制规则：
//   * Dispatch 只允许从 uop0 开始形成连续前缀发射；后面的 uop 不能越过前面 stalled 的 uop。
//   * uop0 只检查自己与 ROB 的 RAW wait；uop1 之后还要检查同拍更老 uop 的 RAW wait。
//   * 最后一个 dispatch 槽额外检查 `arch_hazard.vr_limit`，用于限制 VRF 读口超发。
//   * `rs_ready[i]` 是串联前缀 ready：第 i 个 uop 能发射，要求前面所有已选 uop 的目标资源也 ready。
//   * LSU uop 需要同时考虑 LSU RS ready 和 mapinfo ready；若 pshlsu_valid=0，可跳过 LSU RS ready。
//   * 只有 `uop_valid && rs_ready && rob_ready` 同时成立，才会对 Uop Queue 拉高 ready。
// - 阅读建议：按 “uop_valid 前缀 -> rs_ready 前缀 -> ready/valid 输出” 阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_ctrl
(
    raw_uop_rob,
    raw_uop_uop,
    arch_hazard,
    uop_ctrl,
    uop_valid_uop2dp,
    uop_ready_dp2uop,
    rs_valid_dp2alu,
    rs_ready_alu2dp,
    rs_valid_dp2pmtrdt,
    rs_ready_pmtrdt2dp,
    rs_valid_dp2mul,
    rs_ready_mul2dp,
    rs_valid_dp2div,
    rs_ready_div2dp,
  `ifdef ZVE32F_ON
    rs_valid_dp2fma,
    rs_ready_fma2dp,
  `endif
    rs_valid_dp2lsu,
    rs_ready_lsu2dp,
    mapinfo_valid_dp2lsu,
    mapinfo_ready_lsu2dp,
    uop_valid_dp2rob,
    uop_ready_rob2dp
);
// ---端口定义-------------------------------------------------
// 控制输入信号。
    // 当前 uop 与 ROB 未退休写回之间的 RAW 等待/命中信息。
    input   RAW_UOP_ROB_t [`NUM_DP_UOP-1:0] raw_uop_rob;
    // 当前 uop 与同拍更老 uop 之间的 RAW 等待信息；uop0 没有该项。
    input   RAW_UOP_UOP_t [`NUM_DP_UOP-1:1] raw_uop_uop;
    // 结构冒险结果，目前主要包含 VRF 读口限制。
    input   ARCH_HAZARD_t                   arch_hazard;
    // 每个 uop 的目标执行单元，以及是否需要入 ROB/LSU。
    input   UOP_CTRL_t    [`NUM_DP_UOP-1:0] uop_ctrl;

// 握手信号。
    // Uop Queue -> Dispatch 的 valid，以及 Dispatch 回给 Uop Queue 的 ready。
    input   logic         [`NUM_DP_UOP-1:0] uop_valid_uop2dp;
    output  logic         [`NUM_DP_UOP-1:0] uop_ready_dp2uop;

    // Dispatch -> 各执行单元 RS 的 valid/ready。
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2alu;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_alu2dp;
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2pmtrdt;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_pmtrdt2dp;
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2mul;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_mul2dp;
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2div;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_div2dp;
  `ifdef ZVE32F_ON
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2fma;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_fma2dp;
  `endif
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2lsu;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_lsu2dp;
    output  logic         [`NUM_DP_UOP-1:0] mapinfo_valid_dp2lsu;
    input   logic         [`NUM_DP_UOP-1:0] mapinfo_ready_lsu2dp;

    // Dispatch -> ROB 的 valid/ready。pshrob_valid=0 的 uop 不需要真正写 ROB。
    output  logic         [`NUM_DP_UOP-1:0] uop_valid_dp2rob;
    input   logic         [`NUM_DP_UOP-1:0] uop_ready_rob2dp;

// ---内部信号定义--------------------------------------
    // uop_valid[i] 表示第 i 个槽位在 hazard 层面允许发射，并且 0..i 都是连续有效前缀。
    logic [`NUM_DP_UOP-1:0] uop_valid;
    // rs_ready[i] 表示 0..i 这些连续前缀 uop 的目标下游资源都 ready。
    logic [`NUM_DP_UOP-1:0] rs_ready;

// ---代码开始------------------------------------------------------
    genvar i;
    generate
        // 1. 生成 uop_valid 连续前缀。
        //    一旦更老 uop 无效或被 RAW/结构冒险挡住，后续 uop_valid 也会全部为 0。
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_uop_valid
            if (i==0) begin : gen_first
              // uop0 只需要检查 Uop Queue valid 以及与 ROB 的 RAW wait。
              assign uop_valid[0] = uop_valid_uop2dp[0]      &
                                    ~raw_uop_rob[0].vs1_wait &  //检查 ROB RAW
                                    ~raw_uop_rob[0].vs2_wait &
                                    ~raw_uop_rob[0].vd_wait  &
                                    ~raw_uop_rob[0].v0_wait  ;
            end else if (i<`NUM_DP_UOP-1) begin : gen_i
              // 中间槽位必须等待前一槽位可发射，并同时检查 ROB RAW 和同拍 uop RAW。
              assign uop_valid[i] = uop_valid[i-1]           &
                                    uop_valid_uop2dp[i]      &
                                    ~raw_uop_rob[i].vs1_wait &  //检查 ROB RAW
                                    ~raw_uop_rob[i].vs2_wait &
                                    ~raw_uop_rob[i].vd_wait  &
                                    ~raw_uop_rob[i].v0_wait  &
                                    ~raw_uop_uop[i].vs1_wait &  //同拍 uop RAW
                                    ~raw_uop_uop[i].vs2_wait &
                                    ~raw_uop_uop[i].vd_wait  &
                                    ~raw_uop_uop[i].v0_wait  ;
            end else begin : gen_last
              // 最后一个槽位额外受 VRF 读口结构限制保护，避免超出本拍 VRF 读端口数量。
              assign uop_valid[i] = uop_valid[i-1]           &
                                    uop_valid_uop2dp[i]      &
                                    ~raw_uop_rob[i].vs1_wait &
                                    ~raw_uop_rob[i].vs2_wait &
                                    ~raw_uop_rob[i].vd_wait  &
                                    ~raw_uop_rob[i].v0_wait  &
                                    ~raw_uop_uop[i].vs1_wait &
                                    ~raw_uop_uop[i].vs2_wait &
                                    ~raw_uop_uop[i].vd_wait  &
                                    ~raw_uop_uop[i].v0_wait  &
                                    ~arch_hazard.vr_limit    ;  //最后一个槽位额外受 VRF 读口结构限制保护
            end
        end
        // 2. 生成 rs_ready 连续前缀。
        //    目标执行单元由 uop_ctrl.uop_exe_unit 决定；后续槽位还要求前面槽位资源 ready。
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_rs_ready
          if (i==0) begin : gen_first
            always_comb begin
                // 第一个槽位只看自己的目标资源 ready。
                case (uop_ctrl[i].uop_exe_unit)
                    CMP,
                    ALU: rs_ready[0] = rs_ready_alu2dp[0];
                    MUL,
                    MAC: rs_ready[0] = rs_ready_mul2dp[0];
                    MISC,
                    PMT,
                  `ifdef ZVE32F_ON
                    FRDT,
                  `endif
                    RDT: rs_ready[0] = rs_ready_pmtrdt2dp[0];
                  `ifdef ZVE32F_ON
                    FNCMP,
                    FCMP,
                    FMA,
                    FCVT,
                    FTBL:rs_ready[0] = rs_ready_fma2dp[0];
                    FDIV,
                  `endif
                    DIV: rs_ready[0] = rs_ready_div2dp[0];
                    // LSU 需要 mapinfo ready；如果该 uop 不需要进入 LSU RS，则可以忽略 rs_ready_lsu2dp。
                    LSU: rs_ready[0] = (!uop_ctrl[0].pshlsu_valid||rs_ready_lsu2dp[0]) & mapinfo_ready_lsu2dp[0];
                    default: rs_ready[0] = 1'b0;
                endcase
            end
          end else begin : gen_i
            always_comb begin
                // 后续槽位必须保证前面所有槽位已 ready，保持顺序 dispatch。
                case (uop_ctrl[i].uop_exe_unit)
                    CMP,
                    ALU: rs_ready[i] = rs_ready[i-1] & rs_ready_alu2dp[i];
                    MUL,
                    MAC: rs_ready[i] = rs_ready[i-1] & rs_ready_mul2dp[i];
                    MISC,
                    PMT,
                  `ifdef ZVE32F_ON
                    FRDT,
                  `endif
                    RDT: rs_ready[i] = rs_ready[i-1] & rs_ready_pmtrdt2dp[i];
                  `ifdef ZVE32F_ON
                    FNCMP,
                    FCMP,
                    FMA,
                    FCVT:rs_ready[i] = rs_ready[i-1] & rs_ready_fma2dp[i];
                    FDIV,
                  `endif
                    DIV: rs_ready[i] = rs_ready[i-1] & rs_ready_div2dp[i];
                    // LSU 同时检查自身 RS 和 mapinfo 通路；pshlsu_valid=0 时只保留 mapinfo 约束。
                    LSU: rs_ready[i] = rs_ready[i-1] & (!uop_ctrl[i].pshlsu_valid||rs_ready_lsu2dp[i]) & mapinfo_ready_lsu2dp[i];
                    default: rs_ready[i] = 1'b0;
                endcase
            end
          end
        end
        // 3. 输出 ready/valid。
        //    uop_ready_dp2uop 是最终出队条件；各 RS/ROB/LSU valid 都从它派生，保证 payload 同步生效。
        for (i=0; i<`NUM_DP_UOP; i++) begin: gen_ctrl_output
            // 只有 hazard 允许、下游 RS/mapinfo ready、ROB ready 全部满足，才消费 Uop Queue 中该槽 uop。
            assign uop_ready_dp2uop[i]     = uop_valid[i]        &  //hazard 允许
                                             uop_ready_rob2dp[i] &  //ROB ready 全部满足
                                             rs_ready[i]         ;  //下游 RS/mapinfo ready

            // pshrob_valid=0 的内部 uop 不写 ROB，但仍可以发往 RS/LSU。
            assign uop_valid_dp2rob[i]     = uop_ready_dp2uop[i] & 
                                             uop_ctrl[i].pshrob_valid;

            // 按执行单元类型把同一个 dispatch 槽位的 valid 分发到对应 RS。
            assign rs_valid_dp2alu[i]      = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == ALU) ||
                                              (uop_ctrl[i].uop_exe_unit == CMP) );
            assign rs_valid_dp2pmtrdt[i]   = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == MISC)|| 
                                            `ifdef ZVE32F_ON
                                              (uop_ctrl[i].uop_exe_unit == FRDT)|| 
                                            `endif
                                              (uop_ctrl[i].uop_exe_unit == PMT) || 
                                              (uop_ctrl[i].uop_exe_unit == RDT) ); 
            assign rs_valid_dp2mul[i]      = uop_ready_dp2uop[i] & 
                                             (uop_ctrl[i].uop_exe_unit == MUL || 
                                              uop_ctrl[i].uop_exe_unit == MAC );
          `ifdef ZVE32F_ON
            assign rs_valid_dp2fma[i]      = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == FMA)  ||
                                              (uop_ctrl[i].uop_exe_unit == FNCMP)||
                                              (uop_ctrl[i].uop_exe_unit == FCMP) ||
                                              (uop_ctrl[i].uop_exe_unit == FTBL) ||
                                              (uop_ctrl[i].uop_exe_unit == FCVT) );
          `endif
            assign rs_valid_dp2div[i]      = uop_ready_dp2uop[i] & (
                                            `ifdef ZVE32F_ON
                                             uop_ctrl[i].uop_exe_unit == FDIV ||
                                            `endif
                                             uop_ctrl[i].uop_exe_unit == DIV);
            assign rs_valid_dp2lsu[i]      = uop_ready_dp2uop[i] & 
                                             uop_ctrl[i].pshlsu_valid &
                                             (uop_ctrl[i].uop_exe_unit == LSU);
            // LSU mapinfo 与 ROB 分配绑定：只有需要进 ROB 的 LSU uop 才产生 mapinfo。
            assign mapinfo_valid_dp2lsu[i] = uop_valid_dp2rob[i] & 
                                             (uop_ctrl[i].uop_exe_unit == LSU);
        end
    endgenerate
    
endmodule
