
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 功能说明：
// 1. `rvv_backend_alu_unit_mask` 是 ALU p0 阶段的 mask/位逻辑/特殊 mask 指令执行单元。
// 2. 普通整数逻辑指令覆盖 VAND/VOR/VXOR；mask 逻辑覆盖 VMAND/VMOR/VMXOR/VMNAND/VMNOR/VMXNOR 等。
// 3. 还覆盖 VFIRST、VMSBF/VMSOF/VMSIF、VID 等 mask special 指令。
// 4. 本模块直接输出 `PU2ROB_t`，不经过 ALU p1；后级 ready/pop 由上层 `rvv_backend_alu_unit` 仲裁。
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_alu_unit_mask` -> RVV 后端 EX/ALU p0 子单元。
// - 接口与数据流：
//   * 输入：`alu_uop_valid/alu_uop`，其中 `alu_uop` 已包含源操作数、mask、vstart/vl、EEW、ROB entry。
//   * 处理：根据 funct3/funct6/vs1_opcode 选择普通位逻辑、mask 位逻辑、VFIRST、VMSBF/VMSOF/VMSIF 或 VID。
//   * 输出：`result_valid/result`，结果写入 `result.w_data`；本模块不产生饱和和浮点异常标志。
// - 调用关系：上层 rvv_backend_alu_unit；无下层实例。
// - 端口摘要：输入 alu_uop_valid, alu_uop；输出 result_valid, result。
// - 指令分组：
//   * VAND/VOR/VXOR：普通向量整数位逻辑，OPIVV/OPIVX/OPIVI 都可命中。
//   * VMANDN/VMAND/VMOR/VMXOR/VMORN/VMNAND/VMNOR/VMXNOR：mask 寄存器按 bit 运算。
//   * VFIRST：返回第一个置位 mask bit 的索引；没有置位时返回全 1（即 -1）。
//   * VMSBF/VMSOF/VMSIF：围绕第一个置位 bit 生成 before/only/including first 的 mask。
//   * VID：生成元素编号向量，元素值由 `uop_index` 与元素局部编号拼出。
// - define/参数阅读重点：
//   * `BYTE_WIDTH`：8。
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `FUNCT3_WIDTH`：3。
//   * `HWORD_WIDTH`：16。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `ROB_DEPTH_WIDTH`：$clog2(`ROB_DEPTH)=3。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VL_WIDTH`：$clog2(`VLEN)+1；依赖 VLEN。
//   * `VSTART_WIDTH`：$clog2(`VLEN)；依赖 VLEN。
//   * `WORD_WIDTH`：32。
//   * `XLEN`：32；标量整数宽度。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
// - 阅读建议：按 result_valid 覆盖编码 -> src1/src2 准备 -> 组合结果生成 -> vstart/mask 合并写回的顺序阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_alu_unit_mask
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
//
// 接口信号
//
  // ALU RS 输入。该子单元只产生组合结果，是否 pop 由上层根据 result_ready 决定。
  input   logic           alu_uop_valid;
  input   ALU_RS_t        alu_uop;

  // 送往 ROB 的 p0 结果。
  output  logic           result_valid;
  output  PU2ROB_t        result;

//
// 内部信号
//
  // 从 ALU_RS_t 拆出的字段。
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic   [`VSTART_WIDTH-1:0]         vstart;
  logic   [`VLEN-1:0]                 vstart_elements_tmp;
  logic   [`VLEN-1:0]                 vstart_elements;
  logic   [`VL_WIDTH-1:0]             vl;       
  logic                               vm;
  logic   [`VLEN-1:0]                 v0_data;           
  logic   [`VLEN-1:0]                 vd_data;           
  EEW_e                               vd_eew;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vs1_opcode;              
  logic   [`VLEN-1:0]                 vs1_data;           
  logic   [`VLEN-1:0]                 vs2_data;	        
  EEW_e                               vs2_eew;
  logic   [`XLEN-1:0] 	              rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0]     uop_index;          

  // 执行中间量。
  // src2/src1 是统一整理后的输入；result_data_* 分别保存不同 mask/逻辑指令的组合结果。
  logic   [`VLEN-1:0]                 src2_data;
  logic   [`VLEN-1:0]                 src2_data_sub1;
  logic   [`VLEN-1:0]                 src1_data;
  logic   [`VLEN-1:0]                 tail_mask;
  logic   [`VLEN-1:0]                 result_data;
  logic   [`VLEN-1:0]                 result_data_andn;
  logic   [`VLEN-1:0]                 result_data_and; 
  logic   [`VLEN-1:0]                 result_data_or;  
  logic   [`VLEN-1:0]                 result_data_xor; 
  logic   [`VLEN-1:0]                 result_data_orn; 
  logic   [`VLEN-1:0]                 result_data_nand;
  logic   [`VLEN-1:0]                 result_data_nor; 
  logic   [`VLEN-1:0]                 result_data_xnor;
  logic   [`VLEN-1:0]                 result_data_vmsof;
  logic   [`VLEN-1:0]                 result_vmsif;
  logic   [`VLEN-1:0]                 result_data_vmsif;
  logic   [`VLEN-1:0]                 result_data_vmsbf;
  logic   [`VLEN-1:0]                 result_data_vfirst;
  logic   [`VLEN-1:0]                 result_data_vid8;
  logic   [`VLEN-1:0]                 result_data_vid16;
  logic   [`VLEN-1:0]                 result_data_vid32;

  // generate 循环变量。
  genvar                              j;
  genvar                              h;

