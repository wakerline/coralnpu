# CoralNPU RTL 代码全量阅读顺序指南

> 参考注释风格: Parameters.scala — `// ====` 分段 + `// ----` 子段 + 行内 `//` + `/** */` 方法说明
> 已注释文件: 87 Chisel + 77 Verilog 设计文件

---

## 代码库总览

| 层级 | 目录 | 文件数 | 角色 |
|------|------|--------|------|
| 参数/接口 | `chisel/src/coralnpu/` (顶层) | 22 | Parameters, Interfaces, Fabric, Core... |
| 标量流水线 | `chisel/src/coralnpu/scalar/` | 16 | SCore, Fetch, Decode, ALU, BRU, LSU... |
| 向量+浮点 | `chisel/src/coralnpu/rvv/` + `float/` | 6 | RvvCore, FloatCore |
| RVV Verilog | `verilog/rvv/design/` + `common/` | 58 | 向量执行引擎 Verilog 实现 |
| 总线基础设施 | `chisel/src/bus/` | 19 | AXI, TL-UL, 桥接, CLINT, PLIC, SPI, DMA |
| 通用工具 | `chisel/src/common/` | 18 | FIFO, FMA, 仲裁器, 对齐器, 除法器... |
| SoC 集成 | `chisel/src/soc/` + `peripherals/` | 7 | 芯片顶层, Crossbar, 外设接口 |
| 基础 Verilog | `verilog/` (顶层) | 3 | ClockGate, RstSync, SRAM 行为模型 |

---

## 第一层 (Tier 1): 必读基础 — 理解全局参数和接口

> 目标: 理解处理器配置能力和模块间通信协议。建议 1-2 小时。

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 1 | [Parameters.scala](chisel/src/coralnpu/Parameters.scala) | **全局参数配置** | TCM大小/总线位宽/功能使能开关/EmitParametersHeader反射导出C宏 |
| 2 | [Interfaces.scala](chisel/src/coralnpu/Interfaces.scala) | **全部硬件接口Bundle定义** | IBusIO/DBusIO/EBusIO/FabricIO/DebugIO/CsrIO → 模块间通信词典 |
| 3 | [MemorySize.scala](chisel/src/coralnpu/MemorySize.scala) | 内存大小辅助类 | bytes↔KB/MB 转换 |

**读完这三篇后你能回答:**
- TCM 最大多大？总线多宽？哪些功能可选？
- IBus 和 DBus 的握手协议是什么？
- CSR 信号怎么进出核心？

---

## 第二层 (Tier 2): 核心顶层结构 — 理解模块连接关系

> 目标: 理解 Core → SCore → 各执行单元的层次。建议 2-3 小时。

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 4 | [Core.scala](chisel/src/coralnpu/Core.scala) | **处理器核顶层** + Verilog生成入口 | SCore+RvvCore连接, EmitCore命令行编译流程 |
| 5 | [CoreAxi.scala](chisel/src/coralnpu/CoreAxi.scala) | **AXI总线完整系统顶层** | RstSync→ClockGate→Core, ITCM/DTCM三端口仲裁, ibus双路径, AXI Master/Slave |
| 6 | [CoreTlul.scala](chisel/src/coralnpu/CoreTlul.scala) | Core的TL-UL封装 | Axi2TLUL+TLUL2Axi双桥接 |
| 7 | [SCore.scala](chisel/src/coralnpu/scalar/SCore.scala) | **标量RISC-V核心顶层** | 全部功能单元实例化, DispatchV2发射, 写回仲裁 |
| 8 | [Fabric.scala](chisel/src/coralnpu/Fabric.scala) | **内部SRAM交叉开关** | FabricArbiter(固定优先级)+FabricMux(地址路由+偏移) |

