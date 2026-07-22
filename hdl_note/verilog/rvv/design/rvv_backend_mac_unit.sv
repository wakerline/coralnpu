`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_mac_unit
//------------------------------------------------------------------------------
// 功能定位：
// 1. MUL/MAC pipeline 的实际执行单元，既能执行纯乘法，也能执行乘加/乘减。
// 2. 覆盖 VMUL/VMULH/VWMUL/VSMUL 以及 VMACC/VMADD/VNMSAC/VNMSUB/VWMACC* 等指令。
// 3. 与 `rvv_backend_mul_unit` 类似，本模块先拆成 byte 部分积矩阵；不同之处是
//    EX2 还会把乘积与 `mac_addsrc` 做加/减，形成 MAC 结果。
// 4. `mac_mul_reverse` 表示使用 addsrc - product 的反向乘减路径；
//    `is_vmac` 表示最终结果来自乘加/乘减，`is_vsmul` 表示复用 VSMUL 舍入饱和路径。
//
// 流水分界：
// - EX1：源选择、标量广播、byte 部分积生成，并按 EEW 使能必要部分积寄存器。
// - EX2：按 EEW 重组乘积、执行 MAC 加/减、VSMUL 舍入饱和、组装 ROB 写回包。

module rvv_backend_mac_unit (
  // 输出。
  mac2rob_uop_valid, 
  mac2rob_uop_data,
  // 输入。
  clk, 
  rst_n, 
  rs2mac_uop_valid, 
  rs2mac_uop_data,
  mac_pipe_vld_en,
  mac_pipe_data_en,
  trap_flush_rvv
);

input                                 clk;
input                                 rst_n;
input                                 rs2mac_uop_valid;
input   MUL_RS_t                      rs2mac_uop_data;
input                                 mac_pipe_vld_en;
input                                 mac_pipe_data_en;
input                                 trap_flush_rvv;
output                                mac2rob_uop_valid;
output  PU2ROB_t                      mac2rob_uop_data;

// 控制字段、源操作数和结果重组信号。
logic [`ROB_DEPTH_WIDTH-1:0]          mac_uop_rob_entry;
logic [`FUNCT6_WIDTH-1:0]             mac_uop_funct6;
logic [`FUNCT3_WIDTH-1:0]             mac_uop_funct3;
RVVXRM                                mac_uop_xrm;
EEW_e                                 mac_top_vs_eew;
logic [`VLEN-1:0]                     mac_uop_vs1_data;
logic [`VLEN-1:0]                     mac_uop_vs2_data;
logic [`XLEN-1:0]                     mac_uop_rs1_data;
logic [`VLEN-1:0]                     mac_uop_vs3_data;
logic                                 mac_uop_index;

logic                                 is_vv; // 1 表示向量-向量，0 表示向量-标量。
logic [`VLEN-1:0]                     mac_src2;
logic [`VLEN-1:0]                     mac_src1;
logic [`VLEN-1:0]                     mac_addsrc;
logic                                 mac_src2_is_signed;
logic                                 mac_src1_is_signed;
logic                                 mac_is_widen;
logic                                 mac_keep_low_bits;
logic                                 mac_mul_reverse;
logic                                 is_vsmul;
logic                                 is_vmac;

logic [`VLEN-1:0]                     mac_src2_mux;
logic [`VLEN-1:0]                     mac_src1_mux;
logic [`VLENB-1:0]                    mac_src2_is_signed_extend;
logic [`VLENB-1:0]                    mac_src1_is_signed_extend;

logic [`VLENB-1:0][`BYTE_WIDTH-1:0]   mac8_in0;
logic [`VLENB-1:0]                    mac8_in0_is_signed;
logic [`VLENB-1:0][`BYTE_WIDTH-1:0]   mac8_in1;
logic [`VLENB-1:0]                    mac8_in1_is_signed;
logic [`VLEN/2-1:0][`HWORD_WIDTH-1:0] mac8_out;  // 每个 32-bit tile 有 4x4 个 byte 部分积。

logic [`VLEN/2-1:0]                   mac8_en;
// EX2 阶段寄存后的部分积和控制信号。
logic [`VLEN/2-1:0][`HWORD_WIDTH-1:0] mac8_out_d1;  
logic [`VLEN-1:0]                     mac_addsrc_d1;
logic [2*`VLEN-1:0]                   mac_addsrc_widen_d1;

logic                                 rs2mac_uop_valid_d1;
logic                                 mac_src2_is_signed_d1;
logic                                 mac_src1_is_signed_d1;
logic                                 mac_is_widen_d1;
logic                                 mac_keep_low_bits_d1;
logic                                 mac_mul_reverse_d1;
logic                                 is_vsmul_d1;
logic                                 is_vmac_d1;
RVVXRM                                mac_uop_xrm_d1;
EEW_e                                 mac_top_vs_eew_d1;
logic [`ROB_DEPTH_WIDTH-1:0]          mac_uop_rob_entry_d1;

logic [`VLENB-1:0][`HWORD_WIDTH-1:0]  mac_rslt_full_eew8_d1;
logic [2*`VLEN-1:0]                   mac_rslt_eew8_widen_d1;
logic [`VLEN-1:0]                     mac_rslt_eew8_no_widen_d1;
logic [`VLENB-1:0]                    vsmul_round_incr_eew8_d1;
logic [`VLEN-1:0]                     vsmul_rslt_eew8_d1;
logic [`VLENB-1:0]                    vsmul_sat_eew8_d1;
logic [`VLEN-1:0]                     mac_rslt_eew8_d1;
logic [`VLENB-1:0]                    update_vxsat_eew8_d1;
logic [`VLENB-1:0][`BYTE_WIDTH:0]     vmac_mul_add_eew8_no_widen_d1;
logic [`VLENB-1:0][`BYTE_WIDTH:0]     vmac_mul_sub_eew8_no_widen_d1;
logic [`VLEN-1:0]                     vmac_rslt_eew8_no_widen_d1;
logic [`VLENB-1:0][`HWORD_WIDTH:0]    vmac_mul_add_eew8_widen_d1;
logic [`VLENB-1:0][`HWORD_WIDTH:0]    vmac_mul_sub_eew8_widen_d1;
logic [2*`VLEN-1:0]                   vmac_rslt_eew8_widen_d1;

