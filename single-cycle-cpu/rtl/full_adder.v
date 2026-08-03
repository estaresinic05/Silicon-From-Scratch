/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Full Adder
 * Author:         Elliot Staresinic
 * Date:           2026-04-29
 *
 * Description:
 *   This module implements a 1-bit full adder combinational
 *   block. It is used as a building block in the ripple carry
 *   adder and ALU.
 *
 * Interface:
 *   Inputs:
 *     a     - operand bit A
 *     b     - operand bit B
 *     cin   - carry-in (1 bit)
 *
 *   Outputs:
 *     sum   - sum output bit
 *     cout  - carry-out bit
 *
 *******************************************************/

module full_adder (
    input  wire a,
    input  wire b,
    input  wire cin,
    output wire sum,
    output wire cout
);

  assign sum  = a ^ b ^ cin;
  assign cout = (a & b) | (a & cin) | (b & cin);

endmodule