**读懂这层后的关键认知:**
```
CoreAxi (RawModule)
├── RstSync + ClockGate
├── Core
│   ├── SCore (标量核)
│   │   ├── Fetch → Decode/DispatchV2 → ALU/BRU/MLU/DVU/LSU/FPU
│   │   ├── Csr, Regfile, FRegfile
│   │   └── FaultManager, RetirementBuffer
│   └── RvvCore (向量核, 可选)
├── ITCM/DTCM (TCM128 → FabricArbiter 3口)
├── FabricMux (ITCM/DTCM/CSR路由)
├── AxiSlave (外部AXI→Fabric)
├── IBus2Axi + DBus2Axi
└── DebugModule
```

---

## 第三层 (Tier 3): 标量流水线 — 跟踪指令执行全过程

> 目标: 跟踪一条指令从取指到退役的完整路径。建议 3-4 小时。

### 3.1 前端 (Fetch → Decode)

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 9 | [Fetch.scala](chisel/src/coralnpu/scalar/Fetch.scala) | **取指单元 + L0 ICache** | 1KB直接映射, 预译码分支预测, BranchMatchDe/Ex |
| 10 | [UncachedFetch.scala](chisel/src/coralnpu/scalar/UncachedFetch.scala) | 无缓存取指 | enableFetchL0=false时使用 |
| 11 | [Decode.scala](chisel/src/coralnpu/scalar/Decode.scala) | **译码+DispatchV2发射** | RISC-V指令解析, 多lane发射, 寄存器依赖检查 |

### 3.2 执行单元

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 12 | [Alu.scala](chisel/src/coralnpu/scalar/Alu.scala) | ALU | RV32I + Zbb, 单周期, 每lane一个 |
| 13 | [Bru.scala](chisel/src/coralnpu/scalar/Bru.scala) | BRU分支单元 | BEQ/BNE/BLT/JAL/JALR, 每lane一个 |
| 14 | [Mlu.scala](chisel/src/coralnpu/scalar/Mlu.scala) | MLU乘法 | RV32M, 1个MLU共享 |
| 15 | [Dvu.scala](chisel/src/coralnpu/scalar/Dvu.scala) | DVU除法 | 多周期, 仅lane0使用 |
| 16 | [Lsu.scala](chisel/src/coralnpu/scalar/Lsu.scala) | **LSU — 最复杂执行单元** | 标量+向量访存, LsuSlot生命周期, IBUS/DBUS/EXTERNAL三路径 |

### 3.3 控制和状态

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 17 | [Regfile.scala](chisel/src/coralnpu/scalar/Regfile.scala) | 整数寄存器文件 | 32×32-bit, x0恒为0, Scoreboard |
| 18 | [Csr.scala](chisel/src/coralnpu/scalar/Csr.scala) | **CSR单元** | mstatus/mcause/mepc, CSRRW/CSRRS/CSRRC, 中断响应 |
| 19 | [FaultManager.scala](chisel/src/coralnpu/scalar/FaultManager.scala) | 故障管理器 | 异常收集→优先级仲裁→mepc/mtval/mcause |
| 20 | [RetirementBuffer.scala](chisel/src/coralnpu/RetirementBuffer.scala) | **退役缓冲区** | Dispatched→Completed→Retired, 按序提交 |

---

## 第四层 (Tier 4): 存储子系统

