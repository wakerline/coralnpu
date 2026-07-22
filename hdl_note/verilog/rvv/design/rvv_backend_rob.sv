/*
功能说明：
1. RVV 后端 ROB，接收 Dispatch 分配的 uop 元信息，并接收各执行单元 PU 写回的执行结果。
2. ROB 按 entry 跟踪 uop_info、res_mem、entry_valid、uop_done 和 trap_flag。
3. 对 Dispatch 侧，ROB 提供按程序顺序排列的 entry 状态，用于 RAW 旁路/相关性判断。
4. 对 Retire 侧，ROB 只按程序顺序输出最老的连续可退役 uop，最多 `NUM_RT_UOP` 条/拍。
5. 对 trap 侧，LSU/RVV remap 可写入 trap entry；当 trap entry 到达 ROB 队头并被 retire ready 接收时，
   ROB 拉起 trap_flush_rvv 清空内部 FIFO/状态。

吞吐/结构：
1. Dispatch 每拍最多向 ROB push `NUM_DP_UOP` 条 uop。
2. PU 写回端口数为 `NUM_SMPORT`，执行结果可乱序写入对应 rob_entry。
3. Retire 每拍最多 pop `NUM_RT_UOP` 条连续已完成 uop。
4. ROB 对 Dispatch 暴露的信息必须按程序顺序排列，而不是按物理 entry 编号排列，因此使用 wind_uop_rptr 做窗口重排。
*/

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
module rvv_backend_rob
(
    clk,
    rst_n,
    uop_valid_dp2rob,
    uop_dp2rob,
    uop_ready_rob2dp,
    rob_empty,
    rob_entry_rob2dp,
    wr_valid_pu2rob,
    wr_pu2rob,
    rd_valid_rob2rt,
    rd_rob2rt,
    rd_ready_rt2rob,
    rob_entry_rob2rt,
    uop_rob2dp,
    trap_valid_rmp2rob,
    trap_rob_entry_rmp2rob,
    trap_ready_rob2rmp,
    trap_ready_rvv2rvs,
    trap_flush_rvv    
);  
// 全局时钟/复位。
    input   logic                   clk;
    input   logic                   rst_n;

// Dispatch 向 ROB 分配 uop 元信息。
// rob_entry_rob2dp 是当前写指针，Dispatch 用它给新 uop 标记 rob_entry。
    input   logic     [`NUM_DP_UOP-1:0] uop_valid_dp2rob;
    input   DP2ROB_t  [`NUM_DP_UOP-1:0] uop_dp2rob;
    output  logic     [`NUM_DP_UOP-1:0] uop_ready_rob2dp;
    output  logic                       rob_empty;
    output  logic     [`ROB_DEPTH_WIDTH-1:0] rob_entry_rob2dp;

// 执行单元 PU 乱序写回结果，根据 wr_pu2rob.rob_entry 定位 ROB entry。
    input   logic     [`NUM_SMPORT-1:0] wr_valid_pu2rob;
    input   PU2ROB_t  [`NUM_SMPORT-1:0] wr_pu2rob;

// ROB 到 Retire：按程序顺序弹出最多 `NUM_RT_UOP` 条连续可退役 uop。
    output  logic     [`NUM_RT_UOP-1:0] rd_valid_rob2rt;
    output  ROB2RT_t  [`NUM_RT_UOP-1:0] rd_rob2rt;
    input   logic     [`NUM_RT_UOP-1:0] rd_ready_rt2rob;
    output  logic     [`ROB_DEPTH_WIDTH-1:0] rob_entry_rob2rt;

// 把 ROB 内所有 entry 暴露给 Dispatch 做旁路/相关性判断。
// 注意这里必须按程序顺序输出，而不是按物理 entry_index 输出。
    output  ROB2DP_t  [`ROB_DEPTH-1:0]  uop_rob2dp;

// trap 写入与处理握手。
    input   logic                           trap_valid_rmp2rob;
    input   logic   [`ROB_DEPTH_WIDTH-1:0]  trap_rob_entry_rmp2rob;
    output  logic                           trap_ready_rob2rmp;
    output  logic                           trap_ready_rvv2rvs;    
    output  logic                           trap_flush_rvv;        

