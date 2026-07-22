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

// ============================================================================
// UncachedFetch.scala — 无缓存取指单元 (enableFetchL0=false 时使用)
// 直接通过 IBus 访问指令存储器, 无 L0 ICache
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._

class PredecodeOutput(p: Parameters) extends Bundle {
    val insts = Vec(p.fetchInstrSlots, new FetchInstruction(p)) // 预译码后送入指令缓冲的指令窗口
    val count = UInt(4.W)                              // 本次 fetch response 中有效指令数
    val nextPc = UInt(p.instructionBits.W)             // 下一次取指 PC
    val hasJumped = Bool()                             // 窗口内是否预判到跳转
}

class FetchResponse(p: Parameters) extends Bundle {
    val addr = UInt(p.fetchAddrBits.W)                 // IBus 请求原始地址
    val inst = Vec(p.fetchInstrSlots, UInt(p.instructionBits.W)) // 返回 cache line 拆出的指令槽
    val fault = Bool()                                 // IBus 取指异常
}

class Instruction(p: Parameters) extends Bundle {
    val addr = UInt(p.fetchAddrBits.W)                 // 指令 PC
    val inst = UInt(p.instructionBits.W)               // 指令编码
}

// Fetch 返回重排队列:
//   - newTx 记录已发出的 IBus 请求地址和 txid;
//   - busResp 按 txid 回填响应;
//   - commit 按发请求顺序提交给 FetchControl;
//   - flush 时标记旧请求为 cancelled, 等返回后丢弃并释放 txid。
class FetchReorderBuffer(txidBits: Int, addrBits: Int, dataBits: Int, capacity: Int, flowResponse: Boolean = false) extends Module {
  val ctrWidth = log2Ceil(capacity + 1)                // 队列元素计数位宽
  val indexWidth = log2Ceil(capacity)                  // 队列索引位宽

  // Structures

  class Response extends Bundle {
    val data = UInt(dataBits.W)                        // IBus 返回数据
    val fault = Bool()                                 // IBus fault 标志
  }

  class NewTx extends Bundle {
    val txid = UInt(txidBits.W)                        // 分配给 IBus 请求的 transaction id
    val addr = UInt(addrBits.W)                        // 请求地址
  }

  // This comes from the bus
  class ResponseWithTxid extends Bundle {
    val txid = UInt(txidBits.W)                        // 返回对应的 transaction id
    val resp = new Response()                          // 返回数据/异常
  }

  // This is just FetchResponse before instructions are separated.
  // I don't want the reorder buffer to understand the idea of instructions.
  class ResponseWithAddr extends Bundle {
    val addr = UInt(addrBits.W)                        // 原始请求地址
    val resp = new Response()                          // 原始返回响应
  }

  class Entry extends Bundle {
    val txid = UInt(txidBits.W)                        // 此 entry 追踪的 txid
    val addr = UInt(addrBits.W)                        // 此 entry 对应的请求地址
    val resp = Valid(new Response())                   // 响应是否已回填

    def asResponse: ResponseWithAddr = MakeWireBundle[ResponseWithAddr](
        new ResponseWithAddr,
        _.addr -> addr,
        _.resp -> resp.bits,
    )
  }
  object Entry {
    def apply(): Entry = MakeWireBundle[Entry](
      new Entry,
      _.txid -> 0.U,
      _.addr -> 0.U,
      _.resp -> MakeInvalid(new Response),
    )
  }

  // IO

  val io = IO(new Bundle {
    val newTx = Flipped(Decoupled(new NewTx()))        // 新发出的 IBus 请求
    // We always consume the resp. It is discarded if nothing matches.
    val busResp = Flipped(Valid(new ResponseWithTxid())) // IBus 返回响应, 若 txid 不匹配则丢弃
    val commit = Decoupled(new ResponseWithAddr())     // 按请求顺序提交的响应
    // Allocator should always have space for what it allocated.
    val freeTxid = Valid(UInt(txidBits.W))             // 可释放回 txid allocator 的 txid
    val flush = Input(Bool())                          // 取消所有已发未提交的请求
  })

  class State extends Bundle {
    val queue = Vec(capacity, new Entry)               // 顺序队列, entry 顺序等于请求发出顺序
    val nElem = UInt(ctrWidth.W)                       // 队列中有效 entry 数
    val nCancelled = UInt(ctrWidth.W)                  // 队头起被 flush 取消的 entry 数

