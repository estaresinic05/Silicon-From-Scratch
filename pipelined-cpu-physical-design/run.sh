#!/bin/bash
#############################################################################
# pipelined-cpu-pnr: RTL to routed layout, one command per experiment.
#
#   ./run.sh                                 full flow at the default clock
#   ./run.sh --period 2.5 --note "tighten"   full flow at 2.5 ns
#   ./run.sh --period 4.0 --util 0.80        ...at 80% core utilization
#   ./run.sh --period 4.1 --effort high      ...synthesise at high effort
#   ./run.sh --period 4.0 --artifacts        ...also write DEF, netlist, SDF, GDS
#   ./run.sh --name baseline --note "..."    name the run yourself
#   ./run.sh --name baseline --from cts      resume an existing run at CTS
#   ./run.sh --name baseline --from report   re-report a routed run, no re-route
#   ./run.sh --timing typ                    single typical corner, runs 00-03
#   ./run.sh lec <run> [syn|routed|gate]     equivalence; gate = syn vs routed
#   ./run.sh sim                             run the program on the RTL core
#   ./run.sh gls <run> [corner] [+trace]     run it on the routed netlist
#   ./run.sh libs                            fetch the slow/typ/fast libraries
#   ./run.sh cells                           fetch the Verilog cell models
#   ./run.sh gds                             fetch the Nangate45 stream file
#   ./run.sh table                           rebuild results/QOR.md
#
# EVERY RUN REPORTS ALL THREE CORNERS. Implementation still targets slow for
# setup and fast for hold; the report stage adds a typical view and re-reports
# from the same routed database, so a typical number and a slow number can
# never again be quoted apart. --from report back-fills a run that is already
# routed, without re-routing it.
#
# EVERY RUN GETS ITS OWN DIRECTORY under runs/, so a second experiment can
# never destroy the first one's reports. That was the whole problem with
# building in a single work/: the comparison a sweep exists to produce was
# being overwritten by the next step of the sweep.
#
#   runs/<name>/     out/ reports/ enc/ and the DEF. Big, gitignored.
#   results/<name>/  the small text reports, copied out. Committed.
#   results/qor.csv  one row per run. Committed.
#   results/QOR.md   the table you actually read. Generated, never edited.
#############################################################################

set -e
cd "$(dirname "$0")"
ROOT=$(pwd)
export PNR_ROOT="$ROOT"

NG45=$HOME/MacroPlacement/Enablements/NanGate45
DESIGN=pipelined_cpu_core

# nanoHUB has python3; a Windows laptop generally has only "python", and the
# gate-level simulation is meant to run there. Resolve it once.
#
# Each candidate is EXECUTED, not merely located. Windows ships an App Execution
# Alias called python3.exe that exists on PATH, satisfies `command -v`, and then
# refuses to run with an advert for the Microsoft Store. Testing for presence
# picks it every time.
PY=""
for _c in python3 python py; do
    if command -v "$_c" >/dev/null 2>&1 && "$_c" -c "import sys" >/dev/null 2>&1; then
        PY="$_c"; break
    fi
done

PERIOD=3.0
UTIL=0.70
EFFORT=medium
ARTIFACTS=0
NAME=""
FROM="syn"
NOTE=""
DO_QOR=1
TIMING=mmmc
SYN_CORNER_ARG=""

# Stage order, including synthesis. Anything after 'syn' is an Innovus stage
# and is handed to innovus.tcl as START_STAGE.
STAGES="syn floorplan power place cts route report"

