`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef DIV_DEFINE_SVH
`include "rvv_backend_div.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_div_unit_divider
//------------------------------------------------------------------------------
// 功能定位：
// 1. 单元素整数除法器，供 `rvv_backend_div_unit` 按 8/16/32 位元素宽度批量实例化。
// 2. 本模块只计算一个元素的 quotient/remainder，不直接接收 DIV_RS_t，也不直接写 ROB。
// 3. 算法是恢复除法风格的“移位 + 减法”迭代：先用被除数前导零减少循环次数，
//    每个工作周期展开 3 次 f_div_step，以降低总迭代周期。
// 4. `opcode=DIV_SIGN` 表示有符号 VDIV/VREM；`opcode=DIV_ZERO` 表示无符号
//    VDIVU/VREMU。命名里的 ZERO 不是“除数为 0”，而是无符号时符号位按 0 处理。
// 5. 特殊语义在本模块内完成：除数为 0 时 quotient 全 1、remainder 为 dividend；
//    有符号 `INT_MIN / -1` 时 quotient 为 INT_MIN、remainder 为 0。
//
// 接口握手：
// - `div_ready` 只在 DIV_IDLE 拉高，表示可接收新元素。
// - `result_valid` 在 DIV_PRINT 拉高，直到上层 `result_ready` 接收结果。
// - `trap_flush_rvv` 清除关键寄存器，避免 flush 后旧除法状态继续输出。

module rvv_backend_div_unit_divider
(
  clk,
  rst_n,
  div_valid,
  div_ready,
  opcode,
  src2_dividend,
  src1_divisor,
  result_quotient,
  result_remainder,
  result_valid,
  result_ready,
  trap_flush_rvv
);
//
// 参数
//
  // 当前实例处理的元素宽度，可为 BYTE/HWORD/WORD。
  parameter logic[7:0] DIV_WIDTH = `WORD_WIDTH;

//
// 接口信号
//
  // 全局时钟/复位。
  input   logic                 clk;
  input   logic                 rst_n;

  // 有符号/无符号除法选择。
  input   DIV_SIGN_SRC_e        opcode;

  // 输入操作数：src2 是被除数，src1 是除数。
  input   logic                 div_valid;
  output  logic                 div_ready;
  input   logic [DIV_WIDTH-1:0] src2_dividend;
  input   logic [DIV_WIDTH-1:0] src1_divisor;

  // 输出结果：商、余数以及 valid/ready 握手。
  output  logic [DIV_WIDTH-1:0] result_quotient;
  output  logic [DIV_WIDTH-1:0] result_remainder;
  output  logic                 result_valid;
  input   logic                 result_ready;

  // RVV trap/flush 清除迭代状态。
  input   logic                 trap_flush_rvv;  

//
// 内部信号
//
  // 状态机：空闲、迭代计算、等待结果被消费。
  typedef enum logic [1:0] {DIV_IDLE, DIV_WORKING, DIV_PRINT} state_e;
  state_e                       state, next_state;
  
  // 被除数前导零计数，用于跳过无意义高位迭代。
  logic [$clog2(DIV_WIDTH):0]   cnt_clzb;
  logic [$clog2(DIV_WIDTH):0]   clzb;
  logic [$clog2(DIV_WIDTH):0]   count_shift;

  // 单周期展开 3 次除法 step 的临时结果。
  logic [DIV_WIDTH-1:0]         quotient_r1;
  logic [DIV_WIDTH-1:0]         quotient_r2;
  logic [DIV_WIDTH-1:0]         quotient_r3;
  logic [DIV_WIDTH-1:0]         remainder_r1;
  logic [DIV_WIDTH-1:0]         remainder_r2;
  logic [DIV_WIDTH-1:0]         remainder_r3;
  logic [$clog2(DIV_WIDTH):0]   count_r1;
  logic [$clog2(DIV_WIDTH):0]   count_r2;
  logic [$clog2(DIV_WIDTH):0]   count_r3;

  // 迭代寄存器：保存规格化后的被除数、除数、商、余数、剩余迭代次数和符号。
  logic                         dividend_en;
  logic [DIV_WIDTH-1:0]         dividend_d;
  logic [DIV_WIDTH-1:0]         dividend_q;
  logic                         divisor_en;
  logic [DIV_WIDTH-1:0]         divisor_d;
  logic [DIV_WIDTH-1:0]         divisor_q;
  logic                         quotient_en;
  logic [DIV_WIDTH-1:0]         quotient_d;
  logic [DIV_WIDTH-1:0]         quotient_q;
  logic                         remainder_en;
  logic [DIV_WIDTH-1:0]         remainder_d;
  logic [DIV_WIDTH-1:0]         remainder_q;
  logic                         count_en;
  logic [$clog2(DIV_WIDTH):0]   count_d;
  logic [$clog2(DIV_WIDTH):0]   count_q;
  logic                         q_sgn_en;
  logic                         q_sgn_d;
  logic                         q_sgn_q;
  logic                         r_sgn_en;
  logic                         r_sgn_d;
  logic                         r_sgn_q;
`ifdef TB_SUPPORT
  logic                         res_reuse_valid_p0;
