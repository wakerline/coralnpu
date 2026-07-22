// ============================================================================
// Fabric.scala — 内部 SRAM 交叉开关 (Fabric)
//
// Fabric 是连接标量核 LSU / RVV 向量 LSU / DMA 等主设备到多个 SRAM
// (ITCM/DTCM/CSR) 从设备的内部互联网络。由两个核心组件组成:
//
//   FabricArbiter — N:1 固定优先级仲裁器
//     优先级: source(0) > source(1) > ... > source(N-1)
//     fabricBusy(i) = scanLeft(sourceValid) 计算反压链
//     读数据/写响应广播回所有源端口 (各端口自行过滤)
//
//   FabricMux — 1:N 地址路由多路分配器
//     根据 MemoryRegion.contains(addr) 确定目标端口
//     地址自动减去目标区域基地址 (从设备看到 0-based 本地地址)
//     读数据延迟 1 拍取回 (RegInit 匹配外设响应时序)
//
// 典型拓扑: N个主设备 → FabricArbiter → FabricMux → M个从设备
// 约束: 同一周期每个端口只能有读或写之一有效 (不能同时)
// ============================================================================
// Copyright 2025 Google LLC
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
import chisel3.util._

import common._

// ============================================================================
// FabricArbiter — N:1 固定优先级仲裁器
//
// 多个主设备 (LSU/RVV/DMA等) 共享同一组 SRAM 时, 由 FabricArbiter 决定谁先访问。
// 使用"固定优先级"而非 Round-Robin: 实现简单、延迟确定、无状态。
//
//   输入源:  source(0) (最高优先)   source(1)   ...   source(N-1) (最低)
//                \                    |                  /
//                 └───────────────────┼─────────────────┘
//                                     ↓
//                              仲裁输出 port
//
// 反压机制: fabricBusy(i) 告诉源 i "你现在发请求也不会被选中, 别发了"。
//          源 i 收到 busy=1 时应暂停发出新请求, 等 busy=0 再发。
//
// 约束: Fabric 协议规定同一端口不能同时读写 (硬件断言保证)。
//       因此仲裁只需判断"是否有有效请求", 不需区分读/写。
// ============================================================================
/** FabricArbiter — N:1 固定优先级仲裁器
 *  @param p Parameters 配置
 *  @param n 输入端口数 (默认 2) */
class FabricArbiter(p: Parameters, n: Int = 2) extends Module {
  val io = IO(new Bundle {
    val source     = Vec(n, Flipped(new FabricIO(p)))  // N 个主设备端口 (Flipped: 外部驱动)
    val fabricBusy = Output(Vec(n, Bool()))             // busy(i)=1: 源i被更高优先级阻塞
    val port       = new FabricIO(p)                    // 仲裁后唯一输出
  })

  // 硬件断言: Fabric 协议不允许同一端口同时读写
  // map 检查每个端口, reduce(_||_) 汇总: 任意端口违规即报错
  assert(!io.source.map(x => x.readDataAddr.valid && x.writeDataAddr.valid).reduce(_ || _))

  // sourceValid(i): 源 i 是否有待处理的请求 (读或写)
  val sourceValid = io.source.map(x => x.readDataAddr.valid || x.writeDataAddr.valid)

  // ---- 优先级反压链: scanLeft 核心算法 ----
  // scanLeft(false.B)(_||_) 从左到右累积 OR:
  //   sourceValid =      [  0,    1,    0,    1  ]
  //   scanLeft(_||_) =   [  0,    0,    1,    1,  1 ]   (初始值 false 在最前)
  //   dropRight(1)   =   [  0,    0,    1,    1  ]      (去掉末尾多余的 1)
  //
  // 含义: 源0永不被阻塞(第一个 busy 总是 0);
  //       源1在源0有效时被阻塞(busy=1);
  //       源2/3在源0或源1有效时被阻塞
  val busySignals = sourceValid.scanLeft(false.B)(_ || _).dropRight(1)
  io.fabricBusy := VecInit(busySignals)

