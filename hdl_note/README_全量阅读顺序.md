# CoralNPU RTL 全量代码阅读顺序

> 164 个设计文件 (87 Chisel + 77 Verilog)，按 8 层渐进式排列。
> 每层内按数据流/依赖关系排序，先读依赖项再读使用者。

---

## 第一层：全局参数与接口 (3 文件, ~1h)

> 所有模块的"词典"和"控制面板"，必须先读。

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 1 | [Parameters.scala](chisel/src/coralnpu/Parameters.scala) | 全局参数配置 + C 头文件生成 | 无 |
| 2 | [Interfaces.scala](chisel/src/coralnpu/Interfaces.scala) | 全部硬件接口 Bundle 定义 | Parameters |
| 3 | [MemorySize.scala](chisel/src/coralnpu/MemorySize.scala) | 内存大小辅助类 | 无 |

---

## 第二层：核心顶层结构 (6 文件, ~2h)

> 理解 Core → SCore 的层次和模块连接。

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 4 | [Core.scala](chisel/src/coralnpu/Core.scala) | 处理器核顶层 + EmitCore | Parameters, Interfaces |
| 5 | [SCore.scala](chisel/src/coralnpu/scalar/SCore.scala) | 标量核心顶层 | Parameters, Interfaces |
| 6 | [CoreAxi.scala](chisel/src/coralnpu/CoreAxi.scala) | AXI 总线完整系统 | Core, TCM, DBus2Axi, IBus2Axi |
| 7 | [CoreTlul.scala](chisel/src/coralnpu/CoreTlul.scala) | TL-UL 总线封装 | CoreAxi, Axi2TLUL, TLUL2Axi |
| 8 | [Fabric.scala](chisel/src/coralnpu/Fabric.scala) | 内部 SRAM 交叉开关 | Parameters, Interfaces |
| 9 | [CoreAxiCSR.scala](chisel/src/coralnpu/CoreAxiCSR.scala) | CSR 子系统 | Parameters, Fabric |

---

## 第三层：标量流水线前端 (4 文件, ~1.5h)

> 取指 → 译码 → 发射。

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 10 | [Fetch.scala](chisel/src/coralnpu/scalar/Fetch.scala) | 取指单元 + L0 ICache | Parameters, Interfaces |
| 11 | [UncachedFetch.scala](chisel/src/coralnpu/scalar/UncachedFetch.scala) | 无缓存取指 (备用) | Parameters, Interfaces |
| 12 | [Decode.scala](chisel/src/coralnpu/scalar/Decode.scala) | 译码 + DispatchV2 发射 | Parameters, RvvInterface |
| 13 | [InstructionBuffer.scala](chisel/src/common/InstructionBuffer.scala) | 指令缓冲 + CircularBuffer | 无 |

---

## 第四层：标量执行单元 (7 文件, ~2h)

> ALU / BRU / MLU / DVU / LSU / FPU。

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 14 | [Alu.scala](chisel/src/coralnpu/scalar/Alu.scala) | 算术逻辑单元 | Parameters |
| 15 | [Bru.scala](chisel/src/coralnpu/scalar/Bru.scala) | 分支解析单元 | Parameters |
| 16 | [Mlu.scala](chisel/src/coralnpu/scalar/Mlu.scala) | 乘法单元 | Parameters |
| 17 | [Dvu.scala](chisel/src/coralnpu/scalar/Dvu.scala) | 除法单元 | Parameters, IDiv |
| 18 | [Lsu.scala](chisel/src/coralnpu/scalar/Lsu.scala) | Load/Store 单元 | Parameters, RvvInterface, ScatterGather, Aligner |
| 19 | [Fpu.scala](chisel/src/coralnpu/scalar/Fpu.scala) | 标量浮点单元 | Parameters, Fma, Fp, FloatCore |
| 20 | [Regfile.scala](chisel/src/coralnpu/scalar/Regfile.scala) | 整数寄存器文件 | Parameters |

---

## 第五层：控制与状态 (4 文件, ~1.5h)

> CSR、异常、调试、退役。

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 21 | [Csr.scala](chisel/src/coralnpu/scalar/Csr.scala) | 控制状态寄存器单元 | Parameters |
| 22 | [FaultManager.scala](chisel/src/coralnpu/scalar/FaultManager.scala) | 故障管理器 | Parameters |
| 23 | [RetirementBuffer.scala](chisel/src/coralnpu/RetirementBuffer.scala) | 指令退役缓冲区 | Parameters, CircularBufferMulti |
| 24 | [Debug.scala](chisel/src/coralnpu/scalar/Debug.scala) | RISC-V 调试模块 | Parameters, Fabric |

