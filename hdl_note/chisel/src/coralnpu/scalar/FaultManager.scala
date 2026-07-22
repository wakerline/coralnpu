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
// FaultManager.scala — 故障管理器
// 收集各流水线阶段异常(译码/执行/LSU/RVV) → 优先级仲裁 → mepc/mtval/mcause
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._

/** FaultManager — 收集各流水线阶段异常, 按 RISC-V 优先级仲裁, 输出 mepc/mtval/mcause */
class FaultManager(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val in = new Bundle {
      val fault = Input(Vec(p.instructionLanes, new Bundle {     // 每 lane 的异常标志
        val csr   = Bool()                                       // CSR 指令异常
        val jal   = Bool()                                       // JAL 跳转异常
        val jalr = Bool()                                        // JALR 目标异常
        val bxx = Bool()                                         // 条件分支目标异常
        val undef = Bool()                                       // 未定义指令异常
        val rvv = if (p.enableRvv) Some(Bool()) else None        // RVV dispatch 阶段异常
      }))
      val pc = Input(Vec(p.instructionLanes, new Bundle {
        val pc = UInt(32.W)                                      // 每 lane 指令 PC, 作为 decode fault 的 mepc
      }))
      val memory_fault = Input(Valid(new FaultInfo(p)))          // LSU load/store fault
      val rvv_fault = Option.when(p.enableRvv)(Input(
          Valid(new FaultManagerOutput)))                        // RVV 执行/后端直接给出的 trap 信息
      val undef = Input(Vec(p.instructionLanes, new Bundle {
        val inst = UInt(32.W)                                    // 未定义指令原始编码, 写 mtval
      }))
      val jal = Input(Vec(p.instructionLanes, new Bundle {
        val target = UInt(32.W)                                  // JAL 异常目标, 写 mtval
      }))
      val jalr = Input(Vec(p.instructionLanes, new Bundle {
        val target = UInt(32.W)                                  // JALR 异常目标, 写 mtval
      }))
      val fetchFault = Input(Valid(UInt(32.W)))                  // 取指访问 fault PC
    }
    val out = Output(Valid(new FaultManagerOutput))              // 仲裁后的 trap 输出给 BRU/CSR
  })

  // ---- lane 内 decode/dispatch fault 汇总 ----
  // faults(x)=lane x 是否有任意前端/dispatch 异常; PriorityEncoder 选择最早 lane。
  val faults = VecInit((0 until p.instructionLanes).map(x => (
      io.in.fault(x).csr |
      io.in.fault(x).jal |
      io.in.fault(x).jalr |
      io.in.fault(x).bxx |
      io.in.fault(x).undef |
      io.in.fault(x).rvv.getOrElse(false.B))))
  val fault = faults.reduce(_|_)                                  // 任意 lane 有 decode/dispatch fault
  val first_fault = PriorityEncoder(faults)                       // 最早 fault lane
  val undef_fault = io.in.fault.map(_.undef).reduce(_|_)          // 任意 lane undef
  val undef_fault_idx = PriorityEncoder(io.in.fault.map(_.undef)) // 最早 undef lane
  val csr_fault = io.in.fault.map(_.csr).reduce(_|_)              // 任意 lane CSR fault
  val csr_fault_idx = PriorityEncoder(io.in.fault.map(_.csr))
  val jal_fault = io.in.fault.map(_.jal).reduce(_|_)              // 任意 lane JAL fault
  val jal_fault_idx = PriorityEncoder(io.in.fault.map(_.jal))
  val jalr_fault = io.in.fault.map(_.jalr).reduce(_|_)            // 任意 lane JALR fault
  val jalr_fault_idx = PriorityEncoder(io.in.fault.map(_.jalr))
  val bxx_fault = io.in.fault.map(_.bxx).reduce(_|_)              // 任意 lane branch fault
  val bxx_fault_idx = PriorityEncoder(io.in.fault.map(_.bxx))
  val rvv_dispatch_fault = io.in.fault.map(_.rvv.getOrElse(false.B)).reduce(_|_) // RVV dispatch fault
  val rvv_dispatch_fault_idx = PriorityEncoder(io.in.fault.map(_.rvv.getOrElse(false.B)))
  val instr_access_fault = io.in.fetchFault.valid                 // 取指访问 fault
  val load_fault = io.in.memory_fault.valid && !io.in.memory_fault.bits.write // load fault
  val store_fault = io.in.memory_fault.valid && io.in.memory_fault.bits.write // store fault
  val rvv_fault = io.in.rvv_fault.map(_.valid).getOrElse(false.B) // RVV 后端 trap

  // ---- trap 有效与 mepc 选择 ----
  // 优先级与下面 MuxCase 顺序一致: memory/RVV 后端优先, 再 decode fault, 最后 fetch fault。
  io.out.valid := fault || instr_access_fault || load_fault || store_fault || rvv_fault
  io.out.bits.mepc := MuxCase(0.U(32.W), Seq(
    load_fault -> io.in.memory_fault.bits.epc,                    // load fault PC
    store_fault -> io.in.memory_fault.bits.epc,                   // store fault PC
    rvv_fault -> io.in.rvv_fault.map(_.bits.mepc).getOrElse(0.U), // RVV 提供 mepc
    fault -> io.in.pc(first_fault).pc,                            // decode fault 用最早 lane PC
    instr_access_fault -> io.in.fetchFault.bits,                  // fetch fault PC
  ))

  // first_fault_is_* 把“最早 fault lane”再分类, 确保同拍多 lane fault 时只上报最早指令。
  val first_fault_is_csr          = (csr_fault && (csr_fault_idx === first_fault))
  val first_fault_is_jal          = (jal_fault && (jal_fault_idx === first_fault))
  val first_fault_is_jalr         = (jalr_fault && (jalr_fault_idx === first_fault))
  val first_fault_is_bxx          = (bxx_fault && (bxx_fault_idx === first_fault))
  val first_fault_is_undef        = (undef_fault && (undef_fault_idx === first_fault))
  val first_fault_is_rvv_dispatch = (rvv_dispatch_fault && (rvv_dispatch_fault_idx === first_fault))
  // ---- mcause 选择 ----
  // 0=instruction address misaligned, 1=instruction access fault,
  // 2=illegal instruction, 5=load access fault, 7=store/AMO access fault。
  io.out.bits.mcause := MuxCase(0.U(32.W), Seq(
    load_fault -> 5.U(32.W),                                      // load access fault
    store_fault -> 7.U(32.W),                                     // store access fault
    rvv_fault -> io.in.rvv_fault.map(_.bits.mcause).getOrElse(2.U(32.W)), // RVV 自带 cause
    first_fault_is_csr -> 2.U(32.W),                              // illegal instruction
    first_fault_is_jal -> 0.U(32.W),                              // instruction address misaligned
    first_fault_is_jalr -> 0.U(32.W),
    first_fault_is_bxx -> 0.U(32.W),
    first_fault_is_undef -> 2.U(32.W),                            // illegal instruction
    first_fault_is_rvv_dispatch -> 2.U(32.W),                     // illegal instruction
    instr_access_fault -> 1.U(32.W),                              // instruction access fault
  ))
  // ---- mtval 选择 ----
  // 访存 fault 写 fault 地址; 未定义/RVV dispatch fault 写原指令; JAL/JALR misalign 写目标地址。
  io.out.bits.mtval := MuxCase(0.U(32.W), Seq(
    load_fault -> io.in.memory_fault.bits.addr,                  // load fault 地址
    store_fault -> io.in.memory_fault.bits.addr,                 // store fault 地址
    rvv_fault -> io.in.rvv_fault.map(_.bits.mtval).getOrElse(0.U),
    first_fault_is_csr -> 0.U,                                   // CSR illegal 不提供额外 mtval
    first_fault_is_jal -> io.in.jal(jal_fault_idx).target,       // misaligned JAL target
    first_fault_is_jalr -> (io.in.jalr(jalr_fault_idx).target & "xFFFFFFFE".U), // JALR target bit0 清零后上报
    first_fault_is_bxx -> 0.U(32.W),
    first_fault_is_undef -> io.in.undef(undef_fault_idx).inst,   // illegal instruction encoding
    first_fault_is_rvv_dispatch -> io.in.undef(rvv_dispatch_fault_idx).inst,
    instr_access_fault -> 0.U(32.W),
  ))
  // decode=true 表示异常来自 decode/dispatch 阶段, BRU/CSR 可据此区分同步 trap 来源。
  io.out.bits.decode := MuxCase(false.B, Seq(
    first_fault_is_csr -> true.B,
    first_fault_is_jal -> true.B,
    first_fault_is_jalr -> true.B,
    first_fault_is_bxx -> true.B,
    first_fault_is_undef -> true.B,
    first_fault_is_rvv_dispatch -> true.B,
  ))
}
