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
// Library.scala — CoralNPU 专用硬件工具函数库
//
// 常用硬件原语 (全部是组合逻辑, 无状态):
//
//   ---- 条件赋值 ----
//   MuxOR/Mux0       — valid=data, !valid=0 (OR-safe 多路合并)
//
//   ---- 数学 ----
//   Min/Max/Repeat/SignExt/Mod2
//
//   ---- 向量操作 ----
//   VecOR/OrReduce   — 向量元素归约 OR (树形结构, 对数深度)
//   IndexMask        — 按索引掩码 (index位置输出原值, 其余=0)
//   VecAt/BoolAt     — 按索引读取向量/UInt的某一位
//   WiredAND/WiredOR — 树形 AND/OR 归约 (对时序友好)
//
//   ---- 前导/尾随 0/1 计数 ----
//   Ctz/Cto/Clz/Clo/Clb/WCtz — 基于 PriorityEncoder
//
//   ---- AXI/总线辅助 ----
//   PageMaskShift    — 页边界检测 (AXI 跨页判断)
//   GenerateMasks    — 双事务字节掩码
//   BytemaskToBitmask— 字节掩码→位掩码
//
//   ---- Decoupled 工具 ----
//   GateDecoupled    — enable 门控 Decoupled 握手
//   WithAddr/LiftAddr— 带地址字段的 Data 包装/函数提升
// ============================================================================
// | 函数                   | 你看到它时应该怎么理解            |
// | -------------------- | ---------------------- |
// | `Mux0(valid, data)`  | 无效时输出 0                |
// | `MuxOR(valid, data)` | 无效时输出 0，方便多路 OR 合并     |
// | `Min/Max`            | 比较器 + Mux              |
// | `Repeat`             | 复制 bit                 |
// | `SignExt`            | 符号扩展                   |
// | `Mod2`               | 2 的幂取模                 |
// | `VecOR`              | 线性 OR 归约               |
// | `OrReduce`           | 树形 OR 归约               |
// | `IndexMask`          | 只保留一个 index 的元素        |
// | `VecAt`              | 动态索引读取 Vec             |
// | `BoolAt`             | 动态读取 UInt 某一 bit       |
// | `WiredAND`           | 树形 AND 归约              |
// | `WiredOR`            | 树形 OR 归约               |
// | `Ctz`                | 低位连续 0 个数              |
// | `Clz`                | 高位连续 0 个数              |
// | `WCtz`               | 宽位低位连续 0 计数            |
// | `PageMaskShift`      | AXI 跨页/页边界辅助           |
// | `GenerateMasks`      | 生成非对齐/双事务 byte mask    |
// | `BytemaskToBitmask`  | byte mask 扩展成 bit mask |
// | `GateDecoupled`      | enable 门控 ready/valid  |
// | `WithAddr`           | 给数据附加地址                |
// | `LiftAddr`           | 保留地址，只变换 payload       |


package coralnpu

import chisel3._
import chisel3.util._

// ===================================================================
// 条件赋值: valid 时输出 data, 否则输出 0 (OR-safe)
// 为什么用 OR 语义? 多个 MuxOR 输出可以直接 | 合并, 形成 Priority Mux
// ===================================================================

/** Mux0: valid=1→data, valid=0→0 */
object Mux0 {
  def apply(valid: Bool, data: UInt): UInt = Mux(valid, data, 0.U(data.getWidth.W))
  def apply(valid: Bool, data: Bool): Bool = Mux(valid, data, false.B)
}

/** MuxOR: 与 Mux0 相同语义, 名称强调 OR-safe (多路输出可 | 合并) */
object MuxOR {
  def apply(valid: Bool, data: UInt): UInt = Mux(valid, data, 0.U(data.getWidth.W))
  def apply(valid: Bool, data: Bool): Bool = Mux(valid, data, false.B)
}

// ===================================================================
// 数学工具
// ===================================================================

/** Min: 取两数最小值 */
object Min {
  def apply(a: UInt, b: UInt): UInt = {
    assert(a.getWidth == b.getWidth)
    Mux(a < b, a, b)
  }
}

/** Max: 取两数最大值 */
object Max {
  def apply(a: UInt, b: UInt): UInt = {
    assert(a.getWidth == b.getWidth)
    Mux(a > b, a, b)
  }
}

