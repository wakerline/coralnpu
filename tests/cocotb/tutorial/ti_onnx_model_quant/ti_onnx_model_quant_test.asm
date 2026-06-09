
bazel-out/k8-fastbuild-ST-dd8dc713f32d/bin/tests/cocotb/tutorial/ti_onnx_model_quant/ti_onnx_model_quant_test.elf:     file format elf32-littleriscv


Disassembly of section .text:

00000000 <_start>:
       0:	b0205073          	csrwi	minstret,0
       4:	b8205073          	csrwi	minstreth,0
       8:	b0202573          	csrr	a0,minstret
       c:	b82025f3          	csrr	a1,minstreth
      10:	00200117          	auipc	sp,0x200
      14:	ff010113          	addi	sp,sp,-16 # 200000 <__stack_end__>
      18:	00100197          	auipc	gp,0x100
      1c:	7e818193          	addi	gp,gp,2024 # 100800 <__global_pointer$>
      20:	00000213          	li	tp,0
      24:	00000313          	li	t1,0
      28:	00000393          	li	t2,0
      2c:	00000413          	li	s0,0
      30:	00000493          	li	s1,0
      34:	00000593          	li	a1,0
      38:	00000613          	li	a2,0
      3c:	00000693          	li	a3,0
      40:	00000713          	li	a4,0
      44:	00000793          	li	a5,0
      48:	00000813          	li	a6,0
      4c:	00000893          	li	a7,0
      50:	00000913          	li	s2,0
      54:	00000993          	li	s3,0
      58:	00000a13          	li	s4,0
      5c:	00000a93          	li	s5,0
      60:	00000b13          	li	s6,0
      64:	00000b93          	li	s7,0
      68:	00000c13          	li	s8,0
      6c:	00000c93          	li	s9,0
      70:	00000d13          	li	s10,0
      74:	00000d93          	li	s11,0
      78:	00000e13          	li	t3,0
      7c:	00000e93          	li	t4,0
      80:	00000f13          	li	t5,0
      84:	00000f93          	li	t6,0
      88:	92018513          	addi	a0,gp,-1760 # 100120 <_ZN10__cxxabiv1L12atexit_countE>
      8c:	00103597          	auipc	a1,0x103
      90:	8e458593          	addi	a1,a1,-1820 # 102970 <__bss_end>
      94:	7ac010ef          	jal	1840 <crt_section_clear>
      98:	00002417          	auipc	s0,0x2
      9c:	81840413          	addi	s0,s0,-2024 # 18b0 <__fini_array_end>
      a0:	00002497          	auipc	s1,0x2
      a4:	81048493          	addi	s1,s1,-2032 # 18b0 <__fini_array_end>
      a8:	00947a63          	bgeu	s0,s1,bc <init_array_loop_end>

000000ac <init_array_loop>:
      ac:	00042283          	lw	t0,0(s0)
      b0:	000280e7          	jalr	t0
      b4:	00440413          	addi	s0,s0,4
      b8:	fe946ae3          	bltu	s0,s1,ac <init_array_loop>

000000bc <init_array_loop_end>:
      bc:	00001297          	auipc	t0,0x1
      c0:	00428293          	addi	t0,t0,4 # 10c0 <coralnpu_exception_handler>
      c4:	30529073          	csrw	mtvec,t0
      c8:	000062b7          	lui	t0,0x6
      cc:	60028293          	addi	t0,t0,1536 # 6600 <global_const_workspace+0x47d0>
      d0:	3002a073          	csrs	mstatus,t0
      d4:	00100297          	auipc	t0,0x100
      d8:	04028293          	addi	t0,t0,64 # 100114 <_ret>
      dc:	0badd537          	lui	a0,0xbadd
      e0:	00d50513          	addi	a0,a0,13 # badd00d <__stack_end__+0xb8dd00d>
      e4:	00a2a023          	sw	a0,0(t0)
      e8:	00000513          	li	a0,0
      ec:	00000593          	li	a1,0
      f0:	00000097          	auipc	ra,0x0
      f4:	06408093          	addi	ra,ra,100 # 154 <main>
      f8:	000080e7          	jalr	ra
      fc:	00050913          	mv	s2,a0
     100:	01c010ef          	jal	111c <__cxa_finalize>
     104:	00001417          	auipc	s0,0x1
     108:	7ac40413          	addi	s0,s0,1964 # 18b0 <__fini_array_end>
     10c:	00001497          	auipc	s1,0x1
     110:	7a448493          	addi	s1,s1,1956 # 18b0 <__fini_array_end>
     114:	00940a63          	beq	s0,s1,128 <fini_array_loop_end>

00000118 <fini_array_loop>:
     118:	ffc48493          	addi	s1,s1,-4
     11c:	0004a283          	lw	t0,0(s1)
     120:	000280e7          	jalr	t0
     124:	fe941ae3          	bne	s0,s1,118 <fini_array_loop>

00000128 <fini_array_loop_end>:
     128:	00090513          	mv	a0,s2
     12c:	00100297          	auipc	t0,0x100
     130:	fe828293          	addi	t0,t0,-24 # 100114 <_ret>
     134:	00a2a023          	sw	a0,0(t0)
     138:	00050663          	beqz	a0,144 <success>

0000013c <failure>:
     13c:	00100073          	ebreak
     140:	0100006f          	j	150 <loop>

00000144 <success>:
     144:	b0202573          	csrr	a0,minstret
     148:	b82025f3          	csrr	a1,minstreth
     14c:	08000073          	.insn	4, 0x08000073

00000150 <loop>:
     150:	0000006f          	j	150 <loop>

00000154 <main>:
  uint64_t start = mcycle_read();
  inference_status = tvmgen_default_run(&inputs, &outputs);
  inference_cycles = mcycle_read() - start;
}

int main(void) {
     154:	ff010113          	addi	sp,sp,-16
     158:	00112623          	sw	ra,12(sp)
  run_model();
     15c:	564010ef          	jal	16c0 <run_model>
  return 0;
}
     160:	00000513          	li	a0,0
     164:	00c12083          	lw	ra,12(sp)
     168:	01010113          	addi	sp,sp,16
     16c:	00008067          	ret

00000170 <tvmgen_default_run>:
     170:	00052503          	lw	a0,0(a0)
     174:	0005a583          	lw	a1,0(a1)
     178:	00002637          	lui	a2,0x2
     17c:	001006b7          	lui	a3,0x100
     180:	e3060613          	addi	a2,a2,-464 # 1e30 <global_const_workspace>
     184:	17068693          	addi	a3,a3,368 # 100170 <global_workspace>
     188:	3680006f          	j	4f0 <tvmgen_default___tvm_main__>

0000018c <tvmgen_default_fused_cast_cast>:
     18c:	00002737          	lui	a4,0x2
     190:	00e58733          	add	a4,a1,a4
     194:	00054783          	lbu	a5,0(a0)
     198:	00458593          	addi	a1,a1,4
     19c:	00150513          	addi	a0,a0,1
     1a0:	d007f7d3          	fcvt.s.w	fa5,a5
     1a4:	fef5ae27          	fsw	fa5,-4(a1)
     1a8:	fee596e3          	bne	a1,a4,194 <tvmgen_default_fused_cast_cast+0x8>
     1ac:	00000513          	li	a0,0
     1b0:	00008067          	ret

000001b4 <tvmgen_default_fused_nn_avg_pool2d>:
     1b4:	00002837          	lui	a6,0x2
     1b8:	01068833          	add	a6,a3,a6
     1bc:	08050e13          	addi	t3,a0,128
     1c0:	00080e93          	mv	t4,a6
     1c4:	00000313          	li	t1,0
     1c8:	04000f13          	li	t5,64
     1cc:	00531513          	slli	a0,t1,0x5
     1d0:	08050893          	addi	a7,a0,128
     1d4:	000e0613          	mv	a2,t3
     1d8:	000e8713          	mv	a4,t4
     1dc:	f00007d3          	fmv.w.x	fa5,zero
     1e0:	f8060793          	addi	a5,a2,-128
     1e4:	00f72027          	fsw	fa5,0(a4) # 2000 <global_const_workspace+0x1d0>
     1e8:	0007a707          	flw	fa4,0(a5)
     1ec:	00478793          	addi	a5,a5,4
     1f0:	00e7f7d3          	fadd.s	fa5,fa5,fa4
     1f4:	00f72027          	fsw	fa5,0(a4)
     1f8:	fef618e3          	bne	a2,a5,1e8 <tvmgen_default_fused_nn_avg_pool2d+0x34>
     1fc:	02050513          	addi	a0,a0,32
     200:	00470713          	addi	a4,a4,4
     204:	08060613          	addi	a2,a2,128
     208:	fd151ae3          	bne	a0,a7,1dc <tvmgen_default_fused_nn_avg_pool2d+0x28>
     20c:	00430313          	addi	t1,t1,4
     210:	010e8e93          	addi	t4,t4,16
     214:	200e0e13          	addi	t3,t3,512
     218:	fbe31ae3          	bne	t1,t5,1cc <tvmgen_default_fused_nn_avg_pool2d+0x18>
     21c:	00002737          	lui	a4,0x2
     220:	000027b7          	lui	a5,0x2
     224:	10070713          	addi	a4,a4,256 # 2100 <global_const_workspace+0x2d0>
     228:	8b07a787          	flw	fa5,-1872(a5) # 18b0 <__fini_array_end>
     22c:	00e68733          	add	a4,a3,a4
     230:	00058793          	mv	a5,a1
     234:	00082707          	flw	fa4,0(a6) # 2000 <global_const_workspace+0x1d0>
     238:	01080813          	addi	a6,a6,16
     23c:	01078793          	addi	a5,a5,16
     240:	10f77753          	fmul.s	fa4,fa4,fa5
     244:	fee7a827          	fsw	fa4,-16(a5)
     248:	ff482707          	flw	fa4,-12(a6)
     24c:	10f77753          	fmul.s	fa4,fa4,fa5
     250:	fee7aa27          	fsw	fa4,-12(a5)
     254:	ff882707          	flw	fa4,-8(a6)
     258:	10f77753          	fmul.s	fa4,fa4,fa5
     25c:	fee7ac27          	fsw	fa4,-8(a5)
     260:	ffc82707          	flw	fa4,-4(a6)
     264:	10f77753          	fmul.s	fa4,fa4,fa5
     268:	fee7ae27          	fsw	fa4,-4(a5)
     26c:	fd0714e3          	bne	a4,a6,234 <tvmgen_default_fused_nn_avg_pool2d+0x80>
     270:	00000513          	li	a0,0
     274:	00008067          	ret

