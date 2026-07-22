/*
功能说明：
1. RVV 向量寄存器堆顶层，封装 32xVLEN 物理寄存器，并提供 Dispatch/PMT 读口和 Retire 写口。
2. Dispatch 侧有 `NUM_DP_VRF` 个组合读口，PMT/permutation 额外有 1 个组合读口。
3. Retire 侧有 `NUM_RT_UOP` 个写回 lane，每个 lane 携带目的寄存器、VLEN 数据和 byte strobe。
4. 上层 Retire 已处理同拍 VRF WAW；这里把多个写 lane 展开为 32 个寄存器的 byte enable/data 后按 OR 合并。
5. 物理存储在 rvv_backend_vrf_reg 中，本模块负责端口解包、写使能合并和读数据选择。

Dispatch 读口：NUM_DP_VRF = 6
PMT 专用读口：1
v0 mask 固定直出口：1，不带地址，固定读 v0
Retire 写口：NUM_RT_UOP = 4
*/
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_vrf(/*AUTOARG*/
   // 读数据输出：Dispatch 多读口、v0 mask 直出、PMT 专用读口。
   vrf2dp_rd_data, vrf2dp_v0_data, vrf2pmt_rd_data,
   // 输入：时钟复位、读地址、Retire 写回。
   clk, rst_n, dp2vrf_rd_index, pmt2vrf_rd_index, 
   rt2vrf_wr_valid, rt2vrf_wr_data
   );  
// 全局时钟/复位。
input   logic                   clk;
input   logic                   rst_n;
    
// Dispatch 到 VRF：组合读地址，当拍即可从 vrf_rd_data_full 选择出读数据。
input   logic     [`NUM_DP_VRF-1:0][`REGFILE_INDEX_WIDTH-1:0] dp2vrf_rd_index;

// VRF 到 Dispatch：源操作数读数据；v0 单独直出供 mask 逻辑使用。
output  logic     [`NUM_DP_VRF-1:0][`VLEN-1:0]  vrf2dp_rd_data;
output  logic                      [`VLEN-1:0]  vrf2dp_v0_data;

// PMT/permutation 专用读地址，避免占用 Dispatch 读口。
input   logic     [`REGFILE_INDEX_WIDTH-1:0]  pmt2vrf_rd_index;
// VRF 到 PMT/permutation 的组合读数据。
output  logic     [`VLEN-1:0]                 vrf2pmt_rd_data;

// Retire 到 VRF：最多 `NUM_RT_UOP` 路写回，每路都带 byte strobe。
input   logic     [`NUM_RT_UOP-1:0] rt2vrf_wr_valid;
input   RT2VRF_t  [`NUM_RT_UOP-1:0] rt2vrf_wr_data;

genvar  j,k;

// ---内部信号与主逻辑------------------------------------------------
logic [`NUM_RT_UOP-1:0]                           wr_valid;
logic [`NUM_RT_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] wr_addr;
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]                wr_data;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               wr_we;              // byte 写使能。
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]                wr_web;             // byte 写使能扩展成 bit mask。
logic [`NUM_RT_UOP-1:0][`NUM_VRF-1:0][`VLENB-1:0] vrf_wr_wen;
logic [`NUM_RT_UOP-1:0][`NUM_VRF-1:0][`VLEN-1:0]  vrf_wr_data;
logic [`NUM_VRF-1:0][`VLENB-1:0]                  vrf_wr_wen_full;
logic [`NUM_VRF-1:0][`VLEN-1:0]                   vrf_wr_data_full;
logic [`NUM_VRF-1:0][`VLEN-1:0]                   vrf_rd_data_full;   // 32 个物理 VRF 寄存器的完整数据。

// RT2VRF 数据解包：
// 每个写回 lane 先展开成“对 32 个寄存器的 one-hot byte 写使能 + 写数据”。
generate
  for (j=0;j<`NUM_RT_UOP;j++) begin: GET_WT_DATA  //最大为4
    assign wr_valid[j] = rt2vrf_wr_valid[j];
    assign wr_addr[j]  = rt2vrf_wr_data[j].rt_index;
    assign wr_data[j]  = rt2vrf_wr_data[j].rt_data;
    assign wr_we[j]    = rt2vrf_wr_data[j].rt_strobe;
    
    // byte strobe 扩展为 bit mask，避免无效 byte 的数据参与 OR 合并。
    for(k=0;k<`VLENB;k++) begin: GET_WE_BIT
      assign wr_web[j][k*`BYTE_WIDTH +: `BYTE_WIDTH] = {`BYTE_WIDTH{wr_we[j][k]}};
    end

    // 只有 wr_valid 有效时才对目标寄存器产生写使能和写数据。
    always_comb begin
      vrf_wr_wen[j]  = 'b0;
      vrf_wr_data[j] = 'b0;

      if(wr_valid[j]) begin  //第 j 路写回只会写 32 个 VRF 寄存器中的一个。
        vrf_wr_wen[j][wr_addr[j]] = wr_we[j];
        vrf_wr_data[j][wr_addr[j]] = wr_data[j]&wr_web[j];  //只是把 strobe 无效的 byte 数据清 0，避免多个 retire lane 做 OR 合并时污染数据。
                                                            //真正决定写不写的是 wen, 是bit写寄存器控制
      end
    end
  end
endgenerate

// 合并所有 retire 写回 lane：
// Retire 已保证同拍 WAW 被合并/屏蔽，因此这里可以按寄存器和 byte 对使能、数据做 OR。
// 把 4 路写回 lane 合并
always_comb begin
  vrf_wr_wen_full = 'b0;
  vrf_wr_data_full = 'b0;

  for(int i=0; i<`NUM_VRF; i++) begin  //写回几个寄存器
    for(int h=0; h<`NUM_RT_UOP; h++) begin  //4
      vrf_wr_wen_full[i] = vrf_wr_wen_full[i] | vrf_wr_wen[h][i];
      vrf_wr_data_full[i] = vrf_wr_data_full[i] | vrf_wr_data[h][i];
    end
  end
end

// VRF 物理存储体。
rvv_backend_vrf_reg 
vrf_reg (
  // 输出整组 32xVLEN 寄存器。
  .vreg   (vrf_rd_data_full), 
  // 输入合并后的 byte 写使能和写数据。
  .clk    (clk), 
  .rst_n  (rst_n),
  .wen    (vrf_wr_wen_full), 
  .wdata  (vrf_wr_data_full)
);

// VRF2DP 数据选择：v0 直出，其余读口按 dp2vrf_rd_index 组合读取。
assign vrf2dp_v0_data = vrf_rd_data_full[0];

generate
  for (j=0;j<`NUM_DP_VRF;j++) begin: GET_RD_DATA  //NUM_DP_VRF个读口
    assign vrf2dp_rd_data[j] = vrf_rd_data_full[dp2vrf_rd_index[j]];
  end
endgenerate

// VRF2PMT 数据选择：PMT/permutation 使用独立读地址。
assign vrf2pmt_rd_data = vrf_rd_data_full[pmt2vrf_rd_index];

endmodule
