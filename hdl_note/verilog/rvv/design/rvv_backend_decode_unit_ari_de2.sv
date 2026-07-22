
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_unit_ari_de2` -> RVV 后端 DE2 的算术/逻辑/浮点 uop 展开器。
// - 接口与数据流：
//   * 输入：来自 DE1 的 `LCMD_t`，其中已经包含 EMUL/EEW/uop_vstart/uop_index_max 等静态解码结果。
//   * 处理：按 OPIV*/OPMV*/OPF* 类别，将一条向量算术命令展开为最多 `NUM_DE_UOP` 个候选 uop。
//   * 输出：候选 `UOP_QUEUE_t` 数组，交给 `rvv_backend_decode_ctrl` 压缩并写入 Uop Queue。
// - 调用关系：上层 rvv_backend_decode_unit_de2；无下层实例。
// - 端口摘要：输入 lcmd_valid, lcmd, uop_index_remain；输出 uop_valid, uop。
// - define/参数阅读重点：
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `FUNCT3_WIDTH`：3。
//   * `FUNCT6_WIDTH`：6。
//   * `HWORD_WIDTH`：16。
//   * `IMM_WIDTH`：5。
//   * `NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `UOP_INDEX_WIDTH`：5。
//   * `UOP_INDEX_WIDTH_ALU`：$clog2(`UOP_NUM_ALU)=3。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VM_WIDTH`：1。
//   * `VSTART_WIDTH`：$clog2(`VLEN)；依赖 VLEN。
//   * `WORD_WIDTH`：32。
//   * `XLEN`：32；标量整数宽度。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 这些宽度/深度受 `DISPATCH3/DISPATCH2` 影响；当前配置文件开启 `DISPATCH3`。
// - 关键生成逻辑：
//   * `uop_index_base`：本拍第一个候选 uop 的 index，普通指令从 max(uop_vstart, remain) 续发。
//   * `first_uop_valid/last_uop_valid`：标记规约、比较、slide、compress 等需要特殊首/尾 uop 语义的边界。
//   * `uop_exe_unit`：把指令分派到 ALU/CMP/MUL/DIV/MAC/PMT/RDT/FMA/FDIV/FCVT 等执行单元。
//   * `uop_class`：描述该 uop 需要哪些源操作数和目的操作数，例如 XVV/VVX/VVV/XXX。
//   * `vd/vs1/vs2/v0/rs1` 相关 valid 和 index：决定 dispatch/scoreboard/VRF 读写端口如何使用。
// - 阅读建议：按 “字段拆分 -> uop_index -> valid/first/last -> exe_unit -> uop_class -> 寄存器索引 -> UOP_QUEUE 输出” 阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_decode_unit_ari_de2
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
  // 单条 ARI LCMD，有效时代表该命令已经在 DE1 通过合法性检查。
  input   logic                               lcmd_valid;
  input   LCMD_t                              lcmd;

  // controller 反馈的续发位置；长指令上一拍未发完时，从该 uop_index 继续。
  input   logic       [`UOP_INDEX_WIDTH-1:0]  uop_index_remain;
  // 本模块直接生成候选 uop，不直接与 Uop Queue ready 握手。
  output  logic       [`NUM_DE_UOP-1:0]       uop_valid;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]       uop;

