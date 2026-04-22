
puts [clock format [clock seconds] -format "%Y-%m-%d %T"]
set svf_file_tail 0
set cur_shell_run_path  [pwd]
set svf_file $GUI_DESIGN_NAME.svf
while {[file isfile $svf_file]} {
	incr svf_file_tail 1
	set svf_file $GUI_DESIGN_NAME.svf.$svf_file_tail
}
set_svf $svf_file

file delete -force work
define_design_lib WORK -path ./work
set starttime [clock seconds]
#set alib_library_analysis_path $ALIB_LIB_PATH
set hdlin_check_no_latch true
#set hdlin_preserve_sequential true
#set hdlin_report_inferred_modules true
set compile_seqmap_propagate_constants false
#set compile_delete_unloaded_sequential_cells false
set compile_enable_register_merging false
set compile_register_replication false
set enable_recovery_removal_arcs true
set report_default_significant_digits 3
set sh_continue_on_error false
#set dc_allow_rtl_pg false
# 0304 add for dft
#set compile_seqmap_disable_qn_pin_connections true
#set test_disable_find_best_scan_out true

#set compile_enable_constant_propagation_with_no_boundary_opt false
#set compile_preserve_subdesign_interfaces true

set compile_ultra_hier_opt ""
set hierarchy_opt ""
if { !$GUI_UNGROUP } {
	set compile_ultra_hier_opt	" -no_autoungroup"
	set hierarchy_opt		"-hierarchy"
}

## read verilog netlist
if { $GUI_BLOCK_ABSTRACTION_DESIGNS1 != ""} {
	set_top_implementation_options -block_references $GUI_BLOCK_ABSTRACTION_DESIGNS1
}
if { $GUI_BLOCK_ABSTRACTION_DESIGNS != ""} {
	set_top_implementation_options -block_references $GUI_BLOCK_ABSTRACTION_DESIGNS 
}
if { $GUI_BLOCK_ABSTRACTION_DESIGNS2 != ""} {
	set_top_implementation_options -block_references $GUI_BLOCK_ABSTRACTION_DESIGNS2 
}

if { $GUI_DDC_FILE != ""} {
	read_ddc $GUI_DDC_FILE
}
if { $GUI_DDC_FILE1 != ""} {
	read_ddc $GUI_DDC_FILE1
}
if { $GUI_DDC_FILE2 != ""} {
	read_ddc $GUI_DDC_FILE2
}
if {$GUI_VCS_OPTION != ""} {
analyze -format sverilog -vcs $GUI_VCS_OPTION
elaborate $GUI_DESIGN_NAME > ./elaborate.log
} else {
	source $GUI_RTL_ORDER_FILE
	elaborate $GUI_DESIGN_NAME
}

set gui_top_design_name $GUI_DESIGN_NAME
set gui_exact_design_count 0
if {![catch {set gui_exact_design_count [sizeof_collection [get_designs -quiet $GUI_DESIGN_NAME]]}]} {
	set gui_top_design_name $GUI_DESIGN_NAME
}
if {$gui_exact_design_count == 0} {
	set matched_designs ""
	catch {set matched_designs [get_object_name [get_designs -quiet ${GUI_DESIGN_NAME}*]]}
	if {[llength $matched_designs] == 1} {
		set gui_top_design_name [lindex $matched_designs 0]
	} elseif {[llength $matched_designs] > 1} {
		echo "Multiple elaborated designs match '$GUI_DESIGN_NAME': $matched_designs"
		exit
	} else {
		echo "Can't find elaborated design matching '$GUI_DESIGN_NAME'"
		exit
	}
}

current_design $gui_top_design_name

if { ![link] } {
	echo "Linking error!"
	exit; #Exits DC if a serious linking problem is encountered
}
if { $GUI_BLOCK_ABSTRACTION_DESIGNS != ""} {
	report_top_implementation_options
	report_block_abstraction
}

#set dont touch & dont use
#source -echo -verbose ../local_scripts/dont_touch.tcl

