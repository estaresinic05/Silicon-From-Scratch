/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         ALU Control Unit
 * Author:         Elliot Staresinic
 * Date:           2026-05-25
 *
 * Description:
 *   This module implements a small, combinational control 
 *   unit that takes as input the fetched instruction, as 
 *   well as the 2-bit ALUOp signal from the main CPU control
 *   unit. The funct3 and funct7 fields of the instruction 
 *   are then extracted in order to generate the proper 
 *   4-bit ALU operation control signal. 
 *
 * Interface:
 *   Inputs:
 *     funct3      - funct3 field from instruction
 *     funct7Bit5  - bit 5 from the funct7 field
 *     opcode      - opcode field of instruction
 *     ALUOp       - 2-bit control sent from main CPU CU
 *
 *   Outputs:
 *     ALUControl  - 4-bit ALU control signal
 *
 *******************************************************/

module alu_control (
    input  wire [2:0] funct3,
    input  wire       funct7Bit5,
    input  wire [6:0] opcode,
    input  wire [1:0] ALUOp,
    output reg  [3:0] ALUControl
);
  wire isRtype;
  assign isRtype = (opcode == 7'b0110011);

  always @(*) begin
    case (ALUOp)
      2'b00:   ALUControl = 4'b0010;  //addition (lw/sw)
      2'b01:   ALUControl = 4'b0110;  //subtraction (beq/bne)
      2'b10: begin  // R-type and I-type decode (and blt)
        case (funct3)
          3'b000:  ALUControl = (funct7Bit5 && isRtype) ? 4'b0110 :  // sub
                                                          4'b0010;  // add/addi
          3'b111:  ALUControl = 4'b0000;  // and/andi
          3'b110:  ALUControl = 4'b0001;  // or/ori
          3'b010:  ALUControl = 4'b0111;  // slt
          3'b100:  ALUControl = 4'b0111;  // blt
          default: ALUControl = 4'b0000;
        endcase
      end
      default: ALUControl = 4'b0000;
    endcase
  end

endmodule
