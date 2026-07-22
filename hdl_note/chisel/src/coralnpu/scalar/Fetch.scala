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


// ============================================================================
// Fetch.scala — 取指单元 (含 L0 ICache: 1KB 直接映射)
// L0: 32索引×1路×256-bit, 预译码分支预测(backward taken/forward not)
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import _root_.circt.stage.ChiselStage

object Fetch {
  def apply(p: Parameters): Fetch = {
    return Module(new Fetch(p))
  }
}

// Instruction fetch unit, with an integrated L0 cache.
// Fetch 负责从 IBus 填充 L0 指令缓存, 按 instruction lane 输出连续指令,
// 并根据 Decode 预判分支/Execute 真实分支结果修正下一拍取指地址。
// abstract class FetchUnit(p: Parameters) extends Module {
//   val io = IO(new Bundle {
//     val csr = new CsrInIO(p)
//     val debug_pc = Flipped(Valid(UInt(p.fetchAddrBits.W)))
//     val ibus = new IBusIO(p)
//     val inst = new FetchIO(p)
//     val branch = Flipped(Vec(p.instructionLanes, new BranchTakenIO(p)))
//     val linkPort = Flipped(new RegfileLinkPortIO)
//     val iflush = Flipped(new IFlushIO(p))
//     val pc = UInt(p.fetchAddrBits.W)
//     val fault = Output(Valid(UInt(32.W)))
//   })
// }
class Fetch(p: Parameters) extends FetchUnit(p) {
  // Stub: 当前 Fetch 不向外报告 pc/fault, 保留接口默认值。
  io.pc := 0.U                                         // 取指 PC 观测口未使用
  io.fault := MakeInvalid(0.U(32.W))                   // Fetch 不产生异常
  // This is the only compiled and tested configuration (at this time).
  assert(p.fetchAddrBits == 32)                        // 当前只验证 32-bit PC
  assert(p.fetchDataBits == 256)                       // IBus 每次取 256-bit, 即 8 条 32-bit 指令

  //双缓冲slice，无 ready 旁路，无 valid 旁路
  val aslice = Slice(UInt(p.fetchAddrBits.W), true)    // IBus 请求地址缓冲, 切断 ready/valid 时序路径
  val readAddr = Reg(UInt(p.fetchAddrBits.W))           // 已发出的 IBus 请求地址
  val readDataEn = RegInit(false.B)                     // 下一拍 IBus rdata 是否可写入 L0

  val readAddrEn = io.ibus.valid && io.ibus.ready       // IBus 接收请求
  val readData = io.ibus.rdata                          // IBus 返回的 256-bit cache line
  readDataEn := readAddrEn && !io.iflush.valid          // flush 周期丢弃返回数据

  io.iflush.ready := !aslice.io.out.valid               // 请求队列清空后才允许完成 IFlush

  // ---- L0 cache 地址划分 ----
  // | 字段       |    值 | 含义                            |
  // | ---------- | ---: | ----------------------------- |
  // | line 大小  | 32 B | 每 line 8 条指令                  |
  // | `lanes`    |    8 | 每个 cache line 有 8 条 32-bit 指令 |
  // | `indices`  |   32 | 1KB / 32B = 32 行              |
  // | `indexLsb` |    5 | byte offset 为 addr[4:0]       |
  // | `indexMsb` |    9 | index 为 addr[9:5]             |
  // | `tagLsb`   |   10 | tag 为 addr[31:10]             |
  val lanes    = p.fetchDataBits / p.instructionBits   // 每条 cache line 含多少条指令
  val indices  = p.fetchCacheBytes * 8 / p.fetchDataBits // L0 cache line 数
  val indexLsb = log2Ceil(p.fetchDataBits / 8)          // line 内 byte offset 低位
  val indexMsb = log2Ceil(indices) + indexLsb - 1       // index 高位
  val tagLsb   = indexMsb + 1                           // tag 低位
  val tagMsb   = p.fetchAddrBits - 1                    // tag 高位
  val indexCountBits = log2Ceil(indices - 1)            // index 位宽检查

