#############################################################################
# Genus synthesis: pipelined_cpu_core -> Nangate45 gate netlist
#
# Author: Elliot Staresinic
#
# Run from a run directory:   genus -files $PNR_ROOT/scripts/genus.tcl
#
# Outputs land in the CURRENT directory, inputs come from $PNR_ROOT. That is
# what lets several runs coexist: each one owns its out/ and reports/ and
# nothing is shared but the source.
#
# This replaces the yosys run in Verilog/CPU/sta. The design is identical,
# so the two are directly comparable, and any difference is the synthesiser
# rather than the RTL.
#
# There is no blackboxing here. The memories are outside pipelined_cpu_core
# by construction, so nothing needs to be hidden from the tool and the
# "did the memory get optimised away" question does not arise.
#############################################################################

set NG45    $env(HOME)/MacroPlacement/Enablements/NanGate45
set DESIGN  pipelined_cpu_core

# Sources are read from the project root, results are written where we stand.
# PNR_ROOT is set by run.sh; the fallback keeps a hand run from work/ working.
if {[info exists env(PNR_ROOT)]} {
    set ROOT $env(PNR_ROOT)
} else {
    set ROOT ..
}

set RTL     $ROOT/rtl
set SDC     $ROOT/constraints/${DESIGN}.sdc
set OUT     out
set RPT     reports

file mkdir $OUT
file mkdir $RPT

#--------------------------------------------------------------------------
# Libraries
#--------------------------------------------------------------------------
# SYNTHESISE AT THE CORNER YOU WILL BE JUDGED AT.
#
# Genus optimises against whatever library it is given and then spends what is
# left over on area, so a netlist built at typical has no reason to be fast
# enough at slow. Handing it the slow library is not a margin trick, it is the
# only way the netlist and the signoff view agree about what the cells cost.
#
# SYN_CORNER lets run.sh pick, which is what makes the corner a controlled
# variable rather than a rewrite. Setting it to typical reproduces runs 00
# through 03 exactly.
if {[info exists env(SYN_CORNER)]} {
    set SYN_CORNER $env(SYN_CORNER)
} else {
    set SYN_CORNER slow
}

switch -- $SYN_CORNER {
    slow    {set SYN_LIB NangateOpenCellLibrary_slow.lib}
    fast    {set SYN_LIB NangateOpenCellLibrary_fast.lib}
    typical {set SYN_LIB NangateOpenCellLibrary_typical.lib}
    default {
        puts "### SYN_CORNER '$SYN_CORNER' is not slow, fast or typical."
        exit 1
    }
}

if {![file exists $NG45/lib/$SYN_LIB]} {
    puts "### missing library: $NG45/lib/$SYN_LIB"
    puts "### slow and fast are not in the stock MacroPlacement enablement."
    puts "### They come from The-OpenROAD-Project/OpenROAD test/Nangate45."
    exit 1
}

puts "### synthesising against $SYN_LIB"

set_db init_lib_search_path $NG45/lib
set_db library [list $NG45/lib/$SYN_LIB]

# The LEF is not needed for logic synthesis, but giving it to Genus lets it
# use real cell dimensions when it estimates area and wire load.
set_db lef_library [list \
    $NG45/lef/NangateOpenCellLibrary.tech.lef \
    $NG45/lef/NangateOpenCellLibrary.macro.mod.lef ]

#--------------------------------------------------------------------------
# Read and elaborate
#--------------------------------------------------------------------------
read_hdl [glob $RTL/*.v]
elaborate $DESIGN

# check_design catches unconnected ports and multiply driven nets. It is
# worth reading even when it passes.
check_design -unresolved
check_design -all > $RPT/00_check_design.rpt

read_sdc $SDC

#--------------------------------------------------------------------------
# Synthesise
#
# medium effort on the first pass. Push to high once the flow runs clean
# and you are chasing a number rather than a result.
#
# The effort comes from the environment rather than from an edit here, so a
# run RECORDS what it was built at. run.sh writes it into RUN.env and qor.py
# puts it in the table beside the clock. Two runs at the same period that
# differ only in effort are otherwise indistinguishable in the results, which
# is the one thing this experiment exists to tell apart.
#
# A bad value is an error, not a fallback. Silently reverting a typo'd
# "hgih" to medium would produce a run labelled high effort that was not, and
# a wrong number that looks measured is worse than a failed run.
#--------------------------------------------------------------------------
set syn_effort "medium"
if {[info exists ::env(SYN_EFFORT)]} {
    set syn_effort $::env(SYN_EFFORT)
}
if {[lsearch -exact {low medium high} $syn_effort] < 0} {
    error "SYN_EFFORT must be low, medium or high, not '$syn_effort'"
}
puts "INFO: synthesis effort = $syn_effort"

set_db syn_generic_effort $syn_effort
set_db syn_map_effort     $syn_effort
set_db syn_opt_effort     $syn_effort

syn_generic
syn_map
syn_opt

#--------------------------------------------------------------------------
# Hand off to Innovus
#--------------------------------------------------------------------------
write_hdl                  > $OUT/${DESIGN}_netlist.v
write_sdc                  > $OUT/${DESIGN}.sdc

report_area                > $RPT/01_syn_area.rpt
report_gates               > $RPT/02_syn_gates.rpt
report_timing              > $RPT/03_syn_timing.rpt
report_timing -unconstrained > $RPT/04_syn_unconstrained.rpt
report_power               > $RPT/05_syn_power.rpt

puts "=========================================================="
puts " SYNTHESIS DONE"
puts "   netlist : $OUT/${DESIGN}_netlist.v"
puts "   sdc     : $OUT/${DESIGN}.sdc"
puts "   reports : $RPT"
puts "=========================================================="
puts " Look at 03_syn_timing.rpt before going on. The slack there"
puts " is the pre-layout number, and post-route will be worse."
puts "=========================================================="

exit
