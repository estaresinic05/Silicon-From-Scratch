/********************************************************************************
 * Project:        ALU Design
 * Module:         ALU Full Testbench
 * Author:         Elliot Staresinic
 * Date:           2026-06-02
 * Target:         Icarus Verilog (iverilog -g2012)
 *
 * Purpose:
 *   Self-checking, stand-alone unit testbench for alu_full. Exercises the
 *   seven operations the control unit drives (AND, OR, ADD, SUB, SLT, NOR,
 *   NAND) with a small, curated set of directed vectors and verifies the
 *   result bus together with the ovf and zero flags.
 *
 * Verification strategy (independent behavioral oracle):
 *   The DUT is purely combinational, so this is NOT a clocked lockstep TB.
 *   For every applied stimulus a behavioral golden model re-derives the
 *   expected outputs WITHOUT copying the DUT's gate-level structure:
 *     - result is computed from native Verilog operators (&, |, +, -,
 *       signed <, ~) per operation;
 *     - ovf is computed from the two's-complement sign-bit overflow
 *       identity  (opA[N-1]==opB[N-1]) && (sum[N-1]!=opA[N-1])  rather than
 *       the DUT's cin^cout expression, giving a genuinely separate path to
 *       the same answer;
 *     - zero is computed as (result == 0).
 *   Every applied vector is compared with 4-state equality (!==) so that any
 *   X/Z on the DUT outputs is also caught. Errors are reported the moment
 *   they occur and tallied; a final banner prints PASS/FAIL.
 *
 * Coverage notes (each vector targets a specific edge case):
 *   - Logic bit-patterns through AND, OR, NOR, NAND (incl. zero-flag set).
 *   - ADD with no overflow, ADD positive overflow, ADD negative overflow.
 *   - SUB of equal operands (zero flag), SUB overflow.
 *   - Signed SLT true / false, including the overflow-correction edge cases
 *     (min-negative vs max-positive in both directions).
 *   Both ovf = 0/1 and zero = 0/1 are exercised. The nine control codes the
 *   control unit does not drive (datapath byproducts) are out of scope.
 *
 * Waveform:
 *   Dumps to waveforms/dump.vcd via $dumpfile/$dumpvars.
 *
 *******************************************************************************/

