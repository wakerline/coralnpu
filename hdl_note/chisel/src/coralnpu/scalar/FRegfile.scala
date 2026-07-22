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
// FRegfile.scala — 浮点寄存器文件 (32×FP32)
// 3读端口+2写端口 + Scoreboard 跟踪浮点寄存器 RAW 依赖
// ============================================================================

package coralnpu

import chisel3._
import chisel3.util._
import common.Fp32

class FRegfile(p: Parameters, n_read: Int, n_write: Int) extends Module {
  val io = IO(new Bundle {
    val read_ports = Vec(n_read, new FRegfileRead)       // 浮点读端口, 数量由 FloatCore 配置
    val write_ports = Vec(n_write, new FRegfileWrite)    // 浮点写回端口
    val dm_write_valid = Input(Bool())                   // debug 写入时抑制部分 scoreboard 检查

    val scoreboard_set = Input(UInt(32.W))               // Dispatch 发射浮点写 rd 时置位 busy，表示后续会写，需要阻塞
    val scoreboard = Output(UInt(32.W))                  // 当前浮点寄存器 busy mask
    val exception = Output(Bool())                       // 同一寄存器多写冲突异常，但是SCore未连接

    val busPort = new RegfileBusPortIO(p)                // 给 LSU/store 使用的数据端口
    val busPortAddr = Input(UInt(5.W))                   // LSU 需要读取的浮点寄存器地址
  })

  val fregfile = RegInit(VecInit.fill(32)(Fp32.fromWord("x00000000".U(32.W)))) // 32 个 FP32 寄存器
  val scoreboard = RegInit(0.U(32.W))                    // 浮点寄存器 RAW 依赖 scoreboard

  // ---- Scoreboard 更新 ----
  // 写回端口清除 busy, Dispatch 提供的 scoreboard_set 置 busy。
  val scoreboard_clr = io.write_ports.map(x =>
      Mux(x.valid, UIntToOH(x.addr), 0.U)).reduce(_|_)   // 本拍完成写回的寄存器 mask
  scoreboard := (scoreboard & ~scoreboard_clr) | io.scoreboard_set // 清除已写回, 置位新发射
  io.scoreboard := scoreboard                            // 输出给 Dispatch 做依赖判断

  val scoreboard_error = RegInit(false.B)                // 清除未置位 busy bit 视为协议错误
  val dm_write_valid = io.dm_write_valid                 // debug 写入绕过正常 scoreboard 协议
  scoreboard_error := ((scoreboard & scoreboard_clr) =/= scoreboard_clr) && !dm_write_valid//检查要清除的 busy 位，是否之前真的处于 busy 状态。
  assert(!scoreboard_error)

  // ---- 写端口 ----
  // 每个物理寄存器汇总所有写端口, 同拍多写同一非仲裁寄存器时报 exception。
  val register_write_error = Wire(Vec(32, Bool()))       // 每个寄存器的多写冲突标志
  for (i <- 0 until 32) {
    val valid = io.write_ports.map(x => x.valid & x.addr === i.U) // 哪些写端口写寄存器 i
    val data = PriorityMux(valid, io.write_ports.map(_.data))      // 若唯一有效, 选择写数据
    register_write_error(i) := PopCount(valid) > 1.U               // 同寄存器多写冲突
    when (valid.reduce(_|_)) {
      fregfile(i) := data                                // 执行浮点寄存器写回
    }
  }
  io.exception := register_write_error.reduce(_|_)       // 任一寄存器冲突则上报异常

  // ---- 读端口 ----
  // 无效读返回 +0.0, 有效读返回对应 FP32 寄存器内容。
  for (i <- 0 until n_read) {
    val read_port = io.read_ports(i)                     // 第 i 个浮点读端口
    read_port.data := Mux(read_port.valid,
                          fregfile(read_port.addr),
                          Fp32.Zero(false.B))
  }

  // ---- LSU/store bus port ----
  //fsw f1, 8(x2)
  io.busPort.addr(0) := 0.U                              // FRegfile 只提供 store 数据, 不负责地址
  // If there's a write in progress, forward the value. Otherwise, fetch from the regfile.
  // TOOD(atv): Generalize this a bit, such that if there is an incoming write on any port for the addr, we fwd it.
  //这段代码本身没有保证 fsw 一定拿到新值。
  //实际是否安全，要看 Dispatch 是否通过 scoreboard 阻止这种情况：
  io.busPort.data(0) := (if (n_read < 2) {
    0.U                                                  // 读端口不足时不提供浮点 store 数据
  } else {
    fregfile(io.busPortAddr).asWord                      // 读取浮点寄存器作为 store 数据
  })
  for (i <- 1 until p.instructionLanes) {
    io.busPort.addr(i) := 0.U                            // 只使用 busPort(0)。其它 lane 未使用
    io.busPort.data(i) := 0.U
  }
}
