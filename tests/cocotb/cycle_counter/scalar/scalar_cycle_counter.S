/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

.option norvc

.equ REPEAT_COUNT, 64
.equ NUM_TESTS, 100

.section .data
.align 4
.global cycle_counter_num_tests
cycle_counter_num_tests:
  .word NUM_TESTS
.global cycle_counter_repeat_count
cycle_counter_repeat_count:
  .word REPEAT_COUNT
.global cycle_counter_overhead_cycles_lo
cycle_counter_overhead_cycles_lo:
  .word 0
.global cycle_counter_overhead_cycles_hi
cycle_counter_overhead_cycles_hi:
  .word 0
.global cycle_counter_serial_barrier_cycles_lo
cycle_counter_serial_barrier_cycles_lo:
  .word 0
.global cycle_counter_serial_barrier_cycles_hi
cycle_counter_serial_barrier_cycles_hi:
  .word 0
.global cycle_counter_cycles_lo
cycle_counter_cycles_lo:
  .zero NUM_TESTS * 4
.global cycle_counter_cycles_hi
cycle_counter_cycles_hi:
  .zero NUM_TESTS * 4
.global cycle_counter_instret_lo
cycle_counter_instret_lo:
  .zero NUM_TESTS * 4
.global cycle_counter_instret_hi
cycle_counter_instret_hi:
  .zero NUM_TESTS * 4

.section .data
.align 4
scalar_load_data:
  .word 0x3f800000
  .word 0x40000000
  .word 0x40400000
  .word 0x40800000
scalar_store_data:
  .zero 16
scalar_trap_scratch:
  .zero 4

.section .text
.global main

.macro READ_COUNTER csrlo, csrhi, lo, hi, tmp
1:
  csrr \hi, \csrhi
  csrr \lo, \csrlo
  csrr \tmp, \csrhi
  bne \hi, \tmp, 1b
.endm

.macro SUB64 endlo, endhi, startlo, starthi, outlo, outhi, tmp
  sub \outlo, \endlo, \startlo
  sltu \tmp, \endlo, \startlo
  sub \outhi, \endhi, \starthi
  sub \outhi, \outhi, \tmp
.endm

.macro STORE_RESULT base, idx, lo, hi
  la t6, \base\()_lo
  sw \lo, (\idx * 4)(t6)
  la t6, \base\()_hi
  sw \hi, (\idx * 4)(t6)
.endm

.macro SERIAL_BARRIER
  fence
  csrr s9, mcycle
  addi s9, s9, 0
.endm

.macro MEASURE idx, body:vararg
  .global cycle_counter_test_\idx\()_start
  .global cycle_counter_test_\idx\()_end
cycle_counter_test_\idx\()_start:
  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  READ_COUNTER minstret, minstreth, t3, t4, t5
  .rept REPEAT_COUNT
    \body
    SERIAL_BARRIER
  .endr
  READ_COUNTER minstret, minstreth, s4, s5, s6
  READ_COUNTER mcycle, mcycleh, s7, s8, s9
  SUB64 s7, s8, t0, t1, s10, s11, t6
  STORE_RESULT cycle_counter_cycles, \idx, s10, s11
  SUB64 s4, s5, t3, t4, s10, s11, t6
  STORE_RESULT cycle_counter_instret, \idx, s10, s11
cycle_counter_test_\idx\()_end:
.endm

.macro MEASURE_TAKEN_BRANCH idx, op
  .global cycle_counter_test_\idx\()_start
  .global cycle_counter_test_\idx\()_end
cycle_counter_test_\idx\()_start:
  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  READ_COUNTER minstret, minstreth, t3, t4, t5
  li s6, REPEAT_COUNT
.Lbranch_loop_\@:
  \op x0, x0, .Lbranch_target_\@
  nop
.Lbranch_target_\@:
  SERIAL_BARRIER
  addi s6, s6, -1
  bnez s6, .Lbranch_loop_\@
  READ_COUNTER minstret, minstreth, s4, s5, s6
  READ_COUNTER mcycle, mcycleh, s7, s8, s9
  SUB64 s7, s8, t0, t1, s10, s11, t6
  STORE_RESULT cycle_counter_cycles, \idx, s10, s11
  SUB64 s4, s5, t3, t4, s10, s11, t6
  STORE_RESULT cycle_counter_instret, \idx, s10, s11
cycle_counter_test_\idx\()_end:
.endm

.macro MEASURE_JAL idx
  .global cycle_counter_test_\idx\()_start
  .global cycle_counter_test_\idx\()_end
cycle_counter_test_\idx\()_start:
  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  READ_COUNTER minstret, minstreth, t3, t4, t5
  li s6, REPEAT_COUNT
