`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_arb
//------------------------------------------------------------------------------
// 功能定位：
// 1. 本模块是 RVV 后端“执行单元结果 -> ROB 写端口”的结果仲裁器。
// 2. 上层 `rvv_backend` 将各 PU 的 `PU2ROB_t` 结果按固定顺序拼成
//    `req_arb/item_arb`，本模块从最多 `NUM_PU` 个结果源中选择最多
//    `NUM_SMPORT` 个结果写入 ROB。
// 3. `grant[i]` 同时作为上层结果 FIFO 的 pop/ready 依据：某个源被 grant 后，
//    对应 `item[i]` 会在本周期送入某个 `result` 写端口。
// 4. 本模块只处理写回端口冲突，不改变 ROB entry，也不判断指令年龄；
//    ROB 根据 `PU2ROB_t.rob_entry` 完成乱序写回、顺序退休。
//
// PU 编号约定来自 `rvv_backend.sv` 的拼接顺序：
// - 未开启 `ZVE32F_ON` 时：
//   * req[0:1]：LSU0/LSU1，直连 ROB port0/port1，优先级最高。
//   * req[2:3]：ALU0/ALU1，与 MUL 共享 port2/port3 的空闲槽。
//   * req[4:5]：MUL0/MUL1，只在 LSU port0/1 有空闲时通过 round-robin 进入。
//   * req[6]：PMTRDT0，直连 ROB port2。
//   * req[7]：DIV0，直连 ROB port3。
// - 开启 `ZVE32F_ON` 时：
//   * req[0:1]：LSU0/LSU1。
//   * req[2:3]：ALU0/ALU1。
//   * req[4:5]：MUL/MAC0、MUL/MAC1。
//   * req[6]：PMTRDT0，req[7]：DIV0。
//   * req[8:9]：FMA0/FMA1，分别和 req[4]/req[5] 竞争 port0/port1 的空闲槽。
//
// 宏阅读提示：
// - `NUM_LSU`=2，`NUM_ALU`=2，`NUM_MUL`=2，`NUM_PMTRDT`=1，`NUM_DIV`=1。
// - `ZVE32F_ON` 打开时 `NUM_FMA`=2，`NUM_PU`=10；关闭时 `NUM_FMA`=0，
//   `NUM_PU`=8。
// - `ARBITER_ON` 打开时 `NUM_SMPORT`=4，表示 ROB 只有 4 个结果写端口；
//   若不开仲裁，宏里 `NUM_SMPORT` 会退化为 `NUM_PU`，上层直接并行接 ROB。

module rvv_backend_arb(
  clk,
  rst_n,
  req,
  item,
  grant,
  result_valid,
  result
);

// 全局时钟/复位。
    input   logic                       clk;
    input   logic                       rst_n;
// PU 到仲裁器：
// req[i] 表示第 i 个结果源有有效结果，item[i] 是该源要写 ROB 的数据。
    input   logic     [`NUM_PU-1:0]     req;
    input   PU2ROB_t  [`NUM_PU-1:0]     item;
// grant[i] 表示本周期消费第 i 个结果源，上层据此 pop 对应结果 FIFO。
    output  logic     [`NUM_PU-1:0]     grant;
// 仲裁器到 ROB：最多 4 个写端口，每个端口独立 valid/data。
    output  logic     [`NUM_SMPORT-1:0] result_valid;
    output  PU2ROB_t  [`NUM_SMPORT-1:0] result;

