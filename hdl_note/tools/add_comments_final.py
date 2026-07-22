#!/usr/bin/env python3
"""
最终版注释添加脚本 — 保留 license block，只处理尚未详细注释的文件。
"""
import os, sys

BASE = "/home/wangyy/002_research/coralnpu/hdl_note"

# 文件描述表
DESC = {}
DESC.update({
    # coralnpu/ 顶层
    "CoreAxi.scala": ("Core的AXI总线封装 — 完整CoralNPU AXI系统顶层(RawModule)", "时钟/复位: RstSync→ClockGate→Core\nITCM/DTCM: TCM128+SRAM+FabricArbiter(3口:core/debug/axi_slave)\nCSR: CoreCSR, FabricMux第三个端口\nibus→ITCM快速或IBus2Axi→AXI外部(地址范围判断)\nebus→DBus2Axi→AXI Master\nDebug: dmReqArbiter+inflight Queue路由请求/响应"),
    "CoreTlul.scala": ("Core的TileLink-UL总线封装", "通过TLUL2Axi+Axi2TLUL双桥接适配到OpenTitan TL-UL, 结构类似CoreAxi"),
    "CoreAxiCSR.scala": ("CoreAxi的CSR子模块(CoreCSR+CoreCsrAddrs)", "CoreCsrAddrs: 调试寄存器地址定义\nCoreCSR: 片上CSR(Fabric接口), 复位/时钟门控/PC启动/调试寄存器"),
    "RetirementBuffer.scala": ("指令退役缓冲区 — 跟踪在飞指令，保证按序提交", "指令生命周期: Dispatched→Completed→Retired\n跟踪标量/浮点/向量写回+store完成+异常\nmini模式: 简化版用于非验证省面积"),
    "RvviTrace.scala": ("RVVI验证跟踪接口(RISC-V Verification Interface)", "GenerateRvviTraceSource: 动态生成SV黑盒\nRvviTraceBlackBox: Chisel BlackBox+内联SV\nRvviTrace: 退役缓冲→RVVI标准格式"),
    "TCM.scala": ("紧耦合内存(TCM)的Chisel封装 — TCM128", "128-bit宽TCM, 封装Sram_Nx128 BlackBox\ntcmEntries=tcmSizeBytes/16, 按子条目粒度读写"),
    "L1ICache.scala": ("L1指令缓存(8KB, 4路组相联)", "4-way set-associative, 256槽→64组\nCache line: 256-bit(32B)\n地址: Tag[31:11]|Index[10:5]|Offset[4:0]"),
    "L1DCache.scala": ("L1数据缓存(双bank, 每bank 256槽)", "双bank并行访问, 通过DBusIO与LSU对接"),
    "DBus2Axi.scala": ("数据总线(DBus)→AXI4 Master协议转换", "DBus2AxiV2: 三状态机(waddr/wdata/wresp)写路径+读路径\n读数据RegNext延迟1拍\n故障检测AXI RESP"),
    "IBus2Axi.scala": ("取指总线(IBus)→AXI4读协议转换", "单地址单数据缓冲: 地址不变→缓存返回, 改变→新AXI读"),
    "AxiSlave.scala": ("AXI Slave→Fabric协议转换", "外部AXI4→内部Fabric\n支持FIXED/INCR/WRAP突发, 地址自动递增"),
    "MemorySize.scala": ("内存大小辅助类", "bytes↔kBytes/KBytes转换, fromBytes/fromKBytes/fromMBytes工厂"),
    "Sram.scala": ("SRAM BlackBox封装+AxiBurstType枚举", "Sram_Nx128: 128-bit SRAM BlackBox\nSRAM: FabricIO封装"),
    "SramNx128.scala": ("Sram_Nx128 BlackBox具体实现", ""),
    "SRAM.scala": ("SRAM模块FabricIO封装", ""),
    "Library.scala": ("CoralNPU专用硬件工具库", "MuxOR/MuxUpTo1H/MakeValid/MakeInvalid等硬件原语\nCoralNPURRArbiter: Round-Robin仲裁器"),
    "RstSync.scala": ("复位同步器Chisel封装", "封装verilog/RstSync.sv, 异步复位同步释放"),
    "ClockGate.scala": ("时钟门控Chisel封装", "封装verilog/ClockGate.sv, enable控制+te测试旁路"),
})

