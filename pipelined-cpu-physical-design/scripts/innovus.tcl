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
# CORE UTILIZATION IS THE PHYSICAL LEVER, so it is an argument rather than an
# edit. It trades area against routability and timing: pack tighter and the
# cells are closer, which shortens wires, until the router runs out of room and
# starts detouring, at which point everything gets worse at once. Finding that
# bend is what a utilization sweep is for, and it cannot be found by reasoning.
if {[info exists env(CORE_UTIL)]} {
    set UTIL $env(CORE_UTIL)
} else {
    set UTIL 0.70
}
set ASPECT 1.0
set MARGIN 10

# Per-run artifacts that a sweep does not need: three SDFs at about 6 MB each
# and a 9.6 MB GDS, plus the minutes they take to write. Off unless asked for.
# A sweep is eight or more runs, so this is the difference between a table in
# the morning and a full disk.
if {[info exists env(WRITE_ARTIFACTS)]} {
    set WRITE_ARTIFACTS $env(WRITE_ARTIFACTS)
} else {
    set WRITE_ARTIFACTS 0
}

# Margin the optimiser must carry, in ns. 0 is the old behaviour exactly.
if {[info exists env(TARGET_SLACK)]} {
    set TARGET_SLACK $env(TARGET_SLACK)
} else {
    set TARGET_SLACK 0
}

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

    # MULTI-MODE MULTI-CORNER.
    #
    # Setup is signed off on the SLOW corner and hold on the FAST one, which
    # is the whole point: a late path is worst when the silicon is slow, cold
    # supply and hot, and an early path is worst when it is fast. Checking
    # both against typical, as this flow did through run 03, asks neither
    # question and answers a third nobody cares about.
    #
    #   slow   SlowSlow  0.95 V  125 C     setup
    #   typ    TypTyp    1.10 V   25 C     neither, kept for comparison runs
    #   fast   FastFast  1.25 V    0 C     hold
    #
    # The RC corner moves with the library. Cmax, worst-case parasitics, pairs
    # with slow for setup; Cmin pairs with fast for hold. Pairing a fast
    # library with pessimistic wires would invent margin that is not there.
    #
    # TIMING_MODE=typ restores the single typical view, which is what runs 00
    # through 03 were built with and the only way to reproduce them.
    if {[info exists env(TIMING_MODE)]} {
        set TIMING_MODE $env(TIMING_MODE)
    } else {
        set TIMING_MODE mmmc
    }

    create_constraint_mode -name CON -sdc_files [list out/${DESIGN}.sdc]
    create_rc_corner -name Cmax -qx_tech_file $NG45/qrc/NG45.tch -T 125
    create_rc_corner -name Cmin -qx_tech_file $NG45/qrc/NG45.tch -T 0

    if {$TIMING_MODE eq "typ"} {
        create_library_set  -name TYP_LIB -timing [list $NG45/lib/NangateOpenCellLibrary_typical.lib]
        create_delay_corner -name TYP -library_set TYP_LIB -rc_corner Cmax
        create_analysis_view -name WC_VIEW -constraint_mode CON -delay_corner TYP
        create_analysis_view -name BC_VIEW -constraint_mode CON -delay_corner TYP
        puts "### TIMING_MODE=typ: single typical corner, runs 00-03 behaviour"
    } else {
        foreach {set_name lib} {
            SLOW_LIB NangateOpenCellLibrary_slow.lib
            FAST_LIB NangateOpenCellLibrary_fast.lib
        } {
            if {![file exists $NG45/lib/$lib]} {
                puts "### missing library: $NG45/lib/$lib"
                puts "### slow and fast come from The-OpenROAD-Project/OpenROAD"
                puts "### test/Nangate45. Re-run with TIMING_MODE=typ to skip MMMC."
                exit 1
            }
            create_library_set -name $set_name -timing [list $NG45/lib/$lib]
        }
        create_delay_corner -name WC -library_set SLOW_LIB -rc_corner Cmax
        create_delay_corner -name BC -library_set FAST_LIB -rc_corner Cmin
        create_analysis_view -name WC_VIEW -constraint_mode CON -delay_corner WC
        create_analysis_view -name BC_VIEW -constraint_mode CON -delay_corner BC
        puts "### TIMING_MODE=mmmc: setup on slow/Cmax, hold on fast/Cmin"
    }

    init_design -setup {WC_VIEW} -hold {BC_VIEW}

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
# Optimisation target slack
#
# THIS IS NOT A TIMING CONSTRAINT, and that is the whole point of it.
#
# The design lands about 26 ps short at 4.1 ns. After CTS it is POSITIVE in
# ten runs out of ten, mean +0.003; detailed routing then reveals wire delay
# the optimiser never modelled, mean +0.026 with sigma 0.016. Landing 26 ps
# short with 16 ps of scatter crosses zero about one run in six, which is the
# 1-in-6 closure rate the repeatability probe measured independently.
#
# THE OBVIOUS FIX DOES NOT WORK. Raising setup clock uncertainty so the
# pre-route optimiser carries the route cost as margin is self-cancelling
# here, because there is ONE constraint mode, CON, and it is active for the
# final analysis as well as for optimisation. Thirty picoseconds of extra
# uncertainty moves the optimiser's target down by 30 ps and the signoff
# requirement down by the same 30 ps, and the slack comes out where it
# started. It is arithmetically identical to shortening the period, and this
# project has already measured what that buys: 4.1 and 4.2 ns came back at
# mean -23 and -22 ps, so 100 ps of period was worth 1 ps of slack.
#
# setOptMode moves where the optimiser STOPS without moving the ruler it is
# judged by. Post-CTS stopping at +0.003 was never the optimiser running out
# of road: it had roughly 170 ps of headroom down to the 3.83 ns floor and
# stopped because it had met its target. Ask for more and it keeps going.
#
# SIZING. 0.030 buys the mean route cost and lands near +0.004, which still
# closes about half the time because the run-to-run sigma is 19 ps. 0.060 is
# the mean plus about two sigma, and is the difference between "it closed"
# and "it closes". It is paid for in area and runtime.
#
# Outside every run_from guard on purpose: a resumed run optimises too, and a
# margin that only applied to a full run would silently vanish from -from place.
#--------------------------------------------------------------------------
# THE OPTION NAME, established by probe on 2026-08-12 against Innovus
# 23.12-s091_1. `setOptMode -help` on this build lists only the Common UI
# spellings, and the one that exists is
#
#     [-opt_setup_target_slack <SLACK>]
#
# There is NO post-route variant of it. `-postRouteSetupTargetSlack` came back
# IMPTCM-48, "not a legal option", and the nearest thing in the usage list is
# `-opt_post_route_setup_recovery <ENUM>`, which is area recovery and a
# different knob. One target slack governs optimisation including route_opt, so
# one is what gets set. The legacy camelCase `-setupTargetSlack` is kept as a
# second candidate because it parsed on this build, but the documented name is
# tried first and wins.
#
# AN OPTION INNOVUS DOES NOT KNOW CAN WARN AND RETURN SUCCESS. That is exactly
# how `timeDesign -postRoute -si` got recorded as a step that ran: it printed
# IMPOPT-7017, did nothing, and exited zero. So the option is set and then READ
# BACK, and the run refuses to start rather than build with no margin under a
# name that claims it has one.
if {$TARGET_SLACK != 0} {
    set TS_OK ""
    foreach opt {opt_setup_target_slack setupTargetSlack} {
        if {[catch {setOptMode -$opt $TARGET_SLACK} msg]} {
            puts "### setOptMode -$opt REFUSED: $msg"
            continue
        }
        if {[catch {getOptMode -$opt} got]} { set got "(unreadable)" }
        puts "### setOptMode -$opt -> $got"
        set TS_OK $opt
        break
    }
    if {$TS_OK eq ""} {
        puts "### ####################################################"
        puts "### TARGET_SLACK=$TARGET_SLACK requested and NO setOptMode option took it."
        puts "### Refusing to build: the run would be named for a margin it does not have."
        puts "### ####################################################"
        exit 1
    }
    puts "### optimisation target slack $TARGET_SLACK ns via -$TS_OK"
} else {
    puts "### optimisation target slack 0 (stop at zero, the old behaviour)"
}

