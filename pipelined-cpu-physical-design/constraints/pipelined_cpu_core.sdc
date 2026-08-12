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

# The period comes from the environment when run.sh sets it, so a sweep is a
# loop rather than eleven hand edits and a lost comparison. Running the tools
# directly with nothing in the environment gets the default below.
#
# Only Genus reads this file. Innovus reads the SDC Genus writes out, which
# already has the period baked in, so setting it once here carries it through
# the whole flow.
if {[info exists env(CLK_PERIOD)]} {
    set CLK_PERIOD $env(CLK_PERIOD)
} else {
    set CLK_PERIOD 3.0
}

create_clock -name clk -period $CLK_PERIOD [get_ports clk]

# Modelled uncertainty stands in for jitter and, before CTS, for skew.
#
# Setup and hold get separate numbers, and they must. An unqualified
# set_clock_uncertainty applies to BOTH checks, which sounds conservative
# and is not, because the two checks use it with opposite sign. For setup
# it comes out of the budget, which is the pessimism you want. For hold it
# is ADDED to the requirement, so it demands the data arrive later than
# physics needs.
#
# The 08 Aug run reported ten violated hold paths between -0.011 and
# -0.014 ns. Every one was manufactured here: a 0.10 ns hold margin sitting
# on top of a 0.012 ns flip-flop requirement that the design already met
# with 0.085 ns to spare. 0.02 ns is a realistic figure for jitter alone,
# which is all hold has to cover once the clock tree is real.
set_clock_uncertainty -setup 0.10 [get_clocks clk]
set_clock_uncertainty -hold  0.02 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

# The RAW reset port is asynchronous and genuinely cannot be timed: it has no
# relationship to clk, so there is no edge to measure it against.
#
# THIS LINE USED TO DISABLE FAR MORE THAN THAT, and check_timing found it on
# 2026-08-12. Before reset_sync existed the port drove the reset pin of all
# 1347 flops directly, so `-from [get_ports reset]` made every one of those
# pins an unconstrained endpoint: 4041 uncons_endpoint warnings, and all 1349
# recovery checks reported UNTESTED by report_analysis_coverage. Asserting a
# reset asynchronously is correct. Releasing one that way is a real silicon
# bug, and the check that would have caught it was switched off.
#
# It now covers only what it should. rst_sync is driven by a register inside
# reset_sync, so every path from there to a flop's reset pin STARTS AT A FLOP,
# not at this port, and is timed normally. `-from` constrains startpoints, so
# those paths are not matched by this exception. What remains matched is the
# port to the synchroniser's own async pins, which is the one arc that really
# is unmeasurable.
#
# The `no_input_delay` warning on this port is expected and correct for the
# same reason: there is no clock to reference an input delay to.
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
