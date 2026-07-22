// ============================================================================
// RetirementBuffer.scala — 指令退役缓冲区 (Retirement Buffer)
//
// 管理从发射(dispatch)到退役(retire)的指令生命周期，保证按程序顺序提交。
//
// 指令生命周期: Dispatched → Completed → Retired
//   跟踪每条在飞指令的: 标量写回/浮点写回/向量写回/store完成/异常
//   mini 模式(mini=true): 简化版用于非验证模式，省面积
//
// IO: inst(输入指令)/targets(跳转目标)/writeAddr+Data(寄存器写回)/
//     fault(异常)/nSpace(剩余槽位)/nRetired(已退役)/empty/trapPending/debug
//
// 实现: CircularBufferMulti 存储指令信息 + resultBuffer 跟踪完成状态
//       + vectorWriteAccumulator 聚合向量写回
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

/** RetirementBufferIO — 退役缓冲区外部 IO
 *
 *  输入 (来自 Dispatch / LSU / FaultManager):
 *    inst          — 每 lane 发射的指令 (PC+指令字)
 *    targets       — BRU 计算的目标地址 (JAL/Bxx)
 *    jalrTargets   — JALR 目标地址
 *    jump/branch   — 是否跳转/分支
 *    storeComplete — store 操作完成的 PC (来自 LSU)
 *    writeAddr/Data Scalar — 标量寄存器写回地址/数据
 *    writeAddr/Data Float  — 浮点寄存器写回 (条件: enableFloat)
 *    writeAddr/Data Vector — 向量寄存器写回 (条件: enableRvv)
 *    fault         — 异常信息 (mepc/mtval/mcause/decode)
 *
 *  输出 (→ Dispatch / CSR / Debug):
 *    nSpace        — 剩余槽位数 (Dispatch 据此决定是否发射)
 *    nRetired      — 已退役指令数 (→ CSR 计数器)
 *    empty         — 缓冲区为空
 *    trapPending   — 有异常等待退役
 *    debug         — 退役指令的完整快照 (→ RVVI/调试) */
class RetirementBufferIO(p: Parameters) extends Bundle {
  val inst = Input(Vec(p.instructionLanes, Decoupled(new FetchInstruction(p))))
  val targets       = Input(Vec(p.instructionLanes, UInt(32.W)))
  val jalrTargets   = Input(Vec(p.instructionLanes, UInt(32.W)))
  val jump          = Input(Vec(p.instructionLanes, Bool()))
  val branch        = Input(Vec(p.instructionLanes, Bool()))
  val storeComplete = Input(Valid(UInt(32.W)))                   // LSU store 完成 (PC)
  val writeAddrScalar = Input(Vec(p.instructionLanes, new RegfileWriteAddrIO))
  val writeDataScalar = Input(Vec(p.instructionLanes + 2, Valid(new RegfileWriteDataIO)))
  val writeAddrFloat  = Option.when(p.enableFloat)(Input(new RegfileWriteAddrIO))
  val writeDataFloat  = Option.when(p.enableFloat)(Input(Vec(2, Valid(new RegfileWriteDataIO))))
  val writeAddrVector = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, new RegfileWriteAddrIO)))
  val writeDataVector = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, Valid(new VectorWriteDataIO(p)))))
  val fault = Input(Valid(new FaultManagerOutput))               // 异常输入
  val nSpace    = Output(UInt(32.W))                              // 剩余槽位
  val nRetired  = Output(UInt(log2Ceil(p.retirementBufferSize + 1).W))
  val empty     = Output(Bool())                                  // 缓冲区空
  val trapPending = Output(Bool())                                // 异常待退役
  val debug     = Output(new RetirementBufferDebugIO(p))          // 调试快照
}

/** RetirementBuffer — 指令退役缓冲区
 *
 *  该模块负责把乱序完成的执行结果重新整理成按序退役:
 *    1. Dispatch 发射时, 指令元信息进入 instBuffer。
 *    2. ALU/LSU/FPU/RVV 等单元完成后, 写回端口或 storeComplete/fault 更新 resultBuffer。
 *    3. 只有从队头开始连续完成的指令才会一起退役。
 *    4. 如果遇到 trap, 只退役到 trap 指令为止, 然后清空后续投机状态。
 *
 *  @param p    Parameters 配置
 *  @param mini 简化模式 (true=省面积, 不记录 inst/result) */
