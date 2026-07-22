
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

`ifdef ZVE32F_ON
//------------------------------------------------------------------------------
// rvv_backend_fma_wrapper
//------------------------------------------------------------------------------
// 功能定位：
// 1. 单个 FMA wrapper，接收一路 `FMA_RS_t`，内部按 `fma_type` 分发到四类子路径。
// 2. addmul 子路径使用 `fpnew_fma_multi`，覆盖 VFADD/VFSUB/VFMUL 以及各类 fused MAC。
// 3. allcmp 子路径使用 `fpnew_noncomp`，覆盖 VMFEQ/VMFLT 等 mask 比较、VFSGNJ、
//    VFMIN/VFMAX 和 VFCLASS。FCMP mask 类会跨 uop 合并 mask。
// 4. cvt 子路径使用 `fpnew_cast_multi`，覆盖 VFCVT* 以及可选 BF16/FP32 转换。
// 5. tbl 子路径使用 `rvv_backend_sqrt7_rec7`，覆盖 VFRSQRT7/VFREC7 近似查表类指令。
// 6. 四条子路径的结果在本 wrapper 内用 round-robin 仲裁成一路 `PU2ROB_t`。
//
// 数据宽度：
// - 默认按 FP32 lane 处理，每个 lane 宽 `WORD_WIDTH`=32。
// - `VLENW`=`VLEN/32`，即本 wrapper 中 fpnew lane 的数量。
// - `ZVFBFWMA_ON` 打开时，额外支持 BF16 输入/输出，部分结果按 EEW16 分半写回。

module rvv_backend_fma_wrapper(
  // 全局信号。
  clk,
  rst_n,
  // FMA RS 输入。
  fma_uop_vld,
  fma_uop,
  // one-hot 子路径类型。
  fma_type,
  // 各子路径 ready，反馈给上层调度。
  fma_uop_addmul_rdy,
  fma_uop_cmp_rdy,
  fma_uop_cvt_rdy,
  fma_uop_tbl_rdy,
  // trap/flush。
  trap_flush_rvv,
  // 结果输出到 ROB 写回通路。
  fma_result_vld,
  fma_result,
  // ROB/后端结果通路 ready。
  fma_result_rdy
);
  parameter PIPEREGS  = 3; 
  // 全局时钟/复位。
  input   logic         clk;
  input   logic         rst_n;
  // 输入 uop。
  input   logic         fma_uop_vld;
  input   FMA_RS_t      fma_uop;
  // fma_type[0]=addmul，[1]=allcmp，[2]=cvt，[3]=tbl。
  input   logic [3:0]   fma_type;
  // 对每类子路径分别给 ready，避免某条子路径拥塞阻塞其它类型的发射判断。
  output  logic         fma_uop_addmul_rdy;
  output  logic         fma_uop_cmp_rdy;
  output  logic         fma_uop_cvt_rdy;
  output  logic         fma_uop_tbl_rdy;
  // RVV trap/flush，清理 fpnew/table 和比较累积状态。
  input   logic         trap_flush_rvv;
  // wrapper 仲裁后的单路结果。
  output  logic         fma_result_vld;
  output  PU2ROB_t      fma_result;
  // 后级可接收结果。
  input   logic         fma_result_rdy;

//
// 内部信号
//
  // 子路径输入 valid。
  logic                                     addmul_vld;
  logic                                     allcmp_vld;
  logic                                     cvt_vld;
  logic                                     tbl_vld;
  // 操作数和 fpnew 控制字段。
  logic [`VLEN-1:0]                         src1;
  logic [`VLEN-1:0]                         src2;
  logic [`VLEN-1:0]                         src3;
  logic [`VLENW-1:0][2:0][`WORD_WIDTH-1:0]  op_i;
  EEW_e                                     vd_eew;
  fpnew_pkg::roundmode_e                    rnd_mod_dec;
  fpnew_pkg::roundmode_e                    rnd_mod_i;    // 对 noncomp 来说也编码比较/minmax/sgnj 的变体。
  fpnew_pkg::operation_e                    op_type;
  logic                                     op_mod;
  fpnew_pkg::fp_format_e                    src_fmt;
  fpnew_pkg::fp_format_e                    src2_fmt;
  fpnew_pkg::fp_format_e                    dst_fmt;
  fpnew_pkg::int_format_e                   int_fmt;
  // tag 随 fpnew 流水返回，用于恢复 rob_entry、uop_index、last_uop_valid 等信息。
  TAG_t                                     tag_fma;
  FCMP_TAG_t                                tag_fcmp;
  FCVT_TAG_t                                tag_fcvt;
  TAG_t                                     tag_ftbl;
  // 四类子路径结果 valid 和 round-robin 仲裁 grant。
  logic     [3:0]                           result_vld;
  logic     [3:0]                           arb_rdy;
  // add/mul/fused MAC 子路径结果。
  logic                                     addmul_result_vld;
  logic     [`VLEN-1:0]                     addmul_result;
  fpnew_pkg::status_t [`VLENW-1:0]          addmul_status_o;
  TAG_t                                     addmul_tag_o;
  logic                                     addmul_result_rdy;
  // 浮点/整数/BF16 转换子路径结果。
  logic                                     cvt_result_vld;
  logic     [`VLEN-1:0]                     cvt_result;
  fpnew_pkg::status_t [`VLENW-1:0]          cvt_status_o;
  FCVT_TAG_t                                cvt_tag_o;
  logic                                     cvt_result_rdy;
  // sqrt7/rec7 查表近似子路径结果。
  logic                                     tbl_result_vld;
  logic     [`VLEN-1:0]                     tbl_result;
  RVFEXP_t  [`VLENW-1:0]                    tbl_status_o;
  TAG_t                                     tbl_tag_o;
  logic                                     tbl_result_rdy;
  // 比较、分类、符号注入、min/max 子路径结果。
  logic                                     allcmp_result_vld_tmp;
  logic                                     allcmp_result_vld;
  logic                                     is_class_o;
  logic     [`VLEN-1:0]                     allcmp_unit_res;
  fpnew_pkg::classmask_e  [`VLENW-1:0]      class_result;
  logic     [`VLEN-1:0]                     allcmp_result;
  fpnew_pkg::status_t [`VLENW-1:0]          allcmp_status_o;
  FCMP_TAG_t                                allcmp_tag_o;
  logic                                     allcmp_result_rdy_tmp;
  logic                                     allcmp_result_rdy;
  // FCMP mask 类额外信息：
  // fpnew_noncomp 只返回每个 32-bit lane 的比较 bit，FCMP 需要按 uop_index
  // 将多段比较结果合并，并根据 vstart/vl/vm/v0 保留旧 vd。
  logic         [PIPEREGS:0][1:0]           info_vld;
  logic         [PIPEREGS:0]                info_rdy;
  FCMP_INFO_t   [PIPEREGS:0]                cmp_info;
  logic   [`VLEN-1:0]                       v0;
  logic   [`VLEN-1:0]                       vstart_elements_tmp;
  logic   [`VLEN-1:0]                       vstart_elements;
  logic   [`VLEN-1:0]                       tail_elements_tmp;
  logic   [`VLEN-1:0]                       tail_elements;
  logic   [6:0]                             cmp_en;
  logic   [8*`VLENW-1:0]                    cmp;
  logic   [7*`VLENW-1:0]                    cmp_d1;
  logic   [`VLEN-1:0]                       cmp_res_tmp;
  logic   [`VLEN-1:0]                       cmp_res;
  RVFEXP_t  [8*`VLENW-1:0]                  cmp_status;
  RVFEXP_t  [7*`VLENW-1:0]                  cmp_status_d1;
  RVFEXP_t  [`VLEN-1:0]                     cmp_fexp_tmp;
  RVFEXP_t  [`VLEN-1:0]                     cmp_fexp_per1;
  RVFEXP_t  [`VLENB-1:0]                    cmp_fexp;
  RVFEXP_t  [`VLENB-1:0]                    allcmp_fexp;
  
  genvar                                    i;

//
// 子路径 valid 生成
//
  // fma_type 由上层根据 uop_exe_unit 解码成 one-hot。
  assign addmul_vld = fma_uop_vld & fma_type[0];
  assign allcmp_vld = fma_uop_vld & fma_type[1];
  assign cvt_vld    = fma_uop_vld & fma_type[2];
  assign tbl_vld    = fma_uop_vld & fma_type[3];

`ifdef ZVFBFWMA_ON
  assign vd_eew     = (fma_uop.uop_funct6.ari_funct6 == VFUNARY0 && fma_uop.vs1 == VFNCVTBF16)? EEW16 : EEW32;
`else
  assign vd_eew     = EEW32;
`endif

  // 准备源操作数。
  // OPFVF 将浮点标量 rs1 广播到所有 FP32 lane；BF16 扩展路径会按 uop_index
  // 从 VLEN 低半/高半选出 BF16 元素并做 NaN-box 形式的扩展。
  always_comb begin
    src1 = fma_uop.vs1_data;
    src2 = fma_uop.vs2_data;
    src3 = fma_uop.vs3_data;
    
    case(fma_uop.uop_funct3)
      OPFVF: begin
        src1 = {`VLENW{fma_uop.rs1_data}};
      `ifdef ZVFBFWMA_ON
        if(fma_uop.uop_funct6.ari_funct6==VFWMACCBF16) begin
          for(int i=0;i<`VLENW;i++) begin
            if(fma_uop.uop_index[0]) begin
              src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs2_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
            end
            else begin
              src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
            end
          end
        end
      `endif
      end
    `ifdef ZVFBFWMA_ON
      OPFVV: begin
        case(fma_uop.uop_funct6.ari_funct6)
          VFUNARY0: begin 
            for(int i=0;i<`VLENW;i++) begin
              if(fma_uop.vs1==VFWCVTBF16) begin
                if(fma_uop.uop_index[0]) begin
                  src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs2_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                end
                else begin
                  src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                end
              end
            end
          end
          VFWMACCBF16: begin
            for(int i=0;i<`VLENW;i++) begin
              if(fma_uop.uop_index[0]) begin
                src1[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs1_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs2_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
              end
              else begin
                src1[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs1_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), fma_uop.vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
              end
            end
          end
        endcase
      end
    `endif
    endcase
  end

  // 将 RVV frm 编码转换成 fpnew roundmode。
  always_comb begin
    case(fma_uop.frm)
      FRNE:    rnd_mod_dec = fpnew_pkg::RNE;
      FRTZ:    rnd_mod_dec = fpnew_pkg::RTZ;
      FRDN:    rnd_mod_dec = fpnew_pkg::RDN;
      FRUP:    rnd_mod_dec = fpnew_pkg::RUP;
      FRMM:    rnd_mod_dec = fpnew_pkg::RMM;
      default: rnd_mod_dec = fpnew_pkg::DYN;
    endcase
  end

  // 将 RVV 浮点指令解码为 fpnew 操作码、操作数顺序、格式和 op_mod。
  // fpnew_fma_multi 的 operands_i 是 3 操作数形式；普通 add/sub 会把第三操作数置 0。
  always_comb begin
    // 默认按 FP32 FMADD 建立控制，具体指令再覆盖。
    for(int i=0;i<`VLENW;i++) begin
      op_i[i] = {src3[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]};
    end
    rnd_mod_i = rnd_mod_dec;
    op_type   = fpnew_pkg::FMADD;
    op_mod    = 1'b0;
    src_fmt   = fpnew_pkg::FP32;
    src2_fmt  = fpnew_pkg::FP32;
    dst_fmt   = fpnew_pkg::FP32;
    int_fmt   = fpnew_pkg::INT32;
    
    case(1'b1)
      addmul_vld: begin // ADD/MUL/FMA 类。
        case(fma_uop.uop_funct6.ari_funct6)
          VFADD: begin
            op_type   = fpnew_pkg::ADD;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH], `WORD_WIDTH'b0}; 
            end
          end
          VFSUB: begin
            op_type = fpnew_pkg::ADD;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH], `WORD_WIDTH'b0}; 
            end
          end
          VFRSUB: begin
            op_type = fpnew_pkg::ADD;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH], `WORD_WIDTH'b0}; 
            end
          end
          VFMUL: begin
            op_type = fpnew_pkg::MUL;
          end
          VFMACC: begin
            op_type = fpnew_pkg::FMADD;
          end
          VFNMACC: begin
            op_type = fpnew_pkg::FNMSUB;
            op_mod  = 1'b1;
          end
          VFMSAC: begin
            op_type = fpnew_pkg::FMADD;
            op_mod  = 1'b1;
          end
          VFNMSAC: begin
            op_type = fpnew_pkg::FNMSUB;
          end
          VFMADD: begin
            op_type = fpnew_pkg::FMADD;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
          VFNMADD: begin
            op_type = fpnew_pkg::FNMSUB;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
          VFMSUB: begin
            op_type = fpnew_pkg::FMADD;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
          VFNMSUB: begin
            op_type = fpnew_pkg::FNMSUB;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
        `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            op_type = fpnew_pkg::FMADD;
            src_fmt = fpnew_pkg::FP16ALT;
            src2_fmt= fpnew_pkg::FP32;
            dst_fmt = fpnew_pkg::FP32;
          end
        `endif
        endcase
      end
      allcmp_vld: begin // 比较/分类/符号/minmax 类。
        case(fma_uop.uop_funct6.ari_funct6)
          VMFEQ: begin
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RDN;
          end
          VMFNE:begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RDN; 
            op_mod    = 1'b1;
          end
          VMFLT: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RNE; 
            op_mod    = 1'b1;
          end
          VMFLE: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RTZ; 
            op_mod    = 1'b1;
          end
          VMFGT: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RTZ; 
          end
          VMFGE: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RNE; 
          end
          VFSGNJ: begin
            op_type   = fpnew_pkg::SGNJ;
            rnd_mod_i = fpnew_pkg::RNE;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]};
            end
          end
          VFSGNJN: begin
            op_type   = fpnew_pkg::SGNJ;
            rnd_mod_i = fpnew_pkg::RTZ;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]};
            end
          end
          VFSGNJX: begin
            op_type   = fpnew_pkg::SGNJ;
            rnd_mod_i = fpnew_pkg::RDN;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]};
            end
          end
          VFMIN: begin
            op_type   = fpnew_pkg::MINMAX;
            rnd_mod_i = fpnew_pkg::RNE;
          end
          VFMAX: begin
            op_type   = fpnew_pkg::MINMAX;
            rnd_mod_i = fpnew_pkg::RTZ;
          end
          VFUNARY1: begin
            op_type   = fpnew_pkg::CLASSIFY;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, `WORD_WIDTH'b0, src2[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
        endcase
      end
      cvt_vld: begin // 类型转换类。
        case(fma_uop.vs1)
          VFCVT_XUFV: begin
            op_type   = fpnew_pkg::F2I; 
            op_mod    = 1'b1;
          end
          VFCVT_XFV: begin
            op_type   = fpnew_pkg::F2I; 
          end
          VFCVT_FXUV: begin
            op_type   = fpnew_pkg::I2F;
            op_mod    = 1'b1;
          end
          VFCVT_FXV: begin 
            op_type   = fpnew_pkg::I2F; 
          end
          VFCVT_RTZXUFV: begin
            op_type   = fpnew_pkg::F2I; 
            rnd_mod_i = fpnew_pkg::RTZ;
            op_mod    = 1'b1;
          end
          VFCVT_RTZXFV: begin
            op_type   = fpnew_pkg::F2I; 
            rnd_mod_i = fpnew_pkg::RTZ; 
          end
        `ifdef ZVFBFWMA_ON
          VFNCVTBF16: begin
            op_type   = fpnew_pkg::F2F;
            src2_fmt  = fpnew_pkg::FP32;
            dst_fmt   = fpnew_pkg::FP16ALT;
          end
          VFWCVTBF16: begin
            op_type   = fpnew_pkg::F2F;
            src2_fmt  = fpnew_pkg::FP16ALT;
            dst_fmt   = fpnew_pkg::FP32;
          end
        `endif
        endcase
      end
    endcase
  end

  // tag 随子路径流水返回。lane0 的 fpnew 实例携带 tag，其它 lane 不携带，
  // 因为同一条向量 uop 的 rob_entry/uop_index 对所有 lane 相同。
`ifdef TB_SUPPORT
  assign tag_fma.uop_pc             = fma_uop.uop_pc;
  assign tag_fcmp.com_tag.uop_pc    = fma_uop.uop_pc;
  assign tag_fcvt.com_tag.uop_pc    = fma_uop.uop_pc;
  assign tag_ftbl.uop_pc            = fma_uop.uop_pc;
