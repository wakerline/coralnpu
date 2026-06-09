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

.section .data
.align 4
scalar_data_a:
  .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
scalar_data_b:
  .word 0x01020304, 0x05060708, 0x090a0b0c, 0x0d0e0f10
rvv_data_a:
  .word 1, 2, 3, 4
rvv_data_b:
  .word 5, 6, 7, 8
rvv_store:
  .zero 64

.section .text
.global main

.macro SERIAL_BARRIER
  fence
  csrr s9, mcycle
  addi s9, s9, 0
.endm

.macro INIT_TEST_REGS
  la s0, scalar_data_a
  la s1, scalar_data_b
  la s2, rvv_data_a
  la s3, rvv_data_b
  la s4, rvv_store
  li s5, 0x13579bdf
  li s6, 0x2468ace0
  vsetivli x0, 4, e32, m1, ta, ma
  vle32.v v1, (s2)
  vle32.v v2, (s3)
.endm

main:
  INIT_TEST_REGS

  .global rvv_scalar_case0_start
  .global rvv_scalar_case0_scalar_load
  .global rvv_scalar_case0_vector_load
  .global rvv_scalar_case0_end
rvv_scalar_case0_start:
  SERIAL_BARRIER
rvv_scalar_case0_scalar_load:
  lw t0, 0(s0)
rvv_scalar_case0_vector_load:
  vle32.v v4, (s2)
rvv_scalar_case0_end:
  SERIAL_BARRIER

  .global rvv_scalar_case1_start
  .global rvv_scalar_case1_vector_load
  .global rvv_scalar_case1_scalar_load
  .global rvv_scalar_case1_end
rvv_scalar_case1_start:
  SERIAL_BARRIER
rvv_scalar_case1_vector_load:
  vle32.v v5, (s3)
rvv_scalar_case1_scalar_load:
  lw t1, 4(s1)
rvv_scalar_case1_end:
  SERIAL_BARRIER

  .global rvv_scalar_case2_start
  .global rvv_scalar_case2_vector_load
  .global rvv_scalar_case2_vector_compute
  .global rvv_scalar_case2_end
rvv_scalar_case2_start:
  SERIAL_BARRIER
rvv_scalar_case2_vector_load:
  vle32.v v6, (s2)
rvv_scalar_case2_vector_compute:
  vadd.vv v8, v1, v2
rvv_scalar_case2_end:
  SERIAL_BARRIER

  .global rvv_scalar_case3_start
  .global rvv_scalar_case3_vector_compute
  .global rvv_scalar_case3_vector_load
  .global rvv_scalar_case3_end
rvv_scalar_case3_start:
  SERIAL_BARRIER
rvv_scalar_case3_vector_compute:
  vadd.vv v9, v1, v2
rvv_scalar_case3_vector_load:
  vle32.v v7, (s3)
rvv_scalar_case3_end:
  SERIAL_BARRIER

  .global rvv_scalar_case4_start
  .global rvv_scalar_case4_scalar_load
  .global rvv_scalar_case4_scalar_compute
  .global rvv_scalar_case4_end
rvv_scalar_case4_start:
  SERIAL_BARRIER
rvv_scalar_case4_scalar_load:
  lw t2, 8(s0)
rvv_scalar_case4_scalar_compute:
  add t3, s5, s6
rvv_scalar_case4_end:
  SERIAL_BARRIER

  .global rvv_scalar_case5_start
  .global rvv_scalar_case5_scalar_compute
  .global rvv_scalar_case5_scalar_load
  .global rvv_scalar_case5_end
rvv_scalar_case5_start:
  SERIAL_BARRIER
rvv_scalar_case5_scalar_compute:
  add t4, s5, s6
rvv_scalar_case5_scalar_load:
  lw t5, 12(s1)
rvv_scalar_case5_end:
  SERIAL_BARRIER

  .global rvv_scalar_case6_start
  .global rvv_scalar_case6_vector_load
  .global rvv_scalar_case6_vector_compute_dep
  .global rvv_scalar_case6_end
rvv_scalar_case6_start:
  SERIAL_BARRIER
rvv_scalar_case6_vector_load:
  vle32.v v10, (s2)
rvv_scalar_case6_vector_compute_dep:
  vadd.vv v11, v10, v2
rvv_scalar_case6_end:
  SERIAL_BARRIER

  .global rvv_scalar_case7_start
  .global rvv_scalar_case7_scalar_load
  .global rvv_scalar_case7_scalar_compute_dep
  .global rvv_scalar_case7_end
rvv_scalar_case7_start:
  SERIAL_BARRIER
rvv_scalar_case7_scalar_load:
  lw t2, 0(s0)
rvv_scalar_case7_scalar_compute_dep:
  add t3, t2, s6
rvv_scalar_case7_end:
  SERIAL_BARRIER

  .global rvv_scalar_case8_start
  .global rvv_scalar_case8_vector_load0
  .global rvv_scalar_case8_vector_load1
  .global rvv_scalar_case8_vector_compute0
  .global rvv_scalar_case8_vector_compute1
  .global rvv_scalar_case8_end
rvv_scalar_case8_start:
  SERIAL_BARRIER
rvv_scalar_case8_vector_load0:
  vle32.v v12, (s2)
