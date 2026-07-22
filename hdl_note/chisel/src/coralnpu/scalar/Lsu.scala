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
// Lsu.scala — Load/Store 单元 (最复杂的执行单元)
// 标量+向量访存, LsuCmd→LsuUOp→LsuSlot(16B槽), IBUS/DBUS/EXTERNAL三路径
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.rvv._

//DFlushIO如下：
// class DFlushIO(p: Parameters) extends Bundle {
//   val valid = Output(Bool())
//   val ready = Input(Bool())
//   val all   = Output(Bool())  // all=0, see io.dbus.addr for line address.
//   val clean = Output(Bool())  // clean and flush
// }
class DFlushFenceiIO(p: Parameters) extends DFlushIO(p) {
  // fence.i 需要同时通知 I-cache/取指侧刷新，并给出下一条 PC。
  val fencei = Output(Bool())
  val pcNext = Output(UInt(32.W))
}

class Lsu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // ---- Decode 周期输入 ----
    // DispatchV2 每个 lane 都可能送来一条 LSU 请求，LSU 内部再压入统一队列。
    val req = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
    // 标量寄存器堆 busPort 已在 Decode/Regfile 阶段完成地址加法和 store data 读取。
    val busPort = Flipped(new RegfileBusPortIO(p))
    // 浮点 load/store 需要单独从 FRegfile 读取/写回数据。
    val busPort_flt = Option.when(p.enableFloat)(Flipped(new RegfileBusPortIO(p)))

    // ---- Execute/完成周期输出 ----
    // 标量 load 写回 x 寄存器。
    val rd = Valid(Flipped(new RegfileWriteDataIO))
    // 浮点 load 写回 f 寄存器。
    val rd_flt = Valid(Flipped(new RegfileWriteDataIO))

    // ---- Cache/片上存储接口 ----
    // IBus 用于访问 IMEM 区域，只允许读；DBus 用于访问 DMEM 区域。
    val ibus = new IBusIO(p)
    val dbus = new DBusIO(p)
    // flush/fencei 通过该接口通知 cache/取指侧。
    val flush = new DFlushFenceiIO(p)
    // 访存异常统一通过 FaultManager 上报。
    val fault = Valid(new FaultInfo(p))

    // 最终会接到外部总线的 DBus 风格接口。
    // 用于访问 peripheral 或外部地址空间，后续通常会桥接到 TileLink/AXI。
    val ebus = new EBusIO(p)

    // 向量访存活动提示。
    val vldst = Output(Bool())

    // 接口如下所示：
    // class Lsu2Rvv(p: Parameters) extends Bundle {
    //   val addr = UInt(5.W)
    //   val data = UInt(p.rvvVlen.W)
    //   val last = Bool()
    // }
    
    // class Rvv2Lsu(p: Parameters) extends Bundle {
    //   val idx = Valid(new Bundle {
    //     val addr = UInt(5.W)
    //     val data = UInt(p.rvvVlen.W)
    //   })
    //   val vregfile = Valid(new Bundle {
    //     val addr = UInt(5.W)
    //     val data = UInt(p.rvvVlen.W)
    //   })
    //   val mask = Valid(UInt(p.rvvVlenb.W))
    // }
    val rvv2lsu = Option.when(p.enableRvv)(
        Vec(2, Flipped(Decoupled(new Rvv2Lsu(p)))))
    val lsu2rvv = Option.when(p.enableRvv)(Vec(2, Decoupled(new Lsu2Rvv(p))))

    // RVV 当前配置状态，向量访存计算 EMUL/SEW/segment 时会用到。
    // class RvvConfigState(p: Parameters) extends Bundle {
    //   val vl = Output(UInt(log2Ceil(p.rvvVlen + 1).W))
    //   val vstart = Output(UInt(log2Ceil(p.rvvVlen).W))
    //   val ma = Output(Bool())
    //   val ta = Output(Bool())
    //   val xrm = Output(UInt(2.W))
    //   val sew = Output(UInt(3.W))
    //   // This may be reduced according to vl.
    //   val lmul = Output(UInt(3.W))
    //   // This is the original one set in vset(i)vl(i)
    //   val lmul_orig = Output(UInt(3.W))
    //   val vill = Output(Bool())
    
    //   /**
    //    * Construct the vtype CSR value.
    //    * See section 3.4 of the RISC-V Vector Specification v1.0.
    //    */
    //   def vtype: UInt = {
    //     Cat(vill, 0.U(23.W), ma, ta, sew, lmul_orig)
    //   }
    // }
    val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))

    // LSU 内部队列剩余空间，Dispatch 用它做结构冒险/反压判断。
    val queueCapacity = Output(UInt(3.W))
    // LSU 是否仍有队列项、活动事务、写回或向量循环未完成。
    val active = Output(Bool())
    // store 完成通知，ROB/retirement 用于确认 store 已真正发出或向量 store uop 已结束。
    val storeComplete = Output(Valid(UInt(32.W)))
  })
}

object Lsu {
  // 对外仍暴露 Lsu 抽象类型，实际实现使用 LsuV2。
  def apply(p: Parameters): Lsu = {
    return Module(new LsuV2(p))
  }
}

object LsuOp extends ChiselEnum {
  // 标量整数 load/store。
  val LB  = Value  // 加载 1 字节（Byte）,有符号扩展
  val LH  = Value  // 加载 2 字节（Halfword）,有符号扩展
  val LW  = Value  // 加载 4 字节（Word）（RV64下会进行符号扩展）
  val LBU = Value  // 加载 1 字节（Byte）,无符号扩展
  val LHU = Value  // 加载 2 字节（Halfword）,无符号扩展
  //将通用寄存器中的低位数写入内存。
  val SB  = Value  // 存储 1 字节（Byte）
  val SH  = Value  // 存储 2 字节（Halfword）
  val SW  = Value  // 存储 4 字节（Word）
  // cache/fence/flush 类操作。
  // 区分 FENCEI（清指令）、FLUSHAT（清TLB）、FLUSHALL（清所有）。
  val FENCEI = Value  // fence.i 指令，通知 I-cache/取指侧刷新
  val FLUSHAT = Value  // flush 指令，通知 cache/取指侧刷新，并给出下一条 PC
  val FLUSHALL = Value  // flush 指令，通知 cache/取指侧刷新所有缓存，并给出下一条 PC
  // 占位/分类操作：VLDST 表示 RVV 访存，FLOAT 表示浮点 load/store。
  val VLDST = Value  // 向量加载/存储指令,LSU看到这个标签后，不会按标量去处理，
                     // 而是准备接收向量单元发来的向量长度（vl）、元素宽度（sew）和掩码信息，进行段式或连续的大块数据搬运。
  val FLOAT = Value  // 浮点加载/存储指令

  // 向量访存指令，按 load/store、unit/strided/indexed、ordered/unordered 分类。
  val VLOAD_UNIT = Value    //对应汇编指令 vle8/16/32.v。访问的内存地址是连续的（基址 + 0, +1, +2...）
  val VLOAD_STRIDED = Value  //对应汇编指令 vlse8.v。访问的内存地址是基址 + stride * i，stride是一个固定的步长。
  val VLOAD_OINDEXED = Value  //对应汇编指令 vluxei8.v。且硬件保证这些访问在内存顺序上是“有序”的.
                              //访问的内存地址是基址 + index[i]，index是一个向量寄存器，里面存放了每个元素的偏移量。
  val VLOAD_UINDEXED = Value  //对应汇编指令 vluxei8.v。且硬件保证这些访问在内存顺序上是“无序”的.
                              //访问的内存地址是基址 + index[i]，index是一个向量寄存器，里面存放了每个元素的偏移量。
  val VSTORE_UNIT = Value   //对应汇编指令 vse8/16/32.v。访问的内存地址是连续的（基址 + 0, +1, +2...）
  val VSTORE_STRIDED = Value  //对应汇编指令 vsse8.v。访问的内存地址是基址 + stride * i，stride是一个固定的步长。
  val VSTORE_OINDEXED = Value  //对应汇编指令 vsuxei8.v。且硬件保证这些访问在内存顺序上是“有序”的.
                              //访问的内存地址是基址 + index[i]，index是一个向量寄存器，里面存放了每个元素的偏移量。
  val VSTORE_UINDEXED = Value  //对应汇编指令 vsuxei8.v。且硬件保证这些访问在内存顺序上是“无序”的.
                              //访问的内存地址是基址 + index[i]，index是一个向量寄存器，里面存放了每个元素的偏移量。

