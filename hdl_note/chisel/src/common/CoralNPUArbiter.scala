// ============================================================================
// CoralNPUArbiter.scala — Round-Robin 公平轮转仲裁器
//
// 基于 Chisel 的 LockingRRArbiter 的 fork 版本。
// 与 Chisel 原版的关键区别: lastGrant 初始化为 0 (而非随机值),
// 解决仿真中的 X-Propagation 问题, 同时保证综合行为确定。
//
// Round-Robin 原理:
//   上次仲裁胜出的端口之后的下一个端口获得最高优先级,
//   轮转循环确保所有端口公平获得服务。
//
//   例 (n=4, lastGrant=1): 优先级 = port2 > port3 > port0 > port1
//
// 核心组件:
//   CoralNPUArbiterCtrl    — 优先级控制逻辑 (固定优先级 → 轮转映射)
//   InitedLockingRRArbiter — Locking 仲裁器 (锁定模式: 胜出后保持直到事务完成)
//   CoralNPURRArbiter      — 对外接口 (count=1 表示无额外锁定计数)
// io.in(0).valid ─┐
// io.in(1).valid ─┤
// io.in(2).valid ─┤──► RR Arbiter ───► io.out.valid
// io.in(3).valid ─┘

// io.out.ready ───────────────► 被选中端口的 ready

// io.in(i).bits ──────────────► io.out.bits
// io.chosen ──────────────────► 当前选中端口编号
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

package common

import chisel3._
import chisel3.util._

// ===================================================================
// CoralNPUArbiterCtrl — 优先级控制逻辑
//
// 输入: N 个请求信号 request(n)
// 输出: N 个 grant 信号 grant(n) (one-hot, 最多一个为 true)
//
// 算法:
//   例 request = [a, b, c, d]
//   head    = a                        (最高优先, 总是通过)
//   tail    = scanLeft(b, c, d)(_||_)  (累积 OR: b, b||c, b||c||d)
//   grants  = [a, !b, !(b||c), !(b||c||d)]
//
//   含义: a 总是被授予; b 仅在 a=0 时被授予; c 仅在 a=b=0 时被授予; ...
//       这就是"固定优先级"的 grant 生成逻辑
// ===================================================================
object CoralNPUArbiterCtrl {
  /** 生成 N 个请求的固定优先级 grant 信号 (request(0) 最高优先级) */
  def apply(request: Seq[Bool]): Seq[Bool] = request.length match {
    case 0 => Seq()                                              // 无请求 → 无 grant
    case 1 => Seq(true.B)                                        // 单请求 → 总是授予
    case _ =>
      // scanLeft 从左到右累积 OR
      // 例: request=[a,b,c,d] → scanLeft(a)(_||_) = [a, a||b, a||b||c]
      //     tail.init = [b, c]; 结果: [a, !a, !(a||b), !(a||b||c)]
      true.B +: request.tail.init.scanLeft(request.head)(_ || _).map(!_)//
  }
}

// ===================================================================
// InitedLockingRRArbiter — 带初始化的 Locking Round-Robin 仲裁器
//
// Locking 模式: 一旦某个端口胜出 (io.out.fire), 仲裁器"锁定"该端口,
//              直到事务完成才释放。在 AXI 等需要多周期事务的总线上至关重要。
//
// Round-Robin 实现:
//   lastGrant: 上次胜出的端口号 (RegInit=0, 仿真友好)
//   grantMask: 优先级掩码 — 端口号 > lastGrant 的端口有优先权
//   validMask: 仅考虑"有优先权"的请求
//   最终 grant: 先在 validMask 中选, 若全无则回退到所有请求中选
//
// choice 信号: 输出当前选中的端口号, 供外部路由使用
//              (如 CoreAxi 的 inflight Queue 用它记录请求来源)
// ===================================================================
class InitedLockingRRArbiter[T <: Data](gen: T, n: Int, count: Int, needsLock: Option[T => Bool] = None)
    extends LockingArbiterLike[T](gen, n, count, needsLock) {

  // lastGrant: 上次胜出的端口号。RegInit=0 避免仿真 X 传播问题
  lazy val lastGrant = RegInit(0.U(log2Ceil(n).W))
  lastGrant := Mux(io.out.fire, io.chosen, lastGrant)            // 输出握手时更新

  // grantMask(i): 端口 i 是否有"高于 lastGrant"的 RR 优先级
  // 例: n=4, lastGrant=1 → grantMask=[0,0,1,1] (端口2,3优先)
  lazy val grantMask = (0 until n).map(_.asUInt > lastGrant)//port i 是否位于 lastGrant 后面
  // validMask(i): 有请求 且 有优先权
  lazy val validMask = io.in.zip(grantMask).map { case (in, g) => in.valid && g }//port i 有请求，并且 port i 在 lastGrant 后面

  /** grant: 生成 one-hot 选择信号
   *  先在 validMask (高于lastGrant的端口) 中用固定优先级选, 若全无则回退到所有请求 */
  override def grant: Seq[Bool] = {
    // ctrl(i):   仅 validMask 中的固定优先级 (i < n)
    // ctrl(i+n): 所有请求中的固定优先级 (回退, i >= n)
    val ctrl = CoralNPUArbiterCtrl((0 until n).map(i => validMask(i)) ++ io.in.map(_.valid))
    (0 until n).map(i => ctrl(i) && grantMask(i) || ctrl(i + n))
  }

  /** choice: 输出选中的端口号
   *  validMask 中的端口优先于普通请求中的端口 (RR 语义)
   *  从高到低用 when 链: 后覆盖前, 实现优先级 */
  override lazy val choice = WireDefault((n - 1).asUInt)         // 默认最后一个
  for (i <- n - 2 to 0 by -1)                                    // 普通请求: 端口号小的覆盖大的
    when(io.in(i).valid) { choice := i.asUInt }
  for (i <- n - 1 to 1 by -1)                                    // validMask: 有优先权的端口覆盖
    when(validMask(i)) { choice := i.asUInt }
}

// ===================================================================
// CoralNPURRArbiter — 对外使用的 Round-Robin 仲裁器
//
// count=1: 锁定 1 周期 (事务完成后立即释放), 本质上等同于普通 RRArbiter
//          但保留了 lastGrant 初始化为 0 的行为
// ===================================================================
/** CoralNPURRArbiter — Round-Robin 仲裁器
 *  @param gen 被仲裁的数据类型
 *  @param n   输入端口数
 *  @param moduleName 可选模块名 (用于 Verilog 生成) */
class CoralNPURRArbiter[T <: Data](val gen: T, val n: Int, moduleName: Option[String] = None) extends InitedLockingRRArbiter[T](gen, n, 1) {
  override val desiredName = moduleName.getOrElse(super.desiredName)
}
