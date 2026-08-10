/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Carry Lookahead Adder
 * Author:         Elliot Staresinic
 * Date:           2026-08-09
 *
 * Description:
 *   This module implements a N-bit carry lookahead adder
 *   that can perform addition or subtraction depending
 *   on the operation bit. The operation bit doubles as
 *   the cin to bit 0. This module can detect overflow by
 *   setting the ovf bit.
 *
 *   It is a drop-in replacement for ripple_carry_adder:
 *   same ports, same parameter, same meaning for every
 *   signal, so the ALU can swap one for the other.
 *
 *   A ripple carry adder makes bit i wait for bit i-1,
 *   so its delay grows with N. Lookahead breaks that
 *   chain by asking two questions of every bit before
 *   any carry has arrived. A bit GENERATES a carry when
 *   both operands are 1, and it PROPAGATES an incoming
 *   carry when exactly one of them is. Those depend only
 *   on a and b, so every bit answers at once, and a carry
 *   can then be written directly instead of waited for.
 *
 *   Bits are grouped into BW-bit blocks. Each block folds
 *   its bits into one block generate and one block
 *   propagate, the same two questions asked of a group,
 *   and a second level of lookahead uses those to produce
 *   the carry into every block. Depth grows with the
 *   number of levels rather than with N.
 *
 * Interface:
 *   Inputs:
 *     operation - add = 0, sub = 1
 *     a         - operand bit A (N-bit)
 *     b         - operand bit B (N-bit)
 *
 *   Outputs:
 *     sum       - sum output bits (N-bit)
 *     ovf       - carry-out of the Nth bit XOR carry-in
 *
 *******************************************************/

module carry_lookahead #(
    parameter N = 32
) (
    input  wire         operation,
    input  wire [N-1:0] a,
    input  wire [N-1:0] b,
    output wire [N-1:0] sum,
    output wire         ovf
);

  localparam BW = 4;                        // bits per lookahead block
  localparam NB = (N + BW - 1) / BW;        // blocks, rounded up
  localparam NP = NB * BW;                  // padded width

  // Subtracting is adding the complement with a carry in, which is why the
  // operation bit both flips b and seeds the first carry.
  wire [N-1:0] bx = b ^ {N{operation}};
  wire [N-1:0] p = a ^ bx;                  // propagate: exactly one operand is 1
  wire [N-1:0] g = a & bx;                  // generate:  both operands are 1

  // EVERY always block below declares its own accumulator and term. Sharing
  // them at module level is not a style question: each block's inferred
  // sensitivity list then contains variables the other blocks write, so the
  // three retrigger one another with different values and the model oscillates
  // forever instead of settling. Simulation hangs rather than reporting
  // anything wrong, which is the least helpful way for it to fail.
  //
  // Padding out to a whole number of blocks. A pad bit must be transparent:
  // propagate 1 so it never breaks a block's propagate chain, generate 0 so it
  // never invents a carry. Written as a loop rather than a concatenation
  // because {0{...}} is illegal when N already divides evenly into blocks.
  reg [NP-1:0] pp, gg;
  always @* begin : pad
    integer i;
    for (i = 0; i < NP; i = i + 1) begin
      pp[i] = (i < N) ? p[i] : 1'b1;
      gg[i] = (i < N) ? g[i] : 1'b0;
    end
  end

  // ---- level 1: fold each block into one generate and one propagate ----
  //
  //   BG = g3 | p3.g2 | p3.p2.g1 | p3.p2.p1.g0
  //   BP = p3.p2.p1.p0
  //
  // Walking j downward with a running product of the higher propagates builds
  // both at once: the accumulator holds exactly the term each generate needs,
  // and what it holds after the last step IS the block propagate.
  reg [NB-1:0] BP, BG;
  always @* begin : level1
    integer k, j;
    reg acc, term;
    for (k = 0; k < NB; k = k + 1) begin
      term = 1'b0;
      acc  = 1'b1;
      for (j = BW - 1; j >= 0; j = j - 1) begin
        term = term | (acc & gg[k*BW+j]);
        acc  = acc & pp[k*BW+j];
      end
      BG[k] = term;
      BP[k] = acc;
    end
  end

  // ---- level 2: the carry into every block, from the block terms ----
  // Same shape one level up, which is what makes this hierarchical rather
  // than a single flat equation with an N-input gate in it.
  reg [NB:0] BC;
  always @* begin : level2
    integer k, j;
    reg acc, term;
    BC[0] = operation;                      // the operation bit is the carry in
    for (k = 1; k <= NB; k = k + 1) begin
      term = 1'b0;
      acc  = 1'b1;
      for (j = k - 1; j >= 0; j = j - 1) begin
        term = term | (acc & BG[j]);
        acc  = acc & BP[j];
      end
      BC[k] = term | (acc & BC[0]);
    end
  end

  // ---- the carry into every bit, expanded inside its block ----
  // Each block starts from a carry that lookahead already produced, so this
  // expansion is BW wide and never N wide. No bit waits on the one below it.
  reg [NP:0] c;
  always @* begin : bitcarry
    integer k, j, m;
    reg acc, term;
    c[0] = operation;
    for (k = 0; k < NB; k = k + 1) begin
      c[k*BW] = BC[k];
      for (m = 0; m < BW; m = m + 1) begin
        term = 1'b0;
        acc  = 1'b1;
        for (j = m; j >= 0; j = j - 1) begin
          term = term | (acc & gg[k*BW+j]);
          acc  = acc & pp[k*BW+j];
        end
        c[k*BW+m+1] = term | (acc & BC[k]);
      end
    end
  end

  assign sum = p ^ c[N-1:0];
  assign ovf = c[N] ^ c[N-1];  //signed overflow: carry into MSB XOR carry out of MSB

endmodule
