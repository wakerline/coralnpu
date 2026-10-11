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
import scala.collection.mutable.StringBuilder

import bus.TLULParameters

object MemoryRegionType extends ChiselEnum {
  val IMEM       = Value
  val DMEM       = Value
  val Peripheral = Value
  val External   = Value
}

class MemoryRegion(
  val memStart: Int,
  val memSize: Int,
  val memType: MemoryRegionType.Type
) {

  def contains(addr: UInt): Bool = {
    val addrWidth = addr.getWidth.W
    (addr >= memStart.U(addrWidth)) && (addr < memStart.U(addrWidth) + memSize.U(addrWidth))
  }

}

object MemoryRegions {
  val default = Seq(
    new MemoryRegion(0x0000000, 0x00002000, MemoryRegionType.IMEM),      // ITCM
    new MemoryRegion(0x0010000, 0x00008000, MemoryRegionType.DMEM),      // DTCM
    new MemoryRegion(0x0030000, 0x00001000, MemoryRegionType.Peripheral) // CSR
  )
  def highmem(itcmSizeKBytes: Int, dtcmSizeKBytes: Int) = Seq(
    // The DTCM and CSR base addresses are deliberately offset in `highmem`
    // to allow for varying size up to 1MB without affecting existing memory base addresses
    new MemoryRegion(0x00000000, itcmSizeKBytes * 1024, MemoryRegionType.IMEM), // ITCM
    new MemoryRegion(0x00100000, dtcmSizeKBytes * 1024, MemoryRegionType.DMEM), // DTCM
    new MemoryRegion(0x00200000, 0x00001000, MemoryRegionType.Peripheral)       // CSR
  )
}

object Parameters {
  val itcmSizeKBytesDefault = 8  // default itcm size for current IP design
  val dtcmSizeKBytesDefault = 32 // default dtcm size for current IP design
  val itcmSizeKBytesHighmem = 1024
  val dtcmSizeKBytesHighmem = 1024
  def apply(): Parameters   = {
    return new Parameters()
  }
  def apply(m: Seq[MemoryRegion]): Parameters = {
    return new Parameters(m)
  }
}

class Parameters(var m: Seq[MemoryRegion] = Seq(), val hartId: Int = 0, val xlen: Int = 32) {
  // Machine.
  val programCounterBits = xlen
  val instructionBits    = 32
  val instructionLanes   = 4

  // Enable extra logic for verification purposes.
  var enableVerification = false

  // TODO: It might seem intuitive to couple exposeDebugPorts and
  // enableVerification, as debug ports are only needed for verification.
  // However, coupling them is not trivial because enableVerification also
  // enables the full Retirement Buffer (ROB) tracking mode (mini = false).
  // Under configurations with RVV disabled but Float enabled (like core_mini_axi_sim),
  // the full ROB mode has hardware bugs/hangs (e.g. vector store waits and reset
  // oscillations). We still need the debug ports exposed for these targets to
  // generate instruction traces for riscv-dv co-simulation, but we must run
  // the ROB in mini mode (enableVerification = false) to avoid the hangs.
  // Thus, we keep these parameters decoupled.
  // Expose the debug/trace ports at the module boundary.
  var rawExposeDebugPorts = false

  // Expose ports if explicitly requested, or automatically if full verification is enabled.
  def shouldExposeDebugPorts: Boolean = { rawExposeDebugPorts || enableVerification }

  // Enable RVV. This conforms to the RVV1.0 specification.
  var enableRvv     = false
  val rvvVlen       = 128
  def rvvVlenb: Int = { rvvVlen / 8 }
  // indexing a single byte within one vector register
  def rvvByteIndexWidth: Int = log2Ceil(rvvVlenb)
  // Number of retirement lanes from RVV core (4 in synthesis, 6 in verification with decoder retirement)
  def rvvRetireLanes: Int = if (enableVerification) instructionLanes + 2 else instructionLanes

  // Enable VME (Zvt) non-tile state and mset* instructions. Requires enableRvv.
  var enableVme  = false
  val vmeTeRatio = 8
  def vmeTe: Int = { rvvVlen / vmeTeRatio }

