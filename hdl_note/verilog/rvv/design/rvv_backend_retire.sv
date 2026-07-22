`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
// 功能说明：
// 1. RVV 后端 Retire/RT 阶段，接收 ROB 按程序顺序读出的最多 `NUM_RT_UOP` 条结果。
// 2. 根据 ROB2RT_t 中的 w_type，把结果分发到 VRF、XRF、FRF、VCSR、VXSAT、FCSR。
// 3. Retire 仍保持顺序提交：lane j 的 ready 依赖 lane j-1 的 ready，前面 lane 不能提交时后面也不能越过。
// 4. 若 lane0 是 trap，则只更新 vector_csr 给前端/CSR 处理，后续 lane 会被 w_valid_chkTrap 屏蔽。
// 5. VRF 同拍多 lane 写同一寄存器时，通过 rvv_backend_retire_waw 做 byte 级合并，避免旧 lane 单独写回。
// 6. VXSAT/FCSR 是归约式副作用：只要本拍提交 lane 中有对应 bit，就向对应 CSR 接口发一次更新请求。

module rvv_backend_retire(
  rob2rt_write_valid,
  rob2rt_write_data,
  rt2rob_write_ready,
  rt2xrf_write_valid,
  rt2rvs_write_data,
  rvs2rt_write_ready,
`ifdef ZVE32F_ON
  rt2frf_write_valid,
  frf2rt_write_ready,
`endif
  rt2vrf_write_valid,
  rt2vrf_write_data,
  rt2vcsr_write_valid,
  rt2vcsr_write_data,
  vcsr2rt_write_ready,
  rt2vxsat_write_valid,
  rt2vxsat_write_data,
  vxsat2rt_write_ready
`ifdef ZVE32F_ON
  ,rt2fcsr_write_valid,
  rt2fcsr_write_data,
  fcsr2rt_write_ready
`endif
);
// ROB 顺序读出的待退役结果。
    input   logic    [`NUM_RT_UOP-1:0]            rob2rt_write_valid;
    input   ROB2RT_t [`NUM_RT_UOP-1:0]            rob2rt_write_data;
    output  logic    [`NUM_RT_UOP-1:0]            rt2rob_write_ready;

// 写回标量整数寄存器/XRF，也复用 RT2RVS_t 承载写回数据。
    output  logic    [`NUM_RT_UOP-1:0]            rt2xrf_write_valid;
    output  RT2RVS_t [`NUM_RT_UOP-1:0]            rt2rvs_write_data;
    input   logic    [`NUM_RT_UOP-1:0]            rvs2rt_write_ready;

// 写回浮点寄存器 FRF，仅 ZVE32F_ON 下存在。
`ifdef ZVE32F_ON
    output  logic    [`NUM_RT_UOP-1:0]            rt2frf_write_valid;
    input   logic    [`NUM_RT_UOP-1:0]            frf2rt_write_ready;
`endif

// 写回向量寄存器 VRF，带 byte strobe。
    output  logic    [`NUM_RT_UOP-1:0]            rt2vrf_write_valid;
    output  RT2VRF_t [`NUM_RT_UOP-1:0]            rt2vrf_write_data;

// trap 时更新 vector CSR 状态。
    output  logic                                 rt2vcsr_write_valid;
    output  RVVConfigState                        rt2vcsr_write_data;
    input   logic                                 vcsr2rt_write_ready;

// VXSAT 饱和标志更新。
    output  logic                                 rt2vxsat_write_valid;
    output  logic   [`VCSR_VXSAT_WIDTH-1:0]       rt2vxsat_write_data;
    input   logic                                 vxsat2rt_write_ready;

`ifdef ZVE32F_ON
// 浮点异常标志汇总到 FCSR[4:0]。
    output  logic                                 rt2fcsr_write_valid;
    output  RVFEXP_t                              rt2fcsr_write_data;
    input   logic                                 fcsr2rt_write_ready;
`endif

