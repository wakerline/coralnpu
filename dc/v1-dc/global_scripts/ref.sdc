###################################################################################
## parameter define ,modify by custom
###################################################################################
set driving_cell {STH_BUF_6 A X}
set output_load 0.1
set max_fanout 20
set max_transition 0.3
set input_delay 0.1
set output_delay 0.1

###################################################################################
## common timing constrains
###################################################################################
###clock define
create_clock -name clk -period 1.6  [get_ports clk]
set_clock_uncertainty -setup 0.1 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_clock_gating_check -setup 0.1 [get_clocks clk]
set_clock_gating_check -hold 0.1 [get_clocks clk]
set_clock_transition 0.1 clk

set all_real_clock [filter_collection [get_attribute [get_clocks] sources] object_class==port]
if {$synopsys_program_name == "dc_shell" || $synopsys_program_name == "icc_shell" } { set_ideal_network $all_real_clock }
if {$synopsys_program_name == "pt_shell"} { set_propagated_clock [all_clocks]}
###common constrains
set_max_fanout $max_fanout [current_design]
set_max_transition $max_transition [current_design]
###inputs driving
set_driving_cell -lib_cell [lindex $driving_cell 0] -pin [lindex $driving_cell 2] \
			[remove_from_collection [all_inputs] $all_real_clock]
###outputs load
set_load $output_load [all_outputs]
###group path
group_path -name D-L -from [remove_from_collection [all_inputs] ${all_real_clock}]
group_path -name C-O -to [all_outputs]
group_path -name D-O -from [remove_from_collection [all_inputs] ${all_real_clock}] -to [all_outputs]

###################################################################################
###port timing constrains & special constrains
###################################################################################
set_input_delay -clock clk $input_delay [remove_from_collection [all_inputs] $all_real_clock]
set_output_delay -clock clk $output_delay [all_outputs]
