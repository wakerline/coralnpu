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
// Regfile.scala — 标量整数寄存器文件 (32×32-bit)
//
// 32 个 32-bit 寄存器 (x0~x31), x0 硬连线恒为 0。
// 8 读端口 + 6 写端口 + Scoreboard 跟踪 RAW (写后读) 依赖供 DispatchV2 使用。
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common._
import _root_.circt.stage.ChiselStage

object Regfile {
  def apply(p: Parameters): Regfile = {
    return Module(new Regfile(p))
  }
}

class RegfileReadAddrIO extends Bundle {
  val valid = Input(Bool())                             // 读请求有效
  val addr  = Input(UInt(5.W))                          // 读寄存器地址 rs
}
//某些指令虽然形式上走 rs2 读口，但实际操作数可能是立即数，由 Dispatch 通过 readSet 直接送进去。
class RegfileReadSetIO extends Bundle {
  val valid = Input(Bool())                             // 直接注入读数据有效
  val value = Input(UInt(32.W))                         // 直接注入的读数据, 覆盖 regfile 读值
}
//这个接口用于 LSU/JALR 这类需要 rs1 + imm 地址计算的路径。
//JALR 目标地址路径是：
// Regfile 读 rs1
//   ↓
// rs1 + imm
//   ↓
// target(i).data
//   ↓
// BRU
class RegfileBusAddrIO extends Bundle {
  val valid = Input(Bool())                             // bus 地址计算请求有效
  val immen = Input(Bool())                             // 是否使用 rs1 + immed
  val immed = Input(UInt(32.W))                         // 立即数偏移
}
//这是给 BRU/JALR 使用的目标地址输出。
class RegfileBranchTargetIO extends Bundle {
  val data = Output(UInt(32.W))                         // BRU/JALR/LSU 使用的目标地址
}

class Regfile(p: Parameters) extends Module {
  // The register file has 1 write port per instruction lane.
  // Additionally, there are two more write ports to service
  // the MLU/DVU, and the LSU, as they may take more cycles.
  val extraWritePorts = 2                               // 额外写端口: MLU/DVU + LSU
  val io = IO(new Bundle {
    // Decode cycle: Dispatch 发起读端口、scoreboard 标记和地址计算请求。
    val readAddr = Vec(p.instructionLanes * 2, new RegfileReadAddrIO) // 每 lane 两个源操作数, 共 8R
    //某些指令虽然形式上走 rs2 读口，但实际操作数可能是立即数，由 Dispatch 通过 readSet 直接送进去。
    val readSet  = Vec(p.instructionLanes * 2, new RegfileReadSetIO)  // 旁路/立即写入读数据
    val writeAddr = Vec(p.instructionLanes, new RegfileWriteAddrIO)   // Dispatch 标记将来会写 rd,作用是设置 scoreboard
    val busAddr = Vec(p.instructionLanes, Input(new RegfileBusAddrIO)) // LSU/JALR 目标地址计算rs1/rs1+imm
    val target = Vec(p.instructionLanes, new RegfileBranchTargetIO)    // BRU 目标地址输出
    val linkPort = new RegfileLinkPortIO                  // x1/ra 链接端口, 用于 ret 预测
    val busPort = new RegfileBusPortIO(p)                 // LSU 地址/写数据端口
    val debugBusPort = new Bundle {
      val idx = Input(UInt(5.W))                         // debug 读寄存器索引
      val data = Output(UInt(32.W))                      // debug 读寄存器数据
    }
    val debugWriteValid = Input(Bool())                  // debug 写入时抑制部分 scoreboard 检查

    // Execute cycle: 上一拍 Decode 读出的数据和各执行单元写回。
    val readData = Vec(p.instructionLanes * 2, new RegfileReadDataIO) // 8 个读数据端口
    val writeData = Vec(p.instructionLanes + extraWritePorts, new Bundle {
      val valid = Input(Bool())                         // 写回有效
      val bits = new RegfileWriteDataIO                 // 写回地址/数据
    })                                                   // 4 lane + 2 extra = 6 个写回端口
    //例如分支 taken 后，后续 lane 属于错误路径；这些 lane 的写回要屏蔽。
    val writeMask = Vec(p.instructionLanes + extraWritePorts, new Bundle {val valid = Input(Bool())}) // 被 squash 的写回屏蔽
    val scoreboard = new Bundle {
      val regd = Output(UInt(32.W))                     // 寄存器版 busy mask，也就是上一拍
      val comb = Output(UInt(32.W))                     // 当拍清除后的组合 busy mask
    }
  })


