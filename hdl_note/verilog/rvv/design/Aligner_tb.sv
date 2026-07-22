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

`ifndef ALIGNER_TB_N
`define ALIGNER_TB_N 4
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`Aligner_tb` -> 验证层：testbench，不属于综合主数据通路。
// - 接口与数据流：
//   * 该文件是局部子模块；主要接口含义可结合上层实例名和结构体类型阅读。
// - 调用关系：目录内未找到上层；下层 Aligner(dut)
// - define/参数阅读重点：
//   * `ALIGNER_TB_N`：未在 design 头文件中定义；testbench 本地/编译宏。
// - 不确定/条件宏提示：
//   * `ALIGNER_TB_N` 不在 design 头文件里定义，需要从 testbench 编译参数确认。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module Aligner_tb();
  localparam N = `ALIGNER_TB_N;
  localparam ITERATIONS = 100;
  typedef logic[31:0] MyInt;

  logic valid_in[N-1:0];
  MyInt [N-1:0] data_in;

  logic valid_out[N-1:0];
  MyInt [N-1:0] data_out;

  Aligner#(.T (logic [31:0]), .N (N))
  dut(
    valid_in,
    data_in,
    valid_out,
    data_out
  );

  task automatic run_random_test;
    automatic logic [3:0] outIdx = 0;
    for (int it = 0; it < ITERATIONS; it++) begin
      $display("*** RVVFrontEnd_tb iteration ", it, " ***");
      for (int i = 0; i < N; i++) begin
        valid_in[i] = $urandom_range(0, 1);
        data_in[i] = $urandom;
      end

      #1

      for (int o = 0; o < N; o++) begin
        if (valid_out[o] != (o < $countones(valid_in))) begin
          $error("valid_out o=", 0, " was set incorrectly. valid_in=",
                  valid_in);
        end
      end

      outIdx = 0;
      for (int i = 0; i < N; i++) begin
        if (valid_in[i] == 1) begin
          if (data_in[i] != data_out[outIdx]) begin
            $error("Bad data_out, expected ", data_in[i], " got ",
                    data_out[outIdx]);
          end
          outIdx = outIdx + 1;
        end
      end
    end

    $finish;
  endtask

  initial
    begin: initialize_all_signals
      $display("*** RVVFrontEnd_tb test begin ***");
      $display("Testing N=", N);
      run_random_test;
    end

  final
    begin
      $display("*** Test finished ***");
    end

endmodule
