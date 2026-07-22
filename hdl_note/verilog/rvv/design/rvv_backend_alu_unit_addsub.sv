
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef ALU_DEFINE_SVH
`include "rvv_backend_alu.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_alu_unit_addsub
//------------------------------------------------------------------------------
// 功能定位：
// 1. 这是 RVV ALU 加减路径的 p0 阶段，输入来自 ALU RS 的 `ALU_RS_t`。
// 2. 本模块不直接写 ROB，而是输出 `PIPE_DATA_t` 给后一级
//    `rvv_backend_alu_unit_execution_p1`。
// 3. p0 只完成源操作数重排、标量广播、加/减方向选择、byte 级加减和
//    中间进位/符号信息保存；16/32 位进位归并、饱和裁剪、比较 mask 合并、
//    min/max 选择和最终 ROB 写回都在 p1 完成。
// 4. `CMP_SUPPORT` 控制是否接收 VMADC/VMSBC/VMSEQ/VMSNE/VMSLT/VMSLE/VMSGT
//    等比较或 mask 生成类指令。顶层通常只给部分 lane 打开该参数。
//
// 指令覆盖范围：
// - 普通加减：VADD/VSUB/VRSUB/VADC/VSBC。
// - 饱和加减：VSADDU/VSADD/VSSUBU/VSSUB。
// - 比较和 mask 生成：VMADC/VMSBC/VMSEQ/VMSNE/VMSLT*/VMSLE*/VMSGT*。
// - min/max：VMINU/VMIN/VMAXU/VMAX。
// - 拓宽和平均：VWADD*/VWSUB*、VAADD*/VASUB*。
//
// 宏阅读提示：
// - `BYTE_WIDTH` 为 8；`XLEN` 为 32。
// - `EMUL_MAX` 为最大 EMUL/LMUL 展开系数。
// - `VLEN` 不在本 design 文件中固定，需由 VLEN_128/VLEN_256/VLEN_512/
//   VLEN_1024 等编译宏决定；`VLENB`=`VLEN/8，`VLENW`=`VLEN/32。

module rvv_backend_alu_unit_addsub
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
  parameter CMP_SUPPORT = 1'b0;

//
// 接口信号
//
  // ALU RS 输入：valid 和完整 uop 内容。
  input   logic                           alu_uop_valid;
  input   ALU_RS_t                        alu_uop;
  // p0 到 p1 的流水中间结果，不是最终 ROB 写回包。
  output  logic                           result_valid;
  output  PIPE_DATA_t                     result;

//
// 内部信号
//
  // 从 ALU_RS_t 拆出的控制字段和源操作数。
  FUNCT6_u                                uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]             uop_funct3;
  logic                                   vm; 
  logic   [`VLEN-1:0]                     v0_data;
  logic   [`VLEN-1:0]                     vs1_data;           
  logic   [`VLEN-1:0]                     vs2_data;	        
  EEW_e                                   vs2_eew;
  logic   [`XLEN-1:0] 	                  rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0]         uop_index;          

  // p0 执行用的 byte 粒度数据通路。
  // src*_data 是实际参与加减的两个源；product8/cout8 保存每个 byte 的初算结果。
  logic   [`VLENB-1:0]                    v0_data_in_use;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src2_data;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src1_data;
  logic   [`VLENB-1:0]                    src2_sgn;
  logic   [`VLENB-1:0]                    src1_sgn;
  logic   [`VLENB-1:0]                    cin;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   product8;
  logic   [`VLENB-1:0]                    cout8;
  ADDSUB_e                                opcode;
  
  // generate 循环变量。
  genvar                                  j;

//
// 拆分 uop，准备计算需要的公共字段
//
  // 将 ALU_RS_t 中的字段转成本模块内部信号，后续组合逻辑只引用这些内部名。
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vm             = alu_uop.vm;  
  assign  v0_data        = alu_uop.v0_data;
  assign  vs1_data       = alu_uop.vs1_data;
  assign  rs1_data       = alu_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data       = alu_uop.vs2_data;
  assign  vs2_eew        = alu_uop.vs2_eew;
  assign  uop_index      = alu_uop.uop_index;

