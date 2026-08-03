/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         32-bit Clocked Data Memory
 * Author:         Elliot Staresinic
 * Date:           2026-05-23
 *
 * Description:
 *   This module implements a 32-bit, clocked data memory
 *   with word aligned access. Writes are at the posedge
 *   of the clock, and data is only written when writeEnable
 *   is high. Data is only read when readEnable is high.
 *   The parameter DEPTH indicates how many words the memory 
 *   can store.
 *   
 * Interface:
 *   Inputs:
 *     dataAddress  - 32-bit address of data to read or write
 *     writeData    - 32-bit data to be written
 *     writeEnable  - write control signal
 *     readEnable   - read control signal
 *     clk          - clock
 *     
 *   Outputs:
 *     readData     - 32-bit data that has been read from memory
 *
 *******************************************************/

module data_mem #(
    parameter DEPTH = 256
) (
    input wire [31:0] dataAddress,
    input wire [31:0] writeData,
    input wire writeEnable,
    input wire readEnable,
    input wire clk,
    output wire [31:0] readData
);

  reg [31:0] memory[0:DEPTH-1];  //create DEPTH number of 32-bit registers

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1) memory[i] = 32'b0;  // initialize registers to zero
  end

  /*******Write*******/
  always @(posedge clk) begin
    if (writeEnable && dataAddress[31:2] < DEPTH) memory[dataAddress[31:2]] <= writeData;
  end

  /*******Read*******/
  assign readData = (readEnable && dataAddress[31:2] < DEPTH) ? memory[dataAddress[31:2]] : 32'b0;


endmodule