  def isVector(op: LsuOp.Type): Bool = {
    // 判断是否为任意 RVV 向量访存。
    op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VLOAD_STRIDED,
               LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
               LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED,
               LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)
  }

  def isIndexedVector(op: LsuOp.Type): Bool = {
    // indexed load/store 需要从 RVV 侧额外取得 index vector。
    op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
               LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)
  }

  def isNonindexedVector(op: LsuOp.Type): Bool = {
    // unit-stride/strided 不需要 index vector，只依赖 base/stride。
    op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VLOAD_STRIDED,
               LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED)
  }

  def isFlush(op: LsuOp.Type): Bool = {
    // flush/fence 指令不进入普通访存 slot，而是走 flush 状态机。
    op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHAT, LsuOp.FLUSHALL)
  }

  def isScalarLoad(op: LsuOp.Type): Bool = {
    // 只有标量整数 load 会写回 x 寄存器。
    op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)
  }

  //设计上，标量 byte/half/word 访问可能放大成 16B line 访问，后续再通过 byte select/gather 取出需要的数据。
  // | 操作                | 对齐时 size | 未对齐时    |
  // | ----------------- | -------: | ------- |
  // | byte load/store   |       1B | 仍 1B    |
  // | half load/store   |       2B | 放大为 16B |
  // | word load/store   |       4B | 放大为 16B |
  // | float load/store  |       4B | 放大为 16B |
  // | vector load/store |      16B | 16B     |
  def opSize(op: LsuOp.Type, address: UInt): (UInt, UInt) = {
    // 返回外部/DBus 事务 size，以及对齐后的访问地址。
    // 未对齐 half/word 访问在这里放大成 16B line 访问，由后续 byte 选择逻辑处理。
    val halfAligned = (address(0) === 0.U)
    val wordAligned = (address(1, 0) === 0.U)

    val size = MuxUpTo1H(16.U, Seq(
      op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> 1.U,  //byte load/store 走 1B 事务。
      op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> Mux(halfAligned, 2.U, 16.U),  //half load/store 走 2B 事务，未对齐时放大为 16B。
      op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) ->
          Mux(wordAligned, 4.U, 16.U),  //word/float load/store 走 4B 事务，未对齐时放大为 16B。
      LsuOp.isVector(op) -> 16.U,  //vector load/store 走 16B 事务。
    ))

    val halfAlignedAddress = address(31, 1) << 1.U  // half load/store 需要按 2B 对齐。
    val wordAlignedAddress = address(31, 2) << 2.U  // word/float load/store 需要按 4B 对齐。
    val lineAlignedAddress = address(31, 4) << 4.U  // vector load/store 需要按 16B 对齐。
    val alignedAddress = MuxUpTo1H(lineAlignedAddress, Seq(
      op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> address,  // byte load/store 走 1B 事务，地址不变。
      (op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) && halfAligned) ->  
          halfAlignedAddress,  // half load/store 走 2B 事务，地址按 2B 对齐。
      (op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) && wordAligned) ->
          wordAlignedAddress,  // word/float load/store 走 4B 事务，地址按 4B 对齐。
    ))

    (size, alignedAddress)
  }
}

class LsuCmd(p: Parameters) extends Bundle {
  // Dispatch 阶段送入 LSU 的原始命令。
  // 此时标量地址/数据还通过 Regfile busPort 旁路提供，后面会合成为 LsuUOp。
  val store = Bool()
  // load 目的 rd，或 store/flush/RVV 指令携带的相关寄存器字段。
  val addr = UInt(5.W)
  // LSU操作类型
  val op = LsuOp()
  // fault/storeComplete/flush 需要回传该指令 PC。
  val pc = UInt(32.W)
  // RVV 访存指令字段：elemWidth 对应编码中的 width/eew。
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  // segment load/store 的 nf 字段。
  val nfields = Option.when(p.enableRvv) { UInt(3.W) }
  // RVV load/store 的 umop 字段，用于识别 mask/whole-register 等特殊访存。
  val umop = Option.when(p.enableRvv) { UInt(5.W) }

  // | 函数                  | 含义                                                |
  // | ------------------- | ------------------------------------------------- |
  // | `isMaskOperation()` | RVV mask load/store，固定 EMUL=1,eew=8                     |
  // | `isWholeRegister()` | RVV whole-register load/store，EMUL 由 `nfields` 决定 |
  def isMaskOperation(): Bool = {
    // RVV mask load/store 使用固定 EMUL=1，且只对 unit-stride 生效。
    if (p.enableRvv) {
      (umop.get === "b01011".U) &&
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
    } else {
      false.B
    }
  }

  def isWholeRegister(): Bool = {
    // whole-register load/store 的 EMUL 来自 nf，而不是普通 vtype/lmul 计算。
    if (p.enableRvv) {
      (umop.get === "b01000".U) &&
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
    } else {
      false.B
    }
  }

  // 访存指令的 EEW/width 字段，RVV spec 7.9.1 定义。
  override def toPrintable: Printable = {
    cf"LsuCmd(store -> ${store}, addr -> 0x${addr}%x, op -> ${op}, " +
    cf"pc -> 0x${pc}%x, elemWidth -> ${elemWidth}, nfields -> ${nfields})"
  }
}

class LsuUOp(p: Parameters) extends Bundle {
  // LSU 内部队列保存的微操作。它已经包含计算好的地址、store data 和 RVV 派生字段。
  val store = Bool()
  val rd = UInt(5.W)
  val op = LsuOp()
  val pc = UInt(32.W)
  // 标量/浮点访存的有效地址；RVV 访存的 base address。
  val addr = UInt(32.W)
  val data = UInt(32.W)  // store data，也可作为 strided 访存的 stride/rs2
  // 与 RVV spec 中的 width 字段对齐：indexed 访存时控制 index 宽度，
  // 其他向量访存时控制数据元素宽度。
  // | 字段          | 含义              |
  // | ----------- | --------------- |
  // | `elemWidth` | EEW/width       |
  // | `sew`       | 当前 vtype.SEW    |
  // | `emul_data` | 本次数据寄存器组 EMUL   |
  // | `nfields`   | segment field 数 |
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  // vtype 中的 sew：indexed 访存时控制实际数据宽度，其他操作中不使用。
  val sew = Option.when(p.enableRvv) { UInt(3.W) }
  // 本次操作涉及的数据寄存器组大小；segment 访存时是每个 field 的寄存器组大小。
  val emul_data = Option.when(p.enableRvv) { UInt(3.W) }
  // segment field 数量编码。
  val nfields = Option.when(p.enableRvv) { UInt(3.W) }

  override def toPrintable: Printable = {
    cf"LsuUOp(store -> ${store}, rd -> ${rd}, op -> ${op}, " +
    cf"pc -> 0x${pc}%x, addr -> 0x${addr}%x, data -> ${data})"
  }
}

object LsuUOp {// 将 Dispatch 阶段的 LsuCmd 与 Regfile busPort 结果合并成队列中的 LSU uop。
  def apply(p: Parameters,
            i: Int,
            cmd: LsuCmd,
            sbus: RegfileBusPortIO,
            fbus: Option[RegfileBusPortIO],
            rvvState: Option[Valid[RvvConfigState]]): LsuUOp = {
    // 将 Dispatch 命令与 Regfile busPort 结果合并成队列中的 LSU uop。
    val result = Wire(new LsuUOp(p))
    //直接复制 Dispatch 命令中的基本字段。
    result.store := cmd.store
    result.rd := cmd.addr
    result.op := cmd.op
    result.pc := cmd.pc
    if (fbus.isDefined) {
      // 浮点 store 使用 FRegfile 数据；其他 store 使用标量 rs2 数据。
      result.addr := sbus.addr(i)  //有效地址来自标量 regfile bus port 的第 i 个 lane。
                                   //说明地址计算由上游完成，LSU 不再做 rs1 + imm。
      result.data := Mux(
          cmd.op === LsuOp.FLOAT, fbus.get.data(i), sbus.data(i))  //如果是浮点 store，则 store data 来自 FRegfile。
                                                                   //否则来自整数 Regfile。
    } else {
      result.addr := sbus.addr(i)  //没有浮点支持时，只使用标量 bus port。
      result.data := sbus.data(i)
    }
    if (p.enableRvv) {
      val eew = cmd.elemWidth.get  // 来自指令编码的 EEW/width。
      val sew = rvvState.get.bits.sew  // 来自 vtype 的 SEW。
      val lmul = rvvState.get.bits.lmul  //
      // TODO(davidgao): 前端应增加非法 LMUL 组合检查。
      // unit-stride/const-stride 的 EMUL 由 EEW/SEW 与 LMUL 共同决定；
      // 默认值适用于 eew == sew 的情况。
      val emul_data = MuxUpTo1H(lmul, Seq(  //EMUL = (EEW/SEW)*LMUL
          // eew == 1/4 sew
          (eew === "b000".U && sew === "b010".U) -> (lmul - 2.U),  //
          // eew == 1/2 sew
          ((eew === "b000".U && sew === "b001".U) ||
           (eew === "b101".U && sew === "b010".U)) -> (lmul - 1.U),
          // eew == 2 sew
          ((eew === "b101".U && sew === "b000".U) ||
           (eew === "b110".U && sew === "b001".U)) -> (lmul + 1.U),
          // eew == 4 sew
          (eew === "b110".U && sew === "b000".U) -> (lmul + 2.U),
      ))
      result.elemWidth.get := eew
      // | RVV 访存                   | EMUL 规则                     |
      // | ------------------------- | --------------------------- |
      // | mask load/store           | 固定按 LMUL=1                  |
      // | whole-register load/store | 根据 `nfields` 得到 LMUL1/2/4/8 |
      // | indexed vector            | 默认保留 vtype.lmul             |
      result.emul_data.get := MuxCase(lmul, Seq(
          // mask 访存固定按 LMUL=1 处理。
          cmd.isMaskOperation() -> 0.U,
          // RVV Spec 7.9：whole-register 访存中 nf 编码要 load/store 的向量寄存器数量。
          cmd.isWholeRegister() -> MuxUpTo1H(0.U, Seq(
              (cmd.nfields.get === 0.U) -> 0.U,  // NF1 -> LMUL1
              (cmd.nfields.get === 1.U) -> 1.U,  // NF2 -> LMUL2
              (cmd.nfields.get === 3.U) -> 2.U,  // NF4 -> LMUL4
              (cmd.nfields.get === 7.U) -> 3.U,  // NF8 -> LMUL8
          )),
          LsuOp.isNonindexedVector(cmd.op) -> emul_data,
          // 默认：indexed vector 和标量路径保留 vtype.lmul。
      ))

      // mask/whole-register 访存不按普通 segment field 递增。所以 nfields 强制为 0。
      result.nfields.get := MuxUpTo1H(cmd.nfields.get, Seq(
          cmd.isMaskOperation() -> 0.U,
          cmd.isWholeRegister() -> 0.U,
      ))
      result.sew.get := rvvState.get.bits.sew
    }

    result
  }
}

