
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
// rvv_backend_div_unit
//------------------------------------------------------------------------------
// 功能定位：
// 1. 整数向量除法/取余执行单元，处理 VDIVU/VDIV/VREMU/VREM。
// 2. 输入来自 DIV reservation station 的 `DIV_RS_t`，输出最终 `PU2ROB_t`
//    给 `rvv_backend_div`，再由后端结果仲裁写入 ROB。
// 3. 本模块并行实例化 8/16/32 位单元素 divider：
//    - EEW8 会同时使用 8 位、16 位、32 位 divider 阵列覆盖整条 VLEN。
//    - EEW16 使用 16 位和 32 位 divider 阵列。
//    - EEW32 只使用 32 位 divider 阵列。
//    这种分配方式让较宽 divider 的低位结果承接高编号元素，最后按 EEW 截低位拼回。
// 4. OPMVV 使用 vs1 作为除数；OPMVX 将 rs1 按当前 EEW 广播为除数。
// 5. 有符号 VDIV/VREM 会对窄元素做符号扩展；无符号 VDIVU/VREMU 做零扩展。
//
// 宏阅读提示：
// - `BYTE_WIDTH`=8，`HWORD_WIDTH`=16，`WORD_WIDTH`=32，`XLEN`=32。
// - `VLEN` 由编译宏决定；`VLENB/H/W` 分别是按 8/16/32 位划分的元素/片段数。

module rvv_backend_div_unit
(
  clk,
  rst_n,
  div_uop_valid,
  div_uop,
  div_uop_ready,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);
//
// 接口信号
//
  // 全局时钟/复位。
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS 到整数 DIV unit 的 valid/ready 握手和 uop 内容。
  input   logic     div_uop_valid;
  input   DIV_RS_t  div_uop;
  output  logic     div_uop_ready;

  // 整数 DIV unit 输出给后级 ROB 写回通路的结果。
  output  logic     result_valid;
  output  PU2ROB_t  result;
  input   logic     result_ready;

  // RVV trap/flush，清除各元素 divider 和已暂存的 uop 信息。
  input   logic     trap_flush_rvv;                

//
// 内部信号
//
  // 从 DIV_RS_t 拆出的控制字段和源操作数。
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  FUNCT6_u                        uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  logic   [`VLEN-1:0]             vs1_data;           
  logic   [`VLEN-1:0]             vs2_data;	        
  EEW_e                           vs2_eew;
  logic   [`XLEN-1:0] 	          rs1_data;        

  // 执行数据通路：
  // 8/16/32 位源数组分别喂给对应宽度的 divider；quotient/remainder 数组保存返回结果。
  logic                                     uop_valid;
  logic                                     uop_valid_e;
  logic                                     uop_valid_d1;
  logic   [`VLENB/2-1:0]                    div_ready8;
  logic   [`VLENH/2-1:0]                    div_ready16;
  logic   [`VLENW-1:0]                      div_ready32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   src2_data8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  src2_data16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     src2_data32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   src1_data8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  src1_data16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     src1_data32;
  DIV_RES_t                                 res_info;
  DIV_RES_t                                 res_info_d1;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   quotient8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  quotient16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     quotient32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   remainder8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  remainder16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     remainder32;
  logic   [`VLENB/2-1:0]                    result_valid8;
  logic   [`VLENH/2-1:0]                    result_valid16;
  logic   [`VLENW-1:0]                      result_valid32;
  logic   [`VLEN-1:0]                       result_data; 
  logic                                     result_all_valid; 
  DIV_SIGN_SRC_e                            opcode;

  // generate 循环变量。
  genvar                                                j;

//
// 拆分 uop，准备除法操作数
//
  // DIV_RS_t 字段拆分。这里的 vs2 是被除数，vs1/rs1 是除数来源。
  assign  rob_entry   = div_uop.rob_entry;
  assign  uop_funct6  = div_uop.uop_funct6;
  assign  uop_funct3  = div_uop.uop_funct3;
  assign  vs1_data    = div_uop.vs1_data;
  assign  rs1_data    = div_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data    = div_uop.vs2_data;
  assign  vs2_eew     = div_uop.vs2_eew;
  