//
// 准备计算源数据
//
  // 拆分 ALU_RS_t。`vs1_opcode` 在 VWRXUNARY0/VMUNARY0 中用于选择 VFIRST/VMSBF/VMSOF/VMSIF/VID 等子操作。
  assign  rob_entry      = alu_uop.rob_entry;
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vstart         = alu_uop.vstart;
  assign  vl             = alu_uop.vl;
  assign  vm             = alu_uop.vm;
  assign  v0_data        = alu_uop.v0_data;
  assign  vd_data        = alu_uop.vd_data;
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
  // 生成 tail_mask：bit j 小于 vl 时为 1，用于 VFIRST 屏蔽 tail 区域。
  // 旧写法保留在下方注释中；当前写法逐 bit 比较，综合上更直观。
  // assign tail_mask = vl[`VL_WIDTH-1] ? '1 ((`VLEN)'('b1)<<vl[`VL_WIDTH-2:0]) - 1'b1;
  generate
    for(j=0;j<`VLEN;j++) assign tail_mask[j] = j[`VL_WIDTH-1:0] < vl;
  endgenerate

  // 生成本子单元的 result_valid。
  // 只有普通逻辑、mask 逻辑、VFIRST、VMSBF/VMSOF/VMSIF、VID 编码命中时才置位。
  always_comb begin
    // 默认当前 uop 不属于 mask 单元。
    result_valid = 'b0;

    // 按 funct3/funct6/vs1_opcode 判断当前 uop 是否命中本单元。
    case(uop_funct3)
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end

      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            result_valid = alu_uop_valid;
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF,
              VID: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
    endcase
  end

  // 准备统一的 src1_data/src2_data。
  // OPIVX/OPIVI 的标量/立即数操作数会按 EEW 广播到整条向量。
  always_comb begin
    // 默认清零，避免未覆盖路径产生锁存。
    src2_data       = 'b0;
    src1_data       = 'b0;

    // 按具体指令整理源操作数。
    case(uop_funct3)
      OPIVV: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            src2_data = vs2_data;
            src1_data = vs1_data;
          end
        endcase
      end
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            src2_data = vs2_data;
            for(int i=0;i<`VLEN/`WORD_WIDTH;i++) begin  //广播
              case(vs2_eew) 
                EEW8: begin  
                  src1_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {(`WORD_WIDTH/`BYTE_WIDTH){rs1_data[0 +: `BYTE_WIDTH]}};
                end
                EEW16: begin
                  src1_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {(`WORD_WIDTH/`HWORD_WIDTH){rs1_data[0 +: `HWORD_WIDTH]}};
                end
                EEW32: begin
                  src1_data[i*`WORD_WIDTH +: `WORD_WIDTH] = rs1_data;
                end
              endcase
            end
          end 
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            src2_data  = vs2_data;
            src1_data  = vs1_data;
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                // VFIRST 只在 body/tail 有效元素中搜索；vm=0 时还需要与 v0 mask 相与。
                if (vm==1'b1)
                  src2_data = vs2_data&tail_mask;
                else
                  src2_data = vs2_data&tail_mask&v0_data; 
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF: begin
                // mask-first 类指令先得到参与搜索的 mask 源；vm=0 时只保留 v0 允许的 bit。
                if (vm==1'b1)
                  src2_data = vs2_data;
                else
                  src2_data = vs2_data&v0_data; 
              end
              // VID 不需要普通源操作数，后续直接根据 uop_index/元素编号生成结果。
            endcase
          end
        endcase
      end
    endcase
  end

//
// 计算结果
//
  // 普通向量位逻辑和 mask 位逻辑的基础组合结果。
  assign result_data_and   = src2_data & src1_data;  
  assign result_data_andn  = src2_data & (~src1_data);  
  assign result_data_or    = src2_data | src1_data;  
  assign result_data_xor   = src2_data ^ src1_data;  
  assign result_data_orn   = src2_data | (~src1_data);  
  assign result_data_nand  = ~(src2_data & src1_data);  
  assign result_data_nor   = ~(src2_data | src1_data);  
  assign result_data_xnor  = ~(src2_data ^ src1_data); 
  // first-one 辅助结果：
  // src2_data_sub1      = src2 - 1
  // result_data_vmsof   = 只保留第一个置位 bit
  // result_data_vmsif   = 从 bit0 到第一个置位 bit 均为 1
  // result_data_vmsbf   = 第一个置位 bit 之前为 1，不包含第一个置位 bit
  assign src2_data_sub1    = src2_data - 1'b1;
  assign result_data_vmsof = src2_data & (~src2_data_sub1);  //发现1，only自身1
  assign result_vmsif      = src2_data ^ src2_data_sub1;  //发现1，低位全1+自身1
  assign result_data_vmsif = (src2_data==0) ? {`VLEN{1'b1}} : result_vmsif;  //发现1，低位全1+自身1
  assign result_data_vmsbf = (src2_data==0) ? {`VLEN{1'b1}} : {1'b0,result_vmsif[`VLEN-1:1]};  //不包含自身，低位全1
 
  // VFIRST：把 first-one onehot 转成二进制索引；若没有置位 bit，返回全 1。
  always_comb begin
    result_data_vfirst = 'b0;
    
    if (src2_data=='b0) 
      result_data_vfirst = {`VLEN{1'b1}};
    else begin
      for(int i=0;i<`VLEN;i++) begin
        if (result_data_vmsof[i]==1'b1) 
          result_data_vfirst = (`VLEN)'(i);         // one-hot 转二进制索引，得到第一个 1 的位置。
      end
    end
  end

  // VID：按 EEW 生成元素编号。1,2,3,4,5等
  // `uop_index` 表示当前 uop 覆盖的向量片段，高位拼上片段号，低位拼元素局部编号。
  generate
    for(j=0;j<`VLENB;j++) begin: GET_VID8
      assign result_data_vid8[j*`BYTE_WIDTH +: `BYTE_WIDTH] = (`BYTE_WIDTH)'({uop_index, j[$clog2(`VLENB)-1:0]}); 
    end
  endgenerate

  generate
    for(j=0;j<`VLEN/`HWORD_WIDTH;j++) begin: GET_VID16
      assign result_data_vid16[j*`HWORD_WIDTH +: `HWORD_WIDTH] = (`HWORD_WIDTH)'({uop_index, j[$clog2(`VLEN/`HWORD_WIDTH)-1:0]});
    end
  endgenerate

  generate
    for(j=0;j<`VLEN/`WORD_WIDTH;j++) begin: GET_VID32
      assign result_data_vid32[j*`WORD_WIDTH +: `WORD_WIDTH] = (`WORD_WIDTH)'({uop_index, j[$clog2(`VLEN/`WORD_WIDTH)-1:0]});
    end
  endgenerate

  // 选择最终 result_data。
  always_comb begin
    // 默认清零。
    result_data = 'b0; 

    // 按指令选择对应组合结果。
    case(uop_funct3)
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND: begin
            result_data = result_data_and;
          end
          VOR: begin
            result_data = result_data_or;
          end
          VXOR: begin
            result_data = result_data_xor;
          end
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN: begin
            result_data = result_data_andn;
          end
          VMAND: begin
            result_data = result_data_and; 
          end
          VMOR: begin
            result_data = result_data_or; 
          end
          VMXOR: begin
            result_data = result_data_xor; 
          end
          VMORN: begin
            result_data = result_data_orn; 
          end
          VMNAND: begin
            result_data = result_data_nand; 
          end
          VMNOR: begin
            result_data = result_data_nor; 
          end
          VMXNOR: begin
            result_data = result_data_xnor; 
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                result_data = result_data_vfirst;
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF: begin
                result_data = result_data_vmsbf;
              end
              VMSOF: begin
                result_data = result_data_vmsof;
              end
              VMSIF: begin
                result_data = result_data_vmsif;
              end
              VID: begin
                case(vd_eew)
                  EEW8: begin
                    result_data = result_data_vid8;
                  end
                  EEW16: begin
                    result_data = result_data_vid16;
                  end
                  EEW32: begin
                    result_data = result_data_vid32;
                  end
                endcase
              end
            endcase
          end
        endcase
      end
    endcase
  end

//
// 提交结果到 ROB
//
  // 生成 prestart 掩码：vstart 之前的元素保持原 vd_data，避免异常恢复后重复执行已完成元素。
  barrel_shifter #(.DATA_WIDTH(`VLEN)) 
  u_prestart (.din((`VLEN)'('1)), .shift_amount(vstart[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vstart_elements_tmp));
  assign vstart_elements  = ~vstart_elements_tmp;

  always_comb begin
    // 默认写回 result_data。
  `ifdef TB_SUPPORT
    result.uop_pc    = alu_uop.uop_pc;
  `endif
    result.rob_entry = rob_entry;
    result.w_data    = result_data;
    result.w_valid   = result_valid;
    result.vsaturate = 'b0;
  `ifdef ZVE32F_ON
    result.fpexp     = 'b0;
  `endif

    case(uop_funct3)
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            result.w_data = result_data;
          end
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            // mask 逻辑需要保留 vstart 之前的旧 vd bit，其余位置写入新 mask 结果。
            result.w_data = result_data&(~vstart_elements) | vd_data&vstart_elements;
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                result.w_data = result_data;
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF: begin
                // vm=0 时，只有 v0 mask 允许的位置写新结果，其余保持旧 vd。
                if (vm==1'b1)
                  result.w_data = result_data;
                else 
                  result.w_data = result_data&v0_data | vd_data&(~v0_data);
              end
              VID: begin
                result.w_data = result_data;
              end
            endcase
          end
        endcase
      end
    endcase
  end   

endmodule