00000278 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast>:
     278:	f0000753          	fmv.w.x	fa4,zero
     27c:	fe010113          	addi	sp,sp,-32
     280:	00812c23          	sw	s0,24(sp)
     284:	20e707d3          	fmv.s	fa5,fa4
     288:	00112e23          	sw	ra,28(sp)
     28c:	00912a23          	sw	s1,20(sp)
     290:	10e6a027          	fsw	fa4,256(a3)
     294:	10e6a227          	fsw	fa4,260(a3)
     298:	00058413          	mv	s0,a1
     29c:	00060793          	mv	a5,a2
     2a0:	20060713          	addi	a4,a2,512
     2a4:	00052607          	flw	fa2,0(a0)
     2a8:	0007a687          	flw	fa3,0(a5)
     2ac:	00878793          	addi	a5,a5,8
     2b0:	00450513          	addi	a0,a0,4
     2b4:	78d677c3          	fmadd.s	fa5,fa2,fa3,fa5
     2b8:	10f6a027          	fsw	fa5,256(a3)
     2bc:	ffc52607          	flw	fa2,-4(a0)
     2c0:	ffc7a687          	flw	fa3,-4(a5)
     2c4:	70d67743          	fmadd.s	fa4,fa2,fa3,fa4
     2c8:	10e6a227          	fsw	fa4,260(a3)
     2cc:	fcf71ce3          	bne	a4,a5,2a4 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0x2c>
     2d0:	20062687          	flw	fa3,512(a2)
     2d4:	21062707          	flw	fa4,528(a2)
     2d8:	00d12623          	sw	a3,12(sp)
     2dc:	00d7f7d3          	fadd.s	fa5,fa5,fa3
     2e0:	00c12423          	sw	a2,8(sp)
     2e4:	000024b7          	lui	s1,0x2
     2e8:	10e7f7d3          	fmul.s	fa5,fa5,fa4
     2ec:	e0078553          	fmv.x.w	a0,fa5
     2f0:	458010ef          	jal	1748 <floorf>
     2f4:	f00507d3          	fmv.w.x	fa5,a0
     2f8:	8b44a707          	flw	fa4,-1868(s1) # 18b4 <__fini_array_end+0x4>
     2fc:	00812603          	lw	a2,8(sp)
     300:	00c12683          	lw	a3,12(sp)
     304:	a0e797d3          	flt.s	a5,fa5,fa4
     308:	04079c63          	bnez	a5,360 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0xe8>
     30c:	07f00793          	li	a5,127
     310:	00f40023          	sb	a5,0(s0)
     314:	1046a787          	flw	fa5,260(a3)
     318:	20462687          	flw	fa3,516(a2)
     31c:	21462707          	flw	fa4,532(a2)
     320:	00d7f7d3          	fadd.s	fa5,fa5,fa3
     324:	10e7f7d3          	fmul.s	fa5,fa5,fa4
     328:	e0078553          	fmv.x.w	a0,fa5
     32c:	41c010ef          	jal	1748 <floorf>
     330:	f00507d3          	fmv.w.x	fa5,a0
     334:	8b44a707          	flw	fa4,-1868(s1)
     338:	a0e797d3          	flt.s	a5,fa5,fa4
     33c:	04079263          	bnez	a5,380 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0x108>
     340:	07f00793          	li	a5,127
     344:	00f400a3          	sb	a5,1(s0)
     348:	01c12083          	lw	ra,28(sp)
     34c:	01812403          	lw	s0,24(sp)
     350:	01412483          	lw	s1,20(sp)
     354:	00000513          	li	a0,0
     358:	02010113          	addi	sp,sp,32
     35c:	00008067          	ret
     360:	000027b7          	lui	a5,0x2
     364:	8b87a707          	flw	fa4,-1864(a5) # 18b8 <__fini_array_end+0x8>
     368:	a0f717d3          	flt.s	a5,fa4,fa5
     36c:	00078663          	beqz	a5,378 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0x100>
     370:	c00797d3          	fcvt.w.s	a5,fa5,rtz
     374:	f9dff06f          	j	310 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0x98>
     378:	f8000793          	li	a5,-128
     37c:	f95ff06f          	j	310 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0x98>
     380:	000027b7          	lui	a5,0x2
     384:	8b87a707          	flw	fa4,-1864(a5) # 18b8 <__fini_array_end+0x8>
     388:	a0f717d3          	flt.s	a5,fa4,fa5
     38c:	02078263          	beqz	a5,3b0 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast+0x138>
     390:	c00797d3          	fcvt.w.s	a5,fa5,rtz
     394:	00000513          	li	a0,0
     398:	00f400a3          	sb	a5,1(s0)
     39c:	01c12083          	lw	ra,28(sp)
     3a0:	01812403          	lw	s0,24(sp)
     3a4:	01412483          	lw	s1,20(sp)
     3a8:	02010113          	addi	sp,sp,32
     3ac:	00008067          	ret
     3b0:	f8000793          	li	a5,-128
     3b4:	00f400a3          	sb	a5,1(s0)
     3b8:	01c12083          	lw	ra,28(sp)
     3bc:	01812403          	lw	s0,24(sp)
     3c0:	01412483          	lw	s1,20(sp)
     3c4:	00000513          	li	a0,0
     3c8:	02010113          	addi	sp,sp,32
     3cc:	00008067          	ret

000003d0 <tvmgen_default_fused_nn_max_pool2d>:
     3d0:	0c0077d7          	vsetvli	a5,zero,e8,m1,ta,ma
     3d4:	5e0030d7          	vmv.v.i	v1,0
     3d8:	7ff50f93          	addi	t6,a0,2047
     3dc:	00158e93          	addi	t4,a1,1
     3e0:	002f8f93          	addi	t6,t6,2
     3e4:	00150f13          	addi	t5,a0,1
     3e8:	0ff50e13          	addi	t3,a0,255
     3ec:	fe0e8fa3          	sb	zero,-1(t4)
     3f0:	f01e4683          	lbu	a3,-255(t3)
     3f4:	001e0793          	addi	a5,t3,1
     3f8:	000f0813          	mv	a6,t5
     3fc:	fede8fa3          	sb	a3,-1(t4)
     400:	f02e4703          	lbu	a4,-254(t3)
     404:	0ad77733          	maxu	a4,a4,a3
     408:	feee8fa3          	sb	a4,-1(t4)
     40c:	00fef663          	bgeu	t4,a5,418 <tvmgen_default_fused_nn_max_pool2d+0x48>
     410:	07fe8793          	addi	a5,t4,127
     414:	0aff6063          	bltu	t5,a5,4b4 <tvmgen_default_fused_nn_max_pool2d+0xe4>
     418:	f04e0893          	addi	a7,t3,-252
     41c:	000e8513          	mv	a0,t4
     420:	000e8593          	mv	a1,t4
     424:	000e8613          	mv	a2,t4
     428:	000e8693          	mv	a3,t4
     42c:	07e00713          	li	a4,126
     430:	0c0777d7          	vsetvli	a5,a4,e8,m1,ta,ma
     434:	020680a7          	vse8.v	v1,(a3)
     438:	00179313          	slli	t1,a5,0x1
     43c:	40f70733          	sub	a4,a4,a5
     440:	00f686b3          	add	a3,a3,a5
     444:	22080107          	vlseg2e8.v	v2,(a6)
     448:	00680833          	add	a6,a6,t1
     44c:	02060127          	vse8.v	v2,(a2)
     450:	1a218157          	vmaxu.vv	v2,v2,v3
     454:	00f60633          	add	a2,a2,a5
     458:	02058127          	vse8.v	v2,(a1)
     45c:	00f585b3          	add	a1,a1,a5
     460:	22088207          	vlseg2e8.v	v4,(a7)
     464:	006888b3          	add	a7,a7,t1
     468:	1a220157          	vmaxu.vv	v2,v2,v4
     46c:	02050127          	vse8.v	v2,(a0)
     470:	00f50533          	add	a0,a0,a5
     474:	fa071ee3          	bnez	a4,430 <tvmgen_default_fused_nn_max_pool2d+0x60>
     478:	060e8f23          	sb	zero,126(t4)
     47c:	ffee4703          	lbu	a4,-2(t3)
     480:	06ee8f23          	sb	a4,126(t4)
     484:	fffe4783          	lbu	a5,-1(t3)
     488:	0ae7f7b3          	maxu	a5,a5,a4
     48c:	06fe8f23          	sb	a5,126(t4)
     490:	000e4703          	lbu	a4,0(t3)
     494:	0af777b3          	maxu	a5,a4,a5
     498:	06fe8f23          	sb	a5,126(t4)
     49c:	100f0f13          	addi	t5,t5,256
     4a0:	080e8e93          	addi	t4,t4,128
     4a4:	100e0e13          	addi	t3,t3,256
     4a8:	f5ff12e3          	bne	t5,t6,3ec <tvmgen_default_fused_nn_max_pool2d+0x1c>
     4ac:	00000513          	li	a0,0
     4b0:	00008067          	ret
     4b4:	000f0713          	mv	a4,t5
     4b8:	000e8793          	mv	a5,t4
     4bc:	00078023          	sb	zero,0(a5)
     4c0:	00074603          	lbu	a2,0(a4)
     4c4:	00270713          	addi	a4,a4,2
     4c8:	00178793          	addi	a5,a5,1
     4cc:	fec78fa3          	sb	a2,-1(a5)
     4d0:	fff74683          	lbu	a3,-1(a4)
     4d4:	0ac6f6b3          	maxu	a3,a3,a2
     4d8:	fed78fa3          	sb	a3,-1(a5)
     4dc:	00074603          	lbu	a2,0(a4)
     4e0:	0ad676b3          	maxu	a3,a2,a3
     4e4:	fed78fa3          	sb	a3,-1(a5)
     4e8:	fcee1ae3          	bne	t3,a4,4bc <tvmgen_default_fused_nn_max_pool2d+0xec>
     4ec:	fb1ff06f          	j	49c <tvmgen_default_fused_nn_max_pool2d+0xcc>

000004f0 <tvmgen_default___tvm_main__>:
     4f0:	fd010113          	addi	sp,sp,-48
     4f4:	01312e23          	sw	s3,28(sp)
     4f8:	00058993          	mv	s3,a1
     4fc:	00068593          	mv	a1,a3
     500:	02812423          	sw	s0,40(sp)
     504:	03212023          	sw	s2,32(sp)
     508:	02112623          	sw	ra,44(sp)
     50c:	00068913          	mv	s2,a3
     510:	00060413          	mv	s0,a2
     514:	268000ef          	jal	77c <tvmgen_rootbed_npu_main_0>
     518:	1a051863          	bnez	a0,6c8 <tvmgen_default___tvm_main__+0x1d8>
     51c:	02912223          	sw	s1,36(sp)
     520:	7ff90493          	addi	s1,s2,2047
     524:	02148493          	addi	s1,s1,33
     528:	00048593          	mv	a1,s1
     52c:	00090513          	mv	a0,s2
     530:	440000ef          	jal	970 <tvmgen_rootbed_npu_main_1>
     534:	18051863          	bnez	a0,6c4 <tvmgen_default___tvm_main__+0x1d4>
     538:	00090593          	mv	a1,s2
     53c:	00048513          	mv	a0,s1
     540:	6a8000ef          	jal	be8 <tvmgen_rootbed_npu_main_2>
     544:	18051063          	bnez	a0,6c4 <tvmgen_default___tvm_main__+0x1d4>
     548:	00048593          	mv	a1,s1
     54c:	00090513          	mv	a0,s2
     550:	355000ef          	jal	10a4 <tvmgen_rootbed_npu_main_3>
     554:	16051863          	bnez	a0,6c4 <tvmgen_default___tvm_main__+0x1d4>
     558:	0c0077d7          	vsetvli	a5,zero,e8,m1,ta,ma
     55c:	5e0030d7          	vmv.v.i	v1,0
     560:	7ff90f93          	addi	t6,s2,2047
     564:	7ff90693          	addi	a3,s2,2047
     568:	7ff90293          	addi	t0,s2,2047
     56c:	022f8f93          	addi	t6,t6,34
     570:	12068693          	addi	a3,a3,288
     574:	01228293          	addi	t0,t0,18
     578:	41090513          	addi	a0,s2,1040
     57c:	00090493          	mv	s1,s2
     580:	41190f13          	addi	t5,s2,1041
     584:	fe0f0fa3          	sb	zero,-1(t5)
     588:	f016c703          	lbu	a4,-255(a3)
     58c:	000f8e13          	mv	t3,t6
     590:	f0468313          	addi	t1,a3,-252
     594:	feef0fa3          	sb	a4,-1(t5)
     598:	f026c783          	lbu	a5,-254(a3)
     59c:	000f0893          	mv	a7,t5
     5a0:	000f0813          	mv	a6,t5
     5a4:	0ae7f7b3          	maxu	a5,a5,a4
     5a8:	feff0fa3          	sb	a5,-1(t5)
     5ac:	000f0593          	mv	a1,t5
     5b0:	000f0613          	mv	a2,t5
     5b4:	07e00713          	li	a4,126
     5b8:	0c0777d7          	vsetvli	a5,a4,e8,m1,ta,ma
     5bc:	020600a7          	vse8.v	v1,(a2)
     5c0:	00179e93          	slli	t4,a5,0x1
     5c4:	40f70733          	sub	a4,a4,a5
     5c8:	00f60633          	add	a2,a2,a5
     5cc:	220e0107          	vlseg2e8.v	v2,(t3)
     5d0:	01de0e33          	add	t3,t3,t4
     5d4:	02058127          	vse8.v	v2,(a1)
     5d8:	1a218157          	vmaxu.vv	v2,v2,v3
     5dc:	00f585b3          	add	a1,a1,a5
     5e0:	02080127          	vse8.v	v2,(a6)
     5e4:	00f80833          	add	a6,a6,a5
     5e8:	22030207          	vlseg2e8.v	v4,(t1)
     5ec:	01d30333          	add	t1,t1,t4
     5f0:	1a220157          	vmaxu.vv	v2,v2,v4
     5f4:	02088127          	vse8.v	v2,(a7)
     5f8:	00f888b3          	add	a7,a7,a5
     5fc:	fa071ee3          	bnez	a4,5b8 <tvmgen_default___tvm_main__+0xc8>
     600:	060f0f23          	sb	zero,126(t5)
     604:	ffe6c703          	lbu	a4,-2(a3)
     608:	080f0f13          	addi	t5,t5,128
     60c:	100f8f93          	addi	t6,t6,256
     610:	feef0f23          	sb	a4,-2(t5)
     614:	fff6c783          	lbu	a5,-1(a3)
     618:	10068693          	addi	a3,a3,256
     61c:	0ae7f7b3          	maxu	a5,a5,a4
     620:	feff0f23          	sb	a5,-2(t5)
     624:	f006c703          	lbu	a4,-256(a3)
     628:	0af777b3          	maxu	a5,a4,a5
     62c:	feff0f23          	sb	a5,-2(t5)
     630:	f5e29ae3          	bne	t0,t5,584 <tvmgen_default___tvm_main__+0x94>
     634:	00090593          	mv	a1,s2
     638:	418000ef          	jal	a50 <tvmgen_rootbed_npu_main_4>
     63c:	08051463          	bnez	a0,6c4 <tvmgen_default___tvm_main__+0x1d4>
     640:	000027b7          	lui	a5,0x2
     644:	00f907b3          	add	a5,s2,a5
     648:	00078593          	mv	a1,a5
     64c:	00090513          	mv	a0,s2
     650:	00f12623          	sw	a5,12(sp)
     654:	0d9000ef          	jal	f2c <tvmgen_rootbed_npu_main_5>
     658:	06051663          	bnez	a0,6c4 <tvmgen_default___tvm_main__+0x1d4>
     65c:	00003637          	lui	a2,0x3
     660:	00c12783          	lw	a5,12(sp)
     664:	80060613          	addi	a2,a2,-2048 # 2800 <global_const_workspace+0x9d0>
     668:	00c90633          	add	a2,s2,a2
     66c:	0007c703          	lbu	a4,0(a5) # 2000 <global_const_workspace+0x1d0>
     670:	00178793          	addi	a5,a5,1
     674:	00448493          	addi	s1,s1,4
     678:	d00777d3          	fcvt.s.w	fa5,a4
     67c:	fef4ae27          	fsw	fa5,-4(s1)
     680:	fef616e3          	bne	a2,a5,66c <tvmgen_default___tvm_main__+0x17c>
     684:	00090693          	mv	a3,s2
     688:	00040613          	mv	a2,s0
     68c:	00090593          	mv	a1,s2
     690:	00090513          	mv	a0,s2
     694:	b21ff0ef          	jal	1b4 <tvmgen_default_fused_nn_avg_pool2d>
     698:	00040613          	mv	a2,s0
     69c:	02812403          	lw	s0,40(sp)
     6a0:	02412483          	lw	s1,36(sp)
     6a4:	02c12083          	lw	ra,44(sp)
     6a8:	00090693          	mv	a3,s2
     6ac:	00098593          	mv	a1,s3
     6b0:	00090513          	mv	a0,s2
     6b4:	01c12983          	lw	s3,28(sp)
     6b8:	02012903          	lw	s2,32(sp)
     6bc:	03010113          	addi	sp,sp,48
     6c0:	bb9ff06f          	j	278 <tvmgen_default_fused_nn_contrib_dense_pack_add_multiply_floor_clip_cast>
     6c4:	02412483          	lw	s1,36(sp)
     6c8:	02c12083          	lw	ra,44(sp)
     6cc:	02812403          	lw	s0,40(sp)
     6d0:	02012903          	lw	s2,32(sp)
     6d4:	01c12983          	lw	s3,28(sp)
     6d8:	fff00513          	li	a0,-1
     6dc:	03010113          	addi	sp,sp,48
     6e0:	00008067          	ret