> 目标: 理解内核如何访问指令和数据存储。建议 2-3 小时。

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 21 | [TCM.scala](chisel/src/coralnpu/TCM.scala) | **紧耦合内存** | TCM128封装Sram_Nx128, Vec↔UInt转换 |
| 22 | [L1ICache.scala](chisel/src/coralnpu/L1ICache.scala) | **L1指令缓存** | 8KB 4路组相联, CAM查找, 伪LRU替换, AXI填充 |
| 23 | [L1DCache.scala](chisel/src/coralnpu/L1DCache.scala) | L1数据缓存 | 双bank, SEC-DED ECC, Flush状态机 |
| 24 | [DBus2Axi.scala](chisel/src/coralnpu/DBus2Axi.scala) | **DBus→AXI转换** | 三状态机写路径, 读路径RegNext延迟 |
| 25 | [IBus2Axi.scala](chisel/src/coralnpu/IBus2Axi.scala) | IBus→AXI转换 | 单地址缓冲, 地址匹配快速返回 |
| 26 | [AxiSlave.scala](chisel/src/coralnpu/AxiSlave.scala) | **AXI Slave→Fabric** | 突发支持, 读写仲裁, 地址自动递增 |
| 27 | [CoreAxiCSR.scala](chisel/src/coralnpu/CoreAxiCSR.scala) | CSR子系统 | CoreCSR + CoreAxiCSR, 复位/时钟/调试寄存器 |
| 28 | [Sram.scala](chisel/src/coralnpu/Sram.scala) | SRAM BlackBox | SramBlock + Sram_Nx128 多块拼接 |
| 29 | [SRAM.scala](chisel/src/coralnpu/SRAM.scala) | SRAM FabricIO封装 | Fabric协议→SRAM时序 |
| 30 | [SramNx128.scala](chisel/src/coralnpu/SramNx128.scala) | 128-bit SRAM模块 | 参数化深度, 多模块选片 |

**存储层级:**
```
core.ibus → ITCM(1周期) → IBus2Axi → AXI外部(慢)
core.dbus → DTCM(1周期)
core.ebus → DBus2Axi → AXI Master → 外部
```

---

## 第五层 (Tier 5): 向量与浮点

> 目标: 理解 RVV 1.0 向量扩展和 FPU。建议 3-5 小时。

### 5.1 Chisel 封装层

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 31 | [RvvInterface.scala](chisel/src/coralnpu/rvv/RvvInterface.scala) | **RVV核接口定义** | RvvCoreIO/RvvConfigState/Rvv2Lsu/Lsu2Rvv |
| 32 | [RvvCore.scala](chisel/src/coralnpu/rvv/RvvCore.scala) | RVV向量核Chisel封装 | 封装Verilog Backend |
| 33 | [RvvDecode.scala](chisel/src/coralnpu/rvv/RvvDecode.scala) | RVV指令译码 | V扩展→微操作 |
| 34 | [RvvAlu.scala](chisel/src/coralnpu/rvv/RvvAlu.scala) | RVV ALU操作码 | RvvAluOp枚举 |
| 35 | [FloatCoreInterface.scala](chisel/src/coralnpu/float/FloatCoreInterface.scala) | 浮点核心IO | FloatCoreIO |
| 36 | [FloatCore.scala](chisel/src/coralnpu/float/FloatCore.scala) | **浮点执行单元** | FP32 FMA+Div+Sqrt, PULP/E906选择 |
| 37 | [Fpu.scala](chisel/src/coralnpu/scalar/Fpu.scala) | 标量FPU | 与FRegfile+FloatCore交互 |
| 38 | [FRegfile.scala](chisel/src/coralnpu/scalar/FRegfile.scala) | 浮点寄存器文件 | 32×FP32, 多读多写, Scoreboard |

