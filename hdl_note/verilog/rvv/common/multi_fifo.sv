// multi_fifo 是 RVV 后端大量使用的同步多端口 FIFO。
//
// 主要特性：
//   1. 一拍可以 push 多个元素，push[M-1:0] 是每个 push lane 的 valid bit；
//   2. 一拍可以 pop 多个元素，pop[N-1:0] 是每个 pop lane 的 valid bit；
//   3. M 和 N 可独立参数化，push 宽度和 pop 宽度不要求相同；
//   4. fifo_data 会按 rptr 为起点重新排序导出全部 FIFO 内容，便于调试/旁路观察；
//   5. wptr/rptr/entry_count 对外可见，供上层判断容量和定位 entry。
//
// 使用约束：
//   - 默认 FULL_PUSH=0 时，FIFO 已满不能同拍 push，即使本拍也有 pop；
//   - FULL_PUSH=1 时，容量判断会先扣除本拍 pop_count，从而允许满 FIFO 同拍 pop+push；
//   - CHAOS_PUSH=0 时，上层应保持 push 从低 lane 开始连续；
//   - CHAOS_PUSH=1 时，本模块会把不连续 push 压紧成 push_seq/datain_seq 后写入。

// 结构：
// push[M] / datain[M]
//         ↓
//    多路入队压紧/计数
//         ↓
//   mem[DEPTH] 环形 FIFO
//         ↓
//    多路出队/可选寄存输出
//         ↓
// dataout[N] / pop[N]
module multi_fifo
(
  // global
  clk,
  rst_n,
  // push side
  push,
  datain,
  full,
  almost_full,
  // pop side
  pop,
  dataout,
  empty,
  almost_empty,
  // fifo info
  clear,
  fifo_data,
  wptr,
  rptr,
  entry_count
);
// ---parameter definition--------------------------------------------
  parameter type T      = logic [7:0];  // FIFO 中单个 entry 的数据类型。
  parameter M           = 4;            // push lane 数，即 push/datain 宽度。
  parameter N           = 4;            // pop lane 数，即 pop/dataout 宽度。
  parameter DEPTH       = 16;           // FIFO 深度。
  parameter POP_CLEAR   = 1'b0;         // pop 后是否把对应 mem entry 清 0，主要用于调试/可视化。
  parameter ASYNC_RSTN  = 1'b0;         // 是否对 mem/dataout 使用异步低有效复位。
  parameter CHAOS_PUSH  = 1'b0;         // 是否支持不连续 push，例如 push=4'b1010。
  parameter DATAOUT_REG = 1'b0;         // dataout 是否打一拍寄存输出。
  parameter FULL_PUSH   = 1'b0;         // FIFO 满时是否允许同拍 pop 腾空间后 push。

  localparam DEPTH_BITS = $clog2(DEPTH);

// ---port definition-------------------------------------------------
  input   logic                   clk;
  input   logic                   rst_n;
  input   logic [M-1:0]           push;         // push bitmask：push[i]=1 表示 datain[i] 本拍入队。
  input   T     [M-1:0]           datain;
  output  logic                   full;
  output  logic [M-1:0]           almost_full;  // almost_full[0]=1 表示 full。
                                                // almost_full[1]=1 表示空闲槽 <= 1。
                                                // almost_full[M-1]=1 表示空闲槽 <= M-1。
  input   logic [N-1:0]           pop;          // pop bitmask：pop[i]=1 表示 dataout[i] 本拍出队。
  output  T     [N-1:0]           dataout;
  output  logic                   empty;
  output  logic [N-1:0]           almost_empty; // almost_empty[0]=1 表示 empty。
                                                // almost_empty[1]=1 表示有效数据数 <= 1。
                                                // almost_empty[N-1]=1 表示有效数据数 <= N-1。
  input   logic                   clear;
  output  T     [DEPTH-1:0]       fifo_data;    // 以 rptr 为起点顺序展开的 FIFO 内容。主要用于调试和旁路观察。
  output  logic [DEPTH_BITS-1:0]  wptr;         // 写指针，指向下一次写入位置。
  output  logic [DEPTH_BITS-1:0]  rptr;         // 读指针，指向下一次读出位置。
  output  logic [DEPTH_BITS  :0]  entry_count;  // 当前已占用 entry 数，范围 0..DEPTH。