//它在一个 16B slot 内为每个 byte lane 生成地址。
// | elemWidth | 元素大小 | 地址生成                   |
// | --------- | ---: | ---------------------- |
// | `000`     |   1B | 每个 byte 一个元素           |
// | `101`     |   2B | 每 2 个 byte 共享一个 stride |
// | `110`     |   4B | 每 4 个 byte 共享一个 stride |
object ComputeStridedAddrs {
  def apply(bytesPerSlot: Int,
            baseAddr: UInt,
            stride: UInt,
            elemWidth: UInt): Vec[UInt] = {
    // 根据 base、stride 和元素宽度生成一个 16B slot 内每个 byte 对应的实际地址。
    MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // elemWidth 合法性已在 Decode 阶段检查。
      // TODO: 可考虑把 elemWidth 改成枚举，减少对二进制编码常量的直接依赖。
      (elemWidth === "b000".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + (i.U*stride))(31, 0))),                     // 1-byte 元素，addr[i] = baseAddr + i × stride
      //addr[0] = base + 0×stride + 0
      //addr[1] = base + 0×stride + 1
      //addr[2] = base + 1×stride + 0
      //addr[3] = base + 1×stride + 1
      (elemWidth === "b101".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + ((i >> 1).U*stride))(31, 0) + (i & 1).U)),  // 2-byte 元素,
      // addr[0..3]   = base + 0×stride + byte_offset
      // addr[4..7]   = base + 1×stride + byte_offset
      // addr[8..11]  = base + 2×stride + byte_offset
      // addr[12..15] = base + 3×stride + byte_offset
      (elemWidth === "b110".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + ((i >> 2).U*stride))(31, 0) + (i & 3).U)),  // 4-byte 元素
    ))
  }
}

// 用于 indexed vector load/store：
// address = baseAddr + index[i] + byte_offset

// 它先把 index vector 拆成：
// indexWidth	index 元素
// 000	8-bit  index
// 101	16-bit index
// 110	32-bit index

// 然后再根据数据 sew 判断每几个 byte 共享一个 index。
// sew	数据元素大小	byte 分组
// 000	8-bit  	    每 byte 一个 index
// 001	16-bit	    每 2 byte 一个 index
// 010	32-bit	    每 4 byte 一个 index

//为一个 16 字节（128 位）的数据块（即 bytesPerSlot），生成 16 个独立的 32 位内存地址
object ComputeIndexedAddrs {
  def apply(bytesPerSlot: Int,
            baseAddr: UInt,
            indices: UInt,
            indexWidth: UInt,
            sew: UInt): Vec[UInt] = {
    // 将 index vector 按 indexWidth 展开成 byte 级地址偏移。
    val indices8 = UIntToVec(indices, 8).map(x => Cat(0.U(24.W), x)) // 8-bit index，直接扩展到 32-bit。
    val indices16 = UIntToVec(indices, 16).map(x => Cat(0.U(16.W), x))  // 16-bit index，扩展到 32-bit。
    val indices32 = UIntToVec(indices, 32)  // 32-bit index，直接使用。

    val indices_v = MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // 8-bit index。
      (indexWidth === "b000".U) -> VecInit(indices8),// 8-bit index。每个 byte lane 对应一个 index。
      // 16-bit index。复制到每个 byte lane，便于按 byte 生成地址。
      (indexWidth === "b101".U) -> VecInit(indices16 ++ indices16),// 16-bit index。每 2 个 byte lane 对应一个 index。
      // 32-bit index。同理复制覆盖 16B slot 内所有 byte。
      (indexWidth === "b110".U) -> VecInit(
          indices32 ++ indices32 ++ indices32 ++ indices32),// 32-bit index。每 4 个 byte lane 对应一个 index。
    ))

    MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // elemWidth 合法性已在 Decode 阶段检查。
      // 8-bit 数据：每个 byte 都有独立 offset。
      (sew === "b000".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i)))),
      // 16-bit 数据：每 2 个 byte 共享一个 index offset。
      (sew === "b001".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i >> 1) + (i & 1).U))),
      // 32-bit 数据：每 4 个 byte 共享一个 index offset。
      (sew === "b010".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i >> 2) + (i & 3).U)))
    ))
  }
}

//向量访存可能不是一次 16B 就结束，而是要循环处理多个维度：
class LsuVectorLoop extends Bundle {
  // 向量访存可能拆成 subvector、segment、LMUL 三层循环。

  // subvector: indexed 访存中一个 index vector 不能覆盖所有 data vector 时的分片。
  // 所以需要分多次从 RVV 取 index/mask/data。
  val subvector = new LoopingCounter(3.W)
  // segment: segment load/store 的 field 维度。
  //用于一个 vector register group 中多个寄存器的循环处理。
  val segment = new LoopingCounter(4.W)
  // lmul: 向量寄存器组内的寄存器编号维度。
  val lmul = new LoopingCounter(4.W)
  // 辅助状态：保存初始 rd 和当前正在处理的 rd。
  val rdStart = UInt(5.W)
  val rd = UInt(5.W)

  def isActive(): Bool = {
    // 任一循环计数器未完成，都表示当前向量指令还有后续子操作。
    (!subvector.isFull()) || (!segment.isFull()) || (!lmul.isFull())
  }

  def nextSubvector(): LsuVectorLoop = {
    // 只推进 subvector，用于等待 RVV 侧继续提供 index/data/mask。
    val result = MakeWireBundle[LsuVectorLoop](new LsuVectorLoop, _ -> this)  //复制当前 loop 状态到一个新 wire。
    result.subvector := subvector.next()  //subvector 加一
    result  //返回更新后的 loop 状态。
  }

  //完成一次 16B 访存返回或 store 完成通知后，推进到下一个向量位置segment/lmul。。
  def nextVector(): LsuVectorLoop = {
    val result = MakeWireBundle[LsuVectorLoop](new LsuVectorLoop, _ -> this)
    result.subvector := subvector.reset()  //每处理完一个 vector chunk，subvector 回到起点。
    result.segment := Mux(segment.isFull(), segment.reset(), segment.next())  //如果 segment 已满，则 segment 回 0；否则 segment 加一。
    result.lmul := Mux(segment.isFull(), lmul.next(), lmul)  //只有 segment 维度跑完后，才推进 lmul。
    result.rd := Mux(segment.isFull(),
                     rdStart + lmul.next().curr,
                     rd + lmul.max)  //如果 segment 跑完，则进入下一个 LMUL 寄存器组；否则在 segment 内按 field 推进。
    result
  }

  override def toPrintable: Printable = {
    cf"    subvector: ${subvector.curr} of [0..${subvector.max}]\n" +
    cf"    segment: ${segment.curr} of [0..${segment.max}]\n" +
    cf"    lmul: ${lmul.curr} of [0..${lmul.max}]\n" +
    cf"    rdStart: ${rdStart}\n    rd: ${rd}\n"
  }
}

// bytesPerSlot 是一个 LSU slot 覆盖的 byte 数，这里通常等于一个向量寄存器片段宽度。
// p.lsuDataBytes 是总线一次 beat/line 可搬运的 byte 数。  //256bit
class LsuSlot(p: Parameters, bytesPerSlot: Int) extends Bundle {
  //地址低 4 bit 是 16B line 内 byte offset
  //地址高位是 line address
  val elemBits = log2Ceil(p.lsuDataBytes)