usage() {
    # The line range is the comment block at the top of this file. It moves
    # whenever that block grows, and nothing catches it but reading the output,
    # so `./run.sh --help` is worth an eye after editing the header.
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

#---------------------------------------------------------------------------
# Preflight. Every one of these has bitten someone.
#---------------------------------------------------------------------------
preflight() {
    local fail=0

    for t in genus innovus; do
        if ! command -v $t >/dev/null 2>&1; then
            echo "MISSING: $t is not on your PATH."
            echo "         try: ls /apps/cadencedigital/r23/bin"
            fail=1
        fi
    done

    if [ ! -d "$NG45" ]; then
        echo "MISSING: the Nangate45 enablement is not at $NG45"
        echo "         it comes from the MacroPlacement repo:"
        echo "         cd ~ && git clone --depth 1 https://github.com/TILOS-AI-Institute/MacroPlacement"
        fail=1
    else
        for f in lib/NangateOpenCellLibrary_typical.lib \
                 lef/NangateOpenCellLibrary.tech.lef \
                 lef/NangateOpenCellLibrary.macro.mod.lef \
                 qrc/NG45.tch; do
            [ -f "$NG45/$f" ] || { echo "MISSING: $NG45/$f"; fail=1; }
        done

        # A WARNING, NOT A FAILURE. The flow runs without these; it just runs
        # with fewer corners, which is a real thing to want on a machine that
        # has only the stock enablement. It is called out because the failure
        # mode is otherwise silent: the corner table simply comes back empty
        # for that corner and an empty column reads like a clean one.
        for f in lib/NangateOpenCellLibrary_slow.lib \
                 lib/NangateOpenCellLibrary_fast.lib \
                 lib/NangateOpenCellLibrary_typical_openroad.lib; do
            [ -f "$NG45/$f" ] || {
                echo "NOTE: $NG45/$f is absent."
                echo "      That corner will be skipped. Run './run.sh libs' to fetch it."
            }
        done
    fi

    [ $fail -eq 0 ] || { echo; echo "Preflight failed. Nothing was run."; exit 1; }
    echo "Preflight OK."
}

# Is stage $1 at or after the requested start?
stage_index() {
    local i=0
    for s in $STAGES; do
        [ "$s" = "$1" ] && { echo $i; return; }
        i=$((i + 1))
    done
    echo -1
}

#---------------------------------------------------------------------------
run_syn() {
    echo "=== SYNTHESIS (Genus) at ${PERIOD} ns ==========================="
    genus -files "$ROOT/scripts/genus.tcl" -log genus
    echo "=== synthesis done =============================================="
}

run_pnr() {
    echo "=== PLACE AND ROUTE (Innovus), from '${1}' ======================"
    if [ ! -f out/pipelined_cpu_core_netlist.v ]; then
        echo "No netlist in $(pwd)/out. Run synthesis for this run first."
        exit 1
    fi
    START_STAGE="$1" innovus -files "$ROOT/scripts/innovus.tcl" -log innovus
    echo "=== place and route done ========================================"
}

collect() {
    [ -n "$PY" ] || { echo "no python found, skipping QOR"; return; }
    "$PY" "$ROOT/scripts/qor.py" collect "$ROOT/runs/$NAME" --note "$NOTE" --root "$ROOT"
}

# Formal equivalence: does the gate netlist still compute what the RTL says?
#
# Synthesis is a program that rewrites your design, and timing reports say
# nothing about whether it rewrote it correctly. Every real flow runs this
# after synthesis and again after any ECO. It is the cheapest check in the
# whole flow and it was the largest thing missing from this one.
#
# The dofile is written into the run directory rather than kept as a template,
# because it carries absolute paths and a stale one that silently compares the
# wrong netlist is worse than no check at all.
run_lec() {
    local name="$1"
    local which="${2:-syn}"
    local rundir="$ROOT/runs/$name"
    local netlist="$rundir/out/pipelined_cpu_core_netlist.v"

    # WHICH NETLIST IS BEING PROVEN EQUIVALENT.
    #
    # 'syn' is the Genus netlist, which is what this check has always compared
    # and which says nothing about place and route. route_opt_design rewrites
    # the netlist after synthesis: it resizes cells, clones drivers, and pushes
    # inversions across boundaries. A real flow re-runs equivalence after every
    # optimisation step for exactly that reason, and this one never has.
    #
    # 'routed' compares the netlist that corresponds to the layout. Reach for
    # it when the gate-level simulation disagrees with the RTL, because it
    # separates "post-route optimisation changed the logic" from "the
    # simulation harness is wrong", and nothing else does.
    if [ "$which" = "routed" ]; then
        netlist="$rundir/out/pipelined_cpu_core_routed.v"
        [ -f "$netlist" ] || {
            echo "No routed netlist at $netlist"
            echo "         run '--from report' first."
            exit 1
        }
        echo "### comparing the ROUTED netlist, not the synthesised one"
    fi

    [ -f "$netlist" ] || { echo "No netlist at $netlist"; exit 1; }
    command -v lec >/dev/null 2>&1 || {
        echo "MISSING: lec is not on your PATH."
        echo "         try: export PATH=/apps/cadencedigital/r23/bin:\$PATH"
        exit 1
    }

    # Expand the RTL list HERE. A heredoc does not glob, so writing rtl/*.v
    # into the dofile would leave a literal wildcard and depend on Conformal
    # expanding it, which is not a promise worth resting the check on.
    local rtl_files
    rtl_files=$(ls "$ROOT"/rtl/*.v | tr '
' ' ')

    cat > "$rundir/lec.do" <<EOF
// Conformal LEC: RTL (golden) against the synthesised netlist (revised).
set log file lec.log -replace

// A cell with no functional model would silently compare as equivalent,
// which is the one outcome that must never happen quietly.
set undefined cell black_box

// MODEL WHAT SYNTHESIS ACTUALLY DID TO THE SEQUENTIAL LOGIC.
//
// Genus proves flops constant and deletes them, which is correct and is not
// something LEC knows by default. Without these the deleted flops stay in
// golden as UNMAPPED key points, and an unmapped key point is treated as a
// free variable: golden is then allowed to do things the real design cannot,
// and every compared point downstream of it fails.
//
// That is exactly what the first run produced. Five deleted flops caused 35
// non-equivalent points:
//
//   IDEX_operation_reg[3]  IFID_operation is 4 bits and the control unit only
//                          emits 0000/0001/0010/0110/0111, so bit 3 is never
//                          set. Freeing it let the ALU perform an operation
//                          the CPU cannot issue, and all 32 bits of
//                          EXMEM_aluResult_reg mismatched.
//   IF_pc_reg[0]           the PC steps by 4, so bit 0 is constant zero.
//   IFID_pc_reg[0]         same, one stage on. imem_addr[0] and dbg_pc[0]
//                          failed because of these two.
//   *_memToReg_reg         folded into the control it feeds.
//
// -seq_constant_x_to 0 is needed on top, for register x0. reg_file.v zeroes RF
// in an INITIAL block, which simulation honours and synthesis ignores, so
// RF[0] has no reset and Conformal models it as a latch holding X rather than
// a constant. It is dead either way, gated on write and muxed on read.
//
// These relax the check, so the unmapped count is reported below and is the
// number to read. Zero non-equivalent with points still unmapped is not a pass.
set flatten model -seq_constant
set flatten model -seq_constant_x_to 0

// NOT -seq_merge. It was added here speculatively, on no symptom, and merging
// equivalent flops is exactly the transform that mangles a shift register's
// key points. memToReg is a plain four-deep shift chain, IFID to IDEX to
// EXMEM to MEMWB, and it was the one sequential point still failing while it
// was on. Add an option because a report asks for it, not in case it helps.

read library -liberty $NG45/lib/NangateOpenCellLibrary_typical.lib -revised

read design $rtl_files -verilog -golden -sensitive -continuousassignment bidirectional
read design $netlist -verilog -revised -sensitive -continuousassignment bidirectional

set system mode lec

// SYNTHESIS MERGED TWO CONTROL SIGNALS THAT ARE ALWAYS EQUAL, and no
// mapping command can express that.
//
// pipelined_cpu_control.v drives IFID_memRead and IFID_memToReg identically in
// every branch, and the datapath pipelines both with identical flush, stall
// and reset behaviour, so they are one signal carried twice. Genus keeps a
// single chain: the netlist has IDEX_memRead_reg and EXMEM_memRead_reg and no
// memToReg at those stages.
//
// add mapped points was tried here and rejected with "This is already a mapped
// point". Conformal maps ONE TO ONE, golden's memRead flops had already
// claimed the revised ones, and golden simply holds more state than revised
// does. That is not a mapping problem to be worked around, it is the RTL
// declaring two registers where the hardware has one.
//
// Leaves MEMWB_memToReg_reg non-equivalent and its two feeders unmapped. The
// fix belongs in the RTL, not here.

add compared points -all
compare

// Three reports, and the second one is the one people forget. A clean
// non-equivalent count means nothing if most points were never mapped.
report compare data      > $rundir/reports/60_lec_compare.rpt
report unmapped points   > $rundir/reports/61_lec_unmapped.rpt
report verification      > $rundir/reports/62_lec_verification.rpt

exit -force
EOF

    echo "=== FORMAL EQUIVALENCE (Conformal LEC) ========================="
    mkdir -p "$rundir/reports"
    (cd "$rundir" && lec -nogui -dofile lec.do)
    echo
    echo "--- verification result ---"
    cat "$rundir/reports/62_lec_verification.rpt" 2>/dev/null || echo "(no report written)"
    echo
    echo "--- unmapped key points (must be 0, or understood) ---"
    grep -iE "Not-mapped|unmapped" "$rundir/reports/61_lec_unmapped.rpt" 2>/dev/null | head -5
    echo
    echo "PASS = Compare Results: Equivalent, AND no unmapped key points."
    echo "Reports: runs/$name/reports/6*_lec_*.rpt"
}

# The three corner libraries, which the enablement does not ship.
#
# MacroPlacement gives you NangateOpenCellLibrary_typical.lib and nothing else.
# slow and fast come from OpenROAD's test/Nangate45, and so must the typical
# used for corner REPORTING: the MacroPlacement one is a different vintage of
# the same library whose tie cells LOGIC0_X1 and LOGIC1_X1 carry output pin Y
# where OpenROAD's carry Z. Mixing them throws TECHLIB-1371 four times and the
# corner views cannot be built. The two files are 501 bytes apart and that is
# the whole of the difference that matters.
#
# The MacroPlacement typical is deliberately left in place and untouched. It is
# what --timing typ and the LEC dofile read, and it is what runs 00 through 03
# were built with, so overwriting it would stop them reproducing.
#
# Downloads only what is missing, because a library that a run was built
# against must never be silently replaced underneath its reports.
get_libs() {
    echo "=== fetching the Nangate45 corner libraries ======================"
    local base=https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD/master/test/Nangate45
    mkdir -p "$NG45/lib"
    local src dst
    for pair in "Nangate45_slow.lib:NangateOpenCellLibrary_slow.lib" \
                "Nangate45_fast.lib:NangateOpenCellLibrary_fast.lib" \
                "Nangate45_typ.lib:NangateOpenCellLibrary_typical_openroad.lib"; do
        src=${pair%%:*}
        dst=${pair##*:}
        if [ -f "$NG45/lib/$dst" ]; then
            echo "  have $dst"
        else
            echo "  fetching $dst"
            curl -fL -o "$NG45/lib/$dst" "$base/$src"
        fi
    done
    ls -l "$NG45/lib/"NangateOpenCellLibrary_*.lib
}

# Verilog behaviour for the standard cells, which the enablement does not ship.
#
# Liberty describes a cell's TIMING, LEF its SHAPE, and neither says what it
# COMPUTES. A simulator needs the third view, and it is in none of the three
# places this project already pulls from: not the MacroPlacement enablement,
# not ORFS's nangate45 platform, not OpenROAD's test/Nangate45. All checked.
#
# Fetched rather than committed, the same as the GDS. The models carry Nangate's
# copyright notice and are pulled from where the library was published.
# Compare the SYNTHESISED netlist against the ROUTED one, gate against gate.
#
# THIS IS A TIGHTER CHECK THAN EITHER AGAINST THE RTL, and it exists because
# the RTL comparison passed while the routed netlist simulated wrong.
#
# Comparing a netlist to RTL needs relaxations: `set flatten model
# -seq_constant` so Conformal models the flops Genus proved constant and
# deleted, and -seq_constant_x_to 0 for the register file's missing reset.
# Those relaxations are correct for that comparison and they widen it.
#
# Gate against gate needs NONE of them. Both sides have the same flops, the
# same names and the same structure, so every key point maps one to one and
# any difference place and route introduced has nowhere to hide. If this fails
# while the RTL comparison passed, the relaxations were masking it.
run_lec_gate() {
    local name="$1"
    local rundir="$ROOT/runs/$name"
    local syn="$rundir/out/${DESIGN}_netlist.v"
    local routed="$rundir/out/${DESIGN}_routed.v"

    [ -f "$syn" ]    || { echo "No synthesised netlist at $syn"; exit 1; }
    [ -f "$routed" ] || { echo "No routed netlist at $routed"; exit 1; }
    command -v lec >/dev/null 2>&1 || {
        echo "MISSING: lec is not on your PATH."
        echo "         try: export PATH=/apps/cadencedigital/r23/bin:\$PATH"
        exit 1
    }

    cat > "$rundir/lec_gate.do" <<EOF
// Conformal LEC: the SYNTHESISED netlist (golden) against the ROUTED one.
set log file lec_gate.log -replace

// No modelling relaxations. Both sides are gates, so anything that does not
// map one to one is a real difference and must be reported as one.
set undefined cell black_box

read library -liberty $NG45/lib/NangateOpenCellLibrary_typical.lib -both

read design $syn    -verilog -golden  -sensitive -continuousassignment bidirectional
read design $routed -verilog -revised -sensitive -continuousassignment bidirectional

set system mode lec
add compared points -all
compare

report compare data    > $rundir/reports/63_lecgate_compare.rpt
report unmapped points > $rundir/reports/64_lecgate_unmapped.rpt
report verification    > $rundir/reports/65_lecgate_verification.rpt

exit -force
EOF

    echo "=== EQUIVALENCE: synthesised netlist vs routed netlist ==========="
    mkdir -p "$rundir/reports"
    (cd "$rundir" && lec -nogui -dofile lec_gate.do)
    echo
    cat "$rundir/reports/65_lecgate_verification.rpt" 2>/dev/null || echo "(no report written)"
    echo
    echo "Non-equivalent points, if any:"
    grep -c "Non-equivalent" "$rundir/reports/63_lecgate_compare.rpt" 2>/dev/null || true
}

get_cells() {
    echo "=== fetching the Nangate45 Verilog cell models ==================="
    mkdir -p "$ROOT/sim/cells"
    if [ -f "$ROOT/sim/cells/NangateOpenCellLibrary.v" ]; then
        echo "  already present: sim/cells/NangateOpenCellLibrary.v"
    else
        curl -fL -o "$ROOT/sim/cells/NangateOpenCellLibrary.v" \
          https://raw.githubusercontent.com/JulianKemmerer/Drexel-ECEC575/master/Encounter/NangateOpenCellLibrary/Front_End/Verilog/NangateOpenCellLibrary.v
    fi
    ls -l "$ROOT/sim/cells/"
}

# Run programs/program.mem on the RTL core. This is the baseline the gate run
# is compared against, and it uses the SAME testbench, so any difference
# between the two is the netlist and not the harness.
run_sim_rtl() {
    command -v iverilog >/dev/null 2>&1 || { echo "MISSING: iverilog"; exit 1; }
    echo "=== RTL core simulation ========================================="
    iverilog -g2012 -o "$ROOT/sim/rtl.vvp" \
        "$ROOT/sim/tb_cpu_core.v" "$ROOT/sim/mem_model.v" "$ROOT"/rtl/*.v || exit 1
    (cd "$ROOT" && vvp sim/rtl.vvp "$@")
}

# Run the same program on the netlist.
#
#     ./run.sh gls 06-clk3p9              zero-delay, on the routed netlist
#     ./run.sh gls 06-clk3p9 slow         back-annotated with the slow SDF
#
# TWO DEFINES ARE LOAD BEARING.
#
#   GATE_SIM  turns on rf_init_gates.vh, which holds the register file at zero
#             through reset. The netlist's register file has no reset, because
#             reg_file.v initialises RF in an `initial` block and synthesis
#             ignores those. Without it this program is X from instruction 25,
#             `add x18, x18, x17`, which reads x18 before writing it.
#
#   TETRAMAX  suppresses ng_xbuf inside the Nangate models. Without it they
#             DRIVE THEIR OWN RN INPUT PORT, iverilog reports "input port RN is
#             coerced to inout" a few hundred times, the asynchronous resets
#             never take, and the whole design sits at X forever. The symptom
#             looks like a broken netlist and is entirely the cell models.
# Locate Xcelium.
#
# xrun IS NOT IN THE TREE THAT CARRIES GENUS AND INNOVUS. nanoHUB keeps nine
# Cadence digital releases side by side -- r6 r8 r9 r12 r20 r21 r22 r23 current
# dev -- and Xcelium is only in the older six. r23/bin holds a startXcelium
# launcher that prints "Xcelium can be run with the xrun command" and sets up
# nothing, so the tool looks absent from every shell.
#
# This is the same trap as the original one: `command not found` meant the PATH
# pointed at one directory out of several, not that the tool was missing.
#
# The result is APPENDED to PATH by the caller, never prepended: r21/bin almost
# certainly carries its own genus and innovus, and putting it first would
# silently move the whole implementation flow two releases backwards.
find_xrun() {
    if command -v xrun >/dev/null 2>&1; then echo xrun; return; fi
    local c n best="" bestn=-1
    for c in /apps/cadencedigital/*/bin/xrun; do
        [ -x "$c" ] || continue
        n=$(echo "$c" | sed -n 's|.*/cadencedigital/r\([0-9]\{1,\}\)/bin/xrun||p')
        [ -n "$n" ] || continue
        if [ "$n" -gt "$bestn" ]; then bestn="$n"; best="$c"; fi
    done
    [ -n "$best" ] && echo "$best"
}

run_gls() {
    local name="$1"; shift
    # A bare word after the run name is the corner; anything starting with '+'
    # is a plusarg for the simulation and is passed straight through.
    local corner="zero"
    if [ $# -gt 0 ] && [ "${1#+}" = "$1" ]; then corner="$1"; shift; fi
    local rundir="$ROOT/runs/$name"
    local cells="$ROOT/sim/cells/NangateOpenCellLibrary.v"
    local netlist="$rundir/out/${DESIGN}_routed.v"

    [ -f "$cells" ] || { echo "MISSING: $cells"; echo "         run: ./run.sh cells"; exit 1; }

    if [ ! -f "$netlist" ]; then
        # The pre-layout netlist is a fallback and it is NOT the layout. It has
        # no clock tree and none of the post-route optimisation, so it answers
        # "does synthesis work", not "does the thing we built work". There is
        # also no SDF for it, so it can only ever be a zero-delay run.
        netlist="$rundir/out/${DESIGN}_netlist.v"
        [ -f "$netlist" ] || { echo "No netlist in $rundir/out."; exit 1; }
        echo "NOTE: no routed netlist in this run, falling back to the Genus one."
        echo "      Re-run '--from report' to write ${DESIGN}_routed.v and the SDFs."
    fi

    # The clock the run was built at, in ps. A timing-annotated simulation has
    # to be exercised at the period its delays were extracted for, or the
    # answer is about a clock the design was never constrained to.
    local period_ps=10000
    if [ -f "$rundir/RUN.env" ]; then
        period_ps=$(awk -F= '/CLK_PERIOD/{printf "%d", $2 * 1000}' "$rundir/RUN.env")
    fi
    # Unless the caller overrides it, which is how you find the period that
    # actually works rather than the one that was asked for.
    case " $* " in *" +period_ps="*) period_ps="" ;; esac

    local sdf=""
    if [ "$corner" != "zero" ]; then
        sdf="$rundir/out/${DESIGN}_${corner}.sdf"
        [ -f "$sdf" ] || {
            echo "No SDF at $sdf"
            echo "         re-run '--from report' to write it."
            exit 1
        }
    fi

    # Regenerated from THIS netlist every time, so the forced register names
    # can never be stale relative to the netlist being simulated.
    "$PY" "$ROOT/scripts/mk_rf_init.py" "$netlist" -o "$ROOT/sim/rf_init_gates.vh" || exit 1

    local plus=""
    [ -n "$period_ps" ] && plus="+period_ps=$period_ps"

    # DELETE THE BINARY BEFORE BUILDING IT.
    #
    # A failed compile used to leave the PREVIOUS run's sim/gate.vvp in place,
    # and vvp then happily ran it. That produced a full, plausible, completely
    # wrong result: byte-identical output from a different netlist, which read
    # as "the fix changed nothing" when in fact nothing had been rebuilt. An
    # invalid rf_init_gates.vh is exactly how it happens.
    rm -f "$ROOT/sim/gate.vvp"

    echo "=== GATE-LEVEL simulation: $name, corner '$corner' =============="
    echo "    netlist : $netlist"
    [ -n "$sdf" ] && echo "    sdf     : $sdf"
    [ -n "$period_ps" ] && echo "    period  : $period_ps ps"

    #-----------------------------------------------------------------------
    # XCELIUM IS THE ONE THAT ENFORCES TIMING CHECKS.
    #
    # The Nangate models carry $setuphold, $width, $recovery and $hold, and
    # each one drives a NOTIFIER into the flop's UDP. When a check fires the
    # UDP puts X on the output, the X flows into the writeback trace, and this
    # testbench fails. THAT is the full check: routing, extraction and timing
    # analysis all reduced to whether the program still computes.
    #
    # iverilog honours SDF path delays with -gspecify but does not enforce the
    # checks, so it can only ever say the delays did not change the answer. It
    # is kept for the zero-delay run, which is a different and cheaper
    # question.
    #
    # Three xrun options are load bearing:
    #   -timescale 1ps/1ps  the netlist and the cell models declare none, and
    #                       Xcelium refuses to elaborate a mixed design where
    #                       some modules have a timescale and others do not.
    #   -access +rwc        rf_init_gates.vh forces internal nets. Without
    #                       write access those forces are silently refused and
    #                       the register file stays X.
    #   -negdelay           SDF may contain negative delays at the fast corner;
    #                       without this they are clamped to zero and the hold
    #                       check is quietly optimistic.
    #-----------------------------------------------------------------------
    local log="$ROOT/sim/gls_${name}_${corner}.log"
    mkdir -p "$ROOT/sim"

    local XRUN
    # || true, because find_xrun exits non-zero when there is no Xcelium
    # and `set -e` turns that into a silent abort of the whole script.
    XRUN=$(find_xrun || true)

    # XCELIUM WHENEVER IT IS THERE, with or without an SDF.
    #
    # It enforces the timing checks, and it is also the tool that reads Innovus
    # netlists every day. iverilog simulates this design's GENUS netlist
    # correctly and its ROUTED netlist incorrectly, with the same testbench,
    # the same cell models, at zero delay, at every clock period tried, and
    # whatever the register file is forced to. Conformal compared that routed
    # netlist against the RTL and returned PASS with Incomplete verification: 0,
    # so the layout matches the design and the discrepancy is in how the
    # netlist is being simulated. Running the zero-delay tier on Xcelium too
    # takes the simulator out of the list of variables instead of leaving it in.
    if [ -n "$XRUN" ]; then
        echo "    xrun     : $XRUN"
        # THE CELL MODELS MUST BE COMPILED IN THE MODE THE SDF WAS WRITTEN FOR.
        # This is the whole ballgame for the timing tier.
        #
        # Innovus writes RECREM checks and negative-timing-check SETUPHOLDs:
        # 1,350 and 2,694 of them in this design. The Nangate models only carry
        # those inside `ifdef NTC / `ifdef RECREM. Compiled without them, over a
        # thousand annotations bind to NOTHING:
        #
        #   *W,SDFNET: Unable to annotate to non-existent timing check
        #              (RECREM (posedge RN) (posedge CK)) ... of DFFR_X1
        #
        # Some delays then land and others are dropped, and that inconsistent
        # delay picture captures the wrong data with no violation to flag it.
        # That is exactly how all three corners came back with 32 identical
        # errors and zero timing-check messages, on a netlist that passes
        # perfectly at zero delay.
        #
        # TETRAMAX STAYS ON for the SDF tier too. Taking it off was tried and
        # the design stopped running entirely: zero writes, nothing clocked.
        #
        # TETRAMAX suppresses the ng_xbuf X-propagation primitives, and in the
        # NTC branch those give RN_d a SECOND driver -- buf(RN_d, RN_di) and
        # ng_xbuf(RN_d, RNx, 1'b1), with RNx buffered back off RN_d. Two
        # drivers that disagree resolve to X, the flops never leave reset, and
        # the CPU does nothing at all.
        #
        # The x-buffers are an X-pessimism feature, not a correctness one. The
        # delayed reference signals the annotated checks need -- CK_d, D_d,
        # RN_di -- come from the $setuphold and $recrem delayed-signal
        # arguments, which NTC and RECREM provide and TETRAMAX leaves alone.
        #
        # Zero delay keeps TETRAMAX and switches the checks off outright. With
        # no delays, data changes in the same instant as the clock edge and
        # every check would fire meaninglessly.
        local sdfdef modedef checkarg
        if [ -n "$sdf" ]; then
            sdfdef="-define SDF_FILE=\"$sdf\""
            modedef="-define NTC -define RECREM -define TETRAMAX"
            checkarg=""
            echo "    simulator: xrun, SDF annotated, timing checks ENFORCED"
        else
            sdfdef=""
            modedef="-define TETRAMAX"
            checkarg="-notimingchecks"
            echo "    simulator: xrun, zero delay, timing checks off"
        fi
        "$XRUN" -timescale 1ps/1ps -access +rwc $checkarg \
             -define GATE_SIM $modedef $sdfdef \
             -l "$log" \
             "$ROOT/sim/tb_cpu_core.v" "$ROOT/sim/mem_model.v" "$netlist" "$cells" \
             $plus "$@"
        [ -n "$sdf" ] && summarise_violations "$log"
        return
    fi

    # IVERILOG WILL NOT DO THE SDF TIER, and this is a refusal rather than a
    # warning because it produced a confidently wrong answer.
    #
    # The typical corner has +1.257 ns of slack at 3.9 ns. Every path has over
    # a nanosecond of margin, so a correct timing simulation CANNOT produce
    # wrong data there. iverilog produced wrong data anyway, with bits 2 and 3
    # corrupted, while the same netlist at zero delay passes perfectly. The
    # delays are being misapplied; iverilog's $sdf_annotate support is partial.
    #
    # A wrong result that looks like a real one is worse than no result, so
    # this path stops. +force_iverilog overrides it for anyone who wants to
    # look at the misapplication itself.
    if [ -n "$sdf" ]; then
        case " $* " in
            *" +force_iverilog "*) echo "    simulator: iverilog, SDF, RESULTS NOT TRUSTWORTHY" ;;
            *)
                echo "REFUSING: the SDF tier needs xrun, and xrun was not found."
                echo "          iverilog applies SDF delays incorrectly on this design:"
                echo "          the typ corner has +1.257 ns of slack and still comes back"
                echo "          wrong, while zero delay passes. That is a broken measurement,"
                echo "          not a broken design, and it must not be reported as a result."
                echo
                echo "          Zero delay works everywhere:   ./run.sh gls $name"
                echo "          The timing tier needs nanoHUB, where xrun lives in"
                echo "          /apps/cadencedigital/r21/bin and run.sh finds it itself."
                echo "          Override with +force_iverilog if you want to see it anyway."
                exit 1
                ;;
        esac
    fi

    command -v iverilog >/dev/null 2>&1 || { echo "MISSING: iverilog and xrun"; exit 1; }
    # NOT eval, and not a defines string. SDF_FILE has to reach the compiler
    # with its quotes intact so that `$sdf_annotate(`SDF_FILE, ...)` expands to
    # a string literal. Collecting the flags in a variable and eval-ing it lets
    # the shell eat the quotes, and the error then lands on a testbench line
    # rather than anywhere near the quoting that caused it.
    if [ -n "$sdf" ]; then
        iverilog -g2012 -gspecify -DGATE_SIM -DTETRAMAX -DSDF_FILE="\"$sdf\"" \
            -o "$ROOT/sim/gate.vvp" \
            "$ROOT/sim/tb_cpu_core.v" "$ROOT/sim/mem_model.v" "$netlist" "$cells" || exit 1
    else
        iverilog -g2012 -DGATE_SIM -DTETRAMAX \
            -o "$ROOT/sim/gate.vvp" \
            "$ROOT/sim/tb_cpu_core.v" "$ROOT/sim/mem_model.v" "$netlist" "$cells" || exit 1
    fi
    (cd "$ROOT" && vvp sim/gate.vvp $plus "$@" 2>&1 | tee "$log")
}

