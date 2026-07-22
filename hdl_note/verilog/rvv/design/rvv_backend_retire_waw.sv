
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
// 功能说明：
// 1. Retire 阶段的同拍 VRF WAW 合并单元。
// 2. 输入是一组按程序顺序排列的待退役 lane，其中最后一个 lane 是“当前检查的年轻 lane”。
// 3. 如果更老 lane 和当前年轻 lane 写同一个向量寄存器，则更老 lane 不再单独写 VRF；
//    它的有效 byte 会被合并到当前年轻 lane 的写数据中。
// 4. 合并粒度是 byte strobe：只有 w_strobe 为 1 的 byte 才覆盖 res/res_strobe。
// 5. waw 输出标记哪些更老 lane 被当前年轻 lane 吞并，retire 顶层据此屏蔽这些 lane 的 VRF 写使能。

module rvv_backend_retire_waw(
  valid,
  w_index,
  w_strobe,
  w_data,
  waw,
  res,
  res_strobe
);
  parameter UOP_NUM = 2;

  // 输入 lane 数由实例化位置决定；UOP_NUM=j+1 时，lane[UOP_NUM-1] 是当前年轻 lane。
  input   logic [UOP_NUM-1:0]                           valid;
  input   logic [UOP_NUM-1:0][`REGFILE_INDEX_WIDTH-1:0] w_index;
  input   logic [UOP_NUM-1:0][`VLENB-1:0]               w_strobe;
  input   logic [UOP_NUM-1:0][`VLEN-1:0]                w_data;
  // waw 的低位对应被合并的更老 lane；res/res_strobe 是合并后的写回数据。
  output  logic [`NUM_RT_UOP-1:0]                       waw;
  output  logic [`VLEN-1:0]                             res;
  output  logic [`VLENB-1:0]                            res_strobe;

  // vd_hit[i] 表示 lane i 与最后一个 lane 写同一个目的 VRF，且两者都有效。
  logic   [UOP_NUM-1:0] vd_hit;
    
  always_comb begin
    res         = 'b0;
    res_strobe  = 'b0;
    vd_hit      = 'b0;

    for(int i=0;i<UOP_NUM;i++) begin
      // valid[UOP_NUM-1] 保证只有当前年轻 lane 真正要写时，才触发对更老 lane 的吞并。
      vd_hit[i] = valid[i]&valid[UOP_NUM-1]&(w_index[i]==w_index[UOP_NUM-1]);
      
      for(int j=0;j<`VLENB;j++) begin  //lane i 写同一个vd;lane i 的byte j有效,合并。
        // byte 级合并：更老 lane 中有效的 byte 进入当前年轻 lane 的最终写数据。
        if(vd_hit[i]&w_strobe[i][j]) begin
          res_strobe[j]                   = 'b1;
          res[j*`BYTE_WIDTH+:`BYTE_WIDTH] = w_data[i][j*`BYTE_WIDTH+:`BYTE_WIDTH];  //i ~ UOP_NUM-2个uop操作，被merge到最后一个uop操作
        end
      end
    end
  end
  
  // 当前 lane 自己的 vd_hit 只用于生成 res，不需要作为“被吞并 lane”上报，因此截掉最高位。
  assign waw = (`NUM_RT_UOP)'(vd_hit[UOP_NUM-2:0]); 
endmodule
