# CoralNPU IME 芯片微架构设计参考

> 文档状态：**Design Reference Candidate / P0-P1 可实施基线**  
> 面向读者：CPU、向量处理器、RTL、验证、形式验证、综合与软件工具链工程师  
> 文档版本：0.1  
> 日期：2026-07-18  
> 仓库基线：`66bbcd3226d5f65e02fb38ac188268038020d589`  
> IME 规范输入：`20260629-Zvvm-IME-riscv-unprivileged-605-730-Zvvm-IME.pdf`  
> IME PDF SHA-256：`c0d25144279b1790cb285d3598e8207005ba9dfc9c24cb5aa00c7d1838829307`  
> RISC-V 参考规范：`riscv-spec-inter20260710.pdf`  
> RISC-V PDF SHA-256：`04499fadf0a8c3d55a73543ed4c38bf6a6c9e1a2e4f3ed23c1d4c81867e81f7c`

---

## 1. 文档用途与约束语言

本文是 CoralNPU 实现 IME（Integrated Matrix Extension）时的芯片设计参考，覆盖：

1. IME 架构语义与首发产品子集；
2. scalar core（源码模块名 `SCore`）的 decode、顺序、异常、CSR 与退休修改；
3. RVV frontend/backend、VRF、执行单元和提交路径修改；
4. 可配置 elaboration、接口、状态机、复位、flush、验证与签核要求；
5. 不能从当前规范或平台事实中唯一确定的事项及其关闭条件。

本文不是“RTL 已经正确”的声明。只有实现、独立参考模型、断言、回归、形式验证和综合检查全部通过后，某个 profile 才能转为 `IMPLEMENTED` 或 `RELEASED`。

全文采用以下标签，禁止混用：

| 标签 | 含义 | 变更权限 |
| --- | --- | --- |
| `[SPEC]` | 由本文锁定的 IME/RISC-V 规范决定 | 只能随规范基线变更 |
| `[DECISION]` | CoralNPU 项目为消除实现歧义而冻结的设计选择 | 需架构评审/ADR |
| `[SOURCE]` | 当前仓库源码事实 | 源码变化后必须复核 |
| `[OPEN]` | 现有输入不足以唯一关闭的问题 | 关闭前不得宣称支持 |

关键词 **必须/不得/应当/可以** 分别对应 MUST/MUST NOT/SHOULD/MAY。发生冲突时，优先级为：锁定的规范原文及勘误 > 本文 `[SPEC]` 转录 > 已批准的项目 ADR > 本文其他内容 > RTL 当前行为。当前 RTL 行为不得反向定义架构语义。

---

## 2. 交付范围与产品 profile

### 2.1 分阶段范围

| Phase | 内容 | 本文状态 | 是否允许产品宣称 |
| --- | --- | --- | --- |
| P0 | IME 配置状态、VSET/WARL、精确异常、退休基础设施、feature-off 行为 | 可实施 | 通过签核后可宣称基础设施 |
| P1 | `vmmacc.vv`，W=1，SEW=8/16/32，λ=2 | 可实施 | 通过 P0/P1 全部签核后可宣称 |
| P2 | `vwmmacc/vqmmacc/v8wmmacc` 与窄元素 packing | 架构预留，未关闭 | 不得宣称 |
| P3 | matrix tile load/store | 规范和平台异常模型未关闭 | 不得宣称 |
| P4 | FP/MX matrix MAC | 外部格式/数值规范和 FCSR 路径未关闭 | 不得宣称 |

### 2.2 首发 profile：`coralnpu_ime_p1_vlen128`

`[DECISION]` 首发 profile 固定如下：

| 参数 | 值 |
| --- | --- |
| XLEN | 32 |
| VLEN | 128 |
| Base vector profile | 当前 CoralNPU Zve32x 范围 |
| IME 指令 | 仅 `vmmacc.vv` |
| SEW | 8、16、32 |
| λ 支持集合 | 每个受支持 SEW 均为 `{2}` |
| LMUL | architectural LMUL = 1、2、4、8 |
| widening factor W | 1 |
| mask | `vm=1`；`vm=0` 精确 illegal-instruction |
| `vstart` | 必须为 0 |
| 最大在途 IME macro | 1 |
| 执行策略 | scalar/iterative matrix MAC，系统级串行化 |
| 可见提交 | 整条 macro 原子提交 |
| tail 策略 | 不写 active N 之外的 C 元素 |

首发范围不包括 SEW64。该限制不是把规范中的 SEW64 行解释为不存在，而是明确限定本产品的 type-specific extension claim。

---

## 3. IME 架构规范基线

### 3.1 Tile 几何

`[SPEC]` 对 matrix MAC，定义：

```text
L       = lambda
W       = widening factor
LMUL    = architectural vtype.vlmul（CoralNPU 中必须使用 lmul_orig）
M       = N_max = VLEN / (SEW * L)
N       = VL / (L * LMUL)
K_eff   = L * W * LMUL
EMUL_C  = VLEN / (SEW * L^2)

C[M,N] <- C[M,N] + A[M,K_eff] * transpose(B[N,K_eff])
```

合法性必须同时满足：

```text
LMUL in {1,2,4,8}
VL % (L*LMUL) == 0
0 <= N <= N_max
EMUL_C in {1,2,4,8,16}
```

A、B 各占一个 LMUL register group；C 占一个 EMUL_C register group。每个 group 的 base 必须按自身 group size 对齐，且最高物理寄存器不得超过 `v31`。

`[SOURCE]` 当前 `RvvFrontEnd.sv` 同时保留 `.lmul_orig`，并可能根据 VL 缩减内部 `.lmul`。所有 IME geometry、边界和 hazard 计算必须使用 `.lmul_orig`，不得使用缩减值。

P1 固定几何为：

| SEW | λ | M=Nmax | EMUL_C | K_eff | active N |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 2 | 8 | 4 | `2*LMUL` | `VL/(2*LMUL)` |
| 16 | 2 | 4 | 2 | `2*LMUL` | `VL/(2*LMUL)` |
| 32 | 2 | 2 | 1 | `2*LMUL` | `VL/(2*LMUL)` |

### 3.2 物理 tile 映射

`[SPEC]` 物理映射不得把 register group 简化为普通寄存器顺序拼接。令 `epr=VLEN/EEW`：

```text
tile_reg_idx(i, group_mul, lambda, epr):
  linesize   = lambda * group_mul
  line       = i / linesize
  elem       = i % linesize
  regoff     = elem / lambda
  elementoff = line * lambda + (elem % lambda)
  return regoff * epr + elementoff

mat_A_idx(i,k) = tile_reg_idx(i*K_eff + k,
                              LMUL, lambda, VLEN/EEW_A)
mat_B_idx(k,j) = tile_reg_idx(j*K_eff + k,
                              LMUL, lambda, VLEN/EEW_B)
mat_C_idx(i,j) = tile_reg_idx(i*N_max + j,
                              EMUL_C, lambda, VLEN/SEW)
```

flat index 到物理地址的唯一转换为：

```text
vreg      = base + flat_index / epr
element   = flat_index % epr
bit_low   = element * EEW
bit_high  = bit_low + EEW - 1
```

实现和独立模型必须共享同一数学定义，但不得共享同一 RTL helper 实现，以避免共因错误。

### 3.3 `vtype` 扩展字段

`[SPEC]` RV32 目标布局为：

