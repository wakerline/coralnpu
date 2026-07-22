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


// 译码模块: 完成指令译码，并把译码结果送往对应功能单元。
// 若某个功能单元本周期已经被另一个译码 lane 占用，这里通过串行化机制
// 暂停当前译码指令，直到下一拍再提交给该功能单元。

// ============================================================================
// Decode.scala — RISC-V 指令译码 + DispatchV2 多 lane 发射
//
// 译码结果: 译码后的控制信号 Bundle
// 发射逻辑: 多 lane 指令发射 — 寄存器依赖检查/结构冒险检测/LSU/MLU/DVU/RVV
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.float.{FloatInstruction, FloatOpcode}
import coralnpu.rvv._

class DecodedInstruction(p: Parameters) extends Bundle {
  // 原始指令编码。
  val inst = UInt(32.W)                                 // 原始 32-bit 指令编码

  // 各种指令格式展开后的立即数。
  val imm12  = UInt(32.W)                               // I-type 符号扩展立即数
  val imm20  = UInt(32.W)                               // U-type 立即数
  val immjal = UInt(32.W)                               // JAL 跳转立即数
  val immbr  = UInt(32.W)                               // branch 分支立即数
  val immcsr = UInt(32.W)                               // CSR uimm/rs1 字段零扩展
  val immst  = UInt(32.W)                               // S-type store 立即数

  // RV32I: 每个 Bool 对应一种已识别的基础整数指令。
  val lui   = Bool() //lui指令行为：将 rd 寄存器的值设置为 imm20 字段的值（即指令的高 20 位），并将低 12 位清零。
  val auipc = Bool() //auipc指令行为：将 rd 寄存器的值设置为当前指令地址加上 imm20 字段的值（即指令的高 20 位），并将低 12 位清零。
  val jal   = Bool() //jal指令行为：将 rd 寄存器的值设置为下一条指令的地址（即当前指令地址加 4），并将程序计数器（PC）设置为当前指令地址加上 immjal 字段的值。
  val jalr  = Bool() //jalr指令行为：将 rd 寄存器的值设置为下一条指令的地址（即当前指令地址加 4），并将程序计数器（PC）设置为 rs1 寄存器的值加上 imm12 字段的值，同时将结果的最低位清零。
  val beq   = Bool() //beq指令行为：如果 rs1 寄存器的值等于 rs2 寄存器的值，则将程序计数器（PC）设置为当前指令地址加上 immbr 字段的值，否则继续执行下一条指令。
  val bne   = Bool() //bne指令行为：如果 rs1 寄存器的值不等于 rs2 寄存器的值，则将程序计数器（PC）设置为当前指令地址加上 immbr 字段的值，否则继续执行下一条指令。
  val blt   = Bool() //blt指令行为：如果 rs1 寄存器的值小于 rs2 寄存器的值，则将程序计数器（PC）设置为当前指令地址加上 immbr 字段的值，否则继续执行下一条指令。
  val bge   = Bool() //bge指令行为：如果 rs1 寄存器的值大于等于 rs2 寄存器的值，则将程序计数器（PC）设置为当前指令地址加上 immbr 字段的值，否则继续执行下一条指令。
  val bltu  = Bool() //bltu指令行为：如果 rs1 寄存器的值小于 rs2 寄存器的值（无符号比较），则将程序计数器（PC）设置为当前指令地址加上 immbr 字段的值，否则继续执行下一条指令。
  val bgeu  = Bool() //bgeu指令行为：如果 rs1 寄存器的值大于等于 rs2 寄存器的值（无符号比较），则将程序计数器（PC）设置为当前指令地址加上 immbr 字段的值，否则继续执行下一条指令。
  val csrrw = Bool() //csrrw指令行为：将 CSR 寄存器的值写入 rs1 寄存器，并将 rs2 寄存器的值写入 CSR 寄存器。
  val csrrs = Bool() //csrrs指令行为：将 CSR 寄存器的值写入 rs1 寄存器，并将 rs2 寄存器的值与 CSR 寄存器的值进行或运算，结果写入 CSR 寄存器。
  val csrrc = Bool() //csrrc指令行为：将 CSR 寄存器的值写入 rs1 寄存器，并将 rs2 寄存器的值与 CSR 寄存器的值进行与运算，结果写入 CSR 寄存器。
  val lb    = Bool() //lb指令行为：从内存中读取一个字节，并将其符号扩展后写入 rd 寄存器。
  val lh    = Bool() //lh指令行为：从内存中读取一个半字，并将其符号扩展后写入 rd 寄存器。
  val lw    = Bool() //lw指令行为：从内存中读取一个字，并将其符号扩展后写入 rd 寄存器。
  val lbu   = Bool() //lbu指令行为：从内存中读取一个字节，并将其零扩展后写入 rd 寄存器。
  val lhu   = Bool() //lhu指令行为：从内存中读取一个半字，并将其零扩展后写入 rd 寄存器。
  val sb    = Bool() //sb指令行为：将 rd 寄存器的值写入内存中的一个字节。
  val sh    = Bool() //sh指令行为：将 rd 寄存器的值写入内存中的一个半字。
  val sw    = Bool() //sw指令行为：将 rd 寄存器的值写入内存中的一个字。
  val fence = Bool() //fence指令行为：确保在该指令之前的所有加载和存储操作都已完成。
  val addi  = Bool() //addi指令行为：将 rs1 寄存器的值与 imm12 字段的值相加，结果写入 rd 寄存器。
  val slti  = Bool() //slti指令行为：如果 rs1 寄存器的值小于 imm12 字段的值，则将 rd 寄存器的值设置为 1，否则设置为 0。
  val sltiu = Bool() //sltiu指令行为：如果 rs1 寄存器的值小于 imm12 字段的值（无符号比较），则将 rd 寄存器的值设置为 1，否则设置为 0。
  val xori  = Bool() //xori指令行为：将 rs1 寄存器的值与 imm12 字段的值进行异或运算，结果写入 rd 寄存器。
  val ori   = Bool() //ori指令行为：将 rs1 寄存器的值与 imm12 字段的值进行或运算，结果写入 rd 寄存器。
  val andi  = Bool() //andi指令行为：将 rs1 寄存器的值与 imm12 字段的值进行与运算，结果写入 rd 寄存器。
  val slli  = Bool() //slli指令行为：将 rs1 寄存器的值左移 imm12 字段的值（无符号），结果写入 rd 寄存器。
  val srli  = Bool() //srli指令行为：将 rs1 寄存器的值右移 imm12 字段的值（无符号），结果写入 rd 寄存器。
  val srai  = Bool() //srai指令行为：将 rs1 寄存器的值右移 imm12 字段的值（有符号），结果写入 rd 寄存器。
  val add   = Bool() //add指令行为：将 rs1 和 rs2 寄存器的值相加，结果写入 rd 寄存器。
  val sub   = Bool() //sub指令行为：将 rs1 和 rs2 寄存器的值相减，结果写入 rd 寄存器。
  val slt   = Bool() //slt指令行为：如果 rs1 寄存器的值小于 rs2 寄存器的值，则将 rd 寄存器的值设置为 1，否则设置为 0。
  val sltu  = Bool() //sltu指令行为：如果 rs1 寄存器的值小于 rs2 寄存器的值（无符号比较），则将 rd 寄存器的值设置为 1，否则设置为 0。
  val xor   = Bool() //xor指令行为：将 rs1 和 rs2 寄存器的值进行异或运算，结果写入 rd 寄存器。
  val or    = Bool() //or指令行为：将 rs1 和 rs2 寄件存储在寄存器中。
  val and   = Bool() //and指令行为：将 rs1 和 rs2 寄存器的值进行与运算，结果写入 rd 寄存器。
  val sll   = Bool() //sll指令行为：将 rs1 寄存器的值左移 rs2 寄存器的值（无符号），结果写入 rd 寄存器。
  val srl   = Bool() //srl指令行为：将 rs1 寄存器的值右移 rs2 寄存器的值（无符号），结果写入 rd 寄存器。
  val sra   = Bool() //sra指令行为：将 rs1 寄存器的值右移 rs2 寄存器的值（有符号），结果写入 rd 寄存器。
 
  // RV32M: 乘除扩展指令。
  val mul     = Bool() //mul指令行为：将 rs1 和 rs2 寄存器的值相乘，结果写入 rd 寄存器。
  val mulh    = Bool() //mulh指令行为：将 rs1 和 rs2 寄存器的值相乘，取高 32 位结果写入 rd 寄存器。
  val mulhsu  = Bool() //mulhsu指令行为：将 rs1 寄存器的值（有符号）与 rs2 寄存器的值（无符号）相乘，取高 32 位结果写入 rd 寄存器。
  val mulhu   = Bool() //mulhu指令行为：将 rs1 和 rs2 寄存器的值相乘，取低 32 位结果写入 rd 寄存器。
  val div     = Bool() //div指令行为：将 rs1 和 rs2 寄存器的值相除，结果写入 rd 寄存器。
  val divu    = Bool() //divu指令行为：将 rs1 和 rs2 寄存器的值相除（无符号），结果写入 rd 寄存器。
  val rem     = Bool() //rem指令行为：将 rs1 和 rs2 寄存器的值取模，结果写入 rd 寄存器。
  val remu    = Bool() //remu指令行为：将 rs1 和 rs2 寄存器的值取模（无符号），结果写入 rd 寄存器。