// ---内部信号定义-----------------------------------------------------
  `ifdef ZVE32F_ON

  // - 开启 `ZVE32F_ON` 时：
//   * req[0:1]：LSU0/LSU1。
//   * req[2:3]：ALU0/ALU1。
//   * req[4:5]：MUL/MAC0、MUL/MAC1。
//   * req[6]：PMTRDT0，req[7]：DIV0。
//   * req[8:9]：FMA0/FMA1，分别和 req[4]/req[5] 竞争 port0/port1 的空闲槽。

    // 浮点打开时，port0/1 优先给 LSU；若对应 LSU 没有结果，则在
    // MUL/MAC 和 FMA 之间做二选一 round-robin。
    logic [1:0][1:0]  req_fmamac;
    logic [1:0][1:0]  grant_fmamac;
    // port2/3 优先给 PMTRDT/DIV；若其中一个空闲，则 ALU0/1 通过
    // round-robin 抢占空闲端口。
    logic [1:0]       req_alu;
    logic [1:0]       grant_alu;

    // ROB port0：
    // - req[0] LSU0 直接占用 port0。
    // - LSU0 不占用时，在 req[4] MUL/MAC0 和 req[8] FMA0 间轮转选择。
    assign grant[0]      = req[0];
    assign req_fmamac[0] = grant[0] ? 'b0 : {req[8],req[4]};

    arb_round_robin #(.REQ_NUM(2))
    arb_fmamac0 (.grant(grant_fmamac[0]), .req(req_fmamac[0]), .clk(clk), .rst_n(rst_n));

    assign grant[4]        = grant_fmamac[0][0];
    assign grant[8]        = grant_fmamac[0][1];
    assign result_valid[0] = grant[0] || grant[4] || grant[8];
    always_comb begin
      // port0 的数据优先级与 grant 关系保持一致：LSU0 > MUL/MAC0 > FMA0。
      unique case(1'b1)
        grant[0]:           result[0] = item[0];
        grant_fmamac[0][0]: result[0] = item[4];
        default:            result[0] = item[8];
      endcase
    end

    // ROB port1：
    // - req[1] LSU1 直接占用 port1。
    // - LSU1 不占用时，在 req[5] MUL/MAC1 和 req[9] FMA1 间轮转选择。
    assign grant[1]      = req[1];
    assign req_fmamac[1] = grant[1] ? 'b0 : {req[9],req[5]};

    arb_round_robin #(.REQ_NUM(2))
    arb_fmamac1 (.grant(grant_fmamac[1]), .req(req_fmamac[1]), .clk(clk), .rst_n(rst_n));

    assign grant[5]        = grant_fmamac[1][0];
    assign grant[9]        = grant_fmamac[1][1];
    assign result_valid[1] = grant[1] || grant[5] || grant[9];
    always_comb begin
      // port1 的数据优先级与 grant 关系保持一致：LSU1 > MUL/MAC1 > FMA1。
      unique case(1'b1)
        grant[1]:           result[1] = item[1];
        grant_fmamac[1][0]: result[1] = item[5];
        default:            result[1] = item[9];
      endcase
    end

    // ROB port2/3：
    // - req[6] PMTRDT0 固定偏向 port2。
    // - req[7] DIV0 固定偏向 port3。
    // - 若 PMTRDT/DIV 只占用其中一个端口，另一个空闲端口可给 ALU0/1。
    // - 若 PMTRDT/DIV 都空闲，ALU0/ALU1 分别直连 port2/port3。
    assign grant[6] = req[6];
    assign grant[7] = req[7];
    // 只有 port2/3 恰好空出一个时，ALU0/1 才需要二选一仲裁；
    // 两个都空时不需要仲裁，两个都满时也不能接收 ALU。
    assign req_alu  = grant[6]^grant[7] ? req[3:2] : 'b0;
    
    arb_round_robin #(.REQ_NUM(2))
    arb_alu (.grant(grant_alu), .req(req_alu), .clk(clk), .rst_n(rst_n));

    always_comb begin
      case(grant[7:6])
        2'b11: begin
          // PMTRDT 和 DIV 同时有效，占满 port2/3，ALU 本周期不被 grant。
          result_valid[2] = 1'b1;
          result[2]       = item[6];
          result_valid[3] = 1'b1;
          result[3]       = item[7];
          grant[2]        = 'b0;
          grant[3]        = 'b0;
        end
        2'b01: begin
          // 只有 PMTRDT 占用 port2，port3 让给一个 ALU。
          result_valid[2] = 1'b1;
          result[2]       = item[6];
          result_valid[3] = |grant_alu;
          result[3]       = grant_alu[0] ? item[2] : item[3];
          grant[2]        = grant_alu[0];
          grant[3]        = grant_alu[1];
        end
        2'b10: begin
          // 只有 DIV 占用 port3，port2 让给一个 ALU。
          result_valid[2] = |grant_alu;
          result[2]       = grant_alu[0] ? item[2] : item[3];
          result_valid[3] = 1'b1;
          result[3]       = item[7];
          grant[2]        = grant_alu[0];
          grant[3]        = grant_alu[1];
        end
        default: begin
          // port2/3 都空闲时，ALU0/1 直接各占一个端口。
          result_valid[2] = req[2];
          result[2]       = item[2];
          result_valid[3] = req[3];
          result[3]       = item[3];
          grant[2]        = req[2];
          grant[3]        = req[3];
        end
      endcase
    end

  `else 

