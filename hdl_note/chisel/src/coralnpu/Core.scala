// ============================================================================
// Core.scala — CoralNPU 处理器核心顶层 + Verilog 生成入口
//
// Core 类 — 标量核(SCore) + 向量核(RvvCore) + 对外接口封装
//   对外暴露: CSR / 中断(irq/timer/software) / 调试(DM) /
//            取指总线(ibus) / 数据总线(dbus) / 扩展总线(ebus) /
//            流水线刷新(iflush/dflush) / 调试观测(debug)
//   连接: io <> score.io (<> 双向连接) + RvvCore 通过 Option.when 条件实例化
//
// EmitCore 对象 — 命令行驱动的 Chisel→Verilog 编译工具
//   支持选项: --enableRvv/--enableFloat/--itcmSizeKBytes/
//            --useAxi/--useTlul/--target-dir 等
//   根据 TCM 大小自动选择 default/highmem 内存映射
//   生成 VCore_parameters.h (EmitParametersHeader) + Core.sv + Core.zip
//                           ┌──────────────────────────────┐
//                           │             Core             │
//                           │                              │
//  irq/timer/software ─────►│                              │
//  csr in/out        ◄─────►│                              │
//  dm debug          ◄─────►│                              │
//                           │      ┌────────────────┐      │
//  ibus              ◄─────►│◄────►│     SCore      │      │
//  dbus              ◄─────►│◄────►│ 标量主流水线    │      │
//  ebus              ◄─────►│◄────►│ CSR/LSU/Fetch  │      │
//  iflush/dflush     ◄─────►│◄────►│ Debug/Fault    │      │
//  debug             ◄─────►│◄────►│                │      │
//                           │      └───────┬────────┘      │
//                           │              │               │
//                           │              │ optional      │
//                           │              ▼               │
//                           │      ┌────────────────┐      │
//                           │      │    RvvCore     │      │
//                           │      │  向量后端       │      │
//                           │      └────────────────┘      │
//                           │                              │
//  halted/fault/wfi ◄───────│                              │
//                           └──────────────────────────────┘
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

import chisel3._

import java.io.{File, FileOutputStream}
import java.util.zip._
import java.nio.file.{Paths, Files, StandardOpenOption}
import java.nio.charset.{StandardCharsets}
import coralnpu.rvv.{RvvCore}
import _root_.circt.stage.ChiselStage
import scala.collection.mutable.Stack

/** Core 伴生对象 — 工厂方法，调用方写 Core(p) 即可实例化 */
object Core {
  def apply(p: Parameters): Core = Module(new Core(p, "Core"))
  def apply(p: Parameters, moduleName: String): Core = Module(new Core(p, moduleName))
}

/** Core — 标量核 + 向量核的顶层包装 (Module with RequireAsyncReset) */
class Core(p: Parameters, moduleName: String) extends Module with RequireAsyncReset {
  override val desiredName = moduleName  //表示生成 Verilog 时模块名由 moduleName 决定。
  // IO: CSR / 中断 / 调试 / 三条总线(ibus/dbus/ebus) / flush / debug
  val io = IO(new Bundle {
    val csr = new CsrInOutIO(p)
    val halted = Output(Bool())        // 核心已暂停
    val fault = Output(Bool())         // 核心发生异常
    val wfi = Output(Bool())           // 核心等待中断
    val irq = Input(Bool())            // 外部中断请求
    val timer_irq = Input(Bool())      // 定时器中断
    val software_irq = Input(Bool())   // 软件中断
    val debug_req = Input(Bool())      // 调试请求
    val dm = new CoreDMIO(p)           // 调试模块接口

    val ibus = new IBusIO(p)           // 取指总线 (到指令存储器)
    val dbus = new DBusIO(p)           // 数据总线 (到数据存储器)
    val ebus = new EBusIO(p)           // 扩展总线 (到外部)

    val iflush = new IFlushIO(p)       // 指令流水线刷新
    val dflush = new DFlushIO(p)       // 数据流水线刷新
    val debug = new DebugIO(p)         // 调试观测
  })

  // 实例化标量核 SCore + 可选的 RVV 向量核
  val score = SCore(p)                                         // 标量 RISC-V 核心
  val rvvCore = Option.when(p.enableRvv)(RvvCore(p))           // 向量核 (仅 enableRvv)
  if (p.enableRvv) {
    rvvCore.get.io <> score.io.rvvcore.get     // 标量核↔向量核双向连接,批量连接 Bundle 中同名字段
  }

  // ---- 将 SCore 的 IO 透传到 Core 顶层 ----
  //相当于Core内又包含了一个SCore模块，Core的IO直接连接到SCore的IO上。这样外部访问Core的IO时，实际上就是在访问内部SCore的IO。
  io.csr    <> score.io.csr  //双向批量连接 Bundle Bundle 内有 Input/Output 混合方向
  io.ibus   <> score.io.ibus
  io.ebus   <> score.io.ebus
  io.halted := score.io.halted  //单向赋值，Core 顶层的 halted 输出 = SCore 的 halted 输出
  io.fault  := score.io.fault
  io.wfi    := score.io.wfi
  score.io.irq := io.irq
  score.io.timer_irq := io.timer_irq
  score.io.software_irq := io.software_irq
  score.io.dm <> io.dm

