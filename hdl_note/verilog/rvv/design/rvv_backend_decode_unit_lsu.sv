
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_unit_lsu` -> RVV 后端 DE1 阶段的向量访存解码单元。
// - 接口与数据流：
//   * 输入：来自 CQ 的 `RVVCmd`，其中包含原始指令 bits、opcode 和当前 RVV CSR 状态。
//   * 处理：识别 LOAD/STORE、unit-stride/constant-stride/indexed、mask/whole-register/fault-first、
//     segment 等访存形态，并计算 LSU 后续展开 uop 需要的 EMUL/EEW/evl。
//   * 检查：完成 vd/vs2/v0 重叠、寄存器组对齐、segment 寄存器范围、vstart/evl、SEW/LMUL 等合法性检查。
//   * 输出：合法时生成 `LCMD_t` 给 DE2/LCQ；非法编码时 `lcmd_valid=0`，指令直接丢弃。
// - 调用关系：上层 rvv_backend_decode_unit；无下层实例。
// - 端口摘要：输入 inst_valid, inst；输出 lcmd_valid, lcmd。
// - define/参数阅读重点：
//   * `FUNCT3_WIDTH`：3。
//   * `FUNCT6_WIDTH`：6。
//   * `NFIELD_WIDTH`：3。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `UMOP_WIDTH`：5。
//   * `UOP_INDEX_WIDTH`：5。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VL_WIDTH`：$clog2(`VLEN)+1；依赖 VLEN。
//   * `VM_WIDTH`：1。
//   * `VSTART_WIDTH`：$clog2(`VLEN)；依赖 VLEN。
//   * `rvv_forbid`：strong(seq) 取反的 assert property 宏，来自 rvv_backend_sva.svh。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 断言宏来自 `rvv_backend_sva.svh`，只有相关编译开关打开时才会参与仿真检查。
// - 访存指令形态速查：
//   * US/US_US：普通 unit-stride load/store，地址连续递增，nf>1 时为 segment load/store。
//   * US/US_WR：whole-register load/store，不使用 vl 作为元素数，而是按寄存器组容量计算 evl。
//   * US/US_MK：mask load/store，EEW 固定为 1 bit，evl=ceil(vl/8) 字节。
//   * US/US_FF：fault-first unit-stride load，仅 LOAD 合法，遇到 fault 时由 LSU 调整可见 vl。
//   * CS：constant-stride load/store，地址按 rs2/stride 递增，nf>1 时为 segment。
//   * IU/IO：unordered/ordered indexed load/store，vs2 是索引向量，EEW_vs2 由指令编码决定。
// - 阅读建议：
//   * 先看 `rvv_backend.svh` 中 `RVVCmd/LCMD_t/FUNCT6_u/EMUL_e/EEW_e` 的定义。
//   * 再按 “字段拆分 -> mop/umop 分类 -> EMUL -> EEW -> 特殊合法性 -> evl -> LCMD 输出” 阅读。
//   * 本模块只负责 decode 和静态合法性；真正地址生成、访存 fault、fault-first vl 更新在 LSU 后续流水处理。
// 详细中文注释（自动梳理）END

module rvv_backend_decode_unit_lsu
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd
);
//
// 接口信号
//
  // inst_valid 表示当前 RVVCmd 有效；本模块只接受 opcode 为 LOAD/STORE 的 RVV 访存指令。
  input   logic                       inst_valid;
  input   RVVCmd                      inst;
  
  // lcmd_valid 表示访存指令通过 DE1 合法性检查，可以进入后续 LCQ/DE2。
  output  logic                       lcmd_valid;
  output  LCMD_t                      lcmd;

