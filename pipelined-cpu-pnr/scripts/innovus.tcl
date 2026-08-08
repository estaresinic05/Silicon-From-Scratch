#############################################################################
# Innovus place and route: pipelined_cpu_core on Nangate45
#
# Author: Elliot Staresinic
#
# Run from pipelined-cpu-pnr/work:   innovus -files ../scripts/innovus.tcl
#
# This design contains NO MACROS. Everything is standard cells, so there is
# no macro placement, no halo, and no PG model needed before placement. The
# flow is floorplan, power, place, clock tree, route, verify.
#
# The design is saved after every stage into enc/. If a stage fails you can
# restore the last good one instead of starting over:
#     restoreDesign enc/<stage>.enc pipelined_cpu_core
#############################################################################

set NG45   $env(HOME)/MacroPlacement/Enablements/NanGate45
set DESIGN pipelined_cpu_core
set SITE   FreePDK45_38x28_10R_NP_162NW_34O

# Core utilization for the first floorplan. 0.70 is a normal starting point:
# dense enough to be a real problem, loose enough to route.
set UTIL   0.70
set ASPECT 1.0
set MARGIN 10

file mkdir enc
file mkdir reports

#--------------------------------------------------------------------------
# 1. Libraries, netlist, constraints
#--------------------------------------------------------------------------
set init_lef_file [list \
    $NG45/lef/NangateOpenCellLibrary.tech.lef \
    $NG45/lef/NangateOpenCellLibrary.macro.mod.lef ]

set init_verilog          ../out/${DESIGN}_netlist.v
set init_top_cell         $DESIGN
set init_design_netlisttype Verilog
set init_design_settop    1
set init_pwr_net          VDD
set init_gnd_net          VSS

# One corner is enough for a first run. Cmax with the QRC techfile means
# extraction is real rather than a default table.
create_library_set   -name WC_LIB -timing [list $NG45/lib/NangateOpenCellLibrary_typical.lib]
create_rc_corner     -name Cmax -qx_tech_file $NG45/qrc/NG45.tch -T 25
create_delay_corner  -name WC -library_set WC_LIB -rc_corner Cmax
create_constraint_mode -name CON -sdc_files [list ../out/${DESIGN}.sdc]
create_analysis_view  -name WC_VIEW -constraint_mode CON -delay_corner WC

init_design -setup {WC_VIEW} -hold {WC_VIEW}

setAnalysisMode -analysisType onChipVariation -cppr both
setDesignMode -process 45
setDesignMode -topRoutingLayer 10 -bottomRoutingLayer 2

#--------------------------------------------------------------------------
# 2. Floorplan
#
# Utilization based rather than fixed size: the tool computes a core big
# enough to hold the cells at $UTIL density, square, with a $MARGIN ring
# for the power ring and pins.
#--------------------------------------------------------------------------
floorPlan -site $SITE -r $ASPECT $UTIL $MARGIN $MARGIN $MARGIN $MARGIN

# Spread the pins around the boundary instead of leaving them stacked.
setPinAssignMode -pinEditInBatch true
editPin -pin [all_inputs]  -side LEFT  -layer 3 -spreadType SIDE -unit MICRON -spreadDirection clockwise
editPin -pin [all_outputs] -side RIGHT -layer 3 -spreadType SIDE -unit MICRON -spreadDirection clockwise
setPinAssignMode -pinEditInBatch false

saveDesign enc/01_floorplan.enc
puts "### STAGE 1 floorplan done. Die: [dbGet top.fPlan.box]"

#--------------------------------------------------------------------------
# 3. Power
#
# globalNetConnect is what tells the tool that every cell's VDD pin belongs
# to the VDD net. That connection is not in the netlist and never is.
#--------------------------------------------------------------------------
clearGlobalNets
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi -inst * -override
globalNetConnect VSS -type tielo -inst * -override

setGenerateViaMode -auto true
generateVias

# Nangate45 preferred directions alternate: odd layers horizontal, even
# vertical. So a ring's top and bottom run on metal9 and its sides on
# metal8, and vertical straps go on metal8.
addRing -nets {VDD VSS} -type core_rings -follow core \
        -layer {top metal9 bottom metal9 left metal8 right metal8} \
        -width 2 -spacing 1 -offset 1

