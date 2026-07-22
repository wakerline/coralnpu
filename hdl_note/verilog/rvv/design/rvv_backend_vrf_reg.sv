// 功能说明：
// 1. RVV 向量寄存器堆的物理存储体，包含 `NUM_VRF` 个 VLEN 宽寄存器，即 v0-v31。
// 2. 每个寄存器按 byte 切分成 `VLENB` 个 8-bit edff，写使能 wen[i][j] 控制单个 byte。
// 3. 本模块只负责存储，不做读口选择、不做写冲突仲裁；这些逻辑在上层 rvv_backend_vrf 中完成。
// 4. vreg 输出整组 32xVLEN 数据，上层用寄存器编号进行组合选择。
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_vrf_reg (/*AUTOARG*/
   // 输出整组物理向量寄存器。
   vreg,
   // 输入 byte 写使能、写数据和时钟复位。
   wen, wdata, clk, rst_n
   );

  output logic [`NUM_VRF-1:0][`VLEN-1:0]  vreg;

  input  logic [`NUM_VRF-1:0][`VLENB-1:0] wen; // byte 写使能。
  input  logic [`NUM_VRF-1:0][`VLEN-1:0]  wdata;
  input  logic                            clk;
  input  logic                            rst_n;

// -- 32 个向量寄存器 ------------------------------------------------
genvar i,j;
generate
  for (i=0; i<`NUM_VRF; i=i+1) begin
    for (j=0; j<`VLENB; j=j+1) begin
      // 每个 byte 独立一个带使能寄存器，因此 Retire 可按 byte strobe 部分写回。
      edff #(
        .T      (logic [`BYTE_WIDTH-1:0])
      )
      vrf_unit1_reg (
        .q      (vreg[i][j*`BYTE_WIDTH +: `BYTE_WIDTH]),
        .e      (wen[i][j]),
        .d      (wdata[i][j*`BYTE_WIDTH +: `BYTE_WIDTH]),
        .clk    (clk),
        .rst_n  (rst_n)
        );
    `ifdef ASSERT_ON
      // 仿真断言：寄存器 byte 不应变成 X，便于发现未初始化或多驱动问题。
      `rvv_forbid($isunknown(vreg[i][j*`BYTE_WIDTH +: `BYTE_WIDTH]))
        else $error("VREG: data is unknow at vreg[%0d][%0d:%0d]",i,8*j+7,8*j);
    `endif //ASSERT_ON
    end // byte 循环
  end // 寄存器编号循环
endgenerate


endmodule