# scalar/ 标量核
DESC.update({
    "SCore.scala": ("标量RISC-V核心顶层 — 组织完整流水线", "Fetch→DispatchV2→ALU/BRU/MLU/DVU/LSU/FPU→RetirementBuffer\n含Regfile/CSR/FaultManager/可选FloatCore/可选RvvCore\nIBus仲裁: LSU(优先)+Fetch共享"),
    "Fetch.scala": ("取指单元 — 含L0 ICache(1KB直接映射)", "L0 Cache: 32索引×1路×256-bit line\n预译码: JAL/RET/Bxx分支预测\n分支匹配: BranchMatchDe(译码)/BranchMatchEx(执行)\n4指令/lane输出, 含brchFwd"),
    "Decode.scala": ("RISC-V指令译码+DispatchV2多lane发射", "32-bit→控制信号/opcode/funct3/funct7/rd/rs1/rs2\nDispatchV2: 寄存器依赖check/LSU/MLU/DVU结构冒险检测"),
    "Alu.scala": ("算术逻辑单元(ALU)", "RV32I: ADD/SUB/SLT/SLTU/XOR/OR/AND/SLL/SRL/SRA, 单周期"),
    "Bru.scala": ("分支解析单元(BRU)", "条件分支: BEQ/BNE/BLT/BGE/BLTU/BGEU\n无条件: JAL/JALR\n目标地址计算+BranchTakenIO反馈取指"),
    "Mlu.scala": ("乘法单元(MLU)", "RV32M: MUL/MULH/MULHSU/MULHU, 多周期, 1个MLU供4lane共享"),
    "Dvu.scala": ("除法单元(DVU)", "RV32M: DIV/DIVU/REM/REMU, 多周期, 仅lane0使用"),
    "Lsu.scala": ("Load/Store单元(LSU) — 最复杂的执行单元", "LsuOp枚举: 标量(LB/LH/LW/SB/SH/SW/FLOAT)+向量(VLOAD_UNIT/STRIDED/INDEXED等)\nLsuCmd→LsuUOp→LsuSlot(16字节槽): 管理访存生命周期\n地址: ComputeStridedAddrs(跨步)/ComputeIndexedAddrs(索引)\n数据路径: IBUS(ITCM)/DBUS(DTCM)/EXTERNAL(AXI)三选一"),
    "Fpu.scala": ("标量浮点单元(FPU)", "RV32F/D+Zfbfmin(BF16), 通过FRegfile访问浮点寄存器, 与FloatCore交互"),
    "Csr.scala": ("控制状态寄存器(CSR)单元", "RISC-V CSR: mstatus/mcause/mepc/mtvec/mie/mip等\nCSRRW/CSRRS/CSRRC操作, 中断/异常响应"),
    "Regfile.scala": ("标量整数寄存器文件(32×32-bit)", "x0恒为0, 多lane并行读写+Scoreboard跟踪RAW依赖"),
    "FRegfile.scala": ("浮点寄存器文件(32×FP32)", "3读+2写端口, 支持调试访问+Scoreboard"),
    "Debug.scala": ("RISC-V调试模块(Debug Module Spec 0.13)", "DebugModule: halt/resume/CSR/寄存器读写\n含ITCM/DTCM调试FabricIO"),
    "FaultManager.scala": ("故障管理器 — 异常收集和仲裁", "收集源: 译码/执行/LSU/RVV异常, 优先级仲裁, 输出mepc/mtval/mcause"),
    "UncachedFetch.scala": ("无缓存取指单元", "enableFetchL0=false时使用, 直接IBus访问"),
})