---

## 第六层：存储子系统 (11 文件, ~3h)

> TCM、Cache、SRAM、总线适配。

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 25 | [TCM.scala](chisel/src/coralnpu/TCM.scala) | 紧耦合内存 | SramNx128 |
| 26 | [SramNx128.scala](chisel/src/coralnpu/SramNx128.scala) | 128-bit SRAM 模块 | Sram |
| 27 | [Sram.scala](chisel/src/coralnpu/Sram.scala) | SRAM BlackBox 封装 | Interfaces |
| 28 | [SRAM.scala](chisel/src/coralnpu/SRAM.scala) | SRAM FabricIO 封装 | Fabric |
| 29 | [L1ICache.scala](chisel/src/coralnpu/L1ICache.scala) | L1 指令缓存 | Parameters |
| 30 | [L1DCache.scala](chisel/src/coralnpu/L1DCache.scala) | L1 数据缓存 | Parameters |
| 31 | [DBus2Axi.scala](chisel/src/coralnpu/DBus2Axi.scala) | DBus → AXI 转换 | Parameters, bus/Axi |
| 32 | [IBus2Axi.scala](chisel/src/coralnpu/IBus2Axi.scala) | IBus → AXI 转换 | Parameters, bus/Axi |
| 33 | [AxiSlave.scala](chisel/src/coralnpu/AxiSlave.scala) | AXI Slave → Fabric | Parameters, Fabric, bus/Axi |
| 34 | [FRegfile.scala](chisel/src/coralnpu/scalar/FRegfile.scala) | 浮点寄存器文件 | Fp |
| 35 | [RvviTrace.scala](chisel/src/coralnpu/RvviTrace.scala) | RVVI 验证跟踪 | RetirementBuffer |

---

## 第七层：向量与浮点扩展 (6 Chisel + 58 Verilog, ~5h)

### 7.1 Chisel 封装层 (6 文件)

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 36 | [RvvInterface.scala](chisel/src/coralnpu/rvv/RvvInterface.scala) | RVV 核接口定义 | Parameters |
| 37 | [RvvCore.scala](chisel/src/coralnpu/rvv/RvvCore.scala) | RVV 向量核 Chisel 封装 | RvvInterface |
| 38 | [RvvDecode.scala](chisel/src/coralnpu/rvv/RvvDecode.scala) | RVV 指令译码 | RvvInterface |
| 39 | [RvvAlu.scala](chisel/src/coralnpu/rvv/RvvAlu.scala) | RVV ALU 操作码枚举 | 无 |
| 40 | [FloatCoreInterface.scala](chisel/src/coralnpu/float/FloatCoreInterface.scala) | 浮点核心 IO | Parameters |
| 41 | [FloatCore.scala](chisel/src/coralnpu/float/FloatCore.scala) | 浮点执行单元 | Fma, Fp, FloatCoreInterface |

### 7.2 Verilog RVV 顶层 + 前端 (3 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 42 | [RvvCore.sv](verilog/rvv/design/RvvCore.sv) | RVV 向量核心顶层 |
| 43 | [RvvFrontEnd.sv](verilog/rvv/design/RvvFrontEnd.sv) | RVV 前端 (指令缓冲+预译码) |
| 44 | [rvv_backend.sv](verilog/rvv/design/rvv_backend.sv) | RVV 后端顶层 |

### 7.3 Verilog RVV 译码+发射 (8 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 45 | [rvv_backend_decode.sv](verilog/rvv/design/rvv_backend_decode.sv) | 向量指令译码 |
| 46 | [rvv_backend_decode_ctrl.sv](verilog/rvv/design/rvv_backend_decode_ctrl.sv) | 译码控制 |
| 47 | [rvv_backend_decode_de2.sv](verilog/rvv/design/rvv_backend_decode_de2.sv) | 译码第二级 |
| 48 | [rvv_backend_decode_unit.sv](verilog/rvv/design/rvv_backend_decode_unit.sv) | 译码子单元 |
| 49 | [rvv_backend_decode_unit_ari.sv](verilog/rvv/design/rvv_backend_decode_unit_ari.sv) | 算术译码 |
| 50 | [rvv_backend_decode_unit_ari_de2.sv](verilog/rvv/design/rvv_backend_decode_unit_ari_de2.sv) | 算术译码第二级 |
| 51 | [rvv_backend_decode_unit_lsu.sv](verilog/rvv/design/rvv_backend_decode_unit_lsu.sv) | LSU 译码 |
| 52 | [rvv_backend_decode_unit_lsu_de2.sv](verilog/rvv/design/rvv_backend_decode_unit_lsu_de2.sv) | LSU 译码第二级 |