//
// 内部信号
//
  // RVVCmd.bits 对应原始指令 [31:7]，这里重新拆回 RVV load/store 的主要字段。
  logic   [`FUNCT6_WIDTH-1:0]         inst_funct6;      // 原始指令编码 [31:26]。  {nf[2:0],mew[0],mop[2:0]}
  logic   [`NFIELD_WIDTH-1:0]         inst_nf;          // 原始指令编码 [31:29]，segment 字段 nf。
  logic   [`VM_WIDTH-1:0]             inst_vm;          // 原始指令编码 [25]，mask 使能位。      
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vs2;         // 原始指令编码 [24:20]，indexed 访存索引寄存器。rs2
  logic   [`UMOP_WIDTH-1:0]           inst_umop;        // 原始指令编码 [24:20]，unit-stride 子操作。lumop
  logic   [`FUNCT3_WIDTH-1:0]         inst_funct3;      // 原始指令编码 [14:12]，访存 EEW 编码。width
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vd;          // 原始指令编码 [11:7]，load 目的vd或 store数据源字段vs3。
  RVVOpCode                           inst_opcode;      // 原始指令编码 [6:0]，LOAD/STORE opcode。

  logic   [`VSTART_WIDTH-1:0]         csr_vstart;
  logic   [`VL_WIDTH-1:0]             csr_vl;
  logic   [`VL_WIDTH-1:0]             evl;
  RVVConfigState                      vector_csr_lsu;  // 当前向量 CSR 状态，来自 RVVCmd.arch_state。
  RVVSEW                              csr_sew;
  RVVLMUL                             csr_lmul;
  // emul_vd：单个目的/数据寄存器组大小；load 使用 vd，store 语义上对应 vs3。
  // emul_vs2：indexed 访存中索引向量 vs2 的寄存器组大小；非 indexed 访存为 EMUL_NONE。
  // emul_vd_nf：segment/whole-register 时 nf 合并后的 vd/vs3 总寄存器组大小。
  // emul_max：本条指令所有相关寄存器组中的最大 EMUL，用于 uop 展开和合法性判断。
  EMUL_e                              emul_vd;          
  EMUL_e                              emul_vs2;          
  EMUL_e                              emul_vd_nf; 
  EMUL_e                              emul_max; 
  // uop_index_max 是本条访存指令在后端展开后的最后一个 uop 编号，0 表示只有 1 个 uop。
  logic   [`UOP_INDEX_WIDTH-1:0]      uop_index_max;         
  // eew_vd 是实际访存数据元素宽度；eew_vs2 是 indexed 访存的索引元素宽度。
  EEW_e                               eew_vd;          
  EEW_e                               eew_vs2;          
  EEW_e                               eew_max;         
  // valid_lsu_opcode/valid_lsu_mop 分别表示 opcode 和 mop/umop 编码可被本 LSU decode 接受。
  logic                               valid_lsu;
  logic                               valid_lsu_opcode;
  logic                               valid_lsu_mop;
  logic                               inst_encoding_correct;
  logic                               check_special;
  logic                               check_vd_overlap_v0;
  logic                               check_vd_part_overlap_vs2;
  logic   [`REGFILE_INDEX_WIDTH:0]    vd_index_start;
  logic   [`REGFILE_INDEX_WIDTH:0]    vd_index_end;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vd_index_offset;
  logic                               check_vd_overlap_vs2;
  logic                               check_vs2_part_overlap_vd_2_1;
  logic                               check_vs2_part_overlap_vd_4_1;
  logic                               check_common;
  logic                               check_vd_align;
  logic                               check_vs2_align;
  logic                               check_vd_in_range;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  check_vd_cmp;
  logic                               check_sew;
  logic                               check_lmul;
  logic                               check_evl_not_0;
  logic                               check_vstart_sle_evl;
  logic                               check_frm;
  FUNCT6_u                            funct6_lsu;
  logic                               force_vma_agnostic; 
  logic                               force_vta_agnostic; 
  genvar                              j;
  
  // 原始指令 funct3[14:12] 中编码的访存 EEW，只支持 8/16/32 bit。
  localparam  SEW_8     = 3'b000;
  localparam  SEW_16    = 3'b101;
  localparam  SEW_32    = 3'b110;

//
// 解码
//
  // 1. 从 RVVCmd 中拆出 opcode、funct、寄存器编号和当前向量 CSR。
  //    inst_valid=0 时清零，避免无效周期误触发合法性检查。
  assign inst_funct6    = inst_valid ? inst.bits[24:19] : 'b0;
  assign inst_nf        = inst_valid ? inst.bits[24:22] : 'b0;
  assign inst_vm        = inst_valid ? inst.bits[18] : 'b0;
  assign inst_vs2       = inst_valid ? inst.bits[17:13] : 'b0;
  assign inst_umop      = inst_valid ? inst.bits[17:13] : 'b0;
  assign inst_funct3    = inst_valid ? inst.bits[7:5] : 'b0;
  assign inst_vd        = inst_valid ? inst.bits[4:0] : 'b0;
  assign inst_opcode    = inst_valid ? inst.opcode : LOAD;
  assign vector_csr_lsu = inst_valid ? inst.arch_state : RVVConfigState'('0);
  assign csr_vstart     = inst_valid ? inst.arch_state.vstart : 'b0;
  assign csr_vl         = inst_valid ? inst.arch_state.vl : 'b0;
  assign csr_sew        = inst_valid ? inst.arch_state.sew : SEW8;
  assign csr_lmul       = inst_valid ? inst.arch_state.lmul : LMULRESERVED;
  
// 解码 funct6/mop/umop
  // 2. 基于 opcode + funct6 低 3 bit + umop 识别 LSU 指令大类。
  assign valid_lsu = valid_lsu_opcode&valid_lsu_mop&inst_valid;

  // opcode 只接受 LOAD/STORE，并写入后续 LCMD 使用的 is_store 标志。
  always_comb begin
    funct6_lsu.lsu_funct6.lsu_is_store = IS_LOAD;
    valid_lsu_opcode                   = 'b0;

    case(inst_opcode)
      LOAD: begin
        funct6_lsu.lsu_funct6.lsu_is_store = IS_LOAD;
        valid_lsu_opcode                   = 1'b1;
      end
      STORE: begin
        funct6_lsu.lsu_funct6.lsu_is_store = IS_STORE;
        valid_lsu_opcode                   = 1'b1;
      end
    endcase

  // lsu_mop 区分 unit-stride、constant-stride、unordered indexed、ordered indexed。
  // lsu_umop 只在 unit-stride 下继续区分普通、whole-register、mask、fault-first。
    // 默认值先落到普通 unit-stride load，只有匹配合法编码后 valid_lsu_mop 才置 1。
    funct6_lsu.lsu_funct6.lsu_mop    = US;
    funct6_lsu.lsu_funct6.lsu_umop   = US_US;
    funct6_lsu.lsu_funct6.lsu_is_seg = NONE;
    valid_lsu_mop                    = 'b0;
    
    //NF1：普通单 field 访存
    //NF2/NF3/.../NF8：segment load/store
    //例如：
    //vle32.v      → NF1，普通 load
    //vlseg2e32.v  → NF2，segment load
    //vlseg4e8.v   → NF4，segment load
    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_REGULAR: begin          
            // 普通 unit-stride；nf!=1 时按 segment 访存处理。
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_US;
            valid_lsu_mop                    = 1'b1;
            funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
          end
          US_WHOLE_REGISTER: begin
            // whole-register load/store：一次搬运完整向量寄存器组，evl 后面按 VLEN/EEW 计算。
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_WR;
            valid_lsu_mop                    = 1'b1;
          end
          US_MASK: begin
            // mask load/store：按 mask 字节流访问，EEW 在后面固定为 1 bit。
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_MK;
            valid_lsu_mop                    = 1'b1;
          end
          US_FAULT_FIRST: begin
            // fault-first 只对 unit-stride load 合法；特殊合法性检查会禁止 store。
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_FF;
            valid_lsu_mop                    = 1'b1;
            funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
          end
        endcase
      end
      UNORDERED_INDEX: begin
        // unordered indexed：vs2 提供索引，访存顺序不保证。
        funct6_lsu.lsu_funct6.lsu_mop    = IU;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
      CONSTANT_STRIDE: begin
        // constant-stride：所有元素地址按固定 stride 递增。
        funct6_lsu.lsu_funct6.lsu_mop    = CS;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
      ORDERED_INDEX: begin
        // ordered indexed：vs2 提供索引，要求按元素顺序保序访问。
        funct6_lsu.lsu_funct6.lsu_mop    = IO;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
    endcase
  end

// 计算 EMUL
  // 3. 计算 EMUL 和 uop_index_max。
  //    普通/segment load 使用 vd 作为数据寄存器；store 语义上数据源是 vs3，但编码字段同 vd。
  //    indexed 访存还需要计算 vs2 索引寄存器组的 EMUL。
  always_comb begin
    // 默认全部置为 NONE；如果没有命中合法组合，后续 check_lmul 会失败。
    emul_vd         = EMUL_NONE;
    emul_vs2        = EMUL_NONE;
    emul_vd_nf      = EMUL_NONE;
    emul_max        = EMUL_NONE;
    uop_index_max   = 'd0;

    if (valid_lsu) begin  
      case(funct6_lsu.lsu_funct6.lsu_mop)
        US: begin
          case(funct6_lsu.lsu_funct6.lsu_umop)
            US_US,
            US_FF: begin
              case(inst_nf)
                // 普通/fault-first unit-stride：
                // emul_vd = ceil(EEW/SEW * LMUL)
                // emul_vd_nf = NF * emul_vd
                // unit-stride 无 vs2 索引源，所以 emul_vs2 保持 EMUL_NONE。
                // uop_index_max = emul_vd_nf - 1，对应每个寄存器组切片展开一个 uop。
                NF1: begin
                  case({inst_funct3,csr_sew})  
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin  //width:sew = 1:1    
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);  // 对应 EMUL1 的 1 个寄存器组 uop
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);  // EMUL2
                          emul_vd_nf    = EMUL_e'(csr_lmul);
                          emul_max      = EMUL_e'(csr_lmul);
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);  // 对应 EMUL2 的 2 个寄存器组 uop
                        end
                        LMUL4: begin
                          emul_vd       = EMUL_e'(csr_lmul);  // EMUL4
                          emul_vd_nf    = EMUL_e'(csr_lmul);
                          emul_max      = EMUL_e'(csr_lmul);
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);  // 对应 EMUL4 的 4 个寄存器组 uop
                        end
                        LMUL8: begin
                          emul_vd       = EMUL_e'(csr_lmul);  // EMUL8
                          emul_vd_nf    = EMUL_e'(csr_lmul);
                          emul_max      = EMUL_e'(csr_lmul);
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);  // 对应 EMUL8 的 8 个寄存器组 uop
                        end
                      endcase
                    end
                    // 2:1
                // 普通/fault-first unit-stride：
                // emul_vd = ceil(EEW/SEW * LMUL)
                // emul_vd_nf = NF * emul_vd
                // unit-stride 无 vs2 索引源，所以 emul_vs2 保持 EMUL_NONE。
                // uop_index_max = emul_vd_nf - 1，对应每个寄存器组切片展开一个 uop。
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin     //width:sew = 2:1           
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL8;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                // 普通/fault-first unit-stride：
                // emul_vd = ceil(EEW/SEW * LMUL)
                // emul_vd_nf = NF * emul_vd
                // unit-stride 无 vs2 索引源，所以 emul_vs2 保持 EMUL_NONE。
                // uop_index_max = emul_vd_nf - 1，对应每个寄存器组切片展开一个 uop。
                    {SEW_32,SEW8}: begin       //width:sew = 4:1         
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL1_2: begin    
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL8;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                // 普通/fault-first unit-stride：
                // emul_vd = ceil(EEW/SEW * LMUL)
                // emul_vd_nf = NF * emul_vd
                // unit-stride 无 vs2 索引源，所以 emul_vs2 保持 EMUL_NONE。
                // uop_index_max = emul_vd_nf - 1，对应每个寄存器组切片展开一个 uop。
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin       //width:sew = 1:2         
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                      endcase
                    end
                    // 1:4
                // 普通/fault-first unit-stride：
                // emul_vd = ceil(EEW/SEW * LMUL)
                // emul_vd_nf = NF * emul_vd
                // unit-stride 无 vs2 索引源，所以 emul_vs2 保持 EMUL_NONE。
                // uop_index_max = emul_vd_nf - 1，对应每个寄存器组切片展开一个 uop。
                    {SEW_8,SEW32}: begin       //width:sew = 1:4         
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                      endcase
                    end
                  endcase
                end
                // 普通/fault-first unit-stride：
                // emul_vd = ceil(EEW/SEW * LMUL)
                // emul_vd_nf = NF * emul_vd
                // unit-stride 无 vs2 索引源，所以 emul_vs2 保持 EMUL_NONE。
                // uop_index_max = emul_vd_nf - 1，对应每个寄存器组切片展开一个 uop。
                NF2: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL1_2: begin    
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                      endcase
                    end
                  endcase
                end
                NF3: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL1_2: begin    
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                  endcase
                end
                NF4: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL1_2: begin    
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                  endcase
                end
                NF5: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                  endcase
                end
                NF6: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end                
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                  endcase
                end
                NF7: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                  endcase
                end
                NF8: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin            
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin            
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin            
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                  endcase
                end
              endcase
            end
            //whole-register load/store 不按普通 vl 作为元素数量，而是搬运完整向量寄存器组。
            US_WR: begin
              case(inst_nf)
                NF1: begin
                  emul_vd       = EMUL1;
                  emul_vd_nf    = EMUL1;
                  emul_max      = EMUL1;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                end
                NF2: begin
                  emul_vd       = EMUL2;
                  emul_vd_nf    = EMUL2;
                  emul_max      = EMUL2;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                end
                NF4: begin
                  emul_vd       = EMUL4;
                  emul_vd_nf    = EMUL4;
                  emul_max      = EMUL4;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                end
                NF8: begin
                  emul_vd       = EMUL8;
                  emul_vd_nf    = EMUL8;
                  emul_max      = EMUL8;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                end
              endcase
            end
            //mask load/store，EEW 固定为 1 bit，evl=ceil(vl/8) 字节。
            US_MK: begin
              case(csr_lmul)
                LMUL1_4,
                LMUL1_2,
                LMUL1,
                LMUL2,
                LMUL4,
                LMUL8: begin
                  emul_vd       = EMUL1;
                  emul_vd_nf    = EMUL1;
                  emul_max      = EMUL1;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                end
              endcase
            end
          endcase
        end
        //是固定 stride 访存：addr[i] = base + i × stride
        CS: begin
          case(inst_nf)
            // whole-register：
            // emul_vd = ceil(EEW/SEW * LMUL)
            // unit-stride 无 vs2 索引源。
            // emul_vd_nf = NF * emul_vd
            // emul_max = emul_vd_nf。
            // uop_index_max = emul_vd_nf - 1。
            NF1: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL8;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL8;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                  endcase
                end
              endcase
            end
            NF2: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                  endcase
                end
              endcase
            end
            NF3: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF4: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF5: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
              endcase
            end
            NF6: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end                
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF7: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
              endcase
            end
            NF8: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        
        //indexed 访存分两类：unordered indexed, ordered indexed
        //vs2 的 EEW 是 index 宽度，可能与数据 EEW 不同
        //IU/IO 中 vs2 是索引向量，EEW_vs2 由指令编码决定。
        IU,
        IO: begin
          case(inst_nf)
            // indexed：
            // emul_vd = LMUL 对应的数据寄存器组大小。
            // emul_vd_nf = NF * emul_vd。
            // emul_vs2 = ceil(index_EEW/SEW * LMUL)，描述索引向量寄存器组大小。
            // emul_max = max(emul_vd_nf, emul_vs2)。
            // uop_index_max = NF * max(emul_vd, emul_vs2) - 1。
            NF1: begin
              case({inst_funct3,csr_sew})
                // 1:1
                // {vs2,vd}
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                // // {vs2,vd}
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
            // indexed：
            // emul_vd = LMUL 对应的数据寄存器组大小。
            // emul_vd_nf = NF * emul_vd。
            // emul_vs2 = ceil(index_EEW/SEW * LMUL)，描述索引向量寄存器组大小。
            // emul_max = max(emul_vd_nf, emul_vs2)。
            // uop_index_max = NF * max(emul_vd, emul_vs2) - 1。
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF2: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF3: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL1: begin    
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                    LMUL2: begin    
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d23);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF4: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1_2: begin    
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL1: begin    
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                    LMUL2: begin    
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d31);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            // indexed：
            // emul_vd = LMUL 对应的数据寄存器组大小。
            // emul_vd_nf = NF * emul_vd。
            // emul_vs2 = ceil(index_EEW/SEW * LMUL)，描述索引向量寄存器组大小。
            // emul_max = max(emul_vd_nf, emul_vs2)。
            // uop_index_max = NF * max(emul_vd, emul_vs2) - 1。
            NF5: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d9);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d9);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d19);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
              endcase
            end
            NF6: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                  endcase
                end                
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d23);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF7: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d13);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d13);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d27);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
              endcase
            end
            NF8: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin            
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin            
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d31);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin            
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

// 计算 EEW
  // 4. 计算数据 EEW 和索引 EEW。
  //    unit/stride 访存只关心 eew_vd；indexed 访存同时关心数据元素 eew_vd 和索引元素 eew_vs2。
  always_comb begin
    // 默认 NONE；未命中 8/16/32 或非法组合时，后续 check_sew 会失败。
    eew_vd  = EEW_NONE;
    eew_vs2 = EEW_NONE;
    eew_max = EEW_NONE;  

    if (valid_lsu) begin  
      case(funct6_lsu.lsu_funct6.lsu_mop)
        US: begin
          case(funct6_lsu.lsu_funct6.lsu_umop)
            US_US,
            US_WR,
            US_FF: begin  //unit/whole/fault-first 访存，EEW 由 funct3 指定。
              case(inst_funct3)
                SEW_8: begin
                  // e8 unit/whole/fault-first 访存。
                  eew_vd          = EEW8;
                  eew_max         = EEW8;
                end
                SEW_16: begin
                  // e16 unit/whole/fault-first 访存。
                  eew_vd          = EEW16;
                  eew_max         = EEW16;
                end
                SEW_32: begin
                  // e32 unit/whole/fault-first 访存。
                  eew_vd          = EEW32;
                  eew_max         = EEW32;
                end
              endcase
            end
            US_MK: begin  //mask load/store 以 bit 为元素，编码仍要求 funct3=000。
              case(inst_funct3)
                SEW_8: begin
                  // mask load/store 以 bit 为元素，编码仍要求 funct3=000。
                  eew_vd          = EEW1;
                  eew_max         = EEW1;
                end
              endcase
            end
          endcase
        end
        CS: begin
          // constant-stride 数据 EEW 直接由 funct3 指定。
          case(inst_funct3)
            SEW_8: begin
              eew_vd          = EEW8;
              eew_max         = EEW8;
            end
            SEW_16: begin
              eew_vd          = EEW16;
              eew_max         = EEW16;
            end
            SEW_32: begin
              eew_vd          = EEW32;
              eew_max         = EEW32;
            end
          endcase
        end
        IU,
        IO: begin
          // indexed 访存：funct3 指定索引 EEW，csr_sew 指定数据 EEW。
          // 例如 {SEW_16,SEW32} 表示 16-bit index 访问 32-bit 数据元素。
          case({inst_funct3,csr_sew})
            {SEW_8,SEW8}: begin
              eew_vd          = EEW8;
              eew_vs2         = EEW8;
              eew_max         = EEW8;
            end
            {SEW_8,SEW16}: begin
              eew_vd          = EEW16;
              eew_vs2         = EEW8;
              eew_max         = EEW16;
            end
            {SEW_8,SEW32}: begin
              eew_vd          = EEW32;
              eew_vs2         = EEW8;
              eew_max         = EEW32;
            end
            {SEW_16,SEW8}: begin
              eew_vd          = EEW8;
              eew_vs2         = EEW16;
              eew_max         = EEW16;
            end
            {SEW_16,SEW16}: begin
              eew_vd          = EEW16;
              eew_vs2         = EEW16;
              eew_max         = EEW16;
            end
            {SEW_16,SEW32}: begin
              eew_vd          = EEW32;
              eew_vs2         = EEW16;
              eew_max         = EEW32;
            end
            {SEW_32,SEW8}: begin
              eew_vd          = EEW8;
              eew_vs2         = EEW32;
              eew_max         = EEW32;
            end
            {SEW_32,SEW16}: begin
              eew_vd          = EEW16;
              eew_vs2         = EEW32;
              eew_max         = EEW32;
            end
            {SEW_32,SEW32}: begin
              eew_vd          = EEW32;
              eew_vs2         = EEW32;
              eew_max         = EEW32;
            end
          endcase
        end
      endcase
    end
  end

//  
// 指令编码合法性检查

  // 5. LSU 指令合法性检查。
  //    check_special 覆盖具体访存形态的额外限制；check_common 覆盖所有 LSU 指令的公共限制。
  assign inst_encoding_correct = check_special&check_common&valid_lsu;

  // 当 vm=0 时使用 v0 作为 mask，load 的目的寄存器组不能覆盖 v0。
  // check_vd_overlap_v0=1 表示 vd 与 v0 不冲突；vm=1 时不使用 mask，直接通过。
  assign check_vd_overlap_v0 = (((inst_vm==1'b0)&(inst_vd!='b0)) | (inst_vm==1'b1));

  // indexed load 中，当数据 EEW 小于 index EEW 时，vd 不能只覆盖 vs2 寄存器组的一部分。
  // check_vd_part_overlap_vs2=1 表示没有这种“部分覆盖”冲突。
  always_comb begin
    check_vd_part_overlap_vs2     = 'b0;          
    
    case(emul_vs2)
      EMUL1: begin
        check_vd_part_overlap_vs2 = 1'b1;          
      end
      EMUL2: begin
        check_vd_part_overlap_vs2 = !((inst_vd[0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1])));
      end
      EMUL4: begin
        check_vd_part_overlap_vs2 = !((inst_vd[1:0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2])));
      end
      EMUL8 : begin
        check_vd_part_overlap_vs2 = !((inst_vd[2:0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3])));
      end
    endcase
  end

  // segment indexed load 中，vd/vs3 的 NF 个数据寄存器组不能与 index 源 vs2 整组重叠。
  // check_vd_overlap_vs2=1 表示完整寄存器组范围不相交。
  assign vd_index_start = {1'b0,inst_vd};

  always_comb begin
    case(emul_vd_nf)
      EMUL2:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d1);
      EMUL3:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d2);
      EMUL4:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d3);
      EMUL5:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d4);
      EMUL6:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d5);
      EMUL7:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d6);
      EMUL8:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d7);
      default: vd_index_offset = 'b0;
    endcase
  end
  assign vd_index_end = {1'b0, inst_vd+vd_index_offset};

  always_comb begin                                                             
    check_vd_overlap_vs2 = 'b0;          
    
    case(emul_vs2)
      EMUL1: begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2}<vd_index_start) || 
                               ({1'b0,inst_vs2}>vd_index_end);          
      end
      EMUL2: begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:1]}<vd_index_start[`REGFILE_INDEX_WIDTH:1]) || 
                               ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:1]}>vd_index_end[`REGFILE_INDEX_WIDTH:1]);          
      end
      EMUL4: begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:2]}<vd_index_start[`REGFILE_INDEX_WIDTH:2]) || 
                               ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:2]}>vd_index_end[`REGFILE_INDEX_WIDTH:2]);          
      end
      EMUL8 : begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:3]}<vd_index_start[`REGFILE_INDEX_WIDTH:3]) || 
                               ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:3]}>vd_index_end[`REGFILE_INDEX_WIDTH:3]);          
      end
    endcase
  end

  // indexed load 中，当数据 EEW 是 index EEW 的 2 倍时，vs2 不能只覆盖 vd 的非法半边。
  always_comb begin
    check_vs2_part_overlap_vd_2_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs2_part_overlap_vd_2_1 = 1'b1;
      end
      EMUL2: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1])&(inst_vs2[0]!=1'b1));
      end
      EMUL4: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2])&(inst_vs2[1:0]!=2'b10));
      end
      EMUL8: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3])&(inst_vs2[2:0]!=3'b100));
      end
    endcase
  end

  // indexed load 中，当数据 EEW 是 index EEW 的 4 倍时，vs2 不能只覆盖 vd 的非法 1/4 子组。
  always_comb begin
    check_vs2_part_overlap_vd_4_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs2_part_overlap_vd_4_1 = 1'b1;
      end
      EMUL2: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1])&(inst_vs2[0]!=1'b1));
      end
      EMUL4: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2])&(inst_vs2[1:0]!=2'b11));
      end
      EMUL8: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3])&(inst_vs2[2:0]!=3'b110));
      end
    endcase
  end

  // 针对不同访存形态的特殊限制：
  // - 普通/stride load 目的不能覆盖 v0 mask；store 没有目的寄存器，所以放行。
  // - whole-register 要求 vm=1；store whole-register 只接受 funct3=e8。
  // - mask load/store 要求 vm=1、funct3=e8、funct6 高位为 0。
  // - fault-first 只允许 load，并且目的不能覆盖 v0。
  // - indexed segment load 还要求 vd 组不与 vs2 index 组重叠。
  always_comb begin 
    check_special = 'b0;

    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_REGULAR: begin
            check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0 : 1'b1;
          end
          US_WHOLE_REGISTER: begin  //
            check_special = inst_vm&((inst_opcode==LOAD)||((inst_opcode==STORE)&(inst_funct3==SEW_8)));
          end
          US_MASK: begin
            check_special = inst_vm&(inst_funct3==SEW_8)&(inst_funct6[5:3]=='b0);
          end
          US_FAULT_FIRST: begin
            check_special = check_vd_overlap_v0&(inst_opcode==LOAD);
          end
        endcase
      end
      
      CONSTANT_STRIDE: begin
        check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0 : 1'b1;
      end
      
      UNORDERED_INDEX,
      ORDERED_INDEX: begin
        if (inst_nf==NF1) begin
          case({inst_funct3,csr_sew})
            // EEW_vs2:EEW_vd = 1:1。
            {SEW_8,SEW8},
            {SEW_16,SEW16},
            {SEW_32,SEW32}: begin            
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0 : 1'b1;
            end
            // 2:1
            {SEW_16,SEW8},
            {SEW_32,SEW16},            
            // 4:1
            {SEW_32,SEW8}: begin            
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vd_part_overlap_vs2 : 1'b1;
            end
            // 1:2
            {SEW_8,SEW16},
            {SEW_16,SEW32}: begin            
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1 : 1'b1;
            end
            // 1:4
            {SEW_8,SEW32}: begin            
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vs2_part_overlap_vd_4_1 : 1'b1;
            end
          endcase
        end
        else begin
          // segment indexed load 中，vd 组不能与 vs2 索引组完整重叠。
          check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vd_overlap_vs2 : 1'b1;
        end        
      end
    endcase
  end

  // 所有 LSU 指令共享的合法性：寄存器组对齐、寄存器编号不越界、EEW/EMUL 有效、
  // | 检查                     | 作用                                     |
  // | ---------------------- | -------------------------------------- |
  // | `check_vd_align`       | `vd` 是否按 `emul_vd` 对齐                  |
  // | `check_vs2_align`      | indexed 访存的 `vs2` 是否按 `emul_vs2` 对齐    |
  // | `check_vd_in_range`    | segment/whole-register 是否导致寄存器编号超过 v31 |
  // | `check_sew`            | `eew_max` 是否有效                         |
  // | `check_lmul`           | `emul_max` 是否有效                        |
  // | `check_evl_not_0`      | 实际执行长度 `evl` 不能为 0                     |
  // | `check_vstart_sle_evl` | `vstart <= evl`                        |
  // | `check_frm`            | 浮点舍入模式是否有效，当前统一保留检查                    |
  // evl 非 0、vstart 小于 evl；若打开 CHECK_FRM，还会检查浮点舍入模式编码。
  assign check_common = check_vd_align&check_vs2_align&check_vd_in_range&check_sew&check_lmul
                      `ifdef ZVE32F_ON
                        `ifdef CHECK_FRM
                        &check_frm
                        `endif
                      `endif
                        &check_evl_not_0&check_vstart_sle_evl;

  // vd/vs3 必须按 EMUL 对齐，例如 EMUL4 要求寄存器编号低 2 bit 为 0。
  always_comb begin
    check_vd_align = 'b0; 

    case(emul_vd)
      EMUL_NONE,
      EMUL1: begin
        check_vd_align = 1'b1; 
      end
      EMUL2: begin
        check_vd_align = (inst_vd[0]==1'b0); 
      end
      EMUL4: begin
        check_vd_align = (inst_vd[1:0]==2'b0); 
      end
      EMUL8: begin
        check_vd_align = (inst_vd[2:0]==3'b0); 
      end
    endcase
  end

  // indexed 访存的 vs2 index 寄存器组也必须按 emul_vs2 对齐。
  always_comb begin
    check_vs2_align = 'b0; 

    case(emul_vs2)
      EMUL_NONE,
      EMUL1: begin
        check_vs2_align = 1'b1; 
      end
      EMUL2: begin
        check_vs2_align = (inst_vs2[0]==1'b0); 
      end
      EMUL4: begin
        check_vs2_align = (inst_vs2[1:0]==2'b0); 
      end
      EMUL8: begin
        check_vs2_align = (inst_vs2[2:0]==3'b0); 
      end
    endcase
  end
  
  // 检查 vd/vs3 + NF*EMUL 是否仍落在 v0-v31 范围内。
  // 例如 emul_vd_nf=EMUL8 时，起始寄存器最大只能是 v24。
  always_comb begin 
    case(emul_vd_nf)
      EMUL1:   check_vd_cmp = 'd31;
      EMUL2:   check_vd_cmp = 'd30;
      EMUL3:   check_vd_cmp = 'd29;
      EMUL4:   check_vd_cmp = 'd28;
      EMUL5:   check_vd_cmp = 'd27;
      EMUL6:   check_vd_cmp = 'd26;
      EMUL7:   check_vd_cmp = 'd25;
      EMUL8:   check_vd_cmp = 'd24;
      default: check_vd_cmp = 'b0;
    endcase
  end
  assign check_vd_in_range = (emul_vd_nf!=EMUL_NONE) ? inst_vd <= check_vd_cmp : 'b0;

  // eew_max 仍为 NONE 说明 EEW 编码或 SEW 组合不受支持。
  assign check_sew = (eew_max != EEW_NONE);
    
  // emul_max 仍为 NONE 说明 LMUL/EEW/segment 组合不受支持。
  assign check_lmul = (emul_max != EMUL_NONE);

  // 6. 计算 LSU 使用的有效元素数 evl。
  //    大多数访存 evl=vl；whole-register 和 mask 访存按规范改写 evl。
  // | 访存类型                               | `evl` 语义                                 |
  // | ---------------------------------- | ---------------------------------------- |
  // | 普通 unit-stride / strided / indexed | 通常等于 `csr_vl`                            |
  // | mask load/store                    | `ceil(vl/8)`，因为 mask 是 bitstream，按字节访问   |
  // | whole-register                     | 不使用普通 `vl`，按完整寄存器容量计算                    |
  // | fault-first                        | 初始类似普通 load，实际 fault 后 `vl` 更新由 LSU 后续处理 |
  always_comb begin
    evl = csr_vl;
    
    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_WHOLE_REGISTER: begin
            // whole-register：evl = 寄存器组数 * VLEN / EEW，不依赖当前 vl。
            case(emul_max)
              EMUL1: begin
                case(eew_max)
                  EEW8: begin
                    evl = 1*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 1*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 1*`VLEN/32;
                  end
                endcase
              end
              EMUL2: begin
                case(eew_max)
                  EEW8: begin
                    evl = 2*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 2*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 2*`VLEN/32;
                  end
                endcase
              end
              EMUL4: begin
                case(eew_max)
                  EEW8: begin
                    evl = 4*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 4*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 4*`VLEN/32;
                  end
                endcase
              end
              EMUL8: begin
                case(eew_max)
                  EEW8: begin
                    evl = 8*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 8*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 8*`VLEN/32;
                  end
                endcase
              end
            endcase
          end
          US_MASK: begin       
            // mask load/store 以字节搬运 mask，元素数按 ceil(vl/8) 计算。
            evl = {3'b0,csr_vl[`VL_WIDTH-1:3]} + (csr_vl[2:0]!='b0);
          end
        endcase
      end
    endcase
  end
  
  // evl=0 时本模块认为指令无效，不向后续 LSU 发射。
  assign check_evl_not_0 = evl!='b0;

  // vstart 必须落在本条访存实际处理的 evl 范围内。
  assign check_vstart_sle_evl = {1'b0,csr_vstart} < evl;

`ifdef ZVE32F_ON
  // 若启用浮点相关检查，frm 只能是 0-4；5-7 为非法/保留编码。
  assign check_frm = inst.arch_state.frm < 3'd5;
`endif

  `ifdef ASSERT_ON
    `ifdef TB_SUPPORT
      `rvv_forbid((inst_valid==1'b1)&(inst_encoding_correct==1'b0))
      else $warning("pc(0x%h) instruction will be discarded directly.\n",$sampled(inst.inst_pc));
    `else
      `rvv_forbid((inst_valid==1'b1)&(inst_encoding_correct==1'b0))
      else $warning("This instruction will be discarded directly.\n");
    `endif
  `endif
  
  // 当源/目的寄存器重叠且 EEW 不同，规范要求该指令按 mask-agnostic 处理，避免保留旧值语义。
  assign force_vma_agnostic = (check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE);

  // mask 目的寄存器的 tail 元素总是 tail-agnostic；不同 EEW 重叠时也强制 tail-agnostic。
  assign force_vta_agnostic = (eew_vd==EEW1) |
                              ((check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE));
  
  // 7. 组装 LCMD。LSU 指令没有 vs1 向量源，所以 eew/emul_vs1 固定为 NONE。
  assign lcmd_valid              = inst_encoding_correct;
  assign lcmd.cmd                = inst;
  assign lcmd.eew_vs1            = EEW_NONE;
  assign lcmd.eew_vs2            = eew_vs2;
  assign lcmd.eew_vd             = eew_vd;
  assign lcmd.eew_max            = eew_max;
  assign lcmd.emul_vs1           = EMUL_NONE;
  assign lcmd.emul_vs2           = emul_vs2;
  assign lcmd.emul_vd            = emul_vd;
  assign lcmd.emul_max           = emul_max;
  assign lcmd.uop_vstart         = 'b0;
  assign lcmd.uop_index_max      = uop_index_max;
  assign lcmd.evl                = evl;
  assign lcmd.force_vma_agnostic = force_vma_agnostic;
  assign lcmd.force_vta_agnostic = force_vta_agnostic;

endmodule