//
// 内部信号
//
  // 从 lcmd.cmd.bits 重新拆出的 RVV 算术指令字段。
  logic   [`FUNCT6_WIDTH-1:0]                         inst_funct6;      // 原始指令编码 [31:26]。  
  logic   [`VM_WIDTH-1:0]                             inst_vm;          // 原始指令编码 [25]，mask 位。      
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  inst_vs2;         // 原始指令编码 [24:20]。
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  inst_vs1;         // 原始指令编码 [19:15]。
  logic   [`IMM_WIDTH-1:0]                            inst_imm;         // 原始指令编码 [19:15]，立即数形态复用 vs1 字段。
  logic   [`FUNCT3_WIDTH-1:0]                         inst_funct3;      // 原始指令编码 [14:12]，OPIV*/OPMV*/OPF* 类别。
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  inst_vd;          // 原始指令编码 [11:7]，向量目的或特殊 rd。
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  inst_rd;          // 原始指令编码 [11:7]，写整数/浮点标量时复用为 rd/fd。
  logic   [`UOP_INDEX_WIDTH-1:0]                      uop_vstart;         
  logic   [`XLEN-1:0]                                 rs1;
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  vs1_opcode;
  logic   [`REGFILE_INDEX_WIDTH-1:0]                  vs2_opcode;
  RVVConfigState                                      vector_csr_ari;
  logic   [`VSTART_WIDTH-1:0]                         csr_vstart;
  logic   [`UOP_INDEX_WIDTH-1:0]                      uop_index_max;         
  EMUL_e                                              emul_vd;          
  EMUL_e                                              emul_vs2;          
  EMUL_e                                              emul_vs1;          
  EMUL_e                                              emul_max; 
  EEW_e                                               eew_max; 

  logic                                               valid_opi;
  logic                                               valid_opm;
`ifdef ZVE32F_ON
  logic                                               valid_opf;
`endif
  // uop_index_base/current 决定本拍每个候选 uop 对应原指令的哪一个寄存器组切片。
  logic   [`UOP_INDEX_WIDTH-1:0]                      uop_index_base;         
  logic   [`NUM_DE_UOP-1:0][`UOP_INDEX_WIDTH:0]       uop_index_current;   
  // 首/尾 uop 标记会影响规约、比较进位、permutation 等指令的源/目的需求。
  logic   [`NUM_DE_UOP-1:0]                           first_uop_valid;    
  logic   [`NUM_DE_UOP-1:0]                           last_uop_valid; 
  // uop_exe_unit 是后续 dispatch 选择执行单元的主字段；uop_class 描述操作数形态。
  EXE_UNIT_e                                          uop_exe_unit; 
  UOP_CLASS_e     [`NUM_DE_UOP-1:0]                   uop_class;   
  RVVConfigState  [`NUM_DE_UOP-1:0]                   vector_csr; 
  logic                                               ignore_vma;
  logic                                               ignore_vta;  
  logic   [`NUM_DE_UOP-1:0]                           v0_valid;           
  logic   [`NUM_DE_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] vd_index;           
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vd_offset;
  logic   [`NUM_DE_UOP-1:0]                           vd_valid;
  logic   [`NUM_DE_UOP-1:0]                           vs3_valid;          
  logic   [`NUM_DE_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] vs1;              
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vs1_offset;
  logic   [`NUM_DE_UOP-1:0]                           vs1_valid;
  logic   [`NUM_DE_UOP-1:0][`REGFILE_INDEX_WIDTH-1:0] vs2_index; 	        
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vs2_offset;
  logic   [`NUM_DE_UOP-1:0]                           vs2_valid;
  logic                                               xd_valid; 
`ifdef ZVE32F_ON
  logic                                               fd_valid; 
`endif
  logic   [`XLEN-1:0] 	                              rs1_data;           
  logic        	                                      rs1_data_valid;     
  logic   [`NUM_DE_UOP-1:0][`UOP_INDEX_WIDTH-1:0]     uop_index;          
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    seg_field_index;
  logic   [`NUM_DE_UOP-1:0]                           pshrob_valid;  
  genvar                                              j;

//
// 解码
//
  // 从 LCMD 中取回原始字段以及 DE1 已计算好的 EMUL/EEW/uop 范围。
  assign inst_funct6    = lcmd_valid ? lcmd.cmd.bits[24:19] : 'b0;
  assign inst_vm        = lcmd_valid ? lcmd.cmd.bits[18] : 'b0;
  assign inst_vs2       = lcmd_valid ? lcmd.cmd.bits[17:13] : 'b0;
  assign vs2_opcode     = lcmd_valid ? lcmd.cmd.bits[17:13] : 'b0;
  assign inst_vs1       = lcmd_valid ? lcmd.cmd.bits[12:8] : 'b0;
  assign vs1_opcode     = lcmd_valid ? lcmd.cmd.bits[12:8] : 'b0;
  assign inst_imm       = lcmd_valid ? lcmd.cmd.bits[12:8] : 'b0;
  assign inst_funct3    = lcmd_valid ? lcmd.cmd.bits[7:5] : 'b0;
  assign inst_vd        = lcmd_valid ? lcmd.cmd.bits[4:0] : 'b0;
  assign inst_rd        = lcmd_valid ? lcmd.cmd.bits[4:0] : 'b0;
  assign vector_csr_ari = lcmd_valid ? lcmd.cmd.arch_state : 'b0;
  assign csr_vstart     = lcmd_valid ? lcmd.cmd.arch_state.vstart : 'b0;
  assign rs1            = lcmd_valid ? lcmd.cmd.rs1 : 'b0;
  assign uop_vstart     = lcmd_valid ? lcmd.uop_vstart : 'b0;
  assign uop_index_max  = lcmd_valid ? lcmd.uop_index_max : 'b0;
  assign emul_vd        = lcmd_valid ? lcmd.emul_vd : EMUL_NONE; 
  assign emul_vs2       = lcmd_valid ? lcmd.emul_vs2 : EMUL_NONE;
  assign emul_vs1       = lcmd_valid ? lcmd.emul_vs1 : EMUL_NONE;
  assign emul_max       = lcmd_valid ? lcmd.emul_max : EMUL_NONE;
  assign eew_max        = lcmd_valid ? lcmd.eew_max : EEW_NONE;

  always_comb begin
    // 按 funct3 粗分成整数/定点 OPI、mask/乘除/规约 OPM、浮点 OPF 三类。
    valid_opi = 'b0;
    valid_opm = 'b0;
    `ifdef ZVE32F_ON
    valid_opf = 'b0;
    `endif    

    case(inst_funct3)
      OPIVV,
      OPIVX,
      OPIVI: valid_opi = lcmd_valid;
      OPMVV,
      OPMVX: valid_opm = lcmd_valid;
    `ifdef ZVE32F_ON
      OPFVV,
      OPFVF: valid_opf = lcmd_valid;
    `endif    
    endcase
  end 

//
// 拆分指令为候选 uop
//
  // 选择本拍展开起始 uop_index。
  // 普通指令优先使用 controller 反馈的 remain，否则使用 DE1 给出的 uop_vstart。
  // gather/slideup/slide1up 这类需要从 uop0 建立全局状态的指令，强制以 remain 为起点。
  always_comb begin
    // 默认：remain 非 0 表示上一拍没发完；否则从 uop_vstart 开始。
    uop_index_base = (|uop_index_remain) ? uop_index_remain : uop_vstart;

    //对于 gather / slideup / slide1up 这类“非元素独立”的向量指令，硬件无法利用 vstart 做轻量级恢复；
    // 指令                 	跨 uop 依赖的状态
    // vrgather	             每个 uop 负责一段索引，结果需要跨 lane 收集并重组，内部数据通路可能需要所有 uop 顺序通过一个集中式收集器。
    // vslideup / vslide1up	 移位操作要求所有低索引元素先被搬移到位，才能写入高索引元素。如果从中间 uop 开始，低 uop 从未执行，移位源的数据是错的。
    // vfslide1up	           同上，浮点版本。
    case(1'b1)
      valid_opi: begin
        case(inst_funct6)
          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin  //
            uop_index_base = uop_index_remain;
          end
        endcase
      end

      valid_opm: begin
        case(inst_funct6)
          VSLIDE1UP: begin
            uop_index_base = uop_index_remain;
          end
        endcase
      end

    `ifdef ZVE32F_ON
      valid_opf: begin
        case(inst_funct6)
          VFSLIDE1UP: begin
            uop_index_base = uop_index_remain;
          end
        endcase
      end
    `endif
    endcase
  end

  // 为每个候选槽计算实际 uop_index；多出来 1 bit 用于与 uop_index_max 做越界比较。
  // NUM_DE_UOP`：6；当前 DISPATCH3 下 DE2 每拍最多写入 UQ 的 uop 数，DISPATCH2 时为 4。
  generate
    for(j=0;j<`NUM_DE_UOP;j++) begin: GET_UOP_INDEX  
      assign uop_index_current[j] = {1'b0, uop_index_base} + j[`UOP_INDEX_WIDTH:0];
    end
  endgenerate

  // 生成候选 uop valid。只要当前槽的 uop_index 没超过 uop_index_max，就可以作为候选输出。
  // 不论uop_index_base是从 uop_vstart 还是 uop_index_remain 开始，当前槽的 uop_index都从低位开始连续有效。
  always_comb begin        
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_VALID
      uop_valid[i] = lcmd_valid & ({1'b1, uop_index_base} <= ({1'b1,uop_index_max}-i[`UOP_INDEX_WIDTH:0]));
    end
  end

  // 标记首 uop。普通指令首 uop 等于 uop_vstart；部分 permutation 指令以 uop0 为首。
  always_comb begin
    // 默认无首 uop。
    first_uop_valid = 'b0;
    
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_FIRST
      first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == uop_vstart;

      //需要完整向量范围的全局状态，而不是从 vstart 对应切片简单开始。
      case(1'b1)
        valid_opi: begin
          case(inst_funct6)
            VSLIDEUP_RGATHEREI16,
            VRGATHER: begin
              first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
            end
          endcase
        end
        valid_opm: begin
          case(inst_funct6)
            VSLIDE1UP: begin
              first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
            end
          endcase
        end
        `ifdef ZVE32F_ON
        valid_opf: begin
          case(inst_funct6)
            VFSLIDE1UP: begin
              first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
            end
          endcase
        end
        `endif
      endcase
    end
  end

  // 标记尾 uop。controller 依靠该标记判断一条 LCMD 何时可以 pop。
  // 它表示当前 uop 是否是本条 LCMD 的最后一个 uop。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_LAST
      last_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == uop_index_max;
    end
  end

  // 选择执行单元。
  // 这里是 DE2 的关键功能之一：同样是 RVV opcode，不同 funct6 会进入 ALU/CMP/MUL/DIV/MAC/PMT/RDT/浮点单元等。
  always_comb begin
    // 默认落到 ALU，只有明确匹配到其他功能单元时覆盖。
    uop_exe_unit = ALU;
    
    case(1'b1)
      valid_opi: begin
        // | 指令类型                                                   | 执行单元                     |
        // | ------------------------------------------------------ | ------------------------ |
        // | `VADD/VSUB/VAND/VOR/VXOR/VSLL/VSRL/VSRA/VMIN/VMAX/...` | `ALU`                    |
        // | `VMADC/VMSBC/VMSEQ/VMSNE/VMSLT/VMSLE/...`              | `CMP`                    |
        // | `VWREDSUMU/VWREDSUM`                                   | `RDT`                    |
        // | `VSLIDEUP/VRGATHER/VSLIDEDOWN`                         | `PMT`                    |
        // | `VSMUL_VMVNRR`                                         | `OPIVI` 时 `ALU`，否则 `MUL` |
        // OPI*：普通整数/逻辑多进 ALU，比较进 CMP，规约进 RDT，重排进 PMT。
        case(inst_funct6)
          VADD,
          VSUB,
          VRSUB,
          VADC,
          VSBC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VNSRL,
          VNSRA,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VMERGE_VMV,
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSSRL,
          VSSRA,
          VNCLIPU,
          VNCLIP: begin
            uop_exe_unit = ALU;
          end 
          
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLTU,
          VMSLT,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT:begin
            uop_exe_unit = CMP;
          end
          
          VWREDSUMU,
          VWREDSUM: begin
            uop_exe_unit = RDT;
          end

          VSLIDEUP_RGATHEREI16,
          VSLIDEDOWN,
          VRGATHER: begin
            uop_exe_unit = PMT;
          end

          VSMUL_VMVNRR: begin
            uop_exe_unit = (inst_funct3==OPIVI) ? ALU : MUL;
          end
        endcase
      end

      valid_opm: begin
        // | 指令类型                               | 执行单元   |
        // | ------------------------------------- | ------ |
        // | 宽化加减、平均、mask 逻辑等              | `ALU`  |
        // | `VMUL/VMULH/VWMUL/...`                | `MUL`  |
        // | `VDIV/VDIVU/VREM/VREMU`               | `DIV`  |
        // | `VMACC/VNMSAC/VMADD/VNMSUB/VWMACC...` | `MAC`  |
        // | 整数规约 `VREDSUM/VREDMAX/...`         | `RDT`  |
        // | `VCPOP`                               | `MISC` |
        // | `VIOTA`                               | `MISC` |
        // | `VSLIDE1UP/VSLIDE1DOWN/VCOMPRESS`     | `PMT`  |
        // OPM*：覆盖宽化、乘除、乘加、规约、mask、compress/slide 等特殊整数类。
        case(inst_funct6)
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W,
          VXUNARY0,
          VAADDU,
          VAADD,
          VASUBU,
          VASUB,
          VMAND,
          VMNAND,
          VMANDN,
          VMXOR,
          VMOR,
          VMNOR,
          VMORN,
          VMXNOR: begin
            uop_exe_unit = ALU;
          end

          VMUL,
          VMULH,
          VMULHU,
          VMULHSU,
          VWMUL,
          VWMULU,
          VWMULSU: begin
            uop_exe_unit = MUL;
          end

          VDIVU,
          VDIV,
          VREMU,
          VREM: begin
            uop_exe_unit = DIV;
          end
          
          VMACC,
          VNMSAC,
          VMADD,
          VNMSUB,
          VWMACCU,
          VWMACC,
          VWMACCSU,
          VWMACCUS: begin
            uop_exe_unit = MAC;
          end

          // 整数规约类。
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR: begin
            uop_exe_unit = RDT;
          end

          VWRXUNARY0: begin
            uop_exe_unit = (vs1_opcode==VCPOP)&(inst_funct3==OPMVV) ? MISC : ALU;
          end
          
          VMUNARY0: begin
            uop_exe_unit = (vs1_opcode==VIOTA) ? MISC : ALU;
          end

          VSLIDE1UP,
          VSLIDE1DOWN,
          VCOMPRESS: begin
            uop_exe_unit = PMT;
          end
        endcase
      end

      `ifdef ZVE32F_ON
      valid_opf: begin
        // | 指令类型                             | 执行单元    |
        // | -------------------------------- | ------- |
        // | `VFADD/VFSUB/VFMUL/VFMACC/...`   | `FMA`   |
        // | `VFDIV/VFRDIV/VFSQRT`            | `FDIV`  |
        // | `VFRSQRT7/VFREC7`                | `FTBL`  |
        // | `VFCLASS/VFMIN/VFMAX/VFSGNJ/...` | `FNCMP` |
        // | 浮点比较 `VMFEQ/VMFLT/...`           | `FCMP`  |
        // | 浮点转换 `VFCVT...`                  | `FCVT`  |
        // | 浮点规约 `VFRED...`                  | `FRDT`  |
        // | 浮点 slide                         | `PMT`   |
        // OPF*：浮点 FMA/除法/比较/转换/规约/重排等执行单元选择。
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16,
          `endif
          VFADD,
          VFSUB,      
          VFRSUB,     
          VFMUL,      
          VFMACC,     
          VFNMACC,    
          VFMSAC,     
          VFNMSAC,    
          VFMADD,     
          VFNMADD,    
          VFMSUB,     
          VFNMSUB: begin
            uop_exe_unit = FMA;
          end

          VFDIV,      
          VFRDIV: begin
            uop_exe_unit = FDIV;
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT: begin
                uop_exe_unit = FDIV;
              end
              VFRSQRT7,
              VFREC7: begin
                uop_exe_unit = FTBL;
              end
              VFCLASS: begin
                uop_exe_unit = FNCMP;
              end
            endcase
          end

          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX: begin
            uop_exe_unit = FNCMP;
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            uop_exe_unit = FCMP;
          end

          VFMERGE_VFMV,
          VWRFUNARY0: begin
            uop_exe_unit = ALU;
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16,
              VFWCVTBF16,
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin
                uop_exe_unit = FCVT;
              end
            endcase
          end

          VFREDOSUM,
          VFREDUSUM,
          VFREDMAX,
          VFREDMIN: begin
            uop_exe_unit = FRDT;
          end

          VFSLIDE1UP,
          VFSLIDE1DOWN: begin
            uop_exe_unit = PMT;
          end
        endcase
      end
      `endif  
    endcase
  end

  // 生成 uop_class。
  // uop_class 用来告诉 dispatch/scoreboard 该 uop 是否需要读 vs1/vs2/vd、是否写 vd 或标量 rd。
  // | `uop_class` | 直观含义                                         |
  // | ----------- | -------------------------------------------- |
  // | `XXX`       | 不需要普通向量源，或只依赖内部/标量/特殊逻辑                      |
  // | `XVV`       | 读两个向量源，通常是 `vs2` 和 `vs1`                     |
  // | `XVX`       | 读一个向量源和一个标量/立即数                              |
  // | `VVV`       | 读 `vd` 作为累加/旧值，同时读两个向量源                      |
  // | `VVX`       | 读 `vd` 作为累加/旧值，同时读向量源和标量                     |
  // | `XXV`       | 只读一个向量源，常见于 slide/gather/compress/merge 某些形态 |
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_CLASS
      // 默认 XXX，表示没有向量源操作数；具体指令再覆盖。
      uop_class[i] = XXX;
      
      case(1'b1)
        valid_opi: begin
          // OPI* uop_class。
          case(inst_funct6)
            VADD,
            VSUB,
            VRSUB,
            VADC,
            VSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VNSRL,
            VNSRA,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VNCLIPU,
            VNCLIP: begin
              if(inst_funct3==OPIVV)
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VWREDSUMU,
            VWREDSUM: begin
              if(first_uop_valid[i])
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VMADC,
            VMSBC,
            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMSGTU,
            VMSGT: begin
              if(last_uop_valid[i])
                uop_class[i] = inst_funct3==OPIVV ? VVV : VVX;
              else
                uop_class[i] = inst_funct3==OPIVV ? XVV : XVX;
            end

            VMERGE_VMV: begin
              if(inst_funct3==OPIVV)
                uop_class[i] = inst_vm ? XXV : XVV;
              else
                uop_class[i] = inst_vm ? XXX : XVX;
            end

            VSLIDEUP_RGATHEREI16,
            VSLIDEDOWN,
            VRGATHER: begin
              if(inst_funct3==OPIVV)
                uop_class[i] = XXV;
              else   
                uop_class[i] = XXX;
            end
          endcase
        end

        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VWMUL,
            VWMULU,
            VWMULSU,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            // 规约首 uop 读初始 vd/vs1，后续 uop 读上一次规约结果，操作数形态不同。
            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              if(first_uop_valid[i])
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VSLIDE1UP,
            VSLIDE1DOWN: begin
                uop_class[i] = XXX;
            end 
            
            VXUNARY0: begin
              uop_class[i]  = XVX;
            end

            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VWMACCUS: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = VVV;
              else
                uop_class[i] = VVX;
            end

            // 重排类：首 uop 通常需要源向量，后续 uop 多为内部状态推进。
            VCOMPRESS: begin
              if(first_uop_valid[i]) 
                uop_class[i] = XXV;
              else
                uop_class[i] = XXX;
            end

            // mask 类 逻辑：vstart=0 时不需要读旧 vd，否则需要保留/合并旧 mask。
            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              uop_class[i] = (csr_vstart=='b0) ? XVV : VVV;
            end

            VWRXUNARY0: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = XVX;
              else
                uop_class[i] = XXX;
            end

            VMUNARY0: begin
              case(vs1_opcode)
                VMSBF,
                VMSIF,
                VMSOF: begin
                  uop_class[i] = inst_vm ? XVX: VVX;
                end
                VIOTA: begin
                  uop_class[i] = first_uop_valid[i] ? XVX : XXX;
                end
                VID: begin
                  uop_class[i] = XXX;
                end
              endcase
            end
          endcase
        end

        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* uop_class。
          case(inst_funct6)
            VFADD,          
            VFSUB,      
            VFRSUB,
            VFMUL,      
            VFDIV,      
            VFRDIV,     
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VFSLIDE1UP,
            VFSLIDE1DOWN: begin
              if(inst_funct3==OPFVV)
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end 

            `ifdef ZVFBFWMA_ON
            VFWMACCBF16,
            `endif
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB:begin
              if(inst_funct3==OPFVV)
                uop_class[i] = VVV;
              else
                uop_class[i] = VVX;
            end

            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              if(first_uop_valid[i])
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VFUNARY0,
            VFUNARY1: begin
              uop_class[i] = XVX;
            end

            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              if(last_uop_valid[i]) 
                uop_class[i] = inst_funct3==OPFVV ? VVV : VVX;
              else
                uop_class[i] = inst_funct3==OPFVV ? XVV : XVX;
            end

            VFMERGE_VFMV: begin
              if(inst_vm)
                uop_class[i] = XXX;
              else
                uop_class[i] = XVX;
            end

            VWRFUNARY0: begin
              if(inst_funct3==OPFVV)
                uop_class[i] = XVX;
              else
                uop_class[i] = XXX;
            end
          endcase
        end
        `endif
      endcase
    end
  end

  // 更新每个 uop 携带的 vector CSR。
  // vstart 会按当前 uop 覆盖的元素块重新定位；比较/规约/compress 等需要全局状态的指令保留原始 vstart。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_VCSR
      vector_csr[i] = vector_csr_ari;

      // 为每个 uop 计算局部 vstart。
      if(uop_index_current[i]>{1'b0,uop_vstart}) begin
        case(1'b1)
          valid_opi: begin
            // OPI*
            case(inst_funct6)
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT,
              VWREDSUMU,
              VWREDSUM: begin
                vector_csr[i].vstart = vector_csr_ari.vstart;
              end
              default: begin //vstart 要根据 uop_index_current 和 EEW 重定位：
                case(eew_max)
                  EEW8: begin
                    vector_csr[i].vstart  = {uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLENB)){1'b0}}};
                  end
                  EEW16: begin
                    vector_csr[i].vstart  = {1'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`HWORD_WIDTH)){1'b0}}};
                  end
                  EEW32: begin
                    vector_csr[i].vstart  = {2'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`WORD_WIDTH)){1'b0}}};
                  end
                endcase
              end
            endcase
          end
          valid_opm: begin
            // OPM*
            case(inst_funct6)
              VREDSUM,
              VREDMAXU,
              VREDMAX,
              VREDMINU,
              VREDMIN,
              VREDAND,
              VREDOR,
              VREDXOR,
              VCOMPRESS: begin
                vector_csr[i].vstart = vector_csr_ari.vstart;
              end
              default: begin 
                case(eew_max)
                  EEW8: begin
                    vector_csr[i].vstart  = {uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLENB)){1'b0}}};
                  end
                  EEW16: begin
                    vector_csr[i].vstart  = {1'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`HWORD_WIDTH)){1'b0}}};
                  end
                  EEW32: begin
                    vector_csr[i].vstart  = {2'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`WORD_WIDTH)){1'b0}}};
                  end
                endcase
              end
            endcase
          end

          `ifdef ZVE32F_ON
          valid_opf: begin
            // OPF* 指令
            case(inst_funct6)
              VMFEQ,
              VMFNE,
              VMFLT,
              VMFLE,
              VMFGT,
              VMFGE,
              VFREDOSUM,
              VFREDUSUM,
              VFREDMAX,
              VFREDMIN: begin
                vector_csr[i].vstart = vector_csr_ari.vstart;
              end
              default: begin 
                case(eew_max)
                  EEW8: begin
                    vector_csr[i].vstart  = {uop_index_current[i][`UOP_INDEX_WIDTH-1:0],{($clog2(`VLENB)){1'b0}}};
                  end
                  EEW16: begin
                    vector_csr[i].vstart  = {1'b0,uop_index_current[i][`UOP_INDEX_WIDTH-1:0],{($clog2(`VLEN/`HWORD_WIDTH)){1'b0}}};
                  end
                  EEW32: begin
                    vector_csr[i].vstart  = {2'b0,uop_index_current[i][`UOP_INDEX_WIDTH-1:0],{($clog2(`VLEN/`WORD_WIDTH)){1'b0}}};
                  end
                endcase
              end
            endcase
          end
          `endif
        endcase
      end
    end
  end

  // 更新 ignore_vma/ignore_vta。
  // 有些指令把 vm 位复用为子 opcode，不应再按普通 mask policy 解释，因此需要 ignore_vma。
  // 目的 EEW=1 bit 的 mask 结果可能写 tail 元素，因此需要 ignore_vta 或交给 force_vta_agnostic 处理。
  // 当前指令不要按普通 vma/vta 策略处理某些 mask/tail 行为
  // ignore_* 是指令语义主动忽略普通策略；force_* 是因为寄存器重叠/EEW 不同等原因被强制 agnostic
  always_comb begin
    // 默认值 
    ignore_vma = 'b0;
    ignore_vta = 'b0;
      
    case(inst_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(inst_funct6)
          VADC,
          VSBC: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b0;
          end
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLTU,
          VMSLT,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b1;
          end
          VMERGE_VMV: begin
            if (inst_vm=='b0) begin
              ignore_vma = 1'b1;
            end
          end
        endcase
      end

      OPMVV: begin
        case(inst_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b1;
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF: begin
                ignore_vma = 1'b1;
                ignore_vta = 1'b1;
              end
            endcase
          end
        endcase
      end

    `ifdef ZVE32F_ON
    OPFVV: begin
      case(inst_funct6)
        VMFEQ,
        VMFNE,
        VMFLT,
        VMFLE: begin
          ignore_vma = 1'b1;
          ignore_vta = 1'b1;
        end
        VWRFUNARY0: begin
          ignore_vma = 1'b1;
          ignore_vta = 1'b0;
        end
      endcase
    end
    OPFVF: begin
      case(inst_funct6)
        VMFEQ,
        VMFNE,
        VMFLT,
        VMFLE,
        VMFGT,
        VMFGE: begin
          ignore_vma = 1'b1;
          ignore_vta = 1'b1;
        end
        VFMERGE_VFMV,
        VWRFUNARY0: begin
          ignore_vma = 1'b1;
          ignore_vta = 1'b0;
        end
      endcase
    end
    `endif
    endcase
  end
  
  // 生成 v0_valid。
  // vm=0 的 masked 指令需要 v0；部分指令只在首/尾 uop 读取 v0。
  // v0_valid[i] 表示当前 uop 是否需要读取 v0 mask
  always_comb begin
    // 默认值 
    v0_valid = 'b0;
       
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_V0
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VADC,
            VMADC,
            VSBC,
            VMSBC,
            VMERGE_VMV: begin
              v0_valid[i] = !inst_vm;  //直接需要 v0 的指令
            end

            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMSGTU,
            VMSGT: begin
              v0_valid[i] = inst_vm ? 'b0 : last_uop_valid[i];  //这意味着比较类可能先做分片比较，最终在尾 uop 进行 mask 合并/写回
            end
          endcase
        end
        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VWRXUNARY0: begin
              case(vs1_opcode)
                VCPOP,
                VFIRST: begin
                  v0_valid[i] = !inst_vm;  //直接需要 v0 的指令
                end
              endcase
            end
            VMUNARY0: begin
              case(vs1_opcode)
                VMSBF,
                VMSOF,
                VMSIF,
                VIOTA: begin
                  v0_valid[i] = !inst_vm;  //直接需要 v0 的指令
                end
              endcase
            end
          endcase
        end
        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* 指令
          case(inst_funct6)
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              v0_valid[i] = inst_vm ? 'b0 : last_uop_valid[i]; 
            end
            VFMERGE_VFMV: begin
              v0_valid[i] = !inst_vm;
            end
          endcase
        end
        `endif        
      endcase
    end
  end    
  
  // 生成 vd_offset/vd_valid。
  // vd_offset 表示当前 uop 写目的向量寄存器组中的第几个物理寄存器；
  // vd_valid 表示该 uop 是否真的写 vd。规约/比较这类指令常常只在最后一个 uop 写最终结果。
  always_comb begin
    vd_offset = 'b0;
    vd_valid  = 'b0;

    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VD_OFFSET  
      case(1'b1)
        valid_opi: begin
          case(inst_funct6)
            VADD,
            VSUB,
            VRSUB,
            VADC,
            VSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VMERGE_VMV,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VSLIDEDOWN,
            VRGATHER: begin  //普通同宽指令
              vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vd_valid[i]  = 1'b1;
            end

            VMADC,
            VMSBC,
            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMSGTU,
            VMSGT,
            VWREDSUMU,
            VWREDSUM: begin  //规约和比较通常只有最后一个 uop 写最终架构结果
              vd_offset[i] = 'b0;
              vd_valid[i]  = last_uop_valid[i];
            end

            VNSRL,
            VNSRA,
            VNCLIPU,
            VNCLIP: begin  //narrowing 类, 因为源宽、目的窄，两个源切片可能对应一个目的切片
              vd_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vd_valid[i]  = 1'b1;
            end

            VSLIDEUP_RGATHEREI16: begin
              case(inst_funct3)
                OPIVV: begin
                  case({emul_max,emul_vd})
                    {EMUL1,EMUL1},
                    {EMUL2,EMUL2},
                    {EMUL4,EMUL4},
                    {EMUL8,EMUL8}: begin
                      vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                      vd_valid[i]  = 1'b1;
                    end
                    {EMUL2,EMUL1},
                    {EMUL4,EMUL2},
                    {EMUL8,EMUL4}: begin
                      vd_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                      vd_valid[i]  = 1'b1;                    
                    end
                  endcase
                end
                OPIVX,
                OPIVI: begin  
                  vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vd_valid[i]  = 1'b1;
                end 
              endcase
            end
          endcase
        end

        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VXUNARY0,
            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VWMUL,
            VWMULU,
            VWMULSU,
            VWMACCUS,
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB,
            VSLIDE1UP,
            VSLIDE1DOWN,
            VCOMPRESS: begin
              vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vd_valid[i]  = 1'b1;
            end   

            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = last_uop_valid[i];
            end
             
            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = 1'b1;
            end

            VWRXUNARY0: begin
              case(inst_funct3)
                OPMVX: begin
                  vd_offset[i] = 'b0;
                  vd_valid[i]  = 1'b1;
                end
              endcase
            end
         
            VMUNARY0: begin
              case(vs1_opcode)
                VMSBF,
                VMSIF,
                VMSOF: begin
                  vd_offset[i] = 'b0;
                  vd_valid[i]  = 1'b1;
                end
                VIOTA,
                VID: begin
                  vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vd_valid[i]  = 1'b1;
                end
              endcase
            end
          endcase
        end

        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* 指令
          case(inst_funct6)
            `ifdef ZVFBFWMA_ON
            VFWMACCBF16,
            `endif
            VFADD,  
            VFSUB,      
            VFRSUB,     
            VFMUL,      
            VFDIV,      
            VFRDIV,     
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB,    
            VFUNARY1,
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VFMERGE_VFMV,
            VFSLIDE1UP,
            VFSLIDE1DOWN: begin
              vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vd_valid[i]  = 1'b1;
            end

            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE,
            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = last_uop_valid[i];
            end

            VFUNARY0: begin
              case(vs1_opcode)
                `ifdef ZVFBFWMA_ON
                VFNCVTBF16: begin
                  vd_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vd_valid[i]  = 1'b1;
                end
                VFWCVTBF16,
                `endif
                VFCVT_XUFV, 
                VFCVT_XFV,
                VFCVT_RTZXUFV,
                VFCVT_RTZXFV,
                VFCVT_FXUV,
                VFCVT_FXV: begin
                  vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vd_valid[i]  = 1'b1;
                end
              endcase              
            end

            VWRFUNARY0: begin
              case(inst_funct3)
                OPFVF: begin
                  vd_offset[i] = 'b0;
                  vd_valid[i]  = 1'b1;
                end
              endcase
            end
          endcase
        end
        `endif        
      endcase
    end
  end

  // 计算实际 vd 寄存器编号 
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VD_OFFSET
      vd_index[i] = inst_vd + {2'b0, vd_offset[i]};
    end
  end

  // 部分 uop 需要把 vd 当作第三个向量源 vs3 读取
  always_comb begin
    // 默认值
    vs3_valid = 'b0;

    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS3_VALID
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VMADC,
            VMSBC,
            VMSEQ,
            VMSNE,
            VMSLEU,
            VMSLE,
            VMSLTU,
            VMSLT,
            VMSGTU,
            VMSGT: begin  //比较类可能需要在尾 uop 读取旧 vd 来合并 mask 结果
              vs3_valid[i] = last_uop_valid[i];
            end
          endcase
        end

        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR : begin  //mask 逻辑在 vstart != 0 时可能需要保留旧 mask 的前缀部分
              vs3_valid[i] = (csr_vstart!='b0);
            end
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VWMACCUS: begin  //乘加类
              vs3_valid[i] = 1'b1;
            end
            VMUNARY0: begin
              case(inst_funct3)
                OPMVV: begin
                  case(vs1_opcode)
                    VMSBF,
                    VMSIF,
                    VMSOF: begin  //直接需要 v0 的指令
                      vs3_valid[i] = (inst_vm==1'b0);
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* 指令
          case(inst_funct6)
          `ifdef ZVFBFWMA_ON
            VFWMACCBF16,
          `endif
            VFMACC,
            VFNMACC,
            VFMSAC,
            VFNMSAC,
            VFMADD,
            VFNMADD,
            VFMSUB,
            VFNMSUB: begin
              vs3_valid[i] = 1'b1;
            end
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              vs3_valid[i] = last_uop_valid[i];
            end
          endcase
        end
        `endif      
      endcase
    end
  end
  
  // 生成 vs1_offset/vs1_valid。
  // vs1 可能是向量源、标量字段、立即数子 opcode 或规约初值；不同指令和首/尾 uop 规则不同。
  always_comb begin
    vs1_offset = 'b0; 
    vs1_valid  = 'b0;
      
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS1_OFFSET
      case(inst_funct3)
        OPIVV: begin
          case(inst_funct6)
            VADD,
            VSUB,
            VADC,
            VMADC,
            VSBC,
            VMSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VMERGE_VMV,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VRGATHER: begin  //逻辑类
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = 1'b1;   
            end
            
            VNSRL,
            VNSRA,
            VNCLIPU,
            VNCLIP: begin  //窄
              vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs1_valid[i]  = 1'b1;
            end
            
            VWREDSUMU,
            VWREDSUM: begin  //规约类只有首 uop 读取初始累加值 vs1：
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];
            end        
            
            VSLIDEUP_RGATHEREI16: begin
              case({emul_max,emul_vs1})
                {EMUL1,EMUL1},
                {EMUL2,EMUL2},
                {EMUL4,EMUL4},
                {EMUL8,EMUL8}: begin
                  vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vs1_valid[i]  = 1'b1;
                end
                {EMUL2,EMUL1},
                {EMUL4,EMUL2},
                {EMUL8,EMUL4}: begin              
                  vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vs1_valid[i]  = 1'b1;
                end
              endcase
            end
          endcase
        end

        OPMVV: begin
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VWMUL,
            VWMULU,
            VWMULSU,
            VWMACCU,
            VWMACC,
            VWMACCSU: begin
              vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs1_valid[i]  = 1'b1;        
            end

            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = 1'b1;        
            end

            // 规约类
            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];
            end

            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = 1'b1;
            end

            VCOMPRESS: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];        
            end
          endcase
        end
        
        `ifdef ZVE32F_ON
        OPFVV: begin
          case(inst_funct6)
            `ifdef ZVFBFWMA_ON
            VFWMACCBF16: begin
              vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs1_valid[i]  = 1'b1;        
            end

            `endif
            VFADD,          
            VFSUB,      
            VFMUL,      
            VFDIV,      
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB,    
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = 1'b1;        
            end

            VFMERGE_VFMV: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = !inst_vm;        
            end

            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];
            end
          endcase
        end
        `endif
      endcase
    end
  end

  // 计算实际 vs1 寄存器编号；若该指令把 vs1 字段当 opcode/立即数，valid 会在上面关闭。
  always_comb begin 
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS1
      vs1[i] = inst_vs1 + {2'b0, vs1_offset[i]}; 
    end
  end

  // 生成 vs2_offset/vs2_valid。
  // vs2 通常是主向量源；对于 mask、merge、compress、slide 等指令，是否读取 vs2 会受 vm/首尾 uop 影响。
  always_comb begin
    // 默认值
    vs2_offset = 'b0; 
    vs2_valid = 'b0; 
      
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS2_OFFSET
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VADD,
            VSUB,
            VRSUB,
            VADC,
            VSBC,
            VMADC,
            VMSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VNSRL,
            VNSRA,
            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMSGTU,
            VMSGT,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VNCLIPU,
            VNCLIP,
            VWREDSUMU,
            VWREDSUM: begin  //普通同宽指令
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;
            end

            VMERGE_VMV: begin  //merge 指令在 vm=0 时不读取 vs2
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = !inst_vm;
            end
          endcase
        end

        valid_opm: begin
          // OPM* 
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWMUL,
            VWMULU,
            VWMULSU,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VWMACCUS: begin  //宽化类
              vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs2_valid[i]  = 1'b1;        
            end
            
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB,
            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR,
            VWRXUNARY0:begin  //同宽类
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;        
            end

            VXUNARY0: begin
              case(inst_funct3)
                OPMVV: begin
                  case({emul_max,emul_vs2})
                    {EMUL1,EMUL1},
                    {EMUL2,EMUL1},
                    {EMUL4,EMUL1}: begin
                      vs2_offset[i] = 'b0;
                      vs2_valid[i]  = 1'b1;
                    end
                    {EMUL4,EMUL2},
                    {EMUL8,EMUL4}: begin
                      vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                      vs2_valid[i]  = 1'b1;
                    end
                    {EMUL8,EMUL2}: begin
                      vs2_offset[i] = {2'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:2]};
                      vs2_valid[i]  = 1'b1;
                    end
                  endcase
                end
              endcase
            end

            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin  //mask 通常作为单个 mask 寄存器处理
              vs2_offset[i] = 'b0;
              vs2_valid[i]  = 1'b1;   
            end

            VMUNARY0: begin
              case(inst_funct3)
                OPMVV: begin
                  case(vs1_opcode)
                    VMSBF,
                    VMSIF,
                    VMSOF,
                    VIOTA: begin
                      vs2_offset[i] = 'b0;
                      vs2_valid[i]  = 1'b1;   
                    end
                  endcase
                end
              endcase
            end
          endcase
        end

        `ifdef ZVE32F_ON
        valid_opf: begin
          case(inst_funct6)
            `ifdef ZVFBFWMA_ON
            VFWMACCBF16: begin
              vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs2_valid[i]  = 1'b1;        
            end
            `endif

            VFADD,          
            VFSUB,      
            VFRSUB,     
            VFMUL,      
            VFDIV,      
            VFRDIV,     
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB,    
            VFUNARY1,
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE,
            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;        
            end

            VFMERGE_VFMV: begin
              if(!inst_vm) begin
                vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                vs2_valid[i]  = 1'b1; 
              end
            end

            VFUNARY0: begin
              case(vs1_opcode)
                `ifdef ZVFBFWMA_ON
                VFWCVTBF16: begin
                  vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vs2_valid[i]  = 1'b1;        
                end

                VFNCVTBF16,
                `endif
                VFCVT_XUFV,
                VFCVT_XFV,  
                VFCVT_RTZXUFV,
                VFCVT_RTZXFV,
                VFCVT_FXUV,
                VFCVT_FXV: begin
                  vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vs2_valid[i]  = 1'b1;        
                end
              endcase
            end

            VWRFUNARY0: begin
              if(inst_vm) begin
                vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                vs2_valid[i]  = 1'b1; 
              end
            end
          endcase
        end
        `endif
      endcase
    end
  end

  // 计算实际 vs2 寄存器编号。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS2
      vs2_index[i] = inst_vs2 + {2'b0, vs2_offset[i]}; 
    end
  end

  // 生成标量目的寄存器 valid。
  // xd_valid 表示写整数标量 rd；fd_valid 表示写浮点标量 fd。二者都会让 dst_index 使用 inst_vd/rd 字段。
  always_comb begin
    // 默认值
    xd_valid = 'b0;
  `ifdef ZVE32F_ON
    fd_valid = 'b0;
  `endif

    case(inst_funct3)
      OPMVV: begin
        case(inst_funct6)
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST,
              VMV_X_S: begin  //这些是向量结果转整数标量
                xd_valid = 1'b1;
              end
            endcase
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          VWRFUNARY0: begin
            fd_valid = 1'b1;
          end
        endcase
      end
      `endif
    endcase
  end

  // 生成 rs1_data/rs1_data_valid。
  // OPIVX/OPMVX/OPFVF 使用前端提供的 rs1；OPIVI 使用 sign/zero extend 后的立即数。
  always_comb begin
    // 默认值
    rs1_data       = 'b0;
    rs1_data_valid = 'b0;
      
    case(inst_funct3)
      OPIVX: begin
        case(inst_funct6)
          VADD,
          VSUB,
          VRSUB,
          VADC,
          VMADC,
          VSBC,
          VMSBC,
          VAND,
          VOR,
          VXOR,
          VMSEQ,
          VMSNE,
          VMSLTU,
          VMSLT,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VMERGE_VMV,
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSLL,
          VSRL,
          VSRA,
          VNSRL,
          VNSRA,
          VSSRL,
          VSSRA,
          VNCLIPU,
          VNCLIP,
          VSLIDEUP_RGATHEREI16,
          VSLIDEDOWN,
          VRGATHER: begin  //这些使用整数标量 rs1
            rs1_data       = rs1;
            rs1_data_valid = 1'b1;
          end
        endcase
      end

      OPIVI: begin
        case(inst_funct6)
          VADD,
          VRSUB,
          VADC,
          VMADC,
          VAND,
          VOR,
          VXOR,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT,
          VMERGE_VMV,
          VSADDU,
          VSADD: begin  //立即数指令需要扩展 inst_imm
            rs1_data       = {{(`XLEN-`IMM_WIDTH){inst_imm[`IMM_WIDTH-1]}},inst_imm[`IMM_WIDTH-1:0]};
            rs1_data_valid = 1'b1;
          end

          VSLL,
          VSRL,
          VSRA,
          VNSRL,
          VNSRA,
          VSSRL,
          VSSRA,
          VNCLIPU,
          VNCLIP,
          VSLIDEUP_RGATHEREI16,
          VSLIDEDOWN,
          VRGATHER: begin
            rs1_data       = {{(`XLEN-`IMM_WIDTH){1'b0}},inst_imm[`IMM_WIDTH-1:0]};
            rs1_data_valid = 1'b1;
          end
        endcase
      end
      
      OPMVX: begin
        case(inst_funct6)
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W,
          VMUL,
          VMULH,
          VMULHU,
          VMULHSU,
          VDIVU,
          VDIV,
          VREMU,
          VREM,
          VWMUL,
          VWMULU,
          VWMULSU,
          VMACC,
          VNMSAC,
          VMADD,
          VNMSUB,
          VWMACCU,
          VWMACC,
          VWMACCSU,
          VWMACCUS,
          VAADDU,
          VAADD,
          VASUBU,
          VASUB,
          VWRXUNARY0,
          VSLIDE1UP,
          VSLIDE1DOWN: begin  //这些使用整数标量 rs1
            rs1_data       = rs1;
            rs1_data_valid = 1'b1;
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVF: begin
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16,
          `endif
          VFADD,          
          VFSUB,      
          VFRSUB,     
          VFMUL,      
          VFDIV,      
          VFRDIV,     
          VFMACC,     
          VFNMACC,    
          VFMSAC,     
          VFNMSAC,    
          VFMADD,     
          VFNMADD,    
          VFMSUB,     
          VFNMSUB,    
          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX,
          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE,
          VFMERGE_VFMV,
          VFSLIDE1UP,
          VFSLIDE1DOWN: begin  //这些使用整数标量
            rs1_data       = rs1;
            rs1_data_valid = 1'b1;
          end

          VWRFUNARY0: begin  //这些使用整数标量
            rs1_data       = rs1;
            rs1_data_valid = inst_vm;
          end
        endcase
      end
      `endif      
    endcase
  end

  // 输出给后端的 uop_index，去掉比较用的额外最高位。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: ASSIGN_UOP_INDEX
      uop_index[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0];
    end
  end
  
  // ARI 指令没有 segment 访存语义，seg_field_index 固定为 0。
  // 这个字段更多是为了和 LSU uop 格式统一。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: ASSIGN_SEG_INDEX
      seg_field_index[i] = 'b0;
    end
  end

  // pshrob_valid 决定该 uop 是否进入 ROB/完成队列。
  // 比较和规约会展开多个内部 uop，但只有最后一个 uop 产生架构可见结果，所以只让尾 uop 入 ROB。
  // 普通 ALU/MUL/MAC/FMA 等 uop：
  //   每个 uop 都产生一个可写回/可完成结果，所以都进 ROB。
  // 比较/规约类：
  //   可能有多个内部 uop，但只有最后一个 uop 产生架构可见最终结果，
  //   所以只有 last uop 进 ROB。
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: PSHROB_VLD
      case(uop_exe_unit)
      `ifdef ZVE32F_ON
        FCMP,
        FRDT,
      `endif
        CMP,
        RDT: pshrob_valid[i] = last_uop_valid[i];
        default: pshrob_valid[i] = 1'b1;
      endcase
    end
  end

  // 组装 UOP_QUEUE_t 输出。
  // 这里把 DE1/DE2 计算出的所有控制字段集中打包，后续 dispatch/执行单元不再回看 LCMD。
  generate
    for(j=0;j<`NUM_DE_UOP;j++) begin: ASSIGN_RES
    `ifdef TB_SUPPORT
      assign uop[j].uop_pc                = lcmd.cmd.inst_pc;
    `endif  
      assign uop[j].uop_funct3            = inst_funct3;
      assign uop[j].uop_funct6.ari_funct6 = inst_funct6;
      assign uop[j].uop_exe_unit          = uop_exe_unit; 
      assign uop[j].uop_class             = uop_class[j];   
      assign uop[j].vector_csr            = vector_csr[j];  
      assign uop[j].vs_evl                = lcmd.evl;            
      assign uop[j].ignore_vma            = ignore_vma;
      assign uop[j].ignore_vta            = ignore_vta;
      assign uop[j].force_vma_agnostic    = lcmd.force_vma_agnostic;
      assign uop[j].force_vta_agnostic    = lcmd.force_vta_agnostic;
      assign uop[j].vm                    = inst_vm;                
      assign uop[j].v0_valid              = v0_valid[j];          
      assign uop[j].dst_index             = xd_valid
    `ifdef ZVE32F_ON
                                            || fd_valid 
    `endif
                                            ? inst_vd : vd_index[j];          
      assign uop[j].vd_eew                = lcmd.eew_vd;  
      assign uop[j].vd_valid              = vd_valid[j];
      assign uop[j].vs3_valid             = vs3_valid[j];         
      assign uop[j].xd_valid              = xd_valid; 
    `ifdef ZVE32F_ON
      assign uop[j].fd_valid              = fd_valid; 
    `endif
      assign uop[j].vs1                   = vs1[j];              
      assign uop[j].vs1_eew               = lcmd.eew_vs1;           
      assign uop[j].vs1_valid             = vs1_valid[j];
      assign uop[j].vs2_index 	          = vs2_index[j]; 	       
      assign uop[j].vs2_eew               = lcmd.eew_vs2;
      assign uop[j].vs2_valid             = vs2_valid[j];
      assign uop[j].rs1_data              = rs1_data;           
      assign uop[j].rs1_data_valid        = rs1_data_valid;    
      assign uop[j].uop_index             = uop_index[j];         
      assign uop[j].first_uop_valid       = first_uop_valid[j];   
      assign uop[j].last_uop_valid        = last_uop_valid[j];    
      assign uop[j].seg_field_index       = seg_field_index[j];   
      assign uop[j].pshrob_valid          = pshrob_valid[j];   
      assign uop[j].pshlsu_valid          = 'b0;   
    end
  endgenerate


endmodule