  if (p.fetchCacheBytes == 1024) {
    assert(indexLsb == 5)                               // 256-bit line = 32B, offset[4:0]
    assert(indexMsb == 9)                               // 32 个 index: addr[9:5]
    assert(tagLsb == 10)                                // tag 从 addr[31:10]
    assert(tagMsb == 31)
    assert(indices == 32)
    assert(indexCountBits == 5)
    assert(lanes == 8)
  }

  val l0valid = RegInit(0.U(indices.W))                 // 每个 index 的 valid bit
  val l0req   = RegInit(0.U(indices.W))                 // l0req(i)=1 表示第 i 行已经发出了 IBus miss 请求，但数据还没回来。
  val l0tag   = Reg(Vec(indices, UInt((tagMsb - tagLsb + 1).W))) // 直接映射 tag RAM
  val l0data  = Reg(Vec(indices, UInt(p.fetchDataBits.W)))       // 直接映射 data RAM

  // ---- 指令输出寄存器 ----
  val instValid = RegInit(VecInit(Seq.fill(p.instructionLanes)(false.B))) // 各 lane 指令有效
  val instAddr  = Reg(Vec(p.instructionLanes, UInt(p.instructionBits.W))) // 各 lane 指令 PC
  val instBits  = Reg(Vec(p.instructionLanes, UInt(p.instructionBits.W))) // 各 lane 指令 bits

  //instAligned1 = instAligned0 + 32
  val instAligned0 = Cat(instAddr(0)(31, indexLsb), 0.U(indexLsb.W)) // 当前 cache line 对齐地址,低 5 bit 清零
  val instAligned1 = instAligned0 + Cat(1.U, 0.U(indexLsb.W))        // 下一条 cache line 对齐地址,低 5 bit 清零

  val instIndex0 = instAligned0(indexMsb, indexLsb)      // 当前 line index
  val instIndex1 = instAligned1(indexMsb, indexLsb)      // 下一 line index

  val instTag0 = instAligned0(tagMsb, tagLsb)            // 当前 line tag
  val instTag1 = instAligned1(tagMsb, tagLsb)            // 下一 line tag

  val l0valid0 = l0valid(instIndex0)                     // 当前 line valid
  val l0valid1 = l0valid(instIndex1)                     // 下一 line valid

  val l0tag0 = VecAt(l0tag, instIndex0)                  // 当前 line tag 读出
  val l0tag1 = VecAt(l0tag, instIndex1)                  // 下一 line tag 读出

  val match0 = l0valid0 && instTag0 === l0tag0           // 当前 line 命中
  val match1 = l0valid1 && instTag1 === l0tag1           // 下一 line 命中

  // ---- IBus miss 请求生成 ----
  // Do not request entries that are already inflight.
  // Perform a branch tag lookup to see if target is in cache.
  //计算 JAL target,如果 target line 不在 L0 中，就提前发 IBus 请求
  def Predecode(addr: UInt, op: UInt): (Bool, UInt) = {
    val jal = op === BitPat("b????????????????????_?????_1101111") // JAL 可在 Fetch 侧预取目标
    val immed = Cat(Fill(12, op(31)), op(19,12), op(20), op(30,21), 0.U(1.W)) // J-type 立即数
    val target = addr + immed                              // JAL 目标地址
    (jal, target)
  }

  val preBranch = (0 until p.instructionLanes).map(x => Predecode(instAddr(x), instBits(x))) // 当前输出指令预译码
  val preBranchTakens = preBranch.map { case (taken, target) => taken }        // 是否发现 JAL
  val preBranchTargets = preBranch.map { case (taken, target) => target }      // JAL 目标

  val preBranchTaken = (0 until p.instructionLanes).map(i =>
    io.inst.lanes(i).valid && preBranchTakens(i)).reduce(_ || _) // 任意有效 lane 发现 JAL

  val preBranchTarget = MuxCase(//如果任意有效 lane 中发现 JAL，则 preBranchTaken=1。
    preBranchTargets(p.instructionLanes - 1),
    (0 until p.instructionLanes - 1).map(i => preBranchTakens(i) -> preBranchTargets(i))
  )                                                           // 选择最靠前的 JAL 目标

