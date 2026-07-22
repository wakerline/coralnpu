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

// ============================================================================
// CircularBufferMulti.scala — 多入多出环形缓冲区 (Multi-issue CircularBuffer)
// ============================================================================

package common

import chisel3._
import chisel3.util._

/** CircularBufferMulti — 支持一次写入多项、一次读出多项的环形 FIFO。
  *
  * 参数:
  *   t        — 每个队列项的数据类型
  *   n        — 每周期最多 enqueue/dequeue 的项数
  *   capacity — FIFO 总深度
  *
  * 设计约束:
  *   n 和 capacity 都要求为 2 的幂，方便指针自然回绕。
  *   enqValid/deqReady 不是单 bit valid/ready，而是“本周期连续写入/读出多少项”。
  *   enqData(0) 对应最早写入的项，dataOut(0) 对应最老的待读项。
  */
class CircularBufferMulti[T <: Data](t: T, n: Int, capacity: Int) extends Module {
  // 当前实现依赖 2 的幂深度，这样指针加法截断即可完成环形回绕。
  assert(isPow2(n))
  assert(isPow2(capacity))
  val io = IO(new Bundle {
    // 本周期要写入的连续项数，范围 0..n。
    val enqValid = Input(UInt(log2Ceil(n + 1).W))
    // 写入数据数组，只有前 enqValid 项有效。
    val enqData = Input(Vec(n, t))

    // 当前 FIFO 内已占用项数。
    val nEnqueued = Output(UInt(log2Ceil(capacity + 1).W))
    // 当前 FIFO 剩余空槽数，上游通常据此决定能发射多少项。
    val nSpace = Output(UInt(log2Ceil(capacity + 1).W))

    // 从队头开始展开的最多 n 项数据；是否有效由外部结合 nEnqueued 判断。
    val dataOut = Output(Vec(n, t))
    // 本周期确认弹出的连续项数，范围 0..n。
    val deqReady = Input(UInt(log2Ceil(n + 1).W))

    // 清空 FIFO，并把读写指针恢复到 0。
    val flush = Input(Bool())
  })
  // 保留 IO 名称和层次，便于波形/调试直接观察队列状态。
  dontTouch(io)

  // 第一条断言检查“写入后再减去本周期读出”的最终占用不超过容量。
  // 理论上这允许在 FIFO 满/接近满时，只要同周期读出的项数足够多，就继续写入。
  assert(io.nEnqueued +& io.enqValid -& io.deqReady <= capacity.U)
  // 第二条断言更保守: 不考虑同周期读出释放的槽位，要求写入数不超过当前空槽。
  // 这样时序/控制更简单，代价是不能利用同周期 pop 腾出的空间做旁路写入。
  assert(io.enqValid <= (capacity.U -& io.nEnqueued))

  // 不能弹出超过当前已经入队的项数。
  assert(io.deqReady <= io.nEnqueued)

  // buffer 保存实际队列内容；enqPtr 指向下一次写入起点，deqPtr 指向当前队头。
  val buffer = RegInit(VecInit.fill(capacity)(0.U.asTypeOf(t)))
  val enqPtr = RegInit(0.U(log2Ceil(capacity).W))
  val deqPtr = RegInit(0.U(log2Ceil(capacity).W))

  // 将最多 n 项输入扩展到 capacity 项，方便后续按 enqPtr 旋转到真实写入位置。
  val expandedInput = Wire(Vec(capacity, Valid(t)))
  for (i <- 0 until capacity) {
    if (i < n) {
      // 前 enqValid 项标记为有效，其余输入 lane 不写入。
      expandedInput(i) := MakeValid(i.U < io.enqValid, io.enqData(i))
    } else {
      // n 之外的扩展 lane 永远无效，只用于凑齐 capacity 宽度。
      expandedInput(i) := MakeInvalid(t)
    }
  }

  // 左旋后，expandedInput(0) 对齐到 enqPtr，连续 enqValid 项落到环形 buffer 中。
  val rotatedInput = RotateVectorLeft(expandedInput, enqPtr)
  for (i <- 0 until capacity) {
    // 只有本周期命中的写入位置更新，其余槽保持原值。
    buffer(i) := Mux(rotatedInput(i).valid, rotatedInput(i).bits, buffer(i))
  }

  // nEnqueued 是当前占用数；flush 优先清空状态。
  var nEnqueued = RegInit(0.U(io.nEnqueued.getWidth.W))
  enqPtr    := Mux(io.flush, 0.U, enqPtr + io.enqValid)
  deqPtr    := Mux(io.flush, 0.U, deqPtr + io.deqReady)
  nEnqueued := Mux(io.flush, 0.U, nEnqueued + io.enqValid - io.deqReady)

  // 对外暴露占用数和剩余空间。
  io.nEnqueued := nEnqueued
  io.nSpace := capacity.U - nEnqueued

  // 右旋后让 deqPtr 指向的最老项出现在 dataOut(0)，后续项顺序展开。
  val outputBufferView = RotateVectorRight(buffer, deqPtr)
  for (i <- 0 until n) {
    io.dataOut(i) := outputBufferView(i)
  }
}
