/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         ID-Stage Branch Comparison Unit
 * Author:         Elliot Staresinic
 * Date:           2026-08-02
 *
 * Description:
 *   This module resolves branch conditions in the ID
 *   stage. Each operand passes through a 4x1 forwarding
 *   mux before comparison, so that a branch dependent on
 *   an in-flight instruction sees the correct value. The
 *   select encoding is 0 for register file data, 1 for
 *   the EX/MEM ALU result, and 2 for the MEM/WB writeback
 *   value; input 3 is unused and tied low. The unit is
 *   purely combinational and produces two flags for the
 *   branch control logic. Note that the hazard unit must
 *   stall rather than forward when the EX/MEM producer is
 *   a load, since EXMEM_aluResult holds the address at
 *   that point and not the loaded data.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage it lives in.
 *   This whole module is ID stage logic, so its selects and its
 *   flags are IFID_; the two forwarded operands keep the prefix
 *   of the stage they arrive from.
 *
 * Interface:
 *   Inputs:
 *     IFID_readData1     - 32-bit register file read port 1 output (rs1)
 *     IFID_readData2     - 32-bit register file read port 2 output (rs2)
 *     EXMEM_aluResult    - 32-bit forwarded ALU result from the EX/MEM stage
 *     MEMWB_dataToWrite  - 32-bit forwarded writeback value from the MEM/WB stage
 *     IFID_forwardA      - 2-bit operand A forward select from the forwarding unit
 *     IFID_forwardB      - 2-bit operand B forward select from the forwarding unit
 *
 *   Outputs:
 *     IFID_isEqual       - asserted when the selected operands are equal
 *     IFID_lessThan      - asserted when operand A is less than operand B, signed
 *
 *******************************************************/

module branch_comp (
    input  wire [31:0] IFID_readData1,
    input  wire [31:0] IFID_readData2,
    input  wire [31:0] EXMEM_aluResult,
    input  wire [31:0] MEMWB_dataToWrite,
    input  wire [ 1:0] IFID_forwardA,
    input  wire [ 1:0] IFID_forwardB,
    output wire        IFID_isEqual,
    output wire        IFID_lessThan
);

  wire [31:0] IFID_aMuxOut, IFID_bMuxOut;

  // Select encoding matches branch_fwd_unit and the ALU forwarding path:
  // 00 register file, 01 MEM/WB writeback value, 10 EX/MEM ALU result.
  mux_4x1 #(32) a_mux (
      .in0(IFID_readData1),
      .in1(MEMWB_dataToWrite),
      .in2(EXMEM_aluResult),
      .in3(32'b0),
      .sel(IFID_forwardA),
      .out(IFID_aMuxOut)
  );

  mux_4x1 #(32) b_mux (
      .in0(IFID_readData2),
      .in1(MEMWB_dataToWrite),
      .in2(EXMEM_aluResult),
      .in3(32'b0),
      .sel(IFID_forwardB),
      .out(IFID_bMuxOut)
  );

  assign IFID_isEqual  = (IFID_aMuxOut == IFID_bMuxOut);
  assign IFID_lessThan = ($signed(IFID_aMuxOut) < $signed(IFID_bMuxOut));

endmodule
