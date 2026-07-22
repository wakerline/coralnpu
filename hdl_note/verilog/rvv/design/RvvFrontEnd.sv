// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// RvvFrontEnd 负责把 RVS/decode 发来的 RVVInstruction 组装成后端可执行的 RVVCmd。
// 主要工作包括：
//   1. 维护 RVV 架构配置状态，例如 vl、vtype、LMUL、SEW、vstart、vxrm、vxsat；
//   2. 解析 vsetvli/vsetivli/vsetvl，并把新 vl 写回标量 rd；
//   3. 根据后端队列剩余空间进行反压；
//   4. 输入 lane 可能不连续，例如 [0,1,1,0]，输出会经 Aligner 压紧成 [1,1,0,0]；
//   5. 标量寄存器/浮点寄存器操作数比指令晚一拍到达，所以本模块天然引入一拍延迟。
module RvvFrontEnd#(parameter N = 4,
                    parameter CAPACITYBITS=$clog2(2*N + 1),
                    parameter REDUCE_LMUL = 1)
(
  input clk,
  input rstn,

  input logic [`VSTART_WIDTH-1:0]     vstart_i,
  input logic [`VCSR_VXRM_WIDTH-1:0]  vxrm_i,
  input logic [`VCSR_VXSAT_WIDTH-1:0] vxsat_i,
  input logic [2:0]                   frm_i,

  // decode/RVS 输入指令，一拍最多 N 条。
  input logic [N-1:0] inst_valid_i,
  input RVVInstruction [N-1:0] inst_data_i,
  output logic [N-1:0] inst_ready_o,

  // 标量寄存器堆读数据：每条指令对应 rs1/rs2 两个读端口。
  input logic [(2*N)-1:0] reg_read_valid_i,
  input logic [(2*N)-1:0][31:0] reg_read_data_i,

  // 浮点寄存器堆读数据：OPFVF 指令使用浮点标量 rs1。
  input logic [N-1:0][31:0] freg_read_data_i,

  // vset* 配置指令写回标量 rd，数据为计算后的 vl。
  output logic [N-1:0] reg_write_valid_o,
  output logic [N-1:0][4:0] reg_write_addr_o,
  output logic [N-1:0][31:0] reg_write_data_o,

  // 发往 RVV 后端命令队列的 RVVCmd。
  output logic [N-1:0] cmd_valid_o,
  output RVVCmd [N-1:0] cmd_data_o,
  input logic [CAPACITYBITS-1:0] queue_capacity_i,  // 后端当前还能接收的命令数量。
  output logic [CAPACITYBITS-1:0] queue_capacity_o,

  // 前端早期 trap 输出，例如 vill 状态下执行非 vset* 指令。
  output logic trap_valid_o,
  output RVVInstruction trap_data_o,

  // 当前 RVV 配置状态；仅当前端无暂存指令时认为有效。
  output config_state_valid,
  output RVVConfigState config_state
);
  localparam COUNTBITS = $clog2(N + 1);
  typedef logic [COUNTBITS-1:0] count_t;

  // vtype/vl 等 RVV 架构状态寄存器。
  logic vill;
  RVVConfigState config_state_q;

  // 已接收但尚未组合成 RVVCmd 的指令暂存。
  logic [N-1:0] valid_inst_q;     // 该 lane 中的暂存指令是否有效。
  count_t valid_inst_count_q;     // valid_inst_q 的有效条目数。
  RVVInstruction inst_q [N-1:0];  // lane 中暂存的原始指令。

  // 对输入 valid 做前缀和，用于只接收后端容量允许的前若干条指令。
  count_t valid_in_psum [N:0];
  always_comb begin
    valid_in_psum[0] = 0;
    for (int i = 0; i < N; i++) begin
      valid_in_psum[i+1] = valid_in_psum[i] + inst_valid_i[i];  // valid_in_psum[i] 表示 lane i 之前有多少条 valid 指令。
    end
  end

  // 仅当前端暂存槽全部为空时，对外声明 config_state 有效；
  // 这样避免同拍连续 vset* 状态前递带来的时序压力。
  // 前端内部可以串行计算多条 vset* 的状态；但对外只在没有暂存指令时声明 config_state_valid。
  logic config_state_reduction;
  always_comb begin
    config_state_reduction = 1;
    for (int i = 0; i < N; i++) begin
      config_state_reduction = config_state_reduction & (!valid_inst_q[i]);  //lane暂存指令为空时有效
    end
  end
  assign config_state_valid = config_state_reduction;
  assign config_state = config_state_q;

  logic [CAPACITYBITS-1:0] queue_capacity;
  assign queue_capacity_o = queue_capacity;
  always_comb begin
    // 前端自己暂存的一拍指令也会占用后端可用容量。
    queue_capacity = queue_capacity_i - valid_inst_count_q;
  end

  logic inst_accepted [N-1:0];
  count_t valid_inst_count_d;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      // 只接受前缀内能放入队列的指令，保持 lane 从低到高连续发射。
      inst_accepted[i] = (valid_in_psum[i] < queue_capacity) && inst_valid_i[i];
      inst_ready_o[i] = inst_accepted[i];
    end
    valid_inst_count_d = (valid_in_psum[N] < queue_capacity) ?  //对比lane N时几个请求有效
        valid_in_psum[N] : queue_capacity;
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      for (int i = 0; i < N; i++) begin
        valid_inst_q[i] <= 0;
        valid_inst_count_q <= 0;
      end;
    end else begin
      for (int i = 0; i < N; i++) begin
        valid_inst_q[i] <= inst_accepted[i];
        valid_inst_count_q <= valid_inst_count_d;
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < N; i++) begin
      inst_q[i] <= inst_accepted[i] ? inst_data_i[i] : inst_q[i];
    end
  end

  // 基于本拍暂存指令顺序更新 RVV 配置状态；同一拍多条 vset* 会按 lane 序串行生效。
  RVVConfigState inst_config_state [N:0];
  logic [31:0] avl [N-1:0];
  logic [31:0] vlmax [N-1:0];
  logic is_setvl [N-1:0];
  logic [`VL_WIDTH-1:0] vl_minus_one [N-1:0];
  always_comb begin
    inst_config_state[0] = config_state_q;  //先以当前 config_state_q 为基础；
    inst_config_state[0].vstart = vstart_i;  //再覆盖最新 CSR 输入 vstart/vxrm/vxsat/frm；
    inst_config_state[0].xrm = RVVXRM'(vxrm_i);
    inst_config_state[0].xsat = vxsat_i;
`ifdef ZVE32F_ON
    inst_config_state[0].frm = RVFRM'(frm_i);
`endif  // ZVE32F_ON
    // | 指令         | 判断条件                   | 说明                |
    // | ---------- | ---------------------- | ----------------- |
    // | `vsetvli`  | `bits[24] == 0`        | vtype 来自立即数字段     |
    // | `vsetivli` | `bits[24:23] == 2'b11` | AVL 来自 5-bit uimm |
    // | `vsetvl`   | `bits[24:23] == 2'b10` | vtype 来自 rs2      |
    for (int i = 0; i < N; i++) begin  //然后按 lane 顺序处理暂存指令。
      inst_config_state[i+1] = inst_config_state[i];
      avl[i] = 0;
      vlmax[i] = 0;
      is_setvl[i] = 0;

      if (valid_inst_q[i] &&
          (inst_q[i].opcode == RVV) &&
          (inst_q[i].bits[7:5] == 3'b111)) begin  //只有暂存指令有效、opcode 是 RVV、funct3 类别是配置类，才进入 vset 解析。
        if (inst_q[i].bits[24] == 0) begin  // vsetvli
          // 根据 RVV 规范 6.2 的编码规则确定 AVL。
          unique case (inst_q[i].bits[12:8])  //rs1
            0: unique case (inst_q[i].bits[4:0])  //rd
              0:  avl[i] = inst_config_state[i].vl;  // rd = x0, rs1 = x0, 保持原 vl
              default: avl[i] = 32'hFFFFFFFF;        // rd != x0, rs1 = x0, AVL = 最大值
            endcase
            default: avl[i] = reg_read_data_i[2*i];  // rs1 != x0, AVL = rs1 的值
          endcase

          inst_config_state[i+1].lmul_orig = RVVLMUL'(inst_q[i].bits[15:13]);
          inst_config_state[i+1].sew = RVVSEW'(inst_q[i].bits[18:16]);
          inst_config_state[i+1].ta = inst_q[i].bits[19];
          inst_config_state[i+1].ma = inst_q[i].bits[20];
          is_setvl[i] = 1;
        end else if (inst_q[i].bits[24:23] == 2'b11) begin  // vsetivli
          avl[i] =
              {{(`VL_WIDTH - 5){1'b0}}, inst_q[i].bits[12:8]};  //AVL 来自指令中的 5-bit 立即数。
          inst_config_state[i+1].lmul_orig = RVVLMUL'(inst_q[i].bits[15:13]);
          inst_config_state[i+1].sew = RVVSEW'(inst_q[i].bits[18:16]);
          inst_config_state[i+1].ta = inst_q[i].bits[19];
          inst_config_state[i+1].ma = inst_q[i].bits[20];
          is_setvl[i] = 1;
        end else if (inst_q[i].bits[24:23] == 2'b10) begin  // vsetvl
          // 根据 RVV 规范 6.2 的编码规则确定 AVL。
          unique case (inst_q[i].bits[12:8])  //rs1
            0: unique case (inst_q[i].bits[4:0])  //rd
              0:  avl[i] = inst_config_state[i].vl;  // rd = x0, rs1 = x0
              default: avl[i] = 32'hFFFFFFFF;        // rd != x0, rs1 = x0
            endcase
            default: avl[i] = reg_read_data_i[2*i];  // rs1 != x0, vsetvl 的 AVL 来自 rs1，vtype 来自 rs2。
          endcase
          //vtype 来自 rs2
          inst_config_state[i+1].lmul_orig =
              RVVLMUL'(reg_read_data_i[(2*i) + 1][2:0]);
          inst_config_state[i+1].sew =
              RVVSEW'(reg_read_data_i[(2*i) + 1][5:3]);
          inst_config_state[i+1].ta = reg_read_data_i[(2*i) + 1][6];
          inst_config_state[i+1].ma = reg_read_data_i[(2*i) + 1][7];
          is_setvl[i] = 1;
        end
      end

      if (is_setvl[i]) begin
        // 检查 vtype 合法性；非法组合会置 vill。
        // LMUL1=0,
        // LMUL2=1,
        // LMUL4=2,
        // LMUL8=3,
        // LMULRESERVED=4,
        // LMUL1_8=5, // 1/8
        // LMUL1_4=6, // 1/4
        // LMUL1_2=7  // 1/2
        // | SEW    | 不允许的 LMUL               |
        // | ------ | ----------------------- |
        // | SEW8   | reserved, mf8           |
        // | SEW16  | reserved, mf8, mf4      |
        // | SEW32  | reserved, mf8, mf4, mf2 |
        // | 其他 SEW | 直接 illegal              |
        //这里的限制意味着该实现不支持某些 fractional LMUL 组合。例如 SEW32 下不能低于 LMUL1。
        unique case (inst_config_state[i+1].sew)
          SEW8:
            unique case(inst_config_state[i+1].lmul_orig)
              LMULRESERVED: inst_config_state[i+1].vill = 1;
              LMUL1_8: inst_config_state[i+1].vill = 1;
              default: inst_config_state[i+1].vill = 0;
            endcase
          SEW16:
            unique case(inst_config_state[i+1].lmul_orig)
              LMULRESERVED: inst_config_state[i+1].vill = 1;
              LMUL1_8: inst_config_state[i+1].vill = 1;
              LMUL1_4: inst_config_state[i+1].vill = 1;
              default: inst_config_state[i+1].vill = 0;
            endcase
          SEW32:
            unique case(inst_config_state[i+1].lmul_orig)
              LMULRESERVED: inst_config_state[i+1].vill = 1;
              LMUL1_8: inst_config_state[i+1].vill = 1;
              LMUL1_4: inst_config_state[i+1].vill = 1;
              LMUL1_2: inst_config_state[i+1].vill = 1;
              default: inst_config_state[i+1].vill = 0;
            endcase
          default: inst_config_state[i+1].vill = 1;
        endcase

        // 计算 vlmax，并在必要时把 vl 饱和到 vlmax。
        // vlmax = VLENB × LMUL / SEW_bytes
        // 所以用右移实现除以元素 byte 数。
        unique case (inst_config_state[i+1].lmul_orig)
          LMUL1_8: vlmax[i] = ((`VLENB)/8) >> inst_config_state[i+1].sew;
          LMUL1_4: vlmax[i] = ((`VLENB)/4) >> inst_config_state[i+1].sew;
          LMUL1_2: vlmax[i] = ((`VLENB)/2) >> inst_config_state[i+1].sew;
          LMUL1: vlmax[i] = (`VLENB) >> inst_config_state[i+1].sew;
          LMUL2: vlmax[i] = (2*(`VLENB)) >> inst_config_state[i+1].sew;
          LMUL4: vlmax[i] = (4*(`VLENB)) >> inst_config_state[i+1].sew;
          LMUL8: vlmax[i] = (8*(`VLENB)) >> inst_config_state[i+1].sew;
          default: vlmax[i] = 0;
        endcase

        if (inst_config_state[i+1].vill) begin
          // vtype 非法时 vl 置 0，符合 RVV 规范 6.1 末尾建议。
          inst_config_state[i+1].vl = 0;
        end else if (avl[i] > vlmax[i]) begin
          // RVV 规范 6.3 允许的一种实现：AVL 超过 vlmax 时取 vlmax。
          inst_config_state[i+1].vl = vlmax[i];
        end else begin
          inst_config_state[i+1].vl = avl[i];
        end

        inst_config_state[i+1].lmul = inst_config_state[i+1].lmul_orig;

        // TODO: filter out illegal lmul for widening ALU ops and non-indexed
        // LSU ops where eew>sew.
        if (REDUCE_LMUL) begin
          // 使用已经限制到 vlmax 内的 vl 反推更小 LMUL；
          // 这里只会减小或保持 LMUL，不会放大，因此不会引入新的 emul>8 问题。
          // 同时仍需保证结果 LMUL 对当前 SEW 合法，例如 sew=e32 时不能低于 m1。
          // | SEW   | 最小允许 LMUL   |
          // | ----- | ----------- |
          // | SEW8  | 最小到 LMUL1/4 |
          // | SEW16 | 最小到 LMUL1/2 |
          // | SEW32 | 最小到 LMUL1   |
          vl_minus_one[i] = (inst_config_state[i+1].vl == (`VL_WIDTH)'('b0)) ?
              (`VL_WIDTH)'('b0) :
              inst_config_state[i+1].vl - (`VL_WIDTH)'('b1);
          unique case (inst_config_state[i+1].sew)
            SEW8: begin
              if (vl_minus_one[i][`VL_WIDTH-2+:2] != 'b00) begin
                // vl 位于 VLEN/2+1 到 VLEN。
                inst_config_state[i+1].lmul = LMUL8;
              end else if (vl_minus_one[i][`VL_WIDTH-3] == 'b1) begin
                // vl 位于 VLEN/4+1 到 VLEN/2。
                inst_config_state[i+1].lmul = LMUL4;
              end else if (vl_minus_one[i][`VL_WIDTH-4] == 'b1) begin
                // vl 位于 VLEN/8+1 到 VLEN/4。
                inst_config_state[i+1].lmul = LMUL2;
              end else if (vl_minus_one[i][`VL_WIDTH-5] == 'b1) begin
                // vl 位于 VLEN/16+1 到 VLEN/8。
                inst_config_state[i+1].lmul = LMUL1;
              end else if (vl_minus_one[i][`VL_WIDTH-6] == 'b1) begin
                // vl 位于 VLEN/32+1 到 VLEN/16。
                inst_config_state[i+1].lmul = LMUL1_2;
              end else begin
                // vl 位于 0 到 VLEN/32。
                inst_config_state[i+1].lmul = LMUL1_4;
              end
            end
            SEW16: begin
              if (vl_minus_one[i][`VL_WIDTH-3+:2] != 'b00) begin
                // vl 位于 VLEN/4+1 到 VLEN/2。
                inst_config_state[i+1].lmul = LMUL8;
              end else if (vl_minus_one[i][`VL_WIDTH-4] == 'b1) begin
                // vl 位于 VLEN/8+1 到 VLEN/4。
                inst_config_state[i+1].lmul = LMUL4;
              end else if (vl_minus_one[i][`VL_WIDTH-5] == 'b1) begin
                // vl 位于 VLEN/16+1 到 VLEN/8。
                inst_config_state[i+1].lmul = LMUL2;
              end else if (vl_minus_one[i][`VL_WIDTH-6] == 'b1) begin
                // vl 位于 VLEN/32+1 到 VLEN/16。
                inst_config_state[i+1].lmul = LMUL1;
              end else begin
                // vl 位于 0 到 VLEN/32。
                inst_config_state[i+1].lmul = LMUL1_2;
              end
            end
            SEW32: begin
              if (vl_minus_one[i][`VL_WIDTH-4+:2] != 'b00) begin
                // vl 位于 VLEN/8+1 到 VLEN/4。
                inst_config_state[i+1].lmul = LMUL8;
              end else if (vl_minus_one[i][`VL_WIDTH-5] == 'b1) begin
                // vl 位于 VLEN/16+1 到 VLEN/8。
                inst_config_state[i+1].lmul = LMUL4;
              end else if (vl_minus_one[i][`VL_WIDTH-6] == 'b1) begin
                // vl 位于 VLEN/32+1 到 VLEN/16。
                inst_config_state[i+1].lmul = LMUL2;
              end else begin
                // vl 位于 0 到 VLEN/32。
                inst_config_state[i+1].lmul = LMUL1;
              end
            end
          endcase
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      // RVV 规范 3.11 建议复位后 vill=1，其余 vtype 位和 vl 清 0。
      config_state_q.vill <= 1;
      config_state_q.vl <= 0;
      config_state_q.vstart <= 0;
      config_state_q.ma <= 0;
      config_state_q.ta <= 0;
      config_state_q.xrm <= RNU;
      config_state_q.xsat <= 0;
`ifdef ZVE32F_ON
      config_state_q.frm <= RVFRM'('0);
`endif  // ZVE32F_ON
      config_state_q.sew <= SEW8;
      config_state_q.lmul <= LMUL1;
    end else begin
      // 下一拍提交本拍按 lane 顺序计算出的最终配置状态。
      config_state_q <= inst_config_state[N];
    end
  end

  // 生成命令输出和前端早期 trap。非 vset* 指令在 vill=1 时不进入后端，而是直接报 trap。
  logic [N-1:0] unaligned_cmd_valid;
  RVVCmd [N-1:0] unaligned_cmd_data;
  logic [N-1:0] unaligned_trap_valid;  // 该指令是否需要触发前端 trap。
  RVVInstruction [N-1:0] unaligned_trap_data;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      unaligned_trap_valid[i] = valid_inst_q[i] && !is_setvl[i] &&
          inst_config_state[i+1].vill;  //vill 状态下，普通向量指令非法，必须先执行合法的 vset* 恢复配置
      unaligned_trap_data[i] = inst_q[i];
      unaligned_cmd_valid[i] = valid_inst_q[i] && !is_setvl[i] &&
          !inst_config_state[i+1].vill;  //暂存指令有效,不是 vset* 配置指令,当前 vtype 合法

      // 将原始指令和更新后的架构状态组合成后端命令。
`ifdef TB_SUPPORT
      unaligned_cmd_data[i].inst_pc = inst_q[i].pc;
`endif
      //普通 RVV 指令输出给后端
      unaligned_cmd_data[i].opcode = inst_q[i].opcode;  //原始 opcode
      unaligned_cmd_data[i].bits = inst_q[i].bits;      //原始指令 bits
      unaligned_cmd_data[i].arch_state = inst_config_state[i+1];  //当前指令对应的 RVV 架构状态
      // TODO: 继续完善 load/store 的 rs 传播。
      // funct3 == inst[14:12] == bits[7:5]；bits[7] 表示需要标量 rs1
      // (OPIVX/OPFVF/OPMVX/OPCFG)。其中 OPFVF 的标量来自浮点寄存器堆。
      unaligned_cmd_data[i].rs1 =
          inst_q[i].bits[7] ?  
              ((inst_q[i].bits[7:5] == 3'b101) ? freg_read_data_i[i]  // OPFVF
                                               : reg_read_data_i[2*i])
            : 0;

      // 配置指令把新 vl 写入 rd。
      reg_write_valid_o[i] = is_setvl[i];
      reg_write_addr_o[i] = inst_q[i].bits[4:0];
      reg_write_data_o[i] =
          {{(`XLEN-`VL_WIDTH){1'b0}}, inst_config_state[i+1].vl};
    end
  end

  // 压紧输出 lane，保证后端看到的是从 lane0 开始连续有效的命令。
  Aligner#(.T(RVVCmd), .N(N)) cmd_aligner(
      .valid_in(unaligned_cmd_valid),
      .data_in(unaligned_cmd_data),
      .valid_out(cmd_valid_o),
      .data_out(cmd_data_o)
  );

  // 选择最靠前的 trap 指令上报给标量侧 fault/trap 管理逻辑。
  logic trap_occurred;
  RVVInstruction trap_data;
  assign trap_valid_o = trap_occurred;
  assign trap_data_o = trap_data;
  always_comb begin
    trap_occurred = (unaligned_trap_valid != 0);
    // 默认填 0，避免无 trap 时输出保留旧值。
    trap_data.pc = '0;
    trap_data.bits = '0;
    trap_data.opcode = RVV;

    for (int i = 0; i < N; i++) begin
      if (unaligned_trap_valid[i]) begin
        trap_occurred = 1'b1;
        trap_data = unaligned_trap_data[i];
        break;
      end
    end
  end

  // Assertions
  // 非综合代码中有断言，用来检查需要 rs1/rs2 的指令是否拿到了寄存器读数据。
`ifndef SYNTHESIS
  logic [N-1:0] lsu_requires_rs1_read;
  logic [N-1:0] non_lsu_requires_rs1_read;
  logic [N-1:0] requires_rs1_read;
  logic [N-1:0] lsu_requires_rs2_read;
  logic [N-1:0] non_lsu_requires_rs2_read;
  logic [N-1:0] requires_rs2_read;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      // 所有 LSU 指令都读取 rs1。
      lsu_requires_rs1_read[i] = (inst_q[i].opcode != RVV);  //非 RVV opcode 在这里被当成 LSU 类指令，默认需要 rs1。
      // 非 LSU 指令中需要 rs1 的类别。
      non_lsu_requires_rs1_read[i] = (inst_q[i].opcode == RVV) && (
        (inst_q[i].bits[7:5] == 'b100) ||  // OPIVX
        (inst_q[i].bits[7:5] == 'b110) ||  // OPMVX
        ((inst_q[i].bits[7:5] == 'b111) && (inst_q[i].bits[24:23] != 2'b11))  // vsetvl and vsetvli
      );
      requires_rs1_read[i] =
          lsu_requires_rs1_read[i] || non_lsu_requires_rs1_read[i];

      // 只有 strided load/store (mop=0b10) 读取 rs2。
      lsu_requires_rs2_read[i] = (inst_q[i].opcode != RVV) &&
          (inst_q[i].bits[20:19] == 2'b10);
      // 非 LSU 指令中只有 vsetvl 读取 rs2。
      non_lsu_requires_rs2_read[i] = (inst_q[i].opcode == RVV) &&
          (inst_q[i].bits[7:5] == 3'b111) &&
          (inst_q[i].bits[24:18] == 7'b1000000);
      requires_rs2_read[i] =
          lsu_requires_rs2_read[i] || non_lsu_requires_rs2_read[i];
    end
  end

  always @(posedge clk) begin
    for (int i = 0; i < N; i++) begin
      assert(!valid_inst_q[i] || !requires_rs1_read[i] ||
              reg_read_valid_i[2*i]);
      assert(!valid_inst_q[i] || !requires_rs2_read[i] ||
              reg_read_valid_i[(2*i) + 1]);
    end
  end
`endif  // not def SYNTHESIS
endmodule
