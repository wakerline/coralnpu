
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_unit_lsu_de2` -> RVV 后端 DE2 的向量访存 uop 展开器。
// - 接口与数据流：
//   * 输入：来自 DE1 LSU decode 的 `LCMD_t`，其中已经包含 EMUL/EEW/evl/uop_index_max 等信息。
//   * 处理：将 LOAD/STORE、unit-stride/stride/indexed、segment、mask、whole-register 等访存命令展开成 LSU uop。
//   * 输出：候选 `UOP_QUEUE_t` 数组，交给 `rvv_backend_decode_ctrl` 压缩并写入 Uop Queue。
// - 调用关系：上层 rvv_backend_decode_unit_de2；无下层实例。
// - 端口摘要：输入 lcmd_valid, lcmd, uop_index_remain；输出 uop_valid, uop。
// - define/参数阅读重点：
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `FUNCT3_WIDTH`：3。
//   * `FUNCT6_WIDTH`：6。
//   * `HWORD_WIDTH`：16。
//   * `NFIELD_WIDTH`：3。
//   * `NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `UMOP_WIDTH`：5。
//   * `UOP_INDEX_WIDTH`：5。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VM_WIDTH`：1。
//   * `VSTART_WIDTH`：$clog2(`VLEN)；依赖 VLEN。
//   * `WORD_WIDTH`：32。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - 关键生成逻辑：
//   * `uop_index_base/current`：决定本拍候选 uop 覆盖哪个寄存器组切片。
//   * `funct6_lsu`：重新生成 LSU mop/umop/is_store/is_seg，供后续 LSU 执行流水使用。
//   * `vector_csr[i].vstart`：按 uop 覆盖的数据/索引元素范围修正，segment 访存保持原始 vstart。
//   * `vd_offset/vs2_offset`：处理 NF、EMUL、EEW_vd 与 EEW_vs2 比例带来的寄存器组重排。
//   * `pshrob_valid/pshlsu_valid`：访存 uop 既要进 LSU 队列，也要在合适时机进入 ROB/完成跟踪。
// - 阅读建议：按 “字段拆分 -> mop/umop -> uop_index -> vstart -> vd/vs2 offset -> segment index -> UOP_QUEUE 输出” 阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_decode_unit_lsu_de2
(
  lcmd_valid,
  lcmd,
  uop_index_remain,
  uop_valid,
  uop
);
//
// 接口信号
//
  // 单条 LSU LCMD，有效时代表该命令已在 DE1 通过访存合法性检查。
  input   logic                               lcmd_valid;
  input   LCMD_t                              lcmd;

  // controller 反馈的续发位置；LSU 长指令从该 uop_index 继续展开。
  input   logic       [`UOP_INDEX_WIDTH-1:0]  uop_index_remain;
  // 输出给 controller 的候选访存 uop。
  output  logic       [`NUM_DE_UOP-1:0]       uop_valid;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]       uop;