| 位 | 字段 | P0/P1 行为 |
| --- | --- | --- |
| 31 | `vill` | base-V illegal-vtype 标志 |
| 30:28 | `lambda` | `000`=none，`001..111` 编码 1、2、4、8、16、32、64 |
| 27 | `bs` | 可存储；P1 integer ordinary row 忽略 |
| 26 | `altfmt_A` | 0=signed，1=unsigned |
| 25 | `altfmt_B` | 0=signed，1=unsigned |
| 24:9 | reserved | P0/P1 请求非零使 `vtype` illegal |
| 8 | output `altfmt` | P0/P1 capability=false，因此请求 1 使 `vtype` illegal |
| 7 | `vma` | base-V |
| 6 | `vta` | base-V |
| 5:3 | `vsew` | base-V |
| 2:0 | `vlmul` | base-V architectural LMUL |

bit 8 的正向格式语义不由锁定的 IME Draft 0.1 单独定义。P0/P1 只冻结 `has_vtype_altfmt=false` 时的 reserved 行为，不对 bit 8 为 1 的 P4 语义作任何实现声明；该语义必须由 §15 的 P4 外部规范 gate 关闭后才能启用。

`[DECISION]` P1 的 λ WARL 支持表为：

```text
S_lambda(SEW=8)  = {2}
S_lambda(SEW=16) = {2}
S_lambda(SEW=32) = {2}
```

统一选择算法：

```text
select_lambda(SEW, request, old):
  if SEW not in implementation domain: return NONE
  S = supported_lambda_set(SEW)
  if request == NONE:
      if old in S: return old
      else:        return max(S)
  if request in S: return request
  if exists x in S where x <= request: return max(x <= request)
  return min(S)
```

因此首发 profile 中所有合法 SEW 的最终 λ 均为 2。LMUL 改变不得影响 λ 选择。

VSET 行为必须满足：

- `vsetvli/vsetivli` 在最终 `vill=0` 时保留 `bs/altfmt_A/altfmt_B`，λ 执行 preserve-or-initialize；若 base-V 配置本身 illegal，则后述 canonical `vill` 结果优先并把这些字段清零；
- `vsetvl` 从完整 `rs2[31:0]` 读取 high fields 和低位 base-V fields；不得只读取低 8 位；
- feature-on 时 `bs/altfmt_A/altfmt_B` 的组合在配置阶段可表示，具体指令在消费时判断是否合法；
- feature-off 时 `[30:25]` 全部 reserved；任何非零请求产生 canonical illegal vtype；
- unsupported vtype 的 VSET **正常完成**：`vl=0`、`vtype=0x80000000`、`vstart=0`，按规则写 `x[rd]`，不得产生 instruction exception；
- reset 后项目固定 `vl=0`、`vstart=0`、`vtype=0x80000000`，消除未定义/X 状态；
- 每条完成的 VSET 恰好退休一次；unsupported-vtype VSET 也一样。

### 3.4 P1 指令编码与 operand 定义

`[SPEC]` P1 唯一实现的编码：

| 字段 | 值 |
| --- | --- |
| mnemonic | `vmmacc.vv vd, vs1, vs2` |
| opcode `[6:0]` | `1010111` (OP-V) |
| funct3 `[14:12]` | `000` (OPIVV) |
| vd `[11:7]` | C base |
| vs1 `[19:15]` | A base |
| vs2 `[24:20]` | B base |
| vm `[25]` | 必须为 1 |
| funct6 `[31:26]` | `111000` |

相邻但 P1 不支持的 encoding：

| funct6 | 指令 | P1 行为 |
| --- | --- | --- |
| `111001` | `vwmmacc.vv` | precise illegal |
| `111010` | `vqmmacc.vv` | precise illegal |
| `111011` | `v8wmmacc.vv` | precise illegal |

decode 必须匹配完整 `{opcode,funct3,funct6,vm}`。不得因为同一 funct6 在其他 funct3 下属于 base RVV 指令而误判。

用于 raw-encoding 测试的构造式为：

```text
word = (0b111000 << 26) | (1 << 25) |
       (vs2 << 20) | (vs1 << 15) | (0b000 << 12) |
       (vd << 7) | 0b1010111
```

例如 `vmmacc.vv v4,v1,v2` 的 raw word 必须为 `0xe2208257`。该值必须同时进入 decoder、反汇编和 reference-model golden test。

### 3.5 整数算术

`[SPEC]` P1 的 A/B 元素宽度与 C 均为 SEW。对每个乘数：

```text
a_ext = sign_extend(A) if altfmt_A==0 else zero_extend(A)
b_ext = sign_extend(B) if altfmt_B==0 else zero_extend(B)
product = a_ext * b_ext
C_new = (C_old + sum(product[k], k=0..K_eff-1)) mod 2^SEW
```

四种 signedness 组合必须全部支持：SS、SU、US、UU。`bs` 和 output `altfmt` 不改变 P1 ordinary integer 结果。

C 在规范中按 signed accumulator 解释，但 P1 的 integer accumulation 对每个中间结果取模 `2^SEW`，因此 architectural C bit pattern 不依赖把同一 SEW-bit accumulator 位型解释为有符号或无符号。

`[DECISION]` A/B 首先按各自 signedness 被解释为 SEW-bit 整数；精确乘积以 2*SEW-bit 二进制补码/无符号位模式表示，再参与模 `2^SEW` 累加。datapath 可以在每次累加后截断为 SEW，因为模加法与最终统一截断等价。

### 3.6 执行顺序、alias 与 tail

`[SPEC]` 可观察执行顺序为：

```text
for j = 0 .. N-1:
  for i = 0 .. M-1:
    acc = C[i,j]
    for k = 0 .. K_eff-1:
      acc = acc + A[i,k] * B[j,k]
    C[i,j] = acc mod 2^SEW
```

P1 中 A/B/C 都按相同 EEW 访问。合法、对齐且不越界时，A/B/C 的完全或部分重叠均不得被额外判 illegal。后续读必须看到此前 `(j,i)` 输出已经造成的逻辑更新。

`[DECISION]` P1 使用 shadow overlay：

1. 未覆盖字节的读来自 VRF；
2. 已覆盖字节的读来自 shadow；
3. 当前 output 只在完成全部 k 后写入 shadow；
4. 整条 macro 完成前 shadow 不写入 architectural VRF；
5. 提交时一次性写入所有被触及的 C physical registers。

该策略实现 live alias 语义，同时保证异常/flush 前 VRF 无部分更新。禁止无条件 snapshot 全部 A/B/C，因为 snapshot 会破坏规范所需的 live alias 观察顺序。

C 的物理 row stride 始终为 `N_max=M`，不得改用 active N。对 `j>=N` 的 tail：

- `vta=0` 必须保持；
- `vta=1` 规范允许不确定或保持；
- 本项目统一选择“不写”，因此两者均保持。

`VL=0` 合法，得到 `N=0`；必须产生一次无 VRF 写的正常 completion。

### 3.7 指令合法性与异常

P1 ingress 必须在任何 operand read 或状态改变前完成以下检查：

1. feature/profile 已启用；
2. 完整 encoding 是受支持的 `vmmacc.vv`；
3. `vill==0`；
4. `vm==1`；
5. `vstart==0`；
6. SEW 属于 8/16/32 且对应 type extension enabled；
7. LMUL 是 1/2/4/8，禁止 fractional/reserved LMUL；
8. λ=2 且存在于该 SEW 的 capability set；
9. `VL % (λ*LMUL)==0`；
10. `N<=N_max`；
11. A/B 的 LMUL group base 对齐且不越过 v31；
12. C 的 EMUL_C group base 对齐且不越过 v31；
13. capability 表中的 cell 为 enabled，而非 disabled/reserved/blocked。

