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

  assign data1 = (readAddress1 == 5'd0) ? 32'd0 : RF[readAddress1]; // if register x0, read value zero
  assign data2 = (readAddress2 == 5'd0) ? 32'd0 : RF[readAddress2];

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
   * ASYNCHRONOUS, and on the same edge as the write, so nothing else changes:
   * this file is still write-on-negedge and read-second-half, which is what
   * the forwarding logic and the testbench both assume.
   *******************************************************/
  always @(negedge clk or posedge reset) begin
    if (reset) begin
      for (i = 0; i < 32; i = i + 1) RF[i] <= 32'b0;
    end else if (writeEnable && (writeAddress != 5'd0)) begin
      RF[writeAddress] <= writeData;  // when writeEnable is high
    end
  end

endmodule
