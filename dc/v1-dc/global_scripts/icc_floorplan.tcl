##------------------------------------------------
## Create Floorplan
##------------------------------------------------
if { ${GUI_FLOORPLAN_TYPE} == "DEF" } {
	if { ![file isfile $GUI_DEF_FILE] } {
		proc_print_msg -E "Please specify DEF file !"
	}
} elseif { ${GUI_FLOORPLAN_TYPE} == "UTIL" } {
	proc_print_msg -I "Complete floorplan by core_utilization & core_aspect_ratio......"
	if { ${GUI_CORE_UTIL} != "" && ${GUI_CORE_RATIO} != "" } {
		create_floorplan \
			-core_utilization ${GUI_CORE_UTIL} \
			-core_aspect_ratio ${GUI_CORE_RATIO} \
			-left_io2core $GUI_L2C \
			-right_io2core $GUI_R2C \
			-top_io2core $GUI_T2C \
			-bottom_io2core $GUI_B2C
	} else {
		proc_print_msg -E "You should define both CORE_UTIL & CORE_RATIO......"
	}
} elseif { ${GUI_FLOORPLAN_TYPE} == "WH" } {
	proc_print_msg -I "Complete floorplan by core_width & core_height ......"
	if { ${GUI_CORE_WIDTH} != "" && ${GUI_CORE_HEIGHT} != "" } {
		create_floorplan \
			-control_type width_and_height \
			-core_width ${GUI_CORE_WIDTH} \
			-core_height ${GUI_CORE_HEIGHT} \
			-left_io2core $GUI_L2C \
			-right_io2core $GUI_R2C \
			-top_io2core $GUI_T2C \
			-bottom_io2core $GUI_B2C
	} else {
		proc_print_msg -E "You should define both CORE_WIDTH  & CORE_HEIGHT......"
	}
} else {
	proc_print_msg -E "You should define one type of the floorplan......"
}

##------------------------------------------------
## Create FP placement
##------------------------------------------------

set_keepout_margin  -type hard -all_macros -outer $GUI_DP_KEEPOUT_MARGIN
set_fp_placement_strategy \
	-macros_on_edge auto \
	-auto_grouping high \
	-congestion_effort high

if { [file exists ${GUI_DP_CONSTRAINT_FILE}] } {
	source ${GUI_DP_CONSTRAINT_FILE}
}
place_fp_pins -block_level
create_fp_placement -effort high -congestion_driven -timing_driven

set hardmacros [get_cells -hier -filter "@mask_layout_type == macro"]
set_attr $hardmacros is_fixed true

define_name_rules verilog -target_bus_naming_style {%s[%d]} -case_insensitive
change_name -rules verilog -hierarchy

write_def -all_vias -rows_tracks_gcells -regions_groups -macro -pins -blockages -specialnets -output ../outputs/${GUI_DESIGN_NAME}_dp.def
update_dc_floorplan
exit