# Count what the simulator said about timing, by its own message codes.
#
# A functional pass with violations logged is NOT a pass: it means the program
# did not happen to exercise the path that failed. 34 instructions do not cover
# 3,497 timing endpoints, which is exactly why STA is signoff and simulation is
# not. Both numbers get printed so neither can be read alone.
summarise_violations() {
    local log="$1"
    [ -f "$log" ] || return 0
    local su hl wd rc
    su=$(grep -c "TCHKSU"  "$log" 2>/dev/null || true)
    hl=$(grep -c "TCHKHLD" "$log" 2>/dev/null || true)
    wd=$(grep -c "TCHKWID" "$log" 2>/dev/null || true)
    rc=$(grep -cE "TCHKRCV|TCHKREM" "$log" 2>/dev/null || true)
    echo
    echo "--- timing check violations reported by the simulator ---"
    echo "  setup            : $su"
    echo "  hold             : $hl"
    echo "  pulse width      : $wd"
    echo "  recovery/removal : $rc"
    echo "  full log         : $log"
    if [ "$su" != "0" ] || [ "$hl" != "0" ]; then
        echo
        echo "  A functional PASS above with violations here means the program"
        echo "  did not exercise the failing path. It is not timing closure."
    fi
}

get_gds() {
    echo "=== fetching Nangate45 stream file =============================="
    mkdir -p "$HOME/nangate45_gds"
    curl -fL -o "$HOME/nangate45_gds/NangateOpenCellLibrary.gds" \
        https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/gds/NangateOpenCellLibrary.gds
    ls -l "$HOME/nangate45_gds/"
}