### 7.4 Verilog RVV 发射+ROB (8 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 53 | [rvv_backend_dispatch.sv](verilog/rvv/design/rvv_backend_dispatch.sv) | 向量微操作发射 |
| 54 | [rvv_backend_dispatch_bypass.sv](verilog/rvv/design/rvv_backend_dispatch_bypass.sv) | 发射旁路 |
| 55 | [rvv_backend_dispatch_ctrl.sv](verilog/rvv/design/rvv_backend_dispatch_ctrl.sv) | 发射控制 |
| 56 | [rvv_backend_dispatch_operand.sv](verilog/rvv/design/rvv_backend_dispatch_operand.sv) | 操作数发射 |
| 57 | [rvv_backend_dispatch_opr_byte_type.sv](verilog/rvv/design/rvv_backend_dispatch_opr_byte_type.sv) | 字节类型 |
| 58 | [rvv_backend_dispatch_raw_uop_rob.sv](verilog/rvv/design/rvv_backend_dispatch_raw_uop_rob.sv) | RAW→ROB |
| 59 | [rvv_backend_dispatch_raw_uop_uop.sv](verilog/rvv/design/rvv_backend_dispatch_raw_uop_uop.sv) | RAW→uOP |
| 60 | [rvv_backend_dispatch_structure_hazard.sv](verilog/rvv/design/rvv_backend_dispatch_structure_hazard.sv) | 结构冒险 |

### 7.5 Verilog RVV 执行单元 (15 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 61 | [rvv_backend_alu.sv](verilog/rvv/design/rvv_backend_alu.sv) | 向量 ALU 顶层 |
| 62 | [rvv_backend_alu_unit.sv](verilog/rvv/design/rvv_backend_alu_unit.sv) | ALU 子单元 |
| 63 | [rvv_backend_alu_unit_addsub.sv](verilog/rvv/design/rvv_backend_alu_unit_addsub.sv) | 加减法 |
| 64 | [rvv_backend_alu_unit_execution_p1.sv](verilog/rvv/design/rvv_backend_alu_unit_execution_p1.sv) | 执行阶段1 |
| 65 | [rvv_backend_alu_unit_mask.sv](verilog/rvv/design/rvv_backend_alu_unit_mask.sv) | 掩码操作 |
| 66 | [rvv_backend_alu_unit_mask_viota.sv](verilog/rvv/design/rvv_backend_alu_unit_mask_viota.sv) | viota 掩码 |
| 67 | [rvv_backend_alu_unit_other.sv](verilog/rvv/design/rvv_backend_alu_unit_other.sv) | 其他操作 |
| 68 | [rvv_backend_alu_unit_shift.sv](verilog/rvv/design/rvv_backend_alu_unit_shift.sv) | 移位操作 |
| 69 | [rvv_backend_mulmac.sv](verilog/rvv/design/rvv_backend_mulmac.sv) | 乘法/乘累加 |
| 70 | [rvv_backend_mac_unit.sv](verilog/rvv/design/rvv_backend_mac_unit.sv) | MAC 单元 |
| 71 | [rvv_backend_mul_unit.sv](verilog/rvv/design/rvv_backend_mul_unit.sv) | 乘法单元 |
| 72 | [rvv_backend_mul_unit_mul8.sv](verilog/rvv/design/rvv_backend_mul_unit_mul8.sv) | 8位乘法 |
| 73 | [rvv_backend_div.sv](verilog/rvv/design/rvv_backend_div.sv) | 向量除法 |
| 74 | [rvv_backend_div_unit.sv](verilog/rvv/design/rvv_backend_div_unit.sv) | 除法子单元 |
| 75 | [rvv_backend_div_unit_divider.sv](verilog/rvv/design/rvv_backend_div_unit_divider.sv) | 除法器 |

