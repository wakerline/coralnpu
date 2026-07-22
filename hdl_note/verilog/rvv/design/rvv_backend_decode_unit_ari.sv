`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_decode_unit_ari` -> DE1 算术/整数/浮点向量指令解码单元。
// - 接口与数据流：
//   * 输入：来自 CQ 的 `RVVCmd`，其中包含原始 bits、标量 rs1 数据和 RVV 架构状态 vl/vtype。
//   * 处理：解析 OPIV*/OPMV*/OPF* 指令，计算每个源/目的寄存器组的 EMUL 和 EEW。
//   * 检查：完成寄存器组对齐、vd/vs/v0 重叠、vstart/vl、浮点 frm 等合法性检查。
//   * 输出：`LCMD_t`，作为 DE2 的输入；若 `inst_encoding_correct=0`，该指令被直接丢弃。
// - 调用关系：上层 rvv_backend_decode_unit；无下层实例。
// - 端口摘要：输入 inst_valid, inst；输出 lcmd_valid, lcmd。
// - define/参数阅读重点：
//   * `FUNCT3_WIDTH`：3。
//   * `FUNCT6_WIDTH`：6。
//   * `IMM_WIDTH`：5。
//   * `NREG_WIDTH`：3。
//   * `REGFILE_INDEX_WIDTH`：5；寄存器编号宽度。
//   * `UOP_INDEX_WIDTH`：5。
//   * `UOP_INDEX_WIDTH_ALU`：$clog2(`UOP_NUM_ALU)=3。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VLENH`：`VLEN/16；依赖 VLEN。
//   * `VLENW`：`VLEN/32；依赖 VLEN。
//   * `VL_WIDTH`：$clog2(`VLEN)+1；依赖 VLEN。
//   * `VM_WIDTH`：1。
//   * `VSTART_WIDTH`：$clog2(`VLEN)；依赖 VLEN。
//   * `XLEN`：32；标量整数宽度。
//   * `rvv_forbid`：strong(seq) 取反的 assert property 宏，来自 rvv_backend_sva.svh。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
//   * 断言宏来自 `rvv_backend_sva.svh`，只有相关编译开关打开时才会参与仿真检查。
// - 阅读建议：
//   * 先看 `rvv_backend.svh` 中 `RVVCmd/LCMD_t/EMUL_e/EEW_e` 的结构体和枚举定义。
//   * 再按 “字段拆分 -> 指令类别 -> EMUL -> EEW -> 合法性检查 -> LCMD 输出” 的顺序阅读。
//   * `EMUL_NONE/EEW_NONE` 表示该指令组合在当前 SEW/LMUL 下不被支持，会导致 lcmd_valid=0。
// 详细中文注释（自动梳理）END
// 指令行为速查表（DE1 ARI decode）BEGIN
// - 说明：本表描述本文件识别到的算术/逻辑/浮点向量指令的功能语义；真正是否合法、
//   使用哪个 EMUL/EEW、是否需要拆成多个 uop，仍由后续 case 表和合法性检查决定。
// - 操作数形态：OPIVV/OPMVV 表示向量-向量；OPIVX/OPMVX 表示向量-标量；
//   OPIVI 表示向量-立即数；OPFVV/OPFVF 表示浮点向量-向量/向量-标量。
// - VADD/VSUB/VRSUB：逐元素整数加、减、反向减；VRSUB 为 rs1/imm - vs2。
// - VADC/VSBC/VMADC/VMSBC：带进位/借位的加减；VMADC/VMSBC 写 mask 形式的进位/借位结果。
// - VAND/VOR/VXOR：逐元素按位与、或、异或。
// - VSLL/VSRL/VSRA：逐元素左移、逻辑右移、算术右移，移位量来自 vs1/rs1/imm。
// - VMINU/VMIN/VMAXU/VMAX：逐元素无符号/有符号最小值、最大值。
// - VMSEQ/VMSNE/VMSLTU/VMSLT/VMSLEU/VMSLE/VMSGTU/VMSGT：整数比较，结果写入 mask 寄存器 vd。
// - VSADDU/VSADD/VSSUBU/VSSUB：无符号/有符号饱和加减。
// - VAADDU/VAADD/VASUBU/VASUB：无符号/有符号平均加减，结果按 vxrm 舍入。
// - VSSRL/VSSRA：带舍入的逻辑/算术右移，常用于定点缩放。
// - VNSRL/VNSRA：窄化逻辑/算术右移，宽源操作数产生较窄目的元素。
// - VNCLIPU/VNCLIP：无符号/有符号窄化裁剪，右移后按饱和规则写窄目的。
// - VWADDU/VWADD/VWSUBU/VWSUB：宽化加减，SEW 宽源元素生成 2*SEW 宽目的元素。
// - VWADDU_W/VWADD_W/VWSUBU_W/VWSUB_W：宽目的累加/减，2*SEW 的累加源与 SEW 源参与运算。
// - VMUL/VMULH/VMULHU/VMULHSU：整数乘法低位、高位；后缀区分有符号/无符号组合。
// - VDIVU/VDIV/VREMU/VREM：无符号/有符号整数除法和余数。
// - VWMULU/VWMUL/VWMULSU：宽化乘法，SEW 源生成 2*SEW 结果。
// - VMACC/VNMSAC/VMADD/VNMSUB：整数乘加/负乘加类，vd 同时作为累加或加数输入。
// - VWMACCU/VWMACC/VWMACCSU/VWMACCUS：宽化整数乘加，覆盖无符号、有符号和混合符号组合。
// - VREDSUM/VREDMAXU/VREDMAX/VREDMINU/VREDMIN/VREDAND/VREDOR/VREDXOR：整数规约，
//   将有效元素规约到 vd 的起始元素，其他元素由后端按 tail/mask 策略处理。
// - VWREDSUMU/VWREDSUM：宽化求和规约，窄源元素累加到宽目的。
// - VMAND/VMNAND/VMANDN/VMXOR/VMOR/VMNOR/VMORN/VMXNOR：mask 寄存器之间的位逻辑操作。
// - VMSBF/VMSIF/VMSOF：根据源 mask 生成 before-first、including-first、only-first mask。
// - VIOTA：对 mask 中为 1 的元素做前缀计数，生成索引向量。
// - VID：生成元素序号向量，元素值等于 lane/index。
// - VCOMPRESS：按 mask 将 vs2 中有效元素压缩写入 vd 的低索引位置。
// - VSLIDEUP_RGATHEREI16/VRGATHEREI16：编码族复用；OPIVX/OPIVI 下是 vslideup，
//   OPIVV 下是 vrgatherei16，以 16 bit 索引元素执行 gather。
// - VSLIDEDOWN/VSLIDE1UP/VSLIDE1DOWN：向量元素滑动；slide1 类额外从标量端插入/取出一个元素。
// - VRGATHER：按索引向量/标量/立即数从源向量中取元素，形成重排结果。
// - VCPOP/VFIRST/VMV_X_S：mask 置位计数、首个置位元素索引、向量首元素送整数标量寄存器。
// - VMV_S_X：整数标量写入 vd[0]，其余元素按 vtype 策略处理。
// - VMERGE_VMV：编码复用；vm=0 时执行 vmerge，vm=1 时执行 vmv.v.* 广播/移动。
// - VSMUL_VMVNRR：编码复用；可表示定点饱和乘法 vsmul，也可表示整组寄存器拷贝 vmv<nr>r.v。
// - VXUNARY0/VMUNARY0：整数特殊子编码族；本文件进一步按 vs1/vs2 子 opcode 识别具体操作。
// - VZEXT_VF2/VSEXT_VF2/VZEXT_VF4/VSEXT_VF4：零扩展/符号扩展，将较窄元素扩展到当前 SEW。
// - VFADD/VFSUB/VFRSUB：逐元素浮点加、减、反向减。
// - VFMUL/VFDIV/VFRDIV：逐元素浮点乘、除、反向除。
// - VFMACC/VFNMACC/VFMSAC/VFNMSAC/VFMADD/VFNMADD/VFMSUB/VFNMSUB：浮点 fused multiply-add/sub
//   及取负变体，vd 作为累加输入或加数输入。
// - VFMIN/VFMAX：逐元素浮点最小值/最大值。
// - VFSGNJ/VFSGNJN/VFSGNJX：浮点符号注入、符号取反注入、符号异或注入。
// - VMFEQ/VMFNE/VMFLT/VMFLE/VMFGT/VMFGE：浮点比较，结果写 mask 寄存器。
// - VFREDOSUM/VFREDUSUM/VFREDMAX/VFREDMIN：浮点有序求和、无序求和、最大值、最小值规约。
// - VFSQRT/VFRSQRT7/VFREC7/VFCLASS：浮点平方根、倒平方根近似、倒数近似、浮点类别分类。
// - VFCVT_XUFV/VFCVT_XFV/VFCVT_RTZXUFV/VFCVT_RTZXFV：浮点转无符号/有符号整数，
//   RTZ 版本固定向零舍入。
// - VFCVT_FXUV/VFCVT_FXV：无符号/有符号整数转浮点。
// - VFMERGE_VFMV：编码复用；vm=0 时浮点 merge，vm=1 时浮点标量广播/移动。
// - VFMV_F_S/VFMV_S_F：向量首浮点元素送标量浮点端，或标量浮点值写入 vd[0]。
// - VFSLIDE1UP/VFSLIDE1DOWN：浮点 slide1，使用浮点标量端插入或取出一个元素。
// - VFUNARY0/VFUNARY1/VWRXUNARY0/VWRFUNARY0：浮点/宽化浮点特殊子编码族，
//   由 vs1 子 opcode 决定转换、sqrt、class 等具体行为。
// - VFNCVTBF16/VFWCVTBF16/VFWMACCBF16：BF16 窄化转换、宽化转换、宽化乘加，
//   只有打开 `ZVFBFWMA_ON` 时才参与解码。
// 指令行为速查表（DE1 ARI decode）END