// ---内部信号--------------------------------------------------------
    logic                               trap_in;

  // Uop 元信息 FIFO：保持程序顺序，是 ROB 顺序退役的主队列。
    DP2ROB_t  [`NUM_RT_UOP-1:0]         uop_rob2rt;
    logic     [`NUM_RT_UOP-1:0]         uop_valid_rob2rt;
    DP2ROB_t  [`ROB_DEPTH-1:0]          uop_info;
    logic     [`ROB_DEPTH-1:0]          entry_valid;

    logic     [`ROB_DEPTH_WIDTH-1:0]    uop_wptr;
    logic     [`ROB_DEPTH_WIDTH-1:0]    uop_rptr;
    logic     [`NUM_DP_UOP-1:0]         uop_info_fifo_almost_full;

  // 执行结果 RAM：PU 可按 rob_entry 乱序写入。
    RES_ROB_t [`ROB_DEPTH-1:0]          res_mem;
    logic     [`ROB_DEPTH-1:0]          uop_done;

  // trap 标志按 rob_entry 记录，直到该 entry 到队头被处理。
    logic     [`ROB_DEPTH-1:0]          trap_flag;

  // wind 指针用于把环形物理 entry 映射成从 rptr/wptr 开始的顺序窗口。
    logic     [`ROB_DEPTH_WIDTH-1:0]    wind_uop_wptr [`ROB_DEPTH-1:0];
    logic     [`ROB_DEPTH_WIDTH-1:0]    wind_uop_rptr [`ROB_DEPTH-1:0];

    genvar                              i,j;
