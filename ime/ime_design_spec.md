# CoralNPU IME 可选扩展 RTL 微架构设计规格

**Integrated Matrix Extension on CoralNPU — Parameterized RTL Microarchitecture Specification**

| 项目         | 内容                                                         |
| ------------ | ------------------------------------------------------------ |
| 文档版本     | v0.9（架构评审稿）                                           |
| 文档日期     | 2026-07-22                                                   |
| 目标项目     | Google CoralNPU RTL 增加可参数化 IME 支持                    |
| ISA 输入     | `20260629-Zvvm-IME-riscv-unprivileged-605-730-Zvvm-IME(3).pdf`，Chapter 36，Draft 0.1 |
| RTL 基线     | CoralNPU `e634f91a2aba8fcecd66436699a502e2062d5400`（2026-07-21） |
| 推荐首版配置 | RV32 / VLEN=128 / INT8×INT8→INT32 / λ∈{1,2} / 单在途 IME     |
| 文档状态     | 供架构、RTL、DV、综合和软件团队联合评审；不是已实现 RTL 的描述 |

> **规范性说明**：本文用“必须/不得”描述由 IME ISA 规范导出的架构约束；用“建议/推荐”描述本文选择的 CoralNPU 实现方案；用“可选”描述由参数控制的实现能力。若后续 IME 规范版本变化，以最终 ISA 规范为准，并通过本文的需求追踪表评估 RTL 影响。

## 执行摘要

本文提出一种与 CoralNPU 现有 RVV 后端相容、可综合裁剪、支持精确异常的 IME 微架构。设计不引入新的架构可见矩阵寄存器，所有 A、B、C 矩阵 tile 仍映射到 32 个向量寄存器；新增存储仅是带 ROB 标签的瞬态 operand/result buffer，发生 flush 时可以无条件丢弃。

推荐将 IME 作为独立于现有 `ZVT_ON`/VME 的新功能域，以 `enableIme` 和 `IME_ON` 控制。现有 ZVT 的构建开关、队列接入、flush、LSU 旁路和 PE 算术代码可作为工程参考，但其专用 accumulator、mtype/CSR 语义与 IME 不兼容，不得直接作为 IME 架构状态复用。

本方案的核心决策如下。

| 决策             | 选定方案                                                     | 主要理由                                                     |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| 计算指令展开方式 | 每条 IME 计算指令仅分配一个 ROB 宏令牌                       | `EMUL_C` 最大为 16，而现有 ROB 深度为 8；逐 C 寄存器展开无法覆盖完整规范 |
| 结果保存         | IME 内部瞬态 result buffer                                   | 支持多寄存器结果、精确 flush、等待 ROB 头部提交，不成为架构状态 |
| 架构提交         | ROB 头部驱动 commit sequencer，经现有 retire→VRF 写口分拍写回 | 保持按序提交与单一 VRF 写入所有权；最多 4 个寄存器/周期      |
| 依赖跟踪         | 32-bit 源/目的寄存器组掩码 + 单在途 IME 锁                   | 正确覆盖 LMUL/EMUL_C 多寄存器组，并避免构造大量旁路网络      |
| operand 获取     | 等待所有较老相关写回退休后，串行读取完整 A/B/C/v0            | 复用 VRF，避免为多寄存器 ROB bypass 扩展高扇出网络           |
| 计算数据流       | 参数化 outer-product，物理并行度与 ISA tile 几何解耦         | A、B 均为行主序，B 在计算中按转置解释；适合广播 A/B 的同一 K slice |
| tile load/store  | 由 DE2/LSU 生成可重启 element/segment uop                    | 必须在 fault 时精确记录 `vstart`，并保留已完成元素的可见效果 |
| 首版能力         | 个别扩展 `Zvvi8i32mm`，可选 `Zvvmtls`/`Zvvmttls`             | 与 CoralNPU Zve32 轮廓和边缘 INT8 推理需求匹配；不虚报完整 `Zvvmm` |
| 浮点策略         | 参数接口预留，后续分阶段实现；首版关闭                       | FP/MX 的格式、部分和、舍入、NaN 与 fflags 成本显著，应独立签核 |

![CoralNPU 与 IME 的集成架构](assets/ime_integration_arch.png)

## 文档目的、范围与非目标

### 目的

本文把 IME ISA 语义转换为可执行的 RTL 设计规格，回答以下工程问题：

- 指令如何在 CoralNPU 前端、DE1、DE2、UQ、dispatch、ROB、retire 和 LSU 中流动；
- `vtype.lambda/bs/altfmt_A/altfmt_B` 如何保存、WARL 化和随指令快照；
- A/B/C 多寄存器组如何做 RAW/WAR/WAW 检查；
- 一条指令最多写 16 个向量寄存器时，如何保持精确异常和按序退休；
- 计算 datapath 如何参数化并在关闭 IME 时被综合完全裁剪；
- tile load/store 如何实现二维地址、mask、tail 和 `vstart` 重启；
- RTL、DV、软件、PPA 团队分别需要哪些交付物和签核条件。

### 范围

本文覆盖：

- 整数矩阵乘累加 `vmmacc/vwmmacc/vqmmacc/v8wmmacc` 的通用架构；
- 浮点与 microscaling 的接口、状态、异常和分阶段扩展框架；
- order-preserving 与 transposing tile load/store；
- CoralNPU 当前 RVV 后端所需的模块、接口、结构体和控制修改；
- reset、flush、clock gating、性能计数器、形式验证和随机验证计划；
- 面积优先首版 profile 与完整规范演进路线。

### 非目标

本文不负责：

- 修改 IME ISA、重定义未定稿的指令语义或冻结软件 ABI；
- 给出未经综合的面积、频率、功耗百分比；
- 规定 compiler intrinsic 的最终名称或 Linux context-switch 实现；
- 把现有 ZVT/VME 专用 accumulator 暴露为 IME 架构状态；
- 在首版中承诺完整 `Zvvmm`、`Zvvfmm` 或全部 MX 数据类型。

## 设计输入与基线

### ISA 输入

设计输入是所附 IME Draft 0.1，覆盖 `Zvvmm`、`Zvvfmm`、`Zvvmtls`、`Zvvmttls`、microscaling、异常重启和完整 encoding map。本文使用的关键章节包括：

| 规范章节  | 设计输入                               |
| --------- | -------------------------------------- |
| 36.2      | tile 几何、A×Bᵀ+C 语义                 |
| 36.3      | family 与 individual extension 命名    |
| 36.4      | vtype 新字段和 λ WARL 行为             |
| 36.5      | 输入元素 packing，含 4-bit nibble 顺序 |
| 36.6–36.7 | integer、FP、MX 算术语义               |
| 36.8–36.9 | tile load/store 与 transposition       |
| 36.11     | 各条指令编码、非法条件和伪代码         |
| 36.13     | FP、integer、MX 类型映射表             |

### CoralNPU RTL 基线

