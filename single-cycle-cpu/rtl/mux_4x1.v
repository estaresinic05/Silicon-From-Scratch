/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         4x1 Multiplexer
 * Author:         Elliot Staresinic
 * Date:           2026-04-29
 *
 * Description:
 *   This module implements a simple 4x1 multiplexer
 *   which chooses between four input signals.
 *
 * Interface:
 *   Inputs:
 *     in0   - signal on line 0 (N-bit)
 *     in1   - signal on line 1 (N-bit)
 *     in2   - signal on line 2 (N-bit)
 *     in3   - signal on line 3 (N-bit)
 *     sel   - 2-bit select signal
 *
 *   Outputs:
 *     out   - output of mux (N-bit)
 *
 *******************************************************/

module mux_4x1 #(
    parameter N = 1
) (
    input  wire [N-1:0] in0,
    input  wire [N-1:0] in1,
    input  wire [N-1:0] in2,
    input  wire [N-1:0] in3,
    input  wire [  1:0] sel,
    output wire [N-1:0] out
);

  assign out = (sel == 2'b00) ? in0 : (sel == 2'b01) ? in1 : (sel == 2'b10) ? in2 : in3;


endmodule
