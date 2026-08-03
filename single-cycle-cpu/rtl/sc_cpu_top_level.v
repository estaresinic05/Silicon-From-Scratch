/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Single Cycle CPU
 * Author:         Elliot Staresinic
 * Date:           2026-05-26
 *
 * Description:
 *   This module stitches together the datapath, main 
 *   control unit, and ALU control unit to form the top
 *   level module for a single cycle RISC-V CPU. This
 *   module only takes as input clk and reset signals, 
 *   and all other signals are internal. This
 *   implementation doesn't use any pipelining, and uses
 *   a Harvard architecture with separate instruction and 
 *   data memories. It can handle R-type, I-type, S-type,
 *   and SB-type instruction formats for arithmetic, loads
 *   and immediate arithmetic, stores, and conditional
 *   branching respectively. This implementation uses a 
 *   two-read-port and one-write-port register file. An
 *   immediate generation unit generates the proper offset
 *   for branching and immediate arithmetic depnding on
 *   on the instruction.
 *
 * Interface:
 *   Inputs:
 *     clk        - clock
 *     reset      - asynchronous reset
 *
 * Synthesis parameters:
 *   IMEM_WORDS / DMEM_WORDS size the two memories. They default to 256, which
 *   is what simulation uses and what the testbench assumes. The STA flow in
 *   Verilog/CPU/sta overrides them to 32 so the memories do not synthesize into
 *   thousands of flip-flops that bury the CPU logic in the timing report. The
 *   program is 30 instructions and touches two data words, so 32 is sufficient.
 *
 *******************************************************/

module sc_cpu_top_level #(
    parameter integer IMEM_WORDS = 256,
    parameter integer DMEM_WORDS = 256
) (
    input  wire        clk,
    input  wire        reset,
    // Synthesis observability. Without primary outputs the whole CPU is dead
    // code and synthesis deletes it. See the datapath header.
    output wire [31:0] dbg_pc,
    output wire [ 4:0] dbg_wb_addr,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_wb_enable
);

  wire [6:0] opcode;
  wire [2:0] funct3;
  wire       funct7_5;

  wire [2:0] branch;
  wire       memRead;
  wire       memToReg;
  wire [1:0] ALUOp;
  wire       memWrite;
  wire       ALUsrc;
  wire       regWrite;

  wire [3:0] ALUControl;

  sc_cpu_control control_unit (
      .opcode(opcode),
      .funct3(funct3),
      .branch(branch),
      .memRead(memRead),
      .memToReg(memToReg),
      .ALUOp(ALUOp),
      .memWrite(memWrite),
      .ALUsrc(ALUsrc),
      .regWrite(regWrite)
  );

  sc_cpu_datapath #(
      .IMEM_WORDS(IMEM_WORDS),
      .DMEM_WORDS(DMEM_WORDS)
  ) datapath (
      .clk(clk),
      .reset(reset),
      .branch(branch),
      .memRead(memRead),
      .memToReg(memToReg),
      .operation(ALUControl),
      .memWrite(memWrite),
      .ALUsrc(ALUsrc),
      .regWrite(regWrite),
      .opcode(opcode),
      .funct3(funct3),
      .funct7_5(funct7_5),
      .dbg_pc(dbg_pc),
      .dbg_wb_addr(dbg_wb_addr),
      .dbg_wb_data(dbg_wb_data),
      .dbg_wb_enable(dbg_wb_enable)
  );

  alu_control alu_control_unit (
      .funct3(funct3),
      .funct7Bit5(funct7_5),
      .opcode(opcode),
      .ALUOp(ALUOp),
      .ALUControl(ALUControl)
  );

endmodule