logic [`VLENH-1:0][17:0]              mac_rslt_part16_eew16_d1;
logic [`VLENH-1:0][`WORD_WIDTH-1:0]   mac_rslt_full_eew16_d1;
logic [2*`VLEN-1:0]                   mac_rslt_eew16_widen_d1;
logic [`VLEN-1:0]                     mac_rslt_eew16_no_widen_d1;
logic [`VLENH-1:0]                    vsmul_round_incr_eew16_d1;
logic [`VLEN-1:0]                     vsmul_rslt_eew16_d1;
logic [`VLENH-1:0]                    vsmul_sat_eew16_d1;
logic [`VLEN-1:0]                     mac_rslt_eew16_d1;
logic [`VLENB-1:0]                    update_vxsat_eew16_d1;
logic [`VLENH-1:0][`HWORD_WIDTH:0]    vmac_mul_add_eew16_no_widen_d1;
logic [`VLENH-1:0][`HWORD_WIDTH:0]    vmac_mul_sub_eew16_no_widen_d1;
logic [`VLEN-1:0]                     vmac_rslt_eew16_no_widen_d1;
logic [`VLENH-1:0][`WORD_WIDTH:0]     vmac_mul_add_eew16_widen_d1;
logic [`VLENH-1:0][`WORD_WIDTH:0]     vmac_mul_sub_eew16_widen_d1;
logic [2*`VLEN-1:0]                   vmac_rslt_eew16_widen_d1;

logic [`VLENW-1:0][17:0]              mac_rslt_part16_eew32_d1;
logic [`VLENW-1:0][33:0]              mac_rslt_part32_eew32_d1;
logic [`VLENW-1:0][49:0]              mac_rslt_part48_eew32_d1;
logic [`VLENW-1:0][2*`WORD_WIDTH-1:0] mac_rslt_full_eew32_d1;
logic [2*`VLEN-1:0]                   mac_rslt_eew32_widen_d1;
logic [`VLEN-1:0]                     mac_rslt_eew32_no_widen_d1;
logic [`VLENW-1:0]                    vsmul_round_incr_eew32_d1;
logic [`VLEN-1:0]                     vsmul_rslt_eew32_d1;
logic [`VLENW-1:0]                    vsmul_sat_eew32_d1;
logic [`VLEN-1:0]                     mac_rslt_eew32_d1;
logic [`VLENB-1:0]                    update_vxsat_eew32_d1;
logic [`VLENW-1:0][`WORD_WIDTH:0]     vmac_mul_add_eew32_no_widen_d1;
logic [`VLENW-1:0][`WORD_WIDTH:0]     vmac_mul_sub_eew32_no_widen_d1;
logic [`VLEN-1:0]                     vmac_rslt_eew32_no_widen_d1;
logic [`VLENW-1:0][2*`WORD_WIDTH:0]   vmac_mul_add_eew32_widen_d1;
logic [`VLENW-1:0][2*`WORD_WIDTH:0]   vmac_mul_sub_eew32_widen_d1;
logic [2*`VLEN-1:0]                   vmac_rslt_eew32_widen_d1;

logic [`VLENB-1:0]                    update_vxsat;

`ifdef TB_SUPPORT
logic [`PC_WIDTH-1:0]                 mac_uop_pc;
logic [`PC_WIDTH-1:0]                 mac_uop_pc_d1;
`endif

// 整数循环变量和 generate 变量。
integer i,j;
genvar z,x,y;

// 输入 uop 字段拆分。
assign mac_uop_rob_entry = rs2mac_uop_data.rob_entry;
assign mac_uop_funct6    = rs2mac_uop_data.uop_funct6.ari_funct6;
assign mac_uop_funct3    = rs2mac_uop_data.uop_funct3;
assign mac_uop_xrm       = rs2mac_uop_data.vxrm;
assign mac_top_vs_eew    = rs2mac_uop_data.vs2_eew;
assign mac_uop_vs1_data  = rs2mac_uop_data.vs1_data;
assign mac_uop_vs2_data  = rs2mac_uop_data.vs2_data;
assign mac_uop_vs3_data  = rs2mac_uop_data.vs3_data;
assign mac_uop_rs1_data  = rs2mac_uop_data.vs1_data[`XLEN-1:0];
assign mac_uop_index     = rs2mac_uop_data.uop_index;
`ifdef TB_SUPPORT
assign mac_uop_pc        = rs2mac_uop_data.uop_pc;
`endif

