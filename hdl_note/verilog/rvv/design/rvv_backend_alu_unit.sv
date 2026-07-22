
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
// 功能说明：
// 1. `rvv_backend_alu_unit` 是单条 ALU lane 的执行核心，输入来自 ALU RS，输出写回 ROB。
// 2. p0 组合执行层并行实例化 add/sub、shift、mask、other 四类子单元；其中 shift/mask/other 可以直接形成 `PU2ROB_t`。
// 3. add/sub 类先产生 `PIPE_DATA_t` 中间结果，再进入 p1，由 `rvv_backend_alu_unit_execution_p1` 完成最终写回格式整理。
// 4. 当 p1 已有结果且 p0 又产生新结果时，本模块优先把 p1 结果送 ROB，并根据 `result_ready` 决定 p1 是否前进和 RS 是否 pop。
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_alu_unit` -> RVV 后端 EX 执行层内部的一条 ALU lane。
// - 接口与数据流：
//   * 输入：`alu_uop_valid/alu_uop` 来自 ALU RS，`alu_uop` 已包含源操作数、mask、ROB entry、funct、EEW、vstart/vl 等信息。
//   * 处理：p0 子单元并行判断自己是否支持当前 funct；有效结果按优先级选择，add/sub 进入 p1，其它类可直接输出。
//   * 输出：`result_valid/result` 写 ROB；`pop_rs` 表示本 lane 本周期真正接收了 RS 中的 uop。
//   * 控制：`result_ready` 为后级写回口 ready；`trap_flush_rvv` 清除 p1 valid，防止刷新后的旧结果提交。
// - 调用关系：上层 rvv_backend_alu；下层 rvv_backend_alu_unit_addsub(u_alu_addsub), rvv_backend_alu_unit_execution_p1(u_alu_p1), rvv_backend_alu_unit_mask(u_alu_mask), rvv_backend_alu_unit_other(u_alu_other), rvv_backend_alu_unit_shift(u_alu_shift)
// - 端口摘要：输入 clk, rst_n, alu_uop_valid, alu_uop, result_ready, trap_flush_rvv；输出 pop_rs, result_valid, result。
// - define/参数阅读重点：
//   * `CMP_SUPPORT`：参数，lane0 置 1 时 add/sub 路径支持比较类指令；其它 lane 默认 0。
//   * `PIPE_DATA_t`：p0 到 p1 的中间结果格式，保存 w_data/w_valid/rob_entry/vsat 等。
//   * `PU2ROB_t`：最终送 ROB 的写回格式。
// - 不确定/条件宏提示：
//   * `TB_SUPPORT` 打开时会在中间/最终结果中保留 `uop_pc`，便于仿真定位。
// - 阅读建议：先看四个 p0 子单元谁会置 valid，再看 p1 valid 使能和最终提交仲裁。
// 详细中文注释（自动梳理）END

module rvv_backend_alu_unit
(
  clk,
  rst_n,
  alu_uop_valid,
  alu_uop,
  pop_rs,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);

  // 是否允许本 ALU lane 执行比较类指令。顶层 `rvv_backend_alu` 只给 lane0 打开该参数。
  parameter               CMP_SUPPORT = 1'b0;
//
// 接口信号
//
  // 全局时钟/复位。
  input   logic           clk;
  input   logic           rst_n;

  // ALU RS 握手：valid 表示 RS 出口有 uop；pop_rs 表示本 unit 接收该 uop，RS 可以弹出。
  input   logic           alu_uop_valid;
  input   ALU_RS_t        alu_uop;
  output  logic           pop_rs;

  // ALU 写回 ROB 的结果通道。后级 `result_ready=0` 时，本 unit 不能丢失已产生的结果。
  output  logic           result_valid;
  output  PU2ROB_t        result;
  input   logic           result_ready;

  // trap flush：清除本 unit 内部 p1 阶段尚未提交的 valid。
  input   logic           trap_flush_rvv; 

//
// 内部信号
//   
  // p0 子单元结果。add/sub 结果是 PIPE_DATA_t，需要进入 p1；其它子单元已经形成 PU2ROB_t。
  logic                   result_valid_addsub_p0;
  PIPE_DATA_t             result_addsub_p0;
  logic                   result_valid_shift_p0;
  PU2ROB_t                result_shift_p0;
  logic                   result_valid_mask_p0;
  PU2ROB_t                result_mask_p0;
  logic                   result_valid_other_p0;
  PU2ROB_t                result_other_p0;
  // p1 最终结果。
  logic                   result_valid_p1;
  PU2ROB_t                result_p1;
  // p0 -> p1 流水寄存控制。
  logic                   alu_uop_valid_p1_en; // p1 valid 寄存器写使能。
  logic                   alu_uop_valid_p1_in; // 写入 p1 valid 的新值。
  logic                   alu_uop_valid_p1;    // p1 当前是否持有有效 add/sub 类中间结果。
  logic                   alu_uop_p1_en;       // p1 payload 寄存器写使能。
  PIPE_DATA_t             alu_uop_p1_in;       // 写入 p1 的中间结果。
  PIPE_DATA_t             alu_uop_p1;          // p1 持有的中间结果。

//
// 子模块实例
//
// 同一个 uop 同时送入 addsub / shift / mask / other
// 每个子单元内部判断自己是否支持该 funct
// 只有匹配的子单元拉高 result_valid_xxx_p0

  // add/sub/compare 类 p0：结果需要再经过 p1 做最终整理。
  // 操作判断，8位加减
  rvv_backend_alu_unit_addsub #(
    .CMP_SUPPORT          (CMP_SUPPORT)
  ) u_alu_addsub (
    .alu_uop_valid        (alu_uop_valid),
    .alu_uop              (alu_uop),
    .result_valid         (result_valid_addsub_p0),  //输出结果
    .result               (result_addsub_p0)         //输出结果
  );

  // shift 类 p0：可直接生成 ROB 写回结果。
  rvv_backend_alu_unit_shift 
  u_alu_shift (
    .alu_uop_valid        (alu_uop_valid),
    .alu_uop              (alu_uop),
    .result_valid         (result_valid_shift_p0),   //输出结果
    .result               (result_shift_p0)          //输出结果
  );
  
  // mask 类 p0：处理 mask 逻辑、mask 生成等操作，可直接写 ROB。
  rvv_backend_alu_unit_mask 
  u_alu_mask ( 
    .alu_uop_valid        (alu_uop_valid),
    .alu_uop              (alu_uop),
    .result_valid         (result_valid_mask_p0),    //输出结果
    .result               (result_mask_p0)           //输出结果
  );

  // other 类 p0：放置不归入 add/sub、shift、mask 的其它 ALU 操作。
  rvv_backend_alu_unit_other 
  u_alu_other (
    .alu_uop_valid        (alu_uop_valid),
    .alu_uop              (alu_uop),
    .result_valid         (result_valid_other_p0),   //输出结果
    .result               (result_other_p0)          //输出结果
  );

  // p0 -> p1 流水控制。
  // case 输入含义：
  //   bit1 = p1 当前已有有效结果；
  //   bit0 = p0 本周期任一子单元产生有效结果。
  // add/sub 的 p0 结果不会直接送 ROB，必须进入 p1；shift/mask/other 若后级 ready，可直接提交并 pop RS。

  // 结果仲裁：
  // p1 结果优先
  // p0 直出结果次之
  // p1 结果拥有最高写回优先级，因为它是上一拍已经进入流水的旧结果，不能被当前 p0 新结果越过。
  always_comb begin
    case({result_valid_p1,(result_valid_addsub_p0|result_valid_shift_p0|result_valid_mask_p0|result_valid_other_p0)})
      2'b01: begin
        // p1 空、p0 有新结果：只有 add/sub 结果需要写入 p1。
        // 如果 p0 是 add/sub：
        //   p1 valid 写 1
        //   p1 payload 写入 result_addsub_p0
        // 如果 p0 是 shift/mask/other：
        //   不写 p1
        //   结果直接输出 ROB
        alu_uop_valid_p1_en = result_valid_addsub_p0;  //p0有效使能写入p1
        alu_uop_valid_p1_in = 1'b1;
        alu_uop_p1_en       = result_valid_addsub_p0;  //p0数据写入p1寄存器
      end
      2'b11: begin
        // p1 有旧结果、p0 也有新结果：优先提交 p1；只有后级 ready 时 p1 payload 才能接收 p0 新结果。
        // result_ready=1：
        //   p1 旧结果本周期输出
        //   p1 payload 被 p0 新结果覆盖，可以是4个运算中任意一个
        //   p1 valid 保持 1
        
        // result_ready=0：
        //   p1 旧结果不能输出
        //   p1 payload 不更新
        //   p1 valid 保持 1
        //   当前输入 uop 不 pop，下一周期重试
        alu_uop_valid_p1_en = 1'b0;  //为什么？是因为p1有旧结果，原p1 valid=1, 所以保持就行
        alu_uop_valid_p1_in = 1'b1;
        alu_uop_p1_en       = result_ready;  //如果 result_ready=1，说明 p1 旧结果可以被后级接收，那么 p1 payload 可以被 p0 新结果覆盖。
      end
      2'b10: begin
        // p1 有旧结果、p0 无新结果：后级 ready 时清空 p1 valid。
        // 如果后级 ready：
        // result_ready=1：
        //   p1 旧结果输出
        //   p1 valid 清 0
        
        // 如果后级不 ready：
        // result_ready=0：
        //   p1 valid 保持 1
        //   继续保存旧结果
        alu_uop_valid_p1_en = result_ready;  //清空p1 valid
        alu_uop_valid_p1_in = 1'b0;
        alu_uop_p1_en       = 1'b0;
      end
      default: begin  // 2'b00
        // p0/p1 都没有有效结果。
        alu_uop_valid_p1_en = 1'b0;
        alu_uop_valid_p1_in = 1'b0;
        alu_uop_p1_en       = 1'b0;
      end
    endcase
  end
  
  //这段把 p0 当前结果整理成 PIPE_DATA_t，供 p1 保存。
  always_comb begin
    alu_uop_p1_in = 'b0;

    case(1'b1)  //互斥
      result_valid_addsub_p0: begin 
        // add/sub 已经输出 PIPE_DATA_t，直接作为 p1 payload。
        alu_uop_p1_in                     = result_addsub_p0;
      end
      result_valid_shift_p0: begin        
        // shift/mask/other 平时直接写 ROB；当 p1 需要接收 payload 时，将 PU2ROB_t 字段整理为 PIPE_DATA_t 子集。
      `ifdef TB_SUPPORT 
        alu_uop_p1_in.uop_pc              = result_shift_p0.uop_pc;
      `endif
        alu_uop_p1_in.rob_entry           = result_shift_p0.rob_entry;
        alu_uop_p1_in.w_data              = result_shift_p0.w_data;
        alu_uop_p1_in.w_valid             = result_shift_p0.w_valid;
        alu_uop_p1_in.vsat_cout.vsaturate = result_shift_p0.vsaturate;
      end
      result_valid_other_p0: begin
        // other 类结果转入 p1 payload 的字段映射。
      `ifdef TB_SUPPORT 
        alu_uop_p1_in.uop_pc              = result_other_p0.uop_pc;
      `endif
        alu_uop_p1_in.rob_entry           = result_other_p0.rob_entry;
        alu_uop_p1_in.w_data              = result_other_p0.w_data;
        alu_uop_p1_in.w_valid             = result_other_p0.w_valid;
        alu_uop_p1_in.vsat_cout.vsaturate = result_other_p0.vsaturate;
      end
      result_valid_mask_p0: begin
        // mask 类结果转入 p1 payload 的字段映射。
      `ifdef TB_SUPPORT 
        alu_uop_p1_in.uop_pc              = result_mask_p0.uop_pc;
      `endif
        alu_uop_p1_in.rob_entry           = result_mask_p0.rob_entry;
        alu_uop_p1_in.w_data              = result_mask_p0.w_data;
        alu_uop_p1_in.w_valid             = result_mask_p0.w_valid;
        alu_uop_p1_in.vsat_cout.vsaturate = result_mask_p0.vsaturate;
      end
    endcase
  end
  
  cdffr
  uop_valid_p1
  ( 
    .clk        (clk), 
    .rst_n      (rst_n), 
    .c          (trap_flush_rvv),         //clear
    .e          (alu_uop_valid_p1_en),    //enable
    .d          (alu_uop_valid_p1_in),    //输入，enable有效时输出alu_uop_valid_p1_in
    .q          (alu_uop_valid_p1)        //输出，非clear和enable时保持
  ); 
  
  // p1 payload 寄存器。valid 由上面的 cdffr 管，payload 只在需要接收/覆盖时更新。
  edff
  #(
    .T      (PIPE_DATA_t)
  )
  uop_p1
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (alu_uop_p1_en),    //enable
    .d      (alu_uop_p1_in),    //输入
    .q      (alu_uop_p1)
  );

  // 16/32位加减、mask、比较
  // p1 执行/格式整理：把 PIPE_DATA_t 中间结果转换成最终 PU2ROB_t。
  rvv_backend_alu_unit_execution_p1 #(
    .CMP_SUPPORT          (CMP_SUPPORT)
  ) u_alu_p1
  ( 
    .clk                  (clk),
    .rst_n                (rst_n),
    .alu_uop_valid        (alu_uop_valid_p1),
    .alu_uop              (alu_uop_p1),
    .result_valid         (result_valid_p1),  //输出enable
    .result               (result_p1),        //输出结果
    .trap_flush_rvv       (trap_flush_rvv) 
  );

// 
// 提交到 ROB。
// 仲裁规则：
// - p1 有结果时优先输出 p1，保证 add/sub 这类两级流水结果不会被 p0 新结果越过。
// - p0 只有 shift/mask/other 可以直接输出；add/sub p0 只 pop RS 并进入 p1，不直接 result_valid。
// - `pop_rs` 表示当前输入 uop 被真正消耗；若后级不 ready，直接输出类指令不能 pop。
// 
  always_comb begin
    case({result_valid_p1,(result_valid_addsub_p0|result_valid_shift_p0|result_valid_mask_p0|result_valid_other_p0)})
      2'b01: begin
        // p1 空、p0 有结果：根据具体 p0 子单元决定直接提交或进入 p1。
        case(1'b1)
          result_valid_addsub_p0: begin
            // add/sub 进入 p1，本周期不向 ROB 输出；可以立即 pop RS。
            result_valid = 'b0;
            result       = 'b0;
            pop_rs       = 1'b1;
          end
          result_valid_shift_p0: begin
            // shift 直接写 ROB；只有后级 ready 时才 pop RS。
            result_valid = 1'b1;
            result       = result_shift_p0;
            pop_rs       = result_ready;
          end
          result_valid_other_p0: begin
            // other 直接写 ROB；受 result_ready 后压。
            result_valid = 1'b1;
            result       = result_other_p0;
            pop_rs       = result_ready;
          end
          result_valid_mask_p0: begin
            // mask 直接写 ROB；受 result_ready 后压。
            result_valid = 1'b1;
            result       = result_mask_p0;
            pop_rs       = result_ready;
          end
          default: begin
            result_valid = 'b0;
            result       = 'b0;
            pop_rs       = 'b0;
          end
        endcase
      end
      2'b10: begin
        // 只有 p1 有结果：输出 p1，输入侧不 pop。
        result_valid = 1'b1;
        result       = result_p1;
        pop_rs       = 'b0;
      end
      2'b11: begin
        // p1 和 p0 同时有结果：优先输出 p1；后级 ready 时才允许当前输入 uop 被接收/推进。
        result_valid = 1'b1;
        result       = result_p1;
        pop_rs       = result_ready;
      end
      default: begin  // 2'b00
        // 无结果输出，也不消耗 RS uop。
        result_valid = 'b0;
        result       = 'b0;
        pop_rs       = 'b0;
      end
    endcase
  end

endmodule