### 7.6 Verilog RVV FMA+浮点 (5 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 76 | [rvv_backend_fma.sv](verilog/rvv/design/rvv_backend_fma.sv) | 向量 FMA |
| 77 | [rvv_backend_fma_wrapper.sv](verilog/rvv/design/rvv_backend_fma_wrapper.sv) | FMA 包装器 |
| 78 | [rvv_backend_fdiv_wrapper.sv](verilog/rvv/design/rvv_backend_fdiv_wrapper.sv) | 浮点除法包装器 |
| 79 | [rvv_backend_freduction.sv](verilog/rvv/design/rvv_backend_freduction.sv) | 浮点归约 |
| 80 | [rvv_backend_sqrt7_rec7.sv](verilog/rvv/design/rvv_backend_sqrt7_rec7.sv) | 平方根 (7周期) |

### 7.7 Verilog RVV 存储+置换+退役 (11 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 81 | [rvv_backend_lsu_remap.sv](verilog/rvv/design/rvv_backend_lsu_remap.sv) | LSU 地址重映射 |
| 82 | [rvv_backend_pmtrdt.sv](verilog/rvv/design/rvv_backend_pmtrdt.sv) | 置换/归约顶层 |
| 83 | [rvv_backend_pmtrdt_unit.sv](verilog/rvv/design/rvv_backend_pmtrdt_unit.sv) | 置换归约单元 |
| 84 | [rvv_backend_pmtrdt_unit_permutation.sv](verilog/rvv/design/rvv_backend_pmtrdt_unit_permutation.sv) | 置换子单元 |
| 85 | [rvv_backend_pmtrdt_unit_reduction.sv](verilog/rvv/design/rvv_backend_pmtrdt_unit_reduction.sv) | 归约子单元 |
| 86 | [rvv_backend_pmtrdt_unit_reduction_alu.sv](verilog/rvv/design/rvv_backend_pmtrdt_unit_reduction_alu.sv) | 归约 ALU |
| 87 | [rvv_backend_retire.sv](verilog/rvv/design/rvv_backend_retire.sv) | 向量指令退役 |
| 88 | [rvv_backend_retire_waw.sv](verilog/rvv/design/rvv_backend_retire_waw.sv) | WAW 冒险处理 |
| 89 | [rvv_backend_rob.sv](verilog/rvv/design/rvv_backend_rob.sv) | 重排序缓冲 |
| 90 | [rvv_backend_vrf.sv](verilog/rvv/design/rvv_backend_vrf.sv) | 向量寄存器文件 |
| 91 | [rvv_backend_vrf_reg.sv](verilog/rvv/design/rvv_backend_vrf_reg.sv) | VRF 寄存器 |

### 7.8 Verilog RVV 其他 (3 文件)

| 序 | 文件 | 作用 |
|----|------|------|
| 92 | [rvv_backend_arb.sv](verilog/rvv/design/rvv_backend_arb.sv) | 后端仲裁器 |
| 93 | [Aligner.sv](verilog/rvv/design/Aligner.sv) | 数据对齐器 |
| 94 | [MultiFifo.sv](verilog/rvv/design/MultiFifo.sv) | 多通道 FIFO |

### 7.9 Verilog RVV 通用组件 (16 文件)

| 序 | 文件(verilog/rvv/common/) | 作用 |
|----|---------------------------|------|
| 95 | adder.sv | 多宽度加法器 |
| 96 | barrel_shifter.sv | 桶形移位器 |
| 97 | compressor_3_2.sv | 3:2 压缩器 (CSA) |
| 98 | compressor_4_2.sv | 4:2 压缩器 (Wallace) |
| 99 | arb_round_robin.sv | Round-Robin 仲裁器 |
| 100 | cdffr.sv | 带使能+复位 DFF |
| 101 | dff.sv | 基础 DFF |
| 102 | edff.sv | 带使能 DFF |
| 103 | edff_2d.sv | 双使能 DFF (2周期) |
| 104 | fifo_flopped.sv | 触发器 FIFO (1w1r) |
| 105 | fifo_flopped_2w2r.sv | 触发器 FIFO (2w2r) |
| 106 | fifo_flopped_4w2r.sv | 触发器 FIFO (4w2r) |
| 107 | handshake_ff.sv | 握手触发器 |
| 108 | handshake_multi_fifo.sv | 多通道握手 FIFO |
| 109 | multi_fifo.sv | 多通道 FIFO |
| 110 | openFifo4_flopped_ptr.sv | 开放 FIFO (深度4) |
| 111 | openFifo8_flopped_2w2r.sv | 开放 FIFO (深度8, 2w2r) |

