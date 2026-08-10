/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Adder Benchmark Wrappers
 * Author:         Elliot Staresinic
 * Date:           2026-08-09
 *
 * Description:
 *   Two wrappers that put an adder between input and
 *   output registers so synthesis reports a register to
 *   register path rather than an unconstrained lump of
 *   combinational logic. The adder is then the only thing
 *   on that path, and the number Genus prints as Data
 *   Path is the adder's delay.
 *
 *   The two are textually identical apart from the module
 *   being instantiated. That is deliberate: it is what
 *   makes the comparison a comparison. Any difference in
 *   the reported delay belongs to the adder, because
 *   nothing else differs.
 *
 * Interface:
 *   Inputs:
 *     clk       - clock
 *     operation - add = 0, sub = 1
 *     a         - operand A (N-bit)
 *     b         - operand B (N-bit)
 *
 *   Outputs:
 *     sum       - registered sum (N-bit)
 *     ovf       - registered overflow flag
 *
 *******************************************************/

module adder_bench_rca #(
    parameter N = 32
) (
    input  wire         clk,
    input  wire         operation,
    input  wire [N-1:0] a,
    input  wire [N-1:0] b,
    output reg  [N-1:0] sum,
    output reg          ovf
);
  reg          op_q;
  reg  [N-1:0] a_q, b_q;
  wire [N-1:0] s;
  wire         o;

  always @(posedge clk) begin
    op_q <= operation;
    a_q  <= a;
    b_q  <= b;
  end

  ripple_carry_adder #(
      .N(N)
  ) dut (
      .operation(op_q),
      .a(a_q),
      .b(b_q),
      .sum(s),
      .ovf(o)
  );

  always @(posedge clk) begin
    sum <= s;
    ovf <= o;
  end
endmodule


module adder_bench_cla #(
    parameter N = 32
) (
    input  wire         clk,
    input  wire         operation,
    input  wire [N-1:0] a,
    input  wire [N-1:0] b,
    output reg  [N-1:0] sum,
    output reg          ovf
);
  reg          op_q;
  reg  [N-1:0] a_q, b_q;
  wire [N-1:0] s;
  wire         o;

  always @(posedge clk) begin
    op_q <= operation;
    a_q  <= a;
    b_q  <= b;
  end

  carry_lookahead #(
      .N(N)
  ) dut (
      .operation(op_q),
      .a(a_q),
      .b(b_q),
      .sum(s),
      .ovf(o)
  );

  always @(posedge clk) begin
    sum <= s;
    ovf <= o;
  end
endmodule