  // Zvvm build options. Zvvmm is the common IME base in CoralNPU; the
  // optional floating-point and tile-memory families may be selected
  // independently on top of it. These build switches do not by themselves
  // constitute an architectural extension declaration.
  var enableZvvmm    = false
  var enableZvvfmm   = false
  var enableZvvmtls  = false
  var enableZvvmttls = false
  // Floating-point partial-sum model disclosed by the IME implementation.
  // 0 selects exact partial-product reduction; 1 selects the separately
  // specified non-exact partial-sum algorithm. The FP datapath consumes this
  // parameter only when Zvvfmm is enabled.
  var imeFpPsm = 0
  // Physical IME execution profile. The architectural result is independent
  // of these values.  The default is the minimum-area 1x1x1 baseline;
  // supported accelerated profiles use 2x2x1 or 4x4x1 integer arrays.  FP/MX
  // remains single-lane until a separately disclosed parallel reduction is
  // available.
  var imeMPar     = 1
  var imeNPar     = 1
  var imeKPar     = 1
  // Select the ordinary-integer accumulator/result-path experiment.  Keep the
  // correctness-first implementation as the default REF configuration; the
  // switch does not alter FP/MX execution.
  var imeIntOpt    = false
  // Stage-2 ordinary-integer streaming experiment.  It builds on the
  // Stage-1 lane-local accumulator/result path and remains independently
  // selectable so REF, Stage-1 and Stage-2 are reproducible configurations.
  var imeIntStream = false
  // Stage-3 ordinary-integer operand-delivery experiment.  The optimized
  // selector relies on the Stage-2 streaming geometry and remains separately
  // selectable for an exact Stage-2/Stage-3 ablation.
  var imeOdnOpt = false
  // Stage-42 result-index experiment.  The optimized ODN already computes
  // the architectural C element's physical index; carry that index with the
  // PE packet so the direct result packer does not repeat the tile mapping.
  // Keep a separate, default-off switch for an exact REF/OPT ablation.
  var imeResultIndexOpt = false
  // Stage-42 integer PE input experiment.  Share the runtime EEW/sign
  // extension once per physical A row and B column instead of repeating it
  // in every output lane.  The option preserves the existing mulbulk pipeline
  // and is restricted to the already verified streaming integer profile.
  var imeIntPreextendOpt = false
  // Stage-42 shared-LSU Tile exact-data experiment.  Reuse the already
  // elaborated lead-relative normal window for the at-most-four bytes of one
  // SEW8/16/32 Tile element instead of rebuilding a 128-cell data mux.  This
  // affects no address, request-count, fault, restart, or snapshot state.
  var imeTileExactWindowOpt = false
  // Stage-32 operand-snapshot turnaround.  When enabled, the IME consumes
  // the current VRF response and issues the next tagged register request in
  // the same cycle.  The default retains the Stage-31 one-request-at-a-time
  // behavior and the option does not add an architectural state element.
  var imeFetchPipeline = false
  // CS-IME v2 ordered FP/FP-input-MX execution.  The option interleaves
  // independent output cells from one already-snapshotted macro while keeping
  // each cell's K reduction order unchanged.  Integer-input MX remains on the
  // reference path.
  var imeFpOrdered = false
  def imeIntLanes: Int = imeMPar * imeNPar * imeKPar
  // The verified FP/MX profile has one lane so its disclosed reduction order
  // cannot be changed by an elaboration option.
  def imeFpLanes: Int = 1

  def validateFeatureDependencies(): Unit = {
    require(!enableVme || enableRvv, "enableVme requires enableRvv")
    require(!enableZvvmm || enableRvv, "enableZvvmm requires enableRvv")
    require(!enableZvvfmm || enableZvvmm, "enableZvvfmm requires enableZvvmm")
    require(!enableZvvfmm || enableFloat, "enableZvvfmm requires enableFloat")
    require(!enableZvvmtls || enableZvvmm, "enableZvvmtls requires enableZvvmm")
    require(!enableZvvmttls || enableZvvmm, "enableZvvmttls requires enableZvvmm")
    require(imeFpPsm == 0 || imeFpPsm == 1, "imeFpPsm must be 0 or 1")
    require(imeFpPsm == 0 || enableZvvfmm, "imeFpPsm=1 requires enableZvvfmm")
    require(Seq(1, 2, 4).contains(imeMPar), "imeMPar must be 1, 2, or 4")
    require(Seq(1, 2, 4).contains(imeNPar), "imeNPar must be 1, 2, or 4")
    require(Seq(1, 2, 4).contains(imeKPar), "imeKPar must be 1, 2, or 4")
    require(!imeIntOpt || enableZvvmm, "imeIntOpt requires enableZvvmm")
    require(!imeIntStream || imeIntOpt, "imeIntStream requires imeIntOpt")
    require(!imeOdnOpt || imeIntStream, "imeOdnOpt requires imeIntStream")
    require(!imeResultIndexOpt || imeOdnOpt, "imeResultIndexOpt requires imeOdnOpt")
    require(!imeIntPreextendOpt || imeIntStream, "imeIntPreextendOpt requires imeIntStream")
    require(
      !imeTileExactWindowOpt || enableZvvmtls || enableZvvmttls,
      "imeTileExactWindowOpt requires enableZvvmtls or enableZvvmttls"
    )
    require(!imeFetchPipeline || enableZvvmm, "imeFetchPipeline requires enableZvvmm")
    require(!imeFpOrdered || enableZvvfmm, "imeFpOrdered requires enableZvvfmm")
    require(!(enableVme && enableZvvmm), "enableVme and enableZvvmm are mutually exclusive")
  }

  def useRetirementBuffer: Boolean = { enableVerification }

  // Scalar Floating point
  var enableFloat      = false
  var enableZfbfmin    = false
  var enableVectorBf16 = false
  // Use the Div/Sqrt module from PULP instead of E906.
  // It is smaller, but has small rounding errors.
  val floatPulpDivsqrt = 0