`endif
  
//
// 迭代寄存器
//
  // 被除数寄存器。
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  dividend
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (dividend_en),
    .c      (trap_flush_rvv),
    .d      (dividend_d),
    .q      (dividend_q)
  );
  // 除数寄存器。
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  divisor
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (divisor_en),
    .c      (trap_flush_rvv),
    .d      (divisor_d),
    .q      (divisor_q)
  );
  // 商寄存器。
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  quotient
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (quotient_en),
    .c      (trap_flush_rvv),
    .d      (quotient_d),
    .q      (quotient_q)
  );
  // 余数寄存器。
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  remainder
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (remainder_en),
    .c      (trap_flush_rvv),
    .d      (remainder_d),
    .q      (remainder_q)
  );
  // 剩余迭代次数寄存器。
  edff
  #(
  .T        (logic [$clog2(DIV_WIDTH):0])
  )
  count
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (count_en),
    .d      (count_d),
    .q      (count_q)
  );
  // 记录最终商是否需要取负。
  cdffr
  q_sgn
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (q_sgn_en),
    .c      (trap_flush_rvv),
    .d      (q_sgn_d),
    .q      (q_sgn_q)
  );
  // 记录最终余数是否需要取负；RISC-V 余数符号跟被除数一致。
  cdffr
  r_sgn
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (r_sgn_en),
    .c      (trap_flush_rvv),
    .d      (r_sgn_d),
    .q      (r_sgn_q)
  );

//
// 状态机
//
  edff
  #(
  .T        (state_e),
  .INIT     (DIV_IDLE)
  )
  fsm_state
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (next_state!=state),
    .d      (next_state),
    .q      (state)
  );
  
  // 状态转移：
  // - IDLE 接收新元素，若特殊情况或复用命中可直接进入 PRINT。
  // - WORKING 持续迭代，count 收敛到 1 后进入 PRINT。
  // - PRINT 保持 result_valid，等待上层 result_ready。
  // | 状态            | 含义            |
  // | ------------- | ------------- |
  // | `DIV_IDLE`    | 空闲，可以接收新除法    |
  // | `DIV_WORKING` | 正在迭代计算        |
  // | `DIV_PRINT`   | 结果已准备好，等待上层接收 |
  always_comb begin
    next_state = state;

    case(state)
      DIV_IDLE: begin
        if(div_valid&(!trap_flush_rvv)) begin
          if ((count_en=='b1)&(count_d=='b1))  //count_d=='b1表示特殊情况或复用命中时，结果已经在寄存器中准备好了，不需要迭代。
                                               //例如：
                                               //除数为 0
                                               //INT_MIN / -1
                                               //结果复用命中
            next_state = DIV_PRINT;
          else
            next_state = DIV_WORKING;
        end
        else
          next_state = DIV_IDLE;
      end
      DIV_WORKING: begin
        if(div_valid&(!trap_flush_rvv)) begin
          if ((count_en=='b1)&(count_d=='b1))
            next_state = DIV_PRINT;
          else
            next_state = DIV_WORKING;
        end
        else
          next_state = DIV_IDLE;
      end
      DIV_PRINT: begin
        if (div_valid&(!result_ready)&(!trap_flush_rvv))  //等待结果输出
          next_state = DIV_PRINT;
        else
          next_state = DIV_IDLE;
      end
    endcase
  end

  // 计算规格化需要左移的位数。count_shift 多加 1，是因为恢复除法每轮
  // 需要把 quotient 最高位移入 remainder 再尝试减 divisor。
  generate 
    if (DIV_WIDTH== 'd`WORD_WIDTH) begin
      assign clzb = f_clzb32(dividend_d);
      assign count_shift = 'd33 - clzb;            
    end
    else if (DIV_WIDTH== 'd`HWORD_WIDTH) begin
      assign clzb = f_clzb16(dividend_d);
      assign count_shift = 'd17 - clzb;            
    end
    else if (DIV_WIDTH== 'd`BYTE_WIDTH) begin
      assign clzb = f_clzb8(dividend_d);
      assign count_shift = 'd9 - clzb;            
    end
  endgenerate

  // 只有空闲态能接收新的元素除法请求。
  assign div_ready = state==DIV_IDLE; 
  
  // 状态机数据通路控制
  always_comb begin
    // 默认所有寄存器不写、输出无效，具体状态分支再覆盖。
    dividend_en      = 'b0;
    dividend_d       = 'b0;
    divisor_en       = 'b0;
    divisor_d        = 'b0;
    quotient_en      = 'b0;
    quotient_d       = 'b0;
    remainder_en     = 'b0;
    remainder_d      = 'b0;
    count_en         = 'b0;
    count_d          = 'b0;
    q_sgn_en         = 'b0;
    q_sgn_d          = 'b0;         
    r_sgn_en         = 'b0;
    r_sgn_d          = 'b0;
    cnt_clzb         = 'b0;
    quotient_r1      = 'b0;
    quotient_r2      = 'b0;
    quotient_r3      = 'b0;
    remainder_r1     = 'b0;
    remainder_r2     = 'b0;
    remainder_r3     = 'b0;
    count_r1         = 'b0;
    count_r2         = 'b0;
    count_r3         = 'b0;
    result_quotient  = 'b0;
    result_remainder = 'b0;
    result_valid     = 'b0;
`ifdef TB_SUPPORT
    res_reuse_valid_p0 = 'b0;
`endif

    case(state)
      DIV_IDLE: begin
        if(div_valid) begin
          // 除数为 0：按 RISC-V 向量整数除法语义，商为全 1，余数为被除数。
          if(src1_divisor=='b0) begin
            dividend_en = 'b1;
            dividend_d  = 'b0;

            divisor_en = 'b1;
            divisor_d  = 'b0;

            quotient_en = 'b1;
            quotient_d  = '1;

            remainder_en = 'b1;
            remainder_d  = src2_dividend;

            q_sgn_en = 'b1;
            q_sgn_d  = 'b0;

            r_sgn_en = 'b1;
            r_sgn_d  = 'b0;

            count_en = 'b1;
            count_d  = 'b1;
          end
          // 有符号最小负数除以 -1 会数学溢出：结果固定为最小负数，余数为 0。
          else if ((opcode==DIV_SIGN)&(src2_dividend=={1'b1,{(DIV_WIDTH-1){1'b0}}})&(src1_divisor=='1)) begin
            dividend_en = 'b1;
            dividend_d  = 'b0;

            divisor_en = 'b1;
            divisor_d  = 'b0;

            quotient_en = 'b1;
            quotient_d  = {1'b1,{(DIV_WIDTH-1){1'b0}}};

            remainder_en = 'b1;
            remainder_d  = 'b0;

            q_sgn_en = 'b1;
            q_sgn_d  = 'b0;

            r_sgn_en = 'b1;
            r_sgn_d  = 'b0;

            count_en = 'b1;
            count_d  = 'b1;
          end
          // 普通除法初始化。
          else begin
            if(opcode==DIV_SIGN) begin
              // 有符号除法先转成绝对值参与无符号迭代，同时记录结果符号。
              dividend_d  = src2_dividend[DIV_WIDTH-1] ? (~(src2_dividend)+1) : src2_dividend;
              divisor_d  = src1_divisor[DIV_WIDTH-1] ? (~(src1_divisor )+1) : src1_divisor;
              
              q_sgn_d   = src2_dividend[DIV_WIDTH-1]^src1_divisor[DIV_WIDTH-1];
              r_sgn_d   = src2_dividend[DIV_WIDTH-1];
            end
            else begin
              dividend_d  = src2_dividend;
              divisor_d  = src1_divisor;

              q_sgn_d  = 'b0;
              r_sgn_d  = 'b0;
            end

            // 若本次规格化后的被除数、除数和符号与上次完全相同，直接复用
            // quotient_q/remainder_q，避免重复迭代。
            if ((dividend_d==dividend_q)&(divisor_d==divisor_q)&(q_sgn_d==q_sgn_q)&(r_sgn_d==r_sgn_q)) begin
              dividend_en = 'b0; 
              divisor_en = 'b0;

              q_sgn_en  = 'b0;
              r_sgn_en  = 'b0;
              
              count_en = 'b1;
              count_d  = 'b1;

`ifdef TB_SUPPORT
              res_reuse_valid_p0 = 1'b1;
`endif
            end
            else begin
              dividend_en = 'b1; 
              divisor_en = 'b1;

              q_sgn_en  = 'b1;
              r_sgn_en  = 'b1;

              // 根据被除数前导零缩短迭代次数。
              cnt_clzb  = clzb;
              count_en  = 'b1;
              count_d   = count_shift;            

              // quotient 初始放入左移后的被除数；remainder 从 0 开始恢复除法。
              quotient_en = 'b1;   
              quotient_d  = dividend_d<<cnt_clzb;

              remainder_en = 'b1;
              remainder_d  = 'b0;
            end
          end
        end
      end
      DIV_WORKING: begin
        if(div_valid) begin
          // 每个周期连续执行 3 次移位/减法 step，然后按剩余 count 选择有效结果。
          f_div_step (remainder_q ,quotient_q ,divisor_q,remainder_r1,quotient_r1);
          f_div_step (remainder_r1,quotient_r1,divisor_q,remainder_r2,quotient_r2);
          f_div_step (remainder_r2,quotient_r2,divisor_q,remainder_r3,quotient_r3);
          
          count_r1 = count_q - 'd1;
          count_r2 = count_q - 'd2;
          count_r3 = count_q - 'd3;
          
          quotient_en = 'b1;   
          remainder_en = 'b1;
          count_en = 'b1;

          case({{($clog2(DIV_WIDTH)-1){1'b0}},1'b1})
            count_r1: begin
              quotient_d  = quotient_r1;
              remainder_d = remainder_r1;
              count_d     = 'b1; 
            end
            count_r2: begin
              quotient_d  = quotient_r2;
              remainder_d = remainder_r2;
              count_d     = 'b1;            
            end
            default: begin
              quotient_d  = quotient_r3;
              remainder_d = remainder_r3;
              count_d     = count_r3;            
            end
          endcase
        end  
      end
      // 输出最终商/余数，并根据记录的符号位恢复二补码符号。
      DIV_PRINT: begin
        result_valid = 'b1;
        
        result_quotient  = q_sgn_q ? ((~quotient_q )+'d1) : quotient_q;
        result_remainder = r_sgn_q ? ((~remainder_q)+'d1) : remainder_q;
    
        count_en = result_ready;
        count_d  = 'b0;
      end
    endcase
  end

//
// 辅助函数
//
  // 分层计算前导零个数，返回值可以等于输入宽度，表示全 0。
  function [1:0] f_clzb2
  (   
    input logic [1:0] src
  );
    
    if (src[1])
      f_clzb2 = 2'b00;
    else if (src[0])
      f_clzb2 = 2'b01;
    else
      f_clzb2 = 2'b10;
  endfunction

  function [2:0] f_clzb4
  (
    input logic [3:0] src
  );

    logic [1:0] hi;
    logic [1:0] lo;

    hi = f_clzb2(src[3:2]);
    lo = f_clzb2(src[1:0]);
    if ((hi[1]==1'b1)&(lo[1]==1'b1))
      f_clzb4 = 3'b100;
    else if (hi[1]==1'b0)
      f_clzb4 = {1'b0,hi};
    else
      f_clzb4 = {2'b01,lo[0]};
  endfunction

  function [3:0] f_clzb8
  (
    input logic [7:0] src
  );

    logic [2:0] hi;
    logic [2:0] lo;

    hi = f_clzb4(src[7:4]);
    lo = f_clzb4(src[3:0]);
    if ((hi[2]==1'b1)&(lo[2]==1'b1))
      f_clzb8 = 4'b1000;
    else if (hi[2]==1'b0)
      f_clzb8 = {1'b0,hi};
    else
      f_clzb8 = {2'b01,lo[1:0]};
  endfunction

  function [4:0] f_clzb16
  (
    input logic [15:0] src
  );

    logic [3:0] hi;
    logic [3:0] lo;

    hi = f_clzb8(src[15:8]);
    lo = f_clzb8(src[7:0]);
    if ((hi[3]==1'b1)&(lo[3]==1'b1))
      f_clzb16 = 5'b1_0000;
    else if (hi[3]==1'b0)
      f_clzb16 = {1'b0,hi};
    else
      f_clzb16 = {2'b01,lo[2:0]};
  endfunction

  function [5:0] f_clzb32  
  (
    input logic [31:0] src
  );
    
    logic [4:0] hi;
    logic [4:0] lo;

    hi = f_clzb16(src[31:16]);
    lo = f_clzb16(src[15:0]);
    if ((hi[4]==1'b1)&(lo[4]==1'b1))
      f_clzb32 = 6'b10_0000;
    else if (hi[4]==1'b0)
      f_clzb32 = {1'b0,hi};
    else
      f_clzb32 = {2'b01,lo[3:0]};
  endfunction

  // 单步恢复除法：
  // 1. quotient 最高位移入 remainder。
  // 2. 尝试 remainder - divisor。
  // 3. 若不够减，则 quotient 新最低位为 0；否则写回差值，quotient 新最低位为 1。
  function void f_div_step
  (
    input  logic [DIV_WIDTH-1:0] remainder_in,
    input  logic [DIV_WIDTH-1:0] quotient_in,
    input  logic [DIV_WIDTH-1:0] divisor_in,
    output logic [DIV_WIDTH-1:0] remainder_out,
    output logic [DIV_WIDTH-1:0] quotient_out
  );

    logic [DIV_WIDTH-1:0] remainder_tmp;
    logic [DIV_WIDTH  :0] diff;
    
    remainder_tmp = {remainder_in[DIV_WIDTH-2:0],quotient_in[DIV_WIDTH-1]};
    diff = {1'b0,remainder_tmp} - {1'b0,divisor_in};

    if (diff[DIV_WIDTH]) begin
      remainder_out = remainder_tmp;
      quotient_out  = {quotient_in[DIV_WIDTH-2:0],1'b0};  //不够减
    end
    else begin
      remainder_out = diff[DIV_WIDTH-1:0];
      quotient_out  = {quotient_in[DIV_WIDTH-2:0],1'b1};  //可以减
    end
  endfunction

endmodule
