`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

// 功能说明：
// 1. 通用参数化桶形移位器，DATA_WIDTH 指定数据宽度。
// 2. 支持三种移位模式：
//    SHIFT_SLL = 00：逻辑左移，低位补 0；
//    SHIFT_SRL = 01：逻辑右移，高位补 0；
//    SHIFT_SRA = 10：算术右移，高位复制符号位。
// 3. shift_amount 宽度为 $clog2(DATA_WIDTH)，因此最大移位量为 DATA_WIDTH-1。
// 4. 内部用多级 2^j 条件移位实现：每一级根据 shift_amount[j] 决定是否移动 2^j 位。
// 5. 这是纯组合逻辑模块，没有 valid/ready，也没有时序寄存器。
module barrel_shifter 
(
  din,
  shift_amount,
  shift_mode,
  dout
);
  parameter   DATA_WIDTH    = 32;
  // 移位量位宽。DATA_WIDTH 最好为 2 的幂，否则最大可表达移位量仍由 clog2 决定。
  localparam  SHIFT_WIDTH   = $clog2(DATA_WIDTH);
  // 移位模式编码。
  localparam  SHIFT_SLL     = 2'b00;
  localparam  SHIFT_SRL     = 2'b01;
  localparam  SHIFT_SRA     = 2'b10;

  // 输入数据。
  input  logic [DATA_WIDTH-1:0]   din;
  // 移位量，按二进制拆给各级 2^j 移位 mux。
  input  logic [SHIFT_WIDTH-1:0]  shift_amount;
  // 移位模式：逻辑左移、逻辑右移或算术右移。
  input  logic [1:0]              shift_mode;
  // 移位结果。
  output logic [DATA_WIDTH-1:0]   dout;

  // stage[0] 是输入；stage[j+1] 是经过第 j 级 2^j 条件移位后的结果。
  logic  [SHIFT_WIDTH:0][DATA_WIDTH-1:0] stage;

  assign stage[0] = din;
  assign dout     = stage[SHIFT_WIDTH];

  generate
    for(genvar j=0;j< SHIFT_WIDTH;j++) begin : gen_shift_stages
      // 第 j 级负责 2^j 位移位。例如 j=0 移 1 位，j=1 移 2 位，j=2 移 4 位。
      localparam SHIFT_AMOUNT = 1<<j;

      always_comb begin
        if(shift_amount[j]) begin
          case(shift_mode)
            // 逻辑左移：高位向左推出，低 SHIFT_AMOUNT 位补 0。
            SHIFT_SLL: stage[j+1] = {stage[j][DATA_WIDTH-1-SHIFT_AMOUNT:0], {SHIFT_AMOUNT{1'b0}}};
            // 逻辑右移：低位向右推出，高 SHIFT_AMOUNT 位补 0。
            SHIFT_SRL: stage[j+1] = {{SHIFT_AMOUNT{1'b0}}, stage[j][DATA_WIDTH-1:SHIFT_AMOUNT]};
            // 算术右移：低位向右推出，高位复制当前级输入的符号位。
            SHIFT_SRA: stage[j+1] = {{SHIFT_AMOUNT{stage[j][DATA_WIDTH-1]}}, stage[j][DATA_WIDTH-1:SHIFT_AMOUNT]};
            // 非法模式保持不变，避免组合逻辑产生不可预期移位。
            default  : stage[j+1] = stage[j];
          endcase         
        end
        else begin
          // 当前移位量 bit 为 0，本级直接旁路。
          stage[j+1] = stage[j];
        end
      end
    end
  endgenerate
  
endmodule
