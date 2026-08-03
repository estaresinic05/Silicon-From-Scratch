/*******************************************************
 * Project:        RISC-V CPU Design
 * Module:         Single Cycle CPU Control Unit
 * Author:         Elliot Staresinic
 * Date:           2026-05-25
 *
 * Description:
 *   This module implements the main control unit for a 
 *   single cylce, RISC-V CPU. The opcode of each instruction
 *   is fed to this control unit, which then determines
 *   the configuration of all control signals at its output. 
 *   This control unit is purely combinational because this
 *   is a single cycle design, and therefore doesn't utilize
 *   a finite state machine.
 *
 * Interface:
 *   Inputs:
 *     opcode  - bits [6:0] of the instruction
 *     funct3  - funct3 field of instruction
 *
 *   Outputs:
 *     branch    - 3-bit one's hot beq, bne, or blt
 *     memRead   - control signal to read data memory
 *     memToReg  - mux sel signal for load vs arithmetic
 *     ALUOp     - 2-bit ALU operation helper control signal
 *     memWrite  - control signal to write data memroy
 *     ALUsrc    - mux sel signal to send immediate to ALU
 *     regWrite  - control signal to write register file
 *
 *******************************************************/

module sc_cpu_control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    output reg  [2:0] branch,
    output reg        memRead,
    output reg        memToReg,
    output reg  [1:0] ALUOp,
    output reg        memWrite,
    output reg        ALUsrc,
    output reg        regWrite
);

  always @(*) begin

    branch   = 3'b000;
    memRead  = 1'b0;
    memToReg = 1'b0;
    ALUOp    = 2'b00;
    memWrite = 1'b0;
    ALUsrc   = 1'b0;
    regWrite = 1'b0;

    case (opcode)
      7'b0000011: begin   // lw
        memRead = 1'b1;   // read word from memory
        memToReg = 1'b1;  // send word to register
        ALUOp = 2'b00;    // addition
        ALUsrc = 1'b1;    // use immediate as offset
        regWrite = 1'b1;  // write word to register
      end
      7'b0100011: begin  // sw
        memWrite = 1'b1; // write word to memory
        ALUOp = 2'b00;   //addition
        ALUsrc = 1'b1;   // use immediate as offset
      end
      7'b1100011: begin
        case (funct3)
          3'b000: begin      // beq
            branch = 3'b100;
            ALUOp  = 2'b01;  //subtraction
          end
          3'b001: begin      // bne
            branch = 3'b010;
            ALUOp  = 2'b01;  //subtraction
          end
          3'b100: begin      // blt
            branch = 3'b001;
            ALUOp  = 2'b10;  //determined by funct3/7
          end
          default: branch = 3'b000;
        endcase
      end
      7'b0110011: begin  // add, sub, and, or, slt
        ALUOp = 2'b10;   //determined by funct3/7
        regWrite = 1'b1;
      end
      7'b0010011: begin  // addi, andi, ori
        ALUOp = 2'b10;   // determined by funct3/7
        ALUsrc = 1'b1;   // send immediate to ALU
        regWrite = 1'b1;
      end
      default: branch = 3'b000;
    endcase
  end

endmodule