  // ---- 输出选择: MuxCase 按优先级选第一个有效源 ----
  // (0 until n).map(...) 展开后等价于 (以 n=3 为例):
  //   MuxCase(default, Seq(
  //     (sourceValid(0) -> source(0).readDataAddr),  // 优先级最高, 先被检查
  //     (sourceValid(1) -> source(1).readDataAddr),  // 其次
  //     (sourceValid(2) -> source(2).readDataAddr),  // 优先级最低
  //   ))
  // MuxCase 从上到下扫描每个 (条件 -> 值), 选中第一个条件为真的源
  // 例: sourceValid=[false,true,true] → 跳过源0 → 选中源1 (源2不再检查)
  // 所有源都无效时用 MakeInvalid (valid=false 表示无请求)
  io.port.readDataAddr := MuxCase(MakeInvalid(UInt(p.axi2AddrBits.W)),  //默认值就是MakeInvalid(UInt(p.axi2AddrBits.W),带valid+bits
    (0 until n).map(x => (sourceValid(x) -> io.source(x).readDataAddr))
  )
  io.port.writeDataAddr := MuxCase(MakeInvalid(UInt(p.axi2AddrBits.W)),
    (0 until n).map(x => (sourceValid(x) -> io.source(x).writeDataAddr))
  )
  io.port.writeDataBits := MuxCase(0.U(p.axi2DataBits.W),
    (0 until n).map(x => (sourceValid(x) -> io.source(x).writeDataBits))
  )
  io.port.writeDataStrb := MuxCase(0.U((p.axi2DataBits / 8).W),
    (0 until n).map(x => (sourceValid(x) -> io.source(x).writeDataStrb))
  )

  // ---- 响应广播: 读数据/写响应同时发给所有源 ----
  // 为什么广播而不是定向? 仲裁器不知道哪个源在等待响应,
  // 让所有源都看到读数据/写响应, 各源根据自身请求状态自行过滤
  for (i <- 0 until n) {
    io.source(i).readData  := io.port.readData
    io.source(i).writeResp := io.port.writeResp
  }
}

// ============================================================================
// FabricMux — 1:N 地址路由多路分配器
//
// 来自 FabricArbiter 的唯一输出需要分发到不同 SRAM (ITCM/DTCM/CSR/Peripheral)。
// FabricMux 根据访存地址所在的 MemoryRegion 决定路由到哪个从设备端口。
//
//   主设备请求 ──→ FabricMux ──┬── ports(0) → ITCM
//                  (地址路由)  ├── ports(1) → DTCM
//                              ├── ports(2) → CSR
//                              └── ...
//
// 三步处理:
//   ① 地址匹配: 用 MemoryRegion.contains(addr) 确定目标端口
//   ② 地址偏移: 全局地址 & ~memStart → 从设备本地 0-based 地址
//   ③ 响应收集: 写响应立即取回, 读数据延迟1拍 (外设读延迟)
//
// 反压: 目标端口 periBusy=1 时 fabricBusy=1, 通知上游暂停
// ============================================================================
/** FabricMux — 1:N 地址路由多路分配器
 *  @param p       Parameters 配置
 *  @param regions 内存区域列表, 顺序决定端口编号 (regions(0)→ports(0))
 *
 *  IO:
 *    source     — 主设备输入端口 (来自 FabricArbiter)
 *    fabricBusy — 上游反压: 目标端口忙时告知主设备暂停
 *    ports(N)   — N 个从设备输出端口
 *    periBusy(N)— 各从设备忙信号 (从设备→Mux) */
class FabricMux(p: Parameters, regions: Seq[MemoryRegion]) extends Module {
  val portCount   = regions.length                           // 端口数 = 内存区域数 (典型: 3=ITCM/DTCM/CSR)
  val portIdxBits = log2Ceil(portCount)                      // 端口索引位宽 (如 3端口→2-bit)
  val portIdxType = UInt(log2Ceil(portCount).W)          // 端口索引类型 (如 3端口→UInt(2.W))
  val io = IO(new Bundle {
    val source     = Flipped(new FabricIO(p))                // 主设备输入
    val fabricBusy = Output(Bool())                          // 上游反压

    val ports    = Vec(portCount, new FabricIO(p))            // N 个从设备端口
    val periBusy = Vec(portCount, Input(Bool()))              // 各从设备忙信号输入
  })

  // Fabric 协议约束: 同一周期最多一个有效操作
  assert(!(io.source.readDataAddr.valid && io.source.writeDataAddr.valid))

  // ===================================================================
  // ① 地址匹配: 用 MemoryRegion.contains() 确定目标端口
  // ===================================================================
  val sourceValid = io.source.readDataAddr.valid ||
                    io.source.writeDataAddr.valid

  // MuxUpTo1H: 独热多路选择 — 仅最高优先级的有效输入被选中
  // 这里只有读/写两个可能, 读优先, 写次之
  val addr = MuxUpTo1H(0.U, Seq(
    io.source.readDataAddr.valid  -> io.source.readDataAddr.bits,
    io.source.writeDataAddr.valid -> io.source.writeDataAddr.bits,
  ))