#--------------------------------------------------------------------------
# HOLD MARGIN. Policy, not an experiment, which is why it is not a run
# parameter the way setup target slack is.
#
# Added 2026-08-12, when reset_sync made the removal checks real and 119 of
# them failed at the fast corner. The worst was
#
#   u_reset_sync/stage2_reg/Q -> INV_X8 -> datapath/IFID_pc_reg[19]/RN
#   removal 0.134   arrival 0.092   slack -0.061
#
# THE RESET PATH IS TOO FAST, which is the opposite of every timing problem
# this project has had so far. Release propagates to 1347 flops through a
# single inverter in 92 ps, and removal wants it held valid for 134 ps after
# the edge. The fix is delay, and the optimiser inserts it if asked.
#
# Those 119 violations were there this morning as well. They were not being
# checked, because the SDC false path made every reset pin an unconstrained
# endpoint. Timing them is what surfaced this.
#
# 0.08 covers the 61 ps miss with room. A hold margin of a few tens of
# picoseconds is ordinary practice regardless: hold has no frequency knob to
# trade against, an OCV or SI surprise on a min-delay path is uncorrectable
# after tapeout, and buffers are cheap.
#--------------------------------------------------------------------------
#--------------------------------------------------------------------------
# ON-CHIP VARIATION DERATES
#
# setAnalysisMode -analysisType onChipVariation has been on since MMMC
# landed, and until now it had NOTHING TO APPLY. OCV is the mode; the derate
# is the margin. Enabling one without the other is a analysis that looks
# pessimistic in the log and is not.
#
# What it models: two gates on the same die, at the same corner, do not have
# the same delay. Process gradients, local voltage droop and temperature
# differences make one slower than its neighbour, and a launch path and a
# capture path can sit at opposite ends of that spread. A flat derate says
# "assume the late path is N% slower and the early path N% faster than the
# library says". Production flows use AOCV or POCV tables, which vary the
# derate by path depth and cell type; a flat number is the honest academic
# stand-in and is what the library supports.
#
# TWO SEPARATE QUESTIONS, and running them together answers neither. Applied
# with --from report on a netlist that already exists, this measures WHAT OCV
# COSTS. Applied to a full run, it measures what building for it wins back.
# That is the same split the flow already makes between --timing and
# --syn-corner, for the same reason.
#
# 0 is off and is every run before 2026-08-12. 0.05 is a reasonable flat
# figure for a 45 nm academic library. EXPECT THE FREQUENCY TO DROP: that is
# the point, and a number quoted without a derate is quietly optimistic.
#--------------------------------------------------------------------------
if {[info exists env(TIMING_DERATE)]} {
    set TIMING_DERATE $env(TIMING_DERATE)
} else {
    set TIMING_DERATE 0
}

