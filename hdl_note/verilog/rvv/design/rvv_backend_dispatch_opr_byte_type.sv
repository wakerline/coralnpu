// 功能说明：
// 1. `rvv_backend_dispatch_opr_byte_type` 为当前 uop 的向量操作数生成 byte 级类型标记。
// 2. byte_type 用来描述每个 byte 是有效 body、mask inactive、tail，还是 prestart/not-change。
// 3. 执行单元和 ROB/RT 后续可据此判断该 byte 是否参与运算、是否写回、是否按 agnostic 规则填充。

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif
// 详细中文注释（自动梳理）BEGIN
// - 流水线/层次位置：`rvv_backend_dispatch_opr_byte_type` -> RVV 后端 DP 阶段的操作数字节类型生成单元。
// - 接口与数据流：
//   * 输入：`uop_info`，包含执行单元、uop_index、EEW、vstart、vl、vm、ignore_vma/vta 等控制信息。
//   * 输入：`v0_data`，用于 masked 指令判断每个元素是否 active。
//   * 处理：按 EEW/uop_index 计算当前 uop 覆盖的元素区间，并结合 vstart/vl/v0 mask 生成 byte 类型。
//   * 输出：`operand_byte_type.vs2`、`operand_byte_type.vd` 和 LSU 使用的 `v0_strobe`。
// - 调用关系：上层 rvv_backend_dispatch；无下层实例。
// - 端口摘要：输入 uop_info, v0_data；输出 operand_byte_type。
// - define/参数阅读重点：
//   * `EMUL_MAX`：8；最大 EMUL/LMUL 展开系数。
//   * `VLEN`：未在 design 文件内固定；必须由编译宏 VLEN_128/VLEN_256/VLEN_512/VLEN_1024 之一决定。
//   * `VLENB`：`VLEN/8；依赖 VLEN。
//   * `VL_WIDTH`：$clog2(`VLEN)+1；依赖 VLEN。
//   * `VSTART_WIDTH`：$clog2(`VLEN)；依赖 VLEN。
// - 不确定/条件宏提示：
//   * `VLEN` 未在 design 文件中固定，必须从编译参数选择 `VLEN_128/256/512/1024`，因此所有 VLENB/VLENW/VL_WIDTH 也是派生值。
// - byte 类型含义：
//   * BODY_ACTIVE：该 byte 属于当前 uop 的有效 body 元素，且 mask active 或忽略 vma。
//   * BODY_INACTIVE：该 byte 属于 body 元素，但 mask inactive。
//   * TAIL：该 byte 对应元素 index >= vl。
//   * NOT_CHANGE：该 byte 在 vstart 之前，或不属于当前 uop 应处理的子范围，应保持原值。
// - 特殊规则：
//   * vs2 主要描述源操作数是否可用；vd 描述目的/写回 byte 的类型。
//   * RDT/FRDT 规约写回只使用低元素，其余 byte 标为 tail。
//   * narrowing/widening 与 indexed LSU 会让 vs2/vd 的 EEW 不同，因此需要分别计算元素起点和 v0 对齐范围。
//   * `ignore_vma/ignore_vta` 同时为 1 时，本模块把相关 byte 直接视为 BODY_ACTIVE。
// - 阅读建议：按 “eew_max -> vs2 byte_type -> vd/v0_strobe byte_type -> 输出” 阅读。
// 详细中文注释（自动梳理）END

module rvv_backend_dispatch_opr_byte_type
(
    operand_byte_type,
    uop_info,
    v0_data
);
// ---参数定义-------------------------------------------------
    // VLENB_WIDTH 用于把 uop_index 转换为当前 uop 覆盖的元素/byte 起点。
    localparam VLENB_WIDTH = $clog2(`VLENB);

// ---端口定义-------------------------------------------------
    // 输出给 dispatch/RS/ROB 的 byte 类型集合。
    output UOP_OPN_BYTE_TYPE_t operand_byte_type;
    // 当前 uop 的关键信息摘要。
    input  UOP_INFO_t          uop_info;
    // v0 mask 数据。vm=0 时，每个元素是否 active 由 v0_data 决定。
    input  logic [`VLEN-1:0]   v0_data;