  // 当前 slot 正在处理的 uop 基本信息。
  val op = LsuOp()
  val rd = UInt(5.W)
  val store = Bool()
  val pc = UInt(32.W)
  // 向量访存的当前 base address；标量访存中也保存原始地址。
  val baseAddr = UInt(32.W)
  // 每个 byte lane 是否还有未完成事务。
  val active = Vec(bytesPerSlot, Bool())
  // 每个 byte lane 对应的实际地址。
  // 对于 strided/indexed 访存，这 16 个地址可能完全不连续。
  val addrs = Vec(bytesPerSlot, UInt(32.W))
  // load 聚合结果或 store 待写数据，按 byte 保存。
  val data = Vec(bytesPerSlot, UInt(8.W))
  // load 已完成总线事务但还需要写回，或向量 store 需要向 RVV core 回报完成。
  val pendingWriteback = Bool()
  val elemStride = UInt(32.W)     // 向量相邻元素之间的 stride。
  val segmentStride = UInt(32.W)  // segment 之间 base address 的 stride。
  // 与 RVV spec 中的 width 字段对齐：indexed 访存时控制 index 宽度，
  // 其他向量访存时控制数据元素宽度。
  val elemWidth = UInt(3.W)
  // indexed load/store 中控制数据宽度，其他操作中不使用。
  val sew = UInt(3.W)
  // 一个 index vector 可覆盖的数据 vector 分区数，最多 4 份。
  val indexParitions = UInt(3.W)
  val vectorLoop = new LsuVectorLoop()

  // | 函数                   | 含义                              |
  // | --------------------- | ------------------------------- |
  // | `pendingVector()`     | 还需要 RVV core 提供 mask/index/data |
  // | `slotIdle()`          | slot 完全空闲，可接收新 uop              |
  // | `activeTransaction()` | slot 中存在可发出的总线事务                |
  // | `shouldWriteback()`   | load 已完成，等待写回                   |
  // | `targetAddress()`     | 从 active byte 中选择下一条要访问的地址      |
  def pendingVector(): Bool = {
    // 还有 subvector 数据需要从 RVV core 通过 rvv2lsu 提供。
    !vectorLoop.subvector.isFull()  //只要 subvector 还没满，就说明 LSU 还需要 RVV core 提供 mask/index/data。
  }

  // slot 没有未完成任务时，才能从 opQueue 接收新的 uop。
  def slotIdle(): Bool = !(
      active.reduce(_||_) ||  // 仍有未完成总线事务
      pendingWriteback ||     // 仍需要写回 regfile 或通知 RVV
      vectorLoop.isActive()     // 向量循环尚未结束
  )

  // slot 是否存在可发出的总线事务；pendingVector 时需要先等 RVV 数据补齐。
  def activeTransaction(): Bool = {
    (!pendingVector()) && active.reduce(_||_)
  }

  def lineAddresses(): Vec[UInt] = {
    // 将 byte 地址转换成总线 line 地址。
    VecInit(addrs.map(x => x(31, elemBits)))
  }

  def elemAddresses(): Vec[UInt] = {
    // byte 在总线 line 内的偏移。
    VecInit(addrs.map(x => x(elemBits-1, 0)))
  }

  def targetAddress(lastRead: Valid[UInt]): Valid[UInt] = {
    // 从 active byte 中挑选下一条要访问的地址。
    // 如果上一拍已经发起同一条 read line，则本拍抑制该 line，避免重复读。
    val lineAddrs = lineAddresses()
    val lineActive = (0 until bytesPerSlot).map(i =>
        !pendingVector() &&
        active(i) && (!lastRead.valid || (lastRead.bits =/= lineAddrs(i))))

    //slot 每次选择一个目标 line 发起总线事务。
    //同一个 line 内的多个 byte 可以一次 gather/scatter。
    MuxCase(MakeInvalid(UInt(32.W)), (0 until bytesPerSlot).map(
        i => lineActive(i) -> MakeValid(!pendingVector(), addrs(i))))
  }