if {$TIMING_DERATE != 0} {
    set EARLY [expr {1.0 - $TIMING_DERATE}]
    set LATE  [expr {1.0 + $TIMING_DERATE}]
    if {[catch {set_timing_derate -early $EARLY -late $LATE} msg]} {
        puts "### ####################################################"
        puts "### set_timing_derate REFUSED: $msg"
        puts "### TIMING_DERATE=$TIMING_DERATE was asked for and NOT applied."
        puts "### Refusing to build: the run would be named for margin it lacks."
        puts "### ####################################################"
        exit 1
    }
    puts "### OCV derate applied: early $EARLY, late $LATE (+/- $TIMING_DERATE)"
} else {
    puts "### OCV derate 0 (analysis mode is onChipVariation but carries no margin)"
}

set HOLD_TARGET_SLACK 0.08
if {[catch {setOptMode -opt_hold_target_slack $HOLD_TARGET_SLACK} msg]} {
    puts "### ####################################################"
    puts "### setOptMode -opt_hold_target_slack REFUSED: $msg"
    puts "### Hold margin is NOT applied. Removal on the reset net is the"
    puts "### check that needs it; do not read a clean hold column as clean."
    puts "### ####################################################"
} else {
    if {[catch {getOptMode -opt_hold_target_slack} got]} { set got "(unreadable)" }
    puts "### hold target slack -> $got"
}

