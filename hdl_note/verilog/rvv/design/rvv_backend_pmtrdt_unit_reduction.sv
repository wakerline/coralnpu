// 功能说明：
// 1. 整数 reduction/mask reduction 执行单元。
// 2. 支持 vredsum/vredmax/vredmin/vredand/vredor/vredxor、vwredsum*，
//    以及 mask 类 vcpop/viota。
// 3. 数据通路先把 vs2 按 32-bit ALU 宽度分组，在 t0/t1/t2/t3/t4 多级树中逐步规约；
//    树级数由 VLENB 决定，VLEN 越大级数越多。
// 4. 普通规约最后再与 vs1[0] 合并；mask 指令通过 VM FSM 多轮处理 mask bit，
//    viota 还额外维护前缀和，用于生成每个元素之前的有效 bit 数。
// 5. vwredsum/vwredsumu 需要把窄 vs2 拓宽后规约，wsum_h 在低半/高半之间翻转，
//    确保一条 uop 的两半源数据都被送入规约树。

// PMT/RDT RS uop
//     ↓
// 判断普通 reduction / widening reduction / mask reduction
//     ↓
// 准备 vs2 / mask / widen_vs2 / 单位元填充
//     ↓
// t0/t1/t2/t3/t4 多级 32-bit reduction tree
//     ↓
// 最终按 EEW8/16/32 继续归约到一个标量
//     ↓
// 普通 reduction：低位写标量结果
// viota：写整条向量前缀计数结果
//     ↓
// PU2ROB_t 写回 ROB

// 1. VM FSM / mask 分段控制
// 2. mask bit 过滤与展开
// 3. widening reduction 源准备
// 4. t0 输入准备与 inactive/tail 单位元填充
// 5. t0/t1/t2/t3/t4 多级 reduction tree
// 6. 最终 8/16/32-bit 标量合并
// 7. viota prefix result 生成
// 8. PU2ROB_t 结果打包

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif
module rvv_backend_pmtrdt_unit_reduction
(
  clk,
  rst_n,

  rdt_uop_valid,
  rdt_uop,
  rdt_uop_ready,

  rdt_res_valid,
  rdt_res,
  rdt_res_ready,

  trap_flush_rvv
);

// ---端口定义--------------------------------------------------------
// 全局时钟/复位。
  input logic       clk;
  input logic       rst_n;

// 来自 PMTRDT unit 的 reduction uop。
  input             rdt_uop_valid;
  input PMT_RDT_RS_t rdt_uop;
  output logic      rdt_uop_ready;

// 输出到 PMTRDT unit 的 ROB 写回结果。
  output logic      rdt_res_valid;
  output PU2ROB_t   rdt_res;
  input             rdt_res_ready;

// RVV trap/flush 清空内部状态。
  input             trap_flush_rvv;

// ---参数定义--------------------------------------------------------
  localparam        ALU_WIDTH       = 32;
  localparam        ALU_BYTE        = ALU_WIDTH/8;
  localparam        ALU_NUM_T0      = `VLENB/(ALU_BYTE*2);  // t0 阶段每个 ALU 一次处理两个 32-bit 操作数，即 8 byte
  localparam        ALU_STAGE_NUM   = 5'($clog2(ALU_NUM_T0));  //规约树级数
  localparam        VIOTA_STRIDE    = 4;                    // viota 前缀和每 4 个 mask bit 分组。
  localparam        M_SUM_NUM       = `VLENB/VIOTA_STRIDE;
  localparam        ALU_NUM_T1      = ALU_NUM_T0/2;
  localparam        ALU_NUM_T2      = ALU_NUM_T1/2;
  localparam        ALU_NUM_T3      = ALU_NUM_T2/2;
  localparam        ALU_NUM_T4      = ALU_NUM_T3/2;

