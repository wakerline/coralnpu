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
// InstructionBuffer.scala — 指令缓冲 + CircularBufferMulti (多读者环形缓冲)
// ============================================================================

package common

import chisel3._
import chisel3.util._
import common.CircularBufferMulti

/** 封装“最多 n 条元素”的向量式 Decoupled 接口。
  * 约定: bits(0) 到 bits(nValid-1) 是有效元素; nReady 表示下游当前最多可接收多少个元素。
  */
class DecoupledVectorIO[T <: Data](gen: T, n: Int) extends Bundle {
  val nReady = Input(UInt(log2Up(n+1).W))               // 下游可接收的连续元素数量
  val nValid = Output(UInt(log2Up(n+1).W))              // 上游提供的连续有效元素数量
  val bits = Output(Vec(n, gen))                        // 元素数据, 仅前 nValid 个有效
}

object DecoupledVectorIO {
  def apply[T <: Data](gen: T, n: Int): DecoupledVectorIO[T] = new DecoupledVectorIO(gen, n)
}

// Note any instruction will be available to dequeu one full cycle follong enqueuing.
// This must be accounted for when using the instruction buffer as there is no backpressure.
// 指令入队后一整拍才会在 out 侧可见; Fetch/Dispatch 使用时需要接受这个固定延迟。
class InstructionBuffer[T <: Data](val gen: T,
                                   val n: Int,
                                   val window: Int) extends Module {
  assert(window % n == 0)                               // 缓冲深度必须是每拍窗口宽度 n 的整数倍

  val io = IO(new Bundle {
    val feedIn = Flipped(DecoupledVectorIO(gen, n))     // 上游一次写入 0..n 个连续元素
    val out = Vec(n, Decoupled(gen))                    // 下游一次读取最多 n 个连续元素
    val flush = Input(Bool())                           // 清空缓冲并隐藏当前输出

    val nEnqueued = Output(UInt(log2Ceil(window + 1).W)) // 当前已缓存元素数量
    val nSpace = Output(UInt(log2Ceil(window + 1).W))    // 当前剩余空间
  })
  dontTouch(io)

  val circularBuffer = Module(new CircularBufferMulti(t = gen, n = n, capacity = window)) // 多元素环形缓冲

  // ---- Enqueue Logic ----
  // nReady 被限制为 min(n, nSpace), 上游只能声明不超过 nReady 的 nValid。
  val feedInReady = Mux(circularBuffer.io.nSpace < n.U, circularBuffer.io.nSpace, n.U)
  io.feedIn.nReady := feedInReady                       // 告诉上游本拍可写入多少条
  circularBuffer.io.enqValid := io.feedIn.nValid        // 实际入队条数
  circularBuffer.io.enqData := io.feedIn.bits           // 入队数据向量

  circularBuffer.io.flush := io.flush                   // flush 清空环形缓冲状态

  // ---- Dequeue Logic ----
  // 始终把队头起最多 n 个元素接到 out.bits, 但 valid 只对已缓存数量范围内的 lane 置位。
  // flush 当拍不向下游暴露有效数据。
  for (nIndex <- 0 until n) {
    io.out(nIndex).valid := (nIndex.U < circularBuffer.io.nEnqueued) && !io.flush // lane 是否有有效数据
    io.out(nIndex).bits := circularBuffer.io.dataOut(nIndex)       // 队头后第 nIndex 个元素
  }

  // Confirm ready signals are contiguous with assert (ex only ready(0) and ready(2) set should fail)
  // 下游必须从 lane0 开始连续 fire, 不能跳过中间元素; 这样才能保持指令顺序。
  assert(OneHotInOrder(io.out.map(_.fire)), p"OneHotInOrder - Instructions not dispatched in order.")
  val nReady = PopCount(io.out.map(_.fire))             // 本拍实际出队数量
  circularBuffer.io.deqReady := nReady                  // 通知环形缓冲弹出前 nReady 个元素

  io.nEnqueued := circularBuffer.io.nEnqueued           // 对外暴露缓存占用
  io.nSpace := circularBuffer.io.nSpace                 // 对外暴露剩余空间
}