  val preBranchTag = preBranchTarget(tagMsb, tagLsb)          // 预取目标 tag
  val preBranchIndex = preBranchTarget(indexMsb, indexLsb)    // 预取目标 index

  //io.branch 来自 BRU 的真实重定向结果。这里取每个 lane 分支目标的 tag/index。
  val branchTags = io.branch.map(x => x.value(tagMsb, tagLsb))       // BRU 真实跳转目标 tag
  val branchIndices = io.branch.map(x => x.value(indexMsb, indexLsb)) // BRU 真实跳转目标 index

  // | 信号            | 含义                      |
  // | ------------- | ----------------------- |
  // | `l0valids(x)` | 第 x 个 BRU 目标 index 是否有效 |
  // | `l0validP`    | 预取 JAL 目标 index 是否有效    |
  val l0valids = (0 until p.instructionLanes).map(x => l0valid(branchIndices(x))) // 各 BRU 目标 valid
  val l0validP  = l0valid(preBranchIndex)                         // 预取目标 valid

  val l0tags = (0 until p.instructionLanes).map(x => VecAt(l0tag, branchIndices(x))) // 各 BRU 目标 tag
  val l0tagP  = VecAt(l0tag, preBranchIndex)                       // 预取目标 tag

  // 对每个 lane 的真实分支目标判断是否需要发 IBus miss 请求。
  // | 条件                         | 含义              |
  // | -------------------------- | --------------- |
  // | `io.branch(x).valid`       | BRU 真实重定向有效     |
  // | `!l0req(branchIndices(x))` | 该 index 没有在途请求  |
  // | `tag 不匹配 或 valid=0`     | 目标 line 不在 L0 中 |
  val reqBValid = (0 until p.instructionLanes).map(x =>
      io.branch(x).valid && !l0req(branchIndices(x)) &&
      (branchTags(x) =/= l0tags(x) || !l0valids(x)))     // BRU 目标 miss 且没有在途请求
  val prevValid = io.branch.map(_.valid).scan(false.B)(_||_) // 生成前缀 OR，用于判断前面 lane 是否已有有效分支。
  val reqs = (0 until p.instructionLanes).map(x => reqBValid(x) && !prevValid(x)) // 只有最早有效分支可以发 miss 请求。

  //如果当前窗口中有 JAL，且 JAL target 不在 L0 中，就提前请求 target line。
  val reqP = preBranchTaken && !l0req(preBranchIndex) && (preBranchTag =/= l0tagP || !l0validP) // JAL 目标预取
  val req0 = !match0 && !l0req(instIndex0)              // 当前 line miss，并且没有在途请求，则请求当前 line。
  val req1 = !match1 && !l0req(instIndex1)              // 下一 line miss，并且没有在途请求，则请求下一 line。

  //如果任意请求有效，且没有 IFlush，则向 aslice 送请求。
  // 请求优先级: Execute 分支目标 > Fetch 预译码 JAL 目标 > 当前 line > 下一 line。
  aslice.io.in.valid := (reqs ++ Seq(reqP, req0, req1)).reduce(_ || _) && !io.iflush.valid
  aslice.io.in.bits := MuxCase(instAligned1,
    (0 until p.instructionLanes).map(x => reqs(x) -> Cat(io.branch(x).value(31,indexLsb), 0.U(indexLsb.W))) ++
    Array(
      reqP -> Cat(preBranchTarget(31,indexLsb), 0.U(indexLsb.W)),
      req0 -> instAligned0,
    )
  )

  //当 IBus 接收请求时，保存发出的地址。后面数据返回时，用它写 L0 的 tag/index。
  when (readAddrEn) {
    readAddr := io.ibus.addr                             // 记录本次发出的 line 地址, 用于返回写 cache
  }

  io.ibus.valid := aslice.io.out.valid                   // 对外发起 IBus 读请求
  aslice.io.out.ready := io.ibus.ready || io.iflush.valid // flush 时丢弃待发请求
  io.ibus.addr := aslice.io.out.bits                     // 对齐后的 cache line 地址

