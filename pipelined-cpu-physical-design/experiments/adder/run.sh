#!/bin/bash
#############################################################################
# Ripple carry against carry lookahead, on their own, at the slow corner.
#
#   ./run.sh                        both adders, 32 bit, slow corner
#   ./run.sh --period 0.8           a different (still unreachable) target
#   ./run.sh --corner typical       compare at typical instead
#
# WHY THIS EXISTS SEPARATELY from the CPU flow: 74% of the CPU's critical path
# is the ripple carry chain, so replacing the adder is the next experiment. If
# the adder is swapped straight into the CPU and the path does not improve as
# much as hoped, there is no way to tell whether the adder underdelivered or
# whether something around it became the new limit. Measuring the adder alone
# first answers that in advance.
#
# The clock is set far tighter than either adder can meet, deliberately. See
# the note in syn.tcl: a met constraint tells you what you asked for, never
# what was achievable.
#############################################################################

set -e
cd "$(dirname "$0")"
EXP_ROOT=$(pwd)
export EXP_ROOT

PERIOD=0.5
CORNER=slow

while [ $# -gt 0 ]; do
    case "$1" in
        --period) PERIOD="$2"; shift 2 ;;
        --corner) CORNER="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

command -v genus >/dev/null 2>&1 || {
    echo "MISSING: genus is not on your PATH."
    echo "         try: export PATH=/apps/cadencedigital/r23/bin:\$PATH"
    exit 1
}
for lib in NangateOpenCellLibrary_${CORNER}.lib; do
    [ -f "$HOME/MacroPlacement/Enablements/NanGate45/lib/$lib" ] || {
        echo "MISSING: $lib"; exit 1; }
done

export CLK_PERIOD="$PERIOD"
export SYN_CORNER="$CORNER"

# Genus prints picoseconds for this library. "Data Path" is the arrival time
# at the capture register, which with the wrapper's registers at both ends is
# the adder's own delay and nothing else.
extract() {
    local f="$1" key="$2"
    awk -v k="$key" '$0 ~ k":" {for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+$/) {print $i; exit}}' "$f"
}

echo "=================================================================="
echo " adder comparison   corner ${CORNER}   clock ${PERIOD} ns"
echo "=================================================================="

for top in adder_bench_rca adder_bench_cla; do
    echo
    echo "=== $top ==========================================="
    rm -rf "runs/$top"
    mkdir -p "runs/$top"
    ( cd "runs/$top" && ADDER_TOP="$top" genus -files "$EXP_ROOT/syn.tcl" -log genus )
done

#---------------------------------------------------------------------------
# One table, written where it can be committed.
#---------------------------------------------------------------------------
mkdir -p results
{
    echo "# Ripple carry against carry lookahead"
    echo
    echo "Corner \`${CORNER}\`, clock ${PERIOD} ns, both pushed to high effort."
    echo "Delay is Genus's Data Path in picoseconds, register to register, with"
    echo "the adder the only logic on the path."
    echo
    echo "| Adder | Delay (ps) | Slack (ps) | Cells | Area (um2) |"
    echo "|---|---:|---:|---:|---:|"
    for top in adder_bench_rca adder_bench_cla; do
        t="runs/$top/reports/timing.rpt"
        a="runs/$top/reports/area.rpt"
        g="runs/$top/reports/gates.rpt"
        delay=$(extract "$t" "Data Path"); slack=$(extract "$t" "Slack")
        cells=$(awk '/^ *total/ {print $2; exit}' "$g" 2>/dev/null)
        area=$(awk '/^ *total/ {print $NF; exit}' "$a" 2>/dev/null)
        name=$(echo "$top" | sed 's/adder_bench_//')
        echo "| \`$name\` | ${delay:--} | ${slack:--} | ${cells:--} | ${area:--} |"
    done
} > results/COMPARE.md

echo
cat results/COMPARE.md
echo
echo "Full reports: runs/<top>/reports/   Table: results/COMPARE.md"