`endif
  assign tag_fma.rob_entry          = fma_uop.rob_entry;
  assign tag_fcmp.com_tag.rob_entry = fma_uop.rob_entry;
  assign tag_fcmp.is_fcmp           = fma_uop.uop_exe_unit==FCMP;
  assign tag_fcmp.uop_index         = fma_uop.uop_index;
  assign tag_fcmp.last_uop_valid    = fma_uop.last_uop_valid;
  assign tag_fcvt.com_tag.rob_entry = fma_uop.rob_entry;
  assign tag_fcvt.eew_vd            = vd_eew;
  assign tag_fcvt.uop_index         = fma_uop.uop_index[0];
  assign tag_ftbl.rob_entry         = fma_uop.rob_entry;

  // 执行子单元
  generate
    // lane0：携带 tag，并输出本子路径的 ready/valid。
    fpnew_fma_multi #(
      `ifdef ZVFBFWMA_ON
      .FpFmtConfig        (5'b10001),
      `else
      .FpFmtConfig        (5'b10000),
      `endif
      .NumPipeRegs        (PIPEREGS),
      .PipeConfig         (fpnew_pkg::DISTRIBUTED),
      .TagType            (TAG_t)
      )
    addmul (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // 输入操作数和控制信息。
      .operands_i         (op_i[0]), // 三操作数。
      .is_boxed_i         ('1), // FP32/BF16 操作数按 NaN-box 形式传入。
      .rnd_mode_i         (rnd_mod_i),
      .op_i               (op_type),
      .op_mod_i           (op_mod),
      .src_fmt_i          (src_fmt),
      .src2_fmt_i         (src2_fmt),
      .dst_fmt_i          (dst_fmt),
      .tag_i              (tag_fma),
      .mask_i             ('0),
      .aux_i              ('0),
      // 输入握手。
      .in_valid_i         (addmul_vld),
      .in_ready_o         (fma_uop_addmul_rdy),
      .flush_i            (trap_flush_rvv),
      // 输出结果、异常状态和 tag。
      .result_o           (addmul_result[0+:`WORD_WIDTH]), 
      .status_o           (addmul_status_o[0]),          
      .extension_bit_o    (),
      .tag_o              (addmul_tag_o),
      .mask_o             (),
      .aux_o              (),
      // 输出握手。
      .out_valid_o        (addmul_result_vld),    
      .out_ready_i        (addmul_result_rdy),    
      // fpnew 内部 busy 未用于上层调度，本 wrapper 使用 ready/valid 限流。
      .busy_o             (),
      // 外部寄存器使能覆盖未使用。
      .reg_ena_i          ('0),
      // early valid 未用于结构冒险预测。
      .early_out_valid_o  ()
    );
  
    fpnew_noncomp #(
      .FpFormat           (fpnew_pkg::FP32),
      .NumPipeRegs        (PIPEREGS),
      .PipeConfig         (fpnew_pkg::DISTRIBUTED),
      .TagType            (FCMP_TAG_t)
    )
    allcmp (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // 输入操作数和控制信息。
      .operands_i         ({op_i[0][1], op_i[0][0]}), // 两操作数。
      .is_boxed_i         ('1), // FP32 操作数视为已 NaN-box。
      .rnd_mode_i         (rnd_mod_i),
      .op_i               (op_type),
      .op_mod_i           (op_mod),
      .tag_i              (tag_fcmp),
      .mask_i             ('0),
      .aux_i              ('0),
      // 输入握手。
      .in_valid_i         (allcmp_vld),
      .in_ready_o         (fma_uop_cmp_rdy),
      .flush_i            (trap_flush_rvv),
      // 输出结果、分类 mask、异常状态和 tag。
      .result_o           (allcmp_unit_res[0+:`WORD_WIDTH]),
      .status_o           (allcmp_status_o[0]),
      .extension_bit_o    (),
      .class_mask_o       (class_result[0]),
      .is_class_o         (is_class_o),
      .tag_o              (allcmp_tag_o),
      .mask_o             (),
      .aux_o              (),
      // 输出握手。
      .out_valid_o        (allcmp_result_vld_tmp),
      .out_ready_i        (allcmp_result_rdy_tmp),
      // fpnew busy 未使用。
      .busy_o             (),
      // 外部寄存器使能覆盖未使用。
      .reg_ena_i          ('0),
      // early valid 未使用。
      .early_out_valid_o  ()
    );
  
    fpnew_cast_multi #(
      `ifdef ZVFBFWMA_ON
      .FpFmtConfig        (5'b10001),
      `else
      .FpFmtConfig        (5'b10000),
      `endif
      .IntFmtConfig       (4'b1110),
      .NumPipeRegs        (PIPEREGS),
      .PipeConfig         (fpnew_pkg::DISTRIBUTED),
      .TagType            (FCVT_TAG_t)
    )
    cvt (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // 输入操作数和控制信息。
      .operands_i         (src2[0+:`WORD_WIDTH]), // 单操作数。
      .is_boxed_i         ('1), // FP32/BF16 操作数视为已 NaN-box。
      .rnd_mode_i         (rnd_mod_i),
      .op_i               (op_type),
      .op_mod_i           (op_mod),
      .src_fmt_i          (src2_fmt),
      .dst_fmt_i          (dst_fmt),
      .int_fmt_i          (int_fmt),
      .tag_i              (tag_fcvt),
      .mask_i             ('0),
      .aux_i              ('0),
      // 输入握手。
      .in_valid_i         (cvt_vld),
      .in_ready_o         (fma_uop_cvt_rdy),
      .flush_i            (trap_flush_rvv),
      // 输出转换结果、异常状态和 tag。
      .result_o           (cvt_result[0+:`WORD_WIDTH]),
      .status_o           (cvt_status_o[0]),
      .extension_bit_o    (),
      .tag_o              (cvt_tag_o),
      .mask_o             (),
      .aux_o              (),
      // 输出握手。
      .out_valid_o        (cvt_result_vld),
      .out_ready_i        (cvt_result_rdy),
      // fpnew busy 未使用。
      .busy_o             (),
      // 外部寄存器使能覆盖未使用。
      .reg_ena_i          ('0),
      // early valid 未使用。
      .early_out_valid_o  ()
    );
  
    rvv_backend_sqrt7_rec7 #(
      .TagType            (TAG_t)
    )
    tbl (
      .clk                (clk),
      .rst_n              (rst_n),
      // 输入操作数和控制信息。
      .operand_i          (src2[0+:`WORD_WIDTH]), // 单操作数。
      .vs1_i              (fma_uop.vs1),
      .rnd_mode_i         (fma_uop.frm),
      .tag_i              (tag_ftbl),         
      // 输入握手。
      .in_valid_i         (tbl_vld),
      .in_ready_o         (fma_uop_tbl_rdy),
      .flush_i            (trap_flush_rvv),
      // 输出查表近似结果和异常状态。
      .result_o           (tbl_result[0+:`WORD_WIDTH]),   
      .tbl_status_o       (tbl_status_o[0]),
      .tag_o              (tbl_tag_o),
      // 输出握手。
      .out_valid_o        (tbl_result_vld),
      .out_ready_i        (tbl_result_rdy)
    );

    // lane1..VLENW-1：只承载数据通路，不再携带 tag/ready；整条向量 uop
    // 以 lane0 的 ready/valid/tag 作为统一握手代表。
    for(i=1;i<`VLENW;i++) begin:sub_unit      
      fpnew_fma_multi #(
        `ifdef ZVFBFWMA_ON
        .FpFmtConfig        (5'b10001),
        `else
        .FpFmtConfig        (5'b10000),
        `endif
        .NumPipeRegs        (PIPEREGS),
        .PipeConfig         (fpnew_pkg::DISTRIBUTED)
        )
      addmul (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // 输入操作数和控制信息。
        .operands_i         (op_i[i]), // 三操作数。
        .is_boxed_i         ('1), // FP32/BF16 操作数按 NaN-box 形式传入。
        .rnd_mode_i         (rnd_mod_i),
        .op_i               (op_type),
        .op_mod_i           (op_mod),
        .src_fmt_i          (src_fmt),
        .src2_fmt_i         (src2_fmt),
        .dst_fmt_i          (dst_fmt),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        // 输入握手。
        .in_valid_i         (addmul_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // 输出结果和异常状态；tag/valid 由 lane0 代表。
        .result_o           (addmul_result[i*`WORD_WIDTH+:`WORD_WIDTH]), 
        .status_o           (addmul_status_o[i]),          
        .extension_bit_o    (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // 输出握手。
        .out_valid_o        (),    
        .out_ready_i        (addmul_result_rdy),    
        // fpnew busy 未使用。
        .busy_o             (),
        // 外部寄存器使能覆盖未使用。
        .reg_ena_i          ('0),
        // early valid 未使用。
        .early_out_valid_o  ()
      );
  
      fpnew_noncomp #(
        .FpFormat           (fpnew_pkg::FP32),
        .NumPipeRegs        (PIPEREGS),
        .PipeConfig         (fpnew_pkg::DISTRIBUTED)
      )
      allcmp (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // 输入操作数和控制信息。
        .operands_i         ({op_i[i][1], op_i[i][0]}), // 两操作数。
        .is_boxed_i         ('1), // FP32 操作数视为已 NaN-box。
        .rnd_mode_i         (rnd_mod_i),
        .op_i               (op_type),
        .op_mod_i           (op_mod),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        // 输入握手。
        .in_valid_i         (allcmp_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // 输出结果和异常状态；tag/valid 由 lane0 代表。
        .result_o           (allcmp_unit_res[i*`WORD_WIDTH+:`WORD_WIDTH]),
        .status_o           (allcmp_status_o[i]),
        .extension_bit_o    (),
        .class_mask_o       (class_result[i]),
        .is_class_o         (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // 输出握手。
        .out_valid_o        (),
        .out_ready_i        (allcmp_result_rdy_tmp),
        // fpnew busy 未使用。
        .busy_o             (),
        // 外部寄存器使能覆盖未使用。
        .reg_ena_i          ('0),
        // early valid 未使用。
        .early_out_valid_o  ()
      );
  
      fpnew_cast_multi #(
        `ifdef ZVFBFWMA_ON
        .FpFmtConfig        (5'b10001),
        `else
        .FpFmtConfig        (5'b10000),
        `endif
        .IntFmtConfig       (4'b1110),
        .NumPipeRegs        (PIPEREGS),
        .PipeConfig         (fpnew_pkg::DISTRIBUTED),
        .TagType            (FCVT_TAG_t)
      )
      cvt (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // 输入操作数和控制信息。
        .operands_i         (src2[i*`WORD_WIDTH+:`WORD_WIDTH]), // 单操作数。
        .is_boxed_i         ('1), // FP32/BF16 操作数视为已 NaN-box。
        .rnd_mode_i         (rnd_mod_i),
        .op_i               (op_type),
        .op_mod_i           (op_mod),
        .src_fmt_i          (src2_fmt),
        .dst_fmt_i          (dst_fmt),
        .int_fmt_i          (int_fmt),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        // 输入握手。
        .in_valid_i         (cvt_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // 输出结果和异常状态；tag/valid 由 lane0 代表。
        .result_o           (cvt_result[i*`WORD_WIDTH+:`WORD_WIDTH]),
        .status_o           (cvt_status_o[i]),
        .extension_bit_o    (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // 输出握手。
        .out_valid_o        (),
        .out_ready_i        (cvt_result_rdy),
        // fpnew busy 未使用。
        .busy_o             (),
        // 外部寄存器使能覆盖未使用。
        .reg_ena_i          ('0),
        // early valid 未使用。
        .early_out_valid_o  ()
      );
  
      rvv_backend_sqrt7_rec7 #(
      )
      tbl (
        .clk                (clk),
        .rst_n              (rst_n),
        // 输入操作数和控制信息。
        .operand_i          (src2[i*`WORD_WIDTH+:`WORD_WIDTH]), // 单操作数。
        .vs1_i              (fma_uop.vs1),
        .rnd_mode_i         (fma_uop.frm),
        .tag_i              ('0),
        // 输入握手。
        .in_valid_i         (tbl_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // 输出查表近似结果和异常状态；tag/valid 由 lane0 代表。
        .result_o           (tbl_result[i*`WORD_WIDTH+:`WORD_WIDTH]),   
        .tbl_status_o       (tbl_status_o[i]),
        .tag_o              (),
        // 输出握手。
        .out_valid_o        (),
        .out_ready_i        (tbl_result_rdy)
      );
    end
  endgenerate

  // FCMP mask 指令需要额外保存 vstart/vl/vm/v0/旧 vd：
  // fpnew_noncomp 的流水延迟为 PIPEREGS，比较结果返回时这些控制信息也要同步到达。
  assign info_vld[0][0]     = fma_uop_vld&(fma_uop.uop_exe_unit==FCMP);
  assign info_vld[0][1]     = fma_uop_vld&(fma_uop.uop_exe_unit==FNCMP);
  assign info_rdy[PIPEREGS] = allcmp_result_rdy_tmp; 
  assign cmp_info[0].vstart = fma_uop.vstart;
  assign cmp_info[0].vl     = fma_uop.vl;   
  assign cmp_info[0].vm     = fma_uop.vm;
  assign cmp_info[0].v0     = fma_uop.v0_data_valid ? fma_uop.v0_data : '1;
  assign cmp_info[0].vd     = fma_uop.vs3_data;
  
  // FCMP 控制信息流水线，与 fpnew_noncomp 的结果流水对齐。
  generate
    for(i=0;i<PIPEREGS;i++) begin
      assign info_rdy[i] = !(|info_vld[i+1]) || info_rdy[i+1];
      
      // valid 流水寄存器，可被 trap_flush_rvv 清除。
      cdffr #(
        .T            (logic [1:0])
      ) fcmp_vld_pipe ( 
        .q            (info_vld[i+1]), 
        .clk          (clk), 
        .rst_n        (rst_n),  
        .c            (trap_flush_rvv), 
        .e            (info_rdy[i]), 
        .d            (info_vld[i]) 
      );
      // FCMP 控制信息流水寄存器。
      edff # (
        .T            (FCMP_INFO_t)
      ) fcmp_info_pipe ( 
        .q            (cmp_info[i+1]), 
        .clk          (clk), 
        .rst_n        (rst_n),  
        .e            (info_vld[i][0]&info_rdy[i]), 
        .d            (cmp_info[i]) 
      );
    end
    
    always_comb begin
      // 将当前返回 uop 的 lane 比较结果放到由 uop_index 指定的分段位置；
      // 其它分段清零，后续和 cmp_d1 中暂存的旧分段 OR 合并。
      for(int i=0;i<8;i++) begin
        if(allcmp_tag_o.uop_index==i) begin 
          for(int j=0;j<`VLENW;j++) begin
            cmp[i*`VLENW+j]         = allcmp_unit_res[j*`WORD_WIDTH];
            cmp_status[i*`VLENW+j]  = allcmp_status_o[j];
          end
        end
        else begin
          cmp[i*`VLENW+:`VLENW]         = 'b0;
          cmp_status[i*`VLENW+:`VLENW]  = 'b0;
        end
      end
    end
  
    for(i=0;i<7;i++) begin
      // 非最后一个 FCMP uop 的分段比较结果先暂存在 cmp_d1/cmp_status_d1。
      // 最后一个 uop 返回且被接收时清空暂存，准备下一条 FCMP。
      assign cmp_en[i] = allcmp_result_vld_tmp&allcmp_tag_o.is_fcmp&(!allcmp_tag_o.last_uop_valid)&(allcmp_tag_o.uop_index==i);

      cdffr # (
        .T            (logic [`VLENW-1:0])
      ) fcmp_res ( 
        .q            (cmp_d1[i*`VLENW+:`VLENW]), 
        .clk          (clk), 
        .rst_n        (rst_n),  
        .c            (allcmp_result_vld_tmp&allcmp_tag_o.is_fcmp&allcmp_tag_o.last_uop_valid&allcmp_result_rdy_tmp | trap_flush_rvv), 
        .e            (cmp_en[i]), 
        .d            (cmp[i*`VLENW+:`VLENW]) 
      );

      cdffr # (
        .T            (RVFEXP_t[`VLENW-1:0])
      ) fcmp_exp ( 
        .q            (cmp_status_d1[i*`VLENW+:`VLENW]),
        .clk          (clk), 
        .rst_n        (rst_n),  
        .c            (allcmp_result_vld_tmp&allcmp_tag_o.is_fcmp&allcmp_tag_o.last_uop_valid&allcmp_result_rdy_tmp | trap_flush_rvv), 
        .e            (cmp_en[i]), 
        .d            (cmp_status[i*`VLENW+:`VLENW]) 
      );
    end

    assign cmp_res_tmp      = {(`VLEN-8*`VLENW)'(0), cmp[8*`VLENW-1:7*`VLENW], (cmp[7*`VLENW-1:0]|cmp_d1)};
    assign cmp_fexp_tmp     = {((`VLEN-8*`VLENW)*5)'(0), cmp_status[8*`VLENW-1:7*`VLENW], (cmp_status[7*`VLENW-1:0]|cmp_status_d1)};

    // 生成 prestart 和 tail 掩码。vstart 前、vl 后的元素应保留旧 vd。
    barrel_shifter #(.DATA_WIDTH(`VLEN)) 
    u_prestart (.din((`VLEN)'('1)), .shift_amount(cmp_info[PIPEREGS].vstart[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vstart_elements_tmp));
    barrel_shifter #(.DATA_WIDTH(`VLEN)) 
    u_tail (.din((`VLEN)'('1)), .shift_amount(cmp_info[PIPEREGS].vl[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(tail_elements_tmp));
    
    assign vstart_elements  = ~vstart_elements_tmp;
    assign tail_elements    = cmp_info[PIPEREGS].vl[$clog2(`VLEN)] ? 'b0 : tail_elements_tmp;

    assign v0               = {(`VLEN-8*`VLENW)'(0), cmp_info[PIPEREGS].v0};

    for(i=0;i<`VLEN;i++) begin: FCMP_MERGE
      always_comb begin
        // body 且 mask 允许的元素写入比较结果；其它元素保持旧 vd。
        if(!(vstart_elements[i]|tail_elements[i]) & (cmp_info[PIPEREGS].vm|v0[i])) begin
          cmp_res[i]        = cmp_res_tmp[i];
          cmp_fexp_per1[i]  = cmp_fexp_tmp[i];
        end
        else begin
          cmp_res[i]        = cmp_info[PIPEREGS].vd[i];
          cmp_fexp_per1[i]  = 'b0;
        end
      end
    end

    for(i=0;i<`VLENB;i++) begin
      always_comb begin
        // fpexp 以 byte 为单位写回；一个 byte 内任意 bit 产生异常就 OR 到该 byte。
        cmp_fexp[i]   = 'b0;
        for(int j=0;j<8;j++) begin
          cmp_fexp[i] = cmp_fexp[i] | cmp_fexp_per1[i*8+j];
        end
      end
    end
  endgenerate

  // allcmp 子路径最终结果选择：
  // - VFCLASS：输出 class mask 扩展成 32-bit lane。
  // - FNCMP/VFSGNJ/VFMIN/VFMAX：直接使用 fpnew_noncomp 的向量结果。
  // - FCMP mask：只有 last_uop_valid 时输出跨 uop 合并后的 mask。
  always_comb begin
    allcmp_result_vld     = 'b0;
    allcmp_result         = allcmp_unit_res;
    allcmp_result_rdy_tmp = 'b1;
    allcmp_fexp           = 'b0;

    if(allcmp_result_vld_tmp) begin
      if(is_class_o) begin
        allcmp_result_vld     = 'b1;
        allcmp_result_rdy_tmp = allcmp_result_rdy;
        for(int i=0;i<`VLENW;i++) begin
          allcmp_result[i*`WORD_WIDTH+:`WORD_WIDTH] = {22'b0, class_result[i]};
          allcmp_fexp[4*i+:4]                       = {4{allcmp_status_o[i]}};
        end
      end
      else if(!allcmp_tag_o.is_fcmp) begin
        allcmp_result_vld     = 'b1;
        allcmp_result         = allcmp_unit_res;
        allcmp_result_rdy_tmp = allcmp_result_rdy;
        for(int i=0;i<`VLENW;i++) begin
          allcmp_fexp[4*i+:4] = {4{allcmp_status_o[i]}};
        end
      end
      else if(allcmp_tag_o.last_uop_valid) begin
        allcmp_result_vld     = 'b1;
        allcmp_result         = cmp_res;
        allcmp_result_rdy_tmp = allcmp_result_rdy;
        allcmp_fexp           = cmp_fexp;
      end
    end
  end

  // 四条子路径结果仲裁到一路 ROB 写回结果。
  // 只有后级 ready 时才向 arb_round_robin 提供请求，避免提前消费子路径结果。
  arb_round_robin #(.REQ_NUM(4)) arb2rob (.clk(clk), .rst_n(rst_n), .req(result_vld), .grant(arb_rdy));
  assign result_vld         = fma_result_rdy ? {tbl_result_vld, cvt_result_vld, allcmp_result_vld, addmul_result_vld} : 'b0;
  assign fma_result_vld     = |result_vld;
  assign addmul_result_rdy  = arb_rdy[0];
  assign allcmp_result_rdy  = arb_rdy[1];
  assign cvt_result_rdy     = arb_rdy[2];
  assign tbl_result_rdy     = arb_rdy[3];

  always_comb begin
    fma_result = 'b0;

    case(1'b1)
      arb_rdy[3]: begin // 选择 sqrt7/rec7 table 结果。
      `ifdef TB_SUPPORT
        fma_result.uop_pc     = tbl_tag_o.uop_pc;
      `endif
        fma_result.rob_entry  = tbl_tag_o.rob_entry;
        fma_result.w_valid    = 'b1;
        fma_result.vsaturate  = 'b0;
        fma_result.w_data     = tbl_result;
        for(int i=0;i<`VLENW;i++) begin
          fma_result.fpexp[4*i+:4]  = {4{tbl_status_o[i]}};
        end
      end
      arb_rdy[2]: begin // 选择 FCVT/BF16 转换结果。
      `ifdef TB_SUPPORT
        fma_result.uop_pc     = cvt_tag_o.com_tag.uop_pc;
      `endif
        fma_result.rob_entry  = cvt_tag_o.com_tag.rob_entry;
        fma_result.w_valid    = 'b1;
        fma_result.vsaturate  = 'b0;
        for(int i=0;i<`VLENW;i++) begin
        `ifdef ZVFBFWMA_ON
          case(cvt_tag_o.eew_vd) 
            EEW16: begin
              if(cvt_tag_o.uop_index) begin  
                fma_result.w_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`HWORD_WIDTH];
                fma_result.w_data[        i*`HWORD_WIDTH+:`HWORD_WIDTH] = 'b0;
                fma_result.fpexp[`VLENB/2+2*i+:2]                       = {2{cvt_status_o[i]}};
                fma_result.fpexp[         2*i+:2]                       = 'b0;
              end
              else begin
                fma_result.w_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH] = 'b0;
                fma_result.w_data[        i*`HWORD_WIDTH+:`HWORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`HWORD_WIDTH];
                fma_result.fpexp[`VLENB/2+2*i+:2]                       = 'b0;
                fma_result.fpexp[         2*i+:2]                       = {2{cvt_status_o[i]}};
              end
            end
            default: begin // EEW32。
              fma_result.w_data[i*`WORD_WIDTH+:`WORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`WORD_WIDTH];
              fma_result.fpexp[4*i+:4]                      = {4{cvt_status_o[i]}};
            end
          endcase
        `else
          fma_result.w_data[i*`WORD_WIDTH+:`WORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`WORD_WIDTH];
          fma_result.fpexp[4*i+:4]                      = {4{cvt_status_o[i]}};
        `endif
        end
      end
      arb_rdy[1]: begin // 选择 allcmp/class/sign/minmax/FCMP mask 结果。
      `ifdef TB_SUPPORT
        fma_result.uop_pc     = allcmp_tag_o.com_tag.uop_pc;
      `endif
        fma_result.rob_entry  = allcmp_tag_o.com_tag.rob_entry;
        fma_result.w_valid    = 'b1;
        fma_result.vsaturate  = 'b0;
        fma_result.w_data     = allcmp_result;
        fma_result.fpexp      = allcmp_fexp;
      end
      arb_rdy[0]: begin // 选择 add/mul/fused MAC 结果。
      `ifdef TB_SUPPORT
        fma_result.uop_pc     = addmul_tag_o.uop_pc;
      `endif
        fma_result.rob_entry  = addmul_tag_o.rob_entry;
        fma_result.w_valid    = 'b1;
        fma_result.vsaturate  = 'b0;
        fma_result.w_data     = addmul_result;
        for(int i=0;i<`VLENW;i++) begin
          fma_result.fpexp[4*i+:4]  = {4{addmul_status_o[i]}};
        end
      end
    endcase
  end

endmodule
`endif // ZVE32F_ON