000006e4 <tvmgen_rootbed_npu_main_0_>:
     6e4:	ff010113          	addi	sp,sp,-16
     6e8:	00812423          	sw	s0,8(sp)
     6ec:	10400613          	li	a2,260
     6f0:	00050413          	mv	s0,a0
     6f4:	00058513          	mv	a0,a1
     6f8:	00000593          	li	a1,0
     6fc:	00112623          	sw	ra,12(sp)
     700:	295000ef          	jal	1194 <memset>
     704:	40850633          	sub	a2,a0,s0
     708:	c22026f3          	csrr	a3,vlenb
     70c:	00160613          	addi	a2,a2,1
     710:	ffe68693          	addi	a3,a3,-2
     714:	02c6fc63          	bgeu	a3,a2,74c <tvmgen_rootbed_npu_main_0_+0x68>
     718:	00250713          	addi	a4,a0,2
     71c:	10000693          	li	a3,256
     720:	0c06f7d7          	vsetvli	a5,a3,e8,m1,ta,ma
     724:	02040087          	vle8.v	v1,(s0)
     728:	40f686b3          	sub	a3,a3,a5
     72c:	00f40433          	add	s0,s0,a5
     730:	020700a7          	vse8.v	v1,(a4)
     734:	00f70733          	add	a4,a4,a5
     738:	fe0694e3          	bnez	a3,720 <tvmgen_rootbed_npu_main_0_+0x3c>
     73c:	00c12083          	lw	ra,12(sp)
     740:	00812403          	lw	s0,8(sp)
     744:	01010113          	addi	sp,sp,16
     748:	00008067          	ret
     74c:	00040713          	mv	a4,s0
     750:	00250793          	addi	a5,a0,2
     754:	10040613          	addi	a2,s0,256
     758:	00074683          	lbu	a3,0(a4)
     75c:	00170713          	addi	a4,a4,1
     760:	00178793          	addi	a5,a5,1
     764:	fed78fa3          	sb	a3,-1(a5)
     768:	fec718e3          	bne	a4,a2,758 <tvmgen_rootbed_npu_main_0_+0x74>
     76c:	00c12083          	lw	ra,12(sp)
     770:	00812403          	lw	s0,8(sp)
     774:	01010113          	addi	sp,sp,16
     778:	00008067          	ret

0000077c <tvmgen_rootbed_npu_main_0>:
     77c:	ff010113          	addi	sp,sp,-16
     780:	00812423          	sw	s0,8(sp)
     784:	10400613          	li	a2,260
     788:	00050413          	mv	s0,a0
     78c:	00058513          	mv	a0,a1
     790:	00000593          	li	a1,0
     794:	00112623          	sw	ra,12(sp)
     798:	1fd000ef          	jal	1194 <memset>
     79c:	00150613          	addi	a2,a0,1
     7a0:	c22026f3          	csrr	a3,vlenb
     7a4:	40860633          	sub	a2,a2,s0
     7a8:	ffe68693          	addi	a3,a3,-2
     7ac:	02c6fe63          	bgeu	a3,a2,7e8 <tvmgen_rootbed_npu_main_0+0x6c>
     7b0:	00250713          	addi	a4,a0,2
     7b4:	10000693          	li	a3,256
     7b8:	0c06f7d7          	vsetvli	a5,a3,e8,m1,ta,ma
     7bc:	02040087          	vle8.v	v1,(s0)
     7c0:	40f686b3          	sub	a3,a3,a5
     7c4:	00f40433          	add	s0,s0,a5
     7c8:	020700a7          	vse8.v	v1,(a4)
     7cc:	00f70733          	add	a4,a4,a5
     7d0:	fe0694e3          	bnez	a3,7b8 <tvmgen_rootbed_npu_main_0+0x3c>
     7d4:	00c12083          	lw	ra,12(sp)
     7d8:	00812403          	lw	s0,8(sp)
     7dc:	00000513          	li	a0,0
     7e0:	01010113          	addi	sp,sp,16
     7e4:	00008067          	ret
     7e8:	00040713          	mv	a4,s0
     7ec:	00250793          	addi	a5,a0,2
     7f0:	10040613          	addi	a2,s0,256
     7f4:	00074683          	lbu	a3,0(a4)
     7f8:	00170713          	addi	a4,a4,1
     7fc:	00178793          	addi	a5,a5,1
     800:	fed78fa3          	sb	a3,-1(a5)
     804:	fec718e3          	bne	a4,a2,7f4 <tvmgen_rootbed_npu_main_0+0x78>
     808:	00c12083          	lw	ra,12(sp)
     80c:	00812403          	lw	s0,8(sp)
     810:	00000513          	li	a0,0
     814:	01010113          	addi	sp,sp,16
     818:	00008067          	ret

0000081c <tvmgen_rootbed_npu_main_1_>:
     81c:	fd010113          	addi	sp,sp,-48
     820:	03212223          	sw	s2,36(sp)
     824:	cd00f057          	vsetivli	zero,1,e32,m1,ta,ma
     828:	00002937          	lui	s2,0x2
     82c:	01412e23          	sw	s4,28(sp)
     830:	01512c23          	sw	s5,24(sp)
     834:	8c090913          	addi	s2,s2,-1856 # 18c0 <tvmgen_rootbed_npu_main_1_bias_1>
     838:	00002ab7          	lui	s5,0x2
     83c:	00002a37          	lui	s4,0x2
     840:	42006557          	vmv.s.x	v10,zero
     844:	03312023          	sw	s3,32(sp)
     848:	01612a23          	sw	s6,20(sp)
     84c:	01712823          	sw	s7,16(sp)
     850:	01812623          	sw	s8,12(sp)
     854:	00050b93          	mv	s7,a0
     858:	00058c13          	mv	s8,a1
     85c:	02812623          	sw	s0,44(sp)
     860:	02912423          	sw	s1,40(sp)
     864:	02090e93          	addi	t4,s2,32
     868:	908a8a93          	addi	s5,s5,-1784 # 1908 <tvmgen_rootbed_npu_main_1_mult_2>
     86c:	928a0a13          	addi	s4,s4,-1752 # 1928 <tvmgen_rootbed_npu_main_1_shift_3>
     870:	00000993          	li	s3,0
     874:	00500f13          	li	t5,5
     878:	0ff00513          	li	a0,255
     87c:	10000593          	li	a1,256
     880:	00800b13          	li	s6,8
     884:	00092403          	lw	s0,0(s2)
     888:	00299393          	slli	t2,s3,0x2
     88c:	00899293          	slli	t0,s3,0x8
     890:	007a84b3          	add	s1,s5,t2
     894:	005c02b3          	add	t0,s8,t0
     898:	007a03b3          	add	t2,s4,t2
     89c:	000b8e13          	mv	t3,s7
     8a0:	00000f93          	li	t6,0
     8a4:	00040313          	mv	t1,s0
     8a8:	00000893          	li	a7,0
     8ac:	011e0633          	add	a2,t3,a7
     8b0:	011e86b3          	add	a3,t4,a7
     8b4:	00100713          	li	a4,1
     8b8:	00000813          	li	a6,0
     8bc:	0d2777d7          	vsetvli	a5,a4,e32,m4,ta,ma
     8c0:	02060107          	vle8.v	v2,(a2)
     8c4:	02068087          	vle8.v	v1,(a3)
     8c8:	5e003257          	vmv.v.i	v4,0
     8cc:	0c907057          	vsetvli	zero,zero,e16,m2,ta,ma
     8d0:	40f70733          	sub	a4,a4,a5
     8d4:	00f60633          	add	a2,a2,a5
     8d8:	4a23a457          	vsext.vf2	v8,v2
     8dc:	4a13a157          	vsext.vf2	v2,v1
     8e0:	00f686b3          	add	a3,a3,a5
     8e4:	f6242257          	vwmacc.vv	v4,v8,v2
     8e8:	0d207057          	vsetvli	zero,zero,e32,m4,ta,ma
     8ec:	02452257          	vredsum.vs	v4,v4,v10
     8f0:	424027d7          	vmv.x.s	a5,v4
     8f4:	00f80833          	add	a6,a6,a5
     8f8:	fc0712e3          	bnez	a4,8bc <tvmgen_rootbed_npu_main_1_+0xa0>
     8fc:	00188893          	addi	a7,a7,1
     900:	01030333          	add	t1,t1,a6
     904:	fbe894e3          	bne	a7,t5,8ac <tvmgen_rootbed_npu_main_1_+0x90>
     908:	0004a683          	lw	a3,0(s1)
     90c:	0003a703          	lw	a4,0(t2)
     910:	01f287b3          	add	a5,t0,t6
     914:	02d30333          	mul	t1,t1,a3
     918:	001f8f93          	addi	t6,t6,1
     91c:	001e0e13          	addi	t3,t3,1
     920:	40e35333          	sra	t1,t1,a4
     924:	0aa34333          	min	t1,t1,a0
     928:	0a036333          	max	t1,t1,zero
     92c:	00678023          	sb	t1,0(a5)
     930:	f6bf9ae3          	bne	t6,a1,8a4 <tvmgen_rootbed_npu_main_1_+0x88>
     934:	00198993          	addi	s3,s3,1
     938:	00490913          	addi	s2,s2,4
     93c:	005e8e93          	addi	t4,t4,5
     940:	f56992e3          	bne	s3,s6,884 <tvmgen_rootbed_npu_main_1_+0x68>
     944:	02c12403          	lw	s0,44(sp)
     948:	02812483          	lw	s1,40(sp)
     94c:	02412903          	lw	s2,36(sp)
     950:	02012983          	lw	s3,32(sp)
     954:	01c12a03          	lw	s4,28(sp)
     958:	01812a83          	lw	s5,24(sp)
     95c:	01412b03          	lw	s6,20(sp)
     960:	01012b83          	lw	s7,16(sp)
     964:	00c12c03          	lw	s8,12(sp)
     968:	03010113          	addi	sp,sp,48
     96c:	00008067          	ret

00000970 <tvmgen_rootbed_npu_main_1>:
     970:	ff010113          	addi	sp,sp,-16
     974:	00112623          	sw	ra,12(sp)
     978:	ea5ff0ef          	jal	81c <tvmgen_rootbed_npu_main_1_>
     97c:	00c12083          	lw	ra,12(sp)
     980:	00000513          	li	a0,0
     984:	01010113          	addi	sp,sp,16
     988:	00008067          	ret