    def valids = VecInit.tabulate(capacity) (_.U < nElem) // entry 是否在队列有效范围内

    def trimPrecondition = {
      val noOverflow = nElem <= capacity.U              // 队列元素不能超过容量
      val nCancelledReasonable = nCancelled <= nElem    // cancelled 数不能超过 entry 数
      val noDuplicateTxid = !VecInit.tabulate(capacity, capacity) { (i, j) =>
        (i != j).B && state.valids(i) && state.valids(j) && state.queue(i).txid === state.queue(j).txid
      }.exists(x => x.exists(y => y))

      noOverflow && nCancelledReasonable && noDuplicateTxid
    }

    def commonPrecondition = {
      val dontNeedTrim = nCancelled === 0.U || queue(0).resp.valid // cancelled 队头若未返回, 需要先等待/trim

      trimPrecondition && dontNeedTrim
    }

    def trySaveResponse(busResp: ResponseWithTxid): (State, Bool) = {
      val founds = VecInit.tabulate(capacity) {i =>
        valids(i) && (busResp.txid === queue(i).txid)  // 找到返回 txid 对应的 entry
      }
      // Resp cannot match two tx.
      val duplicateTxid = founds.count(x => x) > 1.U
      // Tx cannot get two resp.
      val badResponse = VecInit.tabulate(capacity) {i =>
        founds(i) && queue(i).resp.valid
      }.exists(x => x)
      val precondition = commonPrecondition && !duplicateTxid && !badResponse

      val accepted = Mux(precondition, founds.exists(x => x), WireDefault(Bool(), DontCare))
      val result = Mux(precondition, Mux(accepted, MakeWireBundle[State](
          new State,
          _ -> this,
          _.queue(founds.indexWhere(x => x)).resp -> MakeValid(busResp.resp),
      ), this), State.unreachable())

      (result, accepted)
    }

    def enq(tx: NewTx): State = {
      val precondition = commonPrecondition && nElem < capacity.U // 有空间才允许入队

      val index = nElem(indexWidth - 1, 0)             // 新 entry 放在队尾
      Mux(precondition, MakeWireBundle[State](
          new State,
          _ -> this,
          _.queue(index).txid -> tx.txid,
          _.queue(index).addr -> tx.addr,
          _.queue(index).resp.valid -> false.B,
          // _.queue(index).resp.bits is untouched
          _.nElem -> (nElem + 1.U),
      ), State.unreachable())
    }

    def deq(): State = {
      val precondition = commonPrecondition && nElem > 0.U // 队列非空才允许出队

      Mux(precondition, MakeWireBundle[State](
          new State,
          _ -> this,
          _.queue -> VecInit.tabulate(capacity) {i =>
            if (i + 1 < capacity)
              Mux((i + 1).U < nElem, queue(i + 1), queue(i))
            else queue(i)
          },
          _.nElem -> (nElem - 1.U),
          _.nCancelled -> Mux(nCancelled > 0.U, nCancelled - 1.U, 0.U),
      ), State.unreachable())
    }

    def flush(): State = {
      // 不立即清空 entry, 而是把现有 entry 标记为 cancelled; 之后等响应返回再释放 txid。
      Mux(commonPrecondition, MakeWireBundle[State](
          new State,
          _ -> this,
          _.nCancelled -> nElem,
      ), State.unreachable())
    }

    def maybeTrim(): State = {
      // From the front, discard all cancelled entries without resp
      val keepCancelled = VecInit.tabulate(capacity) {i =>
        (i.U < nCancelled) && queue(i).resp.valid      // 已取消但响应已返回的 entry 需要走释放路径
      }
      val hasKeep = keepCancelled.exists(x => x)
      val offset = Mux(hasKeep, keepCancelled.indexWhere(x => x), nCancelled) // 可直接丢弃的 cancelled 前缀长度

      // Note it's not commonPrecondition here
      Mux(trimPrecondition, MakeWireBundle[State](
          new State,
          _ -> this,
          _.queue -> VecInit.tabulate(capacity) {i =>
            Mux(i.U < nElem - offset, queue(i.U + offset(indexWidth - 1, 0)), queue(i))
          },
          _.nElem -> (nElem - offset),
          _.nCancelled -> (nCancelled - offset),
      ), State.unreachable())
    }
  }
  object State {
    def apply() = MakeWireBundle[State](
        new State,
        _.queue -> VecInit.fill(capacity)(Entry()),
        _.nElem -> 0.U,
        _.nCancelled -> 0.U,
    )