本文以 [CoralNPU 官方仓库](https://github.com/google-coral/coralnpu) 的 commit `e634f91a2aba8fcecd66436699a502e2062d5400` 为设计基线。涉及的关键实现包括：

| 当前模块                                 | 基线事实                                         | IME 影响                                     |
| ---------------------------------------- | ------------------------------------------------ | -------------------------------------------- |
| `Parameters.scala`                       | `rvvVlen=128`；`enableRvv`、`enableVme` 已存在   | 增加独立 `enableIme` 和子功能参数            |
| `RvvDecode.scala` / `RvvInterface.scala` | Chisel 前端生成压缩 RVV command 与 config state  | 扩展 IME opcode 识别及 vtype snapshot        |
| `RvvFrontEnd.sv`                         | command queue、DE1/DE2 前端与配置更新            | 增加 λ WARL、IME legality 与宏令牌           |
| `rvv_backend.sv`                         | UQ→dispatch→RS→execution→ROB→retire              | 增加 IME RS、engine、result/commit 通道      |
| `rvv_backend_dispatch*.sv`               | 以单个 `vs1/vs2/vd/v0` 索引做 hazard/bypass      | 增加 32-bit group mask scoreboard            |
| `rvv_backend_vrf*.sv`                    | 32×VLEN DFF；最多 6 个组合读口；4 个 retire 写口 | 增加可参数化 IME 串行读仲裁；写回仍归 retire |
| `rvv_backend_rob.sv`                     | ROB 深度 8，每项保存一个 VLEN 结果               | IME 项仅保存 token/状态，不保存全部 C 数据   |
| `rvv_backend_retire.sv`                  | `NUM_RT_UOP=4`，经 byte strobe 写 VRF            | 头部 IME 项触发多周期 commit                 |
| `Zvt/*`                                  | 可选 PE/控制/专用 accumulator 和 LSU 通道        | 仅作为非架构代码参考，不直接复用状态模型     |

上述基线可从 [Parameters.scala](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/chisel/src/coralnpu/Parameters.scala)、[rvv_backend.sv](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/rvv_backend.sv)、[rvv_backend_vrf.sv](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/rvv_backend_vrf.sv)、[rvv_backend_rob.sv](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/rvv_backend_rob.sv) 和 [Zvt/zvt.sv](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/Zvt/zvt.sv) 交叉核对。

### 术语

| 术语          | 含义                                                |
| ------------- | --------------------------------------------------- |
| `W`           | widening factor，A/B 输入宽度为 `SEW/W`             |
| `λ`           | IME selected lambda，决定 M/N 几何和 C 寄存器组大小 |
| `M`           | C 的物理行数和最大列数                              |
| `N_tile`      | 由 VL 选择的有效 C 列数                             |
| `K_eff`       | 实际 dot-product K 维长度                           |
| `EMUL_C`      | C tile 占用的向量寄存器数，可到 16                  |
| 宏令牌        | 一条完整 IME 计算指令在 UQ/ROB 中的单个控制项       |
| result buffer | IME 内部、ROB-tagged、非架构化 C 暂存               |
| capture       | 从 VRF 读取并冻结 A/B/C/v0 输入的阶段               |
| group mask    | 32-bit 向量寄存器占用掩码                           |
| TLS/TTLS      | tile load/store / transposing tile load/store       |

## ISA 语义到 RTL 的约束

### 架构状态不变量

`REQ-ARCH-001`：IME 不新增架构可见矩阵寄存器文件。A、B、C 均由现有 32 个向量寄存器组成的寄存器组承载。

`REQ-ARCH-002`：内部 A/B/C buffer、partial sum、scale cache、result buffer 均为微架构状态。其有效位必须受 ROB tag 和 flush 控制；在 trap/flush 时不得对恢复软件可见。

`REQ-ARCH-003`：IME compute 指令只有在其 ROB 宏令牌位于头部、无 trap 且所有 C 写口可接受时，才允许更新 VRF/fflags。

`REQ-ARCH-004`：compute 指令不可通过 `vstart` 重启；开始执行时 `vstart!=0` 必须报 illegal instruction。tile load/store 则必须支持逐元素 `vstart` 重启。

### Tile 几何

矩阵指令完成：

$$
C \leftarrow A \times B^{T} + C
$$

由当前 `VLEN`、`SEW`、`LMUL`、`W` 和 `λ` 派生：

$$
\sigma = \frac{VLEN}{SEW\times\lambda}
$$

$$
M=N_{max}=\sigma
$$

$$
K_{eff}=\lambda\times W\times LMUL
$$

$$
N_{tile}=\frac{VL}{\lambda\times LMUL}
$$

$$
EMUL_C=\frac{VLEN}{SEW\times\lambda^2}\in\{1,2,4,8,16\}
$$

其中：

- A 是 `M×K_eff` tile，A 基址按 `LMUL` 对齐；
- B 是 `N_tile×K_eff` tile，寄存器内按行主序存储，计算时解释为 `Bᵀ`；
- C 是 `M×M` 物理 tile，只有前 `N_tile` 列有效，C 基址按 `EMUL_C` 对齐；
- A/B 输入的 EEW 为 `SEW/W`，C 的元素宽度为 `SEW`；
- `LMUL` 对 IME 必须是整数 1/2/4/8，fractional LMUL 非法；
- `VL` 必须是 `λ×LMUL` 的整数倍，且 `N_tile≤M`。

### VLEN=128 的合法几何

下表是 `VLEN=128` 时所有架构上可允许的非零 λ；实现仍可在其中选择子集，但每个位于 IME 合法域的 `(VLEN,SEW)` 必须至少支持一个 λ。

|  SEW |    λ | M=Nmax | EMUL_C | CoralNPU 首版                  |
| ---: | ---: | -----: | -----: | ------------------------------ |
|    8 |    1 |     16 |     16 | 不实现                         |
|    8 |    2 |      8 |      4 | 不实现                         |
|    8 |    4 |      4 |      1 | 不实现                         |
|   16 |    1 |      8 |      8 | 可选后续                       |
|   16 |    2 |      4 |      2 | 可选后续                       |
|   32 |    1 |      4 |      4 | 必须                           |
|   32 |    2 |      2 |      1 | 必须                           |
|   64 |    1 |      2 |      2 | 当前 RV32/Zve32 profile 不实现 |

![VLEN=128、INT8×INT8→INT32 的 tile 示例](assets/ime_geometry_example.png)

### C tail 的二维语义

C tail 不是普通 RVV 的扁平 `element_index>=VL`。对任意 C 元素 `C[m][n]`，当 `n>=N_tile` 时，该元素属于二维列 tail：

- 执行数据路径不得读取该 C 初值；
- `vta=0` 时不得写回；
- `vta=1` 时可写任意值，也可保持不变；
- 推荐所有实现均对 C tail 保持不变，从而简化 byte strobe 和软件调试；
- tail 计算必须使用列坐标判定，不能把 C tile 线性化后与 `VL` 直接比较。

### 输入 packing

对于 `W>1`，一个 `SEW` storage element 中包含 W 个窄输入元素：

- `EEW>=8`：遵循普通 RISC-V V 低位优先元素顺序；
- `EEW=4`：偶数元素位于 byte 的低 nibble，奇数元素位于高 nibble；
- tile load/store 始终以 `SEW` storage element 为传输粒度，不会自动 unpack；
- transposing tile load/store 转置 storage element，不转置其内部的 W 个窄元素。

### 整数算术

| 指令          |    W | 输入 EEW | C 宽度 | funct6   | `vm=1`           | `vm=0`                        |
| ------------- | ---: | -------: | -----: | -------- | ---------------- | ----------------------------- |
| `vmmacc.vv`   |    1 |      SEW |    SEW | `111000` | ordinary integer | reserved                      |
| `vwmmacc.vv`  |    2 |    SEW/2 |    SEW | `111001` | ordinary integer | `vfwimmacc` MX integer-input  |
| `vqmmacc.vv`  |    4 |    SEW/4 |    SEW | `111010` | ordinary integer | `vfqimmacc` MX integer-input  |
| `v8wmmacc.vv` |    8 |    SEW/8 |    SEW | `111011` | ordinary integer | `vf8wimmacc` MX integer-input |

上述 integer 指令使用 OP-V major opcode、`funct3=OPIVV(000)`；对应 floating-point 指令 `vfmmacc/vfwmmacc/vfqmmacc/vf8wmmacc` 的 `funct6` 为 `010100/010101/010110/010111`，使用 `funct3=OPFVV(001)`。

普通 integer 形式中，`altfmt_A/B=0` 表示有符号、`1` 表示无符号；A/B 可独立选择符号。所有 product 和中间累加最终按 `2^SEW` 取模，因此 RTL 可保留低 `SEW` 位而不需要饱和逻辑。

对首版推荐的 `Zvvi8i32mm`：`SEW=32`、`W=4`、A/B EEW=8，使用 `vqmmacc.vv`。若增加 `Zvvi16i32mm`，则使用 `vwmmacc.vv`。只有实际覆盖 encoding map 指定的全部数据类型/符号组合和行为时，才可以公布对应 individual extension。

### 浮点与 microscaling 约束

| 类别        | 关键 RTL 约束                                                |
| ----------- | ------------------------------------------------------------ |
| 普通 FP     | `vfmmacc/vfwmmacc/vfqmmacc/vf8wmmacc`；输入/输出格式由 `altfmt_A/B/altfmt` 与宽度组合决定 |
| grouping    | 每个 `(SEW,W,λ)` 实现必须披露 `(G,psm,rnd)`；G 为不越过 LMUL=1 或 MX block 边界的 2 次幂 |
| `psm=0`     | partial product 精确归约后再进行规定舍入，推荐首个 FP 实现采用 |
| `psm=1`     | 允许非精确 partial sum，但必须披露算法并提供可执行 SAIL 描述；首版不采用 |
| rounding    | 最终累加使用动态 `frm`；partial sum 可选择 `frm/rto/xct` 并随 profile 固定 |
| fflags      | 所有有效输出的异常标志 OR 聚合，在 ROB 头部随 C 原子提交     |
| MX scale    | `v0` 中每个 16-bit pair：低 byte 为 scale_A，高 byte 为 scale_B，格式 E8M0 |
| block size  | `bs=0` 为 32 elements，`bs=1` 为 16 elements；仅 `vm=0` 有效 |
| MX legality | `SEW×λ>=16`；`bs=1` 时 `W×LMUL<=SEW`；vd/vs1/vs2 不得与 v0 重叠 |
| scale NaN   | scale `0xff` 产生规定的 canonical default NaN，并停止该输出的后续 block 累加 |

首版 `IME_ENABLE_FP=0`、`IME_ENABLE_MX=0` 时，相关 opcode/type cell 必须在 DE1 报 illegal instruction；不得只在 datapath 中返回零或把指令当 NOP。

### vtype 新字段与 WARL

RV32 下 IME 高位字段为：

|    位 | 字段          | reset/vill        | 语义                             |
| ----: | ------------- | ----------------- | -------------------------------- |
|    31 | `vill`        | 由基础 V 规范定义 | illegal vtype                    |
| 30:28 | `lambda[2:0]` | `000`             | selected λ 编码                  |
|    27 | `bs`          | 0                 | MX block size                    |
|    26 | `altfmt_A`    | 0                 | FP 输入格式或 integer signedness |
|    25 | `altfmt_B`    | 0                 | FP 输入格式或 integer signedness |

λ 编码 `001/010/011/100/101/110/111` 分别表示 `1/2/4/8/16/32/64`。其 WARL 行为必须由单一模块实现：

- 写 `000` 表示 preserve-or-initialize：若当前 λ 对新 `(VLEN,SEW)` 仍受支持则保留，否则选最大支持 λ；合法域之外保持 `000`；
- 写受支持的非零值时原样保留；
- 写不支持的非零值时，优先选择不大于请求值的最大支持 λ；若不存在则选择最小支持 λ；
- `vsetvli/vsetivli` 不能直接编码高位字段，必须保留 `bs/altfmt_A/B`，并对 λ 执行 preserve-or-initialize；
- `vsetvl` 从 `rs2` 写完整 vtype，高位字段按上述 WARL 处理；
- 仅改变 LMUL 不改变 λ 支持集合；改变 SEW 可能触发 λ 重新选择；
- `vill=1` 或 reset 时 IME 高位字段清零；
- tile LS 的 immediate λ=`000` 表示使用动态 `vtype.lambda`；非零 immediate 必须精确命中支持集合，不得 WARL clamp。

建议由 Chisel 与 SystemVerilog 共用同一份生成参数表，避免前端读回值和后端 legality 使用不同的 λ mask。

### Tile load/store

四条 tile memory 指令使用 vector load/store major opcode 与 `width=3'b111`：`bits[28:26]=3'b100` 表示 order-preserving，`3'b101` 表示 transposing，`bits[31:29]` 为 immediate λ。

order-preserving 地址为：

$$
q=i\ \mathrm{div}\ linesize,\qquad r=i\ \mathrm{mod}\ linesize
$$

$$
addr(i)=rs1+\frac{SEW}{8}(q\times LD+r)
$$

其中 `linesize=λ×LMUL`，`rs2=0` 时默认 `LD=linesize`。

transposing 地址为：

$$
addr_T(i)=rs1+\frac{SEW}{8}(r\times LD+q)
$$

其中 `rs2=0` 时默认：

$$
LD=\frac{VLEN}{SEW\times\lambda}=M
$$

tile load/store 必须满足：

- 支持 mask，并对 `i<vstart`、mask-off、`i>=VL` 元素不发出 memory request；
- tile load 的 inactive/tail destination 永远保持不变，忽略 `vta/vma`；
- fault 时把精确 fault element index 写入 `vstart`；成功完成后清零 `vstart`；
- masked tile load 的 destination group 不得与 v0 重叠；
- immediate λ 非零但不受支持时，必须 illegal，不做 clamp；
- load/store 组基址按 LMUL 对齐且不得越过 v31。

## 总体微架构

### 设计原则

`DEC-001`：IME 与 ZVT/VME 是正交 feature。新增 `IME_ON`，不改变 `ZVT_ON` 的含义。

`DEC-002`：关闭 IME 后，不保留 IME RS、buffer、PE、scoreboard bit、时钟树叶节点或额外 VRF 存储；对外接口使用 `generate` tie-off 或在 Chisel elaboration 阶段删除。

`DEC-003`：计算指令采用宏令牌；tile memory 指令采用可重启 uop。两类指令共享 decode/geometry，但不共享提交机制。

`DEC-004`：首版仅允许一个在途 IME compute 指令。其他不冲突的普通 RVV 指令可以继续 dispatch/execute；与 IME group mask 冲突的指令停顿。

`DEC-005`：IME 不从 ROB 做多寄存器旁路。capture 只在所有较老相关写已经退休后开始，以控制面积、时序与验证复杂度。

### 模块层次

```text
RvvCore
└── rvv_backend
    ├── existing decode / UQ / dispatch / ROB / retire / VRF / LSU
    └── ime_subsystem                         [IME_ON]
        ├── ime_geometry
        ├── ime_legal
        ├── ime_group_scoreboard
        ├── ime_rs
        ├── ime_operand_fetch
        ├── ime_engine
        │   ├── ime_unpack
        │   ├── ime_scale                    [IME_ENABLE_MX]
        │   ├── ime_pe_array
        │   ├── ime_accum_int               [IME_ENABLE_INT]
        │   ├── ime_accum_fp                [IME_ENABLE_FP]
        │   └── ime_result_buffer
        ├── ime_commit
        └── ime_tls                          [IME_ENABLE_TLS/TTLS]
            ├── ime_tls_addrgen
            ├── ime_tls_uopgen
            └── ime_tls_fault_tracker
```

### 模块职责

| 模块                   | 主要输入                             | 主要输出                     | 必须保证                            |
| ---------------------- | ------------------------------------ | ---------------------------- | ----------------------------------- |
| `ime_geometry`         | vtype、VL、W、寄存器字段             | M/N/K、EMUL_C、group mask    | 无除法器；常量/移位/查表实现        |
| `ime_legal`            | instruction、geometry、feature table | legal、illegal reason bitmap | 所有非法条件在分配执行资源前确定    |
| `ime_group_scoreboard` | dispatch/retire/flush、mask          | issue allow、read/write lock | RAW/WAR/WAW 正确；flush 无残留锁    |
| `ime_rs`               | 合法宏令牌                           | 单条 descriptor              | 初版 1-entry；valid/ready 稳定      |
| `ime_operand_fetch`    | descriptor、VRF read rsp             | A/B/C/v0 buffers             | 全部输入 capture 完成前禁止 compute |
| `ime_pe_array`         | A/B slices、schedule                 | products/partial sums        | 物理并行度参数化；整数取模          |
| `ime_accum_fp`         | partial sums、frm/format             | C、fflags                    | 遵守披露的 `(G,psm,rnd)`            |
| `ime_result_buffer`    | C result、strobes、fflags            | done、commit chunks          | ROB-tagged；flush 安全；非架构状态  |
| `ime_commit`           | ROB head token、result chunks        | retire VRF writes、fflags    | 所有 C 写完才允许 ROB pop           |
| `ime_tls_addrgen`      | base/LD/i/geometry                   | address、active、last        | 地址公式、mask/tail、vstart 精确    |

## 参数化与构建配置

### 顶层功能参数

建议在 `Parameters.scala` 中增加 `ImeParameters`，由 Chisel elaboration 同时驱动 wrapper 端口、SV define 和 package 常量。所有非法组合在 elaboration 阶段 `require()` 失败，而不是生成不可达 RTL。

| 参数                  |        推荐默认 | 含义与约束                                              |
| --------------------- | --------------: | ------------------------------------------------------- |
| `enableIme`           |         `false` | IME 总开关；要求 `enableRvv=true`                       |
| `imeEnableInt`        | `true` when IME | integer compute datapath                                |
| `imeEnableFp`         |         `false` | FP compute；要求相应基础 FP 能力                        |
| `imeEnableMx`         |         `false` | microscaling；要求 FP 或 integer-input FP accumulate    |
| `imeEnableTls`        |         `false` | `vmtl/vmts`                                             |
| `imeEnableTtls`       |         `false` | `vmttl/vmtts`；要求 `imeEnableTls` 或共享 LSU sequencer |
| `imeSupportedSewMask` |         `SEW32` | 支持的 C SEW 集合                                       |
| `imeSupportedWMask`   |            `W4` | 支持的 widening factor                                  |
| `imeLambdaMaskBySew`  |   `SEW32:{1,2}` | 每个 SEW 的受支持 λ，必须是架构允许集合的非空子集       |
| `imeTypeCellMask`     |    `Zvvi8i32mm` | encoding map 中实际实现的 individual extensions         |
| `imeInflight`         |             `1` | 初版必须为 1；后续增加时需扩展 result slots/scoreboard  |
| `imeMPar`             |             `4` | 并行输出行数，`1..Mmax`                                 |
| `imeNPar`             |             `4` | 并行输出列数，`1..Mmax`                                 |
| `imeKPar`             |             `1` | 每输出每周期的标量 product 数                           |
| `imeVrfReadPorts`     |             `1` | IME 专用逻辑读口数；1 最省面积，2 提升 capture          |
| `imeCommitPorts`      |    `NUM_RT_UOP` | 每周期提交 C 寄存器数，不得超过 retire/VRF 写口         |
| `imeFpPsm`            |             `0` | FP partial-sum model；首个 FP profile 固定 0            |
| `imeFpRnd`            |           `XCT` | FP partial-sum rounding policy                          |
| `imeFpGroupByGeom`    | generated table | 每个 `(SEW,W,λ)` 的 G                                   |

### SystemVerilog 编译常量

推荐只保留一个总 define 控制端口和模块存在性；能力集合通过 `ime_pkg.svh` 中的 `localparam` 表表达，避免在核心逻辑散布大量 `ifdef`。

```systemverilog
`ifdef IME_ON
  localparam bit IME_ENABLE_INT  = 1'b1;
  localparam bit IME_ENABLE_FP   = 1'b0;
  localparam bit IME_ENABLE_MX   = 1'b0;
  localparam bit IME_ENABLE_TLS  = 1'b1;
  localparam int IME_M_PAR       = 4;
  localparam int IME_N_PAR       = 4;
  localparam int IME_K_PAR       = 1;
  localparam int IME_COMMIT_PORTS = `NUM_RT_UOP;
`endif
```

### 构建 profile

| Profile           | 指令/类型           | λ           | Datapath                | 用途                 |
| ----------------- | ------------------- | ----------- | ----------------------- | -------------------- |
| `BASE_RVV`        | 无 IME              | —           | 全部裁剪                | 逻辑等价和 PPA 基线  |
| `IME_EDGE_I8_MIN` | `Zvvi8i32mm`        | SEW32:{1}   | 2×2×1 或 4×4×1          | 最小面积验证         |
| `IME_EDGE_I8_REC` | `Zvvi8i32mm`        | SEW32:{1,2} | 4×4×1                   | 推荐边缘推理首版     |
| `IME_EDGE_I8_TLS` | 上述 + TLS/TTLS     | 同上        | + LSU sequencer         | 完整软件数据搬运路径 |
| `IME_INT_WIDE`    | 增加 INT16→INT32 等 | 各自 mask   | unpack/乘法器扩展       | 第二阶段整数能力     |
| `IME_FP_BASE`     | FP16/BF16→FP32      | 合法子集    | `psm=0`、固定 G/rnd     | 第三阶段             |
| `IME_MX_FULL`     | OFP8/OFP4/MXINT     | 合法子集    | scale path + FP special | 最后阶段             |

### Extension 宣告规则

硬件对外宣告必须根据 `imeTypeCellMask` 生成，而不是根据 `enableIme` 粗粒度生成：

- 仅实现 `vqmmacc` 的 SEW32/EEW8 type cell 时，宣告 `Zvvi8i32mm`；
- 未实现所有整数 type cell 时，不宣告 family-level `Zvvmm`；
- 未实现 FP encoding map 的全部要求时，不宣告 `Zvvfmm`；
- TLS/TTLS 的宣告与 compute type cell 正交；
- testbench 必须读取生成的 extension manifest，并验证每个宣告 cell 的正/负例。

## Decode、配置与 legality

### Chisel scalar/front-end decode

当前压缩 RVV 指令入口对 vector load/store 的 `width` 有限制。IME tile memory 使用 `width=111`，因此需要：

1. 在 `RvvCompressedInstruction.from_uncompressed` 中，仅当 `enableImeTls` 且 major opcode 为 vector load/store、`bits[28:26]` 为 `100/101` 时接受 `width=111`；
2. 保留 `bits[31:20]`，使 immediate λ、transpose bit、vm 和 rs2 能传入 SV 前端；
3. 非 tile 的 `width=111` 仍解码为 illegal，避免把保留的 64-bit vector memory encoding 误接收；
4. compute 指令通过 OP-V `funct6/funct3/vm` 识别，并按 `imeTypeCellMask` 过滤；
5. `enableIme=false` 时 decode 表不包含 IME pattern，保证对 baseline 无优先级扰动。

### DE1

DE1 负责所有不依赖执行结果的判定：

- opcode class、W、integer/FP/MX、TLS/TTLS；
- vtype snapshot、VL、vstart、frm；compute 检查 `vstart=0`，TLS/TTLS 允许任意非零 vstart；
- λ 动态/立即数选择；
- M、N、K、EMUL_C 和 group mask；
- type cell 是否在实现 mask 中；
- alignment、group overflow、VL multiple、v0 overlap；
- compute `vstart==0`；tile memory 不因非零 vstart 报 illegal，`vstart>=VL` 时按规范完成空操作并清零；
- 产生 `illegal_reason`，并沿用现有 illegal/trap 路径，不进入 IME RS。

推荐 `illegal_reason` 为 one-hot/bitmap debug 信号，仅在仿真、trace 或性能计数器开启时保留：

```systemverilog
typedef struct packed {
  logic feature_off;
  logic bad_vtype;
  logic bad_lambda;
  logic bad_sew_w;
  logic bad_lmul;
  logic bad_vl;
  logic bad_emul_c;
  logic bad_group_align;
  logic group_overflow;
  logic bad_vstart;
  logic bad_v0_overlap;
  logic bad_mx;
  logic reserved_type_cell;
} IME_ILLEGAL_REASON_t;
```

### Geometry 实现

在支持集合有限的前提下，不应综合通用除法器。建议使用编码和移位：

- `SEW=8<<vsew`；
- λ 只允许 2 的幂，由 `lambda_enc-1` 得到 `log2(lambda)`；
- `M = VLEN >> (log2(SEW)+log2(lambda))`；
- `EMUL_C = VLEN >> (log2(SEW)+2*log2(lambda))`；
- `K_eff = lambda << (log2(W)+log2(LMUL))`；
- `N_tile = VL >> (log2(lambda)+log2(LMUL))`，同时检查低位全零；
- 32-bit group mask 通过 `base`、`count` 生成，不使用可变宽长移位溢出表达式。

```systemverilog
function automatic logic [31:0] reg_group_mask(
  input logic [4:0] base,
  input logic [4:0] count
);
  logic [32:0] ones;
  begin
    ones = (33'b1 << count) - 1'b1;
    reg_group_mask = ones[31:0] << base;
  end
endfunction
```

RTL 必须在调用前检查 `count∈{1,2,4,8,16}` 且 `base+count<=32`；综合/形式工具若不接受上述 variable shift，应改为 case 表。

### 集中 legality 表

| 检查                   | compute | TLS/TTLS                  | 失败动作          |
| ---------------------- | ------- | ------------------------- | ----------------- |
| `enable/type cell`     | 必须    | 必须                      | illegal           |
| `vill=0`、λ 非零且支持 | 必须    | 动态 λ 时必须             | illegal           |
| immediate λ 精确支持   | —       | immediate 非零时必须      | illegal，不 clamp |
| integer LMUL           | 必须    | 必须                      | illegal           |
| `vstart=0`             | 必须    | 否                        | illegal           |
| `VL%(λ×LMUL)==0`       | 必须    | 必须                      | illegal           |
| `EMUL_C` 合法          | 必须    | 用于所选 tile 时必须      | illegal           |
| A/B base 对齐 LMUL     | 必须    | source/dest 对齐 LMUL     | illegal           |
| C base 对齐 EMUL_C     | 必须    | C 搬运场景由软件配置 LMUL | illegal           |
| group 不越过 v31       | 必须    | 必须                      | illegal           |
| `EEW>=4`               | 必须    | N/A（按 SEW storage）     | illegal           |
| `vq` 且 SEW=8          | 非法    | —                         | illegal           |
| `v8w` 且 SEW<32        | 非法    | —                         | illegal           |
| vm=0 MX type/bs/scale  | 必须    | mask 语义                 | illegal           |
| masked load `vd` 与 v0 | —       | 不得重叠                  | illegal           |

### RVVConfigState 扩展

Chisel 与 SV 的 config bundle 必须保持完全一致。建议字段如下：

```systemverilog
typedef struct packed {
  // Existing base-vector fields
  logic        vill;
  logic [2:0]  vsew;
  logic [2:0]  vlmul;
  logic        vta;
  logic        vma;
  logic [VL_W-1:0] vl;
  logic [VL_W-1:0] vstart;

`ifdef IME_ON
  logic [2:0]  ime_lambda;
  logic        ime_bs;
  logic        ime_altfmt_a;
  logic        ime_altfmt_b;
`endif
} RVVConfigState;
```

旧 ZVT 的 `altfmt/mtwiden/tm/tk` 不能与 IME 字段别名。若两种 feature 同时编译，必须在结构体中使用不同命名并在 CSR 映射层明确选择；禁止依靠 field 顺序隐式复用。

## 依赖、dispatch 与寄存器组锁

### 掩码定义

对每条 compute 指令生成：

```text
src_a_mask = LMUL 个寄存器，从 vs1 开始
src_b_mask = LMUL 个寄存器，从 vs2 开始
src_c_mask = EMUL_C 个寄存器，从 vd 开始
dst_c_mask = src_c_mask
scale_mask = vm==0 ? 32'h1 : 0
read_mask  = src_a_mask | src_b_mask | src_c_mask | scale_mask
write_mask = dst_c_mask
```

指令自身 A/B/C 重叠不应被判 illegal。operand fetch 必须在任何 writeback 之前捕获所有输入，因此能自然支持 `vd` 与 `vs1/vs2` 重叠。与 v0 的重叠按 MX 规范单独禁止。

### 与较老指令的依赖

`ime_issue_allow` 的推荐保守条件是：

$$
(read\_mask \cup write\_mask) \cap older\_pending\_dst\_mask = \varnothing
$$

其中普通 ROB entry 的目的掩码由单个 `vd` 转 one-hot，普通多 uop 指令由每个 uop 的真实目的寄存器贡献。这样 IME capture 只读已退休的 VRF 值，不需要从 8 项 ROB 构造多寄存器 × 多 operand 的 bypass mux。

### 与较年轻指令的依赖

IME 分配后输出两类全局锁：

- `ime_read_lock_mask=read_mask`：从 ALLOC 保持到 CAPTURE 完成，阻止较年轻指令写这些寄存器，解决 WAR；
- `ime_write_lock_mask=write_mask`：从 ALLOC 保持到最后一个 C commit 完成，阻止较年轻指令读或写 C，解决 RAW/WAW。

普通 dispatch 的条件扩展为：

```systemverilog
normal_src_conflict = |(normal_read_mask  & ime_write_lock_mask);
normal_dst_conflict = |(normal_write_mask &
                       (ime_write_lock_mask | ime_read_lock_mask));
normal_issue_allow  = !(normal_src_conflict | normal_dst_conflict);
```

CAPTURE 完成后，A/B/v0 的 read lock 可以释放，允许年轻指令覆盖输入寄存器；C 的 write lock 必须保持至 RETIRE。

### 为什么不逐寄存器展开 compute

不采用“每个 C 寄存器一个 uop/ROB entry”的原因：

- `EMUL_C=16` 时超过现有 ROB depth=8；
- 一条指令的所有 C 列需要共享 A/B capture、异常状态和完成边界；
- 逐 uop 退休会使中断或 trap 观察到部分 C 更新，除非额外实现复杂的 instruction grouping；
- 每个 output uop 需要重复保存大 descriptor，增加 UQ/ROB/RS 面积；
- C 结果的内部计算顺序不应被现有 VLEN 级结果仲裁强制限制。

宏令牌方案把多寄存器提交复杂度局部化在 `ime_result_buffer/ime_commit`，对现有后端侵入更可控。

## 控制结构与接口

### IME descriptor

建议的控制结构体如下；实现可根据 profile 对常量字段做综合裁剪。

```systemverilog
typedef enum logic [3:0] {
  IME_VMM, IME_VWMM, IME_VQMM, IME_V8WMM,
  IME_VFMM, IME_VFWMM, IME_VFQMM, IME_VF8WMM
} IME_OP_e;

typedef struct packed {
  logic [`ROB_DEPTH_WIDTH-1:0] rob_tag;
  logic [31:0]                 pc;
  IME_OP_e                     op;
  logic                        is_fp;
  logic                        is_mx;
  logic [3:0]                  sew_log2;
  logic [3:0]                  eew_log2;
  logic [3:0]                  w;
  logic [6:0]                  lambda;
  logic [3:0]                  lmul;
  logic [4:0]                  emul_c;
  logic [5:0]                  m;
  logic [5:0]                  n;
  logic [8:0]                  k_eff;
  logic [4:0]                  vs1;
  logic [4:0]                  vs2;
  logic [4:0]                  vd;
  logic                        vm;
  logic                        bs;
  logic                        altfmt_a;
  logic                        altfmt_b;
  logic                        altfmt_c;
  logic [2:0]                  frm;
  logic [31:0]                 read_mask;
  logic [31:0]                 write_mask;
} IME_DESC_t;
```

不要直接把 `lambda[2:0]` 编码当作数值参与乘法；在 DE1 先解码成 one-hot 或实际 `1/2/4/...`。

### VRF 串行读接口

```systemverilog
typedef struct packed {
  logic [4:0] reg_idx;
  logic [1:0] operand;   // A, B, C, SCALE
  logic [4:0] group_idx;
} IME_VRF_RD_REQ_t;

typedef struct packed {
  logic [`VLEN-1:0] data;
  logic [1:0]       operand;
  logic [4:0]       group_idx;
} IME_VRF_RD_RSP_t;
```

接口采用 decoupled valid/ready。DFF VRF 可组合读并在 engine 侧打一拍；若未来 VRF 改为 SRAM，response latency 可参数化，`operand/group_idx` 随 request tag 返回。`imeVrfReadPorts=1` 时按 A→B→C→v0 读取；为 2 时可并行 A/B，C 仍串行。

### Result/commit 接口

```systemverilog
typedef struct packed {
  logic [`ROB_DEPTH_WIDTH-1:0] rob_tag;
  logic                        done;
  logic [4:0]                  fflags;
} IME_DONE_t;

typedef struct packed {
  logic [4:0]       reg_idx;
  logic [`VLEN-1:0] data;
  logic [`VLENB-1:0] strobe;
  logic              last;
} IME_COMMIT_BEAT_t;
```

`done` 只表示 result buffer 已完整，不能直接释放 destination lock。`commit beat` 仅在 ROB 头部 token 匹配且无 trap 时有效；在 `valid && !ready` 时 data/index/strobe/last 必须保持稳定。

## Compute 指令生命周期

![IME 计算指令的生命周期](assets/ime_compute_sequence.png)

### 状态机

| 状态            | 进入条件                  | 动作                                     | 退出条件                |
| --------------- | ------------------------- | ---------------------------------------- | ----------------------- |
| `IDLE`          | reset/上一条退休          | 无有效 slot                              | 合法宏令牌被接受        |
| `WAIT_OLD`      | 已分配 ROB/锁             | 等待 older pending mask 清零             | 依赖清空且 VRF 读口可用 |
| `CAPTURE_A`     | —                         | 读 LMUL 个 A 寄存器                      | 完成                    |
| `CAPTURE_B`     | —                         | 读 LMUL 个 B 寄存器                      | 完成                    |
| `CAPTURE_C`     | —                         | 只读 active C bytes，或首版读完整 EMUL_C | 完成                    |
| `CAPTURE_SCALE` | MX                        | 读 v0                                    | 完成/非 MX 跳过         |
| `COMPUTE`       | 全部输入冻结              | 按 LMUL step、row/col/K slice 调度       | 全部 active output 完成 |
| `FINALIZE`      | compute done              | 生成 byte strobe、fflags、done           | result slot valid       |
| `WAIT_HEAD`     | done                      | 等待匹配 ROB token 到头部                | commit grant            |
| `COMMIT`        | at head                   | 每周期输出最多 N 个 C 寄存器             | last beat accepted      |
| `COMPLETE`      | C/fflags 全接受           | ROB ready、释放锁/slot                   | `IDLE`                  |
| `ABORT`         | pre-commit flush/tag kill | 清 valid，不写 VRF/FCSR                  | `IDLE`                  |

`COMMIT` 一旦开始，不允许在半途接受针对该条指令的异步中断；retire 必须把整个多周期提交视为一个不可分割的 instruction boundary。同步 trap 在 DE1 已解析完，compute datapath 本身不再产生可恢复 exception。

### ROB 扩展

ROB entry 增加最小控制字段：

```systemverilog
logic        is_ime;
logic        ime_done;
logic        ime_slot;       // one inflight 时可省略
logic [31:0] dst_reg_mask;   // 或只在全局 scoreboard 保存
logic [4:0]  ime_fflags;
```

IME entry 不占用现有单 VLEN result memory。execution 完成时只回写 `ime_done/fflags`；C data 留在 result buffer。ROB 头部输出 `is_ime/rob_tag/slot` 给 retire。retire 在最后 commit beat 前保持 `rt2rob_write_ready=0`，防止 token 被提前 pop。

### Flush 与 tag

- result slot、RS、fetch FSM、compute FSM 都保存 ROB tag；
- backend flush 时广播 `flush_valid` 和边界 tag/全清语义；
- 未进入 commit 的 slot 直接清 valid；
- commit 仅可由当前 ROB head 驱动，因此正常情况下不会出现“已写部分 C 后又被较老 trap flush”；
- assertion 必须证明任意 VRF IME write 均满足 `rob_head_valid && rob_head_is_ime && tag_match && !trap`；
- debug halt 应等待 `ime_commit_busy=0`，并按核心现有 halt boundary 规则处理正在 compute 的非重启指令。

## Compute datapath

![IME 面积优先 outer-product 数据路径](assets/ime_compute_datapath.png)

### Dataflow 选择

选用 outer-product 调度。对每个 K slice，读取 A 的一列和 B 的同一列，广播到 `P_M×P_N` 个 output accumulator：

$$
C_{m,n}\leftarrow C_{m,n}+\sum_{k=k_0}^{k_0+P_K-1}A_{m,k}B_{n,k}
$$

其优势是：

- B 在寄存器中按行主序保存，而计算为 `A×Bᵀ`，同一 k 的 B[n][k] 可直接按行选择；
- C tile 在 VLEN=128/SEW32 时最大仅 4×4，适合少量本地 accumulator；
- `P_M/P_N/P_K` 可独立参数化，ISA tile 无需随物理阵列改变；
- LMUL step 顺序自然，不跨 LMUL=1 边界，便于后续 FP grouping；
- 不需要复用 ZVT 的 16×16 专用 accumulator 阵列。

### 推荐首版 datapath

`IME_EDGE_I8_REC`：

| 属性                 | 值                                                           |
| -------------------- | ------------------------------------------------------------ |
| C 类型               | INT32                                                        |
| A/B 类型             | INT8 或 UINT8，独立符号                                      |
| W                    | 4                                                            |
| λ                    | 1、2                                                         |
| `P_M×P_N`            | 4×4 accumulator                                              |
| `P_K`                | 1                                                            |
| 乘法器数             | 16 个 8×8 signed-capable multiplier                          |
| accumulator          | 16 个 32-bit modulo accumulator                              |
| A/B buffer 最大      | 各 `8×VLEN=1024 bit`                                         |
| C result buffer 最大 | `16×VLEN=2048 bit`，但首版 SEW32 λ∈{1,2} 最大只需 4×VLEN     |
| schedule             | λ=1：4 K cycles/LMUL step；λ=2：8 K cycles/LMUL step，M/N 为 2 |

为了支持 signed×unsigned 与 unsigned×unsigned，乘法器输入可统一扩展至 9 bit：

```systemverilog
a_ext = altfmt_a ? {1'b0, a[7:0]} : {a[7], a[7:0]};
b_ext = altfmt_b ? {1'b0, b[7:0]} : {b[7], b[7:0]};
prod  = $signed(a_ext) * $signed(b_ext);
```

累加只保留低 `SEW` 位，即实现模 `2^SEW`。形式验证需覆盖所有四种符号组合和最大负数/最大无符号数。

### 调度计数器

推荐嵌套次序：`lmul_step → m_block → n_block → k_slice`。近似 compute 周期：

$$
C_{compute}=LMUL\times
\mathrm{ceil}(M/P_M)\times
\mathrm{ceil}(N_{tile}/P_N)\times
\mathrm{ceil}(\lambda W/P_K)+C_{pipe}
$$

capture 周期近似：

$$
C_{capture}=\mathrm{ceil}((2LMUL+EMUL_{C,read}+MX)/P_{vrf})
$$

commit 周期：

$$
C_{commit}=\mathrm{ceil}(EMUL_C/P_{commit})
$$

上述公式用于架构建模，不代替 cycle-accurate RTL 计数；实际还需加入 RS、VRF response、result arb 和 retire backpressure。

### C seed 与 tail strobe

首版允许读取完整 `EMUL_C`，但只把 active C 元素装入 accumulator；tail lane 不读或读后不使用。结果 strobe 由二维坐标生成：

```systemverilog
active_c = (row < M) && (col < N_tile);
byte_en  = active_c ? {SEW/8{1'b1}} : '0;
```

推荐无论 `vta` 值均对 tail 使用 `byte_en=0`。这样不会泄漏未初始化 internal result，也使波形与软件检查稳定。

### Buffer 组织

- A/B buffer 按“寄存器号 × VLEN”存储，unpack 时用 `(row,k)` 映射到 bit offset；
- C/result buffer 按 C 线性 storage element 排列，并维护每个 VLEN chunk 的 byte strobe；
- data array 不需要 reset，只 reset `valid/dirty/index/tag`；
- 若只实现 `SEW32 λ{1,2}`，综合参数应把 result storage 缩到最大 4×VLEN，而不是保留完整 16×VLEN；
- 后续扩展多在途 IME 时，每个 slot 必须独立持有 tag、descriptor、C、fflags 和 commit index。

### FP 扩展策略

FP 不应通过简单复用普通 vector FMA lane 就宣告完成，因为 IME 还要求 grouping、partial sum 和格式组合。建议：

1. 先实现 FP16/BF16→FP32，`psm=0`，固定合法 G，`rnd=xct` 或 `rto`；
2. partial products 在 group 内精确累加到足够宽的 fixed-point/ Kulisch-like 中间表示，group 结束再规范化；
3. final C add 使用 `frm`，收集 NV/DZ/OF/UF/NX；
4. result buffer 保存 5-bit fflags，commit 最后一个 C beat 时与 FCSR 握手；
5. OFP8/OFP4/MX 单独启用 converter、scale 和 NaN shortcut，不让它们出现在 integer-only netlist 中；
6. 每个支持的 `(SEW,W,λ)` 在软件可读设计文档或 discovery 表中披露 `(G,psm,rnd)`。

## Result buffer 与架构提交

### Result buffer 内容

```systemverilog
typedef struct packed {
  logic                         valid;
  logic [`ROB_DEPTH_WIDTH-1:0]  rob_tag;
  logic [4:0]                   base_vd;
  logic [4:0]                   reg_count;
  logic [4:0]                   commit_idx;
  logic [4:0]                   fflags;
  logic [IME_MAX_C_REGS-1:0][`VLEN-1:0]  data;
  logic [IME_MAX_C_REGS-1:0][`VLENB-1:0] strobe;
} IME_RESULT_SLOT_t;
```

若 profile 的最大 `EMUL_C<16`，`IME_MAX_C_REGS` 必须由生成参数缩小。buffer 的 `data` 不 reset；slot valid 清零即可。

### Commit 流程

1. ROB 头部 entry 为 IME 且 `ime_done=1`；
2. retire 比较 `rob_tag` 与 result slot tag；不匹配是 fatal assertion；
3. `ime_commit` 从 `commit_idx` 起每周期提供最多 `min(IME_COMMIT_PORTS, remaining)` 个 C register write；
4. 写地址为 `base_vd+commit_idx+lane`，data/strobe 来自 result slot；
5. retire 把这些 beat 复用到现有 `RT2VRF_t`，并阻止同周期更年轻 ROB entry 退休，以保持简洁的 WAW 优先级；
6. 最后一拍同时提交 fflags；若 FCSR backpressure，则 VRF 最后一拍和 fflags 应作为同一个握手条件，避免重复写/漏写；
7. 最后一拍被接受后，下一时钟沿允许 ROB pop、清 result valid、释放 C lock；
8. `rvv_idle` 必须额外包含 `!ime_busy && !ime_commit_busy && !ime_tls_busy`。

### 原子性边界

这里的“原子提交”指从指令退休与异常可见性的角度，一条 IME compute 不会被较老 trap 切断，也不会允许较年轻指令在部分 C 更新后读取；并不要求 VRF 的 16 个寄存器在同一个物理周期同时翻转。多周期 commit 期间：

- ROB head 不移动；
- destination lock 不释放；
- 不接受 interrupt/debug retirement boundary；
- 普通 execute 可以继续，但所有新结果仍停留在 ROB；
- 若实现要求最简单，可在 commit 期间冻结全部 RVV dispatch，持续时间最多 `ceil(EMUL_C/4)` 周期。

### VRF 写仲裁

建议由 `rvv_backend_retire.sv` 生成最终 `rt2vrf_write_*`，而不是让 IME engine 直接写 VRF。这样保留：

- 现有 byte-strobe merge；
- 同周期多写 WAW 规则；
- trace/RVVI 退休观察点；
- FCSR/vxsat 等 side effect 的共同 ready；
- VRF 写端口的单一所有权。

## Tile load/store 微架构

### 与 compute 的分工

tile memory 指令可能在任意 active element fault，并通过 `vstart` 恢复，因此不能使用“全部结果完成后一次提交”的 compute 模型。推荐复用普通 RVV memory 指令的 uop/ROB/LSU 语义：DE2 把一条 tile memory 指令拆成若干 segment uop，每个 uop 携带全局 element base；LSU 内部按 element 递增发 request，并在 fault 时回报精确 index。

### TLS descriptor

```systemverilog
typedef struct packed {
  logic [`ROB_DEPTH_WIDTH-1:0] rob_tag;
  logic                        is_load;
  logic                        transpose;
  logic                        masked;
  logic [4:0]                  vreg_base;
  logic [4:0]                  lmul;
  logic [6:0]                  lambda;
  logic [6:0]                  linesize;
  logic [7:0]                  sew_bytes;
  logic [VL_W-1:0]             vl;
  logic [VL_W-1:0]             vstart;
  logic [XLEN-1:0]             base_addr;
  logic [XLEN-1:0]             ld_elements;
  logic [VL_W-1:0]             elem_base;
  logic [VL_W-1:0]             elem_count;
} IME_TLS_DESC_t;
```

### Uop 切分

推荐一个 segment uop 对应一个 destination/source VLEN chunk，最多 LMUL=8 个 uop，适配现有 ROB depth=8。每个 segment 包含 `elem_base` 和该 chunk 的最大 element count：

- load result 使用现有 ROB 单 VLEN data + byte strobe；
- inactive/tail bytes 的 strobe 强制 0，VRF 原值自然保持；
- store 不产生 VRF result，但必须保存 fault element index；
- `last_uop` 标识 instruction boundary，禁止在同一 tile 指令中间接受 interrupt；
- 若现有 LSU uop 已更细，可沿用更细切分，但所有 uop 的 instruction id 和全局 element index 必须明确。

当一条 tile load 的 LMUL=8 占满 ROB 时，dispatch 应保证其所有 uop 能连续进入或提供部分入队的无死锁证明。最保守实现是在 DE2 开始发 TLS uop 前等待 ROB/UQ 有足够空间。

### 地址生成器

地址生成器维护 `i`，只对 `i∈[vstart,VL)` 且 mask bit=1 的元素发请求。可用商/余数的 bit slicing 代替除法，因为 `linesize=λ×LMUL` 是 2 的幂：

```systemverilog
row = i >> log2_linesize;
col = i & (linesize - 1);

if (!transpose)
  elem_offset = row * ld_elements + col;
else
  elem_offset = col * ld_elements + row;

byte_addr = base_addr + elem_offset * sew_bytes;
```

`ld_elements` 是 rs2 值；为零时在 issue 前替换为规范默认值。乘法 `row*LD`/`col*LD` 可复用 LSU AGU 乘加、使用迭代加法，或按 PPA profile 实现小乘法器；需要通过时序综合选择。

### Mask 与 tail

- `i<vstart`：prestart，不读 v0、不访问 memory、不写 destination；
- `i>=VL`：tail，不访问 memory；load 不写 destination；
- masked 且 v0[i]=0：inactive，不访问 memory；load 不写 destination；
- masked load 的 destination group 与 v0 重叠在 DE1 判 illegal；
- load strobe 仅覆盖已成功返回的 active element；
- faulting element及之后元素不得产生 destination write；允许在总线中存在的 speculative request 必须被禁止或保证其异常/写回被 kill。

### Fault 与 vstart

`REQ-TLS-FAULT-001`：每个 memory request 携带全局 element index `i`，response/fault 必须返回同一 tag。

`REQ-TLS-FAULT-002`：若第 i 个 active element fault，写 `vstart=i`，触发该 instruction 的 trap；已经退休的更早 segment 保持，faulting segment 中仅更早成功元素可通过 byte strobe 保持。

`REQ-TLS-FAULT-003`：正常完成最后 active element后，退休 side effect 把 `vstart` 清零。

`REQ-TLS-FAULT-004`：重启从当前 `vstart` 开始，不得再次访问 prestart 元素。store 场景尤其必须通过 bus monitor 验证没有重复的早期写。

### Burst/coalescing

优化是可选的，不影响架构：

- order-preserving 且连续列可合并为最长不越过 cacheline/总线边界的 burst；
- transposing 通常是 strided request，首版可逐 element；
- burst 内仍需保留每个 element 的 fault/tag 映射；若总线只报告 beat fault，可令每 beat 对应单个 SEW element；
- masked/tail gap 不得被包含在可能产生异常的 memory transaction 中。

## 异常、interrupt、debug 与恢复

### Compute illegal instruction

所有确定性非法条件必须在 DE1/DE2 进入 execution 前报告。illegal instruction 不分配 IME slot、不设置 group lock、不读取 VRF，也不改变 fflags/vstart。

### Compute runtime exception

integer compute 没有数据相关 trap。FP 的 IEEE 异常只更新 fflags，不触发同步 trap。故 compute 一旦通过 legality，可安全运行至 result done；任何较老 trap 的 flush 都能丢弃瞬态状态。

### Interrupt

- compute 指令不可重启，因此 interrupt 只能在其完整 retirement boundary 之前或之后进入；
- 等待 ROB head/commit 时，该宏令牌仍是未退休指令；
- tile load/store 可通过 vstart 重启，但仍遵守基础 V 规范关于 element 级 trap 的边界；
- performance watchdog 不应把长 IME compute 误判为 backend hang。

### Debug halt

建议 precise halt：debug 请求到达后停止接受新指令，允许较老指令和当前不可重启 IME compute 走到安全 retirement boundary，再拉起 halted。若产品要求立即 halt，则必须保存完整 internal IME state；首版不建议该模式。

### Flush 清理表

| 状态                       | flush 动作                            | 允许的架构影响                            |
| -------------------------- | ------------------------------------- | ----------------------------------------- |
| IME RS                     | clear valid                           | 无                                        |
| operand fetch              | cancel request；丢 rsp                | 无                                        |
| A/B/C/v0 buffer            | clear slot valid                      | 无                                        |
| PE/accumulator             | clear active/valid                    | 无                                        |
| result buffer（未 commit） | clear valid                           | 无                                        |
| destination/read locks     | 按 killed tag 清除                    | 无                                        |
| TLS pending request        | kill 或抑制回写；遵守总线不可取消规则 | 仅规范允许的已完成较早 memory side effect |
| commit 中                  | 正常设计不应被较老 trap 命中；assert  | 已提交写属于当前 ROB head                 |

## Reset、时钟、功耗与 DFT

### Reset

- 所有控制 valid、FSM state、tag valid、lock mask、pending flag 复位为 0；
- A/B/C/result data array 不复位，避免 reset tree 和面积；
- vtype 的 IME 高位字段在 reset 或 vill 时读为 0；
- `IME_ON=0` 时所有 IME 输出 tie-off：busy=0、decode_hit=0、VRF/LSU request valid=0；
- reset 释放后在没有合法 IME 指令前，任何未复位 datapath bit 都不得影响可见输出。

### Clock gating

建议：

```systemverilog
ime_clk_en = ime_rs_valid |
             ime_fetch_busy |
             ime_compute_busy |
             ime_result_valid |
             ime_commit_busy |
             ime_tls_busy;
```

大 buffer 进一步使用 operand-level write enable。PE array 仅在 `COMPUTE` 状态翻转；FP/MX 子路径用 feature constant 先综合裁剪，再在启用 profile 中局部 gate。

### Power isolation

若 SoC 实现把 IME 放入独立 power domain：

- 因无架构状态，不要求 retention；
- 只允许在 `rvv_idle && !ime_busy` 时关电；
- isolation clamp 所有 valid 为 0、busy 根据 power manager protocol 处理；
- 唤醒后按 reset 路径清控制状态。

### DFT

- result/operand buffer 可用 scan DFF 或小 SRAM MBIST，取决于实例化；
- clock-gate 必须提供 scan enable bypass；
- 不复位 data array 需要 ATPG 约束 valid=0；
- PE multiplier 的结构测试可复用 ATPG，不需要架构 CSR 可见性。

## 性能与 PPA 模型

### 端到端延迟

一条无争用 compute 指令的近似延迟：

$$
L_{IME}=L_{front}+C_{wait\_old}+C_{capture}+C_{compute}+C_{final}+C_{wait\_head}+C_{commit}
$$

性能模型必须分别报告：

- execution latency：从 IME RS accept 到 result done；
- retirement latency：从 dispatch 到 ROB pop；
- throughput：连续无依赖 IME 指令的间隔；
- useful MAC/cycle：只统计 active `M×N_tile×K_eff`；
- VRF capture/commit 占用周期；
- 因 group conflict、ROB head、VRF port、LSU 产生的 stall 周期。

### 推荐性能计数器

| 计数器                    | 含义                              |
| ------------------------- | --------------------------------- |
| `ime_inst_retired`        | 成功退休 compute 指令数           |
| `ime_tls_retired`         | 成功退休 tile memory 指令数       |
| `ime_active_cycles`       | IME 非 idle 周期                  |
| `ime_compute_cycles`      | PE 实际工作周期                   |
| `ime_capture_stall`       | 等 older/VRF read port            |
| `ime_group_hazard_stall`  | group mask 冲突导致 dispatch 停顿 |
| `ime_wait_rob_head`       | result done 后等待提交            |
| `ime_commit_cycles`       | 多寄存器提交周期                  |
| `ime_tls_faults`          | tile memory fault 数              |
| `ime_illegal_by_reason[]` | 可选仿真/bring-up 计数            |

### 面积构成

不在 RTL 规格中给出未经综合的百分比。综合报告至少分解：

- 乘法器/FP converter/rounder；
- accumulator 与 result buffer；
- A/B capture buffer；
- VRF 新读 mux 与布线；
- group scoreboard/descriptor/控制；
- TLS address multiply/queue；
- clock tree 增量。

必须使用同一 PDK、约束、retiming、clock gating 设置比较 `BASE_RVV`、`IME_EDGE_I8_MIN`、`IME_EDGE_I8_REC` 和 `IME_EDGE_I8_TLS`。对 `enableIme=false` 还要进行 netlist 结构 diff，确认无 IME 存储和 datapath 残留。

## RTL 文件改造建议

### Chisel/构建层

| 文件                                       | 修改                                                       |
| ------------------------------------------ | ---------------------------------------------------------- |
| `hdl/chisel/src/coralnpu/Parameters.scala` | 增加 `ImeParameters`、合法组合 `require`、profile          |
| `Core.scala`                               | wrapper 参数/端口只在 enableIme 时生成                     |
| `rvv/RvvInterface.scala`                   | config、command 所需 IME 字段                              |
| `rvv/RvvDecode.scala`                      | OP-V IME 与 width=111 tile memory 识别                     |
| `rvv/RvvCore.scala`                        | 传递 feature table，生成 `IME_ON`                          |
| build rules/configs                        | 增加 IME variants、extension manifest、lint/formal targets |

### 现有 SystemVerilog

| 文件                               | 修改                                             |
| ---------------------------------- | ------------------------------------------------ |
| `rvv_backend_define.svh`           | IME 参数、port counts、最大 buffer 尺寸          |
| `rvv_backend.svh` / opcode package | `IME_DESC_t`、ROB/dispatch/result 字段           |
| `RvvFrontEnd.sv`                   | vtype WARL、IME snapshot、decode routing         |
| DE1/DE2 decode modules             | geometry、legality、compute macro/TLS uop        |
| `rvv_backend_dispatch*.sv`         | group masks、IME read/write locks、RS routing    |
| `rvv_backend_rob.sv`               | `is_ime/done/slot` token                         |
| `rvv_backend_retire.sv`            | multi-cycle IME commit、fflags handshake         |
| `rvv_backend_vrf*.sv`              | IME decoupled read口与仲裁；写口保持 retire 所有 |
| LSU/remap modules                  | TLS metadata、element index、fault→vstart        |
| `rvv_backend.sv`                   | 实例化、arb、flush、`rvv_idle`                   |

### 新增 SystemVerilog

```text
hdl/verilog/rvv/design/ime/
├── ime_pkg.svh
├── ime_lambda_warl.sv
├── ime_geometry.sv
├── ime_legal.sv
├── ime_group_scoreboard.sv
├── ime_rs.sv
├── ime_operand_fetch.sv
├── ime_unpack.sv
├── ime_pe_array.sv
├── ime_accum_int.sv
├── ime_accum_fp.sv             [FP]
├── ime_scale.sv                [MX]
├── ime_result_buffer.sv
├── ime_commit.sv
├── ime_tls_addrgen.sv          [TLS]
├── ime_tls_uopgen.sv           [TLS]
├── ime_tls_fault_tracker.sv    [TLS]
└── ime_subsystem.sv
```

### ZVT/VME 可复用边界

可参考：

- optional build/define plumbing；
- RS→专用 execution unit 的 valid/ready 接入；
- backend flush、busy、idle 汇总；
- LSU 旁路通道和 FIFO coding style；
- PE multiplier 的局部算术实现和 clock gating 手法。

不得直接复用：

- ZVT 专用 accumulator 作为架构 C；
- ZVT `mset`/mtype CSR 作为 IME vtype；
- 固定 16×16 tile 几何；
- 不带 ROB token 的写回；
- 只按单个 `vd/vs1/vs2` 做 hazard 的控制；
- 任何未覆盖 IME `vstart/tail/MX/fflags` 的 LSU/PE 语义。

从面积角度，当前 ZVT 16×16 PE 与多组专用 accumulator 对 VLEN=128、SEW32 的最大 4×4 C tile 明显过宽。首版应实例化独立的小型参数化 IME engine；若后续产品要求同时支持 ZVT 与 IME，可再评估共享 multiplier lane，而不是共享架构存储。

## RTL 编码要求

- 所有跨模块 bundle 使用 `typedef struct packed`，禁止相同 bit vector 在多个文件手工切片；
- 所有 feature constant 由生成 package 单源产生；
- top-level 使用少量 `generate if (IME_ENABLE_*)`，模块内部以 parameter constant 优化，避免散布嵌套 `ifdef`；
- valid/ready 接口必须满足 backpressure 数据稳定；
- counter 宽度由最大合法 geometry 推导，并对最后值显式比较；
- group mask、index 加法先扩位，检查 overflow 后再截断；
- signed/unsigned 乘法在 operand 扩展处显式 `$signed`，禁止依赖上下文隐式符号；
- tail/mask write enable 在数据写口前最后一级再次 gating；
- datapath data array 不 reset，valid/control 必须 reset；
- 每个 FSM 有 default safe assignment、illegal state recovery 和 onehot/gray assertion；
- lint 不允许 inferred latch、宽度截断、未使用 IME 信号在关闭 profile 中残留。

## 验证策略

### Reference model

建立独立于 RTL 调度的 architectural model，输入为 instruction、VRF、vtype、VL/vstart、memory、frm，输出为 VRF/memory/fflags/vstart/trap。优先从规范 SAIL 伪代码派生，并对每个实现 type cell 固化版本 hash。

Scoreboard 比较点是 instruction retirement，而不是 PE 内部每周期。compute 宏令牌需比较整个 C group；tile memory fault 需比较 partial destination/memory 和 `vstart`。

### 单元验证

| DUT                     | 关键场景                                                     |
| ----------------------- | ------------------------------------------------------------ |
| `ime_lambda_warl`       | 000 preserve/init、向下 clamp、无更小值时取最小、SEW 切换、vill/reset |
| `ime_geometry`          | 所有 VLEN128 合法/非法 λ、VL multiple、EMUL_C、group overflow |
| `ime_legal`             | 每个 reason 独立触发；feature/type cell negative tests       |
| `ime_group_scoreboard`  | RAW/WAR/WAW、self overlap、capture 后释放 read lock、flush   |
| `ime_unpack`            | INT4 nibble、INT8/16、四种符号组合、FP alternate formats     |
| `ime_pe_array`          | 随机 dot product、wrap、参数化边界                           |
| `ime_result_buffer`     | tag、tail strobe、backpressure、flush、最大 EMUL_C           |
| `ime_commit`            | 1/2/4/8/16 regs、4 ports、FCSR stall、ROB head change        |
| `ime_tls_addrgen`       | 两种公式、默认/显式 LD、mask/tail/prestart、地址 overflow    |
| `ime_tls_fault_tracker` | 每个 element fault、重启不重复、load partial strobe          |

### 指令级 directed tests

- λ、LMUL、VL、N_tile 的笛卡尔覆盖；
- `vd/vs1/vs2` 无重叠、两两重叠、完全重叠；
- C group 位于 v0、v16、v28 等边界以及越过 v31 的 negative case；
- signed×signed、signed×unsigned、unsigned×signed、unsigned×unsigned；
- 零、全 1、最大正/负、溢出 wrap、交替 bit pattern；
- C tail 列在 `vta=0/1` 下均验证未写推荐行为；
- `vstart!=0` compute illegal；
- 每条 unsupported instruction/type cell/λ 都必须 illegal；
- back-to-back IME、IME→普通 vector、普通 vector→IME 的依赖；
- ROB 中存在较老长延迟 MUL/LSU、较年轻无关指令时的 overlap；
- trap/branch flush 分别命中 WAIT_OLD、CAPTURE、COMPUTE、WAIT_HEAD；
- commit backpressure 和 debug halt 请求；
- TLS/TTLS 每个 active index fault、mask gap、tail、rs2=0/非零；
- FP 后续阶段覆盖 ±0、subnormal、∞、qNaN/sNaN、overflow/underflow/inexact 和 scale `0xff`。

### 随机与差分

- constrained-random 生成合法/非法 descriptor，与 SAIL/reference model 差分；
- 随机插入普通 RVV/scalar 指令、ROB backpressure、LSU latency、flush；
- memory model 支持按 element 注入 access/page/bus fault；
- 对相同 architecture input，以 `P_M/P_N/P_K` 不同的多个 profile 运行，结果必须相同；
- integer 结果应与任意 K grouping 无关；FP 结果按披露 `(G,psm,rnd)` 比较。

### 形式断言

建议至少包括：

```systemverilog
// Disabled-feature non-interference
assert property (!IME_ON |-> !ime_vrf_wr_valid && !ime_lsu_req_valid);

// No architectural write before ROB-head commit
assert property (ime_vrf_wr_valid |->
                 rob_head_valid && rob_head_is_ime &&
                 (ime_commit_tag == rob_head_tag) && !rob_head_trap);

// Backpressure stability
assert property (ime_commit_valid && !ime_commit_ready |=>
                 $stable(ime_commit_beat));

// Tail never written in the recommended undisturbed implementation
assert property (ime_commit_valid |->
                 ((ime_commit_strobe & ime_tail_byte_mask) == '0));

// Flush kills all non-architectural IME state
assert property (flush_all |=>
                 !ime_rs_valid && !ime_result_valid &&
                 (ime_read_lock_mask == '0) && (ime_write_lock_mask == '0));

// A completed token cannot retire before the final write is accepted
assert property (rob_head_is_ime && !ime_commit_last_fire |->
                 !rob_head_pop);
```

还需证明：group mask 不越界、同一 result slot 唯一 tag、同一 C register 不在同周期被两个来源写、read lock 仅在 capture 完成后释放、TLS inactive 元素从不发 request、fault 返回的 `vstart` 等于 request element tag。

### 覆盖率

功能覆盖 cross 至少包括：

- `op × SEW × W × λ × LMUL × N_tile`；
- `altfmt_A × altfmt_B`；
- overlap class × dependency stall reason；
- state-at-flush × result-valid；
- `EMUL_C × commit_backpressure`；
- TLS transpose × LD-default × mask × fault-index-position；
- FP format A × format B × format C × frm × exception flags；
- 每个 individual extension 的 legal hit 和 unsupported illegal hit。

代码覆盖豁免必须按 feature profile 分离；不能用 `IME_ENABLE_FP=0` 的不可达代码拉低 integer profile 覆盖，也不能以编译裁剪为由跳过 feature-on 的负例。

### Baseline 等价

`enableIme=false` 的签核包括：

- elaborated port/interface 与 baseline wrapper 兼容，或由明确的 wrapper adapter 保持兼容；
- 现有 RVV regression bit-for-bit 通过；
- 形式 sequential equivalence，排除允许的 instance/name 差异；
- netlist 中无 `ime_*` state element、multiplier、buffer 或 clock gate；
- timing/PPA 差异仅来自工具随机性和必要的 top-level constant，不接受功能路径退化。

## 需求追踪

| 需求 ID                  | 规范来源                    | RTL 责任模块                 | 主要验证                  |
| ------------------------ | --------------------------- | ---------------------------- | ------------------------- |
| `REQ-ARCH-001`           | 36.2/36.5                   | VRF、IME subsystem           | 架构 state audit          |
| `REQ-GEO-001`            | 36.2                        | `ime_geometry`               | exhaustive table/formal   |
| `REQ-CFG-001`            | 36.4.1–36.4.2               | `ime_lambda_warl`、front end | WARL directed/formal      |
| `REQ-PACK-001`           | 36.5.1                      | `ime_unpack`                 | nibble/byte patterns      |
| `REQ-INT-001`            | 36.6/36.13.2                | decode、PE                   | type-cell differential    |
| `REQ-FP-001`             | 36.7                        | FP accum                     | SAIL + special values     |
| `REQ-MX-001`             | 36.7.3/36.12/36.13.3        | scale/FP/legal               | scale/block/NaN tests     |
| `REQ-TAIL-001`           | compute descriptions        | result strobe                | column-tail assertions    |
| `REQ-EXC-001`            | 36.11 compute               | legal/ROB/commit             | vstart/flush tests        |
| `REQ-TLS-001`            | 36.8                        | TLS addrgen/LSU              | address differential      |
| `REQ-TTLS-001`           | 36.9                        | TLS addrgen/LSU              | transpose differential    |
| `REQ-TLS-FAULT-001..004` | tile instruction exceptions | LSU/fault tracker            | fault injection           |
| `REQ-PARAM-001`          | 项目要求                    | Chisel/build/SV generate     | config matrix/equivalence |

## 实施阶段与入口/出口条件

### 阶段 A：规范冻结与生成表

交付：type-cell manifest、λ mask、encoding 表、geometry/reference model。退出条件：ISA/DV/RTL 对所有首版 legal/illegal case 达成一致。

### 阶段 B：decode、vtype、geometry

交付：Chisel/SV config、WARL、DE1 legality、负例测试。退出条件：不实例化 PE 也能在仿真中正确识别并拒绝/接收全部指令。

### 阶段 C：integer compute MVP

交付：single-token RS、capture、4×4×1 INT8 engine、result buffer、commit、group lock。退出条件：`Zvvi8i32mm` directed/random/formal 通过；所有 flush 状态无可见写。

### 阶段 D：TLS/TTLS

交付：width111 decode、addrgen、uopgen、fault/vstart。退出条件：每个 element fault injection 与重启测试通过，无 inactive memory access。

### 阶段 E：性能与 PPA

交付：profile matrix、综合/STA/power、计数器、软件 microbenchmark。退出条件：达到项目设定的面积/频率门槛；未达到时通过 `P_M/P_N/P_K/VRF ports` 调参，不改变 ISA。

### 阶段 F：FP/MX

交付：格式 converter、披露表、SAIL model、fflags/MX。退出条件：每个宣告 extension cell 完整通过 special-value 与随机差分；未完成前保持 feature bit/manifest 关闭。

## 评审待决项

以下项目必须在 RTL freeze 前由对应 owner 决策：

| ID        | 待决项                                   | 建议                                  | Owner     |
| --------- | ---------------------------------------- | ------------------------------------- | --------- |
| `OPEN-01` | 首版是否包含 TLS/TTLS                    | compute bring-up 后立即加入，独立参数 | 架构/软件 |
| `OPEN-02` | `P_M/P_N/P_K` 与目标频率                 | 先综合 2×2×1、4×4×1、4×4×2            | PPA/RTL   |
| `OPEN-03` | VRF 专用读口 1 或 2                      | 面积优先 1；性能数据后决定 2          | PPA       |
| `OPEN-04` | IME 等待 older 时是否要求 ROB 完全 drain | 用 mask 等相关写退休，不要求全 drain  | RTL/DV    |
| `OPEN-05` | commit 期间是否允许普通 RVV dispatch     | 初版可冻结，后续放开无冲突流          | RTL       |
| `OPEN-06` | debug halt 的最大等待时延                | precise boundary，不保存内部执行状态  | Debug/SoC |
| `OPEN-07` | FP 首个 `(G,psm,rnd)`                    | `psm=0`，`rnd=xct/rto` 二选一         | FP 架构   |
| `OPEN-08` | VME 与 IME 是否允许同时构建              | 允许但资源独立；共享留到 PPA 证据后   | 产品/RTL  |

## Sign-off 清单

### 架构

- [ ] 所有宣告 extension 与 `imeTypeCellMask` 一致；
- [ ] λ WARL、immediate λ、vtype reset/vill 行为核对完成；
- [ ] C tail、A/B/C overlap、MX v0 overlap 规则核对完成；
- [ ] FP profile 的 `(G,psm,rnd)` 已披露并冻结。

### RTL

- [ ] `IME_ON=0` 无功能/时序/面积残留；
- [ ] compute 单 ROB token，最大 `EMUL_C` 可提交；
- [ ] 任何 flush 点均无未授权 VRF/FCSR write；
- [ ] result/operand data array 无 reset，valid/control reset 完整；
- [ ] `rvv_idle`、debug halt、clock gating 已纳入 IME busy；
- [ ] lint/CDC/RDC/DFT clean。

### DV/Formal

- [ ] reference model 版本绑定到 spec revision；
- [ ] geometry/type-cell 全覆盖；
- [ ] group RAW/WAR/WAW、overlap、flush 全覆盖；
- [ ] TLS 每个 element fault 与 restart 全覆盖；
- [ ] commit backpressure/fflags 原子性断言通过；
- [ ] baseline sequential equivalence 通过。

### 软件

- [ ] extension discovery/manifest 与硬件一致；
- [ ] context switch 仅保存标准 VRF/vtype/vstart/FCSR，无额外矩阵状态；
- [ ] intrinsic/assembler 对 immediate λ 和 type cell 编码一致；
- [ ] C `EMUL_C=16` 的软件 pair/unpair 策略已验证；
- [ ] tile memory layout、LD 默认值与 4-bit packing 文档化。

## 结论

CoralNPU 增加 IME 的关键不是再挂接一个矩阵乘法阵列，而是把多寄存器 tile 的依赖、非重启 compute、可重启 tile memory、vtype WARL 与按序精确提交正确嵌入现有 RVV 后端。本文选择“宏令牌 + 组掩码 + 瞬态结果缓冲 + ROB 头部串行提交”，在不增加架构状态的前提下解决 `EMUL_C=16` 与现有 ROB/VRF 接口的矛盾；同时以独立 feature 参数把首版 INT8 能力和后续 FP/MX/TLS 演进隔离。

建议先以 `IME_EDGE_I8_REC` 完成端到端闭环：`Zvvi8i32mm`、SEW32、λ={1,2}、单在途、4×4×1 outer-product engine。待 legality、hazard、flush、commit 和差分验证稳定后，再分别开启 TLS/TTLS、更多 integer type cell 与 FP/MX。这个顺序能把 ISA 正确性风险与算术/PPA 风险解耦，也能确保每个阶段只宣告真正完整实现的扩展。

## 参考资料

- 所附 `20260629-Zvvm-IME-riscv-unprivileged-605-730-Zvvm-IME(3).pdf`，Chapter 36，Draft 0.1。
- [Google CoralNPU 官方仓库](https://github.com/google-coral/coralnpu)，本文基线 commit `e634f91a2aba8fcecd66436699a502e2062d5400`。
- [CoralNPU Parameters.scala](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/chisel/src/coralnpu/Parameters.scala)。
- [CoralNPU RVV backend](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/rvv_backend.sv)。
- [CoralNPU RVV VRF](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/rvv_backend_vrf.sv)。
- [CoralNPU RVV ROB](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/rvv_backend_rob.sv)。
- [CoralNPU ZVT top](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/Zvt/zvt.sv) 与 [ZVT accumulator](https://github.com/google-coral/coralnpu/blob/e634f91a2aba8fcecd66436699a502e2062d5400/hdl/verilog/rvv/design/Zvt/zvt_acc.sv)，仅作为实现参考。