### 5.2 Verilog RVV 后端 (按数据流)

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 39 | [RvvCore.sv](verilog/rvv/design/RvvCore.sv) | **RVV顶层** | FrontEnd+Backend实例化 |
| 40 | [RvvFrontEnd.sv](verilog/rvv/design/RvvFrontEnd.sv) | RVV前端 | 指令缓冲+预译码 |
| 41 | [rvv_backend_decode.sv](verilog/rvv/design/rvv_backend_decode.sv) | 向量译码 | uOP生成 |
| 42 | [rvv_backend_dispatch.sv](verilog/rvv/design/rvv_backend_dispatch.sv) | 向量发射 | 重命名+结构冒险 |
| 43 | [rvv_backend_rob.sv](verilog/rvv/design/rvv_backend_rob.sv) | 重排序缓冲 | 乱序执行窗口 |
| 44 | [rvv_backend_alu.sv](verilog/rvv/design/rvv_backend_alu.sv) | 向量ALU | 例化子ALU |
| 45 | [rvv_backend_mulmac.sv](verilog/rvv/design/rvv_backend_mulmac.sv) | 乘法/乘累加 | MAC单元 |
| 46 | [rvv_backend_div.sv](verilog/rvv/design/rvv_backend_div.sv) | 向量除法 | |
| 47 | [rvv_backend_fma.sv](verilog/rvv/design/rvv_backend_fma.sv) | 向量FMA | 融合乘加 |
| 48 | [rvv_backend_lsu_remap.sv](verilog/rvv/design/rvv_backend_lsu_remap.sv) | LSU地址重映射 | Scatter/Gather |
| 49 | [rvv_backend_vrf.sv](verilog/rvv/design/rvv_backend_vrf.sv) | 向量寄存器文件 | 128-bit×32 |
| 50 | [rvv_backend_retire.sv](verilog/rvv/design/rvv_backend_retire.sv) | 向量退役 | 按序提交+写回 |
| 51 | [rvv_backend_arb.sv](verilog/rvv/design/rvv_backend_arb.sv) | 后端仲裁 | 执行→写回 |

**RVV 后端流水线:**
```
RvvFrontEnd → Decode → Dispatch(重命名/发射) → ROB → ALU/MUL/DIV/LSU/FMA/PMTRDT
                                                   ↓
                                                Retire(按序) → VRF写回
```

### 5.3 Verilog RVV 通用组件 (基础构建块)

| 序号 | 文件(verilog/rvv/common/) | 功能 |
|------|---------------------------|------|
| 52 | adder.sv | 多宽度加法器 (8/16/32/64/128-bit) |
| 53 | barrel_shifter.sv | 桶形移位器 |
| 54 | compressor_3_2.sv | 3:2压缩器 (CSA) |
| 55 | compressor_4_2.sv | 4:2压缩器 (Wallace Tree) |
| 56 | arb_round_robin.sv | Round-Robin仲裁器 |
| 57 | fifo_flopped.sv | 触发器FIFO (1w1r) |
| 58 | handshake_ff.sv | 握手触发器 |
| 59 | multi_fifo.sv | 多通道FIFO |
| 60 | Aligner.sv + MultiFifo.sv | 数据对齐 + 多通道FIFO (design目录) |

### 5.4 Verilog RVV 子单元 (按需查阅)

| 文件前缀(rvv_backend_) | 功能分组 |
|------------------------|----------|
| alu_unit_*.sv (6个) | ALU子单元: addsub/execution/mask/shift/other |
| decode_unit_*.sv (6个) | 译码子单元: ari/lsu/de2 |
| dispatch_*.sv (6个) | 发射子单元: bypass/ctrl/operand/hazard |
| div_unit_*.sv (2个) | 除法子单元: divider |
| mul_unit_*.sv (2个) | 乘法子单元: mul8 |
| pmtrdt_unit_*.sv (3个) | 置换/归约子单元 |
| retire_waw.sv | WAW冒险处理 |
| sqrt7_rec7.sv | 平方根 |
| vrf_reg.sv | VRF寄存器 |
| fdiv_wrapper.sv / fma_wrapper.sv / freduction.sv | 浮点包装 |

---

## 第六层 (Tier 6): 总线基础设施

