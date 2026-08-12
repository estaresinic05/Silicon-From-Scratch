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

  always @(posedge clk or posedge async_reset) begin
    if (async_reset) begin
      stage1 <= 1'b1;
      stage2 <= 1'b1;
    end else begin
      stage1 <= 1'b0;
      stage2 <= stage1;
    end
  end

  assign sync_reset = stage2;


endmodule