    def unreachable() = MakeWireBundle[State](
        new State,
        _.queue -> DontCare,
        _.nElem -> DontCare,
        _.nCancelled -> DontCare,
    )
  }

  val state = RegInit(State())

  // ---- Stage 1: 处理 bus response ----
  val badResponse = io.busResp.valid && VecInit.tabulate(capacity) {i =>
    state.valids(i) && state.queue(i).resp.valid && state.queue(i).txid === io.busResp.bits.txid
  }.exists(x => x)                                      // 同一个 txid 不允许重复返回
  val s1Precondition = state.commonPrecondition && !badResponse
  assert(s1Precondition)
  val (stateAfterResp, respFound) = state.trySaveResponse(io.busResp.bits) // 匹配则写入对应 entry
  // BusResp takes priority here because s1Reject cannot depend on io.flush.
  val s1Reject = io.busResp.valid && !respFound         // 无匹配的响应直接释放 txid
  val s1State = Mux(s1Precondition, Mux(io.busResp.valid, stateAfterResp, state), State.unreachable())

  // ---- Stage 2: 按顺序提交队头 response ----
  val s2Src = if (flowResponse) s1State else state      // 是否允许 response 当拍直通到 commit
  // Prevent io.commit.valid from depending on io.commit.valid
  val s2Valid = !s1Reject && s2Src.valids(0) && s2Src.nCancelled === 0.U && s2Src.queue(0).resp.valid // 队头已返回且未取消
  val s2Commit = io.commit.fire                         // 下游接受 commit
  val s2Precondition = s2Src.commonPrecondition && (!s2Commit || s2Valid)
  assert(s2Precondition)
  val s2State = Mux(s2Precondition, Mux(s2Commit, s1State.deq(), s1State), State.unreachable())

  // ---- Stage 3: 处理 flush ----
  val s3Precondition = s2State.commonPrecondition
  assert(s3Precondition)
  val s3State = Mux(s3Precondition, Mux(io.flush, s2State.flush().maybeTrim(), s2State), State.unreachable())

  // ---- Stage 4: 丢弃 cancelled response ----
  val s4Discard = !s1Reject && !s2Commit && s3State.valids(0) && s3State.nCancelled > 0.U // cancelled 队头可释放
  val s4Precondition = s3State.commonPrecondition && (!s4Discard || s3State.queue(0).resp.valid)
  assert(s4Precondition)
  val s4State = Mux(s4Precondition, Mux(s4Discard, s3State.deq().maybeTrim(), s3State), State.unreachable())

  // ---- Stage 5: 接收新 transaction ----
  val s5Ready = !s4State.valids(capacity - 1)           // 队尾未占用表示有空间
  val s5Fire = io.newTx.fire                            // 新请求入队
  val s5Precondition = s4State.commonPrecondition && (!s5Fire || s5Ready)
  assert(s5Precondition)
  val s5State = Mux(s5Precondition, Mux(s5Fire, s4State.enq(io.newTx.bits), s4State), State.unreachable())

  assert(s5State.commonPrecondition)
  state := s5State

  io.newTx.ready := s5Ready                             // 对 Fetcher 的入队 ready
  io.commit.valid := s2Valid                            // 对 FetchControl 的顺序响应 valid
  io.commit.bits := s2Src.queue(0).asResponse           // 提交队头响应
  val freeTxidUsage = VecInit(Seq(s1Reject, s2Commit, s4Discard)).count(x => x) // 每拍最多释放一个 txid
  assert(freeTxidUsage <= 1.U)
  io.freeTxid := MuxUpTo1H(MakeInvalid(0.U(txidBits.W)), Seq(
      s1Reject -> MakeValid(io.busResp.bits.txid),      // 无匹配 response 的 txid
      s2Commit -> MakeValid(s2Src.queue(0).txid),       // 正常 commit 的 txid
      s4Discard -> MakeValid(s3State.queue(0).txid),    // flush 丢弃的 txid
  ))
}

