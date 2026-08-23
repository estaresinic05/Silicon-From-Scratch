# Silicon From Scratch

![Silicon From Scratch](single-cycle-cpu/docs/logo.jpg)

> An open, hands-on way to learn how processors are *actually* built — from a single logic gate to a verified five-stage RISC-V pipeline, and from that pipeline down to a routed 45 nm layout.

---

<p align="center"><em>You don't learn to ride a bike by reading about it; you strap on your helmet and push off, finding your balance as you go, with hope that your leap into the unknown will take you to somewhere you couldn't have reached standing still.</em></p>

---

## What This Is

**Silicon From Scratch** teaches how the processors inside modern devices are designed, verified, and built — for people who would rather build one than read about one.

Most material on computer architecture asks you to accept a block diagram and move on. This does the opposite. Every design here is real Verilog you can clone, simulate, and take apart; every claim about it has a testbench behind it; and every performance number was measured rather than estimated. Where a diagram would normally be the end of the explanation, here it is the thing you go and build. The last design does not stop at Verilog either: it is placed, routed and timed until it is a layout with a frequency on it.

The whole approach rests on one idea: **dive in.** You do not need a degree, an expensive software licence, or anyone's permission. Every core design in this repository simulates on your own machine with free, open-source tools, and the written material assumes you are seeing this for the first time.

## Two Halves, Meant To Be Used Together

Silicon From Scratch is a teaching site and a hardware repository, and they do different jobs.

### The site — [siliconfromscratch.com](https://siliconfromscratch.com)

A structured course that builds the ideas up one layer at a time, with the parts that are hard to picture made interactive rather than described:

- **An interactive ALU datapath explorer.** Pick an operation, or flip the four `control[3:0]` bits yourself, and the exact gates and wires carrying the result light up while everything inactive dims. The most direct way to see *why* a mux-based ALU works.
- **Meet the Processor.** A guided descent into a real AMD Ryzen 5 9600X die in seven stops, from the packaged chip down through the floorplan, a single core, the copper metal stack, the standard-cell rows, and finally one inverter. The blocks are labelled from real die annotations, and several open onto explainer videos.
- **Editable Verilog flip cards.** Write RTL in the page and watch the truth table it produces update as you type.
- **Waveforms and Check Yourself quizzes** in every lesson, so you find out whether the idea landed before you build on top of it.

**Published lessons:**

| Track | Lessons |
|---|---|
| **Beginner — ALU** | Logic Gates and the 1-bit ALU · Full Adder and Ripple Carry Adder · 32-bit ALU Slice · Complete 32-bit ALU · Testing Your ALU |
| **Intermediate — Single-Cycle CPU** | The Basics of Instructions · Fetch, Decode, Execute · Constructing a Datapath · The Control Unit · Testing Your Single-Cycle CPU |
| **Advanced — Pipelined CPU** | Pipelining · The Pipelined Datapath · The Pipelined Control · Data Hazards · Control Hazards |
| **Advanced — Physical Design** | Transistor Basics · Implementing Arbitrary Logic and Stick Diagrams |

### This repository — the designs themselves

The working hardware the lessons are teaching you to build. Clone it, run it, break it, and read the verification that proves it works.

**Use the site to understand an idea; use the repo to build the thing.**

## Who It's For

Students, hobbyists, career-switchers, tinkerers, and the merely curious — young or old. If you have ever wondered how a sliver of sand ends up running your code, this is for you. No prior chip-design experience is assumed, and the projects are ordered so that each one needs only what came before it.

## Start Here

Work through these top to bottom.

| Project | Level | Status | What you'll build and learn |
|---------|-------|--------|-----------------------------|
| [**ALU**](./ALU/) | Beginner — start here | Complete | A parameterized N-bit ripple-carry ALU (slice + MSB) supporting AND, OR, ADD, SUB, SLT, NOR and NAND. The single best place to understand how arithmetic and logic are actually done in hardware. Verified against a behavioral oracle. |
| [**Single-Cycle CPU**](./single-cycle-cpu/) | Intermediate | Complete | A full RV32I single-cycle Harvard processor — datapath, control, register file and memory working together to run real RISC-V programs. Verified against a lockstep golden model *and* a hand-derived final-state oracle. |
| [**Pipelined CPU**](./pipelined-cpu/) | Advanced | Complete | A five-stage RV32I pipeline with full forwarding, load-use and branch interlocks, and branch resolution in ID. The leap from "it works" to "it works *fast*". Verified against three independent oracles. |
| [**Pipelined CPU — Physical Design**](./pipelined-cpu-physical-design/) | Advanced | Complete | The same pipeline carried from RTL to a routed, DRC-clean layout on the Nangate 45 nm library with Cadence Genus and Innovus. Closes at 4.00 ns, 250 MHz at the slow signoff corner, proven logically equivalent to the RTL and simulated on the routed netlist. |