  // 遍历所有 region, 用 contains(addr) 判断地址落在哪
  // 例: addr=0x10000 → ITCM范围? 否. DTCM范围? 是 → selected=(true, 1)
  // MakeValid(true, idx): 生成 valid=true + bits=idx 的信号
  val selected = MuxCase(MakeInvalid(portIdxType), (0 until portCount).map(
    x => (sourceValid && regions(x).contains(addr)) ->
        MakeValid(true.B, x.U(portIdxBits.W))
  ))

  // portSelected(i): 被选中 且 目标设备不忙
  val portSelected = (0 until portCount).map(
      i => selected.valid && (selected.bits === i.U) && !io.periBusy(i))
  assert(PopCount(VecInit(portSelected)) <= 1.U)            // 一条地址只能命中一个 region (硬件保证)

  // 上游反压: 目标端口忙 → fabricBusy=1
  io.fabricBusy := MuxUpTo1H(false.B, (0 until portCount).map(
    i => (selected.valid && (selected.bits === i.U)) -> io.periBusy(i)
  ))

  // ===================================================================
  // ② 地址偏移: 全局地址 → 从设备本地地址
  //
  // 为什么要偏移? 每个从设备 (如 ITCM SRAM) 只看到自己的地址空间,
  // 不知道自己在全局地址空间中的位置。例如:
  //   全局地址 0x10000 (DTCM基址) → 偏移后 0x00000 → DTCM 看到的地址
  //   全局地址 0x10004             → 偏移后 0x00004
  //
  // 偏移方式: addr & ~memStart (位掩码法, 仅当 memStart 是2的幂时有效)
  //   例: memStart=0x10000 → ~memStart=0xFFFEFFFF
  //       addr=0x10004 → 0x10004 & 0xFFFEFFFF = 0x00004 ✓
  // ===================================================================
  for (i <- 0 until portCount) {
    // 位掩码偏移: addr & ~memStart 清除基地址的高位
    // 仅当 memStart 是 2 的幂时正确 (CoralNPU 的内存区域基地址都是 2 的幂)
    val readAddr  = io.source.readDataAddr.bits &
        ~regions(i).memStart.U(p.fetchAddrBits.W)  //
    val writeAddr = io.source.writeDataAddr.bits &
        ~regions(i).memStart.U(p.fetchAddrBits.W)

    // 仅选中端口接收命令, 其余端口收到 valid=false
    io.ports(i).readDataAddr.valid :=
        portSelected(i) && io.source.readDataAddr.valid
    io.ports(i).readDataAddr.bits  := Mux(portSelected(i), readAddr, 0.U)
    io.ports(i).writeDataAddr.valid :=
        portSelected(i) && io.source.writeDataAddr.valid
    io.ports(i).writeDataAddr.bits  := Mux(portSelected(i), writeAddr, 0.U)
    io.ports(i).writeDataBits :=
        Mux(portSelected(i), io.source.writeDataBits, 0.U)
    io.ports(i).writeDataStrb :=
        Mux(portSelected(i), io.source.writeDataStrb, 0.U)
  }

  // ===================================================================
  // ③ 响应收集: 写响应立即, 读响应延迟1拍
  //
  // 写响应: 写操作不需要等 SRAM 响应 (SRAM 写总是成功),
  //         所以 writeResp 可以在当前周期立即返回
  // 读响应: SRAM 有 1-cycle 读延迟, 所以用 lastReadSelected 寄存器
  //         记住上一拍选了哪个端口, 本拍从该端口取读数据
  // ===================================================================
  io.source.writeResp := MuxUpTo1H(false.B, (0 until portCount).map(
      i => portSelected(i) -> io.ports(i).writeResp,
  ))

  // lastReadSelected: 寄存上一拍的读端口选择
  // 为什么需要? ports(i).readData 在请求发出后 1 拍才有效
  val lastReadSelected = RegInit(MakeInvalid(portIdxType))
  lastReadSelected := MuxUpTo1H(MakeInvalid(portIdxType), (0 until portCount).map(
    i => (portSelected(i) && io.source.readDataAddr.valid) ->
        MakeValid(true.B, i.U(portIdxBits.W))  // 只有当本拍有读请求时才更新 lastReadSelected, 否则保持不变 (MuxUpTo1H 保持寄存器值)
  ))
  // 根据上一拍的选择, 从对应端口取读数据
  io.source.readData := MuxUpTo1H(MakeInvalid(UInt(p.axi2DataBits.W)),
        (0 until portCount).map(i =>
            (lastReadSelected.valid && (lastReadSelected.bits === i.U)) ->
                io.ports(i).readData
        )
  )
}