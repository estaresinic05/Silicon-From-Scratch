/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Behavioural memories for core-level simulation
 * Author:         Elliot Staresinic
 * Date:           2026-08-10
 *
 * Description:
 *   The instruction and data memories, as the testbench sees them.
 *
 *   These are COPIES of pipelined-cpu/rtl/instruct_mem.v and data_mem.v,
 *   verbatim apart from the program path becoming a parameter. They live here
 *   because pipelined_cpu_core has memory PORTS rather than memory instances:
 *   a memory is not built from standard cells, so it cannot be placed, and it
 *   sits outside the block being implemented. Whatever drives those ports in
 *   simulation has to come from somewhere, and for the netlist that somewhere
 *   is the testbench.
 *
 *   THE MODELS MUST STAY IDENTICAL TO THE ONES IN pipelined-cpu/rtl. The whole
 *   point of the gate-level run is comparing the layout against the RTL result
 *   on the same terms, and a memory that behaves differently here would make
 *   the two incomparable while looking fine.
 *
 *   Both are ASYNCHRONOUS READ. That is what makes the single-cycle design in
 *   the sibling project single-cycle at all, and it is the assumption the SDC's
 *   memory interface budget stands on.
 *
 *******************************************************/

/*======================================================
 * Instruction memory: combinational read, loaded at time 0.
 *
 * Unloaded words read back as a real NOP rather than zero, because a fetch
 * past the end of the program must not decode as an illegal instruction.
 *====================================================*/
module instruct_mem #(
    parameter DEPTH = 256,
    parameter PROGRAM = "programs/program.mem"
) (
    input  wire [31:0] instAddress,
    output wire [31:0] instruction
);

  reg [31:0] memory[0:DEPTH-1];

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
      memory[i] = 32'h00000013;  // NOP
    end
    $readmemh(PROGRAM, memory);
  end

  assign instruction = (instAddress[31:2] < DEPTH) ? memory[instAddress[31:2]] : 32'b0;

endmodule


/*======================================================
 * Data memory: combinational read, synchronous write.
 *====================================================*/
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

  reg [31:0] memory[0:DEPTH-1];

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1) memory[i] = 32'b0;
  end

  always @(posedge clk) begin
    if (writeEnable && dataAddress[31:2] < DEPTH) memory[dataAddress[31:2]] <= writeData;
  end

  assign readData = (readEnable && dataAddress[31:2] < DEPTH) ? memory[dataAddress[31:2]] : 32'b0;

endmodule