class RetirementBuffer(p: Parameters, mini: Boolean = false) extends Module {
  val io = IO(new RetirementBufferIO(p))
  val idxWidth = p.retirementBufferIdxWidth                     // 退役缓冲区索引位宽
  val noWriteRegIdx = ~0.U(idxWidth.W)                           // "无写回"空寄存器索引 (全1)
  val storeRegIdx   = (noWriteRegIdx - 1.U)                     // "store"空寄存器索引 (全1-1)

  /** Instruction — 退役缓冲区中每条在飞指令的跟踪信息 */
  class Instruction extends Bundle {
    val addr          = UInt(32.W)                               // PC 地址
    val inst          = if (mini) UInt(0.W) else UInt(32.W)     // 指令字 (mini模式省面积)
    val idx           = UInt(idxWidth.W)                         // 写回寄存器索引 (noWriteRegIdx=无写回)
    val trap          = Bool()                                   // 指令触发异常
    val isControlFlow = Bool()                                   // 是跳转或分支指令
    val isBranch      = Bool()                                   // 是条件分支
    val isVector      = Bool()                                   // 是向量操作
    val linkOk        = Bool()                                   // 控制流连续性检查通过
    val isEcall       = Bool()                                   // ECALL 指令
    val isMpause      = Bool()                                   // MPAUSE 指令
  }

  val storeComplete = Pipe(io.storeComplete)                     // 打 1 拍 (改善时序)

  val bufferSize = p.retirementBufferSize                        // 8 条在飞指令
  assert(bufferSize >= p.instructionLanes)
  assert(bufferSize >= io.writeDataScalar.length)

  // CircularBufferMulti: 多元素同时入队/出队的环形缓冲区
  // 最多同时入队 bufferSize 条, 同时出队 bufferSize 条
  val instBuffer = Module(new CircularBufferMulti(
      new Instruction, bufferSize, bufferSize))
  io.empty := instBuffer.io.nEnqueued === 0.U
  // 发射约束: 多 lane 必须从 lane0 开始连续 fire。
  // 例如 1110 合法, 1010/0111 非法; 这样环形缓冲区可以直接按 PopCount 入队。
  val instFires = io.inst.map(_.fire)
  val seenFalseV = (instFires.scanLeft(false.B) { (acc, curr) => acc || !curr }).drop(1)//
  assert(!(seenFalseV.zip(instFires).map({ case (seenFalse, fire) => seenFalse && fire }).reduce(_|_)))

  val decodeFaultValid = (io.fault.valid && io.fault.bits.decode) // decode 阶段发现的异常, 跟随当前发射组入队
  // noFire0Fault: fault 已经有效但 lane0 没有 fire, 并且不是 load/store 访存异常。
  // 这类异常需要人工构造一个 fault entry 塞进退役缓冲区, 让异常仍然按序提交。
  // load/store fault 由已有 LSU entry 在 update 阶段匹配 PC 处理, 不额外入队。
  val noFire0Fault = (io.fault.valid && !io.inst(0).fire && (io.fault.bits.mcause =/= 7.U) && (io.fault.bits.mcause =/= 5.U))
  val faultPc = io.fault.bits.mepc

  // regLast* — 跨发射周期跟踪预期 PC (mini 模式优化)
  // 用于验证 dispatch group 第一条指令的控制流连续性 (linkOk)
  // 如果取指单元送来的指令与预期目标不匹配 (如分支预测错误), linkOk=false → 最终触发异常
  val regLastTarget    = RegInit(0.U(32.W))                     // 上次发射的最后一个目标的预测 PC
  val regLastAddr      = RegInit(0.U(32.W))                     // 上次发射的最后一条指令的 PC
  val regLastIsBranch  = RegInit(false.B)                        // 上次最后一条是分支?