  // ---- L0 cache 状态更新 ----
  // initialize tags to 1s as 0xfffxxxxx are invalid instruction addresses
  val l0validClr = WireInit(0.U(indices.W))             // 本拍清除 valid 的 index mask
  val l0validSet = WireInit(0.U(indices.W))             // 本拍置位 valid 的 index mask
  val l0reqClr = WireInit(0.U(indices.W))               // 本拍清除 inflight 的 index mask
  val l0reqSet = WireInit(0.U(indices.W))               // 本拍置位 inflight 的 index mask

  val readIdx = readAddr(indexMsb, indexLsb)            // IBus 返回数据对应 index

  for (i <- 0 until indices) {
    when (readDataEn && readIdx === i.U) {
      l0tag(i.U)  := readAddr(tagMsb, tagLsb)           // 写入返回 line 的 tag
      l0data(i.U) := readData                           // 写入返回 line 的 data
    }
  }

  // 返回数据写入 L0 后：
  // 该 index valid = 1
  // 该 index inflight request = 0
  when (readDataEn) {
    val bits = UIntToOH(readIdx, indices)               // 返回 line 的 one-hot index
    l0validSet := bits                                  // 返回后 line 有效
    l0reqClr   := bits                                  // 返回后不再 inflight
  }

  //如果 flush，则所有 bit 清除。
  when (io.iflush.valid) {
    val clr = ~(0.U(l0validClr.getWidth.W))             // IFlush 清空整个 L0 和所有在途标记
    l0validClr := clr
    l0reqClr   := clr
  }

  //当 miss 请求成功进入 aslice，标记对应 index 已有在途请求。
  when (aslice.io.in.valid && aslice.io.in.ready) {
    l0reqSet := UIntToOH(aslice.io.in.bits(indexMsb, indexLsb), indices) // 新发请求置 inflight
  }

  //如果同一个 bit 同时 set 和 clear，clear 优先生效，因为最后 & ~l0validClr。
  when (l0validClr =/= 0.U || l0validSet =/= 0.U) {
    l0valid := (l0valid | l0validSet) & ~l0validClr     // set/clear 合并更新 valid
  }

  when (l0reqClr =/= 0.U || l0reqSet =/= 0.U) {
    l0req := (l0req | l0reqSet) & ~l0reqClr             // set/clear 合并更新 inflight
  }

  // ---- 顺序取指输出推进 ----
  // Do not use the next instruction address directly in the lookup, as that
  // creates excessive timing pressure. We know that the match is either on
  // the old line or the next line, so can late mux on lookups of prior.
  // Widen the arithmetic paths and select from results.
  val fetchEn = Wire(Vec(p.instructionLanes, Bool()))   // 各 lane 本拍是否被 Dispatch 消耗

  //如果某 lane 的 valid && ready，说明该 lane 指令被 Dispatch 接收。
  for (i <- 0 until p.instructionLanes) {
    fetchEn(i) := io.inst.lanes(i).valid && io.inst.lanes(i).ready // valid/ready 握手成功
  }

  //根据 Dispatch 本拍消耗了多少条连续指令，决定下一拍窗口前移几条。
  // fsel 编码本拍消耗了多少条连续指令:
  //   fsel(0) 表示没有消耗; 其它位表示从 lane0 起消耗到某个 lane。
  val fsela = Cat((0 until p.instructionLanes).reverse.map(x =>
    (x until p.instructionLanes).map(y =>
      (if (y == x) { fetchEn(y) } else { !fetchEn(y) })
    ).reduce(_ && _)
  ))

  //如果所有 lane 都没有被消耗，则 fselb=1。
  val fselb = (0 until p.instructionLanes).map(x => !fetchEn(x)).reduce(_ && _)// fselb=1 表示没有消耗, fselb=0 表示至少消耗了 lane0。
  //fsel 是一个 instructionLanes+1 位的 one-hot 编码。
  val fsel = Cat(fsela, fselb)// fsel 的值表示本拍消耗了多少条连续指令, 以及是否消耗了 lane0。

