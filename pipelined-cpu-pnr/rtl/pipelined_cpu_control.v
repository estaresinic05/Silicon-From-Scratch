/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Pipelined CPU Control Unit
 * Author:         Elliot Staresinic
 * Date:           2026-08-02
 *
 * Description:
 *   This module implements the main control unit for a
 *   pipelined, RISC-V CPU. The opcode, funct3, and funct7
 *   fields of each instruction are fed to this control
 *   unit, which then determines the configuration of all
 *   control signals at its output, including the 4-bit ALU
 *   operation. Folding the ALU decode in here removes the
 *   separate ALU control unit and narrows the ID/EX
 *   pipeline register, since only the 4-bit operation needs
 *   to be carried forward rather than a 2-bit ALUOp plus the
 *   funct fields. All signals are decoded in the ID stage and
 *   pipelined to the stage that consumes them. This unit
 *   is purely combinational and does not use a finite
 *   state machine. Note that IFID_funct7_5 is only meaningful
 *   for R-type instructions; for I-type it is imm[10] and
 *   is ignored. Branch instructions are resolved in the ID
 *   stage by the branch comparison unit, so they leave the
 *   ALU operation at its default.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage it lives in.
 *   Decode happens in the ID stage, which is fed by the IF/ID
 *   register, so both the instruction fields coming in and the
 *   control signals going out are IFID_. Each control signal is
 *   then carried down the pipe by the datapath and takes on the
 *   prefix of whichever register it has reached.
 *
 * Interface:
 *   Inputs:
 *     IFID_opcode      - bits [6:0] of the instruction
 *     IFID_funct3      - funct3 field of instruction
 *     IFID_funct7_5    - bit 5 of the funct7 field, R-type only
 *
 *   Outputs:
 *     IFID_branch      - 3-bit one-hot beq, bne, or blt
 *     IFID_memRead     - control signal to read data memory
 *     IFID_memToReg    - mux sel signal for load vs arithmetic
 *     IFID_operation   - 4-bit ALU operation control signal
 *     IFID_memWrite    - control signal to write data memory
 *     IFID_ALUsrc      - mux sel signal to send immediate to ALU
 *     IFID_regWrite    - control signal to write register file
 *
 *******************************************************/

module pipelined_cpu_control (
    input  wire [6:0] IFID_opcode,
    input  wire [2:0] IFID_funct3,
    input  wire       IFID_funct7_5,
    output reg  [2:0] IFID_branch,
    output reg        IFID_memRead,
    output reg        IFID_memToReg,
    output reg  [3:0] IFID_operation,
    output reg        IFID_memWrite,
    output reg        IFID_ALUsrc,
    output reg        IFID_regWrite
);

  always @(*) begin

    IFID_branch    = 3'b000;
    IFID_memRead   = 1'b0;
    IFID_memToReg  = 1'b0;
    IFID_operation = 4'b0010;  // add is the safe idle operation
    IFID_memWrite  = 1'b0;
    IFID_ALUsrc    = 1'b0;
    IFID_regWrite  = 1'b0;

    case (IFID_opcode)

      7'b0000011: begin        // lw
        IFID_memRead   = 1'b1;
        IFID_memToReg  = 1'b1;
        IFID_operation = 4'b0010;  // add to form the address
        IFID_ALUsrc    = 1'b1;
        IFID_regWrite  = 1'b1;
      end

      7'b0100011: begin        // sw
        IFID_memWrite  = 1'b1;
        IFID_operation = 4'b0010;  // add to form the address
        IFID_ALUsrc    = 1'b1;
      end

      7'b1100011: begin        // SB-type, resolved in ID; ALU unused
        case (IFID_funct3)
          3'b000:  IFID_branch = 3'b100;  // beq
          3'b001:  IFID_branch = 3'b010;  // bne
          3'b100:  IFID_branch = 3'b001;  // blt
          default: IFID_branch = 3'b000;
        endcase
      end

      7'b0110011: begin        // R-type
        IFID_regWrite = 1'b1;
        case (IFID_funct3)
          3'b000:  IFID_operation = IFID_funct7_5 ? 4'b0110 : 4'b0010;  // sub : add
          3'b111:  IFID_operation = 4'b0000;                            // and
          3'b110:  IFID_operation = 4'b0001;                            // or
          3'b010:  IFID_operation = 4'b0111;                            // slt
          default: IFID_operation = 4'b0000;
        endcase
      end

      7'b0010011: begin        // I-type; IFID_funct7_5 is imm[10] here, ignored
        IFID_ALUsrc   = 1'b1;
        IFID_regWrite = 1'b1;
        case (IFID_funct3)
          3'b000:  IFID_operation = 4'b0010;  // addi
          3'b111:  IFID_operation = 4'b0000;  // andi
          3'b110:  IFID_operation = 4'b0001;  // ori
          3'b010:  IFID_operation = 4'b0111;  // slti
          default: IFID_operation = 4'b0000;
        endcase
      end

      default: ;               // defaults above hold

    endcase
  end

endmodule