////////////内部信号/////////////////////
logic [`NUM_RT_UOP-1:0]                           w_valid_chkTrap;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               w_strobe;
logic [`NUM_RT_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] w_addr;
logic [`NUM_RT_UOP-1:0]                           w_valid;
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]                w_data;
logic [`NUM_RT_UOP-1:0]                           trap_flag;
RVVConfigState  [`NUM_RT_UOP-1:0]                 w_vcsr;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               w_vxsaturate;
logic [`NUM_RT_UOP-1:0][`VCSR_VXSAT_WIDTH-1:0]    w_vxsat;
`ifdef ZVE32F_ON
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               fpexp_nv_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               fpexp_dz_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               fpexp_of_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               fpexp_uf_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               fpexp_nx_lanes;
logic [`NUM_RT_UOP-1:0]                           fpexp_nv;
logic [`NUM_RT_UOP-1:0]                           fpexp_dz;
logic [`NUM_RT_UOP-1:0]                           fpexp_of;
logic [`NUM_RT_UOP-1:0]                           fpexp_uf;
logic [`NUM_RT_UOP-1:0]                           fpexp_nx;
RVFEXP_t  [`NUM_RT_UOP-1:0]                       w_fpexp;
logic     [`NUM_RT_UOP-1:0]                       w_fpexp_vld;
logic     [`NUM_RT_UOP-1:0]                       fcsr2rt_ready;
`endif
// waw[j] 由第 j 个 retire lane 检查“它之前的 lane 是否与自己写同一个 VRF”。
logic [`NUM_RT_UOP-1:1][`NUM_RT_UOP-1:0]          waw;
logic [`NUM_RT_UOP-1:0]                           hit_waw;
logic [`NUM_RT_UOP-1:0]                           vrfres_valid;
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]                vrfres;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               vrfres_strobe;
logic [`NUM_RT_UOP-1:0]                           w_vrf_valid;
logic [`NUM_RT_UOP-1:0]                           w_vrf;
logic [`NUM_RT_UOP-1:0]                           w_xrf_valid;
logic [`NUM_RT_UOP-1:0]                           w_xrf;
`ifdef ZVE32F_ON
logic [`NUM_RT_UOP-1:0]                           w_frf_valid;
logic [`NUM_RT_UOP-1:0]                           w_frf;
`endif
logic [`NUM_RT_UOP-1:0]                           vxsat2rt_ready;

genvar                                            i,j;

/////////////////////////////////
/////////////Main////////////////
/////////////////////////////////
generate
  for(j=0;j<`NUM_RT_UOP;j++) begin : gen_inter_logic
    // 从 ROB2RT_t 中拆出通用写回字段，后续按 w_type 分发。
    assign w_addr[j]    = rob2rt_write_data[j].w_index;
    assign w_valid[j]   = rob2rt_write_data[j].w_valid;
    assign w_data[j]    = rob2rt_write_data[j].w_data;
    assign trap_flag[j] = rob2rt_write_data[j].trap_flag;
    assign w_vcsr[j]    = rob2rt_write_data[j].vector_csr;

    for (i=0;i<`VLENB;i++) begin : gen_vlenb
      // 只有 BODY_ACTIVE 的 byte 才会写 VRF，也才会参与 VXSAT/FCSR 归约。
      assign w_strobe[j][i]       = rob2rt_write_data[j].vd_type[i]==BODY_ACTIVE;
      assign w_vxsaturate[j][i]   = w_strobe[j][i] & rob2rt_write_data[j].vxsaturate[i];
      `ifdef ZVE32F_ON
      assign fpexp_nv_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].nv; 
      assign fpexp_dz_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].dz; 
      assign fpexp_of_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].of; 
      assign fpexp_uf_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].uf; 
      assign fpexp_nx_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].nx; 
      `endif
    end

    assign w_vxsat[j]     = |w_vxsaturate[j];
    `ifdef ZVE32F_ON
    assign fpexp_nv[j]    = |fpexp_nv_lanes[j];
    assign fpexp_dz[j]    = |fpexp_dz_lanes[j];
    assign fpexp_of[j]    = |fpexp_of_lanes[j];
    assign fpexp_uf[j]    = |fpexp_uf_lanes[j];
    assign fpexp_nx[j]    = |fpexp_nx_lanes[j];
    assign w_fpexp[j].nv  = fpexp_nv[j];
    assign w_fpexp[j].dz  = fpexp_dz[j];
    assign w_fpexp[j].of  = fpexp_of[j];
    assign w_fpexp[j].uf  = fpexp_uf[j];
    assign w_fpexp[j].nx  = fpexp_nx[j];
    assign w_fpexp_vld[j] = |w_fpexp[j];
    `endif

    //保证trap时，更年轻的指令不能写回寄存器，污染
    if(j==0) begin : gen_0
      // lane0 若自身不是 trap，且 ROB valid，才允许产生真实写回。
      assign w_valid_chkTrap[0] = !trap_flag[0] && rob2rt_write_valid[0];
    end else begin : gen_j
      // 更老 lane 已经 trap 时，后续 lane 即使 ROB 给出 valid 也不能产生架构写回。
      assign w_valid_chkTrap[j] = !(|trap_flag[j-1:0]) && rob2rt_write_valid[j];
    end

  // 按目的寄存器类型生成各写回通道 valid。
    assign w_vrf[j]       = (rob2rt_write_data[j].w_type==VRF) && rob2rt_write_data[j].w_valid;
    assign w_vrf_valid[j] = w_valid_chkTrap[j] && w_vrf[j];
    assign w_xrf[j]       = (rob2rt_write_data[j].w_type==XRF) && rob2rt_write_data[j].w_valid;
    assign w_xrf_valid[j] = w_valid_chkTrap[j] && w_xrf[j];
  `ifdef ZVE32F_ON
    assign w_frf[j]       = (rob2rt_write_data[j].w_type==FRF) && rob2rt_write_data[j].w_valid;
    assign w_frf_valid[j] = w_valid_chkTrap[j] && w_frf[j];
  `endif
  end

