#!/bin/bash
#############################################################################
# pipelined-cpu-pnr: RTL to routed layout, one command per experiment.
#
#   ./run.sh                                 full flow at the default clock
#   ./run.sh --period 2.5 --note "tighten"   full flow at 2.5 ns
#   ./run.sh --name baseline --note "..."    name the run yourself
#   ./run.sh --name baseline --from cts      resume an existing run at CTS
#   ./run.sh --timing typ                    single typical corner, runs 00-03
#   ./run.sh lec <run>                       formal equivalence, RTL vs netlist
#   ./run.sh gds                             fetch the Nangate45 stream file
#   ./run.sh table                           rebuild results/QOR.md
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

PERIOD=3.0
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
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
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
    command -v python3 >/dev/null 2>&1 || { echo "python3 not found, skipping QOR"; return; }
    python3 "$ROOT/scripts/qor.py" collect "$ROOT/runs/$NAME" --note "$NOTE" --root "$ROOT"
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
    local rundir="$ROOT/runs/$name"
    local netlist="$rundir/out/pipelined_cpu_core_netlist.v"

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

// SYNTHESIS MERGED TWO CONTROL SIGNALS THAT ARE ALWAYS EQUAL.
//
// pipelined_cpu_control.v assigns IFID_memRead and IFID_memToReg identically
// in every branch: both 0 by default, both 1 for a load, never assigned
// anywhere else. They are one signal with two names, so Genus keeps a single
// flop chain and drives both from it. The netlist has IDEX_memRead_reg and
// EXMEM_memRead_reg but no memToReg at those stages, which leaves golden's
// copies unmapped and fails MEMWB_memToReg_reg downstream of them.
//
// Mapped explicitly rather than with a blanket -seq_merge. A named pair says
// which optimisation was accepted and can be re-checked when the RTL changes;
// a global relaxation silently forgives anything of that shape forever.
add mapped points /datapath/IDEX_memToReg_reg  /datapath/IDEX_memRead_reg
add mapped points /datapath/EXMEM_memToReg_reg /datapath/EXMEM_memRead_reg


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
    table) python3 "$ROOT/scripts/qor.py" table --root "$ROOT"; exit 0 ;;
    lec)   [ -n "${2:-}" ] || { echo "usage: ./run.sh lec <run-name>"; exit 1; }
           run_lec "$2"; exit 0 ;;
    -h|--help) usage 0 ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --period) PERIOD="$2"; shift 2 ;;
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
[ -n "$NAME" ] || NAME="clk$(echo "$PERIOD" | tr '.' 'p')"

export CLK_PERIOD="$PERIOD"

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
    echo "CLK_PERIOD=$PERIOD" > RUN.env
elif [ -f RUN.env ]; then
    . ./RUN.env
    PERIOD="$CLK_PERIOD"
    export CLK_PERIOD
fi

echo "=================================================================="
echo " run     $NAME"
echo " clock   $PERIOD ns"
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