任一失败必须产生一次 precise illegal-instruction exception，并满足：

- `mtval` 为原始 32-bit instruction encoding；
- fault PC 为该 instruction PC；
- faulting instruction 不退休，`minstret` 不递增；
- 不写 VRF、GPR、vector CSR、`vstart`、`fflags` 或 memory；
- 不允许另一模块对同一 instruction 再产生第二个 trap；
- fault 必须保持到明确的 trap-boundary acknowledge，禁止单周期脉冲丢失。

`[SPEC]` matrix MAC 不支持以 `vstart` 中断后恢复。`[DECISION]` 首发实现将已 admission 的 legal macro 视为不可中断区间：普通 interrupt/debug 请求保持 pending，在 macro 的原子 retirement edge 之后进入边界；reset 仍按平台 reset contract 具有最高优先级。

---

## 4. CoralNPU 当前微架构事实与差距

### 4.1 当前路径

```text
Fetch/Decode (SCore)
  -> scalar DecodedInstruction / RetirementBuffer allocation
  -> RvvCoreShim (Chisel)
  -> RvvFrontEnd.sv (VSET + command capture)
  -> rvv_backend (CQ/UQ/ROB/execution/retire)
  -> rd_rob2rt_o[3:0]
  -> scalar RetirementBuffer
  -> architectural retire / FaultManager / CSR counters
```

### 4.2 源码确认事实

| 位置 | 当前事实 | IME 影响 |
| --- | --- | --- |
| `Parameters.scala` | `enableRvv`、`rvvVlen=128` 等为全局可变参数；无 sealed IME 配置 | 需增加可复现的 build-time IME record |
| `RvvInterface.scala::RvvConfigState` | 有 `vl/vstart/sew/lmul/lmul_orig/vill`，`vtype` 高位固定为 0 | 必须增加 IME high fields 和完整 vtype pack |
| `Decode.scala` | OP-V 可进入 RVV；未知 IME encoding 可能被当作 vector writer | feature-off/unsupported encoding 必须在 scalar ingress 精确拦截，避免退休悬挂 |
| `RvvFrontEnd.sv` | VSET 主要处理低位；`vsetvl` 未读取完整 rs2 high fields | P0 必须重构 VSET canonicalization |
| `RvvCore.sv` | `rvv_idle = backend_idle && frontend_cmd_valid==0` | 未覆盖前端缓存/config/trap 等全部在途状态，不能直接作为 IME admission proof |
| `rvv_backend_define.svh` | 当前 profile：DISPATCH3、6 个 VRF read、4 个 retire/write lanes、ROB 8、UQ 16 | P1 可复用 3 个 read 和 4 个 commit lanes，无需新增 VRF port |
| `rvv_backend_vrf.sv` | combinational read；多 lane write 以 byte strobe OR 合并 | 必须证明同字节不发生冲突，并用 gated write-valid |
| `rvv_backend_retire.sv` | 存在计算后的 `w_vrf_valid`，但一处 ready 条件仍使用未 gate 的 `w_vrf` | IME 接入前必须修复并回归 base RVV |
| `RvvCore.sv` | FCSR backend output 当前 ready 常 1，但没有 architectural update | P4 不得在此基础上宣称 fflags 正确 |
| `FaultManager.scala` | RVV trap 是 `Valid` 风格脉冲，无 ready/ack | precise IME fault 必须改为 durable transaction |
| `RetirementBuffer.scala` | vector completion 主要按 `uop_pc` 和 `last_uop_valid` 匹配 | 需 macro transaction ID，不能只依赖 PC |
| `RetirementBuffer.scala` | `nRetired` 仅显式排除 ECALL | 必须保证所有 trapping instruction 均不计入 `minstret` |
| `Csr.scala` | `mstatus.VS/FS` 当前近似固定 Initial，Dirty/SD 未完整实现 | P0 必须建立真实 vector-context 状态更新 |

上述项目不是建议性优化，而是 P0/P1 correctness 前置项。

---

## 5. 目标微架构

### 5.1 总体结构

```text
                         scalar age/order domain
  Decode + raw inst + PC -------------------------------+
       |                                                |
       v                                                v
  ImeIngressController -- illegal --> ImeFaultCoordinator --> FaultManager
       | legal immutable command                         |        |
       v                                                 |        v
  +---------------------------- RVV domain --------------+  TrapBoundaryAck
  | ImeEngineP1                                               |
  |   |                                                       |
  |   +-> ImeVrfArbiter -> existing 6R VRF                    |
  |   |                                                       |
  |   +-> ShadowOverlay -> held ImeResultBatch                 |
  +-----------------------------+------------------------------+
                                | result-ready/completion
                                v
                    scalar RetirementBuffer (head check)
                                |
                                v
                    ImeCommitCoordinator -> 4W VRF + VS Dirty
                                |                 (same edge)
                                +-> RB dequeue + minstret + OuterRetireAck
```

### 5.2 冻结原则

`[DECISION]` P1 采用以下不可分割的策略：

1. **单 macro 在途**：`max_inflight=1`；
2. **系统级串行化**：IME 入场前，所有 older scalar/RVV/memory effect 已到安全边界；IME 活跃时阻止 younger architectural issue；
3. **immutable snapshot**：合法性判断和执行使用接收时快照，后续 VSET/CSR 不得改变在途语义；
4. **内部 shadow、退休点原子提交**：执行期无 architectural VRF 写；VRF、CSR 和 RB retirement 同 edge；
5. **单一 fault owner**：同一 macro 只能由 `ImeFaultCoordinator` 交付一个同步异常；
6. **显式完成/退休握手**：engine completion 不等于 architectural retirement；
7. **复用 VRF 端口**：IME 与普通 RVV backend 互斥占用 VRF；
8. **不在首版引入 speculative rollback**：若未来允许并发，必须重新证明所有 precise-state 性质。

### 5.3 模块职责

| 模块 | 建议归属 | 主要职责 |
| --- | --- | --- |
| `ImeDecode` | Chisel/scalar | full encoding 识别、feature-off guard、静态分类 |
| `ImeIngressController` | Chisel/scalar | program-order barrier、snapshot、macro_id、legal/fault 分流 |
| `ImeFaultCoordinator` | Chisel/scalar | sticky fault、唯一 trap owner、trap ack |
| `ImeEngineP1` | SystemVerilog/RVV | geometry、索引、迭代 MAC、shadow 更新 |
| `ImeVrfArbiter` | SystemVerilog/RVV | 普通 backend 与 IME 的 6R/4W 所有权互斥 |
| `ImeShadowOverlay` | SystemVerilog/RVV | C physical register shadow、byte-valid、alias bypass |
| `ImeCommitCoordinator` | SystemVerilog/RVV | 原子 0..4 register commit、completion 保持 |
| `ImeRetireAdapter` | Chisel | completion 到 scalar RB、outer retire ack |
| `ImeBuildConfig` | Chisel/build | sealed feature/profile/capability 唯一真源 |

---

## 6. Scalar core（SCore）修改

### 6.1 Decode 与 dispatch

`ImeDecode` 必须输出：

```text
is_ime_encoding       // 属于锁定 IME encoding space
is_ime_supported      // 当前 effective profile 实现
ime_class             // P1/P2/P3/P4/reserved
ime_requires_vstart0
ime_writes_vrf
ime_may_fault_sync
```

