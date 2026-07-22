// ============================================================================
// AxiSlave.scala — AXI4 Slave → Fabric 协议转换
//
// 将外部 AXI4 Master 请求转换为内部 Fabric 协议 (读写分离):
//   - 读/写地址通过 CoralNPURRArbiter 仲裁 (Queue(2) 缓冲)
//   - 支持 AXI 突发: FIXED/INCR/WRAP, 地址自动递增
//   - 写路径: AXI Write Data(Queue(3)) → Fabric writeData → AXI Write Response
//   - 读路径: Fabric readDataAddr → 1拍后读回 → AXI Read Data(Queue(3))
//   - 故障检测: Fabric writeResp/readData.valid 区分 OKAY/SLVERR
//
// IO: axi(Flipped AXI) ↔ fabric ↔ periBusy(反压)


// 完整写事务例子

// 假设外部 AXI master 发起 2-beat INCR 写：

// AW addr = 0x2000
// AW len  = 1
// AW size = 2    // 4B per beat
// AW burst = INCR

// W beat0: data0, last=0
// W beat1: data1, last=1

// 处理过程：

// AW 进入 axiAddrCmd
// writeDataQueue 收到 W beat0 / beat1

// Beat 0:
//     Fabric writeDataAddr = 0x2000
//     Fabric writeDataBits = data0
//     cmdAddr -> 0x2004
//     不产生 B response，因为 last=0

// Beat 1:
//     Fabric writeDataAddr = 0x2004
//     Fabric writeDataBits = data1
//     cmdAddr -> 0x2008
//     last=1，生成 AXI B response
//     axiAddrCmd.ready = writeResponse.fire


// 完整读事务例子

// 假设外部 AXI master 发起 4-beat INCR 读：

// AR addr = 0x1000
// AR len  = 3
// AR size = 2    // 4B per beat
// AR burst = INCR
// Cycle 0:
//     AR 进入 Queue，addrArbiter 选中读命令
//     axiAddrCmd.valid = 1
//     cmdAddr = 0x1000

// Beat 0:
//     Fabric readDataAddr = 0x1000
//     readsIssued = 0
//     lastRead = false
//     cmdAddr -> 0x1004

// Beat 1:
//     Fabric readDataAddr = 0x1004
//     readsIssued = 1
//     lastRead = false
//     cmdAddr -> 0x1008

// Beat 2:
//     Fabric readDataAddr = 0x1008
//     readsIssued = 2
//     lastRead = false
//     cmdAddr -> 0x100c

// Beat 3:
//     Fabric readDataAddr = 0x100c
//     readsIssued = 3
//     lastRead = true
//     AXI R last = true
//     axiAddrCmd.ready = 1
// ============================================================================
// Copyright 2024 Google LLC
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

import bus._
import common._

/** RWAxiAddress — 读写仲裁后的 AXI 地址 + write 标志
 *  addr  — AXI 地址 (含 addr/id/len/size/burst 等)
 *  write — 1=写请求, 0=读请求 (从 arbiter.chosen 派生) */
class RWAxiAddress(p: Parameters) extends Bundle {
  val addr  = new AxiAddress(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)
  val write = Bool()                                             // 1=写, 0=读
}

/** ReadResult — 读请求的追踪信息: 事务 ID + 最后一拍标志 */
class ReadResult(idBits: Int) extends Bundle {
  val id   = UInt(idBits.W)                                     // AXI 事务 ID (用于读数据路由)
  val last = Bool()                                               // 突发最后一拍?
}

/** ReadResult 伴生对象 — 工厂方法 */
object ReadResult {
  def apply(idBits: Int, id: UInt, last: Bool): ReadResult = {
    val result = Wire(new ReadResult(idBits))
    result.id := id; result.last := last; result
  }
}

/** AxiSlave — 外部 AXI4 Master → 内部 Fabric 协议转换。
 *  支持 AXI 突发 (FIXED/INCR/WRAP), 读写地址通过 Round-Robin 仲裁。 */