/** Repeat: 将 Bool 重复 n 次 → n-bit UInt */
object Repeat {
  def apply(b: Bool, n: Int): UInt = {
    val r = VecInit(Seq.fill(n)(b))  // 重复 n 个 b 组成 Vec, 然后转换为 UInt
    r.asUInt
  }
}

/** SignExt: 符号扩展 v 到 n 位宽 */
object SignExt {
  def apply(v: UInt, n: Int): UInt = {
    val s = v.getWidth  // v 的原始位宽
    val r = Cat(Repeat(v(s - 1), n - s), v)  // 先生成 n-s 个符号位, 再拼接原值 v
    assert(r.getWidth == n)
    r.asUInt
  }
}

/** Mod2: 除数为 2 的幂时的取模 (dividend & (divisor-1)) */
object Mod2 {
  def apply(dividend: UInt, divisor: UInt) = dividend & (divisor - 1.U)  // 适用于 divisor 是 2 的幂的情况, 等价于 dividend % divisor, 但更高效
}

// ===================================================================
// 向量操作: Vec 元素的归约/索引/掩码
// ===================================================================

/** VecOR: 向量元素 OR 归约 (递归实现, 对数深度)
 *  Vec(4, UInt(7.W)) → UInt(7.W)
 *  等价于: for (i <- 0 until count) out |= in(i) */
/** VecOR: 递归 OR 归约 — 从 vec(0) 到 vec(count-1) 逐元素 OR
 *  内部实现用递归调用在 Scala 编译期展开为硬件链 */
object VecOR {
  // 内部递归: index 逐个累加, bits 累积 OR 结果
  def apply(vec: Vec[UInt], count: Int, index: Int, bits: UInt): UInt = {
    if (index < count) apply(vec, count, index+1, bits | vec(index)) else bits
  }
  def apply(vec: Vec[Bool], count: Int, index: Int, bits: Bool): Bool = {
    if (index < count) apply(vec, count, index+1, bits || vec(index)) else bits
  }
  // 公开接口: 归约前 count 个元素
  def apply(vec: Vec[UInt], count: Int): UInt = apply(vec, count, 0, 0.U)//
  def apply(vec: Vec[Bool], count: Int): Bool = apply(vec, count, 0, false.B)//
  // 归约全部元素
  def apply(vec: Vec[UInt]): UInt = apply(vec, vec.length, 0, 0.U)
  def apply(vec: Vec[Bool]): Bool = apply(vec, vec.length, 0, false.B)
}

/** IndexMask: 按索引掩码 — index 位置保留原值, 其余位置输出 0
 *  例: data=[A,B,C,D], index=2 → [0,0,C,0] */
object IndexMask {
  def apply(data: Vec[UInt], index: UInt): Vec[UInt] = {
    val count = data.length
    val width = data(0).getWidth.W
    val value = Wire(Vec(count, UInt(width)))
    for (i <- 0 until count) {
      value(i) := Mux(i.U === index, data(i), 0.U)
    }
    value
  }
}

/** OrReduce: 树形 OR 归约 — 两两配对 OR, 对数深度 (vs VecOR 的线性深度)
 *  例: [A,B,C,D] → [A|B, C|D] → [(A|B)|(C|D)]
 *  时序优于 VecOR, 适合宽向量 */
object OrReduce {
  def apply(data: Vec[UInt]): UInt = {
    if (data.length > 1) {
      val count = data.length / 2                              // 配对组数
      val odd   = data.length & 1                               // 奇数个元素时多一个
      val width = data(0).getWidth.W
      val value = Wire(Vec(count + odd, UInt(width)))
      for (i <- 0 until count) {
        value(i) := data(2 * i + 0) | data(2 * i + 1)          // 两两 OR
      }
      if (odd != 0) value(count) := data(2 * count)             // 落单的直接传递
      OrReduce(value)                                           // 递归到树收敛
    } else { data(0) }
  }
}

/** VecAt: 从 Vec 中按 index 读取第 index 个元素
 *  内部用 IndexMask + OrReduce: 先把 index 位置以外的元素清零, 再 OR 归约 */
