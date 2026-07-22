// ============================================================================
// DBus2Axi.scala — 数据总线 (DBus/EBus) → AXI4 Master 协议转换
//
// DBus2AxiV2 将核内简化 DBus 协议转为标准 AXI4 Master:
//   写路径: 三状态机(waddrFired/wdataFired/wrespReceived)管理 AXI 三通道独立握手
//           Queue(2) 解耦地址和数据通道
//   读路径: raddrFired + rdataReceived 状态机 → RegNext 延迟1拍匹配DBus时序
//   故障: AXI RESP ≠ OKAY 时报告 FaultInfo
// ============================================================================
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

package coralnpu

import chisel3._
import chisel3.util._

import bus.{AxiMasterIO, AxiResponseType, AxiWriteData}
import common._
import _root_.circt.stage.{ChiselStage,FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

/** DBus2Axi 伴生对象 — 工厂方法 (默认实例化 V2 版本)
 *  @param id AXI 事务 ID: ebus=0(数据), ibus=1(取指) — 用于读数据 ID 路由 */
object DBus2Axi {
  def apply(p: Parameters, id: Int = 0): DBus2Axi = Module(new DBus2AxiV2(p, id))
}

/** ReadCtrl — 读控制信息 (未使用, 保留) */
class ReadCtrl(p: Parameters) extends Bundle {
  val addr = UInt(p.axi2AddrBits.W)                            // 读地址
  val size = UInt(p.axi2DataBits.W)                             // 读大小
  val pc   = UInt(p.programCounterBits.W)                       // 指令 PC
}

/** WriteCtrl — 写控制信息 (未使用, 保留) */
class WriteCtrl(p: Parameters) extends Bundle {
  val addr = UInt(p.axi2AddrBits.W)                            // 写地址
  val pc   = UInt(p.programCounterBits.W)                       // 指令 PC
}

/** DBus2Axi 基类 — 定义 IO Bundle (DBus 输入 + AXI Master 输出 + 故障) */
class DBus2Axi(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val dbus  = Flipped(new DBusIO(p))                           // DBus 输入 (核内协议)
    val axi   = new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits) // AXI Master 输出
    val fault = Valid(new FaultInfo(p))                           // 总线故障报告
  })
}

/** DBus2AxiV2 — DBus→AXI4 完整转换实现 (继承 DBus2Axi 的 IO)。
 *  @param id AXI 事务 ID: ebus=0, ibus=1 — 用于 AXI 读数据按 ID 路由回正确源。 */
class DBus2AxiV2(p: Parameters, id: Int = 0) extends DBus2Axi(p) {
  // 断言: dbus.size 必须是 2 的幂次 (单次传输宽度)
  assert(!(io.dbus.valid && PopCount(io.dbus.size) =/= 1.U),
         cf"Invalid dbus size=${io.dbus.size}")

  // ---- 写路径: 三状态机管理 AXI 三通道独立握手 ----
  // AXI 写有三个独立通道 (WriteAddr/WriteData/WriteResp)，需分别跟踪完成状态
  // waddrFired: AXI 写地址通道已握手但数据/响应未完成
  val waddrFired = RegInit(false.B) // AXI 写地址已发但数据/响应未完成
  io.axi.write.addr.valid := !waddrFired && io.dbus.valid && io.dbus.write
  io.axi.write.addr.bits.defaults()                               // 未显式设置的域取安全默认值
  io.axi.write.addr.bits.addr := io.dbus.addr                     // 地址 = DBus 地址
  io.axi.write.addr.bits.size := Ctz(io.dbus.size)               // Ctz: 2的幂→AXI size编码 (1→0,2→1,4→2...)
  io.axi.write.addr.bits.prot := 2.U                              // prot=2: 非特权数据访问
  io.axi.write.addr.bits.id := id.U                               // 事务 ID (区分 ibus/ebus)

  // wdataFired: AXI 写数据已入队但地址/响应未完成
  val wdataFired = RegInit(false.B)
  // Queue(2) 解耦写地址和写数据通道: 地址可先于数据发出
  val wdataQueue = Module(new Queue(new AxiWriteData(p.axi2DataBits, p.axi2IdBits), 2))
  wdataQueue.io.enq.valid := !wdataFired && io.dbus.valid && io.dbus.write
  wdataQueue.io.enq.bits.data := io.dbus.wdata
  wdataQueue.io.enq.bits.strb := io.dbus.wmask                   // 字节掩码 → AXI strb
  wdataQueue.io.enq.bits.last := true.B                           // 单拍传输, last=1
  io.axi.write.data <> wdataQueue.io.deq                          // <> Bulk Connect 出队

