/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         ALU Forwarding Unit
 * Author:         Elliot Staresinic
 * Date:           2026-08-01
 *
 * Description:
 *   This module implements a small, combinational unit
 *   that resolves read-after-write data hazards for the
 *   EX stage of the pipeline. It compares the source
 *   registers of the instruction in EX against the
 *   destination registers of the two instructions ahead
 *   of it, in MEM and WB, and generates mux select
 *   signals to forward the newer result directly to the
 *   ALU inputs rather than reading a stale value from
 *   the register file. An EX/MEM match takes priority
 *   over a MEM/WB match, since EX/MEM holds the more
 *   recent result. Writes to x0 are ignored, as x0 is
 *   hardwired to zero and never carries a real value.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage it lives in.
 *   The outputs are IDEX_ because they select operands in the
 *   EX stage, which is fed by the ID/EX register.
 *
 * Interface:
 *   Inputs:
 *     IDEX_rs1        - rs1 field from ID/EX pipe register
 *     IDEX_rs2        - rs2 field from ID/EX pipe register
 *     EXMEM_rd        - rd field from EX/MEM pipe register
 *     MEMWB_rd        - rd field from MEM/WB pipe register
 *     EXMEM_regWrite  - regfile write enable from EX/MEM
 *     MEMWB_regWrite  - regfile write enable from MEM/WB
 *
 *   Outputs:
 *     IDEX_forwardA   - 2-bit mux select for ALU operand A
 *     IDEX_forwardB   - 2-bit mux select for ALU operand B
 *
 *                       00 - no forwarding, use register file
 *                       10 - forward ALU result from EX/MEM
 *                       01 - forward write-back data from MEM/WB
 *
 *******************************************************/

module alu_fwd_unit (
    input  wire [4:0] IDEX_rs1,
    input  wire [4:0] IDEX_rs2,
    input  wire [4:0] EXMEM_rd,
    input  wire [4:0] MEMWB_rd,
    input  wire       EXMEM_regWrite,
    input  wire       MEMWB_regWrite,
    output reg  [1:0] IDEX_forwardA,
    output reg  [1:0] IDEX_forwardB
);

  always @(*) begin
    // defaults: no forwarding, read from register file
    IDEX_forwardA = 2'b00;
    IDEX_forwardB = 2'b00;

    // ---- IDEX_forwardA ----
    if (EXMEM_regWrite && (EXMEM_rd != 5'd0)
                       && (EXMEM_rd == IDEX_rs1))
      IDEX_forwardA = 2'b10;  // from EX/MEM
    else if (MEMWB_regWrite && (MEMWB_rd != 5'd0)
                            && (MEMWB_rd == IDEX_rs1))
      IDEX_forwardA = 2'b01;  // from MEM/WB

    // ---- IDEX_forwardB ----
    if (EXMEM_regWrite && (EXMEM_rd != 5'd0)
                       && (EXMEM_rd == IDEX_rs2))
      IDEX_forwardB = 2'b10;
    else if (MEMWB_regWrite && (MEMWB_rd != 5'd0)
                            && (MEMWB_rd == IDEX_rs2))
      IDEX_forwardB = 2'b01;
  end

endmodule
