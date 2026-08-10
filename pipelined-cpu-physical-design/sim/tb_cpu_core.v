/********************************************************************************
 * Project:        RISC-V CPU Design
 * Module:         Core-level testbench, RTL and gate netlist
 * Author:         Elliot Staresinic
 * Date:           2026-08-10
 * Target:         Icarus Verilog (-g2012) and Xcelium (xrun)
 *
 * Purpose:
 *   Run programs/program.mem on pipelined_cpu_core and prove it behaves. The
 *   SAME testbench drives the RTL core and the post-route gate netlist, because
 *   both present the identical module name and port list. Anything it reports
 *   about one is directly comparable to the other, which is the entire point.
 *
 * WHY THIS EXISTS INSTEAD OF tb_pipelined_cpu_top_level.v
 *
 *   That testbench is excellent and it cannot be used here. It reads
 *   dut.datapath.registers.RF[k], dut.datapath.data_memory.memory[k],
 *   dut.datapath.IF_pc and five control signals by hierarchical reference.
 *   NONE OF THOSE SURVIVE SYNTHESIS. A gate netlist has cells and nets; the
 *   register file becomes 992 flip-flops named registers_RF_reg[r][b] and the
 *   pipeline control signals become wires with numbers for names.
 *
 *   So this testbench observes only what a real chip would let you observe:
 *   the ports. That is what the dbg_* ports were added for.
 *
 * THE ORACLE: THE WRITEBACK TRACE
 *
 *   dbg_wb_enable / dbg_wb_addr / dbg_wb_data are the register file's write
 *   port brought to the boundary. Every architectural register write the CPU
 *   performs appears there, in order, one per cycle it commits one.
 *
 *   A golden RV32I model runs the whole program at time 0 and produces the
 *   ordered list of writes the program MUST perform. The observed sequence is
 *   compared against it element by element. This catches a wrong value, a
 *   wrong destination, a missing write, an extra write, and a write in the
 *   wrong order, which between them cover every way a pipeline can be broken:
 *   a lost flush shows up as an extra write, a lost stall as a wrong value.
 *
 *   Data memory is checked directly, because the memories are OUTSIDE the core
 *   and this testbench owns them.
 *
 *   The register file is reconstructed by replaying the observed writes, and
 *   the reconstruction is checked against a hand-derived final-state table
 *   that was never read out of any simulation.
 *
 * WRITES TO x0 ARE EXPECTED ON THE PORT
 *
 *   regWrite is decoded from the opcode and does not look at rd, so an
 *   instruction targeting x0 still asserts dbg_wb_enable. The register file
 *   discards it. Instructions 28 and 29 of this program do exactly that, on
 *   purpose. The golden model therefore emits those writes too, and the
 *   reconstruction discards them the way the hardware does.
 *
 * THE REGISTER FILE POWERS UP UNKNOWN IN GATES
 *
 *   reg_file.v zeroes RF in an `initial` block. Simulation honours it,
 *   SYNTHESIS IGNORES IT, so the netlist's register file has no reset and
 *   every register reads X until something writes it.
 *
 *   That matters here because instruction 25, `add x18, x18, x17`, READS x18
 *   BEFORE ANY INSTRUCTION HAS WRITTEN IT. In RTL the initial block hides it.
 *   In gates x18 is X, and the loop accumulates X into the result.
 *
 *   This is a property of the PROGRAM, not of the layout. Real silicon powers
 *   up with whatever the register file feels like holding. `+define+GATE_SIM`
 *   forces the 31 register nets to zero through reset and releases them
 *   before the first writeback, which is what a real gate-level flow does for
 *   un-resettable state. Run without it to watch the X spread instead.
 *
 * PLUSARGS
 *   +period_ps=<n>   clock period in ps, default 10000 (10 ns)
 *   +trace           print one line per observed write
 *
 *******************************************************************************/