// ---主逻辑----------------------------------------------------------
  // Uop info FIFO：
  // push 侧来自 Dispatch，pop 侧来自 Retire；clear 由 trap_flush_rvv 清空。
    multi_fifo #(  //数据
        .T            (DP2ROB_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_RT_UOP),
        .DEPTH        (`ROB_DEPTH),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1),
        .FULL_PUSH    (1'b1)
    ) u_uop_info_fifo (
      // 全局信号。
        .clk          (clk),
        .rst_n        (rst_n),
      // push 侧：支持每拍 `NUM_DP_UOP` 路 push。
        .push         (uop_valid_dp2rob),
        .datain       (uop_dp2rob),
        .full         (),
        .almost_full  (uop_info_fifo_almost_full),
      // pop 侧：Retire ready 后才真正出队。
        .pop          (rd_valid_rob2rt & rd_ready_rt2rob),
        .dataout      (uop_rob2rt),
        .empty        (rob_empty),
        .almost_empty (),
      // fifo_data 暴露整个窗口内容，供 Dispatch 旁路/相关性检查。
        .clear        (trap_flush_rvv),
        .fifo_data    (uop_info),
        .wptr         (uop_wptr),
        .rptr         (uop_rptr),
        .entry_count  ()
    );

    assign rob_entry_rob2dp = uop_wptr;
    assign uop_ready_rob2dp = ~uop_info_fifo_almost_full;

  // entry_valid：
  // Dispatch push 时置位；Retire pop 时清零；trap flush 时整体清空。
    multi_fifo #(  //entry_valid：
        .T            (logic),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_RT_UOP),
        .DEPTH        (`ROB_DEPTH),
        .POP_CLEAR    (1'b1),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1),
        .FULL_PUSH    (1'b1)
    ) u_uop_valid_fifo (
      // 全局信号。
        .clk          (clk),
        .rst_n        (rst_n),
      // push 侧 entry_valid 与 uop_valid_dp2rob 同步写入。
        .push         (uop_valid_dp2rob),
        .datain       (uop_valid_dp2rob),
        .full         (),
        .almost_full  (),
      // pop 侧跟随 Retire 真正消费的 lane 清除。
        .pop          (rd_valid_rob2rt & rd_ready_rt2rob),
        .dataout      (uop_valid_rob2rt),
        .empty        (),
        .almost_empty (),
      // 暴露所有 entry 的 valid 位。
        .clear        (trap_flush_rvv),
        .fifo_data    (entry_valid),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

  // PU 结果写入 ROB：
  // 执行完成的 uop 可乱序写回，ROB 只根据 rob_entry 更新对应 res_mem。
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n)
            res_mem <= 'b0;
        else begin
            for (int k=0; k<`NUM_SMPORT; k++) begin  //pu写端口数
                if (wr_valid_pu2rob[k]) begin
                  `ifdef TB_SUPPORT
                    res_mem[wr_pu2rob[k].rob_entry].uop_pc    <= wr_pu2rob[k].uop_pc;
                  `endif                
                    res_mem[wr_pu2rob[k].rob_entry].w_valid   <= wr_pu2rob[k].w_valid;
                    res_mem[wr_pu2rob[k].rob_entry].w_data    <= wr_pu2rob[k].w_data;
                    res_mem[wr_pu2rob[k].rob_entry].vsaturate <= wr_pu2rob[k].vsaturate;
                  `ifdef ZVE32F_ON
                    res_mem[wr_pu2rob[k].rob_entry].fpexp     <= wr_pu2rob[k].fpexp;
                  `endif
                end
            end
        end
    end

  // uop_done：
  // PU 写回时置位；Retire pop 时清零；trap flush 时整体清空。

  // 环形指针展开：
  // wind_uop_rptr[i] 表示从队头开始第 i 个程序顺序 entry 的物理下标。
  // wind_uop_wptr[i] 表示从写指针开始偏移 i 的物理下标。
     generate
         for (i=0; i<`ROB_DEPTH; i++) begin : gen_wind_uop_ptr
           assign wind_uop_rptr[i] = uop_rptr+i;
           assign wind_uop_wptr[i] = uop_wptr+i; //不需要
         end
     endgenerate
    
    //fifo中提取出一部分，进行类似fifo的操作
     always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            uop_done <= '0;
        else if (trap_flush_rvv)
            uop_done <= '0;
        else begin
            for (int k=0; k<`NUM_RT_UOP; k++) begin
                if (rd_valid_rob2rt[k] && rd_ready_rt2rob[k])  //retire ready，输入有效
                    uop_done[wind_uop_rptr[k]] <= 1'b0;
            end
            for (int k=0; k<`NUM_SMPORT; k++) begin
                if (wr_valid_pu2rob[k])
                    uop_done[wr_pu2rob[k].rob_entry] <= 1'b1;
            end
        end
    end

  //只是检查
  `ifdef ASSERT_ON 
    logic [`ROB_DEPTH-1:0][`NUM_SMPORT-1:0] res_sel; // 每个 entry 同一拍最多只能被一个 PU 写回。
    generate
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_res_sel
            for (j=0; j<`NUM_SMPORT; j++) begin : gen_smport    
                assign res_sel[i][j] = wr_valid_pu2rob[j] && (wr_pu2rob[j].rob_entry == i);
            end

            `rvv_expect($onehot0(res_sel[i])) 
            else $error("ROB: Multiple PU results write same entry: index %d, PU %d\n", i, $sampled(res_sel[i]));

        end
    endgenerate
  `endif

  `ifdef ASSERT_ON
    generate
      for (i=0; i<`ROB_DEPTH; i++) begin : gen_res_write_check
        `rvv_forbid( uop_done[wind_uop_rptr[i]] && !entry_valid[i] )
        else $error("ROB: Write back to ROB entry[%d] while entry is invalid", i);

      `ifdef TB_SUPPORT
        `rvv_forbid( uop_done[wind_uop_rptr[i]] && entry_valid[i] && (res_mem[wind_uop_rptr[i]].uop_pc !== uop_info[i].uop_pc) )
        else $error("ROB: Result pc written back to ROB is mismacth: res_mem[%d].uop_pc(0x%08x) != uop_info[%d].uop_pc(0x%08x)", i, res_mem[wind_uop_rptr[i]].uop_pc, i, uop_info[i].uop_pc);
      `endif
      end
    endgenerate
  `endif

  // trap_flag：
  // trap 发生时先记录到对应 ROB entry；只有触发 trap 的 uop 成为队头并被 Retire 接收时才 flush。
  always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n)
          trap_flag <= '0;
      else if (trap_flush_rvv)
          trap_flag <= '0;
      else if (trap_valid_rmp2rob & trap_ready_rob2rmp)
          trap_flag[trap_rob_entry_rmp2rob] <= 1'b1;
  end

  // trap 写入端不反压，晚发现 fault 可以直接标记对应 ROB entry。
  assign trap_ready_rob2rmp = 1'b1;

  // 生成 Retire 读口：
  // lane0 只要队头完成或队头带 trap 即可 valid；
  // lane i 必须自己完成、前一 lane valid，并且前一 entry 不是 trap，才能同拍继续退役。
  generate
      for (i=0; i<`NUM_RT_UOP; i++) begin : gen_rob2rt
        // retire_uop valid：严格从队头开始形成连续窗口。
          if (i==0) begin : gen_0
            assign rd_valid_rob2rt[0] = uop_valid_rob2rt[0] & (uop_done[wind_uop_rptr[0]]|trap_flag[wind_uop_rptr[i]]);
          end else begin : gen_i
            assign rd_valid_rob2rt[i] = uop_valid_rob2rt[i] & uop_done[wind_uop_rptr[i]] & rd_valid_rob2rt[i-1] & ~trap_flag[wind_uop_rptr[i]-1'b1];
          end
        // retire_uop data：元信息来自 uop FIFO，结果来自 res_mem，trap_flag 单独旁路。
        `ifdef TB_SUPPORT          
          assign rd_rob2rt[i].uop_pc          = uop_rob2rt[i].uop_pc;
          assign rd_rob2rt[i].last_uop_valid  = uop_rob2rt[i].last_uop_valid;
        `endif          
          assign rd_rob2rt[i].w_valid         = res_mem[wind_uop_rptr[i]].w_valid & uop_done[wind_uop_rptr[i]];
          assign rd_rob2rt[i].w_index         = uop_rob2rt[i].w_index;
          assign rd_rob2rt[i].w_data          = res_mem[wind_uop_rptr[i]].w_data;
          assign rd_rob2rt[i].w_type          = uop_rob2rt[i].w_type;
          assign rd_rob2rt[i].vd_type         = uop_rob2rt[i].byte_type;
          assign rd_rob2rt[i].trap_flag       = trap_flag[wind_uop_rptr[i]];  //传出trap
          assign rd_rob2rt[i].vector_csr      = uop_rob2rt[i].vector_csr;
          assign rd_rob2rt[i].vxsaturate      = res_mem[wind_uop_rptr[i]].vsaturate;
        `ifdef ZVE32F_ON
          assign rd_rob2rt[i].fpexp           = res_mem[wind_uop_rptr[i]].fpexp;
        `endif
      end
  endgenerate

  assign rob_entry_rob2rt = uop_rptr;
  
  // trap 处理与 flush：
  // 当队头 trap 被 Retire ready 接收时，trap_in 拉高；trap_flush_rvv 持续两拍，用于清空 ROB/RS/流水状态。
  assign trap_in = uop_valid_rob2rt[0] & rd_rob2rt[0].trap_flag & rd_ready_rt2rob[0];
  edff trap_ready (.q(trap_ready_rvv2rvs), .d(trap_in&(!trap_ready_rvv2rvs)), .e(1'b1), .clk(clk), .rst_n(rst_n));
  assign trap_flush_rvv = trap_in||trap_ready_rvv2rvs; // flush 持续 2 个 cycle。

  // 按程序顺序旁路 ROB 状态给 Dispatch：
  // valid 来自 entry_valid，w_valid/w_data 来自已完成结果；Dispatch 可据此做源操作数转发或 RAW 检查。
  generate
      for (i=0; i<`ROB_DEPTH; i++) begin : gen_rob2dp
        `ifdef TB_SUPPORT
          assign uop_rob2dp[i].uop_pc  = uop_info[i].uop_pc;
        `endif
          assign uop_rob2dp[i].valid   = entry_valid[i];  //暴露fifo所有数据entry_vlid
          assign uop_rob2dp[i].w_valid = res_mem[wind_uop_rptr[i]].w_valid & uop_done[wind_uop_rptr[i]];  //写回数据旁路
          assign uop_rob2dp[i].w_index = uop_info[i].w_index;
          assign uop_rob2dp[i].w_type  = uop_info[i].w_type;
          assign uop_rob2dp[i].w_data  = res_mem[wind_uop_rptr[i]].w_data;
          assign uop_rob2dp[i].byte_type = uop_info[i].byte_type;
          assign uop_rob2dp[i].vector_csr = uop_info[i].vector_csr;
      end
  endgenerate
  
endmodule
