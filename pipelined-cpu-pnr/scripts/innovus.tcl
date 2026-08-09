#############################################################################
# Innovus place and route: pipelined_cpu_core on Nangate45
#
# Author: Elliot Staresinic
#
# Run from a run directory:   innovus -files $PNR_ROOT/scripts/innovus.tcl
#
# This design contains NO MACROS. Everything is standard cells, so there is
# no macro placement, no halo, and no PG model needed before placement. The
# flow is floorplan, power, place, clock tree, route, verify.
#
# The design is saved after every stage into enc/, and START_STAGE lets you
# begin from any of them instead of from the top. Placement takes minutes on
# this design and hours on a real one, so re-running it to try a different
# CTS setting is waste you only tolerate once.
#
#     START_STAGE=cts   ./run.sh ...     restores enc/03_placed.enc
#
# Stage names, in order: floorplan power place cts route report
#############################################################################

set NG45   $env(HOME)/MacroPlacement/Enablements/NanGate45
set DESIGN pipelined_cpu_core
set SITE   FreePDK45_38x28_10R_NP_162NW_34O

# Sources come from the project root, everything written lands where we stand.
if {[info exists env(PNR_ROOT)]} {
    set ROOT $env(PNR_ROOT)
} else {
    set ROOT ..
}

#--------------------------------------------------------------------------
# Stage gating
#
# run_from returns true for every stage at or after START_STAGE, so each
# section below is guarded by one call and the default path stays exactly
# what it was: START_STAGE unset means floorplan, means run everything.
#--------------------------------------------------------------------------
set STAGE_ORDER {floorplan power place cts route report}

if {[info exists env(START_STAGE)]} {
    set START $env(START_STAGE)
} else {
    set START floorplan
}

set START_IDX [lsearch $STAGE_ORDER $START]
if {$START_IDX < 0} {
    puts "### START_STAGE '$START' is not one of: $STAGE_ORDER"
    exit 1
}

proc run_from {stage} {
    global STAGE_ORDER START_IDX
    return [expr {[lsearch $STAGE_ORDER $stage] >= $START_IDX}]
}

# The database to restore when starting partway in: whatever the stage
# BEFORE START_STAGE saved.
#
# NOTE THE .dat, it is load bearing. saveDesign enc/03_placed.enc writes TWO
# things: a small Tcl script called 03_placed.enc, and the actual session
# directory 03_placed.enc.dat beside it. restoreDesign wants the DIRECTORY.
# Handing it the .enc file gets you
#
#     IMPSYT-7338: The specified design session directory
#     '.../enc/03_placed.enc' could not be located as specified.
#
# which reads like a missing file and is nothing of the kind. The file is
# sitting right there. It simply is not the thing being asked for.
array set RESTORE_FROM {
    power  enc/01_floorplan.enc.dat
    place  enc/02_power.enc.dat
    cts    enc/03_placed.enc.dat
    route  enc/04_cts.enc.dat
    report enc/05_routed.enc.dat
}

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
# A full start reads the netlist and builds the analysis view. A resumed start
# restores a saved database, which already carries its libraries, its
# constraints and its views, so init_design must NOT run again.
if {[run_from floorplan]} {

    set init_lef_file [list \
        $NG45/lef/NangateOpenCellLibrary.tech.lef \
        $NG45/lef/NangateOpenCellLibrary.macro.mod.lef ]

    set init_verilog          out/${DESIGN}_netlist.v
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
    create_constraint_mode -name CON -sdc_files [list out/${DESIGN}.sdc]
    create_analysis_view  -name WC_VIEW -constraint_mode CON -delay_corner WC

    init_design -setup {WC_VIEW} -hold {WC_VIEW}

} else {
    set RESTORE $RESTORE_FROM($START)

    # isdirectory, not exists. The sibling .enc file is present whether or not
    # the session directory beside it is, so testing for a file would let a
    # broken resume straight through this guard to fail inside restoreDesign.
    if {![file isdirectory $RESTORE]} {
        puts "### cannot resume at '$START': $RESTORE is not there."
        puts "### run the earlier stages in this run directory first."
        exit 1
    }
    puts "### resuming at stage '$START' from $RESTORE"
    restoreDesign $RESTORE $DESIGN
}

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
if {[run_from floorplan]} {
    floorPlan -site $SITE -r $ASPECT $UTIL $MARGIN $MARGIN $MARGIN $MARGIN

    # Spread the pins along the boundary instead of leaving them stacked.
    #
    # Two traps here, both already paid for:
    #   -unit obliges -spacing, so it is absent. -spreadType side already
    #   distributes pins evenly along the whole edge.
    #
    #   editPin -pin wants pin NAMES. [all_inputs] returns an SDC collection
    #   handle, and passing it makes the tool look for a pin literally called
    #   "0x21b". The names come from the design database instead.
    #
    # Wrapped in catch because pin placement is an optimisation, not a
    # requirement. If it fails the flow should carry on with default pins
    # rather than throw away the stages that follow.
    if {[catch {
        setPinAssignMode -pinEditInBatch true
        set IN_PINS  [dbGet -e [dbGet -p2 -e top.terms.direction input ].name]
        set OUT_PINS [dbGet -e [dbGet -p2 -e top.terms.direction output].name]
        editPin -pin $IN_PINS  -side LEFT  -layer 3 -spreadType side
        editPin -pin $OUT_PINS -side RIGHT -layer 3 -spreadType side
        setPinAssignMode -pinEditInBatch false
        puts "### pins spread: [llength $IN_PINS] in on LEFT, [llength $OUT_PINS] out on RIGHT"
    } msg]} {
        setPinAssignMode -pinEditInBatch false
        puts "### pin spreading skipped, using default placement"
        puts "### reason: $msg"
    }

    saveDesign enc/01_floorplan.enc
    puts "### STAGE 1 floorplan done. Die: [dbGet top.fPlan.box]"
}