---

## 第八层：总线基础设施 (19 文件, ~3h)

### 8.1 总线协议定义

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 112 | [Axi.scala](chisel/src/bus/Axi.scala) | AXI4 Bundle 定义 | 无 |
| 113 | [TileLinkUL.scala](chisel/src/bus/TileLinkUL.scala) | TL-UL Bundle 定义 | Parameters |

### 8.2 协议桥接

| 序 | 文件 | 作用 | 依赖 |
|----|------|------|------|
| 114 | [Axi2TLUL.scala](chisel/src/bus/Axi2TLUL.scala) | AXI → TL-UL | Axi, TileLinkUL |
| 115 | [TLUL2Axi.scala](chisel/src/bus/TLUL2Axi.scala) | TL-UL → AXI | Axi, TileLinkUL |

### 8.3 TL-UL 基础设施

| 序 | 文件 | 作用 |
|----|------|------|
| 116 | [TlulFifoAsync.scala](chisel/src/bus/TlulFifoAsync.scala) | TL-UL 异步 FIFO |
| 117 | [TlulFifoSync.scala](chisel/src/bus/TlulFifoSync.scala) | TL-UL 同步 FIFO |
| 118 | [TlulSocket1N.scala](chisel/src/bus/TlulSocket1N.scala) | 1:N 分发器 |
| 119 | [TlulSocketM1.scala](chisel/src/bus/TlulSocketM1.scala) | M:1 汇聚器 |
| 120 | [TlulWidthBridge.scala](chisel/src/bus/TlulWidthBridge.scala) | 位宽桥接 |
| 121 | [TlulIntegrity.scala](chisel/src/bus/TlulIntegrity.scala) | 完整性校验 |
| 122 | [TlulIdRemapper.scala](chisel/src/bus/TlulIdRemapper.scala) | ID 重映射 |
| 123 | [TlulToSram.scala](chisel/src/bus/TlulToSram.scala) | TL-UL → SRAM |

### 8.4 外设控制器

| 序 | 文件 | 作用 |
|----|------|------|
| 124 | [Clint.scala](chisel/src/bus/Clint.scala) | CLINT 中断控制器 |
| 125 | [Plic.scala](chisel/src/bus/Plic.scala) | PLIC 平台中断 |
| 126 | [GPIO.scala](chisel/src/bus/GPIO.scala) | GPIO 控制器 |
| 127 | [DmaEngine.scala](chisel/src/bus/DmaEngine.scala) | DMA 引擎 |
| 128 | [SpiMaster.scala](chisel/src/bus/SpiMaster.scala) | SPI Master |
| 129 | [Spi2TLUL.scala](chisel/src/bus/Spi2TLUL.scala) | SPI → TL-UL v1 |
| 130 | [Spi2TLULV2.scala](chisel/src/bus/Spi2TLULV2.scala) | SPI → TL-UL v2 |

---

## 第九层：通用工具库 (18 文件, ~2h)

| 序 | 文件 | 作用 | 被谁用 |
|----|------|------|--------|
| 131 | [Fifo.scala](chisel/src/common/Fifo.scala) | 标准同步 FIFO | 全局 |
| 132 | [FifoX.scala](chisel/src/common/FifoX.scala) | 可扩展 FIFO | 全局 |
| 133 | [FifoXe.scala](chisel/src/common/FifoXe.scala) | 可扩展 FIFO(带错误) | 全局 |
| 134 | [FifoIxO.scala](chisel/src/common/FifoIxO.scala) | I入X出 FIFO | 全局 |
| 135 | [FIFOState.scala](chisel/src/common/FIFOState.scala) | FIFO 状态跟踪 | 全局 |
| 136 | [CircularBufferMulti.scala](chisel/src/common/CircularBufferMulti.scala) | 多读者环形缓冲 | RetBuf, InstBuf |
| 137 | [CoralNPUArbiter.scala](chisel/src/common/CoralNPUArbiter.scala) | Round-Robin 仲裁 | CoreAxi, AxiSlave |
| 138 | [Fma.scala](chisel/src/common/Fma.scala) | FP32 融合乘加 | FloatCore |
| 139 | [Fp.scala](chisel/src/common/Fp.scala) | FP32 编解码 | FloatCore, FRegfile |
| 140 | [IDiv.scala](chisel/src/common/IDiv.scala) | 整数除法器 | Dvu |
| 141 | [Aligner.scala](chisel/src/common/Aligner.scala) | 数据对齐 | LSU, RVV |
| 142 | [ScatterGather.scala](chisel/src/common/ScatterGather.scala) | 向量分散/聚集 | LSU |
| 143 | [Slice.scala](chisel/src/common/Slice.scala) | 位切片 | Fetch, LSU |
| 144 | [IndexAllocator.scala](chisel/src/common/IndexAllocator.scala) | 索引分配器 | ROB |
| 145 | [MathUtil.scala](chisel/src/common/MathUtil.scala) | 数学工具 | 全局 |
| 146 | [Library.scala](chisel/src/common/Library.scala) | 通用硬件库 | 全局 |
| 147 | [SvGenerationUtils.scala](chisel/src/common/SvGenerationUtils.scala) | SV 生成工具 | RvviTrace |
| 148 | [Library.scala](chisel/src/coralnpu/Library.scala) | CoralNPU 专用库 | 全局 |