  // | RVV→LSU 数据 | 用途                                |
  // | ---------- | --------------------------------- |
  // | `mask`     | 哪些 byte lane 参与访存                 |
  // | `idx`      | indexed load/store 的 index vector |
  // | `vregfile` | vector store 的数据                  |
  def vectorUpdate(rvv2lsu: Rvv2Lsu): LsuSlot = {
    // 接收 RVV core 提供的 mask/data/index，更新当前 subvector 对应的 byte 地址和数据。
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.pendingWriteback := pendingWriteback
    result.baseAddr := baseAddr
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.indexParitions := indexParitions
    result.vectorLoop := vectorLoop.nextSubvector()
    result.elemWidth := elemWidth
    result.sew := sew

    // segmentBaseAddr 表示当前 segment field 的起始地址。
    // unit-stride/strided/indexed 都先定位到 segment，再在 segment 内计算每个 byte 地址。
    val segmentBaseAddr = baseAddr + (segmentStride * vectorLoop.segment.curr)(31, 0)  //计算当前 segment field 的 base address。
    val bitsPerSlot = bytesPerSlot * 8 
    // indexed 访存中，一个 index vector 可能被拆成多个分区使用。
    val indices = MuxUpTo1H(rvv2lsu.idx.bits.data, Seq(
        // 2 of 2：选择第二半 index。
        ((indexParitions === 2.U) && (vectorLoop.lmul.curr(0) === 1.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot - 1, bitsPerSlot / 2)),
        // 2 of 4：选择第 2 个 quarter。
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 1.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot / 2 - 1, bitsPerSlot / 4)),
        // 3 of 4：选择第 3 个 quarter。
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 2.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot * 3 / 4 - 1, bitsPerSlot / 2)),
        // 4 of 4：选择第 4 个 quarter。
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 3.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot - 1, bitsPerSlot * 3 / 4)),
    ))

    // 非 indexed 访存不依赖 idx；indexed 访存则等待 idx.valid。
    val shouldUpdate = LsuOp.isNonindexedVector(op) ||
                       (!vectorLoop.subvector.isEnabled()) ||
                       rvv2lsu.idx.valid
    // mask 的每一位对应 slot 内一个 byte lane。只有被 mask 选中的 byte 会进入 active 集合。
    val newActiveBytes = Mux(
        shouldUpdate && LsuOp.isVector(op) && rvv2lsu.mask.valid,
        VecInit(rvv2lsu.mask.bits.asBools),
        VecInit.fill(bytesPerSlot)(false.B))

    // 根据访存类型生成每个 active byte 的实际地址。
    // unit-stride 和 strided 共享 ComputeStridedAddrs，只是 elemStride 的来源不同。
    val updateAddrs = MuxUpTo1H(addrs, Seq(
        op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
            ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
            ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
                   LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED) ->
            ComputeIndexedAddrs(bytesPerSlot, segmentBaseAddr, indices,
                                elemWidth, sew),
    ))

    // 新 mask 激活的 byte 会与旧 active 状态合并，因为同一个 slot 可能跨多个 line 分批完成。
    result.active := VecInit.tabulate(bytesPerSlot)(
        i => active(i) || newActiveBytes(i))

    // 只有新激活的 byte 需要写入新地址，尚未完成的旧 byte 保持原地址。
    result.addrs := VecInit.tabulate(bytesPerSlot)(
        i => Mux(newActiveBytes(i), updateAddrs(i), addrs(i)))

    // store 路径从 RVV core 取得整个向量寄存器数据，并拆成 byte 保存；
    // load 路径没有 vregfile.valid，保持原 data。
    result.data := Mux(shouldUpdate && LsuOp.isVector(op) && rvv2lsu.vregfile.valid,
        UIntToVec(rvv2lsu.vregfile.bits.data, 8), data)

    result
  }

  // 上一拍发出 read
  // 本拍拿到 lineData
  // 从 lineData 中 gather 目标 byte
  // 写入 slot.data
  // 清除对应 active byte
  // | 场景                     |
  // | ---------------------- |
  // | 标量非对齐访问                |
  // | vector 跨 line          |
  // | 多 byte 分散在同一 line      |
  // | indexed/strided 的非连续地址 |
  // 根据上一拍总线读回的数据更新 slot。
  def loadUpdate(lineAddr: UInt, lineData: UInt): LsuSlot = {
    // TODO(derekjchow): 检查跨 line/跨总线的访存顺序语义。
    val lineAddrs = lineAddresses()
    val lineActive = VecInit((0 until bytesPerSlot).map(i =>
        active(i) &&  // 只更新仍 active 的 byte。
        (lineAddrs(i) === lineAddr)))  // 只更新匹配读回 line 的 byte。
    val lineDataVec = UIntToVec(lineData, 8)  //把总线返回的 line 数据拆成 byte 数组。
    // Gather 根据每个 byte 在 line 内的偏移，把总线返回 line 中的目标 byte 抽出来。
    val gatheredData = Gather(elemAddresses(), lineDataVec)  //根据每个 byte 的 line 内 offset，从 lineDataVec 中抽取目标 byte。

    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.baseAddr := baseAddr
    result.addrs := addrs
    result.pendingWriteback := pendingWriteback
    result.active := (0 until bytesPerSlot).map(
        i => active(i) & ~lineActive(i))  //对已经读回的 byte，清除 active。
    result.data := VecInit((0 until bytesPerSlot).map(
        i => Mux(lineActive(i), gatheredData(i), data(i))))  //对于本次返回 line 覆盖的 byte，把 gather 数据写入 slot.data。
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew
    result.indexParitions := indexParitions
    result.vectorLoop := vectorLoop

    result
  }

  // load 事务已经完成，但结果还需要写回寄存器堆或通知 RVV core。
  def shouldWriteback(): Bool = {
    !pendingVector() && !active.reduce(_||_) && pendingWriteback
  }

  // 写回完成后推进向量循环或清除 pendingWriteback。
  def writebackUpdate(): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.store := store
    result.pc := pc
    result.addrs := addrs
    result.active := active
    result.data := data
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew

    val vectorLoopNext = vectorLoop.nextVector()  //推进 RVV 的 segment/lmul 循环。
    val vectorWriteback = vectorLoop.isActive()   //判断当前是否是向量写回/通知。
    // nextVector 后 lmul 满，说明整个向量指令所有寄存器组/segment 都处理完。
    val finished = vectorLoopNext.lmul.isFull()
    //构造一个“所有循环都满”的 loop 状态。构造一个“所有循环都满”的 loop 状态。
    val finishedVectorLoop = Wire(new LsuVectorLoop)
    finishedVectorLoop := vectorLoop
    finishedVectorLoop.subvector.curr := vectorLoop.subvector.max
    finishedVectorLoop.segment.curr := vectorLoop.segment.max
    finishedVectorLoop.lmul.curr := vectorLoop.lmul.max

    result.indexParitions := indexParitions  //
    // 未完成时推进到下一组 vectorLoop；完成时把 loop 标记为全满，slotIdle 才能变为 true。
    result.vectorLoop := Mux(finished,
                             finishedVectorLoop,
                             vectorLoopNext)
    result.pendingWriteback := !finished

    // TODO(davidgao): 将 baseAddr 偏移计算吸收到 vectorLoop 中。
    // 只有完成一个 LMUL 维度内所有 segment 后，才需要推进 baseAddr 到下一组向量寄存器。
    val lmulUpdate = vectorWriteback && vectorLoop.segment.isFull()
    result.baseAddr := MuxCase(baseAddr, Seq(
      !lmulUpdate -> baseAddr,
      // unit-stride 访存按连续 16B 片段推进 baseAddr。
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
          (baseAddr + (vectorLoop.segment.max * 16.U) + 16.U),
      op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
          // strided 根据元素宽度决定一个 16B slot 覆盖多少个元素，从而决定 baseAddr 跨度。
          // | elemWidth | 推进                |
          // | --------- | ----------------- |
          // | 8-bit     | `elemStride * 16` |
          // | 16-bit    | `elemStride * 8`  |
          // | 32-bit    | `elemStride * 4`  |
          MuxUpTo1H(baseAddr + (elemStride * bytesPerSlot.U), Seq(
            (elemWidth === "b000".U) ->
                (baseAddr + (elemStride * bytesPerSlot.U)),
            (elemWidth === "b101".U) ->
                (baseAddr + (elemStride * (bytesPerSlot/2).U)),
            (elemWidth === "b110".U) ->
                (baseAddr + (elemStride * (bytesPerSlot/4).U)),
          ))
          // (baseAddr + (vectorLoop.segment.max * elemStride)(31, 0)),

      // indexed 访存的 baseAddr 不随 lmul 推进。
    ))
    result.rd := result.vectorLoop.rd

    result
  }

  def scatter(lineAddr: UInt): (Vec[UInt], Vec[Bool], Vec[Bool]) = {
    // 将 slot 中属于同一 line 的 store byte 收集成总线写数据和写 mask。
    // pendingVector 时表示向量 store 数据/mask 还没完全到位，不能发写事务。
    val canScatter = store && (!LsuOp.isVector(op) || !pendingVector())  //只有 store 才能 scatter。
    val lineAddrs = lineAddresses()  //得到每个 byte 所在 line。
    //选出当前 line 中要写出的 active byte
    val lineActive = VecInit((0 until bytesPerSlot).map(i =>
        canScatter && active(i) & (lineAddrs(i) === lineAddr)))
    Scatter(lineActive, elemAddresses(), data)
  }

  def storeUpdate(selected: Vec[Bool]): LsuSlot = {
    // 总线接受 store 后，清除已经写出的 byte lane。
    assert(selected.length == active.length)
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.pendingWriteback := pendingWriteback
    result.active := (0 until bytesPerSlot).map(i => active(i) & ~selected(i))  //被本次总线写出的 byte 变成 inactive。其他 byte 保持 active，等待后续总线事务。
    result.baseAddr := baseAddr
    result.addrs := addrs
    result.data := data
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew
    result.indexParitions := indexParitions
    result.vectorLoop := vectorLoop
    result
  }

  def scalarLoadResult(): UInt = {
    // 将 byte 级 load 结果重新拼成标量写回数据。
    val word = Cat(data(3), data(2), data(1), data(0))
    val half = Cat(data(1), data(0))
    val byte =  data(0)
    // 有符号 load 需要符号扩展，无符号 load 直接零扩展。
    val halfSigned = Wire(SInt(32.W))
    halfSigned := half.asSInt
    val byteSigned = Wire(SInt(32.W))
    byteSigned := byte.asSInt
    MuxLookup(op, 0.U)(Seq(
      LsuOp.LB -> byteSigned.asUInt,
      LsuOp.LBU -> byte,
      LsuOp.LH -> halfSigned.asUInt,
      LsuOp.LHU -> half,
      LsuOp.LW -> word,
      LsuOp.FLOAT -> word,
    ))
  }

  override def toPrintable: Printable = {
    val lines = (0 until bytesPerSlot).map(i =>
        cf"  $i: ${active(i)}, 0x${addrs(i)}%x, 0x${data(i)}%x\n")
    cf"store: $store\n  op: ${op}\n  pc: 0x${pc}%x\n" +
    cf"  baseAddr: 0x${baseAddr}%x\n" +
    cf"  pendingWriteback: ${pendingWriteback}\n" +
    cf"  vectorLoop:\n${vectorLoop.toPrintable}" +
    cf"  elemWidth: 0b${elemWidth}%b elemStride: ${elemStride}\n" +
    lines.reduce(_+_)
  }
}

object LsuSlot {
  def inactive(p: Parameters, bytesPerSlot: Int): LsuSlot = {
    // 空 slot：所有状态清零，表示可接收新 uop。
    0.U.asTypeOf(new LsuSlot(p, bytesPerSlot))
  }