  /** dispatch — 将发射信息组装为 Instruction 跟踪记录
   *  关键逻辑: idx 的选择 (优先级: 浮点 > 向量 > 标量 > store) */
  def dispatch(
      finst: FetchInstruction,
      scalarAddr: RegfileWriteAddrIO,
      floatAddr: Option[RegfileWriteAddrIO],
      vectorAddr: Option[RegfileWriteAddrIO],
      isJump: Bool,
      isBranch: Bool,
      linkOk: Bool,
      isFault: Bool): Instruction = {
    val floatValid = floatAddr.map(_.valid).getOrElse(false.B)
    val fAddr = floatAddr.map(_.addr).getOrElse(0.U)

    val sValid = scalarAddr.valid
    val sAddr = scalarAddr.addr

    val vectorValid = vectorAddr.map(_.valid).getOrElse(false.B)
    val vAddr = vectorAddr.map(_.addr).getOrElse(0.U)

    // 根据 opcode/width 判断 store 类型。
    // 标量 store: opcode 0x23。
    val scalarStore = (finst.inst(6,0) === "b0100011".U)
    val width = finst.inst(14,12)
    // 浮点 store: opcode 0x27 且 width 为 001/010/011/100。
    // 分别对应 16/32/64/128 bit FP store。
    val floatStore = (finst.inst(6,0) === "b0100111".U) &&
                     (width === "b001".U || width === "b010".U ||
                      width === "b011".U || width === "b100".U)
    // 向量 store: opcode 0x27 且 width 为 000/101/110/111。
    // 分别对应 8/16/32/64 bit 元素宽度的 vector store。
    val vectorStore = (finst.inst(6,0) === "b0100111".U) &&
                      (width === "b000".U || width === "b101".U ||
                       width === "b110".U || width === "b111".U)
    val store = scalarStore || floatStore || vectorStore

    val instr = Wire(new Instruction)
    instr.addr := finst.addr
    instr.inst := finst.inst
    // idx 表示本指令等待哪个写回结果:
    //   noWriteRegIdx: 不写寄存器, 数据天然 ready;
    //   storeRegIdx: store 指令, 等 LSU 的 storeComplete;
    //   其他值: 等对应标量/浮点/向量写回端口。
    instr.idx := MuxCase(noWriteRegIdx, Seq(
      floatValid -> (fAddr +& p.floatRegfileBaseAddr.U),
      (vectorValid) -> (vAddr +& p.rvvRegfileBaseAddr.U),
      (sValid && sAddr =/= 0.U) -> sAddr,
      store -> storeRegIdx,
    ))
    instr.trap := isFault
    instr.isControlFlow := isJump || isBranch
    instr.isBranch := isBranch
    instr.isVector := vectorValid || vectorStore
    instr.linkOk := linkOk
    instr.isEcall := (finst.inst === 0x73.U)
    instr.isMpause := (finst.inst === 0x08000073.U)
    instr
  }

  /** fault — 为没有正常 fire 的异常构造一条退役缓冲区记录
   *
   *  异常仍然需要走 RetirementBuffer, 这样可以保证:
   *    - 前面更老的指令先完成/退役;
   *    - 异常指令退役后触发 flush;
   *    - debug/RVVI 能看到对应 PC 和指令信息。
   */
  def fault(
      finst: FetchInstruction,
      scalarAddr: RegfileWriteAddrIO,
      floatAddr: Option[RegfileWriteAddrIO],
      vectorAddr: Option[RegfileWriteAddrIO],
      isJump: Bool,
      isBranch: Bool): Instruction = {
    // 异常指令仍然复用 dispatch() 填好 isControlFlow/idx 等字段,
    // 这样 JAL link 写回、debug 输出等路径仍保持一致。
    val instr = dispatch(finst, scalarAddr, floatAddr, vectorAddr, isJump, isBranch,
                         linkOk = true.B, isFault = true.B)
    instr.addr := io.fault.bits.mepc
    // 只有 illegal instruction(mcause=2) 时 mtval 是指令编码;
    // 其他异常如地址错误时 mtval 通常是出错地址, 不能当指令字使用。
    instr.inst := Mux(!mini.B && io.fault.bits.mcause === 2.U, io.fault.bits.mtval, finst.inst)
    // 用 fault PC 重新检查与上一条已知控制流目标是否连续。
    instr.linkOk := (instr.addr === regLastTarget) || (regLastIsBranch && instr.addr === regLastAddr + 4.U)
    instr
  }