// VRF WAW：
// lane0 没有更老同拍 lane，直接使用自身数据；lane1..N 依次检查更老 lane 是否与自己写同一 VRF。
  assign vrfres[0]         = w_data[0];
  assign vrfres_strobe[0]  = w_strobe[0];

  for(j=1;j<`NUM_RT_UOP;j++) begin: process_waw  //uop操作高低位分两次写同一个寄存器，需要merge
    rvv_backend_retire_waw #(
      .UOP_NUM    (j+1)
    ) u_process_waw (
      .valid      (w_vrf_valid[j:0]&rt2rob_write_ready[j:0]),
      .w_index    (w_addr[j:0]),
      .w_strobe   (w_strobe[j:0]),
      .w_data     (w_data[j:0]),
      .waw        (waw[j]),  //waw_hit，保留年轻指令，覆盖老指令
      .res        (vrfres[j]),
      .res_strobe (vrfres_strobe[j])
    );
  end

  always_comb begin
    hit_waw = 'b0;
    for(int i=1;i<`NUM_RT_UOP;i++) begin
      // 任意年轻 lane 吞并了某个更老 lane，则更老 lane 的独立 VRF 写回需要被屏蔽。
      hit_waw = hit_waw | waw[i];
    end
  end
  
  // 屏蔽被 WAW 合并掉的旧 lane；最终只保留每组同目的 VRF 中最年轻的写口。
  assign vrfres_valid = w_vrf_valid & rt2rob_write_ready & (~hit_waw);

