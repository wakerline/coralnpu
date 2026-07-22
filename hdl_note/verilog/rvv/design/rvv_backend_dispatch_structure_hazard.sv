// 功能说明：
// 1. `rvv_backend_dispatch_structure_hazard` 是 `rvv_backend_dispatch` 的子模块。
// 2. 本模块根据本拍待发射 uop 的 `uop_class`，给 Dispatch 侧普通 VRF 读口安排读地址 `rd_index`。
// 3. 如果多个 uop 同拍发射时需要的 VRF 读端口数超过当前配置能提供的端口数，则置位 `arch_hazard.vr_limit`，
//    由 dispatch 控制逻辑限制后续 lane 发射。
//

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_structure_hazard` -> RVV 后端 DP/Dispatch 阶段的 VRF 读端口结构冒险检查。
// - 接口与数据流：
//   * 输入：`strct_uop` 来自 UQ 中本拍最多 `NUM_DP_UOP` 个 uop 的源寄存器摘要和 `uop_class`。
//   * 处理：按 `uop_class` 判断每个 uop 需要读取哪些向量源，并把这些源寄存器分配到有限的 VRF 读口上。
//   * 输出：`rd_index` 送往 VRF；`arch_hazard.vr_limit` 表示本拍读口不够，需要限制发射。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 strct_uop；输出 rd_index, arch_hazard。
// - `uop_class` 约定：
//   * `uop_class` 是 dispatch 使用的向量源读口需求分类，`V` 表示需要普通 VRF 读源，`X` 表示该类位置不需要普通 VRF 读源。
//   * 这些名字主要表达“需要几个/哪类向量源”，不要把三个字符机械理解成固定寄存器位置；实际读哪个寄存器仍由 `vs*_valid` 和下面的 case 表决定。
//   * `XXX`：不读普通向量源；`XXV`/`XVX`/`VXX`：读 1 个源；`XVV`/`VVX`：读 2 个源；`VVV`：读 3 个源。
//   * enum 中还定义了 `VXV`，但本文件当前没有为它单独列出读口排布分支。
//   * `vd_index` 在这里不表示写目的，而是当 `vs3_valid` 置位时作为“旧 vd/累加输入”被读出。
// - 本模块只处理普通 VRF 读口结构限制，不处理 RAW/WAW 数据相关，也不判断各执行单元 RS 或 ROB 是否有空间。
// - define/参数阅读重点：
//   * `NUM_DP_UOP`：3；当前 DISPATCH3 下 Dispatch 每拍最多发射 uop 数，DISPATCH2 时为 2。
//   * `NUM_DP_VRF`：6；当前 DISPATCH3 下 Dispatch 侧 VRF 读口数，DISPATCH2 时为 4。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
// - 不确定/条件宏提示：
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - 阅读建议：先看结构体类型定义所在的 `rvv_backend.svh`，再按 valid/ready、pop/push、trap_flush_rvv 三类信号追踪控制流。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_structure_hazard
(
    rd_index,
    arch_hazard,
    strct_uop
);

//---port definition--------------------------------------------------
    output logic [`NUM_DP_VRF-1:0][`REGFILE_INDEX_WIDTH-1:0] rd_index;    // 分配给 VRF 每个普通读口的寄存器编号。
    output ARCH_HAZARD_t                                     arch_hazard; // 结构冒险结果；当前结构体只有 vr_limit。
    input  STRCT_UOP_t [`NUM_DP_UOP-1:0]                     strct_uop;   // 本拍 dispatch 候选 uop 的源寄存器需求摘要。
//---internal signal definition---------------------------------------
//---code start-------------------------------------------------------
// 根据各 lane 的源操作数需求生成 VRF 读地址，并判断普通读端口是否够用。
// 注意：后续 `rvv_backend_dispatch_operand` 会按照同一套读口排布，从 `rd_data_vrf2dp` 中取出 vs1/vs2/vd-as-source 等普通向量操作数。

//VVV：vd、vs2、vs1

    generate