// ---内部信号--------------------------------------------------------
  logic                     wsum, wsum_h;          // 拓宽规约标志，以及当前处理低半/高半的翻转位。
  logic [`VLEN-1:0]         widen_vs2;             // 拓宽后的 vs2 数据。
  BYTE_TYPE_t               widen_vs2_type;        // 拓宽后每个 byte 的 body/tail/mask 类型。

  RDT_ALU_t                 alu_ctrl_t0, alu_ctrl_t1;
  logic                     alu_t0_valid, alu_t1_valid;
  logic                     alu_t0_ready, alu_t1_ready;
  logic [ALU_NUM_T0-1:0][ALU_BYTE-1:0][7:0] src1_t0, src2_t0, dst_t0, data_t1; // t0 pairwise reduction 的源/目的。
  logic [ALU_BYTE-1:0][7:0] vs1_t0, vs1_t1;                // reduction 初值 vs1[0]。

  VM_STATE_e                vm_state, next_vm_state;             // mask 指令状态机：vcpop/viota。
  logic                     state_en;
  logic                     vm_en;
  logic                     vm_last_opr;                   // mask 指令最后一轮。
  logic [`VL_WIDTH-1:0]     vm_cnt, vm_cnt_q;
  RDT_VM_t                  vm_ctrl, vm_ctrl_q;
  logic [`VLEN-1:0]         vs2_m, vs2_m_tail_tmp, vs2_m_tail, vs2_m_body, vs2_m_d, vs2_m_q;       // 套用 v0/vm/tail 后的 mask 源。
  logic [`VLEN-1:0]         vm_vs2;
  logic [`VLENB-1:0]        vs2_m_t0, vs2_m_t1;            // mask bit 随规约树流水传递。
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0] vs2_m_sum_t0, vs2_m_sum_t1;   // viota 分组前缀和。

  // ALU_STAGE_NUM > 0
  RDT_ALU_t                 alu_ctrl_t2;
  logic                     alu_t2_valid;
  logic                     alu_t2_ready;
  logic [ALU_NUM_T1-1:0][ALU_BYTE-1:0][7:0] src1_t1, src2_t1, dst_t1, data_t2; // reduction operation in 1 stage: source value for reduction data_t1
  logic [ALU_BYTE-1:0][7:0] vs1_t2;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t2;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t1_tmp, vs2_m_sum_t2;
  // ALU_STAGE_NUM > 1
  RDT_ALU_t                 alu_ctrl_t3;
  logic                     alu_t3_valid;
  logic                     alu_t3_ready;
  logic [ALU_NUM_T2-1:0][ALU_BYTE-1:0][7:0] src1_t2, src2_t2, dst_t2, data_t3; // reduction operation in 1 stage: source value for reduction data_t2
  logic [ALU_BYTE-1:0][7:0] vs1_t3;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t3;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t2_tmp, vs2_m_sum_t3;
  // ALU_STAGE_NUM > 2
  RDT_ALU_t                 alu_ctrl_t4;
  logic                     alu_t4_valid;
  logic                     alu_t4_ready;
  logic [ALU_NUM_T3-1:0][ALU_BYTE-1:0][7:0] src1_t3, src2_t3, dst_t3, data_t4; // reduction operation in 1 stage: source value for reduction data_t3
  logic [ALU_BYTE-1:0][7:0] vs1_t4;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t4;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t3_tmp, vs2_m_sum_t4;
  // ALU_STAGE_NUM > 3
  RDT_ALU_t                 alu_ctrl_t5;
  logic                     alu_t5_valid;
  logic                     alu_t5_ready;
  logic [ALU_NUM_T4-1:0][ALU_BYTE-1:0][7:0] src1_t4, src2_t4, dst_t4, data_t5; // reduction operation in 1 stage: source value for reduction data_t4
  logic [ALU_BYTE-1:0][7:0] vs1_t5;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t5;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t4_tmp, vs2_m_sum_t5;

  // ALU_STAGE_NUM == 0
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t0;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t1;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t0;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t1;
  // ALU_STAGE_NUM == 1
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t2;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t2;
  // ALU_STAGE_NUM == 2
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t3;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t3;
  // ALU_STAGE_NUM == 3
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t4;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t4;
  // ALU_STAGE_NUM == 4
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t5;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t5;

  RDT_ALU_t                 alu_ctrl;
  logic                     alu_ctrl_valid;
  logic [ALU_BYTE-1:0][7:0] rdt_vs2, rdt_vs1;
  logic [7:0]               rdt_src1_8b,  rdt_src2_8b;
  logic [7:0]               rdt_vs1_8b,  rdt_vs2_8b,  dst_8b;
  logic [15:0]              rdt_vs1_16b, rdt_vs2_16b, dst_16b;
  logic [31:0]              rdt_vs1_32b, rdt_vs2_32b, dst_32b;
  logic [ALU_WIDTH-1:0]     rdt_dst;
  logic [ALU_BYTE-1:0][7:0] rdt_pre_dst;

  logic [ALU_BYTE-1:0][7:0] viota_src1;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0]        viota_cin;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0]        viota_cout;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_dst;

  genvar i;

// ---主逻辑----------------------------------------------------------
  // VM FSM：
  // MSK0 处理第一段 mask，MSKN 继续处理后续段；vcpop/viota 的 vl 可能超过单拍可处理元素数。
  always_comb begin
    next_vm_state = MSK0;
    state_en = 1'b0;
    vm_en = 1'b0;
    vm_last_opr = 1'b0;  //mask指令最后一轮
    case (vm_state)
      MSK0: begin
        if(rdt_uop_valid & ((vm_ctrl.uop_funct6==VWRXUNARY0)|(vm_ctrl.uop_funct6==VMUNARY0))) begin //vcpop 和 viota 是 mask 类指令
          if (vm_cnt < vm_ctrl.vlmax) begin
            next_vm_state = MSKN;
            state_en = 1'b1;
            vm_en = 1'b1;
          end else begin
            vm_last_opr = 1'b1;
          end
        end
      end
      default: begin // MSKN
      //对 vcpop 来说，只有最后一轮完成后才能认为整个 uop ready；对 viota 来说，每一轮都可能产生一段向量前缀和结果。
        if (vm_cnt >= vm_ctrl_q.vlmax) begin
          next_vm_state = MSK0;
          state_en = vm_ctrl_q.uop_funct6==VMUNARY0 ? rdt_uop_valid : 1'b1;
          vm_last_opr = 1'b1;
        end
        vm_en = 1'b1;
      end
    endcase
  end
  cdffr #(.T(VM_STATE_e), .INIT(MSK0)) vm_state_reg (.q(vm_state), .d(next_vm_state), .c(trap_flush_rvv), .e(state_en&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));
  
  // vm_cnt：记录 mask 指令已经处理到的元素位置，不同 EEW 每拍推进的元素数不同。
  // viota / VMUNARY0：
  //   EEW32 每轮推进 VLENW 个元素
  //   EEW16 每轮推进 VLENH 个元素
  //   EEW8  每轮推进 VLENB 个元素
  // vcpop / VWRXUNARY0：vcpop.m rd, vs2, v0.t # x[rd] = sum_i ( vs2.mask[i] && v0.mask[i] )
  //   每轮按 VLENH 推进
  always_comb begin
    case (vm_state)
      MSK0: begin
        case (vm_ctrl.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl.vd_eew)
              EEW32: vm_cnt = `VLENW;
              EEW16: vm_cnt = `VLENH;
              default: vm_cnt = `VLENB;
            endcase
          end
          default: vm_cnt = `VLENH;
        endcase
      end
      default: begin // MSKN
        case (vm_ctrl_q.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl_q.vd_eew)
              EEW32: vm_cnt = vm_cnt_q + `VLENW;
              EEW16: vm_cnt = vm_cnt_q + `VLENH;
              default: vm_cnt = vm_cnt_q + `VLENB;
            endcase
          end
          default: vm_cnt = vm_cnt_q +`VLENH;
        endcase
      end
    endcase
  end
  cdffr #(.T(logic[`VL_WIDTH-1:0])) vm_cnt_reg (.q(vm_cnt_q), .d(vm_cnt), .c(trap_flush_rvv), .e(vm_en&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  // vs2_m：先套用 v0 mask/vm/tail，得到真正参与 vcpop/viota 的 mask bit。
  barrel_shifter #(.DATA_WIDTH(`VLEN)) 
  u_tail (.din((`VLEN)'('1)), .shift_amount(rdt_uop.vl[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vs2_m_tail_tmp));
  
  assign vs2_m_tail = rdt_uop.vl[$clog2(`VLEN)] ? 'b0 : vs2_m_tail_tmp;
  assign vs2_m_body = ~vs2_m_tail;
  // vs2_data：原始 mask 源
  // v0_data：mask 控制
  // vm：是否不使用 v0 mask
  // vs2_m_body：去掉 tail 后的 body 区域
  assign vs2_m = rdt_uop.vs2_data & (rdt_uop.v0_data | {(`VLEN){rdt_uop.vm}}) & vs2_m_body;

  always_comb begin
    case (vm_state)
      MSK0: begin
        case (vm_ctrl.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl.vd_eew)
              EEW32: vs2_m_d = vs2_m >> `VLENW;
              EEW16: vs2_m_d = vs2_m >> `VLENH;
              default: vs2_m_d = vs2_m >> `VLENB; //EEW8
            endcase
          end
          default: vs2_m_d = vs2_m >> `VLENH; // vcpop 写 XRF，结果宽度远小于 XLEN，这里按 16-bit 分段推进。
        endcase
      end
      default: begin //MSKN
        case (vm_ctrl_q.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl_q.vd_eew)
              EEW32: vs2_m_d = vs2_m_q >> `VLENW;
              EEW16: vs2_m_d = vs2_m_q >> `VLENH;
              default: vs2_m_d = vs2_m_q >> `VLENB; // EEW8
            endcase
          end
          default: vs2_m_d = vs2_m_q >> `VLENH; // vcpop 继续按 16-bit 分段推进。
        endcase
      end
    endcase
  end
  edff #(.T(logic[`VLEN-1:0])) vs2_m_reg (.q(vs2_m_q), .d(vs2_m_d), .e(vm_en&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  assign vm_ctrl.uop_funct6 = rdt_uop.uop_funct6;
  assign vm_ctrl.vlmax      = rdt_uop.vlmax;
  assign vm_ctrl.vd_eew     = rdt_uop.vd_eew;
  cdffr #(.T(RDT_VM_t)) vm_ctrl_reg (.q(vm_ctrl_q), .d(vm_ctrl), .c(trap_flush_rvv), .e(vm_en&(vm_state==MSK0)&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  // vm_vs2：把 mask bit 扩展成普通规约树能处理的 8/16/32-bit 元素。
  always_comb begin
    case (vm_state)
      MSK0: begin
        case (vm_ctrl.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl.vd_eew)
              EEW32: for (int j=0; j<`VLENW; j++) vm_vs2[32*j+:32] = {31'h0, vs2_m[j]};
              EEW16: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m[j]};
              default: for (int j=0; j<`VLENB; j++) vm_vs2[8*j+:8] = {7'h0, vs2_m[j]};
            endcase
          end
          default: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m[j]};
        endcase
      end
      default: begin // MSKN
        case (vm_ctrl_q.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl_q.vd_eew)
              EEW32: for (int j=0; j<`VLENW; j++) vm_vs2[32*j+:32] = {31'h0, vs2_m_q[j]};
              EEW16: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m_q[j]};
              default: for (int j=0; j<`VLENB; j++) vm_vs2[8*j+:8] = {7'h0, vs2_m_q[j]};
            endcase
          end
          default: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m_q[j]};
        endcase
      end
    endcase
  end

  // 每个 t0 ALU 规约 8 byte 的数据：
  // src2_t0[i] = vs2_data[8*i + 0 .. 8*i + 3]
  // src1_t0[i] = vs2_data[8*i + 4 .. 8*i + 7]
  generate
    // t0 输入准备：每个 ALU 接收两个 32-bit 操作数，等价于先做第一层 pairwise reduction。
    for (i=0; i<ALU_NUM_T0; i++) begin : gen_src_t0  // 需要ALU_NUM_T0 = `VLENB/(4*2)个alu，每个alu处理8 bytes
      // src2_t0：前半组元素。非 BODY_ACTIVE 元素填入对应操作的单位元。
      // 计算时不影响结果，等价于mask操作
      // | 指令            | inactive/tail 填充值 | 原因                   |
      // | ------------- | ----------------- | -------------------- |
      // | `vredsum`     | 0                 | 加法单位元                |
      // | `vredor`      | 0                 | OR 单位元               |
      // | `vredxor`     | 0                 | XOR 单位元              |
      // | `vredmaxu`    | 0                 | 无符号 max 的最小候选        |
      // | `vredminu`    | 全 1               | 无符号 min 的最大候选        |
      // | `vredand`     | 全 1               | AND 单位元              |
      // | `vredmax`     | signed 最小值        | 有符号 max 的最小候选        |
      // | `vredmin`     | signed 最大值        | 有符号 min 的最大候选        |
      // | `vwredsum*`   | 0                 | 求和单位元                |
      // | `vcpop/viota` | mask 扩展值          | 由 `vm_vs2` 提供 0/1 元素 |
      always_comb begin
        src2_t0[i][0][7:0] = rdt_uop.vs2_data[8*(8*i)+:8]  ;
        src2_t0[i][1][7:0] = rdt_uop.vs2_data[8*(8*i+1)+:8]; 
        src2_t0[i][2][7:0] = rdt_uop.vs2_data[8*(8*i+2)+:8]; 
        src2_t0[i][3][7:0] = rdt_uop.vs2_data[8*(8*i+3)+:8]; 
        case (rdt_uop.uop_funct6)
          VMUNARY0, // VIOTA
          VWRXUNARY0: begin // VCPOP 
            //vm_vs2已经是body ，所以直接赋值由 vm_vs2 提供eew扩展后的 0/1 元素
            src2_t0[i][0][7:0] = vm_vs2[8*(8*i)+:8]  ;
            src2_t0[i][1][7:0] = vm_vs2[8*(8*i+1)+:8]; 
            src2_t0[i][2][7:0] = vm_vs2[8*(8*i+2)+:8]; 
            src2_t0[i][3][7:0] = vm_vs2[8*(8*i+3)+:8]; 
          end
          VWREDSUMU,
          VWREDSUM:begin  //扩展位，0
            if (widen_vs2_type[8*i]   == BODY_ACTIVE) src2_t0[i][0][7:0] = widen_vs2[8*(8*i)+:8];
            else                                      src2_t0[i][0][7:0] = 8'h00;
            if (widen_vs2_type[8*i+1] == BODY_ACTIVE) src2_t0[i][1][7:0] = widen_vs2[8*(8*i+1)+:8];
            else                                      src2_t0[i][1][7:0] = 8'h00;
            if (widen_vs2_type[8*i+2] == BODY_ACTIVE) src2_t0[i][2][7:0] = widen_vs2[8*(8*i+2)+:8];
            else                                      src2_t0[i][2][7:0] = 8'h00;
            if (widen_vs2_type[8*i+3] == BODY_ACTIVE) src2_t0[i][3][7:0] = widen_vs2[8*(8*i+3)+:8];
            else                                      src2_t0[i][3][7:0] = 8'h00;
          end
          VREDMAX:begin  //signed 最小值
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h00; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h00; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h80; 
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h80; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h00; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h80; 
              end
              default:begin // EEW8
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h80; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h80; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h80; 
              end
            endcase
          end
          VREDMIN:begin  //signed 最大值
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'hFF; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'hFF; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h7F; 
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h7F; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'hFF; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h7F; 
              end
              default:begin // EEW8
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h7F; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h7F; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h7F; 
              end
            endcase
          end
          VREDMINU,      //全 1, 无符号 min 的最大候选
          VREDAND:begin  //全 1， AND 单位元
            if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'hFF;
          end
          default:begin // VREDSUM, VREDMAXU, VREDOR, VREDXOR， 0
            if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h00; 
            if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h00; 
            if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h00; 
          end
        endcase
      end
      // 每个 t0 ALU 规约 8 byte 的数据：
      // src2_t0[i] = vs2_data[8*i + 0 .. 8*i + 3]
      // src1_t0[i] = vs2_data[8*i + 4 .. 8*i + 7]
      // src1_t0：后半组元素。与 src2_t0 一样对 inactive/tail 元素填单位元。
      always_comb begin
        src1_t0[i][0][7:0] = rdt_uop.vs2_data[8*(8*i+4)+:8];
        src1_t0[i][1][7:0] = rdt_uop.vs2_data[8*(8*i+5)+:8];
        src1_t0[i][2][7:0] = rdt_uop.vs2_data[8*(8*i+6)+:8];
        src1_t0[i][3][7:0] = rdt_uop.vs2_data[8*(8*i+7)+:8];
        case (rdt_uop.uop_funct6)
          VMUNARY0,
          VWRXUNARY0:begin
            src1_t0[i][0][7:0] = vm_vs2[8*(8*i+4)+:8];
            src1_t0[i][1][7:0] = vm_vs2[8*(8*i+5)+:8];
            src1_t0[i][2][7:0] = vm_vs2[8*(8*i+6)+:8];
            src1_t0[i][3][7:0] = vm_vs2[8*(8*i+7)+:8];
          end
          VWREDSUMU,
          VWREDSUM:begin
            if (widen_vs2_type[8*i+4] == BODY_ACTIVE) src1_t0[i][0][7:0] = widen_vs2[8*(8*i+4)+:8];
            else                                      src1_t0[i][0][7:0] = 8'h00;
            if (widen_vs2_type[8*i+5] == BODY_ACTIVE) src1_t0[i][1][7:0] = widen_vs2[8*(8*i+5)+:8];
            else                                      src1_t0[i][1][7:0] = 8'h00;
            if (widen_vs2_type[8*i+6] == BODY_ACTIVE) src1_t0[i][2][7:0] = widen_vs2[8*(8*i+6)+:8];
            else                                      src1_t0[i][2][7:0] = 8'h00;
            if (widen_vs2_type[8*i+7] == BODY_ACTIVE) src1_t0[i][3][7:0] = widen_vs2[8*(8*i+7)+:8];
            else                                      src1_t0[i][3][7:0] = 8'h00;
          end
          VREDMAX:begin
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h80;
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h80;
              end
              default:begin // EEW8
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h80;
              end
            endcase
          end
          VREDMIN:begin
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h7F;
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h7F;
              end
              default:begin // EE8
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h7F;
              end
            endcase
          end
          VREDMINU,
          VREDAND:begin
            if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'hFF;
          end
          default:begin // VREDSUM, VREDMAXU, VREDOR, VREDXOR
            if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h00;
          end
        endcase
      end
    end //for (i=0; i<ALU_NUM_T0; i++) begin : gen_src_t0
  endgenerate

  assign wsum = (rdt_uop.uop_funct6 == VWREDSUMU) || (rdt_uop.uop_funct6 == VWREDSUM);  //Widening Integer Reduction
  //由于rst_n的存在，初始化后wsum_h=0，只要eable有效 wsum_h 是低半 / 高半翻转位
  cdffr #(.T(logic)) wsum_h_reg (.q(wsum_h), .d(~wsum_h), .c(trap_flush_rvv), .e(wsum & alu_t0_valid & alu_t0_ready), .clk(clk), .rst_n(rst_n));
  // 拓宽规约源准备：
  // EEW8/16 的源元素被扩成 2*SEW，VWREDSUM 做符号扩展，VWREDSUMU 高半补 0。
  // wsum_h 在低半和高半之间切换，用同一套规约树处理整条向量。
  always_comb begin
    case(rdt_uop.vs2_eew)
      EEW16:begin
        for (int j=0; j<`VLENB/4; j++) begin
          //代码里 widen_vs2 保存拓宽后的数据，widen_vs2_type 保存拓宽后每个 byte 是否是 BODY_ACTIVE。这很重要，
          //因为 inactive/tail 元素不能参与规约，必须被替换成对应操作的单位元。
          widen_vs2[16*(2*j)+:16]   = wsum_h ? rdt_uop.vs2_data[(`VLEN/2+16*j)+:16] : rdt_uop.vs2_data[(16*j)+:16];
          //高16位补符号位或者0
          widen_vs2[16*(2*j+1)+:16] = rdt_uop.uop_funct6 == VWREDSUM ? wsum_h ? {16{rdt_uop.vs2_data[`VLEN/2+16*(j+1)-1]}}
                                                                              : {16{rdt_uop.vs2_data[16*(j+1)-1]}}
                                                                     : '0;
          //widen_vs2_type 保存拓宽后每个 byte 是否是 BODY_ACTIVE
          widen_vs2_type[4*j]   = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j]   : rdt_uop.vs2_type[2*j];
          widen_vs2_type[4*j+1] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j+1] : rdt_uop.vs2_type[2*j+1];
          widen_vs2_type[4*j+2] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j]   : rdt_uop.vs2_type[2*j];
          widen_vs2_type[4*j+3] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j+1] : rdt_uop.vs2_type[2*j+1];
        end
      end
      default:begin // EEW8
        for (int j=0; j<`VLENB/2; j++) begin
          widen_vs2[8*(2*j)+:8]   = wsum_h ? rdt_uop.vs2_data[(`VLEN/2+8*j)+:8] : rdt_uop.vs2_data[(8*j)+:8];
          widen_vs2[8*(2*j+1)+:8] = rdt_uop.uop_funct6 == VWREDSUM ? wsum_h ? {8{rdt_uop.vs2_data[`VLEN/2+8*(j+1)-1]}}
                                                                            : {8{rdt_uop.vs2_data[8*(j+1)-1]}}
                                                                   : '0;
          widen_vs2_type[2*j]   = wsum_h ? rdt_uop.vs2_type[`VLENB/2+j] : rdt_uop.vs2_type[j];
          widen_vs2_type[2*j+1] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+j] : rdt_uop.vs2_type[j];
        end
      end
    endcase
  end

  // t0 规约级：把原始 vs2 或 vm_vs2 做第一层 pairwise reduction。
  assign alu_t0_valid = rdt_uop_valid & (rdt_uop_ready | !wsum_h);
`ifdef TB_SUPPORT
  assign alu_ctrl_t0.uop_pc     = rdt_uop.uop_pc;
`endif
  assign alu_ctrl_t0.rob_entry  = rdt_uop.rob_entry;
  assign alu_ctrl_t0.vm_state   = vm_state;
  assign alu_ctrl_t0.uop_funct6 = rdt_uop.uop_funct6;
  assign alu_ctrl_t0.vd_eew     = vm_ctrl.uop_funct6==VWRXUNARY0 ? EEW16 : rdt_uop.vd_eew;
  assign alu_ctrl_t0.vs2_eew    = vm_ctrl.uop_funct6==VWRXUNARY0 ? EEW16 : rdt_uop.vd_eew; // 2*SEW when vwsum
  assign alu_ctrl_t0.first_uop_valid = rdt_uop.first_uop_valid & ~wsum_h;
  assign alu_ctrl_t0.last_uop_valid = vm_ctrl.uop_funct6==VWRXUNARY0 ? vm_last_opr : wsum ? rdt_uop.last_uop_valid&wsum_h : rdt_uop.last_uop_valid;

  generate
    for (i=0; i<ALU_NUM_T0; i++) begin : gen_alu_t0
      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t0 (
        .src1   (src1_t0[i]),
        .src2   (src2_t0[i]),
        .ctrl   (alu_ctrl_t0),
        .dst    (dst_t0[i])
      );
  
      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t0_reg (.q(data_t1[i]), .d(dst_t0[i]), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));
    end
  endgenerate

  assign vs2_m_t0 = vm_state==MSK0 ? vs2_m[`VLENB-1:0] : vs2_m_q[`VLENB-1:0];
  edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t0_reg (.q(vs2_m_t1), .d(vs2_m_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  always_comb begin
    // M_SUM_NUM = `VLENB/VIOTA_STRIDE;
    for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t0[i] = '0;  //前缀和初始化为0
    for (int i=1; i<M_SUM_NUM; i++) 
      for (int j=0; j<VIOTA_STRIDE; j++) vs2_m_sum_t0[i] += vs2_m_t0[(i-1)*VIOTA_STRIDE+j];
    for (int i=2; i<M_SUM_NUM; i=i+2) vs2_m_sum_t0[i] = vs2_m_sum_t0[i] + vs2_m_sum_t0[i-1]; 
    for (int i=3; i<M_SUM_NUM; i=i+4) vs2_m_sum_t0[i] = vs2_m_sum_t0[i] + vs2_m_sum_t0[i-1];
    for (int i=4; i<M_SUM_NUM; i=i+4) vs2_m_sum_t0[i] = vs2_m_sum_t0[i] + vs2_m_sum_t0[i-2];
  end
  edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t0_reg (.q(vs2_m_sum_t1), .d(vs2_m_sum_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  //handshake_ff:
  // output T        outdata;
  // output logic    outvalid;
  // input  logic    outready;

  // input  T        indata;
  // input  logic    invalid;
  // output logic    inready;

  // assign data_en = invalid & inready;
  // edff #(.T(T)) data_reg (.q(outdata), .d(indata), .e(data_en), .clk(clk), .rst_n(rst_n));

  // assign valid_en = invalid & inready | outvalid & outready;
  // cdffr #(.T(logic)) valid_reg (.q(outvalid), .d(invalid), .c(c), .e(valid_en), .clk(clk), .rst_n(rst_n));
  handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t0_reg (.outdata(alu_ctrl_t1), .outvalid(alu_t1_valid), .outready(alu_t1_ready), 
                                                     .indata(alu_ctrl_t0),  .invalid(alu_t0_valid),  .inready(alu_t0_ready),
                                                     .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

  // vs1[0] 作为 reduction 初值，随流水传到最终合并级。
  assign vs1_t0 = rdt_uop.vs1_data[0+:ALU_WIDTH];
  edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t0_reg (.q(vs1_t1), .d(vs1_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

generate
  // 后续规约树：只规约 vs2 产生的中间结果，暂不与 vs1[0] 合并。
  if (ALU_STAGE_NUM > 5'd0) begin
    for (i=0; i<ALU_NUM_T1; i++) begin : gen_alu_t1
      // src2_t1 data
      always_comb begin
        src2_t1[i][0][7:0] = data_t1[2*i][0][7:0];
        src2_t1[i][1][7:0] = data_t1[2*i][1][7:0];
        src2_t1[i][2][7:0] = data_t1[2*i][2][7:0];
        src2_t1[i][3][7:0] = data_t1[2*i][3][7:0];
      end
      // src1_t1 data
      always_comb begin
        src1_t1[i][0][7:0] = data_t1[2*i+1][0][7:0];
        src1_t1[i][1][7:0] = data_t1[2*i+1][1][7:0];
        src1_t1[i][2][7:0] = data_t1[2*i+1][2][7:0];
        src1_t1[i][3][7:0] = data_t1[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t1 (
        .src1   (src1_t1[i]),
        .src2   (src2_t1[i]),
        .ctrl   (alu_ctrl_t1),
        .dst    (dst_t1[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t1_reg (.q(data_t2[i]), .d(dst_t1[i]), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T1; i++) begin : gen_alu_t1

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t1_reg (.q(vs2_m_t2), .d(vs2_m_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t1_tmp[i] = vs2_m_sum_t1[i];
      for (int i=4; i<M_SUM_NUM; i=i+8)
        for (int j=1; j<4; j++) vs2_m_sum_t1_tmp[i+j] = vs2_m_sum_t1[i+j] + vs2_m_sum_t1[i];
      for (int i=8; i<M_SUM_NUM; i=i+8) vs2_m_sum_t1_tmp[i] = vs2_m_sum_t1[i] + vs2_m_sum_t1[i-4];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t1_reg (.q(vs2_m_sum_t2), .d(vs2_m_sum_t1_tmp), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t1_reg (.outdata(alu_ctrl_t2), .outvalid(alu_t2_valid), .outready(alu_t2_ready), 
                                                       .indata(alu_ctrl_t1),  .invalid(alu_t1_valid),  .inready(alu_t1_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t1_reg (.q(vs1_t2), .d(vs1_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));
  end
  
  if (ALU_STAGE_NUM > 5'd1) begin
    for (i=0; i<ALU_NUM_T2; i++) begin : gen_alu_t2
      // src2_t2 data
      always_comb begin
        src2_t2[i][0][7:0] = data_t2[2*i][0][7:0];
        src2_t2[i][1][7:0] = data_t2[2*i][1][7:0];
        src2_t2[i][2][7:0] = data_t2[2*i][2][7:0];
        src2_t2[i][3][7:0] = data_t2[2*i][3][7:0];
      end
      // src1_t2 data
      always_comb begin
        src1_t2[i][0][7:0] = data_t2[2*i+1][0][7:0];
        src1_t2[i][1][7:0] = data_t2[2*i+1][1][7:0];
        src1_t2[i][2][7:0] = data_t2[2*i+1][2][7:0];
        src1_t2[i][3][7:0] = data_t2[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t2 (
        .src1   (src1_t2[i]),
        .src2   (src2_t2[i]),
        .ctrl   (alu_ctrl_t2),
        .dst    (dst_t2[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t2_reg (.q(data_t3[i]), .d(dst_t2[i]), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T2; i++) begin : gen_alu_t2

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t2_reg (.q(vs2_m_t3), .d(vs2_m_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t2_tmp[i] = vs2_m_sum_t2[i];
      for (int i=8; i<M_SUM_NUM; i=i+16)
        for (int j=1; j<8; j++) vs2_m_sum_t2_tmp[i+j] = vs2_m_sum_t2[i+j] + vs2_m_sum_t2[i];
      for (int i=16; i<M_SUM_NUM; i=i+16) vs2_m_sum_t2_tmp[i] = vs2_m_sum_t2[i] + vs2_m_sum_t2[i-8];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t2_reg (.q(vs2_m_sum_t3), .d(vs2_m_sum_t2_tmp), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t2_reg (.outdata(alu_ctrl_t3), .outvalid(alu_t3_valid), .outready(alu_t3_ready), 
                                                       .indata(alu_ctrl_t2),  .invalid(alu_t2_valid),  .inready(alu_t2_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t2_reg (.q(vs1_t3), .d(vs1_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM > 5'd2) begin
    for (i=0; i<ALU_NUM_T3; i++) begin : gen_alu_t3
      // src2_t3 data
      always_comb begin
        src2_t3[i][0][7:0] = data_t3[2*i][0][7:0];
        src2_t3[i][1][7:0] = data_t3[2*i][1][7:0];
        src2_t3[i][2][7:0] = data_t3[2*i][2][7:0];
        src2_t3[i][3][7:0] = data_t3[2*i][3][7:0];
      end
      // src1_t3 data
      always_comb begin
        src1_t3[i][0][7:0] = data_t3[2*i+1][0][7:0];
        src1_t3[i][1][7:0] = data_t3[2*i+1][1][7:0];
        src1_t3[i][2][7:0] = data_t3[2*i+1][2][7:0];
        src1_t3[i][3][7:0] = data_t3[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t3 (
        .src1   (src1_t3[i]),
        .src2   (src2_t3[i]),
        .ctrl   (alu_ctrl_t3),
        .dst    (dst_t3[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t3_reg (.q(data_t4[i]), .d(dst_t3[i]), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T3; i++) begin : gen_alu_t3

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t3_reg (.q(vs2_m_t4), .d(vs2_m_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t3_tmp[i] = vs2_m_sum_t3[i];
      for (int i=16; i<M_SUM_NUM; i=i+32)
        for (int j=1; j<16; j++) vs2_m_sum_t3_tmp[i+j] = vs2_m_sum_t3[i+j] + vs2_m_sum_t3[i];
      for (int i=32; i<M_SUM_NUM; i=i+32) vs2_m_sum_t3_tmp[i] = vs2_m_sum_t3[i] + vs2_m_sum_t3[i-16];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t3_reg (.q(vs2_m_sum_t4), .d(vs2_m_sum_t3_tmp), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t3_reg (.outdata(alu_ctrl_t4), .outvalid(alu_t4_valid), .outready(alu_t4_ready),
                                                       .indata(alu_ctrl_t3),  .invalid(alu_t3_valid),  .inready(alu_t3_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t3_reg (.q(vs1_t4), .d(vs1_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM > 5'd3) begin
    for (i=0; i<ALU_NUM_T4; i++) begin : gen_alu_t4
      // src2_t4 data
      always_comb begin
        src2_t4[i][0][7:0] = data_t4[2*i][0][7:0];
        src2_t4[i][1][7:0] = data_t4[2*i][1][7:0];
        src2_t4[i][2][7:0] = data_t4[2*i][2][7:0];
        src2_t4[i][3][7:0] = data_t4[2*i][3][7:0];
      end
      // src1_t4 data
      always_comb begin
        src1_t4[i][0][7:0] = data_t4[2*i+1][0][7:0];
        src1_t4[i][1][7:0] = data_t4[2*i+1][1][7:0];
        src1_t4[i][2][7:0] = data_t4[2*i+1][2][7:0];
        src1_t4[i][3][7:0] = data_t4[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t4 (
        .src1   (src1_t4[i]),
        .src2   (src2_t4[i]),
        .ctrl   (alu_ctrl_t4),
        .dst    (dst_t4[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t4_reg (.q(data_t5[i]), .d(dst_t4[i]), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T3; i++) begin : gen_alu_t4

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t4_reg (.q(vs2_m_t5), .d(vs2_m_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t4_tmp[i] = vs2_m_sum_t4[i];
      for (int i=32; i<M_SUM_NUM; i=i+64)
        for (int j=1; j<32; j++) vs2_m_sum_t4_tmp[i+j] = vs2_m_sum_t4[i+j] + vs2_m_sum_t4[i];
      for (int i=64; i<M_SUM_NUM; i=i+64) vs2_m_sum_t4_tmp[i] = vs2_m_sum_t4[i] + vs2_m_sum_t3[i-32];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t4_reg (.q(vs2_m_sum_t5), .d(vs2_m_sum_t4_tmp), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t4_reg (.outdata(alu_ctrl_t5), .outvalid(alu_t5_valid), .outready(alu_t5_ready), 
                                                       .indata(alu_ctrl_t4),  .invalid(alu_t4_valid), .inready(alu_t4_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t4_reg (.q(vs1_t5), .d(vs1_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));
  end

  // | 指令                     | ready 条件                     | 原因                |
  // | ---------------------- | ---------------------------- | ----------------- |
  // | `vcpop` / `VWRXUNARY0` | `vm_last_opr & alu_t0_ready` | 必须等 mask FSM 最后一轮 |
  // | `vwredsum*`            | `wsum_h & alu_t0_ready`      | 必须低半和高半都送入规约树     |
  // | 其它                     | `alu_t0_ready`               | t0 能接收即可消费 uop    |
  if (ALU_STAGE_NUM == 5'd0) begin
    assign rdt_vs2 = data_t1[0];
    assign rdt_vs1 = vs1_rdt_vm_t1;
    assign alu_ctrl = alu_ctrl_t1;
    assign alu_ctrl_valid = alu_t1_valid;
    assign alu_t1_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t1;

    // VM 操作：首轮从 0 开始，后续轮次把上一轮结果作为 pre_res 继续累加。
    assign vs1_rdt_vm_t0 = f_mux_rdt_vm(vs1_t0, rdt_pre_dst, alu_ctrl_t0.uop_funct6, alu_ctrl_t0.vm_state, alu_ctrl_t0.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t0_reg (.q(vs1_rdt_vm_t1), .d(vs1_rdt_vm_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

    // VIOTA：把 mask 前缀和转换为 ALU 第二操作数。
    assign viota_src2_t0 = f_vmsum2src2(vs2_m_sum_t0, vs2_m_t0, alu_ctrl_t0.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t0_reg (.q(viota_src2_t1), .d(viota_src2_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd1) begin
    assign rdt_vs2 = data_t2[0];
    assign rdt_vs1 = vs1_rdt_vm_t2;
    assign alu_ctrl = alu_ctrl_t2;
    assign alu_ctrl_valid = alu_t2_valid;
    assign alu_t2_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t2;

    // VM 操作：根据实际规约树级数，在最终级前一级合并 pre_res。
    assign vs1_rdt_vm_t1 = f_mux_rdt_vm(vs1_t1, rdt_pre_dst, alu_ctrl_t1.uop_funct6, alu_ctrl_t1.vm_state, alu_ctrl_t1.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t1_reg (.q(vs1_rdt_vm_t2), .d(vs1_rdt_vm_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));

    // VIOTA：随当前流水级传递前缀和。
    assign viota_src2_t1 = f_vmsum2src2(vs2_m_sum_t1, vs2_m_t1, alu_ctrl_t1.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t1_reg (.q(viota_src2_t2), .d(viota_src2_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd2) begin
    assign rdt_vs2 = data_t3[0];
    assign rdt_vs1 = vs1_rdt_vm_t3;
    assign alu_ctrl = alu_ctrl_t3;
    assign alu_ctrl_valid = alu_t3_valid;
    assign alu_t3_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t3;

    // VM 操作：根据实际规约树级数，在最终级前一级合并 pre_res。
    assign vs1_rdt_vm_t2 = f_mux_rdt_vm(vs1_t2, rdt_pre_dst, alu_ctrl_t2.uop_funct6, alu_ctrl_t2.vm_state, alu_ctrl_t2.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t2_reg (.q(vs1_rdt_vm_t3), .d(vs1_rdt_vm_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));

    // VIOTA：随当前流水级传递前缀和。
    assign viota_src2_t2 = f_vmsum2src2(vs2_m_sum_t2, vs2_m_t2, alu_ctrl_t2.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t2_reg (.q(viota_src2_t3), .d(viota_src2_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd3) begin
    assign rdt_vs2 = data_t4[0];
    assign rdt_vs1 = vs1_rdt_vm_t4;
    assign alu_ctrl = alu_ctrl_t4;
    assign alu_ctrl_valid = alu_t4_valid;
    assign alu_t4_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t4;

    // VM 操作：根据实际规约树级数，在最终级前一级合并 pre_res。
    assign vs1_rdt_vm_t3 = f_mux_rdt_vm(vs1_t3, rdt_pre_dst, alu_ctrl_t3.uop_funct6, alu_ctrl_t3.vm_state, alu_ctrl_t3.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t3_reg (.q(vs1_rdt_vm_t4), .d(vs1_rdt_vm_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));

    // VIOTA：随当前流水级传递前缀和。
    assign viota_src2_t3 = f_vmsum2src2(vs2_m_sum_t3, vs2_m_t3, alu_ctrl_t3.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t3_reg (.q(viota_src2_t4), .d(viota_src2_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd4) begin
    assign rdt_vs2 = data_t5[0];
    assign rdt_vs1 = vs1_rdt_vm_t5;
    assign alu_ctrl = alu_ctrl_t5;
    assign alu_ctrl_valid = alu_t5_valid;
    assign alu_t5_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t5;

    // VM 操作：根据实际规约树级数，在最终级前一级合并 pre_res。
    assign vs1_rdt_vm_t4 = f_mux_rdt_vm(vs1_t4, rdt_pre_dst, alu_ctrl_t4.uop_funct6, alu_ctrl_t4.vm_state, alu_ctrl_t4.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t4_reg (.q(vs1_rdt_vm_t5), .d(vs1_rdt_vm_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));

    // VIOTA：随当前流水级传递前缀和。
    assign viota_src2_t4 = f_vmsum2src2(vs2_m_sum_t4, vs2_m_t4, alu_ctrl_t4.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t4_reg (.q(viota_src2_t5), .d(viota_src2_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));
  end
 
endgenerate

  assign rdt_vs2_32b = rdt_vs2;
  assign rdt_vs1_32b = rdt_vs1;
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (32)
  ) u_alu_dst_32b (
    .src1   (rdt_vs2_32b),
    .src2   (rdt_vs1_32b),
    .ctrl   (alu_ctrl),
    .dst    (dst_32b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (16)
  ) u_alu_16b (
    .src1   (rdt_vs2_32b[15:0]),
    .src2   (rdt_vs2_32b[31:16]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_vs2_16b)
  );

  assign rdt_vs1_16b = rdt_vs1[1:0];
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (16)
  ) u_alu_dst_16b (
    .src1   (rdt_vs2_16b),
    .src2   (rdt_vs1_16b),
    .ctrl   (alu_ctrl),
    .dst    (dst_16b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_0 (
    .src1   (rdt_vs2_32b[7:0]),
    .src2   (rdt_vs2_32b[15:8]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_src2_8b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_1 (
    .src1   (rdt_vs2_32b[23:16]),
    .src2   (rdt_vs2_32b[31:24]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_src1_8b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_2 (
    .src1   (rdt_src2_8b),
    .src2   (rdt_src1_8b),
    .ctrl   (alu_ctrl),
    .dst    (rdt_vs2_8b)
  );

  assign rdt_vs1_8b = rdt_vs1[0];
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_dst_8b (
    .src1   (rdt_vs2_8b),
    .src2   (rdt_vs1_8b),
    .ctrl   (alu_ctrl),
    .dst    (dst_8b)
  );

  // 最终元素宽度选择：
  // 32-bit 可直接把规约树输出与 vs1[0] 合并；16/8-bit 需要先在 32-bit 内继续规约到单个元素。
  always_comb begin
    case (alu_ctrl.vd_eew)
      EEW32: rdt_dst = {{(ALU_WIDTH-32){1'b0}},dst_32b};
      EEW16: rdt_dst = {{(ALU_WIDTH-16){1'b0}},dst_16b};
      default: rdt_dst = {{(ALU_WIDTH-8){1'b0}},dst_8b};
    endcase
  end

  // pre_dst 作为跨 uop/跨 mask 轮次的累计结果：
  // max/min/and 需要按操作补符号或单位元，其它操作补 0。
  always_comb begin
    case (alu_ctrl.uop_funct6)
      VREDMAXU,
      VREDMAX,
      VREDMINU,
      VREDMIN:
        case (alu_ctrl.vd_eew)
          EEW32: rdt_pre_dst = {(ALU_WIDTH/32){dst_32b}};  //复制广播
          EEW16: rdt_pre_dst = {(ALU_WIDTH/16){dst_16b}};
          default: rdt_pre_dst = {(ALU_WIDTH/8){dst_8b}};
        endcase
      VREDAND:
        case (alu_ctrl.vd_eew)
          EEW32: rdt_pre_dst = {{(ALU_WIDTH-32){1'b1}},dst_32b};
          EEW16: rdt_pre_dst = {{(ALU_WIDTH-16){1'b1}},dst_16b};
          default: rdt_pre_dst = {{(ALU_WIDTH-8){1'b1}},dst_8b};
        endcase
      // VMUNARY0/VWRXUNARY0/VWREDSUM*/VREDSUM/VREDOR/VREDXOR 都按 0 扩展。
      default:
        case (alu_ctrl.vd_eew)
          EEW32: rdt_pre_dst = {{(ALU_WIDTH-32){1'b0}},dst_32b};
          EEW16: rdt_pre_dst = {{(ALU_WIDTH-16){1'b0}},dst_16b};
          default: rdt_pre_dst = {{(ALU_WIDTH-8){1'b0}},dst_8b};
        endcase
    endcase
  end

  // viota_dst：把当前元素之前的 mask 计数与前面累积的 rdt_vs1 相加，生成每个元素的 iota 值。
  assign viota_src1 = f_rdtsum2src1(rdt_vs1, alu_ctrl.vd_eew);
  assign viota_cin  = f_cout2cin(viota_cout, alu_ctrl.vd_eew);
  generate
    for (i=0; i<`VLEN/ALU_WIDTH; i++) begin : gen_viota_res
      adder #(.ADD_NUM(ALU_BYTE), .ADD_WIDTH(8)) u_adder (.a(viota_src1), .b(viota_src2[i]), .cin(viota_cin[i]), .sum(viota_dst[i]), .cout(viota_cout[i]));
    end
  endgenerate

  // 结果打包：
  // viota 写回整条向量；普通 reduction 只把最终标量结果放在低位，其余位清零。
  always_comb begin
  `ifdef TB_SUPPORT
    rdt_res.uop_pc = alu_ctrl.uop_pc;
  `endif
    rdt_res.rob_entry = alu_ctrl.rob_entry;
    case (alu_ctrl.uop_funct6)
      VMUNARY0: rdt_res.w_data = viota_dst;
      default: rdt_res.w_data = {{(`VLEN-ALU_WIDTH){1'b0}}, rdt_dst};
    endcase
    rdt_res.w_valid = rdt_res_valid;
    rdt_res.vsaturate = '0;
  `ifdef ZVE32F_ON
    rdt_res.fpexp = '0;
  `endif
  end

  // 输入 ready：
  // vcpop 需要等 mask FSM 最后一轮；vwredsum* 需要等高半也进入 t0；其它指令跟随 t0 ready。
  // | 指令                     | ready 条件                     | 原因                |
  // | ---------------------- | ---------------------------- | ----------------- |
  // | `vcpop` / `VWRXUNARY0` | `vm_last_opr & alu_t0_ready` | 必须等 mask FSM 最后一轮 |
  // | `vwredsum*`            | `wsum_h & alu_t0_ready`      | 必须低半和高半都送入规约树     |
  // | 其它                     | `alu_t0_ready`               | t0 能接收即可消费 uop    |
  always_comb begin
    case (rdt_uop.uop_funct6)
      VWRXUNARY0:rdt_uop_ready = vm_last_opr & alu_t0_ready;
      VWREDSUMU,
      VWREDSUM:rdt_uop_ready = wsum_h & alu_t0_ready;
      default: rdt_uop_ready = alu_t0_ready; // VMUNARY0
    endcase
  end

  // 输出 valid：
  // viota 每轮都可能产生向量结果；普通 reduction 只在 last_uop_valid 对应的最终 uop 输出。
  always_comb begin
    case (alu_ctrl.uop_funct6)
      VMUNARY0: rdt_res_valid = alu_ctrl_valid;
      default:rdt_res_valid = alu_ctrl.last_uop_valid & alu_ctrl_valid;
    endcase
  end

// ---函数------------------------------------------------------------
  // f_mux_rdt_vm：选择本轮 reduction 的初值。普通 reduction 首 uop 用 vs1[0]，后续用 pre_res；
  // mask 指令首轮从 0 开始，后续轮次累加上一轮结果。
  function [ALU_BYTE-1:0][7:0] f_mux_rdt_vm;
    input [ALU_BYTE-1:0][7:0] vs1_rdt;    // 向量规约的初值 vs1[0]。
    input [ALU_BYTE-1:0][7:0] pre_res;    // 上一轮/上一 uop 的累计结果。
    input FUNCT6_u funct6;                // 指令类型。
    input VM_STATE_e vm_state;            // mask 状态机状态。
    input            first_uop_valid;

    case (funct6)
      VMUNARY0,
      VWRXUNARY0:
        case (vm_state)
          MSK0: f_mux_rdt_vm = '0;
          default: f_mux_rdt_vm = pre_res; // MSKN
        endcase
      // 普通 reduction 首 uop 使用 vs1[0]，后续 uop 使用累计值。
      default: 
        if (first_uop_valid)
          f_mux_rdt_vm = vs1_rdt;
        else
          f_mux_rdt_vm = pre_res;
    endcase
  endfunction

  // 把累计值复制到 viota 每个元素
  // 核心作用
  // viota 要输出每个元素之前的有效 mask bit 个数。这个结果由两部分相加：
  // 当前分段之前的累计值
  // +
  // 当前分段内部的局部前缀和

  // f_rdtsum2src1 提供的是第一部分：
  // 当前分段之前的累计值
  // 它把 sum 复制到每个元素位置，使同一个 32-bit word 里的多个元素都能加上同一个 base。
  function [ALU_BYTE-1:0][7:0] f_rdtsum2src1;
    input [ALU_BYTE-1:0][7:0] sum;
    input EEW_e eew;

    // 把当前累计和复制到每个元素位置，供 viota 的并行加法器使用。
    case (eew)
      EEW32: f_rdtsum2src1 = {(ALU_BYTE/4){sum[3:0]}};
      EEW16: f_rdtsum2src1 = {(ALU_BYTE/2){sum[1:0]}};
      default: f_rdtsum2src1 = {(ALU_BYTE){sum[0]}}; //EEW8
    endcase
  endfunction
  
  //
  function automatic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0] f_vmsum2src2;
    input [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum;  //之前的累计和
    input [`VLENB-1:0]  vs2_m;                            //当前分段的mask bit
    input EEW_e eew;

    localparam MIN_ = (10'(`VSTART_WIDTH) < 10'd8) ? 8-`VSTART_WIDTH : 0;
    localparam MAX_ = (10'(`VSTART_WIDTH) < 10'd8) ? `VSTART_WIDTH : 8;
    logic [`VLENB-1:0][`VSTART_WIDTH-1:0] vs2_m_src2;  
    logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE/4-1:0][31:0] vs2_m_src2_32b;
    logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE/2-1:0][15:0] vs2_m_src2_16b;
    logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]    vs2_m_src2_8b;
    begin
      // 先得到每个 mask bit 之前的分组内前缀和，再按 EEW 打包成 ALU 的 src2。
      for (int i= 0; i<M_SUM_NUM; i++) begin 
          vs2_m_src2[i*VIOTA_STRIDE] = vs2_m_sum[i]; 
        // element0 prefix = base
        // element1 prefix = base + m0
        // element2 prefix = base + m0 + m1
        // element3 prefix = base + m0 + m1 + m2
        for (int j=1; j<VIOTA_STRIDE; j++) begin
          vs2_m_src2[i*VIOTA_STRIDE+j] = vs2_m_src2[i*VIOTA_STRIDE+j-1] + vs2_m[i*VIOTA_STRIDE+j-1]; 
        end
      end

      for (int i= 0; i<`VLEN/ALU_WIDTH; i++)
        for (int j=0; j<ALU_BYTE/4; j++)
          vs2_m_src2_32b[i][j] = {{(32-`VSTART_WIDTH){1'b0}}, {vs2_m_src2[i*ALU_BYTE/4+j][`VSTART_WIDTH-1:0]}};

      for (int i= 0; i<`VLEN/ALU_WIDTH; i++)
        for (int j=0; j<ALU_BYTE/2; j++)
          vs2_m_src2_16b[i][j] = {{(16-`VSTART_WIDTH){1'b0}}, {vs2_m_src2[i*ALU_BYTE/2+j][`VSTART_WIDTH-1:0]}};

      for (int i= 0; i<`VLEN/ALU_WIDTH; i++)
        for (int j=0; j<ALU_BYTE; j++)
          vs2_m_src2_8b[i][j] = {{(MIN_){1'b0}}, {vs2_m_src2[i*ALU_BYTE+j][MAX_-1:0]}};

      case (eew)
        EEW32: f_vmsum2src2 = vs2_m_src2_32b;
        EEW16: f_vmsum2src2 = vs2_m_src2_16b;
        default: f_vmsum2src2 = vs2_m_src2_8b; //EEW8
      endcase
    end
  endfunction

  //控制 byte adder 的进位边界
  function [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0] f_cout2cin;
    input [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0] cout;
    input EEW_e eew;

    // viota 的加法也要遵守元素边界：EEW32 每 4 byte 串进位，EEW16 每 2 byte 串进位，EEW8 不串进位。
    for (int i=0; i<`VLEN/ALU_WIDTH; i++) begin
      f_cout2cin[i][0] = 1'b0;
      case (eew)
        EEW32: for (int j=1; j<ALU_BYTE; j++) f_cout2cin[i][j] = j%4==0 ? 1'b0 : cout[i][j-1];
        EEW16: for (int j=1; j<ALU_BYTE; j++) f_cout2cin[i][j] = j%2==0 ? 1'b0 : cout[i][j-1];
        default: for (int j=1; j<ALU_BYTE; j++) f_cout2cin[i][j] = 1'b0; //EEW8
      endcase
    end
  endfunction

endmodule