  // ZBB: 位操作基础扩展指令。
  val andn  = Bool() //andn指令行为：将 rs1 和 rs2 寄存器的值进行与非运算，结果写入 rd 寄存器。
  val orn   = Bool() //orn指令行为：将 rs1 和 rs2 寄存器的值进行或非运算，结果写入 rd 寄存器。
  val xnor  = Bool() //xnor指令行为：将 rs1 和 rs2 寄存器的值进行异或非运算，结果写入 rd 寄存器。
  val clz  = Bool() //clz指令行为：计算 rs1 寄存器的值中前导零的个数，结果写入 rd 寄存器。
  val ctz  = Bool() //ctz指令行为：计算 rs1 寄存器的值中尾随零的个数，结果写入 rd 寄存器。
  val cpop = Bool() //cpop指令行为：计算 rs1 寄存器的值中 1 的个数，结果写入 rd 寄存器。
  val max  = Bool() //max指令行为：比较 rs1 和 rs2 寄存器的值，取较大者写入 rd 寄存器。
  val maxu = Bool() //maxu指令行为：比较 rs1 和 rs2 寄存器的值（无符号），取较大者写入 rd 寄存器。
  val min  = Bool() //min指令行为：比较 rs1 和 rs2 寄存器的值，取较小者写入 rd 寄存器。
  val minu = Bool() //minu指令行为：比较 rs1 和 rs2 寄存器的值（无符号），取较小者写入 rd 寄存器。
  val sextb = Bool() //sextb指令行为：将 rs1 寄件存储在寄存器中。
  val sexth = Bool() //sexth指令行为：将 rs1 寄件存储在寄存器中。
  val rol = Bool() //rol指令行为：将 rs1 寄件存储在寄存器中。
  val ror = Bool() //ror指令行为：将 rs1 寄件存储在寄存器中。
  val orcb = Bool() //orcb指令行为：将 rs1 寄件存储在寄存器中。
  val rev8 = Bool() //rev8指令行为：将 rs1 寄件存储在寄存器中。
  val zexth = Bool() //zexth指令行为：将 rs1 寄件存储在寄存器中。
  val rori = Bool() //rori指令行为：将 rs1 寄件存储在寄存器中。

  // 核心控制: 系统/异常/暂停类控制指令。
  val ebreak = Bool() //ebreak指令行为：触发断点异常。
  val ecall  = Bool() //ecall指令行为：触发环境调用异常。
  val mpause = Bool() //mpause指令行为：暂停处理器执行。
  val mret   = Bool() //mret指令行为：从异常处理程序返回。
  val undef  = Bool() //undef指令行为：未定义指令。
  val wfi    = Bool() //wfi指令行为：等待中断。

  // 屏障: 指令/数据 flush 和 fence 类操作。
  val fencei = Bool() //fencei指令行为：刷新指令缓存。
  val flushat = Bool() //flushat指令行为：刷新地址转换缓存。
  val flushall = Bool() //flushall指令行为：刷新所有缓存。

  val rvv = Option.when(p.enableRvv)(Valid(new RvvCompressedInstruction())) // RVV 压缩后的内部指令

  val float = Option.when(p.enableFloat)(Valid(new FloatInstruction())) // 浮点内部指令

  // ---- 指令分类辅助函数 ----
  // 这些辅助函数供 DispatchV2 做结构冒险、scoreboard 依赖和功能单元选择。
  //alu操作
  def isAluImm(): Bool = {
      addi || slti || sltiu || xori || ori || andi || slli || srli || srai || rori
  }
  def isAluReg(): Bool = {
      add || sub || slt || sltu || xor || or || and || xnor || orn || andn || sll || srl || sra
  }
  def isAlu1Bit(): Bool = { clz || ctz || cpop || sextb || sexth || zexth || orcb || rev8 }
  def isAlu2Bit(): Bool = { min || minu || max || maxu || rol || ror }
  def isAlu(): Bool = { isAluImm() || isAluReg() || isAlu1Bit() || isAlu2Bit() }
  //csr操作
  def isCsr(): Bool = { csrrw || csrrs || csrrc }
  def isCsrImm() = { isCsr() &&  inst(14) }
  def isCsrReg() = { isCsr() && !inst(14) }
  //branch操作
  def isCondBr(): Bool = { beq || bne || blt || bge || bltu || bgeu }
  //Scalar load/store操作
  def isScalarLoad(): Bool = { lb || lh || lw || lbu || lhu }
  def isScalarStore(): Bool = { sb || sh || sw }
  // float操作
  def isFloat(): Bool = { float.map(f => f.valid).getOrElse(false.B) }
  // float load/store操作
  def isFloatLoad(): Bool = {
    float.map(f => f.valid && f.bits.opcode === FloatOpcode.LOADFP).getOrElse(false.B)
  }
  def isFloatStore(): Bool = {
    float.map(f => f.valid && f.bits.opcode === FloatOpcode.STOREFP).getOrElse(false.B)
  }
  // LSU操作
  // LSU 在 CoralNPU 中不仅负责普通访存，也负责部分 flush/fence 类操作。
  def isLsu(): Bool = {
      isScalarLoad() || isScalarStore() || flushat || flushall ||
      isFloatLoad() || isFloatStore() || (if (p.enableRvv) {
        rvv.get.valid && rvv.get.bits.isLoadStore()
      } else {
        false.B
      })
  }
  // MLU操作
  def isMul(): Bool = { mul || mulh || mulhsu || mulhu }
  // DVU操作
  def isDvu(): Bool = { div || divu || rem || remu }
  def isFency(): Bool = { fencei || ebreak || wfi || mpause || flushat || flushall }

  // 必须从 slot0 发射的指令；这些指令发射时同周期不能再发射其他 lane。
  // | 类型                                  | 原因                                |
  // | ------------------------------------- | --------------------------------- |
  // | fence / flush / ebreak / wfi / mpause | 控制全局状态，不能乱序混发                     |
  // | CSR                                   | 精确状态，要求 ROB 为空并从 lane0 发射         |
  // | Float                                 | 当前 FloatCore 只从 lane0 发射          |
  // | RVV 读/写浮点寄存器                    | 与 FRegfile/Float 状态耦合，需要 lane0 处理 |
  def forceSlot0Only(): Bool = {
    // CSR/float/RVV 访问浮点寄存器/特殊 fence 类指令需要 lane0 独占发射。
    isFency() || isCsr() || isFloat() || rvvReadsFloatRs1() || rvvWritesFrd()
  }

  // 判断是否为跳转或上下文切换类指令；其后的 lane 不允许在同周期继续执行。
  def isJump(): Bool = {
    // 控制流改变或上下文切换类指令之后的同拍指令不能继续发射。
    jal || jalr || ebreak || ecall || mpause ||
    mret
  }

  // float 指令是否需要读写定点/浮点寄存器
  def floatWritesRd(): Bool = { float.map(f => f.valid && f.bits.scalar_rd).getOrElse(false.B) }
  def floatReadsScalarRs1(): Bool = { float.map(f => f.valid && f.bits.scalar_rs1).getOrElse(false.B) }
  def floatReadsFloatRs1(): Bool = { float.map(f => f.valid && f.bits.float_rs1).getOrElse(false.B) }
  def floatReadsRs2(): Bool = { float.map(f => f.valid && f.bits.uses_rs2).getOrElse(false.B) }
  def floatReadsRs3(): Bool = { float.map(f => f.valid && f.bits.uses_rs3).getOrElse(false.B) }

  //rvv是否需要读写浮点寄存器
  def rvvReadsFloatRs1(): Bool = {
    rvv.map(x => x.valid && x.bits.readsFloatRs1()).getOrElse(false.B)
  }

  //rvv是否需要读写浮点标量寄存器
  def rvvWritesFrd(): Bool = {
    rvv.map(x => x.valid && x.bits.writesFrd()).getOrElse(false.B)
  }

  //rvv是否需要读写定点标量寄存器
  def rvvWritesRd(): Bool = {
    if (p.enableRvv) {
      rvv.get.valid && rvv.get.bits.writesRd()
    } else {
      false.B
    }
  }

  //决定是否需要向 Regfile 发 rs1/rs2 读请求，同时也用于 RAW 依赖检查。
  def readsRs1(): Bool = {
    // 标量 rs1 读端口需求, 包含 jalr/CSR/MLU/DVU/LSU/float/RVV 等来源。
    isCondBr() || isAluReg() || isAluImm() || isAlu1Bit() || isAlu2Bit() ||
    isCsr() || isMul() || isDvu() || jalr || floatReadsScalarRs1() ||
    (if (p.enableRvv) { rvv.get.valid && rvv.get.bits.readsRs1() } else { false.B })
  }
  def readsRs2(): Bool = {
    // 标量 rs2 读端口需求, store/branch/寄存器型 ALU/乘除/RVV 等会使用。
    isCondBr() || isAluReg() || isAlu2Bit() || isScalarStore() || isCsrReg() ||
    isMul() || isDvu() ||
    (if (p.enableRvv) { rvv.get.valid && rvv.get.bits.readsRs2() } else { false.B })
  }

