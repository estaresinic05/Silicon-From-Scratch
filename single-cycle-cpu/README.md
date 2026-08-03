# Single-Cycle RISC-V CPU

A fully functional, single-cycle RV32I processor implemented in Verilog. Every stage of the classical datapath — fetch, decode, execute, memory, and write-back — completes within a single clock cycle. The design is verified by a self-checking testbench that runs a 30-instruction program and independently validates the result against a hand-derived oracle.

---

## Architecture

The processor follows a **Harvard architecture** with separate instruction and data memories. Control logic is purely combinational — no finite state machine is required in a single-cycle design. The datapath and control unit are connected through a dedicated ALU control unit that decodes `funct3` and `funct7` fields to generate the final 4-bit ALU operation signal.

### System Architecture Diagram

![Single-Cycle CPU Architecture](docs/sc-cpu-architecture.jpg)

### Supported Instructions

| Format | Instructions |
|--------|-------------|
| R-type | `add`, `sub`, `and`, `or`, `slt` |
| I-type | `addi`, `andi`, `ori`, `slti`, `lw` |
| S-type | `sw` |
| SB-type | `beq`, `bne`, `blt` |

---

## Module Hierarchy

```
sc_cpu_top_level
├── sc_cpu_control          Main control unit (combinational, opcode-decoded)
├── alu_control             ALU control unit (funct3/funct7 decode)
└── sc_cpu_datapath
    ├── instruct_mem        Read-only instruction memory (loaded from program.mem)
    ├── imm_gen             Immediate generator (I, S, SB, U, UJ formats)
    ├── reg_file            32x32-bit register file (2 read ports, 1 write port)
    ├── mux_2x1             ALU source mux; write-back mux; branch/increment mux (×3)
    ├── alu_full            32-bit ALU (ripple-carry, parameterized)
    │   ├── alu_slice       1-bit ALU slice (bits [30:0])
    │   │   ├── mux_2x1     Output select (ALU result vs. pass-through)
    │   │   ├── mux_4x1     Operation select (add/sub, and, or, slt)
    │   │   └── full_adder  1-bit full adder
    │   └── alu_msb         MSB ALU slice (overflow detection, setLess)
    │       ├── mux_2x1     Output select (ALU result vs. pass-through)
    │       ├── mux_4x1     Operation select (add/sub, and, or, slt)
    │       └── full_adder  1-bit full adder (MSB, feeds overflow logic)
    ├── data_mem            Clocked data memory (word-aligned, read/write enable)
    └── ripple_carry_adder  PC + 4 adder; PC + immediate adder (×2)
```

### Key Design Decisions

**Ripple-carry adder for PC arithmetic.** The PC increment and branch target computation use the same parameterized ripple-carry adder module rather than a behavioral `+` operator, keeping the implementation fully structural at the arithmetic level.

**ALU built from 1-bit slices.** `alu_full` instantiates 31 identical `alu_slice` modules and one `alu_msb` module via `generate`. Each slice supports AND, OR, addition, and set-less-than (SLT). The MSB slice additionally detects signed overflow and drives the `setLess` signal back to bit 0.

**3-bit one-hot branch encoding.** The control unit outputs `branch[2:0]` as a one-hot signal — `100` for BEQ, `010` for BNE, `001` for BLT — rather than a single branch enable. The datapath combines this with the ALU `zero` and `lessThan` flags to select the correct next PC in a single combinational expression.

**x0 hardwired to zero.** Both the register file and the golden reference model enforce that reads from register x0 always return zero and writes to x0 are silently discarded, consistent with the RISC-V specification.

**`dbg_*` observability outputs.** The top level exposes `dbg_pc`, `dbg_wb_addr`, `dbg_wb_data` and `dbg_wb_enable`. They have no functional role and the testbench does not read them. They exist because a module whose only ports are `clk` and `reset` has no primary outputs, so every net is unreachable and synthesis dead-code elimination deletes the entire CPU.

---

## File Structure