  // 将每个 dispatch lane 转换成 instBuffer 的入队数据。
  // decode fault 会附着在对应 PC 的 lane 上; noFire fault 只从 lane0 人工注入。
  val insts = (0 until p.instructionLanes).map(i => {
    val isDecodeFault = decodeFaultValid && (faultPc === io.inst(i).bits.addr)
    val isNoFireFault = (i == 0).B && noFire0Fault

    // linkOk 是轻量级控制流连续性校验:
    //   lane0 对照上一周期最后一条指令的预测目标;
    //   laneN 对照 laneN-1 的目标或分支 fallthrough。
    val linkOk = if (i == 0) {
        (io.inst(0).bits.addr === regLastTarget) || (regLastIsBranch && io.inst(0).bits.addr === regLastAddr + 4.U)
    } else {
        val prevIsJalr = (io.inst(i-1).bits.inst(6,0) === "b1100111".U)
        val prevTarget = Mux(prevIsJalr, io.jalrTargets(i-1), io.targets(i-1))
        val prevIsBranch = io.branch(i-1)
        (io.inst(i).bits.addr === prevTarget) || (prevIsBranch && io.inst(i).bits.addr === io.inst(i-1).bits.addr + 4.U)
    }

    val fAddr = io.writeAddrFloat.filter(_ => i == 0)
    val vAddr = io.writeAddrVector.map(_(i))
    Mux(isNoFireFault,
        fault(io.inst(i).bits, io.writeAddrScalar(i), fAddr, vAddr, io.jump(i), io.branch(i)),
        dispatch(io.inst(i).bits, io.writeAddrScalar(i), fAddr, vAddr, io.jump(i), io.branch(i), linkOk, isDecodeFault))
  })

  // regLast 更新: 取最后一条 fire 的指令信息, 用于下一周期的 linkOk 检查
  val hasFire    = instFires.reduce(_|_)
  val targetsList = (0 until p.instructionLanes).map(i => {
       val isJalr = (io.inst(i).bits.inst(6,0) === "b1100111".U)
       Mux(isJalr, io.jalrTargets(i), io.targets(i))             // JALR 用 jalrTarget, 其余用 target
  })
  val addrList   = io.inst.map(_.bits.addr)//
  val branchList = io.branch
  // PriorityMux(instFires.reverse, ...) — 取最后一条 fire 的指令的值
  regLastTarget    := Mux(hasFire, PriorityMux(instFires.reverse, targetsList.reverse), regLastTarget)
  regLastAddr      := Mux(hasFire, PriorityMux(instFires.reverse, addrList.reverse), regLastAddr)
  regLastIsBranch  := Mux(hasFire, PriorityMux(instFires.reverse, branchList.reverse), regLastIsBranch)

  // instBuffer 入队: fire 的指令数 + 异常指令 (可能未 fire)。
  // decodeFaultValid/noFire0Fault 为 Bool, +& 会把它们扩成 0/1 参与计数。
  val instsWithWriteFired = PopCount(io.inst.map(_.fire))
  instBuffer.io.enqValid := instsWithWriteFired +& (decodeFaultValid || noFire0Fault)
  io.nSpace := instBuffer.io.nSpace                              // 剩余槽位 → Dispatch

  for (i <- 0 until p.instructionLanes) {
    instBuffer.io.enqData(i) := insts(i)
  }
  for (i <- p.instructionLanes until bufferSize) {
    instBuffer.io.enqData(i) := 0.U.asTypeOf(instBuffer.io.enqData(i))
  }

  /** InstructionUpdate — resultBuffer 中每条指令的完成状态 */
  class InstructionUpdate extends Bundle {
    val result = if (mini) UInt(0.W) else UInt(dataWidth.W)       // 退役/debug 看到的写回数据
    val trap = Bool()                                             // 该 entry 是否异常
    val cfDone = Bool()                                           // 控制流检查是否完成
  }

  /** VectorWrite — RVV 一条指令可能产生多个 vreg 写回, 这里逐项累积 */
  class VectorWrite extends Bundle {
    val data = UInt(p.rvvVlen.W)                                  // 向量寄存器写回数据
    val idx = UInt(5.W)                                           // 向量寄存器号
  }

