
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 功能说明：
// 1. `rvv_backend_alu_unit_other` 是 ALU p0 阶段的 move/merge/extend 类执行单元。
// 2. 它覆盖不属于 add/sub、shift、mask 的简单组合类指令，例如 VMERGE/VMV、VMVNRR、VZEXT/VSEXT、VMV.X.S、VMV.S.X。
// 3. 打开 `ZVE32F_ON` 时，还覆盖 VFMERGE/VFMV 以及浮点标量/向量 move 的 32 位形式。
// 4. 本模块直接输出 `PU2ROB_t`，不经过 ALU p1；后级 ready/pop 由上层 `rvv_backend_alu_unit` 仲裁。
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_alu_unit_other` -> RVV 后端 EX/ALU p0 子单元。
// - 接口与数据流：
//   * 输入：`alu_uop_valid/alu_uop`，操作数、mask、EEW、uop_index、ROB entry 已由 dispatch/RS 准备好。
//   * 处理：根据 funct3/funct6/vs1_opcode/vm 选择 move、merge、符号/零扩展或标量搬运路径。
//   * 输出：`result_valid/result`，结果写入 `result.w_data`；本模块不产生饱和和浮点异常标志。
// - 调用关系：上层 rvv_backend_alu_unit；无下层实例。
// - 端口摘要：输入 alu_uop_valid, alu_uop；输出 result_valid, result。
// - 指令分组：
//   * VMERGE_VMV：`vm=0` 时执行 vmerge，按 v0 mask 在 vs2/src1 中选择；`vm=1` 时执行 vmv 广播/搬运。
//   * VSMUL_VMVNRR：在 OPIVI 编码下用于整组寄存器搬运 vmv<nr>r。
//   * VXUNARY0 + VZEXT/VSEXT：把较窄元素零扩展/符号扩展到更宽目的元素。
//   * VWRXUNARY0：覆盖 vmv.x.s、vmv.s.x 这类向量首元素与标量之间的搬运。
//   * ZVE32F_ON 下的 VFMERGE_VFMV/VWRFUNARY0：覆盖单精度浮点 move/merge。
// - define/参数阅读重点：
//   * `BYTE_WIDTH`：8。
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `FUNCT3_WIDTH`：3。
//   * `HWORD_WIDTH`：16。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `ROB_DEPTH_WIDTH`：$clog2(`ROB_DEPTH)=3。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VLENW`：`VLEN/32；依赖 VLEN。
//   * `WORD_WIDTH`：32。
//   * `XLEN`：32；标量整数宽度。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
// - 阅读建议：先看 result_valid 覆盖哪些编码，再看 src1/src2 准备，最后看 extend/merge 结果选择。
// 详细中文注释（自动梳理）END

module rvv_backend_alu_unit_other
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
//
// 接口信号
//
  // ALU RS 输入。是否 pop 由上层根据 result_ready 和其它 p0/p1 结果统一决定。
  input   logic                   alu_uop_valid;
  input   ALU_RS_t                alu_uop;

  // 送往 ROB 的 p0 结果。
  output  logic                   result_valid;
  output  PU2ROB_t                result;

//
// 内部信号
//
  // 从 ALU_RS_t 拆出的字段。
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic                               vm;
  EEW_e                               vd_eew;
  logic   [`VLEN-1:0]                 v0_data;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vs1_opcode;              
  logic   [`VLEN-1:0]                 vs1_data;           
  logic   [`VLEN-1:0]                 vs2_data;	        
  EEW_e                               vs2_eew;
  logic   [`XLEN-1:0] 	              rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0]     uop_index;          

  // 执行中间量。
  // src1_data/src2_data 是统一整理后的两个输入；result_data_extend/result_data_vmerge 是两类主要组合结果。
  logic   [`VLENB-1:0]                v0_data_in_use;
  logic   [`VLEN-1:0]                 src2_data;
  logic   [`VLEN-1:0]                 src1_data;
  logic   [`VLEN-1:0]                 result_data;
  logic   [`VLEN-1:0]                 result_data_extend;  
  logic   [`VLEN-1:0]                 result_data_vmerge; 
  
  // generate 循环变量。
  genvar                              j;