  def fromLsuUOp(uop: LsuUOp, p: Parameters, bytesPerSlot: Int): LsuSlot = {
    // 将队列中的 LsuUOp 展开成 byte-granular slot。
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := uop.op
    result.rd := uop.rd
    result.store := uop.store
    result.pc := uop.pc
    //RVV loop 初始化
    if (p.enableRvv) {
      val effectiveLmul = MuxCase(uop.emul_data.getOrElse(0.U)(1, 0), Seq(
        // fractional EMUL 按 EMUL=1 处理。
        (uop.emul_data.getOrElse(0.U)(2)) -> 0.U(2.W),
      ))

      val nfields = Mux(LsuOp.isVector(uop.op), uop.nfields.get, 0.U)
      // indexed load 中，如果 index 元素宽度大于 data 元素宽度，
      // 一个 data vector 可能需要多次 rvv2lsu 交互才能拿齐 index。
      val elemWidth = uop.elemWidth.get
      val elemMultiplier = MuxUpTo1H(1.U, Seq(
        // 8-bit 数据，16-bit index。
        ((elemWidth === "b101".U) && (uop.sew.get === 0.U)) -> 2.U,
        // 8-bit 数据，32-bit index。
        ((elemWidth === "b110".U) && (uop.sew.get === 0.U)) -> 4.U,
        // 16-bit 数据，32-bit index。
        ((elemWidth === "b110".U) && (uop.sew.get === 1.U)) -> 2.U,
      ))
      // max_subvector 表示一个 data vector 需要拆成几次 index 交互。
      // 例如 8-bit 数据 + 32-bit index 时，一个 index vector 只能覆盖 1/4 个数据 byte lane。
      val max_subvector = MuxUpTo1H(1.U, Seq(
        ((elemMultiplier === 2.U) && (uop.emul_data.get.asSInt >= 0.S)) -> 2.U,
        ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt >= 0.S)) -> 4.U,
        ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt === -1.S)) -> 2.U,
      ))
      // 一个 index vector 可服务多少个 data vector 分区。
      result.indexParitions := MuxUpTo1H(1.U, Seq(
        // 16-bit 数据，8-bit index。
        ((elemWidth === "b000".U) && (uop.sew.get === 1.U)) -> 2.U,
        // 32-bit 数据，8-bit index。
        ((elemWidth === "b000".U) && (uop.sew.get === 2.U)) -> 4.U,
        // 32-bit 数据，16-bit index。
        ((elemWidth === "b101".U) && (uop.sew.get === 2.U)) -> 2.U,
      ))
      // vectorLoop 三个维度在 slot 内共同描述一个向量访存指令的完成进度：
      // subvector 负责 indexed 分片，segment 负责 nf field，lmul 负责寄存器组。
      result.vectorLoop := MakeWireBundle[LsuVectorLoop](
          new LsuVectorLoop,
          _.subvector -> LoopingCounter(MuxCase(0.U, Seq(
            LsuOp.isIndexedVector(uop.op) -> max_subvector,
            LsuOp.isVector(uop.op) -> 1.U,
          ))),
          _.segment -> LoopingCounter(
              Mux(LsuOp.isVector(uop.op), nfields, 0.U)),
          _.lmul -> LoopingCounter(
              Mux(LsuOp.isVector(uop.op), (1.U(4.W) << effectiveLmul), 0.U)),
          _.rdStart -> uop.rd,
          _.rd -> uop.rd,
      )
    } else {
      // 非 RVV 配置下禁用所有向量循环维度。
      result.indexParitions := 0.U
      result.vectorLoop := 0.U.asTypeOf(result.vectorLoop)
    }

    // 所有向量操作都需要 LSU 回传完成信息；向量 store 虽不写寄存器，
    // 也必须通知 RVV core 该 store uop 已完成。
    result.pendingWriteback := !uop.store || LsuOp.isVector(uop.op)

    // | 操作         | active 初始值       |
    // | ---------- | ---------------- |
    // | byte       | 1 byte active    |
    // | half       | 2 byte active    |
    // | word/float | 4 byte active    |
    // | vector     | 初始 0，等待 RVV mask |
    val active = MuxUpTo1H(0.U(bytesPerSlot.W), Seq(
      // 标量 byte/half/word 访问在 slot 初始化时就知道哪些 byte lane 有效。
      uop.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> "b1".U(bytesPerSlot.W),
      uop.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> "b11".U(bytesPerSlot.W),
      uop.op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) -> "b1111".U(bytesPerSlot.W),
      // 向量访存的 active byte 由后续 rvv2lsu mask 决定。
      LsuOp.isVector(uop.op) -> 0.U(bytesPerSlot.W),
    ))
    result.active := active.asBools

    // 计算初始地址。非 strided 默认按连续 byte 地址初始化。
    result.baseAddr := uop.addr
    result.elemWidth := uop.elemWidth.getOrElse(0.U(3.W))
    result.sew := uop.sew.getOrElse(0.U(3.W))
    result.addrs := Mux(
        uop.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED),
        // strided 初始地址已经依赖 stride，因此初始化时直接生成每个 byte 的地址。
        ComputeStridedAddrs(bytesPerSlot, uop.addr, uop.data, uop.elemWidth.getOrElse(0.U(3.W))),
        // 标量和非 strided 向量先按连续 byte 初始化；向量地址稍后由 vectorUpdate 覆盖。
        VecInit((0 until bytesPerSlot).map(i => uop.addr + i.U)))

    val unitStride = Mux(
        uop.op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
                       LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED),
        // indexed load/store：unit stride 也用于控制 segment stride。
        MuxUpTo1H(1.U, Seq(
            (result.sew === "b000".U) -> 1.U,  // 1-byte 元素
            (result.sew === "b001".U) -> 2.U,  // 2-byte 元素
            (result.sew === "b010".U) -> 4.U,  // 4-byte 元素
        )),
        // 非 indexed load/store：元素宽度来自 elemWidth。
        MuxUpTo1H(1.U, Seq(
            (uop.elemWidth.getOrElse(3.U) === "b000".U) -> 1.U,  // 1-byte 元素
            (uop.elemWidth.getOrElse(3.U) === "b101".U) -> 2.U,  // 2-byte 元素
            (uop.elemWidth.getOrElse(3.U) === "b110".U) -> 4.U,  // 4-byte 元素
        )),
    )

    // unit-stride segment 需要跨 field 跳过 nfields 个元素；strided 则直接使用 rs2 stride。
    // 如果是 unit-stride segment 访存：
    // elemStride = unitStride × (nfields + 1)
    // 如果是 strided/indexed：
    // elemStride = uop.data
    result.segmentStride := unitStride
    result.elemStride := Mux(
        uop.op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT),
        unitStride + (uop.nfields.getOrElse(3.U) * unitStride),
        uop.data)

    //把 32-bit store data 拆成 4 个 byte。
    result.data(0) := uop.data(7, 0)
    result.data(1) := uop.data(15, 8)
    result.data(2) := uop.data(23, 16)
    result.data(3) := uop.data(31, 24)
    // 标量 store 最多提供 32-bit 数据，剩余 byte lane 清 0；
    // 向量 store 的完整数据会在 vectorUpdate 中由 rvv2lsu.vregfile 覆盖。
    for (i <- 4 until bytesPerSlot) {
      result.data(i) := 0.U
    }

    result
  }
}

//未使用
// class LsuCtrl(p: Parameters) extends Bundle {
//   // 旧版/辅助控制 Bundle，按总线事务抽象 LSU 控制字段。
//   // 当前 LsuV2 主路径主要使用 LsuSlot，但这些字段保留了较完整的总线事务语义。
//   val pc = UInt(32.W)
//   // addr 是原始地址，adrx 通常是对齐/扩展后的总线地址。
//   val addr = UInt(32.W)
//   val adrx = UInt(32.W)
//   // store 写数据或 load 返回数据暂存。
//   val data = UInt(32.W)
//   // 写回寄存器编号。
//   val index = UInt(5.W)
//   // size 是当前事务大小，fullsize 可表示原始请求完整大小。
//   val size = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
//   val fullsize = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
//   // write=true 表示 store；sext=true 表示 load 需要符号扩展。
//   val write = Bool()
//   val sext = Bool()
//   // iload 标记走 IBus/IMEM 的取指侧读。
//   val iload = Bool()
//   val fencei = Bool()
//   val flushat = Bool()
//   val flushall = Bool()
//   val sldst = Bool()  // cached 标量 load/store
//   val vldst = Bool()  // 向量 load/store
//   val fldst = Bool() // 浮点 load/store
//   // 访问命中的内存区域类型。
//   val regionType = MemoryRegionType()
//   // byte 写 mask。
//   val mask = UInt(p.lsuDataBytes.W)
//   // 向量 store 完成通知中的最后一拍标记。
//   val last = Bool()
// }

// class LsuReadData(p: Parameters) extends Bundle {
//   // load 返回路径携带的元数据，用于对齐、符号扩展和写回选择。
//   val addr = UInt(32.W)
//   val index = UInt(5.W)
//   val size = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
//   val fullsize = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
//   val sext = Bool()
//   val iload = Bool()
//   val sldst = Bool()
//   val fldst = Bool()
//   val regionType = MemoryRegionType()
//   val mask = UInt(p.lsuDataBytes.W)
//   // 向量 load/store 回传给 RVV core 时使用的结束标记。
//   val last = Bool()
// }

object LsuBus extends ChiselEnum {
  // LSU 可访问的三类总线目标。
  val IBUS = Value
  val DBUS = Value
  val EXTERNAL = Value
}

class LsuRead(lineBits: Int) extends Bundle {
  // 记录上一拍发出的 read，用于下一拍选择正确 rdata 并避免重复发同一 line。
  val bus = LsuBus()
  val lineAddr = UInt(lineBits.W)
}

object LsuRead {
  def apply(bus: LsuBus.Type, lineAddr: UInt): LsuRead = {
    val result = Wire(new LsuRead(lineAddr.getWidth))
    result.bus := bus
    result.lineAddr := lineAddr
    result
  }
}

class FlushCmd extends Bundle {
  // 等待 cache/取指侧接受的 flush/fencei 命令。
  // all=true 表示全局 flush；fencei=true 时还需要刷新取指侧并跳转 pcNext。
  val all = Bool()
  val fencei = Bool()
  val pcNext = UInt(32.W)
}

object FlushCmd {
  def apply(cmd: LsuCmd): FlushCmd = {
    // 从 LSU flush 类命令生成实际 flush 控制。
    val result = Wire(new FlushCmd)
    result.all    := cmd.op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHALL)
    result.fencei := (cmd.op === LsuOp.FENCEI)
    result.pcNext := cmd.pc + 4.U
    result
  }
}

class LsuV2(p: Parameters) extends Lsu(p) {
  class LsuFault(p: Parameters) extends Bundle {
    // fault 需要额外保存 rd/op/store，后续写回屏蔽和 slot 清理会用到。
    // | 字段     | 作用                |
    // | ------- | ----------------- |
    // | `info`  | fault 地址、epc、读写类型 |
    // | `rd`    | fault 指令原本的 rd    |
    // | `op`    | fault 指令类型        |
    // | `store` | fault 是否来自 store  |
    val info = new FaultInfo(p)
    val rd = UInt(5.W)
    val op = LsuOp()
    val store = Bool()
  }

  // ---- 默认连接 ----
  io.vldst := 0.U  //默认没有向量访存活动提示。

