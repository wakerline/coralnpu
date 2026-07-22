//
// 功能说明：
// 1. 控制 DE2 从 LCQ/Command Queue 弹出命令，并把 DE2 解出的 uop 写入 Uop Queue。
//
// 设计特点：
// 1. 本模块不是重新解码指令，而是把多条指令产生的二维候选 uop 压缩成一维 Uop Queue 写端口。
// 2. push 只有在对应 Uop Queue 写槽 ready 时才会置位，因此 ready 也参与决定本拍能否 pop 指令。
// 3. 若一条长向量指令本拍没有发完，会通过 uop_index_remain 记录下一拍继续展开的位置。
// 4. trap_flush_rvv 会清除 uop_index_remain，避免 flush 后继续发射旧指令的剩余 uop。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_ctrl` -> RVV 后端 DE2 的发射/压缩控制器。
// - 接口与数据流：
//   * 输入：`de_uop_valid/de_uop`，形状为 [NUM_DE_INST][NUM_DE_UOP]，来自多个 DE2 decode unit。
//   * 处理：按照程序顺序优先级，把二维候选 uop 压缩到 Uop Queue 的一维写端口。
//   * 输出：`push/uop` 写入 Uop Queue，`pop` 告诉 LCQ 哪些 LCMD 已经完整消费。
//   * 续发：当最老指令未完全写入 Uop Queue 时，保存下一拍应继续发的 `uop_index_remain`。
// - 调用关系：上层 rvv_backend_decode_de2；无下层实例。
// - 端口摘要：输入 clk, rst_n, de_uop_valid, de_uop, uq_ready, trap_flush_rvv；输出 uop_index_remain, pop, push, uop。
// - define/参数阅读重点：
//   * `NUM_DE_INST`：3'd2；DE1/DE2 每拍处理的命令条数。
//   * `NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
//   * `UOP_INDEX_WIDTH`：5。
//   * `rvv_expect`：assert property 宏，来自 rvv_backend_sva.svh。
// - 不确定/条件宏提示：
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
//   * 断言宏来自 `rvv_backend_sva.svh`，只有相关编译开关打开时才会参与仿真检查。
// - 压缩规则：
//   * 低编号 LCMD 是更老指令，始终优先占用低编号 push 端口。
//   * `de_uop_valid[x][y]` 连续为 1 时，表示第 x 条 LCMD 还有第 y 个候选 uop。
//   * 对每个 push[k]，case/casex 选择“程序顺序中的第 k 个有效 uop”。
//   * `last_uop` 用来判断某条 LCMD 本拍是否已经发到最后一个 uop，只有完成后才能 pop。
// - 阅读建议：先看 `push/uop` 生成，再看 `last_uop/pop`，最后看 `uop_index_remain` 寄存器更新。
// 详细中文注释（自动梳理）END

