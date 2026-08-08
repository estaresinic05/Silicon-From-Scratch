# pipelined-cpu-pnr

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
./run.sh          synthesis, then place and route
./run.sh syn      synthesis only
./run.sh pnr      place and route only
./run.sh gds      fetch the Nangate45 stream file, so a GDSII can be written
```

`run.sh` checks its prerequisites before touching anything and refuses to start
if a library or a tool is missing, with the fix printed.

Everything runs inside `work/`. Delete that directory to start clean.

---

## What comes out

```
out/pipelined_cpu_core_netlist.v   gate level netlist from Genus
out/pipelined_cpu_core.sdc         constraints, propagated through synthesis
work/pipelined_cpu_core_final.def  the routed layout
work/enc/                          Innovus database, one per stage
reports/                           synthesis reports
work/reports/                      place and route reports
```

**`work/reports/40_final_setup.rpt` is the result.** The worst path slack in
that file is post-route timing with extracted parasitics, and it is the only
timing number worth quoting. Everything before it is an estimate.

---

## The flow, stage by stage

Innovus saves the database after every stage into `work/enc/`. If something
fails you can go back rather than start over:

```
restoreDesign enc/03_placed.enc pipelined_cpu_core
```

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

Once a run completes clean, tighten `CLK_PERIOD` and rerun until it fails. The
last value that passed post-route is the real number.

## Two assumptions to quote with any result

1. **The memory interface budget is invented.** The SDC gives 30% of a cycle
   for the memory to answer and 30% for setup at its input. Those are
   assumptions, not measurements, and the timing result moves if they change.
2. **Nangate45 has no foundry behind it.** This flow produces a complete
   layout, not a fabricated chip. Saying so unprompted reads as rigour.