// TODO(atv): Privatize this and FetchControl
// Module which is responsible for performing
// memory fetches which are requested by
// `FetchControl`.
class Fetcher(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val ctrl = Flipped(Irrevocable(UInt(p.fetchAddrBits.W))) // FetchControl 发来的取指地址
    val flushTx = Input(Bool())                       // flush/branch 后取消旧 transaction
    val fetch = Decoupled(new FetchResponse(p))       // 顺序化后的 fetch response
    val ibus = new IBusIO(p)                          // 外部指令总线
  })

  val lsb = log2Ceil(p.fetchDataBits / 8)             // IBus line 内 byte offset 位数
  assert((p.fetchDataBits == 128 && lsb == 4) || (p.fetchDataBits == 256 && lsb == 5))

  val maxConcurrentTx = 2                             // 最多允许 2 个未完成取指请求
  val txidAllocator = Module(new IndexAllocatorShifting(maxConcurrentTx)) // txid 分配/回收

  // The reorder buffer does not flow the response. This serves as the delay
  // cycle to break the rdata->addr loop.
  // TODO(davidgao): upgrade ibus and move the delay upstream.
  val reorderBuffer = Module(new FetchReorderBuffer(
      txidBits=txidAllocator.width,
      addrBits=p.fetchAddrBits,
      dataBits=p.fetchDataBits,
      capacity=maxConcurrentTx,
      flowResponse=false,
  ))

  val canStartFetch = io.ctrl.valid && reorderBuffer.io.newTx.ready && txidAllocator.io.alloc.valid // 地址/队列/txid 都可用
  // The fetch request goes through without stopping.
  io.ibus.valid := canStartFetch                       // 对 IBus 发起读请求
  io.ibus.addr := Cat(io.ctrl.bits(p.fetchAddrBits - 1, lsb), 0.U(lsb.W)) // IBus 请求按 line 对齐

  val ibusAddrFire = io.ibus.fire                      // IBus 地址握手成功
  // TODO(davidgao): Add txid to ibus interface
  // io.ibus.txid := txidAllocator.io.alloc.bits
  txidAllocator.io.alloc.ready := ibusAddrFire         // 请求发出后消耗 txid
  reorderBuffer.io.newTx.valid := ibusAddrFire         // 同步把请求登记进 ROB
  reorderBuffer.io.newTx.bits.addr := io.ctrl.bits     // 保存未对齐原始 PC
  reorderBuffer.io.newTx.bits.txid := txidAllocator.io.alloc.bits
  // TODO(davidgao): remove this adapter when we decouple data from addr on ibus
  reorderBuffer.io.busResp.valid := RegNext(ibusAddrFire, false.B) // 当前 IBus 假设下一拍返回
  reorderBuffer.io.busResp.bits.txid := RegNext(txidAllocator.io.alloc.bits) // 返回 txid 延迟一拍
  reorderBuffer.io.busResp.bits.resp.data := io.ibus.rdata       // 返回数据
  reorderBuffer.io.busResp.bits.resp.fault := RegNext(io.ibus.fault.valid) // fault 与请求对齐
  reorderBuffer.io.commit.ready := io.fetch.ready       // 下游 ready 反压 commit
  reorderBuffer.io.flush := io.flushTx                  // flush 取消旧请求
  io.ctrl.ready := ibusAddrFire                         // 请求发出后接受 ctrl 地址

  txidAllocator.io.free.valid := reorderBuffer.io.freeTxid.valid // ROB 释放 txid
  txidAllocator.io.free.bits := reorderBuffer.io.freeTxid.bits

  io.fetch.valid := reorderBuffer.io.commit.valid       // 顺序化 response 有效
  io.fetch.bits := MakeWireBundle[FetchResponse](
      new FetchResponse(p),
      _.addr -> reorderBuffer.io.commit.bits.addr,      // 原始请求地址
      _.inst -> UIntToVec(reorderBuffer.io.commit.bits.resp.data, p.instructionBits), // line 拆成指令槽
      _.fault -> reorderBuffer.io.commit.bits.resp.fault, // fetch fault
  )
}

