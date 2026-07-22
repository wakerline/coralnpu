// 说明：下面两段 64bit viota 实现目前被注释掉，仅作为历史/备选结构保留。
// 当前实际使用的 active module 是 viota32/viota7/viota4。
// module rvv_backend_alu_unit_mask_viota64
//(
//  source,
//  result_viota64
//);
//  input  logic  [63:0]                source;
//  output logic  [63:0][$clog2(64):0]  result_viota64;
//
//  logic [1:0][31:0][$clog2(32):0]     result_viota32;
//
//  genvar                              j;
//  
//  // 计算
//  generate
//    for(j=0;j<2;j++) begin: GET_VIOTA32
//      rvv_backend_alu_unit_mask_viota32
//      u_viota32
//      (
//        .source         (source[32*j +: 32]),
//        .result_viota32 (result_viota32[j])
//      );
//    end
//    
//    for(j=0;j<32;j++) begin: GET_VIOTA64
//      assign result_viota64[j] = result_viota32[0][j];
//      assign result_viota64[j+32] = result_viota32[1][j]+result_viota32[0][31];
//    end
//  endgenerate
//
//endmodule
 
//
//  另一种基于 viota16 的 viota64 备选实现
//

// module rvv_backend_alu_unit_mask_viota64
// (
//   source,
//   result_viota64
// );
//   input  logic  [63:0]                source;
//   output logic  [63:0][$clog2(64):0]  result_viota64;
// 
//   logic [3:0][15:0][$clog2(16):0]     result_viota16;
//   logic      [15:0][$clog2(16):0]     sum_47to32;
//   logic      [15:0][$clog2(16):0]     carry_47to32;
//   logic      [15:0][$clog2(16):0]     sum_63to48;
//   logic      [15:0][$clog2(16):0]     carry_63to48;
//   logic      [15:0][$clog2(16):0]     cout_63to48;
// 
//   genvar                              j;
//   
//   // 计算
//   generate
//     for(j=0;j<4;j++) begin: GET_VIOTA16
//       rvv_backend_alu_unit_mask_viota16
//       u_viota16
//       (
//         .source         (source[16*j +: 16]),
//         .result_viota16 (result_viota16[j])
//       );
//     end
//     
//     for(j=0;j<16;j++) begin: GET_VIOTA64
//       assign result_viota64[j] = result_viota16[0][j];
//       assign result_viota64[j+16] = result_viota16[1][j]+result_viota16[0][15];
//       assign result_viota64[j+32] = sum_47to32[j]+{carry_47to32[j],1'b0};
//       assign result_viota64[j+48] = sum_63to48[j]+{({1'b0,carry_63to48[j]}+{1'b0,cout_63to48[j]}),1'b0};
// 
//       compressor_3_2
//       #(
//         .WIDTH  ($clog2(16)+1)
//       )
//       viota64_47to32
//       (
//         .src1         (result_viota16[0][15]),
//         .src2         (result_viota16[1][15]),
//         .src3         (result_viota16[2][j]),
//         .result_sum   (sum_47to32[j]),
//         .result_carry (carry_47to32[j])
//       );
// 
//       compressor_4_2
//       #(
//         .WIDTH  ($clog2(16)+1)
//       )
//       viota64_63to48
//       (
//         .src1         (result_viota16[0][15]),
//         .src2         (result_viota16[1][15]),
//         .src3         (result_viota16[2][15]),
//         .src4         (result_viota16[3][j]),
//         .cin          ('0),
//         .result_sum   (sum_63to48[j]),
//         .result_carry (carry_63to48[j]),
//         .result_cout  (cout_63to48[j])
//       );
//     end
//   endgenerate
// 
// endmodule
// 功能说明：
// 1. 本文件实现 VIOTA 类 mask 前缀计数辅助逻辑。
// 2. 对输入 mask `source`，输出 `result_viotaN[i]` 表示 source[0:i] 中置位 bit 的个数。
// 3. 该结果可用于 viota.m：每个元素位置得到它之前/截至当前 mask bit 的累计计数，再由上层组合成索引向量。
// 4. 当前 active 结构包含 32bit、7bit、4bit 三个组合模块，无时序寄存器。
//
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_alu_unit_mask_viota*` -> RVV 后端 EX/ALU mask 路径的组合辅助计数树。
// - 接口与数据流：
//   * 输入：`source` 是待做前缀 popcount 的 mask bit 向量。
//   * 处理：小宽度模块直接查表，大宽度模块把低位分段结果加到高位分段，形成全局前缀计数。
//   * 输出：`result_viota4/7/32`，每个元素都是对应 bit 位置的累计置位数。
// - 调用关系：`viota32` 调用 4 个 `viota7` 和 1 个 `viota4`；`viota7` 调用 1 个 `viota4`；`viota4` 无下层实例。
// - 端口摘要：输入 source；输出 result_viota32, result_viota7, result_viota4。
// - 结构说明：
//   * `viota4`：直接枚举 1/2/3/4 bit 前缀的 popcount。
//   * `viota7`：低 4 bit 复用 viota4，高 3 bit 在 viota4[3] 基础上加 source[4:6] 的局部计数。
//   * `viota32`：把 32 bit 拆成 7+7+7+7+4，用 compressor_3_2/4_2 汇总前面分段的总数，减少加法链深度。
// - define/参数阅读重点：
//   * 本文件没有直接使用反引号宏；宽度由常量 4/7/32 与 `$clog2()` 推导。
// - 阅读建议：先看 `viota4` 的“前缀 popcount”定义，再回看 `viota7/viota32` 如何把分段前缀计数平移到全局坐标。
// 详细中文注释（自动梳理）END

module rvv_backend_alu_unit_mask_viota32
(
  source,
  result_viota32
);

  input  logic [31:0]               source;         // 32bit mask 输入。
  output logic [31:0][$clog2(32):0] result_viota32; // 每个 bit 位置对应的 source[0:i] popcount。
  
  // 32bit 被分成 4 个 7bit 块和最高 4bit 块。
  logic [3:0][6:0][2:0]             result_viota7;  // 每个 7bit 分段内部的前缀 popcount。
  logic      [6:0][2:0]             sum_20to14;     // 第 14..20 bit：前两个 7bit 总数 + 第三个块局部计数。
  logic      [6:0][2:0]             carry_20to14;
  logic      [6:0][2:0]             sum_27to21;     // 第 21..27 bit：前三个 7bit 总数 + 第四个块局部计数。
  logic      [6:0][2:0]             carry_27to21;
  logic      [6:0][2:0]             cout_27to21;
  logic      [3:0][2:0]             result_viota4;  // 最高 4bit 块内部前缀 popcount。
  logic      [3:0][2:0]             sum_31to28;     // 第 28..31 bit：前四个 7bit 总数 + 最高 4bit 局部计数。
  logic      [3:0][2:0]             carry_31to28;
  logic      [3:0][2:0]             cout_31to28;
  
  genvar                            j;

  // 先计算低 28bit 的 4 个 7bit 分段内部前缀计数。
  generate
    for(j=0;j<4;j++) begin: GET_VIOTA7_FOR_27_0_BIT
      rvv_backend_alu_unit_mask_viota7
      u_viota7
      (
        .source(source[j*7 +: 7]),
        .result_viota7(result_viota7[j])
      );
    end
  endgenerate

  rvv_backend_alu_unit_mask_viota4
  u_viota4
  (
    .source(source[31:28]),
    .result_viota4(result_viota4)
  );

  generate
    for(j=0;j<7;j++) begin: GET_VIOTA32_27_0
      // bit[0:6] 直接使用第 0 个 7bit 块的局部计数。
      assign result_viota32[j] = ($clog2(32)+1)'(result_viota7[0][j]);
      // bit[7:13] = 第 1 个 7bit 局部计数 + 第 0 块总置位数。
      assign result_viota32[j+7] = ($clog2(32)+1)'(result_viota7[1][j])+($clog2(32)+1)'(result_viota7[0][6]);
      // bit[14:20] 和 bit[21:27] 用 compressor 汇总前序分段总数，减少长加法路径。
      assign result_viota32[j+14] = ($clog2(32)+1)'(sum_20to14[j])+($clog2(32)+1)'({carry_20to14[j],1'b0});
      assign result_viota32[j+21] = ($clog2(32)+1)'(sum_27to21[j])+($clog2(32)+1)'({({1'b0,carry_27to21[j]})+($clog2(32)+1)'({1'b0,cout_27to21[j]}),1'b0});


      compressor_3_2
      #(
        .WIDTH        (3)
      )
      viota32_20to14
      (
        .src1         (result_viota7[0][6]),
        .src2         (result_viota7[1][6]),
        .src3         (result_viota7[2][j]),
        .result_sum   (sum_20to14[j]),
        .result_carry (carry_20to14[j])
      );
      
      compressor_4_2
      #(
        .WIDTH        (3)
      )
      viota32_27to21
      (
        .src1         (result_viota7[0][6]),
        .src2         (result_viota7[1][6]),
        .src3         (result_viota7[2][6]),
        .src4         (result_viota7[3][j]),
        .cin          ('0),
        .result_sum   (sum_27to21[j]),
        .result_carry (carry_27to21[j]),
        .result_cout  (cout_27to21[j])
      );
    end

    for(j=0;j<4;j++) begin: GET_VIOTA32_31_28
      // bit[28:31] = 前 28bit 总置位数 + 最高 4bit 块局部前缀计数。
      assign result_viota32[j+28] = ($clog2(32)+1)'(sum_31to28[j])+
                                    ($clog2(32)+1)'({({1'b0,carry_31to28[j]})+
                                    ($clog2(32)+1)'({1'b0,cout_31to28[j]}),1'b0});

      compressor_4_2
      #(
        .WIDTH        (3)
      )
      viota32_31to28
      (
        .src1         (result_viota7[0][6]),
        .src2         (result_viota7[1][6]),
        .src3         (result_viota7[2][6]),
        .src4         (result_viota7[3][6]),
        .cin          (result_viota4[j]),
        .result_sum   (sum_31to28[j]),
        .result_carry (carry_31to28[j]),
        .result_cout  (cout_31to28[j])
      );
    end
  endgenerate
  
endmodule

// module rvv_backend_alu_unit_mask_viota16
// (
//   source,
//   result_viota16
// );
//   input  logic  [15:0]               source;
//   output logic  [15:0][$clog2(16):0] result_viota16;
// 
//   logic [3:0][3:0][$clog2(4):0]      result_viota4;
//   logic      [3:0][$clog2(4):0]      sum_11to8;
//   logic      [3:0][$clog2(4):0]      carry_11to8;
//   logic      [3:0][$clog2(4):0]      sum_15to12;
//   logic      [3:0][$clog2(4):0]      carry_15to12;
//   logic      [3:0][$clog2(4):0]      cout_15to12;
// 
//   genvar                             j;
//   
//   // 计算
//   generate
//     for(j=0;j<4;j++) begin: GET_VIOTA4
//       rvv_backend_alu_unit_mask_viota4
//       u_viota4
//       (
//         .source         (source[j*4 +: 4]),
//         .result_viota7  (result_viota4[j])
//       );
//     end
// 
//     for(j=0;j<4;j++) begin: GET_VIOTA16
//       assign result_viota16[j] = result_viota4[0][j];
//       assign result_viota16[j+4] = result_viota4[1][j]+result_viota4[0][3];
//       assign result_viota16[j+8] = sum_11to8[j]+{carry_11to8[j],1'b0};
//       assign result_viota16[j+12] = sum_15to12[j]+{({1'b0,carry_15to12[j]}+{1'b0,cout_15to12[j]}),1'b0};
// 
//       compressor_3_2
//       #(
//         .WIDTH  ($clog2(4)+1)
//       )
//       viota16_11to8
//       (
//         .src1         (result_viota4[0][3]),
//         .src2         (result_viota4[1][3]),
//         .src3         (result_viota4[2][j]),
//         .result_sum   (sum_11to8[j]),
//         .result_carry (carry_11to8[j])
//       );
// 
//       compressor_4_2
//       #(
//         .WIDTH  ($clog2(4)+1)
//       )
//       viota16_15to12
//       (
//         .src1         (result_viota4[0][3]),
//         .src2         (result_viota4[1][3]),
//         .src3         (result_viota4[2][3]),
//         .src4         (result_viota4[3][j]),
//         .cin          ('0),
//         .result_sum   (sum_15to12[j]),
//         .result_carry (carry_15to12[j]),
//         .result_cout  (cout_15to12[j])
//       );
//     end
//   endgenerate
// 
// endmodule

module rvv_backend_alu_unit_mask_viota7
(
  source,
  result_viota7
);

  input  logic [6:0]      source;        // 7bit mask 输入。
  output logic [6:0][2:0] result_viota7; // 每个 bit 位置对应的 source[0:i] popcount，最大值 7。
  
  logic [3:0][2:0]        result_viota4; // 低 4bit 的前缀 popcount。

  rvv_backend_alu_unit_mask_viota4
  u_viota4
  (
    .source(source[3:0]),
    .result_viota4(result_viota4)
  );
  
  assign result_viota7[3:0] = result_viota4;

  always_comb begin
    // 第 4 位的全局前缀计数 = 低 4bit 总数 + source[4]。
    case(source[4])
      1'b0: begin
        result_viota7[4] = result_viota4[3];
      end
      1'b1: begin
        result_viota7[4] = result_viota4[3]+1'b1;
      end
      default: begin
        result_viota7[4] = result_viota4[3];
      end
    endcase

    // 第 5 位的全局前缀计数 = 低 4bit 总数 + source[4:5] 中 1 的个数。
    case(source[5:4])
      2'b00: begin
        result_viota7[5] = result_viota4[3];
      end
      2'b01,
      2'b10: begin
        result_viota7[5] = result_viota4[3]+1'b1;
      end
      2'b11: begin
        result_viota7[5] = result_viota4[3]+2'd2;
      end
      default: begin
        result_viota7[5] = result_viota4[3];
      end
    endcase

    // 第 6 位的全局前缀计数 = 低 4bit 总数 + source[4:6] 中 1 的个数。
    case(source[6:4])
      3'b000: begin
        result_viota7[6] = result_viota4[3];
      end
      3'b001,
      3'b010,
      3'b100: begin
        result_viota7[6] = result_viota4[3]+1'b1;
      end
      3'b011,
      3'b101,
      3'b110: begin
        result_viota7[6] = result_viota4[3]+2'd2;
      end
      3'b111: begin
        result_viota7[6] = result_viota4[3]+2'd3;
      end
      default: begin
        result_viota7[6] = result_viota4[3];
      end
    endcase
  end

endmodule

module rvv_backend_alu_unit_mask_viota4
(
  source,
  result_viota4 
);

  input  logic [3:0]              source;        // 4bit mask 输入。
  output logic [3:0][$clog2(4):0] result_viota4; // 每个 bit 位置对应的 source[0:i] popcount，最大值 4。
  
  always_comb begin
    // result_viota4[0] = popcount(source[0:0])。
    case(source[0])
      1'b0: begin
        result_viota4[0] = 3'd0;
      end
      1'b1: begin
        result_viota4[0] = 3'd1;
      end
      default: begin
        result_viota4[0] = 3'd0;
      end
    endcase

    // result_viota4[1] = popcount(source[0:1])。
    case(source[1:0])
      2'b00: begin
        result_viota4[1] = 3'd0;
      end
      2'b01,
      2'b10: begin
        result_viota4[1] = 3'd1;
      end
      2'b11: begin
        result_viota4[1] = 3'd2;
      end
      default: begin
        result_viota4[1] = 3'd0;
      end
    endcase

    // result_viota4[2] = popcount(source[0:2])。
    case(source[2:0])
      3'b000: begin
        result_viota4[2] = 3'd0;
      end
      3'b001,
      3'b010,
      3'b100: begin
        result_viota4[2] = 3'd1;
      end
      3'b011,
      3'b101,
      3'b110: begin
        result_viota4[2] = 3'd2;
      end
      3'b111: begin
        result_viota4[2] = 3'd3;
      end
      default: begin
        result_viota4[2] = 3'd0;
      end
    endcase

    // result_viota4[3] = popcount(source[0:3])。
    case(source)
      4'b0000: begin
        result_viota4[3] = 3'd0;
      end
      4'b0001,
      4'b0010,
      4'b0100,
      4'b1000: begin
        result_viota4[3] = 3'd1;
      end
      4'b0011,
      4'b0101,
      4'b1001,
      4'b0110,
      4'b1010,
      4'b1100: begin
        result_viota4[3] = 3'd2;
      end
      4'b0111,
      4'b1011,
      4'b1101,
      4'b1110: begin
        result_viota4[3] = 3'd3;
      end
      4'b1111: begin
        result_viota4[3] = 3'd4;
      end
      default: begin
        result_viota4[3] = 3'd0;
      end
    endcase
  end

endmodule
