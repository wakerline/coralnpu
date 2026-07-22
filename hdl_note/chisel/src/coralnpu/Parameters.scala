// ============================================================================
// Parameters.scala — CoralNPU 全局参数配置与内存映射
//
// 本文件定义了整个处理器的"配置单"，包含 5 个核心部件:
//
//   1. MemoryRegionType   — 内存区域类型枚举 (IMEM / DMEM / Peripheral / External)
//   2. MemoryRegion       — 内存区域描述类，定义一段地址空间，提供 contains() 地址判断
//   3. MemoryRegions      — 两套预定义地址映射 (default 低地址 / highmem 高地址)
//   4. Parameters         — 处理器全部硬件参数: 总线位宽、缓存、功能开关、TCM 大小
//   5. EmitParametersHeader — 利用 Scala 运行时反射将参数自动导出为 C #define 宏
//
// 设计原则:
//   所有硬件规模参数集中在一处管理，Chisel → Verilog 编译时读取这些参数决定硬件大小。
//   同一份参数通过 EmitParametersHeader 同步导出为 C 头文件供软件/仿真引用，
//   避免软硬件各自维护一份参数造成不一致。
//
// 命名约定:
//   val = 不可变常量 (如 programCounterBits = 32 — 编译期固定)
//   var = 可运行时覆盖 (如 enableRvv, itcmSizeKBytes — 命令行可改)
//   def = 派生计算值 (如 fetchInstrSlots — 由其他参数推算)
// ============================================================================
// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._                                          // Chisel3 核心 (Module, Bundle, UInt, Bool, Reg...)
import chisel3.util._                                     // Chisel3 工具 (Decoupled, Valid, Queue, log2Ceil...)
import scala.collection.mutable.StringBuilder             // 可变字符串构建器，用于拼接 C 头文件文本

// ============================================================================
// MemoryRegionType — 内存区域类型枚举
//
// 区分处理器地址空间中不同性质的内存区域。
// 地址译码器根据地址命中的区域类型决定走哪条访问路径:
//   IMEM       → 指令紧耦合内存 (ITCM)，1 周期延迟
//   DMEM       → 数据紧耦合内存 (DTCM)，1 周期延迟
//   Peripheral → 外设 MMIO 空间 (CSR / Timer / 中断控制器)，需要 Fabric 路由
//   External   → 片外访问，通过 AXI 总线发出
//
// ChiselEnum 既可用于 Scala 层参数化配置，也会在需要时综合为硬件状态机编码。
// ============================================================================
object MemoryRegionType extends ChiselEnum {
  val IMEM       = Value   // 指令内存 (Instruction Tightly Coupled Memory)
  val DMEM       = Value   // 数据内存 (Data Tightly Coupled Memory)
  val Peripheral = Value   // 外设 MMIO 区 (CSR / Timer / 中断控制器等)
  val External   = Value   // 片外访问区 (通过 AXI 总线访问 DRAM / Flash 等)
}

// ============================================================================
// MemoryRegion — 内存区域描述 (纯 Scala 参数类，非硬件 Module)
//
// 三个 Int 参数描述一段连续的地址空间:
//   memStart — 区域起始字节地址
//   memSize  — 区域总字节数
//   memType  — 区域类型 (IMEM / DMEM / Peripheral / External)
//
// 核心方法: contains(addr)
//   接收一个 Chisel UInt 硬件地址信号，返回 Bool 表示该地址是否在本区域内。
//   综合成硬件就是两个比较器 + 一个与门:
//
//     addr >= memStart  ──┐
//                         ├── AND ──→ Bool
//     addr <  memStart   ──┘
//            + memSize
//
//   注意: Chisel 的 UInt 字面量位宽由值推断，可能与 addr 位宽不同，
//   因此用 addr.getWidth.W 作为显式 Width 传给 .U() 保证位宽一致。
// ============================================================================
class MemoryRegion(
  val memStart: Int,                       // 区域基地址 (字节粒度)，如 0x00000000
  val memSize: Int,                        // 区域总字节数，如 0x2000 = 8KB
  val memType: MemoryRegionType.Type,      // 区域类型 (控制访问路径)
) {

  /** 判断给定硬件地址是否落在本区域内，返回 Chisel Bool 供地址译码器使用 */
  def contains(addr: UInt): Bool = {
    val addrWidth = addr.getWidth.W        // 取 addr 信号的位宽，统一 .U() 字面量宽度
    (addr >= memStart.U(addrWidth)) &&      // 下界比较: addr >= 起始地址
    (addr < memStart.U(addrWidth) + memSize.U(addrWidth))  // 上界比较: addr < 起始地址 + 大小
  }

}