rvv_scalar_case8_vector_load1:
  vle32.v v13, (s3)
rvv_scalar_case8_vector_compute0:
  vadd.vv v14, v1, v2
rvv_scalar_case8_vector_compute1:
  vxor.vv v15, v1, v2
rvv_scalar_case8_end:
  SERIAL_BARRIER

  .global rvv_scalar_case9_start
  .global rvv_scalar_case9_vector_compute0
  .global rvv_scalar_case9_vector_compute1
  .global rvv_scalar_case9_vector_load0
  .global rvv_scalar_case9_vector_load1
  .global rvv_scalar_case9_end
rvv_scalar_case9_start:
  SERIAL_BARRIER
rvv_scalar_case9_vector_compute0:
  vadd.vv v16, v1, v2
rvv_scalar_case9_vector_compute1:
  vxor.vv v17, v1, v2
rvv_scalar_case9_vector_load0:
  vle32.v v18, (s2)
rvv_scalar_case9_vector_load1:
  vle32.v v19, (s3)
rvv_scalar_case9_end:
  SERIAL_BARRIER

  .global rvv_scalar_case10_start
  .global rvv_scalar_case10_vector_load0
  .global rvv_scalar_case10_vector_compute0
  .global rvv_scalar_case10_vector_load1
  .global rvv_scalar_case10_vector_compute1
  .global rvv_scalar_case10_end
rvv_scalar_case10_start:
  SERIAL_BARRIER
rvv_scalar_case10_vector_load0:
  vle32.v v20, (s2)
rvv_scalar_case10_vector_compute0:
  vadd.vv v21, v1, v2
rvv_scalar_case10_vector_load1:
  vle32.v v22, (s3)
rvv_scalar_case10_vector_compute1:
  vxor.vv v23, v1, v2
rvv_scalar_case10_end:
  SERIAL_BARRIER

  .global rvv_scalar_case11_start
  .global rvv_scalar_case11_vector_compute0
  .global rvv_scalar_case11_vector_load0
  .global rvv_scalar_case11_vector_compute1
  .global rvv_scalar_case11_vector_load1
  .global rvv_scalar_case11_end
rvv_scalar_case11_start:
  SERIAL_BARRIER
rvv_scalar_case11_vector_compute0:
  vadd.vv v24, v1, v2
rvv_scalar_case11_vector_load0:
  vle32.v v25, (s2)
rvv_scalar_case11_vector_compute1:
  vxor.vv v26, v1, v2
rvv_scalar_case11_vector_load1:
  vle32.v v27, (s3)
rvv_scalar_case11_end:
  SERIAL_BARRIER

  .global rvv_scalar_case12_start
  .global rvv_scalar_case12_vector_load0
  .global rvv_scalar_case12_vector_load1
  .global rvv_scalar_case12_vector_load2
  .global rvv_scalar_case12_vector_load3
  .global rvv_scalar_case12_vector_compute0
  .global rvv_scalar_case12_vector_compute1
  .global rvv_scalar_case12_vector_compute2
  .global rvv_scalar_case12_vector_compute3
  .global rvv_scalar_case12_end
rvv_scalar_case12_start:
  SERIAL_BARRIER
rvv_scalar_case12_vector_load0:
  vle32.v v24, (s2)
rvv_scalar_case12_vector_load1:
  vle32.v v25, (s3)
rvv_scalar_case12_vector_load2:
  vle32.v v26, (s2)
rvv_scalar_case12_vector_load3:
  vle32.v v27, (s3)
rvv_scalar_case12_vector_compute0:
  vadd.vv v28, v1, v2
rvv_scalar_case12_vector_compute1:
  vxor.vv v29, v1, v2
rvv_scalar_case12_vector_compute2:
  vand.vv v30, v1, v2
rvv_scalar_case12_vector_compute3:
  vor.vv v31, v1, v2
rvv_scalar_case12_end:
  SERIAL_BARRIER

  .global rvv_scalar_case13_start
  .global rvv_scalar_case13_vector_compute0
  .global rvv_scalar_case13_vector_compute1
  .global rvv_scalar_case13_vector_compute2
  .global rvv_scalar_case13_vector_compute3
  .global rvv_scalar_case13_vector_load0
  .global rvv_scalar_case13_vector_load1
  .global rvv_scalar_case13_vector_load2
  .global rvv_scalar_case13_vector_load3
  .global rvv_scalar_case13_end
rvv_scalar_case13_start:
  SERIAL_BARRIER
rvv_scalar_case13_vector_compute0:
  vadd.vv v24, v1, v2
rvv_scalar_case13_vector_compute1:
  vxor.vv v25, v1, v2
rvv_scalar_case13_vector_compute2:
  vand.vv v26, v1, v2
rvv_scalar_case13_vector_compute3:
  vor.vv v27, v1, v2
rvv_scalar_case13_vector_load0:
  vle32.v v28, (s2)
rvv_scalar_case13_vector_load1:
  vle32.v v29, (s3)
rvv_scalar_case13_vector_load2:
  vle32.v v30, (s2)
rvv_scalar_case13_vector_load3:
  vle32.v v31, (s3)
rvv_scalar_case13_end:
  SERIAL_BARRIER

  ret