#---------------------------------------------------------------------------
# Argument parsing
#---------------------------------------------------------------------------
case "${1:-}" in
    gds)   get_gds; exit 0 ;;
    libs)  get_libs; exit 0 ;;
    cells) get_cells; exit 0 ;;
    sim)   shift; run_sim_rtl "$@"; exit 0 ;;
    gls)   [ -n "${2:-}" ] || { echo "usage: ./run.sh gls <run-name> [zero|slow|typ|fast] [+trace]"; exit 1; }
           shift; run_gls "$@"; exit 0 ;;
    table) "$PY" "$ROOT/scripts/qor.py" table --root "$ROOT"; exit 0 ;;
    lec)   [ -n "${2:-}" ] || { echo "usage: ./run.sh lec <run-name> [syn|routed|gate]"; exit 1; }
           if [ "${3:-syn}" = "gate" ]; then run_lec_gate "$2"; else run_lec "$2" "${3:-syn}"; fi
           exit 0 ;;
    -h|--help) usage 0 ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --period) PERIOD="$2"; shift 2 ;;
        --util)   UTIL="$2";   shift 2 ;;
        --effort) EFFORT="$2"; shift 2 ;;
        --artifacts) ARTIFACTS=1; shift ;;
        --name)   NAME="$2";   shift 2 ;;
        --from)   FROM="$2";   shift 2 ;;
        --note)   NOTE="$2";   shift 2 ;;
        --timing) TIMING="$2"; shift 2 ;;
        --syn-corner) SYN_CORNER_ARG="$2"; shift 2 ;;
        --no-qor) DO_QOR=0;    shift ;;
        *) echo "unknown option: $1"; echo; usage 1 ;;
    esac
