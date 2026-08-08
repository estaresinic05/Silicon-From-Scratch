#############################################################################
# Timing constraints for pipelined_cpu_core
#
# Author: Elliot Staresinic
#
# START LOOSE. The clock below is 3.0 ns, which is well slower than the
# 1.81 ns this design reached in pre-layout synthesis. That is deliberate:
# the goal of the first run is one clean end to end pass, not a timing
# result. Fighting timing on run one is how people abandon a flow.
#
# Once a run completes clean, tighten CLK_PERIOD until it fails, and the
# last value that passed post-route is the real number.
#############################################################################

set CLK_PERIOD 3.0

create_clock -name clk -period $CLK_PERIOD [get_ports clk]

# Modelled uncertainty stands in for jitter and, before CTS, for skew.
set_clock_uncertainty 0.10 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

# reset is asynchronous by design, so it is not a timed path.
set_false_path -from [get_ports reset]

#############################################################################
# Memory interface
#
# The instruction and data memories live outside this block. Budgeting 30%
# of the cycle each way says the memory answers within 30% of a period and
# needs 30% of a period of setup at its own input. Those are assumptions,
# not measurements, and they must be quoted alongside any timing result.
#############################################################################

set IO_DELAY [expr {$CLK_PERIOD * 0.30}]

set_input_delay  $IO_DELAY -clock clk [get_ports {imem_rdata[*]}]
set_input_delay  $IO_DELAY -clock clk [get_ports {dmem_rdata[*]}]

set_output_delay $IO_DELAY -clock clk [get_ports {imem_addr[*]}]
set_output_delay $IO_DELAY -clock clk [get_ports {dmem_addr[*]}]
set_output_delay $IO_DELAY -clock clk [get_ports {dmem_wdata[*]}]
set_output_delay $IO_DELAY -clock clk [get_ports {dmem_write}]
set_output_delay $IO_DELAY -clock clk [get_ports {dmem_read}]

# The dbg_* ports are observation only and carry no functional weight, but
# they must still be constrained or their paths go unanalysed.
set_output_delay $IO_DELAY -clock clk [get_ports {dbg_pc[*]}]
set_output_delay $IO_DELAY -clock clk [get_ports {dbg_wb_addr[*]}]
set_output_delay $IO_DELAY -clock clk [get_ports {dbg_wb_data[*]}]
set_output_delay $IO_DELAY -clock clk [get_ports {dbg_wb_enable}]

#############################################################################
# Boundary environment
#
# Without these the tool assumes an ideal driver and zero load at the block
# boundary, which flatters every I/O path.
#############################################################################

set_driving_cell -lib_cell BUF_X2 -pin Z [all_inputs]
set_load 0.02 [all_outputs]

set_max_transition 0.30 [current_design]
set_max_fanout 20 [current_design]
