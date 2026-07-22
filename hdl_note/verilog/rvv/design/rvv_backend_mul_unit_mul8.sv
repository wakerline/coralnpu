//------------------------------------------------------------------------------
// rvv_backend_mul_unit_mul8
//------------------------------------------------------------------------------
// 功能定位：
// 1. 8-bit 基础乘法单元，是 MUL/MAC 执行单元的最小乘法积木。
// 2. 上层把一个 VLEN 向量先拆成 byte，再用多个 mul8 组成 8/16/32 位乘法矩阵。
// 3. `src*_is_signed` 控制是否对对应 8-bit 输入做符号扩展；无符号输入则高位补 0。
// 4. 输出 `res` 为 16-bit 部分积，后续由 `rvv_backend_mul_unit` 或
//    `rvv_backend_mac_unit` 按 EEW 重新移位相加，形成完整元素乘积。

module rvv_backend_mul_unit_mul8 (
  res,
  src0, 
  src0_is_signed,
  src1, 
  src1_is_signed
);

parameter MUL_WIDTH = `BYTE_WIDTH;

// 一个输入按 MUL_WIDTH 扩成 2*MUL_WIDTH 后相乘，因此当前默认是 8x8 -> 16。
input   [MUL_WIDTH-1:0]   src0;
input                     src0_is_signed;
input   [MUL_WIDTH-1:0]   src1;
input                     src1_is_signed;
output  [2*MUL_WIDTH-1:0] res;

logic                     src0_sgn;
logic                     src1_sgn;

// 只有有符号乘法且最高位为 1 时才扩展符号位。
assign src0_sgn = src0_is_signed&src0[MUL_WIDTH-1];
assign src1_sgn = src1_is_signed&src1[MUL_WIDTH-1];

// 统一用扩展后的操作数相乘，避免上层为有符号/无符号分别实例化乘法器。
assign res = {{MUL_WIDTH{src0_sgn}}, src0} * {{MUL_WIDTH{src1_sgn}}, src1};

endmodule
