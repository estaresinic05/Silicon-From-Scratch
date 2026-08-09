# pipelined-cpu-physical-design

Physical design copy of the five stage pipelined RISC-V CPU. RTL to routed
layout on Nangate45, using Cadence Genus and Innovus.

**This is a separate copy on purpose.** `Verilog/CPU/pipelined-cpu/` is the
verified simulation design and nothing here touches it. That design passes its
testbench at 34 retirements in 48 cycles and should stay pinned. This copy will
drift as physical design demands things simulation does not care about.

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

A formatted Word report for any run, with every number parsed out of that run's
own reports rather than transcribed:

```
python3 scripts/make_report.py --run runs/<name> --images docs/images
```

Screenshots dropped into `docs/images/` under the filenames listed in its
README are placed automatically, each with its caption.

---

**`runs/<name>/reports/40_final_setup.rpt` is the result.** The worst path slack in
that file is post-route timing with extracted parasitics, and it is the only
timing number worth quoting. Everything before it is an estimate.

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