// ============================================================================
// MemoryRegions — 预定义的两套地址映射方案
//
// default (低地址): 地址紧凑，适合 TCM 较小的 IP 配置
//   ITCM:  0x00000_0000 ~ 0x00000_1FFF   (8KB)
//   DTCM:  0x00001_0000 ~ 0x00001_7FFF  (32KB)
//   CSR:   0x00003_0000 ~ 0x00003_0FFF   (4KB)
//
// highmem (高地址): 将 DTCM 和 CSR 的基地址抬高到 1MB 和 2MB 处，
//   为 ITCM 腾出完整的 0~1MB 空间。ITCM 和 DTCM 最大均可配置为 1MB，
//   各自独立扩展，互不踩踏。
//   ITCM:  0x00000_0000 ~ (itcmSizeKBytes * 1024) - 1
//   DTCM:  0x00010_0000 ~ 0x00010_0000 + (dtcmSizeKBytes * 1024) - 1
//   CSR:   0x00020_0000 ~ 0x00020_0FFF  (4KB 固定)
// ============================================================================
object MemoryRegions {

  /** 默认低地址映射 — ITCM 8KB, DTCM 32KB, CSR 4KB */
  val default = Seq(
    new MemoryRegion(0x0000000, 0x00002000, MemoryRegionType.IMEM),       // ITCM:  0x00000~0x01FFF
    new MemoryRegion(0x0010000, 0x00008000, MemoryRegionType.DMEM),       // DTCM:  0x10000~0x17FFF
    new MemoryRegion(0x0030000, 0x00001000, MemoryRegionType.Peripheral), // CSR:   0x30000~0x30FFF
  )

  /**
   * 高地址映射 — ITCM 和 DTCM 大小可由参数动态决定
   *
   * @param itcmSizeKBytes ITCM 大小 (KB)，如 1024 = 1MB — 决定 ITCM 区域的上界
   * @param dtcmSizeKBytes DTCM 大小 (KB)，如 1024 = 1MB — 决定 DTCM 区域的上界
   *
   * DTCM 和 CSR 的基地址被有意设置为 1MB 对齐 (0x100000 / 0x200000)，
   * 使得 ITCM 可以独占 0x000000 ~ 0x0FFFFF (1MB)，不受 DTCM/CSR 影响。
   */
  def highmem(itcmSizeKBytes: Int, dtcmSizeKBytes: Int) = Seq(
    new MemoryRegion(0x00000000, itcmSizeKBytes * 1024, MemoryRegionType.IMEM),       // ITCM: 大小可变
    new MemoryRegion(0x00100000, dtcmSizeKBytes * 1024, MemoryRegionType.DMEM),       // DTCM: 大小可变
    new MemoryRegion(0x00200000, 0x00001000, MemoryRegionType.Peripheral),            // CSR:  4KB 固定
  )
}

// ============================================================================
// Parameters 伴生对象 — 提供默认常量值和工厂方法
//
// Scala 中与类同名的 object 称为"伴生对象" (companion object)。
// 定义 apply() 方法后，调用方可直接写:
//   Parameters()           // 等价于 Parameters.apply() → new Parameters()
//   Parameters(memRegions) // 等价于 Parameters.apply(m) → new Parameters(m)
// 比直接 new Parameters() 更简洁，且便于以后改变构造逻辑。
// ============================================================================
object Parameters {
  val itcmSizeKBytesDefault = 8      // 当前 IP 默认 ITCM:  8KB (足够小型固件)
  val dtcmSizeKBytesDefault = 32     // 当前 IP 默认 DTCM: 32KB (栈 + 全局数据)
  val itcmSizeKBytesHighmem = 1024   // highmem 模式下最大 ITCM: 1MB
  val dtcmSizeKBytesHighmem = 1024   // highmem 模式下最大 DTCM: 1MB

  /** 工厂方法: 无参 → 使用默认内存映射 (m=Seq(), hartId=0) */
  def apply(): Parameters = new Parameters()

  /** 工厂方法: 传入自定义内存区域序列 */
  def apply(m: Seq[MemoryRegion]): Parameters = new Parameters(m)
}