# rvv/ + float/
DESC.update({
    "RvvCore.scala": ("RVV向量核心Chisel封装", "封装Verilog RVV Backend\nRvvCoreIO: inst/rs/frs/rd/lsu2rvv/rvv2lsu/configState"),
    "RvvDecode.scala": ("RVV向量指令译码", "V扩展指令解析, 生成向量微操作"),
    "RvvAlu.scala": ("RVV向量ALU Chisel封装", ""),
    "RvvInterface.scala": ("RVV向量核接口定义", "RvvCoreIO/RvvConfigState/Rvv2Lsu/Lsu2Rvv"),
    "FloatCore.scala": ("浮点运算核心", "FP32 FMA(融合乘加)+Div+Sqrt\n可选PULP或E906 Div/Sqrt"),
    "FloatCoreInterface.scala": ("浮点核心IO接口", ""),
})

# bus/ 总线
DESC.update({
    "Axi.scala": ("AXI4总线协议Bundle定义", "5通道: WriteAddr/WriteData/WriteResp+ReadAddr/ReadData\nAxiResponseType: OKAY/EXOKAY/SLVERR/DECERR"),
    "TileLinkUL.scala": ("TileLink-Uncached Lightweight总线", "OpenTitan标准TL-UL, TLULParameters配置"),
    "Axi2TLUL.scala": ("AXI→TL-UL协议桥", "AXI4 Master→TL-UL事务转换"),
    "TLUL2Axi.scala": ("TL-UL→AXI协议桥", "TL-UL→AXI4 Master事务转换"),
    "Clint.scala": ("CLINT核内中断控制器", "RISC-V: timer中断+mtime/mtimecmp, software中断+msip"),
    "Plic.scala": ("PLIC平台级中断控制器", "外部中断优先级仲裁+分发"),
    "GPIO.scala": ("GPIO控制器", "通用IO, TL-UL总线访问"),
    "DmaEngine.scala": ("DMA引擎", "内存到内存搬运, AXI/TL-UL"),
    "SpiMaster.scala": ("SPI Master控制器", ""),
    "Spi2TLUL.scala": ("SPI→TL-UL桥v1", ""),
    "Spi2TLULV2.scala": ("SPI→TL-UL桥v2", ""),
    "TlulFifoAsync.scala": ("TL-UL异步FIFO(跨时钟域)", ""),
    "TlulFifoSync.scala": ("TL-UL同步FIFO", ""),
    "TlulSocket1N.scala": ("TL-UL 1:N分发器", "地址路由, 1主→N从"),
    "TlulSocketM1.scala": ("TL-UL M:1汇聚器", "仲裁, M主→1从"),
    "TlulWidthBridge.scala": ("TL-UL位宽桥接", "不同位宽TL-UL链路转换"),
    "TlulIntegrity.scala": ("TL-UL完整性校验", "ECC保护+验证"),
    "TlulIdRemapper.scala": ("TL-UL ID重映射", "跨桥接时事务ID重映射"),
    "TlulToSram.scala": ("TL-UL→SRAM适配器", "TL-UL读写→SRAM时序"),
})

# common/ 通用
DESC.update({
    "Fifo.scala": ("通用FIFO队列", "Fifo: Queue封装, FifoWithCnt: 带计数器"),
    "FifoX.scala": ("可扩展FIFO(FifoX)", "深度X可配置"),
    "FifoXe.scala": ("可扩展FIFO(带错误)", ""),
    "FifoIxO.scala": ("I输入X输出FIFO", ""),
    "FIFOState.scala": ("FIFO状态跟踪", "读写指针+空满"),
    "CircularBufferMulti.scala": ("多读者环形缓冲区", "多读端口环形缓冲"),
    "CoralNPUArbiter.scala": ("Round-Robin仲裁器", "公平轮转+chosen"),
    "Fma.scala": ("融合乘加(FMA)", "FP32: a*b+c"),
    "Fp.scala": ("浮点运算原语", "Fp32: FP32硬件Bundle+IEEE754编解码"),
    "IDiv.scala": ("整数除法器", "流水线, 有符号/无符号"),
    "MathUtil.scala": ("数学工具函数", "Ctz/PopCount等封装"),
    "Aligner.scala": ("数据对齐器", "非对齐→目标边界"),
    "ScatterGather.scala": ("Scatter/Gather访存", "向量分散写/聚集读地址"),
    "Slice.scala": ("位切片工具", "宽数据→子元素"),
    "InstructionBuffer.scala": ("指令缓冲", "取指→译码弹性缓冲"),
    "IndexAllocator.scala": ("索引分配器", "有限资源(ROB槽位)分配回收"),
    "Library.scala": ("通用硬件库(common)", "编解码/流水线寄存器/Valid处理"),
    "SvGenerationUtils.scala": ("SystemVerilog生成工具", "生成SV wrapper"),
})