  // 判断寄存器读端口是否应由立即数/PC 直接注入。
  // | 指令             | 注入端口   | 注入值            |
  // | -------------- | ------ | -------------- |
  // | `auipc`        | rs1Set | PC             |
  // | CSR immediate  | rs1Set | uimm           |
  // | `addi`         | rs2Set | imm12          |
  // | `lui`          | rs2Set | imm20          |
  // | `clz/ctz/cpop` | rs2Set | 默认立即数路径，不用 rs2 |
  def rs1Set(): Bool = { auipc || isCsrImm() }          // rs1 端口直接注入 PC 或 CSR uimm
  def rs2Set(): Bool = { rs1Set() || isAluImm() || isAlu1Bit() || lui } // rs2 端口注入立即数
}

//DispatchV2 继承它
class Dispatch(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // 核心控制状态。这些会影响 fence、mpause、single-step 等。
    val halted = Input(Bool())                            // 核心暂停时禁止发射
    val mactive = Input(Bool())  // 存储系统仍有活动请求
    val lsuActive = Input(Bool()) // LSU 仍有活动请求

    //Regfile scoreboard 状态: 用于 RAW 依赖检查
    val scoreboard = new Bundle {
      val regd = Input(UInt(32.W))                        // Regfile 寄存器版标量忙位掩码
      val comb = Input(UInt(32.W))                        // 当拍写回旁路后的标量忙位掩码
    }
    //FRegfile scoreboard 状态: 用于 RAW 依赖检查
    val fscoreboard = Option.when(p.enableFloat)(Input(UInt(32.W))) // 浮点寄存器忙位掩码

    // 分支状态。
    val branchTaken = Input(Bool())                       // 任意 BRU 已实际跳转, 用于抑制未对齐异常

    // fault 上报状态。
    val csrFault = Output(Vec(p.instructionLanes, Bool())) // 非法 CSR 地址异常
    val jalFault = Output(Vec(p.instructionLanes, Bool())) // JAL 目标未对齐异常
    val jalrFault = Output(Vec(p.instructionLanes, Bool())) // JALR 目标未对齐异常
    val bxxFault = Output(Vec(p.instructionLanes, Bool())) // branch 目标未对齐异常
    val undefFault = Output(Vec(p.instructionLanes, Bool())) // 未定义指令异常
    val rvvFault = Option.when(p.enableRvv)(
        Output(Vec(p.instructionLanes, Bool())))// RVV 指令异常
    val bruTarget = Output(Vec(p.instructionLanes, UInt(32.W))) // 分支/JAL 目标, 给 ROB/FaultManager
    val jalrTarget = Input(Vec(p.instructionLanes, new RegfileBranchTargetIO)) // Regfile 计算出的 JALR 目标

    val interlock = Input(Bool())                       // 外部互锁: BRU 系统指令/flush 等

    // Decode 输入接口。
    val inst = Vec(p.instructionLanes, Flipped(Decoupled(new FetchInstruction(p)))) // Fetch 输出的多 lane 指令

    // Decode 周期访问寄存器堆的接口。
    // | 接口                | 作用                           |
    // | ----------------- | ---------------------------- |
    // | `rs1Read/rs2Read` | 请求下一拍读 rs1/rs2               |
    // | `rs1Set/rs2Set`   | 立即数/PC 直接注入读端口               |
    // | `rdMark`          | 发射时把 rd 标记 busy              |
    // | `busRead`         | 给 LSU/JALR 计算 `rs1 + imm` 地址 |
    val rs1Read = Vec(p.instructionLanes, Flipped(new RegfileReadAddrIO)) // 标量 rs1 读地址
    val rs1Set  = Vec(p.instructionLanes, Flipped(new RegfileReadSetIO))  // rs1 端口立即数/PC 注入
    val rs2Read = Vec(p.instructionLanes, Flipped(new RegfileReadAddrIO)) // 标量 rs2 读地址
    val rs2Set  = Vec(p.instructionLanes, Flipped(new RegfileReadSetIO))  // rs2 端口立即数注入
    val rdMark  = Vec(p.instructionLanes, Flipped(new RegfileWriteAddrIO)) // 标量 rd scoreboard 置位
    val busRead = Vec(p.instructionLanes, Flipped(new RegfileBusAddrIO))   // LSU/BRU 地址计算请求
    // RVV/Float 相关寄存器接口。
    val rdMark_flt = Option.when(p.enableFloat)(Flipped(new RegfileWriteAddrIO)) // 浮点 rd scoreboard 置位
    val rvvRdMark = Option.when(p.enableRvv)(Vec(p.instructionLanes, Flipped(new RegfileWriteAddrIO))) // RVV vd 置位
    val frs1Read = Option.when(p.enableFloat)(Vec(p.instructionLanes, Flipped(new RegfileReadAddrIO))) // RVV 读 frs1

    // | 单元  | 接口类型        | 含义           |
    // | --- | ----------- | ------------ |
    // | ALU | `Valid`     | 默认无 ready 反压 |
    // | BRU | `Valid`     | 默认无 ready 反压 |
    // | CSR | `Valid`     | lane0 发射     |
    // | LSU | `Decoupled` | 有队列反压        |
    // | MLU | `Decoupled` | 共享乘法器，有反压    |
    // | DVU | `Decoupled` | 多周期除法器，有反压   |
    // ALU 接口。
    val alu = Vec(p.instructionLanes, Valid(new AluCmd)) // 每 lane ALU 请求

    // 分支接口。
    val bru = Vec(p.instructionLanes, Valid(new BruCmd(p))) // 每 lane BRU 请求

    // CSR 接口。
    val csr = Valid(new CsrCmd)                         // CSR 只从 lane0 发射

    // LSU 接口。
    val lsu = Vec(p.instructionLanes, Decoupled(new LsuCmd(p))) // LSU 请求队列入口
    val lsuQueueCapacity = Input(UInt(3.W))             // LSU 队列剩余容量

    // 乘法器接口。
    val mlu = Vec(p.instructionLanes, Decoupled(new MluCmd)) // MLU 请求

    // 除法器接口。
    val dvu = Vec(p.instructionLanes, Decoupled(new DvuCmd)) // DVU 请求

    // RVV 接口。
    val rvv = Option.when(p.enableRvv)(
        Vec(p.instructionLanes, Decoupled(new RvvCompressedInstruction)))
    val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p)))) // 当前 RVV vtype/vl/vstart
    val rvvIdle = Option.when(p.enableRvv)(Input(Bool())) // RVV 是否空闲
    val rvvQueueCapacity = Option.when(p.enableRvv)(Input(UInt(4.W))) // RVV 队列剩余容量

    // 浮点接口。
    val float = Option.when(p.enableFloat)(Decoupled(new FloatInstruction)) // FloatCore 请求
    val csrFrm = Option.when(p.enableFloat)(Input(UInt(3.W))) // CSR.frm, 用于浮点 rm 合法性检查

    val fbusPortAddr = Option.when(p.enableFloat)(Output(UInt(5.W))) // 浮点 store 读取 FRegfile 地址

    val retirement_buffer_nSpace = Input(UInt(5.W))     // ROB 剩余槽位
    val retirement_buffer_empty = Input(Bool())         // ROB 是否为空
    val retirement_buffer_trap_pending = Input(Bool())  // ROB 内是否有待提交 trap
    val single_step = Input(Bool())                     // 调试单步模式
    val debug_mode = Input(Bool())                      // 当前调试模式
    val branch = Output(Vec(p.instructionLanes, Bool())) // 给 ROB 标记条件分支
    val jump = Output(Vec(p.instructionLanes, Bool()))   // 给 ROB 标记跳转类指令
  })
}

class DispatchV2(p: Parameters) extends Dispatch(p) {
  // ---- 指令译码 ----
  // 每个 fetch lane 独立译码, 之后统一做跨 lane 依赖/资源检查。
  // 每个 lane 生成一个 DecodedInstruction。
  val decodedInsts = (0 until p.instructionLanes).map(i =>
    DecodeInstruction(p, i, io.inst(i).bits.addr, io.inst(i).bits.inst,
                      io.csrFrm.getOrElse(0.U))
  )

  // ---------------------------------------------------------------------------
  // 跳转处理。
  //如果 lane0 是 jal，那么 lane1/2/3 不允许同拍继续发射。原因是跳转之后的顺序 lane 可能已经属于错误路径。
  // 判断指令流中是否已经出现跳转，这也包含会触发上下文切换的指令。
  // fence 类指令同样按跳转屏障处理，阻止后续 lane 同拍发射。
  val isJump = decodedInsts.map(x => x.isJump() || x.isFency())
  // 目前 io.jump 只被 ROB 使用。
  // 这里希望只标记普通控制流指令，例如不包含 mret/ecall，
  // 也不包含 fence 这类兼具其他语义的指令。
  io.jump := decodedInsts.map(x => x.isJump() && !x.ecall && !x.mret) // ROB 只记录普通跳转,剔除ecall和mret
  val jumped = isJump.scan(false.B)(_ || _)             // lane i 之前是否已有跳转/特殊 fence

  // ---------------------------------------------------------------------------
  // 分支处理。一旦前面有条件分支，后续 lane 就不能发射。
  val isBranch = decodedInsts.map(_.isCondBr())         // 条件分支
  io.branch := isBranch
  val branched = isBranch.scan(false.B)(_ || _)         // lane i 之前是否已有分支
  val branchInterlock = (0 until p.instructionLanes).map(i => branched(i)) // 分支之后的 lane 停发