.Ljal_loop_\@:
  jal x0, .Ljal_target_\@
  nop
.Ljal_target_\@:
  SERIAL_BARRIER
  addi s6, s6, -1
  bnez s6, .Ljal_loop_\@
  READ_COUNTER minstret, minstreth, s4, s5, s6
  READ_COUNTER mcycle, mcycleh, s7, s8, s9
  SUB64 s7, s8, t0, t1, s10, s11, t6
  STORE_RESULT cycle_counter_cycles, \idx, s10, s11
  SUB64 s4, s5, t3, t4, s10, s11, t6
  STORE_RESULT cycle_counter_instret, \idx, s10, s11
cycle_counter_test_\idx\()_end:
.endm

.macro MEASURE_JALR idx
  .global cycle_counter_test_\idx\()_start
  .global cycle_counter_test_\idx\()_end
  la s3, .Ljalr_target_\@
cycle_counter_test_\idx\()_start:
  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  READ_COUNTER minstret, minstreth, t3, t4, t5
  li s6, REPEAT_COUNT
.Ljalr_loop_\@:
  jalr x0, 0(s3)
  nop
.Ljalr_target_\@:
  SERIAL_BARRIER
  addi s6, s6, -1
  bnez s6, .Ljalr_loop_\@
  READ_COUNTER minstret, minstreth, s4, s5, s6
  READ_COUNTER mcycle, mcycleh, s7, s8, s9
  SUB64 s7, s8, t0, t1, s10, s11, t6
  STORE_RESULT cycle_counter_cycles, \idx, s10, s11
  SUB64 s4, s5, t3, t4, s10, s11, t6
  STORE_RESULT cycle_counter_instret, \idx, s10, s11
cycle_counter_test_\idx\()_end:
.endm

.macro MEASURE_SERIAL_BARRIER_OVERHEAD
  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  .rept REPEAT_COUNT
    SERIAL_BARRIER
  .endr
  READ_COUNTER mcycle, mcycleh, t3, t4, t5
  SUB64 t3, t4, t0, t1, s10, s11, t6
  la t6, cycle_counter_serial_barrier_cycles_lo
  sw s10, 0(t6)
  la t6, cycle_counter_serial_barrier_cycles_hi
  sw s11, 0(t6)
.endm

.macro INIT_SCALAR_REGS
  li s0, 0x12345678
  li s1, 0x00001000
  li s2, 0x87654321
  la s3, scalar_load_data
  li a0, 0x3f800000
  li a1, 0x40000000
  fmv.w.x ft0, a0
  fmv.w.x ft1, a1
  fmv.w.x ft2, a0
.endm

