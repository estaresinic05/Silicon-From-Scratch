/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         32-bit Register File
 * Author:         Elliot Staresinic
 * Date:           2026-05-21
 *
 * Description:
 *   This module implements a 32-bit register file with
 *   2 read ports. It has a write enable signal which
 *   controls when the register file is written. This
 *   module also protects from overwriting register x0 which
 *   will always be equal to zero for the RISC-V ISA.
 *
 *   Written on the RISING edge, with a write-forward bypass
 *   on both read ports so that a read still sees a write
 *   issued in the same cycle. It used to write on the
 *   falling edge instead, which made every path out of this
 *   module a half-cycle path. See the note above the always
 *   block for the measurement that changed it.
 *
 * Interface:
 *   Inputs:
 *     readAddress1  - 5-bit address of 1st register to read
 *     readAddress2  - 5-bit address of 2nd register to read
 *     writeAddress  - 5-bit address of register to write to
 *     writeData     - 32-bit data to be written
 *     writeEnable   - 1-bit control signal to control writing
 *     clk           - clock of system
 *     reset         - asynchronous, clears every register to zero
 *
 *   Outputs:
 *     data1         - data read from readAddress1
 *     data2         - data read from readAddress2
 *
 *******************************************************/

module reg_file (
    input  wire [ 4:0] readAddress1,
    input  wire [ 4:0] readAddress2,
    input  wire [ 4:0] writeAddress,
    input  wire [31:0] writeData,
    input  wire        writeEnable,
    input  wire        clk,
    input  wire        reset,
    output wire [31:0] data1,
    output wire [31:0] data2
);

  reg [31:0] RF[0:31];  // 32 registers each 32 bits long

  integer i;

  /*******************************************************
   * WRITE-FORWARD BYPASS
   *
   * The write lands on the RISING edge, so a read in the same cycle would
   * otherwise return the old value. These two terms hand the incoming
   * writeData straight to a read port that is asking for the register being
   * written, which restores exactly the behaviour the negedge write used to
   * give, for anything that samples on a clock edge.
   *
   * IT IS NOT REDUNDANT WITH THE FORWARDING UNITS, and the reason is worth
   * keeping. branch_fwd_unit does cover the ID stage, because branches
   * resolve in ID and its comparison is contemporaneous with the register
   * read. alu_fwd_unit cannot: an instruction reads the register file in ID
   * and does not use the value until EX, by which time the instruction that
   * wrote it has left MEM/WB and there is nothing left to compare against.
   * Remove these two terms and the ALU operand path silently reads stale
   * data one cycle later.
   *
   * x0 is never forwarded. The outer term already returns zero for it, and a
   * write to x0 never reaches RF in the first place.
   *******************************************************/
  wire forward1 = writeEnable && (writeAddress != 5'd0) && (writeAddress == readAddress1);
  wire forward2 = writeEnable && (writeAddress != 5'd0) && (writeAddress == readAddress2);

  assign data1 = (readAddress1 == 5'd0) ? 32'd0 :  // if register x0, read value zero
                 forward1 ? writeData : RF[readAddress1];
  assign data2 = (readAddress2 == 5'd0) ? 32'd0 :
                 forward2 ? writeData : RF[readAddress2];

  /*******************************************************
   * RESET, WHERE THERE USED TO BE AN `initial` BLOCK
   *
   * The old version zeroed RF in an initial block. Simulation honours that
   * and SYNTHESIS IGNORES IT, so the gate netlist came up with 992 bits of X
   * and no way to clear them. Real silicon behaves the same way: a register
   * file powers up holding whatever it holds.
   *
   * That is not theoretical for this design. Instruction 25 of
   * programs/program.mem is `add x18, x18, x17`, which READS x18 BEFORE
   * ANYTHING HAS WRITTEN IT. The RTL testbench passed only because of the
   * initial block, which is to say it passed on something the hardware does
   * not have.
   *
   * Faking it from the testbench was tried at length and is not sound.
   * Forcing the flop outputs never touches the cell model's internal state,
   * so every bit reverts to X on release. Driving the scan pins works on one
   * netlist and not another. iverilog and Xcelium then disagree about how the
   * leftover X resolves, which is why the routed netlist simulated wrong in
   * both while Conformal proved it equivalent to the RTL twice over.
   *
   * A reset costs area: all 992 flops become resettable. It buys a processor
   * that powers up in a defined state, a gate-level simulation that matches
   * the RTL by construction rather than by hack, and one less thing that is
   * true in simulation and false in silicon. Plenty of real processors reset
   * their register file for exactly these reasons.
   *
   * ASYNCHRONOUS, and on the same edge as the write.
   *******************************************************/

  /*******************************************************
   * THE WRITE EDGE, AND WHY IT MOVED
   *
   * This file used to write on the NEGEDGE so that a write and a read could
   * share a cycle: write in the first half, read in the second. It is a
   * classic trick and it costs more than it looks like it costs.
   *
   * A flop clocked on the falling edge launches its data at T/2 and is
   * captured by logic on the next rising edge, so every path out of the
   * register file gets HALF A CLOCK PERIOD, not a whole one. Measured on the
   * routed layout at 4.1 ns, run `clk4p1_ehigh`, the worst such path had
   * 1.87 ns of budget against a 4.1 ns clock, which is 46% of the period, and
   * 19 of the 21 failing setup paths were this one family: register file read,
   * through the branch comparator, into the PC.
   *
   * It also explains why loosening the clock barely helped. A half-cycle path
   * receives only half of every picosecond added to the period, so 400 ps of
   * extra clock bought these paths 200 ps, which is close enough to the
   * optimiser's run-to-run scatter to vanish inside it.
   *
   * Writing on the rising edge gives those paths the full period. The cost is
   * the two forwarding terms above, which is one mux per read port.
   *******************************************************/
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      for (i = 0; i < 32; i = i + 1) RF[i] <= 32'b0;
    end else if (writeEnable && (writeAddress != 5'd0)) begin
      RF[writeAddress] <= writeData;  // when writeEnable is high
    end
  end

endmodule