<table>
  <tr>
    <td width="33.33%" valign="top" align="center">
      <a href="ALU/docs/slice-architecture.jpg"><img src="ALU/docs/slice-architecture.jpg" alt="ALU slice architecture" width="100%"></a>
      <br><sub><b>ALU</b><br>One bit slice of the ripple-carry ALU</sub>
    </td>
    <td width="33.33%" valign="top" align="center">
      <a href="single-cycle-cpu/docs/sc-cpu-architecture.jpg"><img src="single-cycle-cpu/docs/sc-cpu-architecture.jpg" alt="Single-cycle CPU architecture" width="100%"></a>
      <br><sub><b>Single-Cycle CPU</b><br>One instruction per clock, start to finish</sub>
    </td>
    <td width="33.33%" valign="top" align="center">
      <a href="pipelined-cpu/docs/pipelined-cpu-architecture.jpg"><img src="pipelined-cpu/docs/pipelined-cpu-architecture.jpg" alt="Pipelined CPU architecture" width="100%"></a>
      <br><sub><b>Pipelined CPU</b><br>Five stages in flight at once, with forwarding and interlocks</sub>
    </td>
  </tr>
</table>

Each design ships a written **design verification report** ([single-cycle](./single-cycle-cpu/docs/design-verification-report.pdf), [pipelined](./pipelined-cpu/docs/design-verification-report.pdf)) covering methodology, a per-instruction execution trace, a functional coverage matrix, and the open issues. The layout ships its own **physical design report**, generated from the run that produced it. Those reports are the part of the flow that most learning material skips, and they are where "I think it works" becomes "here is why it works".

## What You'll Find in Each Project

Every design is meant to be opened up and understood, not just run:

- **RTL** — synthesizable Verilog/SystemVerilog for the datapath, control unit, register file, ALU and memory subsystem. The design itself.
- **Testbenches** — self-checking verification environments, including lockstep comparison against an independent reference simulator and hand-derived final-state oracles. This is how you *prove* a design is correct instead of hoping. The pipelined CPU is held to the single-cycle design's expected-state table unchanged, so both processors are checked to end in the same architectural state, register for register and memory word for memory word.
- **Waveforms** — VCD dumps and traces that let you watch the design behave cycle by cycle. Where the abstract becomes concrete.
- **Programs** — RISC-V machine-code test programs exercising arithmetic, logic, memory and control flow. What the CPU actually runs.
- **Design verification reports** — the full written argument for correctness, per CPU.

The physical design project adds the layers below the RTL: the synthesis and place-and-route scripts, the SDC constraints, the committed timing, area, power and DRC reports for the run that shipped, and a gate-level testbench that runs the same program on the routed netlist with back-annotated delays.

## From RTL to Layout

The pipelined CPU does not stop at a netlist. [`pipelined-cpu-physical-design/`](./pipelined-cpu-physical-design/) carries the same RTL through a full digital implementation flow — Cadence Genus for synthesis, Innovus for floorplanning, placement, clock tree synthesis, routing and static timing — and ends in a routed, DRC-clean layout on the Nangate 45 nm open cell library.

This is the part of chip design that block diagrams cannot show you. A netlist has no size, no distance and no clock skew; a layout has all three, and every one of them costs time. Watching the same design give back to wire delay what synthesis said it had won is the fastest way to understand why physical design is its own discipline.

<table>
  <tr>
    <td width="50%" valign="top" align="center">
      <a href="pipelined-cpu-physical-design/docs/images/die-routed.png"><img src="pipelined-cpu-physical-design/docs/images/die-routed.png" alt="The routed die" width="100%"></a>
      <br><sub><b>The routed die</b><br>156 × 156 µm, 97 standard cell rows, five power stripes over a metal8/metal9 ring</sub>
    </td>
    <td width="50%" valign="top" align="center">
      <a href="pipelined-cpu-physical-design/docs/images/die-zoom.png"><img src="pipelined-cpu-physical-design/docs/images/die-zoom.png" alt="Standard cells at the routing level" width="100%"></a>
      <br><sub><b>Inside the cell rows</b><br>A 10 µm window: metal1 power rails in blue, signal routing above them, vias as small crossed squares</sub>
    </td>
  </tr>
</table>

<p align="center">
  <a href="pipelined-cpu-physical-design/docs/images/die-critical-path.png"><img src="pipelined-cpu-physical-design/docs/images/die-critical-path.png" alt="The critical path" width="100%"></a>
  <br><sub><b>The critical path</b>, +0.014 ns, highlighted in yellow. It leaves <code>IFID_instr_reg[5]</code>, crosses the immediate generator, and then walks the carry chain of the 32-bit ripple-carry adder that computes the branch target. Sixty of its seventy-three instances are that carry chain, which is why the placer draws it as a column hard against the right edge: a ripple carry is linear, so its layout is a line.</sub>
</p>

### The shipped design

