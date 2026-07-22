`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_operand` -> RVV 后端 DP 阶段的 VRF 操作数整理单元。
// - 接口与数据流：
//   * 输入：`uop_uop2dp` 给出每个 dispatch 槽的 uop_class，说明该 uop 需要 vs1/vs2/vd 中哪些向量源。
//   * 输入：`rd_data_vrf2dp` 是 VRF 根据 structure_hazard 生成的读地址返回的原始读口数据。
//   * 输入：`v0_mask_vrf2dp` 是单独读出的 v0 mask 数据，不占用普通 `NUM_DP_VRF` 数据读口。
//   * 输出：`vrf_byp` 把 VRF 读口数据整理成每个 uop 的 v0/vs1/vs2/vd 四类操作数，供后续 ROB bypass 覆盖。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 uop_uop2dp, rd_data_vrf2dp, v0_mask_vrf2dp；输出 vrf_byp。
// - define/参数阅读重点：
//   * `NUM_DP_UOP`：3；当前 DISPATCH3 下 Dispatch 每拍最多发射 uop 数，DISPATCH2 时为 2。
//   * `NUM_DP_VRF`：6；当前 DISPATCH3 下 Dispatch 侧 VRF 读口数，DISPATCH2 时为 4。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - 读口映射规则：
//   * 本模块不产生 VRF 读地址；读地址由 `rvv_backend_dispatch_structure_hazard` 生成。
//   * `uop_class` 中每个字符描述操作数形态：V 表示需要一个向量读口，X 表示该位置不读 VRF。
//     例如 XVV 需要 vs1/vs2，VVX 需要 vd/vs2，VXX 只需要 vd。
//   * DISPATCH3 下有 3 个 uop 槽和 6 个普通 VRF 读口。uop0/uop1 先占用固定读口组合，
//     uop2 再根据前两个 uop 的 uop_class 复用剩余或已安排好的读口数据。
//   * DISPATCH2 下有 2 个 uop 槽和 4 个普通 VRF 读口，映射关系更直接：uop0 使用低读口，uop1 使用高读口。
//   * 所有 uop 的 v0 都直接来自 `v0_mask_vrf2dp`，因为 v0 mask 由独立路径提供。
// - 阅读建议：先看 DISPATCH2 分支理解基本映射，再看 DISPATCH3 分支中 uop2 如何根据 uop0/uop1 的读口占用做选择。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_operand
(
  vrf_byp,
  uop_uop2dp,
  rd_data_vrf2dp,
  v0_mask_vrf2dp
);
// ---端口定义-------------------------------------------------
  // 按 dispatch 槽输出的操作数集合：每个 uop 一份 v0/vs1/vs2/vd。
  output  UOP_OPN_t   [`NUM_DP_UOP-1:0]             vrf_byp;
  // 当前 dispatch 槽的 uop，主要使用其中的 uop_class 和 vs1_valid 信息辅助读口选择。
  input   UOP_QUEUE_t [`NUM_DP_UOP-1:0]             uop_uop2dp;
  // 普通 VRF 读口返回数据，读口数量由 NUM_DP_VRF 决定。
  input   logic       [`NUM_DP_VRF-1:0][`VLEN-1:0]  rd_data_vrf2dp;
  // v0 mask 专用数据路径。
  input   logic       [`VLEN-1:0]                   v0_mask_vrf2dp;

// 从 VRF 读口数据整理每个 uop 的源操作数。
`ifdef DISPATCH3
  // DISPATCH3：每拍最多 3 个 uop，普通 VRF 读口为 6 个。
  // 默认 uop0 使用 rd0/rd1/rd2，uop1 使用 rd3/rd4/rd5；
  // uop2 的数据来源取决于 uop0/uop1 已经占用了哪些读口。
  always_comb begin
    // v0 来自独立 mask 路径；uop0/uop1 的默认三源映射先直接摆好。
    vrf_byp[0].v0  = v0_mask_vrf2dp;
    vrf_byp[0].vs1 = rd_data_vrf2dp[0];
    vrf_byp[0].vs2 = rd_data_vrf2dp[1];
    vrf_byp[0].vd  = rd_data_vrf2dp[2];
    vrf_byp[1].v0  = v0_mask_vrf2dp;
    vrf_byp[1].vs1 = rd_data_vrf2dp[3];
    vrf_byp[1].vs2 = rd_data_vrf2dp[4];
    vrf_byp[1].vd  = rd_data_vrf2dp[5];
    vrf_byp[2].v0  = v0_mask_vrf2dp;
    vrf_byp[2].vs1 = 'b0;
    vrf_byp[2].vs2 = 'b0;
    vrf_byp[2].vd  = 'b0;

    // uop2 需要的读口不能简单固定，因为前两个 uop 的 uop_class 不同会改变 rd_data_vrf2dp 的分配。
    // 下面的 case 表逐项描述“在 uop0/uop1 读口占用给定时，uop2 的 vs1/vs2/vd 应该取哪个 rd 口”。
    case(uop_uop2dp[2].uop_class)
      XXV,
      XVX,
      VXX: begin
        // uop2 只需要一个向量源时，根据前序 uop 的读口占用选择可复用的单个 rd 口。
        case(uop_uop2dp[0].uop_class)
          XXV,
          XVV: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[2];
            vrf_byp[2].vs2 = rd_data_vrf2dp[2];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end

          XXX,
          XVX,
          VXX,
          VVX: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[0];
            vrf_byp[2].vd  = rd_data_vrf2dp[0];
          end

          VVV: begin 
            case(uop_uop2dp[1].uop_class)
              XXV,
              XVV: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[5];
                vrf_byp[2].vs2 = rd_data_vrf2dp[5];
                vrf_byp[2].vd  = rd_data_vrf2dp[5];
              end

              XXX,
              XVX,
              VXX,
              VVX: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[3];
                vrf_byp[2].vs2 = rd_data_vrf2dp[3];
                vrf_byp[2].vd  = rd_data_vrf2dp[3];
              end
            endcase
          end
        endcase
      end
      
      XVV,
      VVX: begin
        // uop2 需要两个向量源时，按前序 uop_class 选择两路数据；未使用的 vd/vs1 位置保持一致映射。
        case(uop_uop2dp[0].uop_class)
          XXX,
          VXX: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[0];
          end

          XXV: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[2];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end

          XVX: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[2];
            vrf_byp[2].vd  = rd_data_vrf2dp[0];
          end

          XVV,
          VVX: begin
            case(uop_uop2dp[1].uop_class)
              XXX,
              VXX: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[3];
                vrf_byp[2].vs2 = rd_data_vrf2dp[4];
                vrf_byp[2].vd  = rd_data_vrf2dp[3];
              end

              XXV: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[5];
                vrf_byp[2].vs2 = rd_data_vrf2dp[4];
                vrf_byp[2].vd  = rd_data_vrf2dp[5];
              end

              XVX: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[3];
                vrf_byp[2].vs2 = rd_data_vrf2dp[5];
                vrf_byp[2].vd  = rd_data_vrf2dp[3];
              end   

              VVX: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[3];
                vrf_byp[2].vs2 = uop_uop2dp[0].vs1_valid ? rd_data_vrf2dp[2] : rd_data_vrf2dp[0];
                vrf_byp[2].vd  = rd_data_vrf2dp[3];
              end

              XVV: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[5];
                vrf_byp[2].vs2 = uop_uop2dp[0].vs1_valid ? rd_data_vrf2dp[2] : rd_data_vrf2dp[0];
                vrf_byp[2].vd  = rd_data_vrf2dp[5];
              end
            endcase
          end

          VVV: begin 
            case(uop_uop2dp[1].uop_class)
              XXX,
              VXX: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[3];
                vrf_byp[2].vs2 = rd_data_vrf2dp[4];
                vrf_byp[2].vd  = rd_data_vrf2dp[3];
              end

              XVX: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[3];
                vrf_byp[2].vs2 = rd_data_vrf2dp[5];
                vrf_byp[2].vd  = rd_data_vrf2dp[3];
              end

              XXV: begin
                vrf_byp[2].vs1 = rd_data_vrf2dp[4];
                vrf_byp[2].vs2 = rd_data_vrf2dp[5];
                vrf_byp[2].vd  = rd_data_vrf2dp[4];
              end
            endcase
          end
        endcase
      end

      VVV: begin
        // uop2 需要三路向量源时，必须同时考虑 uop0/uop1 的组合，才能定位三路 rd_data。
        case({uop_uop2dp[0].uop_class,uop_uop2dp[1].uop_class})
          {XXX,XXX},
          {XXX,XXV},
          {XXX,XVX},
          {XXX,VXX},
          {XXX,XVV},
          {XXX,VVX},
          {XXX,VVV}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end

          {XXV,XXX},
          {XVX,XXX},
          {VXX,XXX},
          {XVV,XXX},
          {VVX,XXX},
          {VVV,XXX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[3];
            vrf_byp[2].vs2 = rd_data_vrf2dp[4];
            vrf_byp[2].vd  = rd_data_vrf2dp[5];
          end

          {XXV,VXX},
          {XXV,VVX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[3];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end
          
          {XXV,XXV},
          {XXV,XVX},
          {XXV,XVV}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[5];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end
          
          {XVX,VXX},
          {XVX,VVX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[3];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end

          {XVX,XXV},
          {XVX,XVX},
          {XVX,XVV}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[5];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end

          {VXX,VXX},
          {VXX,VVX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[3];
          end

          {VXX,XXV},
          {VXX,XVX},
          {VXX,XVV}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[1];
            vrf_byp[2].vd  = rd_data_vrf2dp[5];
          end

          {XVV,VXX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[3];
            vrf_byp[2].vs2 = rd_data_vrf2dp[4];
            vrf_byp[2].vd  = rd_data_vrf2dp[2];
          end

          {XVV,XVX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[3];
            vrf_byp[2].vs2 = rd_data_vrf2dp[2];
            vrf_byp[2].vd  = rd_data_vrf2dp[5];
          end

          {XVV,XXV}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[2];
            vrf_byp[2].vs2 = rd_data_vrf2dp[4];
            vrf_byp[2].vd  = rd_data_vrf2dp[5];
          end

          {VVX,VXX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[3];
            vrf_byp[2].vs2 = rd_data_vrf2dp[4];
            vrf_byp[2].vd  = rd_data_vrf2dp[0];
          end

          {VVX,XVX}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[3];
            vrf_byp[2].vs2 = rd_data_vrf2dp[0];
            vrf_byp[2].vd  = rd_data_vrf2dp[5];
          end

          {VVX,XXV}: begin
            vrf_byp[2].vs1 = rd_data_vrf2dp[0];
            vrf_byp[2].vs2 = rd_data_vrf2dp[4];
            vrf_byp[2].vd  = rd_data_vrf2dp[5];
          end
        endcase
      end
    endcase
  end   

`else // DISPATCH2
  // DISPATCH2：每拍最多 2 个 uop，普通 VRF 读口为 4 个。
  // uop0 使用 rd0/rd1/rd3 中的相关读口，uop1 使用 rd2/rd3/rd1 中的相关读口；
  // 具体选择由 uop_class 决定。
  always_comb begin
    // 先清零所有普通操作数，避免不需要的源端口带入旧值；v0 仍统一来自 mask 路径。
    vrf_byp[0].v0  = v0_mask_vrf2dp;
    vrf_byp[0].vs1 = 'b0;
    vrf_byp[0].vs2 = 'b0;
    vrf_byp[0].vd  = 'b0;
    vrf_byp[1].v0  = v0_mask_vrf2dp;
    vrf_byp[1].vs1 = 'b0;
    vrf_byp[1].vs2 = 'b0;
    vrf_byp[1].vd  = 'b0;

    // 根据 uop0 的操作数类型，从 structure_hazard 安排好的 VRF 读口中取 vs1/vs2/vd。
    case(uop_uop2dp[0].uop_class)
      VVV:begin
        vrf_byp[0].vd  = rd_data_vrf2dp[3];
        vrf_byp[0].vs1 = rd_data_vrf2dp[1];
        vrf_byp[0].vs2 = rd_data_vrf2dp[0];
      end                       
      XVV: begin
        vrf_byp[0].vs1 = rd_data_vrf2dp[1];
        vrf_byp[0].vs2 = rd_data_vrf2dp[0];
      end
      VVX: begin
        vrf_byp[0].vd  = rd_data_vrf2dp[1];
        vrf_byp[0].vs2 = rd_data_vrf2dp[0];
      end
      VXX: begin
        vrf_byp[0].vd  = rd_data_vrf2dp[0];
      end
      XVX: begin
        vrf_byp[0].vs2 = rd_data_vrf2dp[0];
      end
      XXV: begin
        vrf_byp[0].vs1 = rd_data_vrf2dp[0];
      end
    endcase

    // 根据 uop1 的操作数类型，从高半部分 VRF 读口中取 vs1/vs2/vd。
    case(uop_uop2dp[1].uop_class)
      VVV:begin
        vrf_byp[1].vd  = rd_data_vrf2dp[1];
        vrf_byp[1].vs1 = rd_data_vrf2dp[3];
        vrf_byp[1].vs2 = rd_data_vrf2dp[2];
      end
      XVV: begin
        vrf_byp[1].vs1 = rd_data_vrf2dp[3];
        vrf_byp[1].vs2 = rd_data_vrf2dp[2];
      end
      VVX: begin
        vrf_byp[1].vd  = rd_data_vrf2dp[3];
        vrf_byp[1].vs2 = rd_data_vrf2dp[2];
      end
      VXX: begin
        vrf_byp[1].vd = rd_data_vrf2dp[2];
      end
      XVX: begin
        vrf_byp[1].vs2 = rd_data_vrf2dp[2];
      end
      XXV: begin
        vrf_byp[1].vs1 = rd_data_vrf2dp[2];
      end
    endcase
  end
`endif

endmodule