---

## 第十层：SoC 集成 + 基础 Verilog (10 文件, ~1.5h)

| 序 | 文件 | 作用 |
|----|------|------|
| 149 | [SoCChiselConfig.scala](chisel/src/soc/SoCChiselConfig.scala) | SoC 全局配置 |
| 150 | [CrossbarConfig.scala](chisel/src/soc/CrossbarConfig.scala) | Crossbar 配置 |
| 151 | [CoralNPUXbar.scala](chisel/src/soc/CoralNPUXbar.scala) | Crossbar 矩阵 |
| 152 | [SoCRecords.scala](chisel/src/soc/SoCRecords.scala) | SoC 记录类型 |
| 153 | [TlulSram.scala](chisel/src/soc/TlulSram.scala) | SoC 级 SRAM |
| 154 | [CoralNPUChiselSubsystem.scala](chisel/src/soc/CoralNPUChiselSubsystem.scala) | CoralNPU 芯片子系统 |
| 155 | [PeripheralInterface.scala](chisel/src/peripherals/PeripheralInterface.scala) | 外设接口定义 |
| 156 | [ClockGate.sv](verilog/ClockGate.sv) | 时钟门控 |
| 157 | [RstSync.sv](verilog/RstSync.sv) | 复位同步器 |
| 158 | [Sram.v](verilog/Sram.v) | SRAM 行为模型 |
| 159 | [ClockGate.scala](chisel/src/coralnpu/ClockGate.scala) | 时钟门控 Chisel 封装 |
| 160 | [RstSync.scala](chisel/src/coralnpu/RstSync.scala) | 复位同步 Chisel 封装 |
| 161 | [Sram_1rw_256x256.v](verilog/Sram_1rw_256x256.v) | 256×256 SRAM 实例 |
| 162 | [Sram_1rwm_256x288.v](verilog/Sram_1rwm_256x288.v) | 256×288 带掩码 SRAM |

---

## 按角色推荐路径

| 角色 | 阅读层 | 文件数 | 时间 |
|------|--------|--------|------|
| 硬件架构师 | 1→2→3→6→8→10 | 25 | ~3h |
| RTL 设计工程师 | 1→2→3→4→5→6→9 | 45 | ~6h |
| 验证工程师 | 1→2→5→6(适配器)→9→10 | 30 | ~4h |
| SoC 集成工程师 | 1→2→6→8→10 | 35 | ~4h |
| 全线深入 | 1→2→3→4→5→6→7→8→9→10 | 162 | ~20h |

---

## 阅读技巧

1. **先看 IO，再看逻辑**: 每个文件先找 `val io = IO(new Bundle {...})` 理解输入输出
2. **跟踪数据流**: Fetch→Decode→ALU/BRU/LSU→Regfile→RetirementBuffer
3. **`<>` 双向连接**: `a <> b` 等价于 `a.valid := b.valid; b.ready := a.ready` (Bulk Connect)
4. **Option.when**: 条件编译模式，`Option.when(p.enableRvv)(...)` 仅在 enableRvv=true 时生成硬件
5. **RegInit/RegNext**: 寄存器初始化/下一拍延迟，是流水线的关键组件
6. **Chisel 先于 Verilog**: Chisel 是设计主源码；Verilog RVV 后端是第三方 IP 通过 BlackBox 集成
