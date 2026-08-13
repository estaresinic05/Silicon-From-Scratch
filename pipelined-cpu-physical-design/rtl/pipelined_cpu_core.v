/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Pipelined CPU Core
 * Author:         Elliot Staresinic
 * Date:           2026-08-08
 *
 * Description:
 *   This module stitches together the datapath, the main
 *   control unit, the hazard detection unit and the two
 *   forwarding units. It is everything the processor is
 *   except its memories, which appear here as interface
 *   pins rather than as instances.
 *
 *   THIS IS THE MODULE THAT GOES THROUGH SYNTHESIS AND
 *   PLACE AND ROUTE. It is the top of the physical design
 *   copy in pipelined-cpu-pnr. The verified simulation
 *   design lives in pipelined-cpu and is not touched by
 *   anything in this directory.
 *
 *   The split exists because a memory is not built from
 *   standard cells. It has no gate level view, so a placer
 *   has nothing to place and the run fails on it. Real
 *   processors are partitioned the same way, with the
 *   caches sitting outside the core boundary and their
 *   ports on it.
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
 *   -------Synthesis observability (dbg_*)-------
 *   These carry no functional weight. They exist because a module whose only
 *   ports are clk and reset has NO primary outputs, so every net is
 *   unreachable and synthesis dead-code elimination deletes the entire CPU.
 *   Exposing the architectural writes keeps the whole datapath live, and is
 *   what a real debug or trace port would carry anyway.
 *
 * Interface:
 *   Inputs:
 *     clk           - clock
 *     reset         - asynchronous reset
 *     imem_rdata    - instruction returned by the instruction memory
 *     dmem_rdata    - word returned by the data memory
 *
 *   Outputs:
 *     imem_addr     - byte address of the instruction to fetch
 *     dmem_addr     - byte address of the data word to read or write
 *     dmem_wdata    - word to store
 *     dmem_write    - store enable
 *     dmem_read     - load enable
 *     dbg_pc        - fetch program counter
 *     dbg_wb_addr   - register file write address
 *     dbg_wb_data   - register file write data
 *     dbg_wb_enable - register file write enable
 *
 *******************************************************/

module pipelined_cpu_core (
    input  wire        clk,
    input  wire        reset,
    /*--------- instruction memory interface ---------*/
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    /*------------ data memory interface ------------*/
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_write,
    output wire        dmem_read,
    input  wire [31:0] dmem_rdata,
    /*------------------- debug -------------------*/
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

  /* THE RESET IS ASYNCHRONOUS AND THE PORT DRIVES IT DIRECTLY.
     `set_false_path -from [get_ports reset]` in the SDC covers every flop's
     reset pin, which is correct for a single-clock design with no reset domain
     crossing: asserting asynchronously needs no timing, and there is no second
     clock for the release to be unrelated to.

     A reset synchroniser was built and evaluated for this design on 12 August.
     It closed the recovery and removal checks that the false path waives, and
     it broke gate-level simulation from the first instruction of the program,
     reproducibly, across two synchroniser variants and at every corner. That
     was established by a controlled A/B and the synchroniser is not part of
     the design that ships. */
  pipelined_cpu_datapath datapath (
      .clk(clk),
      .reset(reset),
      .IFID_branch(IFID_branch),
      .IFID_memRead(IFID_memRead),
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
      .imem_addr(imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_write(dmem_write),
      .dmem_read(dmem_read),
      .dmem_rdata(dmem_rdata),
      .dbg_pc(dbg_pc),
      .dbg_wb_addr(dbg_wb_addr),
      .dbg_wb_data(dbg_wb_data),
      .dbg_wb_enable(dbg_wb_enable)
  );

endmodule