  // 构造两组地址：
  // 第一组：当前窗口地址
  // 第二组：当前窗口地址 + N*4
  // 如果 4 lane，当前窗口：
  // A, A+4, A+8, A+12
  // 第二组：
  // A+16, A+20, A+24, A+28
  // 两组合起来，方便根据消耗数量选择平移后的窗口。
  val nxtInstAddrOffset = instAddr.map(x => x) ++ instAddr.map(x => x + (p.instructionLanes * 4).U) // 保留原窗口和下一窗口
  // 根据 fsel 选择下一拍窗口地址。
  // 例子：4 lane 当前窗口：
  // A, A+4, A+8, A+12
  // 如果消耗 2 条，则下一窗口：
  // A+8, A+12, A+16, A+20
  //如果消费了 2 条，下一拍 lane0 应该取 nxtInstAddrOffset(2)
  //nxtInstAddrOffset(2) = A+8,所以 lane0 下一拍就是 A+8。
  val nxtInstAddr = (0 until p.instructionLanes).map(i =>
      (0 until (p.instructionLanes + 1)).map(
          j => MuxOR(fsel(j), nxtInstAddrOffset(j + i))).reduce(_|_)) // 根据消耗数量平移取指窗口

  //用于判断下一窗口是否跨 line，以及是否命中。
  val nxtInstIndex0 = nxtInstAddr(0)(indexMsb, indexLsb)              // 下一窗口首指令 index
  val nxtInstIndex1 = nxtInstAddr(p.instructionLanes - 1)(indexMsb, indexLsb) // 下一窗口末指令 index

  //如果本拍 IBus 返回的数据正好是当前 line，则可以直接用 readData，不用等写入 L0 后再读。
  val readFwd0 =
      readDataEn && readAddr(31,indexLsb) === instAligned0(31,indexLsb) // 返回数据旁路当前 line
  val readFwd1 =
      readDataEn && readAddr(31,indexLsb) === instAligned1(31,indexLsb) // 返回数据旁路下一 line

  val nxtMatch0Fwd = match0 || readFwd0                   // 当前 line 命中或本拍返回
  val nxtMatch1Fwd = match1 || readFwd1                   // 下一 line 命中或本拍返回

  //这里用 instIndex0(0) 比较，利用当前 line 和下一 line 的相对关系减少重新查 tag 的时序压力。
  val nxtMatch0 =
      Mux(instIndex0(0) === nxtInstIndex0(0), nxtMatch0Fwd, nxtMatch1Fwd) // 下一窗口首 line 有效性
  val nxtMatch1 =
      Mux(instIndex0(0) === nxtInstIndex1(0), nxtMatch0Fwd, nxtMatch1Fwd) // 下一窗口末 line 有效性

  val nxtInstValid = Wire(Vec(p.instructionLanes, Bool())) // 顺序路径下一窗口 valid

  val nxtInstBits0 = Mux(readFwd0, readData, VecAt(l0data, instIndex0)) // 当前 line 指令数据
  val nxtInstBits1 = Mux(readFwd1, readData, VecAt(l0data, instIndex1)) // 下一 line 指令数据
  val nxtInstBits = Wire(Vec(16, UInt(p.instructionBits.W)))            // 两条 line 展平为 16 条指令

  //把两条 256-bit line 拆成 16 条 32-bit 指令。
  for (i <- 0 until 8) {
    val offset = 32 * i                              // 32-bit 指令在 256-bit line 内的偏移
    nxtInstBits(i + 0) := nxtInstBits0(31 + offset, offset) // 当前 line 第 i 条
    nxtInstBits(i + 8) := nxtInstBits1(31 + offset, offset) // 下一 line 第 i 条
  }

