
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 功能说明：
// 1. `rvv_backend_alu_unit_shift` 是 ALU p0 阶段的移位/窄化移位/定点舍入移位执行单元。
// 2. 输入 `ALU_RS_t` 已经携带 vs1/vs2/rs1、EEW、vxrm、uop_index 和 ROB entry，本模块不再访问 VRF。
// 3. 支持 VSLL/VSRL/VSRA、VSSRL/VSSRA、VNSRL/VNSRA、VNCLIPU/VNCLIP 等整数移位类指令。
// 4. 本模块直接输出 `PU2ROB_t`，属于 `rvv_backend_alu_unit` 中可在 p0 直接写回 ROB 的路径之一。
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_alu_unit_shift` -> RVV 后端 EX/ALU p0 子单元。
// - 接口与数据流：
//   * 输入：`alu_uop_valid/alu_uop`，其中 `alu_uop` 已包含源操作数和控制字段。
//   * 处理：先按 funct3/funct6 判断是否属于 shift 单元，再准备移位源、移位量、移位模式，最后做逐元素 barrel shift。
//   * 输出：`result_valid/result`，写回数据在 `result.w_data`，饱和标志在 `result.vsaturate`。
// - 调用关系：上层 rvv_backend_alu_unit；无下层实例。
// - 端口摘要：输入 alu_uop_valid, alu_uop；输出 result_valid, result。
// - 指令分组：
//   * VSLL：逻辑左移。
//   * VSRL/VSRA：逻辑右移/算术右移。
//   * VSSRL/VSSRA：带 `vxrm` 舍入的右移。
//   * VNSRL/VNSRA：窄化右移，宽元素结果写入较窄目的元素位置。
//   * VNCLIPU/VNCLIP：窄化、舍入并饱和裁剪，溢出时写最大/最小值并置 `vsaturate`。
// - define/参数阅读重点：
//   * `BYTE_WIDTH`：8。
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `FUNCT3_WIDTH`：3。
//   * `HWORD_WIDTH`：16。
//   * `ROB_DEPTH_WIDTH`：$clog2(`ROB_DEPTH)=3。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VLENH`：`VLEN/16；依赖 VLEN。
//   * `VLENW`：`VLEN/32；依赖 VLEN。
//   * `WORD_WIDTH`：32。
//   * `XLEN`：32；标量整数宽度。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
// - 阅读建议：按 `result_valid` 支持指令 -> 源数据准备 -> `shift_mode` -> barrel_shifter -> rounding/saturation -> result 打包的顺序阅读。
// 详细中文注释（自动梳理）END

// ALU_RS_t alu_uop
//     ↓
// 识别是否是 shift 类指令
//     ↓
// 根据 OPIVV / OPIVX / OPIVI 准备移位源和移位量
//     ↓
// 根据 VSLL / VSRL / VSRA 选择左移、逻辑右移、算术右移
//     ↓
// barrel_shifter 并行逐元素移位
//     ↓
// 根据 vxrm 做定点舍入
//     ↓
// 对 VNCLIPU / VNCLIP 做饱和裁剪和 vsaturate 标记
//     ↓
// 打包成 PU2ROB_t 写 ROB
module rvv_backend_alu_unit_shift
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
  localparam  SHIFT_SLL   = 2'b00;
  localparam  SHIFT_SRL   = 2'b01;
  localparam  SHIFT_SRA   = 2'b10;
//
// 接口信号
//
  // ALU RS 输入。该子单元只产生组合结果，是否真正 pop 由上层 `rvv_backend_alu_unit` 根据 result_ready 决定。
  input   logic                   alu_uop_valid;
  input   ALU_RS_t                alu_uop;

  // 送往 ROB 的 p0 结果。
  output  logic                   result_valid;
  output  PU2ROB_t                result;