规则：

- 任何 `is_ime_encoding` 都必须由 IME ingress 接管，不得落入 generic OP-V 路径；
- feature-off 或 phase-disabled encoding 仍由 ingress 产生 precise illegal exception；
- IME 强制 slot 0，且同一 fetch/dispatch group 中不得与其他 architectural instruction 同时 fire；
- 一旦 `ime_pending`，冻结 younger dispatch，直至 outer retire 或 trap boundary；
- decode 不得提前以当前 mutable CSR 值判定所有动态合法性；动态检查在生成 snapshot 的 admission edge 完成。

### 6.2 Admission 与顺序屏障

定义：

```text
ime_admission_safe =
    scalar_older_drained
 && retirement_buffer_has_ime_entry
 && rvv_frontend_empty
 && rvv_backend_idle_complete
 && lsu_no_older_effect
 && no_pending_sync_fault
 && no_unaccepted_interrupt_boundary
 && ime_engine_idle
```

`rvv_backend_idle_complete` 必须是新建的完整空闲定义，至少覆盖 frontend input holding、VSET/config transaction、command queue、uop queue、ROB、execution units、LSU outstanding、retire/writeback、trap 和 CSR writeback，不得使用当前简化 `rvv_idle` 直接替代。

admission edge 同时：

1. 锁存 raw instruction、PC、macro_id；
2. 锁存完整 `ImeConfigSnapshot`；
3. 在同一快照上完成所有 legality predicate；
4. 原子选择 `legal command` 或 `sticky fault`，二者 one-hot；
5. 从此阻止配置状态变化进入该 macro。

### 6.3 Retirement Buffer

Retirement Buffer entry 增加：

```text
is_ime
ime_macro_id
ime_done
ime_trap
ime_commit_intent
```

匹配规则：

- IME completion 必须按 `ime_macro_id` 精确匹配；PC 仅用于 debug，不得作为唯一 identity；
- `VL=0` completion 的 `write_count=0`，但 `ime_done=1`，不得等待不存在的 write-valid；
- legal macro 只有在 `ImeCompletion.fire` 后 result-ready；该事件不写 architectural state；
- legal macro 只有在对应 entry 为 head、无更高优先级同步 trap、VRF/CSR/retire 资源均 ready 时才允许 `ImeMacroCommit.fire`；pending interrupt/debug 按 §6.6 延迟到该 macro retirement boundary；
- `ImeMacroCommit.fire` 同一 edge 完成所有 C byte write、VS Dirty update、RB dequeue 和 retirement-counter event；禁止把这四项拆成不同 architectural edge；当前无 `mcountinhibit.IR` 的 profile 对该 event 执行 `minstret+=1`，未来若实现 counter inhibit 必须服从其架构规则；
- illegal macro 只有在 durable fault 到达 head 并被 trap boundary 接受后从 RB 清除；
- legal macro 在上述 head retirement edge 产生 `ImeOuterRetireAck`；ack 可以在下一拍寄存输出，但其语义必须指向该唯一 commit edge；
- `minstret` 只统计真正退休的 legal instruction，所有同步 exception instruction 均不统计；
- flush 必须按 macro_id 清除 stale completion，旧 epoch 的消息不得命中新 entry。

### 6.4 FaultManager 与异常协议

将 IME fault 从无握手 `Valid` 脉冲改为：

```text
ImeFault.valid
ImeFault.ready
ImeFault.bits = {macro_id, pc, raw_inst, cause, tval}
```

生产者在 `valid && !ready` 时必须保持全部 bits 稳定。`ready` 只可表示 scalar trap boundary 已经原子接受该异常；它不是“看见了 valid”。

priority 要求：

- older fault/interrupt 优先于尚未 admission 的 IME；
- 已 admission 的 legal IME 作为不可中断 macro 完成，pending interrupt 在其 retirement boundary 后处理；
- 已产生的 IME synchronous fault 优先于 younger interrupt；
- 同一 macro 的 decoder/backend 不得各自报 fault。

### 6.5 CSR 与 vector context

`RvvConfigState` 和 CSR readback 必须包含：

```text
vl, vstart, vtype[31:0]
lambda, bs, altfmt_A, altfmt_B
sew, lmul_orig, vta, vma, vill
```

`config_state_valid` 必须成为真实的一致性协议：CSR 只能在 valid transaction 上采样新状态，不得无条件读取可能正在变化的 `.bits`。

P0 应把 `mstatus.VS` 实现为真实状态：

- reset 为 Initial 或项目约定初值；
- 成功改变 vector architectural state 的 VSET 置 Dirty；
- legal IME 写 C 时置 Dirty；
- unsupported-vtype VSET 仍改变 `vl/vtype/vstart`，因此置 Dirty；
- illegal IME 不置 Dirty；
- `SD` 由 FS/VS 等 dirty 状态派生，不得固定为 0。

P1 不产生 `fflags`。P4 接入前必须先实现 age-ordered FCSR update，禁止继续使用“ready 常 1、数据丢弃”的现状。

### 6.6 Flush、interrupt 与 debug

- legal command `fire` 之前，普通 architectural flush 可以清除 pending ingress/RB entry；
- legal command `fire` 之后，首发 profile 不接受普通 interrupt/debug flush，相关请求保持 pending 到原子 retirement edge；
- reset 可以在任意状态清除 command、shadow、fault、completion 和所有握手 holding register；illegal 路径由 matching TrapBoundaryAck 清除；
- `macro_id` 包含 epoch；任何实际 kill/reset 后 epoch 前进，旧 epoch completion/fault 必须被丢弃并触发 assertion 记录；
- debug halt 若在 admission 前到达，可阻止 admission；若在 macro 内到达，首版策略是在原子 macro 完成并到达 retirement boundary 后停机；
- NMI/reset 的平台优先级若允许异步破坏 architectural state，必须由 SoC reset contract 单独定义；本文不假设 shadow 能跨 reset 保留。

---

## 7. RVV frontend/backend 修改

### 7.1 `RvvConfigState` 与 wrapper

扩展 Chisel/SystemVerilog 两侧结构并保持 bit-accurate 对齐。建议不要通过散落的独立端口传字段，而是使用版本化 packed struct：

```text
ImeConfigSnapshotV1 {
  vl              : VLWidth
  vstart          : VStartWidth
  vtype           : 32
  sew             : 3
  lmul_orig       : 3
  lambda_enc      : 3
  bs              : 1
  altfmt_a        : 1
  altfmt_b        : 1
  vta             : 1
  vma             : 1
  vill            : 1
  profile_id      : implementation-defined constant ID
}
```

所有跨 Chisel/SV 边界的 struct 必须有 elaboration-time width assertion 和仿真 pack/unpack golden test。

### 7.2 `RvvFrontEnd.sv`

P0 修改：

1. VSET 使用单一 canonicalization function 计算完整 vtype；
2. `vsetvl` 消费完整 `rs2[31:0]`；
3. `vsetvli/vsetivli` 按规范保留或初始化 high IME fields；
4. reset 显式初始化 `lmul_orig`、λ、bs、altfmt_A/B；
5. unsupported vtype VSET 正常生成 config completion/GPR result，不发 trap；
6. 输出配置 state 的 valid/ready 或等价无丢失协议；
7. `frontend_empty` 覆盖 input holding、command valid、VSET update 和 trap holding。

