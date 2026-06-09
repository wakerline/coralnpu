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

.equ REPEAT_COUNT, 8
.equ NUM_TESTS, 251

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
.global cycle_counter_current_test
cycle_counter_current_test:
  .word 0xffffffff
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
rvv_data:
  .word 1, 2, 3, 4
  .word 5, 6, 7, 8
  .word 9, 10, 11, 12
  .word 13, 14, 15, 16
rvv_store:
  .zero 128
rvv_index8:
  .byte 0, 4, 8, 12, 0, 4, 8, 12
rvv_index16:
  .half 0, 4, 8, 12, 0, 4, 8, 12
rvv_index32:
  .word 0, 4, 8, 12

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
  li t6, \idx
  la s11, cycle_counter_current_test
  sw t6, 0(s11)
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

.macro SKIP_MEASURE idx
  .global cycle_counter_test_\idx\()_start
  .global cycle_counter_test_\idx\()_end
cycle_counter_test_\idx\()_start:
  li t6, \idx
  la s11, cycle_counter_current_test
  sw t6, 0(s11)
cycle_counter_test_\idx\()_end:
.endm

.macro INIT_RVV_E32
  la s0, rvv_data
  la s1, rvv_store
  li s2, 4
  vsetivli x0, 4, e32, m1, ta, ma
  vle32.v v1, (s0)
  vle32.v v2, (s0)
  vle32.v v3, (s0)
  vmseq.vi v0, v1, 1
.endm