```
single-cycle-cpu/
├── Makefile
├── README.md
├── rtl/
│   ├── sc_cpu_top_level.v      Top-level module (control + datapath + ALU CU)
│   ├── sc_cpu_datapath.v       Full datapath
│   ├── sc_cpu_control.v        Main control unit
│   ├── alu_control.v           ALU control unit
│   ├── alu_full.v              32-bit parameterized ALU
│   ├── alu_msb.v               MSB ALU slice (overflow, setLess)
│   ├── alu_slice.v             1-bit ALU slice
│   ├── full_adder.v            1-bit full adder
│   ├── ripple_carry_adder.v    N-bit ripple carry adder
│   ├── reg_file.v              32x32-bit register file
│   ├── imm_gen.v               Immediate generator
│   ├── instruct_mem.v          Read-only instruction memory
│   ├── data_mem.v              Clocked data memory
│   ├── mux_2x1.v               2x1 multiplexer
│   └── mux_4x1.v               4x1 multiplexer
├── testbench/
│   └── tb_sc_cpu_top_level.v   Self-checking lockstep testbench
├── programs/
│   ├── program.mem             30-instruction RV32I test program (hex)
│   └── program_mem.txt         Same program, annotated with disassembly
├── waveforms/
│   ├── dump.vcd                Simulation waveform dump
│   └── waveform.jpg            Simulation waveform screenshot
└── docs/
    ├── sc-cpu-architecture.jpg     Hand-drawn system architecture diagram
    └── design-verification-report  Full verification report (.docx and .pdf)
```

---

## Test Program

The 30-instruction test program exercises the full supported instruction set including arithmetic, logic, memory access, and all three branch types. Every branch is tested in both the taken and not-taken direction, a three-iteration backward-branch loop produces 34 retired instructions from 30 words, and `x0` write suppression is checked from both instruction formats.

The image is shared byte for byte with the pipelined implementation of the same ISA subset, so both designs are verified on identical work and their results can be compared directly. It is generated by `../pipelined-cpu/programs/build_program.py`, which writes both copies from one source — edit the generator, not `program.mem`.

```
00500093    addi  x1,  x0,  5
FFD00113    addi  x2,  x0,  -3
001101B3    add   x3,  x2,  x1
40308233    sub   x4,  x1,  x3
001172B3    and   x5,  x2,  x1
00416333    or    x6,  x2,  x4
001123B3    slt   x7,  x2,  x1
FFF0A413    slti  x8,  x1,  -1
0030F493    andi  x9,  x1,  3
0080E513    ori   x10, x1,  8
04000593    addi  x11, x0,  64
00A5A023    sw    x10, 0(x11)
0005A603    lw    x12, 0(x11)
001606B3    add   x13, x12, x1
00D5A223    sw    x13, 4(x11)
0045A703    lw    x14, 4(x11)
00D70463    beq   x14, x13, 8
06300093    addi  x1,  x0,  99
00400793    addi  x15, x0,  4
00900813    addi  x16, x0,  9
0107C463    blt   x15, x16, 8
06300113    addi  x2,  x0,  99
00F84463    blt   x16, x15, 8
00F80463    beq   x16, x15, 8
00300893    addi  x17, x0,  3
01190933    add   x18, x18, x17
FFF88893    addi  x17, x17, -1
FE089CE3    bne   x17, x0,  -8
07B00013    addi  x0,  x0,  123
00208033    add   x0,  x1,  x2
```

The two `addi x1/x2, x0, 99` instructions are never executed — the taken branches above them skip past. They target `x1` and `x2` deliberately, so if branch behaviour ever regressed the expected final state below would fail loudly.

### Expected Final State

| Register | Value | Notes |
|----------|-------|-------|
| x1  | `0x00000005` | Not 99 — the branch skipped that write |
| x2  | `0xFFFFFFFD` | Signed -3, and not 99 for the same reason |
| x3  | `0x00000002` | |
| x4  | `0x00000003` | |
| x5  | `0x00000005` | `and` with a negative operand |
| x6  | `0xFFFFFFFF` | Signed -1 |
| x7  | `0x00000001` | Signed compare, -3 < 5 |
| x9  | `0x00000001` | |
| x10 | `0x0000000D` | |
| x11 | `0x00000040` | Data memory base address |
| x12 | `0x0000000D` | Loaded back from `dmem[16]` |
| x13 | `0x00000012` | |
| x14 | `0x00000012` | Loaded back from `dmem[17]` |
| x15 | `0x00000004` | |
| x16 | `0x00000009` | |
| x18 | `0x00000006` | Loop sum, 3 + 2 + 1 |

