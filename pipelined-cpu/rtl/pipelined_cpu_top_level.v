/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Pipelined CPU
 * Author:         Elliot Staresinic
 * Date:           2026-08-02
 *
 * Description:
 *   This module stitches together the datapath, the main
 *   control unit, the hazard detection unit and the two
 *   forwarding units to form the top level module for a five
 *   stage pipelined RISC-V CPU. This module only takes as
 *   input clk and reset signals, and all other signals are
 *   internal. It uses a Harvard architecture with separate
 *   instruction and data memories. It can handle R-type,
 *   I-type, S-type, and SB-type instruction formats for
 *   arithmetic, loads and immediate arithmetic, stores, and
 *   conditional branching respectively. Branches resolve in
 *   the ID stage.
 *
 *   There is no separate ALU control unit. The main control
 *   unit decodes the 4-bit ALU operation directly, which
 *   narrows the ID/EX pipeline register since only the
 *   operation needs carrying forward rather than ALUOp plus
 *   the funct fields.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage it lives in:
 *
 *     IF_     before the IF/ID register        (fetch)
 *     IFID_   out of the IF/ID register        (decode)
 *     IDEX_   out of the ID/EX register        (execute)
 *     EXMEM_  out of the EX/MEM register       (memory)
 *     MEMWB_  out of the MEM/WB register       (writeback)
 *
 *   The hazard and forwarding units live here rather than
 *   inside the datapath, so that the datapath has exactly one
 *   source for every control signal it consumes.
 *
 * Synthesis parameters:
 *   IMEM_WORDS / DMEM_WORDS size the two memories. They default to 256, which
 *   is what simulation uses and what every testbench assumes. The STA flow in
 *   Verilog/CPU/sta overrides them to 32 so the memories do not synthesize into
 *   thousands of flip-flops that bury the CPU logic in the timing report. The
 *   program is 30 instructions and touches two data words, so 32 is sufficient.
 *
 *   -------Synthesis observability (dbg_*)-------
 *   These carry no functional weight and nothing in simulation reads them.
 *   They exist because a module whose only ports are clk and reset has NO
 *   primary outputs, so every net is unreachable and synthesis dead-code
 *   elimination deletes the entire CPU. Exposing the architectural writes
 *   keeps the whole datapath live, and is what a real debug or trace port
 *   would carry anyway.
 *     dbg_pc        - fetch program counter
 *     dbg_wb_addr   - register file write address
 *     dbg_wb_data   - register file write data
 *     dbg_wb_enable - register file write enable
 *
 * Interface:
 *   Inputs:
 *     clk        - clock
 *     reset      - asynchronous reset
 *
 *******************************************************/

