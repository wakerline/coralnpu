
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_unit_de2` -> RVV 后端 DE2 的单条 LCMD 分流/展开入口。
// - 接口与数据流：
//   * 输入：一条 `LCMD_t`，其中已经包含 DE1 计算好的 EMUL/EEW/evl/uop_index_max 等信息。
//   * 处理：只按 opcode 做二级分流；LOAD/STORE 交给 LSU DE2 展开，RVV 算术/逻辑/浮点交给 ARI DE2 展开。
//   * 输出：最多 `NUM_DE_UOP` 个候选 `UOP_QUEUE_t`，由上层 controller 再压缩并写入 Uop Queue。
// - 调用关系：上层 rvv_backend_decode_de2；下层 rvv_backend_decode_unit_ari_de2(u_ari_decode_de2), rvv_backend_decode_unit_lsu_de2(u_lsu_decode_de2)
// - 端口摘要：输入 lcmd_valid, lcmd, uop_index_remain；输出 uop_valid, uop。
// - define/参数阅读重点：
//   * `NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
//   * `UOP_INDEX_WIDTH`：5。
// - 不确定/条件宏提示：
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - 关键行为：
//   * 本模块不重新做指令合法性检查，默认输入 LCMD 已经由 DE1 过滤。
//   * `uop_index_remain` 用于长指令续发：当上一拍 Uop Queue 空间不够时，controller 会把未发完的 uop_index 反馈给本模块。
//   * 同一条 LCMD 只会命中 LSU 或 ARI 其中一路；若 opcode 不是 LOAD/STORE/RVV，则输出保持无效。
//   * 两个子模块都会生成候选 uop，但最终输出通过 `valid_lsu/valid_ari` 选择其中一路。
// - 阅读建议：结合 `rvv_backend_decode_unit_ari_de2.sv` 和 `rvv_backend_decode_unit_lsu_de2.sv` 看具体 uop 字段如何填写。
// 详细中文注释（自动梳理）END

module rvv_backend_decode_unit_de2
(
  lcmd_valid,
  lcmd,
  uop_index_remain,
  uop_valid,
  uop
);
//
// 接口信号
//
  // 来自 DE1/LCQ 的单条合法命令。
  input   logic                           lcmd_valid;
  input   LCMD_t                          lcmd;
  // 对于第 0 条 LCMD，上层 controller 可能反馈未完成的 uop_index，从该位置继续展开。
  input   logic   [`UOP_INDEX_WIDTH-1:0]  uop_index_remain;
  
  // 输出给上层 controller 的候选 uop；此处还没有真正和 Uop Queue 握手。
  output  logic       [`NUM_DE_UOP-1:0]   uop_valid;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]   uop;

//
// 内部信号
//
  // 根据 opcode 得到的两路有效标志；同一条 LCMD 正常情况下只会有一路为 1。
  logic                                   valid_ari;
  logic                                   valid_lsu;
  // ARI 子展开器生成的候选 uop，覆盖整数、mask、规约、浮点等 RVV opcode。
  logic           [`NUM_DE_UOP-1:0]       uop_valid_ari;
  UOP_QUEUE_t     [`NUM_DE_UOP-1:0]       uop_ari;
  // LSU 子展开器生成的候选 uop，覆盖 LOAD/STORE、segment、indexed、whole-register 等。
  logic           [`NUM_DE_UOP-1:0]       uop_valid_lsu;
  UOP_QUEUE_t     [`NUM_DE_UOP-1:0]       uop_lsu;

//
// 解码
//
  // 只按 opcode 做粗分流：访存走 LSU DE2，普通 RVV 算术/逻辑/浮点走 ARI DE2。
  assign valid_lsu  = lcmd_valid & ((lcmd.cmd.opcode==LOAD) | (lcmd.cmd.opcode==STORE));
  assign valid_ari  = lcmd_valid & (lcmd.cmd.opcode==RVV);
  
  // LSU DE2：基于 DE1 已给出的 EMUL/EEW/evl 等信息，生成访存 uop。
  rvv_backend_decode_unit_lsu_de2 u_lsu_decode_de2
  (
    .lcmd_valid         (valid_lsu),
    .lcmd               (lcmd),
    .uop_index_remain   (uop_index_remain),
    .uop_valid          (uop_valid_lsu),
    .uop                (uop_lsu)  
  );

  // ARI DE2：基于 DE1 已给出的 EMUL/EEW/uop_vstart 等信息，生成执行单元 uop。
  rvv_backend_decode_unit_ari_de2 u_ari_decode_de2
  (
    .lcmd_valid         (valid_ari),
    .lcmd               (lcmd),
    .uop_index_remain   (uop_index_remain),
    .uop_valid          (uop_valid_ari),
    .uop                (uop_ari)  
  );

  // 根据 opcode 选择一路输出。默认清零可以避免非法/空泡 LCMD 产生误 push。
  always_comb begin 
    uop_valid     = 'b0;
    uop           = 'b0;
    
    case(1'b1)
      valid_lsu: begin
        // LOAD/STORE：输出 LSU 展开的候选 uop。
        uop_valid = uop_valid_lsu;
        uop       = uop_lsu;
      end
  
      valid_ari: begin
        // RVV opcode：输出 ARI 展开的候选 uop。
        uop_valid = uop_valid_ari;
        uop       = uop_ari;
      end
    endcase
  end

endmodule