class FetchControl(p: Parameters) extends Module {
    val io = IO(new Bundle {
        val fetchFault = Valid(UInt(32.W))             // 取指异常和异常 PC
        val csr = new CsrInIO(p)                       // reset PC 等 CSR 输入
        val iflush = Input(Valid(UInt(32.W)))          // IFlush/debug 重定向 PC
        val branch = Input(Valid(UInt(p.fetchAddrBits.W))) // BRU 真实分支重定向 PC
        val fetchData = Flipped(Decoupled(new FetchResponse(p))) // Fetcher 返回的 line
        val linkPort = Flipped(new RegfileLinkPortIO)  // ret 预测使用的返回地址

        val fetchAddr = Irrevocable(UInt(p.fetchAddrBits.W)) // 发给 Fetcher 的取指地址
        val flushTx = Output(Bool())                   // 请求 Fetcher 取消旧 transaction
        val bufferRequest = DecoupledVectorIO(new FetchInstruction(p), p.fetchInstrSlots) // 写入指令缓冲
    })

    val lsb = log2Ceil(p.fetchDataBits / 8)            // line 内 byte offset 位数

    // Decode 阶段轻量分支预测:
    //   JAL 一定 taken;
    //   后向条件分支预测 taken;
    //   JALR/RET 在 Predecode 中单独处理。
    def PredictJump(addr: UInt, inst: UInt): ValidIO[UInt] = {
      assert(p.instructionBits == 32)
      val jal = inst === BitPat("b????????????????????_?????_1101111") // JAL
      val immjal = Cat(Fill(12, inst(31)), inst(19,12), inst(20), inst(30,21), 0.U(1.W)) // J-type imm
      val bxx = inst === BitPat("b???????_?????_?????_???_?????_1100011") &&
                  inst(31) && inst(14,13) =/= 1.U     // 后向条件分支预测 taken
      val immbxx = Cat(Fill(20, inst(31)), inst(7), inst(30,25), inst(11,8), 0.U(1.W)) // B-type imm
      val immed = Mux(inst(2), immjal, immbxx)         // opcode bit 选择 J/B 立即数

      val valid = jal || bxx                           // 是否预测跳转
      val target = addr + immed                        // 预测目标

      MakeValid(valid, target)
    }

    // 将一条 IBus 返回 line 转换成 FetchInstruction 窗口, 并计算下一次 fetch PC。
    def Predecode(fetchResponse: FetchResponse): PredecodeOutput = {
      val addr = fetchResponse.addr                    // 原始请求 PC
      val lsb = log2Ceil(p.fetchDataBits / 8)
      assert((p.fetchDataBits == 128 && lsb == 4) || (p.fetchDataBits == 256 && lsb == 5))
      val baseAddr = addr(p.fetchAddrBits - 1, lsb)    // line 对齐高位
      val startElem = addr(lsb - 1, lsb - log2Ceil(p.fetchInstrSlots)) // 请求 PC 在 line 内的起始指令槽

      val insts = ShiftVectorRight(fetchResponse.inst, startElem) // 把起始槽移到 lane0
      val addrs = VecInit.tabulate(p.fetchInstrSlots)(i =>
          addr + (i * 4).U
      )                                                 // 对应每个输出槽的连续 PC

      val branchTargets = VecInit.tabulate(p.fetchInstrSlots)(i =>
          PredictJump(addrs(i), insts(i))
      )                                                 // 每条指令的预测跳转目标

      val validsIn = VecInit.tabulate(p.fetchInstrSlots)(i =>
          i.U < p.fetchInstrSlots.U - startElem
      )                                                 // line 中从 startElem 到末尾才有效
      val jumped = VecInit.tabulate(p.fetchInstrSlots)(i =>
          validsIn(i) && branchTargets(i).valid
      )                                                 // 有效槽内预测跳转
      val firstJumpOH = VecInit(PriorityEncoderOH(jumped)) // 只采用最早的预测跳转

      // Have we jumped before the instruction i
      val hasJumpedBefore = VecInit(jumped.scan(false.B)(_||_).take(p.fetchInstrSlots)) // i 之前是否已有跳转

      val validsOut = VecInit.tabulate(p.fetchInstrSlots)(i =>
          validsIn(i) && !hasJumpedBefore(i)
      )                                                 // 跳转之后的顺序指令无效

      val nextFetchPc = MuxUpTo1H(Cat(baseAddr + 1.U, 0.U(lsb.W)),
          (0 until p.fetchInstrSlots).map(i => firstJumpOH(i) -> branchTargets(i).bits)) // 默认下一 line, 跳转时用目标

      val result = MakeWireBundle[PredecodeOutput](
          new PredecodeOutput(p),
          _.insts -> VecInit.tabulate(p.fetchInstrSlots)(i =>
              MakeWireBundle[FetchInstruction](
                  new FetchInstruction(p),
                  _.addr -> addrs(i),                  // 指令 PC
                  _.inst -> insts(i),                  // 指令 bits
                  _.brchFwd -> jumped(i),              // 标记 Fetch 已按该跳转前推
              )
          ),
          _.count -> validsOut.count(x => x),          // 写入 buffer 的有效条数
          _.nextPc -> nextFetchPc,                     // 下一次 fetch PC
          _.hasJumped -> jumped.reduce(_||_),          // 窗口内是否有预测跳转
      )

      result
    }