//
// 内部信号
//
  logic   [`FUNCT6_WIDTH-1:0]                         inst_funct6;      // 原始指令编码 [31:26]。
  logic   [`NFIELD_WIDTH-1:0]                         inst_nf;          // 原始指令编码 [31:29]，segment NF 字段。
  logic   [`VM_WIDTH-1:0]                             inst_vm;          // 原始指令编码 [25]，mask 位。
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  inst_vs2;         // 原始指令编码 [24:20]，indexed 访存索引源。
  logic   [`UMOP_WIDTH-1:0]                           inst_umop;        // 原始指令编码 [24:20]，unit-stride 子操作。
  logic   [`FUNCT3_WIDTH-1:0]                         inst_funct3;      // 原始指令编码 [14:12]，访存 EEW 编码。
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  inst_vd;          // 原始指令编码 [11:7]，load 目的或 store 数据源字段。
  RVVOpCode                                           inst_opcode;      // 原始指令编码 [6:0]，LOAD/STORE。
  RVVConfigState                                      vector_csr_lsu;
  logic   [`VSTART_WIDTH-1:0]                         csr_vstart;
  logic   [`UOP_INDEX_WIDTH-1:0]                      uop_index_max;         
  EMUL_e                                              emul_vd;          
  EMUL_e                                              emul_vs2;          
  EMUL_e                                              emul_max; 
  EEW_e                                               eew_vd;          
  EEW_e                                               eew_vs2;          
  EEW_e                                               eew_max;          

  logic                                               valid_lsu;
  logic                                               valid_lsu_opcode;
  logic                                               valid_lsu_mop;
  logic   [`UOP_INDEX_WIDTH-1:0]                      uop_index_base;         
  logic   [`NUM_DE_UOP-1:0][`UOP_INDEX_WIDTH:0]       uop_index_current;   
  logic   [`NUM_DE_UOP-1:0]                           first_uop_valid;    
  logic   [`NUM_DE_UOP-1:0]                           last_uop_valid;     
  UOP_CLASS_e                                         uop_class;   
  RVVConfigState  [`NUM_DE_UOP-1:0]                   vector_csr;  
  logic   [`NUM_DE_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] vd_index;           
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vd_offset;
  logic                                               vd_valid;
  logic                                               vs3_valid;          
  logic   [`NUM_DE_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] vs2_index; 	        
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vs2_offset;
  logic   [`NUM_DE_UOP-1:0]                           vs2_valid;
  logic   [`NUM_DE_UOP-1:0][`UOP_INDEX_WIDTH-1:0]     uop_index;          
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    seg_field_index;
  logic   [`NUM_DE_UOP-1:0]                           pshrob_valid;  
  logic                                               pshlsu_valid;
  FUNCT6_u                                            funct6_lsu;  
  genvar                                              j;

//
// 解码
//
  // 从 LCMD 中恢复原始访存指令字段，以及 DE1 已计算的 EMUL/EEW/uop 范围。
  assign inst_funct6    = lcmd_valid ? lcmd.cmd.bits[24:19] : 'b0;
  assign inst_nf        = lcmd_valid ? lcmd.cmd.bits[24:22] : 'b0;
  assign inst_vm        = lcmd_valid ? lcmd.cmd.bits[18] : 'b0;
  assign inst_vs2       = lcmd_valid ? lcmd.cmd.bits[17:13] : 'b0;
  assign inst_umop      = lcmd_valid ? lcmd.cmd.bits[17:13] : 'b0;
  assign inst_funct3    = lcmd_valid ? lcmd.cmd.bits[7:5] : 'b0;
  assign inst_vd        = lcmd_valid ? lcmd.cmd.bits[4:0] : 'b0;
  assign inst_opcode    = lcmd_valid ? lcmd.cmd.opcode : LOAD;
  assign vector_csr_lsu = lcmd_valid ? lcmd.cmd.arch_state : RVVConfigState'('0);
  assign csr_vstart     = lcmd_valid ? lcmd.cmd.arch_state.vstart : 'b0;
  assign uop_index_max  = lcmd_valid ? lcmd.uop_index_max : 'b0;
  assign emul_vd        = lcmd_valid ? lcmd.emul_vd : EMUL_NONE; 
  assign emul_vs2       = lcmd_valid ? lcmd.emul_vs2 : EMUL_NONE;
  assign emul_max       = lcmd_valid ? lcmd.emul_max : EMUL_NONE;
  assign eew_vd         = lcmd_valid ? lcmd.eew_vd : EEW_NONE; 
  assign eew_vs2        = lcmd_valid ? lcmd.eew_vs2 : EEW_NONE;
  assign eew_max        = lcmd_valid ? lcmd.eew_max : EEW_NONE;

  // opcode 和 mop/umop 都合法时，才认为这是有效 LSU uop 展开输入。
  assign valid_lsu = valid_lsu_opcode&valid_lsu_mop&lcmd_valid;

  // 识别 LOAD/STORE，并写入 funct6_lsu.is_store。
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
  // lsu_umop 在 unit-stride 下继续区分普通、whole-register、mask、fault-first。
    // 默认值先落到普通 unit-stride；只有匹配合法编码后 valid_lsu_mop 才置位。
    funct6_lsu.lsu_funct6.lsu_mop    = US;
    funct6_lsu.lsu_funct6.lsu_umop   = US_US;
    funct6_lsu.lsu_funct6.lsu_is_seg = NONE;
    valid_lsu_mop                    = 'b0;
    
    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_REGULAR: begin          
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_US;
            valid_lsu_mop                    = 1'b1;
            funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
          end
          US_WHOLE_REGISTER: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_WR;
            valid_lsu_mop                    = 1'b1;
          end
          US_MASK: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_MK;
            valid_lsu_mop                    = 1'b1;
          end
          US_FAULT_FIRST: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_FF;
            valid_lsu_mop                    = 1'b1;
            funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
          end
        endcase
      end
      UNORDERED_INDEX: begin
        funct6_lsu.lsu_funct6.lsu_mop    = IU;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
      CONSTANT_STRIDE: begin
        funct6_lsu.lsu_funct6.lsu_mop    = CS;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
      ORDERED_INDEX: begin
        funct6_lsu.lsu_funct6.lsu_mop    = IO;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
    endcase
  end

//
// 拆分访存指令为候选 uop
//
  // LSU DE2 由 controller 明确给出续发起点；首次展开时 remain 为 0。
  assign uop_index_base = uop_index_remain;

  // 计算本拍每个候选槽对应的 uop_index。
  generate
    for(j=0;j<`NUM_DE_UOP;j++) begin: GET_UOP_INDEX
      assign uop_index_current[j] = {1'b0, uop_index_base} + j[`UOP_INDEX_WIDTH:0];
    end
  endgenerate

  // 只要当前 uop_index 没超过 DE1 给出的 uop_index_max，就生成候选 uop。
  always_comb begin        
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_VALID
      uop_valid[i] = lcmd_valid&(uop_index_current[i]<={1'b0,uop_index_max});
    end
  end

  // 首/尾 uop 标记。controller 用 last_uop_valid 决定 LCMD 何时可以 pop。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_LAST
      first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
      last_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == uop_index_max;
    end
  end

  // 生成 uop_class。
  // load: unit/stride 不读向量索引，为 XXX；indexed load 读 vs2 index，为 XVX。
  // store: unit/stride 读 store 数据 vs3，为 VXX；indexed store 读 vs3 和 vs2 index，为 VVX。
  always_comb begin
    // 默认 XXX。
    uop_class = XXX;
    
    case(inst_opcode) 
      // | load 类型              | `uop_class` | 原因                     |
      // | -------------------- | ----------- | ---------------------- |
      // | unit-stride load     | `XXX`       | 不读向量源，只需要 base/内部地址信息  |
      // | constant-stride load | `XXX`       | 不读向量源                  |
      // | indexed load         | `XVX`       | 需要读 `vs2` index vector |
      LOAD:begin
        case(inst_funct6[2:0])
          UNIT_STRIDE,
          CONSTANT_STRIDE: begin
            uop_class = XXX;
          end
          UNORDERED_INDEX,
          ORDERED_INDEX: begin
            uop_class = XVX;
          end
        endcase
      end
      // | store 类型              | `uop_class` | 原因                                        |
      // | --------------------- | ----------- | ----------------------------------------- |
      // | unit-stride store     | `VXX`       | 需要读 store data，也就是 `vs3`                  |
      // | constant-stride store | `VXX`       | 需要读 store data                            |
      // | indexed store         | `VVX`       | 同时读 store data `vs3` 和 index vector `vs2` |
      STORE: begin
        case(inst_funct6[2:0])
          UNIT_STRIDE,
          CONSTANT_STRIDE: begin
            uop_class = VXX;
          end
          UNORDERED_INDEX,
          ORDERED_INDEX: begin
            uop_class = VVX;
          end
        endcase
      end
    endcase
  end
  
  // 更新每个访存 uop 携带的 vector CSR/vstart。
  // 非 segment 访存按 uop_index 映射到对应元素块；segment 访存保持原始 vstart，由 seg_field_index 区分 field。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_VCSR
      // 默认值
      vector_csr[i] = vector_csr_lsu;

      // 为每个 uop 计算局部 vstart；indexed 且 index EEW 大于数据 EEW 时，一个 index uop 覆盖多个数据块。
      // index 元素更宽，一个 index 寄存器切片对应的数据元素覆盖范围更大，
      // 所以 data 的 uop_index 映射不能简单按当前 uop_index 直接推进。
      if(funct6_lsu.lsu_funct6.lsu_is_seg!=IS_SEGMENT) begin  //当 eew_vd < eew_vs2 时，一个索引 uop 涵盖的索引个数少，不足以填满一个数据 uop，
                                                              //因此多个索引 uop 才对应一个数据 uop 的元素范围。
        case({eew_vd,eew_vs2})
          // indexed load/store，且 eew_vd < eew_vs2。
          // eew_vd	eew_vs2	R	   起始数据索引 = floor(i/R) × 块大小	拼接操作
          // 8	       16	  2	   floor(i/2) * VLENB	              {i[W-1:1], log2(VLENB)'b0} (i>>1)
          // 16	       32	  2	   floor(i/2) * VLENH	              {i[W-1:1], log2(VLENH)'b0}
          // 8	       32	  4	   floor(i/4) * VLENB	              {i[W-1:2], log2(VLENB)'b0} (i>>2)
          {EEW8 ,EEW16}: begin
            vector_csr[i].vstart  = (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:1],($clog2(`VLENB)'('b0))}) < csr_vstart ? 
                                      csr_vstart : 
                                      (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:1],($clog2(`VLENB)'('b0))});
          end
          {EEW16,EEW32}: begin
            vector_csr[i].vstart  = (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:1],($clog2(`VLEN/`HWORD_WIDTH)'('b0))}) < csr_vstart ? 
                                      csr_vstart : 
                                      (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:1],($clog2(`VLEN/`HWORD_WIDTH)'('b0))});
          end
          {EEW8 ,EEW32}: begin
            vector_csr[i].vstart  = (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:2],($clog2(`VLENB)'('b0))}) < csr_vstart ? 
                                      csr_vstart : 
                                      (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:2],($clog2(`VLENB)'('b0))});
          end
          // 其他情况按数据 EEW 的每个 VLEN 切片推进。
          // EEW8  ：vstart = max(csr_vstart, uop_index × VLENB)
          // EEW16 ：vstart = max(csr_vstart, uop_index × VLEN/16)
          // EEW32 ：vstart = max(csr_vstart, uop_index × VLEN/32)
          default: begin  //当 eew_vd >= eew_vs2 或非 indexed 时，索引 uop 与数据 uop 是 1:1 的，每个 uop 对应一个数据块。
                          //此时索引 uop i 的起始数据元素索引就是 i * (VLEN / eew_max)。
            case(eew_max)
              EEW8: begin
                vector_csr[i].vstart  = (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:0],($clog2(`VLENB)'('b0))}) < csr_vstart ? 
                                          csr_vstart : 
                                          (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:0],($clog2(`VLENB)'('b0))});
              end
              EEW16: begin
                vector_csr[i].vstart  = (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:0],($clog2(`VLEN/`HWORD_WIDTH)'('b0))}) < csr_vstart ? 
                                          csr_vstart : 
                                          (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:0],($clog2(`VLEN/`HWORD_WIDTH)'('b0))});
              end
              EEW32: begin
                vector_csr[i].vstart  = (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:0],($clog2(`VLEN/`WORD_WIDTH)'('b0))}) < csr_vstart ? 
                                          csr_vstart : 
                                          (`VSTART_WIDTH)'({uop_index[i][`UOP_INDEX_WIDTH-1:0],($clog2(`VLEN/`WORD_WIDTH)'('b0))});
              end
            endcase
          end
        endcase
      end
    end
  end

  // 生成 vd_offset。
  // segment/NF 和 EMUL 组合会导致 uop_index 到物理寄存器 offset 的顺序不是简单递增；
  // 这里把同一 field 的不同寄存器组重新映射到正确的 vd/vs3 offset。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VD_OFFSET
      // 默认值
      vd_offset[i] = 'b0;

      case(inst_funct6[2:0])
        UNIT_STRIDE: begin
          case(inst_umop)  
            US_REGULAR,            
            US_FAULT_FIRST: begin  //segment 指令, 多个 field 交织
              case({inst_nf,emul_vd})
                {NF2,EMUL4}: begin  //两组，每组四个，v0, v4, v1, v5, v2, v6, v3, v7
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd4;
                    5'd2   : vd_offset[i] = 3'd1;
                    5'd3   : vd_offset[i] = 3'd5;
                    5'd4   : vd_offset[i] = 3'd2;
                    5'd5   : vd_offset[i] = 3'd6;
                    5'd6   : vd_offset[i] = 3'd3;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase   
                end
                {NF2,EMUL2}: begin  //两组，每组两个，v0, v2, v1, v3
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd2;
                    5'd2   : vd_offset[i] = 3'd1;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase   
                end
                {NF3,EMUL2}: begin  //三组，每组两个，v0, v2, v1, v3, v2, v4
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd2;
                    5'd2   : vd_offset[i] = 3'd4;
                    5'd3   : vd_offset[i] = 3'd1;
                    5'd4   : vd_offset[i] = 3'd3;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase   
                end
                {NF4,EMUL2}: begin  //四组，每组两个，v0, v2, v1, v3, v2, v4, v3, v5
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd2;
                    5'd2   : vd_offset[i] = 3'd4;
                    5'd3   : vd_offset[i] = 3'd6;
                    5'd4   : vd_offset[i] = 3'd1;
                    5'd5   : vd_offset[i] = 3'd3;
                    5'd6   : vd_offset[i] = 3'd5;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase
                end
                default:   //其他情况按 uop_index 直接映射到寄存器组切片。
                  vd_offset[i] = uop_index_current[i][2:0];
              endcase
            end
            US_WHOLE_REGISTER: begin  //普通情况 uop_index_current[i] 直接映射到寄存器组切片
              vd_offset[i] = uop_index_current[i][2:0];
            end
            US_MASK: begin  //只有一个v0
              vd_offset[i] = 'b0;
            end
          endcase
        end

        CONSTANT_STRIDE: begin
          case({inst_nf,emul_vd})
            {NF2,EMUL4}: begin  //两组，每组四个，v0, v4, v1, v5, v2, v6, v3, v7
              case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                5'd1   : vd_offset[i] = 3'd4;
                5'd2   : vd_offset[i] = 3'd1;
                5'd3   : vd_offset[i] = 3'd5;
                5'd4   : vd_offset[i] = 3'd2;
                5'd5   : vd_offset[i] = 3'd6;
                5'd6   : vd_offset[i] = 3'd3;
                default: vd_offset[i] = uop_index_current[i][2:0];
              endcase   
            end
            {NF2,EMUL2}: begin  //两组，每组两个，v0, v2, v1, v3
              case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                5'd1   : vd_offset[i] = 3'd2;
                5'd2   : vd_offset[i] = 3'd1;
                default: vd_offset[i] = uop_index_current[i][2:0];
              endcase   
            end
            {NF3,EMUL2}: begin  //三组，每组两个，v0, v2, v1, v3, v2, v4
              case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                5'd1   : vd_offset[i] = 3'd2;
                5'd2   : vd_offset[i] = 3'd4;
                5'd3   : vd_offset[i] = 3'd1;
                5'd4   : vd_offset[i] = 3'd3;
                default: vd_offset[i] = uop_index_current[i][2:0];
              endcase   
            end
            {NF4,EMUL2}: begin  //四组，每组两个，v0, v2, v1, v3, v2, v4, v3, v5
              case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                5'd1   : vd_offset[i] = 3'd2;
                5'd2   : vd_offset[i] = 3'd4;
                5'd3   : vd_offset[i] = 3'd6;
                5'd4   : vd_offset[i] = 3'd1;
                5'd5   : vd_offset[i] = 3'd3;
                5'd6   : vd_offset[i] = 3'd5;
                default: vd_offset[i] = uop_index_current[i][2:0];
              endcase
            end
            default: vd_offset[i] = uop_index_current[i][2:0];  //其他情况按 uop_index 直接映射到寄存器组切片。
          endcase
        end
        
        UNORDERED_INDEX,
        ORDERED_INDEX: begin  //需要考虑eew_vs2 与 eew_vd 的比例
          case({eew_vs2,eew_vd})
            // EEW_vs2:EEW_vd = 1:1。
            {EEW8,EEW8},
            {EEW16,EEW16},
            {EEW32,EEW32},            
            // EEW_vs2:EEW_vd = 1:2。
            {EEW8,EEW16},
            {EEW16,EEW32},
            // EEW_vs2:EEW_vd = 1:4。
            {EEW8,EEW32}: begin            
              case({inst_nf,emul_vd})
                {NF2,EMUL4}: begin  //index EEW 与 data EEW 一样，或者 index 更窄,大体可以沿用 segment 的 offset 映射。
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd4;
                    5'd2   : vd_offset[i] = 3'd1;
                    5'd3   : vd_offset[i] = 3'd5;
                    5'd4   : vd_offset[i] = 3'd2;
                    5'd5   : vd_offset[i] = 3'd6;
                    5'd6   : vd_offset[i] = 3'd3;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase   
                end
                {NF2,EMUL2}: begin
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd2;
                    5'd2   : vd_offset[i] = 3'd1;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase   
                end
                {NF3,EMUL2}: begin
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd2;
                    5'd2   : vd_offset[i] = 3'd4;
                    5'd3   : vd_offset[i] = 3'd1;
                    5'd4   : vd_offset[i] = 3'd3;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase   
                end
                {NF4,EMUL2}: begin
                  case(uop_index_current[i][`UOP_INDEX_WIDTH-1:0])
                    5'd1   : vd_offset[i] = 3'd2;
                    5'd2   : vd_offset[i] = 3'd4;
                    5'd3   : vd_offset[i] = 3'd6;
                    5'd4   : vd_offset[i] = 3'd1;
                    5'd5   : vd_offset[i] = 3'd3;
                    5'd6   : vd_offset[i] = 3'd5;
                    default: vd_offset[i] = uop_index_current[i][2:0];
                  endcase
                end
                default: vd_offset[i] = uop_index_current[i][2:0];
              endcase
            end
            // EEW_vs2:EEW_vd = 2:1。
            {EEW16,EEW8},
            {EEW32,EEW16},
            // EEW_vs2:EEW_vd = 4:1。
            {EEW32,EEW8}: begin              //index 更宽，一个 index 寄存器切片对应多个数据寄存器切片，数据寄存器组切片的顺序不是简单递增，需要重新映射。
              case({emul_vs2,emul_vd})
                {EMUL1,EMUL1}: 
                  vd_offset[i] = uop_index_current[i][2:0];
                {EMUL2,EMUL1}:  //v0, v1, v2, v3
                  vd_offset[i] = uop_index_current[i][3:1];  //两个 uop_index 对应同一个 data register offset
                {EMUL4,EMUL2}: begin
                  case(inst_nf)
                    NF2: begin  //索引寄存器组：v0, v1, v2, v3 （EMUL_vs2=4）
                                //数据寄存器组：两个字段各用 EMUL_vd=2，即字段 0 用 v0, v2，字段 1 用 v1, v3 （交错）
                                //数据依次存进 v0 → v2 → v1 → v3，而不是 v0, v1, v2, v3。
                      vd_offset[i] = {1'b0, uop_index_current[i][1], uop_index_current[i][2]};  
                    end
                    NF3: begin  //v0, v2, v4, v1, v3, v5
                      case(uop_index_current[i][`UOP_INDEX_WIDTH-1:1])
                        4'd1   : vd_offset[i] = 3'd2;
                        4'd2   : vd_offset[i] = 3'd4;
                        4'd3   : vd_offset[i] = 3'd1;
                        4'd4   : vd_offset[i] = 3'd3;
                        default: vd_offset[i] = uop_index_current[i][3:1];
                      endcase   
                    end
                    NF4: begin  //v0, v3, v1, v4, v2, v5, v3, v6
                      vd_offset[i] = {uop_index_current[i][2:1], uop_index_current[i][3]};
                    end
                    default: vd_offset[i] = {1'b0, uop_index_current[i][2:1]};  //v0, v2, v1, v3
                  endcase
                end
                {EMUL8,EMUL4}: begin 
                  if (inst_nf==NF2)
                    vd_offset[i] = {uop_index_current[i][1], uop_index_current[i][3:2]};
                  else
                    vd_offset[i] = {1'b0, uop_index_current[i][2:1]};
                end
                {EMUL4,EMUL1}: 
                  vd_offset[i] = uop_index_current[i][4:2];
                {EMUL8,EMUL2}: begin 
                  case(inst_nf)
                    NF2: begin
                      vd_offset[i] = {1'b0, uop_index_current[i][2], uop_index_current[i][3]};
                    end
                    NF3: begin
                      case(uop_index_current[i][`UOP_INDEX_WIDTH-1:2])
                        3'd1   : vd_offset[i] = 3'd2;
                        3'd2   : vd_offset[i] = 3'd4;
                        3'd3   : vd_offset[i] = 3'd1;
                        3'd4   : vd_offset[i] = 3'd3;
                        default: vd_offset[i] = uop_index_current[i][4:2];
                      endcase   
                    end
                    NF4: begin
                      vd_offset[i] = {uop_index_current[i][3:2], uop_index_current[i][4]};
                    end
                    default: vd_offset[i] = uop_index_current[i][4:2];
                  endcase
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

  // 计算实际 vd/vs3 寄存器编号。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VD
      vd_index[i] = inst_vd + {2'b0, vd_offset[i]};
    end
  end

  // 生成 vd_valid/vs3_valid。
  // LOAD 写 vd；STORE 不写 vd，而是把 inst_vd 字段作为 store 数据源 vs3。
  always_comb begin
    // 默认值
    vs3_valid = 'b0;
    vd_valid  = 'b0;

    if(inst_opcode==STORE)
      vs3_valid = 1'b1;
    else
      vd_valid  = 1'b1;
  end

  // 生成 indexed 访存的 vs2_offset/vs2_valid。
  // unit/stride 访存没有 index 源；indexed 访存才读取 vs2，offset 由 EEW 比例、EMUL 和 NF 决定。
  always_comb begin
    // 默认值
    vs2_offset = 'b0; 
    vs2_valid  = 'b0; 
    
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS2_OFFSET
      case(inst_funct6[2:0])
        UNORDERED_INDEX,
        ORDERED_INDEX: begin
          case({eew_vs2,eew_vd})
            // EEW_vs2:EEW_vd = 1:1。
            {EEW8,EEW8},
            {EEW16,EEW16},
            {EEW32,EEW32}: begin
              case(emul_vs2)
                EMUL2: begin
                  case(inst_nf)
                    NF2:     vs2_offset[i] = {2'b0, uop_index_current[i][1]};  //v0, v0, v1, v1
                    NF3:     vs2_offset[i] = (uop_index_current[i]>='d3) ? 3'd1 : 3'b0;  //v0, v0, v0, v1, v1, v1
                    NF4:     vs2_offset[i] = {2'b0, uop_index_current[i][2]};  //v0, v0, v0, v0, v1, v1, v1, v1
                    default: vs2_offset[i] = {2'b0, uop_index_current[i][0]};  //v0, v1
                  endcase
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL4: begin  //v0, v0, v1, v1, v2, v2, v3, v3或者v0, v1, v2, v3, v0, v1, v2, v3
                  vs2_offset[i] = (inst_nf==NF2) ? {1'b0, uop_index_current[i][2:1]} : {1'b0, uop_index_current[i][1:0]};
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL8: begin
                  vs2_offset[i] = uop_index_current[i][2:0];
                  vs2_valid[i]  = 1'b1; 
                end
                default: begin //EMUL1
                  vs2_offset[i] = 'b0;
                  vs2_valid[i]  = 1'b1; 
                end
              endcase
            end
            // EEW_vs2:EEW_vd = 2:1。
            {EEW16,EEW8},
            {EEW32,EEW16}: begin  //一个 index register 切片覆盖更多数据元素，对应关系变粗。
              case(emul_vs2)
                EMUL2: begin  //v0, v1, v2, v3
                  vs2_offset[i] = {2'b0, uop_index_current[i][0]};
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL4: begin
                  case(inst_nf)
                    NF2:     vs2_offset[i] = {1'b0, uop_index_current[i][2], uop_index_current[i][0]};  //v0, v1, v0, v1, v2, v3, v2, v3
                    NF3:     vs2_offset[i] = {1'b0, uop_index_current[i][3:1] >= 3'd3, uop_index_current[i][0]};
                    NF4:     vs2_offset[i] = {1'b0, uop_index_current[i][3], uop_index_current[i][0]};
                    default: vs2_offset[i] = uop_index_current[i][2:0]; // NF1
                  endcase
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL8: begin
                  vs2_offset[i] = (inst_nf==NF2) ? {uop_index_current[i][3:2], uop_index_current[i][0]} : uop_index_current[i][2:0];
                  vs2_valid[i]  = 1'b1; 
                end
                default: begin //EMUL1
                  vs2_offset[i] = 'b0;
                  vs2_valid[i]  = 1'b1; 
                end
              endcase
            end
            // EEW_vs2:EEW_vd = 4:1。
            {EEW32,EEW8}: begin    
              case(emul_vs2)
                EMUL2: begin  //索引寄存器组共有 2 个寄存器（v0、v1）,元素索引 0..3 在 v0，4..7 在 v1。
                  vs2_offset[i] = {2'b0, uop_index_current[i][0]};
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL4: begin  //16 个索引:索引 0..3 在 v0，4..7 在 v1，8..11 在 v2，12..15 在 v3。
                  vs2_offset[i] = {1'b0, uop_index_current[i][1:0]};
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL8: begin  //EMUL=8 时有 8 个索引寄存器（v0~v7），每个仍提供 4 个索引，共 32 个索引，对应 8 个 uop。
                  case(inst_nf)
                    //uop_index 中，[3] 可以看作段选择（0 或 1），[1:0] 是组内索引（0..3，对应每组 4 个索引）。
                    // 段 0 索引 0..3 → v0
                    // 段 1 索引 0..3 → v1
                    // 段 0 索引 4..7 → v2
                    // 段 1 索引 4..7 → v3
                    NF2:     vs2_offset[i] = {uop_index_current[i][3], uop_index_current[i][1:0]};
                    NF3:     vs2_offset[i] = {uop_index_current[i][4:2] >= 3'd3, uop_index_current[i][1:0]};
                    NF4:     vs2_offset[i] = {uop_index_current[i][4], uop_index_current[i][1:0]};
                    default: vs2_offset[i] = uop_index_current[i][2:0];  //NF1 如果没有段式访存（NF=1），寄存器也是自然线性排列：
                  endcase
                  vs2_valid[i]  = 1'b1; 
                end
                default: begin //EMUL1
                  vs2_offset[i] = 'b0;
                  vs2_valid[i]  = 1'b1; 
                end
              endcase
            end
            // EEW_vs2:EEW_vd = 1:2。
            {EEW8,EEW16},
            {EEW16,EEW32}: begin
              case(emul_vs2)
                EMUL1: begin
                  vs2_offset[i] = 'b0;
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL2: begin
                  vs2_offset[i] = (inst_nf==NF2) ? {2'b0, uop_index_current[i][2]} : {2'b0, uop_index_current[i][1]};
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL4: begin
                  vs2_offset[i] = {1'b0, uop_index_current[i][2:1]};
                  vs2_valid[i]  = 1'b1; 
                end
              endcase
            end
            // EEW_vs2:EEW_vd = 1:4。
            {EEW8,EEW32}: begin     
              case(emul_vs2)
                EMUL1: begin
                  vs2_offset[i] = 'b0;
                  vs2_valid[i]  = 1'b1; 
                end
                EMUL2: begin
                  vs2_offset[i] = {2'b0, uop_index_current[i][2]};
                  vs2_valid[i]  = 1'b1; 
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

  // 计算实际 vs2 index 寄存器编号。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS2
      vs2_index[i] = inst_vs2 + {2'b0, vs2_offset[i]}; 
    end
  end

  // 输出给后端的 uop_index，去掉比较用的额外最高位。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: ASSIGN_UOP_INDEX
      uop_index[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0];
    end
  end


  // seg_field_index 表示当前 uop 属于 segment 指令中的哪个 field/同 field 第几个切片。
  // 对于 segment 指令，后续 LSU 不只要知道当前 uop 的寄存器 offset，还要知道它属于哪个 segment field。
  // 例如：
  // vlseg4e32.v
  // 有 4 个 field。seg_field_index 会告诉 LSU 当前 uop 是 field0、field1、field2 还是 field3 的访问。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_SEG_INDEX
      // 默认规则：unit-stride、constant-stride，以及 EEW_vs2 <= EEW_vd 的 indexed 访存。
      if(inst_nf==NF2)  //field0 : 0、1； field1: 2、3; 每 2 个 uop 组成一个 field
        seg_field_index[i] = {1'b0, uop_index_current[i][2:1]};
      else if(inst_nf==NF3)  //field0 : 0、1、2； field1: 3、4、5;
        seg_field_index[i] = (uop_index_current[i]>=6'd3) ? 'd1 : 'b0;  
      else if(inst_nf==NF4)  //field0 : 0、1、2、3； field1: 4、5、6、7;
        seg_field_index[i] = {2'b0,uop_index_current[i][2]};
      else
        seg_field_index[i] = 'b0;

      // EEW_vs2 > EEW_vd 时，index uop 覆盖的数据切片更多，需要重算 segment field 归属。
      case(inst_funct6[2:0])
        UNORDERED_INDEX,
        ORDERED_INDEX: begin
          case({eew_vs2,eew_vd})
            // EEW_vs2:EEW_vd = 2:1。
            {EEW16,EEW8},
            {EEW32,EEW16}: begin
              case(emul_vs2)  //决定“分组粒度”
                EMUL2: seg_field_index[i] = {2'b0, uop_index_current[i][0]};  //每 2 个 uop 一个 field
                EMUL4: begin  //uop 被切成 4 个 field × 每个 field 4 个 uop，但 NF 决定“这 16 个 uop 怎么被交错分配”
                  case(inst_nf)  //决定“segment 切法
                    //field = (uop/4)*2 + (uop%2)
                    //0、1、4、5 → field0；2、3、6、7 → field1；8、9、12、13 → field2；10、11、14、15 → field3
                    NF2:     seg_field_index[i] = {1'b0, uop_index_current[i][2], uop_index_current[i][0]};
                    
                    NF3:     seg_field_index[i] = {1'b0, uop_index_current[i]>='d6, uop_index_current[i][0]};
                    ////0、1、8、9 → field0；2、3、10、11 → field1；4、5、12、13 → field2；6、7、14、15 → field3
                    NF4:     seg_field_index[i] = {1'b0, uop_index_current[i][3], uop_index_current[i][0]};
                    default: seg_field_index[i] = 'b0;
                  endcase
                end
                EMUL8: seg_field_index[i] = (inst_nf==NF2) ? {uop_index_current[i][3:2], uop_index_current[i][0]} : uop_index_current[i][2:0];
              endcase
            end
            // EEW_vs2:EEW_vd = 4:1。
            {EEW32,EEW8}: begin   
              case(emul_vs2)
                EMUL2: seg_field_index[i] = {2'b0, uop_index_current[i][0]};
                EMUL4: seg_field_index[i] = {1'b0, uop_index_current[i][1:0]};
                EMUL8: begin
                  case(inst_nf)
                    NF2:     seg_field_index[i] = {uop_index_current[i][3], uop_index_current[i][1:0]};
                    NF3:     seg_field_index[i] = {uop_index_current[i]>='d12, uop_index_current[i][1:0]};
                    NF4:     seg_field_index[i] = {uop_index_current[i][4], uop_index_current[i][1:0]};
                    default: seg_field_index[i] = uop_index_current[i][2:0];
                  endcase
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

  // pshrob_valid 决定该访存 uop 是否进入 ROB/完成跟踪。
  // 当 EEW_vs2 > EEW_vd 时，一个 index uop 可能对应多个数据 uop，只有覆盖完整数据组的 uop 才进 ROB。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: PSHROB_VLD
      // EEW_vs2 > EEW_vd 的 indexed 访存需要按比例稀疏入 ROB。
      case({eew_vs2,eew_vd})
        // EEW_vs2:EEW_vd = 2:1。
        {EEW16,EEW8},
        {EEW32,EEW16}: begin  //每 2 个 data 粒度的 uop 合并成 1 个 ROB 完成点。
          case(emul_vs2)
            EMUL2,
            EMUL4,
            EMUL8:   pshrob_valid[i] = uop_index_current[i][0];
            default: pshrob_valid[i] = 'b1;
          endcase
        end
        // EEW_vs2:EEW_vd = 4:1。
        {EEW32,EEW8}: begin  //每 4 个 data 粒度的 uop 合并成 1 个 ROB 完成点。
          case(emul_vs2)
            EMUL2:   pshrob_valid[i] = uop_index_current[i][0];  //覆盖rd四分之一结果
            EMUL4,
            EMUL8:   pshrob_valid[i] = uop_index_current[i][1:0]==2'b11;
            default: pshrob_valid[i] = 'b1;
          endcase
        end
        default: pshrob_valid[i] = 'b1;
      endcase
    end
  end

  // pshlsu_valid 决定该 uop 是否进入 LSU reservation station。
  // 在 UNMK_USCS_LOAD_NOHANDSHAKE 配置下，非 masked 的 unit/stride load 可不走普通 LSU 握手机制。
`ifdef UNMK_USCS_LOAD_NOHANDSHAKE
  assign pshlsu_valid = !( inst_vm & 
                          (funct6_lsu.lsu_funct6.lsu_is_store==IS_LOAD) &
                          ((funct6_lsu.lsu_funct6.lsu_mop==US)||(funct6_lsu.lsu_funct6.lsu_mop==CS))
                         );
`else
  assign pshlsu_valid = 1'b1;
`endif

  // 组装 UOP_QUEUE_t 输出。
  // LSU uop 固定使用 LSU 执行单元；vs1/rs1 标量字段在这里不使用，store 数据通过 vs3_valid 标记。
  generate
    for(j=0;j<`NUM_DE_UOP;j++) begin: ASSIGN_RES
    `ifdef TB_SUPPORT
      assign uop[j].uop_pc                = lcmd.cmd.inst_pc;
    `endif  
      assign uop[j].uop_funct3            = inst_funct3;
      assign uop[j].uop_funct6            = funct6_lsu;
      assign uop[j].uop_exe_unit          = LSU; 
      assign uop[j].uop_class             = uop_class;   
      assign uop[j].vector_csr            = vector_csr[j];  
      assign uop[j].vs_evl                = lcmd.evl;
      assign uop[j].ignore_vma            = 'b0;
      assign uop[j].ignore_vta            = 'b0;
      assign uop[j].force_vma_agnostic    = lcmd.force_vma_agnostic;
      assign uop[j].force_vta_agnostic    = lcmd.force_vta_agnostic;
      assign uop[j].vm                    = inst_vm;
      assign uop[j].v0_valid              = 'b1;          
      assign uop[j].dst_index             = vd_index[j];          
      assign uop[j].vd_eew                = lcmd.eew_vd;  
      assign uop[j].vd_valid              = vd_valid;
      assign uop[j].vs3_valid             = vs3_valid;
      assign uop[j].xd_valid              = 'b0; 
    `ifdef ZVE32F_ON
      assign uop[j].fd_valid              = 'b0; 
    `endif
      assign uop[j].vs1                   = 'b0;              
      assign uop[j].vs1_eew               = EEW_NONE;           
      assign uop[j].vs1_valid             = 'b0;
      assign uop[j].vs2_index 	          = vs2_index[j]; 	       
      assign uop[j].vs2_eew               = lcmd.eew_vs2;
      assign uop[j].vs2_valid             = vs2_valid[j];
      assign uop[j].rs1_data              = 'b0;           
      assign uop[j].rs1_data_valid        = 'b0;    
      assign uop[j].uop_index             = uop_index[j];         
      assign uop[j].first_uop_valid       = first_uop_valid[j];   
      assign uop[j].last_uop_valid        = last_uop_valid[j];    
      assign uop[j].seg_field_index       = seg_field_index[j];   
      assign uop[j].pshrob_valid          = pshrob_valid[j];   
      assign uop[j].pshlsu_valid          = pshlsu_valid;
    end
  endgenerate

endmodule
