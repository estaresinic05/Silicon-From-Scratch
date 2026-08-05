#*******************************************************
# Project:        RISC-V CPU Design
# Module:         Makefile
# Author:         Elliot Staresinic
# Date:           2026-08-02
#
# Description:
#   This Makefile compiles the Pipelined CPU hierarchy
#   into a file called 'sim', which can be ran by issuing
#   the command 'vvp sim'. Alternatively, issuing the
#   command 'make run' will compile and run the program.
#   In order to view the output waveform, the command
#   'gtkwave waveforms/dump.vcd' must be issued.
#
#   'make lint' elaborates the design and FAILS on any
#   implicit net. See the note at the bottom of this file
#   for why that check matters more here than it looks.
#
#*******************************************************

SIM  = sim
STD  = -g2012
TOP  = pipelined_cpu_top_level

TB   = testbench/tb_pipelined_cpu_top_level.v

SRCS = rtl/pipelined_cpu_top_level.v \
       rtl/pipelined_cpu_datapath.v \
       rtl/pipelined_cpu_control.v \
       rtl/hzrd_detection_unit.v \
       rtl/alu_fwd_unit.v \
       rtl/branch_fwd_unit.v \
       rtl/branch_comp.v \
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

# ---- remove command ----------------------------------------
# Deliberately NOT switched on $(OS). GNU Make runs recipes through sh when
# one is on PATH, which it is here via Git Bash / MSYS, so recipes get Unix
# commands even though OS reports Windows_NT. Selecting `del` on Windows makes
# every recipe that removes a file fail with "del: command not found".
RM = rm -f

# ---- default target (compile only) -------------------------
all: $(SIM)

$(SIM): $(TB) $(SRCS)
	iverilog $(STD) -o $(SIM) $(TB) $(SRCS)

# ---- run ---------------------------------------------------
run: $(SIM)
	vvp $(SIM)

# ---- lint: elaborate the RTL and reject implicit nets -------
# iverilog reports an implicit net as a WARNING and still exits 0, so the
# warning has to be promoted to a failure by hand. Without this the build is
# green while a typo silently truncates a 32-bit bus to one bit.
lint:
	@iverilog $(STD) -Wall -o /dev/null -s $(TOP) $(SRCS) 2> lint.log; \
	status=$$?; \
	cat lint.log; \
	if grep -q "implicit definition" lint.log; then \
	    echo ""; \
	    echo "LINT FAILED: implicit net(s) above. Every one is a typo or a"; \
	    echo "missing declaration, and each is silently ONE BIT WIDE."; \
	    $(RM) lint.log; \
	    exit 1; \
	fi; \
	$(RM) lint.log; \
	if [ $$status -ne 0 ]; then exit $$status; fi; \
	echo "lint clean: no implicit nets, no elaboration errors"

# ---- clean -------------------------------------------------
clean:
	$(RM) $(SIM) lint.log dump.vcd

.PHONY: all run lint clean

#*******************************************************
# Why 'make lint' exists
#
#   Verilog silently creates a one-bit wire for any
#   identifier that was never declared. A mistyped signal
#   name therefore compiles, simulates, and quietly
#   discards every bit above bit 0 of a 32-bit bus. There
#   is no error and, by default, no warning either.
#
#   Two ways to catch it. The language has a
#   `default_nettype none directive that turns undeclared
#   identifiers into hard errors, but it must be repeated
#   in every file and left switched off at the end of each
#   one, which is easy to get wrong.
#
#   This project uses the other way: leave the RTL clean
#   and let the build enforce it. -Wall makes iverilog
#   report each implicit net, and the recipe above turns
#   any such report into a failed build.
#
#   Run 'make lint' before every commit.
#*******************************************************
