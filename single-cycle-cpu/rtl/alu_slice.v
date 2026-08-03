/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         ALU Slice
 * Author:         Elliot Staresinic
 * Date:           2026-05-19
 *
 * Description:
 *   This module implements a 1-bit slice of an ALU. This
 *   slice will be used in the least significant 31 bits of
 *   a 32-bit ALU.
 *
 * Interface:
 *   Inputs:
 *     a         - operand bit A
 *     b         - operand bit B
 *     cin       - carry-in (1 bit)
 *     less      - 1 if a < b, 0 otherwise
 *     Ainvert   - sel line of 2x1 mux that inverts a
 *     Binvert   - sel line of 2x1 mux that inverts b
 *     operation - sel line of 4x1 mux that determines op
 *
 *   Outputs:
 *     result    - the result of either 4 operations
 *     cout      - carry-out bit
 *
 *******************************************************/

module alu_slice (
    input  wire       a,
    input  wire       b,
    input  wire       cin,
    input  wire       less,
    input  wire       Ainvert,
    input  wire       Binvert,
    input  wire [1:0] operation,
    output wire       result,
    output wire       cout
);

  wire aMuxOut, bMuxOut;
  wire aANDb, aORb, aADDb;

  mux_2x1 #(1) aMux (  // mux to determine if we use a or ~a
      .in0(a),
      .in1(~a),
      .sel(Ainvert),
      .out(aMuxOut)
  );
  mux_2x1 #(1) bMux (  // mux to determine if we use b or ~b
      .in0(b),
      .in1(~b),
      .sel(Binvert),
      .out(bMuxOut)
  );

  assign aANDb = aMuxOut & bMuxOut;  // AND functionality
  assign aORb  = aMuxOut | bMuxOut;  // OR functionality

  full_adder bitAdder (  // addition (and subtraction) functionality
      .a(aMuxOut),
      .b(bMuxOut),
      .cin(cin),
      .sum(aADDb),
      .cout(cout)
  );

  mux_4x1 #(1) resultMux (  // choice between operations
      .in0(aANDb),
      .in1(aORb),
      .in2(aADDb),
      .in3(less),
      .sel(operation),
      .out(result)
  );

endmodule
