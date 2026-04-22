
# ===================================================================
#        Filename: makefile
#
#         Created: 2022-07-02 02:14:08 PM
#      Last $Date$
#          Author: yanglp, raindroper@163.com
#    Organization: National ASIC Design Engineering Center, IACAS
#
#     Description: 
# ===================================================================
## -----------------------------------------------------------------------------
##      PART A define filelist here
## -----------------------------------------------------------------------------

ROOT_DIR ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
export DESIGN_ROOT=/home/wangyy/002_research/coralnpu/

## define filelist

FILE_LIST_TB ?= -f filelist
DW_SIM_VER ?= /home/wangwy/software/synopsys/install/syn/syn/T-2022.03-SP2/dw/sim_ver
TOP_MODULE ?= ara_tb
DPI_SO ?=
PRELOAD ?=
FSDB_WAVE_FILE ?= $(ROOT_DIR)/vcs/wave_sdf.sv

ifeq ($(RTL_SIMULATION),1)
	FILE_LIST_RTL = +incdir+$(DW_SIM_VER) \
					-y $(DW_SIM_VER) 
else
	FILE_LIST_RTL =
endif

## -----------------------------------------------------------------------------
##      PART B define timescale parameter here
## -----------------------------------------------------------------------------

## define timescale parameter
TIMESCALE = 1ns/1ps

## -----------------------------------------------------------------------------
##      PART C define VCS sim parameter here
## -----------------------------------------------------------------------------

## define basic parameter for vcs
ifeq ($(RTL_SIMULATION),1)
	VCS_COMPILE_RTL_PARA = +define+RTL_SIMULATION
else
	VCS_COMPILE_RTL_PARA = +warn=noNTCDNC +warn=noIWNF +warn=noTFIPC +define+NTC +define+RECREM -picarchive
endif

VCS_COMPILE_TB_PARA = +v2k -sverilog


## define wave parameter for vcs
ifeq ($(WAVE_EN),1)
  ifeq ($(RTL_SIMULATION),1)
		VCS_WAVE_PARA = -kdb -debug_access+pp+dmptf+thread -debug_region=cell+encrypt+lib
  else
		VCS_WAVE_PARA = -kdb -debug_access+pp -debug_region=cell+encrypt+lib
  endif
else
	VCS_WAVE_PARA = -kdb -debug_access+r
endif

ifeq ($(FSDB_DUMP),1)
	VCS_WAVE_PARA += -P $(NOVAS_HOME)/share/PLI/VCS/LINUX64/novas.tab \
									 $(NOVAS_HOME)/share/PLI/VCS/LINUX64/pli.a
	VCS_COMPILE_RTL_PARA += +define+SVT_FSDB_ENABLE
endif

## define code coverage parameter for vcs
ifeq ($(CM_EN),1)
	VCS_CM_PARA = -cm line+cond+fsm+branch+tgl+assert -cm_line contassign -lca \
								-cm_cond basic+allops -cm_hier hier_cm_lst 
	VCS_CM_PARA_RUN = -cm line+cond+fsm+branch+tgl+assert
else
	VCS_CM_PARA =
	VCS_CM_PARA_RUN =
endif

## define timing check parameter for vcs
ifeq ($(TCHK),1)
	VCS_TCHK_PARA = +neg_tchk -negdelay
else
	VCS_TCHK_PARA = +no_tchk_msg +notimingchecks +nospecify
endif

## define initreg parameter for vcs
ifeq ($(RTL_SIMULATION),1)
	VCS_INITREG_PARA = +lint=TFIPC-L
	#VCS_INITREG_PARA = +vcs+initreg+config+initreg_configfile
else ifeq ($(POST_GATE_SIM),1)
	VCS_INITREG_PARA = +vcs+initreg+config+initreg_configfile_gate
else
	VCS_INITREG_PARA = +vcs+initreg+config+initreg_configfile_gate
endif

## define gui parameter for vcs
ifeq ($(GUI_EN),1)
	VCS_GUI_PARA = -gui
else
	VCS_GUI_PARA =
endif

## define wave dump for vcs
dump_fsdb = 0
ifeq ($(FSDB_DUMP),1)
	dump_fsdb = 1
endif

## define display level for uvm
VERBOSITY = UVM_LOW
#VERBOSITY = UVM_MEDIUM
#VERBOSITY = UVM_HIGH

## define timescale parameter for vcs
VCS_TIMESCALE_PARA = -timescale=$(TIMESCALE)
#VCS_TIMESCALE_PARA = -override_timescale=$(TIMESCALE)