  // resultBuffer: 与 instBuffer 的 dataOut 顺序一一对应。
  // instBuffer 只保存指令元信息; resultBuffer 保存该指令是否已完成、是否 trap、写回结果。
  val dataWidth = if (mini) 0 else (if (p.enableRvv) p.lsuDataBits else 32)
  val resultBuffer = RegInit(VecInit(Seq.fill(bufferSize)(MakeInvalid(new InstructionUpdate))))

  // 向量写回累积器使用独立的环形指针:
  //   accEnqPtr 对应新入队指令的位置;
  //   accDeqPtr 对应当前队头。
  // 因为一条 RVV 指令可能分多次返回多个 vreg 写回, 需要在真正退役前把它们聚合起来。
  val accEnqPtr = RegInit(0.U(log2Ceil(bufferSize).W))
  val accDeqPtr = RegInit(0.U(log2Ceil(bufferSize).W))
  val vectorWriteAccumulator = Option.when(!mini && p.enableRvv)(
    RegInit(VecInit.fill(bufferSize)(VecInit.fill(8)(0.U.asTypeOf(Valid(new VectorWrite)))))
  )

  val vectorAccumulatorNext = Option.when(!mini && p.enableRvv)(
    Wire(Vec(bufferSize, Vec(8, Valid(new VectorWrite))))
  )
  val debugVectorWrites = Option.when(!mini && p.enableRvv)(
    Wire(Vec(bufferSize, Vec(8, Valid(new VectorWrite))))
  )
  if (!mini && p.enableRvv) {
      vectorAccumulatorNext.get := vectorWriteAccumulator.get
      debugVectorWrites.get := vectorWriteAccumulator.get
  }

  // 根据各执行单元写回结果计算下一拍 resultBuffer。
  // 注意: 这里只更新每个 entry 的完成状态; 真正退役后的右移在后面统一处理。
  val resultUpdate = Wire(Vec(bufferSize, Valid(new InstructionUpdate)))

