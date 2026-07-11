/*******************************************************
 * Project:        RISC-V Single Cycle Design
 * Module:         32-bit Read-Only Instruction Memory
 * Author:         Elliot Staresinic
 * Date:           2026-05-23
 *
 * Description:
 *   This module implements a 32-bit, read-only instruction
 *   memory with word aligned access. Since this is similar
 *   to a ROM, it isn't dependent on the system clock, as
 *   reads from memory are assumed to be instantaneous. The
 *   parameter DEPTH indicates how many instructions the
 *   memory can store.
 *
 * Interface:
 *   Inputs:
 *     instAddress  - 32-bit address of instruction to fetch
 *     
 *   Outputs:
 *     instruction  - 32-bit instruction to decode and execute
 *
 *******************************************************/

module instruct_mem #(
    parameter DEPTH = 256
) (
    input  wire [31:0] instAddress,
    output wire [31:0] instruction
);

  reg [31:0] memory[0:DEPTH-1];  //create DEPTH number of 32-bit registers

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
      memory[i] = 32'h00000013;  // NOP
    end
      $readmemh("programs/program.mem", memory);
  end

  assign instruction = (instAddress[31:2] < DEPTH) ? memory[instAddress[31:2]] : 32'b0;  //drop lower 2 bits for word aligned access

endmodule