  // The scalar registers.
  val regfile = RegInit(VecInit.fill(32)(0.U(32.W)))    // 32 个 32-bit 标量寄存器

  // ***************************************************************************
  // The scoreboard.
  // ***************************************************************************
  val scoreboard = RegInit(0.U(32.W))                   // 每个 bit 表示对应 rd 仍有未完成写回

  // The write Addr:Data contract is against speculated opcodes. If an opcode
  // is in the shadow of a taken branch it will still Set:Clr the scoreboard,
  // but the actual write will be Masked.
  // Dispatch 发射时根据 writeAddr 置 busy; 执行单元写回时根据 writeData 清 busy。
  val scoreboard_set = io.writeAddr
      .map(x => MuxOR(x.valid, UIntToOH(x.addr, 32))).reduce(_|_) // 本拍需要置位的 rd mask

  val scoreboard_clr0 = io.writeData
      .map(x => MuxOR(x.valid, UIntToOH(x.bits.addr, 32))).reduce(_|_) // 本拍写回完成的 rd mask

  val scoreboard_clr = Cat(scoreboard_clr0(31,1), 0.U(1.W)) // x0 永远不进入 scoreboard

  when (scoreboard_set =/= 0.U || scoreboard_clr =/= 0.U) {
    val nxtScoreboard = (scoreboard & ~scoreboard_clr) | scoreboard_set // 清除已写回, 置位新发射
    scoreboard := Cat(nxtScoreboard(31,1), 0.U(1.W))    // 强制 x0 busy=0
  }

  io.scoreboard.regd := scoreboard                      // 给 Dispatch 的寄存器状态
  io.scoreboard.comb := scoreboard & ~scoreboard_clr    // 给 Dispatch 的当拍写回旁路状态

  // ***************************************************************************
  // The read port response.
  // ***************************************************************************
  val readDataReady = RegInit(VecInit(Seq.fill(p.instructionLanes * 2){false.B})) // 读数据 valid 打拍
  val readDataBits  = RegInit(VecInit.fill(p.instructionLanes * 2)(0.U(32.W)))    // 读数据打拍
  val nxtReadDataBits = Wire(Vec(p.instructionLanes * 2, UInt(32.W)))             // 当拍组合读值，用于 busPort 等

  for (i <- 0 until (p.instructionLanes * 2)) {
    io.readData(i).valid := readDataReady(i)            // Execute 阶段读数据有效
    io.readData(i).data  := readDataBits(i)             // Execute 阶段读数据
  }

  // ***************************************************************************
  // One hot write ports.
  // ***************************************************************************
  val writeValid = Wire(Vec(32, Bool()))                // 每个寄存器是否有写回
  val writeData  = Wire(Vec(32, UInt(32.W)))            // 每个寄存器对应的写回数据

  writeValid(0) := true.B  // do not require special casing of indices
  writeData(0)  := 0.U     // regfile(0) is optimized away

  for (i <- 1 until 32) {
    val valid = (0 until p.instructionLanes + extraWritePorts).map(j => {
        val addrValid = (io.writeData(j).bits.addr === i.U) // 写端口 j 是否指向寄存器 i
        (io.writeData(j).valid && addrValid && !io.writeMask(j).valid)}) // 未被 mask 才真正写

    val data = (0 until p.instructionLanes + extraWritePorts).map(
        x => MuxOR(valid(x), io.writeData(x).bits.data)).reduce(_|_) // one-hot 选择写数据

    writeValid(i) := Cat(valid) =/= 0.U                 // 任一端口写该寄存器
    writeData(i)  := data                               // 对应写数据

    assert(PopCount(valid) <= 1.U)                      // 同一寄存器同拍最多一个写端口
  }

  for (i <- 0 until 32) {
    when (writeValid(i)) {
      regfile(i) := writeData(i)                        // 执行实际写回
    }
  }

  // We care if someone tried to write x0 (e.g. nop is encoded this way), but want
  // it separate for above mentioned optimization.
  val x0 = (0 until p.instructionLanes).map(x =>
      io.writeData(x).valid &&
      io.writeData(x).bits.addr === 0.U &&
      !io.writeMask(x).valid)                           // lane 写 x0 的观测信号, x0 实际仍为 0