module pipelined_cpu_top_level #(
    parameter integer IMEM_WORDS = 256,
    parameter integer DMEM_WORDS = 256
) (
    input  wire        clk,
    input  wire        reset,
    output wire [31:0] dbg_pc,
    output wire [ 4:0] dbg_wb_addr,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_wb_enable
);

  /*-------- instruction fields, out of IF/ID --------*/
  wire [6:0] IFID_opcode;
  wire [2:0] IFID_funct3;
  wire       IFID_funct7_5;

  /*----------- control signals, decoded in ID -----------*/
  wire [2:0] IFID_branch;
  wire       IFID_memRead;
  wire       IFID_memToReg;
  wire [3:0] IFID_operation;
  wire       IFID_memWrite;
  wire       IFID_ALUsrc;
  wire       IFID_regWrite;

  /*--------- register numbers, per pipe stage ---------*/
  wire [4:0] IFID_rs1, IFID_rs2;
  wire [4:0] IDEX_rs1, IDEX_rs2, IDEX_rd;
  wire [4:0] EXMEM_rd;
  wire [4:0] MEMWB_rd;

  /*------- control read back out of the pipe regs -------*/
  wire       IDEX_memRead, IDEX_regWrite;
  wire       EXMEM_memRead, EXMEM_regWrite;
  wire       MEMWB_regWrite;

  /*---------------- hazard and forwarding ----------------*/
  wire       IFID_pcWrite, IFID_write, IFID_stall;
  wire [1:0] IDEX_forwardA, IDEX_forwardB;
  wire [1:0] IFID_forwardA, IFID_forwardB;

  /*----------------------- flushes -----------------------*/
  wire       IFID_takeBranch;  // resolved in ID, out of the datapath

  // A taken branch is resolved in ID, so the only wrongly fetched instruction
  // is the one behind it and only IF/ID needs clearing. IDEX_flush and
  // EXMEM_flush stay low: nothing wrongly issued ever gets past ID.
  //
  // The stall qualifier is not optional. While the hazard unit stalls a branch
  // waiting on an operand, IFID_takeBranch is computed from data that is not
  // ready yet, and inside the IF/ID register the flush path is tested before
  // the write path. An unqualified flush would therefore clear IF/ID on a
  // stall cycle and destroy the branch instruction itself.
  wire       IFID_flush  = IFID_takeBranch && !IFID_stall;
  wire       IDEX_flush  = 1'b0;
  wire       EXMEM_flush = 1'b0;

  pipelined_cpu_control control_unit (
      .IFID_opcode(IFID_opcode),
      .IFID_funct3(IFID_funct3),
      .IFID_funct7_5(IFID_funct7_5),
      .IFID_branch(IFID_branch),
      .IFID_memRead(IFID_memRead),
      .IFID_memToReg(IFID_memToReg),
      .IFID_operation(IFID_operation),
      .IFID_memWrite(IFID_memWrite),
      .IFID_ALUsrc(IFID_ALUsrc),
      .IFID_regWrite(IFID_regWrite)
  );

  hzrd_detection_unit hazard_detection (
      .IFID_branch(IFID_branch),
      .IFID_rs1(IFID_rs1),
      .IFID_rs2(IFID_rs2),
      .IDEX_rd(IDEX_rd),
      .EXMEM_rd(EXMEM_rd),
      .IDEX_memRead(IDEX_memRead),
      .IDEX_regWrite(IDEX_regWrite),
      .EXMEM_memRead(EXMEM_memRead),
      .IFID_pcWrite(IFID_pcWrite),
      .IFID_write(IFID_write),
      .IFID_stall(IFID_stall)
  );

  alu_fwd_unit ALU_forward (
      .IDEX_rs1(IDEX_rs1),
      .IDEX_rs2(IDEX_rs2),
      .EXMEM_rd(EXMEM_rd),
      .MEMWB_rd(MEMWB_rd),
      .EXMEM_regWrite(EXMEM_regWrite),
      .MEMWB_regWrite(MEMWB_regWrite),
      .IDEX_forwardA(IDEX_forwardA),
      .IDEX_forwardB(IDEX_forwardB)
  );

  branch_fwd_unit branch_forward (
      .IFID_rs1(IFID_rs1),
      .IFID_rs2(IFID_rs2),
      .EXMEM_rd(EXMEM_rd),
      .MEMWB_rd(MEMWB_rd),
      .EXMEM_regWrite(EXMEM_regWrite),
      .MEMWB_regWrite(MEMWB_regWrite),
      .IFID_forwardA(IFID_forwardA),
      .IFID_forwardB(IFID_forwardB)
  );

  pipelined_cpu_datapath #(
      .IMEM_WORDS(IMEM_WORDS),
      .DMEM_WORDS(DMEM_WORDS)
  ) datapath (
      .clk(clk),
      .reset(reset),
      .IFID_branch(IFID_branch),
      .IFID_memRead(IFID_memRead),
      .IFID_memToReg(IFID_memToReg),
      .IFID_operation(IFID_operation),
      .IFID_memWrite(IFID_memWrite),
      .IFID_ALUsrc(IFID_ALUsrc),
      .IFID_regWrite(IFID_regWrite),
      .IFID_flush(IFID_flush),
      .IDEX_flush(IDEX_flush),
      .EXMEM_flush(EXMEM_flush),
      .IFID_pcWrite(IFID_pcWrite),
      .IFID_write(IFID_write),
      .IFID_stall(IFID_stall),
      .IDEX_forwardA(IDEX_forwardA),
      .IDEX_forwardB(IDEX_forwardB),
      .IFID_forwardA(IFID_forwardA),
      .IFID_forwardB(IFID_forwardB),
      .IFID_opcode(IFID_opcode),
      .IFID_funct3(IFID_funct3),
      .IFID_funct7_5(IFID_funct7_5),
      .IFID_takeBranch(IFID_takeBranch),
      .IFID_rs1(IFID_rs1),
      .IFID_rs2(IFID_rs2),
      .IDEX_rs1(IDEX_rs1),
      .IDEX_rs2(IDEX_rs2),
      .IDEX_rd(IDEX_rd),
      .IDEX_memRead(IDEX_memRead),
      .IDEX_regWrite(IDEX_regWrite),
      .EXMEM_rd(EXMEM_rd),
      .EXMEM_memRead(EXMEM_memRead),
      .EXMEM_regWrite(EXMEM_regWrite),
      .MEMWB_rd(MEMWB_rd),
      .MEMWB_regWrite(MEMWB_regWrite),
      .dbg_pc(dbg_pc),
      .dbg_wb_addr(dbg_wb_addr),
      .dbg_wb_data(dbg_wb_data),
      .dbg_wb_enable(dbg_wb_enable)
  );

endmodule
