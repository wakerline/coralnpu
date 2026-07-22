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
// Slice.scala — 位切片工具 (宽数据总线→子元素 + 仲裁/反压)
// Slice.scala 实现了一个通用 ready/valid 弹性缓冲器。
// 核心功能：
// 1. 支持 1-entry 或 2-entry 缓冲。
// 2. 支持 Decoupled in/out 接口。
// 3. 用 ipos/opos 判断 empty/full。
// 4. 用 count 输出当前占用数量。
// 5. 用 mem 保存缓冲数据。
// 6. passReady 允许满缓冲同拍读写，提高吞吐。
// 7. passValid 允许空缓冲输入直接透传到输出，降低延迟。
// 8. 在 Fetch 中，它被用作 IBus 请求地址缓冲，切断 miss 生成逻辑到 IBus 的 ready/valid 时序路径。
// ============================================================================

package common

import chisel3._
import chisel3.util._
import _root_.circt.stage.ChiselStage

object Slice {
  // 构造 ready/valid 切片。
  // doubleBuffered 选择 1 项或 2 项缓冲，passReady/passValid 控制握手旁路。
  def apply[T <: Data](t: T, doubleBuffered: Boolean = true,
      passReady: Boolean = false, passValid: Boolean = false) = {
    Module(new Slice(t, doubleBuffered, passReady, passValid))
  }
}

class Slice[T <: Data](t: T, doubleBuffered: Boolean,
    passReady: Boolean, passValid: Boolean) extends Module {
  val io = IO(new Bundle {
    // 上游输入通道。
    val in  = Flipped(Decoupled(t))
    // 下游输出通道。
    val out = Decoupled(t)
    // 当前缓冲中保存的有效元素数量。
    val count = Output(UInt(2.W))
    // 对外暴露缓冲内容，便于调试或状态观测。
    val value = Output(Vec(if (doubleBuffered) 2 else 1, Valid(t)))
  })

  // 缓冲深度：双缓冲为 2，单缓冲为 1。
  val size = if (doubleBuffered) 2 else 1

  // 环形写指针和读指针。双缓冲时指针额外带绕回位，用于区分空和满。
  val ipos = RegInit(0.U(size.W))
  val opos = RegInit(0.U(size.W))
  // 缓冲占用计数。
  val count = RegInit(0.U(size.W))
  // 数据缓冲，复位为类型 t 对应宽度的 0。
  val mem = RegInit(VecInit(Seq.fill(size)(0.U(t.getWidth.W).asTypeOf(t))))

  // 读写指针相等表示缓冲为空。
  val empty = ipos === opos
  // valid 旁路：空缓冲且下游 ready 时，输入可直接到输出，不写入 mem。
  val bypass = if (passValid) io.in.valid && io.out.ready && empty else false.B
  // 真实写入缓冲的一拍握手。
  val ivalid = io.in.valid && io.in.ready && !bypass
  // 真实从缓冲读出的一拍握手。
  val ovalid = io.out.valid && io.out.ready && !bypass

  // 写入成功时推进写指针。
  when (ivalid) {
    ipos := ipos + 1.U
  }

  // 读出成功时推进读指针。
  when (ovalid) {
    opos := opos + 1.U
  }

  // 输入和输出不平衡时更新缓冲占用。
  when (ivalid =/= ovalid) {
    count := count + ivalid - ovalid
  }

  if (doubleBuffered) {
    // 双缓冲满条件：低位相同、绕回位不同。
    val full = ipos(0) === opos(0) && ipos(1) =/= opos(1)
    if (passReady) {
      // ready 旁路：满缓冲若本拍下游消费，仍允许上游送入新数据。
      io.in.ready := !full || io.out.ready                      // pass-through
    } else {
      // 普通模式下满缓冲直接向上游反压。
      io.in.ready := !full//切断ready/valid路径，阻止上游继续送入新数据
    }

    // mem(0) 是输出头部。满缓冲被读出时由 mem(1) 前移；
    // 空缓冲接收新数据或非满缓冲读写同拍时，由输入更新头部。
    when (ovalid && full) {
      mem(0) := mem(1)
    } .elsewhen (ivalid && !ovalid && empty ||
          ivalid && ovalid && !full) {
      mem(0) := io.in.bits
    } .otherwise {
      mem(0) := mem(0)
    }

    // mem(1) 保存第二项数据，只在头部已占用后继续接收时更新。
    when (ivalid && !ovalid && !empty ||
          ivalid && ovalid && full) {
      mem(1) := io.in.bits
    }

    // 暴露双缓冲状态：mem(0) 在非空时有效，mem(1) 仅满时有效。
    io.value(0).valid := !empty
    io.value(1).valid := full
    io.value(0).bits := mem(0)
    io.value(1).bits := mem(1)
  } else {
    if (passReady) {
      // 单缓冲 ready 旁路：空缓冲或下游本拍消费时可接收。
      io.in.ready := empty || io.out.ready                      // pass-through
    } else {
      // 普通单缓冲只在空时接收。
      io.in.ready := empty
    }

    // 单缓冲只保存一项数据。
    when (ivalid) {
      mem(0) := io.in.bits
    } .otherwise {
      mem(0) := mem(0)
    }

    // 暴露单缓冲状态。
    io.value(0).valid := !empty
    io.value(0).bits := mem(0)
  }

  if (!passValid) {
    // 无 valid 旁路时，输出只能来自缓冲。
    io.out.valid := !empty
    io.out.bits  := mem(0)
  } else {
    // valid 旁路：空缓冲时输入 valid/bits 可组合透传到输出。
    io.out.valid := !empty || io.in.valid                       // pass-through
    io.out.bits  := Mux(!empty, mem(0), io.in.bits)             // pass-through
  }

  // 导出缓冲占用数量。
  io.count := count
}

// 下面几个入口用于生成不同缓冲深度和握手旁路配置的 Slice Verilog。
object EmitSlice extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), false, false, false), args)
}

object EmitSlice_1 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), false, false, true), args)
}

object EmitSlice_2 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), false, true, false), args)
}

object EmitSlice_3 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), false, true, true), args)
}

object EmitSlice_4 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), true, false, false), args)
}

object EmitSlice_5 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), true, false, true), args)
}

object EmitSlice_6 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), true, true, false), args)
}

object EmitSlice_7 extends App {
  ChiselStage.emitSystemVerilogFile(new Slice(UInt(32.W), true, true, true), args)
}