  io.iflush <> score.io.iflush
  io.dflush <> score.io.dflush
  io.debug  <> score.io.debug
  io.dbus <> score.io.dbus
}

// ============================================================================
// EmitCore — 命令行 Verilog 生成工具
//
// 解析命令行参数 (--enableRvv/--itcmSizeKBytes/--useAxi/--target-dir 等)，
// 配置 Parameters → 选择 Core/CoreAxi/CoreTlul → 调用 ChiselStage 生成 Verilog。
//
// 三阶段:
//   ① 解析参数设置 p 的属性
//   ② 根据 TCM 大小确定内存映射 (default/highmem) 和模块名后缀
//   ③ lazy val core 选型 (AXI/TLUL/裸Core) → emitSystemVerilog 生成
//   ④ 如果 --target-dir 指定: 写 .sv + .h + zip 打包
// ============================================================================
/** EmitCore — 命令行 Verilog 生成工具 (Scala App 入口)
 *
 *  流程: 解析参数 → 配置 Parameters → 选型 Core/CoreAxi/CoreTlul
 *       → ChiselStage 生成 Verilog → 写 .sv + .h + 打包 zip
 *
 *  调用示例:
 *    sbt "runMain coralnpu.EmitCore --enableRvv=true --useAxi --target-dir=out" */
object EmitCore extends App {
  val p = new Parameters                                       // 可配置参数对象
  var moduleName = "Core"                                      // 模块名 (默认 Core)
  var chiselArgs = List[String]()                              // 透传给 ChiselStage 的额外参数
  var targetDir: Option[String] = None                          // 输出目录 (None=仅生成字符串)
  var useAxi  = false                                          // 是否生成 AXI 封装顶层
  var useTlul = false                                          // 是否生成 TL-UL 封装顶层

  // ---- ① 命令行参数解析 ----
  for (arg <- args) {
    if (arg.startsWith("--enableFetchL0")) {
      p.enableFetchL0 = arg.split("=")(1).toBoolean            // L0 ICache 使能
    } else if (arg.startsWith("--moduleName")) {
      moduleName = arg.split("=")(1)                            // 输出模块名
    } else if (arg.startsWith("--fetchDataBits")) {
      p.fetchDataBits = arg.split("=")(1).toInt                // 取指数据位宽
    } else if (arg.startsWith("--enableRvv")) {
      p.enableRvv = arg.split("=")(1).toBoolean                // RVV 向量扩展
    } else if (arg.startsWith("--enableFloat")) {
      p.enableFloat = arg.split("=")(1).toBoolean              // 标量浮点
    } else if (arg.startsWith("--enableZfbfmin")) {
      p.enableZfbfmin = arg.split("=")(1).toBoolean            // BF16 扩展
    } else if (arg.startsWith("--enableVerification")) {
      p.enableVerification = arg.split("=")(1).toBoolean       // 验证模式
    } else if (arg.startsWith("--lsuDataBits")) {
      p.lsuDataBits = arg.split("=")(1).toInt                  // LSU 数据位宽
    } else if (arg.startsWith("--itcmSizeKBytes")) {
      p.itcmSizeKBytes = arg.split("=")(1).toInt               // ITCM 大小(KB)
    } else if (arg.startsWith("--dtcmSizeKBytes")) {
      p.dtcmSizeKBytes = arg.split("=")(1).toInt               // DTCM 大小(KB)
    // 注意: itcmSizeKBytes 和 dtcmSizeKBytes 取代了旧的 highmem 标志
    // 如需 highmem 模式, 将两个 TCM 大小都设为 1024
    } else if (arg.startsWith("--useAxi")) {
      useAxi = true                                             // 生成 CoreAxi 封装
    } else if (arg.startsWith("--useTlul")) {
      useTlul = true                                            // 生成 CoreTlul 封装
    } else if (arg.startsWith("--target-dir")) {
      targetDir = Some(arg.split("=")(1))                      // 输出目录路径
    } else {
      chiselArgs = chiselArgs :+ arg                            // 透传给 ChiselStage
    }
  }
  assert(!(useAxi && useTlul))                                 // AXI 和 TL-UL 互斥

  // ---- ② 根据 TCM 大小确定模块名后缀 ----
  val finalModuleName =
    if (p.itcmSizeKBytes == Parameters.itcmSizeKBytesDefault &&
        p.dtcmSizeKBytes == Parameters.dtcmSizeKBytesDefault) {
      moduleName                                                // 默认大小: "Core"
    } else if (p.itcmSizeKBytes == Parameters.itcmSizeKBytesHighmem &&
               p.dtcmSizeKBytes == Parameters.dtcmSizeKBytesHighmem) {
      s"${moduleName}Highmem"                                   // 1MB+1MB: "CoreHighmem"
    } else {
      s"${moduleName}_ITCM${p.itcmSizeKBytes}KB_DTCM${p.dtcmSizeKBytes}KB" // 自定义
    }