> 目标: 理解芯片的总线互联架构。建议 2-3 小时。

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 61 | [Axi.scala](chisel/src/bus/Axi.scala) | **AXI4 Bundle定义** | 5通道 + AxiResponseType |
| 62 | [TileLinkUL.scala](chisel/src/bus/TileLinkUL.scala) | **TL-UL Bundle定义** | OpenTitan标准 |
| 63 | [Axi2TLUL.scala](chisel/src/bus/Axi2TLUL.scala) | AXI→TL-UL桥 | 协议转换 |
| 64 | [TLUL2Axi.scala](chisel/src/bus/TLUL2Axi.scala) | TL-UL→AXI桥 | 协议转换 |
| 65 | [Clint.scala](chisel/src/bus/Clint.scala) | CLINT | timer+software中断 |
| 66 | [Plic.scala](chisel/src/bus/Plic.scala) | PLIC | 外部中断仲裁 |
| 67 | [DmaEngine.scala](chisel/src/bus/DmaEngine.scala) | DMA引擎 | 内存到内存搬运 |
| 68 | [GPIO.scala](chisel/src/bus/GPIO.scala) | GPIO控制器 | |
| 69 | [SpiMaster.scala](chisel/src/bus/SpiMaster.scala) + [Spi2TLUL.scala](chisel/src/bus/Spi2TLUL.scala) + [Spi2TLULV2.scala](chisel/src/bus/Spi2TLULV2.scala) | SPI控制器+桥 | 3个文件 |
| 70 | [TlulFifoAsync.scala](chisel/src/bus/TlulFifoAsync.scala) + [TlulFifoSync.scala](chisel/src/bus/TlulFifoSync.scala) | TL-UL FIFO | 异步/同步 |
| 71 | [TlulSocket1N.scala](chisel/src/bus/TlulSocket1N.scala) + [TlulSocketM1.scala](chisel/src/bus/TlulSocketM1.scala) | TL-UL Socket | 1:N分发 + M:1汇聚 |
| 72 | [TlulWidthBridge.scala](chisel/src/bus/TlulWidthBridge.scala) | TL-UL位宽桥接 | 不同位宽转换 |
| 73 | [TlulIntegrity.scala](chisel/src/bus/TlulIntegrity.scala) | TL-UL完整性 | ECC保护 |
| 74 | [TlulIdRemapper.scala](chisel/src/bus/TlulIdRemapper.scala) | TL-UL ID重映射 | |
| 75 | [TlulToSram.scala](chisel/src/bus/TlulToSram.scala) | TL-UL→SRAM | 总线→存储 |

---

## 第七层 (Tier 7): SoC 集成 + 调试

> 目标: 理解完整 SoC 芯片结构。建议 1-2 小时。

| 序号 | 文件 | 一句话 | 关键看点 |
|------|------|--------|----------|
| 76 | [SoCChiselConfig.scala](chisel/src/soc/SoCChiselConfig.scala) | **SoC全局配置** | 外设地址映射/中断分配/端口定义 |
| 77 | [CoralNPUChiselSubsystem.scala](chisel/src/soc/CoralNPUChiselSubsystem.scala) | **CoralNPU子系统** | Core+Crossbar+外设 |
| 78 | [CoralNPUXbar.scala](chisel/src/soc/CoralNPUXbar.scala) | 交叉开关矩阵 | TL-UL多主多从 |
| 79 | [CrossbarConfig.scala](chisel/src/soc/CrossbarConfig.scala) | Crossbar配置 | |
| 80 | [SoCRecords.scala](chisel/src/soc/SoCRecords.scala) | SoC记录类型 | DataRecord+TLBundleMap |
| 81 | [TlulSram.scala](chisel/src/soc/TlulSram.scala) | SoC级SRAM | |
| 82 | [PeripheralInterface.scala](chisel/src/peripherals/PeripheralInterface.scala) | 外设接口 | 通用Bundle |
| 83 | [Debug.scala](chisel/src/coralnpu/scalar/Debug.scala) | **调试模块** | Debug Module Spec 0.13 |
| 84 | [RvviTrace.scala](chisel/src/coralnpu/RvviTrace.scala) | RVVI验证跟踪 | 退役→RVVI格式 |

---

## 第八层 (Tier 8): 通用工具 — 按需查阅

