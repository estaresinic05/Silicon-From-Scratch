# Pipelined CPU Physical Design

Physical design copy of the five stage pipelined RISC-V CPU. RTL to routed
layout on Nangate45, using Cadence Genus and Innovus.

<p align="center">
  <img src="docs/images/die-routed.png" width="47%" alt="The routed core: 93 rows of standard cells filling a 131 by 130 micron square, signal routing on metal2 through metal6, and the power ring on metal8 and metal9.">
  <img src="docs/images/die-zoom.png" width="47%" alt="A few standard cell rows zoomed until individual cells resolve, with the metal1 power rails running along each row boundary.">
</p>

<p align="center">
  <em>Left: the routed core, 131.29 &times; 130.2 &micro;m, 4,332 standard cells in
  93 rows at 69.7% density, wired with 73,127 &micro;m of copper. Meets setup
  timing at 357 MHz with 2 ps to spare <strong>at the typical corner</strong>.
  That is not the signoff figure: judged at the slow corner, this design does
  not close below about 4.1 ns, which is 244 MHz.<br>
  Right: the same layout zoomed until individual cells resolve. The horizontal
  lines are the metal1 power rails that every cell straddles.</em>
</p>

**This is a separate copy on purpose.** `Verilog/CPU/pipelined-cpu/` is the
verified simulation design and nothing here touches it. That design passes its
testbench at 34 retirements in 48 cycles and should stay pinned. This copy will
drift as physical design demands things simulation does not care about.

The die shots above come from `results/03-ring-fix/reports/`, which is committed
so every number can be checked against its source. **That run was judged at a
single typical corner**, and that is why its 2.8 ns is no longer the headline:
re-judged at slow, the same layout misses by −0.968 ns across 362 endpoints. It
is still the best *typical* run, with clean connectivity and **zero DRC
violations**, and it is worth reading as the point where this project learned
that a corner is part of a number rather than a footnote to one.

**The signoff result is 244 MHz**, from `results/fmax-clk4p1/`, judged at slow
with hold clean at all three corners. `results/QOR.md` carries one row per run
and a **By corner** table beside it. Every timing figure on this page states the
corner it was measured at, and any figure that does not is a bug in this
document. All of them assume `IO_DELAY = 0.30 × CLK_PERIOD`.

---

## The one difference from the simulation design

`pipelined_cpu_core` is the top level here, and **it has no memories.** They
appear on its boundary as ports instead:

```
imem_addr  ->        dmem_addr  ->
imem_rdata <-        dmem_wdata ->
                     dmem_write ->
                     dmem_read  ->
                     dmem_rdata <-
```

A memory is not built from standard cells and has no gate level view, so a
placer has nothing to place for one and the run fails on it. Hoisting the
memories out leaves a pure standard cell block, which is the shape physical
design needs. Real processors are partitioned identically, with the caches
outside the core boundary.

Concretely: `instruct_mem` and `data_mem` are not in `rtl/` at all, and
`pipelined_cpu_datapath.v` drives the ports above instead of instantiating
them. Nothing else in the RTL changed.

---

## Prerequisites

Both are already true on nanoHUB if you have followed along:

1. **Genus and Innovus on your PATH.** They live in `/apps/cadencedigital/r23/bin`,
   which is a different tree from the analog Cadence install that `cadence_nd.sh`
   sets up. Check with `which -a genus innovus`.
2. **The Nangate45 enablement**, at `~/MacroPlacement/Enablements/NanGate45`.
   It ships the Liberty, both LEFs, and the QRC techfile, so extraction is real
   rather than a default table. If you do not have it:
   ```
   cd ~ && git clone --depth 1 https://github.com/TILOS-AI-Institute/MacroPlacement
   ```

---

## Running it

```
./run.sh                                   full flow at the default clock
./run.sh --period 2.5 --note "tighten"     full flow at 2.5 ns
./run.sh --name baseline --note "..."      name the run yourself
./run.sh --name baseline --from cts        resume an existing run at CTS
./run.sh gds                               fetch the Nangate45 stream file
./run.sh table                             rebuild results/QOR.md
```

`run.sh` checks its prerequisites before touching anything and refuses to start
if a library or a tool is missing, with the fix printed.

**Every run gets its own directory under `runs/`.** That is the whole point: a
second experiment can never destroy the first one's reports, which is what made
a single shared `work/` untenable the moment there was more than one result
worth comparing. A run is named after its clock unless you say otherwise, so
`--period 2.5` builds `runs/clk2p5`.

