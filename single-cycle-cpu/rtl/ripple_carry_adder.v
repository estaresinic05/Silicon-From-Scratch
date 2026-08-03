/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         rippleCarryAdder
 * Author:         Elliot Staresinic
 * Date:           2026-04-29
 *
 * Description:
 *   This module implements a N-bit ripple carry adder 
 *   that can perform addition or subtraction depending
 *   on the operation bit. The operation bit doubles as
 *   the cin to the first fullAdder. This module can detect 
 *   overflow by setting the ovf bit.
 *
 * Interface:
 *   Inputs:
 *     operation - add = 0, sub = 1
 *     a         - operand bit A (N-bit)
 *     b         - operand bit B (N-bit)
 *
 *   Outputs:
 *     sum       - sum output bits (N-bit)
 *     ovf       - carry-out bit of Nth fullAdder
 *
 *******************************************************/

module ripple_carry_adder #(
    parameter N = 1
) (
    input  wire         operation,
    input  wire [N-1:0] a,
    input  wire [N-1:0] b,
    output wire [N-1:0] sum,
    output wire         ovf
);
  wire [N:0] cout;
  assign cout[0] = operation;

  genvar i;
  generate
    for (i = 0; i < N; i = i + 1) begin : FA_GEN
      full_adder fa_i (
          a[i],
          (b[i] ^ operation),
          cout[i],
          sum[i],
          cout[i+1]
      );  //create a new fullAdder with cin = cout of the prev.
    end
  endgenerate

  assign ovf = cout[N] ^ cout[N-1];  //signed overflow: carry into MSB XOR carry out of MSB

endmodule