  val scalarRegCount                = 32
  val scalarRegCountWidth           = log2Ceil(scalarRegCount)
  val floatRegCount                 = 32
  val floatRegfileBaseAddr          = 32
  val floatRegCountWidth            = log2Ceil(floatRegCount)
  val rvvRegfileBaseAddr            = 64
  val rvvRegCount                   = 32
  val rvvRegCountWidth              = log2Ceil(rvvRegCount)
  val retirementBufferSize          = 16
  val retirementLanes               = 8
  def retirementBufferIdxWidth: Int = {
    val activeFloatRegCount = (if (enableFloat) { floatRegCount }
                               else { 0 })
    // +2 is for the "no write" and "store" dummy registers.
    log2Ceil(scalarRegCount + activeFloatRegCount + rvvRegCount + 2)
  }

  // L0ICache Fetch unit.
  var enableFetchL0   = true
  val fetchCacheBytes = 1024

  // Scalar Core Fetch bus.
  val fetchAddrBits        = programCounterBits // do not change
  var fetchDataBits        = 256                // do not change
  def fetchInstrSlots: Int = {
    assert(fetchDataBits   % 32 == 0)
    assert(instructionBits % 32 == 0)
    assert(fetchDataBits   % instructionBits == 0)
    fetchDataBits / instructionBits
  }

  // Scalar Core Load Store Unit bus.
  val lsuAddrBits         = programCounterBits // do not change
  var lsuDataBits         = 256
  def lsuDataBytes: Int   = { lsuDataBits / 8 }
  val lsuDelayPipelineLen = 1
  // When increasing bus width, this can be limited to improve timing.
  val lsuStrictWindowBytes = lsuDataBytes
  def dbusSize             = log2Ceil(lsuDataBytes + 1)
  def dbusOffsetBits       = log2Ceil(lsuDataBytes)
  def dbusRowAddrBits      = lsuAddrBits - dbusOffsetBits

  // TCM Size Configuration
  var itcmSizeKBytes = Parameters.itcmSizeKBytesDefault
  var dtcmSizeKBytes = Parameters.dtcmSizeKBytesDefault

  // [Internal] L1ICache interface.
  val l1islots          = 256
  val l1iassoc          = 4
  val axi0IdBits        = 4 // (1x banks, 4 bits unused)
  val axi0AddrBits      = 32
  def axi0DataBits: Int = { fetchDataBits }

  // [Internal] L1DCache interface.
  val l1dslots          = 256 // (x2 banks)
  val l1dassoc          = 4
  val axi1IdBits        = 4   // (x2 banks, 3 bits unused)
  val axi1AddrBits      = 32
  def axi1DataBits: Int = { lsuDataBits }

  // [Internal] TCM[Vector,Scalar] interface.
  var axi2IdBits         = 6
  val axi2AddrBits       = 32
  def axi2DataBits: Int  = { lsuDataBits } // vectorBits
  def axi2DataBytes: Int = { axi2DataBits / 8 }

  // If set, itcmMemoryFile should contain a path to a Verilog mem file.
  // NB: Only used by CoreAxi
  val itcmMemoryFile = ""

  val csrInCount  = 13
  val csrOutCount = 9

  def toTLUL(): TLULParameters = {
    new TLULParameters(
      dataBits = axi2DataBits,
      addrBits = axi2AddrBits,
      idBits = axi2IdBits
    )
  }
}

import scala.reflect.runtime.{universe => ru}
object EmitParametersHeader {
  def apply(p: Parameters): String = {
    val mirror         = ru.runtimeMirror(ru.getClass.getClassLoader)
    val instanceMirror = mirror.reflect(p)
    val symbol         = instanceMirror.symbol
    val typeSym        = symbol.toType
    val fields         = typeSym.decls.collect {
      case t: (ru.TermSymbol @unchecked) if t.isVal || t.isVar => t
    }

    var builder = new StringBuilder()
    builder = builder.append("#ifndef CORALNPU_PARAMETERS_H_\n")
    builder = builder.append("#define CORALNPU_PARAMETERS_H_\n")
    builder = builder.append("\n")
    builder = builder.append("#include <stdbool.h>\n")
    builder = builder.append("\n")
    fields.foreach { x =>
      val fieldMirror = instanceMirror.reflectField(x.asTerm)
      val fieldType   = x.asTerm.typeSignature
      val value       = fieldMirror.get
      val ctype       = fieldType match {
        case t if t =:= ru.typeOf[Int]     => Some("int")
        case t if t =:= ru.typeOf[Boolean] => Some("bool")
        case _                             => None
      }
      if (ctype != None) {
        builder = builder.append(s"#define KP_${x.name} ${value}\n")
      }
    }
    // TODO(atv): See if we can improve the reflection above to execute
    // the methods for our dynamic parameters.
    builder = builder.append(s"#define KP_dbusSize ${p.dbusSize}\n")
    builder = builder.append(s"#define KP_useRetirementBuffer ${p.useRetirementBuffer}\n")
    builder = builder.append(s"#define KP_retirementBufferIdxWidth ${p.retirementBufferIdxWidth}\n")
    builder = builder.append(s"#define KP_exposeDebugPorts ${p.shouldExposeDebugPorts}\n")
    builder = builder.append("#endif\n")
    builder.result()
  }
}
