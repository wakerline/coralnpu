
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_alu_unit_execution_p1
//------------------------------------------------------------------------------
// 功能定位：
// 1. 这是 RVV ALU 加减路径的 p1 阶段，输入来自
//    `rvv_backend_alu_unit_addsub` 的 `PIPE_DATA_t`。
// 2. p0 已经完成 byte 级加/减并保存 product8/cout8；本模块在 p1 中继续
//    归并 16/32 位进位，生成最终 `PU2ROB_t` 写回 ROB。
// 3. 本级完成的主要后处理包括：普通加减结果选择、VAADD/VASUB 舍入、
//    VSADD/VSSUB 饱和检测和裁剪、VMSEQ/VMSLT 等比较 mask 合并、
//    VMADC/VMSBC mask 结果、VMIN/VMAX 选择。
// 4. 比较类指令可能由多个 uop 分段产生一个 mask 结果，因此非最后 uop
//    的比较结果会暂存在 cmp_d1，只有 last_uop_valid 时才对 ROB 输出。
// 5. `trap_flush_rvv` 会清除比较中间寄存器，避免 flush 之后的旧 mask
//    片段继续参与最终写回。
//
// 宏阅读提示：
// - `BYTE_WIDTH`=8，`HWORD_WIDTH`=16，`WORD_WIDTH`=32。
// - `VLEN` 不在本 design 文件中固定，需由 VLEN_128/VLEN_256/VLEN_512/
//   VLEN_1024 等编译宏决定；`VLENB/H/W`、`VL_WIDTH`、`VSTART_WIDTH`
//   均由 `VLEN` 派生。

module rvv_backend_alu_unit_execution_p1
(
  clk,
  rst_n,
  alu_uop_valid,
  alu_uop,
  result_valid,
  result,
  trap_flush_rvv
);
  parameter CMP_SUPPORT = 1'b0;

//
// 接口信号
//
  // 时钟和复位。
  input   logic           clk;
  input   logic           rst_n;
  // addsub p0 输入到 p1 的流水数据。
  input   logic           alu_uop_valid;
  input   PIPE_DATA_t     alu_uop;
  // p1 送往 ROB 的最终结果包。
  output  logic           result_valid;
  output  PU2ROB_t        result;
  // RVV trap/flush，用于清掉比较类跨 uop 累积状态。
  input   logic           trap_flush_rvv; 