// ============================================================================
// Parameters 类 — CoralNPU 处理器核的完整硬件参数集
//
// 该类控制着 Chisel → Verilog 编译时所有可配置的硬件规模。
// 构造参数:
//   m       — 内存区域列表 (默认空 Seq，由 CoreAxi / EmitCore 在构造后设置)
//   hartId  — RISC-V HART (硬件线程) 编号，多核系统中用于区分核心，默认 0
//
// 标注 "do not change" 的参数与外部接口 / 硬件结构深度耦合，
// 随意修改会导致 AXI 位宽不匹配、地址越界等功能错误。
// ============================================================================
class Parameters(var m: Seq[MemoryRegion] = Seq(), val hartId: Int = 0) {

  // ---- 处理器基础 ----
  val programCounterBits = 32    // PC (程序计数器) 位宽 — RISC-V RV32 固定 32 位
  val instructionBits     = 32   // 单条指令位宽 — RV32I 基础指令均为 32-bit
  val instructionLanes    = 4    // 每周期并行取指/译码/发射的指令条数 (4-wide superscalar)

  // ---- 验证模式 ----
  // 设为 true 时启用: 硬件断言、覆盖率信号、完整版 RetirementBuffer
  // 仅在仿真环境使用，综合时务必设为 false 以节省面积
  var enableVerification = false

  // ---- RVV 向量扩展 (符合 RVV 1.0 规范) ----
  var enableRvv = false          // 是否启用 RVV 向量处理单元
                                 //   true  → Core 实例化 RvvCore (增加大量向量硬件)
                                 //   false → Core 仅包含标量流水线
  val rvvVlen   = 128            // VLEN: 单个向量寄存器的总位宽 = 128 bits
                                 //   128-bit 可容纳 4×int32 / 8×int16 / 16×int8
  def rvvVlenb: Int = { rvvVlen / 8 }  // VLEN 的字节表示: 128/8 = 16 bytes

  /**
   * 是否启用完整版退役缓冲区
   *
   * 退役缓冲区 (Retirement Buffer) 跟踪所有在飞指令，保证按程序顺序提交结果。
   * 当前策略: 仅在验证模式下使用完整版，非验证模式使用简化版 (mini=true) 省面积。
   */
  def useRetirementBuffer: Boolean = { enableVerification }

  // ---- 标量浮点单元 ----
  var enableFloat   = false      // 启用标量浮点 (RV32F 单精度 + RV32D 双精度可选)
                                 //   关闭时浮点指令触发非法指令异常
  var enableZfbfmin = false      // 启用 Zfbfmin 扩展 — BF16 (Brain Float 16) 转换指令

  // 浮点除法/平方根模块实现选择:
  //   0 — E906 开源核的 Div/Sqrt (精度高，但面积较大)
  //   1 — PULP 平台的 Div/Sqrt     (面积小，但存在轻微舍入误差)
  val floatPulpDivsqrt = 0

  // ---- 退役缓冲区 (Retirement Buffer) 配置 ----
  // 退役缓冲区为每条在飞指令分配一个索引，索引空间划分为三段:
  //   0 ~ 31:  标量整数寄存器 (x0~x31)
  //   32 ~ 63: 浮点寄存器     (f0~f31)，仅在 enableFloat 时存在
  //   64 ~ 95: 向量寄存器     (v0~v31)，仅在 enableRvv 时存在
  //   +2 空寄存器: 分别代表"无写回"和"已存储"的指令
  val floatRegfileBaseAddr = 32  // 浮点寄存器在退役缓冲区索引空间中的起始偏移
  val rvvRegfileBaseAddr   = 64  // 向量寄存器在退役缓冲区索引空间中的起始偏移
  val rvvRegCount          = 32  // 向量寄存器数量 — RVV 规范定义 v0~v31 共 32 个
  val retirementBufferSize = 8   // 退役缓冲区深度 — 最多同时容纳 8 条未退役指令

  /**
   * 退役缓冲区索引位宽
   *
   * 索引空间 = 标量32 + 浮点(启用32/未启用0) + 向量32 + 2空寄存器
   *
   * +2 的两个空寄存器 (dummy register)含义:
   *   1 个 "no write" — 代表该指令不产生写回 (如 store / branch 指令)
   *   1 个 "store"    — 代表该指令的结果已存入内存 (LSU store 指令完成)
   *
   * log2Ceil(N) = 覆盖 N 个条目所需的最小位宽
   * 例: enableFloat=true 时: 32 + 32 + 32 + 2 = 98 → log2Ceil(98) = 7 bits
   */
  def retirementBufferIdxWidth: Int = {
    val scalarRegCount = 32
    val floatRegCount = (if (enableFloat) { 32 } else { 0 })
    // +2 对应 "no write" 和 "store" 两个空寄存器
    log2Ceil(scalarRegCount + floatRegCount + rvvRegCount + 2)
  }

