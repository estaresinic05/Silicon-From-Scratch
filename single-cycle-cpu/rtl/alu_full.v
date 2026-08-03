/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         ALU Full
 * Author:         Elliot Staresinic
 * Date:           2026-05-19
 *
 * Description:
 *   This module implements the entire N-bit ALU by 
 *   connecting the ALU Slice modules together followed 
 *   by an ALU MSB module.
 *
 * Interface:
 *   Inputs:
 *     a       - operand bit A
 *     b       - operand bit B
 *     control - 4-bit vector responsible for control
 *
 *   Outputs:
 *     result    - the result of either 4 operations
 *     ovf       - set when there is overflow
 *     zero      - set when a == b
 *
 *******************************************************/

module alu_full #(
    parameter N = 32
) (
    input  wire [N-1:0] a,
    input  wire [N-1:0] b,
    input  wire [  3:0] control,
    output wire [N-1:0] result,
    output wire         ovf,
    output wire         zero
);

  /*****Expanding out Control Vector*****/
  wire Ainvert, Bnegate;
  wire [1:0] operation;

  assign Ainvert   = control[3];
  assign Bnegate   = control[2];
  assign operation = control[1:0];
  /**************************************/

  wire [N-1:0] cout;
  wire set;
  assign cout[0] = Bnegate;


  genvar i;
  generate
    for (i = 0; i < N - 1; i = i + 1) begin : ALU_GEN
      alu_slice slice_i (
          .a(a[i]),
          .b(b[i]),
          .cin(cout[i]),
          .less((i == 0) ? set : 1'b0),  // all hardwired to zero except LS slice
          .Ainvert(Ainvert),
          .Binvert(Bnegate),
          .operation(operation),
          .result(result[i]),
          .cout(cout[i+1])
      );  // create a new slice with cin = cout of the previous.
    end
  endgenerate

  alu_msb msb (
      .a(a[N-1]),
      .b(b[N-1]),
      .cin(cout[N-1]),
      .less(1'b0),  // hard wired to zero
      .Ainvert(Ainvert),
      .Binvert(Bnegate),
      .operation(operation),
      .result(result[N-1]),
      .ovf(ovf),
      .setLess(set)
  );

  assign zero = ~|result;  // or all bits, then invert

endmodule