  // ***************************************************************************
  // Read ports with write forwarding.
  // ***************************************************************************
  //旁路
  val rdata = Wire(Vec((p.instructionLanes * 2), UInt(32.W)))  // regfile 原始读值
  val wdata = Wire(Vec((p.instructionLanes * 2), UInt(32.W)))  // 同拍写回旁路值
  val rwdata = Wire(Vec((p.instructionLanes * 2), UInt(32.W))) // 最终读值: 写优先
  for (i <- 0 until (p.instructionLanes * 2)) {
    val idx = io.readAddr(i).addr                       // 读寄存器索引
    val write = VecAt(writeValid, idx)                  // 同拍是否写该寄存器
    rdata(i) := VecAt(regfile, idx)                     // 读旧值
    wdata(i) := VecAt(writeData, idx)                   // 读写回值
    rwdata(i) := Mux(write, wdata(i), rdata(i))         // 读新数据，写回旁路避免 RAW 等一拍
  }
  io.debugBusPort.data := VecAt(regfile, io.debugBusPort.idx) // debug 直接读 regfile

  for (i <- 0 until (p.instructionLanes * 2)) {
    nxtReadDataBits(i) := Mux(
        io.readSet(i).valid, io.readSet(i).value, rwdata(i)) // readSet 优先于 regfile/forward

    readDataReady(i) := io.readAddr(i).valid || io.readSet(i).valid // 下一拍 readData valid
    readDataBits(i) := MuxCase(readDataBits(i), Seq(
        io.readSet(i).valid -> io.readSet(i).value,     // 直接设置读数据
        io.readAddr(i).valid -> rwdata(i)               // 正常读/旁路数据
    ))
  }

  // Bus port priority encoded address.
  val busAddr = Wire(Vec(p.instructionLanes, UInt(32.W))) // 每 lane 的 LSU/JALR 地址
  val busValid = Cat((0 until p.instructionLanes).reverse.map(x => io.busAddr(x).valid)) // bus 地址有效 mask

  for (i <- 0 until p.instructionLanes) {
    busAddr(i) := Mux(io.busAddr(i).immen, rdata(2 * i) + io.busAddr(i).immed,
                      rdata(2 * i))                    // immen=1: rs1+imm; 否则直接 rs1
  }

  for (i <- 0 until p.instructionLanes) {
    io.busPort.addr(i) := busAddr(i)                   // LSU 地址
    io.busPort.data(i) := nxtReadDataBits(2 * i + 1)   // LSU store 数据来自 rs2
  }

  // Branch target address combinatorial.
  for (i <- 0 until p.instructionLanes) {
    io.target(i).data := busAddr(i)                    // BRU/JALR 使用同一地址计算结果
  }

  // ***************************************************************************
  // Link port.
  // ***************************************************************************
  io.linkPort.valid := !scoreboard(1)                  // x1/ra 没有未完成写回时可用于 ret 预测
  io.linkPort.value := regfile(1)                      // x1/ra 当前值

  // ***************************************************************************
  // Assertions.
  // ***************************************************************************
  for (i <- 0 until p.instructionLanes) {
    assert(busAddr(i).getWidth == p.lsuAddrBits)       // 地址位宽必须匹配 LSU
  }

  for (i <- 0 until p.instructionLanes + extraWritePorts) {
    for (j <- (i + 1) until p.instructionLanes + extraWritePorts) {
      // Delay the failure a cycle for debugging purposes.
      val write_fail = RegInit(false.B)
      write_fail := io.writeData(i).valid && io.writeData(j).valid &&
                    io.writeData(i).bits.addr === io.writeData(j).bits.addr &&
                    io.writeData(i).bits.addr =/= 0.U  // 非 x0 同寄存器双写为非法
      assert(!write_fail)
    }
  }

  val scoreboard_error = RegInit(false.B)              // 清除未置位 scoreboard bit 视为错误
  val dm_write_valid = io.debugWriteValid              // debug 写入时允许绕过正常 scoreboard 协议
  scoreboard_error := ((scoreboard & scoreboard_clr) =/= scoreboard_clr) && !dm_write_valid
  assert(!scoreboard_error)
}

object EmitRegfile extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new Regfile(p), args)
}