`x8` and `x17` both end at zero: `slti x8, x1, -1` is false, and `x17` is the loop counter decremented to zero.

| Memory Word | Byte Address | Value |
|-------------|-------------|-------|
| dmem[16] | 64 | `0x0000000D` |
| dmem[17] | 68 | `0x00000012` |

---

## Verification

The testbench uses two independent verification strategies running simultaneously:

**Lockstep golden model.** A behavioral RV32I simulator executes one instruction ahead of each DUT clock edge. After every committed instruction the complete register file, data memory, and program counter are compared against the DUT via hierarchical references. Any mismatch is reported immediately with the step number, signal name, DUT value, and reference value.

**Final-state oracle.** An independently hand-derived table of expected end-of-program register and memory contents is checked once at completion. This catches any latent bug in the golden model itself — two independent methods must agree on the same answer.

The testbench also produces a per-instruction execution trace:

```
 [ 1]  PC=0x00000000  instr=0x00500093  | addi x1, x0, 5       | x1 <= 0x00000005 (5)
 [ 2]  PC=0x00000004  instr=0xffd00113  | addi x2, x0, -3      | x2 <= 0xfffffffd (-3)
 ...
```

**Execution summary.** After the final check the testbench prints retired instructions, clock cycles and cycles per retire, in the same format the pipelined testbench uses so the two can be read side by side. A single-cycle CPU retires one instruction per clock and cannot stall or flush, so its figure is 1.00 by construction rather than by merit.

### Running the Simulation

**Option 1 — Makefile (recommended)**

From the `single-cycle-cpu/` root:

```bash
make        # compile only
make run    # compile and run
```

> Requires `make` to be installed. On Windows: `winget install GnuWin32.Make`

**Option 2 — Manual compile**

```bash
# Linux / Mac
iverilog -g2012 -o sim \
  testbench/tb_sc_cpu_top_level.v \
  rtl/sc_cpu_top_level.v \
  rtl/sc_cpu_datapath.v \
  rtl/sc_cpu_control.v \
  rtl/alu_control.v \
  rtl/alu_full.v \
  rtl/alu_msb.v \
  rtl/alu_slice.v \
  rtl/full_adder.v \
  rtl/ripple_carry_adder.v \
  rtl/reg_file.v \
  rtl/imm_gen.v \
  rtl/instruct_mem.v \
  rtl/data_mem.v \
  rtl/mux_2x1.v \
  rtl/mux_4x1.v

# Windows (PowerShell) — single line
iverilog -g2012 -o sim testbench/tb_sc_cpu_top_level.v rtl/sc_cpu_top_level.v rtl/sc_cpu_datapath.v rtl/sc_cpu_control.v rtl/alu_control.v rtl/alu_full.v rtl/alu_msb.v rtl/alu_slice.v rtl/full_adder.v rtl/ripple_carry_adder.v rtl/reg_file.v rtl/imm_gen.v rtl/instruct_mem.v rtl/data_mem.v rtl/mux_2x1.v rtl/mux_4x1.v

# Run
vvp sim
```

**View waveforms**

```bash
gtkwave waveforms/dump.vcd
```

A passing run produces:

```
==================================================
 RESULT: PASS - 0 errors. DUT == reference == oracle.
==================================================
```

### Waveform

![Simulation Waveform](waveforms/waveform.jpg)

---

## Tools

| Tool | Purpose |
|------|---------|
| Icarus Verilog 12.0 | RTL simulation |
| GTKWave / EPWave | Waveform inspection |
| GNU Make | Build automation |

---

*Part of the [RISC-V CPU Design](../README.md) repository.*