IME computational instruction 不应被普通 RVV uop decoder误拆分；它由 `ImeIngressController` 形成完整 macro command 后进入专用 engine。

### 7.3 `ImeEngineP1`

状态寄存器：

```text
macro_id, raw_inst, pc
config snapshot
vd_base, vs1_base, vs2_base
M, N, K_eff, EMUL_C, LMUL
j, i, k
acc[SEW-1:0]
shadow_data[0:3][VLEN-1:0]
shadow_byte_valid[0:3][VLEN/8-1:0]
```

P1 最大 `EMUL_C=4`，因此四个 shadow entries 足够。该容量是由首发 capability 表推导出的 hard assertion；未来开放不同 λ/SEW 时必须重新计算，不能静默截断。

建议微时序：

```text
LOAD_C:   读取/overlay C[i,j] -> acc
MAC_K:    每周期读取/overlay A[i,k]、B[j,k]，执行一次乘加
STORE_C:  将 acc 写入 C shadow 对应 element bytes
ADVANCE:  k/i/j 计数；最后一个 output 后进入 COMMIT
```

VRF 是 combinational read 时可以把地址产生和采样放在同周期；若综合时序不满足，应增加显式 read pipeline，但不得改变 `(j,i,k)` 的逻辑顺序或 bypass 可见性。

### 7.4 VRF 仲裁与端口分配

`[SOURCE]` 当前配置具有 6 个 dispatch read ports、4 个 retire write lanes。

`[DECISION]` P1 分配：

| 资源 | IME 用途 |
| --- | --- |
| read port 0 | A element 所在 physical register |
| read port 1 | B element 所在 physical register |
| read port 2 | C element初始读，或预取 |
| read ports 3..5 | 保留/置无效 |
| write lanes 0..3 | 原子提交最多 4 个 C physical registers |

IME 拥有 VRF 时，普通 backend 必须已经 empty 且不得发 read/write。仲裁 grant 在整条 macro 期间保持，禁止逐周期抢占。

`rvv_backend_vrf.sv` 的多 lane write 合并必须使用：

```text
effective_strobe = lane_valid && lane_byte_strobe
```

并断言任意两个有效 lane 不写同一 physical register 的同一 byte。IME commit 每个物理寄存器最多使用一个 lane，自然满足该性质。

### 7.5 Shadow overlay

对任意 VRF read `(reg, byte)`：

```text
if shadow_entry_matches(reg) && shadow_byte_valid[byte]:
    read_byte = shadow_data[byte]
else:
    read_byte = vrf_read_data[byte]
```

P1 element 不跨 byte（SEW>=8），byte-valid 足够。shadow entry 的 physical register tag 必须是 `vd_base + regoff`，不得假设 entry index 永远等于 regoff 而省略 tag assertion。

STORE_C 对目标 SEW element 的全部字节同拍更新。任何 partial element update 都是设计错误。

### 7.6 原子提交与普通 retire 路径

当最后一个 active output 完成：

- `N=0`：不申请 VRF write，形成零写 result-ready/completion；
- `N>0`：对 C group 中每个 shadow-valid physical register形成一个 held write lane；
- `ImeCompletion.fire` 只把对应 RB entry 标为 result-ready；不得在该事件写 VRF/CSR；
- `ImeMacroCommit.fire` 必须等于“matching RB entry at head、result-ready、所有 lane ready、CSR ready、retirement allowed”的合取；
- 所有有效 VRF lane、VS Dirty、RB dequeue、`minstret` 和 OuterRetireAck 的语义 commit point 是同一个 edge；
- 任一 downstream backpressure 时，所有 lane、strobe、data、macro_id 和 completion bits 保持稳定；
- 首发策略不在 active legal macro 中接受普通 interrupt/debug flush；这些请求延迟到 retirement boundary。reset 仍可清除 held result。commit 后不存在“已写 VRF 但未退休”的窗口。

P1 `EMUL_C<=4`，当前四个 write lanes 足以单拍提交。若未来 cell 需要超过四个物理 C registers，该 cell 在引入多拍原子 commit buffer/rollback 之前必须保持 disabled。

普通 `rvv_backend_retire.sv` 在 IME 接入前必须修复所有 `w_vrf` 与 trap-gated `w_vrf_valid` 混用，并添加断言：trapping uop 的 effective VRF write-valid 恒为 0。

### 7.7 完整 idle 定义

新增 `rvv_quiescent`，建议定义为以下信号的 AND：

```text
frontend_input_empty
frontend_cmd_empty
frontend_config_empty
frontend_trap_empty
cq_empty
uq_empty
rob_empty
all_exec_units_idle
lsu_no_outstanding
retire_no_pending
csr_writeback_empty
scalar_writeback_empty
ime_engine_idle
ime_commit_empty
ime_fault_empty
```

每个分量必须来自拥有该状态的模块，不能根据若干 valid 的组合近似推断。形式验证必须证明 `rvv_quiescent` 为 1 时 RVV/IME 不会在没有新 input 的情况下产生后续 architectural effect。

---

## 8. 内部事务接口

### 8.1 通用协议

以下接口均采用 ready/valid：

```text
fire = valid && ready
valid && !ready => payload 必须稳定
payload 只在 fire 时被消费
禁止以 pulse 代替未确认事务
```

### 8.2 `ImeCommandV1`

```text
macro_id
pc
raw_inst
vd_base
vs1_base
vs2_base
config_snapshot
decoded_profile_cell_id
```

command 必须是 admission edge 上生成的 immutable payload。engine 不得回读 live CSR 来补字段。

### 8.3 `ImeFaultV1`

```text
macro_id
pc
raw_inst
cause = IllegalInstruction
tval  = zero_extend(raw_inst)
reason_code  // 仅内部 debug/coverage，不改变 architectural cause
```

`reason_code` 至少区分 feature-off、reserved encoding、vill、vm、vstart、SEW、LMUL、λ、VL divisibility、A/B/C alignment、group bound 和 disabled cell。

### 8.4 `ImeCommitBatchV1`

```text
result_valid
macro_id
write_count : 0..4
lane[4] {
  valid
  vreg_index[4:0]
  byte_strobe[VLEN/8-1:0]
  data[VLEN-1:0]
}
set_vs_dirty
```

这是 engine 完成计算后保持的 result/commit payload。`write_count` 必须等于 lane valid popcount。`N=0` 时为 0 且 `set_vs_dirty=0`；有实际 C write 时 `set_vs_dirty=1`。`ImeCompletion` 被 RB 接收后，该 payload 仍必须保持，直到 matching `ImeMacroCommit.fire`；其 `ready` 只能由 RB-head commit coordinator 产生。

### 8.5 `ImeCompletionV1`

```text
macro_id
normal_done
write_count
```

completion 不携带 trap；legal completion 与 fault 是互斥结果。`normal_done` 表示计算和 held result 已完整形成，不表示 instruction 已退休，也不允许单独改变 VRF/CSR。真正 architectural completion 由后续 `ImeMacroCommit.fire` 定义。

### 8.6 `ImeOuterRetireAckV1` 与 `ImeTrapBoundaryAckV1`

- OuterRetireAck：scalar RB 确认 legal macro 已 architectural retirement；engine 此后才可释放 macro_id；
- TrapBoundaryAck：scalar trap path 确认 fault 已进入 architectural trap boundary；fault coordinator 此后清除 sticky fault；
- 两者必须携带 macro_id；错误 ID、重复 ack、无 pending ack 都必须 assertion fail。