  // ---------------------------------------------------------------------------
  // 标量 scoreboard。
  val rdAddr = io.inst.map(_.bits.inst(11,7))            // rd 字段
  //writesRd 表示这条指令是否会写标量 rd。
  //这里写得比较宽：只要不是 store、不是条件分支，大多数指令都会被视为可能写 rd。
  //对 fence、一些系统指令来说，即使 writesRd 为 true，通常 rd 字段是 x0，
  //最后 scoreboard 会忽略 x0，因此功能上仍可接受。
  val writesRd = decodedInsts.map(d =>
      (!d.isScalarStore() && !d.isCondBr()) ||
      (d.isFloat() && d.floatWritesRd()) ||
      d.rvvWritesRd()
  )                                                      // 该指令是否会写标量 rd

  // 如果本 lane 会写 rd，就生成 one-hot mask。
  // scoreboard 依赖检查的核心是计算每个 lane 的 rd 写集合，以及前序 lane 的 rd 写集合。
  val rdScoreboard = (0 until p.instructionLanes).map(i =>
      Mux(writesRd(i), UIntToOH(rdAddr(i), 32), 0.U(32.W))) // 本 lane 将要置位的 rd mask
  val scoreboardScan = rdScoreboard.scan(0.U(32.W))(_ | _) // 之前 lane 的 rd 写集合

  // regd 直接来自寄存器保存的 scoreboard，可在同周期通过寄存器堆 busPort 访问。
  // comb 还包含当拍写回旁路后的结果。
  val regd =  scoreboardScan.map(_ | io.scoreboard.regd) // 寄存器版 scoreboard + 前序 lane 写
  val comb =  scoreboardScan.map(_ | io.scoreboard.comb) // 组合版 scoreboard + 前序 lane 写

  val rs1Addr = io.inst.map(_.bits.inst(19,15))          // rs1 字段
  val rs2Addr = io.inst.map(_.bits.inst(24,20))          // rs2 字段
  //JALR 和 LSU 地址计算/store 数据依赖 Regfile 内部 bus 路径，这些使用 regd scoreboard。
  //原因是这些路径可能不像普通 ALU readData 那样有完整的组合旁路，所以更保守。
  val usesRs1Regd = decodedInsts.map(d => d.jalr || d.isLsu()) // 地址计算依赖 regd 路径
  val usesRs2Regd = decodedInsts.map(d => d.isScalarStore())   // store 数据依赖 regd 路径
  //
  val readScoreboardRegd = (0 until p.instructionLanes).map(i =>
      MuxOR(usesRs1Regd(i), UIntToOH(rs1Addr(i), 32)) | // 需要通过 regd 路径检查的 rs1 位掩码
      MuxOR(usesRs2Regd(i), UIntToOH(rs2Addr(i), 32)))  // 需要通过 regd 路径检查的 rs2 位掩码

  //普通执行单元读取 rs1/rs2，可以使用 comb，因为 Regfile read path 可能考虑当拍写回清除。
  val usesRs1Comb = decodedInsts.map(d => d.readsRs1()) // 普通执行单元 rs1 依赖组合旁路路径
  val usesRs2Comb = decodedInsts.map(d => d.readsRs2()) // 普通执行单元 rs2 依赖组合旁路路径
  val readScoreboardComb = (0 until p.instructionLanes).map(i =>
      MuxOR(usesRs1Comb(i), UIntToOH(rs1Addr(i), 32)) |
      MuxOR(usesRs2Comb(i), UIntToOH(rs2Addr(i), 32)))// 需要通过 comb 路径检查的 rs1/rs2 位掩码

  val readAfterWrite = (0 until p.instructionLanes).map(i =>
      (readScoreboardRegd(i) & regd(i)) =/= 0.U(32.W) ||
      (readScoreboardComb(i) & comb(i)) =/= 0.U(32.W))  // RAW 冒险
  val writeAfterWrite = (0 until p.instructionLanes).map(i =>
      (rdScoreboard(i) & comb(i)) =/= 0.U(32.W))        // WAW 冒险

  // ---------------------------------------------------------------------------
  // 浮点 scoreboard。
  val rs3Addr = io.inst.map(_.bits.inst(31,27))          // 浮点/FMA rs3 字段
  val writesFloatRd = decodedInsts.map(d =>
      (d.isFloat() && !d.floatWritesRd()) ||
      d.rvvWritesFrd()
  )                                                      // 该指令是否会写浮点 rd
  val floatReadScoreboard = if (p.enableFloat) { (0 until p.instructionLanes).map(i =>
    MuxOR(decodedInsts(i).floatReadsFloatRs1() || decodedInsts(i).rvvReadsFloatRs1(), UIntToOH(rs1Addr(i), 32)) |
    MuxOR(decodedInsts(i).floatReadsRs2(), UIntToOH(rs2Addr(i), 32)) |
    MuxOR(decodedInsts(i).floatReadsRs3(), UIntToOH(rs3Addr(i), 32))
  ) } else { (0 until p.instructionLanes).map(_ => 0.U(32.W)) }

  val floatRdScoreboard = if (p.enableFloat) { (0 until p.instructionLanes).map(i =>
    MuxOR(writesFloatRd(i), UIntToOH(rdAddr(i), 32))
  ) } else { (0 until p.instructionLanes).map(_ => 0.U(32.W)) }
  val floatScoreboardScan = floatRdScoreboard.scan(0.U(32.W))(_ | _) // 前序 lane 浮点写集合
  val fcomb = floatScoreboardScan.map(_ | io.fscoreboard.getOrElse(0.U)) // 当前浮点 busy + 前序 lane 写
  val floatReadAfterWrite = (0 until p.instructionLanes).map(i =>
      (floatReadScoreboard(i) & fcomb(i)) =/= 0.U(32.W)) // 浮点 RAW 冒险
  val floatWriteAfterWrite = (0 until p.instructionLanes).map(i =>
      (floatRdScoreboard(i) & fcomb(i)) =/= 0.U(32.W))   // 浮点 WAW 冒险
  // 浮点 store 读取数据寄存器地址。
  if (p.enableFloat) {
    io.fbusPortAddr.get := rs2Addr(0)                   // 浮点 store 的数据寄存器地址
  }

  // ---------------------------------------------------------------------------
  // fence 互锁。等待前面的存储活动完成，再执行全局屏障或暂停类操作。
  val fence = decodedInsts.map(x => x.isFency() && (io.mactive || io.lsuActive)) // 存储系统/LSU 忙时 fence 停发

  // ---------------------------------------------------------------------------
  // slot0 互锁。
  // 如果 lane0 是 slot0-only 指令，后续 lane 不能发。
  // 如果 lane i 自己是 slot0-only 指令，但 i != 0，也不能发。
  // 所以 CSR、float、特殊 fence、部分 RVV/float 相关指令必须从 lane0 发射。
  val slot0Interlock = (0 until p.instructionLanes).map(i =>
    if (i == 0) {
      true.B
    } else {
      !decodedInsts(0).forceSlot0Only() && !decodedInsts(i).forceSlot0Only()
    }
  )

  // ---------------------------------------------------------------------------
  // RVV config 互锁规则。
  // RVV load/store 单元发射时必须看到有效的 config 状态。
  //如果前面 lane 有 vset 改变 config，后面的 RVV load/store 不能同拍使用旧 config。
  val configInvalid = if (p.enableRvv) {
    val configChange = decodedInsts.map(
        x => x.rvv.get.valid && x.rvv.get.bits.isVset()) // vset 会改变后续 RVV config
    configChange.scan(!io.rvvState.get.valid)(_ || _)    // lane i 看到的 config 是否不可用/刚被改
  } else {
    Seq.fill(p.instructionLanes)(false.B)
  }

  val rvvConfigInterlock = if (p.enableRvv) {
    val canDispatchRvv = (0 until p.instructionLanes).map(i =>
        !decodedInsts(i).rvv.get.valid || // 非 RVV 指令不受此互锁限制
        !decodedInsts(i).rvv.get.bits.isLoadStore() || // 非 LSU 类 RVV 指令可自行处理 config 变化
        !configInvalid(i)  // config 有效时允许发射 RVV load/store
    )
    canDispatchRvv
  } else {
    Seq.fill(p.instructionLanes)(true.B)
  }

  // ---------------------------------------------------------------------------
  // RVV vstart 互锁。
  // 若某条指令要求 vstart == 0，则在 vstart != 0 时禁止其发射。
  val rvvVstartInterlock = if (p.enableRvv) {
    (0 until p.instructionLanes).map(i => {
        val invalidVstart =
            decodedInsts(i).rvv.get.valid &&
            decodedInsts(i).rvv.get.bits.requireZeroVstart() &&
            (configInvalid(i) || (io.rvvState.get.bits.vstart =/= 0.U))
        !invalidVstart
    })
  } else {
    Seq.fill(p.instructionLanes)(true.B)
  }

  // ---------------------------------------------------------------------------
  // RVV 队列容量互锁。
  val rvvInterlock = if (p.enableRvv) {
    val isRvv = decodedInsts.map(x => x.rvv.get.valid)  // 本周期各 lane 是否为 RVV
    val isRvvCount = isRvv.scan(0.U(4.W))(_+_)           // lane i 之前 RVV 发射数量
    (0 until p.instructionLanes).map(
        i => isRvvCount(i) < io.rvvQueueCapacity.get)//统计当前周期前面 lane 已经发了多少 RVV 指令，确保不超过 RVV 队列容量。
  } else {
    Seq.fill(p.instructionLanes)(true.B)
  }