  for (i <- 0 until bufferSize) {
    val bufferEntry = instBuffer.io.dataOut(i)
    // 不需要写回的指令只要控制流检查完成即可 dataReady;
    // store 指令没有寄存器写回, 但必须等 LSU storeComplete。
    val nonWritingInstr = bufferEntry.idx === noWriteRegIdx
    val storeInstr = bufferEntry.idx === storeRegIdx

    // 匹配各写回端口是否命中当前 entry:
    //   scalar/float 用统一扩展后的 idx 匹配;
    //   vector 指令优先用 uop_pc 匹配整条指令, 非 vector entry 则按寄存器号匹配。
    val scalarWriteIdxMap = io.writeDataScalar.map(
        x => x.valid && (x.bits.addr === bufferEntry.idx))
    val floatWriteIdxMap = io.writeDataFloat.map(y => y.map(
        x => x.valid && ((x.bits.addr +& p.floatRegfileBaseAddr.U) ===
            bufferEntry.idx))).getOrElse(Seq(false.B))
    val vectorWriteIdxMap = io.writeDataVector.map(y => y.map(
        x => x.valid && (
            (bufferEntry.isVector && !storeInstr && (x.bits.uop_pc === bufferEntry.addr)) ||
            (!bufferEntry.isVector && ((x.bits.addr +& p.rvvRegfileBaseAddr.U) === bufferEntry.idx))
        )
    )).getOrElse(Seq(false.B))
    // faultingInstr: FaultManager 给出的异常 PC 命中当前 entry。
    val faultingInstr = io.fault.valid && (bufferEntry.addr === faultPc)
    // validBufferEntry: 当前 i 位置确实已经入队, 防止空槽被误认为完成。
    val validBufferEntry = (i.U < instBuffer.io.nEnqueued)

    // 选择第一个命中的写回端口。正常情况下同一 entry 只应由一个端口提供最终写回。
    val scalarWriteIdx = PriorityEncoder(scalarWriteIdxMap)
    val floatWriteIdx = PriorityEncoder(floatWriteIdxMap)
    val vectorWriteIdx = PriorityEncoder(vectorWriteIdxMap)

    // RVV 只有最后一个 uop 写回时才认为整条向量指令完成。
    val vectorReady = io.writeDataVector.map(y => y.zip(vectorWriteIdxMap).map({ case (port, matchBool) =>
        matchBool && port.bits.last_uop_valid
    }).reduce(_|_)).getOrElse(false.B)

    if (!mini && p.enableRvv) {
       val pIdx = accDeqPtr + i.U

       // nextEntry 聚合当前周期所有 RVV 写回端口。
       // 每个 k 对应目标向量寄存器组内的一个寄存器偏移。
       val nextEntry = Wire(Vec(8, Valid(new VectorWrite)))

       val portMatches = Wire(Vec(p.instructionLanes, Bool()))
       val portTargets = Wire(Vec(p.instructionLanes, UInt(3.W)))

       for (j <- 0 until p.instructionLanes) {
           val port = io.writeDataVector.get(j)
           portMatches(j) := vectorWriteIdxMap(j)
           val absAddr = port.bits.addr +& p.rvvRegfileBaseAddr.U
           val offset = absAddr - bufferEntry.idx
           portTargets(j) := offset(2,0)
       }

       for (k <- 0 until 8) {
           val hits = Wire(Vec(p.instructionLanes, Bool()))
           val datas = Wire(Vec(p.instructionLanes, UInt(p.rvvVlen.W)))
           val idxs = Wire(Vec(p.instructionLanes, UInt(5.W)))

           for (j <- 0 until p.instructionLanes) {
               val port = io.writeDataVector.get(j)
               hits(j) := portMatches(j) && (portTargets(j) === k.U)
               datas(j) := port.bits.data
               idxs(j) := port.bits.addr
           }

           val anyHit = hits.asUInt.orR
           nextEntry(k).valid := Mux(anyHit, true.B, vectorWriteAccumulator.get(pIdx)(k).valid)
           nextEntry(k).bits.data := Mux(anyHit, PriorityMux(hits, datas), vectorWriteAccumulator.get(pIdx)(k).bits.data)
           nextEntry(k).bits.idx := Mux(anyHit, PriorityMux(hits, idxs), vectorWriteAccumulator.get(pIdx)(k).bits.idx)
       }
       // 只更新有效 entry 的累积器; 空槽保持原值。
       vectorAccumulatorNext.get(pIdx) := Mux(validBufferEntry, nextEntry, vectorWriteAccumulator.get(pIdx))
       debugVectorWrites.get(pIdx) := Mux(validBufferEntry, nextEntry, vectorWriteAccumulator.get(pIdx))
    }

    // ---- 数据就绪判定: dataReady = 标量写回 | 浮点写回 | 向量就绪 | 无写回指令 | store完成 ----
    val dataReady = (scalarWriteIdxMap.reduce(_|_) || floatWriteIdxMap.reduce(_|_) ||
                     vectorReady || nonWritingInstr ||
                     (storeInstr && storeComplete.valid && storeComplete.bits === bufferEntry.addr))
    val isControlFlow = bufferEntry.isControlFlow

    // ---- 控制流完整性检查 (cfMatch): 验证下一条指令的 PC 是否与本条指令预测一致 ----
    val nextValid = if (i < bufferSize - 1) ((i.U +& 1.U) < instBuffer.io.nEnqueued) else false.B
    val nextAddr = if (i < bufferSize - 1) instBuffer.io.dataOut(i + 1).addr else 0.U
    val nextAddrValid = nextValid || noFire0Fault || io.inst(0).valid

    // linkOk 检查: 下一条指令的 PC 是否 = 本条预测的目标 (targetMatch)
    //                          或 = 本条 PC+4 (fallthroughMatch, 仅分支允许)
    val lane0LinkOk = (io.inst(0).bits.addr === regLastTarget) ||
                      (regLastIsBranch && io.inst(0).bits.addr === regLastAddr + 4.U)
    val faultLinkOk = (io.fault.bits.mepc === regLastTarget) ||
                      (regLastIsBranch && io.fault.bits.mepc === regLastAddr + 4.U)
    val fallthrough = bufferEntry.addr + 4.U

    val nextLinkOk = if (i < bufferSize - 1) instBuffer.io.dataOut(i + 1).linkOk else true.B
    val targetMatch = MuxCase(true.B, Seq(
        (nextValid && (i.U < (bufferSize - 1).U)) -> nextLinkOk,  // 下一条在缓冲区内→检查其 linkOk
        noFire0Fault -> faultLinkOk,                                 // 无 fire 异常→检查异常 PC
        io.inst(0).valid -> lane0LinkOk                             // 下一条在输入端口→检查 lane0
    ))
    val fallthroughMatch = (MuxCase(nextAddr, Seq(
                          nextValid -> nextAddr,
                          noFire0Fault -> io.fault.bits.mepc,
                          io.inst(0).valid -> io.inst(0).bits.addr
                      )) === fallthrough)

    // cfMatch: 控制流匹配 = (跳转目标匹配) 或 (分支 + fallthrough匹配)
    val cfMatch = nextAddrValid && (targetMatch || (isBranch && fallthroughMatch))
    // cfReady: 控制流指令等待下一条指令信息就绪后才允许退役
    val cfReady = !isControlFlow || nextAddrValid

    // ---- 完成状态更新: dataDone(数据就绪) + cfDone(控制流验证通过) ----
    val prevDataDone = resultBuffer(i).valid
    val prevCfDone   = resultBuffer(i).valid && resultBuffer(i).bits.cfDone

    val newCfDone = validBufferEntry && cfReady
    val isMpause  = bufferEntry.isMpause
    // currentTrap: 本条指令是否触发异常 (数据有效+控制流检查完成+cf不匹配)
    val currentTrap = resultBuffer(i).bits.trap || faultingInstr ||
        (validBufferEntry && bufferEntry.trap) ||
        (validBufferEntry && isControlFlow && newCfDone && (!cfMatch || noFire0Fault) && !isMpause)

    val newDataDone = validBufferEntry && !prevDataDone && (dataReady || currentTrap)
    val currentDataDone = prevDataDone || newDataDone
    val currentCfDone   = prevCfDone   || newCfDone

    // 将本周期看到的新结果写入 resultUpdate, 下一拍进入 resultBuffer。
    resultUpdate(i).valid := currentDataDone
    resultUpdate(i).bits.cfDone := currentCfDone
    resultUpdate(i).bits.result := 0.U
    resultUpdate(i).bits.trap := currentTrap

    if (!mini) {
      // 从命中的写回端口取出最终数据, 用于 debug/RVVI 退役记录。
      val writeDataScalar = io.writeDataScalar(scalarWriteIdx).bits.data
      val writeDataFloat = io.writeDataFloat.map(x => x(floatWriteIdx).bits.data).getOrElse(0.U)
      val writeDataVector = io.writeDataVector.map(x => x(vectorWriteIdx).bits.data).getOrElse(0.U)

      // 根据写回来源选择数据。FP 优先于 vector/scalar, 与原有写回仲裁保持一致。
      val sdata = if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataScalar) else writeDataScalar
      val fdata = if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataFloat) else writeDataFloat