  // ---- L0 ICache / 取指单元 ----
  var enableFetchL0  = true      // 启用 L0 指令缓存 (位于取指单元内部的小型缓存)
                                 //   true  → 使用 Fetch 模块 (含 1KB L0 ICache)
                                 //   false → 使用 UncachedFetch 模块 (每次取指都走 IBus)
  val fetchCacheBytes = 1024     // L0 ICache 总容量: 1024 bytes = 1KB

  // ---- 取指总线 (do not change: 与 AXI 位宽和 LSU 数据通路耦合) ----
  val fetchAddrBits = 32         // 取指地址位宽 — 32-bit，支持 4GB 寻址空间
  var fetchDataBits = 256        // 取指数据位宽 — 256 bits = 32 bytes/周期
                                 //   每周期可同时取回 256/32 = 8 条 RISC-V 指令

  /**
   * 每个取指数据块中的指令槽数
   *
   * 三条 assert 确保:
   *   1. fetchDataBits 是 32-bit 对齐的
   *   2. instructionBits 是 32-bit 的倍数
   *   3. fetchDataBits 能被 instructionBits 整除
   *
   * 例: 256 / 32 = 8 — 每个取指块可容纳 8 条指令
   */
  def fetchInstrSlots: Int = {
    assert(fetchDataBits % 32 == 0)              // 数据位宽 32-bit 对齐
    assert(instructionBits % 32 == 0)            // 指令位宽 32-bit 对齐
    assert(fetchDataBits % instructionBits == 0) // 数据位宽是指令位宽的整数倍
    fetchDataBits / instructionBits
  }

  // ---- Load/Store 单元总线 (do not change: 与 DCache 和 AXI 耦合) ----
  val lsuAddrBits = 32           // LSU (Load/Store Unit) 地址位宽 — 32-bit
  var lsuDataBits = 256          // LSU 数据位宽 — 256-bit，单周期最多存取 32 bytes
                                 //   宽总线对 RVV 向量访存 (连续地址批量读写) 至关重要
  def lsuDataBytes: Int = { lsuDataBits / 8 }  // LSU 数据通道字节宽: 256/8 = 32 bytes
  val lsuDelayPipelineLen = 1    // LSU 流水线延迟 — 请求到数据返回需 1 个时钟周期

  /**
   * 数据总线大小编码 — 用于 AXI 总线的 size 信号
   *
   * AXI size 信号按 2 的幂次编码单次传输字节数:
   *   size=0 → 1B, size=1 → 2B, size=2 → 4B, size=3 → 8B ...
   *
   * 例: lsuDataBits=256 → lsuDataBytes=32 → dbusSize=log2Ceil(32)+1=5+1=6
   */
  def dbusSize: Int = { log2Ceil(lsuDataBits / 8) + 1 }

  // ---- TCM (紧耦合内存) 大小 ----
  var itcmSizeKBytes = Parameters.itcmSizeKBytesDefault  // ITCM 大小 (KB)，可由命令行 --itcmSizeKBytes 覆盖
  var dtcmSizeKBytes = Parameters.dtcmSizeKBytesDefault  // DTCM 大小 (KB)，可由命令行 --dtcmSizeKBytes 覆盖

  // ---- L1 ICache 的 AXI 接口 (内部编号 AXI0) ----
  val l1islots    = 256          // L1 ICache 槽数 — 256 个 cache line，总容量256x32B = 8KB
  val l1iassoc    = 4            // L1 ICache 组相联度 — 4-way set-associative (64组)
                                 //   地址划分: Tag[31:11] | Index[10:5] | Offset[4:0]
  val axi0IdBits  = 4            // AXI0 ID 位宽 (1 bank 模式),AXI 协议中有 transaction ID，用来区分多个 outstanding 请求。
  val axi0AddrBits = 32          // AXI0 地址位宽
  def axi0DataBits: Int = { fetchDataBits }  // 与取指通路一致 (256-bit)

  // ---- L1 DCache 的 AXI 接口 (内部编号 AXI1) ----
  val l1dslots    = 256          // L1 DCache 槽数 — 256 cache line (x2 banks = 512行, 16KB)
  val axi1IdBits  = 4            // AXI1 ID 位宽 (2 banks 模式)
  val axi1AddrBits = 32          // AXI1 地址位宽
  def axi1DataBits: Int = { lsuDataBits }    // 与 LSU 通路一致 (256-bit)

