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
// RvvInterface.scala — RVV 向量核接口定义 (RISC-V Vector Extension 1.0)
//
// 定义了标量核 (SCore) 与向量核 (RvvCore) 之间的全部通信接口。
//
// 信号分组:
//   RvvConfigState — 向量配置状态 (vl/vtype/sew/lmul/vstart/xrm)
//   Rvv2Lsu        — RVV→LSU: 向量访存请求
//   Lsu2Rvv        — LSU→RVV: 向量访存结果返回
//   RvvCoreIO      — 标量核↔向量核的完整接口
//   Rob2Rt         — ROB→退役阶段: 向量写回信息
//   RvvCsrIO       — RVV CSR 接口 (vstart/vxrm/vxsat/frm)
// ============================================================================

package coralnpu.rvv

import chisel3._
import chisel3.util._
import coralnpu.{RegfileReadDataIO, RegfileWriteDataIO, Parameters}

// ===================================================================
// RvvConfigState — 向量配置状态 (来自 vsetvli/vsetivli 指令)
//
// 对应 RISC-V Vector Spec 1.0 的 vtype 寄存器字段。
// ===================================================================
class RvvConfigState(p: Parameters) extends Bundle {
  // 这些字段由 RVV 后端根据 vset* 指令和 CSR 状态维护，并反馈给 Decode/Dispatch 做互锁判断。
  val vl      = Output(UInt(log2Ceil(p.rvvVlen + 1).W))        // 向量长度 (VL, 当前操作的元素数, 0~VLMAX)
  val vstart  = Output(UInt(log2Ceil(p.rvvVlen).W))            // 向量起始元素索引 (用于恢复中断的向量操作)
  val ma      = Output(Bool())                                  // 掩码无关 (mask agnostic): 非活跃元素保持/清零
  val ta      = Output(Bool())                                  // 尾部无关 (tail agnostic): 超出 VL 的元素处理方式
  val xrm     = Output(UInt(2.W))                               // 定点舍入模式 (0=rne, 1=rtz, 2=rdn, 3=rup)
  val sew     = Output(UInt(3.W))                               // 选定元素宽度 (0=8b, 1=16b, 2=32b, 3=64b, 5=16b, 6=32b...)
  val lmul    = Output(UInt(3.W))                               // 向量寄存器组乘数 (可能被 VL 缩减)
  val lmul_orig = Output(UInt(3.W))                             // 原始 LMUL (来自 vsetvl, 未经 VL 缩减)
  val vill    = Output(Bool())                                  // 非法向量配置 (vtype 编码不合法)

  /** 构造 vtype CSR 值 (RVV Spec 1.0 §3.4)
   *  位布局: [31]vill | [30:7]0 | [6]ma | [5]ta | [4:2]sew | [1:0]lmul_orig (标准字段顺序可能不同)  */
  def vtype: UInt = Cat(vill, 0.U(23.W), ma, ta, sew, lmul_orig)
}

// ===================================================================
// LSU ↔ RVV 通信接口
// ===================================================================

/** Lsu2Rvv — LSU→RVV: 向量 load 数据返回
 *  addr — 目标向量寄存器号
 *  data — VLEN 位宽的向量数据
 *  last — 最后一条微操作 (向量指令可能分解为多个 uOP) */
class Lsu2Rvv(p: Parameters) extends Bundle {
  // LSU 返回 load 数据时，RVV 后端根据 addr/last 完成向量寄存器写回和指令结束判断。
  val addr = UInt(5.W)                                           // 目标向量寄存器 (v0~v31)
  val data = UInt(p.rvvVlen.W)                                   // 向量数据 (128-bit)
  val last = Bool()                                               // 该向量指令的最后一条 uOP
}

/** Rvv2Lsu — RVV→LSU: 向量访存请求
 *  idx       — 索引数据 (用于 indexed load/store)
 *  vregfile  — 向量寄存器数据 (用于 store)
 *  mask      — 访存掩码 (控制哪些元素参与访存) */
class Rvv2Lsu(p: Parameters) extends Bundle {
  // indexed load/store 使用 idx，store 使用 vregfile，mask 用于按元素屏蔽访存。
  val idx = Valid(new Bundle {
    val addr = UInt(5.W)                                         // 索引寄存器号
    val data = UInt(p.rvvVlen.W)                                 // 索引数据 (128-bit)
  })
  val vregfile = Valid(new Bundle {
    val addr = UInt(5.W)                                         // 源向量寄存器号
    val data = UInt(p.rvvVlen.W)                                 // 向量数据
  })
  val mask = Valid(UInt(p.rvvVlenb.W))                           // 访存掩码 (VLENB-bit)
}