// ---内部信号定义--------------------------------------------
    // eew_max 是 vs1/vs2/vd 中最大的 EEW，用于判断 widening/narrowing 的 uop_index 映射。
    EEW_e                               eew_max;
    logic  [1:0]                        eew_max_shift;
    
    // vs2 相关：计算当前 uop 的 vs2 元素起点、每个 byte 对应的元素 index、以及 mask enable。
    logic  [1:0]                        vs2_eew_shift;
    logic  [`VSTART_WIDTH-1:0]          uop_vs2_start;
    logic  [`VSTART_WIDTH-1:0]          uop_vs2_offset;
    logic  [`VLENB-1:0][`VL_WIDTH-1:0]  vs2_ele_index;  // 每个 byte 对应的 vs2 元素 index。
    logic  [`VLENB-1:0]                 vs2_enable, vs2_enable_tmp;
    
    // vd/v0 相关：ele_start 是当前 uop 对应的基础元素起点。
    logic  [`VSTART_WIDTH-1:0]          ele_start;
    logic  [1:0]                        vd_eew_shift;
    logic  [`VSTART_WIDTH-1:0]          uop_vd_start;
    logic  [`VSTART_WIDTH-1:0]          uop_vd_end;
    logic  [`VLENB-1:0][`VL_WIDTH-1:0]  vd_ele_index;   // 每个 byte 对应的 vd 元素 index。
    logic  [`VLENB-1:0]                 vd_enable;

    logic  [`VSTART_WIDTH-1:0]          uop_v0_start;
    logic  [`VSTART_WIDTH-1:0]          uop_v0_start_offset;
    logic  [`VSTART_WIDTH-1:0]          uop_v0_end;
    logic  [`VSTART_WIDTH-1:0]          uop_v0_end_offset;
    logic  [`VLENB-1:0]                 v0_enable, v0_enable_tmp;
    
    // 中间结果。
    BYTE_TYPE_t                         vs2;
    BYTE_TYPE_t                         vd;
    // v0_strobe 用于 LSU，表示每个 byte 是否应被当前访存 uop 操作。
    logic [`VLENB-1:0]                  v0_strobe;

    genvar i;
// ---代码开始-------------------------------------------------
    // 找出本条 uop 相关操作数中的最大 EEW，并给出 log2(EEW/8) 形式的 shift。
    // EEW1 也使用 shift=0，因为 byte 级处理时 mask 会被打包到 byte。
    always_comb begin
      if ((uop_info.vs1_eew==EEW32)||(uop_info.vs2_eew==EEW32)||(uop_info.vd_eew==EEW32)) begin
        eew_max       = EEW32;
        eew_max_shift = 2'h2;
      end
      else if ((uop_info.vs1_eew==EEW16)||(uop_info.vs2_eew==EEW16)||(uop_info.vd_eew==EEW16)) begin
        eew_max       = EEW16;
        eew_max_shift = 2'h1;
      end
      else if ((uop_info.vs1_eew==EEW8)||(uop_info.vs2_eew==EEW8)||(uop_info.vd_eew==EEW8)) begin
        eew_max       = EEW8;
        eew_max_shift = 2'h0;
      end
      else if ((uop_info.vs1_eew==EEW1)||(uop_info.vs2_eew==EEW1)||(uop_info.vd_eew==EEW1)) begin
        eew_max       = EEW1;
        eew_max_shift = 2'h0;
      end
      else begin
        eew_max       = EEW_NONE;
        eew_max_shift = 2'h0;
      end
    end

// 生成 vs2 的 byte type。
    generate
        always_comb begin
            // vs2_eew_shift = log2(vs2_eew/8)，用于 byte index -> element index 的换算。
            case (uop_info.vs2_eew)
                EEW8:   vs2_eew_shift = 2'h0;
                EEW16:  vs2_eew_shift = 2'h1;
                EEW32:  vs2_eew_shift = 2'h2;
                default:vs2_eew_shift = 2'h0;
            endcase
        end

        // 当前 uop 中，一个 VLEN 寄存器块包含多少个 vs2 元素。
        // uop_vs2_offset = log2(VLENB / bytes_per_vs2_element)=log2(VLENB) - log2(bytes_per_vs2_element)。
        assign uop_vs2_offset = (`VSTART_WIDTH)'(VLENB_WIDTH - vs2_eew_shift);  

        always_comb begin
          case (uop_info.uop_exe_unit)
          `ifdef ZVE32F_ON
            FRDT,
          `endif
            RDT:begin
              // 规约类按 vs2 自身 EEW 切片，eew_max 与 vs2_eew 一致。
              uop_vs2_start = (`VSTART_WIDTH)'(uop_info.uop_index) << uop_vs2_offset ;  //单个MUL切片
            end
            default:begin
              case({eew_max,uop_info.vs2_eew})
                {EEW32,EEW32},
                {EEW16,EEW16},
                {EEW8,EEW8}: begin
                  // 普通或 narrowing 场景：vs2 使用当前 uop_index 对应的完整 VLEN 切片。
                  uop_vs2_start = (`VSTART_WIDTH)'(uop_info.uop_index) << uop_vs2_offset;
                end
                {EEW32,EEW16},
                {EEW16,EEW8}: begin
                  // widening 场景，目的更宽：两个 uop_index 共享同一个较窄 vs2 切片。
                  uop_vs2_start = (`VSTART_WIDTH)'(uop_info.uop_index[$clog2(`EMUL_MAX)-1:1]) << uop_vs2_offset;
                end
                {EEW32,EEW8}: begin
                  // widening 场景，目的比源宽 4 倍：四个 uop_index 共享同一个较窄 vs2 切片。
                  uop_vs2_start = (`VSTART_WIDTH)'(uop_info.uop_index[$clog2(`EMUL_MAX)-1:2]) << uop_vs2_offset;
                end
                default: begin
                  uop_vs2_start = 'b0;
                end
              endcase
            end
          endcase
        end

        // 从 v0 中取出当前 vs2 切片对应的 mask bit；后面会按 EEW 扩展到每个 byte。
        assign vs2_enable_tmp  = v0_data[uop_vs2_start+:`VLENB];  //右移1bit对应rs2的8bit，

        for (i=0; i<`VLENB; i++) begin : gen_vs2_byte_type  //对每个字节进行mask和索引操作
            // vm = 1（不使用mask）:所有元素 = 1（全有效）;否则：每 EEW 对应一个 mask bit
            assign vs2_enable[i] = uop_info.vm ? 1'b1 : vs2_enable_tmp[i >> vs2_eew_shift];
            // ele_index = 当前 uop 的 vs2 起始元素 + byte 在当前 EEW 下对应的元素偏移。
            // 举例
            // EEW=16：
            // byte:
            // 0 1 2 3 | 4 5 6 7 | ...
            // i>>1:
            // 0 0 1 1 | 2 2 3 3
            assign vs2_ele_index[i] = (`VL_WIDTH)'(uop_vs2_start) + (i >> vs2_eew_shift);  //索引每个eew数据
            always_comb begin
                // ignore_vta/vma 同时打开时，源 byte 被当作有效 body 处理，避免旧值保留语义。
                if (uop_info.ignore_vta&uop_info.ignore_vma)
                    vs2[i] = BODY_ACTIVE;       
                else if (vs2_ele_index[i] >= uop_info.vl) 
                    vs2[i] = TAIL; 
                else if (vs2_ele_index[i] < {1'b0, uop_info.vstart}) 
                    vs2[i] = NOT_CHANGE; // vstart 前的 prestart 区域。
                else begin 
                    // body 范围内，mask active 或 ignore_vma 时有效；否则是 inactive body。
                    vs2[i] = (vs2_enable[i] || uop_info.ignore_vma) ? BODY_ACTIVE : BODY_INACTIVE;
                end
            end
        end
    endgenerate

// 生成 vd 的 byte type，并同时生成 LSU 使用的 v0_strobe。
    generate
        always_comb begin
            // vd_eew_shift = log2(vd_eew/8)。
            case (uop_info.vd_eew)
                EEW8:   vd_eew_shift = 2'h0;
                EEW16:  vd_eew_shift = 2'h1;
                EEW32:  vd_eew_shift = 2'h2;
                default:vd_eew_shift = 2'h0;
            endcase
        end
        // | 信号              | 含义                       |
        // | ---------------- | -------------------------- |
        // | ele_start        | 当前 uop 在 vector 中的起点 |
        // | uop_v0_start/end | mask 覆盖范围               |
        // | uop_vd_start/end | destination 写回范围        |
        always_comb begin
          case({eew_max,uop_info.vd_eew})
            {EEW32,EEW32},
            {EEW16,EEW16},
            {EEW8,EEW8}: begin
              // 普通同宽场景：vd、v0、当前 uop 覆盖范围完全对齐。
              ele_start           = (`VSTART_WIDTH)'(uop_info.uop_index) << (VLENB_WIDTH - vd_eew_shift);

              uop_v0_start_offset = 'b0; 
              uop_v0_end_offset   = (`VLENB >> vd_eew_shift) - 1'b1;  //tile_size-1
              uop_v0_start        = ele_start;
              uop_v0_end          = ele_start + uop_v0_end_offset;

              uop_vd_start        = uop_v0_start;
              uop_vd_end          = uop_v0_end;  //一个 uop = 一个完整 vector tile
            end
            {EEW32,EEW16},
            {EEW16,EEW8}: begin
              // narrowing 场景：目的比源窄 2 倍，一个源切片对应两个目的子范围。
              ele_start           = (`VSTART_WIDTH)'(uop_info.uop_index[$clog2(`EMUL_MAX)-1:1] << (VLENB_WIDTH - vd_eew_shift));
              
              uop_v0_start_offset = uop_info.uop_index[0] ? (`VSTART_WIDTH)'(`VLENB >> eew_max_shift) : 'b0;  //操作数偏移
              uop_v0_end_offset   = uop_info.uop_index[0] ? (`VLENB >> vd_eew_shift)-1'b1 : (`VLENB >> eew_max_shift)-1'b1; 
              uop_v0_start        = ele_start + uop_v0_start_offset;
              uop_v0_end          = ele_start + uop_v0_end_offset;

              if (uop_info.uop_exe_unit==LSU) begin
                // indexed load/store 中，vd/vs3 数据范围仍覆盖完整目的切片；
                // v0 mask 范围按 index EEW 比例拆分。
                uop_vd_start      = ele_start;
                uop_vd_end        = ele_start + (`VLENB >> vd_eew_shift) - 1'b1;
              end
              else begin
                uop_vd_start      = uop_v0_start;
                uop_vd_end        = uop_v0_end;
              end
            end
            {EEW32,EEW8}: begin
              // narrowing 场景：目的比源窄 4 倍，一个源切片对应四个目的子范围。
              ele_start = (`VSTART_WIDTH)'(uop_info.uop_index[$clog2(`EMUL_MAX)-1:2]) << VLENB_WIDTH;

              // 根据 uop_index[1:0] 选择当前目的子范围对应的 v0 mask 区间。
              case(uop_info.uop_index[1:0])
                2'd3: begin
                  uop_v0_start_offset = `VLENB*3/4;
                  uop_v0_end_offset   = `VLENB*4/4 - 1;
                end
                2'd2: begin
                  uop_v0_start_offset = `VLENB*2/4;
                  uop_v0_end_offset   = `VLENB*3/4 - 1;
                end
                2'd1: begin
                  uop_v0_start_offset = `VLENB*1/4;
                  uop_v0_end_offset   = `VLENB*2/4 - 1;
                end
                default: begin
                  uop_v0_start_offset = 'b0;
                  uop_v0_end_offset   = `VLENB*1/4 - 1;
                end
              endcase
              uop_v0_start = ele_start + uop_v0_start_offset;
              uop_v0_end   = ele_start + uop_v0_end_offset;

              if (uop_info.uop_exe_unit==LSU) begin
                // indexed load/store 中，vd/vs3 数据范围仍覆盖完整目的切片；
                // v0 mask 范围按 index EEW 比例拆分。
                uop_vd_start          = ele_start;
                uop_vd_end            = ele_start + (`VLENB >> vd_eew_shift) - 1'b1;
              end
              else begin
                uop_vd_start          = uop_v0_start;
                uop_vd_end            = uop_v0_end;
              end
            end
            default: begin  // EEW1/无普通 EEW：主要用于 mask 类目的。
              ele_start           = 'b0; 

              uop_v0_start_offset = 'b0;
              uop_v0_end_offset   = 'b0;
              uop_v0_start        = uop_info.vstart; 
              uop_v0_end          = uop_info.vl;

              uop_vd_start        = uop_v0_start;
              uop_vd_end          = uop_v0_end;
            end
          endcase
        end

        // 从 v0 中取出当前目的切片对应的 mask bit。
        assign v0_enable_tmp = v0_data[ele_start+:`VLENB]; 

        for (i=0; i<`VLENB; i++) begin : gen_vd_byte_type
          // ele_index = 当前 uop 的 vd 起始元素 + byte 在当前 EEW 下对应的元素偏移。
          assign v0_enable[i] = uop_info.vm ? 1'b1 : v0_enable_tmp[i >> vd_eew_shift];
          assign vd_enable[i] = v0_enable[i];
          assign vd_ele_index[i] = (`VL_WIDTH)'(ele_start) + (i >> vd_eew_shift);

          always_comb begin
            // v0_strobe 是 LSU 的 byte 级 mask/strobe，表示该 byte 是否真正参与当前访存。
            if (uop_info.ignore_vta&uop_info.ignore_vma)
              v0_strobe[i] = 'b1;
            else if (vd_ele_index[i] >= uop_info.vl) 
              v0_strobe[i] = 'b0;
            else if ((vd_ele_index[i] < {1'b0, uop_info.vstart})||(vd_ele_index[i] < {1'b0, uop_v0_start})) 
              v0_strobe[i] = 'b0;
            else if (vd_ele_index[i] > {1'b0, uop_v0_end}) 
              v0_strobe[i] = 'b0;
            else 
              v0_strobe[i] = v0_enable[i] || uop_info.ignore_vma;
          end

          always_comb begin
            case (uop_info.uop_exe_unit)
            `ifdef ZVE32F_ON
              FRDT,
            `endif
              RDT:begin
                // 规约类只写低元素，其余 byte 视作 tail。
                case(uop_info.vd_eew)
                  EEW32:vd[i] = i<4 ? BODY_ACTIVE : TAIL;
                  EEW16:vd[i] = i<2 ? BODY_ACTIVE : TAIL;
                  default:vd[i] = i<1 ? BODY_ACTIVE : TAIL;
                endcase
              end
              default:begin
                // 普通目的 byte 分类：tail、prestart/not-change、当前 uop 范围外 inactive、或 body active/inactive。
                if (uop_info.ignore_vta&uop_info.ignore_vma)
                    vd[i] = BODY_ACTIVE;       
                else if (vd_ele_index[i] >= uop_info.vl) 
                    vd[i] = TAIL;       
                else if ((vd_ele_index[i] < {1'b0, uop_info.vstart})||(vd_ele_index[i] < {1'b0, uop_vd_start})) 
                    vd[i] = NOT_CHANGE;     // vstart 前或当前 uop 处理范围前，保持旧值。
                else if (vd_ele_index[i] > {1'b0, uop_vd_end}) 
                    vd[i] = BODY_INACTIVE;
                else 
                    vd[i] = (vd_enable[i] || uop_info.ignore_vma) ? BODY_ACTIVE : BODY_INACTIVE;
              end
            endcase
          end
        end
    endgenerate

    // 输出给 dispatch 顶层：
    // - vs2/vd 供 PMT/RDT/ROB 等单元判断每个 byte 的有效性与写回策略；
    // - v0_strobe 供 LSU 作为 byte 级访存 mask/strobe。
    assign operand_byte_type.vs2       = vs2;
    assign operand_byte_type.vd        = vd;
    assign operand_byte_type.v0_strobe = v0_strobe;

endmodule