# soc/ + peripherals/
DESC.update({
    "SoCChiselConfig.scala": ("SoC顶层配置", "外设地址映射+中断分配"),
    "CoralNPUChiselSubsystem.scala": ("CoralNPU芯片子系统", "Core+总线矩阵+外设顶层"),
    "CoralNPUXbar.scala": ("CoralNPU交叉开关", "TL-UL多主多从Crossbar"),
    "CrossbarConfig.scala": ("交叉开关配置", "端口映射+地址路由"),
    "SoCRecords.scala": ("SoC记录类型定义", "SoC级Bundle"),
    "TlulSram.scala": ("TL-UL SRAM(SoC级)", "TL-UL总线SRAM"),
    "PeripheralInterface.scala": ("外设接口定义", "通用外设Bundle"),
})

# Verilog
VERILOG = {
    "ClockGate.sv": ("时钟门控", "基于锁存器无毛刺门控"),
    "RstSync.sv": ("复位同步器", "2级FF, 异步复位同步释放"),
    "Sram.v": ("SRAM行为模型", "1rw+1rwm"),
    "adder.sv": ("多宽度加法器", "8/16/32/64/128-bit"),
    "arb_round_robin.sv": ("Round-Robin仲裁器", ""),
    "barrel_shifter.sv": ("桶形移位器", "左/右/算术/逻辑"),
    "cdffr.sv": ("带使能+复位D触发器", ""),
    "compressor_3_2.sv": ("3:2压缩器(CSA)", ""),
    "compressor_4_2.sv": ("4:2压缩器(Wallace)", ""),
    "dff.sv": ("基础D触发器", ""),
    "edff_2d.sv": ("双使能D触发器(2周期)", ""),
    "edff.sv": ("带使能D触发器", ""),
    "fifo_flopped.sv": ("触发器FIFO(1w1r)", ""),
    "fifo_flopped_2w2r.sv": ("触发器FIFO(2w2r)", ""),
    "fifo_flopped_4w2r.sv": ("触发器FIFO(4w2r)", ""),
    "handshake_ff.sv": ("握手触发器(valid/ready)", ""),
    "handshake_multi_fifo.sv": ("多通道握手FIFO", ""),
    "multi_fifo.sv": ("多通道FIFO", ""),
    "openFifo4_flopped_ptr.sv": ("开放FIFO(深度4)", ""),
    "openFifo8_flopped_2w2r.sv": ("开放FIFO(深度8,2w2r)", ""),
    "RvvCore.sv": ("RVV向量核心顶层", "FrontEnd+Backend"),
    "RvvFrontEnd.sv": ("RVV前端", "指令缓冲+预译码"),
    "rvv_backend.sv": ("RVV后端顶层", "执行引擎"),
    "rvv_backend_alu.sv": ("向量ALU顶层", ""),
    "rvv_backend_decode.sv": ("向量指令译码", "uOP生成"),
    "rvv_backend_dispatch.sv": ("向量uOP发射", "重命名+结构冒险"),
    "rvv_backend_retire.sv": ("向量指令退役", "按序提交+写回仲裁"),
    "rvv_backend_rob.sv": ("向量重排序缓冲(ROB)", ""),
    "rvv_backend_vrf.sv": ("向量寄存器文件(VRF)", "128-bit×32"),
    "rvv_backend_lsu_remap.sv": ("向量LSU地址重映射", "Scatter/Gather"),
    "rvv_backend_mulmac.sv": ("向量乘法/乘累加", "MAC"),
    "rvv_backend_div.sv": ("向量除法", ""),
    "rvv_backend_fma.sv": ("向量FMA", ""),
    "rvv_backend_pmtrdt.sv": ("向量置换/归约", ""),
    "rvv_backend_arb.sv": ("向量后端仲裁器", "执行→写回"),
}