`timescale 1ps / 1ps

module tb_cpu_core;

  // ----------------------------------------------------------------------
  // Parameters
  // ----------------------------------------------------------------------
  localparam integer NUM_INSTR = 30;  // instructions in program.mem
  localparam integer DMEM_WORDS = 256;
  localparam integer IMEM_WORDS = 256;
  localparam integer MAX_WRITES = 512;  // ceiling on dynamic writing instructions
  localparam integer MAX_CYCLES = 2000;  // runaway guard
  localparam integer DRAIN_CYCLES = 10;  // clocks to watch after the last write

  localparam [6:0] OPC_LOAD = 7'b0000011;
  localparam [6:0] OPC_STORE = 7'b0100011;
  localparam [6:0] OPC_BRANCH = 7'b1100011;
  localparam [6:0] OPC_RTYPE = 7'b0110011;
  localparam [6:0] OPC_ITYPE = 7'b0010011;

  integer period_ps;
  integer half_ps;
  reg     do_trace;

  // ----------------------------------------------------------------------
  // DUT and its memories
  // ----------------------------------------------------------------------
  reg clk;
  reg reset;

  wire [31:0] imem_addr, imem_rdata;
  wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  wire dmem_write, dmem_read;
  wire [31:0] dbg_pc, dbg_wb_data;
  wire [ 4:0] dbg_wb_addr;
  wire dbg_wb_enable;

  pipelined_cpu_core u_cpu (
      .clk          (clk),
      .reset        (reset),
      .imem_addr    (imem_addr),
      .imem_rdata   (imem_rdata),
      .dmem_addr    (dmem_addr),
      .dmem_wdata   (dmem_wdata),
      .dmem_write   (dmem_write),
      .dmem_read    (dmem_read),
      .dmem_rdata   (dmem_rdata),
      .dbg_pc       (dbg_pc),
      .dbg_wb_addr  (dbg_wb_addr),
      .dbg_wb_data  (dbg_wb_data),
      .dbg_wb_enable(dbg_wb_enable)
  );

  instruct_mem #(IMEM_WORDS) u_imem (
      .instAddress(imem_addr),
      .instruction(imem_rdata)
  );

  data_mem #(DMEM_WORDS) u_dmem (
      .dataAddress(dmem_addr),
      .writeData  (dmem_wdata),
      .writeEnable(dmem_write),
      .readEnable (dmem_read),
      .clk        (clk),
      .readData   (dmem_rdata)
  );

  // ----------------------------------------------------------------------
  // Golden model state and the expected write trace it produces
  // ----------------------------------------------------------------------
  reg [31:0] ref_regs [0:31];
  reg [31:0] ref_dmem [0:DMEM_WORDS-1];
  reg [31:0] ref_imem [0:IMEM_WORDS-1];
  reg [31:0] ref_pc;

  reg [ 4:0] exp_addr [0:MAX_WRITES-1];
  reg [31:0] exp_data [0:MAX_WRITES-1];
  reg [31:0] exp_pc   [0:MAX_WRITES-1];  // which instruction produced it
  integer exp_n;
  integer exp_retired;  // dynamic instruction count, writing or not

  // Reconstructed architectural state, replayed from the observed port trace
  reg [31:0] obs_regs[0:31];
  integer obs_n;
  integer obs_cycle_last;

  // Independent hand-derived final-state oracle
  reg [31:0] exp_final_regs[0:31];
  reg [31:0] exp_final_dmem[0:DMEM_WORDS-1];

  integer error_count;
  integer cycle_count;
  integer i;

  // ----------------------------------------------------------------------
  // Clock
  // ----------------------------------------------------------------------
  integer got_arg;

  initial begin
    period_ps = 10000;
    do_trace  = 1'b0;
    // Assigned rather than discarded: $value$plusargs is a function, and
    // calling one as a bare statement is not portable Verilog-2001.
    got_arg   = $value$plusargs("period_ps=%d", period_ps);
    if ($test$plusargs("trace")) do_trace = 1'b1;
    half_ps = period_ps / 2;
    clk = 1'b0;
    forever #(half_ps) clk = ~clk;
  end

  // ----------------------------------------------------------------------
  // Waveforms. Named so a gate run and an RTL run do not overwrite each other.
  // ----------------------------------------------------------------------
  initial begin
`ifdef GATE_SIM
    $dumpfile("sim/gate.vcd");
