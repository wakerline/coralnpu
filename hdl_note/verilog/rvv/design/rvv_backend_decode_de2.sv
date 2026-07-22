
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_de2` -> RVV 后端 DE2 顶层。
// - 接口与数据流：
//   * 输入：来自 LCQ/DE1 的 `LCMD_t` 数组；每个 LCMD 已完成 DE1 合法性检查，并带有 EMUL/EEW/uop 范围信息。
//   * 处理：为每条 LCMD 实例化 `rvv_backend_decode_unit_de2`，并把每条指令可展开的 uop 候选送入 controller。
//   * 控制：`rvv_backend_decode_ctrl` 根据 Uop Queue 的 ready 情况压缩/选择 uop、产生 push/pop，并记录跨拍剩余 uop_index。
//   * 输出：写入 Uop Queue 的 `push/uop`，以及回给 LCQ 的 `pop`。
// - 调用关系：上层 rvv_backend；下层 rvv_backend_decode_ctrl(u_decode_ctrl), rvv_backend_decode_unit_de2(u_decode_unit0_de2, u_decode_unit_de2)
// - 端口摘要：输入 clk, rst_n, lcmd_valid, lcmd, uq_ready, trap_flush_rvv；输出 pop, push, uop。
// - define/参数阅读重点：
//   * `NUM_DE_INST`：3'd2；DE1/DE2 每拍处理的命令条数。
//   * `NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
//   * `UOP_INDEX_WIDTH`：5。
// - 不确定/条件宏提示：
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - DE2 展开规则：
//   * `NUM_DE_INST` 表示本级最多同时观察多少条 LCMD。
//   * `NUM_DE_UOP` 表示本级每拍最多向 Uop Queue 推入多少个 uop。
//   * 第 0 条 LCMD 可能上一拍没有完全展开，因此接收 `uop_index_remain` 作为续发起点。
//   * 第 1 条及之后的 LCMD 只有在前面指令本拍展开后仍有空槽时才会被 controller 选择。
//   * `trap_flush_rvv` 进入 controller，用于清空/停止当前 DE2 到 Uop Queue 的发射状态。
// - 阅读建议：先看 `rvv_backend_decode_unit_de2` 如何生成候选 uop，再看 `rvv_backend_decode_ctrl` 如何把二维候选压缩成一维 push/uop。
// 详细中文注释（自动梳理）END

