/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Branch Forwarding Unit
 * Author:         Elliot Staresinic
 * Date:           2026-08-01
 *
 * Description:
 *   This module implements a small, combinational unit
 *   that resolves read-after-write data hazards for the
 *   ID stage of the pipeline, which is needed because
 *   branches resolve in ID rather than EX. It compares
 *   the source registers of the instruction in ID against
 *   the destination registers of the two instructions
 *   ahead of it, in MEM and WB, and generates mux select
 *   signals to steer the newer result into the comparator
 *   inputs rather than using a stale value read from the
 *   register file. An EX/MEM match takes priority over a
 *   MEM/WB match, since EX/MEM holds the more recent
 *   result. Writes to x0 are ignored, as x0 is hardwired
 *   to zero and never carries a real value.
 *
 *   Note that EX/MEM is forwarded without qualifying on
 *   memRead, since a load in MEM whose destination is a
 *   branch operand is stalled by the hazard detection
 *   unit and cannot reach this comparison. The two
 *   modules are coupled in that respect.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage it lives in.
 *   The outputs are IFID_ because they select operands in the
 *   ID stage, which is fed by the IF/ID register.
 *
 * Interface:
 *   Inputs:
 *     IFID_rs1        - rs1 field from IF/ID pipe register
 *     IFID_rs2        - rs2 field from IF/ID pipe register
 *     EXMEM_rd        - rd field from EX/MEM pipe register
 *     MEMWB_rd        - rd field from MEM/WB pipe register
 *     EXMEM_regWrite  - regfile write enable from EX/MEM
 *     MEMWB_regWrite  - regfile write enable from MEM/WB
 *
 *   Outputs:
 *     IFID_forwardA   - 2-bit mux select for comparator input A
 *     IFID_forwardB   - 2-bit mux select for comparator input B
 *
 *                       00 - no forwarding, use register file
 *                       10 - forward ALU result from EX/MEM
 *                       01 - forward write-back data from MEM/WB
 *
 *******************************************************/

module branch_fwd_unit (
    input  wire [4:0] IFID_rs1,
    input  wire [4:0] IFID_rs2,
    input  wire [4:0] EXMEM_rd,
    input  wire [4:0] MEMWB_rd,
    input  wire       EXMEM_regWrite,
    input  wire       MEMWB_regWrite,
    output reg  [1:0] IFID_forwardA,
    output reg  [1:0] IFID_forwardB
);

  always @(*) begin
    // defaults: no forwarding, read from register file
    IFID_forwardA = 2'b00;
    IFID_forwardB = 2'b00;

    // ---- IFID_forwardA (rs1) ----
    if (EXMEM_regWrite && (EXMEM_rd != 5'd0)
                       && (EXMEM_rd == IFID_rs1))
      IFID_forwardA = 2'b10;  // from EX/MEM
    else if (MEMWB_regWrite && (MEMWB_rd != 5'd0)
                            && (MEMWB_rd == IFID_rs1))
      IFID_forwardA = 2'b01;  // from MEM/WB

    // ---- IFID_forwardB (rs2) ----
    if (EXMEM_regWrite && (EXMEM_rd != 5'd0)
                       && (EXMEM_rd == IFID_rs2))
      IFID_forwardB = 2'b10;
    else if (MEMWB_regWrite && (MEMWB_rd != 5'd0)
                            && (MEMWB_rd == IFID_rs2))
      IFID_forwardB = 2'b01;
  end

endmodule