0000098c <tvmgen_rootbed_npu_main_4_>:
     98c:	ff010113          	addi	sp,sp,-16
     990:	00812423          	sw	s0,8(sp)
     994:	41000613          	li	a2,1040
     998:	00050413          	mv	s0,a0
     99c:	00058513          	mv	a0,a1
     9a0:	00000593          	li	a1,0
     9a4:	00112623          	sw	ra,12(sp)
     9a8:	7ec000ef          	jal	1194 <memset>
     9ac:	00050813          	mv	a6,a0
     9b0:	c2202373          	csrr	t1,vlenb
     9b4:	408808b3          	sub	a7,a6,s0
     9b8:	00040513          	mv	a0,s0
     9bc:	00180813          	addi	a6,a6,1
     9c0:	08040593          	addi	a1,s0,128
     9c4:	40040e13          	addi	t3,s0,1024
     9c8:	ffe30313          	addi	t1,t1,-2
     9cc:	00080713          	mv	a4,a6
     9d0:	00050793          	mv	a5,a0
     9d4:	05137863          	bgeu	t1,a7,a24 <tvmgen_rootbed_npu_main_4_+0x98>
     9d8:	00050613          	mv	a2,a0
     9dc:	00080693          	mv	a3,a6
     9e0:	08000713          	li	a4,128
     9e4:	0c0777d7          	vsetvli	a5,a4,e8,m1,ta,ma
     9e8:	02060087          	vle8.v	v1,(a2)
     9ec:	40f70733          	sub	a4,a4,a5
     9f0:	00f60633          	add	a2,a2,a5
     9f4:	020680a7          	vse8.v	v1,(a3)
     9f8:	00f686b3          	add	a3,a3,a5
     9fc:	fe0714e3          	bnez	a4,9e4 <tvmgen_rootbed_npu_main_4_+0x58>
     a00:	08050513          	addi	a0,a0,128
     a04:	00288893          	addi	a7,a7,2
     a08:	08280813          	addi	a6,a6,130
     a0c:	08058593          	addi	a1,a1,128
     a10:	fbc51ee3          	bne	a0,t3,9cc <tvmgen_rootbed_npu_main_4_+0x40>
     a14:	00c12083          	lw	ra,12(sp)
     a18:	00812403          	lw	s0,8(sp)
     a1c:	01010113          	addi	sp,sp,16
     a20:	00008067          	ret
     a24:	0007c683          	lbu	a3,0(a5)
     a28:	00178793          	addi	a5,a5,1
     a2c:	00170713          	addi	a4,a4,1
     a30:	fed70fa3          	sb	a3,-1(a4)
     a34:	fcb786e3          	beq	a5,a1,a00 <tvmgen_rootbed_npu_main_4_+0x74>
     a38:	0007c683          	lbu	a3,0(a5)
     a3c:	00178793          	addi	a5,a5,1
     a40:	00170713          	addi	a4,a4,1
     a44:	fed70fa3          	sb	a3,-1(a4)
     a48:	fcb79ee3          	bne	a5,a1,a24 <tvmgen_rootbed_npu_main_4_+0x98>
     a4c:	fb5ff06f          	j	a00 <tvmgen_rootbed_npu_main_4_+0x74>

00000a50 <tvmgen_rootbed_npu_main_4>:
     a50:	ff010113          	addi	sp,sp,-16
     a54:	00812423          	sw	s0,8(sp)
     a58:	41000613          	li	a2,1040
     a5c:	00050413          	mv	s0,a0
     a60:	00058513          	mv	a0,a1
     a64:	00000593          	li	a1,0
     a68:	00112623          	sw	ra,12(sp)
     a6c:	728000ef          	jal	1194 <memset>
     a70:	00050813          	mv	a6,a0
     a74:	c2202373          	csrr	t1,vlenb
     a78:	408808b3          	sub	a7,a6,s0
     a7c:	00040513          	mv	a0,s0
     a80:	00180813          	addi	a6,a6,1
     a84:	08040593          	addi	a1,s0,128
     a88:	40040e13          	addi	t3,s0,1024
     a8c:	ffe30313          	addi	t1,t1,-2
     a90:	00080713          	mv	a4,a6
     a94:	00050793          	mv	a5,a0
     a98:	05137a63          	bgeu	t1,a7,aec <tvmgen_rootbed_npu_main_4+0x9c>
     a9c:	00050613          	mv	a2,a0
     aa0:	00080693          	mv	a3,a6
     aa4:	08000713          	li	a4,128
     aa8:	0c0777d7          	vsetvli	a5,a4,e8,m1,ta,ma
     aac:	02060087          	vle8.v	v1,(a2)
     ab0:	40f70733          	sub	a4,a4,a5
     ab4:	00f60633          	add	a2,a2,a5
     ab8:	020680a7          	vse8.v	v1,(a3)
     abc:	00f686b3          	add	a3,a3,a5
     ac0:	fe0714e3          	bnez	a4,aa8 <tvmgen_rootbed_npu_main_4+0x58>
     ac4:	08050513          	addi	a0,a0,128
     ac8:	00288893          	addi	a7,a7,2
     acc:	08280813          	addi	a6,a6,130
     ad0:	08058593          	addi	a1,a1,128
     ad4:	fbc51ee3          	bne	a0,t3,a90 <tvmgen_rootbed_npu_main_4+0x40>
     ad8:	00c12083          	lw	ra,12(sp)
     adc:	00812403          	lw	s0,8(sp)
     ae0:	00000513          	li	a0,0
     ae4:	01010113          	addi	sp,sp,16
     ae8:	00008067          	ret
     aec:	0007c683          	lbu	a3,0(a5)
     af0:	00178793          	addi	a5,a5,1
     af4:	00170713          	addi	a4,a4,1
     af8:	fed70fa3          	sb	a3,-1(a4)
     afc:	fcb784e3          	beq	a5,a1,ac4 <tvmgen_rootbed_npu_main_4+0x74>
     b00:	0007c683          	lbu	a3,0(a5)
     b04:	00178793          	addi	a5,a5,1
     b08:	00170713          	addi	a4,a4,1
     b0c:	fed70fa3          	sb	a3,-1(a4)
     b10:	fcb79ee3          	bne	a5,a1,aec <tvmgen_rootbed_npu_main_4+0x9c>
     b14:	fb1ff06f          	j	ac4 <tvmgen_rootbed_npu_main_4+0x74>

00000b18 <tvmgen_rootbed_npu_main_2_>:
     b18:	ff010113          	addi	sp,sp,-16
     b1c:	00001637          	lui	a2,0x1
     b20:	00812423          	sw	s0,8(sp)
     b24:	82060613          	addi	a2,a2,-2016 # 820 <tvmgen_rootbed_npu_main_1_+0x4>
     b28:	00050413          	mv	s0,a0
     b2c:	00058513          	mv	a0,a1
     b30:	00000593          	li	a1,0
     b34:	00112623          	sw	ra,12(sp)
     b38:	65c000ef          	jal	1194 <memset>
     b3c:	00050813          	mv	a6,a0
     b40:	408808b3          	sub	a7,a6,s0
     b44:	c2202373          	csrr	t1,vlenb
     b48:	7ff40e13          	addi	t3,s0,2047
     b4c:	00040513          	mv	a0,s0
     b50:	00188893          	addi	a7,a7,1
     b54:	00280813          	addi	a6,a6,2
     b58:	001e0e13          	addi	t3,t3,1
     b5c:	10040593          	addi	a1,s0,256
     b60:	ffe30313          	addi	t1,t1,-2
     b64:	00080713          	mv	a4,a6
     b68:	00050793          	mv	a5,a0
     b6c:	05137863          	bgeu	t1,a7,bbc <tvmgen_rootbed_npu_main_2_+0xa4>
     b70:	00050613          	mv	a2,a0
     b74:	00080693          	mv	a3,a6
     b78:	10000713          	li	a4,256
     b7c:	0c0777d7          	vsetvli	a5,a4,e8,m1,ta,ma
     b80:	02060087          	vle8.v	v1,(a2)
     b84:	40f70733          	sub	a4,a4,a5
     b88:	00f60633          	add	a2,a2,a5
     b8c:	020680a7          	vse8.v	v1,(a3)
     b90:	00f686b3          	add	a3,a3,a5
     b94:	fe0714e3          	bnez	a4,b7c <tvmgen_rootbed_npu_main_2_+0x64>
     b98:	10050513          	addi	a0,a0,256
     b9c:	00488893          	addi	a7,a7,4
     ba0:	10480813          	addi	a6,a6,260
     ba4:	10058593          	addi	a1,a1,256
     ba8:	fbc51ee3          	bne	a0,t3,b64 <tvmgen_rootbed_npu_main_2_+0x4c>
     bac:	00c12083          	lw	ra,12(sp)
     bb0:	00812403          	lw	s0,8(sp)
     bb4:	01010113          	addi	sp,sp,16
     bb8:	00008067          	ret
     bbc:	0007c683          	lbu	a3,0(a5)
     bc0:	00178793          	addi	a5,a5,1
     bc4:	00170713          	addi	a4,a4,1
     bc8:	fed70fa3          	sb	a3,-1(a4)
     bcc:	fcb786e3          	beq	a5,a1,b98 <tvmgen_rootbed_npu_main_2_+0x80>
     bd0:	0007c683          	lbu	a3,0(a5)
     bd4:	00178793          	addi	a5,a5,1
     bd8:	00170713          	addi	a4,a4,1
     bdc:	fed70fa3          	sb	a3,-1(a4)
     be0:	fcb79ee3          	bne	a5,a1,bbc <tvmgen_rootbed_npu_main_2_+0xa4>
     be4:	fb5ff06f          	j	b98 <tvmgen_rootbed_npu_main_2_+0x80>

00000be8 <tvmgen_rootbed_npu_main_2>:
     be8:	ff010113          	addi	sp,sp,-16
     bec:	00001637          	lui	a2,0x1
     bf0:	00812423          	sw	s0,8(sp)
     bf4:	82060613          	addi	a2,a2,-2016 # 820 <tvmgen_rootbed_npu_main_1_+0x4>
     bf8:	00050413          	mv	s0,a0
     bfc:	00058513          	mv	a0,a1
     c00:	00000593          	li	a1,0
     c04:	00112623          	sw	ra,12(sp)
     c08:	58c000ef          	jal	1194 <memset>
     c0c:	00150893          	addi	a7,a0,1
     c10:	c2202373          	csrr	t1,vlenb
     c14:	7ff40e13          	addi	t3,s0,2047
     c18:	00250813          	addi	a6,a0,2
     c1c:	001e0e13          	addi	t3,t3,1
     c20:	00040513          	mv	a0,s0
     c24:	408888b3          	sub	a7,a7,s0
     c28:	10040593          	addi	a1,s0,256
     c2c:	ffe30313          	addi	t1,t1,-2
     c30:	00080713          	mv	a4,a6
     c34:	00050793          	mv	a5,a0
     c38:	05137a63          	bgeu	t1,a7,c8c <tvmgen_rootbed_npu_main_2+0xa4>
     c3c:	00050613          	mv	a2,a0
     c40:	00080693          	mv	a3,a6
     c44:	10000713          	li	a4,256
     c48:	0c0777d7          	vsetvli	a5,a4,e8,m1,ta,ma
     c4c:	02060087          	vle8.v	v1,(a2)
     c50:	40f70733          	sub	a4,a4,a5
     c54:	00f60633          	add	a2,a2,a5
     c58:	020680a7          	vse8.v	v1,(a3)
     c5c:	00f686b3          	add	a3,a3,a5
     c60:	fe0714e3          	bnez	a4,c48 <tvmgen_rootbed_npu_main_2+0x60>
     c64:	10050513          	addi	a0,a0,256
     c68:	00488893          	addi	a7,a7,4
     c6c:	10480813          	addi	a6,a6,260
     c70:	10058593          	addi	a1,a1,256
     c74:	fbc51ee3          	bne	a0,t3,c30 <tvmgen_rootbed_npu_main_2+0x48>
     c78:	00c12083          	lw	ra,12(sp)
     c7c:	00812403          	lw	s0,8(sp)
     c80:	00000513          	li	a0,0
     c84:	01010113          	addi	sp,sp,16
     c88:	00008067          	ret
     c8c:	0007c683          	lbu	a3,0(a5)
     c90:	00178793          	addi	a5,a5,1
     c94:	00170713          	addi	a4,a4,1
     c98:	fed70fa3          	sb	a3,-1(a4)
     c9c:	fcb784e3          	beq	a5,a1,c64 <tvmgen_rootbed_npu_main_2+0x7c>
     ca0:	0007c683          	lbu	a3,0(a5)
     ca4:	00178793          	addi	a5,a5,1
     ca8:	00170713          	addi	a4,a4,1
     cac:	fed70fa3          	sb	a3,-1(a4)
     cb0:	fcb79ee3          	bne	a5,a1,c8c <tvmgen_rootbed_npu_main_2+0xa4>
     cb4:	fb1ff06f          	j	c64 <tvmgen_rootbed_npu_main_2+0x7c>