`--from` resumes an existing run at a stage boundary instead of starting over.
Placement takes minutes on this design and hours on a real one, so rerunning it
to try a different CTS setting is waste you tolerate exactly once. Stages, in
order: `syn floorplan power place cts route report`.

---

## What comes out

```
runs/<name>/out/pipelined_cpu_core_netlist.v  gate level netlist from Genus
runs/<name>/out/pipelined_cpu_core.sdc        constraints, through synthesis
runs/<name>/pipelined_cpu_core_final.def      the routed layout
runs/<name>/enc/                              Innovus database, one per stage
runs/<name>/reports/                          every report, synthesis and P&R

results/<name>/reports/                       the small text reports, COMMITTED
results/qor.csv                               one row per run
results/QOR.md                                the table you actually read
```

`runs/` is gitignored: the databases are large and binary, and the run is
reproducible from the scripts. `results/` is committed on purpose, because it
holds the evidence behind every number quoted anywhere else, and a claim whose
report is not in the repo is a claim nobody can check.

---

## Comparing iterations

Every run appends one row to `results/QOR.md` on its way out. That table,
rather than any single run, is the real output of this project.

```
python3 scripts/qor.py collect runs/<name> --note "what changed"
python3 scripts/qor.py table
```

`docs/pnr-report.pdf` is the written form of one run, with the floorplan, the
power grid, the clock tree and the timing walked through in full.

### Every run reports all three corners

`QOR.md` carries a **By corner** table beside the main one. The design is
optimised against slow for setup and fast for hold exactly as before, and then
the report stage activates a typical view as well and re-reports from the same
routed database. Nothing about what was built changes; what changes is that a
typical number and a slow number now come out of the same run.

That matters because they are not close. On this design 2.8 ns closes at
**+0.002 at typical and misses by −0.968 at slow**, and for a while those two
facts lived in two different runs and had to be joined by hand. A slack quoted
without its corner is not a result.

Corner reporting also works on a database that is already routed:

```
./run.sh --name 03-ring-fix --from report      # re-report, no re-route
```

If a corner library is missing the run says so in
`reports/49_corner_status.rpt` rather than quietly reporting fewer corners.
`slow` and `fast` are not in the stock MacroPlacement enablement and come from
The-OpenROAD-Project/OpenROAD `test/Nangate45`.

---

**`runs/<name>/reports/40_final_setup.rpt` is the result.** The worst path slack in
that file is post-route timing with extracted parasitics, and it is the only
timing number worth quoting. Everything before it is an estimate.
`40_setup_slow.rpt`, `40_setup_typ.rpt` and `40_setup_fast.rpt` beside it are
the same check at each corner; the signoff one is slow.

---

## Running the program on the layout

Static timing analysis proves every path in the design and executes nothing.
Gate-level simulation executes the program on the netlist that was actually
built. They answer different questions and neither replaces the other.

```
./run.sh cells                     fetch the Nangate Verilog cell models, once
./run.sh sim                       run program.mem on the RTL core
./run.sh gls 06-clk3p9             run the same program on the routed netlist
./run.sh gls 06-clk3p9 slow +trace with the slow corner's SDF, printing writes
```

Both use **the same testbench**, `sim/tb_cpu_core.v`, because the RTL core and
the netlist present the same module name and the same ports. Any difference in
what it reports is the netlist and not the harness.

### It cannot use the RTL testbench, and that is the interesting part

`pipelined-cpu/testbench/` reads `dut.datapath.registers.RF[k]` and five
internal control signals by hierarchical reference. **None of those survive
synthesis.** The register file becomes 992 flip-flops with names like
`registers_RF_reg[7][0]` and the control signals become wires numbered by the
tool.

So this testbench watches only the ports, which is all a real chip would give
you. The oracle is the **writeback trace**: `dbg_wb_enable`, `dbg_wb_addr` and
`dbg_wb_data` are the register file's write port brought to the boundary, and
every architectural write appears there in order. A golden RV32I model produces
the sequence the program must perform, and the observed sequence is compared
against it element by element. A lost flush shows up as an extra write, a lost
stall as a wrong value. Data memory is checked directly, because the memories
sit outside the core and the testbench owns them.

### Two things bite, and both are recorded rather than papered over

**The register file has no reset in gates.** `reg_file.v` zeroes RF in an
`initial` block; simulation honours it and synthesis ignores it. This program
reads x18 at instruction 25 before anything writes it, so in gates x18 is X and
the loop accumulates X. `+define+GATE_SIM` holds the register nets at zero
through reset, which is the standard treatment of un-resettable state. Run
without it to watch the X spread. **This is a property of the program**: real
silicon powers up with whatever the register file happens to hold.