main:
  la t0, scalar_trap_handler
  csrw mtvec, t0
  INIT_SCALAR_REGS

  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  READ_COUNTER mcycle, mcycleh, t3, t4, t5
  SUB64 t3, t4, t0, t1, s10, s11, t6
  la t6, cycle_counter_overhead_cycles_lo
  sw s10, 0(t6)
  la t6, cycle_counter_overhead_cycles_hi
  sw s11, 0(t6)
  MEASURE_SERIAL_BARRIER_OVERHEAD

  MEASURE 0, nop
  MEASURE 1, lui s0, 0x12345
  MEASURE 2, auipc s0, 0
  MEASURE 3, addi s0, s0, 1
  MEASURE 4, slti s0, s0, 1
  MEASURE 5, sltiu s0, s0, 1
  MEASURE 6, xori s0, s0, 0x55
  MEASURE 7, ori s0, s0, 0x55
  MEASURE 8, andi s0, s0, 0x7f
  MEASURE 9, slli s0, s0, 1
  MEASURE 10, srli s0, s0, 1
  MEASURE 11, srai s0, s0, 1
  MEASURE 12, add s0, s0, s1
  MEASURE 13, sub s0, s0, s1
  MEASURE 14, sll s0, s0, s1
  MEASURE 15, slt s0, s0, s1
  MEASURE 16, sltu s0, s0, s1
  MEASURE 17, xor s0, s0, s1
  MEASURE 18, srl s0, s0, s1
  MEASURE 19, sra s0, s0, s1
  MEASURE 20, or s0, s0, s1
  MEASURE 21, and s0, s0, s1
  MEASURE 22, lb s0, 0(s3)
  MEASURE 23, lh s0, 0(s3)
  MEASURE 24, lw s0, 0(s3)
  MEASURE 25, lbu s0, 0(s3)
  MEASURE 26, lhu s0, 0(s3)
  la s3, scalar_store_data
  MEASURE 27, sb s0, 0(s3)
  MEASURE 28, sh s0, 0(s3)
  MEASURE 29, sw s0, 0(s3)
  MEASURE_TAKEN_BRANCH 30, beq
  MEASURE 31, bne x0, x0, 2f; 2: nop
  MEASURE 32, blt x0, x0, 2f; 2: nop
  MEASURE_TAKEN_BRANCH 33, bge
  MEASURE 34, bltu x0, x0, 2f; 2: nop
  MEASURE_TAKEN_BRANCH 35, bgeu
  MEASURE_JAL 36
  MEASURE_JALR 37
  MEASURE 38, fence
  MEASURE 39, fence.i
  li s0, 0x55aa55aa
  MEASURE 40, csrrw s0, mscratch, s0
  MEASURE 41, csrrs s0, mscratch, s1
  MEASURE 42, csrrc s0, mscratch, s1
  MEASURE 43, csrrwi s0, mscratch, 1
  MEASURE 44, csrrsi s0, mscratch, 1
  MEASURE 45, csrrci s0, mscratch, 1
  li s0, 12345
  li s1, 37
  MEASURE 46, mul s0, s0, s1
  MEASURE 47, mulh s0, s0, s1
  MEASURE 48, mulhsu s0, s0, s1
  MEASURE 49, mulhu s0, s0, s1
  li s0, 123456789
  li s1, 37
  MEASURE 50, div s0, s0, s1
  li s0, 123456789
  MEASURE 51, divu s0, s0, s1
  li s0, 123456789
  MEASURE 52, rem s0, s0, s1
  li s0, 123456789
  MEASURE 53, remu s0, s0, s1
  la s3, scalar_load_data
  MEASURE 54, flw ft0, 0(s3)
  la s3, scalar_store_data
  MEASURE 55, fsw ft0, 0(s3)
  INIT_SCALAR_REGS
  MEASURE 56, fadd.s ft0, ft0, ft1
  MEASURE 57, fsub.s ft0, ft0, ft1
  MEASURE 58, fmul.s ft0, ft0, ft1
  MEASURE 59, fdiv.s ft0, ft0, ft1
  MEASURE 60, fsqrt.s ft0, ft0
  MEASURE 61, fsgnj.s ft0, ft0, ft1
  MEASURE 62, fsgnjn.s ft0, ft0, ft1
  MEASURE 63, fsgnjx.s ft0, ft0, ft1
  MEASURE 64, fmin.s ft0, ft0, ft1
  MEASURE 65, fmax.s ft0, ft0, ft1
  MEASURE 66, fcvt.w.s s0, ft0
  MEASURE 67, fcvt.wu.s s0, ft0
  MEASURE 68, fmv.x.w s0, ft0
  MEASURE 69, feq.s s0, ft0, ft1
  MEASURE 70, flt.s s0, ft0, ft1
  MEASURE 71, fle.s s0, ft0, ft1
  MEASURE 72, fclass.s s0, ft0
  MEASURE 73, fcvt.s.w ft0, s0
  MEASURE 74, fcvt.s.wu ft0, s0
  MEASURE 75, fmv.w.x ft0, s0
  li s0, 0x12345678
  li s1, 0x87654321
  MEASURE 76, andn s0, s0, s1
  MEASURE 77, orn s0, s0, s1
  MEASURE 78, xnor s0, s0, s1
  MEASURE 79, clz s0, s0
  li s0, 0x12345678
  MEASURE 80, ctz s0, s0
  MEASURE 81, cpop s0, s0
  MEASURE 82, max s0, s0, s1
  MEASURE 83, maxu s0, s0, s1
  MEASURE 84, min s0, s0, s1
  MEASURE 85, minu s0, s0, s1
  MEASURE 86, sext.b s0, s0
  MEASURE 87, sext.h s0, s0
  MEASURE 88, zext.h s0, s0
  MEASURE 89, rol s0, s0, s1
  MEASURE 90, ror s0, s0, s1
  MEASURE 91, rori s0, s0, 7
  MEASURE 92, orc.b s0, s0
  MEASURE 93, rev8 s0, s0
  INIT_SCALAR_REGS
  MEASURE 94, fmadd.s ft0, ft0, ft1, ft2
  INIT_SCALAR_REGS
  MEASURE 95, fmsub.s ft0, ft0, ft1, ft2
  INIT_SCALAR_REGS
  MEASURE 96, fnmsub.s ft0, ft0, ft1, ft2
  INIT_SCALAR_REGS
  MEASURE 97, fnmadd.s ft0, ft0, ft1, ft2
  la t0, scalar_trap_scratch
  csrw mscratch, t0
  MEASURE 98, ecall
  MEASURE 99, ebreak

  ret

scalar_trap_handler:
  csrrw t6, mscratch, t6
  sw t0, 0(t6)
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  lw t0, 0(t6)
  csrrw t6, mscratch, t6
  mret