`else
    $dumpfile("sim/rtl.vcd");
`endif
    $dumpvars(1, tb_cpu_core);
  end

  // ======================================================================
  // Golden model: execute the whole program, recording every register write
  // ======================================================================
  task build_expected;
    reg [31:0] inst;
    reg [ 6:0] opcode;
    reg [4:0] rd, rs1, rs2;
    reg [2:0] f3;
    reg f7b5;
    reg [31:0] a, b;
    reg signed [31:0] sa, sb;
    reg [31:0] imm_i, imm_s, imm_b, addr, res;
    reg taken, writes;
    reg [31:0] next_pc, this_pc;
    integer guard;
    begin
      exp_n = 0;
      exp_retired = 0;
      guard = 0;

      while ((ref_pc[31:2] < NUM_INSTR) && (guard < MAX_WRITES)) begin
        guard   = guard + 1;
        this_pc = ref_pc;
        inst    = ref_imem[ref_pc[31:2]];
        opcode  = inst[6:0];
        rd      = inst[11:7];
        f3      = inst[14:12];
        rs1     = inst[19:15];
        rs2     = inst[24:20];
        f7b5    = inst[30];

        a       = (rs1 == 5'd0) ? 32'd0 : ref_regs[rs1];
        b       = (rs2 == 5'd0) ? 32'd0 : ref_regs[rs2];
        sa      = a;
        sb      = b;

        imm_i   = {{20{inst[31]}}, inst[31:20]};
        imm_s   = {{20{inst[31]}}, inst[31:25], inst[11:7]};
        imm_b   = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};

        taken   = 1'b0;
        writes  = 1'b0;
        next_pc = ref_pc + 32'd4;
        res     = 32'd0;

        case (opcode)
          OPC_RTYPE: begin
            case (f3)
              3'b000:  res = f7b5 ? (a - b) : (a + b);
              3'b111:  res = a & b;
              3'b110:  res = a | b;
              3'b010:  res = (sa < sb) ? 32'd1 : 32'd0;
              default: res = 32'd0;
            endcase
            writes = 1'b1;
          end
          OPC_ITYPE: begin
            case (f3)
              3'b000:  res = a + imm_i;
              3'b111:  res = a & imm_i;
              3'b110:  res = a | imm_i;
              3'b010:  res = (sa < $signed(imm_i)) ? 32'd1 : 32'd0;
              default: res = 32'd0;
            endcase
            writes = 1'b1;
          end
          OPC_LOAD: begin
            addr   = a + imm_i;
            res    = ref_dmem[addr[31:2]];
            writes = 1'b1;
          end
          OPC_STORE: begin
            addr = a + imm_s;
            ref_dmem[addr[31:2]] = b;
          end
          OPC_BRANCH: begin
            case (f3)
              3'b000:  taken = (a == b);
              3'b001:  taken = (a != b);
              3'b100:  taken = (sa < sb);
              default: taken = 1'b0;
            endcase
            if (taken) next_pc = ref_pc + imm_b;
          end
          default: ;
        endcase

        // The write port carries x0 writes too, so the expected trace does.
        if (writes) begin
          exp_addr[exp_n] = rd;
          exp_data[exp_n] = res;
          exp_pc[exp_n]   = this_pc;
          exp_n           = exp_n + 1;
          if (rd != 5'd0) ref_regs[rd] = res;
        end

        exp_retired = exp_retired + 1;
        ref_pc = next_pc;
      end
    end
  endtask

  // ======================================================================
  // Hand-derived final state. Never read out of a simulation.
  // ======================================================================
  task load_final_oracle;
    integer k;
    begin
      for (k = 0; k < 32; k = k + 1) exp_final_regs[k] = 32'h0;
      for (k = 0; k < DMEM_WORDS; k = k + 1) exp_final_dmem[k] = 32'h0;
      exp_final_regs[1]  = 32'h00000005;  // NOT 99: instruction 17 is squashed
      exp_final_regs[2]  = 32'hFFFFFFFD;  // NOT 99: instruction 21 is squashed
      exp_final_regs[3]  = 32'h00000002;
      exp_final_regs[4]  = 32'h00000003;
      exp_final_regs[5]  = 32'h00000005;
      exp_final_regs[6]  = 32'hFFFFFFFF;
      exp_final_regs[7]  = 32'h00000001;
      exp_final_regs[9]  = 32'h00000001;
      exp_final_regs[10] = 32'h0000000D;
      exp_final_regs[11] = 32'h00000040;
      exp_final_regs[12] = 32'h0000000D;
      exp_final_regs[13] = 32'h00000012;
      exp_final_regs[14] = 32'h00000012;
      exp_final_regs[15] = 32'h00000004;
      exp_final_regs[16] = 32'h00000009;
      exp_final_regs[18] = 32'h00000006;  // loop sum 3 + 2 + 1
      exp_final_dmem[16] = 32'h0000000D;
      exp_final_dmem[17] = 32'h00000012;
    end
  endtask

  // ----------------------------------------------------------------------
  // Cycle counter, running once reset is released
  // ----------------------------------------------------------------------
  always @(posedge clk) if (!reset) cycle_count <= cycle_count + 1;

  // ======================================================================
  // Observe the write port and compare against the expected trace
  //
  // Sampled at the NEGEDGE. The write port is driven from MEM/WB flops, so it
  // is stable from shortly after the posedge, and the register file latches it
  // on this very negedge. Half a period of settling is also what keeps this
  // honest under SDF, where the port does not resolve the instant the clock
  // rises.
  // ======================================================================
  task observe_writes;
    reg [31:0] got_data;
    reg [ 4:0] got_addr;
    begin
      while ((obs_n < exp_n) && (cycle_count < MAX_CYCLES)) begin
        @(negedge clk);
        if (!reset && dbg_wb_enable === 1'b1) begin
          got_addr = dbg_wb_addr;
          got_data = dbg_wb_data;

          if (got_addr !== exp_addr[obs_n] || got_data !== exp_data[obs_n]) begin
            error_count = error_count + 1;
            $display(
                "[ERROR] write %0d at cycle %0d: DUT x%0d <= 0x%08h,  EXPECTED x%0d <= 0x%08h  (from PC 0x%08h)",
                obs_n, cycle_count, got_addr, got_data, exp_addr[obs_n], exp_data[obs_n],
                exp_pc[obs_n]);
          end else if (do_trace) begin
            $display("  [%3d] cyc=%3d  PC=0x%08h  x%0d <= 0x%08h", obs_n, cycle_count, exp_pc[obs_n],
                     got_addr, got_data);
          end

          // Replay it the way the hardware does: x0 absorbs and discards.
          if (got_addr != 5'd0) obs_regs[got_addr] = got_data;

          obs_n = obs_n + 1;
          obs_cycle_last = cycle_count;
        end
      end
    end
  endtask

  // ======================================================================
  // Drain: no ARCHITECTURAL write may happen after the program's last one
  //
  // A pipeline can fail exactly here, with an instruction that should have
  // been squashed still in flight when the program ends.
  //
  // WRITES TO x0 DO NOT COUNT, AND THERE WILL BE A STEADY STREAM OF THEM.
  // The CPU never halts; it keeps fetching, and instruct_mem returns a real
  // NOP for every unloaded word. A NOP is `addi x0, x0, 0`, which decodes with
  // regWrite set, so dbg_wb_enable stays high forever with rd = 0 and the
  // register file discards every one. Counting those as late writes was the
  // first version of this check, and it failed a design that was behaving
  // perfectly. An architectural write is one that changes architectural state,
  // and a write to x0 cannot.
  // ======================================================================
  task drain_and_check;
    integer extra;
    integer nops;
    begin
      extra = 0;
      nops  = 0;
      repeat (DRAIN_CYCLES) begin
        @(negedge clk);
        if (dbg_wb_enable === 1'b1) begin
          if (dbg_wb_addr == 5'd0) begin
            nops = nops + 1;
          end else begin
            extra = extra + 1;
            $display("[DRAIN ERROR] late write at cycle %0d: x%0d <= 0x%08h", cycle_count,
                     dbg_wb_addr, dbg_wb_data);
          end
        end
      end
      if (extra == 0)
        $display("[DRAIN] PASS - no architectural write in %0d cycles after the last one (%0d x0 writes from fetched NOPs, discarded).",
                 DRAIN_CYCLES, nops);
      else error_count = error_count + extra;
    end
  endtask

  // ======================================================================
  // Final checks
  // ======================================================================
  task check_final;
    integer k;
    integer errs;
    begin
      errs = 0;
      for (k = 0; k < 32; k = k + 1)
      if (obs_regs[k] !== exp_final_regs[k]) begin
        errs = errs + 1;
        $display("[FINAL ERROR] x%0d : reconstructed=0x%08h  EXPECTED=0x%08h", k, obs_regs[k],
                 exp_final_regs[k]);
      end
      for (k = 0; k < DMEM_WORDS; k = k + 1)
      if (u_dmem.memory[k] !== exp_final_dmem[k]) begin
        errs = errs + 1;
        $display("[FINAL ERROR] dmem[%0d] : DUT=0x%08h  EXPECTED=0x%08h", k, u_dmem.memory[k],
                 exp_final_dmem[k]);
      end
      if (errs == 0) $display("[FINAL ORACLE] PASS - end state matches the hand-derived table.");
      else begin
        $display("[FINAL ORACLE] FAIL - %0d mismatch(es).", errs);
        error_count = error_count + errs;
      end
    end
  endtask

  // ----------------------------------------------------------------------
  // SDF back-annotation, for the timing tier.
  //
  // Without this the gate run is zero-delay: it proves the netlist computes
  // the right thing, and says nothing about whether it does so in time. The
  // SDF carries the per-instance delays Innovus extracted at one corner, so
  // there is a different file per corner and the clock period has to be set to
  // match with +period_ps.
  // ----------------------------------------------------------------------
`ifdef SDF_FILE
  initial begin
    $sdf_annotate(`SDF_FILE, u_cpu);
    $display(" SDF annotated     : %s", `SDF_FILE);
  end
`endif

  // ----------------------------------------------------------------------
  // Un-resettable state. Defines rf_force and rf_release, and exists only
  // for the gate netlist: in RTL the initial block in reg_file.v does this
  // job, and in gates that initial block was never synthesised.
  // ----------------------------------------------------------------------
`ifdef GATE_SIM
`include "sim/rf_init_gates.vh"
`endif

  // ======================================================================
  // Main sequence
  // ======================================================================
  initial begin
    error_count = 0;
    cycle_count = 0;
    obs_n = 0;
    obs_cycle_last = 0;

    for (i = 0; i < 32; i = i + 1) begin
      ref_regs[i] = 32'h0;
      obs_regs[i] = 32'h0;
    end
    for (i = 0; i < DMEM_WORDS; i = i + 1) ref_dmem[i] = 32'h0;
    for (i = 0; i < IMEM_WORDS; i = i + 1) ref_imem[i] = 32'h00000013;
    $readmemh("programs/program.mem", ref_imem);
    ref_pc = 32'h0;

    build_expected;
    load_final_oracle;

    reset = 1'b1;

`ifdef GATE_SIM
    rf_force;  // hold the register file at zero through reset
`endif

    @(negedge clk);
    @(negedge clk);
    reset = 1'b0;

`ifdef GATE_SIM
    rf_release;
`endif

    $display("\n==================================================");
`ifdef GATE_SIM
    $display(" GATE-LEVEL run on the routed netlist");
`else
    $display(" RTL run on pipelined_cpu_core");
`endif
    $display(" clock period      : %0d ps", period_ps);
    $display(" program           : %0d instructions", NUM_INSTR);
    $display(" expected retires  : %0d", exp_retired);
    $display(" expected writes   : %0d", exp_n);
    $display("==================================================");
    if (do_trace) $display("\n--- writeback trace ---");

    observe_writes;

    if (obs_n < exp_n)
      $display("\n[FATAL] only %0d of %0d expected writes appeared in %0d cycles.", obs_n, exp_n,
               cycle_count);
    else $display("\n[INFO] all %0d writes observed; last one at cycle %0d.", obs_n, obs_cycle_last);

    drain_and_check;
    check_final;

    $display("\n--- result ---");
    $display("  writes observed   : %0d of %0d", obs_n, exp_n);
    $display("  cycles to last    : %0d", obs_cycle_last);
    $display("  instructions      : %0d dynamic", exp_retired);
    if (obs_cycle_last > 0)
      $display("  cycles/instruction: %0d.%02d", obs_cycle_last / exp_retired,
               ((obs_cycle_last * 100) / exp_retired) % 100);
    $display("  execution time    : %0d ps at %0d ps/cycle", obs_cycle_last * period_ps, period_ps);

    $display("\n==================================================");
    if (error_count == 0) $display(" RESULT: PASS - 0 errors.");
    else $display(" RESULT: FAIL - %0d error(s).", error_count);
    $display("==================================================\n");

    $finish;
  end

endmodule
