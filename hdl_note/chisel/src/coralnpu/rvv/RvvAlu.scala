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
// RvvAlu.scala — RVV 向量 ALU 操作码枚举 (RvvAluOp)
// ============================================================================

package coralnpu.rvv

import chisel3._

object RvvAluOp extends ChiselEnum {
  // TODO(davidgao): 这些枚举值只在内部使用，后续可按后端编码需求调整。
  // 普通整数加减。
  val VADD  = Value
  val VSUB  = Value
  val VRSUB = Value

  // 有符号/无符号最小最大值。
  val VMINU = Value
  val VMIN = Value
  val VMAXU = Value
  val VMAX = Value

  // 按位逻辑运算。
  val VAND = Value
  val VOR = Value
  val VXOR = Value

  // gather/索引重排类操作。
  val VRGATHER = Value
  val VRGATHEREI16 = Value

  // slide 上移/下移操作。
  val VSLIDEUP = Value
  val VSLIDEDOWN = Value

  // 带进位/借位的加减，以及对应 mask 生成。
  val VADC = Value
  val VMADC = Value
  val VSBC = Value
  val VMSBC = Value

  // mask merge 和向量搬运。
  val VMERGE = Value
  val VMV = Value

  // 比较生成 mask 的操作。
  val VMSEQ = Value
  val VMSNE = Value
  val VMSLTU = Value
  val VMSLT = Value
  val VMSLEU = Value
  val VMSLE = Value
  val VMSGTU = Value
  val VMSGT = Value

  // 饱和加减。
  val VSADDU = Value
  val VSADD = Value
  val VSSUBU = Value
  val VSSUB = Value

  // 定点饱和乘法。
  val VSMUL = Value

  // 整个向量寄存器组搬运。
  val VMV1R = Value
  val VMV2R = Value
  val VMV4R = Value
  val VMV8R = Value

  // 左移、逻辑/算术右移、饱和右移、窄化右移。
  val VSLL = Value
  val VSRL = Value
  val VSRA = Value
  val VSSRL = Value
  val VSSRA = Value
  val VNSRL = Value
  val VNSRA = Value

  // 窄化 clip 操作。
  val VNCLIPU = Value
  val VNCLIP = Value
}

// RVV 指令是否合法需要结合当前向量配置才能完全判断。
// 这里的 S1DecodedInstruction 只表示已经通过与配置无关的检查，
// 真正执行前还需要用 vtype/vl/vstart 等配置再次交叉检查。
class RvvS1DecodedInstruction extends Bundle {
  // 后端 ALU 使用的内部操作码。
  val op = RvvAluOp()
}
