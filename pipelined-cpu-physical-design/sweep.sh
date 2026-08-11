#!/bin/bash
#############################################################################
# Design-space sweeps for the pipelined CPU.
#
#   bash sweep.sh fmax             find the real closing frequency at slow
#   bash sweep.sh util 4.1         utilization curve at a 4.1 ns clock
#   bash sweep.sh confirm 4.1      is a closure at 4.1 ns repeatable?
#
# A FILE, not a command to paste. Paste into the VNC xterm drops characters,
# and it has already eaten a "--from" once.
#
# Each run is a full synthesis plus place and route. On the bypassed RTL that
# is 13 to 17 minutes, measured; it was 30 to 40 before the register file
# change halved the cell count. Every mode here is four runs. Launch one and
# leave it.
#
# Nothing heavy is written: no DEF, no GDS, no SDF, no netlist. Every number
# these produce comes out of reports/, which is a few kB of text. Add
# --artifacts to a single run later if you want the layout to look at.
#
# THIS FILE USED TO LIVE IN THE NANOHUB HOME DIRECTORY AND NOWHERE ELSE,
# which meant the tool that generated every committed QoR row was itself
# untracked, unreviewable and one `rm` from gone. It is in the repo now. If a
# stale ~/sweep.sh is still sitting in the home directory, delete it rather
# than letting the two drift.
#############################################################################

set -u

export PATH=/apps/cadencedigital/r23/bin:$PATH
cd "$(dirname "$0")" || { echo "cannot find the project directory"; exit 1; }

MODE="${1:-}"

run_one() {
    local period="$1" util="$2" name="$3" note="$4"
    echo
    echo "##########################################################"
    echo "### $name   period=$period ns   utilization=$util"
    echo "##########################################################"
    date
    ./run.sh --period "$period" --util "$util" --name "$name" --note "$note"
}

case "$MODE" in

  fmax)
    # WHAT IS THE REAL CLOSING FREQUENCY AT THE SIGNOFF CORNER.
    #
    # Walking outward finds the first period that closes and the last that
    # does not, which together bracket the answer. A sweep with no failing
    # point cannot show you where the edge is, so include one you expect to
    # miss.
    #
    # NOTE: the 3.9 to 4.3 range was chosen for the OLD RTL, whose register
    # file wrote on the negedge. That design is gone. Re-pick the range from
    # wherever the current one closes before reading anything into these.
    for p in 3.9 4.0 4.1 4.3; do
        run_one "$p" 0.70 "fmax-clk$(echo "$p" | tr '.' 'p')" "fmax sweep at 0.70 util"
    done
    ;;

  util)
    # WHAT DOES DENSITY COST AND BUY.
    #
    # ANSWERED, 2026-08-11, AND THE ANSWER WAS NOTHING. Across 0.60 to 0.85
    # the die shrank 16% per side and total wirelength did not move: 80.7k,
    # 85.0k, 81.3k, 83.6k um with no trend. Shrinking the core shortens nets
    # and packing tighter costs the placer the freedom to put connected cells
    # near each other, and the two cancelled. 0.80 and 0.85 came back about
    # 40 ps WORSE than 0.70.
    #
    # The precondition is in the route log: 0.00% H and V overflow at every
    # point. Utilization is a lever on a design starved of routing space, and
    # this one never was. Re-run this only if congestion appears.
    PERIOD="${2:-}"
    [ -n "$PERIOD" ] || { echo "usage: bash sweep.sh util <period>"; exit 1; }
    for u in 0.60 0.70 0.80 0.85; do
        run_one "$PERIOD" "$u" "util$(echo "$u" | tr -d '0.')-clk$(echo "$PERIOD" | tr '.' 'p')" \
                "utilization sweep at $PERIOD ns"
    done
    ;;

  confirm)
    # IS A MARGINAL CLOSURE REAL, OR DID ONE RUN GET LUCKY?
    #
    # THE OBVIOUS VERSION OF THIS EXPERIMENT MEASURES NOTHING. Innovus is
    # deterministic: the same configuration returns the same answer, byte for
    # byte. 00-baseline and 01-split-uncertainty differ in clock uncertainty
    # and produced identical WNS, cell count and wirelength to three decimals;
    # so did 02-clk2p8 and 03-ring-fix. Running the same command three times
    # gives you the same number three times and tells you nothing about
    # whether it was luck.
    #
    # To sample the optimiser's distribution you have to perturb an input that
    # reshuffles placement WITHOUT moving the timing budget.
    #
    # Utilization does that. A 0.01 step changes the die about half a percent
    # per side, and the utilization sweep puts the slope near 0.70 at roughly
    # -0.145 ns per unit, so +-0.01 carries about 1.5 ps of real effect. That
    # is far inside the ~30 ps run-to-run scatter being measured, while the
    # floorplan dimensions change enough that placement starts somewhere
    # completely different.
    #
    # NOT the clock period. Ten picoseconds of extra period is ten
    # picoseconds of extra slack by construction, which is the very quantity
    # under test.
    #
    # Read it as a vote, not an average: four points plus the existing 0.70
    # run. All closing means the closure is real. A scatter across zero means
    # the design sits on the boundary and a single run cannot be quoted.
    PERIOD="${2:-}"
    [ -n "$PERIOD" ] || { echo "usage: bash sweep.sh confirm <period>"; exit 1; }
    for u in 0.68 0.69 0.71 0.72; do
        run_one "$PERIOD" "$u" "confirm-clk$(echo "$PERIOD" | tr '.' 'p')-u$(echo "$u" | tr -d '0.')" \
                "closure repeatability probe at $PERIOD ns"
    done
    ;;

  *)
    echo "usage:"
    echo "   bash sweep.sh fmax             four runs, 3.9 to 4.3 ns at 0.70"
    echo "   bash sweep.sh util <period>    four runs, 0.60 to 0.85 utilization"
    echo "   bash sweep.sh confirm <period> four runs at 0.68 to 0.72, a noise probe"
    exit 1
    ;;
esac

echo
echo "##########################################################"
echo "### sweep done"
date
python3 scripts/qor.py table
echo
echo "The table is results/QOR.md. Read the BY CORNER section: the slow"
echo "column is signoff, and a run closes when its slow Setup WNS is positive"
echo "with zero violations."
