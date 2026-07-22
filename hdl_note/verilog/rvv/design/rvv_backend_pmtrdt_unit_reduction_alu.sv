// 功能说明：
// 1. reduction 的基础 ALU，宽度可参数化为 8/16/32 bit，内部仍按 byte 切片计算。
// 2. 支持规约求和、拓宽规约求和、max/min、有符号/无符号比较，以及 and/or/xor。
// 3. 对多 byte 元素，cin/cout 只在同一个元素内部串接；元素边界处重新开始进位链。
// 4. max/min 复用加法器做比较：src2 + (~src1) + 1，通过最高 byte 的 cout 判断大小。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif
module rvv_backend_pmtrdt_unit_reduction_alu
(
  src1,
  src2,
  ctrl,
  dst
);

// ---参数定义--------------------------------------------------------
  parameter  ALU_WIDTH = 32;
  localparam ALU_BYTE = ALU_WIDTH/8;

// ---端口定义--------------------------------------------------------
  // src1/src2 都按 byte 组织，ctrl 指示当前规约类型和元素宽度。
  input [ALU_BYTE-1:0][7:0] src1, src2;
  input RDT_ALU_t           ctrl;
  output logic [ALU_BYTE-1:0][7:0] dst;

// ---内部信号--------------------------------------------------------
  logic [ALU_BYTE-1:0][8:0] src1_tmp, src2_tmp;
  logic [ALU_BYTE-1:0]      cin, cout; // 每个 byte 加法器的进位输入/输出。
  logic [ALU_BYTE-1:0][7:0] sum_dst;
  logic [ALU_BYTE-1:0][7:0] and_dst,  or_dst, xor_dst;
  logic [ALU_BYTE-1:0]      lt; // 比较结果来自对应元素最高 byte 的 cout。

  logic [3:0] element_byte; 

  genvar i;

// ---主逻辑----------------------------------------------------------
  // element_byte 表示一个元素包含多少 byte，用于决定进位链和比较结果的边界。
  always_comb begin
    case (ctrl.vs2_eew)
      EEW64: element_byte = 4'h8;
      EEW32: element_byte = 4'h4;
      EEW16: element_byte = 4'h2;
      default: element_byte = 4'h1; //EEW8
    endcase
  end

  // src2_tmp：有符号 max/min 只在元素最高 byte 复制符号位，其余 byte 走无符号扩展。
  generate
    for (i=0; i<ALU_BYTE; i++) begin : gen_src2_tmp
      always_comb begin
        case(ctrl.uop_funct6)
          VREDMAX,
          VREDMIN: src2_tmp[i] = (i%element_byte)==(element_byte-1) ? {src2[i][7],src2[i]} : {1'b0,src2[i]}; 
          // 其它操作不需要对 src2 做符号扩展。
          default: src2_tmp[i] = {1'b0, src2[i]}; 
        endcase
      end
    end
  endgenerate

  // src1_tmp：max/min 通过取反 + cin=1 实现 src2-src1 比较。
  generate
    for (i=0; i<ALU_BYTE; i++) begin : gen_src1_tmp
      always_comb begin
        case(ctrl.uop_funct6)
          VREDMAX,
          VREDMIN: src1_tmp[i] = (i%element_byte)==(element_byte-1) ? ~{src1[i][7],src1[i]} : ~{1'b0,src1[i]}; 
          VREDMAXU,
          VREDMINU: src1_tmp[i] = ~{1'b0, src1[i]};
          // 求和和逻辑规约直接使用原值。
          default: src1_tmp[i] = {1'b0, src1[i]}; 
        endcase
      end
    end
  endgenerate

  // cin：比较类操作的每个元素最低 byte 注入 1，求和类操作注入 0。
  generate
    always_comb begin
      case (ctrl.uop_funct6)
        VREDMAXU,
        VREDMAX,
        VREDMINU,
        VREDMIN: cin[0] = ~1'b0; 
        // 非比较类操作从 0 开始加。
        default: cin[0] = 1'b0; 
      endcase
    end
    for (i=1; i<ALU_BYTE; i++) begin : gen_cin
      always_comb begin
        case (ctrl.uop_funct6)
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN: cin[i] = i%element_byte==0 ? ~1'b0 : ~cout[i-1]; 
          // 元素边界处重新开始进位链，元素内部继续串接上一 byte 的 cout。
          default: cin[i] = i%element_byte==0 ? 1'b0 : cout[i-1]; 
        endcase
      end
    end //for (i=0; i<ALU_BYTE; i++) begin : gen_cin
  endgenerate

  generate
    for (i=0;i<ALU_BYTE;i++) begin : gen_byte_alu
      // 每个 byte 都并行计算加法和逻辑结果，最后按 funct6 选择输出。
      assign {cout[i],sum_dst[i]} = src2_tmp[i] + src1_tmp[i] + cin[i];
      assign and_dst[i] = src2[i][7:0] & src1[i][7:0];
      assign or_dst[i]  = src2[i][7:0] | src1[i][7:0];
      assign xor_dst[i] = src2[i][7:0] ^ src1[i][7:0];
      assign lt[i] = cout[i];
      always_comb begin
        case(ctrl.uop_funct6)
          VMUNARY0,
          VWRXUNARY0,
          VREDSUM,
          VWREDSUMU,
          VWREDSUM: dst[i] = sum_dst[i][7:0];
          VREDMAXU,
          VREDMAX: dst[i] = ~lt[(i/element_byte+1)*element_byte-1] ? src2[i][7:0] : src1[i][7:0];
          VREDMINU,
          VREDMIN: dst[i] = lt[(i/element_byte+1)*element_byte-1] ? src2[i][7:0] : src1[i][7:0];
          VREDAND: dst[i] = and_dst[i];
          VREDOR:  dst[i] = or_dst[i];
          default: dst[i] = xor_dst[i]; //VREDXOR
        endcase
      end
    end
  endgenerate

endmodule