  // 多 lane Dispatch 请求先进入小型 circular queue，LSU 主体一次只处理一个 slot。
  // | 参数   | 含义                   |
  // | ---- | -------------------- |
  // | 入队宽度 | `p.instructionLanes` |
  // | 队列深度 | 4                    |
  // | 队列元素 | `LsuUOp`             |
  //队列最多缓存 4 条 LsuUOp。不是 instructionLanes × 4。
  val opQueue = Module(new CircularBufferMulti(new LsuUOp(p), p.instructionLanes, 4))
  opQueue.io.flush := false.B
  //把队列剩余空间输出给 Dispatch。
  io.queueCapacity := opQueue.io.nSpace

  // ---- Flush 状态 ----
  // DispatchV2 只会在 lane0 且 LSU inactive 时发 flush，因此这里维护一个 pending flush 即可。
  val flushCmd = RegInit(MakeInvalid(new FlushCmd))  // 跟踪等待完成的 flush/fencei 和 pcNext
  io.flush.valid  := flushCmd.valid
  io.flush.all    := flushCmd.bits.all
  io.flush.clean  := true.B
  io.flush.fencei := flushCmd.bits.fencei
  io.flush.pcNext := flushCmd.bits.pcNext

  //如果 lane0 发射了 flush/fence 指令，则生成一个 pending flushCmd。
  flushCmd := MuxCase(flushCmd, Seq(
    // 收到新的 flush/fencei 命令。
    (io.req(0).fire && LsuOp.isFlush(io.req(0).bits.op))  //flush/fence 只能从 lane0 进入。
        -> MakeValid(true.B, FlushCmd(io.req(0).bits)),
    // 下游接受 flush 后清除 pending 状态。
    (io.flush.valid && io.flush.ready) -> MakeInvalid(new FlushCmd),
  ))

  // ---- Decode 请求入队 ----
  // 根据队列剩余空间对每个 lane 产生 ready；flush pending 时暂停接收普通请求。
  val queueSpace = opQueue.io.nSpace
  // validSum(i) 表示 lane i 之前已经有多少条 valid 请求，用来避免超过队列剩余容量。
  val validSum = io.req.map(_.valid).scan(
      0.U(log2Ceil(p.instructionLanes + 1).W))(_+_)  //valid = [1,1,0,1], validSum = [0,1,2,2,3]
  for (i <- 0 until p.instructionLanes) {
    io.req(i).ready := (validSum(i) < queueSpace) && !flushCmd.valid //队列剩余空间够容纳它之前的请求 $$flush pending 时不接受普通请求
  }