// retire 副作用与写回。
  // To VCSR：trap lane0 退役时，把保存的 vector CSR 状态送出。
  assign rt2vcsr_write_valid  = rob2rt_write_valid[0] && trap_flag[0] && vcsr2rt_write_ready;
  assign rt2vcsr_write_data   = w_vcsr[0];

  // To VXSAT：所有实际提交的 VRF lane 中只要有饱和 bit，就置位一次 VXSAT。
  assign vxsat2rt_ready       = ~(w_vrf_valid&w_vxsat) | {`NUM_RT_UOP{vxsat2rt_write_ready}}; 
  assign rt2vxsat_write_valid = |(w_vrf_valid&rt2rob_write_ready&w_vxsat) && !trap_flag[0];
  assign rt2vxsat_write_data  = rt2vxsat_write_valid;

`ifdef ZVE32F_ON
  // To FCSR[4:0]：浮点异常按 lane/byte 归约后再提交；trap 本身不更新 FCSR。
  assign fcsr2rt_ready          = ~w_fpexp_vld | {`NUM_RT_UOP{fcsr2rt_write_ready}};
  assign rt2fcsr_write_valid    = trap_flag[0] ? 'b0 : |(w_fpexp_vld & rob2rt_write_valid & rt2rob_write_ready);
  assign rt2fcsr_write_data.nv  = |(fpexp_nv & rob2rt_write_valid & rt2rob_write_ready);  //OR reduce
  assign rt2fcsr_write_data.dz  = |(fpexp_dz & rob2rt_write_valid & rt2rob_write_ready);
  assign rt2fcsr_write_data.of  = |(fpexp_of & rob2rt_write_valid & rt2rob_write_ready);
  assign rt2fcsr_write_data.uf  = |(fpexp_uf & rob2rt_write_valid & rt2rob_write_ready);
  assign rt2fcsr_write_data.nx  = |(fpexp_nx & rob2rt_write_valid & rt2rob_write_ready);
`endif
  
  always_comb begin
    // lane0 ready 是整拍退役链的起点；trap 时只依赖 VCSR 接口 ready。
    if(trap_flag[0])
      rt2rob_write_ready[0] = vcsr2rt_write_ready;  //使用rt2rob_write_ready[0]，是为了退役后，给rob发ready
    else if(rob2rt_write_data[0].w_type==VRF) begin
      rt2rob_write_ready[0] = vxsat2rt_ready[0]     //使用rt2rob_write_ready[0]，是为了退役后，给rob发ready
                              `ifdef ZVE32F_ON
                              && fcsr2rt_ready[0]
                              `endif
                              ;
    end
    else begin
    `ifdef ZVE32F_ON
      rt2rob_write_ready[0] = (rob2rt_write_data[0].w_type==XRF) ? rvs2rt_write_ready[0] : frf2rt_write_ready[0] & fcsr2rt_ready[0];
    `else
      rt2rob_write_ready[0] = rvs2rt_write_ready[0];
    `endif
    end
  end

  for(j=1;j<`NUM_RT_UOP;j++) begin
    always_comb begin
      // 后续 lane 必须等待前一 lane ready，保证 ROB 出队和架构写回按序发生。
      if(rob2rt_write_data[j].w_type==VRF) begin
        rt2rob_write_ready[j] = rt2rob_write_ready[j-1] & (vxsat2rt_ready[j]
                                                          `ifdef ZVE32F_ON
                                                          && fcsr2rt_ready[j]
                                                          `endif
                                                          );
      end
      else begin
      `ifdef ZVE32F_ON
        rt2rob_write_ready[j] = (rob2rt_write_data[j].w_type==XRF) 
                                ? rt2rob_write_ready[j-1] & rvs2rt_write_ready[j] 
                                : rt2rob_write_ready[j-1] & frf2rt_write_ready[j] & fcsr2rt_ready[j];
      `else
        rt2rob_write_ready[j] = rt2rob_write_ready[j-1] & rvs2rt_write_ready[j];
      `endif
      end
    end
  end

  for(j=0;j<`NUM_RT_UOP;j++) begin : gen_rt2vrf_write
    always_comb begin
      // VRF 写回使用 WAW 合并后的 vrfres/vrfres_strobe；被 hit_waw 的旧 lane 不再写。
      if(w_vrf[j]&rt2rob_write_ready[j]&(!hit_waw[j])) begin
        rt2vrf_write_valid[j]           = 1'b1; 

        `ifdef TB_SUPPORT
        rt2vrf_write_data[j].uop_pc     = rob2rt_write_data[j].uop_pc;
        `endif
        rt2vrf_write_data[j].rt_index   = w_addr[j];
        rt2vrf_write_data[j].rt_data    = vrfres[j];
        rt2vrf_write_data[j].rt_strobe  = vrfres_strobe[j];
      end
      else begin
        rt2vrf_write_valid[j]           = 'b0;     
        rt2vrf_write_data[j]            = 'b0;
      end
    end
  end

  for(j=0;j<`NUM_RT_UOP;j++) begin : gen_rt2rob_write
    always_comb begin
      // XRF/FRF 写回不做 byte 合并，直接使用 ROB 保存的 32-bit 低位数据。
      `ifdef ZVE32F_ON
      if(rt2rob_write_ready[j]&(w_xrf[j]|w_frf[j])) begin
      `else
      if(rt2rob_write_ready[j]&w_xrf[j]) begin
      `endif
        rt2xrf_write_valid[j]           = w_xrf[j];     
        `ifdef ZVE32F_ON
        rt2frf_write_valid[j]           = w_frf[j]; 
        `endif

        `ifdef TB_SUPPORT
        rt2rvs_write_data[j].uop_pc     = rob2rt_write_data[j].uop_pc;
        `endif
        rt2rvs_write_data[j].rt_index   = w_addr[j];
        rt2rvs_write_data[j].rt_data    = w_data[j][31:0];
      end
      else begin
        rt2xrf_write_valid[j]           = 'b0;     
        `ifdef ZVE32F_ON
        rt2frf_write_valid[j]           = 'b0; 
        `endif
        rt2rvs_write_data[j]            = 'b0;
      end
    end
  end
endgenerate

endmodule
