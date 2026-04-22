###################################################################################
## parameter define ,modify by custom
###################################################################################
if {![info exists INPUT_DELAY]} {
  set INPUT_DELAY 0.5
}
if {![info exists OUTPUT_DELAY]} {
  set OUTPUT_DELAY 0.5
}
if {![info exists CLK_PERIOD]} {
  set CLK_PERIOD 2
}
if {![info exists CLK_UNCERTAINTY]} {
  set CLK_UNCERTAINTY 0.2
}
if {![info exists CLK_TRAN]} {
  set CLK_TRAN 0.1
}

###################################################################################
## common timing constrains
###################################################################################
###clock define
create_clock -name GCLK -period $CLK_PERIOD [get_ports io_aclk]
set_clock_uncertainty -setup $CLK_UNCERTAINTY [get_clocks GCLK]
set_clock_uncertainty -hold  $CLK_UNCERTAINTY [get_clocks GCLK]
set_clock_transition $CLK_TRAN [get_clocks GCLK]

set_ideal_network [get_ports {io_aclk io_aresetn}]

set all_real_clock [filter_collection [get_attribute [get_clocks] sources] object_class==port]
if {$synopsys_program_name == "dc_shell" || $synopsys_program_name == "icc_shell" } { set_ideal_network $all_real_clock }
if {$synopsys_program_name == "pt_shell"} { set_propagated_clock [all_clocks]}
###common constrains
#set_max_fanout $max_fanout [current_design]
#set_max_transition $max_transition [current_design]
###inputs driving
#set_driving_cell -lib_cell [lindex $driving_cell 0] -pin [lindex $driving_cell 2] \
#                       [remove_from_collection [all_inputs] $all_real_clock]
###outputs load
#set_load $output_load [all_outputs]
###group path
group_path -name INPUTS -from [remove_from_collection [all_inputs] ${all_real_clock}]
group_path -name OUTPUTS -to [all_outputs]
group_path -name COMBO -from [remove_from_collection [all_inputs] ${all_real_clock}] -to [all_outputs]
group_path -name GCLK -critical 0.2 -weight 5
###################################################################################
###port timing constrains & special constrains
###################################################################################
set_input_delay -clock GCLK -max $INPUT_DELAY [remove_from_collection [all_inputs] $all_real_clock]
set_output_delay -clock GCLK -max $OUTPUT_DELAY [all_outputs]