`ifdef DISPATCH3
      // DISPATCH3：每拍最多 3 个 uop，普通 VRF 读口为 6 个。
      // 默认先按前两个 uop 各占 3 个读口排布：
      // rd0 : uop0.vs1 或复用给 uop2
      // rd1 : uop0.vs2 或复用给 uop2
      // rd2 : uop0.vs3(vd-as-source) 或复用给 uop2
      // rd3 : uop1.vs1 或复用给 uop2
      // rd4 : uop1.vs2 或复用给 uop2
      // rd5 : uop1.vs3(vd-as-source) 或复用给 uop2
      //
      // 设计思路：
      // - uop0/uop1 先保守占位，保证操作数旁路模块的读口选择规则固定。
      // - 再根据 uop0/uop1 的 `uop_class` 找出空闲读口给 uop2。
      // - 若 uop2 所需读口无法全部塞进 6 个读口，则 `vr_limit=1`，表示第三条 uop 不能同拍发射。
      always_comb begin
        // 默认读口分配：前两条 uop 每条预留 vs1/vs2/vd-as-source 三个槽。
        rd_index[0] = strct_uop[0].vs1_index;
        rd_index[1] = strct_uop[0].vs2_index;
        rd_index[2] = strct_uop[0].vd_index;
        rd_index[3] = strct_uop[1].vs1_index;
        rd_index[4] = strct_uop[1].vs2_index;
        rd_index[5] = strct_uop[1].vd_index;
        
        // 默认认为第三条 uop 会受 VRF 读口限制；只有找到合法读口复用方案后才清零。
        arch_hazard.vr_limit = 1'b1;

        case(strct_uop[2].uop_class)
          XXX: begin
            // uop2 不需要普通 VRF 读口，前两条 uop 的默认读口排布即可满足。
            arch_hazard.vr_limit = 'b0;
          end

          XXV,
          XVX,
          VXX: begin
            // uop2 只需要 1 个普通向量源。
            // 根据 uop0/uop1 的源需求，在它们未使用的读口槽里插入 uop2 的那个源。
            case(strct_uop[0].uop_class)
              XXV,
              XVV: begin
                // uop0 不使用 rd2 对应的 vd-as-source 槽，优先把 uop2 的单源放到 rd2。
                case(1'b1)
                  strct_uop[2].vs3_valid: rd_index[2] = strct_uop[2].vd_index;
                  strct_uop[2].vs2_valid: rd_index[2] = strct_uop[2].vs2_index;
                  default:                rd_index[2] = strct_uop[2].vs1_index;
                endcase
                arch_hazard.vr_limit = 'b0;
              end

              XXX,
              XVX,
              VXX,
              VVX: begin
                // uop0 至少空出 rd0/vs1 槽，可把 uop2 的单源放到 rd0。
                case(1'b1)
                  strct_uop[2].vs3_valid: rd_index[0] = strct_uop[2].vd_index;
                  strct_uop[2].vs2_valid: rd_index[0] = strct_uop[2].vs2_index;
                  default:                rd_index[0] = strct_uop[2].vs1_index;
                endcase
                arch_hazard.vr_limit = 'b0;
              end

              VVV: begin 
                // uop0 三个读口全占满，必须到 uop1 的空闲槽中寻找读口。
                case(strct_uop[1].uop_class)
                  XXV,
                  XVV: begin
                    // uop1 不使用 rd5/vd-as-source 槽，给 uop2 单源复用。
                    case(1'b1)
                      strct_uop[2].vs3_valid: rd_index[5] = strct_uop[2].vd_index;
                      strct_uop[2].vs2_valid: rd_index[5] = strct_uop[2].vs2_index;
                      default:                rd_index[5] = strct_uop[2].vs1_index;
                    endcase
                    arch_hazard.vr_limit = 'b0;
                  end

                  XXX,
                  XVX,
                  VXX,
                  VVX: begin
                    // uop1 空出 rd3/vs1 槽，给 uop2 单源复用。
                    case(1'b1)
                      strct_uop[2].vs3_valid: rd_index[3] = strct_uop[2].vd_index;
                      strct_uop[2].vs2_valid: rd_index[3] = strct_uop[2].vs2_index;
                      default:                rd_index[3] = strct_uop[2].vs1_index;
                    endcase
                    arch_hazard.vr_limit = 'b0;
                  end

                  //VVV: arch_hazard.vr_limit = 'b1;
                endcase
              end
            endcase
          end

          XVV,
          VVX: begin
            // uop2 需要 2 个普通向量源。
            // 这里按 uop0/uop1 的 uop_class 查表寻找两个空闲读口；若组合没有覆盖，则保持 vr_limit=1。
            case(strct_uop[0].uop_class)
              XXX,
              VXX: begin
                // uop0 至多占用 vd-as-source，rd0/rd1 可放 uop2 的两个源。
                rd_index[0] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                       strct_uop[2].vd_index ;
                rd_index[1] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              XXV: begin
                // uop0 只占 rd0/vs1，rd1/rd2 可供 uop2 两个源复用。
                rd_index[2] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                       strct_uop[2].vd_index ;
                rd_index[1] = strct_uop[2].vs2_index ;
                arch_hazard.vr_limit = 'b0;
              end

              XVX: begin
                // uop0 只占 rd1/vs2，rd0/rd2 可供 uop2 两个源复用。
                rd_index[0] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                       strct_uop[2].vd_index ;
                rd_index[2] = strct_uop[2].vs2_index ;
                arch_hazard.vr_limit = 'b0;
              end

              XVV,
              VVX: begin
                // uop0 已占用两个读口，需结合 uop1 的读口占用情况继续查找两个空位。
                case(strct_uop[1].uop_class)
                  XXX,
                  VXX: begin
                    // uop1 空出 rd3/rd4，可容纳 uop2 两个源。
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index ;
                    rd_index[4] = strct_uop[2].vs2_index ;
                    arch_hazard.vr_limit = 'b0;
                  end

                  XXV: begin
                    // uop1 空出 rd4/rd5，可容纳 uop2 两个源。
                    rd_index[5] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index ;
                    rd_index[4] = strct_uop[2].vs2_index ;
                    arch_hazard.vr_limit = 'b0;
                  end

                  XVX: begin
                    // uop1 空出 rd3/rd5，可容纳 uop2 两个源。
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index ;
                    rd_index[5] = strct_uop[2].vs2_index ;
                    arch_hazard.vr_limit = 'b0;
                  end   

                  VVX: begin
                    // uop0/uop1 都是两源类，剩余空位分散在前两条 uop 的未用槽中。
                    // 若 uop0 不读 vs1，则 rd0 空闲；否则 rd2 空闲。uop2 的另一个源放到 uop1 空出的 rd3。
                    if (strct_uop[0].vs1_valid=='b0) 
                      rd_index[0] = strct_uop[2].vs2_index;
                    else 
                      rd_index[2] = strct_uop[2].vs2_index;
                    
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    arch_hazard.vr_limit = 'b0;
                  end

                  XVV: begin
                    // 与上一个分支类似，只是 uop1 空出的槽位变成 rd5。
                    if (strct_uop[0].vs1_valid=='b0) 
                      rd_index[0] = strct_uop[2].vs2_index;
                    else 
                      rd_index[2] = strct_uop[2].vs2_index;

                    rd_index[5] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    arch_hazard.vr_limit = 'b0;
                  end
                endcase
              end

              VVV: begin 
                // uop0 三源全占满，只能从 uop1 未占用的两个槽中给 uop2 找空间。
                case(strct_uop[1].uop_class)
                  XXX,
                  VXX: begin
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    rd_index[4] = strct_uop[2].vs2_index ; 
                    arch_hazard.vr_limit = 'b0;
                  end

                  XVX: begin
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    rd_index[5] = strct_uop[2].vs2_index ; 
                    arch_hazard.vr_limit = 'b0;
                  end

                  XXV: begin
                    rd_index[4] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    rd_index[5] = strct_uop[2].vs2_index ; 
                    arch_hazard.vr_limit = 'b0;
                  end

                  VVV: begin
                    // uop0/uop1/uop2 都偏三源，6 个读口无法容纳第三条 uop 的两个源。
                    arch_hazard.vr_limit = 'b1;
                  end
                endcase
              end
            endcase
          end

          VVV: begin
            // uop2 需要 3 个普通向量源。
            // 只有当 uop0/uop1 合计占用不超过 3 个读口，或有可精确复用的空槽组合时，才能容纳 uop2。
            // 下面的大 case 是三发射下的读口装箱表；未列出的组合统一保持/置位 vr_limit。
            case({strct_uop[0].uop_class,strct_uop[1].uop_class})
              {XXX,XXX},
              {XXX,XXV},
              {XXX,XVX},
              {XXX,VXX},
              {XXX,XVV},
              {XXX,VVX},
              {XXX,VVV}: begin
                // uop0 不占普通 VRF 读口，uop2 三个源直接放到 rd0/rd1/rd2。
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[2] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XXV,XXX},
              {XVX,XXX},
              {VXX,XXX},
              {XVV,XXX},
              {VVX,XXX},
              {VVV,XXX}: begin
                // uop1 不占普通 VRF 读口，uop2 三个源直接放到 rd3/rd4/rd5。
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XXV,VXX},
              {XXV,VVX}: begin
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs1_index;
                arch_hazard.vr_limit = 'b0;
              end
              
              {XXV,XXV},
              {XXV,XVX},
              {XXV,XVV}: begin
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[5] = strct_uop[2].vs1_index;
                arch_hazard.vr_limit = 'b0;
              end
              
              {XVX,VXX},
              {XVX,VVX}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVX,XXV},
              {XVX,XVX},
              {XVX,XVV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[5] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VXX,VXX},
              {VXX,VVX}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[3] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VXX,XXV},
              {VXX,XVX},
              {VXX,XVV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVV,VXX}: begin
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVV,XVX}: begin
                rd_index[2] = strct_uop[2].vs2_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVV,XXV}: begin
                rd_index[2] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VVX,VXX}: begin
                rd_index[0] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VVX,XVX}: begin
                rd_index[0] = strct_uop[2].vs2_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VVX,XXV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              default: begin
                // 其他组合需要的普通 VRF 读源超过 6 个读口可承载范围，第三条 uop 被结构限制挡住。
                arch_hazard.vr_limit = 'b1;
              end
            endcase
          end
        endcase
      end

`else // DISPATCH2
      // DISPATCH2：每拍最多 2 个 uop，普通 VRF 读口为 4 个。
      // rd0: uop0.vs2 或 uop0.vs1 或 uop0.vd-as-source
      // rd1: uop0.vs1 或 uop1.vd-as-source
      // rd2: uop1.vs2 或 uop1.vs1 或 uop1.vd-as-source
      // rd3: uop1.vs1 或 uop0.vd-as-source
      //
      // 两发射时不需要像 DISPATCH3 那样给第三条 uop 做装箱，只需固定排布两条 uop 的读口，
      // 再判断两条 uop 的组合是否超过 4 个普通读口。
      always_comb begin
        // VRF 读口 rd0：主要服务 uop0 的第一个可读源。
        // | uop0 class        | rd0 读什么          |
        // | ----------------- | ---------------- |
        // | `VVV/XVV/VVX/XVX` | `uop0.vs2_index` |
        // | `VXX`             | `uop0.vd_index`  |
        // | `XXV`             | `uop0.vs1_index` |
        // | default           | `x`              |
        case(strct_uop[0].uop_class)
          VVV,
          XVV,                      
          VVX,
          XVX: begin
            rd_index[0] = strct_uop[0].vs2_index;
          end
          VXX: begin
            rd_index[0] = strct_uop[0].vd_index;
          end
          XXV: begin
            rd_index[0] = strct_uop[0].vs1_index;
          end
          default: begin
            rd_index[0] = 'x;
          end
        endcase
        // VRF 读口 rd1：服务 uop0.vs1；当 uop0 不占该槽且 uop1 是 VVV 时，可放 uop1.vd-as-source。
        case(strct_uop[0].uop_class)
          VVV,
          XVV:begin                       
            rd_index[1] = strct_uop[0].vs1_index;
          end
          VVX: begin
            rd_index[1] = strct_uop[0].vd_index;
          end
          VXX,
          XVX,
          XXV,
          XXX: begin
            rd_index[1] = strct_uop[1].uop_class==VVV ? strct_uop[1].vd_index : 'x;
          end
          default: begin
            rd_index[1] = strct_uop[1].uop_class==VVV ? strct_uop[1].vd_index : 'x;
          end
        endcase
        // VRF 读口 rd2：主要服务 uop1 的第一个可读源。
        case(strct_uop[1].uop_class)
          VVV,
          XVV,                      
          VVX,
          XVX: begin
            rd_index[2] = strct_uop[1].vs2_index;
          end
          VXX: begin
            rd_index[2] = strct_uop[1].vd_index;
          end
          XXV: begin
            rd_index[2] = strct_uop[1].vs1_index;
          end
          default: begin
            rd_index[2] = 'x;
          end
        endcase
        // VRF 读口 rd3：服务 uop1.vs1/vd-as-source；若 uop0 是 VVV，则优先承载 uop0.vd-as-source。
        case(strct_uop[1].uop_class)
          VVV,
          XVV:begin                       
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : strct_uop[1].vs1_index;
          end
          VVX: begin
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : strct_uop[1].vd_index;
          end
          VXX,
          XVX,
          XXV,
          XXX: begin
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : 'x;
          end
          default: begin
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : 'x;
          end
        endcase
      end

      // DISPATCH2 结构冒险判断：
      // 以下组合需要 5 或 6 个普通 VRF 读源，但硬件只有 4 个读口，因此置位 vr_limit。
      // 其余组合可由上面的固定读口排布满足。
      always_comb begin
        case({strct_uop[0].uop_class, strct_uop[1].uop_class})
          {VVV, VVV},
          {VVV, XVV},
          {VVV, VVX},
          {XVV, VVV},
          {VVX, VVV}: arch_hazard.vr_limit = 1'b1;
          default:    arch_hazard.vr_limit = 1'b0;
        endcase
      end

`endif
    endgenerate

endmodule
