// 功能说明：
// 1. PMT permutation 执行单元，负责 vslideup/vslide1up、vslidedown/vslide1down、
//    vrgather/vrgatherei16 和 vcompress。
// 2. 本单元按 byte 建立 PMT_INFO_t 映射表：每个输出 byte 要么来自 rs1 标量，
//    要么来自某个向量寄存器 byte，要么因为越界写 0。
// 3. t0 阶段计算每个 byte 的来源 index/offset/valid；
//    t1 阶段按同一个 VRF 读地址逐步收集数据；
//    t2 阶段保存收集完成的 byte，全部 byte valid 后写回 ROB。
// 4. vcompress 会迭代扫描 vs1 mask 中的置位 bit，compress_cnt_q 记录当前输出 byte 位置；
//    当 mask 已无有效元素或到达 vl 后，才认为本 uop 可以 ready。
// 5. pmt_go 用 rob_rptr 限制 first uop：第一拍必须等到 ROB 退役指针指向本 rob_entry，
//    防止需要顺序语义的 permutation 过早读取/覆盖目的寄存器。

// 整体执行流程总结
// 非 compress，例如 vrgather
// 1. pmt_uop_valid 输入。
// 2. pmt_go 检查是否允许启动。
// 3. t0 为每个输出 byte 计算：
//    index / offset / zero_valid / rs_valid / vs_valid。
// 4. t0 info 通过 handshake_ff 进入 t1。
// 5. t1 找第一个未收集 byte 的 index，驱动 rd_index_pmt2vrf。
// 6. VRF 返回整条 VLEN 数据。
// 7. 所有需要该 index 的 byte 同拍写入 t2 data slots。
// 8. 重复步骤 5~7，直到所有 byte valid。
// 9. pmt_res_valid 拉高。
// 10. pmt_res_ready 后，data_clear 清空数据槽。

// compress
// 1. pmt_uop_valid 输入。
// 2. compress_vs1 取当前 mask。
// 3. compress_vmsof 找最低 set bit。
// 4. compress_vfirst 得到源元素 index。
// 5. compress_cnt_q 指示当前输出位置。
// 6. 本轮只使能当前输出元素对应的 byte。
// 7. 读取 vs2 对应源 byte，写到 compress_cnt_q 位置。
// 8. 清掉当前 mask bit，compress_cnt_q 前进一个元素。
// 9. 重复，直到 mask 没有有效元素或超过 vl。
// 10. compress_cnt_d 回到 0 后，pmt_uop_ready 拉高。
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif
module rvv_backend_pmtrdt_unit_permutation
(
  clk,
  rst_n,

  pmt_uop_valid,
  pmt_uop,
  pmt_uop_ready,

  pmt_res_valid,
  pmt_res,
  pmt_res_ready,

  rd_index_pmt2vrf,
  rd_data_vrf2pmt,

  rob_rptr,
  trap_flush_rvv
);

// ---端口定义--------------------------------------------------------
// 全局时钟/复位。
  input logic       clk;
  input logic       rst_n;

// 来自 PMTRDT unit 分流后的 permutation uop。
  input             pmt_uop_valid;
  input PMT_RDT_RS_t pmt_uop;
  output logic      pmt_uop_ready;

// 输出到 PMTRDT unit 的 ROB 写回结果。
  output logic      pmt_res_valid;
  output PU2ROB_t   pmt_res;
  input             pmt_res_ready;

// 额外 VRF 读端口：每拍选择一个 index，返回整条 VLEN 数据，再按 offset 取 byte。
  output logic [`REGFILE_INDEX_WIDTH-1:0] rd_index_pmt2vrf;
  input  logic [`VLENB-1:0][`BYTE_WIDTH-1:0] rd_data_vrf2pmt;

// 当前 ROB 退役指针。
  input  logic [`ROB_DEPTH_WIDTH-1:0]     rob_rptr;
// RVV trap/flush 清空内部握手寄存器。
  input             trap_flush_rvv;