`[DECISION]` `macro_id` 使用 `{epoch, sequence}`，总宽度参数化且首版不小于 16 bit。只要任何 command/fault/completion/ack 仍可能在途，就不得重用相同 ID；wrap 只允许在所有相关通道为空时发生。

---

## 9. 控制状态机

### 9.1 Ingress FSM

```text
I_RESET
  -> I_IDLE

I_IDLE
  -- detect IME --> I_DRAIN_PREFIX

I_DRAIN_PREFIX
  -- admission_safe & legal --> I_WAIT_ENGINE
  -- admission_safe & illegal --> I_WAIT_TRAP_ACK
  -- flush --> I_IDLE

I_WAIT_ENGINE
  -- completion.fire --> I_WAIT_OUTER_ACK
  -- reset --> I_RESET

I_WAIT_OUTER_ACK
  -- matching outer_ack.fire --> I_IDLE

I_WAIT_TRAP_ACK
  -- matching trap_ack.fire --> I_IDLE
```

### 9.2 Engine FSM

```text
E_RESET -> E_IDLE
E_IDLE -- command.fire & N==0 --> E_COMMIT_HELD
E_IDLE -- command.fire & N>0  --> E_LOAD_C
E_LOAD_C -> E_MAC_K
E_MAC_K -- k_last --> E_STORE_C
E_STORE_C -- output_last --> E_COMMIT_HELD
E_STORE_C -- otherwise --> E_LOAD_C
E_COMMIT_HELD -- commit.fire --> E_WAIT_OUTER
E_WAIT_OUTER -- outer_ack.fire --> E_IDLE
```

### 9.3 事件优先级

同一周期优先级冻结为：

1. reset；
2. 在当前状态被协议允许的 architectural flush/trap boundary；
3. matching ack；
4. held commit/fault handshake；
5. engine state advance；
6. new admission。

非 matching ack 不得改变状态。active legal macro 中普通 interrupt/debug flush 不属于“被协议允许”的事件。reset 高于 commit，可阻止尚未 fire 的 commit；已经 fire 的 commit 与 scalar retirement 同 edge，因此不存在普通 flush 可回滚窗口。

---

## 10. 可配置实现

### 10.1 配置原则

IME 是 **build-time/elaboration-time** 可配置选项，默认关闭。不得实现为运行时软件 enable bit，也不得同时存在 Chisel 参数、SV define 和测试环境变量三份独立真源。

建议唯一配置类型：

```scala
final case class ImeBuildConfig(
  enable: Boolean = false,
  profileId: String,
  maxInflight: Int = 1,
  enableZvvi8mm: Boolean = false,
  enableZvvi16mm: Boolean = false,
  enableZvvi32mm: Boolean = false,
  enableWidening: Boolean = false,
  enableTileLoadStore: Boolean = false,
  enableFpMx: Boolean = false,
  lambdaBySew: Map[Int, Seq[Int]],
  hasVtypeAltfmt: Boolean = false
)
```

构造时必须校验：

```text
enable => enableRvv
enable => rvvVlen == 128          // 首发 profile
maxInflight == 1                  // 首发 profile
P1 enabled => lambdaBySew exactly {8:[2],16:[2],32:[2]}
enableWidening == false
enableTileLoadStore == false
enableFpMx == false
hasVtypeAltfmt == false
```

交付构建应把规范 PDF hash、profile ID、全部 capability 和最终 elaboration 参数封入 machine-readable variant record，并让生成的 RTL、仿真模型、综合结果与该 record hash 绑定。

### 10.2 Feature-off 行为

feature-off 必须：

- 不实例化 engine、shadow、commit datapath；
- 不增加 VRF 端口；
- IME high vtype bits 按 reserved 处理；
- 所有 IME encoding 产生 precise illegal instruction，不得进入 generic RVV 后悬挂；
- base RVV 的合法 instruction、时序可见状态和异常语义保持不变；
- 通过 off-vs-baseline equivalence 或充分的回归/形式证明。

feature-off decode guard 属于正确解码所需的最小逻辑，不视为“IME datapath 未裁剪”。

### 10.3 Feature-on 可观测能力

软件可见能力必须与硬件 effective capability 完全一致。禁止：

- 配置宣称 P2/P3/P4，但 encoding 只返回 illegal；
- λ CSR readback 支持某值，但 datapath/legal table 不支持；
- RTL 支持某 cell，而软件 manifest 未宣称；
- 仿真通过不同宏临时开放未封存能力。

---

## 11. 文件级修改方案

| 文件/新模块 | 修改内容 | Phase |
| --- | --- | --- |
| `hdl/chisel/src/coralnpu/Parameters.scala` | 增加 immutable `ImeBuildConfig`、构造约束、variant identity | P0 |
| `hdl/chisel/src/coralnpu/scalar/Decode.scala` | IME full decode、slot0、generic OP-V 防漏、barrier | P0/P1 |
| `hdl/chisel/src/coralnpu/scalar/SCore.scala` | ingress、quiescent、fault/completion/ack/CSR 集成 | P0/P1 |
| `hdl/chisel/src/coralnpu/scalar/FaultManager.scala` | durable IME fault 与 trap boundary ack | P0 |
| `hdl/chisel/src/coralnpu/RetirementBuffer.scala` | macro_id、IME completion、trap 不计退休、outer ack | P0 |
| `hdl/chisel/src/coralnpu/scalar/Csr.scala` | 完整 vtype readback、VS Dirty/SD、age-ordered update | P0 |
| `hdl/chisel/src/coralnpu/rvv/RvvInterface.scala` | snapshot/command/fault/completion 类型 | P0 |
| `hdl/chisel/src/coralnpu/rvv/RvvCore.scala` | Chisel/SV bridge、config valid、ack、quiescent | P0/P1 |
| `hdl/verilog/rvv/design/RvvFrontEnd.sv` | high vtype、VSET canonicalization、完整 empty | P0 |
| `hdl/verilog/rvv/design/RvvCore.sv` | IME 端口、完整 quiescent、FCSR dead-end 隔离 | P0/P1 |
| `hdl/verilog/rvv/design/rvv_backend.sv` | VRF/retire ownership mux，普通 backend drain | P1 |
| `hdl/verilog/rvv/design/rvv_backend_vrf.sv` | effective write gate、IME 6R/4W 仲裁、冲突断言 | P1 |
| `hdl/verilog/rvv/design/rvv_backend_retire.sv` | 修复 trap-gated write-valid 使用 | P0 prerequisite |
| 新 `ime_engine_p1.sv` | geometry/index/MAC/FSM | P1 |
| 新 `ime_shadow_overlay.sv` | shadow、byte-valid、alias bypass | P1 |
| 新 `ime_commit_coordinator.sv` | 0..4 lane 原子提交与 completion hold | P1 |
| 新 `ImeIngress.scala` | admission、snapshot、macro_id、fault ownership | P0/P1 |
| 新独立 reference model | bit-accurate tile mapping、alias、signedness、trap oracle | P0/P1 |

实际文件拆分可按项目风格调整，但模块职责和协议不得被合并到无法独立验证的隐式控制中。

---

## 12. 性能、面积与时序模型

### 12.1 P1 基准周期模型

在不含 drain、stall、commit 等待且每个 k 每周期一乘加的情况下：

```text
T_compute ~= N * M * (1 + K_eff + 1)
             ^       ^   ^
             |       |   STORE/ADVANCE
             |       LOAD_C
             outputs
T_total = T_drain + T_admit + T_compute + T_commit_wait + T_retire_wait
```