    val predecode = Predecode(io.fetchData.bits)       // 当前返回 line 的预译码结果

    io.bufferRequest.bits := predecode.insts           // 指令窗口写入 InstructionBuffer

    val pastBranchOrFlush = RegInit(false.B)           // 过去发生过 branch/flush, 尚未发出新 fetch 清理
    val currentBranchOrFlush = io.iflush.valid || io.branch.valid // 本拍发生重定向
    val ongoingBranchOrFlush = pastBranchOrFlush || currentBranchOrFlush // 旧结果需要丢弃

    // If we have faulted we should stop making any new attempts until a branch resolves it.
    val faulted = RegInit(false.B)                     // fetch fault sticky, 等分支重定向清除
    val fetchFaultValid = (faulted || (io.fetchData.valid && io.fetchData.bits.fault)) &&
        !io.branch.valid
    io.fetchFault := MakeValid(fetchFaultValid, io.fetchData.bits.addr) // 上报 fault PC
    faulted := fetchFaultValid                         // 无分支恢复时保持 fault

    val sufficientBuffer = io.bufferRequest.nReady >= predecode.count // 指令缓冲空间足够容纳本窗口
    io.fetchData.ready := sufficientBuffer || fetchFaultValid // fault 响应可直接消费
    // Send out results. All branch or flush, current or past, will make us
    // discard results.
    // TODO(davidgao): ForceZero it when invalid?
    val writeToBuffer = io.fetchData.fire && !fetchFaultValid && !ongoingBranchOrFlush // 正常写指令缓冲
    val nValid = Mux(writeToBuffer, predecode.count, 0.U) // 写入条数
    io.bufferRequest.nValid := nValid

    val ongoingFetch = RegInit(MakeInvalid(UInt(p.fetchAddrBits.W))) // 已提交给 fetchAddr 但尚未 ready 的地址

    // PC is initialized with the CSR value below upon leaving reset.
    val pc = RegInit(MakeInvalid(UInt(32.W)))          // 当前 fetch PC; reset 后第一拍从 CSR 初始化

    // Past branch or flush doesn't block us from initiating new fetches.
    val blockNewFetch = !pc.valid ||  // We're stil in reset.
                        currentBranchOrFlush ||
                        ongoingFetch.valid ||
                        fetchFaultValid                 // 这些情况暂停发起新 fetch

    val pcFetched = RegInit(false.B)                   // 当前 pc 是否已经发起过 fetch, 用于顺序 speculative fetch
    pcFetched := MuxCase(pcFetched, Seq(
        (!pc.valid) -> !blockNewFetch,  // We're leaving reset.
        (io.iflush.valid || io.branch.valid) -> false.B,
        (writeToBuffer && predecode.hasJumped) -> !blockNewFetch,
        // Speculative fetch
        (!blockNewFetch) -> true.B,
    ))
    val pcNext = MuxCase(pc.bits, Seq(
        (!pc.valid) -> Cat(io.csr.value(0)(31,2), 0.U(2.W)),  // 离开 reset: 从 CSR reset PC 初始化
        io.iflush.valid -> io.iflush.bits,             // IFlush/debug 重定向优先
        io.branch.valid -> io.branch.bits,             // BRU 真实分支重定向
        (writeToBuffer && predecode.hasJumped) -> predecode.nextPc, // 预译码跳转前推
        // Speculative fetch
        (!blockNewFetch && pcFetched) -> Cat(pc.bits(31, lsb) + 1.U, 0.U(lsb.W)), // 顺序取下一 line
    ))
    // PC will always be valid as soon as we leave reset.
    pc := MakeValid(pcNext)                            // 更新 fetch PC