  // ---- ③ 根据 TCM 大小选择内存映射 ----
  val memoryRegions =
    if (p.itcmSizeKBytes == Parameters.itcmSizeKBytesDefault &&
        p.dtcmSizeKBytes == Parameters.dtcmSizeKBytesDefault) {
      MemoryRegions.default                                     // 低地址紧凑布局
    } else {
      MemoryRegions.highmem(p.itcmSizeKBytes, p.dtcmSizeKBytes) // 高地址布局
    }

  // ---- ④ Core 选型 (lazy: 延迟到 ChiselStage 上下文中才实际构造) ----
  // 必须在 ChiselStage 上下文中创建 Module, 用 lazy val 延迟求值
  lazy val core = if (useAxi) {
    p.m = memoryRegions
    new CoreAxi(p, finalModuleName)                             // AXI 总线封装版
  } else if (useTlul) {
    p.m = memoryRegions
    new CoreTlul(p, finalModuleName)                            // TL-UL 总线封装版
  } else {
    // "Matcha" 内存布局 (裸 Core, 单一 DMEM 区域 4MB)
    p.m = Seq(
      new MemoryRegion(0x0, 0x400000, MemoryRegionType.DMEM),
    )
    new Core(p, finalModuleName)                                // 裸 Core (无总线封装)
  }

  // ---- ⑤ CIRCT/Firtool 编译选项 ----影响最终生成的 SystemVerilog 风格和验证逻辑。
  val firtoolOpts = Array(
      "--lowering-options=disallowLocalVariables,locationInfoStyle=none",
      "-enable-layers=Verification",
  )
  // 生成 SystemVerilog 字符串 (单文件)
  val systemVerilogSource = ChiselStage.emitSystemVerilog(
    core, chiselArgs.toArray, firtoolOpts)

  // CIRCT 在 SV 文件末尾附加了黑盒资源引用, 需要移除
  // (否则 Verilator 无法解析)
  val resourcesSeparator =
      "// ----- 8< ----- FILE \"firrtl_black_box_resource_files.f\" ----- 8< -----"
  val strippedVerilogSource = systemVerilogSource.split(resourcesSeparator)(0)
  val coreName = core.name                                      // 模块名 (如 "CoreHighmemAxi")

  // 生成参数 C 头文件字符串
  val header_str = EmitParametersHeader(p)

  // ---- ⑥ 输出到文件 (仅当 --target-dir 指定时) ----
  targetDir match {
    case Some(targetDir) => {
      {
        // 第二个 lazy core: 用于 --split-verilog 分模块生成
        // (CoreAxi 内部实例化了多个子模块, split 模式会为每个子模块生成独立 .sv)
        lazy val core2 = if (useAxi) {
          new CoreAxi(p, moduleName)
        } else {
          new Core(p, moduleName)
        }

        // 分模块生成 Verilog (--split-verilog: 每个 Module 一个 .sv 文件)
        ChiselStage.emitSystemVerilogFile(
            core2, chiselArgs.toArray ++ Array(
                "--split-verilog", "--target-dir", targetDir), firtoolOpts)

        // 将所有生成的 .sv 文件打包为 .zip
        val zip = new ZipOutputStream(new FileOutputStream(
            targetDir + "/" + coreName + ".zip"))
        val dirStack = new Stack[File](1)
        dirStack.push(new File(targetDir))
        println(s"target: ${targetDir}")
        while (!dirStack.isEmpty) {
          val dir = dirStack.pop()
          val files = dir.listFiles
          files.foreach { name =>
            if (name.isDirectory()) {
              dirStack.push(name)                                // 递归子目录
            } else {
              val zipName = name.getPath().replace(targetDir + "/", "")
              zip.putNextEntry(new ZipEntry(zipName))            // 创建 zip 条目
              zip.write(Files.readAllBytes(Paths.get(name.getPath())))
              zip.closeEntry()
            }
          }
        }
        zip.close()
      }

      // 写入参数 C 头文件: <targetDir>/VCore_parameters.h
      Files.write(
          Paths.get(targetDir + "/V" + core.name + "_parameters.h"),
          header_str.getBytes(StandardCharsets.UTF_8),
          StandardOpenOption.CREATE)

      // 写入顶层 SystemVerilog 文件: <targetDir>/Core.sv
      Files.write(
          Paths.get(targetDir + "/" + core.name + ".sv"),
          strippedVerilogSource.replace("exclude_file", "exclude_module")
            .getBytes(StandardCharsets.UTF_8),
          StandardOpenOption.CREATE)

      ()
    }
    case None => ()                                              // 无 targetDir: 不写文件
  }
}