#set_dont_touch [get_cells u_epwm*/u_epwm/u_epwm_db/u_DBRED_mep]
#set_dont_touch [get_cells u_epwm*/u_epwm/u_epwm_db/u_DBFED_mep]
#set_dont_touch [get_cells u_epwm*/u_epwm/u_hrpwm_a/u_mep]
#set_dont_touch [get_cells u_epwm*/u_epwm/u_hrpwm_b/u_mep]
#set_dont_touch [get_cells u_fsia/u_fsirx_top/u_fsirx_dlyline]
#set_dont_touch [get_cells u_ecap6/HRCAP_INSTANCE.u_hrcap/u_hrcap_sam]
#set_dont_touch [get_cells u_ecap7/HRCAP_INSTANCE.u_hrcap/u_hrcap_sam]

#source -e -v ../local_scripts/dc_dft_set.tcl

## set dont merge DFF
#set_register_merging [current_design] false

## create Milkyway
if { $GUI_DCG_MODE } {
	if { [file exists ../$GUI_DESIGN_NAME.mdb] } {
		puts "The specified DCG milkyway database is already existing. It will be renamed first......"
		file delete -force ../$GUI_DESIGN_NAME.mdb_bak
		file rename -force ../$GUI_DESIGN_NAME.mdb ../$GUI_DESIGN_NAME.mdb_bak
	}

	if { $MILKYWAY_EXTEND_LAYER } {
		extend_mw_layers
	}

	create_mw_lib -technology $MILKYWAY_TECH ../$GUI_DESIGN_NAME.mdb
	set_mw_lib_reference -mw_reference_library $milkyway_library ../$GUI_DESIGN_NAME.mdb
	open_mw_lib ../$GUI_DESIGN_NAME.mdb
}


eval write -format ddc -output ../outputs/${GUI_DESIGN_NAME}_dc_gtech.ddc $hierarchy_opt
eval write -format verilog -output ../outputs/${GUI_DESIGN_NAME}_dc_gtech.v $hierarchy_opt

## constrain
if { $GUI_SDC_FILE != "" } {
	foreach constraint_file $GUI_SDC_FILE {
			source -echo -verbose $constraint_file
	}
} else {
	puts "ADS Info: Cann't find any timing constraint files."
	puts "ADS Info: please finish timing constraint files as ref.sdc in scripts directory."
	exit
}
#set_disable_timing -from A -to Z [get_cells u_clb*/u_clb_input_mux/u_clb_input_mux_in*/u_sync_mux_out]
#return
### tessent logic
#set tessent_apply_mbist_mux_constraints 0
#set_app_var compile_enable_constant_propagation_with_no_boundary_opt false
#set preserve_instances [tessent_get_preserve_instances icl_extract]
#set_boundary_optimization $preserve_instances false
#set_ungroup $preserve_instances false
#set optimize_instances [tessent_get_optimize_instances]
#set_boundary_optimization $optimize_instances true
#set size_only_instances [tessent_get_size_only_instances]
#set_size_only -all_instances $size_only_instances



#return
#set ungroup
#current_design c28_core
#ungroup {u_cpu} -flatten -start_level  3

#set_dont_touch {u_cpu}
#ungroup -all -flatten -start_level  2