done

case "$TIMING" in
    mmmc|typ) ;;
    *) echo "--timing must be mmmc or typ"; exit 1 ;;
esac

# Checked here as well as in genus.tcl, so a typo costs a second rather than
# the minutes it takes Genus to start and reach the effort lines.
case "$EFFORT" in
    low|medium|high) ;;
    *) echo "--effort must be low, medium or high"; exit 1 ;;
esac

# The two corner knobs are separate on purpose, because they answer different
# questions and changing both at once answers neither. --timing alone, on a
# netlist that already exists, measures what the corner costs. Adding
# --syn-corner measures what building for the corner wins back.
[ -n "$SYN_CORNER_ARG" ] || {
    if [ "$TIMING" = "typ" ]; then SYN_CORNER_ARG=typical; else SYN_CORNER_ARG=slow; fi
}
export TIMING_MODE="$TIMING"
export SYN_CORNER="$SYN_CORNER_ARG"

[ "$(stage_index "$FROM")" -ge 0 ] || {
    echo "--from must be one of: $STAGES"; exit 1; }

# Default run name is the clock it was run at, which is the thing that
# usually differs. clk3p0, clk2p5, and so on.
# Default name is what usually differs. Utilization joins it when it is not
# the 0.70 default, so a sweep cannot silently overwrite itself.
if [ -z "$NAME" ]; then
    NAME="clk$(echo "$PERIOD" | tr '.' 'p')"
    [ "$UTIL" = "0.70" ] || NAME="${NAME}_u$(echo "$UTIL" | tr -d '0.')"
    [ "$EFFORT" = "medium" ] || NAME="${NAME}_e${EFFORT}"
