`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
//------------------------------------------------------------------------------
// rvv_backend_lsu_remap
//------------------------------------------------------------------------------
// 功能定位：
// 1. LSU 返回结果重映射模块，位于 RVV 后端 LSU 返回路径。
// 2. LSU 执行时会把访存请求发往标量/共享 LSU，同时本地保存一份 `LSU_MAP_INFO_t`。
//    返回时，本模块把 `UOP_LSU_t` 与对应 mapinfo 配对，恢复原 ROB entry、
//    目的向量寄存器写回地址等信息。
// 3. load 完成并且 LSU 返回的写寄存器地址与 mapinfo 中记录的地址一致时，
//    生成 `PU2ROB_t` 写回；store 只在 `lsu_vstore_last` 时生成完成通知。
// 4. 若 LSU 返回 trap，本模块不写普通结果，而是把 mapinfo 中的 ROB entry
//    送给 ROB trap 入口，等待 ROB/Fault 路径处理并触发 flush。
//
// 握手关系：
// - `pop_mapinfo` 和 `pop_lsu_res` 同步拉高，表示该 lane 的 mapinfo 与 LSU 返回项同时消费。
// - 普通结果路径受 `result_ready[i]` 控制。
// - trap 路径受 `trap_ready_rob2rmp` 控制，避免 trap entry 被提前丢弃。

module rvv_backend_lsu_remap
(
  mapinfo_valid,
  mapinfo,
  pop_mapinfo,
  lsu_res_valid,
  lsu_res,
  pop_lsu_res,
  result_valid,
  result,
  result_ready,
  trap_valid_rmp2rob,
  trap_rob_entry_rmp2rob,
  trap_ready_rob2rmp
);

//
// 接口信号
//
  // mapinfo 与 LSU 返回结果是一一配对的两条 FIFO/队列输出。
  input   logic           [`NUM_LSU-1:0]  mapinfo_valid;
  input   LSU_MAP_INFO_t  [`NUM_LSU-1:0]  mapinfo;
  output  logic           [`NUM_LSU-1:0]  pop_mapinfo;
  input   logic           [`NUM_LSU-1:0]  lsu_res_valid;
  input   UOP_LSU_t       [`NUM_LSU-1:0]  lsu_res;
  output  logic           [`NUM_LSU-1:0]  pop_lsu_res;

  // 普通 load/store 完成结果输出给 ROB 写回通路。
  output  logic           [`NUM_LSU-1:0]  result_valid;
  output  PU2ROB_t        [`NUM_LSU-1:0]  result;
  input   logic           [`NUM_LSU-1:0]  result_ready;

  // LSU 晚发现异常输出给 ROB trap 通路。
  output  logic                           trap_valid_rmp2rob;
  output  logic   [`ROB_DEPTH_WIDTH-1:0]  trap_rob_entry_rmp2rob;
  input   logic                           trap_ready_rob2rmp;   

//
// 内部信号
//
  genvar                i;

//
// 结果与 trap 重映射逻辑
//
  // 普通结果有效条件：
  // - mapinfo 和 LSU result 都有效。
  // - mapinfo.valid 表示该映射项确实对应一条需要 ROB 完成的 RVV LSU uop。
  // - trap 时不走普通结果。
  // - load 需要 LSU 返回向量寄存器写有效；store 需要最后一个 store beat 完成。
  generate
    for(i=0;i<`NUM_LSU;i++) begin: RES_VALID
      assign result_valid[i] = mapinfo_valid[i]&lsu_res_valid[i]&mapinfo[i].valid&(!lsu_res[i].trap_valid)&(
                               (mapinfo[i].lsu_class==IS_LOAD) & lsu_res[i].uop_lsu2rvv.vregfile_write_valid || 
                               (mapinfo[i].lsu_class==IS_STORE) & lsu_res[i].uop_lsu2rvv.lsu_vstore_last);
    end
  endgenerate

  // 将 LSU 返回数据重新包装成 PU2ROB_t。load 才写 w_data；store 的 w_valid 为 0，
  // 但仍可通过 result_valid 通知 ROB 该 store uop 完成。
  generate
    for(i=0;i<`NUM_LSU;i++) begin: GET_RESULT
      `ifdef TB_SUPPORT
        assign result[i].uop_pc    = mapinfo[i].uop_pc;
      `endif
        assign result[i].rob_entry = mapinfo[i].rob_entry;
        assign result[i].w_data    = lsu_res[i].uop_lsu2rvv.vregfile_write_data;
        assign result[i].w_valid   = (mapinfo[i].lsu_class==IS_LOAD)&
                                     lsu_res[i].uop_lsu2rvv.vregfile_write_valid&
                                     (lsu_res[i].uop_lsu2rvv.vregfile_write_addr==mapinfo[i].vregfile_write_addr);
        assign result[i].vsaturate = 'b0;
      `ifdef ZVE32F_ON
        assign result[i].fpexp     = 'b0;
      `endif
    end
  endgenerate

  always_comb begin
    // 多个 LSU lane 同时 trap 时，这里后面的 lane 会覆盖前面的 ROB entry。
    // 现有 RTL 保持这种优先关系；上层通常依赖同周期不会产生多个待处理 trap。
    trap_valid_rmp2rob = 'b0;
    trap_rob_entry_rmp2rob = 'b0;

    for (int j=0;j<`NUM_LSU;j++) begin
      if (lsu_res[j].trap_valid&lsu_res_valid[j]&mapinfo_valid[j]) begin
        trap_valid_rmp2rob     = 'b1;
        trap_rob_entry_rmp2rob = mapinfo[j].rob_entry;
      end
    end
  end

  // 普通路径在 ROB 接收结果后 pop；trap 路径在 ROB trap 通路 ready 后 pop。
  generate
    for(i=0;i<`NUM_LSU;i++) begin: GET_POP
      assign pop_mapinfo[i] = (!lsu_res[i].trap_valid)&result_valid[i]&result_ready[i]||
                                lsu_res[i].trap_valid&mapinfo_valid[i]&lsu_res_valid[i]&trap_ready_rob2rmp;
      assign pop_lsu_res[i] = pop_mapinfo[i];
    end
  endgenerate


endmodule