| 文件 | 功能 | 被谁使用 |
|------|------|----------|
| [Fifo.scala](chisel/src/common/Fifo.scala) | 标准同步FIFO | 流水线缓冲 |
| [FifoX.scala](chisel/src/common/FifoX.scala) + [FifoXe.scala](chisel/src/common/FifoXe.scala) + [FifoIxO.scala](chisel/src/common/FifoIxO.scala) + [FIFOState.scala](chisel/src/common/FIFOState.scala) | FIFO变体 | 多种场景 |
| [CircularBufferMulti.scala](chisel/src/common/CircularBufferMulti.scala) | 多读者环形缓冲 | RetirementBuffer |
| [CoralNPUArbiter.scala](chisel/src/common/CoralNPUArbiter.scala) | Round-Robin仲裁 | CoreAxi, AxiSlave |
| [Fma.scala](chisel/src/common/Fma.scala) | FP32 FMA | FloatCore |
| [Fp.scala](chisel/src/common/Fp.scala) | FP32编解码 | FloatCore, FRegfile |
| [IDiv.scala](chisel/src/common/IDiv.scala) | 整数除法器 | Dvu |
| [Aligner.scala](chisel/src/common/Aligner.scala) | 数据对齐 | LSU, RVV LSU |
| [ScatterGather.scala](chisel/src/common/ScatterGather.scala) | 向量分散/聚集 | LSU |
| [Slice.scala](chisel/src/common/Slice.scala) | 位切片 | Fetch(L0 ICache) |
| [InstructionBuffer.scala](chisel/src/common/InstructionBuffer.scala) | 指令缓冲 | Fetch→Decode |
| [IndexAllocator.scala](chisel/src/common/IndexAllocator.scala) | 索引分配 | ROB槽位管理 |
| [MathUtil.scala](chisel/src/common/MathUtil.scala) | 数学工具 | 全局 |
| [Library.scala](chisel/src/common/Library.scala) + [Library.scala](chisel/src/coralnpu/Library.scala) | 硬件原语库 | 全局 |
| [SvGenerationUtils.scala](chisel/src/common/SvGenerationUtils.scala) | SV生成 | RvviTrace等 |
| [ClockGate.scala](chisel/src/coralnpu/ClockGate.scala) + [RstSync.scala](chisel/src/coralnpu/RstSync.scala) | 时钟/复位 | CoreAxi |
| [ClockGate.sv](verilog/ClockGate.sv) + [RstSync.sv](verilog/RstSync.sv) + [Sram.v](verilog/Sram.v) | 基础Verilog | BlackBox关联 |

---

## 按角色推荐路径

### 🟢 硬件架构师 (理解整体)
1→2→4→5→7→8→61→62→76→77 (10个文件, ~3小时)

### 🔵 RTL 设计工程师 (理解流水线)
1→2→4→7→9→11→12→13→14→15→16→17→18→20 (14个文件, ~5小时)

### 🟡 验证工程师 (理解接口和调试)
1→2→4→5→19→20→83→84→24→25→26 (11个文件, ~3小时)

### 🟣 SoC 集成工程师 (理解总线)
1→2→4→5→8→24→25→26→61→62→63→64→65→66→76→77 (16个文件, ~4小时)

---

## 阅读技巧

1. **先看 IO, 再看逻辑**: 每个文件找到 `val io = IO(new Bundle {...})` 块
2. **跟踪数据流**: Fetch→Decode→Execute→LSU→Writeback
3. **注意 `<>` 操作符**: Chisel 中 `a <> b` = 双向 Bulk Connect
4. **关注条件编译**: `Option.when(p.enableRvv)(...)` 和 `if (p.enableFloat)`
5. **先 Chisel 后 Verilog**: Chisel 是设计主源码, Verilog RVV 后端是第三方 IP 集成
6. **dummy → "空"**: 注释中 dummy register 统一翻译为"空寄存器"

---

*文件总数: 164 个设计文件 (87 Chisel + 77 Verilog)*
*注释风格参考: Parameters.scala*
*所有文件均以 `// ====` 头部 + `// ----` 子段 + 行内 `//` 方式注释*