      // trap 指令正常不应提交写回数据, debug 轨迹中把 result 清零;
      // 但 noFire0Fault 叠加控制流指令时允许保留已存在的 link 写回信息。
      val result = Mux(newDataDone, MuxCase(0.U, Seq(
        floatWriteIdxMap.reduce(_|_) -> fdata,
        vectorWriteIdxMap.reduce(_|_) -> writeDataVector,
        scalarWriteIdxMap.reduce(_|_) -> sdata,
      )), resultBuffer(i).bits.result)

      val allowWritebackTrap = validBufferEntry && isControlFlow && newCfDone && noFire0Fault
      resultUpdate(i).bits.result := Mux(currentTrap && !allowWritebackTrap, 0.U, result)
    }
  }

  // ---- 退役判定: 检查所有完成的指令 (dataDone+cfDone) 能否按序退役 ----
  val hasTrap       = resultUpdate.map(x => x.valid && x.bits.trap).reduce(_||_)
  val trapDetected  = VecInit(resultUpdate.map(x => x.valid && x.bits.trap))
  val firstTrapIdx  = PriorityEncoder(trapDetected)               // 第一个异常的索引 (最低位)
  val countValid    = Cto(VecInit(resultUpdate.map(x => x.valid && x.bits.cfDone)).asUInt) // 连续完成的指令数 (尾部连续的已完成)

  // 退役策略:
  //   正常: 退役 countValid 条连续完成的指令 (deqReady = countValid)
  //   异常: 退役到异常指令为止 (deqReady = firstTrapIdx + 1)
  // | 情况                      |  `deqReady` |
  // | ----------------------- | ----------: |
  // | 第 0 条 trap 且已完成         |           1 |
  // | 第 3 条 trap，entry0~3 都完成 |           4 |
  // | 第 3 条 trap，但 entry1 未完成 | 等待，不提交 trap |
  // | 无 trap，前 8 条完成          |           8 |
  val limit = firstTrapIdx + 1.U
  val trapReadyToRetire = hasTrap && (limit <= countValid)       // 异常指令之前的所有指令已完成
  val deqReady = Mux(trapReadyToRetire, limit, countValid)       // 本次退役数量

  instBuffer.io.deqReady := deqReady                              // 出队 deqReady 条指令

  val trapRetired = trapReadyToRetire                             // 异常被退役 (触发异常处理)
  instBuffer.io.flush := trapRetired                              // 异常时刷新全部缓冲区

  // ---- 向量写回累积器更新 (条件: !mini + enableRvv) ----
  if (!mini && p.enableRvv) {
     accEnqPtr := Mux(trapRetired, 0.U, accEnqPtr + instBuffer.io.enqValid)
     accDeqPtr := Mux(trapRetired, 0.U, accDeqPtr + deqReady)
     for (x <- 0 until bufferSize) {
         val isEnqueuing = (0 until p.instructionLanes).map(
             k => (k.U < instBuffer.io.enqValid) && (x.U === accEnqPtr + k.U)).reduce(_||_)
         vectorWriteAccumulator.get(x) := Mux(trapRetired || isEnqueuing,
             0.U.asTypeOf(vectorWriteAccumulator.get(0)), vectorAccumulatorNext.get(x))
     }
  }

  // resultBuffer 更新: 右移 deqReady 位 (丢弃已退役的旧数据) + 填入新的 resultUpdate
  resultBuffer := Mux(trapRetired,
      VecInit(Seq.fill(bufferSize)(MakeInvalid(new InstructionUpdate))), // 异常: 清空
      ShiftVectorRight(resultUpdate, deqReady))                          // 正常: 右移

  // 已退役数 = 出队数 - ECALL (ECALL 不算"有效退役")
  val retiredEcalls = PopCount(VecInit((0 until bufferSize).map(
      i => (i.U < deqReady) && instBuffer.io.dataOut(i).isEcall)).asUInt)
  io.nRetired := deqReady - retiredEcalls
  io.trapPending := RegNext(hasTrap && !trapRetired, false.B)    // 有异常但还未退役 → 挂起

  // ---- Debug/RVVI 退役输出 ----
  // 输出本周期真正出队的指令快照:
  //   pc/inst/data/idx/trap 用于调试和 RVVI trace;
  //   trap 指令默认屏蔽 idx, 避免看起来像提交了寄存器写回;
  //   allowDebug 例外用于 noFire0Fault + 控制流指令, 保留必要的 link/debug 信息。
  for (i <- 0 until bufferSize) {
    val valid = (i.U < instBuffer.io.deqReady)
    val allowDebug = resultUpdate(i).bits.trap && instBuffer.io.dataOut(i).isControlFlow && noFire0Fault
    io.debug.inst(i).valid := valid
    io.debug.inst(i).bits.pc := MuxOR(valid, instBuffer.io.dataOut(i).addr)
    io.debug.inst(i).bits.inst := MuxOR(valid && !mini.B, instBuffer.io.dataOut(i).inst)
    io.debug.inst(i).bits.data := MuxOR(valid && !mini.B, resultUpdate(i).bits.result)
    io.debug.inst(i).bits.idx := MuxOR(valid, Mux(resultUpdate(i).bits.trap && !allowDebug, noWriteRegIdx, instBuffer.io.dataOut(i).idx))
    io.debug.inst(i).bits.trap := MuxOR(valid, resultUpdate(i).bits.trap)
    if (!mini && p.enableRvv) {
      val pIdx = accDeqPtr + i.U
      // 完整模式下输出该 RVV 指令累积到的全部向量寄存器写回。
      io.debug.inst(i).bits.vecWrites.get := debugVectorWrites.get(pIdx)
    } else if (p.enableRvv) {
      // mini 模式不记录向量写回明细, 调试端口补零。
      io.debug.inst(i).bits.vecWrites.get := 0.U.asTypeOf(io.debug.inst(i).bits.vecWrites.get)
    }
  }
}
