/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Immediate Generator
 * Author:         Elliot Staresinic
 * Date:           2026-05-24
 *
 * Description:
 *   This module generates the properly sign-extended
 *   immediate value for RV32I instructions based on
 *   the instruction opcode and encoding format.
 *
 * Supported formats:
 *     - I-type
 *     - S-type
 *     - SB-type
 *     - U-type
 *     - UJ-type
 *
 * Interface:
 *   Inputs:
 *     inst  - 32-bit instruction word
 *
 *   Outputs:
 *     imm   - 32-bit sign-extended immediate
 *
 *******************************************************/
module imm_gen (
    input  wire [31:0] inst,
    output reg  [31:0] imm
);
  wire [6:0] opcode;
  assign opcode = inst[6:0];

  always @(*) begin
    case (opcode)
      7'b0010011, 7'b1100111, 7'b0000011:  // I-type
      imm = {{20{inst[31]}}, inst[31:20]};

      7'b0100011:  // S-type
      imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};

      7'b1100011:  // SB-type
      imm = {{19{inst[31]}}, //sign extension
             inst[31], 
             inst[7], 
             inst[30:25], 
             inst[11:8], 
             1'b0};

      7'b0110111, 7'b0010111:  // U-type
      imm = {inst[31:12], 12'b0};

      7'b1101111:  // UJ-type
      imm = {{11{inst[31]}},  //sign extension
             inst[31], 
             inst[19:12], 
             inst[20], 
             inst[30:21], 
             1'b0};

      default: imm = 32'b0;

    endcase
  end

endmodule