#--------------------------------------------------------------------------
# 3. Power
#
# globalNetConnect is what tells the tool that every cell's VDD pin belongs
# to the VDD net. That connection is not in the netlist and never is.
#--------------------------------------------------------------------------
if {[run_from power]} {
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
}

#--------------------------------------------------------------------------
# 4. Placement
#--------------------------------------------------------------------------
if {[run_from place]} {
    setPlaceMode -place_detail_legalization_inst_gap 1
    place_opt_design -out_dir reports -prefix place

    saveDesign enc/03_placed.enc
    report_timing -late > reports/10_place_timing.rpt
    puts "### STAGE 3 placement done."
}

#--------------------------------------------------------------------------
# 5. Clock tree
#
# Before this the clock is ideal: zero skew, zero insertion delay. After
# it the clock is a real buffered network and the numbers get honest.
#--------------------------------------------------------------------------
# clock_opt_design, not ccopt_design. place_opt_design at stage 3 leaves the
# database in the unified PODv2 flow, and that flow has its own command set:
#     place_opt_design -> clock_opt_design -> route_opt_design
# Mixing the older ccopt_design in gives IMPCCOPT-2440.
if {[run_from cts]} {
    create_ccopt_clock_tree_spec
    clock_opt_design

    set_interactive_constraint_modes [all_constraint_modes -active]
    set_propagated_clock [all_clocks]
    set_clock_propagation propagated

    saveDesign enc/04_cts.enc
    report_timing -late  > reports/20_cts_setup.rpt
    report_timing -early > reports/21_cts_hold.rpt
    puts "### STAGE 4 clock tree done."
}

#--------------------------------------------------------------------------
# 6. Filler cells
#
# Fillers close the gaps between placed cells so the wells and the metal1
# power rails are continuous across every row. Without them the rails are
# broken and the design is not manufacturable.
#--------------------------------------------------------------------------
if {[run_from route]} {
    addFiller -cell {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1} \
              -prefix FILLER

    #--------------------------------------------------------------------------
    # 7. Routing
    #--------------------------------------------------------------------------
    setNanoRouteMode -routeWithTimingDriven true
    setNanoRouteMode -routeWithSiDriven true
    setNanoRouteMode -routeUseAutoVia true
    setNanoRouteMode -drouteVerboseViolationSummary 1

    # route_opt_design rather than routeDesign, for the same PODv2 reason as
    # clock_opt_design above. It routes and then optimises against extracted
    # parasitics, so it covers what optDesign -postRoute used to do separately.
    route_opt_design

    saveDesign enc/05_routed.enc
    puts "### STAGE 5 routing done."
}

#--------------------------------------------------------------------------
# 8. Final database
#
# route_opt_design above already optimised against extracted parasitics,
# so there is no separate postRoute pass to run. From here the timing
# numbers come from real wires rather than estimates, which is what makes
# them the only ones worth quoting.
#--------------------------------------------------------------------------
saveDesign enc/06_final.enc

#--------------------------------------------------------------------------
# 9. Verify and report
#--------------------------------------------------------------------------
# Each of these is wrapped on its own. By this point the design is routed
# and saved, and a report command with an option this version dislikes must
# not be what destroys the run.
foreach {label cmd} [list \
    "connectivity" {verify_connectivity -error 0 -geom_connect -no_antenna} \
    "drc"          {verify_drc -limit 100} \
    "setup"        {report_timing -late  -max_paths 10 > reports/40_final_setup.rpt} \
    "hold"         {report_timing -early -max_paths 10 > reports/41_final_hold.rpt} \
    "area"         {report_area  > reports/42_final_area.rpt} \
    "power"        {report_power > reports/43_final_power.rpt} \
    "summary"      {summaryReport -noHtml -outfile reports/44_summary.rpt} \
    "def"          {defOut -netlist -floorplan -routing ${DESIGN}_final.def} \
] {
    if {[catch {eval $cmd} msg]} {
        puts "### report '$label' failed, continuing: $msg"
    }
}

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