  // ---- TCM 的 AXI 接口 (内部编号 AXI2) ----
  var axi2IdBits   = 6           // AXI2 ID 位宽 (var, CoreAxi 构造时可调整)
  val axi2AddrBits = 32          // AXI2 地址位宽
  def axi2DataBits: Int = { lsuDataBits }    // 与 LSU 一致 (原注释: vectorBits)
  def axi2DataBytes: Int = { axi2DataBits / 8 }

  // ---- ITCM 初始化文件 ----
  // 若非空字符串，应指向一个 Verilog $readmemh 格式的 .mem 文件。
  // 仿真/FPGA 启动时预加载到 ITCM。仅 CoreAxi 模块使用。
  val itcmMemoryFile = ""

  // ---- CSR 接口信号数量 ----
  // csrInCount:  核外→核内 CSR 信号 (中断状态/计数器/配置)
  // csrOutCount: 核内→核外 CSR 信号 (异常地址/状态标志/性能计数器)
  val csrInCount  = 13
  val csrOutCount = 9
}

// ============================================================================
// EmitParametersHeader — 利用 Scala 运行时反射自动生成 C #define 头文件
//
// 为什么需要?
//   软件侧 (SystemC 仿真平台 / 固件编译) 也需要知道硬件参数。
//   本模块在 Chisel → Verilog 编译时自动生成 coralnpu_parameters.h，
//   保证软硬件看到的参数严格一致。
//
// 生成规则:
//   Parameters 中每个 val / var 字段:
//     Int     → #define KP_xxx 32     (C int 宏)
//     Boolean → #define KP_xxx false  (C bool 宏)
//     其他    → 跳过
//   def 方法 → 反射无法自动调用，手动补充
//
// 生成示例:
//   #ifndef CORALNPU_PARAMETERS_H_
//   #define CORALNPU_PARAMETERS_H_
//   #include <stdbool.h>
//   #define KP_programCounterBits 32
//   ...
//   #define KP_dbusSize 6        // 手动补充
//   #endif
//
// 调用: EmitParametersHeader(p) → C 头文件字符串
// 写入: <targetDir>/V<CoreName>_parameters.h (由 Core.scala EmitCore 调用)
// ============================================================================
import scala.reflect.runtime.{universe => ru}  // Scala 运行时反射 API，别名 ru
object EmitParametersHeader {

  /** 读取 Parameters 的所有 val/var 字段，生成 C 头文件字符串 */
  def apply(p: Parameters): String = {
    // ① 获取运行时反射镜像
    val mirror         = ru.runtimeMirror(ru.getClass.getClassLoader)
    val instanceMirror = mirror.reflect(p)
    val symbol         = instanceMirror.symbol
    val typeSym        = symbol.toType

    // ② 收集所有 val/var 字段 (滤掉 def 方法)
    val fields = typeSym.decls.collect {
      case t: (ru.TermSymbol @unchecked) if t.isVal || t.isVar => t
    }

    // ③ 构建 C 头文件 include guard 框架
    var builder = new StringBuilder()
    builder = builder.append("#ifndef CORALNPU_PARAMETERS_H_\n")
    builder = builder.append("#define CORALNPU_PARAMETERS_H_\n")
    builder = builder.append("\n")
    builder = builder.append("#include <stdbool.h>\n")
    builder = builder.append("\n")

    // ④ 遍历字段: 类型映射 + 生成宏
    fields.foreach { x =>
      val fieldMirror = instanceMirror.reflectField(x.asTerm)
      val fieldType   = x.asTerm.typeSignature
      val value       = fieldMirror.get
      val ctype = fieldType match {
        case t if t =:= ru.typeOf[Int]     => Some("int")     // Scala Int → C int
        case t if t =:= ru.typeOf[Boolean] => Some("bool")    // Scala Boolean → C bool
        case _                              => None           // 复杂类型跳过
      }
      if (ctype != None) {
        builder = builder.append(s"#define KP_${x.name} ${value}\n")
      }
    }

    // ⑤ 手动补充 def 方法 (反射无法自动执行方法体)
    // TODO(atv): 改进反射以支持自动导出计算方法
    builder = builder.append(s"#define KP_dbusSize ${p.dbusSize}\n")
    builder = builder.append(s"#define KP_useRetirementBuffer ${p.useRetirementBuffer}\n")
    builder = builder.append(s"#define KP_retirementBufferIdxWidth ${p.retirementBufferIdxWidth}\n")
    builder = builder.append("#endif\n")
    builder.result()
  }
}