  // Decode 预判分支目标在 L0 中命中时, 直接从 L0 取目标窗口, 避免等待 Execute 修正。
  def BranchMatchDe(valid: Bool, value: UInt):
      (Bool, UInt, Vec[UInt], Vec[UInt]) = {

    val addr = VecInit((0 until p.instructionLanes).map(x => value + (x * 4).U)) // 目标窗口连续 PC

    val match0 = l0valid(addr(0)(indexMsb,indexLsb)) &&
        addr(0)(tagMsb,tagLsb) === VecAt(l0tag, addr(0)(indexMsb,indexLsb)) //判断目标窗口首 line 是否命中。
    //判断目标窗口末 line 是否命中。如果窗口跨 line，则末尾 lane 需要 match1。
    val match1 = l0valid(addr(p.instructionLanes - 1)(indexMsb,indexLsb)) &&
        addr(p.instructionLanes - 1)(tagMsb,tagLsb) === VecAt(l0tag, addr(p.instructionLanes - 1)(indexMsb,indexLsb)) // 目标末 line 命中

    val vvalid = VecInit((0 until p.instructionLanes).map(x =>
      Mux(addr(0)(4,2) <= (7 - x).U, match0, match1))) // 跨 line 时后半 lane 依赖 match1

    val muxbits0 = VecAt(l0data, addr(0)(indexMsb,indexLsb))                  // 目标首 line 数据
    val muxbits1 = VecAt(l0data, addr(p.instructionLanes - 1)(indexMsb,indexLsb)) // 目标末 line 数据
    val muxbits = Wire(Vec(16, UInt(p.instructionBits.W)))                    // 两条 line 展平

    for (i <- 0 until 8) {
      val offset = 32 * i
      muxbits(i + 0) := muxbits0(31 + offset, offset)
      muxbits(i + 8) := muxbits1(31 + offset, offset)
    }

    //保存最终目标窗口每个 lane 的指令 bits。
    val bits = Wire(Vec(p.instructionLanes, UInt(p.instructionBits.W)))
    for (i <- 0 until p.instructionLanes) {
      val idx = Cat(addr(0)(5) =/= addr(i)(5), addr(i)(4,2)) // 选择首 line/末 line + line 内指令
      bits(i) := VecAt(muxbits, idx)                        // 目标窗口第 i 条指令
    }

    (valid, vvalid.asUInt, addr, bits)
  }

  // Execute 阶段 BRU 已给出真实跳转结果时, 优先用真实目标覆盖 Fetch 窗口。
  def BranchMatchEx(branch: Vec[BranchTakenIO]):
      (Bool, UInt, Vec[UInt], Vec[UInt]) = {
    val valid = branch.map(x => x.valid).reduce(_ || _) // 任意 lane 发生真实重定向

    //选择最早有效分支目标。
    val addrBase = MuxCase(branch(branch.length - 1).value, (0 until branch.length - 1).map(x => branch(x).valid -> branch(x).value)) // 选择最早有效分支目标
    //以真实重定向 PC 为起点生成连续取指窗口。
    val addr = VecInit((0 until branch.length).map(x => addrBase + (x * 4).U)) // 真实目标窗口连续 PC

    val match0 = l0valid(addr(0)(indexMsb,indexLsb)) &&
        addr(0)(tagMsb,tagLsb) === VecAt(l0tag, addr(0)(indexMsb,indexLsb)) // 目标首 line 命中
    val match1 = l0valid(addr(branch.length - 1)(indexMsb,indexLsb)) &&
        addr(branch.length - 1)(tagMsb,tagLsb) === VecAt(l0tag, addr(branch.length - 1)(indexMsb,indexLsb)) // 目标末 line 命中

    val vvalid = VecInit((0 until branch.length).map(x =>
      Mux(addr(0)(4,2) <= (7 - x).U, match0, match1))) // 跨 line 时后半 lane 依赖 match1

    val muxbits0 = VecAt(l0data, addr(0)(indexMsb,indexLsb)) // 目标首 line 数据
    val muxbits1 = VecAt(l0data, addr(branch.length - 1)(indexMsb,indexLsb)) // 目标末 line 数据
    val muxbits = Wire(Vec(16, UInt(p.instructionBits.W))) // 两条 line 展平

    for (i <- 0 until 8) {
      val offset = 32 * i
      muxbits(i + 0) := muxbits0(31 + offset, offset)
      muxbits(i + 8) := muxbits1(31 + offset, offset)
    }

    val bits = Wire(Vec(branch.length, UInt(p.instructionBits.W)))
    for (i <- 0 until branch.length) {
      val idx = Cat(addr(0)(5) =/= addr(i)(5), addr(i)(4,2)) // 选择首 line/末 line + line 内指令
      bits(i) := VecAt(muxbits, idx)                        // 目标窗口第 i 条指令
    }

    (valid, vvalid.asUInt, addr, bits)
  }
  