  // ---------------------------------------------------------------------------
  // LSU 队列容量互锁。
  val isLsu = decodedInsts.map(x => x.isLsu())
  val isLsuCount = isLsu.scan(0.U(4.W))(_+_)             // lane i 之前 LSU 发射数量
  val lsuInterlock =
      (0 until p.instructionLanes).map(
          i => isLsuCount(i) < io.lsuQueueCapacity)

  // ---------------------------------------------------------------------------
  // 未定义指令互锁。
  // 确保 undef 只在第一个 slot 中处理。非 lane0 的 undef 不允许直接发射处理。
  val undefInterlock = (0 until p.instructionLanes).map(i =>
    if (i == 0) { false.B } else { decodedInsts(i).undef }) // 未定义指令只允许 lane0 报 fault
  io.undefFault := (0 until p.instructionLanes).map(i =>
    if (i == 0) { io.inst(i).valid && decodedInsts(i).undef } else { false.B })

  // ---------------------------------------------------------------------------
  // 核心空闲判断。
  // 通过检查寄存器堆 scoreboard 是否清空，以及 LSU 是否仍有活动请求，
  // 判断核心是否已经进入可执行单步/暂停类指令的空闲状态。
  // 标量 scoreboard 清空
  // 浮点 scoreboard 清空
  // RVV 空闲
  // LSU 不 active
  val coreIdle =
        (
          (io.scoreboard.regd === 0.U) &&
          (io.fscoreboard.getOrElse(0.U) === 0.U) &&
          io.rvvIdle.getOrElse(true.B) &&
          !io.lsuActive
        )

  // ---------------------------------------------------------------------------
  // 单步调试互锁。
  val singleStepInterlock = (0 until p.instructionLanes).map(i =>
    !io.single_step || ((i == 0).B && coreIdle))         // 单步时只在核心空闲后发 lane0

  // ---------------------------------------------------------------------------
  // MPAUSE 互锁。
  val mpauseInterlock = (0 until p.instructionLanes).map(i =>
    !decodedInsts(i).mpause || ((i == 0).B && coreIdle)) // MPAUSE 等核心空闲且只从 lane0 发射

  // ---------------------------------------------------------------------------
  // 合并上述规则。
  // canDispatch 表示在考虑顺序发射和下游反压之前，本 lane 是否具备发射资格。
  // | 类别      | 条件                      |
  // | -------- | ----------------------- |
  // | 核心状态  | 未 halted、无外部 interlock  |
  // | Fetch    | `inst.valid=1`          |
  // | 控制流    | 前面没有 jump/branch        |
  // | 依赖      | 无标量 RAW/WAW、无浮点 RAW/WAW |
  // | 特殊指令  | slot0-only 规则满足         |
  // | fence    | 存储系统空闲                  |
  // | RVV      | config/vstart/queue 满足  |
  // | LSU      | 队列有空间                   |
  // | ROB      | 有空间、无 pending trap      |
  // | CSR      | ROB 必须为空                |
  // | Debug    | single-step 规则满足        |
  // | mpause   | coreIdle 且 lane0        |
  val canDispatch = (0 until p.instructionLanes).map(i =>
      !io.halted &&          // 核心 halted 时不发射
      !io.interlock &&       // 外部互锁有效时不发射
      io.inst(i).valid &&    // 指令必须有效才可发射
      !jumped(i) &&          // 跳转之后的 lane 不发射
      !readAfterWrite(i) &&  // 避免标量 RAW 冒险
      !writeAfterWrite(i) && // 避免标量 WAW 冒险
      !floatReadAfterWrite(i) &&  // 避免浮点 RAW 冒险
      !floatWriteAfterWrite(i) && // 避免浮点 WAW 冒险
      !branchInterlock(i) && // 分支之后不发射
      !fence(i) &&           // fence 互锁时不发射
      slot0Interlock(i) &&   // 特殊指令只能从 slot0 发射
      rvvConfigInterlock(i) &&     // RVV config 互锁规则
      rvvVstartInterlock(i) && // 禁止非法的 vstart != 0 发射
      // rvvLsuInterlock(i) &&  // 每拍只发射一个 RVV LsuOp
      lsuInterlock(i) && // 确保 LSU 指令能进入队列
      rvvInterlock(i) && // 确保 RVV 指令能进入队列
      !undefInterlock(i) &&     // 确保 undef 只从第一个 slot 处理
      (i.U < io.retirement_buffer_nSpace) && // ROB 必须有可用槽位
      !io.retirement_buffer_trap_pending && // ROB 有待处理 trap 时暂停发射
      (!decodedInsts(i).isCsr() || io.retirement_buffer_empty) && // CSR 必须等待 ROB 清空
      singleStepInterlock(i) &&  // 单步调试互锁
      mpauseInterlock(i)  // mpause 互锁
  )

