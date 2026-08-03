/********************************************************************************
 * Project:        RISC-V CPU Design
 * Module:         Pipelined CPU Testbench
 * Author:         Elliot Staresinic
 * Date:           2026-08-02
 * Target:         Icarus Verilog (iverilog -g2012)
 *
 * Purpose:
 *   Self-checking, top-level integration testbench for
 *   pipelined_cpu_top_level, exercising the 30-instruction program in
 *   program.mem.
 *
 * Verification strategy (three independent oracles):
 *   1. LOCKSTEP GOLDEN MODEL - a behavioral RV32I-subset simulator that
 *      encodes the CORRECT architectural semantics. It is stepped once per
 *      RETIREMENT rather than once per clock, and after every retirement the
 *      full register file and full data memory are compared against the DUT
 *      via hierarchical references.
 *   2. RETIREMENT ORDER - the PC of the instruction leaving MEM/WB is
 *      compared against the PC the golden model just executed. This is the
 *      check that a pipeline needs and a single-cycle CPU does not: it is
 *      what catches a missing branch flush, a lost stall, or an instruction
 *      committing twice.
 *   3. FINAL-STATE ORACLE - an independently hand-derived table of the
 *      expected end-of-program register and memory contents, checked once at
 *      completion. This guards against a latent bug in the lockstep model
 *      itself (a different method reaching the same answer). The table is
 *      unchanged from the single-cycle testbench, because pipelining must not
 *      change the architectural result.
 *
 * Why this is not the single-cycle testbench with a new DUT name:
 *   That testbench assumes one instruction commits per clock edge and that
 *   dut.datapath.pc is the PC of the instruction being committed. Neither
 *   holds here. An instruction retires four stages after it is fetched, the
 *   fetch PC runs up to four instructions ahead of the one committing, and a
 *   stall or a flush means some clock edges commit nothing at all.
 *
 *   The fix is a SHADOW PIPELINE (below): four registers that carry the PC
 *   and a valid bit alongside the DUT's own pipeline registers, clocked by
 *   exactly the same enables the RTL uses. When the shadow says a valid
 *   instruction is in MEM/WB, that instruction is committing this cycle, and
 *   the shadow knows which PC it came from.
 *
 * Sampling point:
 *   State is sampled just after the NEGEDGE of the cycle in which an
 *   instruction sits in MEM/WB. By then both of its architectural effects are
 *   visible: a store wrote data memory at the posedge that entered MEM/WB,
 *   and a register write lands at the negedge of this cycle, because the
 *   register file is deliberately write-first-half / read-second-half.
 *
 * Halt condition:
 *   The golden model halts when its PC leaves the loaded program image
 *   (word index >= NUM_INSTR). The pipeline is then drained and checked for
 *   late writes. A runaway watchdog terminates pathological non-halting runs.
 *
 *******************************************************************************/