    val fetch = MuxUpTo1H(MakeInvalid(UInt(p.fetchAddrBits.W)), Seq(
        ongoingFetch.valid -> ongoingFetch,            // 若上一地址未被 Fetcher 接收, 继续保持
        !blockNewFetch -> MakeValid(pcNext),           // 否则发出新地址
    ))
    ongoingFetch := Mux(io.fetchAddr.ready, MakeInvalid(UInt(p.fetchAddrBits.W)), fetch) // ready 后清除 pending

    // All branch or flush are cleared once we're able to initiate a new fetch.
    val newFetchInitiated = fetch.valid && !ongoingFetch.valid // 本拍发起新的有效 fetch
    pastBranchOrFlush := ongoingBranchOrFlush && !newFetchInitiated // 新 fetch 发起后清除旧 flush 状态

    // Similarly, whenever we write a fetched jump, we need to flush until we initiate a new fetch
    val newJump = writeToBuffer && predecode.hasJumped // 新写入的窗口里包含预测跳转
    val pendingJump = RegInit(false.B)                 // 等待为预测跳转目标发起新 fetch
    pendingJump := (pendingJump || newJump) && !newFetchInitiated

    io.fetchAddr <> MakeIrrevocable(fetch)             // 发给 Fetcher 的不可撤销地址
    io.flushTx := ongoingBranchOrFlush || pendingJump || newJump // 重定向/预测跳转时取消旧请求
}

class UncachedFetch(p: Parameters) extends FetchUnit(p) {
  // TODO(derekjchow): Make Bru use valid interface
  // 多 lane BRU 重定向取最早有效 lane; 若没有分支则为 invalid。
  val branch = MuxCase(
      MakeInvalid(UInt(p.fetchAddrBits.W)),
      (0 until p.instructionLanes).map(i =>
          io.branch(i).valid -> MakeValid(io.branch(i).value)
      ))

  // ---- FetchControl: PC 选择、预译码、指令缓冲写入控制 ----
  val ctrl = Module(new FetchControl(p))
  ctrl.io.csr <> io.csr                                // reset PC 等 CSR 输入
  ctrl.io.branch := branch                             // BRU 真实跳转目标
  val debug_iflush = Seq(
    io.debug_pc.valid -> MakeValid(io.debug_pc.bits),  // debug 写 DPC 后重定向
  )
  ctrl.io.iflush := MuxCase(MakeInvalid(UInt(p.fetchAddrBits.W)), Seq(
    io.iflush.valid -> MakeValid(io.iflush.pcNext),    // 普通 IFlush 重定向
  ) ++ debug_iflush)
  ctrl.io.linkPort := io.linkPort                      // ret 预测返回地址
  // TODO(derekjchow): Maybe do something with back pressure?
  io.iflush.ready := true.B                            // 无缓存 fetch 直接接受 iflush

  // ---- Fetcher: 将 FetchControl 地址转换成 IBus 请求并顺序返回 ----
  val fetcher = Module(new Fetcher(p))
  fetcher.io.ctrl <> ctrl.io.fetchAddr                 // 取指地址流
  fetcher.io.flushTx := ctrl.io.flushTx                // 取消旧 transaction
  ctrl.io.fetchData <> fetcher.io.fetch                // 返回 fetch line
  fetcher.io.ibus <> io.ibus                           // 外部 IBus

  // ---- InstructionBuffer: 缓冲预译码后的指令窗口, 对 Dispatch 输出 4 lane ----
  val window = p.fetchInstrSlots * 2                   // 缓冲深度为两个 fetch 窗口
  val instructionBuffer = Module(new InstructionBuffer(
      new FetchInstruction(p), p.fetchInstrSlots, window))
  instructionBuffer.io.feedIn <> ctrl.io.bufferRequest // FetchControl 写入指令窗口
  io.inst.lanes <> instructionBuffer.io.out.take(4)    // Dispatch 只消费 instructionLanes=4
  instructionBuffer.io.flush := io.iflush.valid || branch.valid || io.debug_pc.valid // 重定向清空缓冲

  val pc = RegInit(0.U(p.fetchAddrBits.W))             // 对外观测的当前取指 PC
  pc := Mux(instructionBuffer.io.out(0).valid, instructionBuffer.io.out(0).bits.addr, pc)
  io.pc := pc                                          // 输出 lane0 当前 PC
  io.fault := ctrl.io.fetchFault                       // 输出取指异常
}