object VecAt {
  def apply(data: Vec[Bool], index: UInt): Bool = {
    assert(data.length == (1 << index.getWidth))               // index 位宽必须覆盖所有元素
    val dataUInt = Wire(Vec(data.length, UInt(1.W)))
    for (i <- 0 until data.length) dataUInt(i) := data(i)
    OrReduce(IndexMask(dataUInt, index)) =/= 0.U               // 掩码后 OR → 检查非零
  }
  def apply(data: Vec[UInt], index: UInt): UInt = {
    assert(data.length == (1 << index.getWidth))
    OrReduce(IndexMask(data, index))                            // 掩码后 OR → 选中值
  }
}

/** BoolAt: 从 UInt 中读取第 index 位 */
object BoolAt {
  def apply(udata: UInt, index: UInt): Bool = {
    assert(udata.getWidth == (1 << index.getWidth))
    val data = Wire(Vec(udata.getWidth, UInt(1.W)))
    for (i <- 0 until udata.getWidth) data(i) := udata(i)
    OrReduce(IndexMask(data, index)) =/= 0.U
  }
}

/** WiredAND: 树形 AND 归约 — 两两配对 &, 对数深度, 时序友好 */
object WiredAND {
  def apply(bits: UInt): Bool = WiredAND(VecInit(bits.asBools))
  def apply(bits: Vec[Bool]): Bool = {
    val count = bits.length
    if (count > 1) {
      val limit = (count + 1) / 2
      val value = Wire(Vec(limit, Bool()))
      for (i <- 0 until limit) {
        if (i * 2 + 1 >= count) value(i) := bits(2 * i + 0)    // 落单直通
        else value(i) := bits(2 * i + 0) & bits(2 * i + 1)     // 两两 AND
      }
      WiredAND(value)                                           // 递归
    } else { bits(0) }
  }
}

/** WiredOR: 树形 OR 归约 — 两两配对 |, 对数深度 */
object WiredOR {
  def apply(bits: UInt): Bool = WiredOR(VecInit(bits.asBools))
  def apply(bits: Vec[Bool]): Bool = {
    val count = bits.length
    if (count > 1) {
      val limit = (count + 1) / 2
      val value = Wire(Vec(limit, Bool()))
      for (i <- 0 until limit) {
        if (i * 2 + 1 >= count) value(i) := bits(2 * i + 0)
        else value(i) := bits(2 * i + 0) | bits(2 * i + 1)
      }
      WiredOR(value)
    } else { bits(0) }
  }
}

// ===================================================================
// 计数尾随/前导 0/1 (基于 PriorityEncoder + Cat(1, bits) 技巧)
// ===================================================================

/** Cto: Count Trailing Ones — 尾部连续 1 的个数 */
object Cto {
  def apply(bits: UInt): UInt = PriorityEncoder(Cat(1.U(1.W), ~bits))// 在 bits 前面加一个 1 位, 然后对 ~bits 进行 PriorityEncoder, 就能得到尾部连续 1 的个数
}

/** Ctz: Count Trailing Zeros — 尾部连续 0 的个数 */
object Ctz {
  def apply(bits: UInt): UInt = PriorityEncoder(Cat(1.U(1.W), bits))// 在 bits 前面加一个 1 位, 然后对 bits 进行 PriorityEncoder, 就能得到尾部连续 0 的个数
}

/** Clz: Count Leading Zeros — 前导 0 的个数 (Reverse 后 Ctz) */
object Clz {
  def apply(bits: UInt): UInt = PriorityEncoder(Cat(1.U(1.W), Reverse(bits)))// 在 bits 前面加一个 1 位, 然后对 Reverse(bits) 进行 PriorityEncoder, 就能得到前导 0 的个数
}

/** Clo: Count Leading Ones (未使用) */
object Clo {
  def apply(bits: UInt): UInt = PriorityEncoder(Cat(1.U(1.W), Reverse(~bits)))// 在 ~bits 前面加一个 1 位, 然后对 Reverse(~bits) 进行 PriorityEncoder, 就能得到前导 1 的个数
}

/** Clb: Count Leading Bits — MSB=1→Clo, MSB=0→Clz (未使用) */
object Clb {
  def apply(bits: UInt): UInt = {
    val clo = Clo(bits); val clz = Clz(bits)
    Mux(bits(bits.getWidth - 1), clo, clz)// 根据 MSB 决定是计算前导 1 还是前导 0
  }
}