  // ---------------------------------------------------------------------------
  // 尝试发射循环。
  // 执行单元的 ready 反压在这里作用到每个 lane。
  // 每个 lane 只有当前一个 lane 已经成功发射后，才允许尝试发射：
  // lane0 没成功发射 → lane1/2/3 不许越过
  // lane1 没成功发射 → lane2/3 不许越过
  // 所以 DispatchV2 是 多 lane 顺序发射，不是乱序挑选 ready 的 lane。
  val lastReady = Wire(Vec(p.instructionLanes + 1, Bool()))
  lastReady(0) := true.B // TODO(derekjchow): 是否应改为 halted 相关条件？
  for (i <- 0 until p.instructionLanes) {
    val tryDispatch = lastReady(i) && canDispatch(i)     // 前一 lane 已发射成功且本 lane 通过互锁检查
    val d = decodedInsts(i)                              // 本 lane 译码结果

    // -------------------------------------------------------------------------
    // ALU。
    // 将 RV32I/Zbb 的 ALU 类指令映射成 AluOp。
    val alu = SafeMuxUpTo1H(MakeValid(false.B, AluOp.ADD), Seq(
        // RV32IM 操作映射。
        (d.auipc || d.addi || d.add) -> MakeValid(true.B, AluOp.ADD),
        d.sub                        -> MakeValid(true.B, AluOp.SUB),
        (d.slti || d.slt)            -> MakeValid(true.B, AluOp.SLT),
        (d.sltiu || d.sltu)          -> MakeValid(true.B, AluOp.SLTU),
        (d.xori || d.xor)            -> MakeValid(true.B, AluOp.XOR),
        (d.ori || d.or)              -> MakeValid(true.B, AluOp.OR),
        (d.andi || d.and)            -> MakeValid(true.B, AluOp.AND),
        (d.slli || d.sll)            -> MakeValid(true.B, AluOp.SLL),
        (d.srli || d.srl)            -> MakeValid(true.B, AluOp.SRL),
        (d.srai || d.sra)            -> MakeValid(true.B, AluOp.SRA),
        d.lui                        -> MakeValid(true.B, AluOp.LUI),
        // ZBB 操作映射。
        d.andn                       -> MakeValid(true.B, AluOp.ANDN),
        d.orn                        -> MakeValid(true.B, AluOp.ORN),
        d.xnor                       -> MakeValid(true.B, AluOp.XNOR),
        d.clz                        -> MakeValid(true.B, AluOp.CLZ),
        d.ctz                        -> MakeValid(true.B, AluOp.CTZ),
        d.cpop                       -> MakeValid(true.B, AluOp.CPOP),
        d.max                        -> MakeValid(true.B, AluOp.MAX),
        d.maxu                       -> MakeValid(true.B, AluOp.MAXU),
        d.min                        -> MakeValid(true.B, AluOp.MIN),
        d.minu                       -> MakeValid(true.B, AluOp.MINU),
        d.sextb                      -> MakeValid(true.B, AluOp.SEXTB),
        d.sexth                      -> MakeValid(true.B, AluOp.SEXTH),
        d.rol                        -> MakeValid(true.B, AluOp.ROL),
        d.ror                        -> MakeValid(true.B, AluOp.ROR),
        d.orcb                       -> MakeValid(true.B, AluOp.ORCB),
        d.rev8                       -> MakeValid(true.B, AluOp.REV8),
        d.zexth                      -> MakeValid(true.B, AluOp.ZEXTH),
        d.rori                       -> MakeValid(true.B, AluOp.ROR),
    ), AluOp)
    io.alu(i).valid := tryDispatch && alu.valid          // ALU 请求有效
    io.alu(i).bits.addr := rdAddr(i)                     // ALU 写回 rd
    io.alu(i).bits.op := alu.bits                        // ALU 操作码

    // -------------------------------------------------------------------------
    // BRU。
    // 跳转/分支/系统控制类指令映射成 BruOp。
    val bru = SafeMuxUpTo1H(MakeValid(false.B, BruOp.JAL), Seq(
        d.jal    -> MakeValid(true.B, BruOp.JAL),
        d.jalr   -> MakeValid(true.B, BruOp.JALR),
        d.beq    -> MakeValid(true.B, BruOp.BEQ),
        d.bne    -> MakeValid(true.B, BruOp.BNE),
        d.blt    -> MakeValid(true.B, BruOp.BLT),
        d.bge    -> MakeValid(true.B, BruOp.BGE),
        d.bltu   -> MakeValid(true.B, BruOp.BLTU),
        d.bgeu   -> MakeValid(true.B, BruOp.BGEU),
        d.ebreak -> MakeValid(true.B, BruOp.EBREAK),
        d.ecall  -> MakeValid(true.B, BruOp.ECALL),
        d.mpause -> MakeValid(true.B, BruOp.MPAUSE),
        d.mret   -> MakeValid(true.B, BruOp.MRET),
        d.wfi    -> MakeValid(true.B, BruOp.WFI),
    ), BruOp)
    val bru_target = io.inst(i).bits.addr + Mux(
        io.inst(i).bits.inst(2), d.immjal, d.immbr)      // JAL 用 immjal, branch 用 immbr
    io.bru(i).bits.fwd := io.inst(i).bits.brchFwd        // Fetch 是否已按预测方向前推
    io.bru(i).bits.op := bru.bits                        // BRU 操作码
    io.bru(i).bits.pc := io.inst(i).bits.addr            // 当前 PC
    io.bru(i).bits.target := bru_target                  // 目标 PC
    io.bru(i).bits.link := rdAddr(i)                     // JAL/JALR link rd
    io.bru(i).bits.inst := io.inst(i).bits.inst          // 原始指令, trap/debug 用

    // 目标地址未对齐异常；若已有 branchTaken 刷新当前路径，则不再上报旧路径异常。
    // | fault       | 条件                     |
    // | ----------- | ---------------------- |
    // | `jalFault`  | JAL target 低 2 位非 0    |
    // | `jalrFault` | JALR target bit1 非 0   |
    // | `bxxFault`  | branch target 低 2 位非 0 |
    val jalFault = tryDispatch && bru.valid && (bru.bits === BruOp.JAL) && ((bru_target & 0x3.U) =/= 0.U) && !io.branchTaken
    val jalrFault = tryDispatch && bru.valid && (bru.bits === BruOp.JALR) && ((io.jalrTarget(i).data & 0x2.U) =/= 0.U) && !io.branchTaken
    val bxxFault = tryDispatch && bru.valid &&
                  bru.bits.isOneOf(BruOp.BEQ, BruOp.BNE, BruOp.BLT, BruOp.BGE, BruOp.BLTU, BruOp.BGEU) &&
                  ((bru_target & 0x3.U) =/= 0.U) && !io.branchTaken
    io.jalFault(i) := jalFault
    io.jalrFault(i) := jalrFault
    io.bxxFault(i) := bxxFault
    io.bruTarget(i) := io.bru(i).bits.target             // 目标转发给 ROB/FaultManager
    io.bru(i).valid := tryDispatch && bru.valid && !(jalFault || jalrFault || bxxFault)


    // -------------------------------------------------------------------------
    // MLU。
    // RV32M 乘法类指令映射成 MluOp。
    val mlu = SafeMuxUpTo1H(MakeValid(false.B, MluOp.MUL), Seq(
      d.mul     -> MakeValid(true.B, MluOp.MUL),
      d.mulh    -> MakeValid(true.B, MluOp.MULH),
      d.mulhsu  -> MakeValid(true.B, MluOp.MULHSU),
      d.mulhu   -> MakeValid(true.B, MluOp.MULHU),
    ), MluOp)
    io.mlu(i).valid := tryDispatch && mlu.valid          // MLU 请求有效
    io.mlu(i).bits.addr := rdAddr(i)                     // 目的 rd
    io.mlu(i).bits.op := mlu.bits

    // -------------------------------------------------------------------------
    // DVU。
    // RV32M 除法/取余类指令映射成 DvuOp。
    val dvu = SafeMuxUpTo1H(MakeValid(false.B, DvuOp.DIV), Seq(
      d.div  -> MakeValid(true.B, DvuOp.DIV),
      d.divu -> MakeValid(true.B, DvuOp.DIVU),
      d.rem  -> MakeValid(true.B, DvuOp.REM),
      d.remu -> MakeValid(true.B, DvuOp.REMU)
    ), DvuOp)
    io.dvu(i).valid := tryDispatch && dvu.valid          // DVU 请求有效
    io.dvu(i).bits.addr := rdAddr(i)                     // 目的 rd
    io.dvu(i).bits.op := dvu.bits

    // -------------------------------------------------------------------------
    // LSU。
    // 标量 load/store、fence/flush、float load/store、RVV load/store 都统一进入 LSU。
    val lsu = SafeMuxUpTo1H(MakeValid(false.B, LsuOp.LB), Seq(
      d.lb             -> MakeValid(true.B, LsuOp.LB),
      d.lh             -> MakeValid(true.B, LsuOp.LH),
      d.lw             -> MakeValid(true.B, LsuOp.LW),
      d.lbu            -> MakeValid(true.B, LsuOp.LBU),
      d.lhu            -> MakeValid(true.B, LsuOp.LHU),
      d.sb             -> MakeValid(true.B, LsuOp.SB),
      d.sh             -> MakeValid(true.B, LsuOp.SH),
      d.sw             -> MakeValid(true.B, LsuOp.SW),
      d.wfi            -> MakeValid(true.B, LsuOp.FENCEI),
      d.fencei         -> MakeValid(true.B, LsuOp.FENCEI),
      d.flushat        -> MakeValid(true.B, LsuOp.FLUSHAT),
      d.flushall       -> MakeValid(true.B, LsuOp.FLUSHALL),
      (d.isFloatLoad() || d.isFloatStore()) -> MakeValid(true.B, LsuOp.FLOAT)
    ) ++ Option.when(p.enableRvv) {
      val isRvvLoad = d.rvv.get.valid &&
          (d.rvv.get.bits.opcode === RvvCompressedOpcode.RVVLOAD)
      val isRvvStore = d.rvv.get.valid &&
          (d.rvv.get.bits.opcode === RvvCompressedOpcode.RVVSTORE)
      val mop = d.rvv.get.bits.mop
      Seq(
        (isRvvLoad && (mop === RvvAddressingMode.UNIT_STRIDE))        -> MakeValid(true.B, LsuOp.VLOAD_UNIT),
        (isRvvLoad && (mop === RvvAddressingMode.INDEXED_UNORDERED))  -> MakeValid(true.B, LsuOp.VLOAD_UINDEXED),
        (isRvvLoad && (mop === RvvAddressingMode.STRIDED))            -> MakeValid(true.B, LsuOp.VLOAD_STRIDED),
        (isRvvLoad && (mop === RvvAddressingMode.INDEXED_ORDERED))    -> MakeValid(true.B, LsuOp.VLOAD_OINDEXED),
        (isRvvStore && (mop === RvvAddressingMode.UNIT_STRIDE))       -> MakeValid(true.B, LsuOp.VSTORE_UNIT),
        (isRvvStore && (mop === RvvAddressingMode.INDEXED_UNORDERED)) -> MakeValid(true.B, LsuOp.VSTORE_UINDEXED),
        (isRvvStore && (mop === RvvAddressingMode.STRIDED))           -> MakeValid(true.B, LsuOp.VSTORE_STRIDED),
        (isRvvStore && (mop === RvvAddressingMode.INDEXED_ORDERED))   -> MakeValid(true.B, LsuOp.VSTORE_OINDEXED),
      )
    }.getOrElse(Seq()), LsuOp)
    io.lsu(i).valid := tryDispatch && lsu.valid          // LSU 请求有效
    io.lsu(i).bits.store := io.inst(i).bits.inst(5)      // store/load 类型提示
    io.lsu(i).bits.addr := rdAddr(i)                     // load 目的 rd 或 store 相关字段
    io.lsu(i).bits.op := lsu.bits
    io.lsu(i).bits.pc := io.inst(i).bits.addr            // 异常上报 PC
    if (p.enableRvv) {
      io.lsu(i).bits.elemWidth.get := io.inst(i).bits.inst(14,12) // RVV eew/width
      io.lsu(i).bits.nfields.get := io.inst(i).bits.inst(31,29)   // RVV segment 字段数
      io.lsu(i).bits.umop.get := io.inst(i).bits.inst(24,20)      // RVV indexed/全寄存器子操作
    }

    // -------------------------------------------------------------------------
    // CSR。CSR 只在 lane0 发射，且必须等待 ROB 清空以维持精确状态。
    if (i == 0) {
      // CSR 只允许 lane0 发射; CSR 读写需要 ROB 为空以维持精确状态。
      val csr = SafeMuxUpTo1H(MakeValid(false.B, CsrOp.CSRRW), Seq(
        d.csrrw -> MakeValid(true.B, CsrOp.CSRRW),
        d.csrrs -> MakeValid(true.B, CsrOp.CSRRS),
        d.csrrc -> MakeValid(true.B, CsrOp.CSRRC)
      ), CsrOp)
      val csr_bits_index = io.inst(0).bits.inst(31,20)   // CSR 地址
      val (csr_address, csr_address_valid) = CsrAddress.safe(csr_bits_index)
      // 读取 vxsat (0x009) 和 vcsr (0x00F) 时，需要等向量单元空闲。
      // 只有这些 CSR 可能被飞行中的向量指令修改：
      // 饱和算术会设置 vxsat，vcsr 又包含 vxsat 位域。
      val isVxsatOrVcsr = csr_bits_index === 0x009.U || csr_bits_index === 0x00F.U
      val rvvIdleOrNotVxsat = io.rvvIdle.getOrElse(true.B) || !isVxsatOrVcsr
      io.csr.valid := tryDispatch && csr.valid && csr_address_valid && (if (p.enableFloat) { io.float.get.ready } else { true.B }) && rvvIdleOrNotVxsat
      io.csr.bits.addr := rdAddr(i)                      // CSR 旧值写回 rd
      io.csr.bits.index := csr_bits_index                // CSR 地址
      io.csr.bits.rs1 := rs1Addr(i)                      // CSR rs1/uimm 字段
      io.csr.bits.op := csr.bits                         // CSR 操作类型
      io.csrFault(0) := csr.valid && !csr_address_valid && tryDispatch
    } else {
      io.csrFault(i) := false.B
    }

    // -------------------------------------------------------------------------
    // RVV。
    if (p.enableRvv) {
      io.rvv.get(i).valid := tryDispatch && d.rvv.get.valid // RVV 请求有效
      io.rvv.get(i).bits := d.rvv.get.bits              // 压缩后的 RVV 指令
    }

    // -------------------------------------------------------------------------
    // 浮点执行。
    if (p.enableFloat && (i == 0)) {
      // FloatCore 只从 lane0 发射; float load/store 已走 LSU, 不送 FloatCore。
      io.float.get.valid := tryDispatch && d.float.get.valid && !(d.isFloatLoad() || d.isFloatStore())
      io.float.get.bits := d.float.get.bits
    }

    // -------------------------------------------------------------------------
    // WFI。
    // wfi 指令由 BRU 和 LSU 协同处理。

    // -------------------------------------------------------------------------
    // fence。只从 lane0 发射
    val fenceValid = if (i == 0) { tryDispatch && d.fence } else { false.B } // 普通 fence 占位发射

    // 若当前 lane 发射成功，则设置下一 lane 的 lastReady。
    // lastReady 串行保证 lane i 未真正被下游接收时, 后续 lane 不会越过它发射。
    val dispatched = Seq(io.alu(i).fire, io.bru(i).fire, io.mlu(i).fire, io.dvu(i).fire, io.lsu(i).fire) ++
      Option.when(i == 0)(Seq(io.csr.valid, fenceValid)).getOrElse(Seq()) ++
      Option.when(p.enableRvv)(Seq(io.rvv.get(i).fire)).getOrElse(Seq()) ++
      Option.when(p.enableFloat && i == 0)(Seq(io.float.get.fire)).getOrElse(Seq())
    lastReady(i + 1) := dispatched.reduce(_||_)  //代表lane i 是否已经成功发射
  }

