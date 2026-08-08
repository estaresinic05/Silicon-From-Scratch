#!/bin/bash
#############################################################################
# pipelined-cpu-pnr: RTL to routed layout, one command.
#
#   ./run.sh          synthesis, then place and route
#   ./run.sh syn      synthesis only
#   ./run.sh pnr      place and route only (needs synthesis to have run)
#   ./run.sh gds      fetch the Nangate45 stream file so a GDSII can be made
#
# Everything runs in work/. Delete that directory to start clean.
#############################################################################

set -e
cd "$(dirname "$0")"
ROOT=$(pwd)

NG45=$HOME/MacroPlacement/Enablements/NanGate45

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

#---------------------------------------------------------------------------
run_syn() {
    echo "=== SYNTHESIS (Genus) ==========================================="
    mkdir -p work && cd work
    genus -files ../scripts/genus.tcl -log genus
    cd "$ROOT"
    echo "=== synthesis done. reports in reports/ ========================="
}

run_pnr() {
    echo "=== PLACE AND ROUTE (Innovus) ==================================="
    if [ ! -f out/pipelined_cpu_core_netlist.v ]; then
        echo "No netlist found. Run './run.sh syn' first."
        exit 1
    fi
    mkdir -p work && cd work
    innovus -files ../scripts/innovus.tcl -log innovus
    cd "$ROOT"
    echo "=== place and route done ======================================="
}

get_gds() {
    echo "=== fetching Nangate45 stream file =============================="
    mkdir -p "$HOME/nangate45_gds"
    curl -fL -o "$HOME/nangate45_gds/NangateOpenCellLibrary.gds" \
        https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/gds/NangateOpenCellLibrary.gds
    ls -l "$HOME/nangate45_gds/"
}

#---------------------------------------------------------------------------
case "${1:-all}" in
    syn) preflight; run_syn ;;
    pnr) preflight; run_pnr ;;
    gds) get_gds ;;
    all) preflight; run_syn; run_pnr ;;
    *)   echo "usage: $0 [syn|pnr|gds|all]"; exit 1 ;;
esac