module rvv_backend_decode_ctrl
(
  clk,
  rst_n,
  de_uop_valid,
  de_uop,   
  uop_index_remain,
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
  input   logic                                           clk;
  input   logic                                           rst_n;
  // 来自多个 decode_unit_de2 的二维候选 uop；第一维是 LCMD 编号，第二维是该 LCMD 展开的 uop 编号。
  input   logic       [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] de_uop_valid;
  input   UOP_QUEUE_t [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] de_uop;
  // 反馈给第 0 个 decode_unit_de2 的续发 uop_index。
  output  logic       [`UOP_INDEX_WIDTH-1:0]              uop_index_remain;
  // 回给 LCQ 的 pop 信号；只有对应 LCMD 的最后一个 uop 已经被本模块接收/发射时才置位。
  output  logic       [`NUM_DE_INST-1:0]                  pop;
  // 写入 Uop Queue 的一维输出流。
  output  logic       [`NUM_DE_UOP-1:0]                   push;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]                   uop;
  // Uop Queue 每个写端口的 ready。
  input   logic       [`NUM_DE_UOP-1:0]                   uq_ready;
  // RVV trap/flush，清掉跨拍续发状态。
  input   logic                                           trap_flush_rvv; 

//
// 内部信号
//
  // last_uop[k] 表示压缩后的第 k 个输出 uop 是其所属 LCMD 的最后一个 uop。
  logic [`NUM_DE_UOP-1:0]                                 last_uop;
  // uop_index_remain 寄存器相关信号：保存未发完最老 LCMD 的续发位置。
  logic [`UOP_INDEX_WIDTH-1:0]                            final_uop_index;
  logic                                                   uop_index_en;
  logic [`UOP_INDEX_WIDTH-1:0]                            uop_index_din;
  
  // 循环变量。
  integer                                                 i;
  genvar                                                  j;

  `ifdef ASSERT_ON
    `rvv_expect(`NUM_DE_INST<=`NUM_DE_UOP)
    else $error("`NUM_DE_INST=%d is greater than `NUM_DE_UOP=%d.", `NUM_DE_INST, `NUM_DE_UOP);
  `endif

  // 每拍观察的 LCMD 数量不能超过 Uop Queue 写端口数量。
  // 原因是每条 LCMD 至少可能产生 1 个 uop。
  // 若 NUM_DE_INST > NUM_DE_UOP，理论上即使每条指令都只有一个 uop，也无法保证本拍把所有可用指令压缩进 Uop Queue。
  generate
    // push/uop 压缩网络：
    // 将 de_uop[inst][uop] 按程序顺序展平成 uop[port]。
    // 程序顺序优先：
    // lcmd[0] 的 uop 永远优先于 lcmd[1]
    // lcmd[1] 的 uop 永远优先于 lcmd[2]
    // 同一条 LCMD 内，低 uop_index 优先于高 uop_index
    // 把所有候选 uop 按如下顺序排成一列：
    // de_uop[0][0]
    // de_uop[0][1]
    // de_uop[0][2]
    // ...
    // de_uop[1][0]
    // de_uop[1][1]
    // ...
    // de_uop[2][0]
    // ...
    // 然后取其中有效的前 NUM_DE_UOP 个，依次放入 uop[0], uop[1], ...

    // port0 永远只能来自最老 LCMD 的第 0 个 uop。
    assign push[0] = de_uop_valid[0][0]&uq_ready[0];
    assign uop[0]  = de_uop[0][0];

    if (`NUM_DE_INST>=3'd2) begin : gen_push1_uop1
      if(`NUM_DE_UOP>=3'd2) begin
        // 如果 lcmd[0] 还有第 1 个 uop，则优先选择 de_uop[0][1]。
        // 否则选择 lcmd[1] 的第 0 个 uop。
        assign push[1] = (de_uop_valid[0][1]|de_uop_valid[1][0]) ? uq_ready[1] : 'b0;
        assign uop[1]  =  de_uop_valid[0][1] ? de_uop[0][1] : de_uop[1][0];
      end
    end

    if (`NUM_DE_INST==3'd2) begin : if_inst_eq_2 // NUM_DE_INST=2 时的二维到一维压缩网络。
      if(`NUM_DE_UOP>=3'd3) begin : gen_push2_uop2
        always_comb begin
          casex({de_uop_valid[1][1:0],de_uop_valid[0][2:1]})
            4'b??_11: begin  //A0/A1/A2 都有效
              push[2] = uq_ready[2];
              uop[2]  = de_uop[0][2];
            end              
            4'b?1_01: begin  //A0/A1 有效，A2 无效, B0有效
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][0];
            end
            4'b11_?0: begin  //A0有效，A1无效, B0有效，B1有效
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][1];
            end
            default: begin   //无效输出
              push[2] = 'b0;
              uop[2]  = de_uop[0][2];
            end
          endcase
        end
      end // NUM_DE_UOP>=3
    
      if(`NUM_DE_UOP>=3'd4) begin : gen_push3_uop3
        always_comb begin
          casex({de_uop_valid[1][2:0],de_uop_valid[0][3:1]})
            6'b???_111: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[0][3];
            end
            6'b??1_011: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][0];
            end
            6'b?11_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][1];
            end
            6'b111_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][2];
            end
            default: begin 
              push[3] = 'b0;
              uop[3]  = de_uop[0][3];
            end
          endcase
        end
      end // NUM_DE_UOP>=4

      if(`NUM_DE_UOP>=3'd5) begin : gen_push4_uop4
        always_comb begin
          casex({de_uop_valid[1][3:0],de_uop_valid[0][4:1]})
            8'b????_1111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[0][4];
            end
            8'b???1_0111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][0];
            end
            8'b??11_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][1];
            end
            8'b?111_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][2];
            end
            8'b1111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][3];
            end
            default: begin 
              push[4] = 'b0;
              uop[4]  = de_uop[0][4];
            end
          endcase
        end
      end // NUM_DE_UOP>=5

      if(`NUM_DE_UOP>=3'd6) begin : gen_push5_uop5
        always_comb begin
          casex({de_uop_valid[1][4:0],de_uop_valid[0][5:1]})
            10'b?????_11111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[0][5];
            end
            10'b????1_01111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][0];
            end
            10'b???11_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][1];
            end
            10'b??111_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][2];
            end
            10'b?1111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][3];
            end
            10'b11111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][4];
            end
            default: begin 
              push[5] = 'b0;
              uop[5]  = de_uop[0][5];
            end
          endcase
        end
      end // NUM_DE_UOP>=6
    end // NUM_DE_INST=2

    if (`NUM_DE_INST==3'd3) begin : if_inst_eq_3
      // NUM_DE_INST=3 时，同样按 inst0 -> inst1 -> inst2 的顺序填充 push 端口。
      if(`NUM_DE_UOP>=3'd3) begin : gen_push2_uop2
        always_comb begin
          casex({de_uop_valid[2][0],de_uop_valid[1][1:0],de_uop_valid[0][2:1]})
            5'b?_??_11: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[0][2];
            end
            5'b?_?1_01: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][0];
            end
            5'b?_11_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][1];
            end
            5'b1_01_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[2][0];
            end
            default: begin 
              push[2] = 'b0;
              uop[2]  = de_uop[0][2];
            end
          endcase
        end
      end // NUM_DE_UOP==3
    
      if(`NUM_DE_UOP>=3'd4) begin : gen_push3_uop3
        always_comb begin
          casex({de_uop_valid[2][1:0],de_uop_valid[1][2:0],de_uop_valid[0][3:1]})
            8'b??_???_111: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[0][3];
            end
            8'b??_??1_011: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][0];
            end
            8'b??_?11_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][1];
            end
            8'b?1_?01_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            8'b??_111_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][2];
            end
            8'b?1_011_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            8'b11_?01_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][1];
            end
            default: begin 
              push[3] = 'b0;
              uop[3]  = de_uop[0][3];
            end
          endcase
        end
      end // NUM_DE_UOP==4

      if(`NUM_DE_UOP>=3'd5) begin : gen_push4_uop4
        always_comb begin
          casex({de_uop_valid[2][2:0],de_uop_valid[1][3:0],de_uop_valid[0][4:1]})
            11'b???_????_1111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[0][4];
            end
            11'b???_???1_0111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][0];
            end
            11'b???_??11_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][1];
            end
            11'b??1_??01_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            11'b???_?111_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][2];
            end
            11'b??1_?011_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            11'b?11_??01_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            11'b???_1111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][3];
            end
            11'b??1_0111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            11'b?11_?011_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            11'b111_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][2];
            end
            default: begin 
              push[4] = 'b0;
              uop[4]  = de_uop[0][4];
            end
          endcase
        end
      end // NUM_DE_UOP==5

      if(`NUM_DE_UOP>=3'd6) begin : gen_push5_uop5
        always_comb begin
          casex({de_uop_valid[2][3:0],de_uop_valid[1][4:0],de_uop_valid[0][5:1]})
            14'b????_?????_11111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[0][5];
            end
            14'b????_????1_01111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][0];
            end
            14'b????_???11_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][1];
            end
            14'b???1_???01_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b????_??111_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][2];
            end
            14'b???1_??011_??011: begin            
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b??11_???01_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            14'b????_?1111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][3];
            end
            14'b???1_?0111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b??11_??011_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            14'b?111_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            14'b????_11111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][4];
            end
            14'b???1_01111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b??11_?0111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            14'b?111_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            14'b1111_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][3];
            end
            default: begin 
              push[5] = 'b0;
              uop[5]  = de_uop[0][5];
            end
          endcase
        end
      end // NUM_DE_UOP==6 
    end // NUM_DE_INST==3

    if (`NUM_DE_INST==3'd4) begin : if_inst_eq_4
      if(`NUM_DE_UOP>=3'd3) begin : gen_push2_uop2
        always_comb begin
          casex({de_uop_valid[2][0],de_uop_valid[1][1:0],de_uop_valid[0][2:1]})
            5'b?_??_11: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[0][2];
            end
            5'b?_?1_01: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][0];
            end
            5'b?_11_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][1];
            end
            5'b1_01_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[2][0];
            end
            default: begin 
              push[2] = 'b0;
              uop[2]  = de_uop[0][2];
            end
          endcase
        end
      end // NUM_DE_UOP==3
    
      if(`NUM_DE_UOP>=3'd4) begin : gen_push3_uop3
        always_comb begin
          casex({de_uop_valid[3][0],de_uop_valid[2][1:0],de_uop_valid[1][2:0],de_uop_valid[0][3:1]})
            9'b?_??_???_111: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[0][3];
            end
            9'b?_??_??1_011: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][0];
            end
            9'b?_??_?11_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][1];
            end
            9'b?_?1_?01_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            9'b?_??_111_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][2];
            end
            9'b?_?1_011_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            9'b?_11_?01_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][1];
            end
            9'b1_01_?01_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[3][0];
            end
            default: begin 
              push[3] = 'b0;
              uop[3]  = de_uop[0][3];
            end
          endcase
        end
      end // NUM_DE_UOP==4

      if(`NUM_DE_UOP>=3'd5) begin : gen_push4_uop4
        always_comb begin
          casex({de_uop_valid[3][1:0],de_uop_valid[2][2:0],de_uop_valid[1][3:0],de_uop_valid[0][4:1]})
            13'b??_???_????_1111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[0][4];
            end
            13'b??_???_???1_0111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][0];
            end
            13'b??_???_??11_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][1];
            end
            13'b??_??1_??01_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            13'b??_???_?111_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][2];
            end
            13'b??_??1_?011_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            13'b??_?11_??01_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            13'b?1_?01_??01_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][0];
            end
            13'b??_???_1111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][3];
            end
            13'b??_??1_0111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            13'b??_?11_?011_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            13'b?1_?01_?011_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][0];
            end
            13'b??_111_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][2];
            end
            13'b?1_011_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][0];
            end
            13'b11_?01_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][1];
            end
            default: begin 
              push[4] = 'b0;
              uop[4]  = de_uop[0][4];
            end
          endcase
        end
      end // NUM_DE_UOP==5

      if(`NUM_DE_UOP>=3'd6) begin : gen_push5_uop5
        always_comb begin
          casex({de_uop_valid[3][2:0],de_uop_valid[2][3:0],de_uop_valid[1][4:0],de_uop_valid[0][5:1]})
            17'b???_????_?????_11111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[0][5];
            end
            17'b???_????_????1_01111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][0];
            end
            17'b???_????_???11_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][1];
            end
            17'b???_???1_???01_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_????_??111_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][2];
            end
            17'b???_???1_??011_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_??11_???01_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            17'b??1_??01_???01_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b???_????_?1111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][3];
            end
            17'b???_???1_?0111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_??11_??011_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            17'b??1_??01_??011_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b???_?111_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            17'b??1_?011_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b?11_??01_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][1];
            end
            17'b???_????_11111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][4];
            end
            17'b???_???1_01111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_??11_?0111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            17'b??1_??01_?0111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b???_?111_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            17'b??1_?011_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b?11_??01_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][1];
            end
            17'b???_1111_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][3];
            end
            17'b??1_0111_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b?11_?011_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][1];
            end
            17'b111_??01_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][2];
            end
            default: begin 
              push[5] = 'b0;
              uop[5]  = de_uop[0][5];
            end
          endcase
        end
      end // NUM_DE_UOP>=6 
    end // NUM_DE_INST=3
      
    // 计算每个输出端口是否发出了某条 LCMD 的最后一个 uop。
    // 只有 push 成功并且 uop 自身标记 last_uop_valid 时，才会触发对应 LCMD pop。
    for(j=0;j<`NUM_DE_UOP;j++) begin : gen_last_uop
      assign last_uop[j] = push[j]&uop[j].last_uop_valid;  //候选 uop 是最后一个，但没有成功写入 Uop Queue，不算完成。
    end
  endgenerate

  always_comb begin
    pop = 'b0;
    i   = 0;

    // 按输出端口顺序扫描 last_uop。每遇到一个 last_uop，就说明当前最老未 pop 的 LCMD 已完成。
    // 这里的 i 是“当前应该 pop 的 LCMD 编号”，因此天然保持程序顺序。
    for(int k=0;k<`NUM_DE_UOP;k++) begin
      if (i < `NUM_DE_INST) begin
        if (last_uop[k]) begin
          pop[i] = 1'b1;
          i      = i + 1;
        end
      end
    end
  end
  
  // 记录下一拍续发起点：
  // - 如果本拍最后一个成功 push 的 uop 已经是该 LCMD 的最后 uop，则清零。
  // - 否则保存 last pushed uop 的 uop_index+1，下一拍第 0 个 decode_unit 从这里继续展开。
  always_comb begin
    uop_index_din = 'b0;

    for(int k=0;k<`NUM_DE_UOP;k++) begin
      if(push[k])  //串型链，直到最后一个push的uop_index才是最终结果。
        uop_index_din = uop[k].last_uop_valid ? 'b0 : uop[k].uop_index + (`UOP_INDEX_WIDTH)'('d1);
    end
  end

  //Uop Queue 不 ready 时，本拍没有发射任何 uop，续发位置不能前进
  assign uop_index_en = |push;  //只要本拍至少成功 push 了一个 uop，就更新 uop_index_remain。

  // trap_flush_rvv 作为同步 clear，flush 后不能继续使用旧指令的剩余 uop_index。
  cdffr 
  #(
    .T         (logic[`UOP_INDEX_WIDTH-1:0])
  )
  uop_index_cdffr
  ( 
    .clk       (clk), 
    .rst_n     (rst_n), 
    .c         (trap_flush_rvv), 
    .e         (uop_index_en), 
    .d         (uop_index_din),
    .q         (uop_index_remain)
  ); 

endmodule