// 全局执行控制：
// 根据 funct3/funct6 选择乘法两个源、累加源 addsrc、符号模式、是否拓宽、
// 是否执行 MAC、是否执行反向乘减。
always@(*) begin
  case ({rs2mac_uop_valid,mac_uop_funct3}) 
    {1'b1,OPMVV} : begin
      is_vv = 1'b1;
      case (mac_uop_funct6) 
        VMACC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;  //
          is_vmac            = 1'b1;
        end
        VNMSAC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMADD : begin
          mac_src2           = mac_uop_vs3_data; // VMADD/VNMSUB 使用旧 vd/vs3 作为乘法源之一。
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSUB : begin
          mac_src2           = mac_uop_vs3_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACC : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMUL: begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULH : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHSU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMUL : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0; // 拓宽路径不使用 keep_low_bits。
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0; // 拓宽路径不使用 keep_low_bits。
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0; // 拓宽路径不使用 keep_low_bits。
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        default : begin 
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;
        end//end default
      endcase//end funct6
    end//end OPMVV
    {1'b1,OPMVX} : begin
      is_vv = 1'b0;
      case (mac_uop_funct6) 
        VMACC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSAC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMADD : begin
          mac_src2           = mac_uop_vs3_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSUB : begin
          mac_src2           = mac_uop_vs3_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACC : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCUS : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMUL : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULH : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHSU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMUL : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        default : begin 
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;        
        end//end default
      endcase
    end//end OPMVX
    {1'b1,OPIVV} : begin
      is_vv = 1'b1;
      case (mac_uop_funct6) 
        VSMUL_VMVNRR : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b1;
          is_vmac            = 1'b0;
        end
        default : begin 
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;  
        end//end default
      endcase//end funct6
    end//end OPIVV
    {1'b1,OPIVX} : begin
      is_vv = 1'b0;
      case (mac_uop_funct6) 
        VSMUL_VMVNRR : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b1;
          is_vmac            = 1'b0;
        end
        default : begin //currently put default the same as VSMUL_VMVNRR
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;          
        end//end default
      endcase//end funct6
    end//end OPIVX
    default : begin
      is_vv              = 1'b1;
      mac_src2           = `VLEN'b0;
      mac_src1           = `VLEN'b0;
      mac_addsrc         = `VLEN'b0;
      mac_src2_is_signed = 1'b0;
      mac_src1_is_signed = 1'b0;
      mac_is_widen       = 1'b0;
      mac_keep_low_bits  = 1'b0;
      mac_mul_reverse    = 1'b0;
      is_vsmul           = 1'b0;
      is_vmac            = 1'b0;
    end//end default
  endcase//end funct3
end

// MAC 阵列输入准备：
// - 向量-标量形式按 EEW 广播 rs1。
// - signed_extend 只在每个元素最低 byte 位置携带符号控制，用于后续部分积重组。
always@(*) begin
  mac_src2_mux                  = mac_src2;
  
  case (mac_top_vs_eew) 
    EEW16 : begin
      mac_src1_mux              = is_vv ? mac_src1 : {(`VLENH){mac_src1[`HWORD_WIDTH-1:0]}};
      mac_src2_is_signed_extend = {(`VLENH){mac_src2_is_signed,1'b0}};  //每个16bit计算分配1bit
      mac_src1_is_signed_extend = {(`VLENH){mac_src1_is_signed,1'b0}};
    end//end eew16
    EEW32 : begin
      mac_src1_mux              = is_vv ? mac_src1 : {(`VLENW){mac_src1[`WORD_WIDTH-1:0]}};
      mac_src2_is_signed_extend = {(`VLENW){mac_src2_is_signed,3'b0}};  //每个32bit计算分配1bit
      mac_src1_is_signed_extend = {(`VLENW){mac_src1_is_signed,3'b0}};
    end//end eew32
    default : begin //default use eew8
      mac_src1_mux              = is_vv ? mac_src1 : {`VLENB{mac_src1[`BYTE_WIDTH-1:0]}};
      mac_src2_is_signed_extend = {`VLENB{mac_src2_is_signed}};  //每个8bit计算分配1bit
      mac_src1_is_signed_extend = {`VLENB{mac_src1_is_signed}};
    end//end default
  endcase
end

// 将 VLEN 数据拆成 byte 粒度输入，供统一的 8x8 部分积阵列使用。
always@(*) begin
  for (i=0; i<`VLENB; i=i+1) begin
      mac8_in0[i]           = mac_src2_mux[i*`BYTE_WIDTH +: `BYTE_WIDTH];
      mac8_in1[i]           = mac_src1_mux[i*`BYTE_WIDTH +: `BYTE_WIDTH];
      mac8_in0_is_signed[i] = mac_src2_is_signed_extend[i];
      mac8_in1_is_signed[i] = mac_src1_is_signed_extend[i];
  end
end

// 只打拍当前 EEW 需要的部分积：
// EEW8 只需要每个 byte 的对角部分积；EEW16 需要 2x2 部分积；EEW32 使用完整 4x4。
always_comb begin
  mac8_en = 'b0;

  case (mac_top_vs_eew) 
    EEW8: begin
      for(int i=0;i<`VLENW;i++) begin
        mac8_en[16*i]    = mac_pipe_data_en;
        mac8_en[16*i+5]  = mac_pipe_data_en;
        mac8_en[16*i+10] = mac_pipe_data_en;
        mac8_en[16*i+15] = mac_pipe_data_en;
      end
    end
    EEW16: begin
      for(int i=0;i<`VLENW;i++) begin
        mac8_en[16*i]    = mac_pipe_data_en;
        mac8_en[16*i+1]  = mac_pipe_data_en;
        mac8_en[16*i+4]  = mac_pipe_data_en;
        mac8_en[16*i+5]  = mac_pipe_data_en;
        mac8_en[16*i+10] = mac_pipe_data_en;
        mac8_en[16*i+11] = mac_pipe_data_en;
        mac8_en[16*i+14] = mac_pipe_data_en;
        mac8_en[16*i+15] = mac_pipe_data_en;
      end
    end
    EEW32: mac8_en = {(`VLEN/2){mac_pipe_data_en}};
  endcase
end

// 8x8 部分积阵列，每个 32-bit tile 一个 4x4 byte 乘法矩阵。
generate 
  for (z=0; z<`VLENW; z=z+1) begin: cnt_tiles
    for (x=0; x<`WORD_WIDTH/`BYTE_WIDTH; x=x+1) begin: cnt_src0_axis    //操作数1， 0~3
      for (y=0; y<`WORD_WIDTH/`BYTE_WIDTH; y=y+1) begin: cnt_src1_axis  //操作数2， 0~3
        rvv_backend_mul_unit_mul8 
        u_mul8 (
          .res            (mac8_out[z*16+y*4+x]     ), // 16-bit 部分积输出。
          .src0           (mac8_in0[z*4+x]          ), 
          .src0_is_signed (mac8_in0_is_signed[z*4+x]),
          .src1           (mac8_in1[z*4+y]          ), 
          .src1_is_signed (mac8_in1_is_signed[z*4+y])
        );

        edff #(
          .T              (logic [`HWORD_WIDTH-1:0])
        ) 
        u_mul8_delay (
          .q              (mac8_out_d1[z*16+y*4+x]  ), 
          .clk            (clk                      ), 
          .rst_n          (rst_n                    ), 
          .e              (mac8_en[z*16+y*4+x]      ),     
          .d              (mac8_out[z*16+y*4+x]     )
        );
      end
    end
  end
endgenerate

cdffr #(.T(logic))              u_valid_delay (
  .clk(clk), .rst_n(rst_n), .c(trap_flush_rvv), .e(mac_pipe_vld_en), .d(rs2mac_uop_valid), .q(rs2mac_uop_valid_d1));
edff  #(.T(logic [`VLEN-1:0]))  u_addsrc_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_addsrc), .q(mac_addsrc_d1));
edff #(.T(logic))               u_src2_is_signed_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_src2_is_signed), .q(mac_src2_is_signed_d1));
edff #(.T(logic))               u_src1_is_signed_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_src1_is_signed), .q(mac_src1_is_signed_d1));
edff #(.T(logic))               u_is_widen_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_is_widen), .q(mac_is_widen_d1));
edff #(.T(logic))               u_keep_low_bits_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_keep_low_bits), .q(mac_keep_low_bits_d1));
edff #(.T(logic))               u_is_vsmul_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(is_vsmul), .q(is_vsmul_d1));
edff #(.T(logic))               u_mul_reverse_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_mul_reverse), .q(mac_mul_reverse_d1));
edff #(.T(logic))               u_is_vmac_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(is_vmac), .q(is_vmac_d1));
edff #(.T(RVVXRM))              u_xrm_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_uop_xrm), .q(mac_uop_xrm_d1));
edff #(.T(EEW_e))               u_eew_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_top_vs_eew), .q(mac_top_vs_eew_d1));
edff #(.T(logic [`ROB_DEPTH_WIDTH-1:0]))  u_rob_entry_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_uop_rob_entry), .q(mac_uop_rob_entry_d1));
`ifdef TB_SUPPORT
edff #(.T(logic [`PC_WIDTH-1:0]))         u_PC_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_uop_pc), .q(mac_uop_pc_d1));
`endif

/////////////////////////////////////////////////
/////// 进入 EX2 阶段：部分积重组和累加 ///////
/////////////////////////////////////////////////

// 拓宽 MAC 的 addsrc 是 2*EEW 宽；这里复制 VLEN 到 2*VLEN 临时总线，便于索引。
assign mac_addsrc_widen_d1 = {2{mac_addsrc_d1}}; 

// EEW8：完整乘积为 16-bit；MAC 普通路径加/减 8-bit addsrc，拓宽路径加/减 16-bit addsrc。
always@(*) begin
  for (i=0; i<`VLENW; i=i+1) begin: tiles_eew8
    for (j=0; j<`WORD_WIDTH/`BYTE_WIDTH; j=j+1) begin // 
      //因为索引 5 = 4+1, 10 = 8+2, 15 = 12+3，模式为 i*16 + j*5，恰好取到对角线位置。
      mac_rslt_full_eew8_d1[i*4+j]                                   = mac8_out_d1[i*16+j*5];  //16位
      mac_rslt_eew8_widen_d1[2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH] = mac_rslt_full_eew8_d1[i*4+j]; // 拓宽结果拼到 2*VLEN 临时总线。
      mac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]  = mac_keep_low_bits_d1 ? 
                                                                       mac_rslt_full_eew8_d1[i*4+j][0          +:`BYTE_WIDTH] : 
                                                                       mac_rslt_full_eew8_d1[i*4+j][`BYTE_WIDTH+:`BYTE_WIDTH];
      // VSMUL 定点舍入：EEW8 右移 7 位。
      // VSMUL 只有一种需要饱和的特殊溢出：最小负数 × 最小负数。0x80 × 0x80 = 0x4000, 要执行近似0x4000 >>> 7 = 0x80
      case(mac_uop_xrm_d1)
        ROD: vsmul_round_incr_eew8_d1[i*4+j] = !mac_rslt_full_eew8_d1[i*4+j][7] && (|mac_rslt_full_eew8_d1[i*4+j][6:0]);
        RDN: vsmul_round_incr_eew8_d1[i*4+j] = 'b0; 
        RNE: begin 
             vsmul_round_incr_eew8_d1[i*4+j] = mac_rslt_full_eew8_d1[i*4+j][6] && 
                                               ( (|mac_rslt_full_eew8_d1[i*4+j][5:0]) || mac_rslt_full_eew8_d1[i*4+j][7] );
        end
        // RNU。
        default: vsmul_round_incr_eew8_d1[i*4+j] = mac_rslt_full_eew8_d1[i*4+j][6];
      endcase
      
      // VSMUL 饱和检测。
      vsmul_sat_eew8_d1[i*4+j] = mac_rslt_full_eew8_d1[i*4+j][15:14] == 2'b01;
      vsmul_rslt_eew8_d1[`BYTE_WIDTH*(i*4+j)+:`BYTE_WIDTH] = vsmul_sat_eew8_d1[i*4+j] ? 8'h7f :
                                   mac_rslt_full_eew8_d1[i*4+j][(`BYTE_WIDTH-1)+:`BYTE_WIDTH] + {7'b0,vsmul_round_incr_eew8_d1[i*4+j]};  //[14:7]

      // VMAC 普通/拓宽路径：根据 mac_mul_reverse 选择 addsrc + product 或 addsrc - product。
      vmac_mul_add_eew8_no_widen_d1[i*4+j] = {1'b0,mac_addsrc_d1[            `BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} + 
                                             {1'b0,mac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} ; // 9-bit 防止进位丢失。
      vmac_mul_sub_eew8_no_widen_d1[i*4+j] = {1'b0,mac_addsrc_d1[            `BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} - 
                                             {1'b0,mac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} ;
      vmac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH] = mac_mul_reverse_d1 ? 
                                                                         vmac_mul_sub_eew8_no_widen_d1[i*4+j][`BYTE_WIDTH-1:0] :
                                                                         vmac_mul_add_eew8_no_widen_d1[i*4+j][`BYTE_WIDTH-1:0] ;

      vmac_mul_add_eew8_widen_d1[i*4+j] = {1'b0,mac_addsrc_widen_d1[   2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} + 
                                          {1'b0,mac_rslt_eew8_widen_d1[2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} ; //17bit
      vmac_mul_sub_eew8_widen_d1[i*4+j] = {1'b0,mac_addsrc_widen_d1[   2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} - 
                                          {1'b0,mac_rslt_eew8_widen_d1[2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} ;
      vmac_rslt_eew8_widen_d1[`HWORD_WIDTH*(i*4+j) +: `HWORD_WIDTH] = mac_mul_reverse_d1 ? 
                                                                        vmac_mul_sub_eew8_widen_d1[i*4+j][2*`BYTE_WIDTH-1:0] :
                                                                        vmac_mul_add_eew8_widen_d1[i*4+j][2*`BYTE_WIDTH-1:0] ;
    end
  end
end

always_comb begin
  casex({is_vmac_d1,mac_is_widen_d1,is_vsmul_d1,mac_is_widen_d1})
    4'b11?? : mac_rslt_eew8_d1 = vmac_rslt_eew8_widen_d1[`VLEN-1:0];  // MAC 拓宽。
    4'b10?? : mac_rslt_eew8_d1 = vmac_rslt_eew8_no_widen_d1;          // MAC 普通。
    4'b0?1? : mac_rslt_eew8_d1 = vsmul_rslt_eew8_d1;                  // VSMUL。
    4'b0?01 : mac_rslt_eew8_d1 = mac_rslt_eew8_widen_d1[`VLEN-1:0];   // MUL 拓宽。
    4'b0?00 : mac_rslt_eew8_d1 = mac_rslt_eew8_no_widen_d1;           // MUL 普通。
    default : mac_rslt_eew8_d1 = 'b0;
  endcase
end

assign update_vxsat_eew8_d1 = vsmul_sat_eew8_d1;

// EEW16：每个 16-bit 乘法由 4 个 8x8 部分积重组，完整乘积为 32-bit。
// 非拓宽 MUL/MAC 只保留低 16 位或高 16 位；拓宽路径保留完整 32-bit 结果。
always@(*) begin
  for (i=0; i<`VLENW; i=i+1) begin: tiles_eew16
    for (j=0; j<`WORD_WIDTH/`HWORD_WIDTH; j=j+1) begin /
      //j=0 → 使用索引 0,1,4,5（左上角 2×2）
      //j=1 → 使用索引 10,11,14,15（右下角 2×2）

      //(AH:AL) * (BH:BL) = AL*BL + (AH*BL + AL*BH)<<8 + AH*BH<<16
      // mac8_out_d1[i*16+j*10+5]  // 高×高
      // mac8_out_d1[i*16+j*10]    // 低×低
      // mac8_out_d1[i*16+j*10+4]  // 低/高交叉项之一
      // mac8_out_d1[i*16+j*10+1]  // 另一个交叉项
      //AH*BL + AL*BH
      mac_rslt_part16_eew16_d1[2*i+j] = {{2{mac8_out_d1[i*16+j*10+4][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+j*10+4]} + //AH*BL
                                        {{2{mac8_out_d1[i*16+j*10+1][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+j*10+1]} ; //AL*BH

      mac_rslt_full_eew16_d1[2*i+j] = {mac8_out_d1[i*16+j*10+5],mac8_out_d1[i*16+j*10]} + 
                                      {{6{mac_rslt_part16_eew16_d1[2*i+j][17]}},mac_rslt_part16_eew16_d1[2*i+j],8'b0};  //中间交叉16位

      mac_rslt_eew16_widen_d1[2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH] = mac_rslt_full_eew16_d1[i*2+j];  // 拓宽结果按 32-bit 元素写入总线
      mac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]  = mac_keep_low_bits_d1 ? 
                                                                            mac_rslt_full_eew16_d1[i*2+j][0           +:`HWORD_WIDTH] : 
                                                                            mac_rslt_full_eew16_d1[i*2+j][`HWORD_WIDTH+:`HWORD_WIDTH];
      // VSMUL 定点舍入：SEW=16 时右移量是 15，不是 16。
      case(mac_uop_xrm_d1)
        ROD: vsmul_round_incr_eew16_d1[i*2+j] = !mac_rslt_full_eew16_d1[i*2+j][15] && (|mac_rslt_full_eew16_d1[i*2+j][14:0]);
        RDN: vsmul_round_incr_eew16_d1[i*2+j] = 'b0; 
        RNE: begin 
             vsmul_round_incr_eew16_d1[i*2+j] = mac_rslt_full_eew16_d1[i*2+j][14] && 
                                                ( (|mac_rslt_full_eew16_d1[i*2+j][13:0]) || mac_rslt_full_eew16_d1[i*2+j][15]);
             
        end
        // RNU：直接看被截掉的最高位。
        default: vsmul_round_incr_eew16_d1[i*2+j] = mac_rslt_full_eew16_d1[i*2+j][14];
      endcase

      // VSMUL 饱和检测：正溢出时钳位到 0x7fff。
      vsmul_sat_eew16_d1[i*2+j] = mac_rslt_full_eew16_d1[i*2+j][31:30] == 2'b01;

      vsmul_rslt_eew16_d1[16*(i*2+j) +:16]= vsmul_sat_eew16_d1[i*2+j] ? 16'h7fff :
                                              // 右移 15 位后加舍入增量。
                                              mac_rslt_full_eew16_d1[i*2+j][(`HWORD_WIDTH-1)+:`HWORD_WIDTH] + 
                                              {15'b0,vsmul_round_incr_eew16_d1[i*2+j]} ;  

      // VMAC 普通路径：16-bit addsrc 与 16-bit 乘法结果做加/减，结果仍为 16-bit。
      vmac_mul_add_eew16_no_widen_d1[i*2+j] = {1'b0,mac_addsrc_d1[             `HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} + 
                                              {1'b0,mac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} ; //17bit
      vmac_mul_sub_eew16_no_widen_d1[i*2+j] = {1'b0,mac_addsrc_d1[             `HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} - 
                                              {1'b0,mac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} ;
      vmac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +:`HWORD_WIDTH] = mac_mul_reverse_d1 ? 
                                                                           vmac_mul_sub_eew16_no_widen_d1[i*2+j][`HWORD_WIDTH-1:0] :
                                                                           vmac_mul_add_eew16_no_widen_d1[i*2+j][`HWORD_WIDTH-1:0] ;

      // VMAC 拓宽路径：32-bit addsrc_widen 与 32-bit 乘积累加/累减。                                                                     
      vmac_mul_add_eew16_widen_d1[i*2+j] = {1'b0,mac_addsrc_widen_d1[    2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} + 
                                           {1'b0,mac_rslt_eew16_widen_d1[2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} ; //33bit
      vmac_mul_sub_eew16_widen_d1[i*2+j] = {1'b0,mac_addsrc_widen_d1[    2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} - 
                                           {1'b0,mac_rslt_eew16_widen_d1[2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} ;
      vmac_rslt_eew16_widen_d1[`WORD_WIDTH*(i*2+j) +: `WORD_WIDTH] = mac_mul_reverse_d1 ? 
                                                                       vmac_mul_sub_eew16_widen_d1[i*2+j][2*`HWORD_WIDTH-1:0] :
                                                                       vmac_mul_add_eew16_widen_d1[i*2+j][2*`HWORD_WIDTH-1:0];
    end
  end
end

always_comb begin
  casex({is_vmac_d1,mac_is_widen_d1,is_vsmul_d1,mac_is_widen_d1})
    4'b11?? : mac_rslt_eew16_d1 = vmac_rslt_eew16_widen_d1[`VLEN-1:0];  // MAC 拓宽
    4'b10?? : mac_rslt_eew16_d1 = vmac_rslt_eew16_no_widen_d1;          // MAC 普通
    4'b0?1? : mac_rslt_eew16_d1 = vsmul_rslt_eew16_d1;                  // VSMUL
    4'b0?01 : mac_rslt_eew16_d1 = mac_rslt_eew16_widen_d1[`VLEN-1:0];   // MUL 拓宽
    4'b0?00 : mac_rslt_eew16_d1 = mac_rslt_eew16_no_widen_d1;           // MUL 普通
    default : mac_rslt_eew16_d1 = 'b0;
  endcase
end

always_comb begin
  for(int i=0;i<`VLENH;i++) begin
    update_vxsat_eew16_d1[2*i +: 2] = {vsmul_sat_eew16_d1[i],1'b0}; 
  end
end

// EEW32：每个 32-bit 乘法由 16 个 8x8 部分积重组，完整乘积为 64-bit。
// part16/part32/part48 分别收集移位 16/32/48 位附近的交叉项，再统一符号扩展相加。
always@(*) begin
  for (i=0; i<`VLENW; i=i+1) begin //z
    // 32-bit 元素被拆成 4 个 byte：
    //   src2 = s20 + (s21<<8) + (s22<<16) + (s23<<24)
    //   src1 = s10 + (s11<<8) + (s12<<16) + (s13<<24)
    // mul8 输出索引规则来自上面的实例化：mac8_out[i*16 + y*4 + x] = s2x * s1y。
    // 因此 4x4 部分积矩阵为：
    //   y=0: [ 0]=s20*s10, [ 1]=s21*s10, [ 2]=s22*s10, [ 3]=s23*s10
    //   y=1: [ 4]=s20*s11, [ 5]=s21*s11, [ 6]=s22*s11, [ 7]=s23*s11
    //   y=2: [ 8]=s20*s12, [ 9]=s21*s12, [10]=s22*s12, [11]=s23*s12
    //   y=3: [12]=s20*s13, [13]=s21*s13, [14]=s22*s13, [15]=s23*s13
    //
    // 按权重 x+y 分组后，32x32 完整乘积为：
    //   << 0 : [0]（基础）
    //   << 8 : [1](part48低16位) + [4](part48低16位)
    //   <<16 : [2]（基础） + [5](part32低16位) + [8](part32低16位)
    //   <<24 : [3](part16) + [6](part48中16位) + [9](part48中16位) + [12](part16)
    //   <<32 : [7](part32高16位) + [10]（基础） + [13](part32高16位)
    //   <<40 : [11](part48高16位) + [14](part48高16位)
    //   <<48 : [15]（基础）
    //
    // 下面的 part16/part32/part48 是压缩后的加法树，不是按每个权重直接逐项展开。
    // 其中最高 byte 相关的有符号项需要符号扩展：
    //   src1 最高 byte 参与的 [12]/[13]/[14] 用 mac_src1_is_signed_d1 扩展；
    //   src2 最高 byte 参与的 [3]/[7]/[11] 用 mac_src2_is_signed_d1 扩展。
    // 对应 <<24 权重的两端交叉项：part16 = [12] + [3]。
    mac_rslt_part16_eew32_d1[i] = {{2{mac8_out_d1[i*16+12][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+12]} +
                                  {{2{mac8_out_d1[i*16+3 ][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+3 ]} ;    
    // part32 打包两个权重档：
    //   低 16 位：[5] + [8]，左移 16 后补到 <<16 权重；
    //   高 16 位：[13] + [7] 以及低半部进位，左移 16 后补到 <<32 权重。
    mac_rslt_part32_eew32_d1[i] = {{2{mac8_out_d1[i*16+13][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+13],mac8_out_d1[i*16+5]} +
                                  {{2{mac8_out_d1[i*16+7 ][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+7 ],mac8_out_d1[i*16+8]} ;
    // part48 打包三个权重档：
    //   低 16 位：[4] + [1]，左移 8 后补到 <<8 权重；
    //   中 16 位：[6] + [9] 以及低半部进位，左移 8 后补到 <<24 权重；
    //   高 16 位：[14] + [11] 以及中间进位，左移 8 后补到 <<40 权重。
    mac_rslt_part48_eew32_d1[i] = {{2{mac8_out_d1[i*16+14][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+14],mac8_out_d1[i*16+6],mac8_out_d1[i*16+4]} +
                                  {{2{mac8_out_d1[i*16+11][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+11],mac8_out_d1[i*16+9],mac8_out_d1[i*16+1]} ;

    // 主干直接放 [15]/[10]/[2]/[0]：
    //   [0]  覆盖 <<0；
    //   [2]  覆盖 <<16，剩余同权重的 [5]/[8] 已在 part32 低半部；
    //   [10] 覆盖 <<32，剩余同权重的 [7]/[13] 已在 part32 高半部；
    //   [15] 覆盖 <<48。
    // 这里必须是 [2] 而不是 [5]；[5] 已经在 part32 中，改成 [5] 会重复算 [5] 并漏掉 [2]。
    mac_rslt_full_eew32_d1[i] = 
      {mac8_out_d1[i*16+15],mac8_out_d1[i*16+10],mac8_out_d1[i*16+2],mac8_out_d1[i*16]} +
      {{22{mac_rslt_part16_eew32_d1[i][17]}},mac_rslt_part16_eew32_d1[i],24'b0} +
      {{14{mac_rslt_part32_eew32_d1[i][33]}},mac_rslt_part32_eew32_d1[i],16'b0} +
      {{6{mac_rslt_part48_eew32_d1[i][49]}},mac_rslt_part48_eew32_d1[i],8'b0} ;

    mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*i +: 2*`WORD_WIDTH] = mac_rslt_full_eew32_d1[i]; // 拓宽结果按 64-bit 元素写入总线
    mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*i +: `WORD_WIDTH]  = mac_keep_low_bits_d1 ?
                                                                  mac_rslt_full_eew32_d1[i][0           +: `WORD_WIDTH] : 
                                                                  mac_rslt_full_eew32_d1[i][`WORD_WIDTH +: `WORD_WIDTH] ; 
    // VSMUL 定点舍入：SEW=32 时右移量是 31，不是 32。
    case(mac_uop_xrm_d1)
      ROD: vsmul_round_incr_eew32_d1[i] = !mac_rslt_full_eew32_d1[i][31] && (|mac_rslt_full_eew32_d1[i][30:0]);
      RDN: vsmul_round_incr_eew32_d1[i] = 'b0; 
      RNE: begin 
           vsmul_round_incr_eew32_d1[i] = mac_rslt_full_eew32_d1[i][30] && 
                                          ((|mac_rslt_full_eew32_d1[i][29:0]) || mac_rslt_full_eew32_d1[i][31]);
      end
      // RNU：直接看被截掉的最高位。
      default: vsmul_round_incr_eew32_d1[i] = mac_rslt_full_eew32_d1[i][30];
    endcase

    // VSMUL 饱和检测：正溢出时钳位到 0x7fff_ffff。
    vsmul_sat_eew32_d1[i] = mac_rslt_full_eew32_d1[i][63:62] == 2'b01;
    vsmul_rslt_eew32_d1[`WORD_WIDTH*i +: `WORD_WIDTH] = vsmul_sat_eew32_d1[i] ? 32'h7fff_ffff :
                                                          // 右移 31 位后加舍入增量。
                                                          mac_rslt_full_eew32_d1[i][(`WORD_WIDTH-1)+:`WORD_WIDTH] + 
                                                          {31'b0,vsmul_round_incr_eew32_d1[i]};

    // VMAC 普通路径：32-bit addsrc 与 32-bit 乘法结果做加/减。
    vmac_mul_add_eew32_no_widen_d1[i] = {1'b0,mac_addsrc_d1[             `WORD_WIDTH*i +: `WORD_WIDTH]} + 
                                        {1'b0,mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*i +: `WORD_WIDTH]} ;  //33bit
    vmac_mul_sub_eew32_no_widen_d1[i] = {1'b0,mac_addsrc_d1[             `WORD_WIDTH*i +: `WORD_WIDTH]} - 
                                        {1'b0,mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*i +: `WORD_WIDTH]} ;
    vmac_rslt_eew32_no_widen_d1[32*i +:32] = mac_mul_reverse_d1 ? vmac_mul_sub_eew32_no_widen_d1[i][`WORD_WIDTH-1:0] :
                                                                  vmac_mul_add_eew32_no_widen_d1[i][`WORD_WIDTH-1:0] ;

    // VMAC 拓宽路径：64-bit addsrc_widen 与 64-bit 乘积累加/累减。
    vmac_mul_add_eew32_widen_d1[i] = {1'b0,mac_addsrc_widen_d1[    2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} + 
                                     {1'b0,mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} ; //65bit
    vmac_mul_sub_eew32_widen_d1[i] = {1'b0,mac_addsrc_widen_d1[    2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} - 
                                     {1'b0,mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} ;
    vmac_rslt_eew32_widen_d1[64*i +: 64] = mac_mul_reverse_d1 ? vmac_mul_sub_eew32_widen_d1[i][2*`WORD_WIDTH-1:0] :
                                                                vmac_mul_add_eew32_widen_d1[i][2*`WORD_WIDTH-1:0] ;
  end
end

always_comb begin
  casex({is_vmac_d1,mac_is_widen_d1,is_vsmul_d1,mac_is_widen_d1})
    4'b11?? : mac_rslt_eew32_d1 = vmac_rslt_eew32_widen_d1[`VLEN-1:0];  // MAC 拓宽
    4'b10?? : mac_rslt_eew32_d1 = vmac_rslt_eew32_no_widen_d1;          // MAC 普通
    4'b0?1? : mac_rslt_eew32_d1 = vsmul_rslt_eew32_d1;                  // VSMUL
    4'b0?01 : mac_rslt_eew32_d1 = mac_rslt_eew32_widen_d1[`VLEN-1:0];   // MUL 拓宽
    4'b0?00 : mac_rslt_eew32_d1 = mac_rslt_eew32_no_widen_d1;           // MUL 普通
    default : mac_rslt_eew32_d1 = 'b0;
  endcase
end

always_comb begin
  for(int i=0;i<`VLENW;i++) begin
    update_vxsat_eew32_d1[4*i +: 4] = {vsmul_sat_eew32_d1[i],3'b0}; 
  end
end

// 输出打包到 ROB：根据 EEW 选择结果总线；只有 VSMUL 需要回写 vsaturate 标志。
`ifdef TB_SUPPORT
  assign mac2rob_uop_data.uop_pc    = mac_uop_pc_d1;
`endif
  assign mac2rob_uop_valid          = rs2mac_uop_valid_d1;
  assign mac2rob_uop_data.rob_entry = mac_uop_rob_entry_d1;
  assign mac2rob_uop_data.w_valid   = rs2mac_uop_valid_d1;
  assign mac2rob_uop_data.vsaturate = is_vsmul_d1 ? update_vxsat : 'b0;
`ifdef ZVE32F_ON
  assign mac2rob_uop_data.fpexp     = 'b0;
`endif

always_comb begin
  case(mac_top_vs_eew_d1)
    EEW32: begin
      mac2rob_uop_data.w_data = mac_rslt_eew32_d1; 
      update_vxsat            = update_vxsat_eew32_d1;
    end
    EEW16: begin
      mac2rob_uop_data.w_data = mac_rslt_eew16_d1; 
      update_vxsat            = update_vxsat_eew16_d1;
    end
    default: begin  // EEW8
      mac2rob_uop_data.w_data = mac_rslt_eew8_d1; 
      update_vxsat            = update_vxsat_eew8_d1;
    end
  endcase
end


endmodule