  // 将 fire 的请求转换为 LsuUOp；flush 类命令不进入普通 opQueue。
  val ops = (0 until p.instructionLanes).map(i =>  // //对每个 lane 生成一个候选 uop。
    MakeValid(
        io.req(i).fire && !LsuOp.isFlush(io.req(i).bits.op), 
        LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState))  //如果该 lane fire 且不是 flush，则构造有效的 LsuUOp。
  )
  val alignedOps = Aligner(ops)  //把有效 uop 压紧

  // Aligner 会压紧有效 lane，使 circular queue 连续入队。
  opQueue.io.enqValid := PopCount(alignedOps.map(_.valid))  //入队数量等于有效 uop 数。
  opQueue.io.enqData := alignedOps.map(_.bits)  //把压紧后的 uop 写入队列。
  assert(opQueue.io.enqValid <= opQueue.io.nSpace)

  // 队首 uop 展开为下一条可装入 slot 的初始状态。
  val nextSlot = LsuSlot.fromLsuUOp(opQueue.io.dataOut(0), p, 16)

  // 记录上一拍发出的 read 请求；本拍用它选择 rdata 并更新 slot。
  val readFired = RegInit(MakeInvalid(new LsuRead(32 - nextSlot.elemBits)))
  val slot = RegInit(LsuSlot.inactive(p, 16))

  // 按上一拍发出的 bus 类型选择本拍读回数据。
  val readData = MuxLookup(readFired.bits.bus, 0.U)(Seq(
      LsuBus.IBUS -> io.ibus.rdata,
      LsuBus.DBUS -> io.dbus.rdata,
      LsuBus.EXTERNAL -> io.ebus.dbus.rdata,
  ))

  // ==========================================================================
  // ---- 向量输入更新 ----
  // 向量访存需要先从 RVV core 获取 mask/index/store data，填充当前 slot 的 byte 状态。
  val vectorUpdatedSlot = if (p.enableRvv) {
      io.rvv2lsu.get(0).ready := slot.pendingVector()  //当 slot 正在等待 RVV 提供 mask/index/data 时，第 0 路 RVV→LSU ready 拉高。
      io.rvv2lsu.get(1).ready := false.B  // 目前只使用一个 rvv2lsu 接口，第二个接口保留给未来扩展。
      slot.vectorUpdate(io.rvv2lsu.get(0).bits)  //用 RVV 提供的数据更新 slot。
  } else {
      slot  //用 RVV 提供的数据更新 slot。
  }

  // ==========================================================================
  // ---- 事务更新 ----
  // faultReg 保存已经发现但尚未被 FaultManager 消费的异常。
  val faultReg = RegInit(MakeInvalid(new LsuFault(p)))

  // load 更新第一阶段：如果上一拍发过 read，则本拍用 readData 更新 slot。否则 slot 不变
  val loadUpdatedSlot = Mux(readFired.valid,
                            slot.loadUpdate(readFired.bits.lineAddr, readData),
                            slot)

  // 计算下一条目标事务。targetAddress 是 byte 地址，targetLine 是总线 line 地址。
  val targetAddress = loadUpdatedSlot.targetAddress(
      MakeValid(readFired.valid, readFired.bits.lineAddr))
  val targetLine = MakeValid(
      targetAddress.valid, targetAddress.bits(31, nextSlot.elemBits))
  val targetLineAddr = targetLine.bits << 4
  // 根据地址映射判断该 line 应走 ITCM、DTCM、peripheral 还是外部总线。
  // 注意这里使用 line 对齐地址做 region 判断，保证跨 byte lane 的同一 line 走同一路径。
  val itcm = p.m.filter(_.memType == MemoryRegionType.IMEM)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(false.B)
  val dtcm = p.m.filter(_.memType == MemoryRegionType.DMEM)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(true.B)
  val peri = p.m.filter(_.memType == MemoryRegionType.Peripheral)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(false.B)
  // 未命中片上 IMEM/DMEM/peripheral 的地址统一视作外部地址空间。
  val external = !(itcm || dtcm || peri)
  // 一个地址最多命中一个内部区域。
  assert(PopCount(Cat(itcm | dtcm | peri)) <= 1.U)

  // store 时将 slot 内 byte 数据 scatter 成总线 wdata/wmask。
  val (wdata, wmask, wactive) = slot.scatter(targetLine.bits)

  // 根据操作类型和地址对齐情况计算总线 size 及对齐地址。
  val (opSize, alignedAddress) = LsuOp.opSize(slot.op, targetAddress.bits)

  // ---- IBus 路径 ----
  // IMEM 区域只允许 load；store 到 IMEM 会在 fault 逻辑中报错。
  io.ibus.valid := loadUpdatedSlot.activeTransaction() && itcm && !slot.store && !faultReg.valid
  io.ibus.addr := targetLineAddr

  // ---- DBus 路径 ----
  // DTCM/DMEM 区域走 dbus，load 使用 loadUpdatedSlot，store 使用当前 slot。
  io.dbus.valid := dtcm && Mux(slot.store,
                               slot.activeTransaction(),
                               loadUpdatedSlot.activeTransaction()) && !faultReg.valid
  io.dbus.write := slot.store
  io.dbus.pc := slot.pc
  io.dbus.addr := targetLineAddr
  io.dbus.adrx := targetLineAddr
  io.dbus.size := opSize
  io.dbus.wdata := Cat(wdata.reverse)
  io.dbus.wmask := Cat(wmask.reverse)

  // ---- EBus 路径 ----
  // peripheral 和外部地址空间走 ebus；peri 会设置 internal 提示内部外设访问。
  io.ebus.dbus.valid := (external || peri) && Mux(slot.store,
                                                  slot.activeTransaction(),
                                                  loadUpdatedSlot.activeTransaction()) && !faultReg.valid
  io.ebus.dbus.write := slot.store
  io.ebus.dbus.addr := alignedAddress
  io.ebus.dbus.adrx := targetLineAddr
  io.ebus.dbus.size := opSize
  io.ebus.dbus.wdata := Cat(wdata.reverse)
  io.ebus.dbus.wmask := Cat(wmask.reverse)
  io.ebus.dbus.pc := slot.pc
  io.ebus.internal := peri

  val ibusFired = io.ibus.valid && io.ibus.ready
  val dbusFired = io.dbus.valid && io.dbus.ready
  val ebusFired = io.ebus.dbus.valid && io.ebus.dbus.ready
  // 同一拍只能向一个总线目标发起事务。
  assert(PopCount(Seq(ibusFired, dbusFired, ebusFired)) <= 1.U)
  val slotFired = ebusFired || dbusFired || ibusFired

  // 只有 load 事务需要记录 readFired，store 不会在下一拍读回数据。
  // readFired 同时保存 bus 类型和 line 地址，下一拍才能从正确 rdata 端口 gather 数据。
  val readFiredValid = ibusFired || (dbusFired && !io.dbus.write) || (ebusFired && !io.ebus.dbus.write)
  readFired := MakeValid(readFiredValid,
    MuxCase(readFired.bits, Seq(
      (ibusFired) -> LsuRead(LsuBus.IBUS, targetLine.bits),
      (dbusFired && !io.dbus.write) -> LsuRead(LsuBus.DBUS, targetLine.bits),
      (ebusFired && !io.ebus.dbus.write) -> LsuRead(LsuBus.EXTERNAL, targetLine.bits),
    )))

  // ---- 异常处理 ----
  // 当前显式处理两类 fault：外部总线返回 fault，以及对 IMEM 发起 store。
  val ibusFault = Wire(Valid(new FaultInfo(p)))
  ibusFault.valid := loadUpdatedSlot.activeTransaction() && itcm && slot.store
  ibusFault.bits.write := true.B
  ibusFault.bits.addr := targetLineAddr
  ibusFault.bits.epc := slot.pc

  io.fault.valid := faultReg.valid
  io.fault.bits := faultReg.bits.info
  faultReg := {
    // 发现 fault 后保留当前 slot 的 rd/op/store，直到下一轮状态更新清空 slot。
    val f = Wire(Valid(new LsuFault(p)))
    // 外部总线 fault 优先于内部 ibus store fault，因为外部 fault 来自真实响应。
    val nextFaultInfo = MuxCase(MakeInvalid(new FaultInfo(p)), Seq(
        io.ebus.fault.valid -> io.ebus.fault,
        ibusFault.valid -> ibusFault,
    ))
    f.valid := nextFaultInfo.valid
    f.bits.info := nextFaultInfo.bits
    f.bits.rd := slot.rd
    f.bits.op := slot.op
    f.bits.store := slot.store
    f
  }

  // ---- 事务更新 ----
  // 对 store：总线 fire 后清除本次写出的 byte lane。
  // 对 load：loadUpdatedSlot 已经根据 readData 清除读回的 byte lane。
  val storeUpdate = Mux(slotFired, wactive, VecInit.fill(16)(false.B))  //如果本拍 store fire，则 storeUpdate 是本次写出的 byte mask。否则全 false。
  //如果是 store，用 storeUpdate 清除写完的 byte。
  //如果是 load，用 loadUpdatedSlot 清除读回的 byte。
  val transactionUpdatedSlot = Mux(slot.store,
      slot.storeUpdate(storeUpdate), loadUpdatedSlot)
  val lsu2RvvFire = if (p.enableRvv) { io.lsu2rvv.get(0).fire } else { false.B }
  // 标量 store：所有 byte 写完时完成。
  // 向量 store：lsu2rvv 带 last 的完成握手 fire 时完成。
  // 两者发生在不同周期，因此不能简单 AND 在一起。
  // | 标量store条件                        | 含义             |
  // | ----------------------------------- | -------------- |
  // | `slotFired`                         | 本拍 store 被总线接受 |
  // | `slot.store`                        | 当前是 store      |
  // | `!slot.slotIdle()`                  | 之前 slot 不是空    |
  // | `transactionUpdatedSlot.slotIdle()` | 本次事务后 slot 变空  |
  // | `!LsuOp.isVector(slot.op)`          | 不是向量 store     |
  val scalarStoreComplete = slotFired && slot.store && !slot.slotIdle() &&
      transactionUpdatedSlot.slotIdle() && !LsuOp.isVector(slot.op)
  //LSU 已经通过 lsu2rvv 通知 RVV，并且 last=1。
  val vectorStoreComplete = if (p.enableRvv) {
      lsu2RvvFire && io.lsu2rvv.get(0).bits.last
  } else { false.B }
  val storeComplete = scalarStoreComplete || vectorStoreComplete
  // 如果外部总线同拍报 fault，则不发 storeComplete，避免 ROB 误认为 store 正常完成。
  io.storeComplete := Mux(storeComplete && !io.ebus.fault.valid, MakeValid(slot.pc), MakeInvalid(UInt(32.W)))


  // ==========================================================================
  // ---- 写回更新 ----
  // faultReg 有效时，后续判断使用 fault 捕获时保存的 op/store/rd。

  val currentOp = Mux(faultReg.valid, faultReg.bits.op, slot.op)
  val currentStore = Mux(faultReg.valid, faultReg.bits.store, slot.store)

  // ---- 标量写回 ----
  // fault 时仍产生写回 valid，但 io.fault.valid 会在上层屏蔽/处理该写回。
  // | 条件                         | 说明                       |
  // | -------------------------- | ------------------------ |
  // | faultReg 是 scalar load     | fault 情况仍产生 valid，后续上层处理 |
  // | 或 `slot.shouldWriteback()` | 正常 load 已完成              |
  // | 当前 op 是标量 load             | 必须是 LB/LBU/LH/LHU/LW     |
  io.rd.valid := ((faultReg.valid && LsuOp.isScalarLoad(faultReg.bits.op)) || slot.shouldWriteback()) &&
      currentOp.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)

  io.rd.bits.data := slot.scalarLoadResult()
  io.rd.bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)

  // ---- 浮点写回 ----
  // float load 与标量 load 共用 scalarLoadResult 的 byte 拼接逻辑。
  io.rd_flt.valid := ((faultReg.valid && !currentStore) || slot.shouldWriteback()) &&
                     (currentOp === LsuOp.FLOAT)
  io.rd_flt.bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)
  io.rd_flt.bits.data := slot.scalarLoadResult()

  // ---- 向量写回/完成通知 ----
  if (p.enableRvv) {
    val faultDetected = faultReg.valid
    // 若发生 fault，仍必须通知 RVV core 完成，以便 RVV 后端退役该指令并转入 trap 处理。
    val vectorFault = faultDetected && LsuOp.isVector(currentOp)

    io.lsu2rvv.get(0).valid := (slot.shouldWriteback() && LsuOp.isVector(currentOp)) || vectorFault
    io.lsu2rvv.get(0).bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)
    io.lsu2rvv.get(0).bits.data := Cat(slot.data.reverse)
    io.lsu2rvv.get(0).bits.last := (slot.shouldWriteback() || vectorFault) &&
        currentOp.isOneOf(LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED,
                        LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)

    io.lsu2rvv.get(1).valid := false.B
    io.lsu2rvv.get(1).bits.addr := 0.U
    io.lsu2rvv.get(1).bits.data := 0.U
    io.lsu2rvv.get(1).bits.last := true.B
  }

  val writebacksFired = Seq(io.rd.valid, io.rd_flt.valid) ++ (if (p.enableRvv) {
      Seq(io.lsu2rvv.get(0).fire) } else { Seq() })
  // 标量、浮点、向量写回/完成通知同一拍最多发生一个，简化 slot 更新。
  assert(PopCount(writebacksFired) <= 1.U)
  val writebackFired = writebacksFired.reduce(_ || _)
  val writebackUpdatedSlot = slot.writebackUpdate()

  // TODO(derekjchow): 改善 opQueue 出队路径时序。
  opQueue.io.deqReady := Mux(slot.slotIdle() && (opQueue.io.nEnqueued > 0.U), 1.U, 0.U)  //只有 slot 空闲且队列非空时，出队 1 条。

  // ==========================================================================
  // ---- 状态转移 ----

  // ---- 关键断言 ----
  val vectorUpdate = io.rvv2lsu.map(_(0).fire).getOrElse(false.B)
  assert(!vectorUpdate || slot.pendingVector())
  assert(!writebackFired || (slot.shouldWriteback() || faultReg.valid))

  // 先处理 fault
  // 再装载新 uop
  // 再补齐 RVV 数据
  // 再做总线事务
  // 最后做写回/完成通知
  // ---- Slot 状态更新优先级 ----
  val slotNext = MuxCase(slot, Seq(
    // fault 后立刻清空 slot，faultReg 负责保存上报信息。
    (faultReg.valid) -> LsuSlot.inactive(p, 16),
    // slot 空闲时从队列取下一条 uop。
    (slot.slotIdle() && (opQueue.io.nEnqueued > 0.U)) -> nextSlot,
    // 向量访存优先接收 RVV core 提供的 mask/index/data。
    vectorUpdate -> vectorUpdatedSlot,
    // 若仍有 active byte，则继续发起/完成总线事务。
    slot.activeTransaction() -> transactionUpdatedSlot,
    // 最后处理寄存器写回或向量完成通知。
    writebackFired -> writebackUpdatedSlot,
  ))

  slot := slotNext

  // active 供 Dispatch/fence 判断 LSU 是否仍有未完成工作。
  io.active := !slot.slotIdle() || (opQueue.io.nEnqueued =/= 0.U)
}