/** WCtz: Wide Ctz — 32-bit 分段查找第一个非零位
 *  每 32-bit 一段, 当前段全零时跳到下一段继续查 */
object WCtz {
  def apply(bits: UInt, offset: Int = 0): UInt = {
    assert((bits.getWidth % 32) == 0)
    val z = Ctz(bits(31, 0))                                   // 低 32-bit 的 ctz
    val v = z | offset.U
    if (bits.getWidth > 32)
      Mux(!z(5), v, WCtz(bits(bits.getWidth - 1, 32), offset + 32))  // 如果当前段非零, 则结果是 v;
    else
      Mux(!z(5), v, (offset + 32).U)// 如果当前段全零, 则跳到下一段继续查找, offset 累加 32
  }
}

// ===================================================================
// AXI/总线辅助工具
// ===================================================================

// ===================================================================
// PageMaskShift — 跨页检测: 计算掩码移位的位数
//
// AXI 总线中, 一次 burst 传输不能跨越 4KB 页边界。但在未对齐访问场景下,
// 真正的"页"取决于地址低位和传输长度: 一旦 address+length 溢出了 2^n 的
// 对齐边界, 这次传输就在该 2^n 边界处"跨页"了。
//
// 两步法:
//   ① psel/pshift: 暴力检测 address[9:0]+length 是否能放入 4/8/16/.../1024 的页
//   ② addrmask/cto: 如果上一步都失败, 用地址中尾部连续 1 的最长长度作为边界
//
// 例 1: address=0x10, length=8
//   address[3:0]+length = 0x0+8 = 8 ≤ 8  → psel(2)=1 → pshift=4
//   ← 8 字节内放得下, 页尺寸=8, shift=4
//
// 例 2: address=0x100E, length=8
//   address[0]+length = 0xE+8=22 > 4, >8, >16 → psel 全 0 → 走 cto 路径
//   address=0x100E = ...0000_1110 → 尾部连续 1 长 3 位
//   addrmask = ...0000_0000_1111_1111_1111_1 → ~addrmask = ...1111_1111_0000_0000_0000_0
//   PriorityEncoder(~addrmask) → 遇到第一个 0 的位置 = 4 → cto=4
//   ← 需要 2^4=16 字节的页, shift=4
//
// 返回值 shift: 掩码左移的位数, 用于生成跨页检测掩码
// ===================================================================
object PageMaskShift {
  def apply(address: UInt, length: UInt): UInt = {
    assert(address.getWidth == 32)

    // ---- ① psel: 检测 address[9:0]+length 是否不溢出 4/8/16/.../1024 ----
    // psel(0): address[0]+length ≤ 4?   (2^2 尺寸)
    // psel(1): address[1:0]+length ≤ 8?  (2^3 尺寸)
    // ...
    // psel(8): address[9:0]+length ≤ 1024? (2^10 尺寸)
    val psel = Cat((address(9,0) +& length) <= 1024.U,
                   (address(8,0) +& length) <= 512.U,
                   (address(7,0) +& length) <= 256.U,
                   (address(6,0) +& length) <= 128.U,
                   (address(5,0) +& length) <= 64.U,
                   (address(4,0) +& length) <= 32.U,
                   (address(3,0) +& length) <= 16.U,
                   (address(2,0) +& length) <= 8.U,
                   (address(1,0) +& length) <= 4.U)

    // pshift: psel 中第一个(最高的)为 1 的位 → 对应的 shift 值
    // psel(0)=1→shift=2, psel(1)=1→shift=3, ..., psel(8)=1→shift=10
    val pshift =
        Mux(psel(0), 2.U, Mux(psel(1), 3.U, Mux(psel(2), 4.U, Mux(psel(3), 5.U,
        Mux(psel(4), 6.U, Mux(psel(5), 7.U, Mux(psel(6), 8.U, Mux(psel(7), 9.U,
        Mux(psel(8), 10.U, 0.U)))))))))

    // ---- ② cto: 从地址尾部连续 1 的最长长度推断页边界 ----
    // addrmask: 高10位=地址高位, 低10位=全1, 最低位额外补1
    // 补1的目的是: 确保 ~addrmask 有一个终止 0 (因为 cto 在此处终止)
    val addrmask = Cat(address(31,10), ~0.U(10.W), 1.U(1.W))
    // PriorityEncoder(~addrmask): 找到 ~addrmask 中第一个 0 的位置
    // 这个位置 = (addrmask 中尾部连续 1 的长度)
    // 例: addrmask = ...0000_1111_1 → ~addrmask = ...1111_0000_0
    //     PriorityEncoder 在位置 2 处找到第一个 0 → cto=2
    val cto = PriorityEncoder(~addrmask)

    // psel 优先; 若 psel 全0 则用 cto 作为 fallback
    val shift = Mux(psel =/= 0.U, pshift, cto)
    assert(shift.getWidth == 6)

    shift
  }
}