`timescale 1ns / 1ps

module tb_alu_full;

  // ----------------------------------------------------------------------
  // Parameters / constants
  // ----------------------------------------------------------------------
  localparam integer N = 32;  // ALU width under test
  localparam integer SETTLE = 1;  // ns to let combinational logic settle

  // Control codes driven by the control unit (control[3]=Ainvert,
  // control[2]=Bnegate, control[1:0]=operation)
  localparam [3:0] CTRL_AND = 4'b0000;
  localparam [3:0] CTRL_OR = 4'b0001;
  localparam [3:0] CTRL_ADD = 4'b0010;
  localparam [3:0] CTRL_SUB = 4'b0110;
  localparam [3:0] CTRL_SLT = 4'b0111;
  localparam [3:0] CTRL_NOR = 4'b1100;
  localparam [3:0] CTRL_NAND = 4'b1101;

  // ----------------------------------------------------------------------
  // DUT interface
  // ----------------------------------------------------------------------
  reg  [N-1:0] a;
  reg  [N-1:0] b;
  reg  [  3:0] control;
  wire [N-1:0] result;
  wire         ovf;
  wire         zero;

  alu_full #(
      .N(N)
  ) dut (
      .a      (a),
      .b      (b),
      .control(control),
      .result (result),
      .ovf    (ovf),
      .zero   (zero)
  );

  // ----------------------------------------------------------------------
  // Golden (expected) outputs and bookkeeping
  // ----------------------------------------------------------------------
  reg     [N-1:0] exp_result;
  reg             exp_ovf;
  reg             exp_zero;

  integer         error_count;
  integer         test_count;

  // ----------------------------------------------------------------------
  // Waveform dump (EPWave-friendly)
  // ----------------------------------------------------------------------
  initial begin
    $dumpfile("waveforms/dump.vcd");
    $dumpvars(0, tb_alu_full);
  end

  // ----------------------------------------------------------------------
  // Operation name lookup (for readable trace lines)
  // ----------------------------------------------------------------------
  function [8*4-1:0] opname;
    input [3:0] ctrl;
    begin
      case (ctrl)
        CTRL_AND:  opname = "AND";
        CTRL_OR:   opname = "OR";
        CTRL_ADD:  opname = "ADD";
        CTRL_SUB:  opname = "SUB";
        CTRL_SLT:  opname = "SLT";
        CTRL_NOR:  opname = "NOR";
        CTRL_NAND: opname = "NAND";
        default:   opname = "????";
      endcase
    end
  endfunction

  // ======================================================================
  // Behavioral golden model: predict result / ovf / zero for one stimulus
  //   - result : native operators per operation
  //   - ovf    : two's-complement sign-bit overflow identity (independent
  //              of the DUT's cin^cout formulation)
  //   - zero   : result == 0
  // ======================================================================
  task predict;
    input [3:0] ctrl;
    input [N-1:0] av;
    input [N-1:0] bv;
    reg [N-1:0] opA, opB, sum;
    reg cin0;
    reg signed [N-1:0] sav, sbv;
    begin
      // Adder operands exactly as the datapath would form them, used ONLY to
      // derive the overflow flag (which the DUT outputs for every operation).
      opA = ctrl[3] ? ~av : av;
      opB = ctrl[2] ? ~bv : bv;
      cin0 = ctrl[2];
      sum = opA + opB + cin0;
      exp_ovf = (opA[N-1] == opB[N-1]) && (sum[N-1] != opA[N-1]);

      sav = av;
      sbv = bv;

      case (ctrl)
        CTRL_AND:  exp_result = av & bv;
        CTRL_OR:   exp_result = av | bv;
        CTRL_ADD:  exp_result = av + bv;
        CTRL_SUB:  exp_result = av - bv;
        CTRL_SLT:  exp_result = (sav < sbv) ? {{N - 1{1'b0}}, 1'b1} : {N{1'b0}};
        CTRL_NOR:  exp_result = ~(av | bv);
        CTRL_NAND: exp_result = ~(av & bv);
        default:   exp_result = {N{1'bx}};
      endcase

      exp_zero = (exp_result == {N{1'b0}});
    end
  endtask

  // ======================================================================
  // Apply one stimulus, compare DUT against the golden model
  // ======================================================================
  task run_one;
    input [3:0] ctrl;
    input [N-1:0] av;
    input [N-1:0] bv;
    input [8*40-1:0] note;
    begin
      a       = av;
      b       = bv;
      control = ctrl;
      #(SETTLE);  // combinational settle

      predict(ctrl, av, bv);
      test_count = test_count + 1;

      if ((result !== exp_result) || (ovf !== exp_ovf) || (zero !== exp_zero)) begin
        error_count = error_count + 1;
        $display("[ERROR] %-4s a=0x%08h b=0x%08h ctrl=%b  (%0s)", opname(ctrl), av, bv, ctrl, note);
        $display("        result DUT=0x%08h EXP=0x%08h | ovf DUT=%b EXP=%b | zero DUT=%b EXP=%b",
                 result, exp_result, ovf, exp_ovf, zero, exp_zero);
      end else begin
        $display("  ok  %-4s a=0x%08h b=0x%08h -> result=0x%08h ovf=%b zero=%b  | %0s",
                 opname(ctrl), av, bv, result, ovf, zero, note);
      end
    end
  endtask

  // ======================================================================
  // Main test sequence
  // ======================================================================
  initial begin
    error_count = 0;
    test_count  = 0;

    $display("\n==================================================");
    $display(" ALU Full - Self-Checking Unit Testbench");
    $display(" Width N = %0d", N);
    $display(" Operations: AND OR ADD SUB SLT NOR NAND");
    $display("==================================================");
    $display("\n--- Directed edge-case vectors ---");

    // ---- Logic operations (bit patterns; zero flag on AND/NOR) ----
    run_one(CTRL_AND, 32'hF0F0F0F0, 32'h0F0F0F0F, "AND disjoint -> 0, zero set");
    run_one(CTRL_OR, 32'hF0F0F0F0, 32'h0F0F0F0F, "OR  complementary -> all ones");
    run_one(CTRL_NOR, 32'hAAAAAAAA, 32'h55555555, "NOR full cover -> 0, zero set");
    run_one(CTRL_NAND, 32'h12345678, 32'h9ABCDEF0, "NAND general pattern");

    // ---- Addition (no overflow, then both overflow directions) ----
    run_one(CTRL_ADD, 32'h00000005, 32'h00000003, "ADD 5+3=8, no overflow");
    run_one(CTRL_ADD, 32'h7FFFFFFF, 32'h00000001, "ADD maxpos+1 -> +overflow");
    run_one(CTRL_ADD, 32'h80000000, 32'hFFFFFFFF, "ADD minneg+(-1) -> -overflow");

    // ---- Subtraction (equal -> zero flag, then overflow) ----
    run_one(CTRL_SUB, 32'h12345678, 32'h12345678, "SUB equal -> 0, zero set");
    run_one(CTRL_SUB, 32'h80000000, 32'h00000001, "SUB minneg-1 -> overflow");

    // ---- Set-less-than (signed; includes overflow-correction edges) ----
    run_one(CTRL_SLT, 32'hFFFFFFFF, 32'h00000001, "SLT -1 < 1 -> 1 (true)");
    run_one(CTRL_SLT, 32'h00000005, 32'h00000003, "SLT 5 < 3 -> 0 (false)");
    run_one(CTRL_SLT, 32'h80000000, 32'h7FFFFFFF, "SLT minneg < maxpos -> 1 (ovf edge)");
    run_one(CTRL_SLT, 32'h7FFFFFFF, 32'h80000000, "SLT maxpos < minneg -> 0 (ovf edge)");

    // ---- Summary ----
    $display("\n==================================================");
    $display(" Total vectors applied: %0d", test_count);
    if (error_count == 0) $display(" RESULT: PASS - 0 errors. DUT == behavioral oracle.");
    else $display(" RESULT: FAIL - %0d error(s).", error_count);
    $display("==================================================\n");

    $finish;
  end

endmodule