module rvv_backend_decode_unit_ari
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd
);
//
// interface signals
//
  // inst_valid 表示当前 RVVCmd 有效；本模块只处理 opcode=RVV 的算术/逻辑/浮点类指令。
  // LOAD/STORE 已经在上一级 rvv_backend_decode_unit 中分流给 LSU decode。
  input   logic                       inst_valid;
  input   RVVCmd                      inst;
  
  // lcmd_valid 是 DE1 合法解码结果 valid。非法编码不会进入 LCQ/DE2。
  output  logic                       lcmd_valid;
  output  LCMD_t                      lcmd;

//
// internal signals
//
  // 从 RVVCmd.bits 中拆出 RVV 指令字段。
  // RVVCmd.bits 对应原始指令 [31:7]，所以这里的 bit 位置相对原始指令右移 7 位。
  logic   [`FUNCT6_WIDTH-1:0]         inst_funct6;      // inst original encoding[31:26]    
  logic   [`VM_WIDTH-1:0]             inst_vm;          // inst original encoding[25]      
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vs2;         // inst original encoding[24:20]
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vs1;         // inst original encoding[19:15]
  logic   [`IMM_WIDTH-1:0]            inst_imm;         // inst original encoding[19:15]
  logic   [`FUNCT3_WIDTH-1:0]         inst_funct3;      // inst original encoding[14:12]
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vd;          // inst original encoding[11:7]
  logic   [`NREG_WIDTH-1:0]           inst_nr;          // inst original encoding[17:15]
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vs1_opcode;       // 部分 unary/特殊指令复用 vs1 字段作为子 opcode。
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vs2_opcode;       // 部分 move/浮点特殊指令复用 vs2 字段作为子 opcode。
   
  logic   [`XLEN-1:0]                 rs1;              // 前端已经读出的标量 rs1 或浮点标量操作数。
  logic   [`VSTART_WIDTH-1:0]         csr_vstart;
  logic   [`VSTART_WIDTH:0]           evstart;
  logic   [`VL_WIDTH-1:0]             csr_vl;
  logic   [`VL_WIDTH-1:0]             evl;
  RVVSEW                              csr_sew;
  RVVLMUL                             csr_lmul;
  // EMUL 描述每个操作数实际占用的向量寄存器组大小。
  // 例如 EMUL4 表示以寄存器编号低 2 bit 对齐的一组 4 个寄存器。
  EMUL_e                              emul_vd;          
  EMUL_e                              emul_vs2;          
  EMUL_e                              emul_vs1;          
  EMUL_e                              emul_max; 
  // EEW 描述每个操作数的有效元素宽度。EEW1 常用于 mask 结果/输入。
  EEW_e                               eew_vd;          
  EEW_e                               eew_vs2;          
  EEW_e                               eew_vs1;
  EEW_e                               eew_max;          
  // 按 funct3 粗分类：OPI=整数/逻辑类，OPM=乘除/规约/mask/特殊类，OPF=浮点类。
  logic                               valid_opi;
  logic                               valid_opm;