class AxiSlave(p: Parameters) extends Module {
  val io = IO(new Bundle{
    val axi = Flipped(new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits))
    val fabric = new FabricIO(p)                                   // 内部 Fabric 输出
    val txnInProgress = Output(Bool())                             // 事务进行中 (供外部观测)
    val periBusy = Input(Bool())                                   // 外设忙 (暂停新事务)
  })

  // ---- 读写地址仲裁: Round-Robin (读=port0, 写=port1) ----
  // AXI 允许读地址和写地址独立到达，但内部 FabricIO 只有一组：
  // 这个模块一次只处理一个 AXI 命令流，所以必须先在读事务和写事务之间选一个。
  val addrArbiter = Module(new CoralNPURRArbiter(
      new AxiAddress(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits), 2))
  addrArbiter.io.in(0) <> Queue(io.axi.read.addr, 2)              // 读地址缓冲
  addrArbiter.io.in(1) <> Queue(io.axi.write.addr, 2)             // 写地址缓冲
  val axiAddr = Wire(Decoupled(new RWAxiAddress(p)))               // AXI 地址 + write 标志
  axiAddr.valid := addrArbiter.io.out.valid  //仲裁器输出有效
  axiAddr.bits.addr := addrArbiter.io.out.bits  //仲裁器输出有效
  axiAddr.bits.write := (addrArbiter.io.chosen === 1.U)           // chosen=1 → 写

  addrArbiter.io.out.ready := axiAddr.ready
  // Queue(1, pipe=true): pipe=true 使队列支持同周期读写 (无气泡), 减少 1 拍延迟
  // pipe=true 的意思是队列允许同周期入队和出队，减少一拍气泡。
  val axiAddrCmd = Queue(axiAddr, 1, pipe=true)
  val writeActive = axiAddrCmd.valid && axiAddrCmd.bits.write      // 当前命令是写
  val readActive  = axiAddrCmd.valid && !axiAddrCmd.bits.write     // 当前命令是读
  // cmdAddr: 突发传输的当前地址。新命令→取起始地址, 每拍→按突发类型更新
  //FabricIO 每次只发一拍访问，所以 AxiSlave 要把 AXI burst 拆成多次 Fabric 访问，并且每拍更新 cmdAddr。
  val cmdAddr = RegInit(0.U(p.axi2AddrBits.W))

  // ---- 写路径 ----
  val writeData = Queue(io.axi.write.data, 3)                      // 写数据缓冲 (深度3)
  val writeResponse = Wire(Decoupled(new AxiWriteResponse(p.axi2IdBits)))
  io.axi.write.resp <> Queue(writeResponse, 2)                     // 写响应缓冲

  // maybeWriteData: 条件满足但可能被 periBusy 阻止
  val maybeWriteData = writeActive && writeData.valid && writeResponse.ready
  io.fabric.writeDataAddr.valid := maybeWriteData                  // 向 Fabric 发出写请求
  io.fabric.writeDataAddr.bits  := cmdAddr
  io.fabric.writeDataBits := writeData.bits.data
  io.fabric.writeDataStrb := writeData.bits.strb

  writeData.ready := maybeWriteData && !io.periBusy               // periBusy=1 时阻止写

  // 写响应: 数据已发 + last=1 → 生成响应
  writeResponse.valid    := writeData.fire && writeData.bits.last
  writeResponse.bits.id   := axiAddrCmd.bits.addr.id
  writeResponse.bits.resp := Mux(io.fabric.writeResp,              // Fabric 写响应: 1=OKAY
      AxiResponseType.OKAY.asUInt, AxiResponseType.SLVERR.asUInt)

  // ---- 读路径 ----
  val readDataQueueSize = 3
  val readDataQueue = Module(new Queue(
      new AxiReadData(p.axi2DataBits, p.axi2IdBits), readDataQueueSize))
  val readData = readDataQueue.io.enq                              // 队列入口
  io.axi.read.data <> readDataQueue.io.deq                         // AXI 读数据 ← 队列

  val readIssued  = RegInit(MakeInvalid(new ReadResult(p.axi2IdBits))) // 上一拍是否向 Fabric 发出读请求，以及该读请求对应的 AXI ID/last
  val readsIssued = RegInit(0.U((axiAddrCmd.bits.addr.len.getWidth + 1).W))//当前 AXI burst 已经发出了多少拍读请求

  // maybeIssueRead: 队列至少有2空位时才尝试发读 (留余量防阻塞)
  //为了防止读响应一拍后回来时队列满，造成数据无法入队。
  val maybeIssueRead = readActive &&
      ((readDataQueueSize.U - readDataQueue.io.count) >= 2.U)
  val issueRead = maybeIssueRead && !io.periBusy                   //下游不忙，真正发出读 periBusy=1 阻止
  val readsIssuedNext = Mux(axiAddrCmd.fire, 0.U, readsIssued + issueRead)  //新命令→重置计数; 读进行中→计数加1
  val lastRead = (readsIssued === axiAddrCmd.bits.addr.len)        // 最后一拍?

  //readIssued 记录上一拍发出的读请求信息
  readIssued := MakeValid(
      issueRead, ReadResult(p.axi2IdBits, axiAddrCmd.bits.addr.id, lastRead))
  readsIssued := readsIssuedNext

  // 注意: 向 Fabric 发读请求用 maybeIssueRead (而非 issueRead)
  // 原因: 即使此次读被 periBusy 阻止, 下游仲裁器仍需看到 readDataAddr.valid
  //       以便它路由正确的 periBusy 信号回来 — periBusy 的"忙"信息依赖地址
  io.fabric.readDataAddr.valid := maybeIssueRead
  io.fabric.readDataAddr.bits  := cmdAddr

  // 读响应: 1 拍后从 Fabric 读回数据
  readData.valid := readIssued.valid
  readData.bits.data := io.fabric.readData.bits
  readData.bits.id   := readIssued.bits.id
  readData.bits.resp := Mux(io.fabric.readData.valid,              // Fabric 读有效→OKAY
      AxiResponseType.OKAY.asUInt, AxiResponseType.SLVERR.asUInt)
  readData.bits.last := readIssued.bits.last
  assert(!readIssued.valid || readDataQueue.io.enq.ready)          // 读数据必须能入队

  // ---- AXI 突发地址更新 ----
  // baseAddrMask: 按 size 对齐的基地址掩码 (用于 WRAP 边界检测)
  //baseAddrMask 的作用是清掉低 size 位，得到按 beat size 对齐的基地址。
  val baseAddrMask = VecInit((0 until axiAddrCmd.bits.addr.addr.getWidth).map(
      x => !(x.U < axiAddrCmd.bits.addr.size)))
  //cmdAddrBase = 起始地址按 4B 对齐后的地址
  val cmdAddrBase = axiAddrCmd.bits.addr.addr & baseAddrMask.asUInt
  //burst: AXI 突发类型 (FIXED/INCR/WRAP)
  val (burst, burstValid) = AxiBurstType.safe(axiAddrCmd.bits.addr.burst)
  val validBurst = axiAddrCmd.valid && burstValid
  // addrNext: 根据突发类型计算下一拍地址
  val addrNext = MuxUpTo1H(cmdAddr, Seq(
      (validBurst && (burst === AxiBurstType.FIXED)) -> cmdAddr,   // FIXED: 地址不变
      (validBurst && (burst === AxiBurstType.INCR)) ->             // INCR: 地址 + 2^size
          (cmdAddr + (1.U << axiAddrCmd.bits.addr.size)),
      (validBurst && (burst === AxiBurstType.WRAP)) -> {           // WRAP: 到达边界时回绕
          val newAddr = cmdAddr + (1.U << axiAddrCmd.bits.addr.size)
          val newAddrWrapped = Mux(
              newAddr >= cmdAddrBase + (p.axi2DataBits / 8).U,
              cmdAddrBase, newAddr)                                 // 回绕到基地址
          newAddrWrapped(31,0)
      }
  ))

  // cmdAddr 更新: 新命令→取地址; 读写进行中→addrNext
  cmdAddr := MuxCase(cmdAddr, Seq(
      axiAddr.fire -> axiAddr.bits.addr.addr,
      (writeActive && io.fabric.writeDataAddr.valid && !io.periBusy) -> addrNext,
      (readActive && io.fabric.readDataAddr.valid && !io.periBusy) -> addrNext,
  ))

  // 命令完成条件: 写→写响应发出, 读→最后一拍发出
  axiAddrCmd.ready := MuxCase(false.B, Seq(
      writeActive -> writeResponse.fire,
      readActive -> (issueRead && lastRead),
  ))
  io.txnInProgress := axiAddrCmd.valid                             // 事务进行中标志
}