//  
// 准备源操作数
//
  generate
    // result_valid 只表示当前 uop 属于本加减单元可处理的指令集合。
    // 当 CMP_SUPPORT=0 时，比较/mask 生成类指令不会从该 lane 发出有效结果。
    always_comb begin
      // 默认无效，只有匹配到支持的 funct3/funct6 组合才拉高。
      result_valid = 'b0;

      if(CMP_SUPPORT) begin
        case(uop_funct3) 
          OPIVV: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VRSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VRSUB,
              VSADD,
              VSADDU,
              VADC,
              VMADC,
              VMSEQ,
              VMSNE,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
      else begin
        case(uop_funct3) 
          OPIVV: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VRSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VRSUB,
              VSADD,
              VSADDU,
              VADC: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
    end

    // 根据指令类型整理真实参与加减的两个源。
    // - OPIVV 直接使用 vs2/vs1。
    // - OPIVX/OPIVI 会把 rs1/imm 按 EEW 广播到每个元素。
    // - VRSUB、VMSGT* 通过交换 src2/src1，把“反向减”或“大于比较”
    //   统一映射成后续 subtract/less-equal 风格的数据通路。
    // - 拓宽指令根据 uop_index 选择低/高半段，并按有符号/无符号扩展。
    always_comb begin
      // 默认按向量-向量形式取源，特殊形式在下面覆盖。
      src2_data = vs2_data;
      src1_data = vs1_data;

      if(CMP_SUPPORT) begin
        case(uop_funct3) 
          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VADC,
              VSBC,
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VSADDU,
              VSADD,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                for(int i=0;i<`VLENW;i=i+1) begin  //`VLENW`=`VLEN/32
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VMSGTU,
              VMSGT,
              VRSUB: begin  //VRSUB、VMSGT* 通过交换 src2/src1，把“反向减”或“大于比较”
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
                
                src1_data = vs2_data;
              end
            endcase
          end

          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VADC,          
              VMADC,
              VMSEQ,
              VMSNE,
              VMSLEU,
              VMSLE,
              VSADDU,
              VSADD: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VMSGTU,
              VMSGT,
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end

                src1_data = vs2_data;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin  //加宽后，再相加
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W, 
              VWSUBU_W: begin  //vs1加宽
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0; 
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin  //vs1加宽
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}}; 
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =  rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;
                    end
                    EEW32: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                    end
                    EEW32: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] =              rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                    end
                  endcase
                end
              end

              VAADDU,
              VASUBU,
              VAADD,
              VASUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
            endcase
          end
        endcase
      end
      else begin
        case(uop_funct3) 
          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VADC,
              VSBC,
              VSADDU,
              VSADD,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
                
                src1_data = vs2_data;
              end
            endcase
          end

          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VADC,          
              VSADDU,
              VSADD: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end

                src1_data = vs2_data;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0; 
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}}; 
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =  rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;
                    end
                    EEW32: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                    end
                    EEW32: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] =              rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                    end
                  endcase
                end
              end

              VAADDU,
              VASUBU,
              VAADD,
              VASUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

  // 记录每个 byte 的符号位。p1 会用这些符号位判断有符号饱和上溢/下溢、
  // 有符号比较，以及 min/max 的选择方向。
  always_comb begin
    src2_sgn = 'b0;
    src1_sgn = 'b0;

    for(int i=0;i<`VLENB;i++) begin
      src2_sgn[i] = src2_data[i][`BYTE_WIDTH-1];  //区8位最高位，后续8、16、32看真实情况选择使用
      src1_sgn[i] = src1_data[i][`BYTE_WIDTH-1];
    end
  end
 
  // 从 v0 中取出当前 uop 对应的 mask/carry 片段。
  // VADC/VSBC 直接使用 v0 作为 carry/borrow 输入；
  // VMADC/VMSBC 在 vm=0 时使用 v0，vm=1 时等价于无 mask carry 输入。
  always_comb begin
    v0_data_in_use = 'b0;

    case(vs2_eew)
      EEW8: begin
        v0_data_in_use = v0_data[{uop_index,{($clog2(`VLENB)){1'b0}}} +: `VLENB];  //VLENB对应一个uop_index的掩码
      end
      EEW16: begin
        v0_data_in_use = (`VLENB)'(v0_data[{uop_index,{($clog2(`VLENB/2)){1'b0}}} +: `VLENB/2]);
      end
      EEW32: begin
        v0_data_in_use = (`VLENB)'(v0_data[{uop_index,{($clog2(`VLENB/4)){1'b0}}} +: `VLENB/4]);
      end
    endcase
  end

  generate
    for (j=0;j<`VLENW;j=j+1) begin: GET_CIN
      always_comb begin
        // 默认没有 carry/borrow。16/32 位元素只在最低 byte 放入 cin，
        // 高 byte 的跨 byte 进位由 p1 根据 cout8 重新归并。
        cin[4*j]   = 'b0;
        cin[4*j+1] = 'b0;
        cin[4*j+2] = 'b0;
        cin[4*j+3] = 'b0;

        if(CMP_SUPPORT) begin
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADC,
                VSBC: begin  //v0固定，VADC/VSBC 直接使用 v0 作为 carry/borrow 输入；
                  case(vs2_eew)
                    EEW8: begin                    
                      cin[4*j]   = v0_data_in_use[4*j];
                      cin[4*j+1] = v0_data_in_use[4*j+1];
                      cin[4*j+2] = v0_data_in_use[4*j+2];
                      cin[4*j+3] = v0_data_in_use[4*j+3];
                    end
                    EEW16: begin
                      cin[4*j]   = v0_data_in_use[2*j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = v0_data_in_use[2*j+1];
                      cin[4*j+3] = 'b0;
                    end
                    EEW32: begin
                      cin[4*j]   = v0_data_in_use[j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = 'b0;
                      cin[4*j+3] = 'b0;
                    end
                  endcase
                end
                VMADC,
                VMSBC: begin  //依赖vm指定
                  case(vs2_eew)
                    EEW8: begin                    
                      cin[4*j]   = vm ? 'b0 : v0_data_in_use[4*j];
                      cin[4*j+1] = vm ? 'b0 : v0_data_in_use[4*j+1];
                      cin[4*j+2] = vm ? 'b0 : v0_data_in_use[4*j+2];
                      cin[4*j+3] = vm ? 'b0 : v0_data_in_use[4*j+3];
                    end
                    EEW16: begin
                      cin[4*j]   = vm ? 'b0 : v0_data_in_use[2*j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = vm ? 'b0 : v0_data_in_use[2*j+1];
                      cin[4*j+3] = 'b0;
                    end
                    EEW32: begin
                      cin[4*j]   = vm ? 'b0 : v0_data_in_use[j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = 'b0;
                      cin[4*j+3] = 'b0;
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        else begin
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin                    
                      cin[4*j]   = v0_data_in_use[4*j];
                      cin[4*j+1] = v0_data_in_use[4*j+1];
                      cin[4*j+2] = v0_data_in_use[4*j+2];
                      cin[4*j+3] = v0_data_in_use[4*j+3];
                    end
                    EEW16: begin
                      cin[4*j]   = v0_data_in_use[2*j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = v0_data_in_use[2*j+1];
                      cin[4*j+3] = 'b0;
                    end
                    EEW32: begin
                      cin[4*j]   = v0_data_in_use[j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = 'b0;
                      cin[4*j+3] = 'b0;
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
      end
    end

    // 将不同 funct6 归约为两种硬件运算方向：
    // - ADDSUB_VADD：src2 + src1 + cin。
    // - ADDSUB_VSUB：src2 - src1 - cin。
    // 比较、min/max、饱和减等都先复用 subtract 的差值和进位信息，
    // 最终语义由 p1 再根据 funct6 解释。
    always_comb begin
      // 默认加法，匹配到减法/比较/minmax 类时覆盖。
      opcode = ADDSUB_VADD;

      if(CMP_SUPPORT) begin
        // 支持比较 lane 时，比较/mask 生成类也进入 subtract 路径。
        case(uop_funct3) 
          OPIVV,
          OPIVX,
          OPIVI: begin
            case(uop_funct6.ari_funct6)    
              VADD,
              VADC,
              VMADC,
              VSADDU,
              VSADD: begin
                opcode = ADDSUB_VADD;
              end

              VSUB,
              VRSUB,
              VSBC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
          OPMVV,
          OPMVX: begin
            case(uop_funct6.ari_funct6)    
              VWADDU,
              VWADD,
              VWADDU_W,
              VWADD_W,
              VAADDU,
              VAADD: begin
                opcode = ADDSUB_VADD;
              end
              VWSUBU,
              VWSUB,
              VWSUBU_W,
              VWSUB_W,
              VASUBU,
              VASUB: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
        endcase
      end
      else begin
        // 不支持比较 lane 时，只保留普通加减、饱和、min/max、拓宽和平均类。
        case(uop_funct3) 
          OPIVV,
          OPIVX,
          OPIVI: begin
            case(uop_funct6.ari_funct6)    
              VADD,
              VADC,
              VSADDU,
              VSADD: begin
                opcode = ADDSUB_VADD;
              end

              VSUB,
              VRSUB,
              VSBC,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
          OPMVV,
          OPMVX: begin
            case(uop_funct6.ari_funct6)    
              VWADDU,
              VWADD,
              VWADDU_W,
              VWADD_W,
              VAADDU,
              VAADD: begin
                opcode = ADDSUB_VADD;
              end
              VWSUBU,
              VWSUB,
              VWSUBU_W,
              VWSUB_W,
              VASUBU,
              VASUB: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

//    
// p0 执行：byte 级基础加/减
//
  // 每个 byte 独立计算 product8/cout8。对于 EEW16/EEW32，byte 间真实进位
  // 暂时不在本级完全展开，p1 会用 cout8 归并成 product16/product32。
  always_comb begin
    for(int i=0;i<`VLENB;i++) begin: VADDSUB_PROD8
      if (opcode==ADDSUB_VADD) 
        {cout8[i],product8[i]} = (`BYTE_WIDTH+1)'(src2_data[i]) + (`BYTE_WIDTH+1)'(src1_data[i]) + cin[i];
      else // opcode==ADDSUB_VSUB
        {cout8[i],product8[i]} = (`BYTE_WIDTH+1)'(src2_data[i]) - (`BYTE_WIDTH+1)'(src1_data[i]) - cin[i];      
    end
  end

//
// 输出 p0 到 p1 的流水数据
//
  // 注意这里的 result 是 PIPE_DATA_t，不是最终 PU2ROB_t：
  // - w_data 临时保存 product8。
  // - vsat_cout.cout 临时保存 cout8。
  // - v0_src2/src2 与 vd_src1/src1 给 p1 的比较、mask 合并和 min/max 使用。
  `ifdef TB_SUPPORT
    assign result.uop_pc          = alu_uop.uop_pc;
  `endif
    assign result.rob_entry       = alu_uop.rob_entry;
    assign result.opcode          = opcode;
    assign result.uop_funct6      = alu_uop.uop_funct6;
    assign result.uop_funct3      = alu_uop.uop_funct3;
    assign result.is_addsub       = 'b1;
    assign result.is_cmp          = alu_uop.is_cmp;
    assign result.vstart          = alu_uop.vstart;
    assign result.vl              = alu_uop.vl;
    assign result.vm              = alu_uop.vm;
    assign result.vxrm            = alu_uop.vxrm;
    assign result.vs2_eew         = alu_uop.vs2_eew;
    assign result.w_valid         = 'b0;
    assign result.src2_sgn        = src2_sgn;
    assign result.src1_sgn        = src1_sgn;
    assign result.last_uop_valid  = alu_uop.last_uop_valid;
    assign result.uop_index       = alu_uop.uop_index;
    assign result.w_data          = product8;
    assign result.vsat_cout.cout  = cout8;
    
    always_comb begin
      result.v0_src2.v0 = v0_data;
      result.vd_src1.vd = alu_uop.vd_data;  //寄存器旧值

      case(uop_funct3) 
        OPIVV,
        OPIVX: begin
          case(uop_funct6.ari_funct6)
            VMINU,
            VMIN,
            VMAXU,
            VMAX: begin  //传输给p1进行比较结果选取
              result.v0_src2.src2 = src2_data;
              result.vd_src1.src1 = src1_data;
            end
          endcase
        end
      endcase
    end

endmodule