def read_file(fpath):
    with open(fpath, 'r') as f:
        return f.read(), f.readlines()

def already_has_good_comments(content):
    """检测已有详细中文注释: 包含 ====== 和 '文件:' """
    return "======" in content and "文件:" in content

def find_license_end(lines):
    """找到 license 块结束位置 (返回行号, 不含)"""
    for i, line in enumerate(lines):
        if 'limitations under the License' in line:
            return i + 1
    return 0

def process_scala(fpath, title, detail):
    content, lines = read_file(fpath)
    if already_has_good_comments(content):
        return "skip"

    fname = os.path.basename(fpath)
    lic_end = find_license_end(lines)

    # 找 package 行位置
    pkg_idx = None
    for i in range(lic_end, len(lines)):
        if lines[i].strip().startswith('package '):
            pkg_idx = i
            break

    # 构建头部注释
    detail_str = "\n".join(f"// {line}" if line else "//" for line in detail.strip().split("\n")) if detail else ""
    header = f"""// ============================================================================
// 文件: {fname}
// 功能: {title}
{f"//\n{detail_str}\n" if detail_str else ""}// ============================================================================"""

    # 组装新内容: header + license + 从 package 开始的代码
    new_lines = [header, '']
    new_lines.extend(lines[:lic_end])  # license block
    new_lines.append('')
    if pkg_idx is not None:
        new_lines.extend(lines[pkg_idx:])
    else:
        new_lines.extend(lines[lic_end:])

    with open(fpath, 'w') as f:
        f.write('\n'.join(new_lines))
    return "ok"

def process_verilog(fpath, title, detail):
    content, lines = read_file(fpath)
    if already_has_good_comments(content):
        return "skip"

    fname = os.path.basename(fpath)
    lic_end = find_license_end(lines)

    # 找 module/`include 行
    start = lic_end
    for i in range(lic_end, len(lines)):
        s = lines[i].strip()
        if s.startswith('module ') or s.startswith('(*') or s.startswith('`include') or s.startswith('`define'):
            start = i
            break

    detail_str = "\n".join(f"// {line}" if line else "//" for line in detail.strip().split("\n")) if detail else ""
    header = f"""// ============================================================================
// 文件: {fname}
// 功能: {title}
{f"//\n{detail_str}\n" if detail_str else ""}// ============================================================================"""

    new_lines = [header, '']
    new_lines.extend(lines[:lic_end])
    new_lines.append('')
    new_lines.extend(lines[start:])

    with open(fpath, 'w') as f:
        f.write('\n'.join(new_lines))
    return "ok"


def main():
    ok, skip = 0, 0
    # Chisel files
    for root, dirs, files in os.walk(os.path.join(BASE, 'chisel', 'src')):
        for fname in sorted(files):
            if not fname.endswith('.scala'): continue
            if 'Test' in fname or 'Spec' in fname or 'Testbench' in fname or 'TestUtils' in fname: continue
            fpath = os.path.join(root, fname)
            desc = DESC.get(fname, (f"{fname} — CoralNPU RTL设计文件", ""))
            r = process_scala(fpath, desc[0], desc[1])
            if r == "ok": ok += 1
            else: skip += 1

    # Verilog files
    for root, dirs, files in os.walk(os.path.join(BASE, 'verilog')):
        for fname in sorted(files):
            if not (fname.endswith('.sv') or fname.endswith('.v')): continue
            if '_tb' in fname or '/sve/' in root.replace(BASE, ''): continue
            fpath = os.path.join(root, fname)
            desc = VERILOG.get(fname, (f"{fname} — Verilog RTL模块", ""))
            r = process_verilog(fpath, desc[0], desc[1])
            if r == "ok": ok += 1
            else: skip += 1

    print(f"添加: {ok}, 跳过(已有注释): {skip}")

if __name__ == '__main__':
    main()