main:
  INIT_RVV_E32

  READ_COUNTER mcycle, mcycleh, t0, t1, t2
  READ_COUNTER mcycle, mcycleh, t3, t4, t5
  SUB64 t3, t4, t0, t1, s10, s11, t6
  la t6, cycle_counter_overhead_cycles_lo
  sw s10, 0(t6)
  la t6, cycle_counter_overhead_cycles_hi
  sw s11, 0(t6)
  MEASURE_SERIAL_BARRIER_OVERHEAD

  MEASURE 0, nop
  li s2, 4
  MEASURE 1, vsetvli x0, s2, e32, m1, ta, ma
  MEASURE 2, vsetivli x0, 4, e32, m1, ta, ma

  la s0, rvv_data
  vsetivli x0, 16, e8, m1, ta, ma
  MEASURE 3, vle8.v v1, (s0)
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 4, vle16.v v1, (s0)
  vsetivli x0, 4, e32, m1, ta, ma
  MEASURE 5, vle32.v v1, (s0)
  la s1, rvv_store
  vsetivli x0, 16, e8, m1, ta, ma
  MEASURE 6, vse8.v v1, (s1)
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 7, vse16.v v1, (s1)
  vsetivli x0, 4, e32, m1, ta, ma
  MEASURE 8, vse32.v v1, (s1)
  li s2, 4
  vsetivli x0, 16, e8, m1, ta, ma
  MEASURE 9, vlse8.v v1, (s0), s2
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 10, vlse16.v v1, (s0), s2
  vsetivli x0, 4, e32, m1, ta, ma
  MEASURE 11, vlse32.v v1, (s0), s2
  vsetivli x0, 16, e8, m1, ta, ma
  MEASURE 12, vsse8.v v1, (s1), s2
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 13, vsse16.v v1, (s1), s2
  vsetivli x0, 4, e32, m1, ta, ma
  MEASURE 14, vsse32.v v1, (s1), s2

  vsetivli x0, 4, e32, m1, ta, ma
  la s2, rvv_index8
  vle8.v v3, (s2)
  MEASURE 15, vluxei8.v v1, (s0), v3
  la s2, rvv_index16
  vle16.v v3, (s2)
  MEASURE 16, vluxei16.v v1, (s0), v3
  la s2, rvv_index32
  vle32.v v3, (s2)
  MEASURE 17, vluxei32.v v1, (s0), v3
  la s2, rvv_index8
  vle8.v v3, (s2)
  MEASURE 18, vsuxei8.v v1, (s1), v3
  la s2, rvv_index16
  vle16.v v3, (s2)
  MEASURE 19, vsuxei16.v v1, (s1), v3
  la s2, rvv_index32
  vle32.v v3, (s2)
  MEASURE 20, vsuxei32.v v1, (s1), v3

  INIT_RVV_E32
  li s2, 3
  MEASURE 21, vadd.vv v1, v1, v2
  MEASURE 22, vadd.vx v1, v1, s2
  MEASURE 23, vadd.vi v1, v1, 1
  MEASURE 24, vsub.vv v1, v1, v2
  MEASURE 25, vsub.vx v1, v1, s2
  MEASURE 26, vrsub.vx v1, v1, s2
  MEASURE 27, vrsub.vi v1, v1, 1
  MEASURE 28, vand.vv v1, v1, v2
  MEASURE 29, vand.vx v1, v1, s2
  MEASURE 30, vand.vi v1, v1, 7
  MEASURE 31, vor.vv v1, v1, v2
  MEASURE 32, vor.vx v1, v1, s2
  MEASURE 33, vor.vi v1, v1, 7
  MEASURE 34, vxor.vv v1, v1, v2
  MEASURE 35, vxor.vx v1, v1, s2
  MEASURE 36, vxor.vi v1, v1, 7
  MEASURE 37, vsll.vv v1, v1, v2
  MEASURE 38, vsll.vx v1, v1, s2
  MEASURE 39, vsll.vi v1, v1, 1
  MEASURE 40, vsrl.vv v1, v1, v2
  MEASURE 41, vsrl.vx v1, v1, s2
  MEASURE 42, vsrl.vi v1, v1, 1
  MEASURE 43, vsra.vv v1, v1, v2
  MEASURE 44, vsra.vx v1, v1, s2
  MEASURE 45, vsra.vi v1, v1, 1
  MEASURE 46, vminu.vv v1, v1, v2
  MEASURE 47, vmin.vv v1, v1, v2
  MEASURE 48, vmaxu.vv v1, v1, v2
  MEASURE 49, vmax.vv v1, v1, v2
  MEASURE 50, vmseq.vv v0, v1, v2
  MEASURE 51, vmsne.vv v0, v1, v2
  MEASURE 52, vmsltu.vv v0, v1, v2
  MEASURE 53, vmslt.vv v0, v1, v2
  MEASURE 54, vmsleu.vv v0, v1, v2
  MEASURE 55, vmsle.vv v0, v1, v2
  MEASURE 56, vmsgtu.vx v0, v1, s2
  MEASURE 57, vmsgt.vx v0, v1, s2
  MEASURE 58, vmul.vv v1, v1, v2
  MEASURE 59, vmulh.vv v1, v1, v2
  MEASURE 60, vmulhu.vv v1, v1, v2
  MEASURE 61, vmulhsu.vv v1, v1, v2
  INIT_RVV_E32
  li s2, 3
  MEASURE 62, vdivu.vv v1, v1, v2
  INIT_RVV_E32
  MEASURE 63, vdiv.vv v1, v1, v2
  INIT_RVV_E32
  MEASURE 64, vremu.vv v1, v1, v2
  INIT_RVV_E32
  MEASURE 65, vrem.vv v1, v1, v2

  INIT_RVV_E32
  MEASURE 66, vmerge.vvm v1, v1, v2, v0
  MEASURE 67, vmv.v.v v1, v2
  MEASURE 68, vmv.v.x v1, s2
  MEASURE 69, vmv.v.i v1, 1
  MEASURE 70, vslideup.vx v1, v2, s2
  MEASURE 71, vslidedown.vx v1, v2, s2
  MEASURE 72, vslide1up.vx v1, v2, s2
  MEASURE 73, vslide1down.vx v1, v2, s2
  MEASURE 74, vrgather.vv v1, v2, v3
  MEASURE 75, vrgather.vx v1, v2, s2
  MEASURE 76, vrgather.vi v1, v2, 1
  MEASURE 77, vcompress.vm v1, v2, v0

  INIT_RVV_E32
  MEASURE 78, vredsum.vs v1, v2, v3
  MEASURE 79, vredmaxu.vs v1, v2, v3
  MEASURE 80, vredmax.vs v1, v2, v3
  MEASURE 81, vredminu.vs v1, v2, v3
  MEASURE 82, vredmin.vs v1, v2, v3
  MEASURE 83, vredand.vs v1, v2, v3
  MEASURE 84, vredor.vs v1, v2, v3
  MEASURE 85, vredxor.vs v1, v2, v3
  MEASURE 86, vcpop.m s2, v0
  MEASURE 87, vfirst.m s2, v0
  MEASURE 88, vmsbf.m v1, v0
  MEASURE 89, vmsof.m v1, v0
  MEASURE 90, vmsif.m v1, v0
  MEASURE 91, viota.m v1, v0

  la s0, rvv_data
  vsetivli x0, 8, e16, m1, ta, ma
  vle16.v v1, (s0)
  vle16.v v2, (s0)
  MEASURE 92, vwadd.vv v4, v1, v2
  MEASURE 93, vwaddu.vv v4, v1, v2
  MEASURE 94, vwsub.vv v4, v1, v2
  MEASURE 95, vwsubu.vv v4, v1, v2
  vsetivli x0, 4, e16, m1, ta, ma
  vle32.v v4, (s0)
  vle32.v v5, (s0)
  MEASURE 96, vnsrl.wv v1, v4, v5
  MEASURE 97, vnsra.wv v1, v4, v5

  li s2, 4
  li s3, 0xd0
  MEASURE 98, vsetvl x0, s2, s3

  la s0, rvv_data
  la s1, rvv_store
  vsetivli x0, 4, e32, m1, ta, ma
  vmseq.vi v0, v1, 1
  MEASURE 99, vlm.v v0, (s0)
  MEASURE 100, vsm.v v0, (s1)

  la s2, rvv_index8
  vle8.v v3, (s2)
  MEASURE 101, vloxei8.v v1, (s0), v3
  la s2, rvv_index16
  vle16.v v3, (s2)
  MEASURE 102, vloxei16.v v1, (s0), v3
  la s2, rvv_index32
  vle32.v v3, (s2)
  MEASURE 103, vloxei32.v v1, (s0), v3
  la s2, rvv_index8
  vle8.v v3, (s2)
  MEASURE 104, vsoxei8.v v1, (s1), v3
  la s2, rvv_index16
  vle16.v v3, (s2)
  MEASURE 105, vsoxei16.v v1, (s1), v3
  la s2, rvv_index32
  vle32.v v3, (s2)
  MEASURE 106, vsoxei32.v v1, (s1), v3

  MEASURE 107, vl1re32.v v1, (s0)
  MEASURE 108, vl2re32.v v2, (s0)
  MEASURE 109, vl4re32.v v4, (s0)
  MEASURE 110, vl8re32.v v8, (s0)
  MEASURE 111, vs1r.v v1, (s1)
  MEASURE 112, vs2r.v v2, (s1)
  MEASURE 113, vs4r.v v4, (s1)
  MEASURE 114, vs8r.v v8, (s1)

  vsetivli x0, 16, e8, m1, ta, ma
  MEASURE 115, vle8ff.v v1, (s0)
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 116, vle16ff.v v1, (s0)
  vsetivli x0, 4, e32, m1, ta, ma
  MEASURE 117, vle32ff.v v1, (s0)

  INIT_RVV_E32
  li s2, 3
  MEASURE 118, vmseq.vx v0, v1, s2
  MEASURE 119, vmseq.vi v0, v1, 1
  MEASURE 120, vmsne.vx v0, v1, s2
  MEASURE 121, vmsne.vi v0, v1, 1
  MEASURE 122, vmsltu.vx v0, v1, s2
  MEASURE 123, vmslt.vx v0, v1, s2
  MEASURE 124, vmsleu.vx v0, v1, s2
  MEASURE 125, vmsleu.vi v0, v1, 1
  MEASURE 126, vmsle.vx v0, v1, s2
  MEASURE 127, vmsle.vi v0, v1, 1
  MEASURE 128, vmsgtu.vi v0, v1, 1
  MEASURE 129, vmsgt.vi v0, v1, 1
  MEASURE 130, vminu.vx v1, v1, s2
  MEASURE 131, vmin.vx v1, v1, s2
  MEASURE 132, vmaxu.vx v1, v1, s2
  MEASURE 133, vmax.vx v1, v1, s2
  MEASURE 134, vmul.vx v1, v1, s2
  MEASURE 135, vmulh.vx v1, v1, s2
  MEASURE 136, vmulhu.vx v1, v1, s2
  MEASURE 137, vmulhsu.vx v1, v1, s2
  INIT_RVV_E32
  li s2, 3
  MEASURE 138, vdivu.vx v1, v1, s2
  INIT_RVV_E32
  li s2, 3
  MEASURE 139, vdiv.vx v1, v1, s2
  INIT_RVV_E32
  li s2, 3
  MEASURE 140, vremu.vx v1, v1, s2
  INIT_RVV_E32
  li s2, 3
  MEASURE 141, vrem.vx v1, v1, s2

  INIT_RVV_E32
  vmseq.vi v0, v1, 1
  MEASURE 142, vadc.vvm v1, v1, v2, v0
  MEASURE 143, vmadc.vvm v4, v1, v2, v0
  MEASURE 144, vsbc.vvm v1, v1, v2, v0
  MEASURE 145, vmsbc.vvm v4, v1, v2, v0

  la s0, rvv_data
  li s2, 3
  vsetivli x0, 8, e16, m1, ta, ma
  vle16.v v1, (s0)
  vle16.v v2, (s0)
  MEASURE 146, vwaddu.vx v4, v1, s2
  MEASURE 147, vwadd.vx v4, v1, s2
  MEASURE 148, vwsubu.vx v4, v1, s2
  MEASURE 149, vwsub.vx v4, v1, s2
  MEASURE 150, vwaddu.wv v8, v4, v1
  MEASURE 151, vwaddu.wx v8, v4, s2
  MEASURE 152, vwadd.wv v8, v4, v1
  MEASURE 153, vwadd.wx v8, v4, s2
  MEASURE 154, vwsubu.wv v8, v4, v1
  MEASURE 155, vwsubu.wx v8, v4, s2
  MEASURE 156, vwsub.wv v8, v4, v1
  SKIP_MEASURE 157
  MEASURE 158, vnsrl.wx v1, v4, s2
  MEASURE 159, vnsrl.wi v1, v4, 1
  MEASURE 160, vnsra.wx v1, v4, s2
  MEASURE 161, vnsra.wi v1, v4, 1
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 162, vzext.vf2 v4, v1
  SKIP_MEASURE 163
  SKIP_MEASURE 164
  SKIP_MEASURE 165
  SKIP_MEASURE 166
  SKIP_MEASURE 167

  vsetivli x0, 8, e16, m1, ta, ma
  vle16.v v1, (s0)
  vle16.v v2, (s0)
  MEASURE 168, vwmulu.vv v4, v1, v2
  MEASURE 169, vwmulu.vx v4, v1, s2
  MEASURE 170, vwmul.vv v4, v1, v2
  MEASURE 171, vwmul.vx v4, v1, s2
  MEASURE 172, vwmulsu.vv v4, v1, v2
  MEASURE 173, vwmulsu.vx v4, v1, s2
  MEASURE 174, vmacc.vv v1, v1, v2
  MEASURE 175, vmacc.vx v1, s2, v2
  MEASURE 176, vnmsac.vv v1, v1, v2
  MEASURE 177, vnmsac.vx v1, s2, v2
  MEASURE 178, vmadd.vv v1, v1, v2
  MEASURE 179, vmadd.vx v1, s2, v2
  MEASURE 180, vnmsub.vv v1, v1, v2
  MEASURE 181, vnmsub.vx v1, s2, v2
  MEASURE 182, vwmaccu.vv v4, v1, v2
  MEASURE 183, vwmaccu.vx v4, s2, v2
  MEASURE 184, vwmacc.vv v4, v1, v2
  MEASURE 185, vwmacc.vx v4, s2, v2
  MEASURE 186, vwmaccsu.vv v4, v1, v2
  MEASURE 187, vwmaccsu.vx v4, s2, v2
  MEASURE 188, vwmaccus.vx v4, s2, v2

  INIT_RVV_E32
  li s2, 3
  MEASURE 189, vsaddu.vv v1, v1, v2
  MEASURE 190, vsaddu.vx v1, v1, s2
  MEASURE 191, vsaddu.vi v1, v1, 1
  MEASURE 192, vsadd.vv v1, v1, v2
  MEASURE 193, vsadd.vx v1, v1, s2
  MEASURE 194, vsadd.vi v1, v1, 1
  MEASURE 195, vssubu.vv v1, v1, v2
  MEASURE 196, vssubu.vx v1, v1, s2
  MEASURE 197, vssub.vv v1, v1, v2
  MEASURE 198, vssub.vx v1, v1, s2
  MEASURE 199, vaaddu.vv v1, v1, v2
  MEASURE 200, vaaddu.vx v1, v1, s2
  MEASURE 201, vaadd.vv v1, v1, v2
  MEASURE 202, vaadd.vx v1, v1, s2
  MEASURE 203, vasubu.vv v1, v1, v2
  MEASURE 204, vasubu.vx v1, v1, s2
  MEASURE 205, vasub.vv v1, v1, v2
  MEASURE 206, vasub.vx v1, v1, s2
  MEASURE 207, vsmul.vv v1, v1, v2
  MEASURE 208, vsmul.vx v1, v1, s2
  MEASURE 209, vssrl.vv v1, v1, v2
  MEASURE 210, vssrl.vx v1, v1, s2
  MEASURE 211, vssrl.vi v1, v1, 1
  MEASURE 212, vssra.vv v1, v1, v2
  MEASURE 213, vssra.vx v1, v1, s2
  MEASURE 214, vssra.vi v1, v1, 1
  vsetivli x0, 8, e16, m1, ta, ma
  vle32.v v4, (s0)
  MEASURE 215, vnclipu.wv v1, v4, v2
  MEASURE 216, vnclipu.wx v1, v4, s2
  MEASURE 217, vnclipu.wi v1, v4, 1
  MEASURE 218, vnclip.wv v1, v4, v2
  MEASURE 219, vnclip.wx v1, v4, s2
  MEASURE 220, vnclip.wi v1, v4, 1

  INIT_RVV_E32
  vmseq.vi v0, v1, 1
  MEASURE 221, vmand.mm v0, v0, v0
  MEASURE 222, vmnand.mm v0, v0, v0
  MEASURE 223, vmandnot.mm v0, v0, v0
  MEASURE 224, vmxor.mm v0, v0, v0
  MEASURE 225, vmor.mm v0, v0, v0
  MEASURE 226, vmnor.mm v0, v0, v0
  MEASURE 227, vmornot.mm v0, v0, v0
  MEASURE 228, vmxnor.mm v0, v0, v0

  INIT_RVV_E32
  li s2, 3
  MEASURE 229, vmv.x.s s2, v1
  MEASURE 230, vmv.s.x v1, s2
  MEASURE 231, vmv1r.v v1, v2
  MEASURE 232, vmv2r.v v2, v4
  MEASURE 233, vmv4r.v v4, v8
  MEASURE 234, vmv8r.v v8, v16
  MEASURE 235, vmerge.vxm v1, v1, s2, v0
  MEASURE 236, vmerge.vim v1, v1, 1, v0
  MEASURE 237, vslideup.vi v1, v2, 1
  MEASURE 238, vslidedown.vi v1, v2, 1
  vsetivli x0, 8, e16, m1, ta, ma
  vle16.v v3, (s0)
  MEASURE 239, vrgatherei16.vv v1, v2, v3
  MEASURE 240, vid.v v1
  vsetivli x0, 8, e16, m1, ta, ma
  MEASURE 241, vwredsumu.vs v4, v1, v2
  MEASURE 242, vwredsum.vs v4, v1, v2

  vsetivli x0, 4, e32, m1, ta, ma
  li s2, 8
  vle32.v v3, (s0)
  MEASURE 243, vlseg2e32.v v4, (s0)
  MEASURE 244, vsseg2e32.v v4, (s1)
  MEASURE 245, vlsseg2e32.v v4, (s0), s2
  MEASURE 246, vssseg2e32.v v4, (s1), s2
  MEASURE 247, vluxseg2ei32.v v4, (s0), v3
  MEASURE 248, vsuxseg2ei32.v v4, (s1), v3
  MEASURE 249, vloxseg2ei32.v v4, (s0), v3
  MEASURE 250, vsoxseg2ei32.v v4, (s1), v3

  ret