//
// 内部信号
//  
  // 从 PIPE_DATA_t 拆出的控制字段、中间结果和原始源数据。
  ADDSUB_e                                opcode;
  FUNCT6_u                                uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]             uop_funct3;
  logic   [`VSTART_WIDTH-1:0]             vstart;
  logic   [`VL_WIDTH-1:0]                 vl;       
  logic                                   vm;       
  RVVXRM                                  vxrm;       
  logic   [`VLEN-1:0]                     v0_data;
  logic   [`VLEN-1:0]                     vd_data;           
  EEW_e                                   vs2_eew;
  logic        	                          last_uop_valid;
  logic   [$clog2(`EMUL_MAX)-1:0]         uop_index;   

  logic                                   is_cmp;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src2_data;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src1_data;  
  logic   [`VLENB-1:0]                    src2_sgn;
  logic   [`VLENB-1:0]                    src1_sgn;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   product8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  product16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   product32;
  logic   [`VLENB-1:0]                    cout8;
  logic   [`VLENH-1:0]                    cout16;
  logic   [`VLENW-1:0]                    cout32;  
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   round8_src;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  round16_src;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   round32_src;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   round8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  round16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   round32;
  logic   [`VLENB-1:0]                    addu_upoverflow;
  logic   [`VLENB-1:0]                    add_upoverflow;
  logic   [`VLENB-1:0]                    add_underoverflow;
  logic   [`VLENB-1:0]                    subu_underoverflow;
  logic   [`VLENB-1:0]                    sub_upoverflow;
  logic   [`VLENB-1:0]                    sub_underoverflow;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   result_minmax8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  result_minmax16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   result_minmax32;
  logic   [`VLEN-1:0]                     result_data;   // 最终写回数据，覆盖 EEW=8/16/32 的常规元素宽度。
  genvar                                  j;

  // 比较/mask 类指令的跨 uop 暂存和 vstart/vl/tail 保护逻辑。
  logic   [`VLEN-1:0]                     vstart_elements_tmp;
  logic   [`VLEN-1:0]                     vstart_elements;
  logic   [`VLEN-1:0]                     tail_elements_tmp;
  logic   [`VLEN-1:0]                     tail_elements;
  logic   [`VLEN-1:0]                     cmp_tmp;
  logic   [`VLEN-1:0]                     cmp;
  logic   [27:0]                          cmp_en;
  logic   [28*`VLENW-1:0]                 cmp_d1;
  logic   [`VLEN-1:0]                     cmp_res_tmp;
  logic   [`VLEN-1:0]                     cmp_res;
  logic   [`VLEN-1:0]                     vmadcsbc_res;

//
// 拆分 p0 流水数据，准备 p1 后处理
//
  // p0 的 w_data 保存 product8，vsat_cout.cout 保存 cout8。
  // v0_src2/vd_src1 同时承载 mask、旧 vd、min/max 原始比较源等信息。
  assign opcode         = alu_uop.opcode;
  assign uop_funct6     = alu_uop.uop_funct6;
  assign uop_funct3     = alu_uop.uop_funct3;
  assign is_cmp         = alu_uop.is_cmp;
  assign vs2_eew        = alu_uop.vs2_eew;
  assign vstart         = alu_uop.vstart;
  assign vl             = alu_uop.vl;
  assign vm             = alu_uop.vm;
  assign vxrm           = alu_uop.vxrm;
  assign v0_data        = alu_uop.v0_src2.v0;
  assign vd_data        = alu_uop.vd_src1.vd;
  assign src2_data      = alu_uop.v0_src2.src2;
  assign src1_data      = alu_uop.vd_src1.src1;
  assign src2_sgn       = alu_uop.src2_sgn;
  assign src1_sgn       = alu_uop.src1_sgn;
  assign product8       = alu_uop.w_data;
  assign cout8          = alu_uop.vsat_cout.cout;
  assign last_uop_valid = alu_uop.last_uop_valid;
  assign uop_index      = alu_uop.uop_index;

  generate
    // 默认 p1 输入有效就可向 ROB 输出；比较/mask 生成类需要等最后一个 uop
    // 到来后再输出合并后的完整 mask。
    always_comb begin
      // 普通加减、饱和、平均、min/max 等都逐 uop 输出。
      result_valid = alu_uop_valid;

      if(CMP_SUPPORT) begin
        case(uop_funct3) 
          OPIVV: begin
            case(uop_funct6.ari_funct6)
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE: begin
                result_valid = alu_uop_valid&last_uop_valid;  //非最后 uop 只暂存结果，不应该提前写 ROB
              end            
            endcase
          end
          
          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT: begin
                result_valid = alu_uop_valid&last_uop_valid;
              end
            endcase
          end

          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VMADC,
              VMSEQ,
              VMSNE,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT: begin
                result_valid = alu_uop_valid&last_uop_valid;
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

//    
// 归并 p0 的 byte 级结果，生成 16/32 位加减结果
//
  always_comb begin
    for(int i=0;i<`VLENH;i++) begin: VADDSUB_PROD16
      if (opcode==ADDSUB_VADD) 
        {cout16[i],product16[i]} = { ({cout8[2*i+1],product8[2*i+1]} + cout8[2*i]), product8[2*i] };
      else // opcode==ADDSUB_VSUB
        {cout16[i],product16[i]} = { ({cout8[2*i+1],product8[2*i+1]} - cout8[2*i]), product8[2*i] };
    end
  end

  always_comb begin
    for(int i=0;i<`VLENW;i++) begin: VADDSUB_PROD32
      if (opcode==ADDSUB_VADD) 
        {cout32[i],product32[i]} = { ({cout16[2*i+1],product16[2*i+1]} + cout16[2*i]), product16[2*i] };
      else // opcode==ADDSUB_VSUB
        {cout32[i],product32[i]} = { ({cout16[2*i+1],product16[2*i+1]} - cout16[2*i]), product16[2*i] };
    end
  end 

  // VAADD/VASUB 平均类指令的舍入。
  // p0/p1 先得到完整加减结果，再按 vxrm 选择 RNU/RNE/RDN/ROD 四种舍入方式。
  // 无符号平均直接拼接 cout 作为最高位；有符号平均要结合源符号和 cout
  // 还原算术右移时需要的符号扩展位。
  always_comb begin
    round8_src  = 'b0;
    round16_src = 'b0;
    round32_src = 'b0;
    round8  = 'b0;
    round16 = 'b0;
    round32 = 'b0;
    
    case(uop_funct6.ari_funct6)
      VAADDU,
      VASUBU: begin  //平均加/减
        case(vxrm)
          RNU: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]};  //（a+b）>> 1
              round8[i]     = product8[i][0] ? round8_src[i]+1'b1 : round8_src[i];
            end

            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0] ? round16_src[i]+1'b1 : round16_src[i];
            end

            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0] ? round32_src[i]+1'b1 : round32_src[i];
            end
          end
          RNE: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0]&product8[i][1] ? round8_src[i]+1'b1 : round8_src[i];  //
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0]&product16[i][1] ? round16_src[i]+1'b1 : round16_src[i];
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0]&product32[i][1] ? round32_src[i]+1'b1 : round32_src[i];
            end
          end
          RDN: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]}; 
              round8[i]     = round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]}; 
              round16[i]     = round16_src[i];
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]}; 
              round32[i]     = round32_src[i];
            end
          end
          ROD: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = (!product8[i][1])&product8[i][0] ? round8_src[i]+1'b1 : round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = (!product16[i][1])&product16[i][0] ? round16_src[i]+1'b1 : round16_src[i]; 
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]}; 
              round32[i]     = (!product32[i][1])&product32[i][0] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
        endcase
      end
      VAADD,
      VASUB: begin
        case(vxrm)
          RNU: begin
            for(int i=0;i<`VLENB;i=i+1) begin  //处理符号位
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0] ? round8_src[i]+1'b1 : round8_src[i];                  
            end
            
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0] ? round16_src[i]+1'b1 : round16_src[i]; 
            end

            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
          RNE: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0]&product8[i][1] ? round8_src[i]+1'b1 : round8_src[i]; 
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0]&product16[i][1] ? round16_src[i]+1'b1 : round16_src[i]; 
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0]&product32[i][1] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
          RDN: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]}; 
              round8[i]     = round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]}; 
              round16[i]     = round16_src[i];
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]}; 
              round32[i]     = round32_src[i];
            end
          end
          ROD: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = (!product8[i][1])&product8[i][0] ? round8_src[i]+1'b1 : round8_src[i]; 
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = (!product16[i][1])&product16[i][0] ? round16_src[i]+1'b1 : round16_src[i]; 
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = (!product32[i][1])&product32[i][0] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
        endcase
      end
    endcase
  end

  // 饱和加减的溢出检测。
  // - 无符号加 VSADDU：进位 cout 表示上溢。
  // - 无符号减 VSSUBU：借位 cout 表示下溢。
  // - 有符号加/减：根据两个源符号和结果符号判断上溢/下溢。
  // 对 EEW16/EEW32，只在每个元素最低 byte 对应的位置标记有效饱和位，
  // 其它 byte 位置保持 0。
  generate 
    for (j=0;j<`VLENW;j++) begin: OVERFLOW
      always_comb begin
        // 默认无饱和，按当前 EEW 覆盖有效元素位置。
        addu_upoverflow[   4*j +: 4] = 'b0;  //无符号加法溢出 = carry out
        add_upoverflow[    4*j +: 4] = 'b0;  //有符号加法: 正溢出：正 + 正 = 负;负溢出：负 + 负 = 正
        add_underoverflow[ 4*j +: 4] = 'b0;  //负溢出：负 + 负 = 正
        subu_underoverflow[4*j +: 4] = 'b0;  //无符号减法负溢出，进位为负
        sub_upoverflow[    4*j +: 4] = 'b0;  //有符号减，正溢出：正 + 正 = 负
        sub_underoverflow[ 4*j +: 4] = 'b0;  //负溢出：负 + 负 = 正
          
        case(vs2_eew)
          EEW8: begin
            addu_upoverflow[4*j +: 4] = {cout8[4*j+3],cout8[4*j+2],cout8[4*j+1],cout8[4*j]};

            add_upoverflow[4*j +: 4] = {  //正溢出：正 + 正 = 负
              ((product8[4*j+3][`BYTE_WIDTH-1])&(!src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              ((product8[4*j+2][`BYTE_WIDTH-1])&(!src2_sgn[4*j+2])&(!src1_sgn[4*j+2])),
              ((product8[4*j+1][`BYTE_WIDTH-1])&(!src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              ((product8[4*j  ][`BYTE_WIDTH-1])&(!src2_sgn[4*j  ])&(!src1_sgn[4*j  ]))};

            add_underoverflow[4*j +: 4] = {  //负溢出：负 + 负 = 正
              ((!product8[4*j+3][`BYTE_WIDTH-1])&(src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              ((!product8[4*j+2][`BYTE_WIDTH-1])&(src2_sgn[4*j+2])&(src1_sgn[4*j+2])),
              ((!product8[4*j+1][`BYTE_WIDTH-1])&(src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              ((!product8[4*j  ][`BYTE_WIDTH-1])&(src2_sgn[4*j  ])&(src1_sgn[4*j  ]))};
            
            subu_underoverflow[4*j +: 4] = {cout8[4*j+3],cout8[4*j+2],cout8[4*j+1],cout8[4*j]};

            sub_upoverflow[4*j +: 4] = {
              ((product8[4*j+3][`BYTE_WIDTH-1])&(!src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              ((product8[4*j+2][`BYTE_WIDTH-1])&(!src2_sgn[4*j+2])&(src1_sgn[4*j+2])),
              ((product8[4*j+1][`BYTE_WIDTH-1])&(!src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              ((product8[4*j  ][`BYTE_WIDTH-1])&(!src2_sgn[4*j  ])&(src1_sgn[4*j  ]))};

            sub_underoverflow[4*j +: 4] = {
              ((!product8[4*j+3][`BYTE_WIDTH-1])&(src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              ((!product8[4*j+2][`BYTE_WIDTH-1])&(src2_sgn[4*j+2])&(!src1_sgn[4*j+2])),
              ((!product8[4*j+1][`BYTE_WIDTH-1])&(src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              ((!product8[4*j  ][`BYTE_WIDTH-1])&(src2_sgn[4*j  ])&(!src1_sgn[4*j  ]))};
          end
          EEW16: begin
            addu_upoverflow[4*j +: 4] = {cout16[2*j+1],1'b0,cout16[2*j],1'b0};

            add_upoverflow[4*j +: 4] = {
              ((product16[2*j+1][`HWORD_WIDTH-1])&(!src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              1'b0,
              ((product16[2*j  ][`HWORD_WIDTH-1])&(!src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              1'b0};

            add_underoverflow[4*j +: 4] = {
              ((!product16[2*j+1][`HWORD_WIDTH-1])&(src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              1'b0,
              ((!product16[2*j  ][`HWORD_WIDTH-1])&(src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              1'b0};

            subu_underoverflow[4*j +: 4] = {cout16[2*j+1],1'b0,cout16[2*j],1'b0};

            sub_upoverflow[4*j +: 4] = {
              ((product16[2*j+1][`HWORD_WIDTH-1])&(!src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              1'b0,
              ((product16[2*j  ][`HWORD_WIDTH-1])&(!src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              1'b0};

            sub_underoverflow[4*j +: 4] = {
              ((!product16[2*j+1][`HWORD_WIDTH-1])&(src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              1'b0,
              ((!product16[2*j  ][`HWORD_WIDTH-1])&(src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              1'b0};
          end
          EEW32: begin
            addu_upoverflow[4*j +: 4] = {cout32[j],3'b0};

            add_upoverflow[4*j +: 4] = {
              ((product32[j][`WORD_WIDTH-1])&(!src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              3'b0};

            add_underoverflow[4*j +: 4] = {
              ((!product32[j][`WORD_WIDTH-1])&(src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              3'b0};

            subu_underoverflow[4*j +: 4] = {cout32[j],3'b0};

            sub_upoverflow[4*j +: 4] = {
              ((product32[j][`WORD_WIDTH-1])&(!src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              3'b0};

            sub_underoverflow[4*j +: 4] = {
              ((!product32[j][`WORD_WIDTH-1])&(src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              3'b0};
          end
        endcase
      end
    end
  endgenerate

  generate 
    if(CMP_SUPPORT) begin  //生成mask bit
      // 比较类结果生成。
      // product8/16/32 是 src2-src1 的差值：等于零用于 VMSEQ/VMSNE，
      // 符号位和源符号组合用于有符号/无符号大小比较。
      // cmp_en 标记非最后 uop 的有效分段，后面通过 cmp_d1 暂存。
      always_comb begin
        cmp_tmp = 'b0;
        cmp     = 'b0;
        cmp_en  = 'b0;
        
        for(int i=0;i<`VLENW;i++) begin
          // 计算当前 uop 覆盖的比较 bit 分段。
          case(uop_funct6.ari_funct6)
            VMSEQ,  //不相等
            VMSNE: begin  //相等
              case(vs2_eew)
                EEW8: begin
                  cmp_tmp[(4*uop_index  )*`VLENW+i] = |(product8[0*`VLENW+i]);  //用于判断相等，0：相等
                  cmp_tmp[(4*uop_index+1)*`VLENW+i] = |(product8[1*`VLENW+i]);
                  cmp_tmp[(4*uop_index+2)*`VLENW+i] = |(product8[2*`VLENW+i]);
                  cmp_tmp[(4*uop_index+3)*`VLENW+i] = |(product8[3*`VLENW+i]);

                  cmp[(4*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index)*`VLENW+i];
                  cmp[(4*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index+1)*`VLENW+i];
                  cmp[(4*uop_index+2)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index+2)*`VLENW+i];
                  cmp[(4*uop_index+3)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index+3)*`VLENW+i];

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp_tmp[(2*uop_index  )*`VLENW+i] = |(product16[0*`VLENW+i]);
                  cmp_tmp[(2*uop_index+1)*`VLENW+i] = |(product16[1*`VLENW+i]);

                  cmp[(2*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] : 
                                                    !cmp_tmp[(2*uop_index)*`VLENW+i];
                  cmp[(2*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] : 
                                                    !cmp_tmp[(2*uop_index+1)*`VLENW+i];

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp_tmp[uop_index*`VLENW+i] = |(product32[`VLENW*0+i]);

                  cmp[uop_index*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                              cmp_tmp[uop_index*`VLENW+i] : 
                                              !cmp_tmp[uop_index*`VLENW+i];

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase
            end
            VMADC,
            VMSBC: begin
              case(vs2_eew)
                EEW8: begin
                  cmp[(4*uop_index  )*`VLENW+i] = cout8[0*`VLENW+i];
                  cmp[(4*uop_index+1)*`VLENW+i] = cout8[1*`VLENW+i];
                  cmp[(4*uop_index+2)*`VLENW+i] = cout8[2*`VLENW+i];
                  cmp[(4*uop_index+3)*`VLENW+i] = cout8[3*`VLENW+i];

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp[(2*uop_index  )*`VLENW+i] = cout16[0*`VLENW+i];
                  cmp[(2*uop_index+1)*`VLENW+i] = cout16[1*`VLENW+i];

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp[uop_index*`VLENW+i] = cout32[`VLENW*0+i];

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase
            end
            VMSLT,
            VMSLE,
            VMSGT: begin
              case(vs2_eew)
                EEW8: begin //如果发生负向下溢，说明 src2 < src1；否则如果没有正向溢出，再用差值符号判断。
                  cmp_tmp[(4*uop_index  )*`VLENW+i] = sub_underoverflow[0*`VLENW+i] || 
                                                      (!sub_upoverflow[0*`VLENW+i]) && product8[0*`VLENW+i][`BYTE_WIDTH-1];
                  cmp_tmp[(4*uop_index+1)*`VLENW+i] = sub_underoverflow[1*`VLENW+i] || 
                                                      (!sub_upoverflow[1*`VLENW+i]) && product8[1*`VLENW+i][`BYTE_WIDTH-1];
                  cmp_tmp[(4*uop_index+2)*`VLENW+i] = sub_underoverflow[2*`VLENW+i] || 
                                                      (!sub_upoverflow[2*`VLENW+i]) && product8[2*`VLENW+i][`BYTE_WIDTH-1];
                  cmp_tmp[(4*uop_index+3)*`VLENW+i] = sub_underoverflow[3*`VLENW+i] || 
                                                      (!sub_upoverflow[3*`VLENW+i]) && product8[3*`VLENW+i][`BYTE_WIDTH-1];

                  cmp[(4*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] | (!(|product8[0*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] ;
                  cmp[(4*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] | (!(|product8[1*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] ;
                  cmp[(4*uop_index+2)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] | (!(|product8[2*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] ;
                  cmp[(4*uop_index+3)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] | (!(|product8[3*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] ;

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp_tmp[(2*uop_index  )*`VLENW+i] = sub_underoverflow[0*`VLENW+2*i+1] || 
                                                      (!sub_upoverflow[0*`VLENW+2*i+1]) && product16[0*`VLENW+i][`HWORD_WIDTH-1];
                  cmp_tmp[(2*uop_index+1)*`VLENW+i] = sub_underoverflow[2*`VLENW+2*i+1] || 
                                                      (!sub_upoverflow[2*`VLENW+2*i+1]) && product16[1*`VLENW+i][`HWORD_WIDTH-1];

                  cmp[(2*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] | (!(|product16[0*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] ;
                  cmp[(2*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] | (!(|product16[1*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] ;

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp_tmp[uop_index*`VLENW+i] = sub_underoverflow[4*i+3] ||
                                                (!sub_upoverflow[4*i+3]) && product32[i][`WORD_WIDTH-1];

                  cmp[uop_index*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                              cmp_tmp[uop_index*`VLENW+i] | (!(|product32[i])) :
                                              cmp_tmp[uop_index*`VLENW+i] ;

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase     
            end
            VMSLTU,
            VMSLEU,
            VMSGTU: begin
              case(vs2_eew)
                EEW8: begin
                  cmp_tmp[(4*uop_index  )*`VLENW+i] = subu_underoverflow[0*`VLENW+i] || cout8[0*`VLENW+i];
                  cmp_tmp[(4*uop_index+1)*`VLENW+i] = subu_underoverflow[1*`VLENW+i] || cout8[1*`VLENW+i];
                  cmp_tmp[(4*uop_index+2)*`VLENW+i] = subu_underoverflow[2*`VLENW+i] || cout8[2*`VLENW+i];
                  cmp_tmp[(4*uop_index+3)*`VLENW+i] = subu_underoverflow[3*`VLENW+i] || cout8[3*`VLENW+i];

                  cmp[(4*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] | (!(|product8[0*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] ;
                  cmp[(4*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] | (!(|product8[1*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] ;
                  cmp[(4*uop_index+2)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] | (!(|product8[2*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] ;
                  cmp[(4*uop_index+3)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] | (!(|product8[3*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] ;

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp_tmp[(2*uop_index  )*`VLENW+i] = subu_underoverflow[0*`VLENW+2*i+1] || cout16[0*`VLENW+i];
                  cmp_tmp[(2*uop_index+1)*`VLENW+i] = subu_underoverflow[2*`VLENW+2*i+1] || cout16[1*`VLENW+i];

                  cmp[(2*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] | (!(|product16[0*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] ;
                  cmp[(2*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] | (!(|product16[1*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] ;

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp_tmp[uop_index*`VLENW+i] = subu_underoverflow[4*i+3] || cout32[i];

                  cmp[uop_index*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                              cmp_tmp[uop_index*`VLENW+i] | (!(|product32[i])) :
                                              cmp_tmp[uop_index*`VLENW+i] ;

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase  
            end
          endcase
        end
      end

      for(j=0;j<28;j++) begin  //总共32组8位，最后一组不需要暂存
        cdffr # (
          .T            (logic [`VLENW-1:0])
        ) cmp_pipe ( 
          .q            (cmp_d1[j*`VLENW +: `VLENW]),   //!last_uop_valid时暂存
          .clk          (clk), 
          .rst_n        (rst_n),  
          .c            (alu_uop_valid&is_cmp&last_uop_valid | trap_flush_rvv), 
          .e            (cmp_en[j]), 
          .d            (cmp[j*`VLENW +: `VLENW]) 
        );
      end

      assign cmp_res_tmp      = {cmp[`VLEN-1:28*`VLENW], (cmp[28*`VLENW-1:0]|cmp_d1)};  //补上last_uop_valid数据，合并后的完整比较结果向量

      barrel_shifter #(.DATA_WIDTH(`VLEN))  //左移vstart
      u_prestart (.din((`VLEN)'('1)), .shift_amount(vstart[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vstart_elements_tmp));
      barrel_shifter #(.DATA_WIDTH(`VLEN))  //左移vl
      u_tail (.din((`VLEN)'('1)), .shift_amount(vl[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(tail_elements_tmp));
      // vstart_elements[j] = 1 表示 j < vstart，不能改
      // tail_elements[j]   = 1 表示 j >= vl，属于 tail，不能改
      assign vstart_elements  = ~vstart_elements_tmp;
      assign tail_elements    = vl[$clog2(`VLEN)] ? 'b0 : tail_elements_tmp;  //如果 vl 值已经达到或超过 VLEN（最高位为 1），则整个寄存器都是 body，没有尾部

      for(j=0;j<`VLEN;j++) begin: CMP_MERGE
        // 有效 body 元素 
        // & vm 为 1 表示指令不需要掩码（无条件更新所有 body 元素）；若 vm=0，则使用 v0 寄存器的对应位作为掩码，仅当 v0_data[j]=1 时才更新。
        // 当元素在 body 内 且 未被屏蔽时：cmp_res[j] = cmp_res_tmp[j]（采用合并后的比较结果）。
        // 否则：cmp_res[j] = vd_data[j]（保持目标寄存器旧值）
        assign cmp_res[j]       = !(vstart_elements[j]|tail_elements[j]) & (vm|v0_data[j]) ? cmp_res_tmp[j] : vd_data[j];  //目标寄存器 vd 的旧数据
        // 如果是 prestart 或 tail 元素：保持原值。
        // 否则（body 元素）：直接写入 cmp_res_tmp[j]，不受 vm/v0 控制。
        assign vmadcsbc_res[j]  = vstart_elements[j]|tail_elements[j] ? vd_data[j] : cmp_res_tmp[j];  //另一种结果输出（推测用于 vmadc/vsbc 的进位/借位写回）
      end
    end

    // 根据 funct6 选择最终写回数据。
    // 普通加减直接选择 product8/16/32；饱和类在检测到溢出时裁剪到
    // 最大/最小值；比较类输出合并后的 mask；min/max 使用 p0 保留的
    // 原始 src2/src1 和比较结果选择元素。
    for (j=0;j<`VLENW;j++) begin: GET_RESULT_DATA
      always_comb begin
        // 默认透传 p0 数据，匹配到 addsub 支持的 funct6 时覆盖。
        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = alu_uop.w_data[j*`WORD_WIDTH +: `WORD_WIDTH];
        result_minmax8[4*j+3]  = 'b0;
        result_minmax8[4*j+2]  = 'b0;
        result_minmax8[4*j+1]  = 'b0;
        result_minmax8[4*j]    = 'b0;
        result_minmax16[2*j+1] = 'b0;
        result_minmax16[2*j]   = 'b0;
        result_minmax32[j]     = 'b0;
 
        if(CMP_SUPPORT) begin
          // 支持比较 lane：普通算术、饱和、比较、VMADC/VMSBC、min/max 都在此选择结果。
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADD,
                VSUB,
                VRSUB,
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product8[4*j+3],product8[4*j+2],product8[4*j+1],product8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1],product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end
                
                VSADDU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(addu_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(addu_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'hffff_ffff;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSADD: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (add_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (add_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VSSUBU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(subu_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(subu_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (sub_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (sub_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VMADC,
                VMSBC: begin
                  result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = vmadcsbc_res[j*`WORD_WIDTH +: `WORD_WIDTH];
                end

                VMSEQ,
                VMSNE,
                VMSLTU,
                VMSLT,
                VMSLEU,
                VMSLE,
                VMSGTU,
                VMSGT: begin
                  result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = cmp_res[j*`WORD_WIDTH +: `WORD_WIDTH];
                end

                VMINU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src2_data[4*j+3] : src1_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src2_data[4*j+2] : src1_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src2_data[4*j  ] : src1_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src2_data[4*j+1],src2_data[4*j  ]} : {src1_data[4*j+1],src1_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}: 
                                                       {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMIN: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j] = src2_data[4*j];
                        2'b01  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src2_data[4*j] : src1_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b01  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b01  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src2_data[4*j+2] : src1_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b01  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src2_data[4*j+3] : src1_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src2_data[4*j+1],src2_data[4*j]} : {src1_data[4*j+1],src1_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b01  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}:
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAXU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src1_data[4*j+3] : src2_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src1_data[4*j+2] : src2_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src1_data[4*j  ] : src2_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src1_data[4*j+1],src1_data[4*j  ]} : {src2_data[4*j+1],src2_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}: 
                                                       {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAX: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j] = src2_data[4*j];
                        2'b10  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src1_data[4*j] : src2_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b10  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b10  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src1_data[4*j+2] : src2_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b10  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src1_data[4*j+3] : src2_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src1_data[4*j+1],src1_data[4*j]} : {src2_data[4*j+1],src2_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b10  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}:
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end        
              endcase
            end
            
            OPMVV,
            OPMVX: begin
              case(uop_funct6.ari_funct6)
                VWADDU,
                VWSUBU,
                VWADD,
                VWSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VWADDU_W,
                VWSUBU_W,
                VWADD_W,
                VWSUB_W: begin
                  case(vs2_eew)
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VAADDU,
                VAADD,
                VASUBU,
                VASUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round8[4*j+3], round8[4*j+2], round8[4*j+1], round8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round16[2*j+1], round16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = round32[j];
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        else begin
          // 不支持比较 lane：保留普通算术、饱和、min/max、拓宽和平均类结果选择。
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADD,
                VSUB,
                VRSUB,
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product8[4*j+3],product8[4*j+2],product8[4*j+1],product8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1],product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end
                
                VSADDU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(addu_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(addu_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'hffff_ffff;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSADD: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (add_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (add_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VSSUBU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(subu_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(subu_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (sub_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (sub_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VMINU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src2_data[4*j+3] : src1_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src2_data[4*j+2] : src1_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src2_data[4*j  ] : src1_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src2_data[4*j+1],src2_data[4*j  ]} : {src1_data[4*j+1],src1_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}: 
                                                       {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMIN: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j] = src2_data[4*j];
                        2'b01  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src2_data[4*j] : src1_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b01  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b01  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src2_data[4*j+2] : src1_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b01  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src2_data[4*j+3] : src1_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src2_data[4*j+1],src2_data[4*j]} : {src1_data[4*j+1],src1_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b01  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}:
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAXU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src1_data[4*j+3] : src2_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src1_data[4*j+2] : src2_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src1_data[4*j  ] : src2_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src1_data[4*j+1],src1_data[4*j  ]} : {src2_data[4*j+1],src2_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}: 
                                                       {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAX: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j] = src2_data[4*j];
                        2'b10  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src1_data[4*j] : src2_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b10  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b10  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src1_data[4*j+2] : src2_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b10  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src1_data[4*j+3] : src2_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src1_data[4*j+1],src1_data[4*j]} : {src2_data[4*j+1],src2_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b10  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}:
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end        
              endcase
            end
            
            OPMVV,
            OPMVX: begin
              case(uop_funct6.ari_funct6)
                VWADDU,
                VWSUBU,
                VWADD,
                VWSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VWADDU_W,
                VWSUBU_W,
                VWADD_W,
                VWSUB_W: begin
                  case(vs2_eew)
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VAADDU,
                VAADD,
                VASUBU,
                VASUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round8[4*j+3], round8[4*j+2], round8[4*j+1], round8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round16[2*j+1], round16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = round32[j];
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
      end
    end
  endgenerate


//
// 输出最终结果到 ROB
//
  // 组装 PU2ROB_t。若当前包来自 addsub 路径，则使用本级生成的 result_data；
  // 否则透传其它路径已经带入 PIPE_DATA_t 的写回字段。
  always_comb begin
    // 默认结果：普通 addsub 写回数据有效，饱和标志先清零。
  `ifdef TB_SUPPORT
    result.uop_pc    = alu_uop.uop_pc;
  `endif
    result.rob_entry = alu_uop.rob_entry;
    result.w_valid   = alu_uop.is_addsub ? 'b1 : alu_uop.w_valid; 
    result.w_data    = alu_uop.is_addsub ? result_data : alu_uop.w_data; 
    result.vsaturate = alu_uop.is_addsub ? 'b0 : alu_uop.vsat_cout.vsaturate;
  `ifdef ZVE32F_ON
    result.fpexp     = 'b0;
  `endif

    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VSADDU: begin
            result.vsaturate = addu_upoverflow;
          end
          VSADD: begin
            result.vsaturate = add_upoverflow|add_underoverflow;
          end
          VSSUBU: begin
            result.vsaturate = subu_underoverflow;
          end
          VSSUB: begin
            result.vsaturate = sub_upoverflow|sub_underoverflow;
          end
        endcase
      end
    endcase
  end

endmodule