00000cb8 <tvmgen_rootbed_npu_main_5_>:
     cb8:	fd010113          	addi	sp,sp,-48
     cbc:	02812623          	sw	s0,44(sp)
     cc0:	00002437          	lui	s0,0x2
     cc4:	94840413          	addi	s0,s0,-1720 # 1948 <tvmgen_rootbed_npu_main_5_bias_1>
     cc8:	02912423          	sw	s1,40(sp)
     ccc:	04040493          	addi	s1,s0,64
     cd0:	03212223          	sw	s2,36(sp)
     cd4:	03312023          	sw	s3,32(sp)
     cd8:	01412e23          	sw	s4,28(sp)
     cdc:	01512c23          	sw	s5,24(sp)
     ce0:	01b12023          	sw	s11,0(sp)
     ce4:	01612a23          	sw	s6,20(sp)
     ce8:	01712823          	sw	s7,16(sp)
     cec:	01812623          	sw	s8,12(sp)
     cf0:	01912423          	sw	s9,8(sp)
     cf4:	01a12223          	sw	s10,4(sp)
     cf8:	00050a13          	mv	s4,a0
     cfc:	00058d93          	mv	s11,a1
     d00:	00048a93          	mv	s5,s1
     d04:	08040993          	addi	s3,s0,128
     d08:	0c040713          	addi	a4,s0,192
     d0c:	08050293          	addi	t0,a0,128
     d10:	00000913          	li	s2,0
     d14:	01e00613          	li	a2,30
     d18:	0ff00f93          	li	t6,255
     d1c:	00042503          	lw	a0,0(s0)
     d20:	0004a583          	lw	a1,0(s1)
     d24:	0009a383          	lw	t2,0(s3)
     d28:	000a0793          	mv	a5,s4
     d2c:	012d8f33          	add	t5,s11,s2
     d30:	00c0006f          	j	d3c <tvmgen_rootbed_npu_main_5_+0x84>
     d34:	00070603          	lb	a2,0(a4)
     d38:	001f0f13          	addi	t5,t5,1
     d3c:	0007c683          	lbu	a3,0(a5)
     d40:	0017ce83          	lbu	t4,1(a5)
     d44:	00170d03          	lb	s10,1(a4)
     d48:	0027ce03          	lbu	t3,2(a5)
     d4c:	00270c83          	lb	s9,2(a4)
     d50:	02c68633          	mul	a2,a3,a2
     d54:	0827c303          	lbu	t1,130(a5)
     d58:	00370c03          	lb	s8,3(a4)
     d5c:	0837c883          	lbu	a7,131(a5)
     d60:	00470b83          	lb	s7,4(a4)
     d64:	0847c803          	lbu	a6,132(a5)
     d68:	00570b03          	lb	s6,5(a4)
     d6c:	1047c683          	lbu	a3,260(a5)
     d70:	00178793          	addi	a5,a5,1
     d74:	03ae8eb3          	mul	t4,t4,s10
     d78:	00a60633          	add	a2,a2,a0
     d7c:	00670d03          	lb	s10,6(a4)
     d80:	039e0e33          	mul	t3,t3,s9
     d84:	00ce8eb3          	add	t4,t4,a2
     d88:	00770c83          	lb	s9,7(a4)
     d8c:	1047c603          	lbu	a2,260(a5)
     d90:	03830333          	mul	t1,t1,s8
     d94:	01de0e33          	add	t3,t3,t4
     d98:	00870c03          	lb	s8,8(a4)
     d9c:	1057ce83          	lbu	t4,261(a5)
     da0:	037888b3          	mul	a7,a7,s7
     da4:	01c30333          	add	t1,t1,t3
     da8:	00970b83          	lb	s7,9(a4)
     dac:	1857ce03          	lbu	t3,389(a5)
     db0:	03680833          	mul	a6,a6,s6
     db4:	006888b3          	add	a7,a7,t1
     db8:	00a70b03          	lb	s6,10(a4)
     dbc:	1867c303          	lbu	t1,390(a5)
     dc0:	03a686b3          	mul	a3,a3,s10
     dc4:	01180833          	add	a6,a6,a7
     dc8:	00b70d03          	lb	s10,11(a4)
     dcc:	1877c883          	lbu	a7,391(a5)
     dd0:	03960633          	mul	a2,a2,s9
     dd4:	010686b3          	add	a3,a3,a6
     dd8:	00c70c83          	lb	s9,12(a4)
     ddc:	2077c803          	lbu	a6,519(a5)
     de0:	038e8eb3          	mul	t4,t4,s8
     de4:	00d60633          	add	a2,a2,a3
     de8:	00d70c03          	lb	s8,13(a4)
     dec:	2087c683          	lbu	a3,520(a5)
     df0:	037e0e33          	mul	t3,t3,s7
     df4:	00ce8eb3          	add	t4,t4,a2
     df8:	00e70b83          	lb	s7,14(a4)
     dfc:	2097c603          	lbu	a2,521(a5)
     e00:	03630333          	mul	t1,t1,s6
     e04:	01de0e33          	add	t3,t3,t4
     e08:	00f70b03          	lb	s6,15(a4)
     e0c:	2897ce83          	lbu	t4,649(a5)
     e10:	03a888b3          	mul	a7,a7,s10
     e14:	01c30333          	add	t1,t1,t3
     e18:	28a7cd03          	lbu	s10,650(a5)
     e1c:	01070e03          	lb	t3,16(a4)
     e20:	03980833          	mul	a6,a6,s9
     e24:	006888b3          	add	a7,a7,t1
     e28:	28b7cc83          	lbu	s9,651(a5)
     e2c:	01170303          	lb	t1,17(a4)
     e30:	038686b3          	mul	a3,a3,s8
     e34:	01180833          	add	a6,a6,a7
     e38:	30b7cc03          	lbu	s8,779(a5)
     e3c:	01270883          	lb	a7,18(a4)
     e40:	03760633          	mul	a2,a2,s7
     e44:	010686b3          	add	a3,a3,a6
     e48:	30c7cb83          	lbu	s7,780(a5)
     e4c:	01370803          	lb	a6,19(a4)
     e50:	036e8eb3          	mul	t4,t4,s6
     e54:	00d606b3          	add	a3,a2,a3
     e58:	01470b03          	lb	s6,20(a4)
     e5c:	30d7c603          	lbu	a2,781(a5)
     e60:	03cd0e33          	mul	t3,s10,t3
     e64:	00de86b3          	add	a3,t4,a3
     e68:	01570d03          	lb	s10,21(a4)
     e6c:	38d7ce83          	lbu	t4,909(a5)
     e70:	026c8333          	mul	t1,s9,t1
     e74:	00de06b3          	add	a3,t3,a3
     e78:	01670c83          	lb	s9,22(a4)
     e7c:	38e7ce03          	lbu	t3,910(a5)
     e80:	031c08b3          	mul	a7,s8,a7
     e84:	00d30c33          	add	s8,t1,a3
     e88:	38f7c683          	lbu	a3,911(a5)
     e8c:	01770303          	lb	t1,23(a4)
     e90:	030b8833          	mul	a6,s7,a6
     e94:	018888b3          	add	a7,a7,s8
     e98:	03660633          	mul	a2,a2,s6
     e9c:	01180833          	add	a6,a6,a7
     ea0:	03ae8eb3          	mul	t4,t4,s10
     ea4:	01060833          	add	a6,a2,a6
     ea8:	039e0633          	mul	a2,t3,s9
     eac:	010e8eb3          	add	t4,t4,a6
     eb0:	026686b3          	mul	a3,a3,t1
     eb4:	01d60633          	add	a2,a2,t4
     eb8:	00c686b3          	add	a3,a3,a2
     ebc:	02b686b3          	mul	a3,a3,a1
     ec0:	4076d6b3          	sra	a3,a3,t2
     ec4:	0bf6c6b3          	min	a3,a3,t6
     ec8:	0a06e6b3          	max	a3,a3,zero
     ecc:	00df0023          	sb	a3,0(t5)
     ed0:	e6f292e3          	bne	t0,a5,d34 <tvmgen_rootbed_npu_main_5_+0x7c>
     ed4:	00440413          	addi	s0,s0,4
     ed8:	008a8e63          	beq	s5,s0,ef4 <tvmgen_rootbed_npu_main_5_+0x23c>
     edc:	01870713          	addi	a4,a4,24
     ee0:	00448493          	addi	s1,s1,4
     ee4:	00498993          	addi	s3,s3,4
     ee8:	08090913          	addi	s2,s2,128
     eec:	00070603          	lb	a2,0(a4)
     ef0:	e2dff06f          	j	d1c <tvmgen_rootbed_npu_main_5_+0x64>
     ef4:	02c12403          	lw	s0,44(sp)
     ef8:	02812483          	lw	s1,40(sp)
     efc:	02412903          	lw	s2,36(sp)
     f00:	02012983          	lw	s3,32(sp)
     f04:	01c12a03          	lw	s4,28(sp)
     f08:	01812a83          	lw	s5,24(sp)
     f0c:	01412b03          	lw	s6,20(sp)
     f10:	01012b83          	lw	s7,16(sp)
     f14:	00c12c03          	lw	s8,12(sp)
     f18:	00812c83          	lw	s9,8(sp)
     f1c:	00412d03          	lw	s10,4(sp)
     f20:	00012d83          	lw	s11,0(sp)
     f24:	03010113          	addi	sp,sp,48
     f28:	00008067          	ret

00000f2c <tvmgen_rootbed_npu_main_5>:
     f2c:	ff010113          	addi	sp,sp,-16
     f30:	00112623          	sw	ra,12(sp)
     f34:	d85ff0ef          	jal	cb8 <tvmgen_rootbed_npu_main_5_>
     f38:	00c12083          	lw	ra,12(sp)
     f3c:	00000513          	li	a0,0
     f40:	01010113          	addi	sp,sp,16
     f44:	00008067          	ret

00000f48 <tvmgen_rootbed_npu_main_3_>:
     f48:	fd010113          	addi	sp,sp,-48
     f4c:	02912423          	sw	s1,40(sp)
     f50:	000024b7          	lui	s1,0x2
     f54:	b8848493          	addi	s1,s1,-1144 # 1b88 <tvmgen_rootbed_npu_main_3_bias_1>
     f58:	03212223          	sw	s2,36(sp)
     f5c:	7ff50913          	addi	s2,a0,2047
     f60:	03312023          	sw	s3,32(sp)
     f64:	01412e23          	sw	s4,28(sp)
     f68:	01512c23          	sw	s5,24(sp)
     f6c:	01612a23          	sw	s6,20(sp)
     f70:	02812623          	sw	s0,44(sp)
     f74:	01712823          	sw	s7,16(sp)
     f78:	01812623          	sw	s8,12(sp)
     f7c:	01912423          	sw	s9,8(sp)
     f80:	01a12223          	sw	s10,4(sp)
     f84:	01b12023          	sw	s11,0(sp)
     f88:	02190913          	addi	s2,s2,33
     f8c:	00058e13          	mv	t3,a1
     f90:	02048a93          	addi	s5,s1,32
     f94:	04048a13          	addi	s4,s1,64
     f98:	06048e93          	addi	t4,s1,96
     f9c:	00000993          	li	s3,0
     fa0:	0ff00f93          	li	t6,255
     fa4:	10000f13          	li	t5,256
     fa8:	04000b13          	li	s6,64
     fac:	0004a403          	lw	s0,0(s1)
     fb0:	000aa383          	lw	t2,0(s5)
     fb4:	000a2283          	lw	t0,0(s4)
     fb8:	00090893          	mv	a7,s2
     fbc:	00000313          	li	t1,0
     fc0:	80088793          	addi	a5,a7,-2048
     fc4:	00130313          	addi	t1,t1,1
     fc8:	fe078793          	addi	a5,a5,-32
     fcc:	000e8713          	mv	a4,t4
     fd0:	00040c93          	mv	s9,s0
     fd4:	00070683          	lb	a3,0(a4)
     fd8:	0007c803          	lbu	a6,0(a5)
     fdc:	0017c503          	lbu	a0,1(a5)
     fe0:	00170d83          	lb	s11,1(a4)
     fe4:	0027c603          	lbu	a2,2(a5)
     fe8:	00270d03          	lb	s10,2(a4)
     fec:	02d80833          	mul	a6,a6,a3
     ff0:	00370c03          	lb	s8,3(a4)
     ff4:	0037c683          	lbu	a3,3(a5)
     ff8:	0047c583          	lbu	a1,4(a5)
     ffc:	00470b83          	lb	s7,4(a4)
    1000:	10478793          	addi	a5,a5,260
    1004:	00570713          	addi	a4,a4,5
    1008:	03b50533          	mul	a0,a0,s11
    100c:	01980833          	add	a6,a6,s9
    1010:	03a60633          	mul	a2,a2,s10
    1014:	01050533          	add	a0,a0,a6
    1018:	038686b3          	mul	a3,a3,s8
    101c:	00a60633          	add	a2,a2,a0
    1020:	037585b3          	mul	a1,a1,s7
    1024:	00c686b3          	add	a3,a3,a2
    1028:	00d58cb3          	add	s9,a1,a3
    102c:	faf894e3          	bne	a7,a5,fd4 <tvmgen_rootbed_npu_main_3_+0x8c>
    1030:	027c8cb3          	mul	s9,s9,t2
    1034:	006e07b3          	add	a5,t3,t1
    1038:	00188893          	addi	a7,a7,1
    103c:	405cdcb3          	sra	s9,s9,t0
    1040:	0bfcccb3          	min	s9,s9,t6
    1044:	0a0cecb3          	max	s9,s9,zero
    1048:	ff978fa3          	sb	s9,-1(a5)
    104c:	f7e31ae3          	bne	t1,t5,fc0 <tvmgen_rootbed_npu_main_3_+0x78>
    1050:	00898993          	addi	s3,s3,8
    1054:	00448493          	addi	s1,s1,4
    1058:	004a8a93          	addi	s5,s5,4
    105c:	004a0a13          	addi	s4,s4,4
    1060:	100e0e13          	addi	t3,t3,256
    1064:	028e8e93          	addi	t4,t4,40
    1068:	f56992e3          	bne	s3,s6,fac <tvmgen_rootbed_npu_main_3_+0x64>
    106c:	02c12403          	lw	s0,44(sp)
    1070:	02812483          	lw	s1,40(sp)
    1074:	02412903          	lw	s2,36(sp)
    1078:	02012983          	lw	s3,32(sp)
    107c:	01c12a03          	lw	s4,28(sp)
    1080:	01812a83          	lw	s5,24(sp)
    1084:	01412b03          	lw	s6,20(sp)
    1088:	01012b83          	lw	s7,16(sp)
    108c:	00c12c03          	lw	s8,12(sp)
    1090:	00812c83          	lw	s9,8(sp)
    1094:	00412d03          	lw	s10,4(sp)
    1098:	00012d83          	lw	s11,0(sp)
    109c:	03010113          	addi	sp,sp,48
    10a0:	00008067          	ret