addStripe -nets {VDD VSS} -layer metal8 -direction vertical \
          -width 1 -spacing 1 -set_to_set_distance 25 -start_offset 8

# sroute ties the metal1 rails inside every standard cell row up to the grid.
sroute -nets {VDD VSS} -connect corePin

saveDesign enc/02_power.enc
puts "### STAGE 2 power grid done."

#--------------------------------------------------------------------------
# 4. Placement
#--------------------------------------------------------------------------
setPlaceMode -place_detail_legalization_inst_gap 1
place_opt_design -out_dir reports -prefix place

saveDesign enc/03_placed.enc
report_timing -late > reports/10_place_timing.rpt
puts "### STAGE 3 placement done."

#--------------------------------------------------------------------------
# 5. Clock tree
#
# Before this the clock is ideal: zero skew, zero insertion delay. After
# it the clock is a real buffered network and the numbers get honest.
#--------------------------------------------------------------------------
create_ccopt_clock_tree_spec
ccopt_design

set_interactive_constraint_modes [all_constraint_modes -active]
set_propagated_clock [all_clocks]
set_clock_propagation propagated

saveDesign enc/04_cts.enc
report_timing -late  > reports/20_cts_setup.rpt
report_timing -early > reports/21_cts_hold.rpt
report_ccopt_clock_trees > reports/22_clock_tree.rpt
puts "### STAGE 4 clock tree done."

#--------------------------------------------------------------------------
# 6. Filler cells
#
# Fillers close the gaps between placed cells so the wells and the metal1
# power rails are continuous across every row. Without them the rails are
# broken and the design is not manufacturable.
#--------------------------------------------------------------------------
addFiller -cell {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1} \
          -prefix FILLER

#--------------------------------------------------------------------------
# 7. Routing
#--------------------------------------------------------------------------
setNanoRouteMode -routeWithTimingDriven true
setNanoRouteMode -routeWithSiDriven true
setNanoRouteMode -routeUseAutoVia true
setNanoRouteMode -drouteVerboseViolationSummary 1

routeDesign

saveDesign enc/05_routed.enc
puts "### STAGE 5 routing done."

#--------------------------------------------------------------------------
# 8. Post route optimisation
#
# This is the first point where timing is computed from extracted
# parasitics on real wires rather than from estimates. It is the only
# number worth quoting.
#--------------------------------------------------------------------------
optDesign -postRoute

saveDesign enc/06_final.enc

#--------------------------------------------------------------------------
# 9. Verify and report
#--------------------------------------------------------------------------
verify_connectivity -type all -error 0 -warning 0 > reports/30_connectivity.rpt
verify_drc -limit 100                             > reports/31_drc.rpt

report_timing -late  -max_paths 10 > reports/40_final_setup.rpt
report_timing -early -max_paths 10 > reports/41_final_hold.rpt
report_area                        > reports/42_final_area.rpt
report_power                       > reports/43_final_power.rpt
summaryReport -noHtml -outfile reports/44_summary.rpt

defOut -netlist -floorplan -routing ${DESIGN}_final.def

# GDSII, only if the Nangate45 stream file has been fetched. run.sh can
# download it; without it the DEF above is still a complete layout.
set GDS_IN $env(HOME)/nangate45_gds/NangateOpenCellLibrary.gds
if {[file exists $GDS_IN]} {
    streamOut ${DESIGN}.gds \
        -libName ${DESIGN} -merge [list $GDS_IN] -units 1000 -mode ALL
    puts "### GDSII written: ${DESIGN}.gds"
} else {
    puts "### GDSII skipped: no stream file at $GDS_IN"
}

puts "=========================================================="
puts " PLACE AND ROUTE DONE"
puts "   database : enc/06_final.enc"
puts "   layout   : ${DESIGN}_final.def"
puts "   reports  : reports/"
puts "=========================================================="
puts " Read reports/40_final_setup.rpt first. The slack on the"
puts " worst path is your post-route timing result."
puts "=========================================================="