`ifdef ZVE32F_ON
  logic                               valid_opf;
`endif
  logic                               inst_encoding_correct;        // check_special & check_common & inst_valid。
  // check_special 针对具体指令的约束；check_common 针对所有指令共用约束。
  logic                               check_special;
  logic                               check_vd_overlap_v0;
  logic                               check_vd_part_overlap_vs2;
  logic                               check_vd_part_overlap_vs1;
  logic                               check_vd_overlap_vs2;
  logic                               check_vd_overlap_vs1;
  logic                               check_vs2_part_overlap_vd_2_1;
  logic                               check_vs1_part_overlap_vd_2_1;
  logic                               check_vs2_part_overlap_vd_4_1;
  logic                               check_common;
  logic                               check_vd_align;
  logic                               check_vs2_align;
  logic                               check_vs1_align;
  logic                               check_sew;
  logic                               check_lmul;
  logic                               check_vl_not_0;
  logic                               check_vstart_sle_vl;
  logic                               check_frm;
  // uop_vstart/uop_index_max 指示 DE2 从哪个 uop 开始、最多展开到哪个 uop。
  logic   [`UOP_INDEX_WIDTH-1:0]      uop_vstart;         
  logic   [`UOP_INDEX_WIDTH-1:0]      uop_index_max;         
  FUNCT6_u                            funct6_ari;

  // 某些寄存器重叠且 EEW 不同时，规范要求 mask/tail 采用 agnostic 处理。
  logic                               force_vma_agnostic; 
  logic                               force_vta_agnostic; 
   
  // use for for-loop 
  genvar                              j;

  //
  // decode
  //
  // 1. 拆 RVV 指令字段和当前架构状态。
  //    所有字段在 inst_valid=0 时清零，避免无效周期产生误判。
  assign inst_funct6    = inst_valid ? inst.bits[24:19] : 'b0;
  assign inst_vm        = inst_valid ? inst.bits[18] : 'b0;
  assign inst_vs2       = inst_valid ? inst.bits[17:13] : 'b0;
  assign vs2_opcode     = inst_valid ? inst.bits[17:13] : 'b0;
  assign inst_vs1       = inst_valid ? inst.bits[12:8] : 'b0;
  assign vs1_opcode     = inst_valid ? inst.bits[12:8] : 'b0;
  assign inst_imm       = inst_valid ? inst.bits[12:8] : 'b0;
  assign inst_funct3    = inst_valid ? inst.bits[7:5] : 'b0;
  assign inst_vd        = inst_valid ? inst.bits[4:0] : 'b0;
  assign inst_nr        = inst_valid ? inst_vs1[`NREG_WIDTH-1:0] : 'b0;  // for OPIVI instructions 3bit
  assign rs1            = inst_valid ? inst.rs1 : 'b0;                   // 前端读出的整数/浮点标量操作数
  assign csr_vstart     = inst_valid ? inst.arch_state.vstart : 'b0;
  assign csr_vl         = inst_valid ? inst.arch_state.vl : 'b0;
  assign csr_sew        = inst_valid ? inst.arch_state.sew : SEW8;
  assign csr_lmul       = inst_valid ? inst.arch_state.lmul : LMUL1;  

  // 2. 根据 funct3 判断指令大类。后续 EMUL/EEW 表都按 valid_opi/valid_opm/valid_opf 分支。
  always_comb begin
    // 默认无有效类别，只有 inst_valid 且 funct3 命中时才置位。
    valid_opi = 'b0;
    valid_opm = 'b0;
    `ifdef ZVE32F_ON
    valid_opf = 'b0;
    `endif    

    case(inst_funct3)
      OPIVV,                           //整数/逻辑，向量-向量
      OPIVX,                           //整数/逻辑，向量-标量
      OPIVI: valid_opi = inst_valid;   //整数/逻辑，向量-立即数
      OPMVV,                           //乘除/规约/mask/特殊，向量-向量
      OPMVX: valid_opm = inst_valid;   //乘除/规约/mask/特殊，向量-标量
    `ifdef ZVE32F_ON
      OPFVV,                           //浮点，向量-向量
      OPFVF: valid_opf = inst_valid;   //浮点，向量-标量
    `endif    
    endcase
  end 

  // 3. 计算 EMUL。
  //    EMUL 决定 vd/vs1/vs2 寄存器组大小，也决定后续：
  //      - 寄存器编号对齐检查；
  //      - 寄存器组重叠检查；
  //      - DE2 需要拆成多少个 uop。
  //    如果某个指令组合没有给 emul_max 赋有效值，后续 check_lmul 会失败。
  always_comb begin
    // initial
    emul_vd  = EMUL_NONE;  // EMUL_NONE 表示该指令组合在当前 SEW/LMUL 下不被支持，会导致 lcmd_valid=0。
    emul_vs2 = EMUL_NONE;
    emul_vs1 = EMUL_NONE;
    emul_max = EMUL_NONE;
    
    case(inst_funct3)
      OPIVV: begin
        // OPI* instruction：OPIVV/OPIVX/OPIVI 的整数/逻辑/移位/比较类。
        case(inst_funct6)
          VADD,
          VADC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VRGATHER,
          VSUB,
          VSBC,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR: begin  //普通同宽整数指令
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin  //不支持 LMUL1_4/LMUL1_2 的指令组合
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // 比较/带 carry 输出到 mask register，目的寄存器 vd 的 EEW/EMUL 等效为 mask。
          // 这些指令结果是 mask，目的 vd 等效为 mask 寄存器,所以为emul_vd = EMUL1，emul_vd = EMUL1
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSLTU,
          VMSLT: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;  //mask寄存器
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // narrowing instructions：源 vs2 为更宽元素，目的 vd 为较窄元素。
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP:begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;  
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL4;  //emul_vs2 通常是 emul_vd 的 2 倍
                emul_max    = EMUL8;
              end
            endcase 
          end
          
          // VMERGE/VMV 编码复用
          // vm=0：vmerge，需要 vs2
          // vm=1：vmv，要求 vs2=v0, vm=1
          VMERGE_VMV: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          // widening reduction：vd=EMUL1，vs2=EMUL1/2/4/8，vs1=EMUL1
          // vd = vs2规约 + vs1
          VWREDSUMU,
          VWREDSUM: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;  
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          //OPIVX/OPIVI 下可能是 vslideup
          //OPIVV 下是 vrgatherei16
          VSLIDEUP_RGATHEREI16: begin        
            // VRGATHEREI16
            case(csr_lmul)
              LMUL1_4: begin
                case(csr_sew)
                  SEW8,
                  SEW16: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_vs1    = EMUL1;
                    emul_max    = EMUL1;
                  end
                endcase
              end
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                case(csr_sew)
                  SEW8: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_vs1    = EMUL2;  //index = sew16，所以vs1 需要 rd/vs2 2倍寄存器
                    emul_max    = EMUL2;
                  end
                  SEW16,
                  SEW32: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_vs1    = EMUL1;
                    emul_max    = EMUL1;
                  end
                endcase
              end
              LMUL2: begin                  
                case(csr_sew)
                  SEW8: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_vs1    = EMUL4;  //index = sew16，所以vs1 需要 rd/vs2 2倍寄存器
                    emul_max    = EMUL4;
                  end
                  SEW16: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_vs1    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  SEW32: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_vs1    = EMUL1;  //index = sew16，所以vs1 需要 rd/vs2 1/2倍寄存器
                    emul_max    = EMUL2;
                  end
                endcase
              end
              LMUL4: begin
                case(csr_sew)
                  SEW8: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_vs1    = EMUL8;  //index = sew16，所以vs1 需要 rd/vs2 2倍寄存器
                    emul_max    = EMUL8;
                  end
                  SEW16: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_vs1    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  SEW32: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_vs1    = EMUL2;  //index = sew16，所以vs1 需要 rd/vs2 1/2倍寄存器
                    emul_max    = EMUL4;
                  end
                endcase
              end
              LMUL8: begin
                case(csr_sew)
                  SEW16: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_vs1    = EMUL8;
                    emul_max    = EMUL8;
                  end
                  SEW32: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_vs1    = EMUL4;  //index = sew16，所以vs1 需要 rd/vs2 1/2倍寄存器
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end
        endcase
      end
      
      //OPIVX 是整数/逻辑向量-标量形式：vd = vs2 op rs1
      //所以它一般没有 emul_vs1，因为 vs1 字段代表标量寄存器编号，标量值已经由前端读成 rs1。
      OPIVX: begin  
        // OPI* instruction
        case(inst_funct6)
          VADD,
          VADC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VRGATHER,
          VSUB,
          VSBC,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSSUBU,
          VSSUB,
          VRSUB,
          VSLIDEDOWN,
          VSMUL_VMVNRR,
          VSLIDEUP_RGATHEREI16: begin        
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // destination vector register is mask register
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSLTU,
          VMSLT,
          VMSGTU,
          VMSGT: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;  
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin 
                emul_vd     = EMUL1;  //目标寄存器是 mask 寄存器，所以 emul_vd=EMUL1
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // narrowing instructions
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP:begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL4;  //目标寄存器是 vd，源寄存器是 vs2，vs2 是更宽的元素，所以 emul_vs2=2*emul_vd
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VMERGE_VMV: begin  // vm=0：vmerge，需要 vs2；vm=1：vmv，可能不需要 vs2
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
        endcase
      end
      
      //OPIVI 是整数/逻辑向量-立即数形式：vd = vs2 op imm
      //它和 OPIVX 很像，只不过第二操作数来自 inst_imm。
      //不需要 vs1 向量源。
      OPIVI: begin
        // OPI* instruction
        case(inst_funct6)
          VADD,
          VADC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VRGATHER,
          VRSUB,
          VSLIDEDOWN,
          VSLIDEUP_RGATHEREI16: begin        
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // destination vector register is mask register
          VMADC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // narrowing instructions
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP:begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          VMERGE_VMV: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VSMUL_VMVNRR: begin
            // vmv<nr>r.v instruction
            //在 OPIVI 下它可表示 vmv<nr>r.v 整组寄存器搬移。
            //整组 vector register move。
            case(inst_nr)
              NREG1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              NREG2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              NREG4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              NREG8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
        endcase
      end

      //OPMVV 覆盖乘除、规约、mask、特殊整数指令。
      OPMVV: begin
        // OPM* instruction：乘除、规约、mask、特殊 move/slide 等。
        case(inst_funct6)
          // widening instructions: 2SEW = SEW op SEW，vd 通常是源的 2 倍 EMUL。
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWMUL,
          VWMULU,
          VWMULSU,
          VWMACCU,
          VWMACC,
          VWMACCSU: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          // widening instructions: 2SEW = 2SEW op SEW，vd/vs2 为宽类型，vs1 为窄类型。
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end

          //例如 VZEXT_VF2 表示源元素宽度是目的的一半，所以目的 EMUL 可能大于源 EMUL。
          //零扩展/符号扩展类。
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                case(csr_lmul)
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL8;
                  end
                endcase
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                case(csr_lmul)
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end
 
          // SEW = SEW op SEW
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
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
         
          // reduction
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          // mask 
          VMAND,
          VMNAND,
          VMANDN,
          VMXOR,
          VMOR,
          VMNOR,
          VMORN,
          VMXNOR: begin
            emul_vd     = EMUL1;
            emul_vs2    = EMUL1;
            emul_vs1    = EMUL1;
            emul_max    = EMUL1;
          end

          //这些指令通常把向量/mask 的某个结果写到标量寄存器，因此它们只需要读 vs2，不一定写向量 vd。
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST,
              VMV_X_S: begin
                emul_vs2  = EMUL1;
                emul_max  = EMUL1;
              end
            endcase
          end

          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSIF,
              VMSOF: begin  //是 mask 生成类，因此 vd/vs2 多为 EMUL1。
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              VIOTA: begin  //会从 mask 生成索引向量，所以 vd 按 LMUL，vs2 是 mask，因此 vs2=EMUL1。
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL8;
                  end
                endcase
              end
              VID: begin  //生成元素编号向量，只写 vd。
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

          VCOMPRESS: begin  //VCOMPRESS 按 mask 把 vs2 中有效元素压缩到 vd 低位。
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end
        endcase
      end

      //PMVX 是乘除、规约、特殊整数类的向量-标量版本。
      OPMVX: begin
        // OPM* instruction
        case(inst_funct6)
          // widening instructions: 2SEW = SEW op SEW
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWMUL,
          VWMULU,
          VWMULSU,
          VWMACCU,
          VWMACC,
          VWMACCSU: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          // widening instructions: 2SEW = 2SEW op SEW
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // SEW = SEW op SEW
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
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VWMACCUS: begin  //也是宽化乘加，vd 比 vs2 更宽。
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end
         
          // reduction
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          VWRXUNARY0: begin
            if(vs2_opcode==VMV_S_X) begin
              emul_vd     = EMUL1;
              emul_max    = EMUL1;
            end
          end

          VSLIDE1UP,
          VSLIDE1DOWN: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
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
          VFSGNJX: begin  //普通浮点同宽运算
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT,
              VFRSQRT7,
              VFREC7,
              VFCLASS: begin
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

          VMFEQ,           
          VMFNE,           
          VMFLT,           
          VMFLE: begin  //结果写 mask
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16: begin  //双精度到单精度
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase 
              end
              VFWCVTBF16: begin
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL1: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL4;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL8;
                  end
                endcase 
              end
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin  //转换指令，emul不变
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

          VFREDOSUM,       
          VFREDUSUM,       
          VFREDMAX,       
          VFREDMIN: begin  //规约vd=emul1
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          VWRFUNARY0: begin
            if(vs1_opcode==VFMV_F_S) begin  //转移到标量
              emul_vs2      = EMUL1;
              emul_max      = EMUL1;
            end
          end

          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin  //加宽操作
             case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase           
          end
          `endif
        endcase
      end

      //OPFVF 是浮点向量-浮点标量形式:另一个操作数来自浮点标量 rs1。
      OPFVF: begin
        case(inst_funct6)
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
          VFSLIDE1UP,      
          VFSLIDE1DOWN: begin  
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VMFEQ,           
          VMFNE,           
          VMFLT,           
          VMFLE,           
          VMFGT,           
          VMFGE: begin  //比较指令,emul_vd = EMUL1
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VFMERGE_VFMV: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_max    = EMUL8;
              end
            endcase            
          end

          VWRFUNARY0: begin
            if(vs2_opcode==VFMV_S_F) begin
              emul_vd       = EMUL1;
              emul_max      = EMUL1;
            end
          end

          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
             case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase           
          end
          `endif
        endcase
      end
      `endif
    endcase
  end
 
// 4. 计算 EEW。
//    EEW 是每个操作数实际参与运算的元素宽度：
//      - 普通 SEW op SEW 指令：vd/vs2/vs1 通常等于当前 csr_sew；
//      - mask 指令：vd 或源 mask 的 EEW 为 EEW1；
//      - widening/narrowing 指令：源和目的 EEW 不同；
//      - OPIVX/OPIVI/OPMVX/OPFVF 的标量操作数不占用向量寄存器组，因此不一定设置 eew_vs1。
//    eew_max 用于判断元素组覆盖范围、uop_vstart 和合法性。
// | 指令类型      | EEW 规则                              |
// | --------- | ----------------------------------- |
// | 普通同宽整数/浮点 | `vd/vs2/vs1 = 当前 SEW`               |
// | 比较类       | `vd = EEW1`，源为当前 SEW                |
// | mask 逻辑类  | `vd/vs2/vs1 = EEW1`                 |
// | 宽化类       | `vd = 2*SEW`，源为 SEW                 |
// | 窄化类       | `vd = SEW`，`vs2 = 2*SEW`            |
// | 规约类       | `vd/vs1` 为规约结果宽度，`vs2` 为输入元素宽度      |
// | 浮点转换      | 根据转换方向设置 `vd/vs2` 的 EEW             |
// | BF16      | 只在 `ZVFBFWMA_ON` 下处理 BF16/FP32 宽窄关系 |
  always_comb begin
    // initial
    eew_vd          = EEW_NONE;
    eew_vs2         = EEW_NONE;
    eew_vs1         = EEW_NONE;
    eew_max         = EEW_NONE;

    case(1'b1)
      valid_opi: begin
        // OPI* instruction：整数/逻辑/移位/比较/slide/gather 等。
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
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSLIDEDOWN,
          VRGATHER: begin  //普通同宽整数/浮点: vd/vs2/vs1 = 当前 SEW
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW8;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
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
          VMSGT: begin  //比较类:vd = EEW1，源为当前 SEW
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW8;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin  //窄化类 : vd = SEW，vs2 = 2*SEW
            case(csr_sew) 
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end

          VMERGE_VMV: begin  //合并: vd/vs2/vs1 = 当前 SEW
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                if (inst_vm=='b0)
                  eew_vs2   = EEW8;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                if (inst_vm=='b0)
                  eew_vs2   = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                if (inst_vm=='b0)
                  eew_vs2   = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VWREDSUMU,
          VWREDSUM: begin  //规约类:vd/vs1 为规约结果宽度，vs2 为输入元素宽度
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW8;
                eew_vs1     = EEW16;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                eew_vs1     = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end
          
          VSLIDEUP_RGATHEREI16: begin  //滑动类: vd/vs2 = 当前 SEW, vs1 = 由指令指定
            case(inst_funct3)
              // VRGATHEREI16
              OPIVV: begin
                case(csr_sew)
                  SEW8: begin
                    eew_vd      = EEW8;
                    eew_vs2     = EEW8;
                    eew_vs1     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW16;
                    eew_vs1     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_vs1     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              // VSLIDEUP
              OPIVX,
              OPIVI: begin  
                case(csr_sew)
                  SEW8: begin
                    eew_vd      = EEW8;
                    eew_vs2     = EEW8;
                    eew_max     = EEW8;
                  end
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end
        endcase
      end

      valid_opm: begin
        // OPM* instruction：乘除、规约、mask、compress、特殊 move 等。
        case(inst_funct6)
          // widening instructions: 2SEW = SEW op SEW
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWMUL,
          VWMULU,
          VWMULSU,
          VWMACCU,
          VWMACC,
          VWMACCSU: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW8;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end
         
          // widening instructions: 2SEW = 2SEW op SEW
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end

          // SEW = extend 1/2SEW or 1/4SEW
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW8;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                case(csr_sew)
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW8;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

          // SEW = SEW op SEW
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
          // reduction
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR,
          VSLIDE1UP,
          VSLIDE1DOWN: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW8;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end
          
          VWMACCUS: begin  //宽化类: vd = 2*SEW，源为 SEW
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end

          // mask 
          VMAND,
          VMNAND,
          VMANDN,
          VMXOR,
          VMOR,
          VMNOR,
          VMORN,
          VMXNOR: begin  //mask类: vd/vs2/vs1 = EEW1
            case(csr_sew)
              SEW8,
              SEW16,
              SEW32: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW1;
                eew_vs1     = EEW1;
                eew_max     = EEW1;
              end
            endcase
          end

          VWRXUNARY0: begin  //
            case(inst_funct3)
              OPMVV: begin
                case(vs1_opcode)
                  VCPOP,
                  VFIRST,
                  VMV_X_S: begin
                    case(csr_sew)
                      SEW8: begin
                        eew_vs2     = EEW8;
                        eew_max     = EEW8;
                      end
                      SEW16: begin
                        eew_vs2     = EEW16;
                        eew_max     = EEW16;
                      end
                      SEW32: begin
                        eew_vs2     = EEW32;
                        eew_max     = EEW32;
                      end
                    endcase
                  end
                endcase
              end
              OPMVX: begin
                if(vs2_opcode==VMV_S_X) begin
                  case(csr_sew)
                    SEW8: begin
                      eew_vd      = EEW8;
                      eew_max     = EEW8;
                    end
                    SEW16: begin
                      eew_vd      = EEW16;
                      eew_max     = EEW16;
                    end
                    SEW32: begin
                      eew_vd      = EEW32;
                      eew_max     = EEW32;
                    end
                  endcase
                end
              end
            endcase
          end

          VMUNARY0: begin  //
            case(inst_funct3)
              OPMVV: begin
                case(vs1_opcode)
                  VMSBF,
                  VMSIF,
                  VMSOF: begin  //mask类: vd/vs2/vs1 = EEW1
                    case(csr_sew)
                      SEW8,
                      SEW16,
                      SEW32: begin
                        eew_vd      = EEW1;
                        eew_vs2     = EEW1;
                        eew_max     = EEW1;
                      end
                    endcase
                  end
                  VIOTA:begin  //
                    case(csr_sew)
                      SEW8: begin
                        eew_vd      = EEW8;
                        eew_vs2     = EEW1;
                        eew_max     = EEW8;
                      end
                      SEW16: begin
                        eew_vd      = EEW16;
                        eew_vs2     = EEW1;
                        eew_max     = EEW16;
                      end
                      SEW32: begin
                        eew_vd      = EEW32;
                        eew_vs2     = EEW1;
                        eew_max     = EEW32;
                      end
                    endcase
                  end
                  VID: begin
                    case(csr_sew)
                      SEW8: begin
                        eew_vd      = EEW8;
                        eew_max     = EEW8;
                      end
                      SEW16: begin
                        eew_vd      = EEW16;
                        eew_max     = EEW16;
                      end
                      SEW32: begin
                        eew_vd      = EEW32;
                        eew_max     = EEW32;
                      end
                    endcase
                  end
                endcase
              end
            endcase
          end

          VCOMPRESS: begin  //压缩类: vd = SEW，vs2 = SEW，vs1 = EEW1
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW8;
                eew_vs1     = EEW1;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                eew_vs1     = EEW1;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                eew_vs1     = EEW1;
                eew_max     = EEW32;
              end
            endcase
          end
        endcase
      end

      `ifdef ZVE32F_ON
      valid_opf: begin
        // OPF* instruction：浮点向量运算。当前配置默认未开启 ZVE32F_ON。
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            case(csr_sew)
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                if(inst_funct3==OPFVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
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
          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX,
          VFREDOSUM,
          VFREDUSUM,
          VFREDMAX,
          VFREDMIN,
          VFSLIDE1UP,
          VFSLIDE1DOWN: begin
            case(csr_sew)
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPFVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT,
              VFRSQRT7,
              VFREC7,
              VFCLASS: begin
                case(csr_sew)
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            case(csr_sew)
              SEW32: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW32;
                if(inst_funct3==OPFVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VFMERGE_VFMV: begin
            case(csr_sew)
              SEW32: begin
                eew_vd      = EEW32;
                if(inst_vm=='b0)
                  eew_vs2   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
              VFWCVTBF16: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin
                case(csr_sew)
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

          VWRFUNARY0: begin
            case(csr_sew)
              SEW32: begin
                if(inst_funct3==OPFVV)
                  eew_vs2   = EEW32;
                else
                  eew_vd    = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end
        endcase
      end
      `endif
    endcase
  end

// 5. 指令编码/约束检查。
//
// inst_encoding_correct 是本模块最终的合法性判断：
//   - check_special：每条指令自己的特殊约束，例如 vd 不得和 v0/vs 违规重叠；
//   - check_common ：所有指令共用约束，例如寄存器组对齐、SEW/LMUL 合法、vl/vstart 合法；
//   - inst_valid    ：输入命令有效。
//
// 注意：这些检查失败不会在本模块产生 trap，而是让 lcmd_valid=0，指令不进入后续 LCQ/DE2。
  assign inst_encoding_correct = check_special&check_common&inst_valid;

  // vm=0 表示使用 v0 mask，此时目的寄存器组不能覆盖 v0。
  // check_vd_overlap_v0=1 表示检查通过，也就是 vd 不和 v0 违规重叠。
  assign check_vd_overlap_v0 = (((inst_vm==1'b0)&(inst_vd!='b0)) | (inst_vm==1'b1));

  // 检查 EEW_vd < EEW_vs2 时 vd 是否和 vs2 发生“部分重叠”。
  // 部分重叠比完全相同更危险，因为同一寄存器组会被不同元素宽度解释。
  // check_vd_part_overlap_vs2=1 表示通过。
  always_comb begin
    check_vd_part_overlap_vs2 = 'b0;          
    
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

  // 检查 EEW_vd < EEW_vs1 时 vd 是否和 vs1 发生部分重叠。
  // check_vd_part_overlap_vs1=1 表示通过。
  always_comb begin
    check_vd_part_overlap_vs1     = 'b0;          
    
    case(emul_vs1)
      EMUL1: begin
        check_vd_part_overlap_vs1 = 1'b1;          
      end
      EMUL2: begin
        check_vd_part_overlap_vs1 = !((inst_vd[0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs1[`REGFILE_INDEX_WIDTH-1:1])));
      end
      EMUL4: begin
        check_vd_part_overlap_vs1 = !((inst_vd[1:0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs1[`REGFILE_INDEX_WIDTH-1:2])));
      end
      EMUL8 : begin
        check_vd_part_overlap_vs1 = !((inst_vd[2:0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs1[`REGFILE_INDEX_WIDTH-1:3])));
      end
    endcase
  end

  // 某些指令要求 vd 寄存器组不能和 vs2 寄存器组重叠。
  // 比较时按照较大的 EMUL 粒度比较寄存器组号。
  // check_vd_overlap_vs2=1 表示通过。
  always_comb begin
    if((emul_vd==EMUL8)|(emul_vs2==EMUL8)) 
      check_vd_overlap_vs2 = !(inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3]);
    else if((emul_vd==EMUL4)|(emul_vs2==EMUL4)) 
      check_vd_overlap_vs2 = !(inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2]);
    else if((emul_vd==EMUL2)|(emul_vs2==EMUL2)) 
      check_vd_overlap_vs2 = !(inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1]);
    else if((emul_vd==EMUL1)|(emul_vs2==EMUL1)) 
      check_vd_overlap_vs2 = (inst_vd!=inst_vs2);
    else 
      check_vd_overlap_vs2 = 'b0;
  end
  
  // 某些指令要求 vd 寄存器组不能和 vs1 寄存器组重叠。
  // check_vd_overlap_vs1=1 表示通过。
  always_comb begin
    if((emul_vd==EMUL8)|(emul_vs1==EMUL8)) 
      check_vd_overlap_vs1 = !(inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs1[`REGFILE_INDEX_WIDTH-1:3]);
    else if((emul_vd==EMUL4)|(emul_vs1==EMUL4)) 
      check_vd_overlap_vs1 = !(inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs1[`REGFILE_INDEX_WIDTH-1:2]);
    else if((emul_vd==EMUL2)|(emul_vs1==EMUL2)) 
      check_vd_overlap_vs1 = !(inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs1[`REGFILE_INDEX_WIDTH-1:1]);
    else if((emul_vd==EMUL1)|(emul_vs1==EMUL1)) 
      check_vd_overlap_vs1 = (inst_vd!=inst_vs1);
    else 
      check_vd_overlap_vs1 = 'b0;
  end

  // widening 类指令常见 EEW_vd:EEW_vs2 = 2:1。
  // 此时允许部分特定形式的重叠，但不能形成非法半组覆盖。
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
  
  // widening 类指令检查 vs1 对 vd 的 2:1 部分重叠约束。
  always_comb begin
    check_vs1_part_overlap_vd_2_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs1_part_overlap_vd_2_1 = 1'b1;
      end
      EMUL2: begin
        check_vs1_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs1[`REGFILE_INDEX_WIDTH-1:1])&(inst_vs1[0]!=1'b1));
      end
      EMUL4: begin
        check_vs1_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs1[`REGFILE_INDEX_WIDTH-1:2])&(inst_vs1[1:0]!=2'b10));
      end
      EMUL8: begin
        check_vs1_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs1[`REGFILE_INDEX_WIDTH-1:3])&(inst_vs1[2:0]!=3'b100));
      end
    endcase
  end

  // 扩展类指令可能出现 EEW_vd:EEW_vs2 = 4:1，单独检查 4:1 部分重叠约束。
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
 
  // 6. 针对每条指令的特殊合法性表。
  //    该表把前面计算出的 overlap/alignment/vstart 约束组合起来。
  //    典型规则：
  //      - 使用 v0 mask 时 vd 不得覆盖 v0；
  //      - mask 逻辑类指令通常要求 vm=1；
  //      - reduction / compress / vfirst / viota 等要求 vstart=0；
  //      - widening/narrowing 指令有额外寄存器组重叠限制。
  always_comb begin 
    check_special = 'b0;
    
    case(inst_funct3)
      OPIVV: begin
        case(inst_funct6)
          VADD,
          VSUB,
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
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSSRL,
          VSSRA,
          VSLIDEDOWN: begin
            check_special = check_vd_overlap_v0;
          end
        
          VADC,
          VSBC: begin
            check_special = (inst_vm==1'b0)&(inst_vd!='b0);
          end

          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSLTU,
          VMSLT: begin
            check_special = check_vd_part_overlap_vs2&check_vd_part_overlap_vs1;
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
          end
          
          VMERGE_VMV: begin
            // when vm=1, it is vmv instruction and vs2_index must be 5'b0.
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(inst_vs2=='b0));
          end
               
          VWREDSUMU,
          VWREDSUM: begin
            check_special = (csr_vstart=='b0);
          end

          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2&check_vd_overlap_vs1;                
          end
        endcase
      end
      OPIVX: begin
        case(inst_funct6)
          VADD,
          VSUB,
          VRSUB,
          VAND,
          VOR,
          VXOR,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSSRL,
          VSSRA,
          VSLIDEDOWN: begin
            check_special = check_vd_overlap_v0;
          end
        
          VADC,
          VSBC: begin
            check_special = (inst_vm==1'b0)&(inst_vd!='b0);
          end

          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSLTU,
          VMSLT,
          VMSGTU,
          VMSGT: begin
            check_special = check_vd_part_overlap_vs2;
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
          end
          
          VMERGE_VMV: begin
            // when vm=1, it is vmv instruction and vs2_index must be 5'b0.
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(inst_vs2=='b0));
          end
               
          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;
          end
        endcase
      end
      OPIVI: begin
        case(inst_funct6)
          VADD,
          VRSUB,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VSLIDEDOWN: begin
            check_special = check_vd_overlap_v0;
          end

          VADC: begin
            check_special = (inst_vm==1'b0)&(inst_vd!='b0);
          end

          VMADC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT: begin
            check_special = check_vd_part_overlap_vs2;
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
          end
          
          VMERGE_VMV: begin
            // when vm=1, it is vmv instruction and vs2_index must be 5'b0.
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(inst_vs2=='b0));
          end
               
          VSMUL_VMVNRR: begin
            check_special = (inst_vm == 1'b1)&(inst_vs1[4:3]==2'b0)&
                            ((inst_nr==NREG1)|(inst_nr==NREG2)|(inst_nr==NREG4)|(inst_nr==NREG8));
          end

          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;
          end
        endcase
      end

      OPMVV: begin
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
          VWMACCSU: begin
            // overlap constraint
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1&check_vs1_part_overlap_vd_2_1;                
          end

          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            // overlap constraint
            check_special = check_vd_overlap_v0&check_vs1_part_overlap_vd_2_1;                
          end
          
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                // overlap constraint
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;                
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                // overlap constraint
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_4_1;                
              end
            endcase
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
            check_special = check_vd_overlap_v0;          
          end

          // reduction
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR: begin
            check_special = (csr_vstart=='b0);
          end

          // mask 
          VMAND,
          VMNAND,
          VMANDN,
          VMXOR,
          VMOR,
          VMNOR,
          VMORN,
          VMXNOR: begin
            check_special = inst_vm;
          end
          
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST: begin
                check_special = (csr_vstart=='b0);
              end
              VMV_X_S: begin
                check_special = (inst_vm==1'b1);
              end
            endcase
          end

          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSIF,
              VMSOF,
              VIOTA: begin
                check_special = (csr_vstart=='b0)&check_vd_overlap_v0&check_vd_overlap_vs2;
              end
              VID: begin
                check_special = (inst_vs2=='b0)&check_vd_overlap_v0;
              end
            endcase
          end

          VCOMPRESS: begin
            // destination register group cannot overlap the source register group
            check_special = (csr_vstart=='b0)&inst_vm&check_vd_overlap_vs2&check_vd_overlap_vs1;
          end
        endcase
      end
      OPMVX: begin
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
          VWMACCUS: begin
            // overlap constraint
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;                
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
          VSLIDE1DOWN: begin
            check_special = check_vd_overlap_v0;          
          end

          VWRXUNARY0: begin
            check_special = (vs2_opcode==VMV_S_X)&inst_vm&(inst_vs2=='b0)&(csr_vstart=='b0);
          end

          VSLIDE1UP: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1&check_vs1_part_overlap_vd_2_1;
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
          VFSGNJX: begin
            check_special = check_vd_overlap_v0;          
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT,
              VFRSQRT7,
              VFREC7,
              VFCLASS: begin          
                check_special = check_vd_overlap_v0;          
              end
            endcase
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE: begin
            check_special = check_vd_part_overlap_vs2&check_vd_part_overlap_vs1;
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16: begin
                check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
              end
              VFWCVTBF16: begin
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;
              end
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin
                check_special = check_vd_overlap_v0;          
              end
            endcase
          end

          VFREDOSUM,
          VFREDUSUM,
          VFREDMAX,
          VFREDMIN: begin
            check_special = (csr_vstart=='b0);
          end

          VWRFUNARY0: begin
            check_special = inst_vm&(vs1_opcode==VFMV_F_S);
          end
        endcase
      end

      OPFVF: begin
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;
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
          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX,
          VFSLIDE1DOWN: begin
            check_special = check_vd_overlap_v0;          
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            check_special = check_vd_part_overlap_vs2;
          end

          VFMERGE_VFMV: begin
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(vs2_opcode=='b0));
          end

          VWRFUNARY0: begin
            check_special = inst_vm&(vs2_opcode==VFMV_S_F)&(csr_vstart=='b0);
          end

          VFSLIDE1UP: begin
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;          
          end
        endcase
      end
      `endif
    endcase
  end

  // 7. 所有算术类指令共用的合法性。
  //    check_sew/check_lmul 实际检查 EEW/EMUL 是否被上面的表成功识别。
  // check_common 是所有算术类指令共同需要满足的条件。它一般包括：
  // check_vd_align
  // check_vs2_align
  // check_vs1_align
  // check_sew
  // check_lmul
  // check_vl_not_0
  // check_vstart_sle_vl
  // check_frm
  assign check_common = check_vd_align&check_vs2_align&check_vs1_align&check_sew&check_lmul
                      `ifdef ZVE32F_ON
                        &check_frm
                      `endif
                        &check_vl_not_0&check_vstart_sle_vl;

  // vd 寄存器编号必须按 EMUL 对齐：
  //   EMUL2 -> vd[0]=0；EMUL4 -> vd[1:0]=0；EMUL8 -> vd[2:0]=0。
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

  // vs2 寄存器编号按 emul_vs2 对齐。
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
    
  // vs1 寄存器编号按 emul_vs1 对齐。
  always_comb begin
    check_vs1_align = 'b0; 
    
    case(emul_vs1)
      EMUL_NONE,
      EMUL1: begin
        check_vs1_align = 1'b1; 
      end
      EMUL2: begin
        check_vs1_align = (inst_vs1[0]==1'b0); 
      end
      EMUL4: begin
        check_vs1_align = (inst_vs1[1:0]==2'b0); 
      end
      EMUL8: begin
        check_vs1_align = (inst_vs1[2:0]==3'b0); 
      end
    endcase
  end
 
  // 如果 eew_max 仍是 EEW_NONE，说明该指令在当前 SEW 下没有合法解码项。
  assign check_sew = (eew_max != EEW_NONE);
    
  // 如果 emul_max 仍是 EMUL_NONE，说明该指令在当前 LMUL/SEW 下不支持。
  assign check_lmul = (emul_max != EMUL_NONE); 
  
  // evstart 是扩展一位后的有效 vstart，便于和 VL_WIDTH 的 vl/evl 比较。
  always_comb begin
    evstart = {1'b0, csr_vstart};
  end

  // 8. 计算有效向量长度 evl。
  //    大多数指令 evl=vl；少数特殊指令覆盖：
  //      - vmv<nr>r.v 按寄存器组拷贝长度计算；
  //      - vmv.s.x / vfmv.s.f 这类只处理一个元素，evl=1。
  always_comb begin
    evl = csr_vl;
  
    case(inst_funct3)
      OPIVI: begin
        case(inst_funct6)
          VSMUL_VMVNRR: begin
            // vmv<nr>r.v
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
        endcase
      end

      OPMVX: begin
        case(inst_funct6)
          VWRXUNARY0: begin
            if(vs2_opcode==VMV_S_X) begin
              evl = 'b1;
            end
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVF: begin
        case(inst_funct6)
          VWRFUNARY0: begin
            if(vs2_opcode==VFMV_S_F) begin
              evl = 'b1;
            end
          end
        endcase
      end
      `endif      
    endcase
  end

  // 9. vl/vstart 合法性检查。
  //    普通向量指令要求 vl != 0 且 vstart < vl/evl。
  //    写 x/f 标量寄存器的指令即使 vl=0 或 vstart>=vl 也可能需要执行，因此在下面豁免。
  always_comb begin
    check_vl_not_0      = csr_vl!='b0;
    check_vstart_sle_vl = evstart < csr_vl;
    
    // 写 x/f 标量寄存器的指令即使 vstart >= vl，包括 vl=0，也需要执行。
    case(inst_funct3) 

      OPIVI: begin
        case(inst_funct6)
          VSMUL_VMVNRR: begin
            check_vl_not_0      = evl!='b0;
            check_vstart_sle_vl = {1'b0,csr_vstart} < evl;
          end
        endcase
      end

      OPMVV: begin
        case(inst_funct6)
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST,
              VMV_X_S: begin
                check_vl_not_0      = 'b1;
                check_vstart_sle_vl = 'b1;
              end
            endcase
          end
        endcase
      end
      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          VWRFUNARY0: begin
            if(vs1_opcode==VFMV_F_S) begin
              check_vl_not_0      = 'b1;
              check_vstart_sle_vl = 'b1;
            end
          end
        endcase
      end
      `endif      
    endcase
  end

`ifdef ZVE32F_ON
  // 浮点指令需要检查 frm 合法；非浮点指令绕过该检查。
  assign check_frm = (inst.arch_state.frm < 3'd5) && valid_opf || !valid_opf;
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

// 10. 计算第一个 uop index。
//     一个向量寄存器组会按 VLEN/EEW 颗粒切成多个 uop。
//     vstart 落在第几个 VLEN 分片，就从对应 uop_index 开始。

//这个信号表示：如果 vstart 非 0，那么应该从哪个 uop index 开始恢复执行
//DE2 或后续调度可以跳过前面已经完成的 uop。
  always_comb begin
    if((inst_funct6==VWRXUNARY0)&(inst_funct3==OPMVV)&(vs1_opcode==VMV_X_S)) begin
      uop_vstart = 'b0;
    end
   `ifdef ZVE32F_ON
    else if((inst_funct6==VWRFUNARY0)&(inst_funct3==OPFVV)&(vs1_opcode==VFMV_F_S)) begin
      uop_vstart = 'b0;
    end
    `endif
    else begin
      case(eew_max)//跳过了“uop 内偏移”的低位，直接拿到了高位中的 uop 号。
        EEW8: begin
          uop_vstart = (`UOP_INDEX_WIDTH)'(evstart[$clog2(`VLENB) +: `UOP_INDEX_WIDTH_ALU]);  //UOP_INDEX_WIDTH=5, UOP_INDEX_WIDTH_ALU=3
        end
        EEW16: begin
          uop_vstart = (`UOP_INDEX_WIDTH)'(evstart[$clog2(`VLENH) +: `UOP_INDEX_WIDTH_ALU]);
        end
        EEW32: begin
          uop_vstart = (`UOP_INDEX_WIDTH)'(evstart[$clog2(`VLENW) +: `UOP_INDEX_WIDTH_ALU]);
        end
        default: begin
          uop_vstart = 'b0;
        end
      endcase
    end
  end

  // 11. 根据 emul_max 计算最后一个 uop index。
  //     EMUL1/2/4/8 分别对应 1/2/4/8 个 uop，最大 index 为 0/1/3/7。
  always_comb begin
    case(emul_max)
      EMUL1:   uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
      EMUL2:   uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
      EMUL4:   uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
      EMUL8:   uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
      default: uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
    endcase
  end

  // 12. 更新 force_vma_agnostic。
  //     当源/目的寄存器重叠且 EEW 不同，结果 mask inactive 部分按 agnostic 处理。
  assign force_vma_agnostic = ((check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE)) |
                              ((check_vd_overlap_vs1==1'b0)&(eew_vd!=eew_vs1)&(eew_vd!=EEW_NONE)&(eew_vs1!=EEW_NONE));

  // 13. 更新 force_vta_agnostic。
  //     mask 目的寄存器的 tail 元素总是 tail-agnostic；不同 EEW 重叠时也强制 tail-agnostic。
  assign force_vta_agnostic = (eew_vd==EEW1) |   // Mask destination tail elements are always treated as tail-agnostic
                              ((check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE)) |
                              ((check_vd_overlap_vs1==1'b0)&(eew_vd!=eew_vs1)&(eew_vd!=EEW_NONE)&(eew_vs1!=EEW_NONE));

  // 14. 组装 DE1 输出 LCMD。
  //     LCMD 保留原 RVVCmd，同时附加 DE2 展开 uop 所需的 EEW/EMUL/evl/uop 范围信息。
  //     注意这里把 arch_state.vstart 改写为 evstart，特殊指令可能使用扩展/修正后的 vstart。
  always_comb begin
    lcmd.cmd                     = inst;
    lcmd.cmd.arch_state.vstart   = evstart;
  end

  assign lcmd_valid              = inst_encoding_correct;
  assign lcmd.eew_vs1            = eew_vs1;
  assign lcmd.eew_vs2            = eew_vs2;
  assign lcmd.eew_vd             = eew_vd;
  assign lcmd.eew_max            = eew_max;
  assign lcmd.emul_vs1           = emul_vs1;
  assign lcmd.emul_vs2           = emul_vs2;
  assign lcmd.emul_vd            = emul_vd;
  assign lcmd.emul_max           = emul_max;
  assign lcmd.uop_vstart         = uop_vstart;
  assign lcmd.uop_index_max      = uop_index_max;
  assign lcmd.evl                = evl;
  assign lcmd.force_vma_agnostic = force_vma_agnostic;
  assign lcmd.force_vta_agnostic = force_vta_agnostic;


endmodule