  for (i <- 0 until p.instructionLanes) {
    io.inst(i).ready := lastReady(i + 1)                 // Fetch lane 在本 lane 发射成功后才能前进
  }

  // RVV 异常处理。
  if (p.enableRvv) {
    for (i <- 0 until p.instructionLanes) {
      io.rvvFault.get(i) := (if (i == 0) {
        // 若 vstart != 0，则返回 RVV 异常。
        val requireZeroVstart = decodedInsts(i).rvv.get.valid &&
            decodedInsts(0).rvv.get.bits.requireZeroVstart()
        val vStartNotZero = io.rvvState.get.valid &&
            (io.rvvState.get.bits.vstart =/= 0.U)
        io.inst(0).valid && requireZeroVstart && vStartNotZero  // 其他 RVV 异常由执行单元上报，不在 Decode 处理。
      } else {
        false.B
      })
    }
  }

  //产生 Regfile 读地址、立即数注入、scoreboard 标记。
  for (i <- 0 until p.instructionLanes) {
    val d = decodedInsts(i)
    val rs3Addr = io.inst(i).bits.inst(31,27)
    // ---- 寄存器堆读地址/立即数注入请求 ----
    // 发射成功时为下一拍执行单元准备 rs1/rs2，立即数类通过 readSet 注入。
    io.rs1Read(i).valid := io.inst(i).fire && (d.readsRs1() || d.jalr)
    io.rs1Read(i).addr := Mux(io.inst(i).bits.inst(0), rs1Addr(i), rs3Addr(i)) // RVV/特殊编码可从 rs3 字段取源
    io.rs2Read(i).valid := io.inst(i).fire && d.readsRs2()
    io.rs2Read(i).addr := io.inst(i).bits.inst(24,20)

    // 设置立即数注入端口。
    // | 指令            | rs1Set | rs2Set |
    // | ------------- | ------ | ------ |
    // | `auipc`       | PC     | imm20  |
    // | `lui`         | 无      | imm20  |
    // | `addi`        | 无      | imm12  |
    // | CSR immediate | immcsr | 可能相关   |
    io.rs1Set(i).valid := io.inst(i).fire && d.rs1Set()
    io.rs1Set(i).value := Mux(d.isCsr(), d.immcsr, io.inst(i).bits.addr)  // CSR 用 uimm, AUIPC 用 PC
    io.rs2Set(i).valid := io.inst(i).fire && d.rs2Set()
    io.rs2Set(i).value := MuxCase(d.imm12, IndexedSeq((d.auipc || d.lui) -> d.imm20)) // I/U 型立即数

    if (p.enableFloat) {
      io.frs1Read.get(i).valid := io.inst(i).fire && d.rvvReadsFloatRs1() // RVV 读浮点 rs1
      io.frs1Read.get(i).addr  := rs1Addr(i)
    }

    // 标记将要写回的标量寄存器。
    // 发射时先标记 rd 忙，实际写回由各执行单元Regfile稍后清除 scoreboard。
    val rdMark_valid =
        io.alu(i).fire || io.mlu(i).fire || io.dvu(i).fire ||
        io.lsu(i).fire && d.isScalarLoad() ||
        (if (i == 0) { io.csr.valid } else { false.B }) ||
        io.rvv.map(x => x(i).fire && x(i).bits.writesRd()).getOrElse(false.B) ||
        (if (i == 0) { io.float.map(x => x.fire && x.bits.scalar_rd).getOrElse(false.B) } else { false.B }) ||
        (io.bru(i).valid && (io.bru(i).bits.op.isOneOf(BruOp.JAL, BruOp.JALR)) && rdAddr(i) =/= 0.U)

    io.rdMark(i).valid := rdMark_valid
    io.rdMark(i).addr  := rdAddr(i)                     // 标量 rd scoreboard 置位地址

    // 标记将要写回的浮点寄存器。
    if (p.enableFloat && (i == 0)) {
      val rvvWritesFrd = if (p.enableRvv) { io.rvv.get(0).fire && d.rvvWritesFrd() } else { false.B }

      // 复查 slot0 限制是否生效：其他 lane 不应触发浮点写回标记。
      if (p.instructionLanes > 1) {
        val rvvWritesFrdOtherLanes = io.rvv.map(x =>
          (1 until p.instructionLanes).map(j => x(j).fire && x(j).bits.writesFrd())
        ).getOrElse(Seq.fill(p.instructionLanes - 1)(false.B))
        assert(!VecInit(rvvWritesFrdOtherLanes).asUInt.orR)
      }

      val rdMark_flt_valid = (io.float.get.fire && !d.float.get.bits.scalar_rd) ||
                             (io.lsu(0).fire && d.isFloatLoad()) ||
                             rvvWritesFrd
      io.rdMark_flt.get.valid := rdMark_flt_valid       // 浮点 rd scoreboard 置位
      io.rdMark_flt.get.addr := rdAddr(0)
    }

    // 标记将要写回的 RVV 向量寄存器。
    if (p.enableRvv) {
      val rvvRdMark_valid = io.rvv.get(i).fire && d.rvv.get.bits.writesVectorRegister()
      io.rvvRdMark.get(i).valid := rvvRdMark_valid      // RVV vd scoreboard/ROB 置位
      io.rvvRdMark.get(i).addr := d.rvv.get.bits.bits(4,0) // vd
    }

    // 寄存器堆总线地址端口。
    // load/store 的立即数选择由 bit5 区分，RET 由 bit6 区分。
    io.busRead(i).valid := io.lsu(i).valid              // LSU 请求需要 Regfile 计算地址

    // SB,SH,SW   0100011
    val storeSelect = d.inst(6,3) === 4.U && d.inst(1,0) === 3.U // store 指令选择 S-type 立即数
    io.busRead(i).immen := !d.flushat                   // flushat 使用 rs1 原值, 不加立即数
    io.busRead(i).immed := Mux(d.rvv.map(_.valid).getOrElse(false.B),
        0.U,
        Cat(d.imm12(31,5), Mux(storeSelect, d.immst(4,0), d.imm12(4,0))))
  }
}

