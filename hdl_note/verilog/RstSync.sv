// ============================================================================
// RstSync.sv — 复位同步器 Verilog 实现 (2级FF, 异步复位同步释放)
// ============================================================================
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

// ============================================================================
// RstSync.sv — 复位同步器 (异步复位, 同步释放)
//
// 原理: 将外部异步复位信号通过移位寄存器同步到内部时钟域,
//       实现"异步生效、同步释放", 避免复位释放时的亚稳态。
//
// 两级延迟:
//   RST_DELAY = 2 — 复位同步级数 (≥2 保证亚稳态消除)
//   CLK_DELAY = 2 — 时钟使能额外延迟 (复位期间禁止时钟, 防止时钟/复位竞争)
//
// 时钟门控: 复位期间通过 icg(ClockGate) 关闭输出时钟 clk_o,
//           复位释放且 RST+CLK 延迟都完成后才恢复时钟。
//
// 结构:
//   rstn_i ──→ [移位寄存器 rst_delay_reg] ──→ rstn_o (同步释放)
//                               │
//   clk_en ─────────────────────┤──→ clk_en_int ──→ ClockGate ──→ clk_o
// ============================================================================
module RstSync
    (
        input  clk_i,          // 输入时钟
        input  rstn_i,         // 输入异步复位 (低有效)
        input  clk_en,         // 功能时钟使能 (clk_o 仅在 clk_en=1 且已退出复位时有效)
        input  te,             // 测试使能 (te=1 时旁路时钟门控, 直通时钟)
        output clk_o,          // 输出时钟 (门控后)
        output rstn_o          // 输出复位 (低有效, 同步释放)
    );

  // 复位延迟 (≥2 消除亚稳态) 和时钟延迟
  localparam RST_DELAY = 2;                                  // rstn_o 使用的抽头位置
  localparam CLK_DELAY = 2;                                  // clk_en_int 的额外延迟级数

  // 移位寄存器: 共 (RST_DELAY + CLK_DELAY) 级
  //   低  RST_DELAY 级: 用于 rstn_o 同步释放
  //   高  CLK_DELAY 级: 用于时钟使能的额外延迟
  // RST_DELAY 管复位信号本身的同步，CLK_DELAY 管时钟门控的稳定。两者加起来 4 拍后，Core 安全启动。
  logic [RST_DELAY + CLK_DELAY - 1 : 0] rst_delay_reg;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i)
      rst_delay_reg <= '0;                                   // 异步复位: 全 0 (立即生效)
    else
      // 同步释放: 每个时钟周期从低位向高位灌入 1
      rst_delay_reg <= {rst_delay_reg[RST_DELAY + CLK_DELAY - 2 : 0], 1'b1};
  end

  // rstn_o 从第 RST_DELAY 级抽头 (延迟 RST_DELAY 拍后释放)
  assign rstn_o = rst_delay_reg[RST_DELAY - 1];

  // 内部时钟使能: clk_en=1 且 所有延迟级都已完成 (全1)
  // 确保复位完全释放后才恢复时钟, 防止时钟沿与复位释放竞争
  logic clk_en_int;
  assign clk_en_int = clk_en & rst_delay_reg[CLK_DELAY + RST_DELAY - 1];

  // 实例化时钟门控: clk_en_int=1 时输出时钟, 否则关断
  ClockGate icg(.clk_i(clk_i),
                .enable(clk_en_int),
                .te(te),
                .clk_o(clk_o));

  // 仿真断言: 确保延迟参数合法
`ifndef SYNTHESIS
  initial begin
    assert (RST_DELAY >= 2);                                 // 至少 2 级才能消除亚稳态
    assert (CLK_DELAY >= 2);                                 // 至少 2 级时钟延迟
  end
`endif
endmodule