fi

export CLK_PERIOD="$PERIOD"
export CORE_UTIL="$UTIL"
export SYN_EFFORT="$EFFORT"
export WRITE_ARTIFACTS="$ARTIFACTS"

RUNDIR="$ROOT/runs/$NAME"

if [ "$FROM" = "syn" ] && [ -d "$RUNDIR" ]; then
    echo "NOTE: runs/$NAME already exists and will be rebuilt from synthesis."
    echo "      Its archived reports in results/$NAME/ are not touched."
fi

mkdir -p "$RUNDIR"
cd "$RUNDIR"

# A run remembers the clock it was built at. Resuming one without repeating
# --period would otherwise silently re-export the default, and while Innovus
# reads the period out of the SDC Genus already wrote and so would be
# unaffected, the run banner would lie about what you were looking at.
if [ "$FROM" = "syn" ]; then
    printf 'CLK_PERIOD=%s
CORE_UTIL=%s
SYN_EFFORT=%s
' "$PERIOD" "$UTIL" "$EFFORT" > RUN.env
elif [ -f RUN.env ]; then
    . ./RUN.env
    PERIOD="$CLK_PERIOD"
    export CLK_PERIOD
    # A resumed run keeps the effort it was SYNTHESISED at. Resuming does not
    # re-synthesise, so taking the default here would relabel a high-effort
    # run as medium in its own banner and in the table, and the relabelling
    # would survive as the record of what was built.
    if [ -n "${SYN_EFFORT:-}" ]; then EFFORT="$SYN_EFFORT"; fi
    export SYN_EFFORT="$EFFORT"
fi

echo "=================================================================="
echo " run     $NAME"
echo " clock   $PERIOD ns"
echo " util    $UTIL"
echo " effort  $EFFORT"
echo " from    $FROM"
echo " dir     $RUNDIR"
echo "=================================================================="

preflight

FROM_IDX=$(stage_index "$FROM")

# Synthesis, if we are starting at or before it.
if [ "$FROM_IDX" -le 0 ]; then
    run_syn
    PNR_START="floorplan"
else
    PNR_START="$FROM"
fi

run_pnr "$PNR_START"

cd "$ROOT"
[ "$DO_QOR" -eq 1 ] && collect

echo
echo "Reports:  runs/$NAME/reports/40_final_setup.rpt"
echo "Table:    results/QOR.md"