// ---参数定义--------------------------------------------------------
// VLENB_WIDTH 用于在一个向量寄存器内部寻址 byte offset。
  localparam VLENB_WIDTH = $clog2(`VLENB);

// ---内部信号--------------------------------------------------------
// pmt_ctrl_* 保存 uop 级控制；pmt_info_* 是每个输出 byte 的来源描述；pmt_data_* 是实际数据。
  PMT_CTRL_t                pmt_ctrl_t0, pmt_ctrl_t1, pmt_ctrl_t2;
  PMT_INFO_t  [`VLENB-1:0]  pmt_info_t0, pmt_info_t1;
  logic [`VLENB-1:0]        pmt_info_valid;
  logic                     pmt_info_ready;
  PMT_DATA_t  [`VLENB-1:0]  pmt_data_t1, pmt_data_t2;
  logic       [`VLENB-1:0]  pmt_t0_valid, pmt_t1_valid, pmt_t2_valid;
  logic       [`VLENB-1:0]  pmt_t0_ready, pmt_t1_ready, pmt_t2_ready;
  logic                     pmt_go;

  PMT_INFO_t  [`VLENB-1:0]  slideup_info_t0;
  PMT_INFO_t  [`VLENB-1:0]  slidedown_info_t0;
  PMT_INFO_t  [`VLENB-1:0]  rgather_info_t0;
  PMT_INFO_t  [`VLENB-1:0]  compress_info_t0;

  logic [`VLENB-1:0][`XLEN+1:0] slideup_offset;
  logic [`VLENB-1:0]            slideup_overflow;
  logic [`VLENB-1:0]            slideup_scalar_valid;
  logic [`VLENB-1:0][`XLEN+2:0] slidedown_offset;
  logic [`VLENB-1:0]            slidedown_overflow;
  logic [`VLENB-1:0]            slidedown_scalar_valid;
  logic [`VLENB-1:0][`XLEN-1:0] rgather_vs1;
  logic [2*`VLEN-1:0]           double_vs1_data;
  logic [`VLENB-1:0][`XLEN+2:0] rgather_offset;
  logic [`VLENB-1:0]            rgather_overflow;
  logic [`VLEN-1:0]             compress_vs1;
  logic [`VLEN-1:0]             compress_vs1_d, compress_vs1_q;
  logic [`VLEN-1:0]             compress_vmsof;
  logic [`VL_WIDTH-1:0]         compress_vfirst;
  logic                         compress_overflow;
  logic [`VLENB-1:0][`VSTART_WIDTH-1:0]   compress_offset;
  logic [`VLENB-1:0]            compress_info_enable;
  logic [VLENB_WIDTH-1:0]       compress_cnt_d, compress_cnt_q;
  logic                         compress_cnt_en;

  logic [`VSTART_WIDTH-1:0]     last_element_index;

  logic [`VLENB-1:0]            data_valid;
  logic [`VLENB-1:0]            data_valid_zsof; //zero set-only first
  logic [VLENB_WIDTH-1:0]       data_valid_zfirst;
  logic [`VLENB-1:0]            data_write_enable;
  logic                         data_clear; // clear data slots when all data are ready.

  genvar i;

// ---主逻辑----------------------------------------------------------
  // t0：按指令类型生成每个输出 byte 的来源信息。
  generate
    always_comb begin
    `ifdef ZVE32F_ON
      if (pmt_uop.first_uop_valid & (pmt_uop.uop_funct3==OPMVX || pmt_uop.uop_funct3==OPFVF)) // 仅 vslide1up/vfslide1up 需要在低元素处插入标量。
    `else
      if (pmt_uop.first_uop_valid & (pmt_uop.uop_funct3==OPMVX)) // 仅 vslide1up 需要在低元素处插入标量。
    `endif
        case (pmt_uop.vs2_eew)
          EEW32:  slideup_scalar_valid = {{(`VLENB-4){1'h0}}, 4'hF};
          EEW16:  slideup_scalar_valid = {{(`VLENB-2){1'h0}}, 2'h3};
          default: slideup_scalar_valid = {{(`VLENB-1){1'h0}}, 1'h1}; // EEW8
        endcase
      else
        slideup_scalar_valid = '0;
    end
    for (i=0; i<`VLENB; i++) begin: gen_slideup_info_t0 
      always_comb begin
      `ifdef ZVE32F_ON
        if (pmt_uop.uop_funct3 == OPMVX || pmt_uop.uop_funct3 == OPFVF) begin
      `else
        if (pmt_uop.uop_funct3 == OPMVX) begin
      `endif
          case (pmt_uop.vs2_eew)  //vslide1up
            // 当前全局 byte 位置 = VLENB * uop_index + i
            // slide1up 源 byte = 当前全局 byte 位置 - 1 个元素宽度
            EEW32: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({{(`XLEN+1){1'b0}}, 1'b1} << 2) + i;
            EEW16: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({{(`XLEN+1){1'b0}}, 1'b1} << 1) + i;
            default: //EEW8
                   slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({{(`XLEN+1){1'b0}}, 1'b1}) + i;
          endcase
        end else begin  //vslideup
          case (pmt_uop.vs2_eew)
            EEW32: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({2'h0, pmt_uop.rs1_data} << 2)  + i;
            EEW16: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({2'h0, pmt_uop.rs1_data} << 1)  + i;
            default: //EEW8
                   slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({2'h0, pmt_uop.rs1_data})  + i;
          endcase
        end
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
        // 1. 高位非零：说明 offset 负数或超过可表示范围
        // 2. offset >= vlmax * 4：说明超过源向量有效范围
          EEW32: slideup_overflow[i] = (|slideup_offset[i][`XLEN+1:`VL_WIDTH+2]) | (slideup_offset[i][`VL_WIDTH+1:0] >= ({2'h0, pmt_uop.vlmax} << 2));
          // 2. offset >= vlmax * 2：说明超过源向量有效范围
          EEW16: slideup_overflow[i] = (|slideup_offset[i][`XLEN+1:`VL_WIDTH+1]) | (slideup_offset[i][`VL_WIDTH:0] >= ({1'b0, pmt_uop.vlmax} << 1));
          // 2. offset >= vlmax * 1：说明超过源向量有效范围
          default: slideup_overflow[i] = (|slideup_offset[i][`XLEN+1:`VL_WIDTH]) | (slideup_offset[i][`VL_WIDTH-1:0] >= pmt_uop.vlmax); //EEW8
        endcase
      end
      always_comb begin
        // slideup：目标 byte 的源地址 = 当前全局 byte 位置 - slide 距离；越界时回读目的寄存器旧值。
        slideup_info_t0[i].zero_valid = '0;  //回读旧vd
        slideup_info_t0[i].rs_valid = slideup_scalar_valid[i];  //插入标量值
        // 如果越界：读 dst_index，也就是回读旧 vd
        // 如果不越界：读 vs2_index + 跨寄存器偏移
        slideup_info_t0[i].index = slideup_overflow[i] ? pmt_uop.dst_index : pmt_uop.vs2_index + slideup_offset[i][VLENB_WIDTH+:3];
        slideup_info_t0[i].offset = slideup_overflow[i] ? i[0+:VLENB_WIDTH] : slideup_offset[i][0+:VLENB_WIDTH];
        //如果不是 scalar byte，并且当前指令是 slideup / slide1up，则需要从 VRF 取 byte。
        //注意这里 VSLIDEUP_RGATHEREI16 复用了编码名，后面根据 funct3 区分 slideup 和 rgatherei16。
        slideup_info_t0[i].vs_valid = ~slideup_info_t0[i].rs_valid & ((pmt_uop.uop_funct6 == VSLIDEUP_RGATHEREI16) | (pmt_uop.uop_funct6 == VSLIDE1UP));
      end
    end

    assign last_element_index = pmt_uop.vl - 'h1;
    always_comb begin
    `ifdef ZVE32F_ON
      if (pmt_uop.uop_funct3==OPMVX || pmt_uop.uop_funct3==OPFVF) // vslide1down/vfslide1down 在最后一个有效元素处插入标量。
    `else
      if (pmt_uop.uop_funct3==OPMVX) // vslide1down 在最后一个有效元素处插入标量。
    `endif
        case (pmt_uop.vs2_eew)
          // 1. 判断最后一个有效元素是否落在当前 uop_index 这一段
          // 2. 如果是，则把对应元素的 4 个 byte 标记为 scalar_valid
          EEW32: slidedown_scalar_valid = last_element_index[`VSTART_WIDTH-3:VLENB_WIDTH-2] == pmt_uop.uop_index ? {{(`VLENB-4){1'b0}}, 4'hF} << 4*last_element_index[VLENB_WIDTH-3:0] : '0;
          EEW16: slidedown_scalar_valid = last_element_index[`VSTART_WIDTH-2:VLENB_WIDTH-1] == pmt_uop.uop_index ? {{(`VLENB-2){1'b0}}, 2'h3} << 2*last_element_index[VLENB_WIDTH-2:0] : '0;
          default: slidedown_scalar_valid = last_element_index[`VSTART_WIDTH-1:VLENB_WIDTH] == pmt_uop.uop_index ? {{(`VLENB-1){1'b0}}, 1'h1} << last_element_index[VLENB_WIDTH-1:0] : '0;// EEW8
        endcase
      else
        slidedown_scalar_valid = '0;
    end
    for (i=0; i<`VLENB; i++) begin : gen_slidedown_info_t0
      always_comb begin
      `ifdef ZVE32F_ON
        if (pmt_uop.uop_funct3 == OPMVX || pmt_uop.uop_funct3 == OPFVF) begin
      `else
        if (pmt_uop.uop_funct3 == OPMVX) begin
      `endif
          case (pmt_uop.vs2_eew)
            EEW32: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({{(`XLEN+2){1'b0}}, 1'b1} << 2) + i;
            EEW16: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({{(`XLEN+2){1'b0}}, 1'b1} << 1) + i;
            default: //EEW8
                   slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({{(`XLEN+2){1'b0}}, 1'b1}) + i;
          endcase
        end else begin
          case (pmt_uop.vs2_eew)
            EEW32: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({3'h0, pmt_uop.rs1_data} << 2)  + i;
            EEW16: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({3'h0, pmt_uop.rs1_data} << 1)  + i;
            default: //EEW8
                   slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({3'h0, pmt_uop.rs1_data})  + i;
          endcase
        end
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: slidedown_overflow[i] = (|slidedown_offset[i][`XLEN+2:`VL_WIDTH+2]) | (slidedown_offset[i][`VL_WIDTH+1:0] >= ({2'h0, pmt_uop.vlmax} << 2));
          EEW16: slidedown_overflow[i] = (|slidedown_offset[i][`XLEN+2:`VL_WIDTH+1]) | (slidedown_offset[i][`VL_WIDTH:0] >= ({1'b0, pmt_uop.vlmax} << 1));
          default: slidedown_overflow[i] = (|slidedown_offset[i][`XLEN+2:`VL_WIDTH]) | (slidedown_offset[i][`VL_WIDTH-1:0] >= pmt_uop.vlmax);
        endcase
      end
      always_comb begin
        // slidedown：源地址 = 当前全局 byte 位置 + slide 距离；超过 vlmax 的 byte 写 0。
        slidedown_info_t0[i].zero_valid = slidedown_overflow[i];
        slidedown_info_t0[i].rs_valid = slidedown_scalar_valid[i];
        slidedown_info_t0[i].index = pmt_uop.vs2_index + slidedown_offset[i][VLENB_WIDTH+:3];
        slidedown_info_t0[i].offset = slidedown_offset[i][0+:VLENB_WIDTH];
        slidedown_info_t0[i].vs_valid = ~slidedown_scalar_valid[i] & ~slidedown_overflow[i] & 
                                   ((pmt_uop.uop_funct6 == VSLIDEDOWN) | (pmt_uop.uop_funct6 == VSLIDE1DOWN));
      end
    end

    //gather index
    assign double_vs1_data = {2{pmt_uop.vs1_data}};  //主要用于 vrgatherei16 在 EEW8 时索引读取可能需要访问高半/低半。
    for (i=0; i<`VLENB; i++) begin : gen_rgather_info_t0
      // rgather：从 vs1 或立即数/rs1 取得元素索引，再换算成 byte offset。
      always_comb begin
        if (pmt_uop.uop_funct6 == VSLIDEUP_RGATHEREI16) begin // vrgatherei16 的索引元素宽度固定为 16b。
          case(pmt_uop.vs2_eew)  //每个目标4个bytes, 所以0~3为一个索引index
            EEW32: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, pmt_uop.uop_index[0] ? pmt_uop.vs1_data[(i/4+`VLENW)*16+:16] : pmt_uop.vs1_data[(i/4)*16+:16]};
            EEW16: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, pmt_uop.vs1_data[(i/2)*16+:16]};
            default: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, double_vs1_data[i*16+:16]}; //EEW8
                                                                                       // EEW8 时根据 uop_index[0] 选择 vs1 的高半或低半索引数据。
          endcase
        end else begin
          case(pmt_uop.vs2_eew)  //普通 vrgather.vv 的 index 宽度和 vs2_eew 对齐
            EEW32: rgather_vs1[i] = {{(`XLEN-32){1'b0}}, pmt_uop.vs1_data[(i/4)*32+:32]};
            EEW16: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, pmt_uop.vs1_data[(i/2)*16+:16]};
            default: rgather_vs1[i] = {{(`XLEN-8){1'b0}}, pmt_uop.vs1_data[i*8+:8]};// EEW8
          endcase
        end
      end

      always_comb begin
        case (pmt_uop.uop_funct3)
          OPIVX,
          OPIVI:begin // vrgather.vx and vrgather.vi instructions
            case (pmt_uop.vs2_eew)
              //在 vrgather.vx / vrgather.vi 指令中，rs1_data（或立即数）给出的是源向量中第几个元素（element index）。
              //当 EEW=32 时，每个元素占 4 个字节（32 bits）。
              //因此，第 N 个元素的起始字节地址 = N × 4。对于 EEW=32，一个 4 字节元素会对应连续的 4 个 i。
              // 举例（EEW=32）
              // 假设 rs1_data = 3，则源向量中第 3 个元素的 4 个字节分别对应：
              // i=0 → offset = (3<<2) + 0 = 12
              // i=1 → offset = (3<<2) + 1 = 13
              // i=2 → offset = (3<<2) + 2 = 14
              // i=3 → offset = (3<<2) + 3 = 15
              EEW32: rgather_offset[i] = ({3'b0, pmt_uop.rs1_data} << 2) + (i%4);
              EEW16: rgather_offset[i] = ({3'b0, pmt_uop.rs1_data} << 1) + (i%2);
              default: rgather_offset[i] = ({3'b0, pmt_uop.rs1_data}) + (i%1); // EEW8
            endcase
          end
          default: begin // vrgather.vv and vrgatheri16.vv instructions
            case (pmt_uop.vs2_eew)
              EEW32: rgather_offset[i] = ({3'b0, rgather_vs1[i]} << 2) + (i%4); 
              EEW16: rgather_offset[i] = ({3'b0, rgather_vs1[i]} << 1) + (i%2);
              default: rgather_offset[i] = ({3'b0, rgather_vs1[i]}) + (i%1); // EEW8
            endcase
          end
        endcase
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: rgather_overflow[i] = (|rgather_offset[i][`XLEN+2:`VL_WIDTH+2]) | (rgather_offset[i][`VL_WIDTH+1:0] >= ({2'h0, pmt_uop.vlmax} << 2));
          EEW16: rgather_overflow[i] = (|rgather_offset[i][`XLEN+2:`VL_WIDTH+1]) | (rgather_offset[i][`VL_WIDTH:0] >= ({1'b0, pmt_uop.vlmax} << 1));
          default: rgather_overflow[i] = (|rgather_offset[i][`XLEN+2:`VL_WIDTH]) | (rgather_offset[i][`VL_WIDTH-1:0] >= pmt_uop.vlmax);
        endcase
      end
      always_comb begin
        // gather 越界按 RVV 语义写 0；未越界则读取 vs2_index + 高位寄存器偏移。
        rgather_info_t0[i].zero_valid = rgather_overflow[i];
        rgather_info_t0[i].rs_valid = '0;
        rgather_info_t0[i].index = pmt_uop.vs2_index + rgather_offset[i][VLENB_WIDTH+:3];
        rgather_info_t0[i].offset = rgather_offset[i][0+:VLENB_WIDTH];
        rgather_info_t0[i].vs_valid = ~rgather_overflow[i];
      end
    end

    // compress：每次找 vs1 mask 中最低的 1，把对应 vs2 元素压缩到 compress_cnt_q 指定的输出位置。
    assign compress_vs1 = pmt_uop.first_uop_valid&(compress_cnt_q=='0) ? pmt_uop.vs1_data : compress_vs1_q;
    //提取最低位的 1
    assign compress_vmsof = compress_vs1 & ~(compress_vs1 - 'b1);
    always_comb begin
      compress_vfirst = `VLMAX_MAX;
      for (int j=0; j<`VLEN; j++)
        if (compress_vmsof[j]==1'b1) compress_vfirst = j[0+:`VL_WIDTH];  //compress_vmsof 只有一个 1，所以最后得到它的 bit index。
    end
    assign compress_overflow = compress_vfirst >= pmt_uop.vl;  //如果最低 set bit 已经超过 vl，说明没有有效元素要压缩。
    assign compress_vs1_d = compress_vs1 & ~compress_vmsof;  //清掉当前已经处理的最低 set bit
    edff #(.T(logic[`VLEN-1:0])) compress_vs1_reg (.q(compress_vs1_q), .d(compress_vs1_d), .e((pmt_uop.uop_funct6==VCOMPRESS) & |(pmt_t0_valid&pmt_t0_ready)), .clk(clk), .rst_n(rst_n));
    always_comb begin
      if (compress_overflow)
        compress_cnt_d = '0;
      else
        case (pmt_uop.vs2_eew)
        //每压缩一个元素，输出 byte 位置前进一个元素宽度
          EEW32: compress_cnt_d = compress_cnt_q + 'h4;
          EEW16: compress_cnt_d = compress_cnt_q + 'h2;
          default: compress_cnt_d = compress_cnt_q + 'b1; // EEW8
        endcase
    end
    //当 compress 结束或本轮成功处理一个元素时，更新 counter
    assign compress_cnt_en = compress_overflow | 
                             ((pmt_uop.uop_funct6==VCOMPRESS) & |(pmt_t0_valid&pmt_t0_ready));
    edff #(.T(logic[VLENB_WIDTH-1:0])) compress_cnt_reg (.q(compress_cnt_q), .d(compress_cnt_d), .e(compress_cnt_en), .clk(clk), .rst_n(rst_n));
    for (i=0; i<`VLENB; i++) begin : gen_compress_info_t0
      always_comb begin
        if (compress_overflow)
          compress_info_enable[i] = i>=compress_cnt_q;  //如果 compress 结束，则从当前 compress_cnt_q 之后的 byte 都使能
                                                        //这是为了让剩余输出 byte 形成有效数据槽，通常会回读旧 vd 或保持对应语义，防止结果永远不完整。
        else begin
          case(pmt_uop.vs2_eew)
            //判断 byte i 是否属于当前 compress_cnt_q 指向的 4-byte 元素
            EEW32: compress_info_enable[i] = i[VLENB_WIDTH-1:2]==compress_cnt_q[VLENB_WIDTH-1:2];
            EEW16: compress_info_enable[i] = i[VLENB_WIDTH-1:1]==compress_cnt_q[VLENB_WIDTH-1:1];
            default: compress_info_enable[i] = i[VLENB_WIDTH-1:0]==compress_cnt_q[VLENB_WIDTH-1:0]; //EEW8
          endcase
        end
      end
      //当前找到的有效源元素是 compress_vfirst。
      //源 byte 地址是：
      //compress_vfirst * element_bytes + element_inner_byte
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: compress_offset[i] = (compress_vfirst[`VSTART_WIDTH-1:0] << 2) + i%4;
          EEW16: compress_offset[i] = (compress_vfirst[`VSTART_WIDTH-1:0] << 1) + i%2;
          default: compress_offset[i] = compress_vfirst[`VSTART_WIDTH-1:0] + i%1; //EEW8
        endcase
      end
      always_comb begin
        compress_info_t0[i].zero_valid = '0;
        compress_info_t0[i].rs_valid = '0;
        compress_info_t0[i].index = compress_overflow ? pmt_uop.dst_index : pmt_uop.vs2_index + compress_offset[i][VLENB_WIDTH+:3];
        compress_info_t0[i].offset = compress_overflow ? i[0+:VLENB_WIDTH] : compress_offset[i][0+:VLENB_WIDTH];
        compress_info_t0[i].vs_valid = (pmt_uop.uop_funct6 == VCOMPRESS);
      end
    end

    assign pmt_info_ready = (&(data_write_enable|data_valid))&(~(&data_valid));
    for (i=0; i<`VLENB; i++) begin : gen_pmt_info
      always_comb begin
        case (pmt_uop.uop_funct6)
          //VSLIDE1UP == VSLIDEUP_RGATHEREI16
          VSLIDEUP_RGATHEREI16: pmt_info_t0[i] = pmt_uop.uop_funct3 == OPIVV ? rgather_info_t0[i] : slideup_info_t0[i];
          //VSLIDE1DOWN == VSLIDEDOWN
          VSLIDEDOWN: pmt_info_t0[i] = slidedown_info_t0[i];
          VRGATHER: pmt_info_t0[i] = rgather_info_t0[i];
          default: pmt_info_t0[i] = compress_info_t0[i]; // VCOMPRESS
        endcase
      end
      always_comb begin
        case (pmt_uop.uop_funct6)
          // 非 compress：
          // 只要 pmt_go 允许，所有 byte 的 info 都有效
          // compress：
          // 只有当前 compress_info_enable 命中的 byte 有效
          // 因为 compress 一轮只处理一个有效元素对应的 byte。
          VCOMPRESS: pmt_info_valid[i] =  compress_info_enable[i] & pmt_go;
          //VSLIDE1UP, 
          //VSLIDE1DOWN,
          //VSLIDEDOWN,
          //VSLIDEUP_RGATHEREI16,
          //VRGATHER,
          default: pmt_info_valid[i] = pmt_go;
        endcase
      end
      assign pmt_t0_valid[i] = pmt_uop_valid & pmt_info_valid[i];

      handshake_ff #(.T(PMT_INFO_t)) pmt_info_reg (.outdata(pmt_info_t1[i]), .outvalid(pmt_t1_valid[i]), .outready(pmt_info_ready), 
                                                   .indata(pmt_info_t0[i]),  .invalid(pmt_t0_valid[i]),  .inready(pmt_t0_ready[i]),
                                                   .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));
    end
  endgenerate

  // uop 级控制流水：与 byte 级 info/data 流水对齐。
`ifdef TB_SUPPORT
  assign pmt_ctrl_t0.uop_pc = pmt_uop.uop_pc;
`endif
  assign pmt_ctrl_t0.rob_entry = pmt_uop.rob_entry;
  assign pmt_ctrl_t0.rs1_data = pmt_uop.rs1_data;
  assign pmt_ctrl_t0.vs2_eew = pmt_uop.vs2_eew;
  edff #(.T(PMT_CTRL_t)) pmt_ctrl_t0_reg (.q(pmt_ctrl_t1), .d(pmt_ctrl_t0), .e(pmt_t0_valid[0]&pmt_t0_ready[0]), .clk(clk), .rst_n(rst_n));

  // VRF 读收集：
  // 1. 找到第一个尚未收集完成的 byte；
  // 2. 用它的 index 发起整条向量读；
  // 3. 同一拍凡是 index 相同的 byte 都从 rd_data_vrf2pmt 中按 offset 写入。
  generate
    for (i=0; i<`VLENB; i++) assign data_valid[i] = pmt_data_t2[i].valid;
  endgenerate
  // 这里用于找 第一个还没有 valid 的 byte。
  // ~data_valid 表示哪些 byte 还没收集完成。
  // x & ~(x-1) 提取最低的 1。
  assign data_valid_zsof = ~data_valid & ~(~data_valid - 'b1);  
  always_comb begin
    data_valid_zfirst = '0;
    for (int j=0; j<`VLENB; j++)
      if (data_valid_zsof[j]==1'b1) data_valid_zfirst = j;  ////得到第一个未完成 byte 的 index
  end
  
  //发给vrf寄存器进行读操作
  assign rd_index_pmt2vrf = pmt_info_t1[data_valid_zfirst].index;  //本拍选择这个未完成 byte 所需的 VRF index 去读。

  // 某个 byte 可以写入 t2 数据槽，当且仅当：
  // 1. 这个 byte 还没 valid
  // 2. 并且它的数据本拍可获得：
  //    - zero_valid：写 0，不需要 VRF
  //    - rs_valid：来自 rs1，不需要 VRF
  //    - vs_valid 且 index 等于当前 VRF 读 index：本拍 VRF 返回了它需要的寄存器
  // 这样一次 VRF 读可以填多个 byte：
  // 所有 pmt_info_t1[i].index == rd_index_pmt2vrf 的 byte 都可同时写入
  generate
    for (i=0; i<`VLENB; i++) assign data_write_enable[i] = ~pmt_data_t2[i].valid & 
                                                           (pmt_info_t1[i].zero_valid | pmt_info_t1[i].rs_valid | (pmt_info_t1[i].vs_valid & (pmt_info_t1[i].index == rd_index_pmt2vrf)));
  endgenerate

  assign data_clear = pmt_res_valid & pmt_res_ready; 
  generate
    for (i=0; i<`VLENB; i++) begin : gen_pmt_data
      always_comb begin
        if (pmt_info_t1[i].rs_valid)
          case (pmt_ctrl_t1.vs2_eew)
            EEW32: pmt_data_t1[i].data = pmt_ctrl_t1.rs1_data[(i%4)*8+:8];
            EEW16: pmt_data_t1[i].data = pmt_ctrl_t1.rs1_data[(i%2)*8+:8];
            default: pmt_data_t1[i].data = pmt_ctrl_t1.rs1_data[(i%1)*8+:8]; // EEW8
          endcase
        else if (pmt_info_t1[i].vs_valid)
          pmt_data_t1[i].data = rd_data_vrf2pmt[pmt_info_t1[i].offset];  //索引提取
        else
          pmt_data_t1[i].data = '0;
        
        if (data_clear) pmt_data_t1[i].valid = 1'b0;
        else pmt_data_t1[i].valid = pmt_info_t1[i].rs_valid | pmt_info_t1[i].vs_valid | pmt_info_t1[i].zero_valid;
      end

      handshake_ff #(.T(logic[`BYTE_WIDTH-1:0])) pmt_data_value_reg (.outdata(pmt_data_t2[i].data), .outvalid(pmt_t2_valid[i]),                      .outready(pmt_t2_ready[i]), 
                                                                    .indata(pmt_data_t1[i].data),   .invalid(pmt_t1_valid[i]&data_write_enable[i]),  .inready(pmt_t1_ready[i]),
                                                                    .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));
      edff #(.T(logic)) pmt_data_valid_reg (.q(pmt_data_t2[i].valid), .d(pmt_data_t1[i].valid), .e(data_clear|(pmt_t1_valid[i]&data_write_enable[i]&pmt_t1_ready[i])), .clk(clk), .rst_n(rst_n));
      assign pmt_t2_ready[i] = pmt_res_ready; 
    end
  endgenerate

  edff #(.T(PMT_CTRL_t)) pmt_ctrl_t1_reg (.q(pmt_ctrl_t2), .d(pmt_ctrl_t1), .e(pmt_t1_valid[0]&pmt_t1_ready[0]), .clk(clk), .rst_n(rst_n));

// 输入 ready：
// 非 compress 需要所有 byte 的 t0 ready 且顺序门控 pmt_go 通过；
// compress 需要本轮压缩结束（compress_cnt_d 清零）后才弹出 RS uop。
// 如果是 first uop，必须等 ROB 队头指向当前 rob_entry。
// 如果不是 first uop，不受此限制。
// 非 compress：
// 所有 byte 的 t0_ready 都为 1，并且 pmt_go 通过，才 ready。
// 
// compress：
// 只有 compress_cnt_d 回到 0，也就是 compress 当前 uop 处理完，
// 并且最后一个 byte t0_ready，
// 并且 pmt_go 通过，
// 才对上游 ready。
// 
// 这说明：
// vcompress 一个 uop 可能内部多轮迭代；
// 不能每处理一个 mask bit 就 pop 上游 uop。
  assign pmt_go = ((rob_rptr==pmt_uop.rob_entry) | ~pmt_uop.first_uop_valid);
  assign pmt_uop_ready = pmt_uop.uop_funct6 == VCOMPRESS ? (compress_cnt_d == '0) & pmt_t0_ready[`VLENB-1] & pmt_go
                                                         : (&pmt_t0_ready) & pmt_go;

// 结果打包：所有 byte 收集完成后，拼成 VLEN 宽 w_data 写回 ROB。
  always_comb begin
  `ifdef TB_SUPPORT
    pmt_res.uop_pc = pmt_ctrl_t2.uop_pc;
  `endif
    pmt_res.rob_entry = pmt_ctrl_t2.rob_entry;
    for (int j=0; j<`VLENB; j++) pmt_res.w_data[j*8+:8] = pmt_data_t2[j].data; 
    pmt_res.w_valid = &data_valid;
    pmt_res.vsaturate = '0;
  `ifdef ZVE32F_ON
    pmt_res.fpexp = '0;
  `endif
  end

// 所有 byte 的 t2 valid 同时为 1，表示整条 permutation 结果已经完整。
  assign pmt_res_valid = &pmt_t2_valid;

// ---function--------------------------------------------------------

endmodule