//  
// 准备源操作数
//
  // uop 真正被本单元接收的条件：上游 valid 且所有需要的 divider ready。
  assign uop_valid = div_uop_valid&div_uop_ready;
 
  // 按指令形式和 EEW 将向量/标量源拆到 8/16/32 位 divider 输入。
  // 对 EEW8/EEW16，部分高编号元素会放入更宽 divider，输出时只取低 8/16 位。
  always_comb begin
    // 默认清零，避免未使用 divider 输入携带旧值。
    src2_data8   = 'b0;
    src2_data16  = 'b0;
    src2_data32  = 'b0;
    src1_data8   = 'b0;
    src1_data16  = 'b0;
    src1_data32  = 'b0;

    case(uop_funct3) 
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VDIVU,
          VREMU: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {8'b0,vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {24'b0,vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = vs1_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                end             
              end
            endcase
          end

          VDIV,
          VREM: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {{8{vs1_data[(i+1)*`BYTE_WIDTH-1]}},vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {{24{vs1_data[(i+1)*`BYTE_WIDTH-1]}},vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{vs1_data[(i+1)*`HWORD_WIDTH-1]}},vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = vs1_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                end             
              end
            endcase
          end
        endcase
      end
      OPMVX: begin
        case(uop_funct6.ari_funct6)
          VDIVU,
          VREMU: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = rs1_data[0             +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {8'b0,rs1_data[0             +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {24'b0,rs1_data[0             +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = rs1_data[0              +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,rs1_data[0              +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = rs1_data[0             +: `WORD_WIDTH];
                end             
              end
            endcase
          end

          VDIV,
          VREM: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = rs1_data[0             +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {{8{rs1_data[      `BYTE_WIDTH-1]}},rs1_data[0             +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {{24{rs1_data[      `BYTE_WIDTH-1]}},rs1_data[0             +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = rs1_data[0              +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{rs1_data[      `HWORD_WIDTH-1]}},rs1_data[0              +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = rs1_data[0             +: `WORD_WIDTH];
                end             
              end
            endcase
          end
        endcase
      end
    endcase
  end

  // 单元素 divider 只区分有符号和无符号。
  // DIV_SIGN 用于 VDIV/VREM；DIV_ZERO 用于 VDIVU/VREMU。
  always_comb begin
    // 默认按有符号处理，匹配无符号指令时覆盖。
    opcode = DIV_SIGN;

    // 根据 funct3/funct6 选择 divider 的符号模式。
    case(uop_funct3) 
      OPMVV,
      OPMVX: begin
        case(uop_funct6.ari_funct6)    
          VDIV,
          VREM: begin
            opcode = DIV_SIGN;
          end
          VDIVU,
          VREMU: begin
            opcode = DIV_ZERO;
          end
        endcase
      end
    endcase
  end

  //    
  // 实例化各宽度 divider 并收集结果
  // 暂存一拍信息

  // uop_valid_d1 用于在结果未被消费时继续保持 divider 的 div_valid，
  // 让各元素 divider 停在 PRINT 状态直到 ROB ready。
  assign uop_valid_e = uop_valid || result_valid&result_ready;

  cdffr 
  div_vld
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (uop_valid_e),
    .c      (trap_flush_rvv),
    .d      (uop_valid),
    .q      (uop_valid_d1)  
  );

  // 保存本条 uop 的 ROB entry、funct 和 EEW；divider 结果回来后需要这些信息拼包。
`ifdef TB_SUPPORT
  assign res_info.uop_pc      = div_uop.uop_pc;
`endif
  assign res_info.uop_funct6  = uop_funct6;
  assign res_info.uop_funct3  = uop_funct3;
  assign res_info.rob_entry   = rob_entry;
  assign res_info.vs2_eew     = vs2_eew;

  edff #(
    .T      (DIV_RES_t)
  //  .INIT   ('0)  // 保留原作者调试痕迹：此处未给 DIV_RES_t 显式复位值。
  ) res_information
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (uop_valid),
    .d      (res_info),
    .q      (res_info_d1)
  );

  generate
    for(j=0;j<`VLENB/2;j++) begin: DIVIDER8
      // 8 位 divider 阵列：只在 EEW8 指令中承接低半部分 byte 元素。
      rvv_backend_div_unit_divider
      #(
        .DIV_WIDTH          (8'd`BYTE_WIDTH)
      )
      divider_8bit
      (
        .clk                (clk),
        .rst_n              (rst_n),
        .div_valid          (uop_valid&(vs2_eew==EEW8) || uop_valid_d1&(res_info_d1.vs2_eew==EEW8)),
        .div_ready          (div_ready8[j]),
        .opcode             (opcode), 
        .src2_dividend      (src2_data8[j]),
        .src1_divisor       (src1_data8[j]),
        .result_quotient    (quotient8[j]),
        .result_remainder   (remainder8[j]),
        .result_valid       (result_valid8[j]),
        .result_ready       (result_ready&result_valid),
        .trap_flush_rvv     (trap_flush_rvv)
      );     
    end
  endgenerate 

  generate
    for(j=0;j<`VLENH/2;j++) begin: DIVIDER16
      // 16 位 divider 阵列：
      // - EEW8 时承接中间一段 byte 元素，输入做 8->16 扩展。
      // - EEW16 时承接低半部分 halfword 元素。
      rvv_backend_div_unit_divider
      #(
        .DIV_WIDTH          (8'd`HWORD_WIDTH)
      )
      divider_16bit
      (
        .clk                (clk),
        .rst_n              (rst_n),
        .div_valid          (uop_valid&(vs2_eew!=EEW32) || uop_valid_d1&(res_info_d1.vs2_eew!=EEW32)),
        .div_ready          (div_ready16[j]),
        .opcode             (opcode), 
        .src2_dividend      (src2_data16[j]),
        .src1_divisor       (src1_data16[j]),
        .result_quotient    (quotient16[j]),
        .result_remainder   (remainder16[j]),
        .result_valid       (result_valid16[j]),
        .result_ready       (result_ready&result_valid),
        .trap_flush_rvv     (trap_flush_rvv)
      );     
    end
  endgenerate 

  generate
    for(j=0;j<`VLENW;j++) begin: DIVIDER32
      // 32 位 divider 阵列：
      // - EEW8/EEW16 时承接高编号元素，输入做窄元素到 32 位扩展。
      // - EEW32 时承接全部 word 元素。
      rvv_backend_div_unit_divider
      #(
        .DIV_WIDTH          (8'd`WORD_WIDTH)
      )
      divider_32bit
      (
        .clk                (clk),
        .rst_n              (rst_n),
        .div_valid          (uop_valid || uop_valid_d1),
        .div_ready          (div_ready32[j]),
        .opcode             (opcode), 
        .src2_dividend      (src2_data32[j]),
        .src1_divisor       (src1_data32[j]),
        .result_quotient    (quotient32[j]),
        .result_remainder   (remainder32[j]),
        .result_valid       (result_valid32[j]),
        .result_ready       (result_ready&result_valid),
        .trap_flush_rvv     (trap_flush_rvv)
      );     
    end
  endgenerate
  
  // 只有当前 EEW 需要的所有 divider 都 ready，才允许从 DIV RS pop 新 uop。
  always_comb begin
    case(vs2_eew)
      EEW8:    div_uop_ready = &{div_ready32,div_ready16,div_ready8}; 
      EEW16:   div_uop_ready = &{div_ready32,div_ready16};
      EEW32:   div_uop_ready = &{div_ready32};
      default: div_uop_ready = 'b0;
    endcase
  end

  // 当前 EEW 涉及的所有 divider 均返回 result_valid 后，整条向量结果才有效。
  always_comb begin
    result_all_valid = 'b0;
    
    case(res_info_d1.vs2_eew)
      EEW8: begin
        result_all_valid = ({result_valid8,result_valid16,result_valid32}=='1);  //等价于&{result_valid8, result_valid16, result_valid32}
      end
      EEW16: begin
        result_all_valid = ({result_valid16,result_valid32}=='1);
      end
      EEW32: begin
        result_all_valid = (result_valid32=='1);
      end
    endcase
  end

  // 按 VDIV/VREM 选择 quotient 或 remainder，并按 EEW 拼回 VLEN 位写回数据。
  // 对使用更宽 divider 承接的窄元素，只截取 quotient/remainder 的低位。
  always_comb begin
    // 默认清零，未匹配指令不写有效结果。
    result_data = 'b0;

    case(res_info_d1.uop_funct3) 
      OPMVV,
      OPMVX: begin
        case(res_info_d1.uop_funct6.ari_funct6)
          VDIVU,
          VDIV: begin
            case(res_info_d1.vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = quotient8[i];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = quotient16[i-`VLENB/2][0 +: `BYTE_WIDTH];
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = quotient32[i-`VLENB*3/4][0 +: `BYTE_WIDTH];
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = quotient16[i];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = quotient32[i-`VLEN/`HWORD_WIDTH/2][0 +: `HWORD_WIDTH];
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = quotient32[i];
                end             
              end
            endcase
          end

          VREMU,
          VREM: begin
            case(res_info_d1.vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = remainder8[i];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = remainder16[i-`VLENB/2][0 +: `BYTE_WIDTH];
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = remainder32[i-`VLENB*3/4][0 +: `BYTE_WIDTH];
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = remainder16[i];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = remainder32[i-`VLEN/`HWORD_WIDTH/2][0 +: `HWORD_WIDTH];
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = remainder32[i];
                end             
              end
            endcase
          end
        endcase
      end
    endcase
  end

//
// 输出最终结果到 ROB 写回通路
//
`ifdef TB_SUPPORT
  assign result.uop_pc    = res_info_d1.uop_pc;
`endif
  assign result_valid     = result_all_valid;
  assign result.rob_entry = res_info_d1.rob_entry;
  assign result.w_data    = result_data;
  assign result.w_valid   = result_all_valid;
  assign result.vsaturate = 'b0;
`ifdef ZVE32F_ON
  assign result.fpexp     = 'b0;
`endif

endmodule