// - 未开启 `ZVE32F_ON` 时：
//   * req[0:1]：LSU0/LSU1，直连 ROB port0/port1，优先级最高。
//   * req[2:3]：ALU0/ALU1，与 MUL 共享 port2/port3 的空闲槽。
//   * req[4:5]：MUL0/MUL1，只在 LSU port0/1 有空闲时通过 round-robin 进入。
//   * req[6]：PMTRDT0，直连 ROB port2。
//   * req[7]：DIV0，直连 ROB port3。

    // 未打开浮点时，port0/1 在 LSU 与 MUL/MAC 之间分配；
    // port2/3 在 PMTRDT/DIV 与 ALU 之间分配。
    logic [1:0] req_mac;
    logic [1:0] grant_mac;
    logic [1:0] req_alu;
    logic [1:0] grant_alu;

    // ROB port0/1：
    // - req[0]/req[1] LSU0/LSU1 固定优先，占用 port0/port1。
    // - 若 LSU 只占用一个端口，则 req[4]/req[5] 通过 round-robin 抢另一个空闲端口。
    // - 若两个 LSU 都空闲，则 MUL/MAC0/1 直接映射到 port0/1。
    assign grant[0] = req[0];
    assign grant[1] = req[1];
    // 只有 LSU0/1 中恰好一个有效时，MUL/MAC 两路才需要争抢唯一空闲口。
    assign req_mac  = grant[0]^grant[1] ? req[5:4] : 'b0;

    arb_round_robin #(.REQ_NUM(2))
    arb_mac (.grant(grant_mac), .req(req_mac), .clk(clk), .rst_n(rst_n));

    always_comb begin
      case(grant[1:0])
        2'b11: begin
          // 两个 LSU 都有效，占满 port0/1，MUL/MAC 本周期不被 grant。
          result_valid[0] = 1'b1;
          result[0]       = item[0];
          result_valid[1] = 1'b1;
          result[1]       = item[1];
          grant[4]        = 'b0;
          grant[5]        = 'b0;
        end
        2'b01: begin
          // 只有 LSU0 占用 port0，port1 让给一个 MUL/MAC。
          result_valid[0] = 1'b1;
          result[0]       = item[0];
          result_valid[1] = |grant_mac;
          result[1]       = grant_mac[0] ? item[4] : item[5];
          grant[4]        = grant_mac[0];
          grant[5]        = grant_mac[1];
        end
        2'b00: begin
          // 两个 LSU 都空闲，MUL/MAC0/1 直接映射到 port0/1。
          result_valid[0] = req[4];
          result[0]       = item[4];
          result_valid[1] = req[5];
          result[1]       = item[5];
          grant[4]        = req[4];
          grant[5]        = req[5];
        end
        default: begin
          // 只有 LSU1 有效的情况没有把 LSU1 移到 port1 输出，而是本分支置空。
          // 这保持了原 RTL 行为；若后续要优化，应同步检查 ROB 写端口绑定假设。
          result_valid[0] = 'b0;
          result[0]       = item[0];
          result_valid[1] = 'b0;
          result[1]       = item[0];
          grant[4]        = 'b0;
          grant[5]        = 'b0;
        end      
      endcase
    end

// - 未开启 `ZVE32F_ON` 时：
//   * req[0:1]：LSU0/LSU1，直连 ROB port0/port1，优先级最高。
//   * req[2:3]：ALU0/ALU1，共享 port2/port3 的空闲槽。
//   * req[4:5]：MUL0/MUL1，只在 LSU port0/1 有空闲时通过 round-robin 进入。
//   * req[6]：PMTRDT0，直连 ROB port2。
//   * req[7]：DIV0，直连 ROB port3。

    // ROB port2/3：
    // - req[6] PMTRDT0 固定偏向 port2。
    // - req[7] DIV0 固定偏向 port3。
    // - 若只占用一个端口，ALU0/1 通过 round-robin 抢另一个空闲端口。
    // - 若两个都空闲，ALU0/ALU1 直接映射到 port2/port3。
    assign grant[6] = req[6];
    assign grant[7] = req[7];
    // 只有 port2/3 恰好空出一个时，才需要在两个 ALU 之间轮转仲裁。
    assign req_alu  = grant[6]^grant[7] ? req[3:2] : 'b0;
    
    arb_round_robin #(.REQ_NUM(2))
    arb_alu (.grant(grant_alu), .req(req_alu), .clk(clk), .rst_n(rst_n));

    always_comb begin
      case(grant[7:6])
        2'b11: begin
          // PMTRDT 和 DIV 同时有效，占满 port2/3。
          result_valid[2] = 1'b1;
          result[2]       = item[6];
          result_valid[3] = 1'b1;
          result[3]       = item[7];
          grant[2]        = 'b0;
          grant[3]        = 'b0;
        end
        2'b01: begin
          // PMTRDT 占用 port2，port3 让给一个 ALU。
          result_valid[2] = 1'b1;
          result[2]       = item[6];
          result_valid[3] = |grant_alu;
          result[3]       = grant_alu[0] ? item[2] : item[3];
          grant[2]        = grant_alu[0];
          grant[3]        = grant_alu[1];
        end
        2'b10: begin
          // DIV 占用 port3，port2 让给一个 ALU。
          result_valid[2] = |grant_alu;
          result[2]       = grant_alu[0] ? item[2] : item[3];
          result_valid[3] = 1'b1;
          result[3]       = item[7];
          grant[2]        = grant_alu[0];
          grant[3]        = grant_alu[1];
        end
        default: begin
          // port2/3 都空闲时，ALU0/1 直接各占一个端口。
          result_valid[2] = req[2];
          result[2]       = item[2];
          result_valid[3] = req[3];
          result[3]       = item[3];
          grant[2]        = req[2];
          grant[3]        = req[3];
        end
      endcase
    end
  `endif

endmodule