#--------------------------------------------------------------------------
# 2. Floorplan
#
# Utilization based rather than fixed size: the tool computes a core big
# enough to hold the cells at $UTIL density, square, with a $MARGIN ring
# for the power ring and pins.
#--------------------------------------------------------------------------
if {[run_from floorplan]} {
    puts "### floorplanning at utilization $UTIL"
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
    # -spacing 1.5, not 1. Both layers carry a PARALLELRUNLENGTH spacing table
    # in NangateOpenCellLibrary.tech.lef, and a wide wire running a long way
    # beside another one needs more room than the default 0.4/0.8:
    #
    #   metal8  WIDTH >= 1.5, run >= 4.0  ->  1.5
    #   metal9  WIDTH >= 1.5, run >= 4.0  ->  1.5
    #
    # These rings are 2 um wide and run about 137 um, so both land in the
    # last row and last column of their table. At -spacing 1 that produced
    # four MetSpc violations, one per side, each with a violation box exactly
    # 1.000 um wide, which is the gap itself. They were the only DRC errors in
    # the design and they were never in the signal routing.
    addRing -nets {VDD VSS} -type core_rings -follow core \
            -layer {top metal9 bottom metal9 left metal8 right metal8} \
            -width 2 -spacing 1.5 -offset 1

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
    # NAME THE CLOCK CELLS. CCOpt auto-detects them from the libraries, and
    # under MMMC that auto-detection failed outright:
    #
    #   IMPCCOPT-1183  no usable balanced buffers   for power domain auto-default
    #   IMPCCOPT-1184  no usable balanced inverters for power domain auto-default
    #   IMPCCOPT-1135  CTS found neither inverters nor buffers. CTS cannot continue.
    #
    # The cells were never missing. CLKBUF_X1/X2/X3 and the six INV_X* are in
    # all three corner libraries, verified cell by cell. What changed is that
    # two library sets are active instead of one, and the auto-selection stops
    # finding a set it considers usable across both.
    #
    # Naming them is what a production flow does anyway. Auto-detection quietly
    # choosing the wrong drive strengths is a well known way to get a bad clock
    # tree, and this failed loudly only because it found nothing at all.
    set_ccopt_property buffer_cells   {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3}
    set_ccopt_property inverter_cells {INV_X1 INV_X2 INV_X4 INV_X8 INV_X16 INV_X32}

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
#
# saveNetlist is what makes GATE-LEVEL SIMULATION possible. Genus already
# wrote a netlist, but that one is pre-layout: it has no clock tree in it and
# none of the post-route optimisation. This is the netlist that corresponds to
# the layout, and running the program on it is the only way to watch the thing
# that was actually built execute.
#
# -excludeLeafCell leaves out empty module definitions for the standard cells.
# The simulator gets its cell behaviour from the Nangate Verilog models
# instead, and a stub definition here would collide with the real one.
# Physical-only cells are already absent: a filler has no function to simulate.
# NO COMMENTS INSIDE THE LIST BELOW. `[list ...]` is a command, not syntax: a
# `#` line inside it becomes a list ELEMENT, which silently shifts every
# label/command pair after it by one. Tcl will not complain. Notes go here.
#
# power: -outfile, NOT a shell redirect. report_power writes through its own
# file argument and prints nothing useful to stdout, so `> file` produced a
# ZERO BYTE report on every run this flow has ever done. It existed, was
# archived, was committed, and was empty -- the same shape as every other
# silent-success bug here, and the reason this project has area and
# performance numbers and no power number. Without switching activity the
# dynamic figure is an estimate at default toggle rates and the leakage figure
# is real; say which is which when quoting it.
#
# antenna: verify_connectivity runs with -no_antenna, so nothing in this flow
# has ever checked antenna rules. A long metal segment connected to a gate
# collects charge during plasma etch and can destroy the oxide before the
# protection diode is connected. Every real tapeout checks it; it is one
# command.
foreach {label cmd} [list \
    "connectivity" {verify_connectivity -error 0 -geom_connect -no_antenna} \
    "drc"          {verify_drc -limit 100} \
    "setup"        {report_timing -late  -max_paths 50 -nworst 1 > reports/40_final_setup.rpt} \
    "hold"         {report_timing -early -max_paths 50 -nworst 1 > reports/41_final_hold.rpt} \
    "area"         {report_area  > reports/42_final_area.rpt} \
    "power"        {report_power -outfile reports/43_final_power.rpt} \
    "antenna"      {verifyProcessAntenna -reportfile reports/54_antenna.rpt} \
    "summary"      {summaryReport -noHtml -outfile reports/44_summary.rpt} \
] {
    if {[catch {eval $cmd} msg]} {
        puts "### report '$label' failed, continuing: $msg"
    }
}

# The heavy outputs: a 7.8 MB DEF and a 1 MB post-route netlist per run.
#
# Neither is read by a timing sweep. Every number a sweep produces comes out of
# reports/, which is a few kilobytes of text and is what gets committed. These
# are for looking at the layout and for gate-level simulation, so they are
# opt-in with --artifacts.
if {$WRITE_ARTIFACTS} {
    foreach {label cmd} [list \
        "def"     {defOut -netlist -floorplan -routing ${DESIGN}_final.def} \
        "netlist" {saveNetlist out/${DESIGN}_routed.v -excludeLeafCell} \
    ] {
        if {[catch {eval $cmd} msg]} {
            puts "### artifact '$label' failed, continuing: $msg"
        }
    }
}

# GDSII, only if the Nangate45 stream file has been fetched. run.sh can
# download it; without it the DEF above is still a complete layout.
set GDS_IN $env(HOME)/nangate45_gds/NangateOpenCellLibrary.gds
if {$WRITE_ARTIFACTS && [file exists $GDS_IN]} {
    streamOut ${DESIGN}.gds \
        -libName ${DESIGN} -merge [list $GDS_IN] -units 1000 -mode ALL
    puts "### GDSII written: ${DESIGN}.gds"
} else {
    puts "### GDSII skipped. WRITE_ARTIFACTS=$WRITE_ARTIFACTS"
}

#--------------------------------------------------------------------------
# 10. Per-corner timing reports
#
# EVERY RUN REPORTS ALL THREE CORNERS, so a typical number and a slow number
# come out of the same run and can never be quoted apart again. Implementation
# above is untouched: the optimiser still targeted WC_VIEW for setup and
# BC_VIEW for hold, and everything below happens after the design is final and
# saved. Adding a view here cannot change what was built.
#
# THE VIEWS BELOW ARE NEW NAMES ON PURPOSE. Reusing WC_VIEW would be silently
# wrong on a restored run 00 through 03, where that name exists and is bound to
# the TYPICAL library: the report would carry a slow label over typical numbers,
# which is the worst outcome available. RPT_* are created here, bound here, and
# mean the same thing in every run.
#
# This also works on a database restored with --from report, which is what lets
# runs 00 through 06 be re-reported at three corners without re-routing any of
# them. On the early runs that is exactly the experiment run 04 was: the corner
# penalty measured against a netlist that was built without it.
#--------------------------------------------------------------------------
# TWO THINGS HERE WERE LEARNED THE EXPENSIVE WAY, on the first real run.
#
# 1. NO create_rc_corner. Cmax and Cmin already exist, and re-creating an RC
#    corner that is already there DELETES THE PARASITIC DATA for every corner:
#
#      IMPEXT-3508: The corner setup has changed in the MMMC flow ... the
#      parasitic data in the tool from the previous setup is deleted.
#
#    An extracted, routed design silently became an unextracted one. The typ
#    view therefore reuses Cmax rather than getting an RC corner of its own,
#    which is also what runs 00 through 03 did: their delay corner was the
#    typical library on Cmax. So the typ column is directly comparable to the
#    historical typical numbers, which is the entire reason it exists.
#
# 2. THE TYPICAL LIBRARY HAS TO COME FROM THE SAME PLACE AS SLOW AND FAST.
#    Mixing them gives four of these:
#
#      TECHLIB-1371: The 'output' pin 'Y' defined for cell 'LOGIC0_X1' in
#      library 'NangateOpenCellLibrary' is either not defined or defined with
#      different direction in the cell 'LOGIC0_X1' in library
#      'NangateOpenCellLibrary_slow'.
#
#    The two tie cells, LOGIC0_X1 and LOGIC1_X1, have output pin Y in the
#    MacroPlacement typical library and output pin Z in the OpenROAD slow and
#    fast ones. Same library, two vintages, 501 bytes apart, and the design
#    does not even instantiate them because globalNetConnect ties to the rails
#    directly. Innovus validates the library sets against each other regardless
#    of what the design uses.
#
#    NangateOpenCellLibrary_typical_openroad.lib is OpenROAD's Nangate45_typ.lib,
#    which matches the slow and fast files already in use. The MacroPlacement
#    typical is left alone: it is what TIMING_MODE=typ and the LEC dofile read,
#    and overwriting it would stop runs 00 through 03 reproducing.
set CORNER_STATUS {}
set SETUP_VIEWS {}
set CORNER_VIEWS {}
set DROPPED 0

# NOT wrapped silently. The rule from the DRC work holds: wrap an optional step
# so it cannot destroy a route, but never let a MEASUREMENT fail quietly. The
# status lands in an archived file as well as on the terminal, so a run whose
# corner reports did not happen says so in its own evidence rather than just
# in a log nobody opens.
#
# ONE STEP PER CATCH, and errorInfo as well as the message. An early version
# recorded "FAILED activating views: 0", which named neither the command nor
# the reason and cost a log dig to resolve. A diagnostic that does not say
# which of several commands failed is barely better than no diagnostic.
#
# DEFINED BEFORE THE LOOP THAT USES IT. It was first written just above its
# other caller, further down, which left the loop below calling a proc that did
# not exist yet. Tcl reports that as `expected boolean value but got ""`, from
# the `if` around the call rather than from the call itself, which points at
# the wrong line entirely.
proc corner_step {label script} {
    global CORNER_STATUS
    if {[catch {uplevel 1 $script} msg]} {
        set detail [lindex [split $::errorInfo "\n"] 0]
        # Innovus often raises with NOTHING in the Tcl error and prints the
        # real reason to the log instead. Seen twice: msg='0' from an
        # activation failure, and msg='' from create_delay_corner while the
        # log carried "TCLCMD-994 ... 'Cmin'". An empty message is itself
        # information, so say where the reason actually went.
        if {[string trim $msg] eq ""} {
            set msg "(empty)"
            set detail "Innovus wrote the reason to the log, not to Tcl. Grep the newest innovus.log* for ERROR near this command."
        }
        lappend CORNER_STATUS "$label FAILED msg='$msg' detail='$detail'"
        puts "### corner step '$label' FAILED: $msg | $detail"
        return 0
    }
    lappend CORNER_STATUS "$label OK"
    return 1
}

foreach {tag lib rc} [list \
    slow NangateOpenCellLibrary_slow.lib             Cmax \
    typ  NangateOpenCellLibrary_typical_openroad.lib Cmax \
    fast NangateOpenCellLibrary_fast.lib             Cmin \
] {
    if {![file exists $NG45/lib/$lib]} {
        lappend CORNER_STATUS "$tag SKIPPED no $lib"
        continue
    }
    set view RPT_[string toupper $tag]

    # NO BARE catch HERE. These were swallowed once and it cost a debugging
    # round: on runs 00 through 03 the fast corner could not be built at all,
    # every create failed quietly, and the only symptom was
    # `activate FAILED msg='{}'` several steps later, an empty message from a
    # command handed a view name that had never existed.
    #
    # A restored database never already contains these objects. 05_routed is
    # saved long before this section runs, so a create that fails here is
    # always a real failure and always worth recording.
    set ok 1
    foreach {label cmd} [list \
        libset "create_library_set  -name LS_$tag -timing [list $NG45/lib/$lib]" \
        corner "create_delay_corner -name DC_$tag -library_set LS_$tag -rc_corner $rc" \
        view   "create_analysis_view -name $view -constraint_mode CON -delay_corner DC_$tag" \
    ] {
        if {![corner_step ${tag}_$label $cmd]} { set ok 0 ; break }
    }

    if {$ok} {
        lappend SETUP_VIEWS $view
        lappend CORNER_VIEWS $tag $view
    } else {
        lappend CORNER_STATUS "$tag DROPPED, $view was not built"
        incr DROPPED
    }
}

# A DROPPED VIEW AND A SKIPPED ONE ARE NOT THE SAME SITUATION.
#
# Skipped means a library FILE is not installed, and two corners out of three
# is then the honest best available: that is the stock-enablement case.
#
# Dropped means the library was there and the DATABASE would not take it. That
# is runs 00 through 03, built before MMMC existed: their saved sessions have
# no Cmin rc corner, so the fast view cannot be built at all
#
#   TCLCMD-994: Can not find 'rc corner' object with the name 'Cmin'.
#
# and they carry the MacroPlacement typical library, whose tie cells use pin Y
# where the OpenROAD slow and fast use Z, which throws TECHLIB-1371 four times
# without stopping anything. Reporting the two corners that did build would put
# numbers in the table that rest on a library conflict, and a partial row that
# does not announce itself is worse than an absent one.
#
# Neither is fixable from a restored session and neither needs to be. RUN 04 IS
# THIS EXPERIMENT DONE PROPERLY: it re-judged the run-03 netlist at real corners
# from synthesis, which is the measurement a back-fill of run 03 would approximate.
if {$DROPPED > 0} {
    lappend CORNER_STATUS "NOT RUN: $DROPPED view(s) could not be built on this database"
    lappend CORNER_STATUS "HINT: a session saved before MMMC has no Cmin and an incompatible typical library. It cannot be re-judged. See run 04."
    puts "### ####################################################"
    puts "### THIS DATABASE PREDATES MMMC AND CANNOT BE RE-JUDGED."
    puts "### Its own corner is still reported in 40_final_setup.rpt."
    puts "### ####################################################"
} elseif {[llength $SETUP_VIEWS] < 2} {
    lappend CORNER_STATUS "NOT RUN: fewer than two corner libraries installed"
} elseif {[corner_step activate {
    # Every corner active for both checks. A view can be active for setup and
    # hold at once, and reporting is the only thing left to do, so there is no
    # reason to be selective here the way init_design had to be.
    set_analysis_view -setup $SETUP_VIEWS -hold $SETUP_VIEWS
}]} {
    # extractRC is allowed to fail without taking the reports down with it.
    # Now that no RC corner is recreated, the parasitics for Cmax and Cmin
    # should survive activation, so the timing is very likely readable whether
    # or not this succeeds. Killing the reports over it, which is what the
    # first version did, threw away the whole point of the run.
    # SI-aware delay calculation, set before extraction so that everything this
    # section produces comes from one analysis mode.
    #
    # IT DOES NOT REPRODUCE THE SIGNOFF NUMBERS, and the note is here so nobody
    # re-runs the experiment. route_opt_design's own summary is headed
    # "optDesign Final SI Timing Summary" and reports 45 violating paths with
    # -1.344 ns of TNS on run 06. Re-analysing the identical restored database
    # gives 28 and -0.550. Three things were tried: plain timeDesign,
    # `timeDesign -si` which is obsolete in 23.1 and silently does nothing, and
    # this mode set both after and before extractRC. All three give 28.
    #
    # WNS is -0.066 in every one of them, which is the number a clock sweep
    # turns on, so the gap was not worth a fourth run. What it means is that
    # THE CENSUS IS A RE-ANALYSIS AND NOT THE SIGNOFF MEASUREMENT. The three
    # corners are measured identically and so are comparable with each other;
    # they are not comparable with the main QOR table's TNS and violation
    # count, which come from the optimiser's own final analysis.
    corner_step si_mode {setDelayCalMode -engine default -siAware true}
    corner_step extract {extractRC}

    foreach {tag view} $CORNER_VIEWS {
        # -max_paths 50 caps the path DETAIL here exactly as it does in
        # 40_final_setup.rpt. The true violation counts come from the
        # timeDesign summaries below and from nowhere else.
        corner_step report_$tag \
            "report_timing -late  -view $view -max_paths 50 -nworst 1 > reports/40_setup_${tag}.rpt
             report_timing -early -view $view -max_paths 50 -nworst 1 > reports/41_hold_${tag}.rpt"

        # One SDF per corner, for timing-annotated gate-level simulation.
        #
        # The SDF carries this corner's delay for every cell instance and every
        # net. Simulating with it is the only check in the flow that runs the
        # PROGRAM against the layout's real timing; STA proves every path
        # exhaustively but executes nothing, and a zero-delay gate run executes
        # the program but believes every gate is instant.
        #
        # A file per corner, because a delay is meaningless without one.
        #
        # OFF BY DEFAULT. Three files at about 6 MB each, and the minutes to
        # write them, on every run. A sweep is eight or more runs and does not
        # want any of it: fmax and the utilization curve come from the reports.
        if {$WRITE_ARTIFACTS} {
            corner_step sdf_$tag \
                "write_sdf -view $view out/${DESIGN}_${tag}.sdf"
        }
    }

    # -expandedViews adds a block per active view to the summary, under the
    # merged worst-of-all table at the top: WNS, TNS, violating paths and total
    # paths, per corner. WNS alone cannot tell one failing endpoint from four
    # hundred, and per corner it cannot tell one corner's shape from another's.
    #
    # -outDir cornerReports, NOT timingReports. THIS IS LOAD BEARING.
    # timeDesign writes <design>_postRoute.summary.gz, which is the exact
    # filename route_opt_design already wrote there at the end of the route.
    # Writing into the same directory overwrote the signoff summary with this
    # one, and qor.py then archived the replacement over the committed
    # evidence: run 06's TNS went from -1.344 to -0.550 and its violation
    # count from 45 to 28 without a word. A separate directory makes the
    # collision impossible rather than merely unlikely.
    #
    # `timeDesign -postRoute -si` looks like the way to ask for a crosstalk
    # aware analysis. Innovus 23.1 answers:
    #
    #   IMPOPT-7017: The command 'timeDesign -postRoute -si [-hold |
    #   -reportOnly]' is obsolete ... ensure that 'setDelayCalMode -engine
    #   default -siAware true' is set & use 'timeDesign -postRoute'.
    #
    # It WARNED, DID NOTHING, AND RETURNED SUCCESS. No analysis ran, no summary
    # was written, and corner_step recorded OK because the command had not
    # errored. Hence the artifact check below: a step is done when its evidence
    # exists on disk, not when its return code is zero.
    #----------------------------------------------------------------------
    # TIMING COVERAGE: is every endpoint actually being checked?
    #
    # THE VACUOUS PASS IS THE FAILURE MODE THIS EXISTS TO CATCH, and this
    # project has now been bitten by it three times. `timeDesign -postRoute
    # -si` warned, did nothing and returned success. The gate simulation ran
    # with 0 of 12,285 $setuphold checks annotated, so "no violations" and
    # "no checks alive" printed identically. And a run named for a margin no
    # setOptMode option had accepted would have built without it.
    #
    # STA HAS EXACTLY THE SAME HOLE. An unconstrained endpoint raises no
    # violation, so a clean WNS can be clean because paths are not being
    # checked rather than because they pass. check_timing names them:
    # unclocked registers, missing input or output delay, combinational
    # loops, endpoints carrying no check at all.
    #
    # READ THIS BEFORE TRUSTING ANY FREQUENCY, and before adding derates.
    # Refining the margin on an incomplete path set measures the wrong thing
    # more precisely, which is worse than not measuring it.
    #
    # Two spellings tried, because an option or command Innovus does not know
    # can warn and return success. report_analysis_coverage is a Tempus
    # command and may not exist here; its absence is recorded, not fatal.
    #----------------------------------------------------------------------
    set COV_OK 0
    foreach cmd {check_timing checkTimingSetup} {
        if {[corner_step coverage_$cmd "$cmd -verbose > reports/47_check_timing.rpt"]} {
            set COV_OK 1
            break
        }
    }
    if {!$COV_OK} {
        # No -verbose, in case that is what it choked on.
        foreach cmd {check_timing checkTimingSetup} {
            if {[corner_step coverage_plain_$cmd "$cmd > reports/47_check_timing.rpt"]} {
                set COV_OK 1
                break
            }
        }
    }

    # A step is done when its evidence exists on disk, not when its return
    # code is zero. An empty report is the thing that would read as "clean".
    if {$COV_OK} {
        if {[file exists reports/47_check_timing.rpt] && [file size reports/47_check_timing.rpt] > 0} {
            puts "### timing coverage written: reports/47_check_timing.rpt ([file size reports/47_check_timing.rpt] bytes)"
        } else {
            lappend CORNER_STATUS "coverage WROTE NOTHING to reports/47_check_timing.rpt"
            puts "### ####################################################"
            puts "### check_timing returned success and wrote nothing."
            puts "### Treat the timing coverage of this run as UNKNOWN."
            puts "### ####################################################"
        }
    } else {
        lappend CORNER_STATUS "coverage NOT RUN: no check_timing spelling accepted"
    }

    corner_step analysis_coverage {report_analysis_coverage > reports/48_analysis_coverage.rpt}

    # THE TABLE ABOVE IS LATE MODE ONLY. Its rows are ExternalDelay (Late),
    # PulseWidth, Recovery and Setup, and there is no Hold row at all, so a
    # design could have every hold check untested and this report would look
    # complete. Hold is the failure that kills silicon outright rather than
    # merely slowing it down, so it deserves the same question asked of it.
    #
    # Appended to the same file, because one report is what actually gets
    # read, and report_analysis_coverage prints its own command header so the
    # two tables stay distinguishable.
    set HOLD_COV 0
    set n 0
    foreach opt {"-check_type hold" "-early"} {
        incr n
        if {[corner_step analysis_coverage_hold$n \
                "report_analysis_coverage $opt >> reports/48_analysis_coverage.rpt"]} {
            set HOLD_COV 1
            break
        }
    }
    if {!$HOLD_COV} {
        lappend CORNER_STATUS "analysis_coverage_hold NOT RUN: no option accepted, 48 is LATE MODE ONLY"
        puts "### hold coverage not reported; treat 48_analysis_coverage.rpt as late mode only"
    }

    corner_step census_setup {timeDesign -postRoute       -expandedViews -outDir cornerReports}
    corner_step census_hold  {timeDesign -postRoute -hold -expandedViews -outDir cornerReports}

    # DID IT ACTUALLY WRITE ANYTHING. The whole per-corner census is these two
    # files; without them the table shows a dash and nobody can tell a corner
    # that was clean from a corner that was never measured.
    set wrote [glob -nocomplain cornerReports/*.summary.gz]
    if {[llength $wrote] == 0} {
        lappend CORNER_STATUS "census WROTE NOTHING to cornerReports/"
        puts "### ####################################################"
        puts "### THE CORNER CENSUS PRODUCED NO SUMMARY FILE."
        puts "### Per-corner WNS is still in reports/40_setup_*.rpt;"
        puts "### TNS and the violation counts are missing."
        puts "### ####################################################"
    } else {
        lappend CORNER_STATUS "census wrote [llength $wrote] file(s): [lsort $wrote]"
    }
} else {
    puts "### ####################################################"
    puts "### PER-CORNER REPORTING DID NOT RUN."
    puts "### The signoff reports 40/41/50 above are unaffected."
    puts "### ####################################################"
}

set fh [open reports/49_corner_status.rpt w]
puts $fh "Per-corner reporting status"
puts $fh "views requested: $SETUP_VIEWS"
foreach line $CORNER_STATUS { puts $fh $line }
close $fh
puts "### corner status: $CORNER_STATUS"

puts "=========================================================="
puts " PLACE AND ROUTE DONE"
puts "   database : enc/06_final.enc"
puts "   layout   : ${DESIGN}_final.def"
puts "   reports  : reports/"
puts "=========================================================="
puts " Read reports/40_final_setup.rpt first. The slack on the"
puts " worst path is your post-route timing result."
puts "=========================================================="

# innovus -files RUNS the script and then drops to its interactive prompt.
# Without this, run.sh blocks forever waiting on a tool that has visibly
# finished, and collect() never appends the run's QOR row. The symptom is a
# run that prints PLACE AND ROUTE DONE, looks entirely successful, and leaves
# no row in results/QOR.md, because the shell after run_pnr never got control
# back. Runs 00 through 02 were each released by typing exit at the prompt.
exit