该公式是微架构估算，不是 ISA 保证。实现可以流水化 multiplier/read path，只要保持 live alias 顺序和原子提交。

### 12.2 主要硬件成本

- 1 个最大 32x32 signed/unsigned multiplier；
- 1 个至少 32-bit modulo accumulator；
- 4 x 128-bit C shadow data；
- 4 x 16-bit byte-valid 与物理 tag；
- 三路 read address/overlay mux；
- 四路 commit mux；
- ingress/fault/completion/ack 控制与断言。

应分别报告 feature-on/off 的门数、寄存器数、关键路径、动态功耗和时钟门控效果。不得用功能仿真替代综合时序确认。

### 12.3 关键路径候选

1. VRF combinational read -> overlay mux -> sign/zero extend -> multiply -> add -> accumulator；
2. shadow data -> 4-lane commit mux -> VRF write data；
3. decode/config -> legality/group-bound combinational tree；
4. 全系统 quiescent 汇聚。

建议在 legality、operand read/multiply 与 commit 各保留明确 pipeline boundary；增加 pipeline 时必须保持 valid/ready、flush 和 macro_id 对齐。

---

## 13. 验证与签核

### 13.1 独立参考模型

模型输入必须是 raw instruction、完整 pre-state（GPR/VRF/CSR/PC）和 effective capability；输出包括 post-state 或 precise trap。模型必须实现：

- VSET high fields/WARL/canonical illegal vtype；
- `tile_reg_idx`；
- exact `(j,i,k)` live alias；
- SS/SU/US/UU；
- modulo arithmetic；
- tail/VL=0；
- 所有 legality reason；
- retirement/minstret/VS Dirty 期望。

### 13.2 Directed test 最小集合

1. 每个 SEW x LMUL x signedness 的 legal case；
2. `VL=0`、最小 N、最大 N、partial N；
3. `vd==vs1`、`vd==vs2`、A/B/C partial overlap、A==B；
4. C group 处于 v0 起点与最高合法边界；
5. A/B/C 每一种 misalignment 和 v31 overflow；
6. fractional LMUL、λ 请求 clamp/preserve、VL 不整除；
7. `vill`、`vm=0`、`vstart!=0`；
8. P2/P3/P4/reserved encoding precise illegal；
9. feature-off high vtype bits reserved、IME encoding illegal；
10. backpressure 每个 command/fault/commit/completion/ack 通道；
11. reset/flush 位于每个 FSM state；
12. pending interrupt 位于 admission 前、execute 中、commit 后；
13. 相同 PC 的循环连续执行，用 macro_id 防止误匹配；
14. unsupported-vtype VSET 正常退休且 `vl=0/vill=1`；
15. base RVV trap case，确认 gated write-valid 修复无回归。

### 13.3 随机与差分验证

- 约束随机生成 legal/illegal vtype、VL、group base、overlap 和 data；
- RTL 与独立模型逐指令比对 VRF/CSR/trap/minstret；
- 增加 backpressure、interrupt、flush 和重复 PC；
- functional coverage 的每个合法 cell 和每个 illegal reason 均必须命中；
- feature-off 与未加 IME 基线做 architectural trace equivalence。

### 13.4 必须存在的 SVA/形式性质

```text
P1: valid && !ready |=> payload stable
P2: legal_command XOR ime_fault
P3: ime_active -> no ordinary RVV VRF write/read ownership
P4: before commit.fire -> architectural VRF unchanged by IME
P5: fault pending -> no IME VRF/CSR/memory effect
P6: trapping retire entry -> nRetired contribution == 0
P7: completion macro_id matches unique live RB entry
P8: stale epoch message never changes architectural state
P9: commit lanes have no overlapping byte writes
P10: N==0 completion eventually occurs with write_count==0
P11: admitted legal macro eventually reaches completion under fair ready
P12: admitted illegal macro eventually reaches trap ack under fair ready
P13: quiescent && no new input -> no later RVV architectural effect
P14: feature-off IME encoding cannot enter ordinary RVV backend
P15: unsupported-vtype VSET does not raise instruction exception
```

### 13.5 回归分层

| 层级 | 内容 | 合格条件 |
| --- | --- | --- |
| L0 | lint/elaboration/interface width | 0 error、0 未审 waiver |
| L1 | 单元测试：WARL/index/engine/shadow/commit | 全部通过 |
| L2 | scalar+RVV 集成与 directed | 全部通过 |
| L3 | random differential | 达到批准指令数且 0 mismatch |
| L4 | formal/SVA | required properties 全部 proven 或有批准边界 |
| L5 | base RVV/off equivalence | 0 architectural regression |
| L6 | synthesis/STA/CDC/reset | 满足项目 signoff 阈值 |

任何测试仅“启动成功”或只检查最终 `pass` 字符串都不能作为签核证据；必须绑定 DUT variant、seed、模型版本、规范 hash 和结果摘要。

---

## 14. P2/P3/P4 扩展预留

### 14.1 P2 widening

P2 需要额外实现：

- W>1 时 A/B storage EEW=`SEW/W`；
- packed 4-bit/2-bit element 顺序和 sign extension；
- 每个 capability table cell 的 reserved/disabled/blocked 分类；
- destination/source multi-EEW overlap 合法性；
- `EMUL_C=16` 时超过 4 write lanes 的原子提交机制。

`[OPEN]` 当前不能把 widening C 与 A/B overlap 仅按“最高寄存器相同”判为合法，因为 base-V 还涉及同一 physical register 不得以多个 EEW 作为 source 读取等约束。关闭前，P2 所有 C 与 A/B overlap cell 必须 disabled 或 ingress illegal，且不得宣称完整 P2。

### 14.2 P3 tile load/store

P3 需要确定：

- fault-only-first/restart 与 `vstart` 的逐 element 语义；
- element 地址、stride、alignment、page/access fault 优先级；
- LSU outstanding transaction identity、kill、replay；
- partial memory side effect 与 precise trap 边界；
- reset/debug/NMI 下的内存事务处理。

`[OPEN]` 当前 CoralNPU LSU 接口和锁定文档不足以唯一证明上述行为，因此 P3 是硬门禁，不得通过复用普通 vector load/store 的近似路径直接开放。

### 14.3 P4 FP/MX

P4 需要锁定外部 Zvfbfa/格式规范，并实现：

- input/output format 与 `altfmt` 的完整 WARL/legality；
- rounding mode、NaN、subnormal、infinity、signed zero；
- invalid `frm` 行为；
- sticky `fflags` 的精确 age-ordered commit；
- MX scale (`v0.scale`) 与 `bs` 规则；
- FP/MX overlap、shadow 与 exception intent。

`[OPEN]` 当前 FCSR update 在 RVV wrapper 中被 ready 但未提交，且依赖规范未全部锁定。P4 在这两项关闭前不得进入产品 capability。

---

## 15. 已解决设计疑问与未决门禁

### 15.1 本文已冻结的问题