**The Nangate models drive their own reset pin.** Without `+define+TETRAMAX`
they call `ng_xbuf` on the `RN` input port, iverilog reports "input port RN is
coerced to inout" a few hundred times, the asynchronous resets never take, and
the entire design sits at X forever. It looks exactly like a broken netlist and
is entirely the cell models. `run.sh gls` sets both defines.

### What a good run looks like

```
writes observed   : 25 of 25
cycles to last    : 48
instructions      : 34 dynamic
cycles/instruction: 1.41
```

Identical to the RTL run, which is the point. **34 instructions in 48 cycles at
the closing period is the execution time**, and it is the number the pipelined
against single-cycle comparison turns on, since frequency alone flatters a
pipeline that stalls.

---

## The flow, stage by stage

Innovus saves the database after every stage into `runs/<name>/enc/`. If
something fails, or you want to change one thing late in the flow, resume from
a checkpoint rather than start over:

```
./run.sh --name <name> --from cts        # restores 03_placed.enc for you
```

Or by hand, which is also how you open a finished layout in the GUI:

```
restoreDesign enc/03_placed.enc.dat pipelined_cpu_core
```

**Note the `.dat`.** `saveDesign enc/03_placed.enc` writes a small Tcl script
called `03_placed.enc` and the actual session directory `03_placed.enc.dat`
beside it. `restoreDesign` wants the directory. Give it the `.enc` file and it
answers `IMPSYT-7338: The specified design session directory could not be
located`, which reads like the file is missing when it is sitting right there.

| Stage | What happens | Checkpoint |
|---|---|---|
| 1 | Floorplan. Core sized from cell area at 70% utilization, square, 10 µm margin. Pins spread around the boundary. | `01_floorplan.enc` |
| 2 | Power. Ring on metal8/metal9, vertical straps on metal8, `sroute` ties the metal1 rails in every row up to the grid. | `02_power.enc` |
| 3 | Placement with optimization. | `03_placed.enc` |
| 4 | Clock tree. Before this the clock is ideal, zero skew and zero insertion delay. After it the numbers get honest. | `04_cts.enc` |
| 5 | Filler cells, then routing. | `05_routed.enc` |
| 6 | Post route optimization, then DRC and connectivity checks. | `06_final.enc` |

---

## Timing: start loose

`constraints/pipelined_cpu_core.sdc` sets the clock to **3.0 ns**, well slower
than the 1.81 ns this design reached in pre-layout synthesis. That is
deliberate. The goal of the first run is one clean pass end to end, not a
result. Fighting timing on run one is how people abandon a flow.

Once a run completes clean, tighten the clock and rerun until it fails. The
last value that passed post-route is the real number.

```
./run.sh --period 2.5 --note "sweep step 1"
./run.sh --period 2.2 --note "sweep step 2"
```

**Where the sweep has got to. At the typical corner, 2.8 ns passes post-route
with 2 ps to spare. At the slow signoff corner, nothing closes below about
4.1 ns.** Both are real measurements of the same design and they are 46% apart,
which is the most important sentence on this page.

At typical, the worst path launches out of the writeback stage, crosses the
forwarding comparators into the ALU operand mux, and then spends 2.12 ns of its
2.85 ns walking the carry chain of the 32-bit ripple-carry adder. That one chain
is 74% of the clock while the adder is under 3% of the area, and because it is
instantiated structurally the synthesiser cannot restructure out of it.

That made a different adder look like the obvious next gain. **It was measured,
and it is not.** Wrapped identically between registers and judged at slow, a
hand-written carry-lookahead came out 12 ps *slower* than the ripple carry,
1241 ps against 1229, at 741 cells against 1129. Smaller, not faster. Genus
rebuilds a clean chain of full adders into its own carry structure, and this CPU
instantiates one full adder per bit *inside* a per-bit slice, between an invert
mux pair and a result mux, so synthesis never sees a 32-bit addition to
restructure in the first place.

Both Genus and Innovus rerun at each step, and they must: synthesis targets the
constraint too, so a netlist built for 3.0 ns has no reason to be any faster
than 3.0 ns. **This is why a run that meets timing never tells you what was
achievable** — the optimiser converges on whatever it was given and then spends
what is left over on area.

## Two assumptions to quote with any result

1. **The memory interface budget is invented.** The SDC gives 30% of a cycle
   for the memory to answer and 30% for setup at its input. Those are
   assumptions, not measurements, and the timing result moves if they change.
2. **Nangate45 has no foundry behind it.** This flow produces a complete
   layout, not a fabricated chip. Saying so unprompted reads as rigour.
