# CoralNPU × Zvvm IME 工程架构与实现设计规范

> 文档ID：`CORALNPU-IME-ARCH-001`；版本：`1.2-architecture-review-candidate`。<br>
> 文档状态：工程架构设计基线候选。P0/P1 已形成可评审详细设计约束，P2--P4 仍受本文列出的外部/平台门阻塞；**未实现 RTL、未完成工程DoR，不能据此宣称硬件正确或Design Approved**。<br>
> 审计日期：2026-07-12。<br>
> CoralNPU 源码审计基线：Git HEAD `66bbcd3226d5f65e02fb38ac188268038020d589`；审计时worktree并非clean，故§10.1行号只用于定位当前快照，不是release source attestation。正式实现必须按§7.6重新捕获全部preexisting tracked/untracked状态与post-change tree hash。<br>
> 规范基线：`ime/20260629-Zvvm-IME-riscv-unprivileged-605-730-Zvvm-IME.pdf`，SHA-256 `c0d25144279b1790cb285d3598e8207005ba9dfc9c24cb5aa00c7d1838829307`。<br>
> RISC-V 依赖基线：`ime/riscv-spec-inter20260710.pdf`，SHA-256 `04499fadf0a8c3d55a73543ed4c38bf6a6c9e1a2e4f3ed23c1d4c81867e81f7c`；文档版本 `20260710-intermediate`。其当前前言把 V 1.0、Zicntr 2.0 和 Machine ISA 1.13 列为 Ratified；本契约锁定使用其 Base Vector Architecture §9.1、Zicntr §4.3 和 Machine-Level ISA §3.1/3.6，不把合订本的 `intermediate` 标签误读为 IME 已 ratify。<br>
> 本文目标：只给出能由该 PDF、当前 CoralNPU 源码或明确验证义务支持的结论；任何不能由现有证据解决的问题均列为阻塞项。

## 1. “完整且正确”的定义

没有任何设计文档能够替代 RTL、形式证明、仿真、软件工具链与硬件验证。因此本文不使用“已保证正确”作为当前状态；它定义了获得该结论所需的全部关闭条件。

只有同时满足以下条件，才可宣称某一实现 profile 正确：

1. 使用本文件顶部锁定的 PDF（或经重新审计的替代版本）实现全部适用 normative 条款；
2. 所有支持的 instruction/type/lambda/LMUL/vta 组合均有独立参考模型、定向测试和随机测试；
3. 所有 illegal、trap、flush、partial-VL、alias 与 CSR 状态路径有断言或形式证明；
4. RTL、生成的 Chisel/SV wrapper、软件编码与目标仿真配置均通过回归；
5. 没有**适用于该宣称 profile**的未关闭“阻塞”或“待外部裁决”项；未进入 claim scope 的后续 P3/P4 capability 仍必须保持 disabled，不能被忽略或暗中声明支持。

`Zvvm` 是由 `Zvvmm`、`Zvvfmm`、`Zvvmtls`、`Zvvmttls` 组成的 family。PDF §36.3 明确：宣称一个 family-level extension 时，必须支持该 family 的全部指令。因此首个整数版本只能宣称已实现的 type-specific extension，例如 `Zvvi8mm`，不能宣称已经实现 `Zvvmm` 或完整 IME。

### 1.1 工程产品基线、范围与成熟度

本文件冻结的**首个可交付工程基线**不是笼统“实现全部IME”，而是 `ENG-P1-VLEN128-MACHINE`。任何偏离下表的实现必须先提交ADR/CR并重新生成requirements、phase profile和验证计划，不能由实现LLM自行选择。

| 基线项 | 冻结值 | 当前源码证据/约束 |
| --- | --- | --- |
| scalar ISA / XLEN | RV32，XLEN=32 | `Parameters.programCounterBits=32`，本文所有CSR/tval/raw ABI按32 bit |
| VLEN / VRF | VLEN=128，32×128-bit VRF | `Parameters.rvvVlen=128`；`rvv_backend_vrf` |
| scalar ingress | 4 instruction lanes | `Parameters.instructionLanes=4` |
| RVV backend profile | `DISPATCH3`，6 VRF read ports、4 retire/write lanes、ROB=8、UQ=16 | `rvv_backend_define.svh`；若构建改为DISPATCH2必须新建profile并重审资源 |
| clock/reset | P0/P1全部新增逻辑与scalar/RVV使用同一 `clock`；active-low `rstn`，首版禁止功能CDC | 详细reset release/quarantine规则见§4.7 |
| delivery configs | `rvv_core_mini_axi`、`rvv_core_mini_verification_axi`，各有 `ime_off_baseline`/ `ime_on_delivery` | §7.6；其它config不是首版release scope |
| IME product option | immutable elaboration/build option；默认且rollback值为 `ime_off_baseline`，显式可选值为 `ime_on_delivery` | §4.10；不是runtime CSR/fuse/pin/plusarg，不能在已生成artifact上动态切换 |
| privileged scope | `machine-mode-vector-context` | P0正式release必须实现VS/SD；bare-metal-nonprivileged仅可作CAPABILITY_DELTA，不是首版release profile |
| P1 capability | SEW={8,16,32}，LMUL={1,2,4,8}，lambda=2，W=1，`IME_MAX_INFLIGHT=1` | `Zvvi8mm/Zvvi16mm/Zvvi32mm` pinned-PDF实验profile |
| P1 microarchitecture | 单macro、单scalar-MAC/cycle correctness baseline、最多4-register shadow C、单次4-lane commit batch | §4.6--§4.8；性能优化必须另建ADR且保持bit/ordering等价 |
| release claim | `experimental-pinned-pdf` | IME仍Draft 0.1；禁止stable-standard/family-level claim |

工程范围分层如下：

| Phase | 设计成熟度 | 本文允许的动作 | 禁止的声明 |
| --- | --- | --- | --- |
| P0 | detailed-design candidate | 完成需求/架构/ABI/配置、状态、trap与工程基础设施 | 尚未关闭DoR/IMP gate时不得开始P1 datapath |
| P1 | detailed-design candidate | 在P0全部applicable gate关闭后实现上述首版整数profile | `EXT-LAMBDA-SEW64-SCOPE` OPEN时不得称portable/广义Zvvi*合规 |
| P2 | architecture only / BLOCKED部分runtime domain | 可实现明确non-overlap的CAPABILITY_DELTA；full phase等待overlap裁决 | 不得effective-enable受阻type extension |
| P3 | concept architecture / BLOCKED | 仅在memory profile与软件交付scope冻结后进入详细设计 | 不得声称tile-LSU precise/restart或P3 COMPLETE |
| P4 | concept architecture / BLOCKED | 仅可做artifact审计、reference model与CSR基础设施 | 不得enable任何FP/MX CELL或Zvvm FP family |

明确out-of-scope：新architected matrix register file、S/H/vsstatus支持、多macro并发、跨时钟IME、cache-coherent tile engine、P3虚拟地址转换/MPRV首版支持、P4未锁定格式，以及任何stable-standard/portable m16 ABI声明。

### 1.2 原子工程需求与唯一真源

P0任何RTL修改前必须创建 `ime/requirements.yaml` 和 `ime/schemas/requirements.schema.json`。JSON Schema使用Draft 2020-12；YAML先转换为JSON再验证。每条记录的required keys固定为：

```text
id, shall_text, class={ISA,ARCH,INTF,RESET,SW,DV,NFR,RELEASE},
source_refs[{artifact_sha256,section,printed_page}], derived_from_ids[],
applies_to_phase_profiles[], owner_role, owner_module,
verification_refs[{method={TEST,FORMAL,INSPECTION,ANALYSIS},ids[]}],
gate_ids[], status={PROPOSED,APPROVED,IMPLEMENTED,VERIFIED,WAIVED,OBSOLETE}
```

canonicalization固定为RFC 8785 JSON Canonicalization Scheme；所有hash均对UTF-8 canonical JSON计算SHA-256。schema禁止unknown property；ID一经APPROVED不得复用或改义，只能OBSOLETE并新建ID。下面是顶层root requirement，PDF逐条normative要求由P0以同样格式继续原子化，不能只保留散文。

| Requirement ID | 原子shall | 适用phase | owner module/role | verification / gate |
| --- | --- | --- | --- | --- |
| `REQ-ISA-001` | 实现只得使用顶部两份hash锁定artifact及已签核dependency，不得从漂移网页推导DUT行为 | P0--P4 | Spec owner | INSPECTION；`EXT-BASEV-ARTIFACT` |
| `REQ-CFG-001` | 单一config owner必须实现完整RV32 vtype、lambda WARL、unsupported canonicalization、VSET AVL/rd/vstart/VS语义 | P0 | `ImeConfigController` | `TEST-CFG-*`/`PROP-CFG-*`；`IMP-P0-VTYPE-STATE` |
| `REQ-CFG-002` | IME legality与accept必须只消费一次program-order coherent immutable snapshot | P0--P4 | `ImeIngressController` | `PROP-SNAPSHOT-ATOMIC`；`IMP-P0-VTYPE-STATE` |
| `REQ-OPT-001` | IME及其INST/CELL/ISAEXT选择必须是默认off、immutable、hash绑定的elaboration configuration；每个target恰好选择一个sealed variant，任何非法/重复/旁路选择必须在analysis或elaboration失败 | P0--P4 | `ImeCapabilities` + build owner | `TEST-OPT-SCHEMA-*`/negative elaboration；`IMP-P0-OPTIONALITY`/`IMP-P0-BUILD-INTEGRATION` |
| `REQ-OPT-002` | off variant只可保留known-encoding classifier、reserved-vtype canonicalization和precise-illegal shell；所有IME phase state/datapath必须按derived capability结构裁剪；off对base-defined/non-IME traffic零额外side effect、零额外backpressure、零X，known-IME illegal只允许precise-trap协议必需的有界serialization | P0--P4 | `ImeCapabilities` + integration owner | hierarchy/netlist absence + `PROP-OPT-OFF-QUIET`；`IMP-P0-OPTIONALITY` |
| `REQ-OPT-003` | 每个result必须唯一绑定config/variant/record/effective-set与实际artifact：sim/formal/lint读取elaborated identity，production/PPA由pre-synthesis identity extraction+sidecar+exact binary/netlist hash绑定；test env不得充当DUT选择器 | P0--P4 | Build + DV owner | active set `2N` identity/artifact tests；首个profile four-tuple；`IMP-P0-OPTIONALITY` |
| `REQ-OPT-004` | release/rollback必须逐artifact绑定variant、effective extension claim、binary/netlist hash、SBOM和qualification evidence；off artifact的effective IME extension集合恒空且为默认/rollback交付物 | release | Release owner | release-manifest validator；`IMP-ENG-CI-RELEASE` |
| `REQ-DEC-001` | 所有known IME encoding在off/blocked/illegal时必须由唯一pre-backend owner精确trap，不得discard或重复owner | P0--P4 | `ImeIngressController` | `TEST-DEC-*`/`PROP-FAULT-ONCE`；`IMP-P0-PRECISE-FAULT` |
| `REQ-ORD-001` | 首版同时最多存在一个accepted IME macro ID，ID在其全部fault/flush/commit/outer-ack结束前不得复用；pre-accept illegal只用独立scalar age ID且在trap-boundary ack前不复用 | P0--P4 | Ingress + age owner | `PROP-MACRO-ID-LIFETIME`/`PROP-PREACCEPT-AGE-LIFETIME` |
| `REQ-ORD-002` | 所有non-restartable P1/P2/P4 MAC必须在单一MacroCommit edge原子提交全部C、适用fflags/context、trace/minstret与RB retirement；commit容量不足的CELL必须disabled | P1/P2/P4 | `ImeCommitCoordinator` | `PROP-MACRO-COMMIT-ATOMIC`；P1 `IMP-P1-RETIRE-COMMIT`，P2/P4 `IMP-P2P4-ATOMIC-COMMIT` |
| `REQ-TRAP-001` | 同步illegal/memory fault不得architectural-retire或增加minstret，并须按program order完成CSR/redirect | P0/P3 | `ImeFaultCoordinator` | `PROP-TRAP-PRECISE`；`IMP-P0-PRECISE-FAULT` |
| `REQ-P1-001` | P1结果必须逐bit等于锁定PDF `j->i->k`即时读写模型，含所有equal-EEW alias | P1 | `ImeEngineP1` | independent model + `TEST-P1-DATA-*` |
| `REQ-P1-002` | P1不得在architectural macro-commit edge前暴露任何C write；该edge必须以一个不可分割事务同时完成最多4-lane C write、所需VS/SD更新、success trace/minstret与RB retirement | P1 | `ImeCommitCoordinator` | `PROP-COMMIT-ATOMIC`；`IMP-P1-RETIRE-COMMIT` |
| `REQ-P1-003` | P1 tail在vta=0/1均保持，VL=0产生一次no-write completion | P1 | Engine + commit | `TEST-P1-TAIL-*` |
| `REQ-INTF-001` | 所有sticky/Decoupled payload在 `valid&&!ready` 时逐bit稳定且每次fire只消费一次 | P0--P4 | 每个ABI producer | protocol assertions；`IMP-P0-MANIFEST-ABI` |
| `REQ-RST-001` | P0/P1不得引入功能CDC；不同reset-release域之间必须隔离，IME reset未完成时不得accept、fault-pulse或产生side effect | P0/P1 | `ImeResetController` | CDC/RDC/reset lint + `PROP-RESET-QUIET`；`IMP-P0-RESET-RDC` |
| `REQ-P3-001` | P3只在锁定memory context/profile内按logical_i精确保留older effect、提交vstart并禁止faulting/younger effect | P3 | `ImeTileLsu` | P3 fault model；`IMP-P3-FAULT-RESTART` |
| `REQ-P4-001` | P4 C/fflags/context必须同macro age提交，invalid frm按profile选择precise-illegal且CSR值不clamp | P4 | `ImeFpMxEngine` + CSR arbiter | bit-exact model；`IMP-P4-FCSR-NUMERIC` |
| `REQ-DV-001` | 每条APPROVED requirement必须映射至少一个独立TEST/PROP/INSPECTION，release时unmapped=0 | 全阶段 | DV lead | traceability validator；`IMP-ENG-DV-PLAN` |
| `REQ-NFR-001` | 每个config的IME-off须在其批准`reference_binding.input_domain`内与独立reference比较，任何known-encoding/high-vtype/P0-fix或其它差异都只能由具体`DELTA-*`逐项授权；同config IME-on对off才约束为不执行known IME raw、不请求IME high-vtype非零且不使用on-only软件资产，并须对scalar/base-RVV architectural trace、外部transaction和stall逐cycle零差异。off/on外部top IO完全相同 | 全阶段 | Integration lead | reference equivalence + on/off constrained equivalence + differential regression；`IMP-P0-OPTIONALITY`/`IMP-ENG-CI-RELEASE` |
| `REQ-NFR-002` | IME-on实现必须满足已批准的clock/area/power/latency/interrupt-deferral budget；没有budget不得release | P1--P4 | µArch + physical owner | synthesis/perf；`IMP-ENG-PPA-BUDGET` |
| `REQ-REL-001` | release bundle必须可从clean source和锁定tool/container重建并带SBOM、coverage、known issues及attestation | release | Release owner | release reproducibility；`IMP-ENG-CI-RELEASE` |

### 1.3 工程输入、假设与未决输入

规范未知、产品选择和工程假设必须分开管理。假设只有经owner批准且有validation/失效动作时才有效：

| ID | 当前值 | validation / 失效动作 |
| --- | --- | --- |
| `ASSUMP-CLK-001` | P0/P1 producer/consumer全在 `RvvCoreShim.clock` 域 | CDC工具证明跨域数=0；若出现第二时钟，停止并新增CDC architecture/REQ |
| `ASSUMP-RST-001` | 顶层 `rstn`可异步assert；IME使用本地同步release/quarantine | reset recovery/removal与随机deassert test；不满足则release blocker |
| `ASSUMP-LIVE-001` | 在无reset且consumer未故障时，fault/commit/outer-retire sink满足bounded fairness | 每个sink必须给具体bound并formal assume/cover；无bound则性能/死锁gate OPEN |
| `ASSUMP-VRF-001` | first delivery为DISPATCH3，IME串行占用3个既有VRF read ports与4个write lanes | elaboration assertion `NUM_DP_VRF>=3 && NUM_RT_UOP==4` |
| `ASSUMP-P3-001` | P3首版M-mode、MPRV=0、无translation、只访问versioned idempotent normal-memory region | 尚无platform artifact，因此P3保持BLOCKED |

以下输入不能由本文或LLM自行解决；它们必须以versioned artifact提供，否则相应工程gate保持OPEN：

| Engineering input | 当前 | 必须包含 |
| --- | --- | --- |
| `engineering_targets.yaml` | MISSING / release blocker | technology/tool/container、clock constraint、area/power上限、逐tuple latency、最大interrupt/debug deferral、synthesis labels |
| `platform_async_events.yaml` | MISSING / P0 DoR blocker | reset/NMI/debug/trigger/interrupt sources、priority、defer/kill/drain、fairness bound |
| `base_reference.yaml` | MISSING / `IMP-P0-OPTIONALITY` blocker | 每个delivery config一条reference binding；必须有五类comparison capability全true的独立cycle-accurate RTL artifact，并锁定source/build/tool/container/artifact/base-config/top-pin hashes、clock/reset、input domain、mask和逐`DELTA-*`；可另加per-config model-config hash的独立architectural model，禁止用待测off DUT生成自身reference |
| `p3_memory_profile.yaml` | MISSING / P3 blocker | region/PMA/PMP/cache/idempotency/endian/alignment/split/atomicity、AXI error→cause/tval、timeout/retry |
| P4 format/Zvfbfa artifacts | MISSING / P4 blocker | §2.1所列owner-confirmed artifacts及model mapping |
| named owner/approver binding | MISSING / release blocker | §11 RACI角色到真实identity与approval key的绑定 |
| architecture review approval | MISSING / datapath blocker | 本document/version、canonical architecture/ABI hashes、review findings closure与board signatures |
| trusted launcher/trust store/signing service | MISSING / phase-COMPLETE与release blocker | `CORALNPU_IME_LAUNCHER_V1` hash锁定binary、Ed25519 trust store、repo外append-only evidence root与有权限的CI/release keys |

### 1.4 生命周期状态、工程DoR与声明维度

状态机固定为：

```text
CONCEPT -> REQUIREMENTS_APPROVED -> ARCH_REVIEW_CANDIDATE -> ARCH_APPROVED -> RTL_READY
        -> CODE_COMPLETE -> VERIFICATION_COMPLETE -> RELEASE_CANDIDATE -> RELEASED
```

不得跳级；任何锁定spec hash、APPROVED REQ、phase profile、ABI major version或acceptance threshold变化，均使受影响状态退回 `REQUIREMENTS_APPROVED`或更早并强制重签。当前状态是 `ARCH_REVIEW_CANDIDATE`，不是 `ARCH_APPROVED`。

进入RTL修改的工程DoR必须同时满足：requirements/schema/ID catalog通过validator；本phase profile roots已实例化；architecture/FSM/ABI/reset/resource budget完成评审；owner和approver已绑定；verification/coverage plan有稳定ID与Bazel mapping；所有implementation-blocking external gate PASS或相关domain静态disabled；bootstrap/prestate工具链可执行。任一项缺失只能做文档、模型或基础设施工作，不能开始相应datapath。

交付状态必须正交报告，禁止用单个“COMPLETE”混淆：

| 字段 | 值 |
| --- | --- |
| `completion_scope_kind` | PHASE_PROFILE / CAPABILITY_DELTA；唯一scope selector，禁止再定义同义字段 |
| `requested_scope_implementation_status` | NOT_STARTED / PARTIAL / COMPLETE |
| `requested_scope_verification_status` | NOT_RUN / PARTIAL / COMPLETE |
| `phase_profile_implementation_status` | NOT_STARTED / PARTIAL / COMPLETE |
| `phase_profile_verification_status` | NOT_RUN / PARTIAL / COMPLETE |
| `profile_conformance` | BLOCKED / CONSTRAINED_EXPERIMENTAL / CONFORMANT_TO_PINNED_ARTIFACT |
| `standard_claimability` | NOT_CLAIMABLE / EXPERIMENTAL_ONLY / STABLE_STANDARD |
| closure `qualification_status` | NOT_READY / RC |
| post-closure `delivery_status` | NOT_RELEASED / RELEASED；只存在于release manifest/attestation |

`PHASE_PROFILE`请求的requested/phase两组状态必须逐值相等。`CAPABILITY_DELTA`可以使requested-scope两字段为COMPLETE，但schema强制phase-profile两字段至多PARTIAL，且closure `qualification_status=NOT_READY`、post-closure `delivery_status=NOT_RELEASED`。例如首版P1 full profile即使RTL和验证全部完成，只要 `EXT-LAMBDA-SEW64-SCOPE` 与 `EXT-IME-RATIFICATION` OPEN，也只能是 `profile_conformance=CONSTRAINED_EXPERIMENTAL`、`standard_claimability=EXPERIMENTAL_ONLY`，但明确scope内两组implementation/verification状态仍可COMPLETE。

## 2. 审计结论与阻塞矩阵

| 项目 | 状态 | 已确认结论或必须采取的动作 |
| --- | --- | --- |
| IME 与当前 widening-multiply 的完整编码冲突 | 已解决 | 无完整 32-bit 冲突：IME 是 `funct3=000`（OPIVV），标准 `vwmulu/vwmulsu/vwmul.vv` 是 `funct3=010`（OPMVV）。仅 `funct6` 相同不构成冲突。 |
| ratified base-V / trap / counter normative artifact | 已解决 artifact availability | 新增合订本已以路径和 SHA-256 锁定；其当前前言明确列 V 1.0、Zicntr 2.0、Machine ISA 1.13 为 Ratified。§9.1 提供 overlap、reserved-vtype、vstart、VS/SD 及 invalid `frm` 规则，§4.3 规定同步异常不 retire/不增 `instret`，§3.1 提供 FS/VS/SD 和 `mtval`。这只关闭规范artifact门；P0/P3实现与平台memory profile仍须测试/证明关闭。 |
| 当前 CoralNPU 对 IME encoding 的行为 | P0 阻塞 | 当前 OPIVV `funct6=111000..111011` 未被 backend decode，`lcmd_valid=0`。与此同时 scalar `Decode.scala` 已将这类通用 OP-V 标作 vector write，RetirementBuffer 会等待同 PC 的 `last_uop_valid`。因此 backend 的“discard”不是可接受的 no-op，可能无法完成退休；必须在进入 backend 前产生精确 illegal trap。 |
| P0 illegal fault 的可靠交付与 backend flush | P0 阻塞 | `RvvCoreIO.trap` 是frontend输出而非backend flush输入；frontend trap和bare `Decode.rvvFault`都是无ack pulse。P1固定Decode单owner、sticky fault，并拆成durable booking ack与fault record到达精确trap点、写CSR并建立redirect后的trap-boundary ack；faulting instruction不退休且不增加`minstret`。只有trap-boundary ack释放illegal-path serial lock。另一方面backend external trap仍硬连0，P3须扩fault metadata到ROB/flush。 |
| IME `vtype` state、reset、跨 Chisel/SV 边界 | P0 阻塞 | 当前所有 IME high fields 都缺失，且 `RvvFrontEnd.sv` reset 未赋值 `lmul_orig`，而 `RvvConfigState.vtype` 正使用它。必须同步修改 Bundle、SV struct、前端、wrapper、ROB return state、CSR readback，并保证 reset 后 `vtype=0x80000000`。 |
| 低位 output `altfmt` 的规范依赖 | P4 外部实现阻塞 | 锁定 IME PDF 只说该字段位于 Zvfbfa 分配的位置，没有给出位号和完整配置语义。当前公开 Zvfbfa v0.1 文本把它放在 `vtype[8]`，但 IME PDF 未锁定该外部 revision，也未说明各 FP IME extension 是否隐含完整 Zvfbfa。P4 必须先锁定经 ISA owner 确认的 Zvfbfa artifact/hash；在此之前只能把 bit 8 作为 provisional integration target，不能实现或宣称 P4 正确。 |
| P4 external numeric-format specifications | P4 artifact 阻塞 | IME PDF引用OCP Microscaling Formats MX v1.0及IEEE/RISC-V FP format behavior；workspace未归档这些normative artifacts。P4必须锁定OFP4/OFP8/E8M0/MXINT8、IEEE16/32/64/BF16相关artifact revision/path/hash，并把helper语义映射到独立model；P4-N0只消除psm=1 disclosure依赖，不消除format dependency。 |
| 既有 wrapper CSR 位宽 | P0 阻塞 | `RvvCore.scala` 生成的 `rd_rob2rt_o_*_vector_csr_{vl,vstart,xrm,sew,lmul,lmul_orig}` 是未标宽度的 scalar output，却被赋予 multi-bit `RvvConfigState` 字段。先修复所有既有位宽（以及所有 consumer），再增加 IME fields；否则 IME 审计建立在已截断/错连的 CSR 上。 |
| 单一 capability/feature 真源与可选构建 | P0 阻塞 | 当前 Chisel 只有mutable `enableRvv/enableFloat/enableZfbfmin`，`EmitCore`按命令行赋值，SV/Bazel另有`ZVE32F_ON`，全树没有IME或逐type-extension gate。必须新增默认off且由Bazel target唯一绑定的sealed elaboration record，同时驱动Decode legality、vtype reserved/WARL、条件elaboration、软件manifest和测试。off仍保留precise-illegal guard，但必须结构裁掉engine/shadow/IME commit/phase datapath；只绑低runtime enable不合格。构建时断言Scala/SV/artifact/DUT identity一致，禁止命令行define/env/plusarg成为第二入口。 |
| Bazel target-universe完整性 | P0 build-integration阻塞 | 2026-07-12实际执行§4.10冻结的`rdeps(//..., ...)`查询时，仓库加载到401个package后因未定义外部仓库`@@fuchsia_sdk//pkg/zx`失败，未产生可审计全集。因此当前不能声称Core/RVV consumer zero-missing。必须修复/封存该外部依赖，或经build owner ADR批准一个仍覆盖同一全集的可证明query decomposition；随后由trusted launcher执行并签名：rdeps结果与`flow_rule_labels ∪ non-TEST_SUPPORT infrastructure ∪ approved_exclusions`逐项相等，test-support一阶依赖查询另与全部`TEST_SUPPORT` infra逐项相等，才可关闭此门。`flow_rule_labels`显式包含SUITE_PARENT及全部suite members。 |
| config snapshot coherence | P0 阻塞 | `RvvFrontEnd.config_state_valid` 只在其 `valid_inst_q` 全空时为 1，但 `SCore` 无条件把 `configState.bits.vl/vtype` 接到 CSR readback；现状不能证明 `vset*` 在飞行时的 `vl/vtype` 读取、IME snapshot 或配置相关 legality 不会使用 stale/invalid state。必须引入 valid/ready snapshot、同周期 forwarding，或在可见性点 stall，并用 program-order 回归关闭。 |
| privileged `mstatus.VS/FS/SD` | P0/P4 scope与实现阻塞 | `Csr.scala`把VS/FS固定为Initial且RV32 `mstatus.SD`固定为0。Base V §9.1.2.2要求VS=Off时**任何vector instruction及任何vector CSR access**均illegal，不能只修IME opcode；改变vector register/CSR state的成功指令（含VSET更新并清`vstart`）须转Dirty，允许保守提前Dirty。P4 vector-FP还要求FS!=Off。IME legal success按锁定profile更新VS/FS Dirty并令SD反映summary dirty；pre-accept illegal/killed-no-effect不Dirty，但accepted P3 runtime fault因提交`vstart`且可能保留partial load writes，必须在trap可见前提交VS Dirty/SD。若产品明确仅bare-metal/non-privileged profile，必须在manifest明示排除。 |
| IME 使用的 LMUL | P0 阻塞 | PDF 使用 architectural `vtype.vlmul`；CoralNPU 会把内部 `.lmul` 按 VL 缩小。IME 必须使用 immutable `.lmul_orig`，或证明另一机制严格等价。 |
| P1 lambda capability 与适用域 | 条件性结论 / 外部范围门 | P1 可公开的 capability matrix 必须是 `Sλ(8)={2}`、`Sλ(16)={2}`、`Sλ(32)={2}`，其 `EMUL_C={4,2,1}`。当前 frontend 使 SEW64 为 `vill`，故该集合覆盖当前可配置的 Zve32x base-V SEW；但 PDF 对“每个 IME-legal `(VLEN,SEW)`”的全局措辞是否自动排除实现不支持的 SEW64 未明说。发布广义/portable IME 合规结论前，必须取得 ISA owner 的书面范围确认，或实现 SEW64 且支持 `lambda=1`。 |
| P1 IME system serialization | P1 阻塞 | 前端可同周期接受多条指令，CQ 也可多条入队；`rvv_idle` 仅检查 backend FIFO/ROB 与 `frontend_cmd_valid`，不涵盖 frontend queued instruction、config update 或 trap pulse。更重要的是当前 scalar interrupt/fault 可不等待 RVV idle。**所有已识别 IME（含最终 illegal）**必须先到定义的全系统 serial/fault-admission point：所有 older architectural work 已完成、frontend/config/trap 状态已静止、无未决或竞争 FaultManager event；随后才接受 macro 或交付一次 sticky illegal-fault transaction。直到 legal IME 的 tagged **outer retirement** 或 illegal IME 的 `ImeTrapBoundaryAck` 前，必须阻止 younger scalar/RVV effect，或实现 age-aware 精确排序，并将 interrupt 延后到相应边界。仅在 issue 端或仅以 `rvv_idle` 阻塞不够。 |
| debug/trigger/single-step 与 reverse flush | P1 阻塞 | 当前 debug request/trigger可直接进入debug，scalar trap只flush scalar RetirementBuffer，且scalar→RVV reverse kill未接通。P1首版必须在accept前优先处理pending debug/trap；accept后legal macro除global reset外不可kill，并把interrupt、debug halt、trigger、single-step及scalar trap delivery延迟到outer-retire。若交付存在不可延迟NMI/异步kill，必须实现shadow discard+tagged kill/ack并在manifest明示，不能假定不存在。 |
| `EMUL_C=16` | 能力扩展阻塞 | 当前backend `EMUL_e/EMUL_MAX`只到8；full RetirementBuffer的8-slot结构只承载debug/RVVI trace，也会在m16 trace中alias。支持m16必须分别扩backend geometry/uop/commit资源与trace accumulator；不能把trace槽误称为architectural retire capacity，也不能只改一个宏。 |
| C tile tail 与 `VL=0` | 已解决为全 MAC 策略 | `vta=0` tail必须保持，`vta=1`可任意或保持；P1/P2/P4统一write-skip tail。`VL=0`发no-write completion且零VRF/fflags write。 |
| P1 C/A/B overlap | 已解决为实现约束 | P1 的三者 EEW 相等；在 base V operand rule 下，所有 otherwise-aligned/bounded overlap（包括 `vd==vs1`、`vd==vs2`）必须接受。PDF normative pseudocode 定义 `j` 外层、`i` 内层的即时 read/dot/write 顺序；不得无条件 snapshot source 或额外判 overlap illegal。 |
| P2 widening destination/source 与 m16 overlap | P2 阻塞 | W>1时C destination EEW大于A/B EEW；Base V high-end widening条件只是C/A或C/B overlap的必要条件，还受下一行多EEW source规则约束。在该gate OPEN时C与A/B overlap全部disabled；未来关闭后才可同时实施high-end条件。`EMUL_C=16`如何延伸又是独立未决项。 |
| P2/P4 widening accumulator 的多EEW source overlap | P2/P4 外部语义阻塞 | Base V §9.1.4.2 还规定：同一physical vector register不得在一条instruction中作为source以多个EEW读取。IME的C是read-modify-write accumulator；W>1时若C group与A/B group overlap，同一physical register会同时按EEW_C与EEW_A/B读取。IME `check_gemm_reg_groups`只检查alignment/bounds，未明确覆盖或豁免该base规则。ISA owner澄清前，这些operand combinations必须disabled并pre-backend illegal，且不得宣称对应type-extension完整合规；A/B彼此同EEW overlap及W=1不受此新门影响。 |
| Scalar retirement completion/tag/ack/counting 与 build profile | P0/P1 阻塞 | RetirementBuffer当前只以PC匹配vector completion，没有macro_id/per-macro outer-retire ack；`VectorWriteDataIO`又丢失`w_valid`，使N=0 no-write completion在full profile debug accumulator中被误记为write。wrapper还把`uop_pc/last_uop_valid`置于`TB_SUPPORT`。此外当前`nRetired=deqReady-retiredEcalls`只排除ECALL，普通Fault/illegal可能被错误计入`minstret`。必须修正fault counting，分离completion/write valid、扩RB entry/tagged match并增加outer-retire ack。8-slot accumulator只影响debug/RVVI trace，不是architectural readiness；m16需分别解决trace槽与backend EMUL/commit资源。 |
| backend VRF retire write gating | P1 阻塞 | `rvv_backend_retire`虽计算含retire-valid/trap mask的`w_vrf_valid`，最终write-valid却使用裸`w_vrf`。非退休lane通常因zero strobe不改数据，但接口语义错误，lane0 trap+残留w_valid仍有side-effect风险。P1 macro commit前必须使用最终gated valid并证明trap/invalid lane零write-valid/零strobe；不能把zero strobe偶然保护当正确性。 |
| P1 macro resource bound | P1 阻塞 | 最大 P1 tile 为 64 个 C element（SEW8/lambda2），而当前 backend `ROB_DEPTH=8`、`UQ_DEPTH=16`。若拆 element uop，不能一次性无界分配；必须规定 streaming/allocation 上界、backpressure、completion 顺序和无死锁证明。 |
| P3 tile-LSU precise fault/restart | P3 硬阻塞 | 当前 LSU→RVV response 只有 `{addr,data,last}`，port1 未接通。scalar LSU 在 vector fault 时会送一个 completion-like response，但 bridge 会把 non-last response 解释为 VRF write；`FaultInfo` 只有 `{write,addr,epc}`，FaultManager 只能重建 cause 5/7，外部 AXI fault 还是 line address。更严重的是现有 fault 是无 ack `Valid`，`faultReg`/slot 可在 RVV backpressure 时先被清除。tile-LS 还缺 immutable snapshot、tagged fault、双消费者 durable ack 和 `vstart={faulting_i|success:0}` 的 CSR age arbitration。必须新增端到端 sticky request/response fault protocol、精确 tval/cause、vstart update 和 flush/ack。 |
| P3 C accumulator tile I/O 协议 | P3 硬阻塞 | partial C 不能按 compute VL 线性加载/存储，必须使用固定物理布局、full-VL 与 column mask；m16 还需要 compiler pseudo-intrinsic pair/unpair、m8 half I/O 与 v0 mask placement 规则。 |
| P4 FP/MX 与 FCSR ordering | P4 硬阻塞 | backend FCSR write 当前被无条件 ready 后丢弃，未端到端写入 scalar CSR；实际 RVV test target 虽定义 `ZVE32F_ON`，仍不等于完整 PDF FP/MX capability。必须建立按 program age 仲裁的单点 `fflags` update，保证 active output 的 sticky OR、software FCSR 写和 RVV retire 不丢失，且被 flush 的 MAC 不提交 flags。当前 RVV config/decode 也没有 SEW64 完整支持，不能宣称任何 Zvvm FP/MX 合规。 |
| 软件 assembler/compiler 与 C API | 软件交付阻塞 | legacy Binutils 2.28 不支持 V；Coral Bazel Binutils 2.45 可汇编 base RVV，却不识别 `vmmacc.vv`。PDF 还定义 `__riscv_ime_lambda()` / `__riscv_vsetlambda()`；没有 mnemonic/intrinsic lowering 时，不得声称完整软件 ISA 支持。`__riscv_vsetlambda(size_t)` 对非零非 2 的幂请求的 portable 语义也不能从锁定 PDF 无歧义导出，必须由 ISA owner 澄清或明示 implementation-defined precondition/diagnostic。 |
| machine-readable 规范覆盖与接口 ABI | 全阶段阻塞 | 当前只有 prose，尚无逐 encoding/Table-cell 的唯一状态、side-effect 表、跨模块 ready/valid ABI 或 closure report。P0 必须先创建并校验 §4.4 规定的 `spec_manifest`、build manifest、interface ABI 与 traceability matrix；否则自动 agent 无法证明没有漏解码、重复 owner、字段错宽或未测试路径。 |
| 规范稳定性 | claim-only 外部阻塞 | IME PDF 逐条 instruction 标为 Draft 0.1；截至 2026-07-12，官方 `riscv-opcodes` IME encoding PR #406 仍是未 ratify 的开放 PR。新增的 RISC-V 合订本不包含 IME，所以它不能改变这个结论。必须锁定 IME PDF hash 与工具链 commit；这不阻止按锁定 PDF 做实验实现，但在 ratify/freeze 前不得公开宣称 stable-standard ISA。 |

自动实现 agent 可以在本阶段内关闭分配给本阶段的 gate。`implementation_blocking` gate 会阻止对应 RTL/capability；`claim_only_blocking` gate 允许继续实现锁定 PDF 的实验性 profile，但必须缩小声明；明确由调用方排除的 `OUT_OF_SCOPE` 项不得被暗中启用。任一**前置阶段**或当前阶段的 implementation gate 未关闭时，不得开始后续 datapath/能力阶段。例如 P0 可以修复 P0 state/trap gate，P1 不得在 P0 implementation gate 全部关闭前加入 IME datapath，P3 不得在 global fault/flush protocol 已签核前开始 tile-LSU RTL。

当前无法由两份锁定PDF与当前源码单独裁决的**九项PDF语义/标准归属歧义**如下；它们不是外部artifact/profile availability gate的全集，后者另见§2.1。所有歧义都必须显式标注而非由LLM猜测：

1. PDF 的 global lambda requirement 是否对仅依赖 `Zve32x` 的 implementation 自动排除其不支持的 SEW64；需要 ISA owner 的书面 scope 确认，或改为实现 SEW64/`lambda=1`；
2. base-V widening overlap rule 如何适用于 PDF 特有的 `EMUL_C=16` C group；需要 ISA owner 的 normative rule，故 m16 overlap 暂禁；
3. Draft 0.1 的 encoding/API 何时冻结或 ratify；需要 ISA owner/upstream toolchain 的外部版本，RTL 不能自行解决；
4. IME m16 value 跨 externally visible function boundary 的 psABI；PDF 明确尚未指定，故只能禁止 portable public ABI 使用或采用并披露 implementation-defined ABI；
5. `__riscv_vsetlambda(size_t)` 对非零非 2 的幂的 portable C API 语义；需要 ISA owner 澄清，或在本地 API 明示 implementation-defined precondition/diagnostic，不能由硬件 WARL 替它作标准解释；
6. IME PDF 引用的 Zvfbfa `altfmt` precise revision/hash、位定义与配置语义，以及 FP IME extension 是否隐含完整 Zvfbfa；缺失的是外部 normative dependency，不可由 RTL 猜测。当前公开 Zvfbfa v0.1 的 `vtype[8]` 只能作为 provisional evidence；
7. integer-input MX `Zvvxi*/Zvvxni*` 的 base-ISA dependency。PDF Table 86 只定义 implication、不列 Dependencies，而这些指令读取 `frm` 并更新 `fflags`；需要 ISA owner 裁决，未解决前必须保持disabled并pre-backend precise-illegal，不能以“experimental private”名义绕过implementation gate；
8. `__riscv_ime_lambda()==0` 的 portable 解释：PDF §36.4.2 允许 reset、`vill=1`、IME-legal domain 外出现 0，§36.10.1.4 却称 0 只表示尚未配置。硬件只能返回真实字段值；软件不得在澄清前把 0 解释为唯一原因。
9. W>1时C accumulator既按EEW_C读取又作为wide destination；若其physical group与narrow A/B overlap，Base V的“同一source register不得以多个EEW读取”与IME仅列alignment/bounds的异常清单如何组合，锁定文本没有明示。ISA owner给出normative applicability前，只能支持C与A/B不overlap的W>1 operand combinations；不得擅自把high-end destination/source overlap规则当成已覆盖source-source多EEW限制。

### 2.1 Stable gate catalog

所有manifest、prompt输入与closure report只能引用下列稳定ID，禁止用自由文本另起同义gate。`effect=implementation_blocking`表示该gate scope内的硬件/软件能力必须保持disabled并precise-illegal；`effect=claim_only_blocking`表示可以实现锁定PDF的实验功能，但必须缩小标准/portable声明。`disposition`只能是`OPEN|PASS|OUT_OF_SCOPE`；`OUT_OF_SCOPE`必须由caller-owned scope明确排除且不得被依赖闭包重新引入。

| external/artifact gate ID | scope | effect | 当前 | PASS所需证据 |
| --- | --- | --- | --- | --- |
| `EXT-BASEV-ARTIFACT` | P0--P4 | implementation_blocking | PASS | 锁定 `ime/riscv-spec-inter20260710.pdf`，SHA-256 `04499fadf0a8c3d55a73543ed4c38bf6a6c9e1a2e4f3ed23c1d4c81867e81f7c`；当前前言列 V 1.0 Ratified，规范映射为 §9.1/9.2--9.7（printed pp. 281--377） |
| `EXT-TRAP-COUNTER-ARTIFACTS` | P0 fault、P3 memory trap | implementation_blocking | PASS | 同一锁定artifact；Zicntr 2.0 §4.3（printed pp. 64--66）与 Machine ISA 1.13 Chapter 3（printed pp. 678--726，所用 `mtval`规则在 §3.1.16 pp. 704--705）；当前前言将两者列为 Ratified。PASS只表示规范artifact已闭合；P0 illegal `mtval=raw[31:0]`已由本contract固定，P3 memory `mtval`、PMA、split/总线fault仍由 `EXT-P3-MEMORY-PROFILE` 管理 |
| `EXT-LAMBDA-SEW64-SCOPE` | 任何Zvvi*标准合规/type-extension claim | claim_only_blocking | OPEN | ISA owner书面scope规则，或实现并验证SEW64/lambda=1；OPEN时只可称SEW8/16/32 pinned-PDF实验profile |
| `EXT-M16-OVERLAP` | EMUL_C=16 overlap cells | implementation_blocking | OPEN | ISA owner normative overlap rule及tests；不影响明确non-overlap的其它cell |
| `EXT-WIDENING-MULTIEEW-OVERLAP` | W>1且C与A或B physical group overlap的P2/P4 operand combinations | implementation_blocking | OPEN | ISA owner明确Base V source多EEW限制对read-modify-write C的适用性及IME exception-list优先级；OPEN时仅允许C与A/B不overlap，A/B彼此同EEW overlap仍按其它规则处理 |
| `EXT-IME-RATIFICATION` | stable-standard claim | claim_only_blocking | OPEN | owner-frozen/ratified IME artifact path/hash、版本差异审计与manifest重新生成；当前Draft 0.1 PDF不能关闭 |
| `EXT-M16-PSABI` | portable public m16 ABI | claim_only_blocking | OPEN | ratified/owner-approved psABI artifact path/hash与compiler ABI tests |
| `EXT-VSETLAMBDA-NONPOW2` | portable C API的非零非2幂输入 | claim_only_blocking | OPEN | ISA owner定义或从portable scope排除并提供diagnostic contract |
| `EXT-ZVFBFA-ARTIFACT` | P4 low output-altfmt | implementation_blocking | OPEN | owner-confirmed Zvfbfa revision/path/hash及IME dependency裁决 |
| `EXT-P4-FORMAT-ARTIFACTS` | P4 OFP/MX/IEEE formats | implementation_blocking | OPEN | OCP MX v1.0及全部IEEE/RISC-V format artifacts path/hash与model映射 |
| `EXT-P3-MEMORY-PROFILE` | P3 alignment/split/PMA/bus fault behavior | implementation_blocking | OPEN | 首版固定M-mode/no-MPRV/no-translation且只允许profile列出的idempotent normal-memory region；caller锁定memory/PMA/idempotency profile与faulting-portion contract。若允许MPRV/translation，必须另锁定effective privilege、MPRV/MPP、translation/PMP/PMA snapshot及older CSR/SFENCE ordering；fault response前不得产生会在restart时重复的faulting-element device/read effect，store error必须证明未写，否则对应region/config禁用tile access |
| `EXT-INTMX-BASE-DEPENDENCY` | integer-input MX cells | implementation_blocking | OPEN | ISA owner给出base dependency并更新ISAEXT/CELL closure |
| `EXT-LAMBDA0-API` | portable `ime_lambda()==0`解释 | claim_only_blocking | OPEN | ISA owner消除PDF文字冲突；此前API只返回真实field且不声明唯一原因 |

| implementation gate ID | scope | 当前关闭证据 |
| --- | --- | --- |
| `IMP-P0-VTYPE-STATE` | reset/WARL/full-vtype/config coherence/lmul_orig | P0 RTL、width/config tests与formal assertions |
| `IMP-P0-CAPABILITY-SOURCE` | single feature/extension source及default-off | elaboration/manifest双向一致性tests |
| `IMP-P0-OPTIONALITY` | immutable sealed off/on选择、off结构裁剪、DUT identity与base non-interference | variant schema/negative tests、exact guard allowlist/hierarchy/netlist absence、reference/on-off equivalence、active set全部`2N` identity及release-schema fixture test（首个profile four-tuple）；不依赖实际post-closure release manifest |
| `IMP-P0-BUILD-INTEGRATION` | Core/SoC配置传播、SV/Scala资源注册及Verilator/VCS/lint/FPGA variant closure | build-graph query、resource-presence test、所有授权flow逐tuplecompile与identity/hash核对 |
| `IMP-P0-PRECISE-FAULT` | Decode owner、booking/trap ack、fault `minstret+=0` | fault/competition/backpressure/CSR redirect tests |
| `IMP-P0-WRAPPER-WIDTH` | Chisel/SV/wrapper/consumer widths | active set全部`2N` artifact的`ime_interface_width_*_test`零mismatch；首个profile为四项 |
| `IMP-P0-PRIV-STATE` | privileged vector context的VS/SD | VS Off/Dirty、SD与trap-order tests，或caller明确bare-metal `OUT_OF_SCOPE` |
| `IMP-P0-MANIFEST-ABI` | ENC/INST/CELL/ISAEXT/RULE/SW、build overlay、transaction ABI | contract validators与hashes |
| `IMP-P0-RESET-RDC` | async reset、local sync release、跨reset-domain quarantine | CDC+RDC lint、recovery/removal、partial-reset formal与随机相位test |
| `IMP-P1-SERIAL-DEBUG` | older drain、barrier、interrupt/debug/kill | ordering properties与nonvacuous tests |
| `IMP-P1-RETIRE-COMMIT` | macro_id、completion/write split、outer ack、shadow commit | mini/full functional与trace tests |
| `IMP-P1-VRF-GATING` | retire/trap gated VRF writes | invalid/trap/no-write lane assertions |
| `IMP-P1-RESOURCE-DATAPATH` | bounded streaming、alias overlay、geometry/arithmetic | independent-model exhaustive legality和random data tests |
| `IMP-P2-CELL-PACKING` | widening/packing/overlap逐cell | independent packing/overlap oracle |
| `IMP-P2P4-ATOMIC-COMMIT` | P2/P4全部touched C registers及fflags/context同edge提交 | 逐CELL commit-lane capacity、all-or-none mux与backpressure formal |
| `IMP-P3-FAULT-RESTART` | LSU cause/tval/vstart/flush/double-ack/reset | precise fault/restart/side-effect tests |
| `IMP-P3-C-IO-ABI` | full/partial/m16 tile I/O | compiler ABI与physical-layout tests |
| `IMP-P4-FCSR-NUMERIC` | fflags/frm/formats/G-psm-rnd/MX scale | bit-exact model、CSR ordering与artifact hashes |
| `IMP-P4-FS-FRM` | P4 privileged FS/SD与valid frm legality | FS=Off时覆盖existing scalar/vector FP及 `fflags/frm/fcsr` CSR access全部illegal；成功FP/FP-CSR state change按保守policy置FS Dirty并派生SD；P4覆盖frm=0..4与5..7 selected-illegal tests；Off/Initial切换不得清FPR/FCSR |
| `IMP-ENG-REQ-BASELINE` | atomic requirements、schema、stable IDs及traceability | requirements/schema validator、APPROVED roots、unmapped=0 |
| `IMP-ENG-ARCH-BASELINE` | module ownership、FSM、clock/reset、resource schedule与ADR | architecture review record及ABI/FSM lint |
| `IMP-ENG-PPA-BUDGET` | clock/area/power/latency/interrupt-deferral | approved `engineering_targets.yaml`及synthesis/perf evidence |
| `IMP-ENG-DV-PLAN` | TEST/PROP/COV/WAIVER plan及coverage closure | verification-plan validator、coverage/mutation/formal results |
| `IMP-ENG-CI-RELEASE` | presubmit/nightly/release CI、release BOM/provenance/rollback | clean release rebuild、release manifest、attestation与rollback drill |
| `IMP-ENG-GOVERNANCE` | RACI、risk、defect、waiver、ADR/CR和正式审批 | named approver signatures、零未批准critical risk/waiver |
| `IMP-SW-TOOLCHAIN-ABI` | claimed assembler/compiler/C APIs | claim-ID对应的toolchain/IR/asm/runtime tests |

实现gate的`disposition/evidence`由agent从测试与artifact派生，caller不得直接把它标成PASS。上表“当前关闭证据”是验收类型而不是当前PASS状态；本轮没有RTL实现，全部implementation gate保持OPEN或由明确scope标成OUT_OF_SCOPE。

本文的`privileged scope`严格只指当前CoralNPU的**machine-mode vector context**（`mstatus`/machine trap）。S-mode/H-mode、`sstatus`、`vsstatus`及双VS检查不在本contract中；若未来声称这些能力，必须新增stable gate、artifact、CSR/legality/Dirty/SD ABI与tests，不能把machine-mode PASS外推。

## 3. 规范上不可改变的行为

### 3.1 Tile 几何和 architectural LMUL

对于一条 matrix MAC，令 `L = lambda`、`W` 为 widening factor、`LMUL_spec = vtype.vlmul`：

```text
M       = N_max = VLEN / (SEW * L)        # C 的物理 M x M tile
N       = VL / (L * LMUL_spec)            # active C columns
K_eff   = L * W * LMUL_spec
EMUL_C  = VLEN / (SEW * L^2)

C[M,N] <- C[M,N] + A[M,K_eff] x transpose(B[N,K_eff])
```

必须满足 `LMUL_spec ∈ {1,2,4,8}`、`VL % (L*LMUL_spec)==0`、`0<=N<=N_max`、`EMUL_C∈{1,2,4,8,16}`。A/B 是 LMUL 组，C 是独立的 EMUL_C 组；组 base 对齐且不得超过 `v31`。compute VL **只**选择 B/C 的 active column 数 `N`；它不缩小 `M`，也不允许少读 A 的任何一行。A tile load 所需的 `VL_A=M*L*LMUL_spec`；partial-N MAC 仍必须对全部 `M` 行 A 完成 dot product。

所有 VRF physical mapping必须直接实现锁定 PDF 的 `tile_reg_idx`，不能把group当作普通flat-concatenated registers。令 `epr=VLEN/EEW`：

```text
tile_reg_idx(i, group_mul, lambda, epr):
  linesize    = lambda * group_mul
  line        = i / linesize
  elem        = i % linesize
  regoff      = elem / lambda
  elementoff  = line * lambda + (elem % lambda)
  return regoff * epr + elementoff

mat_A_idx(i,k) = tile_reg_idx(i*K_eff + k, LMUL_spec, lambda, VLEN/EEW_A)
mat_B_idx(k,j) = tile_reg_idx(j*K_eff + k, LMUL_spec, lambda, VLEN/EEW_B)
mat_C_idx(i,j) = tile_reg_idx(i*N_max + j, EMUL_C, lambda, VLEN/SEW)
```

返回的flat index再映射为`register=base+flat/epr`、`element=flat%epr`。A与B的EEW相同于当前instruction row，但公式仍分别写`EEW_A/EEW_B`，禁止误用C的SEW。tile-LS也使用同一`tile_reg_idx(i,LMUL,lambda,VLEN/SEW)`。

**CoralNPU 专属约束：**`RvvFrontEnd.sv` 保存 `lmul_orig`，随后在 `REDUCE_LMUL=1` 时根据 VL 修改 `.lmul`。IME 的 geometry、group bound、hazard range 和 K/N 计算必须使用 `.lmul_orig`，因为 PDF 指定的是 architectural `vtype.vlmul`；不得使用缩小后的 `.lmul`。

当前 `VLEN=128`、且限于 PDF integer rows 的 `SEW={8,16,32,64}` 时，architecture-permissible lambda 如下（表是规范几何，不是已实现 capability）：

| SEW | lambda | M=N_max | EMUL_C |
| --- | ---: | ---: | ---: |
| 8 | 1 / 2 / 4 | 16 / 8 / 4 | 16 / 4 / 1 |
| 16 | 1 / 2 | 8 / 4 | 8 / 2 |
| 32 | 1 / 2 | 4 / 2 | 4 / 1 |
| 64 | 1 | 2 | 2 |

P1 的**可观察 WARL capability**必须明确披露为：`Sλ(8)={2}`、`Sλ(16)={2}`、`Sλ(32)={2}`。故 SEW8/16/32 分别得到 `EMUL_C=4/2/1`；请求 `lambda=1` 时因没有受支持的 `<=1` 值而规范性地回落到最小受支持值 2，请求 `lambda>=4` 时回落到 2，零请求保留/初始化为 2。这不是“内部任意限制”，而是 ABI 可读回的 implementation-defined capability，必须由 WARL 回归验证。

P1 `vmmacc`（`W=1`）的固定 geometry 表如下；其中 `Lmul` 必为 `lmul_orig` 所编码的整数 LMUL：

| SEW | lambda | M=N_max | EMUL_C | K_eff | active N |
| --- | ---: | ---: | ---: | --- | --- |
| 8 | 2 | 8 | 4 | `2*Lmul` | `VL/(2*Lmul)` |
| 16 | 2 | 4 | 2 | `2*Lmul` | `VL/(2*Lmul)` |
| 32 | 2 | 2 | 1 | `2*Lmul` | `VL/(2*Lmul)` |

当前 CoralNPU 的 base-V frontend 将 SEW64 配置为 `vill`，所以前一段覆盖的是**当前可配置的** SEW。PDF 的全局 lambda requirement 是否在 type-specific `Zve32x` implementation 中自动排除不支持的 SEW64，不能仅凭现有文字无误推导；在该范围得到 ISA owner 书面确认前，P1 只能宣称本文件锁定的 Zve32x profile，不能以此概括所有 `(VLEN,SEW)`。

### 3.2 `vtype` IME fields 和 WARL

在 RV32 中，锁定 IME PDF 与其引用的低位字段形成下面的目标 layout。`altfmt[8]` 的位号来自当前公开 Zvfbfa v0.1 文本，不是锁定 IME PDF 自身给出的位号，故在外部 dependency gate 关闭前只可作为 provisional P4 integration target：

| 字段 | 位 | 语义 |
| --- | --- | --- |
| `vill` | `[31]` | illegal vtype 指示 |
| `lambda[2:0]` | `[30:28]` | `000`=none，`001..111`=`1,2,4,8,16,32,64` |
| `bs` | `[27]` | MX block size：0=32、1=16 |
| `altfmt_A` | `[26]` | 整数 A：0=signed、1=unsigned |
| `altfmt_B` | `[25]` | 整数 B：0=signed、1=unsigned |
| reserved for this profile | `[24:9]` | 请求非零必须使配置 illegal；不得静默保留 |
| output `altfmt` | `[8]` | Zvfbfa 定义的 output-format selector；是否存在由独立 `has_vtype_altfmt` capability 决定 |
| `vma` / `vta` | `[7]` / `[6]` | base-V mask/tail policy |
| `vsew` / `vlmul` | `[5:3]` / `[2:0]` | base-V SEW 与 architectural LMUL |

Base V 对 unsupported-vtype VSET 的规范结果是 `vl=0`、`vill=1`且其余software-visible `vtype` bits为0。它仍是**成功退休的VSET instruction**，不是illegal-instruction exception，并与所有正常完成的vector instruction一样把 `vstart`清0；VSET仍把新 `vl=0`写入 `x[rd]`（`rd=x0`时无GPR write）。在当前没有 `mcountinhibit.IR` 的 CoralNPU 中必须恰好 `minstret+=1`。machine-mode vector-context profile还必须按本契约的保守策略置 `VS=Dirty`/派生 `SD`。Base V只推荐而非强制同样的reset值；为消除X和实现差异，本CoralNPU contract另外固定reset后 `vstart=0,vl=0,vtype=0x80000000`。不能只清 `vl`、仅在reset测试，或把unsupported-vtype VSET误送illegal trap。

IME high-state capability enabled 时，`vsetvli/vsetivli` 必须原样保留 `bs/altfmt_A/altfmt_B`，并以 preserve-or-initialize 规则更新 lambda；`vsetvl` 从完整 `rs2` 原样写入 `bs/altfmt_A/altfmt_B` 并把 lambda bits 当作 WARL request。`bs/altfmt_A/altfmt_B` 的组合在配置期都可表示：不得 clamp、清零或仅因组合不被某条指令支持就置 `vill`；legality 由消费该组合的 IME instruction 检查。lambda 的单一函数必须实现：

```text
ime_lambda_supported(SEW, L) -> Bool
ime_select_lambda(SEW, encoded_request_L, old_L) -> encoded_L
```

其中 `encoded_request_L ∈ {0,1,2,4,8,16,32,64}`，来自 3-bit architectural lambda encoding；它不是任意 `size_t` C API 参数。

* 不在 IME-legal domain：返回 `000`；
* 请求 `000`：保留仍合法的旧 lambda，否则选最大支持 lambda；
* 请求的非零**编码** lambda 合法：保留；
* 请求的非零**编码** lambda 不合法：选不大于该编码请求的最大支持值；若没有，选最小支持值；
* LMUL 的改变不得影响 lambda 的选择。

feature-dependent reserved 规则必须由同一 capability record 驱动：

* 以下`enableIme`是§4.10 sealed variant record的只读derived constant，不是软件可写状态或独立命令行开关；
* `enableIme=false` 时 `[30:25]` 是 reserved；`vsetvl` 对这些位的任何非零请求必须 canonicalize 为 `vill`，不能让 feature-off state 潜入 CSR；
* `enableIme=true` 时 `[30:25]` 按上述 IME 规则工作，即使当前只启用整数 type-specific extension；
* `has_vtype_altfmt=false` 时 bit 8 是 reserved，任何配置请求 1 必须置 `vill`；`has_vtype_altfmt=true` 时，其 `vsetvli/vsetivli/vsetvl` 写入和 reserved-combination 行为必须来自已经锁定的 Zvfbfa normative artifact；
* `has_vtype_altfmt` 只是该 architectural field 可用性的 capability，不等同于自动宣称完整 Zvfbfa instruction set。FP IME 是否隐含完整 Zvfbfa 仍是 §2 的外部 blocker；
* `[24:9]` 在本交付 profile 中始终 reserved，除非未来 manifest 逐位声明另一个已实现 extension；不得用一个宽泛 `reserved=0` mask 覆盖已定义的 IME high fields或 bit 8。

`vsetvli/vsetivli` 的 immediate 可直接携带低位 bit 8，所以它与必须 preserve 的 IME high fields不是同一种配置行为。P4 的 output `altfmt` 也不是 `altfmt_A/B`。P0/P1 可以在 `has_vtype_altfmt=false` 下完成，但必须正确实现 bit 8 的 reserved behavior；P4 在外部 Zvfbfa artifact/hash 未锁定前保持 disabled。

### 3.3 整数 matrix MAC 的精确索引、tail 与 alias 语义

`vd` 是物理 `M x M`、row-major C；`vs1` 是 `M x K_eff`、row-major A；`vs2` 是 `K_eff x N`、column-major `B_tile^T`。同一 `vs2` 内容也可看成 `N x K_eff`、row-major B，故 dot product 使用 `B[j,k]`。

PDF shared SAIL-like `int_gemm` 的可观察顺序为：

```text
for j = 0 .. N-1:
  for i = 0 .. M-1:
    read C[i,j]
    read A[i,0..K_eff-1] and B[j,0..K_eff-1]
    C[i,j] = C[i,j] + dot(A[i,*], B[j,*]) mod 2^SEW
```

`check_gemm_reg_groups` 只检查 group alignment/bound，未禁止 source/destination overlap。P1 的 W=1 使 A、B、C 的 EEW 都等于 SEW；因此 base V 的 equal-EEW overlap rule 允许所有 otherwise-aligned/bounded A/B/C overlap，包括 `vd==vs1`、`vd==vs2` 和 partial group overlap。P1 的最保守、可证明实现是严格按以上 `(j,i)` 顺序执行，并让后一次读看到前一次已经写入的 alias 值（内部 bypass/overlay 可实现同一效果）。**不得**无条件 snapshot 所有 A/B/C，也不得将这些 P1 overlap 额外判 illegal。

这个结论不得外推到 P2。对 `EMUL_C<=8` 的 widening case，base-V §9.1.4.2 的destination/source high-end规则只是必要条件：destination EEW大于source EEW时，source EMUL至少为1且两group最高寄存器必须相同。它**不是充分条件**，因为同节还禁止同一physical register作为source以多个EEW读取，而IME的C accumulator本身会按EEW_C读取。故在 `EXT-WIDENING-MULTIEEW-OVERLAP`关闭前，W>1的C与A/B任何overlap都必须ingress illegal；不能把high-end overlap标为已解决。A/B均以相同narrow EEW读取，二者彼此overlap不触发这个多EEW门。对IME，不得把A/B的storage EEW误推成 `LMUL/W` 个寄存器：PDF `check_gemm_reg_groups`定义A/B均为LMUL physical group。base V ordinary EMUL最大值为8，因此即使未来解决多EEW问题，普通overlap规则也不能自动推广到 `EMUL_C=16`；m16 overlap继续由 `EXT-M16-OVERLAP`阻塞。

物理 C row stride 始终是 `N_max=M`，不能使用 active N。对于 `N<=j<N_max`：

* `vta=0`：tail 必须保持原值；
* `vta=1`：tail 可任意或保持；
* P1 统一选择不写 tail，因而两种 vta 都正确。

`VL=0` 合法且 `N=0`；PDF 的 `int_gemm` 没有任何 loop iteration，且 base-V 的零 VL 不更新 destination。P1 必须发出 completion，但不得写 VRF。

### 3.4 P1 instruction encoding 与合法性

PDF 的四条 integer MAC encoding 都是 `opcode=1010111`、`funct3=000` (OPIVV)、`vm=1`：

| mnemonic | funct6 | P1 |
| --- | --- | --- |
| `vmmacc.vv` | `111000` | 是 |
| `vwmmacc.vv` | `111001` | 否，P2 |
| `vqmmacc.vv` | `111010` | 否，P2 |
| `v8wmmacc.vv` | `111011` | 否，后续 capability |

标准 RVV `vwmulu/vwmulsu/vwmul.vv` 使用相同的三个 funct6、但 `funct3=010`，故与 PDF 的完整 32-bit IME encoding 不冲突。当前 CoralNPU 也仅在 OPMVV/OPMVX 分支将这些 funct6 解释为 widening multiply；OPIVV 对应 encoding 目前不被实现。

完整 computational decode partition必须在manifest中使用下表，不能只从mnemonic猜 `funct3`：

| encoding class | funct6 | funct3 | `vm=1` | `vm=0` |
| --- | --- | --- | --- | --- |
| `vfmmacc.vv` | `010100` | `001` | ordinary FP-input | reserved |
| `vfwmmacc.vv` | `010101` | `001` | ordinary FP-input | FP-input MX + `v0.scale` |
| `vfqmmacc.vv` | `010110` | `001` | ordinary FP-input | FP-input MX + `v0.scale` |
| `vf8wmmacc.vv` | `010111` | `001` | ordinary FP-input | FP-input MX + `v0.scale` |
| `vmmacc.vv` | `111000` | `000` | ordinary integer | reserved |
| `vwmmacc.vv` | `111001` | `000` | ordinary integer | integer-input MX `vfwimmacc.vv` |
| `vqmmacc.vv` | `111010` | `000` | ordinary integer | integer-input MX `vfqimmacc.vv` |
| `v8wmmacc.vv` | `111011` | `000` | ordinary integer | integer-input MX `vf8wimmacc.vv` |

所有行共同使用OP-V opcode `1010111`，字段仍是`vd,[19:15]=vs1(A),[24:20]=vs2(B)`。decode必须先按full `{opcode,funct3,funct6,vm}` 分类，再按Table 87/88/89和effective extension closure判legal；不能把`vm=0`统一当mask或统一判illegal。

P1 仅在 feature enabled 时支持 `vmmacc.vv` 的 `Zvvi8mm`、`Zvvi16mm`、`Zvvi32mm`；每项必须覆盖 `altfmt_A/B` 的四种 signedness 组合。ordinary integer `vm=1` row 只由 instruction、SEW、`altfmt_A` 和 `altfmt_B` 选择；`bs` ignored。低位 output `altfmt` 在一个已经合法建立的 vtype 中也不参与该 instruction 的 legality：若 `has_vtype_altfmt=true`，必须验证 0/1 得到相同整数行为；若该 capability=false，则 bit 8 的非零请求已在配置期产生 `vill`，不得伪造一个绕过 vtype legality 的 `altfmt=1` instruction test。所有下列情况必须产生一次、精确的 illegal-instruction trap：`vill=1`、`vm=0`、`vstart!=0`、非整数 LMUL、lambda 不支持或为 0、VL 不整除、group 未对齐/越界、未启用的 type extension、保留 encoding。

`vill=1` 是所有 IME class（P1/P2 integer MAC、P3 tile-LS、P4 FP/MX）的第一优先级 illegal 条件；非零 instruction lambda 不会绕过它。illegal 不得改变 `vstart`、VRF、`fflags`、memory 或 completion state，且必须携带 faulting instruction 的原始 PC/encoding。各 class 后续的规则只能在 `vill=0` 的 immutable snapshot 上执行。

### 3.5 P2 widening、packing 与 operand-order 的不可省略规则

对每个 widening factor `W>1`，C 的算术/累加宽度仍是 SEW，A/B 的**存储** EEW 为 `SEW/W`。第 `k` 个 narrow logical element 位于 storage position `floor(k/W)` 的 bits `[EEW*(k%W)+EEW-1 : EEW*(k%W)]`；4-bit storage 时 even logical element 在 byte `[3:0]`、odd logical element 在 `[7:4]`。实现不得把 C 的 SEW 与 A/B 的 EEW 混用，也不得在 tile-LS 中悄悄以 W-unpack/repack 改写存储布局。

令 `Lmul=architectural lmul_orig`。每个 P2 source `S∈{vs1,vs2}` 都必须独立满足 `S % Lmul == 0` 与 `S+Lmul<=32`；C 必须满足 `vd % EMUL_C == 0` 与 `vd+EMUL_C<=32`。**当前 `EXT-WIDENING-MULTIEEW-OVERLAP=OPEN`时，任一S physical group与C group overlap都必须ingress illegal。** 只有ISA owner关闭该gate后，`EMUL_C<=8`、`Lmul>=1`且 `S+Lmul-1 == vd+EMUL_C-1`才成为进一步的必要high-end条件；它本身永远不是当前合法充分条件。`EMUL_C=16`还必须另行关闭 `EXT-M16-OVERLAP`。A/B彼此是相同narrow EEW source，其alias不套destination/source禁令，但仍服从PDF `j -> i -> k` live read/write semantics，不能snapshot source。

P2 decoder 必须把 PDF Table 88 的每个 cell及其runtime RULE partition显式分为 `{supported, feature-disabled illegal, reserved illegal, blocked-external illegal}`，而非从 `W` 自动推导“所有组合合法”。至少下列门必须在 datapath 前关闭：

* `vqmmacc` 的 SEW8/EEW2 cell 是 reserved；
* `v8wmmacc` 的 SEW 小于 32 是 reserved；
* `vwmmacc` 的 SEW8 只可走 PDF 指定的 Int4 row，不能被泛化为任意 EEW4 implementation；
* 所有 A/B signedness、sign extension、packed-4bit nibble order、模 `2^SEW` accumulation 都必须由 independent model 覆盖。

PDF encoding diagram 的 field semantics 是 `vs1=A`、`vs2=B`，而 RVV raw bit positions 是 `[24:20]=vs2`、`[19:15]=vs1`。IME textual grammar 固定为 `vd,vs1(A),vs2(B)`；这也与本地 Binutils 的 base MAC `vwmacc.vv v4,v1,v2 -> 0xf620a257` 一致。不得从 ordinary arithmetic `vwmulu.vv` 的不同 textual field order 推断 IME mapping。实现、raw encoder、assembler printer 和 reference model 必须实现这一固定 mapping；§8 给出 field-semantic golden word 和必须通过的 P2 signedness-discriminating test。

### 3.6 所有 non-restartable IME MAC 的共同 precise-order 契约

P1/P2 integer MAC 与 P4 FP/MX MAC 都要求 `vstart=0`，因此它们不是 P3 那种可逐 element restart 的 instruction。P1 的 `ime_pending -> ime_admission_safe -> {ime_accept_safe: accept legal macro | ime_fault_safe: sticky illegal fault}`、single logical fault owner、`ImeOuterRetireAck`/`ImeTrapBoundaryAck` boundary 不是仅 P1 的优化；**每一个后续 MAC phase 必须继承它**。P2/P4 不得只增加 decoder/datapath 后在现有流水中自由并发。

§3.3 的fixed physical C stride与tail rule也适用于全部P2/P4 MAC。为形成单一可验证策略，本实现所有phase都选择`j>=N`完全不写：`vta=0`因此保持，`vta=1`选择允许的“保持”结果。所有shared `int_gemm/fp_gemm/fp_scaled_gemm/int_scaled_gemm`都按`j->i`完成一个active C output后把结果写入shadow overlay；对任何最终判legal的A/B/C overlap，后续operand/C read必须看到该已完成output。P2/P4同样不得snapshot全部source。

本contract只允许一种首发策略：复用P1全系统serializing policy，所有active C保持在足够容量的shadow，P4再保持`fflags`与context intent，最后在单个`ImeMacroCommit.fire`与RB retirement同edge提交。若当前commit lane数容不下该CELL的全部touched C registers，该CELL保持disabled。未来并发/rollback方案必须新建ADR、ABI major version与完整kill/visibility proof，不能作为本文phase COMPLETE的替代实现。

所有 phase 的 illegal 也服从同一 `ime_fault_safe`/durable-ack rule；P2/P4 不能因新 Table cell、FP exception 或 MX scale path 绕过 program order。普通 FP exception 仍只更新 sticky `fflags`，不改变 illegal-trap ownership。

## 4. 当前 CoralNPU 的事实与必须修改的边界

### 4.1 已验证的现状

| 子系统 | 当前事实 | 对 IME 的结论 |
| --- | --- | --- |
| 配置 | `Parameters.scala` 固定 `rvvVlen=128`；`rvv_backend_config.svh` 默认 `DISPATCH3` | 当前不是 DISPATCH2：默认有 3 dispatch uop、6 VRF dispatch read ports、4 retire lanes。 |
| vtype/reset | `RvvInterface.scala` 与 `rvv_backend.svh` 都缺 lambda/bs/altfmt_A/B/output-altfmt；`RvvFrontEnd.sv` reset 未写 `lmul_orig`，unsupported-vtype VSET 又只清 `vl` 而没有 canonicalize 其它 vtype fields | 必须一起扩展；CoralNPU reset policy显式产生 `vstart=0,vl=0,vtype=0x80000000`并设置内部 `lmul_orig=LMUL1`/新增fields=0。每种unsupported-vtype `vsetvl/vsetvli/vsetivli`都必须成功退休一次、清 `vstart`、读回 `vl=0,vtype=0x80000000`且不产生instruction trap，并断言valid config不含X。 |
| Frontend configuration | `RvvFrontEnd.sv` 的 `vsetvl` 只读 `rs2[7:0]`；`config_state_valid` 只有 frontend `valid_inst_q` 全空才为 1 | 必须实现 full-vtype high bits、feature-dependent reserved mask、WARL、vill canonicalization，且为 P1 公开固定 `Sλ` matrix；同时为 `vset*` in-flight 时的 CSR readback、IME snapshot 和 legality 建立 valid/forwarding/order 机制，不能无条件消费 `configState.bits`。 |
| Capability source | `Parameters.scala:75-87`使用mutable布尔值，`EmitCore`以`startsWith`解析参数；SV `ZVE32F_ON`与Bazel `vopts`又是独立选择，且没有IME gate | 新增sealed `ImeVariantRecord`；代码中的`enableIme`只能是该record的只读derived constant，不能再公开mutable bool或SV define。由一个canonical variant实例生成/校验Scala、SV和build manifest；feature-off encoding仍须pre-backend precise illegal。 |
| Build option | 当前`rvv_core_mini_axi*` targets用共享`gen_flags/vopts`静态拼接功能，未知`EmitCore`参数会落入ChiselStage参数，无法证明唯一配置身份 | 首版只允许静态Bazel target label选择`ime_off_baseline`或`ime_on_delivery`；现有非`_ime` release labels永久绑定off，新`*_ime_*` labels绑定on。target只把唯一`ime_variant_record_ref`传给generator并消费其固定declared outputs；`config_id/variant_id`只能从record派生核验，DUT内嵌非architectural identity供test读取。 |
| Wrapper | `RvvCore.scala` 的 inline generator 既只导出标准 config/ROB `vector_csr` fields，又把多个 multi-bit CSR field 声明为无位宽 scalar output；BUILD 还 suppress `WIDTH/WIDTHEXPAND/WIDTHTRUNC` | 只修改 generator source，不直接改 Bazel 临时 SV；先对齐所有既有 `vl/vstart/xrm/sew/lmul/lmul_orig` 位宽和 consumer，再新增 fields。普通 build 成功不能关闭 width gate，必须有 Chisel `getWidth`、SV `$bits`、port/consumer 一致性测试和不依赖这些 waiver 的 lint。 |
| Decode | 未知 OPIVV 111xxx 在 backend 得到 `lcmd_valid=0`；`requireZeroVstart()` 目前只匹配 `funct3=010`，frontend early trap 仅处理 vill | 在 production `RvvCompressedInstruction`/`Decode.scala` 加 IME classifier、`ime_pending` 和完整 `ime_illegal` predicate；所有 P1 legality（含 vstart）必须走同一 Decode-owned **sticky fault transaction**，完成 `ImeFaultBookingAck -> ImeTrapBoundaryAck`，并 gate `io.rvv`/`rvvRdMark`，禁止让 illegal command 入 backend 后 discard。 |
| RVV ingress / ordering | `RvvFrontEnd` 和 CQ 均可同周期接收/推进多条 RVV command | P1 的 IME interlock 必须覆盖 accept、CQ/LCQ/UQ/RS/ROB 到 completion，不可只加 execution-unit busy。 |
| Scalar packet prefix | Dispatch按`lastReady`只推进ready prefix；`forceSlot0Only`遇到非lane0指令会停该lane及younger | IME在lane k>0时必须允许lanes `[0,k)` strictly-older prefix先fire/drain，只阻止IME本身及younger；待IME到lane0再建立pending。初次识别即冻结整个packet会死锁。 |
| Trap/flush crossing | `RvvFrontEnd` 已有组合、无 ack 的 `trap_valid_o`，经 `RvvCoreIO.trap` 进入 `SCore.FaultManager`；backend 也有 `trap_flush_rvv` skeleton，但 top-level 将其外部 `trap_valid_rvs2rvv` 输入固定 0 | P1 固定使用 Decode-owned sticky/ack `ime_fault` transaction 处理所有 IME pre-backend illegal，frontend path 只保留为既有 non-IME vill route；P3 前必须把 tagged LSU structured fault 接到 backend ROB/flush，并和 scalar trap owner 做一次性协调。 |
| VRF | 32×VLEN、6 dispatch read ports、4 retire write ports | 这些端口不是一个完整 IME dot product 的单周期证明；P1 必须新增能分周期读取 A/B/C 并保持 alias 顺序的 IME datapath，不能塞进普通 element MAC。 |
| VRF hazard/retire | 当前RAW/bypass只比较单physical register并按byte overlay；retire final write-valid未使用已计算的retire/trap-gated valid | macro间serial不能证明macro内group alias；P1必须使用§4.5独立shadow overlay。macro commit还必须修复write-valid gating，断言invalid/trap lane零valid/零strobe。 |
| EMUL | `EMUL_e`、`EMUL_MAX` 和普通 uop logic 最大为 8 | P1 lambda=2 可避开 16；m16 capability 必须单独升级。 |
| Scalar retirement | current RB只按PC匹配vector completion，无macro ID/tagged outer-retire event；`VectorWriteDataIO`无actual-write-valid。full profile的8-slot accumulator仅用于debug/RVVI trace，mini不用该trace accumulator；`uop_pc/last_uop_valid`又受`TB_SUPPORT`控制 | 扩entry/IO/tag match，分离completion与write，新增`ImeOuterRetireAck`。m16的8槽限制是trace alias/覆盖风险，不是architectural readiness/VRF容量证明；backend EMUL/commit资源仍须独立扩展。 |
| `vl` CSR | `RvvConfigState.vl` 是 8 bit，`CsrRvvIO.vl` 却是 `log2Ceil(128)=7` bit | 当前 `vl=128` 读回会截断；P1 前必须将 CSR `vl` 通路扩为能表示 VLMAX 的 8 bit。 |
| `vstart` CSR | 内部可写存储宽度是 `log2Ceil(VLEN)=7` bit | 这是 VLEN=128 下对 element index 0..127 的正确实现宽度，不得仿照 `vl` 错误扩成 8 bit；architectural XLEN-wide CSR read 必须把这 7 bit 零扩展。 |
| Privileged state | `Csr.scala`注明FS/VS dirty未实现，将两者固定为Initial，且`mstatus`读路径把bit31 SD置0 | privileged claim必须实现VS/FS Off/Initial/Clean/Dirty、RV32 SD、program-order coherent accept snapshot与access rule：全部IME检查VS，P4再检查FS；否则manifest明示bare-metal/non-privileged exclusion。 |
| Debug/reverse kill | debug request/trigger/single-step不检查IME busy；scalar trap flush不回传RVV backend，external backend trap输入固定0 | P1 first profile在accept前处理pending event，accept后defer debug/interrupt/scalar trap到outer-retire；global reset丢弃shadow。任何不可延迟异步event必须新增tagged kill/ack，不能依赖现状。 |
| P3 LSU | response 仅含 `{addr,data,last}`；port1 ready 被固定为 false。faulted vector LSU 也产生 response，而 bridge 对 non-last response 置 VRF-write-valid；没有 structured fault 被送入 backend `UOP_LSU_t.trap_valid`。`FaultInfo={write,addr,epc}` 让 FaultManager 只能硬编码 cause 5/7；AXI adapter 上报 line address且对 read-response timing留有 TODO。fault 全链路是无 ack `Valid`，slot 可在 response backpressure 时先被清掉。当前 request 又只 snapshot reduced `lmul`/basic LSU fields | 当前不存在可用于 tile-LS 的精确 fault/restart path；不能只扩 completion bridge，必须一起扩 Decode→`LsuCmd/LsuUOp`、bus fault source、RVV request/response、ROB/flush 和 scalar trap crossing。必须携带原始 cause，并按锁定trap/PMA profile区分element EA与split access的实际faulting-portion address来生成`tval`，再等待backend/scalar durable ack。 |
| P4 FCSR | backend `rt2fcsr_write_*` 被本地无条件 ready 后丢弃，wrapper/`CsrRvvIO` 无 fflags write 通路；常用 RVV sim target 定义 `ZVE32F_ON`，但不是完整 FP/MX implementation | 当前不能正确更新 `fflags`；P4 必须保留/合并 software CSR 与 scalar FloatCore 更新，并按 macro retirement 提交 RVV flags。 |

### 4.2 P1 的 illegal-trap ownership 与 ingress barrier

P1 的整数 MAC 没有 memory fault；但这不使它成为“仅 RVV 局部”的操作。其 legality、config snapshot、retirement、interrupt 边界和 scalar precise fault 都必须按一条 macro 的 program order 处理。它必须在**进入 RVV backend 之前**建立 `ime_decode_and_legalize`：

```text
raw 32-bit instruction + PC + immutable architectural config snapshot
  -> {one accepted P1 IME macro} OR {one pre-backend illegal event}
```

统一config snapshot至少含`vl`、`vstart`、`vill`、`sew`、`lmul_orig`、architectural `vta`、`vma`、`lambda`、`bs`、output `altfmt`、`altfmt_A`、`altfmt_B`和effective feature bits；现有RTL的`.ta/.ma`只是对应`vta/vma`的内部字段名，禁止复制出第二份状态。privileged scope由scalar CSR owner附加program-order coherent的`mstatus.VS/FS`；所有P4 profile不论privilege scope都必须附加`frm`。P3再附加完整`v0_mask_snapshot[127:0]`和address operands，P4附加完整`v0_scale_snapshot[127:0]`。这些字段都必须在accept fire前准备好并随同一次fire锁存；后端不得重新从可被后续`vset*`/CSR、scalar write或VRF write改写的live state推导geometry、privilege legality、address、mask、scale、format或rounding。

当前已有两条 scalar-visible fault route，但它们不能被混为一个可靠的 P1 protocol：

* scalar `Decode.rvvFault -> FaultManager` 是 Decode-stage fault path；
* `RvvFrontEnd.trap_valid_o -> RvvCoreIO.trap -> SCore.FaultManager` 是既有 frontend path，但其产生条件目前仅是 `vill && !vset*`，而且 `Valid` interface 没有 ready/ack、`trap_valid_o` 是组合 pulse。仅从当前源码不能证明它与并发 fault 的仲裁不会丢失该 pulse。

因此本文为 P1 固定**唯一 logical owner**：production `Decode.scala` 的 lane 0（或经等价且已证明的单 lane pre-dispatch stage）必须建立 `is_ime_encoding`、`ime_pending` 和完整 `ime_illegal(snapshot)`。它不得依赖现有 `requireZeroVstart()`，因为该函数目前仅匹配 `funct3=010`，而 IME 是 `funct3=000`。若IME初见于packet lane `k>0`，必须先阻止lane k及younger并允许strictly-older lanes `[0,k)`按prefix规则drain；只有IME被保持/推进到lane0后才capture `ime_pending`。冻结整个packet会阻止older退休并使serial-safe死锁。**IME到达owner后无论最终legal或illegal，都必须先进入`ime_pending`并满足同一serial admission；不得先pulse fault再等待older work。**规则如下：

1. 对任何 IME raw encoding，先等待一个 `configState.valid` 的、按 program order coherent 的 snapshot；不能用 invalid/stale `configState.bits` 猜测 legality；
2. 初次classifier hit只阻止IME及younger，允许strictly-older prefix drain；IME到lane0并建立`ime_pending`后阻止所有younger effect。`ime_illegal`必须覆盖`vill`、feature-off、未实现/保留funct6、`vm`、`vstart`、LMUL、lambda、VL divisibility、group alignment/bound、type/format/signedness cell等该phase可见的全部条件；
3. 不论`ime_illegal`结果如何，先等待`ime_admission_safe`。legal path必须把scalar fetch lane0消费、该lane既有RB enqueue的IME metadata写入与engine command接受耦合为同一个事件：`ime_legal_accept_fire = fetch_lane0.fire = ImeRbEntryEnq.fire = ImeCommand.fire`。其ready合取snapshot、engine与RB reservation；禁止任一子事件单独发生。该entry至少保存`{isIme=1,isImeFault=0,age_tag.kind=ACCEPTED_MACRO,macro_id,pc,raw}`，不进入普通RVV backend、不使用可立即退休的nonWritingInstr，也不靠普通`rvvRdMark`等待PC-only completion；只能由matching `ImeMacroCommit.fire`退休。若illegal，只有legality snapshot、fault sink和同一RB entry reservation均ready时，才以`ime_illegal_booking_fire = fetch_lane0.fire = (ImeRbEntryEnq.fire && isImeFault) = ImeFault.fire`一次性建立`{isIme=1,isImeFault=1,age_tag.kind=PRE_ACCEPT,scalar_age_id,pc,raw}`与Decode-owned durable fault record；该路径不分配macro ID、不发送ImeCommand/backend command；
4. `ime_fault`必须是含`{age_tag:{kind=PRE_ACCEPT,scalar_age_id},pc,raw,cause=2,tval=raw}`的sticky Decoupled transaction；它不得包含或分配`macro_id`。`ImeFaultBookingAck`**恰好定义为**上述illegal booking fire，表示fault entry/record均已durable，不是第二个独立ack接口。fire只允许producer清`ime_fault.valid`，不能释放serial lock/`ime_pending`。随后fault record必须按program order到达精确trap点，matching fault entry被trap消费而`architectural_retire=0`；写好`mepc/mcause/mtval`并建立trap redirect后再返回恰好一次`ImeTrapBoundaryAck`，只有后一个ack释放illegal-path lock；
5. illegal transaction从等待booking到trap-boundary ack期间都抑制`io.rvv.valid/fire`、RVV frontend command、`rvvRdMark`与任何vector completion/write mark；并断言no older work未退休、no younger effect、no competing fault吞掉/重复该record；
6. 不允许 IME 再落入 frontend 的 generic vill trap path；若发生，视为 duplicate-owner assertion failure。该 frontend path 可继续服务既有 non-IME behavior，但不是 P1 IME protocol；
7. `RvvS1Decode` 只可作为同步单元测试模型，不能替代 production `RvvCompressedInstruction`/`Decode.scala`/`RvvFrontEnd.sv` 路径；禁止用 backend `lcmd_valid=0` 表示 illegal。

`ime_serial_safe` 必须是可观察、可断言的 system-level predicate，至少同时包含：

```text
no in-flight vset/config/privilege/frm update older than the pending IME
frontend has no queued instruction or pending frontend trap
RVV backend CQ/LCQ/UQ/RS/ROB/retire empty
all older scalar/float/LSU architectural work retired and no fault pending
no younger instruction has an architectural effect in flight
interrupt policy can defer a newly arriving interrupt until this macro's retire boundary
debug halt/trigger/single-step policy can defer a newly arriving request to the same boundary
FaultManager has no competing unacknowledged event and can reserve/ack an IME fault transaction
```

定义`ime_admission_safe=ime_serial_safe`。`phase_snapshot_valid`必须同时表示coherent config、适用scope的privilege snapshot、P4 `frm`、以及P3/P4所需scalar operand/v0 capture均已完成；`ime_accept_safe=ime_admission_safe&&phase_snapshot_valid&&ime_cmd_sink_ready&&ime_rb_entry_ready`。`ime_fault_safe=ime_admission_safe&&legality_snapshot_valid&&ime_fault_sink_ready&&ime_rb_entry_ready`，其中sink-ready必须是durable booking capacity，不是组合Mux priority；同一个RB ready按`isImeFault`选择metadata，不代表第二enqueue port。现有`rvv_idle`不包含frontend queue/config/trap/debug state。P1最简单的合格实现是**全系统serializing + shadow C**：只在上述atomic accept point接受macro，随后阻止younger effect；accept后legal macro除global reset外不可kill，并把interrupt、debug halt、trigger、single-step和scalar trap delivery延后到tagged`ImeOuterRetireAck`。illegal路径则保持lock到`ImeTrapBoundaryAck`，不是booking ack。backend`last_uop_valid`、aggregate`nRetired`或`rob.empty`都不是充分release条件。若选择并发/killable实现，必须用tagged retirement、rollback、fault/flush/debug acknowledgement证明替代；没有该证明不得声称P1 precise。

RetirementBuffer计数方程冻结为 `nRetired = PopCount(dequeued_entries where architectural_retire==1)`。任一`resultUpdate.trap==1`的faulting entry（illegal、memory fault、ECALL及其它同步异常）必须`architectural_retire=0`，不得按mcause白名单或简单`deqReady-1`修补；同cycle位于fault entry之前且正常完成的older entry各计1。`ImeTrapBoundaryAck`只能在fault entry已以`minstret_delta=0` trap-consume且CSR/redirect durable后产生。

P1 的 pre-accept illegal 可由这一 single-owner 方案关闭；P3 不能沿用这个简化。当前 backend 已具备 `trap_valid_rvs2rvv -> UOP_LSU_t.trap_valid -> ROB -> trap_flush_rvv` 的内部骨架，但 top-level 将该外部 input 硬连 0，且现有 `Lsu2Rvv` 没有 fault bit。P3 开始前必须将**同一个** structured vector-fault event 同时用于 backend precise stop 与 scalar architectural trap，并验证一次性 ownership，例如：

```text
LSU -> rvv_fault(valid, macro_id, uop_id, faulting_i, PC, raw inst, cause, tval)
     -> {backend ROB trap/flush, one scalar FaultManager record}
RVV backend -> rvv_flush_ack(after no younger write/completion is possible)
```

`faulting_i` 必须是 raw logical element index，而不是 “completed count”；masked elements 使后者不能恢复 architectural `vstart`。该协议必须区分保留的 older work 和被杀死的 younger work；只清空全部队列会错误丢失 older result。它还必须断言 fault response 不生成 VRF write（当前 scalar-LSU bridge 对 non-last response 的行为正好相反）。当前跨域接口没有 fault metadata、age/tag 与 request/ack，故这一点不能由现有源码推导解决，是 P3 的明确硬阻塞。

### 4.3 P1 的正确实现 profile

P1 的 profile 是：

```text
instruction:        vmmacc.vv only
extensions:         Zvvi8mm, Zvvi16mm, Zvvi32mm
base-vector scope:  current configurable SEW set {8,16,32}
VLEN:               128
lambda capability:  Sλ(8)={2}, Sλ(16)={2}, Sλ(32)={2}
LMUL supported:     1, 2, 4, 8 (architectural lmul_orig)
vta behavior:       always write-skip C tail
execution policy:   system-level serial/fault-admission point; defer younger effects/interrupt until ImeOuterRetireAck or ImeTrapBoundaryAck
```

这个 profile 的公开范围以 §3.1 的 lambda scope gate 为前提；在该 gate 关闭前，它只是可实现的 CoralNPU design target，不是对所有 IME-legal `(VLEN,SEW)` 的无条件 ISA 声明。

最后一条必须升级为“IME到lane0后capture `ime_pending`，先满足`ime_admission_safe`，legal再满足`ime_accept_safe` fire，illegal再满足`ime_fault_safe` booking，直到对应outer-retire或trap-boundary ack结束”的全系统serializing policy，不是性能目标，且必须覆盖接受点而不只是execution unit：

1. IME instruction强制lane0-only；若初见lane k>0，先允许`[0,k)` older prefix drain并阻止k及younger，之后IME到lane0。接受周期不得有第二条RVV instruction fire；
2. 只有 §4.2 的 `ime_accept_safe` 成立时，IME 才能 fire；这包括 frontend/CQ/LCQ/UQ/RS/backend ROB/retire 无 older RVV work、coherent config snapshot、无 older scalar/float/LSU work 和无 pending fault；
3. 从fire到tagged outer-retire，或从pending到`ImeTrapBoundaryAck`，阻止IME lane及所有younger/普通RVV command入队和younger architectural effect；strictly-older prefix已在capture前drain。新到interrupt/debug/trigger/single-step延后到相应boundary；
4. `ImeOuterRetireAck`、`ImeTrapBoundaryAck`、global reset或已证明按age正确的kill/flush ack才可释放锁；booking ack、last-uop、aggregate empty/nRetired均不可。断言accepted/pending时无older in-flight且boundary前无younger effect。

之后若要并发，必须实现 group-range RAW/WAR/WAW scoreboard、age-aware flush，并证明与上述全串行语义等价。

IME engine 必须按 normative `(j,i)` 语义生成结果。首发P1冻结为独立bounded sequencer，**不**把C element compute分配进现有ROB/UQ，也不产生backend compute-uop completion；它服从 §4.5 的 shadow-C macro commit：

* 在command fire前完成全部 macro legality；
* 保持 macro ID、PC与immutable config snapshot；
* 对每个 active `j` 的所有 `i=0..M-1` 读取 A，并用shadow overlay bypass前面 `(j,i)` 结果到任何alias的A/B/C read，确保partial-N和live-alias语义；
* `N=0` 时必须生成一个**无写 `ImeCompletion` intent**：`macro_id`匹配、`pc=macro PC`、`last=1`，batch为0 lane；它仍携带immutable retire context，避免 Scalar RetirementBuffer等待不存在的VRF写；
* 对非零 N，compute期不产生VRF write。全部active C在shadow完成后，engine同时held唯一`ImeCompletion` intent与batch；batch lane永不携带PC/last或生成第二completion；
* 若为复用现有RB输入而设置adapter，它只能把该唯一`ImeCompletion`映射为`rd_valid_rob2rt_o/uop_pc/last_uop_valid`，并以macro_id扩展RB匹配；legacy fields不得再由write lane或其它producer驱动。该adapter必须无条件存在于production build，不能受`TB_SUPPORT`控制；
* macro commit的所有实际VRF写仍走backend retire/VRF byte strobe，不得旁路写VRF；P1最多4 lane必须在同一`ImeMacroCommit.fire`写完，不得把中间shadow state变成architecture-visible。

未来若要把active C拆成现有backend compute uop，必须先提交ADR并重新定义唯一completion owner、ROB/UQ bound与macro-commit proof；不得在首版实现中混用两套completion协议。

若未来选择支持`EMUL_C=16`，必须先分别扩：backend `EMUL_e`、alignment/index、uop/group iterator与macro commit容量；full RetirementBuffer profile仅用于debug/RVVI的8槽accumulator/3-bit offset；mini/full的tagged completion/outer-ack及所有断言。8槽trace结构不参与architectural readiness，但不扩会让trace错误；没有整组改动，`lambda=1,SEW=8`不可启用。

### 4.4 Machine-readable 规范与 capability manifest

P0开始RTL前必须创建 `ime/spec_manifest.yaml`并把它作为锁定PDF的规范转录；当前文档不能替代该资产。以下schema必须先物化并通过Draft 2020-12 meta-schema：`ime/schemas/{artifact_ref,signature_envelope,trust_store,release_authority,requirements,spec_manifest,phase_profiles,capability_catalog,delivery_variants,top_pin_abi,build_target_bindings,base_reference,capability_artifact_manifest,ime_build_identity,caller_inputs,workspace_prestate,implementation_manifest,change_manifest,architecture,interface_abi,engineering_targets,platform_async_events,verification_plan,coverage_plan,ci_matrix,risk_register,owners,capture_receipt,bootstrap_result,bootstrap_attestation,command_plan,command_result,result_set_attestation,finalization_result,closure_report,closure_attestation,closure_bundle_descriptor,release_manifest,release_attestation,release_bundle_descriptor,release_bundle_attestation}.schema.json`。所有schema必须 `additionalProperties=false`，显式给出type/required/enum/default和 `schema_version`；path/hash/identity/signature必须复用公共结构字段，禁止使用含空格的伪key、自由散文或`<placeholder>`替代字段。YAML输入转换为JSON后按RFC 8785 canonicalize并SHA-256，validator/tool版本也进入manifest。

稳定ID由以下确定性规则生成并由人工spec review签核：mnemonic先大写、非字母数字替换为单个 `-`；`INST-<MNEMONIC>`；`ENC-<MNEMONIC>-F6<hex>-F3<hex>-VM<0|1|X>`；表格cell为 `CELL-T<table>-R<printed-row-ordinal>-C<printed-column-ordinal>`并引用INST/ENC；非表格规则为 `RULE-P<printed-page>-N<normative-statement-ordinal>`；ISA extension为`ISAEXT-<canonical-extension-name-normalized>`。ordinal从页面左上到右下、只计normative statement且从1开始。`SW-*`来自§8批准的固定catalog，新项使用`SW-<domain>-<normalized-name>`并走CR；TEST/PROP/COV/WAIVER ID在APPROVED plan内人工分配且不得复用。architecture的`PRES-*`/`GUARD-*`、base-reference的`DELTA-*`和build-target binding exclusion的`EXCL-*`由各自APPROVED canonical artifact人工分配，必须全局唯一、不可改义/复用，并引用至少一条REQ；不得由hierarchy名字临时生成。

command/result ID只使用§7.6唯一`CORALNPU_IME_COMMAND_ID_V1`/`CORALNPU_IME_RESULT_ID_V1`规则：schema regex分别固定为`^COMMAND-V1-[0-9a-f]{64}$`和`^RESULT-V1-[0-9a-f]{64}$`，完整256-bit digest不得截断或追加suffix。其JCS payload只含plan-time analysis-known command common fields、closed subject key/source-record hash、scope和binding refs；comparison包含两侧record/final-config/reference refs，OFF_ONLY包含base/ref，均**不得**纳入plan冻结后才生成的DUT binary/netlist hash。实际artifact hash只由signed command result/result-set追加绑定。所有schema、fixture、generator和validator不得保留旧`CMD-...-H<12hex>`格式。任何ID collision或PDF改版必须失败，不得自动加随机suffix。完整catalog和phase-profile精确roots/hash在 `IMP-ENG-REQ-BASELINE`关闭前冻结；catalog缺失时caller不得填写猜测ID，也不得开始datapath。

规范事实和某个build的实现状态必须分层，禁止在同一个 `status`字段混合。manifest使用六个互相引用且全局前缀不重叠的record namespace；external gate保留`EXT-*`，ISA extension必须使用`ISAEXT-*`。下面代码块只是字段语义摘要，**真正可验证语法只以上述JSON Schema为准**：

```text
ENC-*  encoding_record:
  id, pdf_sha256, pdf_section, pdf_printed_page,
  raw_mask, raw_match, instruction_id, funct6, funct3,
  raw operand fields, vm/Llambda semantics, referenced_cell_ids

INST-* instruction_record:
  id, mnemonic, instruction_class, encoding_ids,
  operand_A_field, operand_B_field, vd_vs3_field,
  runtime_rule_ids,
  architectural_state, success_minstret_delta, fault_minstret_delta,
  success/fault trace_event_kind, external_gate_ids,
  required_implementation_gate_ids

CELL-* cell_record:
  id, instruction_id, encoding_id, pdf table/row/column,
  normative_status={legal,reserved},
  SEW, EEW_A, EEW_B, EEW_C, W, vm, input/output formats,
  signedness_A/B, consumed/ignored_vtype_fields, lambda/vstart/LMUL/EMUL rules,
  group alignment/bound/overlap/tail-mask rules,
  runtime_rule_ids,
  required_extension_ids_direct, external_gate_ids,
  required_implementation_gate_ids,
  architectural_state={read/write/unchanged for every named state},
  success_minstret_delta, fault_minstret_delta,
  success_trace_event_kind, fault_trace_event_kind

ISAEXT-* extension_record:
  id, name, base_dependencies, implies_direct, family_membership,
  required_instruction_ids, required_cell_ids, required_rule_ids,
  required_extension_ids_if_family,
  required_implementation_gate_ids

RULE-* state_rule_record:
  id, pdf location, subject, precondition, architectural transition,
  runtime_domain_partition, normative_status={legal,reserved},
  exception/side-effect rule, architectural_state,
  success/fault minstret delta and trace_event_kind where applicable,
  external_gate_ids, required_implementation_gate_ids

SW-* software_claim_record:
  id, requires_sw_ids,
  required_hardware_record_ids_or_derivation={INST/CELL/RULE/ISAEXT},
  required_external_gate_ids_or_derivation, required_implementation_gate_ids,
  required_assets_and_tests
```

`architectural_state`至少逐项列出VRF、memory、`vl/vtype/vstart/vxsat/vxrm/frm/fflags`、scalar register、`mstatus.VS/FS/SD`、`minstret`与debug/RVVI trace；不能只列主要数值结果。legal-success instruction/cell的`success_minstret_delta=1`；任何同步illegal或memory-fault transition的`fault_minstret_delta=0`。`vmmacc/vwmmacc/vqmmacc/v8wmmacc`必须显式写`A=inst[19:15]`、`B=inst[24:20]`和`vstart=0` requirement；四条tile load/store各自必须有`INST-*`并分别写VRF/memory、restart、success/fault minstret与trace effects，不能只靠ENC/RULE散文推导。

覆盖规则是硬门槛：

1. 每条architectural instruction mnemonic各自恰好一个`INST-*`；每条computational encoding、四个tile-LS encoding variant各自恰好一个`ENC-*`；PDF Table 87/88/89的每个row×column cell各自恰好一个`CELL-*`并引用instruction/encoding。一个encoding对应多个format/type cell是正常的，不能把二者错误合成“唯一一条record”；所有非表格WARL、restart、exception、tail、API等normative rule必须有`RULE-*`或traceability entry；
2. `normative_status`只由锁定规范决定，只能是`legal`或`reserved`，不随build改变；open外部依赖以`external_gate_ids`引用§2.1，不得把规范legal cell改写成reserved；
3. 每个`delivery_config_id`必须有两个variant overlay：`ime_off_baseline`与`ime_on_delivery`。每个overlay保存五类hardware状态：每个`ENC-*`的唯一pre-backend decode owner；每个`RULE-*`按互斥runtime-domain partition记录`{enforced_legal,enforced_reserved,illegal_feature_off,blocked_external}`；每个`CELL-*`记录`support={none,partial,full}`、精确`enabled_rule_ids/blocked_rule_ids`及逐rule decode behavior，另记录format-cell自身的`{illegal_reserved,illegal_feature_off,blocked_external}`原因；每个`ISAEXT-*`只保存两个布尔值`{direct_enabled,effective_enabled}`并验证`direct_enabled => effective_enabled`，disabled只能派生为`!effective_enabled`；每个`INST-*`记录`support={none,partial,full}`与精确`enabled_cell_ids/blocked_rule_ids`。overlay还必须单独导出只读`effective_legal_inst_ids/effective_legal_cell_ids`；它们只包含至少一个runtime partition为`enforced_legal`且所有dependency/gate已关闭的record，不得等同requested `enabled_*`。normative reserved只能映射illegal；legal runtime partition只有满足全部dependency/gate才能`enforced_legal`；外部门OPEN的partition必须`blocked_external`且pre-backend precise-illegal。任一required legal CELL/RULE仅partial时，parent ISAEXT不得effective-enabled，phase profile也不得COMPLETE；但CAPABILITY_DELTA可明确报告non-overlap等partial runtime subdomain。所有known IME `ENC-*`在off variant仍由IME pre-backend owner捕获后precise-illegal；claim只在on overlay检查其声明的partial/full support，off variant必须全部feature-off precise-illegal；
4. validator必须检查ENC/INST/CELL/ISAEXT/RULE/SW全覆盖、全局ID前缀不重叠、reference完整性、runtime-domain partition无gap/overlap、同条件mask/match collision、raw field mapping、normative-to-build状态合法转换、direct/effective ISA extension closure、software claim closure、feature-off/blocked precise-illegal、side-effect与`minstret`完整性。claim任一ISAEXT必须使其全部required INST/CELL/RULE及family member ISAEXT在每个delivery config的`ime_on_delivery` overlay中full/enforced；任何partial CELL或blocked legal RULE都禁止effective-enabled。每份`VARIANT`测试结果必须记录spec manifest hash、config/variant、overlay hash、`ImeBuildIdentity`和实际DUT binary/netlist hash；`OFF_ONLY_TARGET`记录相同证据并增加target label/binding record；`REFERENCE_COMPARISON`还必须记录config-specific reference binding、cycle/reference-model identity与artifact、input-domain/mask/delta-set hashes及off DUT证据；`VARIANT_COMPARISON`逐边记录两侧spec/config/overlay/identity/artifact字段。validator target固定为`//ime:ime_spec_manifest_test`，目标不存在即gate OPEN；
5. manifest可以生成RTL decode或expected test vectors中的一侧，**不得同时生成DUT decode与其唯一oracle**。至少一份decode checker、arithmetic/reference model和reserved/feature-off truth table必须从锁定PDF独立实现、不复用DUT helper，避免同源错误自证正确。

P0还必须创建并锁定 `ime/phase_profiles.yaml`，防止空claim或任意子集被冒充为阶段完成。每个profile record至少包含：

```text
phase_profile_id, phase_id,
required_claim_root_ids,
required_foundation_delta_root_ids={ENC/RULE roots fixed by profile},
required_delivery_scope, required_software_root_ids,
required_cumulative_implementation_gate_ids,
required_external_gate_ids,
required_config_variant_test_ids,
minimum_coverage_contract
```

`phase_profiles.yaml`不保存completion scope；`completion_scope_kind`只作为caller-owned request selector存在。validator规定 `PHASE_PROFILE`必须使用profile全部固定roots，`CAPABILITY_DELTA`必须使用同一profile作为baseline但只能产生delta COMPLETE/phase PARTIAL；caller不能改写profile内容。

其中 `P3-TILELS-MMODE-NOMPRV` full phase profile固定 `required_delivery_scope=hardware-and-software`，且 `required_software_root_ids`至少包含 `SW-C-TILELS-INTRINSICS`与适用的 `SW-M16-PSEUDO`传递闭包、授权toolchain workspace及其exact commands；因为§P3把C tile I/O/compiler pair-unpair列为非可选交付。caller选择hardware-only时只能用 `CAPABILITY_DELTA`并报告phase PARTIAL，不能关闭 `IMP-P3-C-IO-ABI`或报告P3 COMPLETE。

固定profile ID为 `P0-FOUNDATION`、`P1-INT-W1-SEW8-32-L2`、`P2-INT-PACKED-PINNED-PDF`、`P3-TILELS-MMODE-NOMPRV`、`P4-FP-MX-P4-N0`。P0 profile允许hardware claim集合为空但其foundation gate/test集合非空，并必须固定授权VSET/vtype/VS-SD/default-off decode ownership所需的ENC/RULE foundation delta roots；caller不得删除或改写这些roots。P1--P4的 `required_claim_root_ids`必须非空并由 `spec_manifest`中的稳定INST/CELL/ISAEXT ID组成。若caller只授权某个cell子集，只能使用独立delta request（见下一段），即使该delta全部通过也只能报告“delta COMPLETE / phase PARTIAL”。full phase profile必须满足本节固定root的传递闭包；P2/P4仍允许逐cell实现，但在全部required roots闭合前状态保持PARTIAL/BLOCKED。

对授权与actual capability变化必须做双向delta检查。effective roots固定为：`required_foundation_delta_root_ids ∪ profile_claim_roots ∪ caller_additional_delta_roots`，其中`PHASE_PROFILE`的`profile_claim_roots=required_claim_root_ids`且caller `authorized_delta_root_ids`必须为空；`CAPABILITY_DELTA`的`profile_claim_roots=[]`、`caller_additional_delta_roots=authorized_delta_root_ids`。要在full profile上增加能力必须新建profile/ADR，不能让caller临时扩根。从该并集计算 `authorized_delta_closure_ids`。capability delta的唯一可计算定义是**同一post-change source/config的 `ime_on_delivery` overlay相对 `ime_off_baseline` overlay**，逐config生成 `actual_capability_delta_ids_by_config`并强制 `unauthorized_delta_ids=[]`；不得声称从只含git diff/tar的prestate直接恢复旧overlay。源码文件级before/after由workspace-prestate/change-manifest独立审计。有CELL matrix的computational INST不能脱离精确CELL/RULE集合产生模糊capability claim。applicable implementation gates是“全部前置phase gates + phase-profile固定gates + claim传递闭包中每个hardware/SW record的 `required_implementation_gate_ids` + scope/platform gates”的并集；OUT_OF_SCOPE gate不进入该集合，但validator必须证明它不能被claim/dependency闭包重新引入。

extension closure 也必须进入 manifest，不能散落在 `ifdef`。PDF Table 86 的固定 implication 是：

* FP-input MX BS32 `Zvvx...` 蕴含其对应 unscaled FP IME extension；BS16 `Zvvxn...` 蕴含对应 BS32 `Zvvx...`，再传递蕴含 unscaled extension；
* integer-input MX BS32 `Zvvxi...` **不**蕴含 ordinary integer或 FP-input base IME；BS16 `Zvvxni...` 只蕴含对应 `Zvvxi...`；
* decoder legality 使用传递闭包。例如启用一个 FP BS16 extension 必须同时使对应 BS32/unscaled cell legal；启用 integer BS16 只能使其 integer BS32 cell legal，不能误开普通 `vwmmacc/vqmmacc`；
* Table 73 的 FP type extensions必须携带 base dependency：非 FP64 accumulator row 依赖 `Zve32f`，FP64 accumulator row 依赖 `Zve64d`。integer-input MX 的 base dependency未在 PDF 中闭合，相关`CELL-*`引用对应external gate；其build overlay保持`blocked_external`且decode为precise illegal。

caller先在调用消息中提供§9字段和所有repo path。**任何task-owned workspace写入前**，agent必须用§7.6的trusted host-side git/hash命令把CoralNPU及每个software toolchain repo原始状态保存到repo外只读临时目录；随后才可逐值原样序列化`caller_inputs.json`和修改源码。修改完成后，`ime_workspace_prestate_import`把该原始证据校验并规范化为`workspace_prestate.json`；它必须记录每个repo的`repo_path,base_commit,status_z_sha256,tracked_binary_diff_sha256,untracked archive SHA-256及逐entry path/type/mode/regular-bytes-hash或symlink-target,raw_bundle_sha256`，并排除自身避免自引用。preexisting untracked的原始bytes/metadata来自deterministic tar archive，不能只存会跟随symlink的`sha256sum`；特殊device/socket/FIFO必须拒绝且不得修改。若原始capture缺失/可写/校验失败，停止且不得伪造preexisting状态。

source修改完成后，implementation generator同时读取caller inputs与workspace prestate，做schema、placeholder、scope/dependency和artifact-hash校验，再生成**pre-test as-built** `implementation_manifest.json`；不得再把它称为preflight manifest。它由同一elaboration capability source产生或与其双向校验，至少记录：schema version、caller-input/prestate file hash、base commit、IME PDF与本地RISC-V dependency artifact path/hash、`requirements/spec_manifest/phase_profiles/capability_catalog/delivery_variants/build_target_bindings/base_reference/architecture/interface_abi/engineering_targets/platform_async_events/owners/risk_register/verification_plan/coverage_plan/ci_matrix`的独立canonical hash、XLEN/VLEN/endianness、固定的`standard_status=experimental-pinned-pdf`、`delivery_scope`、phase-profile/caller request selector、hardware/software claim IDs、`delivery_config_ids`及每个config的off/on variant exact build/test/lint labels、静态module/artifact名、variant record/effective-set hash、derived presence、expected `ImeBuildIdentityV1`、off-guard allowlist hash、common generated Scala/lock及每target五个固定sidecars、所有非交付Core/SoC/FPGA target的sealed off-only binding、privileged scope、逐variant ENC owner/INST/CELL/RULE/ISAEXT overlays、`lambda_by_sew`、IME-disabled behavior、实际macro-ID/epoch/decode-ID widths、agent核验的**external-only** gate disposition、applicable `IMP-*` ID/验收条件（当前tree的pre-test状态固定OPEN）、`prior_phase_evidence_refs`（仅作非权威定位，不能继承PASS）、`authorized_delta_root_ids`/`authorized_delta_closure_ids`/`actual_capability_delta_ids_by_config`/`unauthorized_delta_ids`。P3还记录memory/PMA/effective-privilege profile；P4还记录Zvfbfa、OCP MX/IEEE/RISC-V format artifacts及numeric-profile/SAIL的path/hash，并固定 `invalid_frm_behavior=illegal_instruction`。所有前置phase gate必须针对当前post-change tree重验。实际DUT binary/netlist hash只能由后续trusted build result记录，不能预填进pre-test manifest。测试后IMP gate状态不得写回这份冻结manifest，只进入closure report。手写一份与RTL elaboration参数无关联的JSON不合格。

在任何delivery build/test前必须再冻结`ime/closure/<phase>/change_manifest.json`：递归列出本任务全部post-change RTL/source/build/test/spec/canonical-ABI/caller-input/workspace-prestate/implementation-manifest等`source_input`的path、tracked/untracked状态、preexisting hash（若存在）与final content SHA-256，并计算按path排序的`post_change_source_tree_hash`。为避免时序/自引用，它排除自身以及之后才生成的`command_plan.json`、bootstrap/finalization/command results、log、`closure_report.json/.md`与pre-closure attestation；这些统一标为`generated_evidence`，分别由plan hash和detached attestation绑定。post-closure的`release_manifest.json`、release attestation、release bundle descriptor和detached bundle attestation统一标为`generated_release_evidence`，按§7.6的signed closure→release manifest→release attestation→bundle descriptor→bundle attestation单向链绑定，bundle attestation是签名终点；其后只允许产生不参与签名的可重算inventory。两类generated evidence均不属于source-tree hash。implementation manifest不得反向嵌入change-manifest hash。每个test result必须记录**外部计算的**change-manifest file hash与source-tree hash，`ime_repository_hygiene_test`按schema同时验证`source_input`零遗漏、两类generated evidence未误纳，而不是读取尚未完成的closure report。最终closure report只引用source hash和pre-closure command results；不得在写回report后为了“记录最新命令”无限重跑同一test。若结果未commit，这个source-tree hash而非base commit才唯一标识实际被测实现。

若software claim授权了CoralNPU之外的toolchain workspace，每个root必须有独立preexisting/final file manifest与source-tree hash，并由Coral closure记录aggregate hash和该repo的exact hygiene/build/test结果；不能因主change manifest位于CoralNPU就漏掉外部compiler/binutils修改。

### 4.5 IME 内部 transaction ABI

P0 修改 datapath 前必须提交并冻结canonical `ime/closure/P0/interface_abi.yaml`，用`interface_abi.schema.json`验证并按RFC 8785 JSON形式hash；`interface_abi.md`只能由该YAML单向生成用于评审，禁止反向编辑或作为canonical approval/hash输入。`RvvCore.scala` inline generator 是 wrapper source of truth；禁止直接修改 Bazel 临时生成的 wrapper。每条 ABI 要列 producer、consumer、每字段宽度、handshake 方向、owner、reset/flush 与 acceptance 定义。最低集合如下。

所有fault/RB/trap边界使用同一closed tagged union `ImeAgeTag` 而不是伪造`macro_id=0`：`{kind=PRE_ACCEPT,scalar_age_id[IME_SCALAR_AGE_W-1:0]}`只用于feature-off/blocked/pre-accept illegal，`{kind=ACCEPTED_MACRO,macro_id[IME_MACRO_ID_W-1:0]}`只用于已accept legal macro及其P3 runtime fault。`IME_SCALAR_AGE_W`、`IME_MACRO_ID_W`、tag bit和payload bit slice必须在ABI/build manifest中为具体整数并与RetirementBuffer age实现逐bit核对；两个variant不存在“隐含转换”。

| ABI | Producer -> Consumer | 必备 payload/语义 |
| --- | --- | --- |
| `ImeConfigSnapshot` | coherent vector-config owner -> Decode/macro-capture owner | immutable `{vl[7:0],vstart[6:0],vill,vsew[2:0],lmul_orig[2:0],vta,vma,lambda[2:0],bs,altfmt_A,altfmt_B,altfmt}`；architectural `vta/vma`映射现有RTL`.ta/.ma`；该接口不产生instruction-dependent decode_id，也不伪装成privilege/v0/scalar operand/frm producer |
| `ImePrivilegeSnapshot` | scalar CSR program-order owner -> macro-capture owner | 仅privileged scope需要的immutable `{vs[1:0],fs[1:0]}`；所有IME消费VS，P4再消费FS；bare-metal exclusion必须由manifest静态选择，不能用任意常数假装privileged检查 |
| `ImeMemoryContextSnapshot` | scalar privilege/MMU/PMP/PMA program-order owner -> P3 macro-capture/LSU | 首版M-mode/no-MPRV/no-translation profile固定为显式常量并由assertion证明；未来MPRV/translation profile必须immutable捕获 `{effective_privilege,MPRV,MPP,translation context/PMP/PMA profile generation}`或以全序列化证明其在macro期间不变，并定义older CSR/SFENCE可见性；不能用仅含VS/FS的 `ImePrivilegeSnapshot`替代 |
| `ImeFrmSnapshot` | scalar FCSR program-order owner -> P4 macro-capture owner | 所有P4 profile都必须提供immutable`frm[2:0]`，与privileged scope无关；`frm` CSR本身保持完整3-bit RW，软件写5/6/7必须原值读回，不能在CSR write时clamp成RNE；reserved behavior只在随后P4/vector-FP ingress按本profile映射illegal，accept前检查`frm<=4` |
| `ImeRbEntryEnq` | scalar Decode/fetch owner -> RetirementBuffer | 这是现有lane0 `io.inst.fire -> instBuffer` enqueue的IME metadata/替代分支，**不是附加第二enqueue channel**。pre-accept legal/illegal每次恰使RB entry count+1；legal payload `{isIme=1,isImeFault=0,age_tag.kind=ACCEPTED_MACRO,macro_id,pc,raw}`，illegal payload `{isIme=1,isImeFault=1,age_tag.kind=PRE_ACCEPT,scalar_age_id,pc,raw}`。accepted P3 runtime fault更新已有legal entry的fault metadata，**不得再次enqueue**。legal fire必须与`ImeCommand.fire/fetch_lane0.fire`相等，pre-accept illegal的`fire&&isImeFault`必须与`ImeFault.fire/fetch_lane0.fire`相等。entry不走ordinary nonWriting/RVV-PC-only完成；legal只由matching MacroCommit退休，fault只由matching `ImeAgeTag` trap-consume且`architectural_retire=0`移除 |
| `ImeAccept` / `ImeCommand` | scalar program-order/macro-capture owner -> IME engine | `{macro_id,pc[31:0],raw[31:0],decode_id[IME_DECODE_ID_W-1:0],config_snapshot,applicable privilege_snapshot,applicable frm_snapshot,operand fields}`；`decode_id`是manifest生成的tagged namespace：computational form指向具体`CELL-*`，无CELL的tile-LS指向`INST-*`，不得用隐含0；`IME_DECODE_ID_W`及tag/index bit slice在ABI中为具体整数。P3附加接受前读取的`v0_mask_snapshot[127:0]`和scalar address operands，P4附加接受前读取的`v0_scale_snapshot[127:0]`；禁止保存live reference或执行时重读CSR/scalar/VRF；P1一次fire恰好创建一个macro且必须与matching `ImeRbEntryEnq.fire/fetch_lane0.fire`为同一事件 |
| `ImeFault` | Decode/LSU fault owner -> global fault coordinator | sticky Decoupled `{age_tag:ImeAgeTag,pc[31:0],raw[31:0],cause[31:0],tval[31:0],logical_i if P3}`；Decode的feature-off/blocked/pre-accept illegal必须使用`PRE_ACCEPT`，已accept的P3 runtime fault必须使用`ACCEPTED_MACRO`。Machine ISA §3.1.16 允许 illegal-instruction trap 的非零 `mtval`返回实际faulting instruction bits，本 RV32 CoralNPU profile固定P0/P1 illegal的 `tval=raw[31:0]`，不得有时为0有时为raw；ready 表示 durable precise-trap booking capacity，不是组合 priority |
| `ImeFaultBookingAck` / `ImeTrapBoundaryAck` | `ImeFault.fire` / scalar trap-take owner -> serial barrier | booking ack不是额外接口，恰好是`ImeFault.valid&&ImeFault.ready`事件，只表示fault record已durable并允许producer清valid；boundary ack必须回传并逐bit匹配原`ImeAgeTag`，在record到达精确trap点、faulting instruction以`minstret+=0`被trap消费、CSR trap state与redirect建立后恰好一次返回；只有它能释放对应serial lock |
| `ImeVrfWrite` | engine/backend retire -> VRF/trace | `{macro_id,reg_idx[4:0],data[127:0],byte_strobe[15:0],actual_write_valid}`；只有`actual_write_valid`可使VRF/trace记录write，invalid/trap/no-write packet必须valid=0且strobe=0 |
| `ImeVrfCommitBatch` | P1 engine -> macro-commit coordinator -> four VRF retire lanes | 一个sticky Decoupled事务：`{macro_id,lane[4]{valid,reg_idx[4:0],data[127:0],byte_strobe[15:0]},no_write_completion}`。四lane共用**唯一** `valid/ready/fire`，无per-lane ready；producer在stall时保持整包逐bit稳定。P1的batch fire必须与下述`ImeMacroCommit.fire`为同一事件；所有valid lane的`reg_idx`两两不同，未用lane必须valid=0/strobe=0。`no_write_completion=1`当且仅当四lane均invalid/strobe=0。禁止拆成多次可见fire、部分ready、同址lane依赖现有OR-merge或写后回滚。由于本profile `lambda=2`且tail选择保持，`N=0`使用0 lane；`N>0`只允许`ceil(N/lambda)`个valid lane，分别写`vd+0..vd+ceil(N/lambda)-1`且仅active-byte strobe非零，而不是无条件写满EMUL_C个lane |
| `ImeCompletion` | engine/backend -> scalar retire/commit coordinator | 仅legal-success的sticky result-ready intent `{macro_id,pc[31:0],last=1,immutable retire state}`，与`ImeVrfWrite`独立；fault永远不是completion。它本身不得使RB retire或产生architectural write。P1/P2/P4中它与全部C batch、fflags/context intent同时held，并只在对应`ImeMacroCommit.fire`消费；P3只有在其phase effects已durable后才可assert。P1 `N=0`、P3 store/load success的packet本身都可没有VRF write，不能据此推断整个macro无memory/earlier-VRF effect |
| `ImeMacroCommitGrant/Fire` | RetirementBuffer + VRF/CSR/trace readiness -> commit coordinator | P1唯一architectural success boundary。`grant`只在matching macro为RB oldest且四VRF slots、适用时的context-status CSR port、success trace/minstret与ack buffer均可同edge接受时成立；`fire = held_batch_valid && held_completion_valid && (context_not_applicable || held_context_valid) && grant`。同一rising edge原子写全部valid C lanes、在privileged profile置VS Dirty/派生SD、产生一次success trace、RB retirement与`minstret+=1`，并consume batch/completion及适用的context intent；任一sink不ready则所有payload继续held且零side effect。`N=0`仍执行同一fire但VRF lane为0。禁止先写C再等待CSR/retirement，或先retire再补VS/SD |
| `ImeOuterRetireAck` | RetirementBuffer -> serial barrier | P1在`ImeMacroCommit.fire`后为matching macro恰好产生一次ack（允许同edge注册、下一edge可见）；P2/P4沿用等价atomic macro-commit，P3 success则要求全部earlier load/store effects与`vstart=0`已durable后退休。fault/illegal path永不产生；正常路径只有该ack能释放serial lock |
| `ImeFlushReq/Ack` | global age owner <-> accepted-macro IME consumers | `{age_tag.kind=ACCEPTED_MACRO,macro_id}`；该接口只用于已accept macro，pre-accept illegal没有engine consumer且不发dummy flush。`macro_id`已含epoch，禁止再并列一个可不一致的epoch字段。每个consumer先完成该fault transition manifest要求的动作再ack；ack后不得再产生**未列入该transition**的VRF/completion/fault/CSR/memory effect。P3 fault前已durable的older element load VRF writes与store effects按restart语义保留，fault boundary允许且要求`vstart/VS/SD`更新；scalar trap CSR/redirect由另一个带同一`ACCEPTED_MACRO` tag的`ImeTrapBoundaryAck`确认。严禁faulting `logical_i`及以后side effect，不能声称整个macro从未产生memory/VRF effect |
| `ImePreResetQuiesceReq/Ack` | reset owner <-> IME/LSU/AXI response consumers | **仅用于可预告reset且发生在local reset assertion之前**：req先禁止新accept，在clock仍运行时取消/排空outstanding；ack证明之后可拉reset且release后不会出现旧response。不得要求已处于reset的寄存器继续drain/回ack |
| `ImeMemReq/Resp` | P3 engine <-> LSU | §P3 的 immutable tag/logical index/address/data/kind/cause/tval；fault coordinator只有一个 event owner，backend ROB 与 scalar trap各自 durable ack |
| `ImeVstartUpdate` | P3 owner -> CSR | sticky `{macro_id,kind={fault,success},value[6:0]}`，保持至按 age durable commit；CSR read为 XLEN zero-extended |
| `ImeFflagsCommit` | P4 macro-commit coordinator -> CSR | sticky intent `{macro_id,flags[4:0]}`，一个macro只提交一次并按age与scalar-FP/software FCSR write合并；其ready是P4 `ImeMacroCommitGrant`合取项，fire必须与全部C lane、VS/FS/SD、success trace/minstret和RB retirement同一edge。stall时intent稳定且零side effect；禁止先提交flags再等retire，也禁止用OuterAck反向触发 |
| `ImeContextStatusUpdate/Ack` | macro/fault-boundary coordinator -> CSR | privileged scope的sticky `{macro_id,set_vs_dirty,set_fs_dirty}`；legal-success IME置VS，legal-success P4再置FS，accepted P3 runtime fault置VS，pre-accept illegal/killed-no-effect两者均0且不发事务。P1/P2/P4 success的`ready/fire`是各自`ImeMacroCommit`合取项且与全部C、适用fflags、RB retirement同edgedurable；P3 fault可用独立sticky handshake，但其ack必须进入trap-boundary合取。由更新后FS/VS/XS派生RV32 SD |

P1的4-lane物理接入点冻结在 `rvv_backend_retire.sv`：新增独立`ime_batch_valid/payload/commit_fire`端口，在现有normal ROB retire、trap mask、WAW/write-valid最终gating**之后**、`rt2vrf_wr_valid/data`输出**之前**放置all-or-none mux。`ime_batch commit_fire=1`时，normal `rt2vrf_wr_valid=0`且`rob2rt/rt2rob` ready/consume保持0，四个输出lane只来自held batch；普通cycle则batch输出全0且原normal path不变。禁止把batch伪装成四个ROB lane、穿过per-prefix ready/WAW消费，或在VRF之后旁路写。scalar `ImeRbEntry`由matching macro tag在同一个`ImeMacroCommit.fire`独立退休；backend RVV ROB没有该macro entry。formal必须证明两个mux source互斥、off variant mux恒选normal、每个batch valid lane在fire edge恰好写一次。

P1 第一版冻结为 **shadow-C atomic macro commit**，消除 element-uop 提前写 VRF 与 outer-retire 的矛盾：

* compute期间不产生architectural VRF write；最多保存P1 `EMUL_C=4`个register的modified-element overlay，tail byte保持invalid；
* 任何后续 A/B/C read若物理地址命中已写overlay，必须读取overlay的新值，否则读原VRF；因此实现PDF `j->i` live-alias semantics，但绝不snapshot全部source；
* 当前output `(j,i)`在`k<K_eff-1`期间的partial sum只存在独立`acc_q`，其C byte不得置`shadow_valid`或参与A/B/C overlay read。overlay-visible集合必须恰等于已按`j`外层、`i`内层词典序完成的outputs；final-k edge才以`mac_result_next`写当前C byte并置valid；
* 全部 active C完成后，在最多4个retire write lanes上以一个`ImeMacroCommit.fire`同时写最终active bytes、提交VS/SD并完成RB retirement；valid lane数为`ceil(N/lambda)`而不是EMUL_C，tail-only register绝不产生write/trace。之后只返回该fire的tagged outer-retire ack；不得跨多个可观察architectural instruction boundary提交；
* illegal在accept前结束；reset/已证明的kill只丢弃shadow。N=0不写shadow/VRF，只产生一次`ImeCompletion(last=1)`且零`ImeVrfWrite.actual_write_valid`；
* P2/P4 full profile沿用同一atomic model：所有C lane、P4 fflags、VS/FS/SD与RB retirement同一个`ImeMacroCommit.fire`。若适用CELL触及的C registers超过现有4个write lanes，该CELL保持disabled，直到ADR批准并实现足够的同edgecommit容量；首版不接受“多cycle先写一部分C、因barrier所以看不见”替代atomic proof，也不得恢复成element-uop early write。

第一版在`PRES-IME-LEGAL-COMMAND=true`时固定 `IME_MAX_INFLIGHT=1`；无effective legal command的P0/off record为0且不分配macro ID，feature-off/blocked fault booking使用`ImeAgeTag.PRE_ACCEPT`的独立scalar age ID。存在legal command时，`macro_id`是唯一accepted-macro跨模块身份字段，按冻结ABI打包为`{epoch,slot_id}`，其中 `IME_SLOT_W=max(1,ceil(log2(IME_MAX_INFLIGHT)))`、`IME_EPOCH_W>=1`；所有accepted-macro producer/consumer从该字段提取同一epoch，不得另传第二份epoch。实际位宽和bit slice必须在interface/build manifest中是具体整数。正确性不依赖“位宽足够大所以大概不会 wrap”：accepted macro ID在所有request/response、fault、flush、CSR、completion和outer-retire acknowledgement都已结束且跨域队列已证明quiescent前不得复用；`scalar_age_id`在matching trap-boundary ack前不得复用，两类wrap都必须有assertion。可预告reset使用上表的pre-reset drain；不可预告的ndmreset/async reset只有在platform artifact证明core、IME、LSU、AXI adapter/response buffers同reset域且reset原子取消outstanding、release后绝无旧response时才支持。否则P3 gate保持OPEN，不能等已经reset的模块回ack。必须注入跨reset延迟response，证明受支持contract下其不会到达或只被reset-domain外隔离并零side-effect，绝不能别名reset后的新macro。

所有 Decoupled/sticky ABI 统一满足：

* `valid && !ready` 时 payload 每一 bit 稳定，且一次 handshake 只消费一次；禁止用 one-cycle pulse 表达 fault、completion、retire 或 flush acceptance；
* flush后的旧epoch response只能丢弃且零side effect；reset必须在assert前完成`ImePreResetQuiesceAck`，或满足manifest锁定的common-reset atomic-cancel contract，不能只比较一个已回到初值的epoch；同一个architectural event不得由两个producer各自重建；
* P3 structured fault 只有一个 coordinator record，必须分别取得 backend ROB/flush 与 scalar trap 的 durable ack 后才能释放；RVV `ready=0` 或 scalar sink stall 不得丢 fault或先清 slot；
* legal-success path恰好产生一次architectural retirement、`minstret+=1`和一次成功instruction trace；pre-accept illegal或accepted P3 memory-fault path不产生`ImeCompletion/ImeOuterRetireAck`、不作architectural retirement且`minstret+=0`。若debug/RVVI接口报告faulting instruction，必须恰好一次标成trap event而非success/retired record；pre-accept illegal报告零vector writes，accepted P3 load fault的trap event必须保留并报告所有fault前durable load writes、不得包含faulting/younger write。内部element uop不得暴露成多条architectural instruction；
* 每个 ready、outer-retire ack、flush ack 的具体 durable 含义必须由 assertion验证，并以 directed backpressure/flush test证明状态可达；
* 必须为active set每个off/on artifact创建tuple-specific `ime_interface_width_*_test`（共`2N`个；首个profile为§7.6四个），逐项比较 Chisel `getWidth`、SV `$bits`、wrapper port/struct、presence/off-binding与consumer，并先核验DUT identity。现有 `-Wno-WIDTH/-Wno-WIDTHEXPAND/-Wno-WIDTHTRUNC` 不能作为通过证据。

### 4.6 冻结的逻辑架构、模块所有权与文件边界

P0/P1采用下列唯一逻辑分解。模块名是设计所有权，不允许LLM为了方便复制同一状态或新增第二owner；确需合并物理文件时，ABI和state ownership仍必须保持。

```text
scalar Decode / age owner
  -> ImeIngressController -> immutable snapshots -> ImeEngineP1
            |                               |      |
            | illegal                       |      | read addresses
            v                               |      v
      ImeFaultCoordinator                   |  ImeVrfArbiter -> existing VRF
            |                               |      ^
            |                               v      | atomic batch
            |                         ImeCommitCoordinator
            |                         -> VRF + trace + Completion
            v                                      |
      CSR trap + redirect                    RetirementBuffer
                                                   |
                                             OuterRetireAck

P2: ImeEngineP1旁新增ImeEngineP2；两者按各自effective presence独立elaborate并可共存，每条accepted macro按decode_id只路由到一个engine，共用同一VRF/commit边界
P3: 新增ImeTileLsu，复用同一ingress/age/fault边界
P4: 新增ImeFpMxEngine与ImeFcsrArbiter，复用同一commit/outer-retire边界
```

P1/P2/P4的**elaboration presence不是互斥枚举**：full P2/P4 artifact可以同时包含较早phase engine。每条legal encoding由`decode_id`静态映射到恰好一个engine，`ImeCommand.fire`时锁存owner；首版`IME_MAX_INFLIGHT=1`使任意周期的engine-active、VRF grant和commit-source grant均满足`onehot0`，直到matching outer-retire/fault boundary才释放。validator必须分别检查presence共存合法性与runtime owner onehot，禁止用“只实例化最高phase engine”丢失P1能力，也禁止同一macro广播到多个engine。

| Logical module | 冻结source ownership | owned state | 允许职责 | 禁止职责 |
| --- | --- | --- | --- | --- |
| `ImeCapabilities` | 新增 `ime/config/capability_catalog.yaml`、`delivery_variants.yaml`与`build_target_bindings.yaml`；analysis-known rule生成common sealed Scala/lock，静态Bazel targets再产生固定SVH/capability-JSON/build-identity-JSON/header/note五sidecars | 无runtime state | catalog定义可选能力/dependency，delivery与off-only variant instance为每个base config冻结选择；导出derived presence与build identity，二者共同构成唯一elaboration source | 不生成供同次analysis加载的Bazel fragment；不使用runtime hash路径、mutable setter或命令行define绕过variant；不生成DUT与唯一oracle两侧的decode truth |
| `ImeConfigController` | `RvvFrontEnd.sv`、`RvvInterface.scala`、`RvvCore.scala`、scalar CSR bridge | vl/vtype/vstart及coherent snapshot version | VSET/WARL/readback/forwarding | 不做instruction-specific CELL decode |
| `ImeIngressController` | `scalar/Decode.scala`为architectural owner；必要helper放新增 `scalar/ImeIngress.scala` | RVV build始终存在的feature-off minimal pending/age/fault booking；on才有legal macro allocator与frozen legality/snapshot | guard shell负责known encoding precise-illegal；on legal branch再做older-prefix drain、serial admission和command fire | off不得实例化legal-command/engine branch；不计算matrix result；不直接写trap CSR/VRF |
| `ImeEngineP1` | 新增 `hdl/verilog/rvv/design/rvv_ime_engine_p1.sv`，仅`has_p1_datapath`时由 `rvv_backend.sv`实例化 | P1 sequencer、shadow C、overlay-valid | 锁定j/i/k schedule、alias-aware read、batch formation | off/P0-only variant不得出现在elaborated hierarchy；compute期间不得architectural write/retire |
| `ImeEngineP2` | 新增 `hdl/verilog/rvv/design/rvv_ime_engine_p2.sv`，仅`has_p2_datapath`时由 `rvv_backend.sv`实例化 | P2 W/packing sequencer、shadow C、overlay-valid | 严格按已启用Table 88 CELL的W/EEW/EMUL/packing调度并形成atomic batch | 不复用P1 legality或默认W=1；P2 presence=false时hierarchy/state/VRF mux input必须消失 |
| `ImeVrfArbiter` | `rvv_backend.sv`与新增 `rvv_ime_vrf_arbiter.sv`，仅P1/P2/P4任一effective datapath presence为true时存在 | 仅registered owner select；不得缓存architectural data | 在唯一active IME engine owned期间把其read index复用到既有dispatch read ports，并把组合read data返回该engine；P1/P2/P4 owner必须onehot0 | off/无datapath时normal path必须generate-time直连且不存在IME mux；不新增VRF端口；不改变VRF storage |
| `ImeCommitCoordinator` | 新增 `rvv_ime_commit.sv` + `rvv_backend_retire.sv` + scalar `RetirementBuffer.scala`，commit source按derived phase presence条件elaborate | held commit batch、phase-commit status | P1单次最多4-lane原子VRF commit；P2/P4只在已实现足够同edgelane容量时enable对应CELL；completion/context/fflags/outer ack ordering | off时不得保留batch/commit mux与clocked state；不重新计算legality/result；不接受部分batch或多cycle early C write |
| `ImeFaultCoordinator` | `SCore.scala`、`FaultManager.scala`、`RetirementBuffer.scala`，可新增 `scalar/ImeFaultCoordinator.scala` | 单一durable fault record/ack bitmap | backend flush与scalar trap一次性协调 | 不从write/load bit猜cause/tval；不产生第二trap |
| `ImeResetController` | 新增 `rvv_ime_reset_ctrl.sv` + Shim gate；仅`PRES-IME-LOCAL-RESET`为true时elaborate | two-flop release sync、`ime_reset_done` | async assert、local sync release、accept quarantine | pure off guard不得实例化该controller或新增专用reset-release synchronizer的flop/clock load；`GUARD-*` allowlist内为precise-fault协议所必需且`max_count/max_bits`有界的clocked state是唯一例外；不跨clock transport data |
| `ImeTileLsu` | P3新增 `rvv_ime_tile_lsu.sv`及scalar LSU adapter | logical_i、one outstanding transaction、restart candidate | P3 request/response/fault/vstart | P0/P1 build必须elaboration-disabled |
| `ImeFpMxEngine/ImeFcsrArbiter` | P4新增独立SV + scalar CSR arbiter | FP exact-reduction/flags commit state | P4 numeric与single-age fflags commit | artifacts/gates未闭合时不得elaborate active datapath |

跨逻辑模块禁止直接窥视内部寄存器；只能通过§4.5 versioned ABI。每个owned state在 `architecture.yaml`恰好出现一次，validator对重复owner报错。

### 4.7 Clock、reset、CDC/RDC与组合路径契约

首版只允许一个功能clock domain：

| Interface/module | clock | reset | release/quiet contract | CDC |
| --- | --- | --- | --- | --- |
| ingress/config/scalar coordinators | `RvvCoreShim.clock` | top-level async reset | reset期间所有IME valid/ready-side effect为0 | none |
| P1 engine/commit/RVV VRF | 同一clock | local `ime_rstn` | `rstn` async assert；通过2-flop synchronizer local sync deassert；`ime_reset_done`前ingress不得accept/fault | none |
| P3 LSU/AXI adapter | 首版必须同一clock/reset cancellation domain | 平台profile锁定 | 若response buffer不受同一reset，必须显式CDC/reset-isolation FIFO；当前未证明故P3 BLOCKED | P3 artifact决定 |

`PRES-IME-LOCAL-RESET=true`时，`ImeResetController`的两个release flops必须带async clear；`ime_reset_done`只在连续两个有效clock edge后置1。pure off guard不实例化该controller；它的`ime_ingress_reset_done`由已有scalar/top reset domain的release-qualified状态直接派生，第一个post-release edge前所有guard valid/fault side effect为0，不允许新增专用reset-release flop/clock load或伪造常量1。为实现known-encoding precise-fault协议而保留的pending/age/fault clocked state只能来自`GUARD-*` allowlist，并必须满足逐项`max_count/max_bits`上界；它不是local reset synchronizer。FSM中的`ime_reset_done`统一指该derived `ime_ingress_reset_done`；当local controller存在时它逐bit等于local `ime_reset_done`。known IME instruction在其为0时保持在ingress并对younger施加backpressure，不得掉入generic discard/trap。assert reset时，所有IME `valid`、write strobe、completion和CSR update必须在同一或更早edge归零；deassert任意相位随机化并检查recovery/removal。

虽然clock相同，top reset域与local `ime_rstn`域的release edge不同，必须作为RDC而不是“CDC=0”忽略。跨域清单固定为scalar ingress/config/fault侧到engine/commit的command、snapshot、valid/ready，以及engine返回的batch/completion/ack/error。对每条路径，`ime_reset_done=0`时发送valid=0、接收ready视为0、payload不采样，返回valid/ack/write/context side effect=0；只有quarantine两侧都观察到同一同步后的`ime_reset_done`才允许握手。reset assertion仍用共同async path立即清两侧owned valid。

P0/P1 lint必须分别证明功能CDC crossing数为0和上述RDC crossing全部命中批准的quarantine pattern；再执行recovery/removal、任意相位deassert、短assert pulse与“top域已release/local域仍reset”的partial-reset formal。任一未枚举RDC或unconstrained return path使`IMP-P0-RESET-RDC=OPEN`。新增第二clock、clock gating crossing或异步response path必须新建ADR、CDC REQ、synchronizer/FIFO ABI和formal proof；不能只在报告中写“CDC无问题”。

ready/valid组合路径规则：producer `valid/payload`不得组合依赖consumer `ready`；任一 `ready`链最多跨一个模块且不得回到其源形成环；跨Chisel/SV wrapper的sticky transaction至少一侧必须有register slice。lint/formal必须证明无combinational loop，并在ABI记录 `registered_valid/registered_ready/max_comb_depth`。

### 4.8 P0/P1 FSM、事件优先级与liveness

#### 4.8.1 Ingress/serial FSM

| State | invariant | transition/event | next |
| --- | --- | --- | --- |
| `I_RESET` | 零pending/valid/side effect | `ime_reset_done` | `I_IDLE` |
| `I_IDLE` | 无IME macro owned | packet首次发现IME lane k | `I_DRAIN_PREFIX` |
| `I_DRAIN_PREFIX` | lane k及younger held，strictly-older可推进 | IME到lane0且older清空 | `I_WAIT_SAFE` |
| `I_WAIT_SAFE` | snapshot/legality frozen，阻止younger effect | legal && `ime_accept_safe` | command fire，`I_WAIT_OUTER` |
|  |  | illegal && `ime_fault_safe` | fault fire，`I_WAIT_TRAP` |
| `I_WAIT_OUTER` | legal macro barrier held | matching `ImeOuterRetireAck` | `I_IDLE` |
| `I_WAIT_TRAP` | illegal barrier held | matching `ImeTrapBoundaryAck` | `I_IDLE` |

不得增加“fire后立即IDLE”捷径。`I_WAIT_SAFE`的legality和snapshot在stall期间逐bit稳定；command和fault分支互斥且完备。

#### 4.8.2 P1 engine FSM

| State | entry/action | transition | next |
| --- | --- | --- | --- |
| `E_RESET` | 清shadow/valid/batch | `ime_reset_done` | `E_IDLE` |
| `E_IDLE` | 无owned macro | `ImeCommand.fire && N==0` | 锁存macro/snapshot且禁止任何VRF read，`E_NO_WORK` |
|  |  | `ImeCommand.fire && N>0` | 初始化j=0,i=0,k=0，`E_EXEC` |
| `E_NO_WORK` | 所有read valid/MAC/shadow strobe为0 | 无条件形成0-lane no-write batch、Completion intent与context intent | `E_COMMIT_HELD` |
| `E_EXEC` | 每cycle严格执行一个scalar MAC；k=0同时从第3 read port读取当前C/overlay | 最后(j,i,k)完成 | 形成完整batch，`E_COMMIT_HELD` |
|  |  | 当前output未完成 | k++ |
|  |  | output完成且还有i/j | 按PDF顺序更新i/j、k=0 |
| `E_COMMIT_HELD` | batch、Completion intent、所需context intent整包稳定，零write/retire | `ImeMacroCommit.fire`（同时消费三者） | 锁存`commit_done=1`，`E_WAIT_OUTER` |
| `E_WAIT_OUTER` | 不再访问VRF/改batch/发Completion | matching `ImeOuterRetireAck` | 清macro，`E_IDLE` |

最后一个MAC形成batch时，lane data必须取“包含本cycle final MAC结果”的`shadow_next`，不能在同一`always_ff`中用NBA从旧`shadow_q`装载；实现必须显式计算`mac_result_next/shadow_next/batch_next`并用formal assertion对照。若改为另加finalize cycle，必须先走ADR并修改本节FSM和§4.9精确延迟式。

事件优先级固定：

1. global reset assertion；
2. accept前已经存在的older trap/debug/reset request；
3. accepted P3 memory fault或manifest允许的element-stop；
4. normal phase commit/completion；
5. interrupt/debug/trigger/single-step等可延迟event。

accepted P1/P2/P4期间除global reset外，第5类只置pending并等待outer ack；illegal期间等待trap-boundary ack。NMI若不可延迟则该platform profile不支持首版IME，除非提供rollback/kill proof。两个同优先级事件同到时必须由oldest macro ID/architectural age选择，禁止组合priority随ready变化。

liveness不得只写“最终会ready”。`engineering_targets.yaml`必须为older drain、fault booking、commit ready、CSR update和outer retirement分别给出 `max_wait_cycles`；formal使用这些bound建立assumption/guarantee并覆盖每个held state最终退出。任一bound缺失时可证明safety但不能关闭deadlock/performance gate。

### 4.9 P1 datapath、资源调度与性能模型

首版选择correctness-first的**单scalar-MAC/cycle**实现，禁止LLM自行改成并行reduction、source snapshot或element-uop early write：

| Resource | 冻结分配 |
| --- | --- |
| VRF read port 0/1 | `ImeVrfArbiter`选择当前k的A/B physical register；engine先查shadow overlay，再使用VRF data |
| VRF read port 2 | `ImeVrfArbiter`在k=0时选择当前C physical register；其它cycle地址固定0且数据忽略 |
| VRF read ports 3--5 | 保留给现有backend；IME ownership期间全部普通dispatch/uop valid必须为0，避免“读端口无ready”造成隐式竞争 |
| VRF write lanes 0--3 | 仅 `ImeVrfCommitBatch.fire` 同一cycle使用；同周期普通retire write必须为0，所有valid lane的`reg_idx`两两不同 |
| shadow C | 4×128=512 data bits + 4×16=64 byte-valid bits；不是architectural state |
| queues/IDs | command depth=1、commit batch depth=1、IME_MAX_INFLIGHT=1 |
| arithmetic | 对P1 SEW=8/16/32执行signed/unsigned multiply并在SEW位modular accumulate；一个dependent MAC/cycle |

现有 `rvv_backend_vrf.sv` 明确把dispatch read定义为current-cycle return，`vrf2dp_rd_data`由register array组合索引；因此首版可以在一个cycle完成一个dependent scalar MAC，但该组合路径仍须满足已批准clock constraint。令 `C_ops=M*N*K_eff=M*VL`（最后一个等号仅对P1的`W=1`成立）。周期测量定义为两个handshake所在rising edge的序号差；在commit sink从`E_COMMIT_HELD`起持续ready、无reset且command已accept时，冻结：

```text
L_command_fire_to_commit_fire = 1 + max(1, C_ops)
```

`C_ops>0`时，command fire后的下一个edge完成第一个MAC，连续每edge一个，最后一个MAC写入shadow并形成registered batch，再下一edgefire；`C_ops=0`时第一个engine edge形成no-write batch、再下一edgefire。不得插入未建模bubble。outer retirement、admission wait和commit backpressure不含在此式内，分别受§4.8 fairness bound约束。验证对全部合法(SEW,LMUL,VL)测量edge差并断言严格等于该式；若32-bit combinational MAC不能满足clock、或实现需要pipeline/II变化，必须先新建ADR，更新FSM、alias-forwarding、公式、PPA budget与全部ordering proof，不能只放宽test timeout。

首版不得新增VRF physical port、architected register或无界uop allocation。elaboration必须断言 `VLEN==128 && NUM_DP_VRF>=3 && NUM_RT_UOP==4 && IME_MAX_INFLIGHT==1`。综合报告必须单独列IME engine/shadow/control的cell area、critical path和clock-gating opportunity；没有 `engineering_targets.yaml`只能报告功能进展，不能release。

### 4.10 Capability生成链、schema与内部错误策略

IME在本设计中是**elaboration/build-time可配置项**，不是运行时模式。一个已经elaborate的artifact在reset前后都不能改变variant；首版禁止用CSR、fuse、top-level pin、AXI寄存器、Verilog plusarg、环境变量、`--define`或软件写入临时启停IME。若未来需要runtime enable，必须另建ADR和独立profile，定义发现机制、权限/虚拟化、quiesce、在飞macro处理、state清理、trap语义与安全证明；不能复用本节布尔常量。

首版产品层只有一个二值选项，但实现层仍以sealed variant而不是裸布尔值传递：

| product option | canonical variant | `enable_ime` | Bazel target binding | 交付含义 |
| --- | --- | --- | --- | --- |
| `ime=off`（默认） | `ime_off_baseline` | false | 现有非`_ime` release target永久显式绑定off record | 默认产品、base-RVV基线和rollback artifact；不声明任何IME ISAEXT |
| `ime=on` | `ime_on_delivery` | true | 只有新增`*_ime_*` target可绑定on record | 只使variant closure列出的IME能力可用；global bit本身不使任何instruction legal |

不提供公开mutable `Parameters.enableIme` setter。实现必须把生成的`ImeVariantRecord`作为`Parameters`的immutable成员，代码若需要兼容名字，只能定义`def enableIme: Boolean = imeVariant.enableIme`这样的只读derived constant。所有delivery与off-only record的`variant_record_ref`全局唯一；唯一analysis selector是Bazel target/macro封存的`ime_variant_record_ref`，emitter内部只接受一次exact argv `--imeVariantRecordRef=<ref>`。`config_id/variant_id/base_config_id`全部由所选record派生并只作identity/manifest交叉检查，不能参与第二次lookup；这使`config_id=null`的off-only target仍有合法selector。`EmitCore`不得新增可单独覆盖它的`--enableIme=True`或独立config/variant参数。直接运行emitter只可作为non-authoritative开发动作，不进入release plan。解析器必须exact-match并拒绝duplicate/unknown/prefix-spoofed选项，不能沿用当前`startsWith`产生第二入口；选择后从compiled sealed catalog取record并重算hash，不能由argv传入能力位或伪造hash。

现有大量`new Parameters`调用不能靠新增一个默认off参数蒙混迁移。API固定拆成无默认值的sealed elaboration context：`CoreElaborationContext(coreBaseBuildConfig,imeVariantRecord)`和`NonCoreElaborationContext(nonCoreConfigId)`。只有`Parameters.forCore(context)`可传给`Core/CoreAxi/CoreTlul/RvvCore`，这些constructor入口必须type/assert拒绝NonCore；peripheral/TLUL helper只可使用`Parameters.forNonCore`且无IME selector。raw `new Parameters`/`Parameters()`在迁移后由source lint禁止。`CoreTlulParameters`、`ChiselModuleConfig`和SoC instantiate path显式携带`core_base_build_config_ref + ime_variant_record_ref`，缺失不得隐式补off。

P0必须生成constructor migration inventory，语法分析workspace内每个`new Parameters`/factory调用并记录`path,line,owner_kind={CORE,NON_CORE},factory,base_config_ref,variant_ref_or_null`；所有实际Core/SoC/emitter/test callsite必须是CORE且variant非null，peripheral-only才可NON_CORE，zero unclassified。Scala依赖图固定无环且`Parameters.scala`只编译一次：`ime_capability_types_scala`（手写sealed types、无CoralNPU依赖）→`coralnpu_params`（唯一拥有`Parameters.scala`）；`ime_capability_types_scala`→generated `ime_capabilities_scala`（只实例化records）；`coralnpu_base`和SoC/emitter同时依赖`coralnpu_params + ime_capabilities_scala`。必须从`coralnpu_base.srcs`移除重复`Parameters.scala`，禁止两个jar各自定义同名class。

capability配置拆成三个职责不重叠的canonical人工输入：

* `ime/config/capability_catalog.yaml`：定义允许出现的INST/CELL/RULE/ISAEXT、dependency、互斥、gate与参数范围，不选择delivery enable；
* `ime/config/delivery_variants.yaml`：逐`base_config_id × variant_id × record_revision`实例化catalog。root是closed `{schema_version,records[],active_variant_sets[]}`；每个approved phase/revision的active set对每个config恰有`ime_off_baseline`和`ime_on_delivery`。每条record required fields固定为：

```text
schema_version=1, base_config_id, config_id=base_config_id,
variant_record_ref, variant_id, record_revision:uint>=1,
binding_kind=DELIVERY_VARIANT,
variant_wrapper_config_ref, variant_wrapper_config_sha256,
phase_profile_id, enable_ime, max_inflight={0|1}, ime_reset_contract,
enabled_inst_ids[], enabled_cell_ids[],
enabled_rule_ids[], direct_isaext_ids[], has_vtype_altfmt=<base-derived boolean>,
invalid_frm_behavior=illegal_instruction,
p3_memory_profile_id=<string|null>, p4_numeric_profile_id=<string|null>,
required_hardware={core_base_build_config_sha256,enable_rvv=true,
                   xlen=32,vlen=128,dispatch_profile=DISPATCH3,
                   num_dp_vrf=<base actual>,num_rt_uop=4,rob_depth=8,uq_depth=16,
                   has_vtype_altfmt=<same base-derived boolean>},
lambda_by_sew, numeric_phase_parameters, required_software_claim_ids[]
```

`active_variant_sets[]`的required fields是`active_variant_set_id,phase_profile_id,set_revision:uint>=1,config_pairs[]{base_config_id,off_variant_record_ref,on_variant_record_ref}`。ID全局唯一且APPROVED后不可改写；pairs按base ID排序、去重，两ref必须指向同base/phase/record_revision的off/on records。对任一active set定义`N=len(config_pairs)`且`N>=1`；该profile的delivery/verification/release artifact分母恒为`2N`，不能在下游另写固定数量。`build_target_bindings.yaml` root必须用唯一`delivery_active_variant_set_id`封存本source revision中静态delivery targets使用的set，implementation manifest只能从actual target joins核验它；caller/phase env不能选择active set。升级phase时新建record refs和active-set ID，再显式修改BUILD bindings，不改写旧set。

首个P0/P1 release family的两个固定base config必须`has_vtype_altfmt=false`，其active set断言`N=2`。P4不得改写这两个已批准base config或用IME variant偷开独立Zvfbfa能力；只能在Zvfbfa gate关闭后新增P4-capable base/delivery config ID，其off/on两侧的base-derived `has_vtype_altfmt`必须同为true并重跑该P4 active set全部`2N` artifact/profile签核。当前owner-confirmed Zvfbfa artifact与exact P4 base-config IDs/wrapper/target bindings均不存在，故P4 active set保持**BLOCKED且不得生成占位ID/label**；这些输入必须在P4 DoR前由owner批准并完整物化。

* `ime/config/build_target_bindings.yaml`：封存repo中全部Core/SoC/FPGA/public simulation/lint/formal/synthesis/package target的analysis-time绑定。schema root固定包含`schema_version,delivery_active_variant_set_id,target_universe,flow_catalog[],source_registration_sets[],base_configs[],top_pin_abis[],variant_wrapper_configs[],variant_records[],targets[],binding_infrastructure[]`，各部分互相引用且无重复：

```text
target_universe:
  build_file_roots[],
  bazel_query_specs[]{query_id,argv_suffix[]},
  test_support_query_spec=<closed_query_spec|null>,
  approved_exclusions[]{stable_id,target_label,rule_kind,rationale,approval_ref}
flow_catalog[]:
  flow_id, applicable_phase_profile_ids[], rule_kind, tool_kind,
  required_identity_check_kind,
  test_support_kind={NONE|COCOTB_TEST_DATA}, owner
source_registration_sets[]:
  source_registration_set_id,
  entries[]{path,source_label,registration_layer,content_sha256}, canonical_sha256
base_configs[]:
  base_config_id, config_code[15:0], core_base_build_config_v1,
  core_base_build_config_sha256,
  allowed_target_kinds[], owner, approval_ref
top_pin_abis[]:
  top_pin_abi_ref,
  top_pin_abi_v1={schema_version=1,
                  pins[]{name,direction={input|output|inout},width_bits:uint>=1,
                         protocol_role},
                  clock_reset_contract_refs[]},
  top_pin_abi_sha256, owner, approval_ref
variant_wrapper_configs[]:
  variant_wrapper_config_ref, base_config_id, variant_id, record_revision,
  wrapper_config_v1={schema_version,requested_module_name,
                     elaborated_top_module_name,wrapper_chisel_args[],
                     expected_primary_artifact_paths[],
                     top_pin_abi_ref,top_pin_abi_sha256},
  variant_wrapper_config_sha256
variant_records[]:
  variant_record_ref, base_config_id, variant_id, record_revision,
  variant_code[15:0], variant_wrapper_config_ref,
  delivery_scope={delivery,non_delivery}, binding_kind={DELIVERY_VARIANT,SEALED_OFF_ONLY},
  full_variant_record_payload_or_delivery_record_ref,
  variant_record_sha256, effective_set_sha256
targets[]:
  <closed oneOf artifact_binding_kind；见下文>
binding_infrastructure[]:
  infra_label, infra_kind={PROVIDER|BINDING_TEST|IDENTITY_CHECK|TEST_SUPPORT},
  owning_target_labels[], rule_kind, approved_macro_id
```

`flow_catalog[].applicable_phase_profile_ids[]`必须非空、按UTF-8 byte-order排序且zero duplicate；plan只能引用显式包含其root `phase_profile_id`的flow。GLOBAL/phase-neutral flow若适用于多个profile，也必须逐个列出已APPROVED profile ID，禁止用`*`、null或“all current/future profiles”绕过profile join。

`CoreBaseBuildConfigV1`是IME variant之外的完整elaboration真源，schema为closed object且当前required keys固定为：

```text
schema_version=1, base_config_id,
emitter_kind={EmitCore|CoralNPUChiselSubsystemEmitter|other-approved},
bus_kind={core|axi|tlul},
privileged_scope={bare_metal_nonprivileged|machine_mode_vector_context},
parameters={
  hart_id, memory_regions[]{mem_start,mem_size,mem_type},
  enable_verification,enable_rvv,rvv_vlen,enable_float,enable_zfbfmin,
  float_pulp_divsqrt,enable_fetch_l0,fetch_data_bits,lsu_data_bits,
  itcm_size_kbytes,dtcm_size_kbytes,axi2_id_bits,itcm_memory_file_ref
},
derived_and_fixed={
  program_counter_bits,instruction_bits,instruction_lanes,rvv_vlenb,
  use_retirement_buffer,float_regfile_base_addr,rvv_regfile_base_addr,
  rvv_reg_count,retirement_buffer_size,retirement_buffer_idx_width,
  fetch_cache_bytes,fetch_addr_bits,fetch_instr_slots,
  lsu_addr_bits,lsu_data_bytes,lsu_delay_pipeline_len,dbus_size,
  l1i_slots,l1i_assoc,axi0_id_bits,axi0_addr_bits,axi0_data_bits,
  l1d_slots,axi1_id_bits,axi1_addr_bits,axi1_data_bits,
  axi2_addr_bits,axi2_data_bits,axi2_data_bytes,csr_in_count,csr_out_count
},
rvv_backend_constants={xlen,vlen,dispatch_profile,num_dp_vrf,num_rt_uop,
                       rob_depth,uq_depth},
base_feature_constants={has_vtype_altfmt},
soc_context={enable_test_harness:boolean|null},
emit_context={non_variant_chisel_args[],firtool_opts[]},
sv_context={defines[],incdirs[],source_registration_set_id,
            source_registration_set_sha256}
```

`itcm_memory_file_ref`是`{path,sha256}`或JSON `null`，禁止只记路径。`emit_context.non_variant_chisel_args[]`不是可独立编辑的第二份配置：它必须由最终`Parameters`按固定参数名/顺序确定性生成，emitter introspection须逐argv exact-match；任何无法从`CoreBaseBuildConfigV1` leaf唯一反推的参数都使inventory validator失败。module/top/artifact名和pin ABI不属于off/on共享base；它们只属于closed `VariantWrapperConfigV1`。其`variant_wrapper_config_sha256=SHA256(UTF8(JCS(wrapper_config_v1)))`，`wrapper_chisel_args[]`包含module/wrapper选择但排除唯一`--imeVariantRecordRef`；实际emitter argv必须恰为`base non_variant_chisel_args + wrapper_chisel_args + 一个record selector`，三者都禁止duplicate/override。

每个`top_pin_abi_v1`先由`top_pin_abi.schema.json`验证。`TopPinAbiV1`的`pins[]`按`name` UTF-8 byte-order排序且名称唯一，`clock_reset_contract_refs[]`排序去重；`top_pin_abi_sha256=SHA256(UTF8(JCS(top_pin_abi_v1)))`。`protocol_role`只能引用`interface_abi.yaml`中已存在的stable role，禁止自由文本。emitter完成wrapper生成后必须从实际elaborated top introspection重建`{name,direction,width_bits}`全集，并与同一generator输出的一对一pin→stable-role annotation join后形成完整payload；annotation missing/extra/重复、pin/方向/位宽/role差异均fatal，随后重算hash。不能声称从Verilog端口名猜出semantic role。同一base config同一record revision的off/on wrapper可使用不同module/artifact名，但`top_pin_abi_ref/hash`必须逐bit相等；target的expected top/path只能由所引wrapper config派生，不得再抄一份。

`required_hardware`不是另一张自由map，而是closed **actual-value projection** `{core_base_build_config_sha256,enable_rvv,xlen,vlen,dispatch_profile,num_dp_vrf,num_rt_uop,rob_depth,uq_depth,has_vtype_altfmt}`，每一值都必须从上述base config逐值派生；不得把actual port count降级记为`min_*`要求值。P1的`num_dp_vrf>=3`等minimum是对该actual值另行运行的cross-field predicate。`CoreBaseBuildConfigV1`的SHA-256同样按UTF8(JCS)计算；`final_elaboration_config_sha256=SHA256(UTF8(JCS({core_base_build_config_sha256,variant_wrapper_config_sha256,variant_record_sha256,effective_set_sha256})))`。因此final hash同时绑定variant-independent base、variant-specific wrapper、requested record和effective legality，任一项改变都必须重建artifact。

P0必须新增inventory validator，语法分析`Parameters.scala`全部constructor/public elaboration-affecting `val/var/zero-arg def`、`EmitCore`/SoC emitter全部selector、wrapper module/bus选择、RVV backend config macro及resource registration；当前每项必须恰映射到上述base/wrapper/variant的一个leaf或有APPROVED `NON_ELABORATION_INPUT`记录。新增/删除/改类型而未升级对应`CoreBaseBuildConfigV1`/`VariantWrapperConfigV1`/variant schema立即失败。emitter在完成所有赋值、构造module之前从最终`Parameters`和wrapper context序列化actual object，重算base/wrapper/final hash并与sealed record比较；任何遗漏或差异fatal。lint/sim/formal/synthesis/FPGA/package flow都必须继承同一`final_elaboration_config_sha256`，不能自行重建一份近似配置。

`targets[]`不再假定每个rule只消费一个variant。每条先有common closed fields `{target_label,target_kind,binding_provider_label,binding_test_label,authorized_flow_ids[],source_registration_set_id,plan_action,required_phase_ids[],artifact_binding_kind,execution_aggregation_kind={DIRECT|SUITE_PARENT},suite_members[]}`，再以JSON Schema `oneOf` 固定：

```text
SINGLE_VARIANT:
  {base_config_id,variant_record_ref}
REFERENCE_COMPARISON:
  {config_id,base_config_id,off_variant_record_ref,reference_binding_id}
VARIANT_COMPARISON:
  {config_id,base_config_id,off_variant_record_ref,on_variant_record_ref}
MULTI_ARTIFACT_PACKAGE:
  {package_id,input_variant_record_refs[]{minItems=2},
   input_comparison_target_labels[],release_scope_id}
```

`required_phase_ids[]`不是散文标签，而是该target允许产生权威command的as-built phase集合；它必须非空、按`P0..P4`顺序排序且zero duplicate。对root `as_built_phase_id=Pn`，唯一`applicable_targets(Pn)={t | Pn in t.required_phase_ids}`。首个P0/P1 profile中：phase-qualified P0 suite的集合恰为`[P0,P1]`，P1 suite恰为`[P1]`，其余phase-neutral primary/model/lint/base-RVV/standalone/comparison target恰为`[P0,P1]`；SUITE_MEMBER逐值继承parent。label含`pQ`时还必须满足`Q<=n`及label token/test-phase binding一致。non-applicable target仍须存在于lock、tag和repo-wide universe闭包，但本plan不得为其生成binding/flow/identity command或result；不得用环境变量动态skip来代替此静态选择。

`SINGLE_VARIANT`可用于emitter/verilog/model/simulation/lint/formal/synthesis/fpga及只消费一个artifact的package；其result scope只能是`VARIANT`或`OFF_ONLY_TARGET`。`REFERENCE_COMPARISON`恰消费一个delivery-off artifact加所引cycle reference，`VARIANT_COMPARISON`恰消费同config off/on两个artifact，两者的result scope必须与discriminator同名。`MULTI_ARTIFACT_PACKAGE`只允许package/bundle rule，输入必须恰等于APPROVED closure/release plan的已签名tuple和comparison集，其result scope为`MULTI_ARTIFACT_PACKAGE`。provider/test对每个input record/artifact分别携带File handle并逐一核验；禁止为了迁就single-record schema把comparison伪绑到任一侧，也禁止将其列为exclusion。

`execution_aggregation_kind=DIRECT`强制`suite_members=[]`。只有真正的Bazel `test_suite`可使用`SUITE_PARENT`，且`plan_action=test`、`suite_members`非空。每个member是closed `{member_label,member_rule_kind,member_flow_id,member_execution_semantics=BAZEL_CHILD_TEST,testcase_id,member_binding_provider_label}`；数组按`member_label` UTF-8 byte-order严格排序，六字段非空，`testcase_id`在parent内唯一，member label在全文件唯一且不得同时作为其它parent、`targets[]`、infrastructure或exclusion label。`member_flow_id`必须唯一引用与actual child rule兼容的flow record；parent自身`authorized_flow_ids`则校验actual `test_suite` rule，二者不得拿同一个`rule_kind`互相冒充。

当前`rules/coco_tb.bzl`虽然生成`<name>_<testcase>` targets，却把`<name>`生成为另一个无testcase filter的meta `cocotb_test`，不是Bazel suite，故**现状不能作为本contract的SUITE_PARENT**。P0必须给该macro增加锁定的authoritative-suite模式：要求非空、排序去重的exact testcase list，只生成逐testcase child tests，再用`native.test_suite(name=<parent>,tests=<全部child labels>)`建立parent；不得同时生成同名unfiltered meta-test。首个profile全部16个phase suite及8个base-RVV parent都必须启用该模式。legacy meta/mirror模式不进入这些bindings，不能用日志/JUnit推测其隐式发现集合代替Bazel child闭包。

每个member必须由同一批准macro生成、带`ime_variant_bound` tag、直接绑定parent完全相同的artifact discriminator、DUT/sidecars/identity和phase classification；member只能有provider而没有独立binding-test/plan/result，parent的`binding_test_label`必须消费全部member providers/File handles并zero missing/extra验证其actual deps。DIRECT target则使用自身provider/test。这样suite展开是显式closed graph，不会把helper藏成exclusion，也不会将同一testcase重复计为独立权威result。

companion provider/binding-test/identity-check本身会出现在reverse-dependency universe，但不能再为它们递归生成companion。因此它们必须恰好出现于`binding_infrastructure[]`：每个target的provider/test label及每个suite member的`member_binding_provider_label`都被恰一条infra record覆盖；member provider只能由其唯一parent binding test消费，identity checker只能被非空owning targets引用。actual rule kind必须是approved macro生成的provider或read-only test，不得产生/重写DUT、不得被package当作DUT input、不得拥有功能selector。

现有cocotb helper为每个cocotb leaf（无论它是DIRECT target还是SUITE_MEMBER）额外生成的`*_test_data`等非可执行support rule必须逐label进入`binding_infrastructure[]`并固定`infra_kind=TEST_SUPPORT`；它只允许approved `py_library/filegroup`类rule、必须由非空cocotb leaf拥有、不得带`ime_variant_bound`、不得生成或选择DUT/model/simulator binary，也不得携带record/config/variant selector，其source/data/deps由lock重建且zero missing/extra。IME VCS suite必须显式传入已经作为DIRECT target封存并通过identity检查的`model`，禁止使用`cocotb_test_suite`自动生成未绑定`*_vcs_model`；Verilator同样只引用已封存model。任何model/compile/simulator artifact都不能伪装成TEST_SUPPORT。任何其它直接产生/仿真/分析/比较/综合/打包Core/RVV artifact的rule都不属于infrastructure，必须进入`targets[]`或某一target的`suite_members[]`。validator对infra label的rule implementation digest、attrs和outgoing edges做allowlist检查，防止用“binding test/support”名义隐藏实际flow。

`target_universe`也不是caller可缩减的自由数组。schema version 1强制`build_file_roots=["."]`，扫描repo内全部BUILD/.bzl（排除`.git`、Bazel output tree和external repository，但不排除`rules/hdl/tests/fpga/dc/tools/ime`）。`bazel_query_specs`必须逐byte等于下面两个repo-wide closed records；这里只保存command suffix，plan必须在前面拼接implementation manifest锁定的`[bazel_executable_ref.absolute_realpath,"--batch","--ignore_all_rc_files"]`，不得从PATH查找或加载任何system/home/workspace rc。变更只能升级schema、走ADR并由architecture/build owner重签：

```text
{query_id="QUERY-TARGET-UNIVERSE-RDEPS-V1",
 argv_suffix=["query",
  "kind(\".* rule\", rdeps(//..., set(//hdl/chisel/src/coralnpu:all //hdl/chisel/src/soc:all)))",
  "--output=label_kind"]}
{query_id="QUERY-TARGET-UNIVERSE-TAG-V1",
 argv_suffix=["query",
  "attr(tags, \"ime_variant_bound\", //...)","--output=proto"]}
```

三条QUERY command的ID/expected-set ID固定为：repo-wide rdeps=`QUERY-TARGET-UNIVERSE-RDEPS-V1/SET-RDEPS-CLOSURE-V1`，tag=`QUERY-TARGET-UNIVERSE-TAG-V1/SET-FLOW-RULE-LABELS-V1`，suite support=`QUERY-SUITE-SUPPORT-V1/SET-SUITE-SUPPORT-INFRA-V1`；不得由plan generator另起同义ID。

第一条覆盖Core/SoC package内全部rule及repo内所有formal/simulation/synthesis/FPGA/package/bundle下游rule，不依赖它们预先带tag。定义`flow_rule_labels = targets[].target_label ∪ flatten(targets[].suite_members[].member_label)`和`non_test_support_infra_labels = binding_infrastructure[infra_kind!=TEST_SUPPORT].infra_label`；第一条label集合必须恰等于`flow_rule_labels ∪ non_test_support_infra_labels ∪ approved_exclusions[].target_label`，三类集合两两不交。internal library、source aggregation或不直接运行artifact的便利aggregate/test-suite可申请exclusion；权威suite parent及其实际member都属于`flow_rule_labels`。companion provider/read-only check只能进入受限infrastructure；任何其它直接产生/消费最终Core/RVV RTL、model、sim、lint、formal、synthesis、FPGA、package/bundle artifact的rule不得排除。第二条`attr`只是substring candidate查询；validator必须解析其protobuf中每个rule的actual `tags` string-list，要求candidate label集合恰等于`flow_rule_labels`且每个flow label恰有一个**exact element** `ime_variant_bound`，再从`flow_rule_labels`逐项反查actual tags。`ime_variant_bound_extra`等suffix/prefix不能代替exact element；infrastructure/exclusion不得含该exact tag。proto解析失败、tag重复或任一方向set差异均失败。

`TEST_SUPPORT`是cocotb leaf的并列dependency而非Core reverse dependency，故不得塞入第一条等式。定义`test_support_roots`为：(a) `execution_aggregation_kind=DIRECT`且恰有一条authorized flow的`test_support_kind=COCOTB_TEST_DATA`的target label；并集(b) `member_flow_id`所引flow具有该kind的全部SUITE_MEMBER label。任何root解析到零条或多条这种flow均失败。`test_support_query_spec`由validator从按UTF-8 byte-order排序的`test_support_roots`唯一物化为closed `{query_id="QUERY-TEST-SUPPORT-V1",argv_suffix=["query","--noimplicit_deps",<materialized expression>,"--output=label_kind"]}`；plan再按本节受信Bazel executable prefix形成actual argv。`--noimplicit_deps`不可省略，否则Bazel隐式test setup/coverage/XML filegroup会污染support全集。实际lock/plan中必须替换成完整label序列，不得保留尖括号或通配符。其结果必须逐项等于`binding_infrastructure[infra_kind=TEST_SUPPORT].infra_label`，并与DIRECT/member macro expansion及BUILD/.bzl语法扫描三向相等。`test_support_roots`为空时该spec为null且TEST_SUPPORT集合必须空；非空时spec/result均必须存在。任一新增rule会先造成zero-missing失败，不能靠删root/query/kind自洽通过。

`flow_id`与`source_registration_set_id`分别匹配`^FLOW-[A-Z0-9-]+$`和`^SRCSET-[A-Z0-9-]+$`并全局唯一。每个`targets[].authorized_flow_ids`非空、去重且逐项引用`flow_catalog`；target实际Bazel rule kind、`target_kind`、`plan_action`和identity-check kind必须与所引flow逐值兼容。SUITE_PARENT逐member用其`member_flow_id`校验`member_rule_kind`和actual child rule；`testcase_id`只与lock、authoritative macro传入的exact testcase attr、Bazel expansion及structured cocotb result逐值核对，flow catalog不虚构testcase字段。`source_registration_set_id`恰引用一条set；其entries按`(path,source_label,registration_layer)`byte-order排序，`canonical_sha256=SHA256(UTF8(JCS(entries)))`，每个source-tree SV/SVH同时出现于source BUILD export、Chisel resources/srcs和`RvvCore.addResource`适用layer，generated sidecar只出现于downstream layer。validator从实际BUILD/Scala resource graph重建entries并要求zero missing/extra/content-hash mismatch，不能只核对手写路径。

`base_config_id`及非null的`config_id`均限制为`^[a-z0-9_]+$`；每个delivery config必须和一个base config一一对应且两ID逐字节相等，off-only的`config_id`则必须为JSON `null`。APPROVED `base_config_id/config_code/CoreBaseBuildConfigV1`是不可改写的一一记录；任一base leaf变化都必须新建ID和code，不得让旧record的code解析到新hash。`variant_record_ref`在全部delivery/off-only records中全局唯一、不可改义或复用；同一`(base_config_id,variant_id)`的full payload **或derived effective-set payload**因phase/profile/capability/dependency/gate变化时，都必须使用严格递增且无gap的`record_revision`和新ref，旧ref下的record/effective hash不得改写。`variant_wrapper_config_ref`同样immutable，wrapper任一leaf改变必须新ref/hash并产生新variant record revision。`config_code`与`base_config_id`全局一一对应且非零；`variant_code`稳定标识产品语义`(base_config_id,variant_id)`，因此同一variant的不同record revision必须复用同code，不同variant不得复用。`(config_code,variant_code,variant_record_sha256)`在全文件唯一，608-bit identity中的record/effective digest区分revision。target不得重复抄写或覆盖code，只能经record ref派生。`DELIVERY_VARIANT`只能引用`delivery_variants.yaml`中的完整off/on record，且join后`base_config_id/config_id/variant_id/record_revision/variant_record_ref/variant_wrapper_config_ref`逐值相等；`SEALED_OFF_ONLY`在bindings文件内保存完整payload。claimed hash不得替代payload。validator对带`ime_variant_bound` tag的全部exported/emitter/model/simulation/lint/formal/synthesis/FPGA/package/bundle flow rule（含suite parent/member）做Bazel query并要求与`flow_rule_labels`逐项相等、zero missing/extra；non-delivery只能off-only，不进入active delivery set的`2N` artifact分母。

delivery与off-only使用同一个`full_variant_record_payload`规范。required keys及类型固定为：

```text
schema_version:uint=1,
base_config_id:string, config_id:string|null, variant_record_ref:string,
variant_id:string, record_revision:uint>=1,
variant_wrapper_config_ref:string, variant_wrapper_config_sha256:sha256,
binding_kind:{DELIVERY_VARIANT|SEALED_OFF_ONLY},
phase_profile_id:string|null, enable_ime:boolean, max_inflight:uint[0..1],
ime_reset_contract:{COMMON_ATOMIC_RESET|PREANNOUNCED_DRAIN}|null,
enabled_inst_ids:string[], enabled_cell_ids:string[], enabled_rule_ids:string[],
direct_isaext_ids:string[], has_vtype_altfmt:boolean,
invalid_frm_behavior:{illegal_instruction},
p3_memory_profile_id:string|null, p4_numeric_profile_id:string|null,
required_hardware:closed object, lambda_by_sew:closed object,
numeric_phase_parameters:closed object, required_software_claim_ids:string[]
```

`variant_record_sha256 = SHA256(UTF8(JCS(full_variant_record_payload)))`。JCS输入不得包含两个hash字段、approval、path、timestamp或其它envelope metadata；数组按stable ID byte-order排序且去重，空数组/空object和JSON `null`必须显式保留。`effective_set_sha256`只对generator在dependency/gate/closure校验后产生的下列closed payload计算：

```text
{schema_version,base_config_id,config_id,variant_record_ref,variant_id,record_revision,
 variant_wrapper_config_ref,variant_wrapper_config_sha256,binding_kind,
 phase_profile_id,enable_ime,ime_reset_contract,derived_presence_by_stable_id,
 enabled_inst_ids,enabled_cell_ids,effective_legal_inst_ids,effective_legal_cell_ids,
 rule_partition_status_by_id,direct_isaext_ids,effective_ime_isaext_ids,
 required_hardware,lambda_by_sew,numeric_phase_parameters}
```

其算法同样固定为`SHA256(UTF8(JCS(payload)))`，map key按JCS排序，禁止省略空集合。两个hash都必须由generator重算并由schema/lock/Scala/sidecar/identity checker复核，人工输入不一致立即失败。

每个source revision中，每个被至少一个non-delivery `SINGLE_VARIANT` binding引用的base config必须恰有一个**current active** off-only record；没有non-delivery binding的delivery-only base不得凭空增加该record。历史ref不得改写或复用。新base从`record_revision=1`开始；若同base的wrapper/top/pin/artifact或off record/effective payload发生任何变化，则revision严格`+1`且无gap。ref无自由字段，固定为`variant_record_ref="SEALED-OFF-ONLY--" + base_config_id + "--R" + decimal(record_revision)`，`variant_wrapper_config_ref="SEALED-OFF-ONLY-WRAPPER--" + base_config_id + "--R" + decimal(record_revision)`；后者必须引用`variant_wrapper_configs[]`中由actual primary wrapper/TopPinAbiV1构造并重算hash的closed payload。其余record固定为`config_id=null`、`variant_id="sealed_off_only"`、`binding_kind=SEALED_OFF_ONLY`、`phase_profile_id=null`、`enable_ime=false`、`max_inflight=0`、`ime_reset_contract=null`、四个IME enable/claim数组及`required_software_claim_ids=[]`、`p3_memory_profile_id=null`、`p4_numeric_profile_id=null`、`lambda_by_sew={}`、`numeric_phase_parameters={}`、`invalid_frm_behavior=illegal_instruction`；`required_hardware`逐值投影该`base_configs[].core_base_build_config_v1`，`has_vtype_altfmt`取base config固定值。其`effective_legal_inst_ids/effective_legal_cell_ids/effective_ime_isaext_ids=[]`，derived presence只有`PRES-RVV-IME-GUARD=enable_rvv`可能为true，其余IME presence均false。共享同一base config和non-delivery primary wrapper的target必须共享current record；在`SEALED_OFF_ONLY` namespace内schema强制一个base config只对应一个primary wrapper，确需另一个non-delivery primary wrapper时必须新建不同`base_config_id/config_code`，不得共用ref/hash。delivery off/on wrapper仍按active-pair规则各自存在，不受此单off-only-wrapper约束。不同base config不得复用。这样off-only identity可重建、可版本化，而不是伪造delivery config或借用AXI delivery-off record。

schema与generator必须同时实施以下cross-field invariants：

1. 对每个**active delivery config + record revision**，`variant_id=ime_off_baseline <=> enable_ime=false`，`variant_id=ime_on_delivery <=> enable_ime=true`；两record的`config_id=base_config_id`、`record_revision`和`phase_profile_id`相等并映射同一base config。该active set缺失、重复或第三个delivery variant均失败；新phase改变payload时产生新revision/ref但保持产品`variant_id/code`。non-delivery target不受off/on成对规则，而必须恰好绑定自身base config的一个`SEALED_OFF_ONLY` record；
2. off的IME-specific `enabled_inst_ids/enabled_cell_ids/enabled_rule_ids/direct_isaext_ids`全部为空，派生的`effective_legal_inst_ids/effective_legal_cell_ids/effective_ime_isaext_ids`也全部为空；这不影响独立base/Zvfbfa capability，并且record顶层与`required_hardware` 中的`has_vtype_altfmt`都必须等于base feature。只有首个P0/P1 release family固定为false；
3. on的`enabled_*`是requested/authorized closure，必须**恰等于**phase profile或authorized delta closure；`effective_legal_*`则只由完成dependency/gate检查且runtime partition为`enforced_legal`的INST/CELL派生。`blocked_external`、`enforced_reserved`或`illegal_feature_off`不得进入effective legal集。`enable_ime=true`只是允许IME architectural state/guard，不自动legalize任何encoding；
4. `enable_ime => enable_rvv`；`max_inflight=0`当且仅当`effective_legal_inst_ids=[]`，否则首版固定为1。feature-off/pre-accept fault booking只使用scalar age ID，不属于legal IME macro inflight。只有`has_p1_datapath=true`时才强制`XLEN=32,VLEN=128,DISPATCH3,NUM_DP_VRF>=3,NUM_RT_UOP=4,IME_MAX_INFLIGHT=1`及§4.3固定SEW/LMUL/lambda；P2/P3/P4也只有相应effective legal集、profile、artifact和gate闭合后才可导出对应`has_p*`。off-only record按自己的base config校验，不得错误套用P1端口/ROB/UQ要求；
5. `variant_record.required_hardware.core_base_build_config_sha256`必须等于所引base config hash，`variant_wrapper_config_sha256`必须等于所引wrapper重算hash，且wrapper的base/variant/revision三元组必须与record相等。`config_code`查表必须唯一解析回同一base config/hash；这一join加上record digest使608-bit identity间接但完整绑定base/wrapper/final config，不得只核对code值；
6. `PRES-IME-LOCAL-RESET=false <=> ime_reset_contract=null`。该presence为true时contract必须恰为一个非null枚举：`PREANNOUNCED_DRAIN`必须使`PRES-IME-PRE-RESET-QUIESCE=true`并有platform reset owner证明只在matching ack后assert reset；`COMMON_ATOMIC_RESET`必须有platform artifact证明core/IME/LSU/adapter/所有response buffer同一atomic-cancel reset domain且release后无旧response。P3若无response-buffer域与延迟response注入证据，两种contract都不得通过；
7. caller的`privileged_scope`必须逐值等于所有selected base config中已封存的值；caller不能用该字段改变artifact行为。caller/Bazel/Scala/SV/manifest任一tuple、hash、hardware constant或effective-set不一致必须analysis/elaboration fatal，禁止静默降级为off、部分开启或只打印warning。

结构可选性按derived constant冻结，不能只在完整datapath外加一个runtime `if (enable)`：

| derived presence | off/on elaboration内容 | 强制约束 |
| --- | --- | --- |
| `PRES-RVV-IME-GUARD: has_ime_feature_off_guard = enable_rvv` | RVV build始终保留known-IME raw classifier、最小sticky pending/age/RB-booking/fault shell，以及`vsetvl`对IME high bits的reserved检查 | off raw encoding必须精确illegal且不能掉入backend discard；该最小shell允许保留完成precise trap所需的tag/state，但不得含legal-command/compute路径 |
| `PRES-IME-ARCH-STATE: has_ime_arch_state = enable_ime` | on才保存lambda/bs/altfmt_A/B等IME high state并导出coherent snapshot；off把这些fields的architectural值固定为0并对非零request做vill canonicalization | 不得在off留下可被后门写入的IME state；独立`has_vtype_altfmt`仍按其自身extension决定低位bit 8 |
| `PRES-P1-DATAPATH: has_p1_datapath = any(effective-legal P1 CELL)` | 只在true时实例化legal-command path、ImeEngineP1、shadow/accumulator、IME VRF read arbiter和atomic batch commit source | requested但blocked/reserved的CELL不得使它为true；false时normal VRF read/retire write使用generate-time直连，不得保留runtime IME mux、shadow register或IME clock load |
| `PRES-P2-DATAPATH/PRES-P3-TILE-LSU/PRES-P4-FP-MX` | 分别由`effective_legal_cell_ids/effective_legal_inst_ids`与已关闭gate派生 | false时对应engine/queue/LSU/FCSR/fflags接口和state均不elaborate；不能由global `enable_ime`或requested root单独实例化 |

off/on的CoralNPU外部pin-level IO和协议必须相同，IME不增加product pin；为允许两种artifact并存，top module/artifact名字必须按下面静态mapping唯一并由manifest记录，而不是要求文字名字相同。`architecture.yaml`必须为每个可被ABI/structure引用的derived predicate分配不可复用stable ID，首版至少冻结：

```text
PRES-RVV-IME-GUARD          := enable_rvv
PRES-IME-ARCH-STATE         := enable_ime
PRES-P1-DATAPATH            := any(effective_legal_cell_ids in P1)
PRES-P2-DATAPATH            := any(effective_legal_cell_ids in P2)
PRES-P3-TILE-LSU            := any(effective_legal_inst_ids in P3)
PRES-P4-FP-MX               := any(effective_legal_cell_ids in P4)
PRES-IME-LEGAL-COMMAND      := effective_legal_inst_ids != []
PRES-IME-ATOMIC-MAC-COMMIT  := P1-DATAPATH || P2-DATAPATH || P4-FP-MX
PRES-IME-PRIV-CONTEXT       := privileged_scope=machine_mode_vector_context &&
                               PRES-IME-LEGAL-COMMAND
PRES-IME-LOCAL-RESET        := ARCH-STATE || P1 || P2 || P3 || P4
PRES-IME-PRE-RESET-QUIESCE  := PRES-IME-LOCAL-RESET &&
                               ime_reset_contract=PREANNOUNCED_DRAIN
```

这些表达式在schema中是canonical AST（`ref/all/any/eq/nonempty/in_set`节点）而非自由文本；若某接口需要其它组合，先增加新的`PRES-*` record并走CR，接口自身不得嵌入临时布尔式。pure off guard使用既有scalar reset，不实例化`ImeResetController`。典型binding固定为：RB pre-accept fault/booking→`PRES-RVV-IME-GUARD`；legal Command/Completion/OuterAck→`PRES-IME-LEGAL-COMMAND`；accepted-macro Flush→P3或其它可发accepted fault的effective phase presence；C batch/MacroCommit→`PRES-IME-ATOMIC-MAC-COMMIT`；memory/vstart fault ABI→`PRES-P3-TILE-LSU`；frm/fflags→`PRES-P4-FP-MX`；IME context commit→`PRES-IME-PRIV-CONTEXT`；pre-reset drain→`PRES-IME-PRE-RESET-QUIESCE`。feature-off illegal没有engine flush ABI，只有`PRE_ACCEPT` fault/trap tag链；不得为它实例化dummy accepted-macro flush。

内部ABI不再假定所有接口都有`valid/payload/ready/strobe/base_path`五个字段。§4.5每条接口使用discriminated union：

```text
presence_predicate_id: PRES-*
when_absent:
  kind: ABSENT | INERT | DIRECT_BASE
  signal_bindings[]:
    {signal_path,direction,width,side_effect_class,
     policy: ABSENT|CONST0|CONST1|DIRECT,
     direct_base_signal:string|null}
```

`signal_bindings[]`必须与canonical interface signal/leaf manifest恰好相等，覆盖Snapshot、event/ack、Decoupled和双向req/resp的每个真实leaf，zero missing/extra；`DIRECT`必须给同宽同方向的approved base signal，其它policy的`direct_base_signal=null`。`ABSENT`要求该leaf不在hierarchy，`INERT`必须让所有side-effect producer为CONST0且不能用ignored；ready等sink control只能按协议取CONST0/CONST1，且证明不向base core施加backpressure。`DIRECT_BASE`只允许normal base-path mux在generate-time直连。active set全部`2N`个`ime_interface_width_*_test`分别验证presence predicate求值、leaf集合、`$bits`、pin ABI与每一policy；首个profile恰为四项。

`architecture.yaml.off_guard_allowlist[]`还必须逐项列出`GUARD-* stable ID,instance_or_signal_pattern,kind={module,register,wire,clock_load},owner,required_req_ids,rationale,max_count,max_bits`，并hash进入implementation manifest。off structure test要求实际module/register/clock-load集合与allowlist**恰好相等**且所有phase forbidden structure为0；不能把多余state改名成guard。P1/P2/P3/P4 engine、shadow、queue、IME VRF mux、batch/FCSR datapath及`ImeResetController`不得出现在off hierarchy/netlist。完整逻辑仅绑常数0不算结构裁剪。

| config × variant | Bazel label | `--moduleName` / elaborated top | primary generated files |
| --- | --- | --- | --- |
| `rvv_core_mini_axi × off` | `//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library` | `RvvCoreMini` / `RvvCoreMiniAxi` | `RvvCoreMiniAxi.sv`, `VRvvCoreMiniAxi_parameters.h` |
| `rvv_core_mini_verification_axi × off` | `//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library` | `RvvCoreMiniVerification` / `RvvCoreMiniVerificationAxi` | `RvvCoreMiniVerificationAxi.sv`, `VRvvCoreMiniVerificationAxi_parameters.h` |
| `rvv_core_mini_axi × on` | `//hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library` | `RvvCoreMiniIme` / `RvvCoreMiniImeAxi` | `RvvCoreMiniImeAxi.sv`, `VRvvCoreMiniImeAxi_parameters.h` |
| `rvv_core_mini_verification_axi × on` | `//hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library` | `RvvCoreMiniImeVerification` / `RvvCoreMiniImeVerificationAxi` | `RvvCoreMiniImeVerificationAxi.sv`, `VRvvCoreMiniImeVerificationAxi_parameters.h` |

Chisel→SV的唯一功能桥接不得复制当前`ZVE32F_ON`双真源模式。`GenerateCoreShimSource`必须消费同一个`ImeVariantRecord`，在`RvvCore`实例上显式传递`ENABLE_IME/HAS_IME_FEATURE_OFF_GUARD/HAS_IME_ARCH_STATE/HAS_P1/HAS_P2/HAS_P3/HAS_P4`、`CONFIG_CODE/VARIANT_CODE`及`VARIANT_RECORD_SHA256/EFFECTIVE_SET_SHA256`；`RvvCore.sv`可把这些组件声明为供生成wrapper实例化时赋值的parameters，并用constant-generate裁剪，但它们**不是产品或flow配置接口**。声明类型和宽度是ABI：七个presence parameter逐个为`parameter bit ... = 1'b0`，两code逐个为`parameter logic [15:0] ... = 16'h0000`，两digest逐个为`parameter logic [255:0] ... = 256'b0`；禁止untyped `parameter`、`integer`、unsized literal或隐式截断。`RvvCore.sv`必须按本节固定layout只用定宽常量和上述定宽parameter构造唯一`localparam logic [607:0] IME_BUILD_IDENTITY_V1`，不得再接受一个可独立传入的完整identity parameter。每个批准的Verilator/VCS/lint/formal/synthesis/FPGA/test flow都必须以无上述parameter的generated variant wrapper为actual top；wrapper内部只用由同一record生成的定宽literal/localparam覆盖`RvvCore`，并保存不可覆盖的`localparam logic [607:0] EXPECTED_IME_BUILD_IDENTITY_V1`，禁止把任一presence值、code、digest或identity重新暴露为top parameter。禁止另设`IME_ON`预处理宏。

SV入口必须加入constant elaboration check：先断言七个presence的`$bits`均为1、两code均为16、两digest均为256且两个identity localparam均为608；再令`{9'b0,HAS_P4,HAS_P3,HAS_P2,HAS_P1,HAS_IME_ARCH_STATE,HAS_IME_FEATURE_OFF_GUARD,ENABLE_IME}`逐bit等于构造后identity的`[527:512]`，两个digest逐bit等于`[511:256]/[255:0]`，magic/schema/config/variant code也等于固定切片。generated wrapper再把该构造结果与自身record-derived expected-identity literal逐bit比较，任一不等都在编译/elaboration阶段失败。build/command-plan validator必须解析SV parameter声明与每条真实工具argv/top graph，拒绝宽度/类型差异以及对这些parameter或其alias使用Verilator `-G`、VCS `-pvalue+`、parameter file、bind/defparam或等价覆盖，并拒绝以bare `RvvCore`作为批准flow top。`ime_variant_binding` execution test还要从generated wrapper/RTL introspection重建actual parameter tuple及608-bit常量，与lock、五个sidecar和DUT identity逐bit比较。这样所有flow仍编译同一parameterized `RvvCore.sv`，但variant只能由target-label锁定的静态wrapper决定。standalone SV test若使用生成的`rvv_ime_capabilities.svh`，只能核对相同parameter值，不能成为新的selector。

lint前置改造是确定硬门：扩展`vcstatic_lint` rule接收由同一Core build config provider导出的`defines,incdirs,expected_top,ime_build_identity`，而不是继续只写`+define+SIMULATION`。首版四tuple的base define集合必须与Core Verilator实际值逐项一致，至少为`SIMULATION,USE_GENERIC,TB_SUPPORT,VLEN_128,ZVE32F_ON`，include dirs至少为`hdl/verilog/rvv/inc`与`hdl/verilog/rvv/design/FPnew/common_cells/inc`；若build graph证明某项不适用于lint，必须通过APPROVED CR同时修改Core/lint manifest，不能静默删除。off/on差异仅来自各wrapper传给SV的parameters及top名，不得加入IME宏。四个lint target分别分析§4.10 mapping中的准确top并在lint前由bind/static assertion核对identity；未完成rule扩展、define/include/top任一不一致时`IMP-P0-BUILD-INTEGRATION`保持OPEN。

`//ime:ime_capability_gen`联合验证catalog、variant、dependency/互斥与external gate，但**不能生成供同一次Bazel invocation在analysis阶段再加载的`.bzl/BUILD` fragment，也不能用execution-time算出的variant hash决定declared-output路径**。可实施的两级链固定为：

1. analysis已知的`ime_capability_source_gen` rule同时读取catalog、delivery variants及build-target bindings三份canonical YAML，生成固定路径`ImeCapabilities.scala`（包含全部delivery与`SEALED_OFF_ONLY` sealed records）和canonical lock JSON；`hdl/chisel/src/coralnpu`的Scala library显式依赖该generated source，因此它在编译`EmitCore`前完成，不反向修改target graph；
2. BUILD作者**不得填写任何record ref attr**。公开helper只接收`name`和非IME flow参数，以`//<native.package_name()>:<name>`形成actual `target_label`，从reviewed source `build_target_bindings.lock.bzl`逐byte查得其discriminator与全部input refs；missing label、重复label、rule-kind不匹配或任何caller kwargs/gen_flags/vopts中的record/config/variant selector都立即`fail()`。内部不可load的private helper再把`SINGLE_VARIANT`的唯一ref、comparison恰好两个ref或package的APPROVED全部`M>=2` refs传给底层rule；这里`M`与active-set config数`N`无关。`EmitCore`只属于`SINGLE_VARIANT`，从compiled records选择恰好一条并经`extra_outs`写出该target固定命名的sidecars；wrapper同时把相同derived constants传给SV parameters。这样现有非`_ime` label只能解析到lock中的off record，BUILD文本不能把它改指向on。

具体build改造固定为：新增唯一`//hdl/chisel/src/coralnpu:ime_capability_types_scala`与generated `:ime_capabilities_scala`；`coralnpu_params`只依赖前者，`coralnpu_base`/SoC/emitter依赖`coralnpu_params + ime_capabilities_scala`，禁止重复编译类型或generated records。新增`ime_chisel_cc_library` Starlark macro包装当前`chisel_cc_library`；其公开签名**没有**`ime_variant_record_ref/config_id/variant_id/enableIme` attr，而是按actual target label从lock派生唯一ref，并调用同一`.bzl`内不可被BUILD `load()`的private implementation helper。`ime_sidecar_dir`也不是caller attr，而由宏不可覆盖地派生为`<target-name>.ime_capabilities`。宏静态追加唯一严格emitter argv并把目录内五个文件逐项加入`extra_outs`、把同一路径传给`EmitCore`。首个profile四target的declared paths因此在analysis时唯一，不能直接使用相同basename落在同一package输出根。macro拒绝`kwargs/gen_flags/vopts`中的`enableIme/IME_ON/imeVariantRecordRef/config/variant/record`任何selector并给全部生成target加`ime_variant_bound` tag。

这要求实际修改`rules/chisel.bzl`而不是假定外层macro能事后加tag：`chisel_binary`与`chisel_cc_library`签名都新增`tags=[]`，后者把`tags+['ime_variant_bound']`逐项传到`<name>_emit_verilog_binary`、`<name>_emit_verilog`、`<name>_verilog`、`<name>`和`<name>_cc`五个生成rule；bindings逐label列出这五项及其companion provider。`verilog_library`/`verilator_cc_library`若底层不接受tags，必须先扩展对应rule API或用可提供同等query-visible tag/provider的真实wrapper rule，不能只给最外层alias打tag。lint、cocotb、VCS、formal、synthesis、FPGA与package helper同样只向DIRECT、SUITE_PARENT及SUITE_MEMBER等`flow_rule_labels`逐actual rule传播`ime_variant_bound`，而非只标aggregate；`TEST_SUPPORT`强制不带该tag并由独立support query闭合，不能把`*_test_data`等support误报为flow target。

每个`SINGLE_VARIANT` primary emitter binding的固定declared sidecars恰包含：

```text
rvv_ime_capabilities.svh
ime_capability_manifest.json
ime_build_identity.json
coralnpu_ime_config.h
coralnpu_ime_note.S
```

`ime_build_identity.json`是与capability manifest分离的closed JCS payload，required fields固定为：

```text
schema_version=1,
schema_sha256, generator_sha256, spec_manifest_sha256, phase_profile_sha256,
base_config_id, config_id:string|null, variant_id, record_revision,
variant_record_ref, variant_wrapper_config_ref,
requested_module_name, elaborated_top_module_name,
top_pin_abi_ref, top_pin_abi_sha256,
ime_build_identity_v1_hex,
core_base_build_config_sha256, variant_wrapper_config_sha256,
variant_record_sha256, effective_set_sha256,
final_elaboration_config_sha256
```

该文件本身的`SHA256(UTF8(JCS(payload)))`唯一命名为`ime_build_identity_sidecar_sha256`；禁止把`ime_capability_manifest.json`的hash冒充它。只有primary emitter action声明并写这五个File；其Verilog/model/Verilator/sim/lint/formal/synthesis/package下游binding只能以Bazel dependency/File handle引用同一组，不得重新生成或声明同路径输出。comparison/package binding按discriminator引用各input已有sidecar，不产生新的capability sidecar。实际Bazel输出目录由primary artifact identity隔离，例如`<bazel-out>/.../<emitter-target-name>.ime_capabilities/`；base/wrapper/variant/effective/final-config hash全部写在文件内容/provider/sidecar中，不作为同次build动态路径。若采用预计算lockfile，它必须是经签核的source input并在修改catalog/variant时由独立更新步骤重生，不能由本次action自举。所有生成文件固定`schema/generator/spec/profile/base/wrapper/variant/effective/final_config` hash，禁止时间戳、绝对workspace路径和非确定顺序。generator/build不得写或覆盖source tree，并行off/on/config builds不得共享可变输出。每个elaborated target必须断言恰好一个record，compiled Scala record、SVH/JSON/identity/header/note与manifest overlay hash逐值相等；clean-regenerate检查任一drift、串用或hash mismatch立即失败。decoder mask/match真值与independent oracle不能同时由该generator产生。这里的target-generated `rvv_ime_capabilities.svh`只是downstream standalone-test/identity audit sidecar，**不是本次EmitCore的输入，也不加入`RvvCore.addResource`**；standalone test以Bazel dependency直接消费它，避免生成动作依赖自身输出。

首版release scope只含§1.1两个AXI Core config，完整SoC/TLUL/FPGA不是IME-on交付物；但它们不得依赖隐式缺省而悄然漂移。`CoreTlulParameters`、`SoCChiselConfig`以及`CoralNPUChiselSubsystem.instantiateModule`必须显式携带并传播与其**自身base config**匹配的`SEALED_OFF_ONLY` record，所有非授权SoC/other-core target由`build_target_bindings.yaml`逐label封存，并经repo-wide query、逐binding test、逐target build与identity检查；不得借用AXI `ime_off_baseline`。`//ime:ime_non_delivery_targets_off_test`若存在，只能是展开全部`binding_test_label`的开发便利`test_suite`，其单一aggregate result不能关闭gate。SoC emitter不得提供独立feature CLI。未来把SoC加入on scope时，必须新增delivery config ID、off/on records、静态targets、pin/identity/build/test/lint/PPA mapping并重审，而不是只在AXI Core打开IME。

任何新增的**source-tree DUT输入**`rvv_ime_*.sv/.svh`必须同时完成三层资源闭包：`hdl/verilog/rvv/{design,inc}/BUILD`导出、`hdl/chisel/src/coralnpu/BUILD`的`coralnpu_rvv.resources/srcs`注册、`RvvCore.scala addResource`按依赖拓扑加入；Bazel-out identity sidecar按前段明确排除且由下游target直接依赖。新增Scala helper也必须进入对应RVV/scalar `srcs`；Scala capability types/generated records必须严格服从前述无环dependency graph。build integration validator还要查询并执行Core Verilator、cocotb Verilator/VCS、standalone VCS compile、lint、formal、synthesis/package和授权FPGA flow的真实dependency graph，证明每个flow消费同一parameter/identity和全部IME sources。若某flow不在首版scope，manifest必须显式`OUT_OF_SCOPE`并证明其target强制off；“文件存在于workspace”或只在一个simulator编译不能关闭`IMP-P0-BUILD-INTEGRATION`。

`ImeBuildIdentityV1`的canonical packed layout固定为608 bit，不能由实现自行改宽或换端序：

```text
[607:576] magic = 32'h494d4531  // ASCII "IME1"
[575:560] schema_version = 16'h0001
[559:544] config_code
[543:528] variant_code
[527:512] flags = {9'b0,has_p4,has_p3,has_p2,has_p1,has_ime_arch_state,
                   has_ime_feature_off_guard,enable_ime}
[511:256] variant_record_sha256
[255:0]   effective_set_sha256
```

`config_code/variant_code`必须逐值来自上述`build_target_bindings.yaml`两张code表；`config_code`不得跨base config复用，`variant_code`只可在同一`(base_config_id,variant_id)`的递增record revisions间复用。validator必须用`config_code -> base_config_id -> core_base_build_config_sha256`唯一join及variant payload中的`variant_wrapper_config_sha256/required_hardware.core_base_build_config_sha256`逐值核对；因此608-bit record digest传递绑定base和wrapper，而非把code当成可变缩写。所有多字节数字和digest按network/big-endian解释，SHA-256文本首字节进入digest的最高8 bit。两个digest的唯一算法、closed payload、排序和空值规则只采用本节前述`full_variant_record_payload/effective-set payload`定义；这里不得另建简化hash输入。

每个config×variant DIRECT test及每个SUITE_MEMBER child在Bazel analysis graph中必须直接依赖对应DUT artifact和同一identity manifest。Bazel `test_suite` parent本身没有`deps/data`接口，不要求伪造direct DUT attr；它的`tests[]`必须逐项等于lock中`suite_members[].member_label`，parent binding test再证明每个child的direct DUT/identity/phase join。simulation/formal/lint wrapper必须在stimulus/analysis前从hierarchical constant或bind interface读取上述608 bit并逐bit核对；它不得占用architectural CSR或product pin。production synthesis不要求保留一个无功能用途的identity cell：trusted launcher先从pre-synthesis elaborated RTL提取并核对identity/sidecar，再把该identity、generated RTL hash、综合命令/result与exact binary/netlist hash共同签入PPA/release result。`IME_CONFIG_ID/IME_VARIANT_ID`环境变量只可反向交叉检查，绝不能选择DUT。identity不可读/不相等、sidecar不一致或launcher记录的artifact hash不同即result无效。

软件发现边界固定为：IME Draft 0.1没有可写入标准`misa`的bit，`__riscv_ime_lambda()`也只是配置状态查询，不能作为presence probe。首版不宣称portable runtime discovery，禁止发明标准CSR含义或从VLEN/lambda猜测。固定firmware由`coralnpu_ime_config.h`获得vendor-prefixed enable/profile/variant/effective-set hash；off必须使`CORALNPU_IME_ENABLED=0`且toolchain不得定义/发射任何IME ISA feature，on才按software claim闭包启用。`coralnpu_ime_note.S`产生`.note.coralnpu.ime`供link/package/loader兼容性检查；若平台loader尚不消费该note，只能宣称build-time/package-time检查。未来runtime dispatch必须另锁定platform ABI/device-tree或vendor CSR、权限与虚拟化contract。

配置验证必须包含两条独立等价性边界。第一条不能由待测off DUT自建reference。owner-approved `ime/config/base_reference.yaml`使用closed schema：

```text
reference_artifacts[]:
  reference_artifact_id,
  kind={CYCLE_ACCURATE_RTL,INDEPENDENT_ARCH_MODEL},
  source_commit_or_model_version, source_tree_sha256,
  build_label_or_model_config, tool_and_container, artifact_sha256,
  comparison_capabilities={architectural_trace,cycle_trace,
                           external_transactions,stall_timing,pin_protocol},
  owner_approval
comparison_schema_artifacts[]:
  comparison_schema_artifact_id, kind=TRACE_SCHEMA,
  relative_path, artifact_sha256, schema_version, owner_approval
reference_bindings[]:
  reference_binding_id, config_id, base_config_id,
  core_base_build_config_sha256, off_variant_id=ime_off_baseline,
  cycle_reference_artifact_id, independent_arch_model_artifact_id:string|null,
  model_config_sha256:string|null,
  top_pin_abi_ref, top_pin_abi_sha256,
  trace_schema_artifact_id, trace_schema_sha256,
  clock_reset_assumptions, input_domain, compare_mask,
  allowed_delta_records[]
```

每个delivery config恰有一条binding，`config_id/base_config_id/core_base_build_config_sha256/top_pin_abi_ref/hash`必须与其off wrapper mapping一致；`trace_schema_sha256`必须逐bit等于所引`comparison_schema_artifacts[]`文件的实际bytes SHA-256，且该文件随reference evidence进入bundle。pin ABI和trace schema是不同语义对象，不得再合并成一个opaque digest。`cycle_reference_artifact_id`必须引用`CYCLE_ACCURATE_RTL`且五个comparison capability全为true；普通ISA/trace model只能作为附加architectural oracle，绝不能替代cycle/stall/external-transaction reference。同一independent model可被多个config引用，但每个binding必须有独立`model_config_sha256`证明参数化；cycle RTL artifact只有在base config、top-pin ABI、trace schema和artifact hash完全相同时才可共享。reference/schema artifact及binding ID全局唯一，且artifact必须来自caller-owned、task-scope外批准来源，禁止引用本次待测off artifact。

每个差异record使用不可复用`DELTA-*` ID并逐项给出`requirement_ids,rule_ids,adr_or_cr_id,input_predicate,exact_expected_trace_delta`；自由文本wildcard、忽略整个CSR/transaction class或引用待测artifact均失败。该文件/hash/approval进入caller input、implementation manifest和`REFERENCE_COMPARISON` result。

* 每个`ime_off_baseline`对其config-specific cycle reference做constrained architectural/cycle trace equivalence；若binding另有independent model，再执行architectural differential。known IME raw encoding precise-illegal、IME/reserved high-vtype canonicalization及P0 correctness fix只有在该binding的`allowed_delta_records`逐项列明时才允许，其它差异为0。result同时记录binding/artifact/model IDs、source/build/tool/config hashes、off DUT identity/RTL/binary hash、compare-domain/mask/delta-set hash，不能只记录DUT；
* 同一post-change config的on对off，在约束“不执行known IME raw encoding、不请求IME high-vtype非零值、不使用仅on软件资产”下，scalar/base-RVV architectural state、memory/bus transaction、trap/interrupt/debug时序、retirement/minstret和stall逐cycle等价。`ImeBuildIdentity`及纯verification观测信号不进入architectural比较。

这两条proof之外还必须分别执行off precise-illegal/reserved请求矩阵和on legal/disabled-cell矩阵；off结构absence不能替代行为proof，行为等价也不能替代结构absence。

内部错误处理冻结为fail-closed：

* stale epoch/macro mismatch response：丢弃且零side effect，同时verification assertion；不得映射到新macro；
* capacity/overflow：由ready/credit结构性阻止，形式证明不可达；不得覆盖oldest；
* duplicate ack、partial commit、illegal state transition：置内部sticky `ime_protocol_error`、永久禁止新IME accept并保持现有serial barrier；首版不把它伪装成标准architectural exception，release必须用formal证明该路径不可达；
* ECC/parity、runtime self-test与安全故障恢复不在首版scope；若产品要求，必须新增security/safety REQ和platform error-routing ADR。

## 5. 分阶段实现与关闭门槛

### P0：状态和 trap 基础设施

必须完成：

1. 扩展 `RvvConfigState`（Chisel）、`RVVConfigState`（SV）、`RvvCoreWrapper` 生成文本、BlackBox IO、Shim、ROB return state 和 `RvvConfigState.vtype` 拼接；新增的 IME high fields及 feature-dependent output `altfmt` 必须全程可观察；
2. 先修复 wrapper 的既有 field width：`vl=8`、`vstart=7`、`xrm=2`、`sew=3`、`lmul=3`、`lmul_orig=3`（本 `VLEN=128` profile）；`vstart=7` 是索引 0..127 的正确宽度，不能扩成 8。随后为每一个新增 field 指定一致的 Chisel Bundle、SV port/struct、assign 和 consumer width，并通过首个profile四tuple `ime_interface_width_*_test`；其它profile按active set `2N`展开。禁止依赖 Verilog implicit truncation/extension或现有 width waiver；
3. 修复 reset 与 unsupported-vtype canonicalization：将标准只推荐的reset状态固定成CoralNPU强制策略 `vstart=0,vl=0,vtype=0x80000000`，内部显式设置 `lmul_orig=LMUL1`、所有新增fields=0，断言reset release后valid config无X。VS!=Off时，对每种unsupported-vtype `vsetvl/vsetvli/vsetivli`验证它正常退休一次、`minstret+=1`、`vstart=0`、`vl=0`、software-visible `vtype` **恰好**为 `0x80000000`、`rd!=x0`时写0而 `rd=x0`时无GPR write、无illegal fault，machine-mode profile再验证 `VS=Dirty`/派生 `SD`。必须与VS=Off的同一组VSET成对回归：后者是illegal，`minstret+=0`、不写rd且保持vl/vtype/vstart/VS/SD；两个路径不得共用错误side-effect；
4. 在 `RvvFrontEnd.sv` 实现 lambda WARL、`vsetvli/vsetivli/vsetvl` 的完整 high-vtype behavior、feature-dependent reserved mask 和 `vill` canonicalization；按披露 matrix 覆盖 zero、1、2、4、8、16、32、64 请求及 SEW change。`vsetvl` 必须消费完整 rs2，`vsetvli/vsetivli` preserve high fields；`bs/altfmt_A/B` 原样可表示、只在消费 instruction 检查。完整枚举 `rd/rs1={x0,nonzero}` AVL forms：`rd=rs1=x0`只在old `vill=0`且new/old VLMAX（由SEW/LMUL ratio决定）相同时合法keep-vl；lambda/bs/altfmt-only合法改变不改变VLMAX，必须保持vl。对old `vill=1`或VLMAX改变这一reserved form，本CoralNPU profile固定选择正常完成VSET并canonicalize `vill=1,vl=0,vstart=0`，不得随机选择或误trap；
5. 关闭 config coherence gate：为 config readback 和 IME decode 提供 valid/ready snapshot 或等价 forwarding/stall；测试 `vset*` 紧邻 `csrr vl/vtype`、IME、另一次 `vset*` 的 program-order 行为，禁止从 `configState.valid=0` 的 bits 读出架构状态；
6. 让 IME 使用 `lmul_orig`，以“同一 architectural LMUL、不同 VL”的 regression 证明 `K_eff` 不变、只有 `N` 改变；覆盖 `VL=0` 触发 reduced `.lmul` 的反例；
7. 修复 `CsrRvvIO.vl` 的 7-bit 截断，并验证 `csrr vl` 在 VL=128 时返回 128；
8. 在production Decode建立§4.2 single logical owner。IME在lane k>0时只挡k及younger并允许older prefix drain；到lane0后建立`ime_pending/ime_illegal`及sticky fault。每个illegal在serial admission后恰好一次fault、零VRF写；实现并区分`ImeFaultBookingAck`与`ImeTrapBoundaryAck`，只有后者释放lock；覆盖competing fault且禁止frontend duplicate owner；
9. 建立可观测的`ime_serial_safe/accept_safe/fault_safe`、全系统barrier与tagged outer-retire ack。accept前优先处理pending debug/trap；accept后defer interrupt、debug halt、trigger、single-step与scalar trap到outer-retire。列举所有NMI/异步kill source；不可延迟者必须有shadow discard+kill/ack；
10. 扩展scalar RetirementBuffer entry/IO以macro_id匹配而非只按PC；建立`ImeCompletion`唯一owner及production adapter，adapter可映射现有`uop_pc/last_uop_valid`但write lane不得产生第二completion。分离`completion_valid`与`actual_write_valid`，新增tagged`ImeMacroCommitGrant`/`ImeOuterRetireAck`。mini/full都验证N=0不进入VRF/debug accumulator、但在atomic macro-commit正常retire一次；不得以aggregate empty/nRetired充当ack；
11. 修复backend retire→VRF write-valid使用最终retire/trap-gated valid；断言invalid lane、trap lane及no-write completion均零write-valid/零strobe，并覆盖lane0 trap+残留w_valid及younger done lane；
12. 完成field-semantic full-word decode regression：§8的四条IME OPIVV word与标准OPMVV widening-multiply word同时回归；确认feature-off走Decode-owned sticky fault、依次完成`ImeFaultBookingAck`与`ImeTrapBoundaryAck`，且A/B未交换；
13. 建立§4.10默认off的sealed `ImeVariantRecord`/逐capability source；`enableIme`只能是只读derived constant，Bazel target是唯一selector。它同时驱动Chisel Decode/vtype、条件SV elaboration和manifest；构建时断言direct/effective extension closure及Scala/SVH/JSON/DUT identity一致。默认off target中，raw IME instruction encoding必须走Decode-owned illegal-instruction trap；reserved high-vtype非零配置请求则是VSET本身成功退休一次、清 `vstart`并canonicalize为`vl=0,vtype=0x80000000`，不得错误产生instruction trap；
14. 创建并签核§4.4/§4.5的spec/build manifest、interface ABI、side-effect/traceability matrix、validator与width test；Table 87/88/89无missing/duplicate/conflict，ABI在backpressure下稳定；
15. 校验顶部已归档 `ime/riscv-spec-inter20260710.pdf` 的固定SHA-256和module status/section/page映射，将V 1.0 §9.1、Zicntr 2.0 §4.3、Machine ISA 1.13 Chapter 3 traceability写入spec manifest；hash或章节不符立即停止。无需再向caller索取base-V artifact，也禁止复制一份未关联hash的重复PDF或只依赖会漂移网页；
16. 关闭privileged scope gate：若声明machine-mode vector-context correctness，实施`mstatus.VS` Off/Initial/Clean/Dirty；VS=Off时覆盖所有existing base-RVV/IME instruction以及vector CSR read/write/VSET的illegal behavior，不得只接IME decoder。成功改变vector register/CSR的base-RVV、VSET和IME均按本contract保守置VS Dirty并派生RV32 `mstatus.SD`；软件写VS的Off/Initial/Clean/Dirty只改status，**不得清零或改写**VRF/vector CSR，必须用写Off/Initial后恢复的bit-exact state-preservation test证明。P4对FS/FPR/FCSR实施同类规则。若不声明，manifest必须明确bare-metal/non-privileged并禁止相反声明；S/H mode始终不在本contract scope；
17. 修复RetirementBuffer trap accounting：删除当前`nRetired=deqReady-retiredEcalls`的cause特判，实施`nRetired=PopCount(dequeued_entries where architectural_retire==1)`。所有同步trap entry（ECALL、普通Fault、IME illegal/memory fault）为0且不得产生success retirement/outer ack；用fault前同包1/2/3条older legal entry分别验证它们仍各计1，trap entry为0，并验证ImeTrapBoundaryAck对应edge之前/当edge`minstret_delta=0`。
18. 物化并签核§1.2、§4.6--§4.10与§11规定的 `requirements.yaml`、schemas、architecture/FSM、owners、risk、verification/coverage/CI计划；P0/P1所有root REQ必须APPROVED且unmapped=0，关闭 `IMP-ENG-REQ-BASELINE/ARCH-BASELINE/DV-PLAN`；CDC=0与全部枚举RDC quarantine/partial-reset proof通过后才可关闭`IMP-P0-RESET-RDC`；
19. 创建 `ime_capability_gen`、唯一catalog与逐config off/on variant instances；analysis-known source rule先生成包含全部sealed records的common Scala/lock并作为Scala library依赖，BUILD再静态声明target tuple，emitter只产生每target固定declared SVH/capability-JSON/build-identity-JSON/header/note五sidecars；不得生成供同次analysis加载的Bazel fragment或runtime-hash输出路径。clean-regenerate并验证catalog/variant/generator/effective-set hash；创建 `ImeVrfCommitBatch`单ready的4-lane ABI与atomic assertion，不得继续用四个独立handshake；
20. 关闭`IMP-P0-OPTIONALITY`：取得并签核§4.10 `base_reference.yaml`，禁止DUT自建reference；验证非法tuple/hash/旁路define/重复selector全部elaboration fail；off structure实际集合与canonical guard allowlist恰相等、phase datapath/IME reset/VRF mux/shadow额外clock load为0；off guard precise-illegal且零base backpressure；逐tuple test label直接依赖正确DUT并先核验`ImeBuildIdentityV1`；完成可复现的reference及on-vs-off constrained equivalence；release schema只做fixture test，真实release artifact留给`IMP-ENG-CI-RELEASE`；
21. 关闭`IMP-P0-BUILD-INTEGRATION`：为on/off wrapper从同一record传递SV parameters，完成新增SV/Scala三层resource registration；按§7.6有限label矩阵逐tuple编译Core Verilator、运行cocotb Verilator/VCS、编译standalone VCS并执行lint。首版SoC/TLUL/FPGA显式绑定off并标明非on交付scope，`CoreTlulParameters -> SoCChiselConfig -> instantiateModule`不得丢variant；`ime_target_bindings_lock_test`、repo-wide universe/tag query集合证明及每个target各自的`OFF_ONLY_TARGET` binding/build/identity result必须全部PASS，aggregate test-suite结果不计；未来授权on时再补完整静态target矩阵；
22. 取得并验证 `engineering_targets.yaml`、`platform_async_events.yaml`与named RACI binding。缺少PPA/latency/interrupt-deferral数值时可完成P0基础设施，但P1 datapath DoR和 `IMP-ENG-PPA-BUDGET`保持OPEN；
23. 完成§7.6 trusted bootstrap/receipt/plan链路的自举实现和negative test，证明capture receipt、bootstrap ledger、command-plan hash、result ledger与attestation不可替换。

P0 未完成前，不得加入 IME datapath。

### P1：整数 W=1

必须完成：

1. 实现 §4.3 profile；所有已披露 `(SEW,LMUL,VL)` 合法组合均遵循 `Sλ(SEW)={2}` geometry；未关闭 lambda scope gate 时禁止扩大该合规声明；
2. 实现独立、非 DUT helper 复用的 reference model，严格采用 PDF 的 `tile_reg_idx/mat_A_idx/mat_B_idx/mat_C_idx` 和 `j -> i -> k` 读写顺序；
3. 实现§4.5的max-4-register shadow C/byte-valid overlay；所有alias read查overlay，独立sequencer compute期零VRF写，最终以0或`ceil(N/lambda)`个valid lane在单个MacroCommit edge原子写active bytes、VS/SD并退休；
4. 覆盖四个signedness、每个N、VL=0/full VL、group edge、C/A/B alias、vta=0/1、模溢出和back-to-back IME；partial-N poison全部A rows；
5. 对illegal双ack、older-prefix drain、slot0/barrier、debug/trigger/single-step defer、tagged outer-retire、completion/write-valid、N=0、backend trap write-gating和`last_uop_valid`写property；
6. 运行base RVV回归，确认OPMVV widening multiply、exception与debug无退化。

只有第 1 节的签核条件及 §3.1 lambda scope gate 都关闭后，P1 才可宣称“该锁定 PDF revision 下、当前 Zve32x scope 的三个 type-specific integer extensions 与该 VLEN/lambda profile 正确”；无论如何都不能宣称完整 `Zvvmm` family。

### P2：更宽 K 和 capability 扩展

P2 是 non-restartable MAC phase，必须先复用 §3.6 的 `ime_pending`、serial/fault admission、outer-retire C-write commit 与 interrupt policy；在该 gate 未关闭前不得开始任何 widening datapath。P2不复用`ImeEngineP1`的W=1 state machine；任一P2 CELL进入`effective_legal_cell_ids`时，`PRES-P2-DATAPATH`必须同时实例化`ImeEngineP2`、W/packing state、互斥VRF arbiter input和atomic commit source，否则elaboration fatal。P1/P2 engine在首版`IME_MAX_INFLIGHT=1`下必须onehot0，不允许双方同时拥有VRF/commit。

按一项 PDF Table 88 type extension 一次推进；下表只是候选的首批 row，不是自动授权的 decoder：

| 指令 | 初始可选行 | 对应 extension |
| --- | --- | --- |
| `vwmmacc.vv` | SEW16/EEW8，SEW32/EEW16 | `Zvvi8i16mm`、`Zvvi16i32mm` |
| `vqmmacc.vv` | SEW32/EEW8 | `Zvvi8i32mm` |
| Int4 / `v8wmmacc` / SEW64 | 后续独立项目 | 需 packed-4bit、SEW64 与完整 capability 审计 |

`vm=0` 在 P1/P2 必须 illegal；它不是普通整数指令，而是未实现的 MX floating-accumulate encoding。

每个 P2 extension 开始前，必须把每个 operand 的 `{SEW,EEW,EMUL,group base/bound}`、format/signedness、alignment 和 overlap rule 写成单独真值表；不得沿用 P1 的“任意 overlap 可接受”结论。在 `EXT-WIDENING-MULTIEEW-OVERLAP`关闭前，W>1的C与A/B只允许**不overlap**；即使满足high-end widening条件也不能启用。A/B彼此同EEW overlap可按锁定规则接受。对 `EMUL_C=16`，另有 `EXT-M16-OVERLAP`，没有external normative澄清时同样保持C相关overlap disabled。每一个 Table 88 reserved cell 必须在 Decode ingress 判 illegal，不能在 datapath 以后静默 no-op。

每个已启用 row 还必须交付：

1. independent packing oracle，覆盖 W=2/4/8 的 storage-to-logical mapping、all A/B sign combinations、sign extension、4-bit low/high nibble order 和 modulo-`2^SEW` result；
2. field-semantic operand order test：`A=vs1`、`B=vs2`；至少以 W=2/SEW16、lambda=2、LMUL=1、VL=2 的 A signed `0xff`、B unsigned `0x80`（其余 K/C 为零）证明 source field 被交换时一定失败：正确 C 为 `0xff80`，交换 fields 后为 `0x8080`；
3. all legal/illegal overlap layout tests，尤其错误按 `LMUL/W` 缩小 source group、source high-end 不等于 C high-end、unaligned/over-bound group；
4. per instruction concrete capability manifest；任何不在 manifest 的 format、SEW、W、extension bit 或 reserved row 都是 illegal，而不是 fallback 到 P1/W=1 datapath；
5. 对每个CELL计算`touched_C_registers`并证明同edgecommit lane容量足够；不足者保持disabled。full P2关闭`IMP-P2P4-ATOMIC-COMMIT`前不得报告COMPLETE。

### P3：tile load/store（当前硬阻塞）

四条tile-LS的raw partition必须锁定为：

| mnemonic | `[31:29]` | `[28]` | `[27]` | `[26]` | `[25]` | `[24:20]` | funct3 | opcode |
| --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |
| `vmtl.v vd,(rs1),rs2[,Lλ][,vm]` | `Lλ` | 1 | 0 | 0 | `vm` | `rs2` | `111` | `0000111` |
| `vmttl.v vd,(rs1),rs2[,Lλ][,vm]` | `Lλ` | 1 | 0 | 1 | `vm` | `rs2` | `111` | `0000111` |
| `vmts.v vs3,(rs1),rs2[,Lλ][,vm]` | `Lλ` | 1 | 0 | 0 | `vm` | `rs2` | `111` | `0100111` |
| `vmtts.v vs3,(rs1),rs2[,Lλ][,vm]` | `Lλ` | 1 | 0 | 1 | `vm` | `rs2` | `111` | `0100111` |

`[19:15]=rs1`、`[11:7]=vd/vs3`。`Lλ=000`选择vtype.lambda，非零按exact encoded lambda解释；bit26只选择storage-grid order-preserving/transposing，不能隐含W unpack。manifest必须由这些字段生成raw mask/match并与普通vector load/store做collision test。

不得把它称作“复用现有精确 LSU”。tile load/store 的 `vstart!=0` 是合法 restart state，和 P1 MAC 的 `vstart!=0` illegal 规则不同；但 P3 的 **pre-request legality failure**（vill、Lλ、LMUL、group、encoding 等）仍必须走 §4.2 的 `ime_pending -> ime_fault_safe -> ImeFaultBookingAck -> ImeTrapBoundaryAck`，不得发送 memory request 或复用无 ack frontend trap。在实现 `vmtl/vmts/vmttl/vmtts` 前，必须设计并验证新的 LSU→RVV fault protocol，至少带：

```text
macro_id, macro_pc, raw_inst, load_or_store,
rs1_base, LD=unsigned(X(rs2)), SEW, EEW_bytes, lmul_orig,
effective_lambda, VL, initial_vstart, vm, v0_mask_snapshot[127:0], vd_or_vs3
```

上列 immutable macro snapshot 必须在**接受时**锁存；`v0_mask_snapshot`仅在`vm=0`时有语义，但两种`vm`值下都使用同一固定宽度接口；不能在后续 element request 时重读可变 CSR、scalar register 或 mask。每个实际 memory request 至少携带：

```text
macro_id, logical_i, flat_tile_index, effective_address,
is_load/is_store, store_data
```

每个 response 至少携带：

```text
kind={load_data,store_done,fault}, macro_id, logical_i,
load_data, element_effective_address, faulting_i(for fault), cause, tval
```

`logical_i` 是 PDF 的 raw logical element index；它不是 VRF flat index、register number、memory offset 或 “completed count”。`completed_before_fault` 最多是 debug statistic，不能代替 `faulting_i`。新的 `Lsu2Rvv` protocol 必须有上述显式 response kind；`fault` response 不得同时为 `load_data`/`store_done`、不得触发 VRF write，也不得借用旧 `last` bit 表达。`load_data`/`store_done` 必须携带含epoch的`macro_id`与logical progress，以便 backend 只为同一未 killed macro 提交结果。LSU不产生macro_done；tile engine是唯一iteration owner，只有全部active element transaction已按序durable（或no-work）、无fault且`vstart_update(success,0)`/required context update已durable，才生成恰好一次`ImeCompletion`。fault path禁止`ImeCompletion/ImeOuterRetireAck`。

fault metadata 必须由实际 fault source原样携带，不能由下游仅凭 `load_or_store` 重建：

* `cause`集合必须由P3 memory/privilege profile逐值枚举，不得只写“memory fault”：最小M-mode、无translation profile至少区分load address-misaligned/access-fault（4/5）与store/AMO address-misaligned/access-fault（6/7）；若MPRV/translation或未来S-mode进入scope，还必须支持load/store page-fault（13/15）；若平台声明hardware-error exception则加入19并锁定优先级/tval策略。若交付LSU对所有tile EEW address都支持unaligned access，manifest可以声明不会产生4/6，但必须用跨line/bus boundary test证明，不能默认；
* `element_effective_address`是faulting `logical_i`的XLEN-width **virtual** element起始EA（无translation时数值可等于physical address）；`tval`是按caller锁定的privileged trap与memory/PMA profile最终应写入xTVAL的virtual address，二者不得偷懒与post-translation PA/AXI line address合并。cause 4/6在发出split之前报告address-misaligned时，`tval=element_effective_address`；Machine ISA §3.1.16只明确规定misaligned load/store引发access/page/hardware-error且选择非零informative `mtval`时报告**实际faulting portion virtual address**。不得把该句外推成任意aligned AXI split的标准保证；其它case必须由 `EXT-P3-MEMORY-PROFILE`锁定。自然对齐且未拆分的access fault二者相等；
* 16-byte line address、group base、下一个request address都不是通用`tval`。若首版不实现可精确报告portion address且fault-atomic的split access，manifest必须禁止split/unaligned，misaligned element在任何bus request前以cause 4/6失败；不得先完成部分store再报告可重试fault。即使自然对齐，若AXI/target可能在error response前产生store写或会在restart时重复的device/read side effect，该region/config也不得启用对应restartable tile access；必须由PMA/bus contract或monitor证明faulting transaction满足所声明的replay/zero-side-effect规则；
* 当前 `FaultInfo={write,addr,epc}`、FaultManager 固定 5/7、`DBus2Axi` line-address TODO 与 AXI read-response timing TODO 都必须在 P3 前关闭；否则 precise exception source 本身不成立；
* fault record 必须保持到 backend ROB/flush 与 scalar FaultManager 两侧各自 durable ack。专门回归 `Lsu2Rvv.ready=0`、scalar sink多周期 stall与二者交错；不得在 ack 前覆盖 `faultReg` 或清空 slot。

最安全的第一版每macro只允许一个未完成的**element transaction**：从request发出，一直到response被接受且load VRF write已durable或store durable-done ack已返回，整个链路完成后才可发下一个active `i`。仅“bus request已响应”不算完成；否则后续fault可能错误flush尚未durable的older load result。若为了性能允许多个element transaction，必须有按`logical_i`的in-order commit/reorder/cancel协议，并在fault flush中保留所有`<faulting_i`的pending commit，且证明fault `i`后绝不存在`i+1`的VRF write或store side effect。发出每个active `i`前只在macro内部保存restart candidate `i`，不得逐element写architectural `vstart`；发生fault时才在precise trap boundary提交`vstart=i`，所有active access成功完成（含`vstart>=VL`或没有active element的no-work case）才提交`vstart=0`。faulting element与之后元素无副作用，已成功的更早active element保持可见。

`vstart` 不是 backend-local variable，P3 必须新增 tagged architectural update transaction：

```text
vstart_update = {macro_id, kind={fault,success}, value={faulting_i,0}}
```

每次active access前保存`i`的restart candidate。pre-accept illegal、ordinary killed-no-effect path、unsupported async kill及stale epoch不得提交update；accepted P3 memory fault必须在tagged flush ack后提交`faulting_i`，manifest-enabled element-boundary async stop必须提交`next logical_i`，success必须提交0，三类提交都按各自boundary protocol完成。该通路必须穿透RVV wrapper、`RvvCsrIO`、`Csr`、`configState.valid/readback`，并按architectural age仲裁CSR `vstart` write、RVV update、flush/reset：older CSR write先完成，younger write不得越过tile macro；reset取消尚未进入required fault/stop boundary的update。现有wrapper对`vcsr_valid`与CSR write的固定Mux priority不是可接受的P3 ordering proof。

P3 first profile 必须将 asynchronous interrupt 延后到 tile macro success/fault boundary。若未来允许 element-boundary interrupt，则它是另一套 capability：必须产生已提交的 `vstart=next logical i`、停止/ack outstanding request，并证明重启不重复/跳过任何 side effect；在该证明前不得声称 interruptible tile-LS。

P1的“丢弃shadow”不能外推到已产生memory effect的P3。caller必须逐项列出NMI、debug-reset及其它不可延迟event：若它们不属于会重置整个platform且由`ImePreResetQuiesceReq/Ack`或common-reset atomic-cancel contract覆盖的global reset，则P3要么以platform evidence证明该event不存在/可延后，要么实现element-boundary stop，先drain/cancel outstanding element transaction、保留older load/store effect、提交`vstart=next logical_i`和privileged VS/SD，再交付event。仅清tile-engine state会造成store重复或load丢失，必须禁止。

structured fault 是同一架构事件的两个消费者：backend以含epoch的`macro_id`在ROB标记fault，scalar `FaultManager`使用同一event的PC/raw instruction/cause/tval生成一次architectural trap；二者不可各自再合成第二个trap。accepted P3 runtime fault的冻结顺序固定为：

1. 立即停止faulting element尚未durable的effect及所有younger issue，向manifest列出的backend/LSU/VRF/completion consumer发tagged flush；CSR fault-boundary update不在这组flush consumer内；
2. 等待全部required `ImeFlushAck`，同时保留fault前已durable的older load VRF writes与store effects；
3. 再分别发`ImeVstartUpdate`与适用的`ImeContextStatusUpdate`并等待各自durable ack：提交`vstart=faulting_i`，privileged scope同时提交`VS=Dirty`及相应SD并保留fault前partial-load trace；之后才允许fault record到达scalar precise trap-take point；
4. faulting instruction以`minstret+=0`被trap消费，写CSR并建立redirect后产生`ImeTrapBoundaryAck`；
5. 只有`all_required_flush_ack && fault_boundary_vstart_and_required_dirty_durable && ImeTrapBoundaryAck`三者成立才释放serial lock/slot/macro_id。

该路径禁止产生`ImeCompletion`、`ImeOuterRetireAck`或success trace。P3 success path则必须在全部active load/store effect与`vstart=0`/required context update durable后，由tile engine唯一产生一次正常completion，RB随后retire并产生outer ack，`minstret+=1`。该协议必须接入§4.2的global flush/age contract。必须证明：prestart/inactive/tail无访存、fault前active element可见、`vstart=faulting_i`、重试只执行`[vstart,VL)`。

这不是仅扩 `Lsu2Rvv` 的改动：P3 必须同步扩展 `Decode -> LsuCmd/LsuUOp -> scalar LSU request -> RVV request/response -> backend ROB -> scalar trap`，或实现有等价语义、完整含epoch的`macro_id`和 flush proof 的独立 tile engine。当前 `Lsu2Rvv={addr,data,last}`、`RvvCore.sv` 对 non-last 直接产生 VRF write、vector fault 产生 completion-like response，故现有 bridge 不可复用。

P3 的 generic tile-LS decoder/执行模型还必须满足以下规范契约，不能复用 P1 MAC 的 `vstart=0` 规则：

1. effective lambda 是 instruction `Lλ` 非零时的该立即数，否则是 `vtype.lambda`；非零 `Lλ` 必须精确支持，**不得**按 vtype 的 WARL 规则 clamp；无 effective lambda、非整数 LMUL、VL 不可整除、group 未对齐/越界或保留 encoding 均为 illegal；
2. `vill=1` 必须先于 `Lλ`/group check 产生 illegal；所有 legality 必须在首个 memory request 前完成，illegal 保持 `vstart`、VRF、memory 与 FCSR 不变；
3. tile-LS 的 LMUL 是 architectural `vtype.vlmul`，在 CoralNPU 中同样必须使用 `lmul_orig`，不得使用 reduced `.lmul`；
4. `vmtl/vmts` 的 `linesize=lambda*LMUL`，其 memory element offset 为 `(i/linesize)*LD + (i%linesize)`；`vmttl/vmtts` 使用 transposed offset `(i%linesize)*LD + (i/linesize)`；两者都通过 PDF `tile_reg_idx` 映射 logical element 到 register group；
5. `LD=0` 时，order-preserving `vmtl/vmts` 使用 `lambda*LMUL`，transposing `vmttl/vmtts` 使用 `VLEN/(SEW*lambda)`；`LD` 一律为 unsigned `X(rs2)`，effective address 必须以 XLEN 宽度计算 `rs1 + truncate_xlen(mem_offset * EEW_bytes)`，不得使用 host signed arithmetic；
6. `vstart!=0` 是合法的 restart index；`vm=0` 在 P3 是普通 `v0` mask（不是 P4 的 `v0.scale`）。load 的 inactive/tail destination 必须保持不变，store 的 inactive/tail 不访存且二者不产生 memory exception；masked tile load 的 destination group overlap `v0` 是 illegal。Base V §9.1.4.2把mask source视为EEW=1且禁止同一physical source register以多个EEW读取，因此masked tile store的data source group若包含 `v0`也必须pre-ingress illegal；不能因IME页面只额外写load禁令就漏掉通用source规则；
7. tile-LS 传输的是 **SEW-bit storage element**。`vmttl/vmtts` 转置 storage grid，不能被当作 W>1 packed narrow logical input 的转置，也不得 implicit W-unpack/repack。storage-width-qualified `_as_eS` 只由当前C API定义给order-preserving `vmtl/vmts`；transposing intrinsic只定义logical width=storage width且至少8-bit的natural-storage form。不得为Int4/OFP4提供logical transpose，也不得发明`vmttl/vmtts _as_eS`；
8. P3 reference model 必须逐 element 覆盖 `[vstart,VL)`、mask hole、LD=0/高位为 1 的 LD、四个 instruction variant、faulting first/middle/last active `i`、load/store retry、`vstart>=VL` 与 `Lλ=0/nonzero`，不得用普通 1-D vector-LSU index helper 代替；
9. tile-LS 只消费其 geometry/address/mask 所需的 SEW、LMUL、VL、lambda、vstart 与 vm；`bs`、output `altfmt`、`altfmt_A/B` 不参与 tile-LS legality或数值解释。只要 vtype 本身已经合法，不得因这些 ignored fields 的值拒绝 tile-LS。

P3 同时必须实现下面的 **C accumulator tile 软件/ABI 协议**；它不是可选优化：

```text
M = N_max = VLEN / (SEW * lambda)
VL_C_full = M * N_max
tile-LS LMUL = EMUL_C
partial-C mask[p] = ((p % N_max) < N),  0 <= p < VL_C_full
```

1. 对 row-major C 用 `vmtl.v` / `vmts.v`，对 column-major C 用 `vmttl.v` / `vmtts.v`；物理 C shape 始终是 `M x N_max`；
2. partial-N C load/store **不得**使用 `VL=M*N`，因为 active column 在物理 layout 中不连续；必须以 `VL_C_full` 加上上式 mask；
3. tile load 的 inactive/tail destination 保持不变，tile store 的 inactive/tail 不访存，二者均不采用普通 `vta/vma` fill policy；
4. `EMUL_C=16` 没有合法 LMUL=16 single tile-LS：software/compiler 必须通过 IME **pair/unpair pseudo-intrinsics** 将 m16 accumulator 表示为两个 m8 half，再以 LMUL=8 load/store。它们不是新 ISA instruction：`vunpairlo/hi` 是无指令、无数据移动的 alias view，`vpair` 是 value-copying 编译器操作，必要时才发 register moves。令 `C_half_cols=8*lambda`；low/high half 分别覆盖 `0<=j<C_half_cols` / `C_half_cols<=j<N_max`，并以 `C_half_cols` 为每 half line size 构造 partial mask；当 `N<=C_half_cols` 时跳过 high half；
5. PDF 明确规定 masked m16 half-store 的 mask 来自 `v0`；Base V多EEW source规则进一步适用于**所有**masked tile store。故任何masked C load/store的data/destination group都不得包含 `v0`，P3 ABI必须为其选择不含v0的group。对m16 partial half I/O统一把C放在 `v16-v31`，避免low/high half中的任一store-data group与mask重叠；full-tile `vm=1` 的无mask half I/O不受此限制；
6. C I/O 的 `LMUL=EMUL_C` 通常不同于 compute 的 `LMUL_spec`。software 必须在 I/O 后恢复 compute LMUL；P0 必须保证这一 LMUL-only change 不改变 selected lambda。

### P4：完整 FP/MX（当前硬阻塞）

P4 as-built manifest必须固定 `invalid_frm_behavior=illegal_instruction`，明确它是CoralNPU对标准reserved case选定的行为，而不是标准唯一要求。`frm` CSR仍为完整3-bit RW；5/6/7必须可写回，不能在CSR write时clamp。

P4 同为 non-restartable MAC phase，必须先满足 §3.6：全部C write、Completion/fflags/context intent在stall期间held，并在同一个P4 `ImeMacroCommit.fire`与RB retirement精确提交；只把 `fflags` 延后、先写部分C或先取得CSR ack再退休均不合格。触及C registers超过已实现atomic commit lane数的CELL必须保持disabled；full P4关闭`IMP-P2P4-ATOMIC-COMMIT`前不得报告COMPLETE。

实现前必须先补齐 `fflags` 写回到 `Csr` 的端到端通路、`frm`、所需 FP formats、SEW64/EEW64 和 type-extension legality，并关闭 §2 的 Zvfbfa normative dependency gate。P4 full profile必须新增不同于首个P0/P1两config的P4-capable base/delivery config ID；它的off/on record共享base-derived `has_vtype_altfmt=true`和同一pin ABI，IME variant不得成为Zvfbfa开关。P4 manifest 必须分别记录 `has_vtype_altfmt` 与是否宣称完整 Zvfbfa；不能因实现了 output selector 就自动宣称全部 Zvfbfa，也不能在没有锁定该字段配置语义时猜测实现。常用 RVV target 的 `ZVE32F_ON` 只说明它编译了一个现有 FP subset；当前 `FLEN=32`、FCSR write 被丢弃的状态不足以支持 PDF 中的 FP64/完整 Zvvm FP family。

所有P4 matrix MAC必须在ingress统一检查：`vill=0`、`vstart=0`、integer LMUL、lambda/VL/EMUL_C、A/B/C group alignment/bound、PDF Table 87或Table 89的target cell非reserved、该cell所列extension已实现，并且dynamic `frm`是`0..4`。锁定的 Base Vector Architecture §9.1.9.1 规定：任意 vector-FP instruction 在 `frm=5/6/7` 时行为 reserved，且与 `vstart`、`vl` 无关；它没有强制唯一 trap 行为。本 CoralNPU profile 在标准允许的实现选择中**固定映射为 pre-backend precise illegal-instruction exception**，因此所有P4 profile都必须这样处理，不因bare-metal scope消失，即使`VL=0`、`vstart>=VL`或数据路径看似不舍入也一样。privileged scope额外要求`mstatus.VS!=Off`、`mstatus.FS!=Off`。失败不写C、不更新`fflags/VS/FS/SD`。P4同样受§3.3的 `EXT-WIDENING-MULTIEEW-OVERLAP`与 `EXT-M16-OVERLAP`约束；不得因转入FP路径绕过它。

所有 matrix MAC 都不支持普通 vector mask；`vm` 的语义必须按 instruction class 分流，不能统一解释为 mask：

* `vfmmacc` 的 `vm=0` 是 reserved；
* `vfwmmacc/vfqmmacc/vf8wmmacc` 的 `vm=0` 是 FP-input MX form，读取 `v0.scale`，不是 mask；
* `vwmmacc/vqmmacc/v8wmmacc` 的 `vm=0` 分别是 integer-input `vfwimmacc/vfqimmacc/vf8wimmacc`；
* ordinary FP `vm=1` 的 Table 87 row与 legality完全忽略 `bs`；`bs=0/1` 必须选同一个 unscaled cell，decoder不得因 `bs=1` 拒绝普通 FP MAC；
* 所有 MX path 要求 `SEW*lambda>=16`；`bs=1` 时要求 `W*LMUL<=SEW`；`vd`、`vs1`、`vs2` 任一和 `v0` overlap 都是 illegal；integer-input MX 固定 signed input / `altfmt_A=altfmt_B=0`，低位 output `altfmt` 选择 C 的 FP format；Table 89 的所有 reserved cell 都必须 pre-ingress illegal。

output/input format fields必须按各自字段解释，不能合并成一个 `altfmt` predicate：

* provisional Zvfbfa layout 中，低位 `altfmt=vtype[8]` 只选择 C format。Table 75 至少要求 `SEW=32/64 && altfmt=1` reserved，且 `vsew[2]=1` 的 output-format encoding reserved；最终 configuration-time `vill` 行为以锁定的 Zvfbfa artifact为准；
* OFP4 **input** 要求对应的 `altfmt_A=0`/`altfmt_B=0`；对应 input field 为 1 才是 reserved。此前把“OFP4 `altfmt=1`”笼统判 reserved 是错误的：例如 Table 87 某些 OFP4-input row 可以由低位 `altfmt=1` 选择 E5M2 output；
* `FP16×FP16 -> BF16` 与 `BF16×BF16 -> FP16` reserved；只有 mixed `FP16×BF16`/`BF16×FP16` row可以选择 FP16或 BF16 C，且两项对应 type extension都必须 effective-enabled；
* FP32/FP64 input 的 `altfmt_A/B` ignored，但 output `altfmt` 仍按 Table 75/Table 87 独立检查；不得因 input ignored而接受 reserved C format。

P4 decoder 必须先对 direct extension set计算 §4.4 的 Table 86 transitive implication，再选 Table 87/89 cell。FP rows同时检查 Table 73 的 `Zve32f/Zve64d` dependency；integer-input MX 的 base dependency在 ISA owner裁决前保持 `external_blocked`，不能用当前 `ZVE32F_ON` 宏自行补结论。

MX scale layout必须按 PDF §36.7.3 固定，不得把 v0 当作一维紧凑 `M*S` array。所有当前定义的 MX type 使用 E8M0 scale，令：

```text
scale_width = 8
pair_width  = 16
block_size  = (bs == 0) ? 32 : 16
M           = VLEN / (SEW * lambda)
R           = lambda * SEW / pair_width       # 每行 stride，单位为16-bit pair
S           = ceil(K_eff / block_size)         # 每行 active scale-pair count
pair_index(m,s) = m * R + s,  0 <= s < S
v0[pair_index][7:0]  = scale_A(row m, block s)
v0[pair_index][15:8] = scale_B(column m, block s)
```

`M*R=VLEN/16`，所以 layout始终占满一个 v0；每行 `[S,R)` 是 ignored padding，不能紧凑化或参与 flags。E8M0 `0xff` 是 NaN，其余 encoding是 bias-127 的 exact power of two；但 decode到 C format、paired-scale multiply、partial-sum scaling和C accumulation仍可产生flags。非NaN E8M0转换到C format若overflow，结果必须是`+infinity`；随后`+infinity * nonzero finite`按符号得到infinity，`+infinity * zero`得到default canonical NaN并置相应IEEE flags。不能把“scale是2的幂”误实现为无条件无异常 exponent add。

FP-input MX 的 group还必须同时被 LMUL=1 step与scale block切分。对每个 `step,s`：

```text
step_k = [step*lambda*W, (step+1)*lambda*W - 1]
blk_k  = [s*block_size, min((s+1)*block_size, K_eff) - 1]
int_k  = intersection(step_k, blk_k)
subdot_lo = (int_k.lo - step_k.lo) / W
subdot_hi = (int_k.hi - step_k.lo) / W
```

只处理非空 intersection，并从 `subdot_lo` 起按最多 G 个 consecutive sub-dot-product分组，末组 `g_len` 可为 `1..G`；group绝不能跨 step或block。`rnd=frm/rto` 时先把 S按对应模式round到C format，随后combined-scale multiply与C add都是两个独立的C-format operation并各自使用dynamic `frm`；`rnd=xct` 时对internal S施加scale，再只在最终`fp_add_internal(...,frm)`舍入。mixed input format必须各自精确decode并用`fp_mul_exact`相乘，不能先把一个input round/conversion成另一个narrow format。

首个可实现的P4 numeric profile固定为`P4-N0`：对**每个**enabled `(SEW,W,lambda)`显式列出`(G=1,psm=0,rnd=frm)`；即使tuple相同也不能用“其它同上”漏掉cell。该选择满足G约束并由shared exact-reduction pseudocode完全决定，不需要implementation-specific psm=1算法。若未来改变任一tuple，必须创建新的profile ID/artifact/hash；任何`psm=1` profile还必须提供order-independent bulk reduction（exact-product list顺序unspecified）的完整SAIL，定义每个`g_len=1..G`、所有format与fflags，不能用pairwise order-dependent fold或natural-language说明代替。

P4 必须严格拆分两条数值语义，不能以“任意内部 reduction tree”统一处理：

1. **FP-input MAC**（`vfmmacc/vfwmmacc/vfqmmacc/vf8wmmacc` 的非整数输入路径及其 FP microscaling form）对每个支持 `(SEW,W,lambda)` 必须发布并实现 bit-exact `G/psm/rnd` mapping。`G` 必须为 2 的幂且 `1<=G<=lambda`；LMUL>1 必须等价于按 register number 递增执行的 LMUL=1 steps，group/microscaling block 不得跨 step。`psm=0` 必须 exact；`psm=1` 必须提供可执行 SAIL fragment/算法并覆盖每个 shortened `g_len`。同一 `(SEW,W,lambda)` 的 mapping 必须对所有合法 format、scaled/unscaled form 一致，`bs` 不得选择另一 tuple。mixed FP16/BF16、OFP4 input field与output `altfmt` legality严格采用上一段规则；
2. **integer-input MX MAC**（`vfwimmacc/vfqimmacc/vf8wimmacc`）对每个scale block严格依次执行：exact integer dot；`int_to_fp(dot,fmt_C,frm)`；将A/B scale分别decode到`fmt_C`并以`fp_mul(...,fmt_C,frm)`形成paired scale；`fp_mul(paired_scale,fp_sum,fmt_C,frm)`；`fp_add(C,scaled,fmt_C,frm)`。每一步分别OR flags；它**不**使用`G/psm/rnd`。scale pair使用上面的`m*R+s` layout。combined scale为NaN时，该C output写canonical default NaN、停止该output后续block计算；只保留该NaN block的scale decode/multiply flags及更早block flags，该block products/accumulation和所有后续block均不求值、不贡献flags。

`fflags` 是 architectural retirement state，不是 backend-local side effect。每条legal-success P4 macro只在其architecture-retire时提交一次 `fflags := fflags | instruction_flags`；`instruction_flags` 只 OR 实际求值的 active C output helper operation flags，tail/inactive/no-work/VL=0/killed/faulting macro 不贡献。任何helper因input NaN、`0*infinity`、opposite-sign infinity add、scale decode/arithmetic、partial rounding或final accumulation而物化NaN时，都必须写对应C format的default canonical NaN；payload无architectural意义。必须增加 ready/valid 保持至 CSR 接收，并使用一个按 program age 的 `fflags_next` arbitration 来合并 RVV、scalar-FP 和 software FCSR write，或把冲突完全序列化；不得依赖多处 Chisel `when` 的文本优先级。普通 FP exception 是 sticky `fflags`，不是 scalar trap；只有 legality failure 是 illegal trap；被 trap/flush 杀死的 macro 绝不可提交 flags。privileged first profile采用锁定artifact允许的conservative dirty policy：每条legal-success IME在outer-retire同边界置`VS=Dirty`，每条legal-success P4另置`FS=Dirty`，并令RV32`mstatus.SD=(FS==Dirty)||(VS==Dirty)||(XS==Dirty)`；pre-accept illegal与killed-no-effect path不提交这些transition。accepted P3 runtime fault是明确例外：它必须随fault-boundary `vstart`/partial-load state提交VS Dirty/SD，但仍不退休。

reference model 必须按所属路径逐位比较 C result 和 accrued `fflags`。验证必须覆盖 Table 87/89 的 legal/reserved cell、`vm=0/1`、v0 overlap、`bs` boundary、LMUL>1 step equivalence、signaling NaN、`0*infinity`、opposite infinities、OF/UF/NX、forced-NaN block termination、同周期/相邻 scalar-FP/CSR write 与 trap/flush。两类语义、格式组合（含 MX 的 `bs`/`altfmt_*`）和 CSR 通路均关闭前，不得开启任何 FP/MX type extension。

## 6. 完整 IME family 的额外要求

必须严格区分三种 scope：

1. **P1 pinned-profile subset**：仅 `Zvvi8mm`、`Zvvi16mm`、`Zvvi32mm`，仅当前可配置的 SEW8/16/32 与披露的 lambda matrix；
2. **完整 `Zvvmm`**：PDF Table 73/88 的所有整数 row，包括 Int4、Int8、Int16、Int32、Int64 输入/累加组合。Int64 rows 的依赖是 `Zve64x`；当前 CoralNPU frontend 对 SEW64 一律 `vill`，所以必须先扩展基础 RVV 到 Zve64x，再实现 SEW64、EEW64、4-bit packing 和全部 group/retire capacity；
3. **完整 `Zvvm` family**：除完整 `Zvvmm` 外还包含 `Zvvfmm`、`Zvvmtls`、`Zvvmttls`，分别依赖 P4 的 FP/FCSR 关闭与 P3 的 restartable tile-LSU 关闭。

因此“完整 IME family hardware under the pinned PDF”只能是 P0--P4、所需 Zve32/Zve64 base dependency、软件范围内接口和所有 applicable `implementation_blocking` 外部门关闭后的结论，绝不是 P1 的别名。要进一步声称 stable-standard/portable ABI，所有 applicable `claim_only_blocking` gate 也必须关闭。

PDF 是 Draft 0.1。即使硬件功能完全符合锁定 PDF，也只能表述为“符合该 PDF hash 的实验性实现”；要成为公开稳定 ISA，仍需要外部 ISA owner 提供冻结/ratified 版本与工具链支持。这一外部裁决不能由 RTL 或 LLM 解决。

## 7. 验证与签核清单

### 7.0 可执行验证计划、coverage分母与CI层级

P0必须创建 `ime/verification_plan.yaml`、`ime/coverage_plan.yaml`及对应Draft 2020-12 schema。ID namespace固定为 `TEST-*`、`PROP-*`、`COV-*`、`WAIVER-*`。每条APPROVED TEST/PROP已经是一个可执行scope instance，不允许在`config_ids[]/variant_ids[]`里保留待运行时展开的矩阵。common required fields为：

```text
id, requirement_ids[], phase_profile_id, result_scope_kind,
level={UNIT,INTEGRATION,SYSTEM,FORMAL,STATIC,SOFTWARE,SYNTHESIS},
exact_bazel_label_or_tool_argv, stimulus_or_assumptions,
independent_oracle:{kind,artifact_ref,sha256}|null,
expected_result, timeout_seconds, seed_policy, owner_role,
result_artifacts[], pass_criteria, status, scope_payload
```

`verification_plan.yaml` root另外required非空或显式空的`tool_actions[]`，作为TOOL command唯一真源。每项closed payload固定为`{tool_action_id,source_ref={source_kind={TEST|PROP|FLOW},source_id,source_record_sha256},applicable_phase_profile_ids[],tool_path,tool_sha256,exact_argv[],cwd,env_bindings[],input_artifact_refs[],declared_output_paths[],scope_payload,owner_role,approval_ref}`，再计算`tool_action_record_sha256=SHA256(UTF8(JCS(payload)))`并与payload并列保存。ID全局唯一；profile数组非空、排序去重；source ref必须唯一join当前APPROVED TEST/PROP或`flow_catalog[]`完整record及其重算hash。tool path/hash、argv/env/scope或source改变都必须新建action ID或APPROVED revision，旧record不可改义。TOOL command只能引用一条这样的canonical record，runner不得现场构造自由`tool_action_record`。

verification plan不得保存独立`helper_labels[]`或其它suite-member副本。`exact_bazel_label_or_tool_argv`若引用SUITE_PARENT，validator必须从`build_target_bindings.targets[]`唯一join该parent并使用其`suite_members[]`；若引用DIRECT target则member集合严格为空。command plan与result中的expected/executed member集合都从同一lock投影并逐byte比较，从而避免verification plan与build graph各自维护不同helper全集。

`scope_payload`以`result_scope_kind`为discriminator并用JSON Schema `oneOf`固定为：

```text
GLOBAL:
  {config_id:null,base_config_id:null,variant_id:null,direct_duts:[]}
VARIANT:
  {config_id,base_config_id,variant_id,variant_record_ref,
   direct_duts:[{target_label,expected_build_identity,declared_artifact_paths[]}]}
OFF_ONLY_TARGET:
  {config_id:null,base_config_id,variant_id:null,variant_record_ref,target_label,
   direct_duts:[{target_label,expected_build_identity,declared_artifact_paths[]}]}
REFERENCE_COMPARISON:
  {config_id,base_config_id,variant_id:ime_off_baseline,variant_record_ref,
   direct_duts:[{target_label,expected_build_identity,declared_artifact_paths[]}],
   reference_binding_id,cycle_reference_artifact_id,
   independent_arch_model_artifact_id:string|null}
VARIANT_COMPARISON:
  {config_id,base_config_id,variant_id:null,
   compared_duts:[
     {variant_id:ime_off_baseline,variant_record_ref,target_label,expected_build_identity},
     {variant_id:ime_on_delivery,variant_record_ref,target_label,expected_build_identity}]}
MULTI_ARTIFACT_PACKAGE:
  {config_id:null,base_config_id:null,variant_id:null,package_id,target_label,
   input_variant_record_refs[]{minItems=2},input_comparison_target_labels[],
   release_scope_id,direct_duts:[]}
```

`direct_duts`在VARIANT/OFF_ONLY/REFERENCE中恰一项，variant comparison只允许固定两项且顺序off→on；package scope不直接拥有DUT result，只引用已签名input refs并验证zero missing/extra。`declared_artifact_paths[]`是analysis-known path，不是预测hash；实际binary/netlist SHA-256只在execution result中生成并绑定。其它未列字段由`additionalProperties=false`拒绝。`config_id`只属于delivery namespace，OFF_ONLY必须为null并用独立`base_config_id` join canonical record。template若为书写便利描述多个tuple，必须在plan approval前按`<template-id>--<normalized-scope-key>`确定性展开成独立TEST/PROP ID；collision失败。command/result schema复用同一discriminator，不能让一条非comparison result跨两个DUT。

每条COV记录 `id,requirement_ids,bin_or_metric_definition,denominator_source,merge_tool,threshold,exclusions[]`。分母只能由APPROVED requirements/spec manifest/FSM/RTL coverage DB确定生成，禁止测试作者手填“已覆盖总数”。release最低阈值冻结为：

| Metric | P0/P1 release threshold |
| --- | --- |
| applicable REQ mapped/executed/pass | 100% / 100% / 100% |
| legal/illegal encoding、CELL/RULE、SEW/LMUL/lambda/vm/vstart有限cross | 100% exhaustive |
| FSM state与legal transition coverage | 100% |
| assertion elaborated、nonvacuous与pass | 100% |
| formal safety property | 0 unknown/unproven；bounded liveness达到approved bound |
| IME-owned RTL line / branch / toggle | ≥95% / ≥90% / ≥85% |
| decode/legality/fault/commit checker mutation score | ≥90% |
| baseline off-vs-base architectural differential | 0 unauthorized difference |
| on-vs-off constrained non-IME cycle/transaction differential | 0 difference |
| off forbidden hierarchy/register/clock-load instance count | 0；feature-off guard按批准allowlist逐项存在 |
| variant identity/overlay/DUT artifact mismatch | 0 |

任何coverage exclusion必须引用 `WAIVER-*`，含metric/bin、理由、风险、owner、approver、创建/到期日期和evidence hash；S0/S1 defect、architectural requirement或precise-trap path不得waive。工具不提供某metric时不能把它记100%，必须换工具或由release approver明确保持 `IMP-ENG-DV-PLAN=OPEN`。

CI运行策略冻结在 `ime/ci_matrix.yaml`：

| Tier | 触发 | 最低job | 重试/flaky | retention |
| --- | --- | --- | --- | --- |
| presubmit | 每次change | global schema/REQ/architecture/ABI；active set `2N` artifact独立identity/width/build/lint/base-RVV；invalid-config negative、off structure、两类equivalence、适用phase directed smoke与关键formal（首个profile为四tuple/P0/P1） | retry=0；失败不得标flaky跳过 | logs/results ≥30天 |
| nightly | 每日或相关merge | active set `2N` artifact全部directed、100 deterministic seeds/artifact、完整formal/coverage/mutation、generator clean-regenerate、software header/ELF-note compatibility | retry=0；不稳定test自动开BUG并阻止其关闭gate | DB/logs ≥90天 |
| release | release commit的clean checkout | 重跑全部nightly + `2N` artifact synthesis/PPA/identity + reproducibility + SBOM/license + enable→rollback→off recovery drill | retry=0；不得复用presubmit结果 | release生命周期+1年 |

每个job记录runner image digest、Bazel/tool/simulator/license版本、CPU/memory、timeout、shard与exact env allowlist。release结果只能来自受信CI identity，开发机通过不能替代。

### 7.1 必须存在的独立模型

参考模型输入：32×VLEN VRF image、完整且 immutable 的 architectural vtype snapshot、raw instruction fields（显式 `vs1=A`/`vs2=B` mapping）、memory image（P3）、frm/fflags（P4）。它不得调用 DUT 的 SV/Chisel index helper，也不得读取 reduced `.lmul`。P1 必须明确实现：

```text
tile_reg_idx
mat_A_idx(i,k)
mat_B_idx(k,j)
mat_C_idx(i,j,N_max)
int_gemm 的 j -> i -> k 读写顺序
```

### 7.2 P1 最小验证矩阵

| 类别 | 必须覆盖 |
| --- | --- |
| 配置 | CoralNPU reset policy得到 `vstart=0,vl=0,vtype=0x80000000`、无X；每种unsupported-vtype VSET正常退休一次/`minstret+=1`、清 `vstart`、得到 `vl=0,vtype=0x80000000`、`rd!=x0 -> x[rd]=0`/`rd=x0 -> no GPR write`且无trap；vsetvl full high fields、vsetvli preserve/init、feature-on/off reserved mask、披露的 `Sλ` WARL（0/1/2/4/8/16/32/64 请求）、`lmul_orig != lmul`；`vset* -> csrr vl/vtype/vstart`、`vset* -> IME`、CSR `vstart` write -> IME 的 valid/forward/order regression；privileged scope 时VS Off覆盖base-RVV/IME/vector-CSR/VSET且成功state-change转Dirty；ordinary integer `vm=1` 对 `bs` ignored，且仅在 `has_vtype_altfmt=true` 的合法 vtype中验证 low `altfmt` 0/1 ignored |
| 几何 | SEW 8/16/32，LMUL 1/2/4/8，lambda=2，所有合法 N，VL=0、VLMAX，以及同 LMUL/different VL 时 K_eff 恒定 |
| 数据 | 全零、极值、四种 signedness、随机、模 2^SEW 溢出；P1 A/B field order 用非对称 A-row/B-column tile layout 判别（W=1 的 signed/unsigned 乘积模 2^SEW 不能单独判别 source swap）；partial-N 时 poison 每一行 A，以验证全部 M 行仍读取 |
| C tail | vta=0 原值保持；vta=1 允许但 P1 实测保持；physical stride=N_max |
| alias/commit | `vd==vs1`、`vd==vs2`、partial group overlap；证明equal-EEW cases被接受、partial `acc_q`在final-k前不可见、每次read命中shadow overlay时看到sequential model值；compute期零VRF write，最终只用`N==0?0:ceil(N/lambda)`个valid lane一次atomic macro commit，tail-only register零write/trace |
| trap | 每个illegal原因、PC/mtval/mcause、零VRF写、一个Decode-owned fault record；分别stall/验证booking ack和trap-boundary ack，只有后者unlock；覆盖competing memory/frontend fault，禁止frontend duplicate owner |
| 时序 | backpressure、IME在lane k时older prefix drain/IME+younger stop、slot0、pending/safe predicates、frontend/config/trap、older scalar/LSU、accept后interrupt/debug halt/trigger/single-step defer、tagged outer-retire/boundary unlock、last-uop、N=0 completion/write-valid split；断言no older stranded/no younger effect |
| 回归 | standard OPMVV widening、field-semantic raw decode、A/B non-symmetric、RVV exception/debug/trace及既有RVV regressions |

### 7.3 必须证明/断言的属性

* feature-off 或 legality failure：在 `ime_fault_safe` 前不产生 fault pulse/entry/write；随后不产生 RVV backend entry 或 VRF write，并恰好产生一个 durable-ack scalar fault record；legal IME 不产生该 fault；
* 每条 raw IME instruction 只有一个 `ime_pending`；每个 illegal恰好一次 fault booking、恰好一次对应的 `ImeTrapBoundaryAck`，每个 legal均为零，且任何 competing FaultManager event都不能吞掉/重复它；
* P1 macro accepted 时，`ime_accept_safe` 的每个子条件成立；直到该 macro **outer retirement** 前没有 younger architectural effect，interrupt 不得越过该 boundary；
* legal accept的`fetch_lane0.fire/ImeRbEntryEnq.fire/ImeCommand.fire`逐cycle完全相等，illegal booking的`fetch_lane0.fire/(ImeRbEntryEnq.fire&&isImeFault)/ImeFault.fire`逐cycle完全相等；两者都使既有instBuffer计数恰好+1而非双enqueue，专用RB metadata entry绝不经nonWriting/PC-only路径提前退休，且IME不进入普通RVV backend；
* 所有sticky ABI在`valid&&!ready`时payload稳定；`ImeFaultBookingAck`恰为fault fire且不释放illegal lock，trap-boundary ack恰好一次；macro ID在全链路quiescent前不复用，stale epoch零side effect；legal success恰好一次retirement且`minstret+=1`，illegal/P3 fault为`minstret+=0`且无completion/outer-retire；trap trace若存在必须exactly-once且不能标success；
* 每个 active C result 与 reference model 的对应 `(j,i)` 状态相同；
* `shadow_valid`集合在每个cycle恰好等于词典序已完成output；当前output partial只在`acc_q`，final-k的batch/overlay使用包含`mac_result_next`的next-state；
* P1 绝不写 `j>=N` 的 tail；
* geometry 始终从 `lmul_orig` 推导；
* `N=0`的唯一`ImeCompletion` intent满足`macro_id`匹配、`pc=macro PC,last=1`且0-lane batch；若经legacy adapter则唯一映射为`completion_valid=1,actual_write_valid=0,uop_pc=macro PC,last_uop_valid=1`，scalar RB据此参与macro-commit grant但VRF/debug accumulator均不记write；
* partial-N 的每个 `j` 仍处理所有 `i=0..M-1`，不得由 compute VL 截断 A 行；
* m16 capability 未 enable 时，所有要求 `EMUL_C=16` 的 lambda 请求均按 WARL 选到已披露 lambda，而不是进入 8-slot retire path；
* `spec_manifest` 对每个适用 encoding/Table cell有且仅有一个状态，implementation manifest、Chisel/SV feature set与 elaborated assertions一致。
* backend retire invalid/trap lane不产生VRF write-valid或nonzero strobe；P1 compute期只更新shadow C且零VRF write，只有tagged `ImeMacroCommit.fire`写architectural VRF/VS/SD并retire；
* retire mux中batch与normal source永远互斥；batch fire时normal ROB ready/consume/write均0，0/`ceil(N/lambda)`个batch lane各恰写一次，且C/VS/SD/trace/minstret/RB retirement在同一edge发生；
* accept后debug/trigger/single-step/interrupt/scalar trap均不越过macro；global reset丢弃shadow，manifest列出的任何其它async kill都有ack/rollback proof。

### 7.4 P2 不得跳过的额外签核

P2：对每个 Table 88 target cell 用 independent packing oracle 覆盖 W=2/4/8、sign extension、4-bit low/even/high/odd nibble、all A/B signedness、modulo accumulation 和 field-semantic operand mapping。A/B swap discrimination 不得依赖 P1 W=1 modulo result；至少用 P2 W=2/SEW16、lambda=2、LMUL=1、VL=2 的 `A=0xff`（signed）、`B=0x80`（unsigned）、其余 K/C 为零的 case：正确 `C=0xff80`，field-swap control 为 `0x8080`。逐一检查C与A/B non-overlap成功、A/B同EEW overlap、C/A或C/B overlap在external gate OPEN时precise-illegal、LMUL/W-shrunken/low-end/unaligned/out-of-bound overlap、reserved cell及m16 disabled behavior；若owner以后关闭两项overlap gate，再新增对应high-end/m16 normative tests。并对每个 P2 macro 证明继承 `ime_pending`、outer-retire C-write commit 和 interrupt/flush policy。

### 7.5 P3/P4 不得跳过的额外签核

P3 mask-group directed gate：`vm=0`时，masked tile load的destination group或masked tile store的source-data group只要包含 `v0`，都必须在首个memory request前precise-illegal并保持VRF/memory/vstart不变；四条tile-LS各覆盖group含/不含v0，不能只测m16 helper。

P4 FCSR directed gate：逐值写入并读回 `frm=0..7`，证明CSR保留完整3-bit值；再以每个值执行P4/vector-FP，包括 `VL=0`，确认0..4进入相应rounding profile、5..7在instruction ingress产生本profile选定的precise illegal。machine-mode scope还须覆盖FS=Off时scalar/vector FP与FCSR CSR access，及Off/Initial状态切换不清FPR/FCSR。

P3：对四个tile-LS variant分别以PDF `tile_reg_idx`/memory-offset oracle检查`Lλ=0/nonzero`、LD=0/高位LD、ignored format fields、mask hole、`vstart` restart、faulting first/middle/last raw `i`与older/younger effect。每个request/response匹配`{macro_id,logical_i}`；fault response断言精确cause/profile-correct`tval`、零faulting VRF/store-done、一次ROB fault和一次scalar trap。首版验证一个完整element transaction outstanding，特意stall older load VRF commit后尝试推进next i并证明被阻止。分别验证aligned non-split、pre-request misaligned 4/6、可选split portion address/atomicity；store error证明faulting store未写，side-effecting load/device region证明faulting read可安全restart，否则对应region tile access disabled。验证ready/sink stall、跨reset迟到response、pre-reset/common-reset contract、不可延迟event策略和P3 fault partial-write trace。验证fault顺序、vstart/VS/SD、minstret=0及success phase-commit/retire。对full/partial C I/O检查physical layout/mask/m16 halves。P4：先验证Zvfbfa/format/trap artifacts、Table73 dependency与Table86 closure；所有profile覆盖`frm=0..4`和`frm=5/6/7`（含VL=0）illegal，privileged profile覆盖VS/FS Off/Dirty与SD。覆盖Table75/87/89字段规则、MX scale layout、grouping和bit-exact C/fflags；验证全部C lane/fflags/VS/FS/SD/trace/minstret/RB retirement同一`ImeMacroCommit.fire`，并覆盖CSR/scalar-FP竞争、commit backpressure与trap/flush。

### 7.6 强制 Bazel targets 与回归命令

截至本次审计，IME manifest/generator/checker、IME-on build/lint以及逐tuple IME验证target尚未物化；现有off build/VCS target也尚未具备本文要求的sealed binding/identity证据。下面的静态label清单只冻结首个`ENG-P1-VLEN128-MACHINE` profile（P0/P1、`N=2`、四tuple）的contract，不能被P2/P3/P4 profile当作隐式映射。不能把“target not found”、VCS license不可用或只跑aggregate当作跳过；`ime_p*_all`不是必需交付物，也不能产生权威结果：

```text
//ime:ime_spec_manifest_test
//ime:ime_schema_test
//ime:ime_requirements_test
//ime:ime_architecture_test
//ime:ime_verification_plan_test
//ime:ime_capability_gen
//ime:ime_repository_hygiene_test
//ime:ime_workspace_prestate_import
//ime:ime_implementation_manifest_gen
//ime:ime_change_manifest_gen
//ime:ime_command_plan_gen
//ime:ime_bootstrap_attest
//ime:ime_command_runner
//ime:ime_closure_report_gen
//ime:ime_closure_report_attest
//ime:ime_release_manifest_gen
//ime:ime_release_manifest_test
//ime:ime_release_manifest_schema_fixture_test
//ime:ime_option_schema_test
//ime:ime_invalid_configuration_test
//ime:ime_target_bindings_lock_test
//ime:ime_non_delivery_targets_off_test
//ime:ime_artifact_identity_check
//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library
//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library
//hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library
//hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library
//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_lint
//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_lint
//hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library_lint
//hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library_lint
//hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_axi_off_test
//hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_verification_axi_off_test
//hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_axi_on_test
//hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_verification_axi_on_test
//hdl/chisel/src/coralnpu:ime_structure_rvv_core_mini_axi_off_test
//hdl/chisel/src/coralnpu:ime_structure_rvv_core_mini_verification_axi_off_test
//tests/cocotb/ime:ime_p0_rvv_core_mini_axi_off
//tests/cocotb/ime:ime_p0_rvv_core_mini_verification_axi_off
//tests/cocotb/ime:ime_p0_rvv_core_mini_axi_on
//tests/cocotb/ime:ime_p0_rvv_core_mini_verification_axi_on
//tests/cocotb/ime:ime_p1_rvv_core_mini_axi_off
//tests/cocotb/ime:ime_p1_rvv_core_mini_verification_axi_off
//tests/cocotb/ime:ime_p1_rvv_core_mini_axi_on
//tests/cocotb/ime:ime_p1_rvv_core_mini_verification_axi_on
//tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_axi_off
//tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_verification_axi_off
//tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_axi_on
//tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_verification_axi_on
//tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_axi_off
//tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_verification_axi_off
//tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_axi_on
//tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_verification_axi_on
//tests/cocotb/ime:base_rvv_rvv_core_mini_axi_off
//tests/cocotb/ime:base_rvv_rvv_core_mini_verification_axi_off
//tests/cocotb/ime:base_rvv_rvv_core_mini_axi_on
//tests/cocotb/ime:base_rvv_rvv_core_mini_verification_axi_on
//tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_axi_off
//tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_verification_axi_off
//tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_axi_on
//tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_verification_axi_on
//tests/cocotb/ime:rvv_core_mini_axi_off_verilator_model
//tests/cocotb/ime:rvv_core_mini_axi_off_vcs_model
//tests/cocotb/ime:rvv_core_mini_verification_axi_off_verilator_model
//tests/cocotb/ime:rvv_core_mini_verification_axi_off_vcs_model
//tests/cocotb/ime:rvv_core_mini_axi_on_verilator_model
//tests/cocotb/ime:rvv_core_mini_axi_on_vcs_model
//tests/cocotb/ime:rvv_core_mini_verification_axi_on_verilator_model
//tests/cocotb/ime:rvv_core_mini_verification_axi_on_vcs_model
//tests/formal/ime:ime_off_reference_equivalence_rvv_core_mini_axi
//tests/formal/ime:ime_off_reference_equivalence_rvv_core_mini_verification_axi
//tests/formal/ime:ime_on_off_noninterference_rvv_core_mini_axi
//tests/formal/ime:ime_on_off_noninterference_rvv_core_mini_verification_axi
//tests/cocotb/ime:ime_off_reference_diff_rvv_core_mini_axi
//tests/cocotb/ime:ime_off_reference_diff_rvv_core_mini_verification_axi
//tests/cocotb/ime:ime_on_off_diff_rvv_core_mini_axi
//tests/cocotb/ime:ime_on_off_diff_rvv_core_mini_verification_axi
//tests/vcs_sim:rvv_core_mini_axi_sim
//tests/vcs_sim:rvv_core_mini_verification_axi_sim
//tests/vcs_sim:rvv_core_mini_ime_axi_sim
//tests/vcs_sim:rvv_core_mini_ime_verification_axi_sim
```

对首个profile，逐phase cocotb权威**suite label**不是示例，而由以下有限Cartesian product精确枚举；validator必须展开为`2 phases × 4 tuples × 2 simulators = 16`个不同suite label，zero missing/extra：

```text
phase_token   := one of {p0,p1}
tuple_suffix  := one of {
  rvv_core_mini_axi_off,
  rvv_core_mini_verification_axi_off,
  rvv_core_mini_axi_on,
  rvv_core_mini_verification_axi_on
}
Verilator label := //tests/cocotb/ime:ime_<phase_token>_<tuple_suffix>
VCS label       := //tests/cocotb/ime:vcs_ime_<phase_token>_<tuple_suffix>
```

16-count查询只匹配上述exact suite-parent basename grammar；authoritative-suite模式生成的per-testcase child rule不计入这16个parent，但也绝不能被忽略或列为exclusion。每个parent是前述`execution_aggregation_kind=SUITE_PARENT` record，其`suite_members[]`必须从实际Bazel `test_suite` expansion重建并逐项绑定相同DUT/identity/phase，zero unknown/missing/duplicate member。权威plan只请求parent label一次，并从Bazel Event Protocol或等价受信结构化结果保存实际展开的全部member label、testcase ID和逐member outcome；它们必须与lock逐项相等，任一child未请求、未执行、被过滤、skipped或失败都使parent result失败。member不另建权威command/result，不能直接挑一部分member冒充整套PASS，也不能因执行parent而把member重复计数。首个profile的base-RVV回归同样固定四个Verilator parent label `//tests/cocotb/ime:base_rvv_<tuple_suffix>`和四个VCS parent label `//tests/cocotb/ime:vcs_base_rvv_<tuple_suffix>`，并使用同一SUITE_PARENT/member模型。可额外提供`ime_p*_all`作为人工开发便利aggregate，但它不能作为权威result，因为一个未绑定DUT的aggregate不能证明实际所测variant。

每个suite必须引用一个已经独立封存的DIRECT model target；首个profile的八个model label及其映射固定如下，不能让`cocotb_test_suite`按名称临时生成model：

| tuple | Verilator DIRECT model | VCS DIRECT model | elaborated top | direct Verilog dependency |
| --- | --- | --- | --- | --- |
| AXI off | `//tests/cocotb/ime:rvv_core_mini_axi_off_verilator_model` | `//tests/cocotb/ime:rvv_core_mini_axi_off_vcs_model` | `RvvCoreMiniAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog` |
| verification AXI off | `//tests/cocotb/ime:rvv_core_mini_verification_axi_off_verilator_model` | `//tests/cocotb/ime:rvv_core_mini_verification_axi_off_vcs_model` | `RvvCoreMiniVerificationAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_verilog` |
| AXI on | `//tests/cocotb/ime:rvv_core_mini_axi_on_verilator_model` | `//tests/cocotb/ime:rvv_core_mini_axi_on_vcs_model` | `RvvCoreMiniImeAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library_verilog` |
| verification AXI on | `//tests/cocotb/ime:rvv_core_mini_verification_axi_on_verilator_model` | `//tests/cocotb/ime:rvv_core_mini_verification_axi_on_vcs_model` | `RvvCoreMiniImeVerificationAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library_verilog` |

八个model均为`execution_aggregation_kind=DIRECT,plan_action=build`的`SINGLE_VARIANT` target，分别持有自身static target binding/provider/binding test/identity check，并直接依赖表中同tuple Verilog、608-bit identity manifest和sidecar。Verilator不得以`-G`覆盖IME identity；VCS model的`parameters={}`对全部IME字段保持空，不能借参数把off model切成on或反向切换。每个Verilator/VCS suite parent及其members只能依赖表中matching simulator/tuple model；suite触发dependency build不能替代八个model各自的DIRECT build result。现有`rules/coco_tb.bzl`若只支持自动VCS model，P0必须先新增接受exact prebuilt model label的authoritative-suite API，并使parent只是精确`native.test_suite(tests=children)`；未完成前相关target和`IMP-P0-BUILD-INTEGRATION`保持OPEN。

任何其它APPROVED phase profile必须在DoR前由其`active_variant_set.config_pairs[]`和`build_target_bindings.targets[]`物化完整的exact label集合：对每个base config的off/on artifact分别给出primary build、width/identity、lint、base-RVV、phase suite的Verilator/VCS label，以及Verilator/VCS DIRECT model和standalone VCS `target_label,DUT_MODULE,direct_verilog_dependency`；comparison/package labels也逐项封存。plan从这些静态records派生`2N`分母并拒绝placeholder、通配符、未绑定label或复用其它profile identity。P4在exact新config与bindings获批前保持BLOCKED；尤其不得复用本节`has_vtype_altfmt=false`的首个profile四tuple。

首个profile的四个`*_diff_*` label是host-side canonical trace comparator tests，直接消费各自独立运行并签名的DUT/reference trace artifacts；它们不由`coco_tb.bzl`复制，故没有额外`vcs_`别名。comparator必须先核验两侧identity/result/artifact hash和reference binding，再按mask/delta执行比较，不能在同一进程用环境变量重编译/切换两个DUT。

首个profile standalone VCS **compile-only**的四tuple mapping也固定，不按P0/P1改名，而是在每个phase plan中重新执行并绑定当次source/variant hash：

| tuple | exact target | `DUT_MODULE` | direct Verilog dependency |
| --- | --- | --- | --- |
| AXI off | `//tests/vcs_sim:rvv_core_mini_axi_sim` | `RvvCoreMiniAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog` |
| verification AXI off | `//tests/vcs_sim:rvv_core_mini_verification_axi_sim` | `RvvCoreMiniVerificationAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_verilog` |
| AXI on | `//tests/vcs_sim:rvv_core_mini_ime_axi_sim` | `RvvCoreMiniImeAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library_verilog` |
| verification AXI on | `//tests/vcs_sim:rvv_core_mini_ime_verification_axi_sim` | `RvvCoreMiniImeVerificationAxi` | `//hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library_verilog` |

四个standalone target必须直接依赖同tuple identity manifest/sidecar，使用与Core build provider逐项相等的`VLEN_128/ZVE32F_ON/TB_SUPPORT/USE_GENERIC`等既有define且不得添加`IME_ON`。它们只证明独立VCS binary可编译/链接，不宣称runtime smoke；VCS runtime由对应`//tests/cocotb/ime:vcs_*` suite覆盖。若未来要求standalone runtime smoke，必须新增四个exact `sh_test/vcs_test` labels并进入plan，不能把`bazel build`改名成test证据。每个DIRECT cocotb/width/structure/standalone target及每个cocotb SUITE_MEMBER child必须在Bazel analysis graph中直接依赖对应cc-library、identity manifest与overlay；SUITE_PARENT只以exact `tests[]`闭包间接依赖，不能给无该attr的`test_suite`伪造direct dependency。禁止用同一test label配四组环境变量冒充四个DUT。VCS工具或license不可用时，相应result只能是未运行且`IMP-P0-BUILD-INTEGRATION`保持OPEN，禁止以Verilator PASS替代。

`ime_command_plan_gen`必须从冻结的as-built/change manifests生成 `command_plan.json`，逐phase、delivery config、off/on variant和授权toolchain repo展开**exact argv/cwd/env allowlist/declared artifact paths/required overlay hash**；不得用“P2/P3/P4同理”作为machine-readable计划，也不得预填build后才存在的DUT hash。workspace内的 `ime_command_runner`只可做plan schema/ID/argv预检与本地开发便利封装，**不是权威执行或结果信任根**。caller提供的、hash锁定且不在本task change scope内的trusted launcher必须直接按plan spawn每条argv，独立采集cwd/env/start/end/exit/stdout/stderr bytes与artifact hash，并写repo外append-only signed `command_results/<id>.json`。

phase环境字段分成两个且都只做交叉检查：`IME_AS_BUILT_PHASE_ID`和`IME_SUITE_PHASE_TOKEN`均使用大写canonical enum `P0..P4`；前者等于本次manifest/variant实际构建phase，后者等于该test invocation应执行的suite phase。label中的小写token只按唯一映射`p0→P0,...,p4→P4`转换，禁止大小写自由比较。GLOBAL或非test command不设置`IME_SUITE_PHASE_TOKEN`；phase-bound GLOBAL可设置`IME_AS_BUILT_PHASE_ID`，是否设置由plan schema显式记录，不能靠runner缺省。

`command_plan.json`中每个command必须有closed `as_built_phase_id:string|null`、`suite_phase_id:string|null`，并对argv展开后的每个实际test label列出唯一`test_phase_bindings[]{target_label,suite_phase_source={LABEL_TOKEN,AS_BUILT,NONE},expected_suite_phase_id:string|null}`。数组按`target_label` UTF-8 byte-order严格排序且zero duplicate；不执行任何Bazel test subject的command固定为空数组，SUITE_PARENT则同时列parent和全部members。规则固定为：phase-qualified `ime_pN_*`/`vcs_ime_pN_*`使用`LABEL_TOKEN`并由basename转换；base-RVV、width、structure、identity及其它经lock登记为phase-neutral但需phase上下文的test使用`AS_BUILT`；真正不消费phase的test使用`NONE`。存在`NONE`时该argv内全部binding都必须为`NONE`，其expected值、command的`suite_phase_id`和suite env均为null；禁止把phase-free test与phase-bound test混在同一command。一个argv内全部非`NONE` binding的expected值必须相等且逐值等于command的`suite_phase_id`和实际env；因此as-built `P1`重跑历史`P0` suite时不得把phase-neutral test混入同一argv。当前as-built phase为`Pn`时，plan必须对每个`q∈[0,n]`静态列出phase-qualified suite `Pq`，环境固定`AS_BUILT=Pn,SUITE=Pq`；phase-neutral回归另以`SUITE=Pn`运行，或只在同值的`Pn` suite command中合并。test binary从自身label、compiled binding classification和manifest分别重算上述映射，mismatch即fail；环境变量不得选择DUT、改变enabled capability或动态跳过suite。`IME_CONFIG_ID/IME_VARIANT_ID`同样只核对delivery metadata，off-only使用binding中的`base_config_id/variant_record_ref`而不伪造config ID。

command/result schema必须复用§7.0的六种`oneOf` scope，不另建一套字段语义：`GLOBAL`没有DUT；`VARIANT`恰属一个delivery tuple；`OFF_ONLY_TARGET`固定`config_id=null,base_config_id=<id>,variant_id=null,target_label,variant_record_ref`；`REFERENCE_COMPARISON`恰绑定一个config-specific reference binding并记录cycle reference、可选model、off DUT两侧identity/artifact/domain/mask/`DELTA-*` hashes；`VARIANT_COMPARISON`只比较同config固定off/on两侧；`MULTI_ARTIFACT_PACKAGE`只验证APPROVED signed input set与package/bundle。除comparison/package外，一个argv不得跨variant/config/off-only target；comparison不得跨config，package则必须zero missing/extra且不复制input result归属。一个`GLOBAL`argv不得混入任何DUT build/test。

`command_plan.json` root是closed object，至少required `{schema_version,phase_profile_id,as_built_phase_id,preplan_evidence_root_sha256,change_manifest_sha256,implementation_manifest_sha256,post_change_source_tree_hash,source_revision_sha256,commands[]}`；root `as_built_phase_id`是非空`P0..P4`，必须逐值等于generator `--phase`、implementation/change manifest及本次variant revision的phase，不能由任一command另选。`phase_profile_id`必须是本plan唯一APPROVED profile，且逐值等于本plan所引active variant set、verification/flow catalog和implementation manifest的profile。三个source输入hash都必须由generator从已冻结输入重算；再以closed `source_revision_payload={protocol_version="CORALNPU_IME_SOURCE_REVISION_V1",phase_profile_id,as_built_phase_id,change_manifest_sha256,implementation_manifest_sha256,post_change_source_tree_hash}`计算`source_revision_sha256=SHA256(UTF8(JCS(source_revision_payload)))`。它不含plan/result hash，故无自引用；任一source/config/manifest变化都必须产生新revision和新ID namespace，旧result不得跨revision关联。每个post-bootstrap command先有closed common fields `{command_id,command_kind,phase_profile_id,source_revision_sha256,executable_ref,exact_argv[],cwd,env_bindings[],as_built_phase_id:string|null,suite_phase_id:string|null,test_phase_bindings[],bep_output_path:string|null,declared_result_paths[]}`，其中command的profile/revision必须逐值等于root；phase-bound command的`as_built_phase_id`必须等于root，只有verification record明确为phase-free且不消费任何phase env/state的command才可为null，绝不允许填入另一个phase。再用JSON Schema `oneOf`固定唯一subject：

`executable_ref`是closed `{absolute_realpath,sha256,tool_version,version_output_sha256}`；path必须是无symlink的absolute regular executable，并逐值引用implementation manifest的`resolved_executables[]`。`exact_argv[0]`必须逐byte等于该realpath；trusted launcher在执行前后都重算文件hash，直接spawn该absolute path，不经PATH、shell alias或wrapper搜索。Bazel command还必须恰有startup prefix`[absolute_realpath,"--batch","--ignore_all_rc_files"]`，因此system/home/workspace rc和`BAZELRC`不能注入config、filter、define、env或query选项；缺失/重复该option均失败。bootstrap阶段的Bazel argv也服从同一executable/rc规则并由bootstrap attestation绑定。

`env_bindings[]`按name UTF-8 byte-order排序、zero duplicate，每项是closed `{name,value_kind={FIXED|EMPTY|SECRET_REF},fixed_value:string|null,secret_ref:string|null,expected_value_sha256}`。`FIXED`只允许非null fixed value/空secret ref，`EMPTY`固定`fixed_value="",secret_ref=null`，两者hash都重算UTF-8 value；`SECRET_REF`只允许caller-owned nonnull ref、`fixed_value=null`及caller预先锁定的实际value hash。launcher从空环境构造进程环境，只设置这些name，并在result中保存同name、kind和实际value hash而不泄露secret；未列变量一律不继承。PATH即使需要也只能是FIXED且不参与executable选择；HOME/TMPDIR/license/remote-execution变量均须显式绑定。secret只允许license/credential等owner-approved用途，任何config/variant/IME selector作为secret或env均失败。

每条Bazel `build/test/run` command必须在先计算并排序全部`expected_result_id`后，构造`bep_key_sha256=SHA256(UTF8(JCS({protocol_version="CORALNPU_IME_BEP_KEY_V1",source_revision_sha256,expected_result_ids[]})))`，并令`bep_output_path=<trusted_evidence_output_root>/bep/BEP-V1-<bep_key_sha256>.pb`。该此前不存在的path必须进入`declared_result_paths[]`，且exact argv在Bazel subcommand后恰含一次`--build_event_binary_file=<同一absolute path>`；launcher不得隐式追加或改名。因为key只依赖先于command ID确定的result IDs，command ID再hash含该path的exact argv，不产生循环。QUERY command固定`bep_output_path=null`，以signed stdout/stderr和query-specific structured output为证据；其它非Bazel tool若有结构化事件，必须在其canonical tool action中同样显式声明argv/path。

```text
FLOW_TARGET_COMMAND:
  flow_invocations[]{target_label,target_binding_record_sha256,expected_result_id}
GLOBAL_TEST_COMMAND:
  global_test_invocations[]{target_label,verification_record_id,
                            verification_record_sha256,expected_result_id}
BINDING_CHECK_COMMAND:
  {owning_target_label,binding_test_label,binding_check_record_sha256,
   expected_result_id}
IDENTITY_CHECK_COMMAND:
  {owning_target_label,input_artifact_ref,identity_check_label,
   identity_check_record_sha256,expected_result_id}
QUERY_COMMAND:
  {query_id,query_record_sha256,expected_result_id}
TOOL_COMMAND:
  {tool_action_id,tool_action_record_sha256,expected_result_id}
```

`target_binding_record_sha256=SHA256(UTF8(JCS(closed targets[] record)))`；SUITE_PARENT的record因此包含排序后的全部members。`verification_record_sha256`同样重算完整APPROVED TEST/PROP record，`scope_payload_sha256=SHA256(UTF8(JCS(scope_payload)))`。binding/identity check record分别是closed `{check_kind,label,owning_target_label,target_binding_record_sha256,scope_payload_sha256,input_artifact_ref_or_null,expected_identity_hashes[]}`；query record是closed `{query_id,exact_argv[],expected_set_expression_id}`并逐值来自`target_universe`；其它tool action必须引用verification plan或flow catalog中closed record，不得由runner现场杜撰。

六种kind对result-ID通用字段的映射唯一固定如下；表中每个record hash均为`SHA256(UTF8(JCS(对应closed record)))`：

| command kind | `subject_record_sha256` | `plan_action` | `scope_payload` |
| --- | --- | --- | --- |
| `FLOW_TARGET_COMMAND` | `target_binding_record_sha256` | 所引`targets[].plan_action` | 从artifact-binding discriminator唯一派生 |
| `GLOBAL_TEST_COMMAND` | `verification_record_sha256` | `GLOBAL_TEST` | 所引TEST/PROP的GLOBAL scope payload |
| `BINDING_CHECK_COMMAND` | `binding_check_record_sha256` | `BINDING_CHECK` | owning target的scope payload |
| `IDENTITY_CHECK_COMMAND` | `identity_check_record_sha256` | `IDENTITY_CHECK` | owning target的scope payload |
| `QUERY_COMMAND` | `query_record_sha256` | `QUERY` | canonical GLOBAL `{config_id:null,base_config_id:null,variant_id:null,direct_duts:[]}` |
| `TOOL_COMMAND` | `tool_action_record_sha256` | `TOOL_ACTION` | `tool_action_record.scope_payload` |

`tool_action_record`只能是`verification_plan.yaml.tool_actions[]`所引canonical payload；command按`tool_action_id`唯一join并重算`tool_action_record_sha256`、source ref、profile、executable/argv/env/scope和outputs，禁止复制一份可独立编辑的record。QUERY/TOOL缺少映射表任一字段、tool action source悬空或任一join不等即schema失败，不能以null或runner默认补齐。

每种command subject先构造无自由字段的closed `subject_key` oneOf：`FLOW_TARGET_COMMAND={target_label}`；`GLOBAL_TEST_COMMAND={verification_record_id,target_label}`；`BINDING_CHECK_COMMAND={owning_target_label,binding_test_label}`；`IDENTITY_CHECK_COMMAND={owning_target_label,input_artifact_ref,identity_check_label}`；`QUERY_COMMAND={query_id}`；`TOOL_COMMAND={tool_action_id}`，再令`subject_ref_sha256=SHA256(UTF8(JCS(subject_key)))`。对每个subject构造closed `result_id_payload={protocol_version="CORALNPU_IME_RESULT_ID_V1",phase_profile_id,source_revision_sha256,as_built_phase_id,suite_phase_id,command_kind,subject_ref_sha256,subject_record_sha256,plan_action,scope_payload_sha256}`，其中profile/revision只能取command/root的同一非空值；即使QUERY、GLOBAL或`SEALED_OFF_ONLY` source record本身不带delivery profile，也使用本次plan profile，不得从其record中的null派生。固定`expected_result_id="RESULT-V1-" + lowercase_hex(SHA256(UTF8(JCS(result_id_payload))))`。该payload不含command-plan file hash或result内容，故无自引用；同一plan内duplicate result ID或subject多重归属立即失败。再构造closed `command_id_payload={protocol_version="CORALNPU_IME_COMMAND_ID_V1",common_fields_without_command_id,subjects_sorted_by_subject_ref_sha256}`，固定`command_id="COMMAND-V1-" + lowercase_hex(SHA256(UTF8(JCS(command_id_payload))))`；因为common fields已含root-joined profile/revision，command ID同样绑定二者。结果路径只能由expected result ID静态形成，不能反向进入result-ID payload。

为允许§7.6同tuple的Bazel批处理而不牺牲结果归属，FLOW command只有在scope payload、config/variant/off-only identity、`as_built_phase_id/suite_phase_id`、tool/env/cwd以及共享DUT/reference/package/identity/sidecar binding set全部逐值相同时，才可包含多个DIRECT/SUITE_PARENT `flow_invocations[]`；target-local executable、test-data和oracle deps可不同，但必须封存在各自source record中。多个无DUT的GLOBAL tests只需GLOBAL scope、phase、tool/env/cwd逐值相同即可混批，各自不同的non-DUT inputs留在其verification record。comparison、package、不同suite phase或GLOBAL与非GLOBAL均不得混批；BINDING/IDENTITY/QUERY/TOOL command每条只允许一个subject。

trusted launcher必须启用并保存Bazel Event Protocol或等价受信结构化事件，证明每个列出的top-level target实际被请求并得到唯一终态，再为**每个subject**写独立signed result。每条权威`bazel test` exact argv必须恰含一次`--nocache_test_results`；BEP显示任一top-level target或suite member为cached，或无法证明本次实际执行时，该subject不得PASS。允许缓存的开发运行只能产生non-authoritative diagnostic。为避免未定义的共享envelope，批内每份result都重复记录同一`command_id,exact_argv,cwd,env,started_at,finished_at,exit_code,stdout_sha256,stderr_sha256,bep_or_tool_event_sha256`，validator要求同command ID的这些字段逐byte相等；每份result另有自己的subject ref、source-record hash、result ID和outcome。任一subject缺失、filtered、skipped、重复或失败只可使该subject及依赖gate失败，不能由同command其它PASS覆盖。可选aggregate label仍须展开为actual target records，不能保留aggregate权威result。每条result还记录change-manifest hash与command-plan SHA-256；launcher执行前重算plan/attestation，不符即拒绝。任何由workspace runner自行声称的exit/log只能是non-authoritative diagnostic，不能关闭gate。

Bazel analysis不能加载同一次execution action生成的YAML派生文件，因此`ime/config/build_target_bindings.lock.bzl`只能由显式、独立的update动作在analysis之前生成并作为reviewed source input提交。该文件必须导出以actual canonical flow-rule label为唯一key的closed `TARGET_BINDINGS_BY_LABEL`，key集合逐项等于`flow_rule_labels`，同时覆盖DIRECT target、SUITE_PARENT及其全部SUITE_MEMBER。parent/DIRECT value携带discriminator及全部input refs；member value固定`record_kind=SUITE_MEMBER,suite_parent_target_label=<唯一parent>`并逐值继承parent的discriminator、record refs、DUT/identity和phase classification。宏必须先构造自身及其展开member label再做exact dictionary lookup，BUILD/caller不能传入key或value。缺失/额外/重复key、label canonicalization差异、member-parent join不等、value与rule kind不符或一个flow rule解析到多条record都在analysis阶段`fail()`。底层未封装的Core/SoC/FPGA/public sim/lint/formal/synthesis/package rule不得成为BUILD可直接调用的配置入口；语法感知source scan和Bazel query同时要求所有实际flow只经批准helper产生，任何旁路即gate失败。

lock还必须包含`delivery_active_variant_set_id`、排序后的target-universe argv/exclusion ID，以及每条binding的`target/provider/test labels`、suite parent/member关系、artifact-binding discriminator及全部input refs、base/config/variant/revision/ref/code、record/effective/base/wrapper/final-config hashes、requested/elaborated top、top-pin ABI ref/hash、expected artifact paths、reference/package refs、flow IDs和source-registration-set hash；SUITE_MEMBER的`test label`固定为null且provider非null。所有这些都是analysis-known expected metadata，但不复制可独立编辑的feature bits。`ime_target_bindings_lock_test`要求从YAML clean-regenerate逐byte相等，证明全部delivery `SINGLE_VARIANT`和comparison/package inputs恰引用该active set，suite expansion与parent逐项闭合，并对schema固定的repo-wide BUILD/.bzl做语法感知扫描，拒绝绕过批准helper macro直接声明实际flow；它不依赖或构建DUT，故可产生`GLOBAL` result。

每个批准helper macro必须给全部实际flow rule加`ime_variant_bound` tag。DIRECT target和SUITE_PARENT各创建唯一companion `binding_provider_label`与execution-time `binding_test_label`；每个SUITE_MEMBER只创建唯一`member_binding_provider_label`，不得创建独立binding test。`ime_variant_binding` analysis rule的`ImeVariantInfo`只携带lock中的expected metadata和所有实际input target/sidecar/reference/package的Bazel `File` handles；SUITE_PARENT provider/test还必须携带全部member provider及其actual deps。Starlark analysis绝不声称读取action输出内容。parent/DIRECT的`binding_test_label`把这些Files作为runfiles/inputs，在execution时逐input读取sidecar/identity/artifact，重算hash并与provider/lock逐字段比较；parent还逐member验证label/rule kind/testcase/deps/phase且zero missing/extra。其result scope必须恰等于target discriminator：single delivery为`VARIANT`，single non-delivery为`OFF_ONLY_TARGET`，其余为对应comparison/package scope；全部都必须在实际flow前执行。`ime_non_delivery_targets_off_test`只可作为这些off-only test的便利`test_suite`，launcher不得用其aggregate result替代逐test结果。

trusted command plan必须逐argv执行schema固定的两条repo-wide target-universe查询；`test_support_query_argv`非null时还必须恰生成一条QUERY command并执行该物化argv，null时必须零test-support QUERY command、`TEST_SUPPORT`集合为空，且由lock validator的signed GLOBAL result证明此空集条件。launcher把每份实际查询输出按label byte-order排序、保存并签名。rdeps结果必须恰等于`flow_rule_labels ∪ non_test_support_infra_labels ∪ approved_exclusions[].target_label`，tag查询结果必须恰等于`flow_rule_labels`，test-support结果在该查询存在时必须恰等于全部`TEST_SUPPORT` infra。任一parent/member/support candidate未归类、infra伪装、未知exclusion或重复归属均失败。`approved_exclusions`只能排除确实不elaborate/consume CoralNPU/RVV artifact的internal/tooling/data/aggregate rule，不能排除任何实际flow；每项须有不可复用`EXCL-*` ID和owner approval。`binding_infrastructure`只能是前述无递归companion/support且必须被owning target/member完全引用，zero orphan/extra。

随后plan对**每条**`targets[]`记录先产生一个只含该`binding_test_label`的BINDING_CHECK command，scope由artifact-binding discriminator唯一派生；binding test不得批量合并。实际flow默认每target一条FLOW command，只有满足前述严格同scope条件时才可把多个top-level target labels封装成一个command record，但`flow_invocations[]`仍逐target完整列出并产生独立result。最后对每个target的每个DUT input产生一条`//ime:ime_artifact_identity_check` IDENTITY_CHECK command，核对608-bit identity、sidecar和artifact hash。DIRECT target执行自身label；SUITE_PARENT作为一个top-level target只请求parent label一次，plan不得为member另生flow/identity command或独立result。

SUITE_PARENT result必须附带`suite_case_results[]{member_label,testcase_id,outcome={PASS|FAIL|SKIPPED|NOT_RUN},bep_event_sha256:string|null,test_log_sha256:string|null,absence_reason:string|null}`；数组按`member_label` UTF-8 byte-order严格排序且zero duplicate，label/testcase逐项等于lock中`suite_members[]`。`PASS/FAIL`要求event/log两hash均非空且`absence_reason=null`；`SKIPPED`要求event hash非空、`absence_reason`为非空canonical reason，log存在时重算hash、不存在时为null；`NOT_RUN`要求两hash均为null且`absence_reason`为非空canonical reason。任何不满足该条件矩阵的record均schema失败。parent只有在全部member为PASS、全部非cached且BEP证明每个child由该parent在本次command展开执行时才可PASS，任何extra/missing/其它outcome均失败。comparison/package result可引用多个input check ID，但不得复制或改变这些input的原scope归属。active delivery set全部`2N` artifact、non-delivery、reference/on-off comparison和multi-artifact package均不可漏；最终`command_plan.json`中不得保留通配符或placeholder。§7.6的人类可读命令块未逐项展示由lock派生的binding labels和suite members，不表示权威plan可以省略它们。global test只证明schema/graph闭包，不能替代逐target实际binding/flow/identity result。

`closure_report.json`是唯一canonical report，由 `ime_closure_report_gen`只读bootstrap attestation、command-plan hash、manifests与append-only results生成；`.md`只能从该JSON单向派生，JSON不得引用MD。`ime_closure_report_attest`只生成并校验待签名canonical payload，不得接触caller私钥；trusted launcher在两者冻结后生成repo外detached `closure_attestation.json`，记录JSON/MD/plan/schema/tool hashes。report不得反向嵌入attestation结果或其hash。launcher随后可生成signed `closure_bundle_descriptor.json`，只包含report/MD/attestation path+hash，三者不反向引用descriptor。最终消费者必须从该descriptor同时校验canonical JSON和detached attestation。

第一交付profile只允许`delivery_config_ids={rvv_core_mini_axi,rvv_core_mini_verification_axi}`，每个config都必须同时定义 `ime_off_baseline`与 `ime_on_delivery` target/overlay；要求其它config时先补exact labels。下面的host-side capture必须是**本任务任何workspace写入前**的第一组命令；它只写caller指定的repo外`trusted_evidence_output_root/capture`。每个授权toolchain repo重复同组命令并使用独立repo ID子目录。若capture缺失，不得先创建importer再假装还原prestate。

```bash
set -euo pipefail
umask 077
: "${TRUSTED_EVIDENCE_OUTPUT_ROOT:?caller must set an absolute repo-external path}"
test ! -e "${TRUSTED_EVIDENCE_OUTPUT_ROOT}"
mkdir -p "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu"
git -C /home/wangyy/002_research/coralnpu rev-parse HEAD > "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/base_commit.txt"
git -C /home/wangyy/002_research/coralnpu status --porcelain=v1 -z > "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/status.z"
git -C /home/wangyy/002_research/coralnpu diff --binary --no-ext-diff HEAD > "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/tracked.diff"
git -C /home/wangyy/002_research/coralnpu ls-files --others --exclude-standard -z > "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/untracked.z"
git -C /home/wangyy/002_research/coralnpu submodule status --recursive > "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/submodules.txt"
tar --create --file="${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/untracked.tar" --directory=/home/wangyy/002_research/coralnpu --null --files-from="${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/untracked.z" --no-recursion --format=gnu --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner
sha256sum "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/base_commit.txt" "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/status.z" "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/tracked.diff" "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/untracked.z" "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/untracked.tar" "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/submodules.txt" > "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu/raw_bundle.sha256"
chmod -R a-w "${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture"
```

其中`tar --directory`必须显式指向被捕获repo且不得dereference symlink；importer逐entry验证archive与`untracked.z`一一对应。capture期间必须持有workspace mutation lock或等价exclusive ownership；任一命令失败、文件在list/archive之间变化、出现不支持的special file或raw目录无法只读化都使prestate无效并停止。git-ignored path不在该archive内，默认immutable/out-of-scope；若caller授权修改，必须另行逐path归档。必须执行 `git submodule status --recursive`；任一dirty/untracked submodule要么作为独立repo做同等capture，要么停止，禁止只记录superproject gitlink。每个external repo以成对`--repo/--raw-dir`参数导入，implementation manifest再记录所有repo raw-bundle的aggregate hash。

所有可信receipt/result/attestation统一使用 `signature_envelope.schema.json`，禁止每种文件自创签名语义。envelope required fields为`schema_version,payload_type,payload,payload_sha256,signature_algorithm=Ed25519,signature_encoding=base64-rfc4648,key_id,signature`；`payload_sha256=SHA256(UTF8(JCS(payload)))`。实际签名bytes固定为 `UTF8("CORALNPU-IME-SIGNATURE-v1\n" + schema_version + "\n" + payload_type + "\nEd25519\n" + key_id + "\n") || UTF8(JCS(payload))`，`signature`使用RFC 4648 padded Base64。verifier必须先按被签名的`schema_version/payload_type`选择并验证对应payload schema，再用同样domain bytes验签并检查key usage；不得把一个合法payload重包装成另一类型。signature/envelope file hash不进入payload，消除自引用。caller锁定的trust store列出`key_id,public_key,allowed_payload_types,allowed_key_usages,valid_from,valid_until,revoked_at`。每种payload schema必须唯一指定一个RFC3339 UTC `trusted_time_field`：launcher产生的receipt/result/attestation使用其launcher时间，governance policy使用`issued_at`；缺失、字段歧义或时间不可信均拒绝。该时间必须落在key有效期、早于非null`revoked_at`，且payload type与usage均匹配。key rotation必须新建key ID，不得原地替换公钥。

`chmod`只防误写，不构成对同UID恶意/误操作的信任锚。合格closure还必须得到repo外、agent不可改写的trusted launcher/caller-owned `capture_receipt.json`。其schema固定为 `ime/schemas/capture_receipt.schema.json`并引用上述envelope；payload required fields为 `launcher_path,launcher_sha256,launcher_protocol_version,bazel_executable_ref={absolute_realpath,sha256,tool_version,version_output_sha256},mutation_lock_id,repositories[{absolute_path,base_commit,raw_bundle_sha256}],capture_argv,capture_started_at,capture_finished_at`。launcher在capture前重算该Bazel ref；receipt、caller input、bootstrap argv和后续implementation manifest必须逐值相等。receipt必须由caller输入指定的trust store/key验证；其path/hash作为importer必填参数并进入workspace-prestate。若运行环境不能提供不可改写receipt，仍可继续文档/开发工作，但repository-hygiene attestation保持OPEN，不得报告phase COMPLETE。

为消除runner自举与report自引用循环，命令分成三个互斥集合：

1. **trusted bootstrap allowlist**：prestate capture、只读git status/diff check、`ime_workspace_prestate_import`、`ime_implementation_manifest_gen`、`ime_change_manifest_gen`、`ime_command_plan_gen`和attestation payload validation。launcher先只对capture/import/as-built/change的排序结果计算`preplan_evidence_root_sha256`；plan generator以该root为显式输入。plan-generation result不回填preplan root或plan，而只进入最后的detached bootstrap attestation。launcher在repo工具之外签名的`bootstrap_attestation.json`覆盖preplan results/root、plan-generation exact argv/cwd/env/exit/log、capture receipt、所有生成artifact hash及最终plan hash；私钥不得传给workspace binary；
2. **post-bootstrap plan**：所有schema/requirements/architecture tests、build/lint/sim/formal/software/synthesis与`release_qualification_commands`（clean rebuild、PPA、SBOM/license、rollback drill）。只能由trusted launcher直接spawn并形成有限、可枚举、逐条签名且最终有signed result-set root的command-result集合；workspace `ime_command_runner`不得替代launcher观察exit/log。release manifest/signing/publish属于closure-attestation之后的`release_finalization`，绝不在该plan/result set中；
3. **trusted finalization**：plan中全部required result存在且通过后，launcher执行`ime_closure_report_gen`、MD renderer、attestation-payload validator，再在repo工具之外签名detached closure attestation。finalizer写独立repo外`finalization_results`，不把自己的执行结果塞回closure report，避免report为记录自身而无限重写。若生成后任何输入/result变化，整份report/attestation失效并从第3步重做。

`command_plan.json`不得包含生成自身的bootstrap command，也**不得**嵌入最终attestation hash；它只记录不包含plan-generation result的 `preplan_evidence_root_sha256`。在签bootstrap attestation前，trusted launcher必须独立读取已批准的verification/coverage/CI/profile manifests，按stable ID核对每个applicable command恰好一次、每个config×variant齐全且zero extra/missing；不能只信task-owned plan generator/validator的自报结果。detached bootstrap attestation随后同时签名该completeness summary、preplan root、plan-generation result与最终plan hash。executor以caller trust key验证attestation，再逐值比对plan hash/preplan root；plan、evidence或attestation任一改变都使全部result失效。该单向链 `preplan results -> preplan root -> independently-checked plan -> plan-generation result -> detached attestation`既无runner自举，也无plan/attestation循环哈希。

trusted launcher CLI冻结为`CORALNPU_IME_LAUNCHER_V1`。下列argv数组是协议模板；尖括号必须在caller输入schema通过后逐项实例化，launcher发现placeholder、目标root已存在、workspace binary请求私钥或plan argv与schema不一致必须拒绝：

```text
<launcher_abs> capture --protocol CORALNPU_IME_LAUNCHER_V1
  --workspace /home/wangyy/002_research/coralnpu --phase <P0..P4>
  --evidence-root <trusted_evidence_output_root>
  --receipt <capture_receipt_output_path> --trust-store <trust_store_abs>

<launcher_abs> bootstrap --protocol CORALNPU_IME_LAUNCHER_V1
  --workspace /home/wangyy/002_research/coralnpu --phase <P0..P4>
  --caller-input ime/closure/<phase>/caller_inputs.json
  --raw-capture <trusted_evidence_output_root>/capture
  --bootstrap-results <trusted_evidence_output_root>/bootstrap_results
  --bootstrap-attestation <trusted_evidence_output_root>/bootstrap_attestation.json
  --trust-store <trust_store_abs>

<launcher_abs> execute-plan --protocol CORALNPU_IME_LAUNCHER_V1
  --plan ime/closure/<phase>/command_plan.json
  --bootstrap-attestation <trusted_evidence_output_root>/bootstrap_attestation.json
  --results <trusted_evidence_output_root>/command_results
  --result-set-attestation <trusted_evidence_output_root>/result_set_attestation.json
  --trust-store <trust_store_abs>

<launcher_abs> finalize --protocol CORALNPU_IME_LAUNCHER_V1
  --plan ime/closure/<phase>/command_plan.json
  --results <trusted_evidence_output_root>/command_results
  --result-set-attestation <trusted_evidence_output_root>/result_set_attestation.json
  --closure-json ime/closure/<phase>/closure_report.json
  --closure-md ime/closure/<phase>/closure_report.md
  --closure-attestation <trusted_evidence_output_root>/closure_attestation.json
  --closure-bundle-descriptor <trusted_evidence_output_root>/closure_bundle_descriptor.json
  --finalization-results <trusted_evidence_output_root>/finalization_results
  --trust-store <trust_store_abs>

<launcher_abs> release --protocol CORALNPU_IME_LAUNCHER_V1
  --closure-bundle-descriptor <trusted_evidence_output_root>/closure_bundle_descriptor.json
  --release-manifest-output ime/closure/<phase>/release_manifest.json
  --release-attestation-output <trusted_evidence_output_root>/release_attestation.json
  --release-bundle-root <trusted_evidence_output_root>/release_bundle
  --release-bundle-descriptor <trusted_evidence_output_root>/release_bundle_descriptor.json
  --release-bundle-attestation <trusted_evidence_output_root>/release_bundle_attestation.json
  --release-authority <release_authority_abs> --trust-store <trust_store_abs>
```

`release`子命令只允许`release_intent=RELEASE`；其它intent最高产生RC。签名链必须严格单向，禁止任何反向hash：(1) signed closure descriptor → (2) `release_manifest.json` → (3) release authority生成`release_attestation.json` → (4) 复制bundle并生成descriptor payload → (5) release authority生成detached `release_bundle_attestation.json`。两种attestation都必须使用上述统一envelope：

* `release_attestation.json`固定`payload_type=CORALNPU_IME_RELEASE_ATTESTATION_V1`，closed payload为`{protocol_version,phase_id,release_manifest_sha256,closure_bundle_descriptor_sha256,key_usage=release-manifest,signed_at}`；
* `release_bundle_attestation.json`固定`payload_type=CORALNPU_IME_RELEASE_BUNDLE_ATTESTATION_V1`，closed payload为`{protocol_version,phase_id,release_bundle_descriptor_sha256,key_usage=release-bundle,signed_at}`。

两类签名者身份只取各自envelope的`key_id`，payload不得再携带可与之分叉的authority/signer ID。两类`signed_at`均为trusted launcher写入的RFC 3339 UTC时间，必须满足trust-store有效期检查。`release_authority_artifact`本身必须使用统一envelope、`payload_type=CORALNPU_IME_RELEASE_AUTHORITY_V1`及`key_usage=release-authority-policy`，由caller governance key签名并在release开始前已存在；其payload `issued_at`是验证governance key trust-store有效期/吊销状态的trusted time。authority envelope的`key_id`不得出现在其payload的`authorized_key_ids[]`，workspace/release key不得自签或改写授权策略。trust store中release验签key必须同时允许对应`payload_type`和`key_usage`，且该`key_id`必须被该authority artifact的`authorized_key_ids[]`列出并允许matching phase profile/release scope；两个release `signed_at`都必须满足policy半开时间窗`valid_from <= signed_at < valid_until`。尤其bundle key必须允许`release-bundle`，不能以capture/result/release-manifest权限代替。后一attestation envelope不得出现在自己或任何前置产物的hash输入中。

该子命令以0700新建此前不存在的bundle root，按relative path byte-order复制active set的全部`2N`个variant artifacts、software/SBOM、signed closure descriptor、release manifest/attestation和全部被引用evidence，其中`N=len(active_variant_set.config_pairs)`。canonical `release_bundle_descriptor.json`是closed JCS payload，required fields仅为`schema_version,protocol_version,phase_id,release_manifest_sha256,release_attestation_sha256,closure_bundle_descriptor_sha256,entries[]{relative_path,role,size_bytes,sha256}`；`entries[]`必须按`relative_path` UTF-8 byte-order严格排序。`release_bundle_descriptor_sha256=SHA256(UTF8(JCS(descriptor_payload)))`，且必须逐bit等于bundle-attestation payload中的同名字段。禁止absolute path、重复relative path、未列文件或未引用外部文件；不使用未定义的Merkle root，descriptor SHA-256及其detached签名已经覆盖完整排序entry集合。`release_bundle_attestation.json`使用前述统一envelope且不放入被descriptor列举的bundle root。任何消费者必须运行exact argv `<launcher_abs> verify --protocol CORALNPU_IME_LAUNCHER_V1 --bundle-descriptor <trusted_evidence_output_root>/release_bundle_descriptor.json --bundle-attestation <trusted_evidence_output_root>/release_bundle_attestation.json --bundle-root <trusted_evidence_output_root>/release_bundle --trust-store <trust_store_abs>`，先验证envelope schema、payload type/usage、payload hash和descriptor签名，再重算全部entry/manifest/release-attestation/closure链；不能只信文件存在。

capture完成后才能序列化caller inputs并修改source。修改完成后，先由trusted launcher执行/记录下列bootstrap区，再封存plan；之后任何task-owned input改变都使bootstrap/plan/results全部失效，必须重新生成。代码块中到 `ime_command_plan_gen`为bootstrap argv；其后只是P0的人类可读required flow-root argv，不是完整machine minimum。权威`command_plan.json`还必须按前述规则为每个target插入binding test、artifact identity check、suite-member closure和逐target result映射，不能因下面未展开这些派生命令而省略：

```bash
git status --short
git diff --check

bazel --batch run //ime:ime_workspace_prestate_import -- \
  --phase=P0 \
  --repo=/home/wangyy/002_research/coralnpu \
  --raw-dir="${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu" \
  --capture-receipt=<caller-owned-absolute-receipt-path> \
  --output=ime/closure/P0/workspace_prestate.json

bazel --batch run //ime:ime_implementation_manifest_gen -- \
  --phase=P0 \
  --caller-input=ime/closure/P0/caller_inputs.json \
  --prestate=ime/closure/P0/workspace_prestate.json \
  --output=ime/closure/P0/implementation_manifest.json

bazel --batch run //ime:ime_change_manifest_gen -- \
  --phase=P0 \
  --prestate=ime/closure/P0/workspace_prestate.json \
  --output=ime/closure/P0/change_manifest.json

bazel --batch run //ime:ime_command_plan_gen -- \
  --phase=P0 \
  --implementation-manifest=ime/closure/P0/implementation_manifest.json \
  --change-manifest=ime/closure/P0/change_manifest.json \
  --preplan-evidence-root=<trusted-launcher-computed-64hex> \
  --output=ime/closure/P0/command_plan.json

bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 \
  //ime:ime_schema_test \
  //ime:ime_requirements_test \
  //ime:ime_architecture_test \
  //ime:ime_verification_plan_test \
  //ime:ime_spec_manifest_test \
  //ime:ime_repository_hygiene_test \
  //ime:ime_option_schema_test \
  //ime:ime_invalid_configuration_test \
  //ime:ime_target_bindings_lock_test \
  //ime:ime_release_manifest_schema_fixture_test

bazel --batch query \
  'kind(".* rule", rdeps(//..., set(//hdl/chisel/src/coralnpu:all //hdl/chisel/src/soc:all)))' \
  --output=label_kind
bazel --batch query 'attr(tags, "ime_variant_bound", //...)' --output=label
# command_plan在此另插入一条QUERY_COMMAND，逐argv执行lock中已物化且无placeholder的
# target_universe.test_support_query_argv（含--noimplicit_deps）；本块不手抄动态member labels。

# 每个argv/command ID只属于一个config x variant；禁止合并下列四项
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library

bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_lint
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_lint
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_ime_axi_cc_library_lint
bazel --batch build \
  //hdl/chisel/src/coralnpu:rvv_core_mini_ime_verification_axi_cc_library_lint

# 八个cocotb model本身都是DIRECT flow target；必须逐target独立build/result
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_axi_off_verilator_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_axi_off_vcs_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_verification_axi_off_verilator_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_verification_axi_off_vcs_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_axi_on_verilator_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_axi_on_vcs_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_verification_axi_on_verilator_model
bazel --batch build \
  //tests/cocotb/ime:rvv_core_mini_verification_axi_on_vcs_model

# standalone VCS必须逐tuple独立build；不能合并成一个跨variant result
bazel --batch build \
  //tests/vcs_sim:rvv_core_mini_axi_sim
bazel --batch build \
  //tests/vcs_sim:rvv_core_mini_verification_axi_sim
bazel --batch build \
  //tests/vcs_sim:rvv_core_mini_ime_axi_sim
bazel --batch build \
  //tests/vcs_sim:rvv_core_mini_ime_verification_axi_sim

bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_axi_off_test \
  //hdl/chisel/src/coralnpu:ime_structure_rvv_core_mini_axi_off_test \
  //tests/cocotb/ime:ime_p0_rvv_core_mini_axi_off \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_verification_axi_off_test \
  //hdl/chisel/src/coralnpu:ime_structure_rvv_core_mini_verification_axi_off_test \
  //tests/cocotb/ime:ime_p0_rvv_core_mini_verification_axi_off \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_verification_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_axi_on_test \
  //tests/cocotb/ime:ime_p0_rvv_core_mini_axi_on \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_axi_on
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_verification_axi_on_test \
  //tests/cocotb/ime:ime_p0_rvv_core_mini_verification_axi_on \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_verification_axi_on

# cocotb VCS必须与上面的Verilator命令分开记result；每条仍只绑定一个tuple
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_axi_off \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_verification_axi_off \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_verification_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_axi_on \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_axi_on
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P0 --test_env=IME_SUITE_PHASE_TOKEN=P0 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //tests/cocotb/ime:vcs_ime_p0_rvv_core_mini_verification_axi_on \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_verification_axi_on

# 下列八项分别形成config-specific REFERENCE_COMPARISON或VARIANT_COMPARISON result，formal与differential均不可省略或并入单variant命令
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/formal/ime:ime_off_reference_equivalence_rvv_core_mini_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/formal/ime:ime_off_reference_equivalence_rvv_core_mini_verification_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/formal/ime:ime_on_off_noninterference_rvv_core_mini_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/formal/ime:ime_on_off_noninterference_rvv_core_mini_verification_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/cocotb/ime:ime_off_reference_diff_rvv_core_mini_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/cocotb/ime:ime_off_reference_diff_rvv_core_mini_verification_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/cocotb/ime:ime_on_off_diff_rvv_core_mini_axi
bazel --batch test --nocache_test_results --test_output=errors \
  //tests/cocotb/ime:ime_on_off_diff_rvv_core_mini_verification_axi
```

P1不得复用P0 manifest/source hash。P1 task开始且尚未写workspace时，先把上面的host capture路径/phase改为P1执行；修改完成后import该P1 raw evidence、生成并冻结P1输入，再以`IME_AS_BUILT_PHASE_ID=P1`重跑GLOBAL/primary-build/lint/八个DIRECT model/standalone/reference/equivalence common命令。累计plan必须先逐tuple重跑所有phase-qualified P0 suite labels（`IME_AS_BUILT_PHASE_ID=P1,IME_SUITE_PHASE_TOKEN=P0`，不得混入phase-neutral label），再运行下面新增P1 labels和phase-neutral回归（两者均`IME_SUITE_PHASE_TOKEN=P1`）；下面人类代码块只展示新增P1 suite/phase-neutral组合，不得被plan generator解释为省略P0回归：

```bash
bazel --batch run //ime:ime_workspace_prestate_import -- \
  --phase=P1 \
  --repo=/home/wangyy/002_research/coralnpu \
  --raw-dir="${TRUSTED_EVIDENCE_OUTPUT_ROOT}/capture/coralnpu" \
  --capture-receipt=<caller-owned-absolute-receipt-path> \
  --output=ime/closure/P1/workspace_prestate.json

bazel --batch run //ime:ime_implementation_manifest_gen -- \
  --phase=P1 \
  --caller-input=ime/closure/P1/caller_inputs.json \
  --prestate=ime/closure/P1/workspace_prestate.json \
  --output=ime/closure/P1/implementation_manifest.json

bazel --batch run //ime:ime_change_manifest_gen -- \
  --phase=P1 \
  --prestate=ime/closure/P1/workspace_prestate.json \
  --output=ime/closure/P1/change_manifest.json

bazel --batch run //ime:ime_command_plan_gen -- \
  --phase=P1 \
  --implementation-manifest=ime/closure/P1/implementation_manifest.json \
  --change-manifest=ime/closure/P1/change_manifest.json \
  --preplan-evidence-root=<trusted-launcher-computed-64hex> \
  --output=ime/closure/P1/command_plan.json

bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_axi_off_test \
  //hdl/chisel/src/coralnpu:ime_structure_rvv_core_mini_axi_off_test \
  //tests/cocotb/ime:ime_p1_rvv_core_mini_axi_off \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_verification_axi_off_test \
  //hdl/chisel/src/coralnpu:ime_structure_rvv_core_mini_verification_axi_off_test \
  //tests/cocotb/ime:ime_p1_rvv_core_mini_verification_axi_off \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_verification_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_axi_on_test \
  //tests/cocotb/ime:ime_p1_rvv_core_mini_axi_on \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_axi_on
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //hdl/chisel/src/coralnpu:ime_interface_width_rvv_core_mini_verification_axi_on_test \
  //tests/cocotb/ime:ime_p1_rvv_core_mini_verification_axi_on \
  //tests/cocotb/ime:base_rvv_rvv_core_mini_verification_axi_on

bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_axi_off \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_off_baseline \
  //tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_verification_axi_off \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_verification_axi_off
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_axi_on \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_axi_on
bazel --batch test --nocache_test_results --test_output=errors --test_env=IME_AS_BUILT_PHASE_ID=P1 --test_env=IME_SUITE_PHASE_TOKEN=P1 --test_env=IME_CONFIG_ID=rvv_core_mini_verification_axi --test_env=IME_VARIANT_ID=ime_on_delivery \
  //tests/cocotb/ime:vcs_ime_p1_rvv_core_mini_verification_axi_on \
  //tests/cocotb/ime:vcs_base_rvv_rvv_core_mini_verification_axi_on
```

P2/P3/P4的人类可读流程同样累计P0到当前phase，但machine execution不得靠“同理”推导：`command_plan.json`必须从该profile已批准的active set与exact target bindings逐phase完整列出commands/labels/config/variant。每个phase先生成自己的workspace-prestate、pre-test as-built manifest与change manifest，不能用前一phase source hash代表当前tree。每个delivery config的off/on variant都必须有build/test/lint、cocotb Verilator、cocotb VCS与standalone VCS；verification config包含full RB/TB path，off/on verification lint都不可由mini lint替代。每个phase还必须重跑该active set全部`2N` variant artifact的base-RVV、width/identity及适用structure/equivalence checks，并按binding lock逐条重跑applicable non-delivery `OFF_ONLY_TARGET`命令。首个profile才使用§7.6的16个固定suite label和四个standalone mapping；其它profile若尚无exact IDs/labels则DoR失败，不得退回首个profile分母。`ime_repository_hygiene_test`读取冻结的change manifest，检查其中全部tracked/untracked输入、遗漏source path、whitespace/encoding与当前hash；绝不读取尚未完成的closure report。工具/license/simulator不可用时gate保持OPEN。

所有variant-specific test由Bazel依赖图决定DUT，并在第一条stimulus前读取`ImeBuildIdentity`；`IME_CONFIG_ID/IME_VARIANT_ID`缺失、unknown或与DUT不等时必须直接失败，但这两个环境变量绝不能改变编译或选择DUT。off target执行该phase全部known raw encoding、vtype reserved/default-off与零capability-exposure矩阵，不得因“功能disabled”跳过；on target再执行完整legal arithmetic/state/ordering矩阵。四条command ID/result/overlay/DUT hash相互独立，任何一条通过都不能替代另一条。

有限 legality/configuration 空间必须 exhaustive：全部 raw mask/match、Table cell、feature-on/off、SEW/LMUL/lambda/vm/vstart/group/tail组合均覆盖。数值/时序空间在定向边界与独立模型之外，P1 每个 `(SEW,LMUL)` 至少运行记录在 manifest 中的 100 个 deterministic random seeds，并执行所有可用的 assertion/formal property；随机通过不能替代 §7.3 的 ordering、exactly-once与no-stale proof。seed、test binary、log与coverage均写入 closure report并带 hash。

### 7.7 自动实现 agent 的退出门槛

只有同时满足以下条件，agent 才能报告某 phase `COMPLETE`：

1. 调用输入没有placeholder/空值/矛盾；按§4.4闭包计算出的全部 `applicable_implementation_gate_ids`均为PASS。`OUT_OF_SCOPE`不属于applicable集合且validator已证明claim/dependency不可达；`claim_only_blocking`可OPEN但必须自动缩小claim scope；
2. frozen command plan中每条applicable command都有append-only result且exit code为0；没有applicable skip/xfail/timeout/unknown/未运行target。pre-test as-built implementation manifest与change manifest在首个delivery build前冻结；`ime_repository_hygiene_test`覆盖change manifest内全部tracked/untracked task input且零遗漏/whitespace/encoding/hash error；既有无关baseline skip必须单列且不能关闭对应gate；
3. 每个delivery config的 `ime_off_baseline`与 `ime_on_delivery` build/test/lint都通过，mini/full-verification都实际执行本阶段功能测试；off variant所有IME encoding precise-illegal，claim只在on variantenabled；
4. interface-width checker 为零 mismatch，且没有依赖现有 `-Wno-WIDTH*` 掩盖的 implicit truncation/extension；
5. traceability matrix 将每条 applicable normative requirement映射到 manifest record、RTL、独立 model、test/assertion与结果，未映射、重复冲突和未执行计数均为 0；
6. 所有 supported tuple coverage为 100%，所有 disabled/reserved encoding都验证为 precise illegal；所有外部 blocked cell在硬件中保持 disabled；
7. 每个 assertion确实进入 elaborated DUT。对 implication/handshake property，合法 antecedent state必须有 cover/定向测试证明可达，不能 vacuous pass；对“禁止状态永不发生”的 immediate invariant，不要求 cover失败状态，而必须用 mutation/negative stimulus证明checker能在受控错误实现或非法输入下触发；
8. 没有stale/killed-macro side effect、fault/completion重复或丢失、early serial-lock release、错误的`minstret`增量/trace kind。P3 architectural-fault flush只允许manifest列出的fault-boundary`vstart/VS/SD`和fault前older load/store effects，严禁faulting/younger effect；其它killed path零C/CSR/fflags/memory commit；
9. 独立 oracle不复用 DUT helper；若 manifest生成 DUT或test其中一侧，另一侧必须独立且有固定 hash/review evidence；
10. 未修改锁定 PDF，未删除、放宽、xfail或绕过既有 test/assertion/lint/legality rule；确需改变 baseline时必须单独列出证据并保持 gate OPEN等待签核；
11. 从冻结的change-manifest hash与append-only command-result ledger生成canonical `ime/closure/<phase>/closure_report.json`，再单向派生`.md`，记录base commit、post-change source-tree hash、全部manifest/artifact hash、命令/exit/log/seed/coverage/proof及OPEN blocker；最后生成独立`closure_attestation.json`校验JSON/MD。report不反向进入change manifest，attestation也不写回report；
12. capture receipt、bootstrap attestation、逐command result、result-set attestation、finalization result与closure attestation均通过schema/hash/Ed25519/trust-store usage/有效期/吊销验证；每个权威result由trusted launcher直接观察，plan/result-set零missing/duplicate/extra。任一trust-chain失败均使closure `BLOCKED`，不得仅记普通test OPEN；
13. `completion_scope_kind=PHASE_PROFILE`且固定required roots/gates全部闭合，才能使phase-profile两组状态为`COMPLETE`；`CAPABILITY_DELTA`即使自身全部通过也只能使requested-scope两字段COMPLETE，phase-profile两字段强制PARTIAL。只有第1节对应claim的全部条件关闭后才能使用“正确/合规”字样；implementation blocker存在则报告 `BLOCKED`；
14. closure内只有`qualification_status`：`release_intent=DEVELOPMENT`时为NOT_READY，`RELEASE_CANDIDATE|RELEASE`在qualification plan全部通过时最多为RC。RELEASED不得写回closure；只有后置`release_finalization`成功后，release-authority签名的release manifest/attestation才可携带`delivery_status=RELEASED`，LLM/普通project approver不得提升该状态。

## 8. 软件与规范版本门槛

审计到两条不能混淆的本地 toolchain：

```text
# legacy PATH toolchain
/home/wangyy/software/toolchains/pulp_env/gcc7/bin/riscv32-unknown-elf-as --version
# GNU Binutils 2.28.0.20170505

printf '%s\n' '.text' 'vmmacc.vv v0, v0, v0' |
  /home/wangyy/software/toolchains/pulp_env/gcc7/bin/riscv32-unknown-elf-as \
    -march=rv32gcv -o /tmp/legacy-vmmacc.o -
# Fatal error: -march=rv32gcv: unsupported ISA subset `V'

# Coral Bazel toolchain
AS=/home/wangyy/.cache/bazel/_bazel_wangyy/f5fc6ae1de374dadc178c2e803fe3ac1/external/toolchain_coralnpu_v2/bin/riscv32-unknown-elf-as
OD=/home/wangyy/.cache/bazel/_bazel_wangyy/f5fc6ae1de374dadc178c2e803fe3ac1/external/toolchain_coralnpu_v2/bin/riscv32-unknown-elf-objdump
$AS --version
# GNU Binutils 2.45

$AS -march=rv32gcv -mabi=ilp32 -o /tmp/rvv_cycle_counter_v.o \
  tests/cocotb/cycle_counter/rvv/rvv_cycle_counter.S
# objdump includes: e2112257 vwmulu.vv v4,v1,v2
#                   ea112257 vwmulsu.vv v4,v1,v2
#                   ee112257 vwmul.vv v4,v1,v2

printf '%s\n' '.text' 'vwmacc.vv v4, v1, v2' | \
  $AS -march=rv32gcv -mabi=ilp32 -o /tmp/base-mac-order.o -
$OD -d /tmp/base-mac-order.o
# f620a257 vwmacc.vv v4,v1,v2

printf '%s\n' 'vmmacc.vv v4, v1, v2' | $AS -march=rv32gcv -mabi=ilp32 -o /tmp/vmmacc-probe.o -
# Error: unrecognized opcode `vmmacc.vv v4,v1,v2'
```

普通 arithmetic 的 `vwmulu.vv v4,v1,v2 -> 0xe2112257` 使用其自身的 textual grammar，字段为 `vs2=1`、`vs1=2`。它只能证明 OPIVV/OPMVV 的 `funct3` 区分，**不能**定义 IME A/B operand order。相反，本地 Binutils 2.45 可汇编 base MAC：

```text
vwmacc.vv v4,v1,v2 -> 0xf620a257
# fields: vs1=1, vs2=2; grammar is vd,vs1(A),vs2(B)
```

锁定 PDF 对 IME 也规定 `vd,vs1(A),vs2(B)`，且 raw positions 为 `[19:15]=vs1`、`[24:20]=vs2`。因此对 `vd=v4,A=vs1=v1,B=vs2=v2,vm=1,funct3=000`，唯一可标为该语义的 field-level golden 是：

```text
word = (funct6 << 26) | (1 << 25) | (B << 20) | (A << 15) | (0b000 << 12) | (vd << 7) | 0x57
vmmacc.vv   0xe2208257
vwmmacc.vv  0xe6208257
vqmmacc.vv  0xea208257
v8wmmacc.vv 0xee208257
```

旧的 `0xe2110257/0xe6110257/0xea110257/0xee110257` fields 是 `vs2=v1,vs1=v2`，即 PDF semantics 的 `A=v2,B=v1`；它们可作为有意交换 operands 的 negative/control test，但**不得**再标作 `v?mmacc.vv v4,v1,v2` 的 golden。当前 Binutils 2.45 对新的 IME word 仍只会反汇编为 `.word`，不会提供 mnemonic/toolchain 支持；raw word 只可用于硬件 decode 验证。

PDF §36.10 定义的软件交付面不止两个 lambda API；完整软件 claim 至少要覆盖：

```c
size_t __riscv_ime_vlen(void);
size_t __riscv_ime_lambda(void);
size_t __riscv_vsetlambda(size_t requested_lambda);
```

`__riscv_ime_vlen()`返回以**bit**为单位的architectural VLEN，本profile必须返回128；编译期未知时lowering固定为`csrr vlenb`后左移3，不能直接返回16。`__riscv_ime_lambda()`是API层面side-effect-free的隐式`vtype.lambda`读，不改变`vtype`/`vl`/VRF；它不是compiler `readnone/const`，不得跨可能修改lambda的`vset*`/`vsetlambda`做CSE、hoist或speculate。`__riscv_vsetlambda()`必须保留其余`vtype` fields与`vl`，并返回WARL处理后**实际selected lambda**，不是原requested值；outside IME-legal domain返回0。锁定PDF对后一个API可移植地列出的请求域是`0`或正2的幂`{1,2,4,8,16,32,64}`；任意非零非2的幂`size_t`行为不能由现有文字无歧义推出。这是外部API gate：在ISA owner澄清前，实现必须拒绝/诊断此输入，或将行为明确标作implementation-defined，不能把硬件WARL canonicalization冒充portable C API guarantee。除此之外，PDF还定义type-specific/overloaded MAC与tile-LS intrinsics、IME-only m16 accumulator types，以及`__riscv_ime_vpair`/`__riscv_ime_vunpairlo`/`__riscv_ime_vunpairhi` pseudo-intrinsics。

`__riscv_ime_lambda()` 必须返回实际解码的 `vtype.lambda`；不能伪造非零值。锁定 PDF 对返回 0 的原因自相矛盾：§36.4.2 明确 reset、`vill=1` 和 IME-legal domain 外均可能为 0，§36.10.1.4 却称 0 “only”表示尚未配置。因此硬件/ABI test只可验证返回真实字段值；portable software在 ISA owner澄清前不得把 0 解释为唯一状态原因。

后面三类 m16 pseudo-intrinsics 是 compiler builtin，不是 ISA opcode：unpair 是 alias view、无数据移动且与 source 共用寄存器；pair 是 value-copying，必要时可生成 moves；三者均不读写 memory，也不改变 `vl`、`vtype`、`vstart` 或 `fflags`。m16 value 经过 externally visible function boundary 的 psABI 尚未在 PDF 中冻结，故在获得 psABI 规范前，必须禁止把 m16 type 作为 portable public ABI 参数/返回值，或明确采用 implementation-defined ABI。

compiler lowering 还必须把 instruction-mapping MAC/tile-LS intrinsic 建模为相关 VRF 的 ordering barrier：不得跨有 alias/依赖的 vector value 重排、不得把 `vsetlambda`/`vset*` 与其 snapshot 乱序。query、pair、unpair 必须按 PDF 的 DEF/USE/alias 语义建模；pair 的 value-copy 不可错误降成 alias，unpair 的 alias view 不可错误插入 copy。必须交付 IR-level 与 asm-level reordering regression，而不只是 C source 的函数返回值测试。

具体而言，`__riscv_ime_lambda()`是side-effect-free但读取隐式architectural state，`__riscv_vsetlambda(0)`仍可能定义/初始化selected lambda，不能被compiler当作query；`vsetvli/vsetivli`改变SEW时可能定义lambda、只改变LMUL时不得无故改变lambda；`vsetvl`是完整vtype definition，lambda bits为零时依赖旧lambda。tile `_as_eS` API的`ld`与`vl`都以S-bit **storage element**计数，base pointer是相应`uintS_t*`，无数值转换。上述DEF/USE、alias和storage-unit规则必须分别有IR/asm regression；`vsetlambda`还必须测试unsupported合法请求被canonicalize后返回selected值，以及outside-domain返回0。

完整C intrinsic ABI还必须逐prototype锁定以下规则，不能只验证返回数值：

* 每个instruction-mapping MAC/tile-LS intrinsic最后一个参数都是`size_t vl`；tile load/store的type suffix编码tile operand LMUL，MAC accumulator suffix编码C的`EMUL_C`，A/B argument type与可选`_lmN`编码source LMUL，`_lm1`省略；
* tile immediate override写在name的`_L{1|2|4|8|16|32|64}`中，是compile-time immediate且没有runtime lambda argument；masked form的mask是参数列表第一个参数，canonical qualifier顺序为`_as_eS_LN_m`（只对允许`_as_eS`的order-preserving form）；
* 普通tile mask type按data element width/LMUL；`_as_eS` mask type必须按storage width S与tile-LS LMUL计算，不能按packed narrow logical type。`_as_eS`只存在于`vmtl/vmts`；`vmttl/vmtts`只提供logical width=natural storage width且至少8-bit的transposing form；
* 所有MX MAC在`size_t vl`前额外接收`vuint16m1_t v0`。该SSA value必须在instruction point物化到**architectural v0**，因为encoding没有scale-register field；lowering必须建立fixed-register use、必要copy到v0、正确v0 liveness/clobber，并禁止`vd/vs1/vs2` overlap v0，assembly regression必须看到真实v0。FP-input MX mnemonic使用`*_scaled_vv*`，integer-input MX不带`_scaled`；两者都必须带`_bs16/_bs32`，canonical suffix为`{types}[_lmN]_bsN`（integer signedness受Table 89限制，不能生成unsigned MXINT variant）；
* 每个prototype必须有唯一的`{bs,altfmt_A,altfmt_B,low output-altfmt}`映射及配置序列。high fields `[27:25]`不能由`vsetvli/vsetivli` immediate写入，compiler必须用full-vtype `vsetvl`或经审计的等价pseudo在instruction前建立这些field、正确处理lambda preserve/request与`vl`参数；相邻不同format/signedness/bs intrinsic必须回归reconfiguration，禁止沿用stale high fields；
* 每个long/overloaded form的C/A/B types、suffix token顺序、`vl`、mask、v0和immediate lowering必须有header type-check、IR和assembly regression；不能只提供一个接受任意vector type的builtin。

software delivery scope必须用下列`SW-*` record精确表达。validator计算`requires_sw_ids`传递闭包，并要求每个claim引用的hardware INST/CELL/RULE/ISAEXT在**每个delivery config的 `ime_on_delivery` overlay**中达到该SW claim声明的full/partial runtime support；若依赖partial CELL，compiler/assembler资产必须证明它不会生成blocked runtime partition，否则该SW claim不得enabled。`ime_off_baseline`必须相反地验证raw encoding precise-illegal，不能被software claim要求启用。software scope不能超过hardware capability。表中`union(hw.external_gate_ids)`是machine rule：取该SW record实际引用的所有hardware record之`external_gate_ids`并集，不是自由文本gate。

| SW claim ID | requires_sw_ids | required hardware relation | required_external_gate_ids_or_derivation | required_implementation_gate_ids | 必备资产/验证 |
| --- | --- | --- | --- | --- | --- |
| `SW-RAW-ENCODER` | `[]` | 每个可发射word的INST/CELL | `union(hw.external_gate_ids)` | `[]` | independent raw encoder、golden/negative decode |
| `SW-ASM-MNEMONICS` | `[SW-RAW-ENCODER]` | 每个mnemonic的INST及claimed CELL | `union(hw.external_gate_ids)` | `[IMP-SW-TOOLCHAIN-ABI]` | writable toolchain source、assembler+objdump round-trip |
| `SW-C-GEOMETRY-API` | `[]` | claimed lambda/vtype RULE及base profile | `union(claimed RULE.external_gate_ids)` | `[IMP-SW-TOOLCHAIN-ABI]` | compiler/header、VLEN-bits/lambda/vsetlambda DEF/USE与runtime tests |
| `SW-C-MAC-INTRINSICS` | `[SW-ASM-MNEMONICS,SW-C-GEOMETRY-API]` | 每个lowered computational CELL/ISAEXT | `union(hw.external_gate_ids)` | `[IMP-SW-TOOLCHAIN-ABI]` | compiler/header/IR/asm/runtime及vtype reconfiguration |
| `SW-C-TILELS-INTRINSICS` | `[SW-ASM-MNEMONICS,SW-C-GEOMETRY-API]` | claimed tile INST/ISAEXT | `union(hw.external_gate_ids)` | `[IMP-SW-TOOLCHAIN-ABI]` | compiler/header/IR/asm/mask/restart tests |
| `SW-M16-PSEUDO` | `[SW-C-GEOMETRY-API]` | enabled m16 CELL及所用tile INST | `union(hw.external_gate_ids)` | `[IMP-SW-TOOLCHAIN-ABI]` | compiler m16 type、pair/unpair alias/copy与register tests |
| `SW-M16-PUBLIC-ABI` | `[SW-M16-PSEUDO]` | 同上 | `union(hw.external_gate_ids) + [EXT-M16-PSABI]` | `[IMP-SW-TOOLCHAIN-ABI]` | approved psABI与跨函数/compiler/link tests |

hardware-only要求SW集合为空；hardware-and-software要求非空。`SW-ASM-MNEMONICS`或任一`SW-C-*`/`SW-M16-*`都需要caller授权的toolchain source workspace、base commit、可改文件范围及exact build/test labels；只有预装binary版本不足以实施。完整software ISA/ABI claim要求全部适用ID及真实assembler/compiler/objdump；`SW-RAW-ENCODER`永远不能替代其它ID。

P1 RTL 可以先用固定 raw-word encoder 驱动验证，但在 assembler/compiler mnemonic、上述 query/config APIs、所支持 MAC/tile-LS intrinsic lowering、C header/type definitions、m16 pseudo-intrinsic semantics、round-trip test 与 version manifest 完成前，不得声称完整软件 ISA/ABI 支持。

因此，在作出任何软件支持声明前，必须提交与**所宣称 software scope**相对应的下列可复现资产：P1 type-specific claim 至少包含其 raw encoder、`vmmacc` lowering/round-trip（若宣称 mnemonic）、query/config API（若宣称 C API）和 P1 regression；tile-LS、m16 与其它 phase 的条目只在宣称相应 capability 时变为必需。完整软件 ISA/ABI claim 则必须包含全部条目：

1. `SW-RAW-ENCODER`要求固定`.insn`/raw-word encoder及其independent decode test；任何`SW-ASM-*`或`SW-C-*`claim必须另有固定path/version/commit的assembler、compiler、objdump，完整software claim两类资产都要有，raw encoder不得替代toolchain；
2. field-semantic 四条 IME word golden：`vmmacc=e2208257`、`vwmmacc=e6208257`、`vqmmacc=ea208257`、`v8wmmacc=ee208257`，以及 A/B intentionally swapped control words；
3. standard OPMVV word 与 IME OPIVV word 的 decode/disassembler negative test，和 future IME assembler 的 `vd,vs1(A),vs2(B) <-> binary` round-trip test；
4. P2 signedness-discriminating A/B-order test（W=2/SEW16 control: correct `0xff80` vs swapped `0x8080`；不能用 P1 W=1 modulo result 伪装成区分测试）；
5. `__riscv_ime_vlen` / `__riscv_ime_lambda` / `__riscv_vsetlambda`、所支持 MAC/tile-LS intrinsic 和 m16 pair/unpair pseudo-intrinsic 的 software conformance test；`vsetlambda` 非 2 的幂输入必须有已声明的 diagnostic/implementation-defined test，或明确将该 API 排除在发布 scope 外；
6. compiler IR/asm reordering regression、PDF hash、toolchain commit、RTL commit 与 test seed manifest。

截至 2026-07-12，官方 `riscv-opcodes` 的 [unratified IME encoding PR #406](https://github.com/riscv/riscv-opcodes/pull/406) 仍为开放PR；这解释了为什么不能把当前 upstream 工具链/ABI 当作已解决事实。

## 9. 给自动实现 LLM 的强制 Prompt

```text
你在 /home/wangyy/002_research/coralnpu 实现锁定 PDF hash
c0d25144279b1790cb285d3598e8207005ba9dfc9c24cb5aa00c7d1838829307
定义的 Zvvm IME。

调用方必须实例化caller-owned输入；agent不能替调用方猜scope/authority。任何workspace写入前，先严格执行§7.6
repo外prestate capture并取得trusted capture receipt；完成后才可把caller输入原样序列化为schema-validated
`ime/closure/<phase_id>/caller_inputs.json`。source修改完成后生成pre-test as-built `implementation_manifest.json`
和独立`change_manifest.json`，不得称前者为preflight。任一caller-owned字段仍为占位符、空值或互相矛盾时，
不得开始RTL修改并报告缺失输入。

contract-locked（caller不得覆盖，agent每次重算hash）:
  ime_artifact: {path: ime/20260629-Zvvm-IME-riscv-unprivileged-605-730-Zvvm-IME.pdf,
                 sha256: c0d25144279b1790cb285d3598e8207005ba9dfc9c24cb5aa00c7d1838829307,
                 status: Draft-0.1-pinned-experimental}
  riscv_dependency_artifact: {path: ime/riscv-spec-inter20260710.pdf,
                 sha256: 04499fadf0a8c3d55a73543ed4c38bf6a6c9e1a2e4f3ed23c1d4c81867e81f7c,
                 document_version: 20260710-intermediate,
                 locked_modules: [V-1.0-Ratified, Zicntr-2.0-Ratified, Machine-ISA-1.13-Ratified]}
  standard_status: experimental-pinned-pdf
  first_product_profile: ENG-P1-VLEN128-MACHINE
  first_delivery_config_ids: [rvv_core_mini_axi,rvv_core_mini_verification_axi]
  first_delivery_variant_ids: [ime_off_baseline, ime_on_delivery]
  default_and_rollback_variant_id: ime_off_baseline
  variant_selection_mode: immutable-static-bazel-target
  phase_numeric_profile: {P0: null, P1: null, P2: null, P3: null, P4: P4-N0}

caller-owned:
  phase_id: <P0|P1|P2|P3|P4>
  phase_profile_id: <§4.4固定profile ID>
  completion_scope_kind: <PHASE_PROFILE|CAPABILITY_DELTA>
  release_intent: <DEVELOPMENT|RELEASE_CANDIDATE|RELEASE>
  delivery_scope: <hardware-only|hardware-and-software>
  hardware_claim_record_ids: <INST/CELL/ISAEXT ID array；不得引用ENC/RULE作为能力>
  software_claim_ids: <hardware-only必须[]；否则从§8 SW-* stable ID选择>
  software_toolchain_workspaces: <SW-ASM/SW-C/SW-M16 claim必填：repo path、base commit、authorized file scope、exact build/test labels；否则[]>
  delivery_config_ids: <只作caller scope确认，不是selector；必须逐值等于build_target_bindings.delivery_active_variant_set_id所引config_pairs的排序base IDs。ENG-P1 first profile固定[rvv_core_mini_axi,rvv_core_mini_verification_axi]；P4 full必须是owner批准的新P4-capable base configs；每项都有off/on variant>
  privileged_scope: <bare-metal-nonprivileged|machine-mode-vector-context>
  trusted_launcher_artifact: <caller控制的absolute path、SHA-256、launcher_protocol_version=CORALNPU_IME_LAUNCHER_V1；agent不可修改>
  bazel_executable_artifact: <caller先验锁定的{absolute_realpath,sha256,tool_version,version_output_sha256}；无symlink，bootstrap及post-bootstrap都直接执行该path>
  trust_store_artifact: <caller控制的absolute path、SHA-256、schema version；含key usage/validity/revocation>
  trusted_evidence_output_root: <repo外absolute path；调用开始时必须不存在，由launcher以0700原子创建>
  capture_receipt_output_path: <repo外absolute path；capture后由trusted launcher签名，agent只读>
  engineering_targets_artifact: <artifact_ref|null；P1--P4 RTL与任何RC必填，P0仅基础设施时为null>
  platform_async_events_artifact: <schema-valid path、SHA-256、approval signature/key；P0--P4 RTL必填>
  base_reference_artifact: <ime/config/base_reference.yaml的path、SHA-256、owner approval；P0--P4必填，禁止引用本次待测off artifact作为reference>
  owner_binding_artifact: <ime/project/owners.yaml的path、SHA-256与accountable approval signature；RTL/RC必填>
  architecture_approval_artifact: <本document/version、architecture.yaml/canonical interface_abi.yaml的hash及review-board signature；datapath RTL必填>
  risk_register_artifact: <ime/project/risk_register.yaml path、SHA-256、review timestamp；RTL/RC必填>
  release_authority_artifact: <release_authority.schema-valid signed artifact_ref|null；RELEASE时必填，envelope/payload type按§7.6，closed payload恰为{key_usage=release-authority-policy,authorized_key_ids[],allowed_phase_profile_ids[],allowed_delivery_active_variant_set_ids[],issued_at,valid_from,valid_until}，三个时间均为RFC3339 UTC且valid_from<valid_until；其它intent为null>
  authorized_delta_root_ids: <本次允许变化的INST/CELL/ISAEXT ID array；不得引用ENC/RULE>
  external_gate_requests: <逐§2.1 external gate-ID的{requested_scope=IN_SCOPE|OUT_OF_SCOPE,evidence_artifacts[{path,sha256,signer,key_id}]}；caller不得写PASS，也不得覆盖contract已锁定PASS证据>
  p3_memory_profile_artifact: <artifact_ref|null；P3必填，首版固定M-mode/no-MPRV/no-translation及完整memory contract；其它phase为null>
  zvfbfa_artifact: <artifact_ref|null；P4必填的owner-confirmed artifact；其它phase为null>
  p4_format_artifacts: <artifact_ref[]；P4非空并覆盖OCP MX/IEEE/RISC-V formats；其它phase=[]>
  p4_numeric_profile_artifact: <artifact_ref|null；P4必填的G/psm/rnd+SAIL artifact；其它phase为null>

cross-field validation:
  - `phase_profile_id`必须等于`delivery_active_variant_set_id`所引active set的phase profile，`delivery_config_ids`必须等于其排序base IDs；caller不能选active-set ID、删减config或用这些确认字段改变BUILD静态binding，任一mismatch直接拒绝；
  - completion_scope_kind=PHASE_PROFILE时，delivery_scope、hardware/software roots必须逐值等于phase profile requirements，不能由caller删减；
  - completion_scope_kind=PHASE_PROFILE时authorized_delta_root_ids必须[]，授权根自动包含profile的required_claim_root_ids；CAPABILITY_DELTA时不自动加入required_claim_root_ids且caller必须显式给出非空additional delta roots；
  - ENG-P1-VLEN128-MACHINE的P0/P1 PHASE_PROFILE或任何RELEASE_CANDIDATE/RELEASE强制privileged_scope=machine-mode-vector-context；bare-metal-nonprivileged仅允许DEVELOPMENT+CAPABILITY_DELTA，且qualification_status固定NOT_READY；
  - RELEASE_CANDIDATE或RELEASE强制completion_scope_kind=PHASE_PROFILE、该APPROVED profile的全部delivery config同record-revision off/on variant齐全、所有适用工程artifact/approval非null；ENG-P1 first profile的分母恰为两个固定config的四tuple，其它profile不得偷用此分母。RELEASE还强制release_authority_artifact非null；governance envelope按payload `issued_at`验签且其key不得自授权，release manifest/bundle两个envelope的`key_id`都必须被该artifact授权给matching phase/active-set，在trust store中分别允许exact payload type及`release-manifest`/`release-bundle` usage，并令各自`signed_at`落入policy半开时间窗`[valid_from,valid_until)`；
  - caller的privileged_scope必须逐值等于selected `CoreBaseBuildConfigV1`封存值，不能作为第二配置入口；caller不得请求runtime enable或只验证on而删除off；每个授权config固定同时生成/验证同record_revision的off与on，off为默认/rollback。target/variant/base/wrapper/final hash不一致、独立enableIme/IME_ON define/env/plusarg或未知variant必须validation/elaboration失败；
  - trusted launcher必须在任何bootstrap Bazel command前验证`bazel_executable_artifact`的realpath/regular-file/mode/hash及`--version`完整输出hash；capture receipt、caller inputs和implementation manifest逐值复述同一ref。任一差异停止，不能由PATH或后生成manifest补救先前bootstrap自举；
  - base_reference必须满足§4.10 schema并逐项锁定reference artifact/model及DELTA records；missing hash、wildcard compare mask、DUT-self-reference或未批准delta使IMP-P0-OPTIONALITY保持OPEN；
  - P3-TILELS-MMODE-NOMPRV + PHASE_PROFILE强制hardware-and-software、SW-C-TILELS-INTRINSICS与适用SW-M16-PSEUDO闭包及toolchain workspace；
  - P3 hardware-only只能CAPABILITY_DELTA，closure必须写delta COMPLETE/phase PARTIAL且IMP-P3-C-IO-ABI不得PASS；
  - 所有artifact ref必须是schema允许的结构、absolute或repo-relative规范路径、实际SHA-256与可验证signature；不适用项只能按schema使用JSON null或[]，字符串"N/A"、自由文本evidence、missing hash或unknown property均使validation失败；

agent-derived-and-verified（只能来自锁定prestate/as-built source，不从caller复述）:
  workspace_prestate_file_sha256: <imported canonical workspace_prestate.json hash>
  capture_receipt_sha256: <trusted repo-external immutable receipt hash>
  base_commit: <workspace prestate中的git rev-parse HEAD full hash>
  pdf_sha256: c0d25144279b1790cb285d3598e8207005ba9dfc9c24cb5aa00c7d1838829307
  riscv_dependency_pdf_sha256: 04499fadf0a8c3d55a73543ed4c38bf6a6c9e1a2e4f3ed23c1d4c81867e81f7c
  requirements/spec/phase_profile/capability_catalog/delivery_variants/build_target_bindings/base_reference_file_sha256: <各canonical artifact独立hash>
  architecture/interface_abi_file_sha256: <经schema验证的architecture.yaml与ABI canonical hash>
  engineering_targets/platform_events/owners/risk_file_sha256: <从caller refs重算，不接受caller复述>
  verification/coverage/ci_plan_file_sha256: <各canonical artifact独立hash>
  resolved_executables[]: <至少含caller先验bazel ref；每项closed absolute_realpath/hash/tool_version/version_output_sha256并由trusted launcher重算>
  preexisting_state: <只引用workspace_prestate中的NUL status、binary diff、untracked archive/entry metadata及submodule hashes，不再维护弱化重复字段>
  tool_versions_and_build_graph: <从resolved executable refs、锁定compiler/simulator及实际Bazel graph重建>
  expected_variant_build_identity_by_config: <每个off/on静态target的record revision/ref、expected module/artifact名、config/variant code、base/wrapper/record/effective/final-config/sidecar hash；禁止预填尚未build的DUT binary/netlist hash>
  verified_external_gate_dispositions: <只对EXT-*重算artifact hash、scope/dependency后得到PASS|OPEN|OUT_OF_SCOPE及证据>
  applicable_implementation_gate_ids_and_criteria: <按phase profile+claim闭包派生，pre-test状态固定OPEN；OUT_OF_SCOPE不在集合内>
  authorized_delta_closure_ids: <从fixed foundation roots、PHASE_PROFILE required claim roots或CAPABILITY_DELTA caller roots的规则化并集传递派生>
  actual_capability_delta_ids_by_config: <同一post-change config的ime_on_delivery overlay相对ime_off_baseline overlay派生>
  unauthorized_delta_ids: []
  authorized_delta_set_hash: <对排序去重后的root+closure IDs做canonical hash>

post-change-source-derived（写change manifest、每份test result和closure report，不反写implementation manifest）:
  change_manifest_file_sha256: <外部计算>
  post_change_source_tree_hash: <按path排序的全部task-owned source/test/spec/ABI输入hash>
  source_input_file_hashes: <只含§4.4定义的source_input；零遗漏>

bootstrap-derived（trusted launcher封存后只读，写每份result与closure report）:
  preplan_evidence_root_sha256: <不含plan-generation result的capture/import/as-built/change result root>
  bootstrap_attestation_sha256: <覆盖capture receipt与全部bootstrap argv/result/artifact hash的detached attestation>
  command_plan_sha256: <final immutable post-bootstrap plan hash；trusted launcher每条执行前重算>
  result_set_attestation_sha256: <覆盖plan hash、全部权威command result ID/hash与zero-extra/missing计数>

generated-evidence（均不得写回change manifest）:
  generated_preclosure_evidence_hashes: <plan/results/log；closure report可只读引用，最终由closure attestation签名>
  generated_finalization_evidence_hashes: <closure report/MD/finalization result/closure attestation；不得反写closure，外部bundle descriptor同时携带>
  generated_release_evidence_inventory: <验签并重算完整单向链后生成的unsigned convenience index：release manifest/attestation/bundle descriptor/detached bundle attestation及全部bundle entry hashes；它不进入任何前置或自身签名payload，也不得被当作新的trust anchor，消费者必须从detached bundle attestation重新验证>

post-test-derived（只写closure report）:
  actual_variant_artifact_identity_by_config: <从权威VARIANT result汇总的实际ImeBuildIdentity、generated RTL及DUT binary/netlist hash；逐tuple唯一>
  final_implementation_gate_status: <测试/证明完成后逐IMP-*派生>
  requested_scope_implementation_status: <NOT_STARTED|PARTIAL|COMPLETE>
  requested_scope_verification_status: <NOT_RUN|PARTIAL|COMPLETE>
  phase_profile_implementation_status: <NOT_STARTED|PARTIAL|COMPLETE；CAPABILITY_DELTA不得为COMPLETE>
  phase_profile_verification_status: <NOT_RUN|PARTIAL|COMPLETE；CAPABILITY_DELTA不得为COMPLETE>
  profile_conformance: <BLOCKED|CONSTRAINED_EXPERIMENTAL|CONFORMANT_TO_PINNED_ARTIFACT>
  standard_claimability: <NOT_CLAIMABLE|EXPERIMENTAL_ONLY；本contract禁止STABLE_STANDARD>
  qualification_status: <NOT_READY|RC；closure永远不得写RELEASED>

若caller要求首版集合以外的delivery config，必须先为每个config的off/on variant提供exact build/test/lint label并进入command plan，
否则BLOCKED。`standard_status`在本contract中只能是`experimental-pinned-pdf`；stable-standard请求必须停止，
取得owner-frozen/ratified IME replacement artifact并重新审计/生成新contract，不能拿当前Draft PDF直接改标签。
capability delta必须引用manifest record IDs，且actual delta不得超出authorized closure；P1可同时列instruction、具体legal cells与三个ISAEXT type-extension record，
P3可列四条tile-LS INST及ISAEXT，不能用单个自由文本字段。ENC ownership始终存在，不能作为能力开关。
修改与preexisting change重叠时逐hunk保留
用户内容，并在closure report记录before/after evidence；只保存路径不足以证明没有覆盖用户改动。

本文件是 CoralNPU integration contract，不覆盖更高优先级 normative source。优先级固定为：
1) 顶部 hash 锁定 PDF normative text；
2) 锁定版本的 ratified base-V rule及已锁定的外部 dependency；
3) 本文件明确冻结的 CoralNPU implementation decision；
4) 当前源码；
5) 当前测试。
高优先级与低优先级冲突时，停止相关实现并登记 blocker。不得根据 mnemonic、旧设计、普通 RVV行为或现有测试猜测 IME 语义。

开始前：
1) 在任何workspace写入前获取mutation lock，逐repo执行§7.6完整NUL/binary/tar/submodule capture，取得agent不可改写的trusted capture receipt并验证raw dir只读；失败立即停止；
2) capture完成后才序列化caller inputs，并以真实JSON Schema逐项拒绝placeholder/unknown property/hash或signature不符；再阅读本阶段、阻塞矩阵和两份锁定PDF相关页，逐hash复核contract-locked artifacts；
3) 运行M0 DoR审计：requirements/schema/完整ID catalog、profile roots、architecture/FSM/ABI/reset、verification/coverage plan、RACI/risk和所需工程输入必须均已物化且获得相应approval；未满足时只允许补文档、模型、generator、validator和bootstrap基础设施，禁止修改datapath或effective-enable能力；
4) 根据phase profile和claim闭包列出applicable gate与required roots；前置implementation gate未关闭时停止后续datapath。`implementation_blocking`阻止相关能力，`claim_only_blocking`只缩小声明，`OUT_OF_SCOPE`必须由调用输入明确排除且经闭包证明不可达；
5) 不得声称“完整正确”或“ISA合规”，除非本文件第1节全部条件已满足；CAPABILITY_DELTA完成不得冒充phase COMPLETE；
6) 每个源码结论给出精确文件/行证据；不能由锁定PDF或源码证明时，写入“未解决事项 + 原因 + 所需外部证据”，不得猜测；
7) 创建/校验§4.4/§4.5的spec/as-built/change manifests、phase profiles、architecture、interface ABI、side-effect/traceability matrix及command plan validator/closure attestation；workspace runner不是权威执行器，target不存在也不是跳过理由。

硬规则：
- IME 使用现有 32xVLEN VRF，不新增 architected matrix register file。
- IME geometry 使用 lmul_orig（architectural vtype.vlmul），绝不使用 CoralNPU 的 reduced lmul。
- P0 必须先修 wrapper 的既有位宽：vl[7:0]、vstart[6:0]、xrm[1:0]、sew/lmul/lmul_orig[2:0]；vstart的7 bit是正确索引宽度。随后把 lambda/bs/altfmt_A/altfmt_B及feature-dependent low altfmt穿透 Chisel/SV/CSR/reset。CoralNPU reset policy固定 `vstart=0,vl=0,vtype=0x80000000`、无X。VS!=Off时，每种unsupported-vtype VSET正常退休一次/`minstret+=1`、清 `vstart`、得到同样的 `vl/vtype`，`rd!=x0 -> x[rd]=0`且不trap；VS=Off时同一VSET illegal/`minstret+=0`且保持rd/vl/vtype/vstart。完整覆盖 `rd/rs1` AVL forms；`rd=rs1=x0`只在old vill=0且VLMAX不变时keep-vl，reserved case固定canonical vill而不trap，lambda/bs/altfmt-only合法改变必须保持vl。测试 `Sλ(8)=Sλ(16)=Sλ(32)={2}` WARL。high bs/altfmt_A/B原样可表示、在消费时检查；output altfmt absent时bit8 reserved，P4外部Zvfbfa artifact未锁定时禁止实现。
- IME必须作为§4.10默认off、immutable、hash绑定的sealed variant实现；现有非`_ime` target永久绑定off，新`*_ime_*` target绑定on。唯一selector是由actual target label在reviewed lock中查得的`ime_variant_record_ref`，BUILD/CLI/env不得传入或替换它；同一产品variant在phase/profile payload改变时产生新`record_revision/ref`并复用稳定variant code，record/effective digest区分revision。`enableIme`只能是record的只读derived constant，禁止mutable setter、独立`--enableIme`、`IME_ON`宏、env/plusarg/runtime CSR旁路。`CoreBaseBuildConfigV1`只包variant-independent值，module/top/artifact/pin ABI放入`VariantWrapperConfigV1`；base/wrapper/record/effective/final hashes必须形成唯一join。analysis-known rule生成common sealed Scala/lock并先进入Scala library，BUILD再静态声明target tuple及固定sidecar outputs；generator不得生成供同次Bazel analysis加载的fragment或runtime-hash路径。generated wrapper从同一record向`RvvCore.sv`传全部七个presence values、codes和两个digests；`RvvCore`据此构造608-bit identity，wrapper以不可覆盖的expected literal逐bit复核，wrapper top不得暴露这些parameter。所有flow禁止`-G/-pvalue+/defparam`等二次覆盖。compiled Scala record、SVH/capability-JSON/build-identity-JSON/header/note/DUT identity/effective-set hash必须一致。
- off仍须elaborate known-IME classifier、minimal sticky precise-illegal/RB booking shell和high-vtype reserved checker，但必须结构裁掉legal-command path、phase engines、shadow、IME VRF mux、batch/FCSR/tile datapath及其clock load；normal VRF/retire pathgenerate直连。off唯一允许新增的clocked state是`GUARD-*` allowlist中为precise-fault协议所必需且`max_count/max_bits`有界的pending/age/fault state；不得存在`ImeResetController`或专用reset-release synchronizer。feature-off raw encoding必须pre-backend precise illegal，不能只从backend消失；reserved high-vtype配置请求由VSET成功canonicalize vill/vl=0而不trap。用off hierarchy/netlist absence、off-vs-P0-reference及on-vs-off no-IME逐cycleequivalence共同关闭，缺一不可。
- 每个single-variant DIRECT build/lint/test target及每个SUITE_MEMBER child必须直接依赖对应DUT和identity manifest，stimulus前核验`ImeBuildIdentity`；SUITE_PARENT只要求`tests[]`与member闭包逐项相等，由parent binding test核验全部child direct bindings。comparison target显式绑定reference+off或off+on两侧，package/bundle target显式绑定APPROVED N-input set，不得伪绑一侧或exclusion。`IME_CONFIG_ID/VARIANT_ID`只可交叉检查，不能选择DUT。完成新增SV/Scala三层resource registration和Core Verilator、cocotb Verilator/VCS、standalone VCS、lint的逐tuplebuild。首版SoC/TLUL/FPGA显式绑定off且不在IME-on release scope；`CoreTlulParameters -> SoCChiselConfig -> instantiateModule`不得丢variant。
- 逻辑必须保持§4.6唯一state ownership和source边界：`ImeConfigController/ImeIngressController/ImeEngineP1/ImeEngineP2/ImeTileLsu/ImeFpMxEngine/ImeVrfArbiter/ImeCommitCoordinator/ImeFaultCoordinator/ImeResetController`不得复制owner state或形成旁路。IME读只经arbiter复用现有VRF ports；IME ownership期间普通dispatch read/uop与普通retire write均为0，禁止新增physical VRF port。P2 effective presence必须实例化`ImeEngineP2`，不得让P2 legal decode落入P1-only engine或无consumer。
- P0先创建并通过contract-global的spec/schema/hygiene validators，以及active set全部`2N` artifact各自的interface-width/identity/base-RVV测试、off structure检查、variant schema negative test和两类equivalence（首个profile为四tuple）；不得把DUT test与global validator合并，也不得用同一个`ime_p*_all` label只改环境变量。冻结§4.4/§4.5 ABI及ENC/INST/CELL/ISAEXT/RULE/SW分层、phase profiles、config off/on overlays和authorized-vs-actual delta。requested `enabled_*`与effective-legal INST/CELL必须分字段；只有`enforced_legal`可派生PRES/datapath/max-inflight。修改完成、测试开始前冻结pre-test as-built/change manifests与command plan；plan ID只绑定analysis-known refs，实际DUT hash只写signed result。CAPABILITY_DELTA完成不能冒充phase COMPLETE。有effective legal command的首版IME_MAX_INFLIGHT=1，否则为0；accepted macro ID与pre-accept scalar age ID分开且分别在自身boundary ack前不复用，所有sticky payload在backpressure下稳定。
- reset/CDC/RDC严格执行§4.7：`PRES-IME-LOCAL-RESET=false`当且仅当`ime_reset_contract=null`；presence=true时只能选有platform evidence的`PREANNOUNCED_DRAIN`或`COMMON_ATOMIC_RESET`。P0/P1只有一个功能clock域，`rstn` async assert、local two-flop sync release，`ime_reset_done`前双向valid/ready均quarantine且零accept/fault/write/completion/CSR side effect；pure off guard不实例化local controller，使用scalar reset release派生的ingress done，且不得新增专用reset-release flop/clock load；仅`GUARD-*` allowlist内有界的precise-fault state例外。功能CDC crossing=0、所有跨reset-release路径通过RDC lint/partial-reset formal，ready/valid无组合环。任何第二时钟或异步response必须先走ADR、CDC ABI和formal，不得由LLM临时加同步器。
- 若privileged_scope为machine-mode-vector-context，P0必须实现`mstatus.VS` Off/Initial/Clean/Dirty：VS=Off拦截所有base-RVV/IME/VSET/vector CSR access且零side-effect；成功vector state change保守置Dirty/派生RV32 SD；写Off/Initial不得清VRF/vector CSR。accepted P3 fault再按边界置VS Dirty。P4对FS、scalar/vector FP及FCSR CSR access实施同类规则。否则manifest明确bare-metal exclusion。S/H mode不在本contract，scope未固定时gate保持OPEN。
- 任何IME legality/accept前，必须得到program-order coherent的config snapshot；适用时还要privilege、P4 frm、P3/P4 scalar operand和v0 snapshot。使用`ime_admission_safe/phase_snapshot_valid/ime_cmd_sink_ready`定义`ime_accept_safe`；为in-flight writer实现forwarding或stall。不得读取invalid live bits，也不得用reduced lmul。
- P1 仅 SEW=8/16/32、LMUL=1/2/4/8、上述 lambda matrix，且仅 vmmacc.vv/Zvvi8mm/Zvvi16mm/Zvvi32mm；SEW64/lambda scope gate 未关闭前不得扩展合规声明。bs对ordinary integer ignored；low altfmt仅在has_vtype_altfmt=true且vtype合法时测试0/1 ignored，capability absent时nonzero bit8必须在配置期置vill。
- IME在packet lane k初次命中时只阻止k及younger，允许strictly-older prefix drain；到lane0后建立ime_pending。illegal唯一owner是Decode，pre-accept fault使用`ImeAgeTag.PRE_ACCEPT(scalar_age_id)`，不分配或伪造macro ID。sticky fault保持到`ImeFault.fire`，该fire即ImeFaultBookingAck且只清producer valid；serial lock必须等逐bit匹配同tag的fault record到达精确trap点、faulting instruction以`minstret+=0`被trap消费并完成CSR/redirect后的ImeTrapBoundaryAck。修复当前RB对普通Fault可能错误增加nRetired的问题。等待全程抑制RVV/write mark；禁止frontend duplicate trap、lcmd discard或分裂vstart route。
- IME classifier是hard forceSlot0Only requirement，但必须保留older-prefix progress；覆盖fetch/dispatch/RVV ingress/busy，断言不会因冻结whole packet死锁。
- P1只在ime_accept_safe处理pending：ime_admission_safe、phase snapshot valid、engine与专用RB metadata entry均ready。legal path强制`fetch_lane0.fire=ImeRbEntryEnq.fire=ImeCommand.fire`并使用`ACCEPTED_MACRO` tag；illegal path强制`fetch_lane0.fire=(ImeRbEntryEnq.fire&&isImeFault)=ImeFault.fire`并使用`PRE_ACCEPT` tag。`ImeRbEntryEnq`复用既有lane0 instBuffer enqueue、每次只增一个entry，不得另建第二enqueue；两条路径均不发普通RVV backend command。任一子fire单独发生都是S1。legal accept后使用shadow C，除满足reset-quiesce contract的global reset外不可kill；interrupt、debug halt/trigger/single-step和scalar trap延后到tagged ImeOuterRetireAck。illegal等matching `ImeTrapBoundaryAck`。若有NMI/async kill或并发，必须实现tag/rollback/flush ack proof。
- P1 必须按 PDF int_gemm 的 j->i->k 即时读写顺序处理 C/A/B overlap；equal-EEW P1 overlap 必须接受，不得 snapshot 全部 source，也不得额外判 overlap illegal；每个 active j 都必须处理全部 i=0..M-1。
- C tail：vta=0 必须保持；P1 对两种 vta 都保持。physical C stride 始终 N_max=M。
- P1独立sequencer只更新max-4-register shadow C并用byte overlay服务所有alias read，零VRF write/compute-uop completion。partial accumulator在final-k前只在`acc_q`，overlay visible集合只含词典序已完成output；final-k用`shadow_next`形成batch。完成后经`rvv_backend_retire.sv`新增独立batch输入，在normal retire/trap/WAW最终gating后、VRF输出前all-or-none mux；commit cycle普通ROB lane零consume/零write。N=0为唯一Completion intent、0-lane batch。扩scalar RB entry和completion到macro_id match、tagged outer ack，分离write valid；修backend retire trap/invalid write gating。8-slot仅是full-profile trace限制，不能当architecture readiness。
- P1微架构固定单scalar-MAC/cycle、组合VRF current-cycle read和§4.8 FSM。按rising-edge序号计，sink ready时`L_command_fire_to_commit_fire=1+max(1,M*N*K_eff)`且P1中`M*N*K_eff=M*VL`；所有合法tuple实测必须严格相等。时序不收敛只能提交ADR并重审pipeline/alias/latency/PPA，禁止悄悄插bubble或只放宽timeout。
- `ImeVrfCommitBatch`只有一个valid/ready/fire，无per-lane ready；valid lane数为`N==0?0:ceil(N/lambda)`，reg_idx两两不同且仅active byte strobe非零。batch、Completion intent、required context intent必须同时held，只有RB-oldest、VRF/CSR/trace/minstret/ack全部ready时才发生同一个`ImeMacroCommit.fire`；该edge原子写C、VS/SD并退休一次，之后matching OuterRetireAck才释放macro。任何partial fire、tail-only假write、同址OR-merge、early write/retire或rollback都是S1 blocker。
- IME textual/raw mapping 固定为 `vd,vs1(A),vs2(B)`：`A=inst[19:15]`、`B=inst[24:20]`。`RvvDecode.s1decode_opivv(f6vm,vs2,vs1,vd)` 的 positional argument order 不是 IME semantic order，必须显式连 `A=vs1,B=vs2`。对 `vd=4,A=1,B=2,vm=1`，四条 word 是 e2208257/e6208257/ea208257/ee208257；不得把 e211... 的 swapped fields 标成该语义。
- P2：作为 non-restartable MAC，先继承 `ime_pending`/serial admission/outer-retire C-write commit/interrupt policy；任一P2 CELL变为effective legal时必须同步实例化独立`ImeEngineP2`、其W/packing state、VRF arbitration input和atomic commit source，其中任一缺失则schema/elaboration fail。A/B physical group 始终是 `lmul_orig` 个寄存器，不能除以 W。在 `EXT-WIDENING-MULTIEEW-OVERLAP`关闭前，W>1的C与A/B任何overlap均precise-illegal，不能因满足high-end条件就开启；A/B彼此同EEW overlap可接受。m16 C相关overlap另在 `EXT-M16-OVERLAP`关闭前disabled。Table 88 每 cell pre-ingress `{supported|feature-off illegal|reserved illegal|blocked_external}`；实现 exact packing/Int4 nibble 与 P2 A/B-order discriminating regression。
- P3前不得声称tile-LSU/fault/restart可用；首版memory context固定M-mode/no-MPRV/no-translation并锁定idempotent normal-memory region，未来扩展必须加入ImeMemoryContextSnapshot/ordering。pre-request illegal复用`ime_pending -> ime_fault_safe`。接受时锁存全部snapshot；`vm=0`的masked tile load destination或masked tile store source group包含v0均pre-request illegal。首版每次仅一个element transaction从request直到load VRF/store done durable。fault携带cause及profile-correct virtual tval；任何store error必须证明faulting store零side-effect，否则该region禁用。fault顺序为flush ack→保留older effects→提交vstart/required VS/SD→trap boundary；无completion/outer ack/minstret。success在全部effect+vstart0/context durable后才completion/retire。关闭FaultInfo/AXI缺口，验证pre-reset drain或common-reset atomic-cancel contract及跨reset迟到response。不可延迟event不得只丢engine state。C使用full physical layout/mask；m16用compiler pair/unpair和m8 halves。
- P4前不得声称FP/MX/fflags可用；先锁定Zvfbfa/format artifact并解决dependency，计算Table86 closure和Table73 base dependency。P4 full profile必须新增owner-approved P4-capable base/delivery config，off/on两侧共享base-derived `has_vtype_altfmt=true`；不得改写首个P0/P1 base config或用IME variant切换Zvfbfa。`frm` CSR保持完整3-bit RW，写5/6/7必须原值读回；所有P4 profile只在instruction ingress接受frm=0..4，并把5..7按本profile选择映射为precise illegal，即使VL=0也一样。privileged scope另检查VS/FS并提交VS/FS/SD。首profile只接受hash锁定P4-N0的逐tuple`G=1,psm=0,rnd=frm`。区分low output altfmt与input altfmt_A/B，覆盖Table75/87 reserved/mixed/bs。MX v0使用exact layout；全部C batch、Completion、fflags与context intent必须held到同一个P4 MacroCommit fire；commit容量不足的CELL保持disabled。FP-input和integer-input严格使用各自模型。
- 仅raw-word encoder可用时，只能选择`SW-RAW-ENCODER`，它不是mnemonic/toolchain/C API支持。software_claim_ids逐项驱动资产；`ime_lambda`是隐式state read，vsetlambda返回selected value。MX SSA scale必须物化到architectural v0；每个intrinsic建立完整vtype high fields并回归相邻reconfiguration。外部API/psABI gate未闭合时不得伪称portable支持。

每次提交必须由trusted launcher完成bootstrap封存并直接执行`verification_plan.yaml`中全部applicable TEST/PROP/COV与§7.6命令，形成signed result set，再满足§7.7；禁止手工命令或task-owned runner自报结果替代权威ledger。生成canonical `closure_report.json`及其单向派生`.md`，包含修改文件、全部manifest/hash、支持矩阵、正交scope/phase状态、未关闭事项、independent model、非法/trap、base RVV、全部命令/exit code/log/seed/coverage/proof。RELEASE_CANDIDATE/RELEASE的pre-closure qualification还必须从clean checkout执行release CI、两次可复现构建、PPA、SBOM/license和rollback drill；只有`release_intent=RELEASE`且signed closure已产生后，trusted launcher才执行独立release finalization生成release manifest/attestation，二者不得写回closure。缺少toolchain、license、ISA owner冻结版本、工程budget、owner approval或fault interface时gate保持OPEN/BLOCKED，不能猜测或报告COMPLETE/RC；LLM永远不得直接报告RELEASED。
```

## 10. 溯源

| 结论 | 证据 |
| --- | --- |
| geometry、lambda、WARL、type extension/family 规则 | PDF §36.2--§36.4、§36.9.2--§36.9.3、§36.11、§36.13 |
| exact `tile_reg_idx` 与 A/B/C flat mapping | PDF §36.11 shared pseudocode（pp. 653--654） |
| RV32 high-vtype layout、配置期 preserve/write 与 consumption-time format check | PDF §36.4.1--§36.4.4（pp. 590--595） |
| low output `altfmt` external dependency | IME PDF §36.4/§36.4.3 只引用 Zvfbfa；当前 provisional bit-8 evidence 是 [public Zvfbfa v0.1 text](https://github.com/aswaterman/riscv-misc/blob/main/isa/zvfbfa.adoc)，但该 artifact 尚未被 IME PDF/ISA owner锁定，故仍为 P4 blocker |
| C tail 的 vta 行为与 physical stride | PDF pp. 623--624，§36.9.2--§36.9.3 |
| sequential alias 与 P1/P2 overlap | PDF §36.11 shared `int_gemm` pseudocode（p. 660）与 `check_gemm_reg_groups`（pp. 652--653）；[RISC-V V v1.0 operand-overlap rules](https://docs.riscv.org/reference/isa/unpriv/v-st-ext) |
| IME full encoding | PDF §36.11.1/9/14/15（pp. 667、683、697、699） |
| FP/MX与tile-LS full encoding partition | PDF §36.11.2--§36.11.8、§36.11.10--§36.11.13（pp. 669--681、685--695） |
| RISC-V dependency artifact身份/ratified模块 | `ime/riscv-spec-inter20260710.pdf`，SHA-256 `04499fadf0a8c3d55a73543ed4c38bf6a6c9e1a2e4f3ed23c1d4c81867e81f7c`；Document Version 20260710-intermediate；Unprivileged Preface pp. 3--5与Privileged Preface p. 648 |
| standard vector encoding 的 funct3 区分 | 锁定RISC-V artifact Base Vector Architecture §9.1.9.1（printed pp. 318--319）的OPIVV/OPMVV；当前 `rvv_backend.svh` 和 `rvv_backend_decode_unit_ari.sv` |
| 当前 state/wrapper/trap/ingress | `hdl/chisel/src/coralnpu/rvv/RvvInterface.scala`、`RvvDecode.scala`、`RvvCore.scala`、`hdl/verilog/rvv/design/RvvFrontEnd.sv`、`RvvCore.sv`、`hdl/verilog/rvv/design/rvv_backend.sv`、`hdl/chisel/src/coralnpu/scalar/Decode.scala` |
| 当前 resources/retirement | `rvv_backend_config.svh`、`rvv_backend_define.svh`、`rvv_backend_vrf.sv`、`RetirementBuffer.scala` |
| current LSU fault/cause/tval/handshake gap | `Interfaces.scala`、`scalar/Lsu.scala`、`scalar/FaultManager.scala`、`SCore.scala`、`DBus2Axi.scala`、`RvvInterface.scala`、`RvvCore.sv` |
| generic tile-LS lambda/offset/restart semantics | PDF §36.8 及 `vmtl/vmts/vmttl/vmtts` instruction pages（pp. 685--695） |
| C tile load/store physical layout | PDF §36.9.5（pp. 625--626） |
| FP/MX disclosure and reduction requirements | PDF §36.7.2--§36.7.3 |
| FP/MX type dependencies、implication 与 exact encoding cells | PDF Table 73、§36.12/Table 86、§36.13/Table 87--89（pp. 589--590、700--710） |
| C API、tile qualifiers、MX ABI、m16 pseudo-intrinsic 与 psABI boundary | PDF §36.10.1.1--§36.10.1.9（pp. 631--650） |
| base-V vtype/VSET/AVL/vstart/VS behavior | 锁定RISC-V artifact §9.1.2.2（pp. 282--283）、§9.1.2.4/§9.1.2.7（pp. 283--289）、§9.1.5.1--§9.1.5.3（pp. 299--303） |
| operand overlap、mask-source EEW与precise vector trap | 锁定RISC-V artifact §9.1.4.2（pp. 297--298）、§9.1.17（pp. 370--371） |
| invalid vector-FP frm | 锁定RISC-V artifact §9.1.9.1（pp. 318--319）：标准状态是reserved；本contract另固定CoralNPU行为为precise illegal |
| FS/VS/SD、mcountinhibit与xTVAL | 锁定RISC-V artifact Machine ISA 1.13 §3.1.6--§3.1.6.7（pp. 683--692）、§3.1.12（pp. 699--700）、§3.1.16（pp. 704--705） |
| synchronous exception不退休且instret不增加 | 锁定RISC-V artifact Zicntr 2.0 §4.3（printed pp. 64--66） |
| toolchain/upstream status | 本节记录的 legacy Binutils 2.28 与 Coral Bazel Binutils 2.45 实测；[official unratified IME PR #406](https://github.com/riscv/riscv-opcodes/pull/406) |

### 10.1 当前源码审计快照（供实现 agent 定位）

| 结论 | 审计时的精确定位 |
| --- | --- |
| architectural/reduced LMUL、reset X 与 illegal-vtype canonicalization 缺口 | `hdl/verilog/rvv/design/RvvFrontEnd.sv:169-242,250-317,326-342`；`hdl/chisel/src/coralnpu/rvv/RvvInterface.scala:21-40` |
| wrapper multi-bit CSR 被声明为 scalar及 width warning suppression | `hdl/chisel/src/coralnpu/rvv/RvvCore.scala:134-156,348-356`；`hdl/chisel/src/coralnpu/BUILD:744-761` |
| 当前无 IME 单一 capability source，Core参数与SV宏分离 | `hdl/chisel/src/coralnpu/Parameters.scala:69-87,157-190`；`hdl/chisel/src/coralnpu/Core.scala:91-130`；`hdl/verilog/rvv/inc/rvv_backend_config.svh:8-10`；`hdl/chisel/src/coralnpu/BUILD:661-714,744-750` |
| SoC另有一条会丢失新feature的参数复制链，首版必须显式off | `hdl/chisel/src/soc/SoCChiselConfig.scala:38-49,130-141`；`hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala:129-142,385-405` |
| Bazel `gen_flags`只驱动Chisel emitter、`vopts`只驱动Verilator；action不能反向生成同次analysis加载的target fragment/runtime-hash output | `rules/chisel.bzl:131-190`；`rules/utils.bzl:15-47`；`hdl/chisel/src/coralnpu/BUILD:661-765` |
| lint当前只有`+define+SIMULATION`，没有variant define/include属性；IME应以wrapper→SV parameter传递并逐top lint | `rules/lint.bzl:20-28,65-102`；`hdl/chisel/src/coralnpu/rvv/RvvCore.scala:27-29,285-338,579`；`hdl/verilog/rvv/design/RvvCore.sv:15-21` |
| 新增RVV SV/Scala资源需三层注册，文件存在不等于进入生成物 | `hdl/verilog/rvv/design/BUILD:18-126`；`hdl/verilog/rvv/inc/BUILD:15-28`；`hdl/chisel/src/coralnpu/BUILD:104-196,383-414`；`hdl/chisel/src/coralnpu/rvv/RvvCore.scala:452-579` |
| config validity 与 CSR readback 未闭合 | `hdl/verilog/rvv/design/RvvFrontEnd.sv:88-97`；`hdl/chisel/src/coralnpu/scalar/SCore.scala:464-468`；`hdl/chisel/src/coralnpu/scalar/Decode.scala:407-423,686-691` |
| privileged FS/VS Dirty与RV32 SD未实现 | `hdl/chisel/src/coralnpu/scalar/Csr.scala:313-315,404` |
| unsupported backend decode 会 discard | `hdl/verilog/rvv/design/rvv_backend_decode_unit_ari.sv:2416,3274-3278,3338`；`hdl/verilog/rvv/design/rvv_backend.sv:363-413` |
| scalar decode 的 vstart/write-mark 与 OPIVV argument order | `hdl/chisel/src/coralnpu/rvv/RvvDecode.scala:61-88,364-375`；`hdl/chisel/src/coralnpu/scalar/Decode.scala:735-748,801-806,956` |
| frontend trap pulse、FaultManager 无 ack 与 backend external-trap tie-off | `hdl/verilog/rvv/design/RvvFrontEnd.sv:116-127,351-413`；`hdl/chisel/src/coralnpu/rvv/RvvInterface.scala:81-82`；`hdl/chisel/src/coralnpu/scalar/FaultManager.scala:75-123`；`hdl/verilog/rvv/design/RvvCore.sv:230-278`；`hdl/chisel/src/coralnpu/scalar/SCore.scala:154-163` |
| fault booking不等于trap boundary | `hdl/chisel/src/coralnpu/scalar/Bru.scala:109-147,202-266`；`hdl/chisel/src/coralnpu/RetirementBuffer.scala:87-90,207-209,407-438` |
| general fault可能被错误计入nRetired/minstret | `hdl/chisel/src/coralnpu/RetirementBuffer.scala:407-436`（`nRetired=deqReady-retiredEcalls`） |
| interrupt/idle 不能构成 P1 precise barrier | `hdl/chisel/src/coralnpu/scalar/Bru.scala:175-178`；`hdl/verilog/rvv/design/RvvCore.sv:237-239`；`hdl/verilog/rvv/design/rvv_backend.sv:1148-1152` |
| completion/write-valid丢失、PC-only match、无tagged outer ack及8-slot trace限制 | `hdl/chisel/src/coralnpu/Interfaces.scala:217-222`；`hdl/chisel/src/coralnpu/scalar/SCore.scala:80-84`；`hdl/chisel/src/coralnpu/RetirementBuffer.scala:21-39,52-69,237-249,268-328,448-453`；`hdl/chisel/src/coralnpu/rvv/RvvCore.scala:358-365` |
| backend retire VRF write-valid/trap gating风险 | `hdl/verilog/rvv/design/rvv_backend_retire.sv:147-160,253-269`；`hdl/verilog/rvv/design/rvv_backend_retire_waw.sv:36-48`；`hdl/verilog/rvv/design/rvv_backend.sv:1098-1144`；`hdl/verilog/rvv/design/rvv_backend_vrf.sv:56-105` |
| VRF dispatch read是current-cycle组合索引、现有write lanes以OR合并 | `hdl/verilog/rvv/design/rvv_backend_vrf.sv:22-38,56-93,107-117`；这要求IME arbiter独占read/write时隙、valid commit lane地址两两不同，不能依赖同址OR结果 |
| debug immediate entry与scalar→RVV reverse kill缺失 | `hdl/chisel/src/coralnpu/scalar/Csr.scala:528-559`；`hdl/chisel/src/coralnpu/scalar/SCore.scala:120-163,220-225`；`hdl/chisel/src/coralnpu/RetirementBuffer.scala:407-438`；`hdl/verilog/rvv/design/RvvCore.sv:230-277` |
| current single-reg hazard与older-prefix dispatch行为 | `hdl/verilog/rvv/design/rvv_backend_dispatch_raw_uop_rob.sv:43-69`；`hdl/verilog/rvv/design/rvv_backend_dispatch_bypass.sv:31-74`；`hdl/chisel/src/coralnpu/scalar/Decode.scala:397-404,497-529,723-733` |
| `vl` 截断与 LSU request/response fault 缺项 | `hdl/chisel/src/coralnpu/scalar/Csr.scala:22-25`；`hdl/chisel/src/coralnpu/rvv/RvvInterface.scala:43-58`；`hdl/chisel/src/coralnpu/scalar/Decode.scala:648-674`；`hdl/chisel/src/coralnpu/scalar/Lsu.scala:181-264,890-893,1029-1047`；`hdl/verilog/rvv/design/RvvCore.sv:163-177` |
| memory fault cause/tval不足与backpressure丢失风险 | `hdl/chisel/src/coralnpu/Interfaces.scala:106-110`；`hdl/chisel/src/coralnpu/scalar/FaultManager.scala:73-107`；`hdl/chisel/src/coralnpu/DBus2Axi.scala:131-141`；`hdl/chisel/src/coralnpu/scalar/Lsu.scala:978-990,1031-1041,1067-1070`；`hdl/chisel/src/coralnpu/scalar/SCore.scala:154-163` |
| 当前 vstart mux/invalid 不能证明 P3 age ordering | `hdl/chisel/src/coralnpu/rvv/RvvCore.scala:605-655`；`hdl/chisel/src/coralnpu/scalar/Csr.scala:498-499` |
| FCSR update 被丢弃及现有 scalar update 竞争 | `hdl/verilog/rvv/design/RvvCore.sv:221-228`；`hdl/chisel/src/coralnpu/scalar/Csr.scala:468-472,582-585`；`hdl/chisel/src/coralnpu/rvv/RvvInterface.scala:109-116` |
| current dispatch/VRF/retire/EMUL resources | `hdl/verilog/rvv/inc/rvv_backend_define.svh:10-35,98-106`（DISPATCH3为6 read ports、4 retire lanes、ROB=8、UQ=16、EMUL_MAX=8）；`hdl/verilog/rvv/inc/rvv_backend_config.svh:5` |

## 11. 工程实施、风险、签核与发布治理

### 11.1 RACI与审批权限

`ime/project/owners.yaml`必须把下列role绑定到真实identity、组织、approval key和backup。LLM/automation只可作为Responsible生成修改和证据，**不得同时充当Accountable、关闭外部门、批准waiver或发布**。

| Work product / decision | R | A | C | I |
| --- | --- | --- | --- | --- |
| IME/Base-V requirement interpretation、EXT gate | Spec engineer | ISA/spec owner | µArch、DV、SW | Release |
| requirements/profile/schema baseline | Systems engineer | Project technical lead | Spec、RTL、DV、SW | 全团队 |
| architecture/FSM/ABI/PPA budget | µArch lead | Architecture review board | RTL、DV、physical/integration | Release |
| RTL/Chisel/SV/generated config | RTL engineer/LLM | RTL lead | µArch、DV | Integration |
| formal/verification/coverage waiver | DV/formal engineer | DV lead | Spec、RTL | Release |
| compiler/binutils/API/ABI | SW engineer | SW lead | Spec、DV | Release |
| P3 memory/platform profile | Integration engineer | Platform owner | LSU/RTL/DV | SW |
| license/SBOM/security/supply-chain | Release/security engineer | Release owner | Legal、tool owners | Project |
| release/rollback/risk acceptance | Release engineer | Release board | 所有lead | 用户 |

每个PASS/OUT_OF_SCOPE/WAIVER/ADR/CR/release approval记录 `approver_identity,timestamp,evidence_sha256,signature,key_id`。角色空缺时 `IMP-ENG-GOVERNANCE=OPEN`。

### 11.2 风险登记册

`ime/project/risk_register.yaml`使用稳定 `RISK-*` ID，required fields为 `description,probability={L,M,H},impact={L,M,H,CRITICAL},trigger,mitigation,contingency,owner,target_date,residual_risk,status={OPEN,MITIGATED,ACCEPTED,CLOSED},acceptance_signature`。阻塞gate不能替代风险记录。初始最小集合：

| Risk ID | P/I | trigger | mitigation / contingency | 当前 |
| --- | --- | --- | --- | --- |
| `RISK-001-SPEC-DRIFT` | M/CRITICAL | IME/Zvfbfa/hash或encoding变化 | pinned artifacts、diff audit；保持feature off并重新回到requirements review | OPEN |
| `RISK-002-PRECISE-FAULT` | H/CRITICAL | duplicate/lost fault、错误minstret/partial write | single coordinator、formal+mutation；失败禁用IME build | OPEN |
| `RISK-003-P1-TIMING-AREA` | H/H | single-cycle 32-bit MAC不满足clock/area | 先取得PPA budget/综合；若pipeline则ADR+新latency/ordering proof | OPEN |
| `RISK-004-ASYNC-DEFERRAL` | M/H | interrupt/debug/NMI超出平台允许延迟 | bounded fairness/event profile；无法defer则禁用profile或实现rollback | OPEN |
| `RISK-005-P3-MEMORY` | H/CRITICAL | store error已有side effect或read不可重放 | 只允许idempotent region；无platform proof则P3不实现 | OPEN |
| `RISK-006-TOOLCHAIN-ABI` | H/H | assembler/compiler不识别或ABI漂移 | raw encoder仅用于DV；软件claim等待真实toolchain与round-trip | OPEN |
| `RISK-007-DV-CONVERGENCE` | M/H | coverage/formal/mutation未收敛 | 分阶段REQ/COV分母、nightly、禁止无到期waiver | OPEN |
| `RISK-008-EVIDENCE-TRUST` | M/H | receipt/plan/result可被同UID替换 | trusted launcher/signature；不可用则不得release | OPEN |
| `RISK-009-VARIANT-DRIFT` | H/CRITICAL | Chisel/SV/test实际选择不同variant，或off网表残留active datapath | sealed target、SV parameter bridge、DUT identity、structure/equivalence proof；失败撤回on并回滚off | OPEN |

CRITICAL residual risk只能由release board显式ACCEPT且不能覆盖ISA错误、数据破坏或精确trap错误；这些必须mitigate/close或禁用对应capability。

### 11.3 ADR、变更请求、缺陷与waiver

架构决策使用 `ime/project/adr/ADR-*.md`，至少包含context、alternatives、decision、consequences、affected REQ/ABI/profile/gate、PPA与verification impact、approvers。以下变化必须新ADR：variant ID/selector/default值、任何runtime enable、off保留/裁剪边界、SV parameter bridge、P1 MAC并行度/流水、shadow结构、serial policy、VRF port、commit原子性、reset/CDC、P3 memory ordering、P4 reduction。

需求/规范/接口变更使用 `CR-*`：原因、before/after hash、受影响REQ/TEST/RTL/software、compatibility/migration、reverification set和审批。ABI采用 `major.minor`：字段宽度/语义/handshake变化升major并使所有consumer closure失效；仅向后兼容optional metadata可升minor。

缺陷使用 `BUG-*`：

| Severity | 定义 | release policy |
| --- | --- | --- |
| S0 | 数据破坏、安全问题、错误architectural state且不可可靠检测 | 立即停止/rollback；零开放 |
| S1 | ISA/trap/retirement/ordering错误或死锁 | 零开放；不得waive |
| S2 | 受限配置功能/性能/工具链错误，有可靠disable/workaround | 原则上关闭；release board限时waiver |
| S3 | 非功能文档/诊断问题 | 可带known issue发布 |

`WAIVER-*`必须有scope、不可覆盖的REQ、风险、owner/approver、expiry、触发重测条件；到期自动OPEN。不得通过删除test、降低threshold、xfail或改oracle来“关闭”BUG。

### 11.4 Milestone DoR/DoD

| Milestone | DoR | DoD |
| --- | --- | --- |
| M0 Requirements/Architecture Baseline | 两份PDF/hash与source audit可读 | REQ/schema/ID/profile、§4.6--4.10、RACI/risk/DV plan批准；当前目标 |
| M1 P0 Foundation Complete | M0通过，bootstrap可执行 | P0全部applicable IMP/ENG gate PASS；sealed off/on、SV parameter bridge、DUT identity、off structure、active set全部`2N` baseline与equivalence均通过（首个profile为四tuple） |
| M2 P1 Code Complete | P1 DoR、PPA/event budget批准 | RTL/code review完成，所有P1 REQ IMPLEMENTED，尚不等于verified |
| M3 P1 Verification Complete | M2、clean manifests | TEST/PROP/COV thresholds关闭，零S0/S1，REQ VERIFIED |
| M4 P1 Release Candidate | M3、release tool/license可用 | clean rebuild、synthesis/PPA、SBOM/BOM、known issues、rollback drill、RC签名 |
| M5 P1 Released | RC soak/approval | signed release bundle发布；claim严格为pinned-PDF experimental |
| M6+ P2/P3/P4 | 相应external/platform gate与新DoR | 分别独立RC/release，不继承P1结论 |

### 11.5 Release BOM、provenance与rollback

canonical `release_manifest.json`必须是closed object，顶层至少required `schema_version,delivery_status=RELEASED,phase_profile_id,delivery_active_variant_set_id,delivery_variants_sha256,build_target_bindings_sha256,artifacts[],global_result_ids[],off_only_target_results[],reference_comparison_results[],variant_comparison_results[],multi_artifact_package_results[]`，并列出/hash：

* source commit、dirty-state policy、post-change tree hash和所有submodule/toolchain commits；
* 两份spec、REQ/spec/phase/capability/architecture/interface/verification/coverage/CI manifests及schema；
* generated Scala/SV/config、active set全部`2N`个off/on delivery artifact、ELF/test binaries、reference model；
* 全部command/bootstrap results、formal/coverage/mutation/synthesis/PPA报告、seed和logs；
* compiler/binutils/header/API资产、兼容矩阵、release notes、known issues；
* tool/container image digests、license清单、SBOM和可信CI provenance；
* closure report、risk acceptance、waiver与detached signatures。

不能只在bundle顶层写一次“支持IME”。`artifacts[]`对所引APPROVED active set的全部`2N`个variant artifact逐项required；首个`ENG-P1-VLEN128-MACHINE` profile另断言`N=2`，因此恰为四项：

```text
config_id, base_config_id, variant_id, record_revision, variant_record_ref, enable_ime,
config_code, variant_code, ime_build_identity_v1_hex,
ime_build_identity_sidecar_sha256,
core_base_build_config_sha256, variant_wrapper_config_sha256,
final_elaboration_config_sha256,
variant_record_sha256, effective_set_sha256, effective_ime_isaext_ids[],
requested_module_name, elaborated_top_module_name,
top_pin_abi_ref, top_pin_abi_sha256,
generated_rtl_sha256, dut_binary_or_netlist_sha256,
capability_manifest_sha256, software_header_sha256,
software_elf_note_object_sha256,
variant_result_ids[],
sbom_sha256, qualification_status, delivery_roles[] subset of {default,rollback,optional-on}
```

bundle顶层另有且只出现一次：

```text
global_result_ids[],
off_only_target_results[]{target_label, base_config_id, variant_record_ref,
                          result_ids[]},
reference_comparison_results[]{config_id, off_variant_id=ime_off_baseline,
                               reference_binding_id, cycle_reference_artifact_id,
                               independent_arch_model_artifact_id:string|null,
                               result_ids[]},
variant_comparison_results[]{config_id,
                             compared_variant_ids=[ime_off_baseline,ime_on_delivery],
                             result_ids[]},
multi_artifact_package_results[]{package_id,target_label,release_scope_id,
                                 input_variant_record_refs[]{minItems=2},
                                 input_comparison_target_labels[],result_ids[]}
```

`ime_build_identity_v1_hex`必须恰为152个小写hex字符，并由release validator用manifest中的codes/flags/digests重组为§4.10的608 bit后逐bit相等；validator还必须通过record payload的base/wrapper hash join重算final config，不能只比identity hex。每项的`requested_module_name/elaborated_top_module_name/top_pin_abi_ref/hash`必须与所引`VariantWrapperConfigV1`和`TopPinAbiV1`逐字段join，off/on同base+revision的pin ref/hash必须相等；actual top introspection结果也必须相等。`ime_build_identity_sidecar_sha256`必须重算自五sidecar集合中的独立`ime_build_identity.json`，不得等于或代替`capability_manifest_sha256`。sidecar、pre-synthesis extraction、generated RTL和binary/netlist hash须形成同一signed chain。每个`variant_result_ids[]`成员的canonical result记录自身`result_kind={build,lint,test,formal,synthesis,ppa,software}`，且只能属于一个tuple；任一binary/netlist、variant record或variant result ID不得被两个tuple复用。每个`OFF_ONLY_TARGET` result ID只允许出现在与其binding完全相同的一条`off_only_target_results[]`记录中，zero missing/extra；它不属于active delivery set，但必须随bundle保存以证明未授权target仍为off。`GLOBAL`、`REFERENCE_COMPARISON`、`VARIANT_COMPARISON`与`MULTI_ARTIFACT_PACKAGE` result只在bundle顶层对应数组引用一次，禁止复制进任一tuple；comparison/package result可引用其input artifact/result ID，但不改变原归属。

release validator以signed closure、APPROVED plan和`delivery_active_variant_set_id`为分母：令`N=len(active_variant_set.config_pairs)`，`artifacts[]`必须恰为`N × {off,on}=2N`，且每个pair逐ref等于active set；首个profile额外断言`N=2`和四artifact。每个applicable `VARIANT` result恰出现一次于对应tuple，每个`OFF_ONLY_TARGET`恰出现一次于对应binding，每个`GLOBAL`恰出现一次于顶层；每个config恰有一条reference-comparison和一条variant-comparison record，每个APPROVED package/bundle target恰有一条multi-artifact record。这些顶层record的非空`result_ids[]`必须与plan内同scope required command集合逐项相等，package inputs必须与signed plan/closure逐项相等。zero missing/extra/duplicate，否则release失败。全部`N`个off artifact必须`enable_ime=false,effective_ime_isaext_ids=[],delivery_roles=[default,rollback]`；全部`N`个on artifact必须`delivery_roles=[optional-on]`且只能列closure实际effective并已验证的extension。toolchain/C API compatibility matrix必须指向具体on artifact，不能把bundle级experimental claim误贴到off artifact。

release manifest是closure完成后的单向release-finalization产物：`ime_release_manifest_gen/test`只读已签名closure与pre-closure release-qualification command results，report/plan不得反向引用release manifest。trusted launcher验证其schema与所有hash后，以release-authority key生成detached `release_attestation.json`；workspace generator不得访问私钥。该finalization不写回closure report，因而不会形成report/release自引用。

P0的`//ime:ime_release_manifest_schema_fixture_test`只用仓库内固定positive/negative fixtures验证上述schema与唯一归属规则，不读取也不生成真实release manifest；`//ime:ime_release_manifest_test`只在trusted finalization/release阶段对实际产物运行。二者的result ID和gate归属不得混用。

reproducibility边界必须可执行且不把签名时间混入DUT结论：两个独立clean checkout按同一tool/container各构建一次，active set每个primary RTL/binary/netlist、五sidecars和software object的SHA-256必须逐项相同；随后使用**同一组已冻结的signed evidence bytes**在两个空bundle root做dry-run assembly，得到相同entries集合和`release_bundle_descriptor_sha256`。dry-run不得重新签名，`signed_at`/envelope bytes不参加两次DUT构建hash比较；任何其它时间戳、随机顺序或host path必须从canonical artifact schema排除并记录理由。最终只对已通过复现检查的唯一descriptor生成一次bundle attestation。

rollback基线永远是同commit的 `ime_off_baseline`：默认capability=false、known IME raw encoding精确illegal、普通RVV regression通过。S0/S1、错误extension exposure、PPA超限或provenance失效触发rollback；release owner切换/撤回IME-on artifact并发布known-good off artifact，随后运行off smoke +完整baseline regression。不得用删除decoder使encoding落入backend discard作为回滚。每次RC至少演练一次enable→rollback→baseline recovery并保存结果。

### 11.6 当前工程评估

本文件经本轮补强后可作为**工程架构设计评审输入**：规范边界、首发产品profile、root requirements、默认off的sealed可配置构建链、base/wrapper/pin/variant/final identity、逻辑模块、P1 FSM/资源/性能模型、reset/CDC/RDC、验证阈值和发布治理已经明确。它仍不是“项目已经完成”或“立即可以无条件写RTL”的证明；§1.3列出的PPA/event/owner/architecture-approval/trusted-execution输入以及实际JSON schemas、完整ID catalog、phase roots和验证计划尚未物化，当前target-universe query仍被未定义`fuchsia_sdk`外部仓库阻断，P4 exact config/target与规范artifact也未获批准。故当前生命周期严格保持 `ARCH_REVIEW_CANDIDATE`；只有M0 DoD及全部适用DoR gate签核后才能升级为 `ARCH_APPROVED`并进入相应P0/P1 implementation，P4继续保持BLOCKED。
