/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Hazard Detection Unit
 * Author:         Elliot Staresinic
 * Date:           2026-08-01
 *
 * Description:
 *   This module implements a small, combinational unit
 *   that detects the data hazards which cannot be resolved
 *   by forwarding alone, and stalls the front of the
 *   pipeline until the needed operand is available. It
 *   holds the PC and the IF/ID pipe register, and asserts
 *   stall to zero out the control fields of the ID/EX pipe
 *   register, inserting a bubble. Writes to x0 are ignored,
 *   as x0 is hardwired to zero and never carries a real
 *   value. Note that the datapath ORs stall with IDFlush,
 *   which originates elsewhere, since both insert a bubble
 *   by the same mechanism.
 *
 *   Two classes of hazard are detected. The first is the
 *   load-use hazard, where a load sits in EX and the
 *   instruction in ID reads its destination register. The
 *   loaded value is not available until the end of MEM, so
 *   it cannot be forwarded to the ALU in time and the
 *   pipeline stalls one cycle. All other ALU operand
 *   hazards are covered by the EX-stage forwarding unit.
 *
 *   The second class arises because branches resolve in ID
 *   rather than EX. A branch needs its comparison operands
 *   one stage earlier than an ordinary instruction does, so
 *   an ALU result still being computed in EX is also too
 *   late, not just a load. Any register-writing instruction
 *   in EX whose destination matches a branch source
 *   therefore forces a stall, which is why this condition
 *   qualifies on regWrite rather than memRead. A load in
 *   MEM forces a further stall, since EX/MEM carries the
 *   computed address rather than the loaded data. A load
 *   immediately preceding a branch consequently stalls
 *   twice: once from the ID/EX condition, then again from
 *   the EX/MEM condition as the load advances. No counter
 *   or state is required, as the multi-cycle stall emerges
 *   from consecutive single-cycle detections. Operands
 *   available in EX/MEM or MEM/WB are handled by the
 *   separate ID-stage branch forwarding unit.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage it lives in.
 *   All three outputs are IFID_ because this is ID stage logic;
 *   IFID_pcWrite gates a register in IF, but the decision is made
 *   here, in decode.
 *
 * Interface:
 *   Inputs:
 *     IFID_branch     - 3-bit one-hot branch type, 000 is no branch
 *     IFID_rs1        - rs1 field from IF/ID pipe register
 *     IFID_rs2        - rs2 field from IF/ID pipe register
 *     IDEX_rd         - rd field from ID/EX pipe register
 *     EXMEM_rd        - rd field from EX/MEM pipe register
 *     IDEX_memRead    - memRead control from ID/EX pipe register
 *     IDEX_regWrite   - regfile write enable from ID/EX pipe register
 *     EXMEM_memRead   - memRead control from EX/MEM pipe register
 *
 *   Outputs:
 *     IFID_pcWrite    - PC write enable, deasserted to hold PC
 *     IFID_write      - IF/ID write enable, deasserted to hold
 *     IFID_stall      - zeroes ID/EX control fields to insert a NOP
 *
 *                       All three are active such that the pipeline
 *                       advances normally by default; a detected
 *                       hazard drives IFID_pcWrite and IFID_write low
 *                       and IFID_stall high for that cycle.
 *
 *******************************************************/

module hzrd_detection_unit (
    input  wire [2:0] IFID_branch,
    input  wire [4:0] IFID_rs1,
    input  wire [4:0] IFID_rs2,
    input  wire [4:0] IDEX_rd,
    input  wire [4:0] EXMEM_rd,
    input  wire       IDEX_memRead,
    input  wire       IDEX_regWrite,
    input  wire       EXMEM_memRead,
    output reg        IFID_pcWrite,
    output reg        IFID_write,
    output reg        IFID_stall
);

  wire is_branch = |IFID_branch;  // NO_BRANCH is 3'b000

  always @(*) begin
    // defaults: pipeline advances normally
    IFID_pcWrite = 1'b1;
    IFID_write   = 1'b1;
    IFID_stall   = 1'b0;

    // load-use hazard: load in EX, its result needed by instruction in ID
    if (IDEX_memRead && (IDEX_rd != 5'd0)
                     && ((IDEX_rd == IFID_rs1) ||
                         (IDEX_rd == IFID_rs2))) begin
      IFID_pcWrite = 1'b0;  // hold PC
      IFID_write   = 1'b0;  // hold IF/ID
      IFID_stall   = 1'b1;  // zero ID/EX control -> bubble
    end

    // branch operand produced in EX: result not yet computed.
    // Covers ALU ops and loads alike; a load picks up its second
    // stall cycle from the EX/MEM condition below.
    if (is_branch && IDEX_regWrite && (IDEX_rd != 5'd0)
                  && ((IDEX_rd == IFID_rs1) ||
                      (IDEX_rd == IFID_rs2))) begin
      IFID_pcWrite = 1'b0;
      IFID_write   = 1'b0;
      IFID_stall   = 1'b1;
    end

    // branch operand produced by a load in MEM: EX/MEM holds the
    // computed address, not the loaded data.
    if (is_branch && EXMEM_memRead && (EXMEM_rd != 5'd0)
                  && ((EXMEM_rd == IFID_rs1) ||
                      (EXMEM_rd == IFID_rs2))) begin
      IFID_pcWrite = 1'b0;
      IFID_write   = 1'b0;
      IFID_stall   = 1'b1;
    end
  end

endmodule
