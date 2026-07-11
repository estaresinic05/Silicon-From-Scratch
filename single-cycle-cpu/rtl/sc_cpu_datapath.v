/*******************************************************
 * Project:        RISC-V Single Cycle CPU Design
 * Module:         Single Cycle CPU Datapath
 * Author:         Elliot Staresinic
 * Date:           2026-05-24
 *
 * Description:
 *   This module implements the datapath for a single
 *   cycle, RISC-V CPU. It takes as input control signals
 *   from the control unit as well as clk and reset. This
 *   implementation doesn't use any pipelining, and uses
 *   a Harvard architecture with separate instruction and 
 *   data memories. It can handle R-type, I-type, S-type,
 *   and SB-type instruction formats for arithmetic, loads
 *   and immediate arithmetic, stores, and conditional
 *   branching respectively. This implementation uses a 
 *   two-read-port and one-write-port register file. An
 *   immediate generation unit generates the proper offset
 *   for branching and immediate arithmetic depnding on
 *   on the instruction.
 *
 * Interface:
 *   Inputs:
 *     clk        - clock
 *     reset      - asynchronous reset
 *     branch     - 3-bit one's hot encoded control signal
 *     memRead    - control signal to read data memory
 *     memToReg   - mux sel signal for load vs arithmetic
 *     operation  - 4-bit control signal for ALU from ALU CU
 *     memWrite   - control signal to write data memory
 *     ALUsrc     - mux sel signal to send immediate to ALU
 *     regWrite   - control signal to write register file
 *
 *  Outputs:
 *    opcode      - opcode field of instruction for control unit 
 *    funct3      - funct3 field of the instruction
 *    funct7_5    - 5th bit of the funct7 field of the instruction 
 *
 *******************************************************/
module sc_cpu_datapath (
    input  wire       clk,
    input  wire       reset,
    input  wire [2:0] branch,     //one's hot encoding for NO_BRANCH (000), BEQ, BNE, and BLT
    input  wire       memRead,
    input  wire       memToReg,
    input  wire [3:0] operation,
    input  wire       memWrite,
    input  wire       ALUsrc,
    input  wire       regWrite,
    output wire [6:0] opcode,
    output wire [2:0] funct3,
    output wire       funct7_5
);

  //branching conditions
  wire BEQ = branch[2];  // 100
  wire BNE = branch[1];  // 010
  wire BLT = branch[0];  // 001

  //intermediate signals
  reg  [31:0] pc;
  wire [31:0] fetchedInstr, readData1, readData2, dataToWrite, ALUMuxOut,
              ALUresult, wordToLoad, pcPlus4, pcPlusImm, branchOrInc4;
  wire [31:0] immediate;
  wire equalsZero, overflow, lessThan;

  //instruction memory with 256 word depth
  instruct_mem #(256) instruction_memory (
      .instAddress(pc),  //word alignment will be perfomed in data_mem module
      .instruction(fetchedInstr)
  );

  assign opcode   = fetchedInstr[6:0];
  assign funct3   = fetchedInstr[14:12];
  assign funct7_5 = fetchedInstr[30];

  //immediate generation
  imm_gen immediate_generation (
      .inst(fetchedInstr),
      .imm(immediate)
  );

  /**********Register File**********/
  reg_file registers (
      .readAddress1(fetchedInstr[19:15]),  //rs1
      .readAddress2(fetchedInstr[24:20]),  //rs2
      .writeAddress(fetchedInstr[11:7]),  //rd
      .writeData(dataToWrite),
      .writeEnable(regWrite),
      .clk(clk),
      .data1(readData1),
      .data2(readData2)
  );
  /*********************************/

  /****32-bit ALU and Source Mux****/
  mux_2x1 #(32) ALU_src_mux (
      .in0(readData2),
      .in1(immediate),
      .sel(ALUsrc),
      .out(ALUMuxOut)
  );


  alu_full #(32) ALU (
      .a(readData1),
      .b(ALUMuxOut),
      .control(operation),
      .result(ALUresult),
      .ovf(overflow),  // RISC-V arithmetic naturally wrap around on overflow so we ignore this
      .zero(equalsZero)
  );

  assign lessThan = (ALUresult == 32'b1);  // lessThan gets set if result equals 1
  /*********************************/

  /**Data Memory and Load Word Mux**/
  data_mem #(256) data_memory (
      .dataAddress(ALUresult),  //word alignment will be perfomed in data_mem module
      .writeData(readData2),
      .writeEnable(memWrite),
      .readEnable(memRead),
      .clk(clk),
      .readData(wordToLoad)
  );

  mux_2x1 #(32) data_to_write (
      .in0(ALUresult),
      .in1(wordToLoad),
      .sel(memToReg),
      .out(dataToWrite)
  );
  /*********************************/

  /********PC Increment Logic********/
  ripple_carry_adder #(32) pc_plus_4 (
      .operation(1'b0),  //hardwired to add
      .a(pc),
      .b(32'd4),
      .sum(pcPlus4)
  );

  ripple_carry_adder #(32) pc_plus_imm (
      .operation(1'b0),  //hardwired to add
      .a(pc),
      .b(immediate),
      .sum(pcPlusImm)
  );

  mux_2x1 #(32) branch_or_inc_4 (
      .in0(pcPlus4),
      .in1(pcPlusImm),
      .sel((equalsZero & BEQ) | (~equalsZero & BNE) | (lessThan & BLT)),  // branch if equal, not equal, or less than
      .out(branchOrInc4)
  );

  always @(posedge clk or posedge reset) begin
    if (reset) pc <= 0;
    else pc <= branchOrInc4;
  end

  /**********************************/


endmodule
