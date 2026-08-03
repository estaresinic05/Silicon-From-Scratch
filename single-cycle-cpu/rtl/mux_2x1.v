/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         2x1 Multiplexer
 * Author:         Elliot Staresinic
 * Date:           2026-04-29
 *
 * Description:
 *   This module implements a simple 2x1 multiplexer
 *   which chooses between two input signals.
 *
 * Interface:
 *   Inputs:
 *     in0   - signal on line 0 (N-bit)
 *     in1   - signal on line 1 (N-bit)
 *     sel   - 1-bit select signal
 *
 *   Outputs:
 *     out   - output of mux (N-bit)
 *
 *******************************************************/

module mux_2x1 #(
    parameter N = 1
) (
    input  wire [N-1:0] in0,
    input  wire [N-1:0] in1,
    input  wire         sel,
    output wire [N-1:0] out
);

  assign out = sel ? in1 : in0;


endmodule