  // wrespReceived: AXI 写响应已收到但地址/数据未完成
  val wrespReceived = RegInit(false.B)
  io.axi.write.resp.ready := !wrespReceived && io.dbus.valid && io.dbus.write

  // 写完成条件: 三通道全部完成 (fire 或已标记完成)
  val writeFinished = (io.axi.write.addr.fire || waddrFired) &&
                      (wdataQueue.io.enq.fire || wdataFired) &&
                      (io.axi.write.resp.fire || wrespReceived)
  // 三状态机的更新逻辑: 完成→清零, fire→标记完成
  waddrFired := MuxCase(waddrFired, Seq(
    writeFinished -> false.B,                                      // 全部完成: 复位
    io.axi.write.addr.fire -> true.B,                             // 地址已发: 标记
  ))
  wdataFired := MuxCase(wdataFired, Seq(
    writeFinished -> false.B,
    wdataQueue.io.enq.fire -> true.B,
  ))
  wrespReceived := MuxCase(wrespReceived, Seq(
    writeFinished -> false.B,
    io.axi.write.resp.fire -> true.B,
  ))

  // ---- 读路径: 双状态机 (raddrFired + rdataReceived) ----
  val raddrFired = RegInit(false.B)                                // AXI 读地址已发但数据未回
  io.axi.read.addr.valid := !raddrFired && io.dbus.valid && !io.dbus.write
  io.axi.read.addr.bits.defaults()
  io.axi.read.addr.bits.addr := io.dbus.addr
  io.axi.read.addr.bits.size := Ctz(io.dbus.size)
  io.axi.read.addr.bits.prot := 2.U
  io.axi.read.addr.bits.id := id.U

  val rdataReceived = RegInit(MakeInvalid(UInt(p.axi2DataBits.W)))// AXI 读数据已收到但地址未发/未消费
  io.axi.read.data.ready :=
      !rdataReceived.valid && io.dbus.valid && !io.dbus.write

  val readFinished = (io.axi.read.addr.fire || raddrFired) &&
                     (io.axi.read.data.fire || rdataReceived.valid)
  raddrFired := MuxCase(raddrFired, Seq(
    readFinished -> false.B,
    io.axi.read.addr.fire -> true.B,
  ))
  rdataReceived := MuxCase(rdataReceived, Seq(
    readFinished -> MakeInvalid(UInt(p.axi2DataBits.W)),
    io.axi.read.data.fire -> MakeValid(true.B, io.axi.read.data.bits.data),
  ))
  // readNext: 延迟 1 拍寄存器 — DBus 期望 rdata 在 ready 后下一拍有效
  val readNext = RegInit(0.U(p.axi2DataBits.W))
  readNext := Mux(
      readFinished,
      Mux(io.axi.read.data.fire, io.axi.read.data.bits.data, rdataReceived.bits),
      readNext)
  io.dbus.rdata := readNext

  // ---- DBus 响应: 写完成→写 ready, 读完成→读 ready ----
  io.dbus.ready := Mux(io.dbus.write, writeFinished, readFinished)

  // ---- 故障检测: AXI RESP ≠ OKAY 时报告总线错误 ----
  io.fault.valid := io.dbus.valid && Mux(
    io.dbus.write,
    io.axi.write.resp.valid && (io.axi.write.resp.bits.resp =/= AxiResponseType.OKAY.asUInt),
    io.axi.read.data.valid && (io.axi.read.data.bits.resp =/= AxiResponseType.OKAY.asUInt))
  io.fault.bits.write := io.dbus.write
  io.fault.bits.addr := io.dbus.addr                               // 故障地址
  io.fault.bits.epc := io.dbus.pc                                  // 触发故障的指令 PC
}

/** EmitDBus2Axi — Standalone Verilog 生成入口 (调试用) */
@nowarn
object EmitDBus2Axi extends App {
  val p = new Parameters
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new DBus2AxiV2(p))) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