  //该函数用于决定是否在 Decode/Fetch 侧提前前推控制流。
  def PredecodeDe(addr: UInt, op: UInt): (Bool, UInt) = {
    val jal = op === BitPat("b????????????????????_?????_1101111") // JAL: 无条件跳转
    val ret = op === BitPat("b000000000000_00001_000_00000_1100111") &&
                io.linkPort.valid                         // ret: jalr x0, x1, 0 且 linkPort 有返回地址,linkPort 来自 Regfile 的 x1/ra：
    val bxx = op === BitPat("b???????_?????_?????_???_?????_1100011") &&
                op(31) && op(14,13) =/= 1.U              // 后向条件分支预测 taken, 部分比较类型排除
    val immjal = Cat(Fill(12, op(31)), op(19,12), op(20), op(30,21), 0.U(1.W)) // J-type 立即数
    val immbxx = Cat(Fill(20, op(31)), op(7), op(30,25), op(11,8), 0.U(1.W))  // B-type 立即数
    val immed = Mux(op(2), immjal, immbxx)                // 根据 opcode 选择 J/B 立即数
    val target = Mux(ret, io.linkPort.value, addr + immed) // ret 用 linkPort, 其它用 PC+imm
    (jal || ret || bxx, target)
  }

  //对每个当前输出 lane 的指令做预译码。
  //拆出每个 lane 是否预判 taken 和目标地址。
  val brchDe = (0 until p.instructionLanes).map(x => PredecodeDe(instAddr(x), instBits(x))) // Decode 预判分支
  val brchTakensDe = brchDe.map { case (taken, target) => taken }   // 预判 taken mask
  val brchTargetsDe = brchDe.map { case (taken, target) => target } // 预判目标

  //如果某个被 Dispatch 接收的 lane 是预判 taken，则 brchTakenDeOr=1。
  val brchTakenDeOr = (0 until p.instructionLanes).map(x =>
    io.inst.lanes(x).ready && io.inst.lanes(x).valid && brchTakensDe(x)
  ).reduce(_ || _)                                           // 被消费的 lane 中是否有预判跳转

  //选择最早预判 taken 的 lane 的目标。
  val brchTargetDe = MuxCase(brchTargetsDe(p.instructionLanes - 1),
    (0 until p.instructionLanes - 1).map(x => brchTakensDe(x) -> brchTargetsDe(x))
  )                                                          // 选择最靠前的预判目标

  val (brchTakenDe, brchValidDe, brchAddrDe, brchBitsDe) =
      BranchMatchDe(brchTakenDeOr, brchTargetDe)             // Decode 预判目标窗口

  val (brchTakenEx, brchValidEx, brchAddrEx, brchBitsEx) =
      BranchMatchEx(io.branch)                               // Execute 真实目标窗口


  // brchValidDeMask 把预判分支之后的 lane 屏蔽掉, 避免同拍输出分支后的顺序指令。
  val brchValidDeMask =
      Cat((0 until p.instructionLanes).reverse.map(x =>
        if (x == 0) { true.B } else {
          (0 until x).map(y =>
            !brchTakensDe(y)
          ).reduce(_ && _)
        }
      ))

  // brchFwd 标记哪个 lane 发生了 Decode 预判前推, 后续 BRU 用它判断是否需要纠正。
  //如果 lane k 出现 Decode 预判 taken 分支，
  //则 lane k 后面的顺序指令不再对 Dispatch valid。
  //会进入 Dispatch/BRU，成为 BruCmd.fwd。BRU 用它判断：真实 taken 是否和 Fetch 已走方向一致。
  val brchFwd =
    Cat((0 until p.instructionLanes).reverse.map(x =>
      brchTakensDe(x) && (if (x == 0) { true.B } else { (0 until x).map(y => !brchTakensDe(y)).reduce(_ && _) })
    ))

