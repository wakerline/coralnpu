
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

`ifdef ZVE32F_ON
//------------------------------------------------------------------------------
// rvv_backend_freduction
//------------------------------------------------------------------------------
// 功能定位：
// 1. 浮点规约执行单元，仅在 `ZVE32F_ON` 打开时编译，位于 PMT/RDT 执行路径中。
// 2. 处理 VFREDOSUM/VFREDUSUM/VFREDMAX/VFREDMIN 等 FP32 reduction 指令。
// 3. 本模块使用单个 FP32 运算子单元逐元素累积：sum 走 `fpnew_fma_multi` 的 ADD，
//    min/max 走 `fpnew_noncomp` 的 MINMAX。
// 4. `uop.vs2_type` 标记每个 lane 是否为 BODY_ACTIVE；非 active 元素不送 fpnew，
//    而是通过 mask_cur 路径保持当前累积值。
// 5. 只有 last_uop_valid 且所有 lane 处理完毕时，才向 ROB 输出最终标量规约结果。
//
// 宏阅读提示：
// - `WORD_WIDTH`=32，本模块固定按 FP32 元素规约。
// - `CTRW=$clog2(VLEN/WORD_WIDTH)`，用于遍历 `VLENW` 个 FP32 lane。

// active FP32 lane：
//   送入 fpnew ADD / MINMAX
//   大约 3 cycle 后返回 sub_result

// inactive / masked / tail lane：
//   不送入 fpnew
//   mask_cur 直接保持当前累积值
//   大约 1 cycle 推进

// 最终 ROB 写回：
//   只有 last_uop_valid = 1
//   且所有 FP32 lane 处理完
//   且 result_ready = 1
//   才真正完成
// 总延迟 ≈ active_lane_num × 3 + inactive_lane_num × 1

// |   Cycle | 行为                            | 说明                                       |
// | ------: | ------------------------------- | ---------------------------------------- |
// |      C0 | 接收 uop，送入 lane0             | `sub_vs1 = vs1[31:0]`，`sub_vs2 = vs2[0]` |
// |   C1-C2 | fpnew ADD 处理中                 | `sub_busy = 1`                           |
// |      C3 | lane0 结果返回，同时送入 lane1    | `acc1` 作为下一轮 `sub_vs1`                   |
// |   C4-C5 | lane1 处理中                     |                                          |
// |      C6 | lane1 结果返回，同时送入 lane2    | 得到 `acc2`                                |
// |   C7-C8 | lane2 处理中                     |                                          |
// |      C9 | lane2 结果返回，同时送入 lane3    | 得到 `acc3`                                |
// | C10-C11 | lane3 处理中                     |                                          |
// |     C12 | lane3 结果返回，`result_valid=1` | `w_data[31:0] = acc4`                    |

// lane1 = inactive
// | Cycle | 行为                          | 说明                            |
// | ----: | --------------------------- | ----------------------------- |
// |    C0 | 送入 lane0 ADD                | active                        |
// |    C3 | lane0 结果返回，处理 lane1         | lane1 是 inactive，走 `mask_cur` |
// |    C4 | lane1 伪结果返回，送入 lane2 ADD    | `acc` 保持不变                    |
// |    C7 | lane2 结果返回，送入 lane3 ADD     | active                        |
// |   C10 | lane3 结果返回，`result_valid=1` | 最终结果写 ROB                     |

// 长向量，两个uop拼接
// | Cycle | 行为                        | 是否写 ROB |
// | ----: | ------------------------- | ------- |
// |    C0 | uop0 lane0 输入             | 否       |
// |    C3 | uop0 lane1 输入             | 否       |
// |    C6 | uop0 lane2 输入             | 否       |
// |    C9 | uop0 lane3 输入             | 否       |
// |   C12 | uop0 完成，同时 uop1 lane0 可输入 | 否       |
// |   C15 | uop1 lane1 输入             | 否       |
// |   C18 | uop1 lane2 输入             | 否       |
// |   C21 | uop1 lane3 输入             | 否       |
// |   C24 | uop1 完成，`result_valid=1`  | 是       |


module rvv_backend_freduction(
  clk,
  rst_n,
  uop_valid,
  uop_ready,
  uop,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);
  localparam IDLE = 1'b0;
  localparam MATH = 1'b1;
  localparam PipeLine = 3;
  localparam CTRW = $clog2(`VLEN/`WORD_WIDTH);  
  // 全局时钟/复位。
  input   logic     clk;
  input   logic     rst_n;

  // PMT/RDT RS 到 freduction 的输入握手和 uop 内容。
  input   logic       uop_valid;
  output  logic       uop_ready;
  input  PMT_RDT_RS_t uop;

  // 规约结果输出到 ROB 写回通路。
  output  logic       result_valid;
  output  PU2ROB_t    result;
  input   logic       result_ready;
  
  // RVV trap/flush，清除内部累积状态和 fpnew 子单元。
  input   logic                     trap_flush_rvv;


  // 内部状态和控制信号。
  
  logic         set_busy;
  logic         clear_busy;
  logic         next_state;
  logic [`FP_RDT_TAG_WIDTH-1:0] tag_i;
  logic [`FP_RDT_TAG_WIDTH-1:0] rdtadd_tag_o;
  logic [`FP_RDT_TAG_WIDTH-1:0] rdtcmp_tag_o;

  logic         sub_result_vld;
  logic         sub_result_rdy;
  logic  [31:0] sub_result;
  logic  [31:0] sub_vs1;
  logic  [31:0] sub_vs2;
  logic  [31:0] vs2_data_sel;
  logic         result_last_uop; // 当前返回结果是否对应最后一个规约 uop。
  RVFEXP_t      sub_fexcp;
  RVFEXP_t      unused_fexcp;
  fpnew_pkg::status_t sub_status;


  logic         sub_rdtadd_in_vld;
  logic         sub_rdtadd_in_rdy;
  logic         sub_rdtadd_result_vld;
  logic  [31:0] sub_rdtadd_result;
  fpnew_pkg::status_t sub_rdtadd_status;
  

  logic         sub_rdtcmp_in_vld;
  logic         sub_rdtcmp_in_rdy;
  logic         sub_rdtcmp_result_vld;
  logic  [31:0] sub_rdtcmp_result;

  // 子单元 busy 由 sub_busy 统一抽象，不分别使用 add/cmp busy。
  logic         sub_busy;

  fpnew_pkg::roundmode_e sub_add_rnd;
  fpnew_pkg::roundmode_e sub_cmp_rnd;
  fpnew_pkg::roundmode_e sub_rnd_reg;
  fpnew_pkg::roundmode_e sub_rnd;
  fpnew_pkg::roundmode_e sub_rnd_in;
  fpnew_pkg::status_t sub_rdtcmp_status;


  logic  [CTRW-1:0] vld_ctr;
  logic             busy;
  logic             state;
  logic             add_in_vld_reg;
  logic             cmp_in_vld_reg;
  logic      [31:0] vs1_reg;
  logic [`VLEN-1:0] vs2_reg;
  logic [`FP_RDT_TAG_WIDTH-1:0] tag_reg;
  BYTE_TYPE_e [`VLENW-1:0]      vs2_type_reg;
  fpnew_pkg::status_t           fpexp_reg;
  logic                         sub_in_accept;
  logic                         mask_cur;
  logic                         mask_cur_reg;
  logic [`FP_RDT_TAG_WIDTH-1:0] mask_tag_reg;
  logic                 [31:0]  vs1_in_reg;

  // 握手与输入选择。
  // uop_ready 表示当前可接收新规约 uop：空闲，或上一轮最后元素/最终结果已被消费。
  assign uop_ready         =  !busy ||
                               busy && !sub_busy && vld_ctr == '0||
                               busy &&  sub_busy && sub_result_vld && sub_result_rdy && vld_ctr == '0;
  //子操作结果ready
  //只有最终输出 ROB 时才受 result_ready 反压。
  assign sub_result_rdy    =(vld_ctr == '0 && result_last_uop)? result_ready: 1'b1;
  // ari_funct6[2] 选择规约类型：0 为 sum/add，1 为 min/max compare。
  assign sub_cmp_rnd       = uop.uop_funct6.ari_funct6[1]? fpnew_pkg::RTZ: fpnew_pkg::RNE;
  // BODY_ACTIVE 元素才送入 fpnew add 路径；被 mask/tail 跳过的元素不发起运算。
  // 用于刚接收新 uop 的第一个 lane。|| 用于后续 lane
  assign sub_rdtadd_in_vld = uop_valid && !uop.uop_funct6.ari_funct6[2] && (uop.vs2_type[0] == BODY_ACTIVE) && !(add_in_vld_reg | cmp_in_vld_reg) && sub_rdtadd_in_rdy ||
                                                         add_in_vld_reg && (vs2_type_reg[vld_ctr] == BODY_ACTIVE) && sub_rdtadd_in_rdy;
  // min/max 规约使用 noncomp MINMAX 路径。
  // 用于刚接收新 uop 的第一个 lane。|| 用于后续 lane
  assign sub_rdtcmp_in_vld = uop_valid &&  uop.uop_funct6.ari_funct6[2] && (uop.vs2_type[0] == BODY_ACTIVE) && !(add_in_vld_reg | cmp_in_vld_reg) && sub_rdtcmp_in_rdy ||
                                                         cmp_in_vld_reg && (vs2_type_reg[vld_ctr] == BODY_ACTIVE) && sub_rdtcmp_in_rdy;
  //round 模式
  assign sub_rnd           = uop.uop_funct6.ari_funct6[2]? sub_cmp_rnd: sub_add_rnd;
  assign sub_rnd_in        =(uop_valid && uop_ready)? sub_rnd: sub_rnd_reg;
  // mask_cur 表示当前 lane 不参与规约，输出保持累积值并继续推进计数。
  assign mask_cur          = uop_valid && (uop.vs2_type[0] != BODY_ACTIVE) && !(add_in_vld_reg | cmp_in_vld_reg) || 
                            (add_in_vld_reg | cmp_in_vld_reg) && (vs2_type_reg[vld_ctr] != BODY_ACTIVE);
  // 子单元正在忙时，只有其结果被消费后才允许喂入下一元素。
  assign sub_rdtadd_in_rdy = sub_busy? sub_result_vld && sub_result_rdy: 1'b1;
  assign sub_rdtcmp_in_rdy = sub_busy? sub_result_vld && sub_result_rdy: 1'b1;
  // 三种推进条件：add 输入被接收、cmp 输入被接收、或当前 lane 被 mask 跳过。
  assign sub_in_accept     = sub_rdtadd_in_vld && sub_rdtadd_in_rdy && !trap_flush_rvv ||
                             sub_rdtcmp_in_vld && sub_rdtcmp_in_rdy && !trap_flush_rvv ||
                             mask_cur && (!sub_busy || sub_busy && sub_result_vld && sub_result_rdy) && !trap_flush_rvv;
  // 如果本周期接收新 uop，则 tag 来自新 uop。
  // 否则 tag 使用之前锁存的 tag_reg。
`ifdef TB_SUPPORT
  assign tag_i             = (uop_valid && uop_ready)? {uop.last_uop_valid, uop.uop_pc, uop.rob_entry}: tag_reg;
`else
  assign tag_i             = (uop_valid && uop_ready)? {uop.last_uop_valid, uop.rob_entry}: tag_reg;
`endif

  always_comb
  begin
    // 根据 add/cmp/mask 三条返回路径组装子结果，再在最后一个 uop 的最后一个 lane 输出 ROB 结果。
    sub_result_vld    = sub_rdtcmp_result_vld || sub_rdtadd_result_vld || mask_cur_reg;
    result.vsaturate  = '0;  //浮点规约不产生定点饱和。
    result.fpexp      = {{(`VLENB-1){unused_fexcp}}, sub_fexcp};
    if(mask_cur_reg) begin
      // mask/tail 跳过元素：子结果直接沿用进入该 lane 前的累积值。
      sub_result        = vs1_in_reg;
      sub_status        = '0;

      // 同时恢复对应 uop tag，保证 ROB entry 与 last_uop_valid 正确。
    `ifdef TB_SUPPORT
      result.uop_pc     = mask_tag_reg[`ROB_DEPTH_WIDTH+:`PC_WIDTH];
      result_last_uop   = mask_tag_reg[`PC_WIDTH+`ROB_DEPTH_WIDTH];
    `else
      result_last_uop   = mask_tag_reg[`ROB_DEPTH_WIDTH];
    `endif
      result.rob_entry  = mask_tag_reg[0+:`ROB_DEPTH_WIDTH];
      result.w_data     = {(`VLEN-32)'('b0), vs1_in_reg};
    end
    else begin
      // fpnew 返回路径：cmp 优先，否则使用 add 返回。
      // 正常情况下，由于同一 uop 只会走 add 或 cmp，理论上不会同时 valid。
      sub_result        = sub_rdtcmp_result_vld? sub_rdtcmp_result: sub_rdtadd_result;
      sub_status        = sub_rdtcmp_result_vld? sub_rdtcmp_status: sub_rdtadd_status;

      // 从 fpnew tag 恢复 ROB entry 和 last_uop_valid。
    `ifdef TB_SUPPORT
      result.uop_pc     = sub_rdtcmp_result_vld? rdtcmp_tag_o[`ROB_DEPTH_WIDTH+:`PC_WIDTH]:rdtadd_tag_o[`ROB_DEPTH_WIDTH+:`PC_WIDTH];;
      result_last_uop   = sub_rdtcmp_result_vld? rdtcmp_tag_o[`PC_WIDTH+`ROB_DEPTH_WIDTH]:rdtadd_tag_o[`PC_WIDTH+`ROB_DEPTH_WIDTH];;
    `else
      result_last_uop   = sub_rdtcmp_result_vld? rdtcmp_tag_o[`ROB_DEPTH_WIDTH]:rdtadd_tag_o[`ROB_DEPTH_WIDTH];
    `endif
      result.rob_entry  = sub_rdtcmp_result_vld? rdtcmp_tag_o[0+:`ROB_DEPTH_WIDTH]:rdtadd_tag_o[0+:`ROB_DEPTH_WIDTH];
      result.w_data     = {(`VLEN-32)'('b0), sub_result};
    end
    result_valid      = result_last_uop && sub_result_vld && vld_ctr == '0;
    result.w_valid    = result_valid;
  end

  assign unused_fexcp = '0;

  // 规约过程中每个元素产生的浮点异常要 OR 累积，最终写入 fcsr/fpexp。
  assign sub_fexcp.nv = sub_status.NV |fpexp_reg.NV;
  assign sub_fexcp.dz = sub_status.DZ |fpexp_reg.DZ;
  assign sub_fexcp.of = sub_status.OF |fpexp_reg.OF;
  assign sub_fexcp.uf = sub_status.UF |fpexp_reg.UF;
  assign sub_fexcp.nx = sub_status.NX |fpexp_reg.NX;

  assign vs2_data_sel = vs2_reg[(vld_ctr*32)+:32];

  // 加法规约使用 frm；min/max 规约的比较控制在 sub_cmp_rnd 中固定编码。
  always_comb
  begin
    case(uop.frm)
      FRNE:   sub_add_rnd=fpnew_pkg::RNE;
      FRTZ:   sub_add_rnd=fpnew_pkg::RTZ;
      FRDN:   sub_add_rnd=fpnew_pkg::RDN;
      FRUP:   sub_add_rnd=fpnew_pkg::RUP;
      FRMM:   sub_add_rnd=fpnew_pkg::RMM;
      default:sub_add_rnd=fpnew_pkg::DYN;
    endcase
  end

  always_comb
  begin
    // 状态机数据通路：
    // - IDLE 接收新 uop，初始累积值来自 vs1[31:0]。
    // - MATH 逐 lane 消费 vs2，sub_result 回来后作为下一轮 sub_vs1。
    // - 最后一个 uop 的最后一个 lane 完成并被 ROB 接收后回到 IDLE。
    set_busy       = '0;
    clear_busy     = '0;
    next_state     = state;
    sub_vs1        = sub_result;    //sub_vs1 = 上一 lane 返回结果
    sub_vs2        = vs2_data_sel;  //sub_vs2 = 当前 vld_ctr 指向的 vs2 lane
    case(state)
      MATH: begin
        if(trap_flush_rvv) begin
          clear_busy  = 1'b1;
          next_state  = IDLE;
        end
        else if(sub_result_vld && sub_result_rdy) begin  //如果当前子结果已经返回并被消费。
          if(vld_ctr == '0) begin  //vld_ctr == 0 有特殊含义：说明上一轮已经处理完最后一个 lane，计数器回绕到 0。
            if(uop_valid && !trap_flush_rvv) begin  //此时有新 uop
              sub_vs2     = uop.vs2_data[31:0];
              if(result_last_uop)  //刚完成的是 last uop, 取最新输入
                sub_vs1     = uop.vs1_data[31:0];
            end
            else begin  //说明上一条 reduction 还没有结束
              if(result_last_uop) begin  //如果没有新 uop，并且刚完成的是 last uop，则回到 IDLE。
                clear_busy  = 1'b1;
                next_state  = IDLE;
              end
            end
          end
        end
        else begin
          //如果 fpnew 结果还没回来：sub_vs1 使用已保存的累积值 vs1_reg
          sub_vs1         = vs1_reg;
          if(uop_valid && (vld_ctr == '0))
            sub_vs2       = uop.vs2_data[31:0];
        end
      end
      default: begin // IDLE。
        if(uop_valid && uop_ready && !trap_flush_rvv) begin
          set_busy        = 1'b1;
          next_state      = MATH;
          sub_vs1         = uop.vs1_data[31:0];
          sub_vs2         = uop.vs2_data[31:0];
        end
      end
    endcase
  end

  always @(posedge clk or negedge rst_n)
  begin
    if(!rst_n) begin
      vld_ctr     <= '0;
      busy        <= '0;
      state       <= IDLE;
      add_in_vld_reg  <= '0;
      cmp_in_vld_reg  <= '0;
      vs1_reg     <= '0;
      vs2_reg     <= '0;
      tag_reg     <= '0;
      vs2_type_reg<= '0;
      fpexp_reg   <= '0;
      sub_rnd_reg <= fpnew_pkg::roundmode_e'('0);
      mask_cur_reg<= '0;
      mask_tag_reg<= '0;
      vs1_in_reg  <= '0;
      sub_busy <= '0;
    end
    else begin
      state <= next_state;
      if(set_busy) busy <= 1'b1;
      else if(clear_busy) busy <= 1'b0;
      if(trap_flush_rvv) begin
        // flush 清掉待处理类型，避免旧规约在 flush 后继续推进。
        add_in_vld_reg <= 1'b0;
        cmp_in_vld_reg <= 1'b0;
      end
      else if(uop_valid && uop_ready) begin
        // 新 uop 被接收时锁存本轮是 add 规约还是 min/max 规约。
        add_in_vld_reg <= !uop.uop_funct6.ari_funct6[2];
        cmp_in_vld_reg <=  uop.uop_funct6.ari_funct6[2];
        sub_rnd_reg <= sub_rnd;
      end
      else if(sub_in_accept && (vld_ctr == '1)) begin  //当最后一个 lane 被接收后，清掉当前 uop 类型标志
        add_in_vld_reg <= 1'b0;
        cmp_in_vld_reg <= 1'b0;
      end
      if(trap_flush_rvv) begin
        // 累积值和异常状态在 flush 时清空。
        vs1_reg   <= '0;
        fpexp_reg <= '0;
      end
      else if(sub_result_vld && sub_result_rdy) begin
        // 子结果成为下一元素的累积输入；异常状态持续 OR 累积。
        vs1_reg <= sub_result;
        if(vld_ctr == '0 && result_last_uop)
          fpexp_reg <= '0;
        else
          fpexp_reg <= sub_status | fpexp_reg;  //否则继续 OR 累积异常。
      end
      if(uop_valid && uop_ready && !trap_flush_rvv) begin
        // 锁存整条 vs2 和每个 lane 的 BODY_ACTIVE 信息，后续用 vld_ctr 逐 lane 遍历。
        vs2_reg <= uop.vs2_data;
        for(int i=0;i<`VLENW;i++) begin
          vs2_type_reg[i] <= uop.vs2_type[i*4];  //每个 FP32 lane 对应 4 byte，取该 lane 第一个 byte 的 type 作为整个 FP32 元素是否 active。
        end
      `ifdef TB_SUPPORT
        tag_reg <= {uop.last_uop_valid, uop.uop_pc, uop.rob_entry};
      `else
        tag_reg <= {uop.last_uop_valid, uop.rob_entry};
      `endif
      end
      if(trap_flush_rvv) begin 
        // 清除 lane 计数和子单元忙状态。
        vld_ctr       <= '0;
        mask_cur_reg  <= 1'b0;
        sub_busy      <= 1'b0;
      end
      else if(sub_in_accept) begin
        // 当前 lane 已经被 fpnew 接收或被 mask 跳过，推进到下一 lane。
        vld_ctr       <= vld_ctr + 'b1;
        mask_cur_reg  <= mask_cur;
        sub_busy      <= 1'b1;
      end
      else if(sub_result_vld && sub_result_rdy) begin  //子结果被消费后，清 busy
        mask_cur_reg  <= 1'b0;
        sub_busy      <= 1'b0;
      end
      if(mask_cur && !trap_flush_rvv) begin
        // mask/tail 跳过路径也要保存 tag 和当前累积值，便于下周期伪造一个子结果。
        mask_tag_reg  <= tag_i;
        vs1_in_reg    <= sub_vs1;
      end
    end
  end

  fpnew_fma_multi #(
    .FpFmtConfig(5'b10000),
    .NumPipeRegs(PipeLine),
    .PipeConfig(fpnew_pkg::DISTRIBUTED),
    .TagType(logic [`FP_RDT_TAG_WIDTH-1:0])
    )
  rdtadd (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    // 输入操作数和控制信息，使用 ADD 做 sum reduction。
    .operands_i            ({sub_vs1, sub_vs2, 32'b0}), // 两个有效 FP32 操作数。
    .is_boxed_i            ('1), // FP32 操作数视为已 NaN-box。
    .rnd_mode_i            (sub_rnd_in),
    .op_i                  (fpnew_pkg::ADD),
    .op_mod_i              (1'b0),
    .src_fmt_i             (fpnew_pkg::FP32),
    .src2_fmt_i            (fpnew_pkg::FP32),
    .dst_fmt_i             (fpnew_pkg::FP32),
    .tag_i                 (tag_i),
    .mask_i                ('0),
    .aux_i                 ('0),
    // 输入握手。
    .in_valid_i            (sub_rdtadd_in_vld),
    .in_ready_o            (),
    .flush_i               (trap_flush_rvv),
    // 输出累加结果、异常状态和 tag。
    .result_o              (sub_rdtadd_result),
    .status_o              (sub_rdtadd_status),
    .extension_bit_o       (),
    .tag_o                 (rdtadd_tag_o),
    .mask_o                (),
    .aux_o                 (),
    // 输出握手。
    .out_valid_o           (sub_rdtadd_result_vld),
    .out_ready_i           (sub_result_rdy),
    // fpnew busy 未使用，外层用 sub_busy 限流。
    .busy_o                (),
    // 外部寄存器使能覆盖未使用。
    .reg_ena_i             ('0),
    // early valid 未使用。
    .early_out_valid_o     ()
  );


  fpnew_noncomp #(
    .FpFormat(fpnew_pkg::FP32),
    .NumPipeRegs(PipeLine),
    .PipeConfig(fpnew_pkg::DISTRIBUTED),
    .TagType(logic [`FP_RDT_TAG_WIDTH-1:0])
  )
  rdtcmp (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    // 输入操作数和控制信息，使用 MINMAX 做 min/max reduction。
    .operands_i          ({sub_vs2, sub_vs1}), // 两个 FP32 操作数。
    .is_boxed_i          ('1), // FP32 操作数视为已 NaN-box。3
    .rnd_mode_i          (sub_rnd_in),
    .op_i                (fpnew_pkg::MINMAX),
    .op_mod_i            (1'b0),
    .tag_i               (tag_i),
    .mask_i              ('0),
    .aux_i               ('0),
    // 输入握手。
    .in_valid_i          (sub_rdtcmp_in_vld),
    .in_ready_o          (),
    .flush_i             (trap_flush_rvv),
    // 输出 min/max 结果、异常状态和 tag。
    .result_o            (sub_rdtcmp_result),
    .status_o            (sub_rdtcmp_status),
    .extension_bit_o     (),
    .class_mask_o        (),
    .is_class_o          (),
    .tag_o               (rdtcmp_tag_o),
    .mask_o              (),
    .aux_o               (),
    // 输出握手。
    .out_valid_o         (sub_rdtcmp_result_vld),
    .out_ready_i         (sub_result_rdy),
    // fpnew busy 未使用。
    .busy_o              (),
    // 外部寄存器使能覆盖未使用。
    .reg_ena_i           ('0),
    // early valid 未使用。
    .early_out_valid_o   ()
  );

endmodule
`endif // ZVE32F_ON