object DecodeInstruction {
  def apply(p: Parameters, pipeline: Int, addr: UInt, op: UInt,
            csrFrm: UInt): DecodedInstruction = {
    val d = Wire(new DecodedInstruction(p))

    d.inst := op                                        // 保存原始指令

    // ---- 立即数生成 ----
    // 预先生成各格式立即数, Dispatch/ALU/BRU/LSU 后续直接选用。
    d.imm12  := Cat(Fill(20, op(31)), op(31,20))
    d.imm20  := Cat(op(31,12), 0.U(12.W))
    d.immjal := Cat(Fill(12, op(31)), op(19,12), op(20), op(30,21), 0.U(1.W))
    d.immbr  := Cat(Fill(20, op(31)), op(7), op(30,25), op(11,8), 0.U(1.W))
    d.immcsr := op(19,15)
    d.immst  := Cat(Fill(20, op(31)), op(31,25), op(11,7))

    // ---- RV32I opcode 匹配 ----
    // BitPat 直接按 RISC-V 编码匹配基础整数、load/store、branch、CSR。
    d.lui   := op === BitPat("b????????????????????_?????_0110111")
    d.auipc := op === BitPat("b????????????????????_?????_0010111")
    d.jal   := op === BitPat("b????????????????????_?????_1101111")
    d.jalr  := op === BitPat("b????????????_?????_000_?????_1100111")
    d.beq   := op === BitPat("b???????_?????_?????_000_?????_1100011")
    d.bne   := op === BitPat("b???????_?????_?????_001_?????_1100011")
    d.blt   := op === BitPat("b???????_?????_?????_100_?????_1100011")
    d.bge   := op === BitPat("b???????_?????_?????_101_?????_1100011")
    d.bltu  := op === BitPat("b???????_?????_?????_110_?????_1100011")
    d.bgeu  := op === BitPat("b???????_?????_?????_111_?????_1100011")
    d.csrrw := op === BitPat("b????????????_?????_?01_?????_1110011")
    d.csrrs := op === BitPat("b????????????_?????_?10_?????_1110011")
    d.csrrc := op === BitPat("b????????????_?????_?11_?????_1110011")
    d.lb    := op === BitPat("b????????????_?????_000_?????_0000011")
    d.lh    := op === BitPat("b????????????_?????_001_?????_0000011")
    d.lw    := op === BitPat("b????????????_?????_010_?????_0000011")
    d.lbu   := op === BitPat("b????????????_?????_100_?????_0000011")
    d.lhu   := op === BitPat("b????????????_?????_101_?????_0000011")
    d.sb    := op === BitPat("b????????????_?????_000_?????_0100011")
    d.sh    := op === BitPat("b????????????_?????_001_?????_0100011")
    d.sw    := op === BitPat("b????????????_?????_010_?????_0100011")
    d.fence := op === BitPat("b0000_????_????_00000_000_00000_0001111")
    d.addi  := op === BitPat("b????????????_?????_000_?????_0010011")
    d.slti  := op === BitPat("b????????????_?????_010_?????_0010011")
    d.sltiu := op === BitPat("b????????????_?????_011_?????_0010011")
    d.xori  := op === BitPat("b????????????_?????_100_?????_0010011")
    d.ori   := op === BitPat("b????????????_?????_110_?????_0010011")
    d.andi  := op === BitPat("b????????????_?????_111_?????_0010011")
    d.slli  := op === BitPat("b0000000_?????_?????_001_?????_0010011")
    d.srli  := op === BitPat("b0000000_?????_?????_101_?????_0010011")
    d.srai  := op === BitPat("b0100000_?????_?????_101_?????_0010011")
    d.add   := op === BitPat("b0000000_?????_?????_000_?????_0110011")
    d.sub   := op === BitPat("b0100000_?????_?????_000_?????_0110011")
    d.slt   := op === BitPat("b0000000_?????_?????_010_?????_0110011")
    d.sltu  := op === BitPat("b0000000_?????_?????_011_?????_0110011")
    d.xor   := op === BitPat("b0000000_?????_?????_100_?????_0110011")
    d.or    := op === BitPat("b0000000_?????_?????_110_?????_0110011")
    d.and   := op === BitPat("b0000000_?????_?????_111_?????_0110011")
    d.sll   := op === BitPat("b0000000_?????_?????_001_?????_0110011")
    d.srl   := op === BitPat("b0000000_?????_?????_101_?????_0110011")
    d.sra   := op === BitPat("b0100000_?????_?????_101_?????_0110011")

    // ---- RV32M opcode 匹配 ----
    d.mul     := op === BitPat("b0000_001_?????_?????_000_?????_0110011")
    d.mulh    := op === BitPat("b0000_001_?????_?????_001_?????_0110011")
    d.mulhsu  := op === BitPat("b0000_001_?????_?????_010_?????_0110011")
    d.mulhu   := op === BitPat("b0000_001_?????_?????_011_?????_0110011")
    d.div     := op === BitPat("b0000_001_?????_?????_100_?????_0110011")
    d.divu    := op === BitPat("b0000_001_?????_?????_101_?????_0110011")
    d.rem     := op === BitPat("b0000_001_?????_?????_110_?????_0110011")
    d.remu    := op === BitPat("b0000_001_?????_?????_111_?????_0110011")

    // ---- ZBB opcode 匹配 ----
    d.andn  := op === BitPat("b0100000_?????_?????_111_?????_0110011")
    d.orn   := op === BitPat("b0100000_?????_?????_110_?????_0110011")
    d.xnor  := op === BitPat("b0100000_?????_?????_100_?????_0110011")
    d.clz   := op === BitPat("b0110000_00000_?????_001_?????_0010011")
    d.ctz   := op === BitPat("b0110000_00001_?????_001_?????_0010011")
    d.cpop  := op === BitPat("b0110000_00010_?????_001_?????_0010011")
    d.max   := op === BitPat("b0000101_?????_?????_110_?????_0110011")
    d.maxu  := op === BitPat("b0000101_?????_?????_111_?????_0110011")
    d.min   := op === BitPat("b0000101_?????_?????_100_?????_0110011")
    d.minu  := op === BitPat("b0000101_?????_?????_101_?????_0110011")
    d.sextb := op === BitPat("b0110000_00100_?????_001_?????_0010011")
    d.sexth := op === BitPat("b0110000_00101_?????_001_?????_0010011")
    d.rol   := op === BitPat("b0110000_?????_?????_001_?????_0110011")
    d.ror   := op === BitPat("b0110000_?????_?????_101_?????_0110011")
    d.orcb  := op === BitPat("b0010100_00111_?????_101_?????_0010011")
    d.rev8  := op === BitPat("b0110100_11000_?????_101_?????_0010011")
    d.zexth := op === BitPat("b0000100_00000_?????_100_?????_0110011")
    d.rori  := op === BitPat("b0110000_?????_?????_101_?????_0010011")

    // ---- 扩展核心控制指令 ----
    // CoralNPU/RISC-V 系统控制指令, 只允许 pipeline0/lane0 处理。
    d.ebreak := op === BitPat("b000000000001_00000_000_00000_11100_11")
    d.ecall  := op === BitPat("b000000000000_00000_000_00000_11100_11")
    d.mpause := op === BitPat("b000010000000_00000_000_00000_11100_11")
    d.mret   := op === BitPat("b001100000010_00000_000_00000_11100_11")
    d.wfi    := op === BitPat("b000100000101_00000_000_00000_11100_11")

    // ---- fence / flush ----
    d.fencei   := op === BitPat("b0000_0000_0000_00000_001_00000_0001111")
    d.flushat  := op === BitPat("b0010?_??_00000_?????_000_00000_11101_11") && op(19,15) =/= 0.U
    d.flushall := op === BitPat("b0010?_??_00000_00000_000_00000_11101_11")


    if (p.enableFloat) {
      // 浮点译码还会检查 rm/CSR.frm 合法性; 非法则不视为有效 float 指令。
      val float = FloatInstruction.decode(p, op, addr)
      val floatValid = float.valid && float.bits.validate_csrfrm(csrFrm)
      d.float.get := MakeValid(floatValid, float.bits)
    }

    // 清空非 pipeline0 会使用不到的译码状态。
    if (pipeline > 0) {
      // 多 lane 中只有 lane0 能发 CSR/DVU/系统/fence/float 等特殊指令;
      // 非 lane0 直接清掉这些译码结果, 避免后续误发射。
      d.csrrw := false.B
      d.csrrs := false.B
      d.csrrc := false.B

      d.div := false.B
      d.divu := false.B
      d.rem := false.B
      d.remu := false.B

      d.ebreak := false.B
      d.ecall  := false.B
      d.mpause := false.B
      d.mret   := false.B
      d.wfi    := false.B

      d.fence    := false.B
      d.fencei   := false.B
      d.flushat  := false.B
      d.flushall := false.B

      if (p.enableFloat) {
        d.float.get := MakeInvalid(new FloatInstruction)
      }
    }

    if (p.enableRvv) {
      // RVV 由专用 decoder 转成内部压缩格式。
      d.rvv.get := RvvCompressedInstruction.from_uncompressed(op, addr)
    }

    // 生成未定义指令标记。
    // 如果所有已支持指令匹配位都为 0, 则作为 undef 异常处理。
    val decoded = Cat(d.lui, d.auipc,
                      d.jal, d.jalr,
                      d.beq, d.bne, d.blt, d.bge, d.bltu, d.bgeu,
                      d.csrrw, d.csrrs, d.csrrc,
                      d.lb, d.lh, d.lw, d.lbu, d.lhu,
                      d.sb, d.sh, d.sw, d.fence,
                      d.addi, d.slti, d.sltiu, d.xori, d.ori, d.andi,
                      d.add, d.sub, d.slt, d.sltu, d.xor, d.or, d.and, d.xnor, d.orn, d.andn,
                      d.slli, d.srli, d.srai, d.sll, d.srl, d.sra,
                      d.mul, d.mulh, d.mulhsu, d.mulhu,
                      d.div, d.divu, d.rem, d.remu,
                      d.clz, d.ctz, d.cpop, d.min, d.minu, d.max, d.maxu,
                      d.sextb, d.sexth, d.zexth,
                      d.rol, d.ror, d.orcb, d.rev8, d.rori,
                      d.ebreak, d.ecall, d.wfi,
                      d.mpause, d.mret, d.fencei, d.flushat, d.flushall,
                      d.rvv.map(_.valid).getOrElse(false.B),
                      d.float.map(_.valid).getOrElse(false.B))

    d.undef := decoded === 0.U

    d
  }
}
