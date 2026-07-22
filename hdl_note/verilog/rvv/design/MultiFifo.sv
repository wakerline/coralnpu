// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// MultiFifo 是一个简单的多入队/多出队循环 FIFO。
//
// 注意：
//   - valid_in 不是每 lane 一个 bit 的 valid mask，而是“本拍要入队多少个元素”；
//   - ready_out 也不是 ready mask，而是“本拍消费者要出队多少个元素”；
//   - data_in[0 .. valid_in-1] 会被顺序写入 FIFO；
//   - data_out[0 .. ready_out-1] 是本拍消费者应当读取的 FIFO 头部元素；
//   - 调用方必须保证 valid_in <= 空闲槽数，ready_out <= 已占用槽数。
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`MultiFifo` -> 通用工具模块：提供 lane 压紧或多入多出 FIFO 能力。
// - 接口与数据流：
//   * 输入：一次最多 N 个入队项和 ready_out 出队数量。
//   * 处理：用 head/tail/fill_level 维护循环 buffer。
//   * 输出：当前 fill_level 和最多 N 个低位出队项。
// - 调用关系：上层 MultiFifo_tb；无下层实例。
// - 端口摘要：输入 clk, rstn, valid_in, data_in, ready_out；输出 fill_level, data_out。
// - define/参数阅读重点：
//   * 本文件没有直接使用反引号宏。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module MultiFifo#(type T=logic [7:0],
                  // N 表示单拍最多可入队/出队的元素个数。
                  parameter N = 4,
                  // FIFO 总容量，buffer 数组深度为 MAX_CAPACITY。
                  parameter MAX_CAPACITY=16,
                  // valid_in/ready_out 需要能表示 0..N。
                  parameter INTERFACE_BITS=$clog2(N+1),
                  // head/tail/fill_level 需要能表示 0..MAX_CAPACITY。
                  parameter CAPACITYBITS=$clog2(MAX_CAPACITY+1))
(
  input clk,
  input rstn,

  // 入队端：valid_in 表示本拍 data_in 中低 valid_in 项有效。
  input logic [INTERFACE_BITS-1:0] valid_in,
  input T [N-1:0] data_in,

  // 当前 FIFO 中已经占用的元素数。
  // 上游可用它判断剩余空间：valid_in 必须 <= MAX_CAPACITY - fill_level。
  // 下游可用它判断可读元素：ready_out 必须 <= fill_level。
  output logic [CAPACITYBITS-1:0] fill_level,

  // 出队端：data_out 从 tail 开始连续给出最多 N 个队头元素。
  output T [N-1:0] data_out,
  input logic [INTERFACE_BITS-1:0] ready_out
);
  typedef logic [CAPACITYBITS-1:0] buffer_ptr_t;
  typedef logic [CAPACITYBITS-1:0] buffer_size_t;

  // FIFO 状态：
  //   head 指向下一次写入位置；
  //   tail 指向下一次读出位置；
  //   m_fill_level 记录当前已占用元素数。
  buffer_ptr_t head;  // 下一批入队元素从这里开始写。
  buffer_ptr_t tail;  // 下一批出队元素从这里开始读。
  buffer_size_t m_fill_level;
  T [MAX_CAPACITY-1:0] buffer;

  // 环绕加法：ptr + sz 超过 MAX_CAPACITY 时回到 buffer 起点。
  // 这里假设单次移动量不会超过一个 FIFO 容量，因此只减一次 MAX_CAPACITY 即可。
  function automatic buffer_ptr_t WrapAroundSum(buffer_ptr_t ptr,
                                                buffer_size_t sz);
      logic [CAPACITYBITS:0] sum;
      sum = ptr + sz;
      return (sum >= MAX_CAPACITY) ? (sum - MAX_CAPACITY) : sum;
  endfunction

  // 对外暴露当前占用量，便于上下游做容量判断。
  always_comb begin
    fill_level = m_fill_level;
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      head <= 0;
      tail <= 0;
      m_fill_level <= 0;
    end else begin
      // 入队 valid_in 个元素后，head 前进 valid_in。
      head <= WrapAroundSum(head, valid_in);
      // 出队 ready_out 个元素后，tail 前进 ready_out。
      tail <= WrapAroundSum(tail, ready_out);
      // 同一拍可同时入队和出队，占用量按差值更新。
      m_fill_level <= m_fill_level + valid_in - ready_out;
    end
  end

  always_ff @(posedge clk) begin
    // 将 data_in 的低 valid_in 项写入从 head 开始的连续槽位。
    for (int i = 0; i < N; i++) begin
      if (i < valid_in) begin
        buffer[WrapAroundSum(head, i)] <= data_in[i];
      end
    end
  end

  always_comb begin
    for (int i = 0; i < N; i++) begin
      // 从 tail 开始连续读出最多 N 项。调用方只应使用低 ready_out 项。
      data_out[i] = buffer[WrapAroundSum(tail, i)];
    end
  end

  // 仿真期协议检查：调用方不能写爆 FIFO，也不能读空 FIFO。
`ifndef SYNTHESIS
  always @(posedge clk) begin
    // 生产者本拍入队数量不能超过空闲槽数。
    assert (valid_in <= (MAX_CAPACITY - m_fill_level)) else
        $error("Trying to enqueue ", valid_in, " elements ",
               (MAX_CAPACITY - m_fill_level), " free");

    // 消费者本拍出队数量不能超过已占用槽数。
    assert (ready_out <= m_fill_level) else
        $error("Trying to dequeue ", ready_out, " elements ", m_fill_level,
               " free");
  end
`endif  // not def SYNTHESIS

endmodule