| | |
|---|---|
| Clock period | **4.00 ns, 250 MHz** |
| Signoff corner | SS, 0.95 V, 125 °C |
| Setup WNS | +0.014 ns, 0 violations |
| Hold WNS | +0.026 ns at the fast corner, 0 violations |
| Standard cells | 5,319, of which 1,347 are flops |
| Core area | 18,448 µm² at 73.9 % density |
| Total wirelength | 86,521 µm |

Timing is reported at all three corners out of a single routed database, because a frequency with no corner attached to it is not a claim about anything:

| Corner | Setup WNS | Hold WNS | Violations |
|---|---|---|---|
| Slow, SS 0.95 V 125 °C | +0.014 ns | +0.211 ns | 0 |
| Typical | +2.229 ns | +0.056 ns | 0 |
| Fast, FF 1.25 V −40 °C | +2.401 ns | +0.026 ns | 0 |

### How it is proven

A layout nobody has checked is a picture. This one carries:

- **DRC and connectivity** — clean, from `verify_drc` and `verify_connectivity -error 0 -geom_connect`.
- **Logic equivalence** — 1,515 key points equivalent against the RTL in Conformal LEC. The two unmapped points are both PC bit 0, which is constant zero on word-aligned fetches and so is removed by synthesis.
- **Gate-level simulation** — the routed netlist runs the test program and reproduces every architectural register write, at zero delay and at typ, slow and fast SDF. Pass, 0 errors.
- **Repeatability** — 4 of 4 closures at this configuration, mean +5 ps, sigma 6 ps. One lucky run is not a result.

The flow also states what it does *not* do, and why each one is impossible rather than merely skipped. Antenna checking has nothing to check against, because the Nangate 45 LEF carries no antenna properties. LVS and signoff DRC need Pegasus, and an independent signoff timer would need Tempus, neither of which is available here. Recovery and removal checks are waived by a false path from the reset port, and the cost of that waiver, 1,349 untested checks, is written down rather than hidden. IR drop with Voltus and scan insertion are still open. The full account, including the on-chip-variation work, is in [the project's own README](./pipelined-cpu-physical-design/README.md), and the written report is in [`docs/`](./pipelined-cpu-physical-design/docs/).

**Every frequency here is qualified by its corner and its derate.** The design is signed off with derates at 1.0. The same netlist re-judged with 5 % on-chip variation gives −0.237 ns, a measured cost of 251 ps, roughly 220 ps of which is the data path slowing down and the rest the clock skew reversing sign.

### Running it

The whole flow is one script. From `pipelined-cpu-physical-design/`:

```sh
./run.sh --period 4.0 --util 0.71 --target-slack 0.06 --artifacts \
         --name signoff-250mhz
```

That is the exact configuration the shipped design was built with. It needs Genus and Innovus on `PATH` and a Nangate 45 enablement, and preflight names anything missing in a second rather than part way through synthesis. The reports for the shipped run are committed under `results/`, because a number whose report is not in the repository is a number nobody can check.

## Tools

The core RTL projects run on **free, open-source tools** — no licences, no cost:

- **Icarus Verilog** — RTL simulation
- **GTKWave / EPWave** — waveform inspection
- **yosys + abc**, with the Nangate45 library — synthesis and critical-path measurement

The physical-design track uses the **Cadence suite** — Genus for synthesis, Innovus for place and route and static timing, Conformal LEC for equivalence checking, and Xcelium for gate-level simulation, against the free Nangate 45 nm open cell library. That is the professional toolchain, and it is useful to know it exists — but you need none of it to start, and none of it to learn the fundamentals. Everything above the layout was done with the open-source tools.

## Roadmap

Actively growing. Planned:

- **More interactive lessons** on the site, working down toward the physical layers.
- **IR drop analysis** with Voltus, which is the one signoff check the layout is still missing.
- **DFT and scan insertion**, so the design is testable as well as correct.
- **Transistor-level simulation** — verifying timing and behavior below the RTL abstraction.
- **Full-custom layout** — schematic capture and hand-drawn cells in Virtuoso, underneath the standard-cell flow the pipeline uses.
- **A longer test program** — enough instructions to exercise the upper register file, the data memory boundaries, and forwarding priority between EX/MEM and MEM/WB.

## Contributing & Collaborating

This started as one person's exploration, and the goal is for it to be useful to others. If something is confusing, if you find a bug, or if you can explain a piece of it better, issues and contributions are welcome. A lesson that reads clearly to someone new is worth as much here as a fix to the RTL.

## License

The **designs and tooling** are MIT licensed, see [`LICENSE`](LICENSE): every
`rtl/`, `sim/`, `scripts/` and `results/` directory is yours to clone, modify
and build on. The **reports, READMEs, figures, logos and the Silicon From
Scratch name** are all rights reserved, see
[`LICENSE-CONTENT.md`](LICENSE-CONTENT.md).

## About

I built these designs to deepen my own understanding of computer architecture and the full digital design flow, from a line of Verilog to a physical layout. Along the way it became clear the material could help anyone else curious about the field, which is what the site is for.

*Recruiters and collaborators: this doubles as a portfolio of that work — the verification reports and the physical design report above are the best places to start.*
