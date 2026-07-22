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

// Aligner 是一个组合逻辑 lane 压紧模块：
//   - 输入 valid/data 可以有空洞，例如 [0, 1, 0, 1]；
//   - 输出会把有效项按原相对顺序移动到低 lane，例如 [1, 1, 0, 0]；
//   - data_out 只保证 valid_out=1 的 lane 有意义，invalid lane 的数据为 don't care。
//
// 示例：
//   valid_in  = [0, 1, 0, 1], data_in  = [A, B, C, D]
//   valid_out = [1, 1, 0, 0], data_out = [B, D, X, X]
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`Aligner` -> 通用工具模块：提供 lane 压紧或多入多出 FIFO 能力。
// - 接口与数据流：
//   * 输入：N lane valid/data。
//   * 处理：统计前缀 valid，将有效项压到低 lane。
//   * 输出：低 lane 连续的 valid/data，便于后端只处理连续发射。
// - 调用关系：上层 Aligner_tb, RvvFrontEnd；无下层实例。
// - 端口摘要：输入 valid_in, data_in；输出 valid_out, data_out。
// - define/参数阅读重点：
//   * 本文件没有直接使用反引号宏。
// - 不确定/条件宏提示：
//   * 本文件使用的宏要么是固定常量，要么已在上方主要宏列表中说明。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module Aligner#(type T=logic [7:0], parameter N = 8)
(
  // 输入 lane：每个 lane 一份 valid 和 data。
  input logic [N-1:0] valid_in,
  input T [N-1:0] data_in,

  // 输出 lane：所有有效项被压到低 lane，保持输入中的先后顺序。
  output logic [N-1:0] valid_out,
  output T [N-1:0] data_out
);
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
  localparam COUNTBITS = $clog2(N);
  typedef logic [COUNTBITS-1:0] count_t;

  // valid_count[i] 表示输入 lane i 前面有多少个有效 lane。
  // 如果 valid_in[i]=1，那么该输入项应该被放到 output lane valid_count[i]。
  count_t valid_count [N-1:0];
  always_comb begin
    valid_count[0] = 0;
    for (int i = 0; i < N-1; i++) begin
        valid_count[i+1] = valid_count[i] + valid_in[i];
    end
  end

  logic [N-1:0][N-1:0] output_valid_map;
  count_t valid_idx [N-1:0];
  always_comb begin
    
    for (int o = 0; o < N; o++) begin  //0~3开始计算有效输出
      valid_idx[o] = 0;
      for (int i = 0; i < N; i++) begin  //对于第o输出，计算有效输入
        // output_valid_map[o][i]=1 表示输入 i 是第 o 个有效项，
        // 因此需要被送到输出 lane o。
        output_valid_map[o][i] = (valid_count[i] == o) && valid_in[i];  //如果只有0、1有效，对于o=2、3就不会有效
        // 找到输出 lane o 对应的输入索引。由于每个 o 最多匹配一个有效输入，
        // 这里用 OR 累积索引即可。
        valid_idx[o] = valid_idx[o] | (output_valid_map[o][i] ? i : 0);  //输出有效输入i
      end

      // 只要存在输入映射到 output lane o，该输出 lane 就有效。
      valid_out[o] = |output_valid_map[o];
      // invalid 输出 lane 的 data_out 不使用，可视为 don't care。
      data_out[o] = data_in[valid_idx[o]];
    end
  end
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */

endmodule