//
// 准备计算源数据
//
  // 拆分 ALU_RS_t。`vs1_opcode` 对 VXUNARY/VWRXUNARY 类指令同时承担子操作选择作用。
  assign  rob_entry      = alu_uop.rob_entry;
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vm             = alu_uop.vm;
  assign  v0_data        = alu_uop.v0_data;
  assign  vd_eew         = alu_uop.vd_eew;
  assign  vs1_opcode     = alu_uop.vs1;
  assign  vs1_data       = alu_uop.vs1_data;
  assign  rs1_data       = alu_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data       = alu_uop.vs2_data;
  assign  vs2_eew        = alu_uop.vs2_eew;
  assign  uop_index      = alu_uop.uop_index;

//
// 指令识别与源数据准备
//
  // 生成本子单元的 result_valid。
  // 只有 move/merge/extend/标量搬运类编码命中时才置位。
  always_comb begin
    result_valid = 'b0;

    // 按 funct3/funct6/vs1_opcode 判断当前 uop 是否属于 other 单元。
    case(uop_funct3)
      OPIVV,
      OPIVX: begin
        case(uop_funct6.ari_funct6)
          VMERGE_VMV: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VMERGE_VMV,
          VSMUL_VMVNRR: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end

      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2,
              VZEXT_VF4,
              VSEXT_VF4: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VMV_X_S: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
      OPMVX: begin
        case(uop_funct6.ari_funct6)
          VWRXUNARY0: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end

    `ifdef ZVE32F_ON
      OPFVV: begin
        case(uop_funct6.ari_funct6)
          VWRFUNARY0: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end
      OPFVF: begin
        case(uop_funct6.ari_funct6)
          VFMERGE_VFMV,
          VWRFUNARY0: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end
    `endif
    endcase
  end

  // 生成统一的 src1_data/src2_data。
  // 对标量源 OPIVX/OPIVI，会把 rs1_data 按目标 EEW 广播到整条向量。
  always_comb begin
    // 默认清零，避免未覆盖路径产生锁存。
    src2_data    = 'b0;
    src1_data    = 'b0;

    // 按具体指令整理源操作数。
    case(uop_funct3)
      OPIVV: begin
        case(uop_funct6.ari_funct6)
          VMERGE_VMV: begin
            // vm=1：vmv.v.v，直接搬运 vs1。
            if(vm) begin
              src1_data = vs1_data;
            end
            // vm=0：vmerge.vvm，后续按 v0 mask 在 vs2/src1 间选择。
            else begin
              src2_data = vs2_data;
              src1_data = vs1_data;
            end
          end
        endcase
      end

      OPIVX: begin
        case(uop_funct6.ari_funct6)
          VMERGE_VMV: begin
            // vm=1：vmv.v.x，把 rs1 按 vd_eew 广播到所有元素。
            if(vm==1'b1) begin
              for(int i=0;i<`VLENW;i=i+1) begin
                case(vd_eew)
                  EEW8: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  end
                  EEW16: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                  EEW32: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                endcase
              end
            end
            // vm=0：vmerge.vxm，src2 来自 vs2，src1 来自 rs1 广播值。
            else begin 
              src2_data = vs2_data;
              for(int i=0;i<`VLENW;i=i+1) begin
                case(vs2_eew)
                  EEW8: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  end
                  EEW16: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                  EEW32: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                endcase
              end
            end
          end
        endcase
      end

      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VMERGE_VMV: begin
            // vm=1：vmv.v.i，把立即数/rs1_data 低位按 EEW 广播。
            if(vm==1'b1) begin
              for(int i=0;i<`VLENW;i=i+1) begin
                case(vd_eew)
                  EEW8: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  end
                  EEW16: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                  EEW32: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                endcase
              end
            end
            // vm=0：vmerge.vim，src2 来自 vs2，src1 来自立即数广播。
            else begin
              src2_data = vs2_data;
              for(int i=0;i<`VLENW;i=i+1) begin
                case(vs2_eew)
                  EEW8: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  end
                  EEW16: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                  EEW32: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                endcase
              end
            end
          end
          VSMUL_VMVNRR: begin
            // OPIVI + VSMUL_VMVNRR 编码复用为 vmv<nr>r.v 时，直接搬运 vs2_data。
            if(vm) begin
              src2_data = vs2_data;
            end
          end
        endcase
      end

      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                // 扩展 2 倍：根据 uop_index 选择当前 uop 负责的半个源寄存器。
                if (uop_index[0]==1'b0)
                  src2_data = {2{vs2_data[0 +: `VLEN/2]}};
                else
                  src2_data = {2{vs2_data[`VLEN/2 +: `VLEN/2]}};
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                // 扩展 4 倍：根据 uop_index[1:0] 选择当前 uop 负责的四分之一源片段。
                if (uop_index[1:0]==2'b0)
                  src2_data = {4{vs2_data[0 +: `VLEN/4]}};
                else if (uop_index[1:0]==2'b01)
                  src2_data = {4{vs2_data[1*`VLEN/4 +: `VLEN/4]}};
                else if (uop_index[1:0]==2'b10)
                  src2_data = {4{vs2_data[2*`VLEN/4 +: `VLEN/4]}};
                else
                  src2_data = {4{vs2_data[3*`VLEN/4 +: `VLEN/4]}};
              end
            endcase
          end
          VWRXUNARY0: begin
            // vmv.x.s：把 vs2[0] 按 EEW 放入低位，最终由 ROB/写回路径写标量寄存器。
            if(vs1_opcode==VMV_X_S) begin
              case(vs2_eew)
                EEW8: begin
                  src2_data[0 +: `BYTE_WIDTH] = vs2_data[0 +: `BYTE_WIDTH];
                end
                EEW16: begin
                  src2_data[0 +: `HWORD_WIDTH] = vs2_data[0 +: `HWORD_WIDTH];
                end
                EEW32: begin
                  src2_data[0 +: `WORD_WIDTH] = vs2_data[0 +: `WORD_WIDTH];
                end
              endcase
            end
          end
        endcase
      end

      OPMVX: begin
        case(uop_funct6.ari_funct6)
          VWRXUNARY0: begin
            // vmv.s.x：把 rs1 写入 vd[0] 对应的低位元素。
            case(vd_eew)
              EEW8: begin
                src1_data[0 +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
              end
              EEW16: begin
                src1_data[0 +: `HWORD_WIDTH] = rs1_data[0 +: `HWORD_WIDTH];
              end
              EEW32: begin
                src1_data[0 +: `WORD_WIDTH] = rs1_data[0 +: `WORD_WIDTH];
              end
            endcase
          end
        endcase
      end
    `ifdef ZVE32F_ON
      OPFVF: begin
        case(uop_funct6.ari_funct6)
          VFMERGE_VFMV: begin
            // vm=1：vfmv.v.f，当前实现只覆盖 EEW32，把浮点标量广播到所有 32bit 元素。
            if(vm==1'b1) begin
              for(int i=0;i<`VLENW;i=i+1) begin
                case(vd_eew)
                  //EEW8: begin
                  //  src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //  src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //  src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //  src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //end
                  //EEW16: begin
                  //  src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                  //  src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  //  src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                  //  src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  //end
                  EEW32: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                endcase
              end
            end
            // vm=0：vfmerge.vfm，src2 来自 vs2，src1 为浮点标量广播，后续按 v0 mask 选择。
            else begin 
              src2_data = vs2_data;
              for(int i=0;i<`VLENW;i=i+1) begin
                case(vs2_eew)
                  //EEW8: begin
                  //  src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //  src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //  src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //  src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
                  //end
                  //EEW16: begin
                  //  src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                  //  src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  //  src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                  //  src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                  //end
                  EEW32: begin
                    src1_data[(4*i  )*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[0             +: `BYTE_WIDTH];
                    src1_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                    src1_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                  end
                endcase
              end
            end
          end
          VWRFUNARY0: begin
            // vfmv.s.f / vmv.s.f 形态：把浮点标量写入 vd[0]。
            case(vd_eew)
              //EEW8: begin
              //  src1_data[0 +: `BYTE_WIDTH] = rs1_data[0 +: `BYTE_WIDTH];
              //end
              //EEW16: begin
              //  src1_data[0 +: `HWORD_WIDTH] = rs1_data[0 +: `HWORD_WIDTH];
              //end
              EEW32: begin
                src1_data[0 +: `WORD_WIDTH] = rs1_data[0 +: `WORD_WIDTH];
              end
            endcase
          end
        endcase
      end
      OPFVV: begin
        case(uop_funct6.ari_funct6)
          VWRFUNARY0: begin
            // vfmv.f.s / vmv.f.s 形态：把 vs2[0] 作为浮点标量结果搬出。
            case(vs2_eew)
              //EEW8: begin
              //  src2_data[0 +: `BYTE_WIDTH] = vs2_data[0 +: `BYTE_WIDTH];
              //end
              //EEW16: begin
              //  src2_data[0 +: `HWORD_WIDTH] = vs2_data[0 +: `HWORD_WIDTH];
              //end
              EEW32: begin
                src2_data[0 +: `WORD_WIDTH] = vs2_data[0 +: `WORD_WIDTH];
              end
            endcase
          end
        endcase
      end
    `endif
    endcase
  end

//
// 计算结果
//
  // VXUNARY0 扩展类：按 vs1_opcode 做零扩展或符号扩展。
  generate
    for (j=0;j<`VLENW;j=j+1) begin: EXE_EXTEND
      always_comb begin
        result_data_extend[j*`WORD_WIDTH +: `WORD_WIDTH] = 'b0;
        
        case(vs1_opcode) 
          VZEXT_VF2: begin  //无符号扩展2倍
            case(vs2_eew)
              EEW8: begin  
                result_data_extend[(2*j  )*`HWORD_WIDTH +: `HWORD_WIDTH] = {8'b0, src2_data[(2*j  )*`BYTE_WIDTH +: `BYTE_WIDTH]};
                result_data_extend[(2*j+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = {8'b0, src2_data[(2*j+1)*`BYTE_WIDTH +: `BYTE_WIDTH]};
              end
              EEW16: begin
                result_data_extend[j*`WORD_WIDTH +: `WORD_WIDTH] = {16'b0, src2_data[j*`HWORD_WIDTH +: `HWORD_WIDTH]};
              end
            endcase
          end
          VSEXT_VF2: begin  //有符号扩展2倍
            case(vs2_eew)
              EEW8: begin
                result_data_extend[(2*j  )*`HWORD_WIDTH +: `HWORD_WIDTH] = {{8{src2_data[(2*j+1)*`BYTE_WIDTH-1]}}, src2_data[(2*j  )*`BYTE_WIDTH +: `BYTE_WIDTH]};
                result_data_extend[(2*j+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = {{8{src2_data[(2*j+2)*`BYTE_WIDTH-1]}}, src2_data[(2*j+1)*`BYTE_WIDTH +: `BYTE_WIDTH]};
              end
              EEW16: begin
                result_data_extend[j*`WORD_WIDTH +: `WORD_WIDTH] = {{16{src2_data[(j+1)*`HWORD_WIDTH-1]}},src2_data[j*`HWORD_WIDTH +: `HWORD_WIDTH]};
              end
            endcase
          end
          VZEXT_VF4: begin
            case(vs2_eew)
              EEW8: begin
                result_data_extend[j*`WORD_WIDTH +: `WORD_WIDTH] = {24'b0, src2_data[j*`BYTE_WIDTH +: `BYTE_WIDTH]};
              end
            endcase
          end
          VSEXT_VF4: begin       
            case(vs2_eew)
              EEW8: begin
                result_data_extend[j*`WORD_WIDTH +: `WORD_WIDTH] = {{24{src2_data[(j+1)*`BYTE_WIDTH-1]}}, src2_data[j*`BYTE_WIDTH +: `BYTE_WIDTH]};
              end
            endcase
          end
        endcase
      end
    end
  endgenerate
 
  // vmerge 使用的 v0 mask 片段。
  // `uop_index` 选择当前 uop 对应的 mask 子段；EEW 越大，需要的 mask bit 越少。
  always_comb begin
    v0_data_in_use = 'b0;

    case(vs2_eew)
      EEW8: begin
        v0_data_in_use = v0_data[{uop_index,{($clog2(`VLENB)){1'b0}}} +: `VLENB];
      end
      EEW16: begin
        v0_data_in_use = {{(`VLENB/2){1'b0}}, v0_data[{uop_index,{($clog2(`VLENB/2)){1'b0}}} +: `VLENB/2]};
      end
      EEW32: begin
        v0_data_in_use = {{(`VLENB*3/4){1'b0}}, v0_data[{uop_index,{($clog2(`VLENB/4)){1'b0}}} +: `VLENB/4]};
      end
    endcase
  end 

  generate
    for (j=0;j<`VLENW;j=j+1) begin: EXE_VMERGE
      always_comb begin
        result_data_vmerge[j*`WORD_WIDTH +: `WORD_WIDTH] = 'b0;
        
        case(vs2_eew)
          EEW8: begin
            result_data_vmerge[(4*j  )*`BYTE_WIDTH +: `BYTE_WIDTH] = v0_data_in_use[4*j] ?
                                                                     src1_data[(4*j  )*`BYTE_WIDTH +: `BYTE_WIDTH] :
                                                                     src2_data[(4*j  )*`BYTE_WIDTH +: `BYTE_WIDTH] ;
            result_data_vmerge[(4*j+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = v0_data_in_use[4*j+1] ?
                                                                     src1_data[(4*j+1)*`BYTE_WIDTH +: `BYTE_WIDTH] :
                                                                     src2_data[(4*j+1)*`BYTE_WIDTH +: `BYTE_WIDTH] ;
            result_data_vmerge[(4*j+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = v0_data_in_use[4*j+2] ?
                                                                     src1_data[(4*j+2)*`BYTE_WIDTH +: `BYTE_WIDTH] :
                                                                     src2_data[(4*j+2)*`BYTE_WIDTH +: `BYTE_WIDTH] ;
            result_data_vmerge[(4*j+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = v0_data_in_use[4*j+3] ?
                                                                     src1_data[(4*j+3)*`BYTE_WIDTH +: `BYTE_WIDTH] :
                                                                     src2_data[(4*j+3)*`BYTE_WIDTH +: `BYTE_WIDTH] ;
          end
          EEW16: begin
            result_data_vmerge[(2*j  )*`HWORD_WIDTH +: `HWORD_WIDTH] = v0_data_in_use[2*j] ?
                                                                     src1_data[(2*j  )*`HWORD_WIDTH +: `HWORD_WIDTH] :
                                                                     src2_data[(2*j  )*`HWORD_WIDTH +: `HWORD_WIDTH] ;
            result_data_vmerge[(2*j+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = v0_data_in_use[2*j+1] ?
                                                                     src1_data[(2*j+1)*`HWORD_WIDTH +: `HWORD_WIDTH] :
                                                                     src2_data[(2*j+1)*`HWORD_WIDTH +: `HWORD_WIDTH] ;
          end
          EEW32: begin
            result_data_vmerge[j*`WORD_WIDTH +: `WORD_WIDTH] = v0_data_in_use[j] ?
                                                               src1_data[j*`WORD_WIDTH +: `WORD_WIDTH] :
                                                               src2_data[j*`WORD_WIDTH +: `WORD_WIDTH] ;
          end
        endcase
      end
    end
  endgenerate

  // 选择最终 result_data。
  // VMERGE/VMV 根据 vm 选择 merge 结果或单源搬运；extend 使用 result_data_extend。
  always_comb begin
    // 默认清零。
    result_data = 'b0; 

    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VMERGE_VMV: begin
            if(vm==1'b0)
              result_data = result_data_vmerge;
            else
              result_data = src1_data;
          end
          VSMUL_VMVNRR: begin
            result_data = src2_data;
          end
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VXUNARY0: begin
            result_data = result_data_extend;
          end
          VWRXUNARY0: begin
            result_data = src2_data;
          end
        endcase
      end
      OPMVX: begin
        case(uop_funct6.ari_funct6)
          VWRXUNARY0: begin
            result_data = src1_data;
          end
        endcase
      end
    `ifdef ZVE32F_ON
      OPFVF: begin
        case(uop_funct6.ari_funct6)
          VFMERGE_VFMV: begin
            if(vm==1'b0)
              result_data = result_data_vmerge;
            else
              result_data = src1_data;
          end
          VWRFUNARY0: begin
            result_data = src1_data;
          end
        endcase
      end
      OPFVV: begin
        case(uop_funct6.ari_funct6)
          VWRFUNARY0: begin
            result_data = src2_data;
          end
        endcase
      end
    `endif
    endcase
  end

//
// 提交结果到 ROB
//
`ifdef TB_SUPPORT
  assign result.uop_pc    = alu_uop.uop_pc;
`endif
  assign result.rob_entry = rob_entry;
  assign result.w_data    = result_data;
  assign result.w_valid   = result_valid;
  assign result.vsaturate = 'b0;
`ifdef ZVE32F_ON
  assign result.fpexp     = 'b0;
`endif

endmodule