// ===================================================================
// 函数式编程工具: WithAddr / LiftAddr
// ===================================================================

/** WithAddr: 带地址字段的 Data 包装 — 将任意 gen:T 包装为 (addr+bits) Bundle
 *  @param width addr 的位宽
 *  @param gen   被包装的数据类型 */
class WithAddr[+T <: Data](width: Int, gen: T) extends Bundle {
  val addr = UInt(width.W)
  val bits = gen
}

object WithAddr {
  def apply[T <: Data](width: Int, gen: T): WithAddr[T] = new WithAddr(width, gen)
  /** 创建 WithAddr 实例并赋值 */
  def create[T <: Data](addr: UInt, bits: T) = {
    val result = Wire(WithAddr(addr.getWidth, chiselTypeOf(bits)))
    result.addr := addr; result.bits := bits; result
  }
}

/** LiftAddr: 将函数 f: X→Y 提升为 f': WithAddr[X]→WithAddr[Y]
 *  addr 字段在变换前后保持不变, 只对 bits 应用 f 
 *  用途是流水线中保留原始地址，同时对 payload 做变换。*/
object LiftAddr {
  def apply[X <: Data, Y <: Data](width: Int, f: X => Y) = {
    (x: WithAddr[X]) => WithAddr.create(x.addr, f(x.bits))
  }
}

/** GateDecoupled: enable 门控 Decoupled 握手
 *  enable=1: 正常传递 valid/ready/bits
 *  enable=0: valid 始终为 0 (阻断请求), ready 正常传递 */
object GateDecoupled {
  def apply[T <: Bundle](iface: DecoupledIO[T], enable: Bool): DecoupledIO[T] = {
    val out = Wire(chiselTypeOf(iface))
    iface.bits  <> out.bits                                   // bits 直通
    iface.ready := out.ready && (enable)                       // 下游 ready 仅在 enable 时传回
    out.valid   := iface.valid && (enable)                     // 上游 valid 仅在 enable 时向下传
    out
  }
}

/** GenerateMasks: 双事务字节掩码生成
 *  输入: 基地址 + 两个事务大小 → 输出两个字节掩码 (低地址优先)
 *  rotateLeft 将掩码按地址低位偏移旋转到正确位置 */

// 典型场景是非对齐访问拆成两笔事务。

// 例如总线宽度 32B，访问从 byte offset 30 开始，需要写 4B：

// 第一笔写 byte 30~31
// 第二笔写下一行 byte 0~1

// GenerateMasks 就可以生成两笔对应的 byte mask。
object GenerateMasks {
  def apply(nBytes: Int, addr: UInt, txnSizes: Vec[UInt]): (UInt, UInt) = {
    val bottom = addr(log2Ceil(nBytes),0)                     // 地址的低位字节偏移
    val mask0 = VecInit((0 until nBytes).map(i => i.U < txnSizes(0)))
                  .asUInt.rotateLeft(bottom)                   // 第一笔事务掩码 + 旋转
    val mask1 = VecInit((0 until nBytes).map(i => i.U < txnSizes(1)))
                  .asUInt.rotateLeft(bottom + txnSizes(0))     // 第二笔掩码 (从第一笔结束处开始)
    (mask0, mask1)
  }
}

/** BytemaskToBitmask: 字节掩码 → 位掩码
 *  bytemask 的每个 bit 代表一个字节, 展开为 8-bit (0x00 或 0xFF) */
object BytemaskToBitmask {
  def apply(bytemask: UInt): UInt = {
    VecInit(bytemask.asBools.map(Mux(_, 255.U(8.W), 0.U(8.W)))).asUInt
  }
}