// ---internal signal definition--------------------------------------
  T mem[DEPTH-1:0];

  logic                           entry_count_en; 
  logic         [DEPTH_BITS  :0]  entry_count_now;
  logic         [DEPTH_BITS  :0]  next_entry_count;
  logic         [DEPTH_BITS  :0]  push_count;
  logic         [DEPTH_BITS  :0]  pop_count;
  logic         [DEPTH_BITS-1:0]  next_wptr;
  logic         [DEPTH_BITS-1:0]  next_rptr;
  logic         [DEPTH_BITS-1:0]  wind_rptr [DEPTH-1:0];
  logic         [DEPTH_BITS-1:0]  wind_wptr [DEPTH-1:0];

  logic         [M-1:0]           push_seq;      // CHAOS_PUSH 后压紧得到的连续 push。
  T             [M-1:0]           datain_seq;    // 与 push_seq 对齐后的入队数据。
  logic         [DEPTH_BITS:0]    ptr_diff1;
  logic         [DEPTH_BITS:0]    ptr_diff2;
  logic         [DEPTH_BITS-1:0]  offset;
  logic         [DEPTH-1:0]       push_extend;
  logic         [2*DEPTH-1:0]     pop_shift;
  logic         [DEPTH-1:0]       pop_extend;
// ---code start------------------------------------------------------
  genvar  i;  
  integer l,k;
  
  // FIFO 状态：根据本拍 push/pop 数量更新已占用 entry 数。
  assign next_entry_count = entry_count + push_count - pop_count;
  assign entry_count_en = (|push) | (|pop);
  cdffr #(.T(logic[DEPTH_BITS:0])) u_entry_count_reg (.q(entry_count), .c(clear), .e(entry_count_en), .d(next_entry_count), .clk(clk), .rst_n(rst_n));

  //基于上一拍的结果计算full/almost_full/empty/almost_empty，避免组合路径过长。
  generate
  // full/almost_full 计算。
  // FULL_PUSH=1 时先扣掉本拍 pop_count，再判断是否还有空间给 push。
    if(FULL_PUSH) 
      assign entry_count_now = entry_count - pop_count;
    else
      assign entry_count_now = entry_count;
    // | 信号               | 含义         |
    // | ---------------- | ---------- |
    // | `almost_full[0]` | 没有空位       |
    // | `almost_full[1]` | 最多只能再收 1 条 |
    // | `almost_full[2]` | 最多只能再收 2 条 |
    // | `almost_full[3]` | 最多只能再收 3 条 |
    assign full = (entry_count_now == DEPTH);  //不会大于depth，pop_count 由断言保证不会读空。
    assign almost_full[0] = full;

    for (i=1; i<M; i++) begin : gen_almost_full
      assign almost_full[i] = (entry_count_now + i >= DEPTH);
    end

  // empty/almost_empty 只基于当前 entry_count 判断，pop 时由断言保证不读空。
  // | 信号                  | 含义                         |
  // | ------------------- | -------------------------- |
  // | `almost_empty[0]`   | FIFO 为空                    |
  // | `almost_empty[1]`   | FIFO 中有效 entry 数小于等于 1     |
  // | `almost_empty[2]`   | FIFO 中有效 entry 数小于等于 2     |
  // | `almost_empty[N-1]` | FIFO 中有效 entry 数小于等于 `N-1` |
    assign empty           = (entry_count == '0);
    assign almost_empty[0] = empty;

    for (i=1; i<N; i++) begin : gen_almost_empty
      assign almost_empty[i] = (entry_count <= i);
    end

  // fifo_data 按 rptr 展开：fifo_data[0] 是当前队头，fifo_data[1] 是队头后一项。
  // 主要用于调试和旁路观察。
    for (i=0; i<DEPTH; i++) begin : gen_fifo_data
      assign fifo_data[i] = mem[wind_rptr[i]];
    end

  // 生成从 rptr/wptr 开始的环绕地址序列。
  // DEPTH 通常为 2 的幂时，位宽截断天然实现取模。
  // DEPTH = 16
  // DEPTH_BITS = 4
  // 当rptr = 14
  // wind_rptr[0] = 14
  // wind_rptr[1] = 15
  // wind_rptr[2] = 0
  // wind_rptr[3] = 1
    for (i=0; i<DEPTH; i++) begin : gen_wind_ptr
      assign wind_rptr[i] = rptr+i;  //上一拍的rptr/wptr，下一拍的rptr/wptr由pop_count/push_count更新。
      assign wind_wptr[i] = wptr+i;
    end
  endgenerate
  // pop_count 是本拍实际 pop lane 数。
  always_comb begin
    pop_count = {(DEPTH_BITS)'(0), pop[0]};
    for (int j=1; j<N; j++) pop_count = pop_count + pop[j];  // 计算本拍实际 pop lane 数
  end
  
  assign next_rptr = rptr + pop_count;  // 下一拍的读指针 = 当前 rptr + 本拍 pop lane 数
  cdffr #(.T(logic[DEPTH_BITS-1:0])) u_rptr_reg (.q(rptr), .c(clear), .e(|pop), .d(next_rptr), .clk(clk), .rst_n(rst_n));
  
  generate
    // DATAOUT_REG=1 的 dataout 是 FIFO 的“寄存化队头窗口”。
    // 本拍 pop 消费当前窗口；
    // 同一时钟沿 rptr 前移，并把 pop 后的新队头窗口装入 dataout。
    // 因此它改善时序，不一定降低稳态吞吐。
    if(DATAOUT_REG) begin
      logic [DEPTH_BITS:0]          remain_count;
      logic [N-1:0][DEPTH_BITS-1:0] current_rptr_mem;   // 从 FIFO mem 中选择输出数据。
      logic [N-1:0][DEPTH_BITS-1:0] current_rptr_psh;   // FIFO 被 pop 空后，从本拍 push 数据旁路输出。

      // remain_count 表示本拍 pop 后 FIFO 里还剩多少旧数据。
      // 如果 DATAOUT_REG=1，下拍 dataout 优先来自旧 mem；旧数据不够时使用本拍 push 的数据。
      assign remain_count = entry_count-pop_count;  //本拍 pop 后旧 FIFO 中剩下的数据数。

      for (i=0; i<N; i++) begin : gen_rptr
        assign current_rptr_mem[i] = next_rptr+i;     // dataout[i] 从 mem 中读哪个地址, 从下一拍队头开始
        assign current_rptr_psh[i] = i-remain_count;  // 如果 mem 旧数据不够，从本拍 push 数据的第几个 lane 旁路
      end

      if (ASYNC_RSTN) begin
        if (CHAOS_PUSH) begin  //支持不连续 push, 因此存在seq 压紧逻辑
          for (i=0; i<N; i++) begin : gen_dataout
            always_ff @(posedge clk, negedge rst_n) begin
              if (!rst_n)
                dataout[i] <= 'b0;
              else if ((i<remain_count)&(|pop)) //FIFO 中 pop 后剩下的第 i 个旧数据。fifo数据足够pop，直接从fifo读出
                dataout[i] <= mem[current_rptr_mem[i]]; 
              else if ((push_seq[current_rptr_psh[i]]&(current_rptr_psh[i]<(DEPTH_BITS)'(M)))&
                       ((|pop)|(|push_seq))
                      )  //fifo数据不够pop，直接本拍 push 进来的第 (i - remain_count) 个新数据
                dataout[i] <= datain_seq[current_rptr_psh[i]];
            end
          end
        end else begin  //不支持不连续 push, 因此不存在seq 压紧逻辑
          for (i=0; i<N; i++) begin : gen_dataout
            always_ff @(posedge clk, negedge rst_n) begin
              if (!rst_n)
                dataout[i] <= 'b0;
              else if ((i<remain_count)&(|pop))
                dataout[i] <= mem[current_rptr_mem[i]]; 
              else if ((push[current_rptr_psh[i]]&(current_rptr_psh[i]<(DEPTH_BITS)'(M)))&
                       ((|pop)|(|push))
                      )
                dataout[i] <= datain[current_rptr_psh[i]];
            end
          end
        end
      end 
      else begin
        if (CHAOS_PUSH) begin
          for (i=0; i<N; i++) begin : gen_dataout
            always_ff @(posedge clk) begin
              if ((i<remain_count)&(|pop)) 
                dataout[i] <= mem[current_rptr_mem[i]]; 
              else if ((push_seq[current_rptr_psh[i]]&(current_rptr_psh[i]<(DEPTH_BITS)'(M)))&
                       ((|pop)|(|push_seq))
                      )
                dataout[i] <= datain_seq[current_rptr_psh[i]];
            end
          end
        end else begin
          for (i=0; i<N; i++) begin : gen_dataout
            always_ff @(posedge clk) begin
              if ((i<remain_count)&(|pop))
                dataout[i] <= mem[current_rptr_mem[i]]; 
              else if ((push[current_rptr_psh[i]]&(current_rptr_psh[i]<(DEPTH_BITS)'(M)))&
                       ((|pop)|(|push))
                      )
                dataout[i] <= datain[current_rptr_psh[i]];
            end
          end
        end
      end
    end
    else begin
      for (i=0; i<N; i++) begin : gen_dataout
        // 组合输出模式：直接从当前 rptr 后连续读 N 项。低延迟，当前 rptr 对应的数据立即可见
        // dataout 直接依赖 mem/rptr，可能拉长组合路径
        assign dataout[i] = mem[wind_rptr[i]];
      end
    end
  endgenerate

  // push_count 是本拍实际 push lane 数。
  always_comb begin
    push_count = {(DEPTH_BITS)'(0), push[0]};
    for (int j=1; j<M; j++) push_count = push_count + push[j];
  end

  //写指针
  assign next_wptr = wptr + push_count;
  cdffr #(.T(logic[DEPTH_BITS-1:0])) u_wptr_reg (.q(wptr), .c(clear), .e(|push), .d(next_wptr), .clk(clk), .rst_n(rst_n));

  //如果系统设计已经保证 push 连续，建议 CHAOS_PUSH=0，可以减少组合逻辑。
  generate
    if (CHAOS_PUSH) begin
      always_comb begin
        push_seq = '0;
        datain_seq = '0;
        l = 0;
        for (k=0; k<M; k++) begin
          if (push[k]) begin
            // 把不连续的 push lane 压到低 lane，保持原先从低到高的相对顺序。
            push_seq[l] = 1'b1;
            datain_seq[l] = datain[k];
            l++;
          end
        end
      end
    end else begin
      // 不支持乱序 push 时，调用方需要保证 push 本身低 lane 连续。
      assign push_seq = push;
      assign datain_seq = datain;
    end

    if (POP_CLEAR&FULL_PUSH) begin
      // 满 FIFO 同拍 pop+push 且需要 pop 清零时，pop 地址要换算到 wptr 视角，
      // 避免同一 mem entry 同拍既写入新数据又被旧 pop 清零。
      assign ptr_diff1 = {1'b0,rptr} - {1'b0,wptr};  // 计算 pop 地址相对于 wptr 的偏移量，不考虑 rptr/wptr 环绕的情况。
      assign ptr_diff2 = {1'b1,rptr} - {1'b0,wptr};  // 计算 pop 地址相对于 wptr 的偏移量，考虑 rptr/wptr 环绕的情况。
      //如果 ptr_diff1 是负数，就使用绕回后的 ptr_diff2。
      //从 wptr 开始数，数多少个位置能到 rptr。
      //ptr_diff1<0,最高位为1，说明rptr在wptr前面，绕回后才能到达rptr。
      //offset 是 pop 地址相对于 wptr 的偏移量，范围 0..DEPTH-1。
      assign offset    = ptr_diff1[DEPTH_BITS] ? ptr_diff2[DEPTH_BITS-1:0] : ptr_diff1[DEPTH_BITS-1:0];  // 计算 pop 地址相对于 wptr 的偏移量
      
      //把 pop bitmask 转换到以 wptr 为基准的空间中。
      assign push_extend = (DEPTH)'(push_seq);  // 将 push_seq 扩展到 DEPTH 位
      //pop[0] 清的是 wptr+offset
      //pop[1] 清的是 wptr+offset+1
      //...
      //环形移位器
      assign pop_shift   = {(DEPTH)'(pop),(DEPTH)'(pop)}<<offset;  // 将 pop 扩展到 2*DEPTH 位后左移 offset 位
      //从 wptr 视角看，第 j 个位置是否被 pop 清零。
      assign pop_extend  = pop_shift[2*DEPTH-1:DEPTH];  // 取出左移后的高 DEPTH 位作为 pop_extend
    end

    if (ASYNC_RSTN)
      if (POP_CLEAR&FULL_PUSH) begin //带异步复位，且要处理满 FIFO 同拍 pop+push。
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            for (int j=0; j<DEPTH; j++) begin
              mem[j] <= '0;
            end
          else if (clear)
            for (int j=0; j<DEPTH; j++) begin
              mem[j] <= '0;
            end
          else begin
            for (int j=0; j<DEPTH; j++) begin
              // push 优先写入新数据；没有被 push 覆盖且被 pop 的 entry 清 0。
              if (push_extend[j] & (j<M))   //写入新数据
                mem[wind_wptr[j]] <= datain_seq[j];
              else if (pop_extend[j])       //清零旧数据
                mem[wind_wptr[j]] <= 'b0;
            end
          end
        end
      end 
      else if(POP_CLEAR) begin  //普通 pop 清零模式。
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            for (int j=0; j<DEPTH; j++) begin 
              mem[j] <= '0;
            end
          else if (clear)
            for (int j=0; j<DEPTH; j++) begin
              mem[j] <= '0;
            end
          else begin
            for (int j=0; j<M; j++) begin
              // 普通写入路径：把压紧后的 push_seq 写到从 wptr 开始的连续位置。
              if (push_seq[j]) mem[wind_wptr[j]] <= datain_seq[j];
            end
  
            for (int j=0; j<N; j++) begin
              // POP_CLEAR=1 时，被读出的旧 entry 清 0，便于波形观察和避免旧值残留。
              if (pop[j]) mem[wind_rptr[j]] <= '0;
            end
          end
        end
      end
      else begin
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            for (int j=0; j<DEPTH; j++) begin
              mem[j] <= '0;
            end
          else begin
            for (int j=0; j<M; j++) begin
              // POP_CLEAR=0 时，pop 不清 mem；entry_count/rptr 才是判断有效性的依据。
              if (push_seq[j]) mem[wind_wptr[j]] <= datain_seq[j];
            end
          end
        end
      end
    else begin
      if (POP_CLEAR&FULL_PUSH) begin
        always_ff @(posedge clk) begin
          if (clear)
            for (int j=0; j<DEPTH; j++) begin
              mem[j] <= '0;
            end
          else begin
            for (int j=0; j<DEPTH; j++) begin
              if (push_extend[j] & (j<M)) 
                mem[wind_wptr[j]] <= datain_seq[j];
              else if (pop_extend[j])
                mem[wind_wptr[j]] <= 'b0;
            end
          end
        end
      end 
      else if(POP_CLEAR) begin
        always_ff @(posedge clk) begin
          if (clear)
            for (int j=0; j<DEPTH; j++) begin
              mem[j] <= '0;
            end
          else begin
            for (int j=0; j<M; j++) begin
              if (push_seq[j]) mem[wind_wptr[j]] <= datain_seq[j];
            end
  
            for (int j=0; j<N; j++) begin
              if (pop[j]) mem[wind_rptr[j]] <= '0;
            end
          end
        end
      end
      else begin
        always_ff @(posedge clk) begin
          for (int j=0; j<M; j++) begin
            if (push_seq[j]) mem[wind_wptr[j]] <= datain_seq[j];
          end
        end
      end
    end
  endgenerate

  `ifdef ASSERT_ON
    // overflow 检查：FULL_PUSH=0 时，如果 almost_full[i] 已经表示不足以接收第 i 项，
    // push_seq[i] 仍为 1 就说明上游写爆 FIFO。
      generate
        if(!FULL_PUSH) begin
          for (i=0; i<M; i++) begin
            assert property (@(posedge clk) disable iff (!rst_n) not ( push_seq[i] && almost_full[i]))
              else $error("MULTI_FIFO: overflow of fifo when push_seq[%d] and almost_full[%d]", i, i);
          end
        end
      endgenerate
    // underflow 检查：almost_empty[i] 表示 FIFO 中不足以弹出第 i 项，
    // pop[i] 仍为 1 就说明下游读空 FIFO。
      generate
        for (i=0; i<N; i++) begin
          assert property (@(posedge clk) disable iff (!rst_n) not ( pop[i] && almost_empty[i]))
            else $error("MULTI_FIFO: underflow of fifo when pop[%d] and almost_empty[%d]", i, i);
        end
      endgenerate
  `endif

endmodule