// 1. 接收 LCQ 给出的 lcmd_valid/lcmd。
// 2. 第 0 条 LCMD 送入 u_decode_unit0_de2。
//    - 如果上一拍没发完，从 uop_index_remain 继续。
// 3. 第 1 条及之后 LCMD 送入 generate 出来的 decode_unit。
//    - 全部从 uop_index=0 开始。
// 4. 每个 decode_unit 产生一组候选 uop：
//    - de_uop_valid[i][j]
//    - de_uop[i][j]
// 5. controller 读取二维候选矩阵。
// 6. controller 根据程序顺序和 uq_ready 选择可发射 uop。
// 7. controller 输出：
//    - push/uop 写 Uop Queue
//    - pop 通知 LCQ 哪些 LCMD 完整消费
//    - uop_index_remain 记录跨拍剩余 uop 位置
// 8. 如果 trap_flush_rvv 有效，controller 清理当前发射状态。
module rvv_backend_decode_de2
(
  clk, 
  rst_n,
  lcmd_valid,
  lcmd,
  pop,
  push,
  uop,
  uq_ready,
  trap_flush_rvv 
);
//
// 接口信号
//
  // 全局时钟和低有效复位。
  input   logic                         clk;
  input   logic                         rst_n;
  // 来自 LCQ/DE1 的命令。数组下标越小，程序顺序越老。
  input   logic   [`NUM_DE_INST-1:0]    lcmd_valid;
  input   LCMD_t  [`NUM_DE_INST-1:0]    lcmd;
  // pop 回给 LCQ，表示对应 LCMD 已经被 DE2 完整接收/展开，可以从队列弹出。
  output  logic   [`NUM_DE_INST-1:0]    pop;
  // 写入 Uop Queue 的一维 uop 流；push[i] 与 uop[i] 一一对应。
  output  logic   [`NUM_DE_UOP-1:0]     push;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0] uop;
  // Uop Queue 对每个写端口/槽位给出的 ready，controller 只有 ready 时才会 push。
  input   logic   [`NUM_DE_UOP-1:0]     uq_ready;
  // RVV trap/flush 信号，送入 controller 清理当前发射控制状态。
  input   logic                         trap_flush_rvv;  

  //
  // 内部信号
  //
  // 二维候选 uop：第一维是输入 LCMD 编号，第二维是该 LCMD 在本拍可展开的 uop 编号。
  logic       [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] de_uop_valid;
  // de_uop[0][0]：lcmd[0] 的第 0 个候选 uop
  // de_uop[0][1]：lcmd[0] 的第 1 个候选 uop
  // ...
  // de_uop[1][0]：lcmd[1] 的第 0 个候选 uop
  UOP_QUEUE_t [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] de_uop;
  // controller 记录的“第 0 条 LCMD 尚未发完的 uop_index”，用于跨拍续发长指令。
  logic       [`UOP_INDEX_WIDTH-1:0]              uop_index_remain;
  // generate 循环变量。
  genvar                                          i;

  //
  // 解码
  //
  // 第 0 条 LCMD 允许从 uop_index_remain 续发；这是处理长向量指令跨拍展开的关键路径。
  // 假设一条指令需要 8 个 uop，但 NUM_DE_UOP=6，那么：
  // cycle 0：
  //   只能发 uop0 ~ uop5
  //   剩下 uop6 ~ uop7
  //   uop_index_remain = 6
  //   pop[0] = 0
  // cycle 1：
  //   lcmd[0] 仍然是这条指令
  //   decode_unit0 从 uop_index_remain=6 开始展开
  //   发 uop6 ~ uop7
  //   这条指令完整发完
  //   pop[0] = 1
  rvv_backend_decode_unit_de2 u_decode_unit0_de2
  (
    .lcmd_valid             (lcmd_valid[0]),    //input
    .lcmd                   (lcmd[0]),          //input
    .uop_index_remain       (uop_index_remain), //input  跨拍残留的那条指令一定是当前 LCQ 队头，也就是 lcmd[0]。
    .uop_valid              (de_uop_valid[0]),  //output  每个 decode_unit_de2 产生的 de_uop_valid[x][y] 应该是从低位开始连续有效：
    .uop                    (de_uop[0])         //output
  );
   
  generate 
    for (i=1;i<`NUM_DE_INST;i=i+1) begin: DECODE_UNIT
      // 后续 LCMD 只在当前拍从头展开；如果本拍没有被 controller 完整接收，下一拍仍由 LCQ 保持。
      // 下一拍 LCQ 弹出 lcmd[0] 后，原来的未完全发出的lcmd[1] 会成为新的 lcmd[0]，所以只需要处理 lcmd[0] 的跨拍续发。
      rvv_backend_decode_unit_de2 u_decode_unit_de2
      (
        .lcmd_valid         (lcmd_valid[i]),             //input
        .lcmd               (lcmd[i]),                   //input
        .uop_index_remain   ({`UOP_INDEX_WIDTH{1'b0}}),  //input
        .uop_valid          (de_uop_valid[i]),           //output
        .uop                (de_uop[i])                  //output
      );    
    end
  endgenerate
  
  // controller 负责把二维候选 uop 压缩成 Uop Queue 的一维写端口，并生成 pop/push。
  // 所以可以说是顺序发射
  rvv_backend_decode_ctrl u_decode_ctrl
  (
    .clk                    (clk),               //input
    .rst_n                  (rst_n),             //input
    .de_uop_valid           (de_uop_valid),      //input
    .de_uop                 (de_uop),            //input 译码后的二维候选 uop：de_uop[inst_id][uop_id]
    .uop_index_remain       (uop_index_remain),  //output
    .pop                    (pop),               //output pop[i] = 1，表示 lcmd[i] 已经被 DE2 完整接收/展开，LCQ 可以把这条 LCMD 弹出。
    .push                   (push),              //output 这是 DE2 输出给 Uop Queue 的写入流。
    .uop                    (uop),               //output 这是 DE2 输出给 Uop Queue 的写入流。
    .uq_ready               (uq_ready),          //input  DE2 controller 不能无条件 push。它必须满足：候选 uop 有效
                                                 //并且对应 Uop Queue 写端口 ready
    .trap_flush_rvv         (trap_flush_rvv)     //input
  );

endmodule