  for (i <- 0 until p.instructionLanes) {
    // 1, 11, 111, ...: lane i 有效要求从 lane0 到 lane i 都命中。
    nxtInstValid(i) := Mux(
      nxtInstAddr(0)(4,2) <= (7 - i).U,
      nxtMatch0,
      nxtMatch1)

    val nxtInstValidUInt = nxtInstValid.asUInt
    // 更新优先级: Execute 真实分支 > Decode 预判分支 > 顺序推进; IFlush 强制无效。
    instValid(i) := Mux(brchTakenEx, brchValidEx(i,0) === ~0.U((i+1).W),
                    Mux(brchTakenDe, brchValidDe(i,0) === ~0.U((i+1).W),
                    nxtInstValidUInt(i,0) === ~0.U((i+1).W))) && !io.iflush.valid

    // PC 同样按 Execute > Decode > 顺序推进的优先级选择。
    instAddr(i) := Mux(brchTakenEx, brchAddrEx(i),
                   Mux(brchTakenDe, brchAddrDe(i), nxtInstAddr(i)))

    // The (2,0) bits are the offset within the base line plus the next line.
    // The (3) bit of the index must factor the base difference of addresses
    // instAddr and nxtInstAddr which are line aligned.
    //顺序路径下，从两条 line 展开的 nxtInstBits 中选哪条指令。更新指令 bits，优先级与 PC/valid 一致。
    val idx = Cat(instAddr(0)(5) =/= nxtInstAddr(i)(5), nxtInstAddr(i)(4,2)) // 顺序路径选择两条 line 中的指令
    // 指令 bits 与 PC/valid 保持同样的优先级。
    instBits(i) := Mux(brchTakenEx, brchBitsEx(i),
                   Mux(brchTakenDe, brchBitsDe(i),
                   VecAt(nxtInstBits, idx)))
  }

  // This pattern of separate when() blocks requires resets after the data.
  //复位时，从 CSR 给出的 reset PC 开始构造连续取指窗口。
  when (reset.asBool) {
    val addr = Cat(io.csr.value(0)(31,2), 0.U(2.W))       // reset PC 来自 CSR, 按 4B 对齐
    instAddr := (0 until p.instructionLanes).map(i => addr + (4 * i).U) // 初始化连续取指窗口
  }

  // ---- 输出到 Dispatch ----
  for (i <- 0 until p.instructionLanes) {
    io.inst.lanes(i).valid := instValid(i) & brchValidDeMask(i) // 预判分支之后的 lane 不输出
    io.inst.lanes(i).bits.addr  := instAddr(i)                  // 指令 PC
    io.inst.lanes(i).bits.inst  := instBits(i)                  // 指令编码
    io.inst.lanes(i).bits.brchFwd := brchFwd(i)                 // Decode 是否已前推分支
  }

  // ---- 基本一致性检查 ----
  // Fetch 输出窗口必须保持连续 PC。
  for (i <- 1 until p.instructionLanes) {
    assert(instAddr(0) + (4 * i).U === instAddr(i))
  }

  assert(fsel.getWidth == (p.instructionLanes + 1))       // fsel 位宽 = 消耗 0..N 条
  assert(PopCount(fsel) <= 1.U)                           // fsel 必须 one-hot 或全 0

  val instValidUInt = instValid.asUInt                    // valid 必须从 lane0 连续向后
  val instLanesReady = Cat((0 until p.instructionLanes).reverse.map(x => io.inst.lanes(x).ready)) // ready 也必须连续
  for (i <- 0 until p.instructionLanes - 1) {
    assert(!(!instValidUInt(i) && (instValidUInt(p.instructionLanes - 1, i + 1) =/= 0.U)))
    assert(!(!instLanesReady(i) && (instLanesReady(p.instructionLanes - 1, i + 1) =/= 0.U)))
  }
}

object EmitFetch extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new Fetch(p), args)
}
