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
    output wire [31:0] data1,
    output wire [31:0] data2
);

  reg [31:0] RF[0:31];  // 32 registers each 32 bits long

  integer i;

  initial begin
    for (i = 0; i < 32; i = i + 1) RF[i] = 32'b0;  // initialize registers to zero
  end

  assign data1 = (readAddress1 == 5'd0) ? 32'd0 : RF[readAddress1]; // if register x0, read value zero
  assign data2 = (readAddress2 == 5'd0) ? 32'd0 : RF[readAddress2];

  always @(posedge clk) begin  //write register on posedge of clk
    if (writeEnable && (writeAddress != 5'd0))
      RF[writeAddress] <= writeData;  // when writeEnable is high
  end

endmodule