000010a4 <tvmgen_rootbed_npu_main_3>:
    10a4:	ff010113          	addi	sp,sp,-16
    10a8:	00112623          	sw	ra,12(sp)
    10ac:	e9dff0ef          	jal	f48 <tvmgen_rootbed_npu_main_3_>
    10b0:	00c12083          	lw	ra,12(sp)
    10b4:	00000513          	li	a0,0
    10b8:	01010113          	addi	sp,sp,16
    10bc:	00008067          	ret

000010c0 <coralnpu_exception_handler>:
// See the License for the specific language governing permissions and
// limitations under the License.

extern "C" {
void __attribute__((weak)) coralnpu_exception_handler() {
  asm volatile("ebreak");
    10c0:	00100073          	ebreak
  while (1) {}
    10c4:	0000006f          	j	10c4 <coralnpu_exception_handler+0x4>

000010c8 <__cxa_guard_acquire>:
// Called to acquire the lock on the guard variable.
// *guard_object: Pointer to the guard variable.
// Returns 1 if the object should be initialized, 0 otherwise.
int __cxa_guard_acquire(__guard* guard_object) {
  // If the first byte is 0, initialization is needed.
  if (*(reinterpret_cast<char*>(guard_object)) == 0) {
    10c8:	00054503          	lbu	a0,0(a0)
    return 1;
  }
  return 0;
}
    10cc:	00153513          	seqz	a0,a0
    10d0:	00008067          	ret

000010d4 <__cxa_guard_release>:

// Called to release the lock on the guard variable after initialization.
// *guard_object: Pointer to the guard variable.
void __cxa_guard_release(__guard* guard_object) {
  // Set the first byte to 1 to indicate initialization is complete.
  *(reinterpret_cast<char*>(guard_object)) = 1;
    10d4:	00100793          	li	a5,1
    10d8:	00f50023          	sb	a5,0(a0)
}
    10dc:	00008067          	ret

000010e0 <__cxa_guard_abort>:

// Called if initialization fails and the guard needs to be aborted.
void __cxa_guard_abort(__guard* guard_object) {
  // In a bare-metal system, there's not much to do here.
  // We can leave it empty or add some debug output if needed.
}
    10e0:	00008067          	ret

000010e4 <__cxa_atexit>:
static atexit_entry atexit_entries[MAX_ATEXIT_ENTRIES];
static int atexit_count = 0;

// Called to register a destructor for a global/static object.
int __cxa_atexit(void (*destructor)(void*), void* arg, void* dso_handle) {
  if (atexit_count >= MAX_ATEXIT_ENTRIES) {
    10e4:	9201a783          	lw	a5,-1760(gp) # 100120 <_ZN10__cxxabiv1L12atexit_countE>
    10e8:	00700713          	li	a4,7
    10ec:	02f74463          	blt	a4,a5,1114 <__cxa_atexit+0x30>
    return -1;
  }
  atexit_entries[atexit_count].destructor = destructor;
    10f0:	00379693          	slli	a3,a5,0x3
    10f4:	92418713          	addi	a4,gp,-1756 # 100124 <_ZN10__cxxabiv1L14atexit_entriesE>
    10f8:	00d70733          	add	a4,a4,a3
    10fc:	00a72023          	sw	a0,0(a4)
  atexit_entries[atexit_count].arg = arg;
    1100:	00b72223          	sw	a1,4(a4)
  atexit_count++;
    1104:	00178793          	addi	a5,a5,1
    1108:	92f1a023          	sw	a5,-1760(gp) # 100120 <_ZN10__cxxabiv1L12atexit_countE>
  return 0;
    110c:	00000513          	li	a0,0
    1110:	00008067          	ret
    return -1;
    1114:	fff00513          	li	a0,-1
}
    1118:	00008067          	ret

0000111c <__cxa_finalize>:

// Called to execute all registered destructors.
void __cxa_finalize(void* dso_handle) {
    111c:	ff010113          	addi	sp,sp,-16
    1120:	00112623          	sw	ra,12(sp)
    1124:	00912223          	sw	s1,4(sp)
  for (int i = atexit_count - 1; i >= 0; i--) {
    1128:	9201a783          	lw	a5,-1760(gp) # 100120 <_ZN10__cxxabiv1L12atexit_countE>
    112c:	fff78493          	addi	s1,a5,-1
    1130:	0404c463          	bltz	s1,1178 <__cxa_finalize+0x5c>
    1134:	00812423          	sw	s0,8(sp)
    1138:	01212023          	sw	s2,0(sp)
    113c:	00379793          	slli	a5,a5,0x3
    1140:	92418413          	addi	s0,gp,-1756 # 100124 <_ZN10__cxxabiv1L14atexit_entriesE>
    1144:	00f40433          	add	s0,s0,a5
    1148:	fff00913          	li	s2,-1
    114c:	0100006f          	j	115c <__cxa_finalize+0x40>
    1150:	fff48493          	addi	s1,s1,-1
    1154:	ff840413          	addi	s0,s0,-8
    1158:	01248c63          	beq	s1,s2,1170 <__cxa_finalize+0x54>
    if (atexit_entries[i].destructor) {
    115c:	ff842783          	lw	a5,-8(s0)
    1160:	fe0788e3          	beqz	a5,1150 <__cxa_finalize+0x34>
      atexit_entries[i].destructor(atexit_entries[i].arg);
    1164:	ffc42503          	lw	a0,-4(s0)
    1168:	000780e7          	jalr	a5
    116c:	fe5ff06f          	j	1150 <__cxa_finalize+0x34>
    1170:	00812403          	lw	s0,8(sp)
    1174:	00012903          	lw	s2,0(sp)
    }
  }
  atexit_count = 0;
    1178:	9201a023          	sw	zero,-1760(gp) # 100120 <_ZN10__cxxabiv1L12atexit_countE>
}
    117c:	00c12083          	lw	ra,12(sp)
    1180:	00412483          	lw	s1,4(sp)
    1184:	01010113          	addi	sp,sp,16
    1188:	00008067          	ret

0000118c <__cxa_pure_virtual>:

// Called if a pure virtual function is called.
void __cxa_pure_virtual() { asm volatile("ebreak"); }
    118c:	00100073          	ebreak
    1190:	00008067          	ret

00001194 <memset>:
    1194:	00050313          	mv	t1,a0
    1198:	00060a63          	beqz	a2,11ac <memset+0x18>
    119c:	00b30023          	sb	a1,0(t1)
    11a0:	fff60613          	addi	a2,a2,-1
    11a4:	00130313          	addi	t1,t1,1
    11a8:	fe061ae3          	bnez	a2,119c <memset+0x8>
    11ac:	00008067          	ret

000011b0 <__addsf3>:
    11b0:	ff010113          	addi	sp,sp,-16
    11b4:	00800737          	lui	a4,0x800
    11b8:	fff70713          	addi	a4,a4,-1 # 7fffff <__stack_end__+0x5fffff>
    11bc:	0175d613          	srli	a2,a1,0x17
    11c0:	00812423          	sw	s0,8(sp)
    11c4:	01755413          	srli	s0,a0,0x17
    11c8:	00a777b3          	and	a5,a4,a0
    11cc:	00912223          	sw	s1,4(sp)
    11d0:	00b77733          	and	a4,a4,a1
    11d4:	0ff47413          	zext.b	s0,s0
    11d8:	0ff67613          	zext.b	a2,a2
    11dc:	00112623          	sw	ra,12(sp)
    11e0:	01212023          	sw	s2,0(sp)
    11e4:	01f55493          	srli	s1,a0,0x1f
    11e8:	01f5d593          	srli	a1,a1,0x1f
    11ec:	00379793          	slli	a5,a5,0x3
    11f0:	00371713          	slli	a4,a4,0x3
    11f4:	40c406b3          	sub	a3,s0,a2
    11f8:	1cb49c63          	bne	s1,a1,13d0 <__addsf3+0x220>
    11fc:	08d05e63          	blez	a3,1298 <__addsf3+0xe8>
    1200:	0ff00593          	li	a1,255
    1204:	02061663          	bnez	a2,1230 <__addsf3+0x80>
    1208:	00070e63          	beqz	a4,1224 <__addsf3+0x74>
    120c:	fff68613          	addi	a2,a3,-1
    1210:	00061863          	bnez	a2,1220 <__addsf3+0x70>
    1214:	00e787b3          	add	a5,a5,a4
    1218:	00100413          	li	s0,1
    121c:	04c0006f          	j	1268 <__addsf3+0xb8>
    1220:	02b69063          	bne	a3,a1,1240 <__addsf3+0x90>
    1224:	00068413          	mv	s0,a3
    1228:	00078713          	mv	a4,a5
    122c:	2c00006f          	j	14ec <__addsf3+0x33c>
    1230:	feb40ce3          	beq	s0,a1,1228 <__addsf3+0x78>
    1234:	04000637          	lui	a2,0x4000
    1238:	00c76733          	or	a4,a4,a2
    123c:	00068613          	mv	a2,a3
    1240:	01b00593          	li	a1,27
    1244:	00100693          	li	a3,1
    1248:	00c5ce63          	blt	a1,a2,1264 <__addsf3+0xb4>
    124c:	02000693          	li	a3,32
    1250:	40c686b3          	sub	a3,a3,a2
    1254:	00c755b3          	srl	a1,a4,a2
    1258:	00d71733          	sll	a4,a4,a3
    125c:	00e03733          	snez	a4,a4
    1260:	00e5e6b3          	or	a3,a1,a4
    1264:	00d787b3          	add	a5,a5,a3
    1268:	00579713          	slli	a4,a5,0x5
    126c:	12075263          	bgez	a4,1390 <__addsf3+0x1e0>
    1270:	00140413          	addi	s0,s0,1
    1274:	0ff00713          	li	a4,255
    1278:	34e40e63          	beq	s0,a4,15d4 <__addsf3+0x424>
    127c:	7e0006b7          	lui	a3,0x7e000
    1280:	0017d713          	srli	a4,a5,0x1
    1284:	fff68693          	addi	a3,a3,-1 # 7dffffff <__extbss_end__+0x5dffffff>
    1288:	00d77733          	and	a4,a4,a3
    128c:	0017f793          	andi	a5,a5,1
    1290:	00f767b3          	or	a5,a4,a5
    1294:	0fc0006f          	j	1390 <__addsf3+0x1e0>
    1298:	06068463          	beqz	a3,1300 <__addsf3+0x150>
    129c:	408606b3          	sub	a3,a2,s0
    12a0:	0ff00513          	li	a0,255
    12a4:	00041e63          	bnez	s0,12c0 <__addsf3+0x110>
    12a8:	32078063          	beqz	a5,15c8 <__addsf3+0x418>
    12ac:	fff68593          	addi	a1,a3,-1
    12b0:	f60582e3          	beqz	a1,1214 <__addsf3+0x64>
    12b4:	00a69e63          	bne	a3,a0,12d0 <__addsf3+0x120>
    12b8:	0ff00413          	li	s0,255
    12bc:	2300006f          	j	14ec <__addsf3+0x33c>
    12c0:	fea60ce3          	beq	a2,a0,12b8 <__addsf3+0x108>
    12c4:	040005b7          	lui	a1,0x4000
    12c8:	00b7e7b3          	or	a5,a5,a1
    12cc:	00068593          	mv	a1,a3
    12d0:	01b00513          	li	a0,27
    12d4:	00100693          	li	a3,1
    12d8:	00b54e63          	blt	a0,a1,12f4 <__addsf3+0x144>
    12dc:	02000693          	li	a3,32
    12e0:	40b686b3          	sub	a3,a3,a1
    12e4:	00b7d533          	srl	a0,a5,a1
    12e8:	00d797b3          	sll	a5,a5,a3
    12ec:	00f037b3          	snez	a5,a5
    12f0:	00f566b3          	or	a3,a0,a5
    12f4:	00e687b3          	add	a5,a3,a4
    12f8:	00060413          	mv	s0,a2
    12fc:	f6dff06f          	j	1268 <__addsf3+0xb8>
    1300:	00140693          	addi	a3,s0,1
    1304:	0fe6f613          	andi	a2,a3,254
    1308:	06061a63          	bnez	a2,137c <__addsf3+0x1cc>
    130c:	06041063          	bnez	s0,136c <__addsf3+0x1bc>
    1310:	2a078663          	beqz	a5,15bc <__addsf3+0x40c>
    1314:	08070a63          	beqz	a4,13a8 <__addsf3+0x1f8>
    1318:	00f70733          	add	a4,a4,a5
    131c:	00571793          	slli	a5,a4,0x5
    1320:	1c07d663          	bgez	a5,14ec <__addsf3+0x33c>
    1324:	1f8007b7          	lui	a5,0x1f800
    1328:	00375713          	srli	a4,a4,0x3
    132c:	fff78793          	addi	a5,a5,-1 # 1f7fffff <__stack_end__+0x1f5fffff>
    1330:	00f777b3          	and	a5,a4,a5
    1334:	00100413          	li	s0,1
    1338:	0ff47413          	zext.b	s0,s0
    133c:	00979793          	slli	a5,a5,0x9
    1340:	01741413          	slli	s0,s0,0x17
    1344:	0097d793          	srli	a5,a5,0x9
    1348:	00f46433          	or	s0,s0,a5
    134c:	01f49513          	slli	a0,s1,0x1f
    1350:	00c12083          	lw	ra,12(sp)
    1354:	00a46533          	or	a0,s0,a0
    1358:	00812403          	lw	s0,8(sp)
    135c:	00412483          	lw	s1,4(sp)
    1360:	00012903          	lw	s2,0(sp)
    1364:	01010113          	addi	sp,sp,16
    1368:	00008067          	ret
    136c:	f40786e3          	beqz	a5,12b8 <__addsf3+0x108>
    1370:	1c071863          	bnez	a4,1540 <__addsf3+0x390>
    1374:	00078713          	mv	a4,a5
    1378:	f41ff06f          	j	12b8 <__addsf3+0x108>
    137c:	0ff00613          	li	a2,255
    1380:	24c68863          	beq	a3,a2,15d0 <__addsf3+0x420>
    1384:	00e78733          	add	a4,a5,a4
    1388:	00175793          	srli	a5,a4,0x1
    138c:	00068413          	mv	s0,a3
    1390:	0077f713          	andi	a4,a5,7
    1394:	00070a63          	beqz	a4,13a8 <__addsf3+0x1f8>
    1398:	00f7f713          	andi	a4,a5,15
    139c:	00400693          	li	a3,4
    13a0:	00d70463          	beq	a4,a3,13a8 <__addsf3+0x1f8>
    13a4:	00d787b3          	add	a5,a5,a3
    13a8:	00579713          	slli	a4,a5,0x5
    13ac:	e6075ee3          	bgez	a4,1228 <__addsf3+0x78>
    13b0:	00140413          	addi	s0,s0,1
    13b4:	0ff00713          	li	a4,255
    13b8:	20e40e63          	beq	s0,a4,15d4 <__addsf3+0x424>
    13bc:	1f800737          	lui	a4,0x1f800
    13c0:	0037d793          	srli	a5,a5,0x3
    13c4:	fff70713          	addi	a4,a4,-1 # 1f7fffff <__stack_end__+0x1f5fffff>
    13c8:	00e7f7b3          	and	a5,a5,a4
    13cc:	f6dff06f          	j	1338 <__addsf3+0x188>
    13d0:	08d05063          	blez	a3,1450 <__addsf3+0x2a0>
    13d4:	06061263          	bnez	a2,1438 <__addsf3+0x288>
    13d8:	e40706e3          	beqz	a4,1224 <__addsf3+0x74>
    13dc:	fff68613          	addi	a2,a3,-1
    13e0:	00061863          	bnez	a2,13f0 <__addsf3+0x240>
    13e4:	40e787b3          	sub	a5,a5,a4
    13e8:	00100413          	li	s0,1
    13ec:	0340006f          	j	1420 <__addsf3+0x270>
    13f0:	0ff00593          	li	a1,255
    13f4:	e2b688e3          	beq	a3,a1,1224 <__addsf3+0x74>
    13f8:	01b00593          	li	a1,27
    13fc:	00100693          	li	a3,1
    1400:	00c5ce63          	blt	a1,a2,141c <__addsf3+0x26c>
    1404:	02000693          	li	a3,32
    1408:	40c686b3          	sub	a3,a3,a2
    140c:	00c755b3          	srl	a1,a4,a2
    1410:	00d71733          	sll	a4,a4,a3
    1414:	00e03733          	snez	a4,a4
    1418:	00e5e6b3          	or	a3,a1,a4
    141c:	40d787b3          	sub	a5,a5,a3
    1420:	00579713          	slli	a4,a5,0x5
    1424:	f60756e3          	bgez	a4,1390 <__addsf3+0x1e0>
    1428:	04000937          	lui	s2,0x4000
    142c:	fff90913          	addi	s2,s2,-1 # 3ffffff <__stack_end__+0x3dfffff>
    1430:	0127f933          	and	s2,a5,s2
    1434:	1300006f          	j	1564 <__addsf3+0x3b4>
    1438:	0ff00613          	li	a2,255
    143c:	dec406e3          	beq	s0,a2,1228 <__addsf3+0x78>
    1440:	04000637          	lui	a2,0x4000
    1444:	00c76733          	or	a4,a4,a2
    1448:	00068613          	mv	a2,a3
    144c:	fadff06f          	j	13f8 <__addsf3+0x248>
    1450:	06068e63          	beqz	a3,14cc <__addsf3+0x31c>
    1454:	408606b3          	sub	a3,a2,s0
    1458:	02041663          	bnez	s0,1484 <__addsf3+0x2d4>
    145c:	16078463          	beqz	a5,15c4 <__addsf3+0x414>
    1460:	fff68513          	addi	a0,a3,-1
    1464:	00051863          	bnez	a0,1474 <__addsf3+0x2c4>
    1468:	40f707b3          	sub	a5,a4,a5
    146c:	00058493          	mv	s1,a1
    1470:	f79ff06f          	j	13e8 <__addsf3+0x238>
    1474:	0ff00813          	li	a6,255
    1478:	03069063          	bne	a3,a6,1498 <__addsf3+0x2e8>
    147c:	00058493          	mv	s1,a1
    1480:	e39ff06f          	j	12b8 <__addsf3+0x108>
    1484:	0ff00513          	li	a0,255
    1488:	fea60ae3          	beq	a2,a0,147c <__addsf3+0x2cc>
    148c:	04000537          	lui	a0,0x4000
    1490:	00a7e7b3          	or	a5,a5,a0
    1494:	00068513          	mv	a0,a3
    1498:	01b00813          	li	a6,27
    149c:	00100693          	li	a3,1
    14a0:	00a84e63          	blt	a6,a0,14bc <__addsf3+0x30c>
    14a4:	02000693          	li	a3,32
    14a8:	40a686b3          	sub	a3,a3,a0
    14ac:	00a7d833          	srl	a6,a5,a0
    14b0:	00d797b3          	sll	a5,a5,a3
    14b4:	00f037b3          	snez	a5,a5
    14b8:	00f866b3          	or	a3,a6,a5
    14bc:	40d707b3          	sub	a5,a4,a3
    14c0:	00060413          	mv	s0,a2
    14c4:	00058493          	mv	s1,a1
    14c8:	f59ff06f          	j	1420 <__addsf3+0x270>
    14cc:	00140693          	addi	a3,s0,1
    14d0:	0fe6f693          	andi	a3,a3,254
    14d4:	06069e63          	bnez	a3,1550 <__addsf3+0x3a0>
    14d8:	06041263          	bnez	s0,153c <__addsf3+0x38c>
    14dc:	02079463          	bnez	a5,1504 <__addsf3+0x354>
    14e0:	00000493          	li	s1,0
    14e4:	e4070ae3          	beqz	a4,1338 <__addsf3+0x188>
    14e8:	00058493          	mv	s1,a1
    14ec:	00375793          	srli	a5,a4,0x3
    14f0:	0ff00713          	li	a4,255
    14f4:	e4e412e3          	bne	s0,a4,1338 <__addsf3+0x188>
    14f8:	e40780e3          	beqz	a5,1338 <__addsf3+0x188>
    14fc:	004007b7          	lui	a5,0x400
    1500:	0340006f          	j	1534 <__addsf3+0x384>
    1504:	ea0702e3          	beqz	a4,13a8 <__addsf3+0x1f8>
    1508:	40e786b3          	sub	a3,a5,a4
    150c:	00569613          	slli	a2,a3,0x5
    1510:	00065c63          	bgez	a2,1528 <__addsf3+0x378>
    1514:	40f707b3          	sub	a5,a4,a5
    1518:	00058493          	mv	s1,a1
    151c:	00000413          	li	s0,0
    1520:	e0078ce3          	beqz	a5,1338 <__addsf3+0x188>
    1524:	e6dff06f          	j	1390 <__addsf3+0x1e0>
    1528:	00068713          	mv	a4,a3
    152c:	fc0690e3          	bnez	a3,14ec <__addsf3+0x33c>
    1530:	00000793          	li	a5,0
    1534:	00000493          	li	s1,0
    1538:	e01ff06f          	j	1338 <__addsf3+0x188>
    153c:	e2079ae3          	bnez	a5,1370 <__addsf3+0x1c0>
    1540:	00000493          	li	s1,0
    1544:	0ff00413          	li	s0,255
    1548:	004007b7          	lui	a5,0x400
    154c:	dedff06f          	j	1338 <__addsf3+0x188>
    1550:	40e78933          	sub	s2,a5,a4
    1554:	00591693          	slli	a3,s2,0x5
    1558:	0406d263          	bgez	a3,159c <__addsf3+0x3ec>
    155c:	40f70933          	sub	s2,a4,a5
    1560:	00058493          	mv	s1,a1
    1564:	00090513          	mv	a0,s2
    1568:	10c000ef          	jal	1674 <__clzsi2>
    156c:	ffb50513          	addi	a0,a0,-5 # 3fffffb <__stack_end__+0x3dffffb>
    1570:	00a91933          	sll	s2,s2,a0
    1574:	02854a63          	blt	a0,s0,15a8 <__addsf3+0x3f8>
    1578:	40850533          	sub	a0,a0,s0
    157c:	00150513          	addi	a0,a0,1
    1580:	02000713          	li	a4,32
    1584:	40a70733          	sub	a4,a4,a0
    1588:	00a957b3          	srl	a5,s2,a0
    158c:	00e91933          	sll	s2,s2,a4
    1590:	01203933          	snez	s2,s2
    1594:	0127e7b3          	or	a5,a5,s2
    1598:	f85ff06f          	j	151c <__addsf3+0x36c>
    159c:	fc0914e3          	bnez	s2,1564 <__addsf3+0x3b4>
    15a0:	00000413          	li	s0,0
    15a4:	f8dff06f          	j	1530 <__addsf3+0x380>
    15a8:	fc0007b7          	lui	a5,0xfc000
    15ac:	fff78793          	addi	a5,a5,-1 # fbffffff <__ddr_bss_end__+0x7bffffff>
    15b0:	40a40433          	sub	s0,s0,a0
    15b4:	00f977b3          	and	a5,s2,a5
    15b8:	dd9ff06f          	j	1390 <__addsf3+0x1e0>
    15bc:	00070793          	mv	a5,a4
    15c0:	f5dff06f          	j	151c <__addsf3+0x36c>
    15c4:	00058493          	mv	s1,a1
    15c8:	00068413          	mv	s0,a3
    15cc:	f21ff06f          	j	14ec <__addsf3+0x33c>
    15d0:	00068413          	mv	s0,a3
    15d4:	00000793          	li	a5,0
    15d8:	d61ff06f          	j	1338 <__addsf3+0x188>

000015dc <__gesf2>:
    15dc:	00800737          	lui	a4,0x800
    15e0:	fff70713          	addi	a4,a4,-1 # 7fffff <__stack_end__+0x5fffff>
    15e4:	00a77633          	and	a2,a4,a0
    15e8:	01755693          	srli	a3,a0,0x17
    15ec:	0ff6f693          	zext.b	a3,a3
    15f0:	01f55793          	srli	a5,a0,0x1f
    15f4:	00b77733          	and	a4,a4,a1
    15f8:	01f5d893          	srli	a7,a1,0x1f
    15fc:	00060863          	beqz	a2,160c <__gesf2+0x30>
    1600:	f0168813          	addi	a6,a3,-255
    1604:	ffe00513          	li	a0,-2
    1608:	06080463          	beqz	a6,1670 <__gesf2+0x94>
    160c:	0175d593          	srli	a1,a1,0x17
    1610:	0ff5f593          	zext.b	a1,a1
    1614:	00070863          	beqz	a4,1624 <__gesf2+0x48>
    1618:	f0158813          	addi	a6,a1,-255 # 3ffff01 <__stack_end__+0x3dfff01>
    161c:	ffe00513          	li	a0,-2
    1620:	04080863          	beqz	a6,1670 <__gesf2+0x94>
    1624:	00c6e533          	or	a0,a3,a2
    1628:	00e5e833          	or	a6,a1,a4
    162c:	00051a63          	bnez	a0,1640 <__gesf2+0x64>
    1630:	04080063          	beqz	a6,1670 <__gesf2+0x94>
    1634:	00189513          	slli	a0,a7,0x1
    1638:	fff50513          	addi	a0,a0,-1
    163c:	00008067          	ret
    1640:	00081863          	bnez	a6,1650 <__gesf2+0x74>
    1644:	40f007b3          	neg	a5,a5
    1648:	0017e513          	ori	a0,a5,1
    164c:	00008067          	ret
    1650:	ff179ae3          	bne	a5,a7,1644 <__gesf2+0x68>
    1654:	fed5c8e3          	blt	a1,a3,1644 <__gesf2+0x68>
    1658:	00b6d663          	bge	a3,a1,1664 <__gesf2+0x88>
    165c:	00179513          	slli	a0,a5,0x1
    1660:	fd9ff06f          	j	1638 <__gesf2+0x5c>
    1664:	fec760e3          	bltu	a4,a2,1644 <__gesf2+0x68>
    1668:	00000513          	li	a0,0
    166c:	fee668e3          	bltu	a2,a4,165c <__gesf2+0x80>
    1670:	00008067          	ret

00001674 <__clzsi2>:
    1674:	000107b7          	lui	a5,0x10
    1678:	02f57a63          	bgeu	a0,a5,16ac <__clzsi2+0x38>
    167c:	10053793          	sltiu	a5,a0,256
    1680:	0017b793          	seqz	a5,a5
    1684:	00379793          	slli	a5,a5,0x3
    1688:	02000713          	li	a4,32
    168c:	40f70733          	sub	a4,a4,a5
    1690:	00f55533          	srl	a0,a0,a5
    1694:	00000797          	auipc	a5,0x0
    1698:	69478793          	addi	a5,a5,1684 # 1d28 <__clz_tab>
    169c:	00a787b3          	add	a5,a5,a0
    16a0:	0007c503          	lbu	a0,0(a5)
    16a4:	40a70533          	sub	a0,a4,a0
    16a8:	00008067          	ret
    16ac:	01000737          	lui	a4,0x1000
    16b0:	01800793          	li	a5,24
    16b4:	fce57ae3          	bgeu	a0,a4,1688 <__clzsi2+0x14>
    16b8:	01000793          	li	a5,16
    16bc:	fcdff06f          	j	1688 <__clzsi2+0x14>

000016c0 <run_model>:
__attribute__((used, retain)) void run_model() {
    16c0:	fe010113          	addi	sp,sp,-32
    16c4:	00112e23          	sw	ra,28(sp)
    16c8:	00812c23          	sw	s0,24(sp)
    16cc:	00912a23          	sw	s1,20(sp)
    16d0:	01212823          	sw	s2,16(sp)
  tvmgen_default_inputs inputs = {
    16d4:	000ff417          	auipc	s0,0xff
    16d8:	92c40413          	addi	s0,s0,-1748 # 100000 <model_input>
    16dc:	00812623          	sw	s0,12(sp)
  tvmgen_default_outputs outputs = {
    16e0:	90018793          	addi	a5,gp,-1792 # 100100 <model_output>
    16e4:	00f12423          	sw	a5,8(sp)

inline uint64_t mcycle_read(void) {
  uint32_t cycle_low = 0;
  uint32_t cycle_high = 0;
  uint32_t cycle_high_2 = 0;
  asm volatile(
    16e8:	b8002973          	csrr	s2,mcycleh
    16ec:	b00024f3          	csrr	s1,mcycle
    16f0:	b80027f3          	csrr	a5,mcycleh
    16f4:	fef91ae3          	bne	s2,a5,16e8 <run_model+0x28>
  inference_status = tvmgen_default_run(&inputs, &outputs);
    16f8:	00810593          	addi	a1,sp,8
    16fc:	00c10513          	addi	a0,sp,12
    1700:	a71fe0ef          	jal	170 <tvmgen_default_run>
    1704:	10a42223          	sw	a0,260(s0)
    1708:	b80027f3          	csrr	a5,mcycleh
    170c:	b00026f3          	csrr	a3,mcycle
    1710:	b8002773          	csrr	a4,mcycleh
    1714:	fee79ae3          	bne	a5,a4,1708 <run_model+0x48>
  inference_cycles = mcycle_read() - start;
    1718:	40968733          	sub	a4,a3,s1
    171c:	00e6b6b3          	sltu	a3,a3,a4
    1720:	412787b3          	sub	a5,a5,s2
    1724:	40d787b3          	sub	a5,a5,a3
    1728:	10e42423          	sw	a4,264(s0)
    172c:	10f42623          	sw	a5,268(s0)
}
    1730:	01c12083          	lw	ra,28(sp)
    1734:	01812403          	lw	s0,24(sp)
    1738:	01412483          	lw	s1,20(sp)
    173c:	01012903          	lw	s2,16(sp)
    1740:	02010113          	addi	sp,sp,32
    1744:	00008067          	ret

00001748 <floorf>:
    1748:	fe010113          	addi	sp,sp,-32
    174c:	01412423          	sw	s4,8(sp)
    1750:	80000a37          	lui	s4,0x80000
    1754:	01212823          	sw	s2,16(sp)
    1758:	fffa0913          	addi	s2,s4,-1 # 7fffffff <__extbss_end__+0x5fffffff>
    175c:	00a97933          	and	s2,s2,a0
    1760:	01312623          	sw	s3,12(sp)
    1764:	01795993          	srli	s3,s2,0x17
    1768:	00812c23          	sw	s0,24(sp)
    176c:	00112e23          	sw	ra,28(sp)
    1770:	00912a23          	sw	s1,20(sp)
    1774:	f8198993          	addi	s3,s3,-127
    1778:	01600793          	li	a5,22
    177c:	00050413          	mv	s0,a0
    1780:	0937c063          	blt	a5,s3,1800 <floorf+0xb8>
    1784:	00050493          	mv	s1,a0
    1788:	0209da63          	bgez	s3,17bc <floorf+0x74>
    178c:	00000597          	auipc	a1,0x0
    1790:	1305a583          	lw	a1,304(a1) # 18bc <__fini_array_end+0xc>
    1794:	a1dff0ef          	jal	11b0 <__addsf3>
    1798:	00000593          	li	a1,0
    179c:	e41ff0ef          	jal	15dc <__gesf2>
    17a0:	00a05a63          	blez	a0,17b4 <floorf+0x6c>
    17a4:	08045a63          	bgez	s0,1838 <floorf+0xf0>
    17a8:	bf8004b7          	lui	s1,0xbf800
    17ac:	00091463          	bnez	s2,17b4 <floorf+0x6c>
    17b0:	000a0493          	mv	s1,s4
    17b4:	00048413          	mv	s0,s1
    17b8:	05c0006f          	j	1814 <floorf+0xcc>
    17bc:	00800a37          	lui	s4,0x800
    17c0:	fffa0913          	addi	s2,s4,-1 # 7fffff <__stack_end__+0x5fffff>
    17c4:	41395933          	sra	s2,s2,s3
    17c8:	00a977b3          	and	a5,s2,a0
    17cc:	04078463          	beqz	a5,1814 <floorf+0xcc>
    17d0:	00000597          	auipc	a1,0x0
    17d4:	0ec5a583          	lw	a1,236(a1) # 18bc <__fini_array_end+0xc>
    17d8:	9d9ff0ef          	jal	11b0 <__addsf3>
    17dc:	00000593          	li	a1,0
    17e0:	dfdff0ef          	jal	15dc <__gesf2>
    17e4:	fca058e3          	blez	a0,17b4 <floorf+0x6c>
    17e8:	00045663          	bgez	s0,17f4 <floorf+0xac>
    17ec:	413a5a33          	sra	s4,s4,s3
    17f0:	008a04b3          	add	s1,s4,s0
    17f4:	fff94913          	not	s2,s2
    17f8:	0124f4b3          	and	s1,s1,s2
    17fc:	fb9ff06f          	j	17b4 <floorf+0x6c>
    1800:	7f8007b7          	lui	a5,0x7f800
    1804:	00f96863          	bltu	s2,a5,1814 <floorf+0xcc>
    1808:	00050593          	mv	a1,a0
    180c:	9a5ff0ef          	jal	11b0 <__addsf3>
    1810:	00050413          	mv	s0,a0
    1814:	01c12083          	lw	ra,28(sp)
    1818:	00040513          	mv	a0,s0
    181c:	01812403          	lw	s0,24(sp)
    1820:	01412483          	lw	s1,20(sp)
    1824:	01012903          	lw	s2,16(sp)
    1828:	00c12983          	lw	s3,12(sp)
    182c:	00812a03          	lw	s4,8(sp)
    1830:	02010113          	addi	sp,sp,32
    1834:	00008067          	ret
    1838:	00000493          	li	s1,0
    183c:	f79ff06f          	j	17b4 <floorf+0x6c>

Disassembly of section .crt:

00001840 <crt_section_clear>:
  .global crt_section_clear
  .type crt_section_clear, @function
crt_section_clear:

  // Check that start is before end.
  bgeu a0, a1, .L_clear_nothing
    1840:	02b57063          	bgeu	a0,a1,1860 <crt_section_clear+0x20>

  // Check that start and end are word aligned.
  or   t0, a0, a1
    1844:	00b562b3          	or	t0,a0,a1
  andi t0, t0, 0x3
    1848:	0032f293          	andi	t0,t0,3
  bnez t0, .L_clear_error
    184c:	00029e63          	bnez	t0,1868 <crt_section_clear+0x28>

.L_clear_loop:
  // Write zero into section memory word-by-word.
  // TODO: unroll
  sw   zero, 0(a0)
    1850:	00052023          	sw	zero,0(a0)
  addi a0, a0, 4
    1854:	00450513          	addi	a0,a0,4
  bltu a0, a1, .L_clear_loop
    1858:	feb56ce3          	bltu	a0,a1,1850 <crt_section_clear+0x10>
  ret
    185c:	00008067          	ret

.L_clear_nothing:
  // If section length is 0 just return. Otherwise end is before start
  // which is invalid so trigger an error.
  bne a0, a1, .L_clear_error
    1860:	00b51463          	bne	a0,a1,1868 <crt_section_clear+0x28>
  ret
    1864:	00008067          	ret

.L_clear_error:
  ebreak
    1868:	00100073          	ebreak

0000186c <crt_section_copy>:
  .global crt_section_copy
  .type crt_section_copy, @function
crt_section_copy:

  // Check that start is before end.
  bgeu a0, a1, .L_copy_nothing
    186c:	02b57c63          	bgeu	a0,a1,18a4 <crt_section_copy+0x38>

  // Check that start, end and src are word aligned.
  or   t0, a0, a1
    1870:	00b562b3          	or	t0,a0,a1
  or   t0, t0, a2
    1874:	00c2e2b3          	or	t0,t0,a2
  andi t0, t0, 0x3
    1878:	0032f293          	andi	t0,t0,3
  bnez t0, .L_copy_error
    187c:	02029863          	bnez	t0,18ac <crt_section_copy+0x40>
  //        +-------------+
  //        |             |
  //      start          end
  //
  // TODO: disallow all overlap since it indicates API misuse?
  sub  t0, a0, a2           // (start - src) mod 2**32
    1880:	40c502b3          	sub	t0,a0,a2
  sub  t1, a1, a0           // end - start
    1884:	40a58333          	sub	t1,a1,a0
  bltu t0, t1, .L_copy_error
    1888:	0262e263          	bltu	t0,t1,18ac <crt_section_copy+0x40>

.L_copy_loop:
  // Copy data from src into section word-by-word.
  // TODO: unroll
  lw   t0, 0(a2)
    188c:	00062283          	lw	t0,0(a2) # 4000000 <__stack_end__+0x3e00000>
  addi a2, a2, 4
    1890:	00460613          	addi	a2,a2,4
  sw   t0, 0(a0)
    1894:	00552023          	sw	t0,0(a0)
  addi a0, a0, 4
    1898:	00450513          	addi	a0,a0,4
  bltu a0, a1, .L_copy_loop
    189c:	feb568e3          	bltu	a0,a1,188c <crt_section_copy+0x20>
  ret
    18a0:	00008067          	ret

.L_copy_nothing:
  // If section length is 0 just return. Otherwise end is before start
  // which is invalid so trigger an error.
  bne a0, a1, .L_copy_error
    18a4:	00b51463          	bne	a0,a1,18ac <crt_section_copy+0x40>
  ret
    18a8:	00008067          	ret

.L_copy_error:
  ebreak
    18ac:	00100073          	ebreak