//
// 内部信号
//

  // 从 ALU_RS_t 拆出的字段，便于后续组合逻辑使用。
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  FUNCT6_u                        uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  RVVXRM                          vxrm;       
  logic   [`VLEN-1:0]             vs1_data;           
  logic   [`VLEN-1:0]             vs2_data;	        
  EEW_e                           vs2_eew;
  logic   [`XLEN-1:0] 	          rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0] uop_index;          

  // 执行中间量：
  // src2_data* 是待移位数据，shift_amount* 是逐元素移位量。
  // product* 是移位后的主结果，round_bits* 是右移丢弃位，用于 VSSRL/VSSRA/VNCLIP* 的舍入。
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]           src2_data8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]          src2_data16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             src2_data32;
  logic   [`VLENB/2-1:0][$clog2(`BYTE_WIDTH)-1:0]   shift_amount8;
  logic   [`VLENH/2-1:0][$clog2(`HWORD_WIDTH)-1:0]  shift_amount16;
  logic   [`VLENW-1:0][$clog2(`WORD_WIDTH)-1:0]     shift_amount32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]           product8_tmp;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]          product16_tmp;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             product32_tmp;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]             product8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]            product16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             product32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]           round_bits8_tmp;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]          round_bits16_tmp;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             round_bits32_tmp;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]             round_bits8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]            round_bits16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             round_bits32;
  logic   [`VLENB-1:0]                              round_increment8;
  logic   [`VLENH-1:0]                              round_increment16;
  logic   [`VLENW-1:0]                              round_increment32;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]             round8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]            round16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             round32;
  logic   [`VLENH-1:0]                              cout16;
  logic   [`VLENW-1:0]                              cout32;
  logic   [`VLENB-1:0]                              upoverflow;
  logic   [`VLENB-1:0]                              underoverflow;
  logic   [`VLEN-1:0]                               result_data; 
  logic   [1:0]                                     shift_mode;
  
  // generate 循环变量。
  genvar                                            j;

//
// 准备计算源数据
//
  // 拆分 ALU_RS_t 结构体。
  // OPIVV 的移位量来自 vs1_data；OPIVX/OPIVI 的移位量来自 rs1_data。
  assign  rob_entry      = alu_uop.rob_entry;
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vxrm           = alu_uop.vxrm;
  assign  vs1_data       = alu_uop.vs1_data;
  assign  rs1_data       = alu_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data       = alu_uop.vs2_data;
  assign  vs2_eew        = alu_uop.vs2_eew;
  assign  uop_index      = alu_uop.uop_index;
  
//
// 指令识别与源数据准备
//
  // 生成本子单元的 result_valid。
  // 只有当前 uop 的 funct3/funct6 落在 shift 单元覆盖范围时才置位。
  always_comb begin
    // 默认当前 uop 不属于 shift 单元。
    result_valid   = 'b0;

    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VSLL,
          VSRL,
          VSRA,
          VSSRL,
          VSSRA,
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end
    endcase
  end

  // 准备待移位数据和移位量。
  // 同宽移位时按 EEW=8/16/32 直接切分；窄化/裁剪时需要把较宽源扩展到 16/32 位通路。
  always_comb begin
    // 默认清零，避免未覆盖分支产生锁存。
    src2_data8     = 'b0;
    src2_data16    = 'b0;
    src2_data32    = 'b0;
    shift_amount8  = 'b0;
    shift_amount16 = 'b0;
    shift_amount32 = 'b0;

    case(uop_funct3) 
      OPIVV: begin
        case(uop_funct6.ari_funct6)
          VSLL,
          VSRL,
          VSSRL: begin  //窄化高半用零扩展
            // OPIVV 逻辑左/右移、舍入逻辑右移：移位量逐元素来自 vs1_data。
            // 对窄化相关高半段预先做零扩展，方便共用 16/32 位 barrel shifter。
            case(vs2_eew)
              EEW8: begin  //一个模块里同时准备 8/16/32 三种通路，后面再按指令选择结果。
                for(int i=0;i<`VLENB/2;i=i+1) begin  //前半部分按 8-bit 元素走 src2_data8
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)];  //vs1_data[i] 的低 log2(EEW) 位
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin  //中间一段把 8-bit 源零扩展到 16-bit 通路。
                  src2_data16[   i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin  //最后一段把 8-bit 源零扩展到 32-bit 通路。
                  src2_data32[   i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0, vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin  //
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = vs1_data[i*`WORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase
          end

          VSRA,
          VSSRA: begin
            // 算术右移需要对源数据按符号位扩展到更宽通路，右移时保留符号语义。
             case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin  //高位补充符号位
                  src2_data16[   i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0,vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0,vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = vs1_data[i*`WORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase         
          end

          VNSRL,
          VNCLIPU: begin
            // 窄化逻辑右移/无符号裁剪：源为 16/32 位，结果写回较窄元素。
            // `uop_index[0]` 选择当前 uop 负责目的寄存器低半还是高半。
            case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  if (uop_index[0]==1'b0)  //寄存器分半
                    shift_amount16[i] = vs1_data[i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                  else
                    shift_amount16[i] = vs1_data[`VLEN/2+i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  if (uop_index[0]==1'b0)
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)]};
                  else
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[`VLEN/2+i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH  +: `WORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount32[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                  else
                    shift_amount32[i] = vs1_data[`VLEN/2+i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase
          end

          VNSRA,
          VNCLIP: begin
            // 窄化算术右移/有符号裁剪：源数据按符号位扩展，再结合 vxrm 舍入和饱和判断。
             case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount16[i] = vs1_data[i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                  else
                    shift_amount16[i] = vs1_data[`VLEN/2+i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin  //有符号
                  src2_data32[i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  if (uop_index[0]==1'b0)
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[i*`BYTE_WIDTH +: $clog2(`HWORD_WIDTH)]};
                  else
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[`VLEN/2+i*`BYTE_WIDTH +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH  +: `WORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount32[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                  else
                    shift_amount32[i] = vs1_data[`VLEN/2+i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase  
          end
        endcase
      end

      OPIVX,
      OPIVI: begin  //OPIVX / OPIVI：所有元素使用同一个 rs1_data
        case(uop_funct6.ari_funct6)
          VSLL,
          VSRL,
          VSSRL: begin
            // OPIVX/OPIVI：所有元素使用同一个 rs1/立即数移位量。
             case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = rs1_data[0             +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
                  src2_data16[   i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,rs1_data[0             +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0, rs1_data[0             +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0, rs1_data[0              +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0             +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase       
          end

          VSRA,
          VSSRA: begin
            // 标量移位量的算术右移，源数据同样需要符号扩展。
            case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = rs1_data[0             +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
                  src2_data16[   i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,rs1_data[0 +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0,rs1_data[0 +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0,rs1_data[0 +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0 +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase          
          end

          VNSRL,
          VNCLIPU: begin
            // 标量移位量的窄化逻辑右移/无符号裁剪。
            case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0, rs1_data[0              +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0             +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase  
          end

          VNSRA,
          VNCLIP: begin
            // 标量移位量的窄化算术右移/有符号裁剪。
            case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0,rs1_data[0 +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0 +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase 
          end
        endcase
      end
    endcase
  end

  // 选择 barrel shifter 模式。
  // VNS* 和 VNCLIP* 本质也是右移，只是后续结果打包/饱和处理不同。
  // | 模式          | 含义   | 对应指令                       |
  // | ----------- | ---- | -------------------------- |
  // | `SHIFT_SLL` | 逻辑左移 | `VSLL`                     |
  // | `SHIFT_SRL` | 逻辑右移 | `VSRL/VSSRL/VNSRL/VNCLIPU` |
  // | `SHIFT_SRA` | 算术右移 | `VSRA/VSSRA/VNSRA/VNCLIP`  |
  always_comb begin
    // 默认左移。
    shift_mode = SHIFT_SLL;

    // 根据指令选择左移、逻辑右移或算术右移。
    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)    
          VSLL: begin
            shift_mode = SHIFT_SLL;
          end
          VSRL,
          VNSRL,
          VSSRL,
          VNCLIPU: begin
            shift_mode = SHIFT_SRL;
          end
          VSRA,
          VNSRA,
          VSSRA,
          VNCLIP: begin
            shift_mode = SHIFT_SRA;
          end
        endcase
      end
    endcase
  end

//
// 执行移位
//
  // 三组 barrel shifter 分别覆盖 8/16/32 位元素。
  // 输入拼接 `{src, zero}`，输出高半作为移位结果 product，低半作为被移出的 round_bits。
  // 资源复用：
  // 对于8位元素操作， VLENB/2 个shifter8、VLENH/2个shifter16、VLENW个shifter32
  // 对于16位元素操作，VLENH/2个shifter16、VLENW个shifter32
  // 对于32位元素操作，VLENW个shifter32
  // 未使用的单元，由于输入为0，不会造成逻辑翻转

  generate
    for (j=0;j<`VLENB/2;j=j+1) begin: EXE_PROD8
      barrel_shifter #(
        .DATA_WIDTH   (`BYTE_WIDTH*2)
      ) shifter8 (
        .din          ({src2_data8[j],`BYTE_WIDTH'b0}),            
        .shift_amount ({1'b0,shift_amount8[j]}),
        .shift_mode   (shift_mode),     
        .dout         ({product8_tmp[j], round_bits8_tmp[j]})  //{BYTE_WIDTH, BYTE_WIDTH}
      );
    end
  
    for (j=0;j<`VLENH/2;j=j+1) begin: EXE_PROD16
      barrel_shifter #(
        .DATA_WIDTH   (`HWORD_WIDTH*2)
      ) shifter16 (
        .din          ({src2_data16[j],`HWORD_WIDTH'b0}),            
        .shift_amount ({1'b0,shift_amount16[j]}),
        .shift_mode   (shift_mode),     
        .dout         ({product16_tmp[j], round_bits16_tmp[j]}) 
      );
    end

    for (j=0;j<`VLENW;j=j+1) begin: EXE_PROD32
      barrel_shifter #(
        .DATA_WIDTH   (`WORD_WIDTH*2)
      ) shifter32 (
        .din          ({src2_data32[j],`WORD_WIDTH'b0}),            
        .shift_amount ({1'b0,shift_amount32[j]}),
        .shift_mode   (shift_mode),     
        .dout         ({product32_tmp[j], round_bits32_tmp[j]}) 
      );
    end
  endgenerate 
  
  //结果拼接
  always_comb begin
    product8    = 'b0;
    round_bits8 = 'b0;

    for(int i=0;i<`VLENB/2;i=i+1) begin
      product8[i]    = product8_tmp[i];
      round_bits8[i] = round_bits8_tmp[i];
    end
    for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
      product8[i]    = product16_tmp[   i-`VLENB/2][0           +: `BYTE_WIDTH];
      round_bits8[i] = round_bits16_tmp[i-`VLENB/2][`BYTE_WIDTH +: `BYTE_WIDTH];
    end         
    for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
      product8[i]    = product32_tmp[   i-`VLENB*3/4][0             +: `BYTE_WIDTH];
      round_bits8[i] = round_bits32_tmp[i-`VLENB*3/4][3*`BYTE_WIDTH +: `BYTE_WIDTH];
    end
  end
 
  always_comb begin
    product16    = 'b0;
    round_bits16 = 'b0;

    for(int i=0;i<`VLENH/2;i=i+1) begin
      product16[i]    = product16_tmp[i];
      round_bits16[i] = round_bits16_tmp[i];
    end
    for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
      product16[i]    = product32_tmp[   i-`VLENH/2][0            +: `HWORD_WIDTH];
      round_bits16[i] = round_bits32_tmp[i-`VLENH/2][`HWORD_WIDTH +: `HWORD_WIDTH];
    end   
  end

  always_comb begin
    product32    = 'b0;
    round_bits32 = 'b0;

    for(int i=0;i<`VLENW;i=i+1) begin
      product32[i]    = product32_tmp[i];
      round_bits32[i] = round_bits32_tmp[i];
    end
  end

  // 根据 RVV 定点舍入模式 vxrm 生成舍入增量。
  // RNU: round-to-nearest-up；RNE: round-to-nearest-even；RDN: round-down；ROD: round-to-odd。
  generate
    for (j=0;j<`VLENB;j++) begin: INCREMENT8
      always_comb begin
        round_increment8[j] = 'b0;
        
        case(vxrm)
          RNU: begin
            round_increment8[j] = round_bits8[j][`BYTE_WIDTH-1];
          end
          RNE: begin
            round_increment8[j] = round_bits8[j][`BYTE_WIDTH-1] & ((round_bits8[j][`BYTE_WIDTH-2:0]!='b0) | product8[j][0]);
          end
          RDN: begin
            round_increment8[j] = 'b0;
          end
          ROD: begin
            round_increment8[j] = (!product8[j][0]) & (round_bits8[j]!='b0);
          end
        endcase
      end
    end
  endgenerate

  generate
    for (j=0;j<`VLENH;j++) begin: INCREMENT16
      always_comb begin
        round_increment16[j] = 'b0;
        
        case(vxrm)
          RNU: begin
            round_increment16[j] = round_bits16[j][`HWORD_WIDTH-1];
          end
          RNE: begin
            round_increment16[j] = round_bits16[j][`HWORD_WIDTH-1] & ((round_bits16[j][`HWORD_WIDTH-2:0]!='b0) | product16[j][0]);
          end
          RDN: begin
            round_increment16[j] = 'b0;
          end
          ROD: begin
            round_increment16[j] = (!product16[j][0]) & (round_bits16[j]!='b0);
          end
        endcase
      end
    end
  endgenerate

  generate
    for (j=0;j<`VLENW;j++) begin: INCREMENT32
      always_comb begin
        round_increment32[j] = 'b0;
        
        case(vxrm)
          RNU: begin
            round_increment32[j] = round_bits32[j][`WORD_WIDTH-1];
          end
          RNE: begin
            round_increment32[j] = round_bits32[j][`WORD_WIDTH-1] & ((round_bits32[j][`WORD_WIDTH-2:0]!='b0) | product32[j][0]);
          end
          RDN: begin
            round_increment32[j] = 'b0;
          end
          ROD: begin
            round_increment32[j] = (!product32[j][0]) & (round_bits32[j]!='b0);
          end
        endcase
      end
    end
  endgenerate

  // 生成带舍入的右移结果。左移不需要舍入。
  always_comb begin
    for(int i=0;i<`VLENB;i++) begin: ROUND8
      if (shift_mode == SHIFT_SLL)
        round8[i] = 'b0;
      else
        round8[i] = round_increment8[i] ? product8[i]+'b1 : product8[i]; 
    end
  end

  always_comb begin
    for(int i=0;i<`VLENH;i++) begin: ROUND16
      if (shift_mode == SHIFT_SRL)  //逻辑右移
        {cout16[i], round16[i]} = round_increment16[i] ? {1'b0, product16[i]}+'b1 : {1'b0, product16[i]}; 
      else if (shift_mode == SHIFT_SRA)  //算术右移
        {cout16[i], round16[i]} = round_increment16[i] ? {product16[i][`HWORD_WIDTH-1], product16[i]}+'b1 : {product16[i][`HWORD_WIDTH-1], product16[i]}; 
      else begin
        cout16[i]  = 'b0; 
        round16[i] = 'b0;
      end
    end
  end

  always_comb begin
    for(int i=0;i<`VLENW;i++) begin: ROUND32
      if (shift_mode == SHIFT_SRL)
        {cout32[i], round32[i]} = round_increment32[i] ? {1'b0, product32[i]}+'b1 : {1'b0, product32[i]}; 
      else if (shift_mode == SHIFT_SRA)
        {cout32[i], round32[i]} = round_increment32[i] ? {product32[i][`WORD_WIDTH-1], product32[i]}+'b1 : {product32[i][`WORD_WIDTH-1], product32[i]}; 
      else begin
        cout32[i]  = 'b0; 
        round32[i] = 'b0;
      end
    end
  end

  // VNCLIPU/VNCLIP 溢出检查。
  // upoverflow 表示超过正向可表示范围；underoverflow 表示有符号负向下溢。
  // `uop_index[0]` 决定当前窄化 uop 写低半还是高半目的元素。
  generate 
    for (j=0;j<`VLENW/2;j++) begin: GET_OVERFLOW
      always_comb begin
        // initial
        upoverflow[   4*j +: 4] = 'b0;
        underoverflow[4*j +: 4] = 'b0;
        upoverflow[   4*(j+`VLENW/2) +: 4] = 'b0;
        underoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
          
        case(vs2_eew)
          EEW16: begin
            case(shift_mode)
              SHIFT_SRL: begin
              // VNCLIPU 无符号溢出检查：高位非零说明裁剪后需要饱和到全 1。
                if(uop_index[0]==1'b0) begin  //低半部分
                  upoverflow[4*j +: 4] = {
                    ({cout16[4*j+3], round16[4*j+3][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),  //高位非0，溢出
                    ({cout16[4*j+2], round16[4*j+2][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+1], round16[4*j+1][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j  ], round16[4*j  ][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0)};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;  //高半部分还没计算
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;  

                  upoverflow[4*(j+`VLENW/2) +: 4] = {
                    ({cout16[4*j+3], round16[4*j+3][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+2], round16[4*j+2][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+1], round16[4*j+1][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j  ], round16[4*j  ][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0)};
                end
              end
              SHIFT_SRA: begin
              // VNCLIP 有符号溢出检查：根据符号扩展位判断正向溢出或负向下溢。
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    (cout16[4*j+3]=='b0)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+2]=='b0)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+1]=='b0)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j  ]=='b0)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0)};

                  underoverflow[4*j +: 4] = {
                    (cout16[4*j+3]=='b1)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+2]=='b1)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+1]=='b1)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j  ]=='b1)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff)};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                  underoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;
                  underoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout16[4*j+3]=='b0)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+2]=='b0)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+1]=='b0)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j  ]=='b0)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0)};

                  underoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout16[4*j+3]=='b1)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+2]=='b1)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+1]=='b1)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j  ]=='b1)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff)};
                end
              end
            endcase
          end
          EEW32: begin
            case(shift_mode)
              SHIFT_SRL: begin
              // VNCLIPU 32->16 的无符号溢出检查。
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    ({cout32[2*j+1], round32[2*j+1][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0,
                    ({cout32[2*j  ], round32[2*j  ][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLENW/2) +: 4] = {
                    ({cout32[2*j+1], round32[2*j+1][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0,
                    ({cout32[2*j  ], round32[2*j  ][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0};
                end
              end
              SHIFT_SRA: begin
              // VNCLIP 32->16 的有符号溢出检查。
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    (cout32[2*j+1]=='b0)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0,
                    (cout32[2*j  ]=='b0)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0};

                  underoverflow[4*j +: 4] = {  //1 3有效
                    (cout32[2*j+1]=='b1)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0,
                    (cout32[2*j  ]=='b1)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                  underoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;
                  underoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout32[2*j+1]=='b0)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0,
                    (cout32[2*j  ]=='b0)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0};

                  underoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout32[2*j+1]=='b1)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0,
                    (cout32[2*j  ]=='b1)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0};
                end
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

  // 结果打包：
  // - 同宽 shift 直接按 EEW 拼回 VLEN。
  // - VNS* 只写当前 uop 对应的半个目的寄存器区域。
  // - VSS* 使用 round*。
  // - VNCLIP* 结合 round* 与 overflow 标志生成饱和值。
  always_comb begin
    // 默认清零。
    result_data = 'b0;
 
    for(int i=0;i<`VLENW;i++) begin
      // 按指令类型写入当前 32bit 分组对应的结果数据。
      case(uop_funct3) 
        OPIVV,
        OPIVX,
        OPIVI: begin
          case(uop_funct6.ari_funct6)
            VSLL,
            VSRL,
            VSRA: begin  //同宽移位
              case(vs2_eew)
                EEW8: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {product8[4*i+3],product8[4*i+2],product8[4*i+1],product8[4*i]};
                end
                EEW16: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*i+1],product16[2*i]};
                end
                EEW32: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = product32[i];
                end
              endcase
            end
  
            VNSRL,
            VNSRA: begin  //窄化右移，只写一般目的寄存器
              case(vs2_eew)
                EEW16: begin  //16-bit 源 → 8-bit 目的, 两个结果拼接
                  if (uop_index[0]==1'b0)
                    result_data[i*`HWORD_WIDTH         +: `HWORD_WIDTH] = {product16[2*i+1][`BYTE_WIDTH-1:0],product16[2*i][`BYTE_WIDTH-1:0]};
                  else
                    result_data[`VLEN/2+i*`HWORD_WIDTH +: `HWORD_WIDTH] = {product16[2*i+1][`BYTE_WIDTH-1:0],product16[2*i][`BYTE_WIDTH-1:0]};
                end
                EEW32: begin  //32-bit 源 → 16-bit 目的
                  if (uop_index[0]==1'b0)
                    result_data[i*`HWORD_WIDTH         +: `HWORD_WIDTH] = product32[i][`HWORD_WIDTH-1:0];
                  else
                    result_data[`VLEN/2+i*`HWORD_WIDTH +: `HWORD_WIDTH] = product32[i][`HWORD_WIDTH-1:0];
                end
              endcase
            end

            VSSRL,
            VSSRA: begin  //带舍入结果
              case(vs2_eew)
                EEW8: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {round8[4*i+3],round8[4*i+2],round8[4*i+1],round8[4*i]};
                end
                EEW16: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {round16[2*i+1],round16[2*i]};
                end
                EEW32: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = round32[i];
                end
              endcase
            end

            VNCLIPU: begin  //无符号裁剪饱和, 取低位，高半和低半输出结果相同
              case(vs2_eew)
                EEW16: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+3][`BYTE_WIDTH-1 : 0];
                  end
                  else begin  
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+3][`BYTE_WIDTH-1 : 0];
                  end
                end
                EEW32: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i+1][`HWORD_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)+1][`HWORD_WIDTH-1 : 0];
                  end
                end
              endcase
            end

            VNCLIP: begin
              case(vs2_eew)
                EEW16: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+3][`BYTE_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+3][`BYTE_WIDTH-1 : 0];
                  end
                end
                EEW32: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i+1][`HWORD_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)+1][`HWORD_WIDTH-1 : 0];
                  end
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

//
// 提交结果到 ROB
//
  // 默认写回 result_data；只有 VNCLIPU/VNCLIP 会根据溢出标志设置逐 byte 的 vsaturate。
  always_comb begin
    // 默认结果字段。
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
          VNCLIPU: begin
            result.vsaturate = upoverflow;
          end
          VNCLIP: begin
            result.vsaturate = underoverflow|upoverflow;
          end
        endcase
      end
    endcase
  end

endmodule