| ID | 疑问 | 决议 |
| --- | --- | --- |
| D-01 | “score” 指什么 | 本文按 CoralNPU 模块命名解释为 scalar core `SCore` |
| D-02 | IME 使用 reduced LMUL 还是 architectural LMUL | 必须使用 `lmul_orig` |
| D-03 | P1 λ 支持 | SEW8/16/32 均仅 λ=2，并按 WARL 回读 |
| D-04 | A/B operand field | `vs1=A`、`vs2=B` |
| D-05 | overlap 处理 | P1 equal-EEW 全部合法 overlap 用 live shadow overlay |
| D-06 | tail | active N 外统一不写 |
| D-07 | VL=0 | legal、零写、正常 completion/retirement |
| D-08 | 原子性 | 单 macro 串行化、shadow 执行、最多 4 个 C reg 单拍提交 |
| D-09 | 异常 owner | scalar `ImeFaultCoordinator` 唯一 owner，durable ready/valid |
| D-10 | 配置方式 | sealed build-time option，默认 off，不是 runtime bit |
| D-11 | SEW64 | 不属于首发 type-specific claim，不据此推断规范全局不支持 |
| D-12 | 普通 RVV 端口 | P1 复用现有 6R/4W，不新增 VRF port |

### 15.2 未决问题

| Gate | 未决内容 | 为什么当前不能解决 | 关闭条件 | 阻塞范围 |
| --- | --- | --- | --- | --- |
| G-01 | IME Draft 后续版本/勘误 | 输入是 Draft 0.1，未来文本可能变化 | ISA owner 锁定版本和 errata，重新 diff/评审 | 所有 release claim |
| G-02 | SEW64 与全局 λ 要求的 type-specific closure | 当前 Zve32x profile不支持 SEW64，文本适用域需书面确认 | ISA owner 明确适用范围或产品升级 Zve64 | SEW64 claim，不阻塞 P1 |
| G-03 | P2 multi-EEW overlap | 规范约束组合不能由单条 high-end 规则充分推出 | 规范解释 + 独立 model + formal proof | P2 overlap/cells |
| G-04 | EMUL_C=16 原子提交 | 当前仅 4 write lanes | 增加原子多拍 commit buffer/rollback并证明 | 相关 P2/P4 cell |
| G-05 | P3 precise memory model | 平台 LSU/fault/restart 约束未锁定 | 批准的 memory profile 与事务/kill 协议 | 全部 P3 |
| G-06 | P4 数值与 format 依赖 | Zvfbfa/FP/MX normative artifact 未完整锁定 | 固定 PDF/hash、数值 profile、模型 | 全部 P4 |
| G-07 | P4 FCSR architectural path | 当前 fflags 数据被接受但未提交 | 实现 age-ordered FCSR commit 并验证 | 全部 P4 |
| G-08 | NMI/debug/reset SoC 边界 | core 级 RTL不能定义平台异步事件全部语义 | SoC reset/debug contract + CDC/RDC signoff | 产品级 signoff |
| G-09 | toolchain canonical extension naming | Draft 扩展名/版本可能未被 assembler/compiler正式支持 | 锁定 binutils/LLVM patch 和 ELF attributes | 软件发布，不阻塞 raw-encoding RTL验证 |

任何 gate 未关闭时，能力表必须把对应 cell 标为 `blocked`，并在硬件中精确 illegal；不得以“测试暂未覆盖”代替 gate。

---

## 16. P0/P1 实施顺序

1. 建立 `ImeBuildConfig`、variant identity 和 feature-off decode guard；
2. 修复 base RVV retire gated write-valid、trap 退休计数和完整 idle；
3. 扩展 vtype/config state，完成 VSET/WARL/reset/VS Dirty；
4. 增加 macro_id、durable fault、completion、outer/trap ack；
5. 单元验证 P0，确认 base RVV 与 feature-off 无回归；
6. 实现 `ImeEngineP1`、索引器、shadow overlay；
7. 实现 6R/4W 仲裁和原子 commit；
8. 集成 directed + random differential + SVA；
9. 完成综合/STA/复位/CDC 检查；
10. 仅在所有 acceptance 条件满足后更新 capability/release 声明。

该顺序禁止“先做 MAC datapath，最后补异常/退休”。精确顺序和状态可见性属于架构实现本身。

---

## 17. 工程验收清单

P0/P1 只有同时满足以下条件才可标记完成：

- [ ] 规范和仓库 hash 与本次交付记录一致；
- [ ] build-time on/off variant 可复现，feature-off datapath 已裁剪；
- [ ] full encoding decode 无 generic OP-V 漏接；
- [ ] VSET high fields、WARL、unsupported-vtype 和 reset 全部符合 §3.3；
- [ ] 所有 legality check 在 side effect 前完成；
- [ ] P1 geometry/index 与独立模型逐元素一致；
- [ ] SS/SU/US/UU 全覆盖；
- [ ] 全部合法 overlap 通过 live alias 差分测试；
- [ ] tail 和 VL=0 正确；
- [ ] commit 前无 architectural C 部分写；
- [ ] legal completion、illegal fault、outer ack、trap ack 均无 pulse loss；
- [ ] trapping instruction 不递增 `minstret`；
- [ ] VS Dirty/SD 行为正确；
- [ ] 普通 RVV trap write gate bug 已修复并回归；
- [ ] `rvv_quiescent` 有结构审计和形式性质；
- [ ] required SVA 全部通过；
- [ ] feature-off/base RVV 回归或等价检查通过；
- [ ] lint、随机差分、formal、综合、STA、reset/CDC 签核完成；
- [ ] 所有未决 gate 在 capability 中保持 disabled/blocked；
- [ ] 不存在无审批 waiver 或“暂时假设正确”。

---

## 18. 溯源索引

### 18.1 规范输入

- `ime/20260629-Zvvm-IME-riscv-unprivileged-605-730-Zvvm-IME.pdf`
- `ime/riscv-spec-inter20260710.pdf`

实现期间应使用固定 hash 的本地 artifact；不能用同名网络文件替换。

IME Draft 0.1 的主要审阅锚点为：Chapter 36 的 tile geometry、new `vtype` fields、Zvvmm、shared GEMM helpers、`vmmacc.vv` instruction entry、Table 74、Table 77、Table 88 和 Section 36.13 encoding maps。实现评审必须同时检查说明文字、exception list 和 normative operation pseudocode，不能只看 encoding 图。

### 18.2 CoralNPU 源码真源

- `hdl/chisel/src/coralnpu/Parameters.scala`
- `hdl/chisel/src/coralnpu/scalar/SCore.scala`
- `hdl/chisel/src/coralnpu/scalar/Decode.scala`
- `hdl/chisel/src/coralnpu/scalar/FaultManager.scala`
- `hdl/chisel/src/coralnpu/scalar/RetirementBuffer.scala`
- `hdl/chisel/src/coralnpu/scalar/Csr.scala`
- `hdl/chisel/src/coralnpu/rvv/RvvInterface.scala`
- `hdl/chisel/src/coralnpu/rvv/RvvCore.scala`
- `hdl/verilog/rvv/design/RvvCore.sv`
- `hdl/verilog/rvv/design/RvvFrontEnd.sv`
- `hdl/verilog/rvv/design/rvv_backend.sv`
- `hdl/verilog/rvv/design/rvv_backend_vrf.sv`
- `hdl/verilog/rvv/design/rvv_backend_retire.sv`
- `hdl/verilog/rvv/inc/rvv_backend_config.svh`
- `hdl/verilog/rvv/inc/rvv_backend_define.svh`

### 18.3 配套工程文档

更细的工程治理、capability manifest、自动实现 agent 约束和发布证据规则见：

- `ime/CORALNPU_ZVVM_IME_DESIGN.md`

本文负责芯片架构与微架构参考；配套文档负责实施和交付闭环。两者若出现语义冲突，应回到锁定规范和批准 ADR 处理，不得由实现者自行选择较宽松解释。
