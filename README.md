# Silicon From Scratch

A centralized collection of RISC-V processor designs and fundamental building blocks of digital design built from the ground up, documenting my summer of CPU architecture and VLSI design exploration. This repository brings together every stage of the hardware design flow — from register-transfer level (RTL) description, verification, and extending toward physical implementation. You don't learn to ride a bike by reading about it; you strap on your helmet and push off, finding your balance as you go, with hope that your leap into the unknown will take you to somewhere you couldn't have reached standing still.

## Contents

| Component | Status | Description |
|-----------|--------|-------------|
| [Single-Cycle CPU](./single-cycle-cpu/) | Complete | RV32I single-cycle Harvard architecture, verified against a lockstep golden model and hand-derived final-state oracle |
| [Pipelined CPU](./pipelined-cpu/) | Complete | Five-stage RV32I pipeline with full forwarding, load-use and branch interlocks, and branch resolution in ID; verified against three independent oracles |
| [ALU](./ALU/) | Complete | Parameterized N-bit ripple-carry ALU (slice + MSB), supporting AND, OR, ADD, SUB, SLT, NOR, and NAND; verified against a behavioral oracle |

## What's Inside

Each subdirectory contains either a self-contained CPU design implementing the RV32I instruction set (or a working subset), or a key building block to understanding digital design. Designs progress in complexity and microarchitectural sophistication. For every design you'll find:

- **RTL** — synthesizable Verilog/SystemVerilog source for the datapath, control unit, register file, ALU, and memory subsystem.
- **Testbenches** — self-checking verification environments, including lockstep golden-model comparison against independent reference simulators and hand-derived final-state oracles.
- **Waveforms** — VCD dumps and simulation traces capturing cycle-by-cycle architectural behavior.
- **Programs** — RISC-V machine-code test programs exercising arithmetic, logic, memory, and control-flow instructions.
- **Design verification reports** — a full written report per CPU, covering methodology, per-instruction execution trace, functional coverage matrix, and open issues.

## The Two CPUs, Compared

The two processors implement the same instruction subset and run the **same program image, byte for byte** — one generator writes both copies, so they cannot drift apart. That makes them directly comparable, and it makes the comparison the most interesting thing in the repository.

Both were synthesized to Nangate45 45 nm standard cells with yosys, with abc measuring the longest register-to-register path against an identical driver and load. The memories are blackboxed and their access time is the only estimated input.

|  | Single-cycle | Pipelined |
|---|---|---|
| Clock period | 3473 ps | **1813 ps** |
| Maximum frequency | 288 MHz | **552 MHz** |
| Cell area | 10651 µm² | 14153 µm² (+33%) |
| Cycles for the program | 34 | 48 |
| **Runtime** | 118.1 ns | **87.0 ns** |

A pipeline does not execute fewer instructions, and on a short program it does not even execute them in fewer cycles — it takes 14 more. It executes them in *shorter* cycles, and it has to win by enough on the clock to pay for the cycles it added. How much it needs is arithmetic: 48 / 34, or **1.41x**. It got **1.92x**, so the same program finishes **1.36x faster** for a third more silicon.

The margin comes from where the memories sit. The single-cycle critical path crosses **both** memories inside one clock; no pipeline stage crosses more than one.

Both architectural end states are identical, register for register and memory word for memory word. That is the property pipelining has to preserve, and the pipelined testbench checks it against the single-cycle design's expected-state table unchanged.

The synthesis and timing flow lives in `sta/`, and each CPU's verification report documents what it does and does not model.

## Roadmap

This repository is actively growing. Planned additions include:

- **Physical design** — schematic capture, layout, and full-custom flows using the Cadence toolchain (Virtuoso, Spectre).
- **Transistor-level simulation** — verifying timing and functional behavior beyond the RTL abstraction.
- **Clock-aware static timing** — the current flow measures the longest logic path. Wire delay, clock skew, and the half-cycle write-back path created by the pipelined register file's negative-edge write need a real STA tool.
- **A longer test program** — enough instructions to exercise the upper register file, the data memory boundaries, and forwarding priority between EX/MEM and MEM/WB.

## Tools

Icarus Verilog for RTL simulation, GTKWave/EPWave for waveform inspection, yosys and abc with the Nangate45 library for synthesis and critical-path measurement, and the Cadence suite for analog/mixed-signal and physical design.

## About

I built these projects to deepen my understanding of computer architecture and the complete digital design flow — from a line of Verilog to a physical layout. This repository serves as a portfolio of that work, intended to be easy for recruiters and collaborators to navigate.
