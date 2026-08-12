/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Reset Synchroniser
 * Author:         Elliot Staresinic
 * Date:           2026-08-12
 *
 * Description:
 *   Asserts asynchronously, releases synchronously.
 *
 *   The CPU's reset arrives from outside with no
 *   relationship to clk. Asserting it that way is
 *   correct and needs no timing: every flop is forced
 *   to a known state whether or not a clock is running.
 *   RELEASING it that way is the problem, and it is
 *   invisible in simulation because a testbench
 *   deasserts reset everywhere in the same instant.
 *
 *   In silicon the reset net drives 1347 flops and has
 *   real delay across it. Deassert asynchronously and
 *   the flops nearest the driver leave reset on one
 *   clock edge while the far ones leave on the next, so
 *   the pipeline starts in a state the RTL never
 *   models. Static timing calls this the recovery
 *   check, and check_timing found all 1349 of them
 *   untested on 2026-08-12: the reset pin of every flop
 *   was an unconstrained endpoint.
 *
 *   Two flops fix it. Both are forced high the moment
 *   async_reset rises, so assertion stays asynchronous.
 *   On release, stage1 samples 0 and may go metastable,
 *   because that edge really is unrelated to the clock;
 *   stage2 then gives it a full cycle to settle before
 *   anything downstream sees it. The reset the design
 *   receives therefore leaves on a clock edge, is
 *   sourced by a register rather than by a port, and is
 *   timed like any other synchronous signal.
 *
 *   Release costs two clock cycles. Nothing depends on
 *   reset ending on a particular edge, so that is free.
 *
 * Interface:
 *   Inputs:
 *     clk          - system clock
 *     async_reset  - active high, asynchronous
 *
 *   Outputs:
 *     sync_reset   - active high, releases synchronously
 *
 *******************************************************/

module reset_sync (
    input  wire clk,
    input  wire async_reset,
    output wire sync_reset
);

  reg stage1;
  reg stage2;
  reg stage3_n;

  always @(posedge clk or posedge async_reset) begin
    if (async_reset) begin
      stage1 <= 1'b1;
      stage2 <= 1'b1;
    end else begin
      stage1 <= 1'b0;
      stage2 <= stage1;
    end
  end

  /* THE RELEASE LEAVES ON A FALLING EDGE, and that third flop is not
     decoration. With release on the rising edge the deassertion reached the
     flops 92 ps after the capture edge, and the removal check wants it held
     for 134 ps: 119 paths failed at the fast corner by 61 ps. The reset was
     too FAST, which is the opposite of every other timing problem here.

     Innovus does not fix this on its own. Hold optimisation is enabled and it
     closes data paths happily, but it will not insert delay on an async reset
     net to satisfy removal; -opt_hold_target_slack 0.08 was applied and
     returned a byte-identical design. That is a structural problem and it
     wants a structural answer.

     Releasing on the falling edge puts the deassertion half a period from
     every capture edge: 2 ns at a 4 ns clock, against a 0.134 ns removal
     requirement and a recovery requirement smaller still. Both checks pass
     with three orders of magnitude of room rather than by 61 ps of arithmetic,
     which is the kind of margin a reset network should have.

     A negedge flop is exactly what reg_file.v was fixed to REMOVE, and the
     distinction matters: there it sat on the read data path and gave away half
     the clock on every instruction. Here it sits on a signal that changes once
     at power-up and is never in a critical path, so the half cycle it spends
     costs nothing at all.

     Assertion is untouched. All three flops are forced high the instant
     async_reset rises, so reset still asserts with no clock running. */
  always @(negedge clk or posedge async_reset) begin
    if (async_reset) begin
      stage3_n <= 1'b1;
    end else begin
      stage3_n <= stage2;
    end
  end

  assign sync_reset = stage3_n;


endmodule