// ===================================================================
// RvvCoreIO — 标量核 ↔ 向量核的完整接口
//
// 信号流程:
//   指令:   Dispatch → inst (Decoupled) → RvvCore 译码
//   操作数: Regfile → rs/frs → RvvCore 执行
//   访存:   RvvCore → rvv2lsu → LSU (load/store 请求)
//           LSU → lsu2rvv → RvvCore (load 数据返回)
//   写回:   RvvCore → rd (标量) / async_rd (异步标量) / async_frd (异步浮点)
//   配置:   RvvCore → configState (反馈 VL/VTYPE)
//   异常:   RvvCore → trap (非法指令/断点)
// ===================================================================
class RvvCoreIO(p: Parameters) extends Bundle {
    // ---- 指令输入 (译码阶段) ----
    val inst = Vec(p.instructionLanes,
        Flipped(Decoupled(new RvvCompressedInstruction)))         // 压缩格式向量指令

    // ---- 操作数 (执行阶段) ----
    val rs  = Vec(p.instructionLanes * 2, Flipped(new RegfileReadDataIO)) // 标量操作数 (每 lane 2 个)
    val rd  = Vec(p.instructionLanes, Valid(new RegfileWriteDataIO))      // 向量→标量写回 (vfmv.f.s 等)
    val frs = Vec(p.instructionLanes, Input(UInt(32.W)))          // 浮点操作数 (来自 FRegfile)

    // ---- LSU 协处理接口 ----
    val rvv2lsu = Vec(2, Decoupled(new Rvv2Lsu(p)))              // RVV→LSU: 向量访存请求 (2 通道)
    val lsu2rvv = Vec(2, Flipped(Decoupled(new Lsu2Rvv(p))))     // LSU→RVV: load 数据返回 (2 通道)

    // ---- 配置状态 (RVV→SCore) ----
    val configState = Output(Valid(new RvvConfigState(p)))       // 当前 VL/VTYPE 等

    // ---- 异步标量写回 ----
    val async_rd  = Decoupled(new RegfileWriteDataIO)             // 异步标量寄存器写 (非 vmv)
    val async_frd = Decoupled(new RegfileWriteDataIO)             // 异步浮点寄存器写 (vfmv.f.s)

    // ---- 异常 ----
    val trap       = Output(Valid(new RvvCompressedInstruction))  // 向量异常 (附带异常指令编码)

    // ---- CSR 接口 ----
    // vstart/vxrm/vxsat 可由 CSR 模块写入，也可由 RVV 后端执行结果更新。
    val csr = new RvvCsrIO(p)

    // ---- 流水线状态 ----
    val rvv_idle        = Output(Bool())                          // 向量核空闲 (无在飞指令)
    val queue_capacity  = Output(UInt(4.W))                       // 输入队列剩余容量 (→ Dispatch)

    // ---- ROB→退役阶段 ----
    val rd_rob2rt_o = Vec(4, new Rob2Rt(p))                      // ROB 输出: 退役时向量写回信息 (4 通道)
}

// ===================================================================
// Rob2Rt — ROB (重排序缓冲) → 退役阶段
//
// 每条向量指令退役时, 将写回信息通过此接口发送到 RetirementBuffer。
// ===================================================================
class Rob2Rt(p: Parameters) extends Bundle {
  val valid         = Bool()                                      // 该通道有效
  val w_valid       = Bool()                                      // 写回有效
  val w_index       = UInt(5.W)                                  // 写回寄存器号 (v0~v31 或 x0~x31)
  val w_data        = UInt(p.rvvVlen.W)                          // 写回数据 (VLEN 位)
  val w_type        = Bool()                                      // 写回类型: 0=VRF(向量), 1=XRF(标量)
  val vd_type       = UInt(p.rvvVlenb.W)                         // 向量元素宽度 (VLENB-bit, 每元素 1 bit)
  val trap_flag     = Bool()                                      // 该指令触发异常
  val vector_csr    = new RvvConfigState(p)                       // 退役时的 CSR 快照
  val vxsaturate    = UInt(p.rvvVlenb.W)                         // 定点饱和标志 (VLENB-bit)
  val uop_pc        = UInt(32.W)                                  // 微操作 PC (用于关联写回)
  val last_uop_valid = Bool()                                     // 最后一条微操作 (标记向量指令的结束)
}

// ===================================================================
// RvvCsrIO — RVV CSR 接口 (vstart/vxrm/vxsat/frm)
// ===================================================================
class RvvCsrIO(p: Parameters) extends Bundle {
  // RVV 后端向 CSR 模块导出当前状态，同时接收 CSR 指令写入的新值。
  val vstart       = Output(UInt(log2Ceil(p.rvvVlen).W))        // RVV→CSR: 当前 vstart 值
  val vxrm         = Output(UInt(2.W))                           // RVV→CSR: 定点舍入模式
  val vxsat        = Output(Bool())                               // RVV→CSR: 定点饱和标志
  val frm          = Input(UInt(3.W))                            // CSR→RVV: 浮点舍入模式 (fcsr.frm)
  val vstart_write = Input(Valid(UInt(log2Ceil(p.rvvVlen).W)))  // CSR→RVV: 写 vstart
  val vxrm_write   = Input(Valid(UInt(2.W)))                    // CSR→RVV: 写 vxrm
  val vxsat_write  = Input(Valid(Bool()))                        // CSR→RVV: 写 vxsat
}