`timescale 1ns / 1ps

module tb_pipelined_cpu_top_level;

  // ----------------------------------------------------------------------
  // Parameters / constants
  // ----------------------------------------------------------------------
  localparam integer CLK_PERIOD = 10;  // ns
  localparam integer NUM_INSTR = 30;  // instructions in program.mem
  localparam integer DMEM_WORDS = 256;
  localparam integer IMEM_WORDS = 256;
  localparam integer MAX_CYCLES = 2000;  // runaway guard
  localparam integer DRAIN_CYCLES = 8;  // clocks to flush the pipe at the end

  // RV32I opcodes (supported subset)
  localparam [6:0] OPC_LOAD = 7'b0000011;
  localparam [6:0] OPC_STORE = 7'b0100011;
  localparam [6:0] OPC_BRANCH = 7'b1100011;
  localparam [6:0] OPC_RTYPE = 7'b0110011;
  localparam [6:0] OPC_ITYPE = 7'b0010011;

  // ----------------------------------------------------------------------
  // DUT interface
  // ----------------------------------------------------------------------
  reg clk;
  reg reset;

  pipelined_cpu_top_level dut (
      .clk  (clk),
      .reset(reset)
  );

  // ----------------------------------------------------------------------
  // Reference (golden) architectural state
  // ----------------------------------------------------------------------
  reg [31:0] ref_regs[0:31];
  reg [31:0] ref_dmem[0:DMEM_WORDS-1];
  reg [31:0] ref_imem[0:IMEM_WORDS-1];
  reg [31:0] ref_pc;

  // Independent final-state oracle
  reg [31:0] exp_regs[0:31];
  reg [31:0] exp_dmem[0:DMEM_WORDS-1];

  // Drain snapshot, to prove nothing commits after the program halts
  reg [31:0] drain_regs[0:31];
  reg [31:0] drain_dmem[0:DMEM_WORDS-1];

  // Bookkeeping
  integer error_count;
  integer retire_count;
  integer cycle_count;
  integer cycles_at_halt;  // frozen before the drain, so CPI excludes it
  integer stall_cycles;
  integer flush_events;
  integer i;

  // Trace bookkeeping (set by ref_step, printed in the main loop)
  reg [31:0] tr_inst, tr_pc, tr_next_inst;
  reg tr_write_enable, tr_write_0x, tr_is_store, tr_is_branch, tr_branch_taken;
  reg [4:0] tr_dest_address;
  reg [31:0] tr_value_written, tr_mem_address, tr_value_stored;

  // ----------------------------------------------------------------------
  // Disassembler: build human-readable pseudocode for one instruction
  // ----------------------------------------------------------------------
  task disasm;
    input [31:0] inst;
    output reg [8*64-1:0] s;
    reg [6:0] opc;
    reg [4:0] rd, rs1, rs2;
    reg [2:0] f3;
    reg f7b5;
    reg signed [31:0] ii, is, ib;
    begin
      opc  = inst[6:0];
      rd   = inst[11:7];
      f3   = inst[14:12];
      rs1  = inst[19:15];
      rs2  = inst[24:20];
      f7b5 = inst[30];
      ii   = {{20{inst[31]}}, inst[31:20]};
      is   = {{20{inst[31]}}, inst[31:25], inst[11:7]};
      ib   = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
      case (opc)
        OPC_RTYPE:
        case (f3)
          3'b000:  $sformat(s, "%s  x%0d, x%0d, x%0d", f7b5 ? "sub" : "add", rd, rs1, rs2);
          3'b111:  $sformat(s, "and  x%0d, x%0d, x%0d", rd, rs1, rs2);
          3'b110:  $sformat(s, "or   x%0d, x%0d, x%0d", rd, rs1, rs2);
          3'b010:  $sformat(s, "slt  x%0d, x%0d, x%0d", rd, rs1, rs2);
          default: $sformat(s, ".word 0x%08h", inst);
        endcase
        OPC_ITYPE:
        case (f3)
          3'b000:  $sformat(s, "addi x%0d, x%0d, %0d", rd, rs1, ii);
          3'b111:  $sformat(s, "andi x%0d, x%0d, %0d", rd, rs1, ii);
          3'b110:  $sformat(s, "ori  x%0d, x%0d, %0d", rd, rs1, ii);
          3'b010:  $sformat(s, "slti x%0d, x%0d, %0d", rd, rs1, ii);
          default: $sformat(s, ".word 0x%08h", inst);
        endcase
        OPC_LOAD: $sformat(s, "lw   x%0d, %0d(x%0d)", rd, ii, rs1);
        OPC_STORE: $sformat(s, "sw   x%0d, %0d(x%0d)", rs2, is, rs1);
        OPC_BRANCH:
        case (f3)
          3'b000:  $sformat(s, "beq  x%0d, x%0d, %0d", rs1, rs2, ib);
          3'b001:  $sformat(s, "bne  x%0d, x%0d, %0d", rs1, rs2, ib);
          3'b100:  $sformat(s, "blt  x%0d, x%0d, %0d", rs1, rs2, ib);
          default: $sformat(s, ".word 0x%08h", inst);
        endcase
        default: $sformat(s, ".word 0x%08h", inst);
      endcase
    end
  endtask

  // ----------------------------------------------------------------------
  // Clock generation
  // ----------------------------------------------------------------------
  initial clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  // ----------------------------------------------------------------------
  // Waveform dump for EDA Playground EPWave
  // ----------------------------------------------------------------------
  initial begin
    $dumpfile("waveforms/dump.vcd");
    $dumpvars(0, tb_pipelined_cpu_top_level);
  end

  // ----------------------------------------------------------------------
  // Runaway watchdog
  // ----------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * (MAX_CYCLES + 50));
    $display("\n[FATAL] Global timeout reached - simulation did not terminate.");
    $display("        Retired %0d instruction(s) in %0d cycle(s).", retire_count, cycle_count);
    $finish;
  end

  // ======================================================================
  // Shadow pipeline
  //
  // Four registers carrying the PC and a valid bit alongside the DUT's own
  // pipeline registers. The enable and clear conditions below are copied
  // from pipelined_cpu_datapath.v deliberately and must stay in step with
  // it: this is the testbench's model of WHERE each instruction is, and it
  // is only trustworthy if it advances on exactly the same terms.
  //
  // valid is cleared, not merely stale, on a flush or a stall, so a bubble
  // is never mistaken for an instruction. It is also cleared for a fetch
  // past the end of the program image, because instruct_mem returns a real
  // NOP (0x00000013) for every unloaded word rather than nothing at all,
  // and those NOPs would otherwise look like instructions retiring.
  // ======================================================================
  reg [31:0] sh_ifid_pc, sh_idex_pc, sh_exmem_pc, sh_memwb_pc;
  reg sh_ifid_valid, sh_idex_valid, sh_exmem_valid, sh_memwb_valid;

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      sh_ifid_pc    <= 32'b0;
      sh_ifid_valid <= 1'b0;
    end else if (dut.IFID_flush) begin
      sh_ifid_pc    <= 32'b0;
      sh_ifid_valid <= 1'b0;
    end else if (dut.IFID_write) begin
      sh_ifid_pc    <= dut.datapath.IF_pc;
      sh_ifid_valid <= (dut.datapath.IF_pc[31:2] < NUM_INSTR);
    end
    // else: hold, matching the IF/ID stall
  end

  always @(posedge clk or posedge reset) begin
    if (reset || dut.IFID_stall || dut.IDEX_flush) begin
      sh_idex_pc    <= 32'b0;
      sh_idex_valid <= 1'b0;
    end else begin
      sh_idex_pc    <= sh_ifid_pc;
      sh_idex_valid <= sh_ifid_valid;
    end
  end

  always @(posedge clk or posedge reset) begin
    if (reset || dut.EXMEM_flush) begin
      sh_exmem_pc    <= 32'b0;
      sh_exmem_valid <= 1'b0;
    end else begin
      sh_exmem_pc    <= sh_idex_pc;
      sh_exmem_valid <= sh_idex_valid;
    end
  end

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      sh_memwb_pc    <= 32'b0;
      sh_memwb_valid <= 1'b0;
    end else begin
      sh_memwb_pc    <= sh_exmem_pc;
      sh_memwb_valid <= sh_exmem_valid;
    end
  end

  // ----------------------------------------------------------------------
  // Pipeline activity counters
  // ----------------------------------------------------------------------
  always @(posedge clk) begin
    if (!reset) begin
      cycle_count <= cycle_count + 1;
      if (dut.IFID_stall) stall_cycles <= stall_cycles + 1;
      if (dut.IFID_flush) flush_events <= flush_events + 1;
    end
  end

  // ======================================================================
  // Golden reference: decode + execute ONE instruction, update ref state
  // ======================================================================
  task ref_step;
    reg [31:0] inst;
    reg [ 6:0] opcode;
    reg [4:0] rd, rs1, rs2;
    reg [2:0] f3;
    reg       f7b5;
    reg [31:0] a, b;
    reg signed [31:0] sa, sb;
    reg [31:0] imm_i, imm_s, imm_b, addr, res;
    reg        taken;
    reg [31:0] next_pc;
    begin
      inst             = ref_imem[ref_pc[31:2]];
      opcode           = inst[6:0];
      rd               = inst[11:7];
      f3               = inst[14:12];
      rs1              = inst[19:15];
      rs2              = inst[24:20];
      f7b5             = inst[30];

      // ---- trace defaults ----
      tr_inst          = inst;
      tr_pc            = ref_pc;
      tr_write_enable  = 1'b0;
      tr_write_0x      = 1'b0;
      tr_is_store      = 1'b0;
      tr_is_branch     = 1'b0;
      tr_branch_taken  = 1'b0;
      tr_dest_address  = 5'd0;
      tr_value_written = 32'd0;
      tr_mem_address   = 32'd0;
      tr_value_stored  = 32'd0;
      tr_next_inst     = 32'd0;

      a                = (rs1 == 5'd0) ? 32'd0 : ref_regs[rs1];
      b                = (rs2 == 5'd0) ? 32'd0 : ref_regs[rs2];
      sa               = a;
      sb               = b;

      imm_i            = {{20{inst[31]}}, inst[31:20]};
      imm_s            = {{20{inst[31]}}, inst[31:25], inst[11:7]};
      imm_b            = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};

      taken            = 1'b0;
      next_pc          = ref_pc + 32'd4;
      res              = 32'd0;

      case (opcode)
        OPC_RTYPE: begin
          case (f3)
            3'b000:  res = f7b5 ? (a - b) : (a + b);  // sub / add
            3'b111:  res = a & b;  // and
            3'b110:  res = a | b;  // or
            3'b010:  res = (sa < sb) ? 32'd1 : 32'd0;  // slt
            default: res = 32'd0;
          endcase
          if (rd != 5'd0) ref_regs[rd] = res;
          tr_write_enable = (rd != 5'd0);
          tr_write_0x = (rd == 5'd0);
          tr_dest_address = rd;
          tr_value_written = res;
        end
        OPC_ITYPE: begin
          case (f3)
            3'b000:  res = a + imm_i;  // addi
            3'b111:  res = a & imm_i;  // andi
            3'b110:  res = a | imm_i;  // ori
            3'b010:  res = (sa < $signed(imm_i)) ? 32'd1 : 0;  // slti
            default: res = 32'd0;
          endcase
          if (rd != 5'd0) ref_regs[rd] = res;
          tr_write_enable = (rd != 5'd0);
          tr_write_0x = (rd == 5'd0);
          tr_dest_address = rd;
          tr_value_written = res;
        end
        OPC_LOAD: begin
          addr = a + imm_i;
          res  = ref_dmem[addr[31:2]];
          if (rd != 5'd0) ref_regs[rd] = res;
          tr_write_enable = (rd != 5'd0);
          tr_write_0x = (rd == 5'd0);
          tr_dest_address = rd;
          tr_value_written = res;
        end
        OPC_STORE: begin
          addr = a + imm_s;
          ref_dmem[addr[31:2]] = b;
          tr_is_store = 1'b1;
          tr_mem_address = addr;
          tr_value_stored = b;
        end
        OPC_BRANCH: begin
          case (f3)
            3'b000:  taken = (a == b);  // beq
            3'b001:  taken = (a != b);  // bne
            3'b100:  taken = (sa < sb);  // blt
            default: taken = 1'b0;
          endcase
          if (taken) next_pc = ref_pc + imm_b;
          tr_is_branch = 1'b1;
          tr_branch_taken = taken;
          tr_next_inst = next_pc;
        end
        default: ;  // treated as NOP
      endcase

      ref_pc = next_pc;
    end
  endtask

  // ======================================================================
  // Compare DUT architectural state against the reference
  //
  // The fetch PC is deliberately NOT compared. dut.datapath.IF_pc belongs to
  // the instruction being fetched, which is up to four ahead of the one
  // retiring. The equivalent check for a pipeline is check_retire_pc below.
  // ======================================================================
  task check_state;
    integer k;
    begin
      for (k = 0; k < 32; k = k + 1) begin
        if (dut.datapath.registers.RF[k] !== ref_regs[k]) begin
          error_count = error_count + 1;
          $display("[ERROR @ retire %0d] x%0d mismatch: DUT=0x%08h  REF=0x%08h", retire_count, k,
                   dut.datapath.registers.RF[k], ref_regs[k]);
        end
      end
      for (k = 0; k < DMEM_WORDS; k = k + 1) begin
        if (dut.datapath.data_memory.memory[k] !== ref_dmem[k]) begin
          error_count = error_count + 1;
          $display("[ERROR @ retire %0d] dmem[%0d] mismatch: DUT=0x%08h  REF=0x%08h", retire_count,
                   k, dut.datapath.data_memory.memory[k], ref_dmem[k]);
        end
      end
    end
  endtask

  // ======================================================================
  // Retirement order: did the DUT commit the instruction the model expected?
  //
  // This is the pipeline-specific oracle. A missing branch flush shows up
  // here on the very first taken branch, as the instruction behind it
  // retiring when the model has already moved to the branch target.
  // ======================================================================
  task check_retire_pc;
    input [31:0] expected_pc;
    begin
      if (sh_memwb_pc !== expected_pc) begin
        error_count = error_count + 1;
        $display("[ERROR @ retire %0d] retirement order: DUT committed PC=0x%08h, REF expected 0x%08h",
                 retire_count, sh_memwb_pc, expected_pc);
      end
    end
  endtask

  // ======================================================================
  // Per-instruction trace line
  // ======================================================================
  task trace_print;
    reg [8*64-1:0] eff;
    reg [8*64-1:0] dis;
    begin
      if (tr_write_enable)
        $sformat(
            eff,
            "x%0d <= 0x%08h (%0d)",
            tr_dest_address,
            tr_value_written,
            $signed(
                tr_value_written
            )
        );
      else if (tr_write_0x) eff = "x0 write discarded (no-op)";
      else if (tr_is_store)
        $sformat(eff, "dmem[byte %0d] <= 0x%08h", tr_mem_address, tr_value_stored);
      else if (tr_is_branch) begin
        if (tr_branch_taken) $sformat(eff, "branch TAKEN -> 0x%08h", tr_next_inst);
        else eff = "branch not taken";
      end else eff = "(no state change)";
      disasm(tr_inst, dis);
      $display(" [%2d]  cyc=%3d  PC=0x%08h  instr=0x%08h  | %-20s | %0s", retire_count, cycle_count,
               tr_pc, tr_inst, dis, eff);
    end
  endtask

  // ======================================================================
  // Drain: nothing may commit after the last instruction retires
  //
  // A single-cycle CPU cannot fail this way. A pipeline can: an instruction
  // that should have been squashed is still in flight when the program ends,
  // and writes its result a few cycles later. Snapshot, keep clocking, and
  // compare.
  // ======================================================================
  task drain_and_check;
    integer k;
    integer drain_errs;
    begin
      drain_errs = 0;
      for (k = 0; k < 32; k = k + 1) drain_regs[k] = dut.datapath.registers.RF[k];
      for (k = 0; k < DMEM_WORDS; k = k + 1) drain_dmem[k] = dut.datapath.data_memory.memory[k];

      repeat (DRAIN_CYCLES) @(posedge clk);
      #1;

      for (k = 0; k < 32; k = k + 1)
      if (dut.datapath.registers.RF[k] !== drain_regs[k]) begin
        drain_errs = drain_errs + 1;
        $display("[DRAIN ERROR] x%0d changed after halt: 0x%08h -> 0x%08h", k, drain_regs[k],
                 dut.datapath.registers.RF[k]);
      end
      for (k = 0; k < DMEM_WORDS; k = k + 1)
      if (dut.datapath.data_memory.memory[k] !== drain_dmem[k]) begin
        drain_errs = drain_errs + 1;
        $display("[DRAIN ERROR] dmem[%0d] changed after halt: 0x%08h -> 0x%08h", k, drain_dmem[k],
                 dut.datapath.data_memory.memory[k]);
      end

      if (drain_errs == 0)
        $display("[DRAIN] PASS - no architectural state changed in the %0d cycles after halt.",
                 DRAIN_CYCLES);
      else begin
        $display("[DRAIN] FAIL - %0d late write(s). An instruction committed that should not have.",
                 drain_errs);
        error_count = error_count + drain_errs;
      end
    end
  endtask

  // ======================================================================
  // Final full register-file and data-memory dump (hex)
  // ======================================================================
  task dump_final_state;
    integer k;
    begin
      $display("\n--- Final register file (hex and signed decimal) ---");
      for (k = 0; k < 32; k = k + 1)
      $display(
          "  x%-2d = 0x%08h  %11d",
          k,
          dut.datapath.registers.RF[k],
          $signed(
              dut.datapath.registers.RF[k]
          )
      );
      $display("  fetch PC = 0x%08h  (runs ahead of the last retirement)", dut.datapath.IF_pc);
      $display("\n--- Final data memory (non-zero words) ---");
      for (k = 0; k < DMEM_WORDS; k = k + 1)
      if (dut.datapath.data_memory.memory[k] !== 32'h0)
        $display("  dmem[%0d] (byte %0d) = 0x%08h", k, k * 4, dut.datapath.data_memory.memory[k]);
    end
  endtask

  // ======================================================================
  // Independent final-state oracle (hand-derived)
  //
  // Derived by hand from the assembly listing in programs/program_mem.txt and
  // cross-checked against a separate behavioural model, NOT read out of the
  // DUT. Copying a simulation result in here would turn this oracle into an
  // expensive way of asserting that the DUT equals itself.
  //
  // Two of these entries carry most of the weight. x1 and x2 are the registers
  // the two squashed instructions would have set to 99. If a branch flush ever
  // stops working, they say so.
  // ======================================================================
  task load_expected;
    integer k;
    begin
      for (k = 0; k < 32; k = k + 1) exp_regs[k] = 32'h0;
      for (k = 0; k < DMEM_WORDS; k = k + 1) exp_dmem[k] = 32'h0;
      exp_regs[1]  = 32'h00000005;  // NOT 99: instruction 17 is squashed
      exp_regs[2]  = 32'hFFFFFFFD;  // NOT 99: instruction 21 is squashed
      exp_regs[3]  = 32'h00000002;  // -3 + 5
      exp_regs[4]  = 32'h00000003;  // 5 - 2
      exp_regs[5]  = 32'h00000005;  // -3 & 5
      exp_regs[6]  = 32'hFFFFFFFF;  // -3 | 3
      exp_regs[7]  = 32'h00000001;  // -3 < 5 signed
      // x8 stays 0: 5 < -1 is false
      exp_regs[9]  = 32'h00000001;  // 5 & 3
      exp_regs[10] = 32'h0000000D;  // 5 | 8
      exp_regs[11] = 32'h00000040;
      exp_regs[12] = 32'h0000000D;
      exp_regs[13] = 32'h00000012;
      exp_regs[14] = 32'h00000012;
      exp_regs[15] = 32'h00000004;
      exp_regs[16] = 32'h00000009;
      // x17 ends at 0: the loop counter runs down
      exp_regs[18] = 32'h00000006;  // loop sum 3 + 2 + 1
      exp_dmem[16] = 32'h0000000D;
      exp_dmem[17] = 32'h00000012;
    end
  endtask

  task check_final;
    integer k;
    integer final_errs;
    begin
      final_errs = 0;
      for (k = 0; k < 32; k = k + 1)
      if (dut.datapath.registers.RF[k] !== exp_regs[k]) begin
        final_errs = final_errs + 1;
        $display("[FINAL ERROR] x%0d : DUT=0x%08h  EXPECTED=0x%08h", k,
                 dut.datapath.registers.RF[k], exp_regs[k]);
      end
      for (k = 0; k < DMEM_WORDS; k = k + 1)
      if (dut.datapath.data_memory.memory[k] !== exp_dmem[k]) begin
        final_errs = final_errs + 1;
        $display("[FINAL ERROR] dmem[%0d] : DUT=0x%08h  EXPECTED=0x%08h", k,
                 dut.datapath.data_memory.memory[k], exp_dmem[k]);
      end
      if (final_errs == 0)
        $display("[FINAL ORACLE] PASS - end-of-program state matches hand-derived table.");
      else begin
        $display("[FINAL ORACLE] FAIL - %0d mismatch(es).", final_errs);
        error_count = error_count + final_errs;
      end
    end
  endtask

  // ======================================================================
  // Pipeline efficiency summary
  // ======================================================================
  task report_pipeline_stats;
    begin
      $display("\n--- Pipeline behaviour ---");
      $display("  instructions retired : %0d", retire_count);
      $display("  clock cycles to halt : %0d", cycles_at_halt);
      $display("  stall cycles         : %0d", stall_cycles);
      $display("  IF/ID flushes        : %0d", flush_events);
      if (retire_count > 0)
        $display("  cycles per retire    : %0d.%02d", cycles_at_halt / retire_count,
                 ((cycles_at_halt * 100) / retire_count) % 100);
      if (stall_cycles == 0)
        $display(
            "  NOTE: this program never stalled. Load-use hazards are untested until program.mem grows a case that forces one.");
    end
  endtask

  // ======================================================================
  // Main test sequence
  // ======================================================================
  initial begin
    error_count    = 0;
    retire_count   = 0;
    cycle_count    = 0;
    cycles_at_halt = 0;
    stall_cycles   = 0;
    flush_events   = 0;

    // Mirror the program image into the reference instruction memory
    $readmemh("programs/program.mem", ref_imem);
    for (i = 0; i < 32; i = i + 1) ref_regs[i] = 32'h0;
    for (i = 0; i < DMEM_WORDS; i = i + 1) ref_dmem[i] = 32'h0;
    ref_pc = 32'h0;
    load_expected;

    // Reset sequence
    reset = 1'b1;
    @(negedge clk);
    @(negedge clk);
    reset = 1'b0;

    $display("\n==================================================");
    $display(" RISC-V pipelined CPU - Lockstep Integration TB");
    $display(" Program: %0d instructions", NUM_INSTR);
    $display("==================================================");

    // ------------------------------------------------------------------
    // Retirement-driven execution loop
    //
    // One iteration per CLOCK, not per instruction. The golden model is
    // stepped only on the cycles the DUT actually commits something, so
    // stalls and squashed instructions cost cycles here exactly as they do
    // in the hardware.
    // ------------------------------------------------------------------
    $display("\n--- Execution trace ---");
    while ((ref_pc[31:2] < NUM_INSTR) && (cycle_count < MAX_CYCLES)) begin
      @(negedge clk);
      #1;  // let the register-file write settle
      if (sh_memwb_valid) begin
        ref_step;  // advance golden model by one instruction
        retire_count = retire_count + 1;
        trace_print;
        check_retire_pc(tr_pc);  // did the DUT commit the same one?
        check_state;  // full register file and data memory
      end
    end

    cycles_at_halt = cycle_count;

    if (cycle_count >= MAX_CYCLES)
      $display("\n[FATAL] Cycle limit reached with %0d instruction(s) retired.", retire_count);
    else
      $display("\n[INFO] Halt detected after %0d retirement(s) in %0d cycle(s) (REF PC=0x%08h).",
               retire_count, cycle_count, ref_pc);

    // Pipeline-specific and end-of-program cross-checks
    drain_and_check;
    dump_final_state;
    check_final;
    report_pipeline_stats;

    $display("\n==================================================");
    if (error_count == 0) $display(" RESULT: PASS - 0 errors. DUT == reference == oracle.");
    else $display(" RESULT: FAIL - %0d error(s).", error_count);
    $display("==================================================\n");

    $finish;
  end

endmodule
