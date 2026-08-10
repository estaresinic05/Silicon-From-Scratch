#############################################################################
# Genus: synthesise ONE adder benchmark and report what it cost.
#
# Author: Elliot Staresinic
#
# Driven by run.sh, which sets ADDER_TOP, CLK_PERIOD, SYN_CORNER and EXP_ROOT
# and runs this once per adder. Nothing here knows which adder it is building,
# which is the point: both go through the identical script.
#############################################################################

set NG45 $env(HOME)/MacroPlacement/Enablements/NanGate45
set ROOT $env(EXP_ROOT)
set TOP  $env(ADDER_TOP)

file mkdir out
file mkdir reports

#--------------------------------------------------------------------------
# Library. Same corner selection as the main flow, and the same reason: a
# netlist built at typical has no claim to be fast anywhere else.
#--------------------------------------------------------------------------
if {[info exists env(SYN_CORNER)]} {
    set SYN_CORNER $env(SYN_CORNER)
} else {
    set SYN_CORNER slow
}
switch -- $SYN_CORNER {
    slow    {set SYN_LIB NangateOpenCellLibrary_slow.lib}
    fast    {set SYN_LIB NangateOpenCellLibrary_fast.lib}
    typical {set SYN_LIB NangateOpenCellLibrary_typical.lib}
    default {puts "### SYN_CORNER '$SYN_CORNER' is not slow, fast or typical."; exit 1}
}

set_db init_lib_search_path $NG45/lib
set_db library [list $NG45/lib/$SYN_LIB]
set_db lef_library [list \
    $NG45/lef/NangateOpenCellLibrary.tech.lef \
    $NG45/lef/NangateOpenCellLibrary.macro.mod.lef ]

#--------------------------------------------------------------------------
# Read. Both adders and both wrappers are read every time; elaborating one
# top is what selects which adder is actually built, and the other is simply
# never instantiated.
#--------------------------------------------------------------------------
read_hdl -sv [list \
    $ROOT/../../rtl/full_adder.v \
    $ROOT/../../rtl/ripple_carry_adder.v \
    $ROOT/rtl/carry_lookahead.v \
    $ROOT/rtl/adder_bench.v ]

elaborate $TOP

#--------------------------------------------------------------------------
# Constraints.
#
# The clock is set FAR tighter than either adder can reach, on purpose. A run
# that meets its constraint stops optimising and spends what is left on area,
# so a met constraint tells you what you asked for and never what was
# achievable. Both adders miss by a lot, both are therefore pushed as hard as
# the tool knows how, and the Data Path number is then a fair comparison.
#--------------------------------------------------------------------------
create_clock -name clk -period $env(CLK_PERIOD) [get_ports clk]

# The registers at both ends are inside the design, so the only path that
# matters is register to register. The inputs and outputs are given generous
# budgets so no I/O path can become the worst one and hide the adder.
set_input_delay  0.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.0 -clock clk [all_outputs]

set_db syn_generic_effort high
set_db syn_map_effort     high
set_db syn_opt_effort     high

syn_generic
syn_map
syn_opt

#--------------------------------------------------------------------------
# Report
#--------------------------------------------------------------------------
write_hdl > out/${TOP}_netlist.v

report_timing      > reports/timing.rpt
report_area        > reports/area.rpt
report_gates       > reports/gates.rpt
report_power       > reports/power.rpt

puts "=========================================================="
puts " $TOP at ${SYN_CORNER}, clock $env(CLK_PERIOD) ns"
puts " reports/timing.rpt holds the Data Path number"
puts "=========================================================="

exit