## define the whole compiler parameter for vcs
ifeq ($(xprop),1)
	VCS_COMPILE_PARA = ${VCS_COMPILE_RTL_PARA} ${VCS_COMPILE_TB_PARA} ${VCS_TIMESCALE_PARA} ${VCS_WAVE_PARA} ${VCS_TCHK_PARA} ${VCS_CM_PARA} ${VCS_INITREG_PARA} \
									 +vcs+lic+wait +vcs+flush+all -ntb_opts uvm-1.2 +error+10000 +vcs+loopreport -xprop=./xprop_cfg #-parallel+show_features 

	VCS_SIM_PARA =  ${VCS_CM_PARA_RUN} ${VCS_INITREG_PARA} +vcs+loopreport -report=xprop 
else
	VCS_COMPILE_PARA = ${VCS_COMPILE_RTL_PARA} ${VCS_COMPILE_TB_PARA} ${VCS_TIMESCALE_PARA} ${VCS_WAVE_PARA} ${VCS_TCHK_PARA} ${VCS_CM_PARA} ${VCS_INITREG_PARA} \
									 +vcs+lic+wait +vcs+flush+all -ntb_opts uvm-1.2 +error+10000  +vcs+loopreport
#-parallel+show_features 

	VCS_SIM_PARA =  ${VCS_CM_PARA_RUN} ${VCS_INITREG_PARA} +vcs+loopreport
endif

## -----------------------------------------------------------------------------
##      PART E define sim command here
## -----------------------------------------------------------------------------
#Set make target
.PHONY: test rmtf clean_temp clean vcs_com vcs_run vcs_com_run cmrpt urg_cm verdi_cm verdi verdif dve verdi_post

test:
	@echo TIMESCALE
	@echo $(TIMESCALE)
	@echo 
	@echo VCS_COMPILE_PARA
	@echo $(VCS_COMPILE_PARA)
	@echo
	@echo VCS_SIM_PARA
	@echo $(VCS_SIM_PARA)
	@echo

rmtf:
	@ls | grep '^[0-9]\{14\}_' | xargs rm -f

clean_temp: rmtf
	rm -rf *log*
	rm -rf sim_define.sv  testcase.sv  vc_hdrs.h
	rm -rf work INCA* csrc simv.daidir

clean: rmtf
	rm -rf *log* *.txt *.result *.lst *.swp
	rm -rf core.* .nfs*
	rm -rf novas.* verdiLog DVEfiles
	rm -rf *.mem *.hex *.obj
	rm -rf *.vpd *.shm *.fsdb* *.vcd *.key *.wlf
	rm -rf simv* work INCA*
	rm -rf csrc novas.conf  novas.rc verdiLog
	rm -rf *.sdf.X *.dis *.trace *.iss

vcs_com: $(C_MODEL)
	vcs -full64 -kdb -lca -top $(TOP_MODULE) ${VCS_COMPILE_PARA} ${FILE_LIST_TB} ${FILE_LIST_RTL} $(if $(FSDB_DUMP),$(FSDB_WAVE_FILE),) -l comp.log

vcs_run: 
	./simv $(if $(DPI_SO),-sv_lib $(DPI_SO),) ${VCS_GUI_PARA} ${VCS_SIM_PARA} $(if $(PRELOAD),+PRELOAD=$(PRELOAD),) -l sim.log 

vcs_com_run: vcs_com vcs_run

cmrpt:
	urg -lca -full64 -dir simv.vdb res/simv.vdb -dbname merge.vdb
urg_cm:
	firefox urgReport/tests.html &
verdi_cm:
	verdi -cov -covdir merge.vdb
verdi:
	verdi -dbdir ./simv.daidir -ssf $(TOP_MODULE).fsdb &

## -----------------------------------------------------------------------------
##      PART F define debug command here
## -----------------------------------------------------------------------------
## define wave name
WAVE_NAME ?= $(TOP_MODULE)

verdif:
	verdi -uvmDebug -ntb_opts uvm-1.2 -f dut.f -2001 -ssv -ssy -ssz -sv +systemverilogext+.sv+.SV+ +verilog2001ext+.v+.V+ -top $(TOP_MODULE) -ssf $(WAVE_NAME).fsdb &

dve:
	dve -vpd $(WAVE_NAME).vpd -full64 &

verdi_post:
	verdi -f filelist_post -2001 -ssv -ssy -ssz -sv +systemverilogext+.sv+.SV+ +verilog2001ext+.v+.V+ -ssf $(WAVE_NAME).fsdb &
