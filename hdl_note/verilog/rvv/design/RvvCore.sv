// ============================================================================
// RvvCore.sv — RVV 向量核心顶层 (实例化 FrontEnd + Backend)
// ============================================================================
// 本文件是标量核和 RVV 后端之间的包装层：
//   1. 前端 RvvFrontEnd 接收 decode 发来的 RVV/向量访存指令，并维护 vl/vtype/vcsr
//      这类架构状态；
//   2. 后端 rvv_backend 负责命令队列、二级 decode、dispatch、执行、ROB 和退役；
//   3. 顶层在这里把 RVV 与 LSU、标量寄存器堆、浮点寄存器堆、VCSR 的接口拆包/打包；
//   4. 注意这里的 trap_valid_rvs2rvv 目前被 tie-off，外部 trap 注入后端的路径未启用。
// Copyright 2025 Google LLC
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

module RvvCore #(parameter N = 4,
                 parameter CMD_BUFFER_MAX_CAPACITY = 16,  //命令缓冲最大容量参数
                 type RegDataT=logic [31:0],
                 type VRegDataT=logic [127:0],
                 type RegAddrT=logic [4:0],
                 type MaskT=logic [15:0]
                 )
(
  input clk,
  input rstn,

  // 输入 CSR 状态
  input logic [`VSTART_WIDTH-1:0] vstart,
  input logic [1:0] vxrm,
  input logic vxsat,
  input logic [2:0] frm,

  // decode/RVS 输入的指令 bundle，一拍最多 N 条。
  input logic [N-1:0] inst_valid, 
  input RVVInstruction [N-1:0] inst_data,  //pc + opcode + bits(除了opcode外的所有字段)
  output logic [N-1:0] inst_ready,

  // 标量寄存器堆读口：每条指令预留 rs1/rs2 两个读数据。
  // 用于：
  // vsetvl
  // vector-scalar 整数操作
  // strided load/store 的 stride
  // indexed/地址相关配置
  input logic [(2*N)-1:0] reg_read_valid,
  input RegDataT [(2*N)-1:0] reg_read_data,

  // 浮点寄存器堆读口：OPFVF 等指令把浮点标量作为 rs1 操作数。
  // 每条 RVV 指令最多一个浮点标量源
  input RegDataT [N-1:0] freg_read_data,

  // vsetvl/vsetvli/vsetivli 的 rd 写回：写入新 vl。
  // vsetvli rd, rs1, vtype, 它需要把新 vl 写回整数寄存器。
  // 这条路径是 前端同步写回路径，和后端 retire 的异步写回路径不同。
  output logic [N-1:0] reg_write_valid,
  output RegAddrT [N-1:0] reg_write_addr,
  output RegDataT [N-1:0] reg_write_data,

  // 非配置类向量指令退役后写回标量整数寄存器。
  // 典型来源包括：
  // vmv.x.s
  // vcpop.m
  // vfirst.m
  // reduction 结果
  // 其他 vector-to-scalar 结果
  output logic async_rd_valid,
  output RegAddrT async_rd_addr,
  output RegDataT async_rd_data,
  input logic async_rd_ready,

  // 浮点向量指令退役后写回标量浮点寄存器。
  // 例如某些：
  // vector-to-float-scalar
  // floating reduction
  output logic async_frd_valid,
  output RegAddrT async_frd_addr,
  output RegDataT async_frd_data,
  input logic async_frd_ready,

  // RVV 发给标量 LSU 的向量访存 uop，包含索引向量、写数据向量和 v0 mask。
  output  logic     [`NUM_LSU-1:0] uop_lsu_valid_rvv2lsu,            //RVV 有访存 uop 发给 LSU
  output  logic     [`NUM_LSU-1:0] uop_lsu_idx_valid_rvv2lsu,        //indexed load/store 的 index vector
  output  RegAddrT  [`NUM_LSU-1:0] uop_lsu_idx_addr_rvv2lsu,
  output  VRegDataT [`NUM_LSU-1:0] uop_lsu_idx_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_vregfile_valid_rvv2lsu,   //vector store 的源向量数据
  output  RegAddrT  [`NUM_LSU-1:0] uop_lsu_vregfile_addr_rvv2lsu,
  output  VRegDataT [`NUM_LSU-1:0] uop_lsu_vregfile_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_v0_valid_rvv2lsu,         //v0 mask
  output  MaskT     [`NUM_LSU-1:0] uop_lsu_v0_data_rvv2lsu,
  input   logic     [`NUM_LSU-1:0] uop_lsu_ready_lsu2rvv,            //LSU 是否接收

  // LSU 返回给 RVV 的访存结果：地址/写回数据/last 标记。
  // last = 0 → vector load 返回数据，需要写 vregfile
  // last = 1 → vector store 完成通知，不写 vregfile
  input  logic     [`NUM_LSU-1:0] uop_lsu_valid_lsu2rvv,             //LSU 返回有效
  input  RegAddrT  [`NUM_LSU-1:0] uop_lsu_addr_lsu2rvv,              //要写回的向量寄存器地址
  input  VRegDataT [`NUM_LSU-1:0] uop_lsu_wdata_lsu2rvv,             //vector load 返回数据
  input  logic     [`NUM_LSU-1:0] uop_lsu_last_lsu2rvv,              //是否最后一个 store 完成通知
  output logic     [`NUM_LSU-1:0] uop_lsu_ready_rvv2lsu,             //RVV 后端是否接收返回

  // 后端退役侧写回最新 vector CSR 状态。
  output vcsr_valid,
  output RVVConfigState vector_csr,
  input vcsr_ready,

  // 前端暴露当前配置状态，供上层观察/CSR 汇合使用。
  output config_state_valid,
  output RVVConfigState config_state,

  // 空闲与队列容量反馈：queue_capacity 用于反压 decode/RVS。
  output logic rvv_idle,
  output logic [$clog2(2*N + 1)-1:0] queue_capacity,

  // ROB 到退役级的调试/观察输出。
  // 给外部调试、RVVI、RetirementBuffer 或 trace 观察 RVV 退役 uop。
  output ROB2RT_t [`NUM_RT_UOP-1:0] rd_rob2rt_o,
  output logic    [`NUM_RT_UOP-1:0] rd_valid_rob2rt_o,

  // 前端检测到的非法 vtype 使用等早期 trap 输出。
  // 这是 RvvFrontEnd 检测到的早期异常输出。
  output logic trap_valid_o,
  output RVVInstruction trap_data_o,

  // 后端退役时更新 CSR 中的 vxsat，避免饱和标志只在内部连线悬空。
  output logic                            wr_vxsat_valid_o,
  output logic    [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat_o
);
  logic [N-1:0] frontend_cmd_valid;  //前端生成的 RVV 命令有效
  RVVCmd [N-1:0] frontend_cmd_data;  //前端生成的 RVVCmd
  logic [$clog2(2*N + 1)-1:0] queue_capacity_internal;  //后端实际可接收容量，反馈给前端

  // 前端把原始指令、标量操作数和当前 vtype/vl 合成 RVVCmd；
  // queue_capacity_internal 反映后端 CQ 的可接收空间，防止前端超过后端容量。
  // 前端处理配置、操作数、早期非法检查
  RvvFrontEnd#(.N(N)) frontend(
      .clk(clk),
      .rstn(rstn),
      .vstart_i(vstart),
      .vxrm_i(vxrm),
      .vxsat_i(vxsat),
      .frm_i(frm),
      .inst_valid_i(inst_valid),
      .inst_data_i(inst_data),
      .inst_ready_o(inst_ready),
      .reg_read_valid_i(reg_read_valid),
      .reg_read_data_i(reg_read_data),
      .freg_read_data_i(freg_read_data),
      .reg_write_valid_o(reg_write_valid),  //输出 vsetvl 类同步写回
      .reg_write_addr_o(reg_write_addr),
      .reg_write_data_o(reg_write_data),
      .cmd_valid_o(frontend_cmd_valid),  //输出给后端
      .cmd_data_o(frontend_cmd_data),    //输出给后端
      .queue_capacity_i(queue_capacity_internal),
      .queue_capacity_o(queue_capacity),
      .trap_valid_o(trap_valid_o),
      .trap_data_o(trap_data_o),
      .config_state_valid(config_state_valid),  //输出当前配置状态到外部IO
      .config_state(config_state)               //输出当前配置状态到外部IO
  );

  // Backpressure from backend fifo
  logic   [$clog2(`CQ_DEPTH):0] remaining_count_cq2rvs;  //后端命令队列剩余空间
  // Back-pressure frontend
  // 即使后端 CQ 剩余很多，前端最多也只看到 8 个空位。
  always_comb begin
    if (remaining_count_cq2rvs > 2*N) begin
      queue_capacity_internal = 2*N;
    end else begin
      queue_capacity_internal = remaining_count_cq2rvs;
    end
  end

  // Back-end ============================================================

  // LSU Tie-offs
  // RVV send LSU uop to RVS
  // RVV → LSU bundle 拆包
    UOP_RVV2LSU_t     [`NUM_LSU-1:0]          uop_lsu_rvv2lsu;
    always_comb begin
      for (int i = 0; i < `NUM_LSU; i++) begin
        uop_lsu_idx_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_valid;
        uop_lsu_idx_addr_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_addr;
        uop_lsu_idx_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_data;
        uop_lsu_vregfile_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_valid;
        uop_lsu_vregfile_addr_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_addr;
        uop_lsu_vregfile_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_data;
        uop_lsu_v0_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].v0_valid;
        uop_lsu_v0_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].v0_data;
      end
    end

  // LSU feedback to RVV
  // LSU → RVV bundle 打包
    UOP_LSU2RVV_t     [`NUM_LSU-1:0]          uop_lsu_lsu2rvv;
    always_comb begin
      for (int i = 0; i < `NUM_LSU; i++) begin
        `ifdef TB_SUPPORT
              uop_lsu_lsu2rvv[i].uop_pc = 0;
              uop_lsu_lsu2rvv[i].uop_index = 0;
        `endif

        uop_lsu_lsu2rvv[i].vregfile_write_valid = (
            uop_lsu_valid_lsu2rvv[i] && !uop_lsu_last_lsu2rvv[i]);  //如果 LSU 返回 valid 且 last=0，则这是 vector load 数据，需要写回向量寄存器。
        uop_lsu_lsu2rvv[i].vregfile_write_addr = uop_lsu_addr_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].vregfile_write_data = uop_lsu_wdata_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].lsu_vstore_last = (
            uop_lsu_valid_lsu2rvv[i] && uop_lsu_last_lsu2rvv[i]);  //如果 LSU 返回 valid 且 last=1，则这是 vector store 的最后完成通知。
      end
    end

  // Scalar regfile write-back tie-offs
  // TODO(derekjchow): Properly arbitrate write-back tie-offs by extending
  // interface. For time being, only accept from slot 0.
  // 这是后端 retire 到标量核的写回接口。
  logic    [`NUM_RT_UOP-1:0] rt_xrf_valid_rvv2rvs;
  RT2RVS_t [`NUM_RT_UOP-1:0] rt_rvs_rvv2rvs;
  logic    [`NUM_RT_UOP-1:0] rt_rvs_ready_rvs2rvv;

  // 当前顶层只接受 retire slot 0 的整数标量写回。
  // 其他 retire slot 的 ready 固定为 0。
  always_comb begin
    rt_rvs_ready_rvs2rvv[0] = async_rd_ready;
    async_rd_valid = rt_xrf_valid_rvv2rvs[0];
    async_rd_addr = rt_rvs_rvv2rvs[0].rt_index;
    async_rd_data = rt_rvs_rvv2rvs[0].rt_data;
    for (int i = 1; i < `NUM_RT_UOP; i++) begin
      rt_rvs_ready_rvs2rvv[i] = 0;
    end
  end

  // Floating point regfile write-back
  // 后端到浮点标量寄存器的异步写回接口。
  // 同样只把第 0 路浮点 retire 写回导出。
  logic [`NUM_RT_UOP-1:0]                           rvv2rvs_frd_valid;
  logic [`NUM_RT_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] rvv2rvs_frd_addr;
  logic [`NUM_RT_UOP-1:0][`XLEN-1:0]                rvv2rvs_frd_data;
  logic [`NUM_RT_UOP-1:0]                           rvv2rvs_frd_ready;
  always_comb begin
    rvv2rvs_frd_ready[0] = async_frd_ready;
    rvv2rvs_frd_ready[1] = 0;
  end
  assign async_frd_valid = rvv2rvs_frd_valid[0];
  assign async_frd_addr = rvv2rvs_frd_addr[0];
  assign async_frd_data = rvv2rvs_frd_data[0];

  // Backpressure
  // 后端产生 vxsat 更新时，顶层总是 ready。
  logic wr_vxsat_ready;
  always_comb begin
    // TODO(derekjchow): Actually accept
    wr_vxsat_ready = 1;
  end

  // VCSR.vxsat 更新，由后端 retire 产生。
  logic                            wr_vxsat_valid;
  logic    [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;

  // FCSR 更新握手；当前顶层直接 ready，实际接收侧仍待完善。
  // 需要 ZVE32F_ON
  logic    rt2fcsr_write_valid;
  RVFEXP_t rt2fcsr_write_data;
  logic    fcsr2rt_write_ready;
  always_comb begin
    // TODO(derekjchow): 后续需要真正接收并使用 FCSR 更新。
    fcsr2rt_write_ready = 1;
  end

  // 外部 trap 注入 RVV 后端的入口。当前顶层固定为 0，
  // 因此后端只会处理内部 LSU remap/ROB 路径产生的 trap 事件。
  logic  trap_valid_rvs2rvv;
  logic  trap_ready_rvv2rvs;
  always_comb begin
    trap_valid_rvs2rvv = 0;
  end

  logic   [`ISSUE_LANE-1:0] insts_ready_cq2rvs;         //
  logic rvv_backend_idle;                               //后端空闲
  assign rvv_idle = rvv_backend_idle && (frontend_cmd_valid == 0);

  // RVV 后端包含命令队列、二级 decode、uop 队列、保留站、执行单元、ROB 和 retire。
  rvv_backend backend(
      .clk(clk),
      .rst_n(rstn),
      // 前端到后端命令
      // RvvFrontEnd 生成 RVVCmd；
      // rvv_backend 的 command queue 接收 RVVCmd；
      // backend 返回剩余容量 remaining_count_cq2rvs。
      .insts_valid_rvs2cq(frontend_cmd_valid),
      .insts_rvs2cq(frontend_cmd_data),
      .insts_ready_cq2rvs(insts_ready_cq2rvs),  //未连接
      .remaining_count_cq2rvs(remaining_count_cq2rvs),
      //RVV 后端到 LSU
      .uop_lsu_valid_rvv2lsu(uop_lsu_valid_rvv2lsu),
      .uop_lsu_rvv2lsu(uop_lsu_rvv2lsu),
      .uop_lsu_ready_lsu2rvv(uop_lsu_ready_lsu2rvv),
      //LSU 返回到后端
      .uop_lsu_valid_lsu2rvv(uop_lsu_valid_lsu2rvv),
      .uop_lsu_lsu2rvv(uop_lsu_lsu2rvv),
      .uop_lsu_ready_rvv2lsu(uop_lsu_ready_rvv2lsu),
      //后端 retire 产生标量整数写回。
      .rt_rvs_rvv2rvs(rt_rvs_rvv2rvs),
      .rt_xrf_valid_rvv2rvs(rt_xrf_valid_rvv2rvs),
      .rt_rvs_ready_rvs2rvv(rt_rvs_ready_rvs2rvv),

`ifdef ZVE32F_ON
      .async_frd_valid(rvv2rvs_frd_valid),
      .async_frd_addr(rvv2rvs_frd_addr),
      .async_frd_data(rvv2rvs_frd_data),
      .async_frd_ready(rvv2rvs_frd_ready),
`endif
      //后端退役时产生 VXSAT 更新。
      .wr_vxsat_valid(wr_vxsat_valid),
      .wr_vxsat(wr_vxsat),
      .wr_vxsat_ready(wr_vxsat_ready),

`ifdef ZVE32F_ON
      .rt2fcsr_write_valid(rt2fcsr_write_valid),
      .rt2fcsr_write_data(rt2fcsr_write_data),
      .fcsr2rt_write_ready(fcsr2rt_write_ready),
`endif
      //由于 trap_valid_rvs2rvv = 0，外部 trap 注入当前不会发生。
      .trap_valid_rvs2rvv(trap_valid_rvs2rvv),
      .trap_ready_rvv2rvs(trap_ready_rvv2rvs),
      //VCSR 与 ROB 输出
      .vcsr_valid(vcsr_valid),  //后端提交的 vector CSR 状态
      .vector_csr(vector_csr),
      .vcsr_ready(vcsr_ready),
      .rd_valid_rob2rt_o(rd_valid_rob2rt_o),  //ROB 到 retire/debug 的观察输出
      .rvv_idle(rvv_backend_idle),            //后端是否空闲
      .rd_rob2rt_o(rd_rob2rt_o)               //ROB 到 retire/debug 的观察输出
  );

  // 将后端退役产生的 vxsat 更新导出给上层 CSR。
  assign wr_vxsat_valid_o = wr_vxsat_valid;
  assign wr_vxsat_o = wr_vxsat;

endmodule