## ungroup
if { $GUI_UNGROUP } {
	ungroup -all -flatten
} else {
	set ungroup_list ""
	if { $GUI_UNGROUP_FILE != "" } {
		set F [open $GUI_UNGROUP_FILE r]
		while {![eof $F]} {
			[gets $F line]
			if { [regexp {^#} $line] || ![regexp {\S} $line] } { continue }
			regexp {(\S+)\s+(\S+)} $line total cellname instancename
			lappend ungroup_list $line
		}
		close $F
		foreach one_sub $ungroup_list {
			set_dont_touch [get_cells -hierarchical -filter "ref_name==$one_sub"]
		}
		ungroup -flatten -all
		foreach one_sub $ungroup_list {
			remove_attribute [get_cells -hierarchical -filter "ref_name==$one_sub"] dont_touch
			ungroup -flatten -start_level 2 [get_cells -hierarchical -filter "ref_name==$one_sub"]
		}
	}
}
report_hierarchy -noleaf > ../reports/hierarchy.rpt

## Icc dp flow (topographical mode)
if { $GUI_DCG_MODE } {
	set_ignored_layers -min_routing_layer $GUI_MIN_ROUTE_LAYER -max_routing_layer $GUI_MAX_ROUTE_LAYER
	if { [file isfile $GUI_DEF_FILE] } {
		extract_physical_constraints $GUI_DEF_FILE
	}
	if { $GUI_DP_FLOW } {
		eval compile_ultra -no_seq_output_inversion $compile_ultra_hier_opt
		start_icc_dp -f ../global_scripts/icc_floorplan.tcl
		extract_physical_constraints ../outputs/${GUI_DESIGN_NAME}_dp.def
	}
}

## for clock gating opt
if { $GUI_CLOCK_GATE } {
	set power_cg_module_naming_style CLKGATE_%e_%d
	set power_cg_cell_naming_style %c_clkgate_%n
	set power_cg_gated_clock_net_naming_style %c_gate_%n
	set ckgt_cmd "set_clock_gating_style -sequential latch "
	append ckgt_cmd "-${GUI_GATER_CLOCK_TYPE}_edge_logic {integrated:$GUI_GATER_CLOCK_CELL} "
  if { $GUI_GATER_CLOCK_TYPE1 != "none" } {
    append ckgt_cmd "-${GUI_GATER_CLOCK_TYPE1}_edge_logic {integrated:$GUI_GATER_CLOCK_CELL1} "
  }
	append ckgt_cmd "-control_point $GUI_GATER_CLOCK_CONTROL_POINT "
	if { $GUI_GATER_CLOCK_CONTROL_SIGNAL != "none" } {
		append ckgt_cmd "-control_signal $GUI_GATER_CLOCK_CONTROL_SIGNAL "
	}
	append ckgt_cmd "-minimum_bitwidth $GUI_GATER_CLOCK_MIN_BITWIDTH "
	append ckgt_cmd "-setup $GUI_GATER_SETUP "
	append ckgt_cmd "-num_stages $GUI_GATER_NUM_STAGES "
	append ckgt_cmd "-max_fanout $GUI_GATER_MAX_FANOUT "
  if { $GUI_GATER_CLOCK_CELL != "none" } {
	puts $ckgt_cmd
	eval $ckgt_cmd
  }
	append compile_ultra_hier_opt " -gate_clock "

  if { $GUI_RTL_ICG_TYPE != "none" } {
	set ICG_CELL [get_cells -hier -filter "ref_name=~$GUI_RTL_ICG_TYPE*"]
	set ICG_NUM [sizeof $ICG_CELL]
	if { $ICG_NUM  > 0 } {
 	identify_clock_gating -gating_element [get_cells -hier -filter "ref_name=~$GUI_RTL_ICG_TYPE*"]
 }
 }

	
}

## for low power opt
if { $GUI_POWER_OPT } {
	if { $GUI_DCG_MODE } { set_power_prediction true }
	set_leakage_optimization true
	set_dynamic_optimization true
}

## check design and timing pre compiler
check_design > ../reports/check_design_pre.rpt
check_timing > ../reports/check_timing_pre.rpt

## Prevent assignment statements in the Verilog netlist
set_fix_multiple_port_nets -all -buffer_constants
set_app_var verilogout_no_tri true
set_host_options -max_cores $GUI_MAX_CPU_NUM
set_cost_priority -delay
set verilogout_show_unconnected_pins true

## scan
if { $GUI_DFT } {
	append compile_ultra_hier_opt " -scan"
}

set compile_ultra_cmd "compile_ultra -no_seq_output_inversion -timing_high_effort_script $compile_ultra_hier_opt"
if { $GUI_DCG_MODE } { append compile_ultra_cmd " -spg" }
echo $compile_ultra_cmd
eval $compile_ultra_cmd
#compile -map_effort medium -area_effort none -power_effort none -boundary_optimization

## define bus name style
define_name_rules verilog -target_bus_naming_style {%s[%d]} -case_insensitive
change_name -rules verilog -hierarchy

## Report timing cell power area and constraint
set report_timing_opt	"-transition_time -input_pins -capacitance -nets -significant_digits 3 -sort_by slack"
if { $GUI_REPORT_VIOLATION } { append report_timing_opt " -slack_lesser_than 0" }
foreach_in_collection each_path_group [get_path_group] {
	set path_group [get_object_name $each_path_group]
	regsub -all / $path_group _ path_group_rp
	eval report_timing -max_paths 100 $report_timing_opt -group $path_group > ../reports/${path_group_rp}_max.tim
}
#report_timing -transition -cap -nets -delay max -max_path 50 > ../reports/max_timing.rpt
report_constraint -all_violators -significant_digits 3 > ../reports/violation.rpt
report_qor -significant_digits 3 > ../reports/qor.rpt
report_cell > ../reports/cell.rpt
report_power > ../reports/power.rpt
report_clock_gating > ../reports/clock_gating.rpt
check_design > ../reports/check_design.rpt
check_timing > ../reports/check_timing.rpt
report_hierarchy -noleaf > ../reports/hierarchy.rpt

if { $GUI_DCG_MODE } {
	set report_area_phy_opt "-physical"
}
eval report_area $report_area_phy_opt $hierarchy_opt > ../reports/area.rpt

foreach key [array names STD_LIBRARY_NAME] {
	set lib_type [lindex [split $key ,] 0]
	set lib_pvt  [lindex [split $key ,] 1]
	if { [regexp " $lib_type " " $GUI_STD_LIBRARY "] && $lib_pvt == $GUI_PVT } {
		set_attribute [get_libs $STD_LIBRARY_NAME($key)] -type string default_threshold_voltage_group $lib_type
		echo "set_attribute [get_libs $STD_LIBRARY_NAME($key)] -type string default_threshold_voltage_group $lib_type"
	}
}

report_threshold_voltage_group > ../reports/MultiVt.rpt

### dataout
rename_design -postfix _${GUI_DESIGN_NAME} -update_links [remove_from_collection [get_designs] ${GUI_DESIGN_NAME}]
create_block_abstraction
eval write -format ddc -output ../outputs/${GUI_DESIGN_NAME}_dc.ddc $hierarchy_opt
eval write -format verilog -output ../outputs/${GUI_DESIGN_NAME}_dc.v $hierarchy_opt
write_sdc -version 1.8 ../outputs/${GUI_DESIGN_NAME}_dc.sdc
if { $GUI_UNGROUP_FILE != "" } {
	foreach {cell instance} [get_instance_name $GUI_UNGROUP_FILE] {
		current_design $gui_top_design_name
		characterize   $instance
		current_design $cell
		write_sdc -version 1.8 ../outputs/${cell}_dc.sdc
	}
}

if { $GUI_DCG_MODE } {
	eval write_def -all_vias -output ../outputs/${GUI_DESIGN_NAME}_dc.def
	uniquify
	write_milkyway -output ${GUI_DESIGN_NAME}_dc -overwrite
}

if { $GUI_SYN_CYCLE != 1 } {
	for {set i 2} {$i <= $GUI_SYN_CYCLE} {incr i} {
		set compile_ultra_cmd "compile_ultra -timing_high_effort_script -no_seq_output_inversion $compile_ultra_hier_opt"
		if { $GUI_DCG_MODE } { append compile_ultra_cmd " -spg" }
		echo $compile_ultra_cmd
		eval $compile_ultra_cmd
		create_block_abstraction
		eval write -format ddc -output ../outputs/${GUI_DESIGN_NAME}_dc_loop_$i.ddc $hierarchy_opt
		eval write -format verilog -output ../outputs/${GUI_DESIGN_NAME}_dc_loop_$i.v $hierarchy_opt
		write_sdc ../outputs/${GUI_DESIGN_NAME}_dc_$i.sdc
		if { $GUI_DCG_MODE } {
			eval write_def -all_vias -output ../outputs/${GUI_DESIGN_NAME}_dc_loop_$i.def
			uniquify
			write_milkyway -overwrite -output ${GUI_DESIGN_NAME}_loop_$i
		}
		report_timing \
			-sort_by group -max_paths 100000 -capacitance \
			-trans -significant_digits 3 -nets > ../reports/timing_$i.rpt
		report_qor > ../reports/QoR_loop_$i.rpt
	}
}

#redirect -tee -file ../reports/proc_qor.log {
#    proc_qor -csv_file ../reports/proc_qor.csv
#}

set_svf -off
print_message_info
set endtime [clock seconds]
report_runtime
if { !$GUI_DEBUG_MODE } { exit }
