/*****************************************************************
 * Project:        RISC-V CPU Design
 * Module:         Pipelined CPU Datapath
 * Author:         Elliot Staresinic
 * Date:           2026-08-02
 *
 * Description:
 *   This module implements the datapath for a five stage
 *   pipelined RISC-V CPU. It takes as input control signals
 *   from the control unit, the hazard detection unit and the
 *   two forwarding units, as well as clk and reset. It uses
 *   a Harvard architecture with separate instruction and
 *   data memories. It can handle R-type, I-type, S-type,
 *   and SB-type instruction formats for arithmetic, loads
 *   and immediate arithmetic, stores, and conditional
 *   branching respectively. This implementation uses a
 *   two-read-port and one-write-port register file. An
 *   immediate generation unit generates the proper offset
 *   for branching and immediate arithmetic depending on
 *   the instruction. Branches resolve in the ID stage.
 *
 * Signal naming:
 *   Every signal carries the name of the pipeline register it
 *   emerged from, so the prefix says which stage the signal
 *   lives in:
 *
 *     IF_     before the IF/ID register        (fetch)
 *     IFID_   out of the IF/ID register        (decode)
 *     IDEX_   out of the ID/EX register        (execute)
 *     EXMEM_  out of the EX/MEM register       (memory)
 *     MEMWB_  out of the MEM/WB register       (writeback)
 *
 *   Only the fetch stage has a bare prefix, because no
 *   pipeline register precedes it. A signal computed in the
 *   ID stage from IF/ID contents is therefore IFID_, not ID_.
 *
 *   -------Synthesis observability (dbg_*)-------
 *   These carry no functional weight and nothing in simulation reads them.
 *   They exist because a module whose only ports are clk and reset has NO
 *   primary outputs, so every net is unreachable and synthesis dead-code
 *   elimination deletes the entire CPU. Exposing the architectural writes
 *   keeps the whole datapath live, and is what a real debug or trace port
 *   would carry anyway.
 *     dbg_pc        - fetch program counter
 *     dbg_wb_addr   - register file write address
 *     dbg_wb_data   - register file write data
 *     dbg_wb_enable - register file write enable
 *
 * Interface:
 *   Inputs:
 *     clk                - clock
 *     reset              - asynchronous reset
 *     --------Inputs from Main Control Unit--------
 *     IFID_branch        - 3-bit one-hot branch type
 *     IFID_memRead       - control signal to read data memory
 *     IFID_memToReg      - mux sel signal for load vs arithmetic
 *     IFID_operation     - 4-bit ALU operation
 *     IFID_memWrite      - control signal to write data memory
 *     IFID_ALUsrc        - mux sel signal to send immediate to ALU
 *     IFID_regWrite      - control signal to write register file
 *     IFID_flush         - clears the IF/ID pipe register
 *     IDEX_flush         - clears the ID/EX pipe register
 *     EXMEM_flush        - clears the EX/MEM pipe register
 *     ------Inputs from Hazard Detection Unit------
 *     IFID_pcWrite       - control signal to write the PC
 *     IFID_write         - control signal to write the IF/ID pipe register
 *     IFID_stall         - zeroes ID/EX control to insert a bubble
 *     ---------Inputs from Forwarding Units--------
 *     IDEX_forwardA      - EX stage operand A forward select
 *     IDEX_forwardB      - EX stage operand B forward select
 *     IFID_forwardA      - ID stage branch operand A forward select
 *     IFID_forwardB      - ID stage branch operand B forward select
 *
 *  Outputs:
 *    IFID_opcode         - opcode field of instruction for control unit
 *    IFID_funct3         - funct3 field of the instruction
 *    IFID_funct7_5       - 5th bit of the funct7 field of the instruction
 *    IFID_takeBranch     - branch condition met, resolved in ID. Drives the
 *                          IF/ID flush in the top level
 *    -------Outputs to Hazard Detection Unit-------
 *    IFID_rs1            - source register from IF/ID pipe reg
 *    IFID_rs2            - source register from IF/ID pipe reg
 *    IDEX_rd             - destination register from ID/EX pipe register
 *    IDEX_memRead        - memRead control from ID/EX pipe reg
 *    IDEX_regWrite       - regWrite control from ID/EX pipe reg
 *    EXMEM_memRead       - memRead control from EX/MEM pipe reg
 *    ---------Outputs to Forwarding Units----------
 *    IDEX_rs1            - source register from ID/EX pipe register
 *    IDEX_rs2            - source register from ID/EX pipe register
 *    EXMEM_rd            - destination register from EX/MEM pipe register
 *    MEMWB_rd            - destination register from MEM/WB pipe register
 *    EXMEM_regWrite      - control signal to write regfile from EX/MEM
 *    MEMWB_regWrite      - control signal to write regfile from MEM/WB
 *
 *****************************************************************/

module pipelined_cpu_datapath (
    input  wire       clk,
    input  wire       reset,
    input  wire [2:0] IFID_branch,      //one-hot: NO_BRANCH (000), BEQ, BNE, BLT
    input  wire       IFID_memRead,
    input  wire       IFID_memToReg,
    input  wire [3:0] IFID_operation,
    input  wire       IFID_memWrite,
    input  wire       IFID_ALUsrc,
    input  wire       IFID_regWrite,
    input  wire       IFID_flush,
    input  wire       IDEX_flush,
    input  wire       EXMEM_flush,
    input  wire       IFID_pcWrite,
    input  wire       IFID_write,
    input  wire       IFID_stall,
    input  wire [1:0] IDEX_forwardA,
    input  wire [1:0] IDEX_forwardB,
    input  wire [1:0] IFID_forwardA,
    input  wire [1:0] IFID_forwardB,
    output wire [6:0] IFID_opcode,
    output wire [2:0] IFID_funct3,
    output wire       IFID_funct7_5,
    output wire       IFID_takeBranch,
    output wire [4:0] IFID_rs1,
    output wire [4:0] IFID_rs2,
    output reg  [4:0] IDEX_rs1,
    output reg  [4:0] IDEX_rs2,
    output reg  [4:0] IDEX_rd,
    output reg        IDEX_memRead,
    output reg        IDEX_regWrite,
    output reg  [4:0] EXMEM_rd,
    output reg        EXMEM_memRead,
    output reg        EXMEM_regWrite,
    output reg  [4:0] MEMWB_rd,
    output reg        MEMWB_regWrite,
    /*--------- instruction memory interface ---------*/
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    /*------------ data memory interface ------------*/
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_write,
    output wire        dmem_read,
    input  wire [31:0] dmem_rdata,
    output wire [31:0] dbg_pc,
    output wire [ 4:0] dbg_wb_addr,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_wb_enable
);

  //branching conditions
  wire BEQ = IFID_branch[2];  // 100
  wire BNE = IFID_branch[1];  // 010
  wire BLT = IFID_branch[0];  // 001

  /*---------------- IF stage nets ----------------*/
  reg  [31:0] IF_pc;
  wire [31:0] IF_instr;
  wire [31:0] IF_pcPlus4;
  wire [31:0] IF_branchOrInc4;

  /*---------------- ID stage nets ----------------*/
  reg  [31:0] IFID_instr, IFID_pc;
  wire [ 4:0] IFID_rd;
  wire [31:0] IFID_imm;
  wire [31:0] IFID_readData1, IFID_readData2;
  wire [31:0] IFID_pcPlusImm;
  wire        IFID_isEqual, IFID_lessThan;

  /*---------------- EX stage nets ----------------*/
  reg  [31:0] IDEX_readData1, IDEX_readData2, IDEX_imm;
  reg  [ 3:0] IDEX_operation;
  reg         IDEX_ALUsrc, IDEX_memWrite, IDEX_memToReg;
  wire [31:0] IDEX_forwardAOut, IDEX_forwardBOut;
  wire [31:0] IDEX_aluMuxOut;
  wire [31:0] IDEX_aluResult;
  wire        IDEX_overflow, IDEX_zero;

  /*--------------- MEM stage nets ----------------*/
  reg  [31:0] EXMEM_aluResult, EXMEM_storeData;
  reg         EXMEM_memWrite, EXMEM_memToReg;
  wire [31:0] EXMEM_wordToLoad;

  /*---------------- WB stage nets ----------------*/
  reg  [31:0] MEMWB_memData, MEMWB_aluResult;
  reg         MEMWB_memToReg;
  wire [31:0] MEMWB_dataToWrite;

  /*================= IF stage =================*/
  ripple_carry_adder #(32) pc_plus_4 (
      .operation(1'b0),  //hardwired to add
      .a(IF_pc),
      .b(32'd4),
      .sum(IF_pcPlus4)
  );

  // The instruction memory is not instantiated in this copy of the design. It
  // appears on the boundary as imem_addr and imem_rdata instead. A memory is
  // not built from standard cells and has no gate level view, so place and
  // route has nothing to place for one. Every real core is partitioned this
  // way, with the caches outside the core boundary.
  assign imem_addr = IF_pc;  //word alignment was performed inside instruct_mem
  assign IF_instr  = imem_rdata;

  /*================= ID stage =================*/
  assign IFID_opcode   = IFID_instr[6:0];
  assign IFID_funct3   = IFID_instr[14:12];
  assign IFID_funct7_5 = IFID_instr[30];
  assign IFID_rs1      = IFID_instr[19:15];
  assign IFID_rs2      = IFID_instr[24:20];
  assign IFID_rd       = IFID_instr[11:7];

  //immediate generation
  imm_gen immediate_generation (
      .inst(IFID_instr),
      .imm (IFID_imm)
  );

  /**********Register File**********/
  reg_file registers (
      .readAddress1(IFID_rs1),  //rs1
      .readAddress2(IFID_rs2),  //rs2
      .writeAddress(MEMWB_rd),  //rd
      .writeData(MEMWB_dataToWrite),
      .writeEnable(MEMWB_regWrite),
      .clk(clk),
      .data1(IFID_readData1),
      .data2(IFID_readData2)
  );
  /*********************************/

  ripple_carry_adder #(32) pc_plus_imm (
      .operation(1'b0),  //hardwired to add
      .a(IFID_pc),
      .b(IFID_imm),
      .sum(IFID_pcPlusImm)
  );

  branch_comp branch_logic (
      .IFID_readData1(IFID_readData1),
      .IFID_readData2(IFID_readData2),
      .EXMEM_aluResult(EXMEM_aluResult),
      .MEMWB_dataToWrite(MEMWB_dataToWrite),
      .IFID_forwardA(IFID_forwardA),
      .IFID_forwardB(IFID_forwardB),
      .IFID_isEqual(IFID_isEqual),
      .IFID_lessThan(IFID_lessThan)
  );

  assign IFID_takeBranch = (IFID_isEqual && BEQ) ||
                           (~IFID_isEqual && BNE) ||
                           (IFID_lessThan && BLT);  // taken: eq / ne / signed lt

  // in0 is IF_pcPlus4, the sequential next PC, taken when the branch is not
  // taken. in1 is the branch target computed in ID.
  mux_2x1 #(32) branch_or_inc_4 (
      .in0(IF_pcPlus4),
      .in1(IFID_pcPlusImm),
      .sel(IFID_takeBranch),
      .out(IF_branchOrInc4)
  );

  /*================= EX stage =================*/
  mux_4x1 #(32) ALU_forwardA_mux (
      .in0(IDEX_readData1),
      .in1(MEMWB_dataToWrite),
      .in2(EXMEM_aluResult),
      .in3(32'b0),
      .sel(IDEX_forwardA),
      .out(IDEX_forwardAOut)
  );

  mux_4x1 #(32) ALU_forwardB_mux (
      .in0(IDEX_readData2),
      .in1(MEMWB_dataToWrite),
      .in2(EXMEM_aluResult),
      .in3(32'b0),
      .sel(IDEX_forwardB),
      .out(IDEX_forwardBOut)
  );

  /****32-bit ALU and Source Mux****/
  mux_2x1 #(32) ALU_src_mux (
      .in0(IDEX_forwardBOut),
      .in1(IDEX_imm),
      .sel(IDEX_ALUsrc),
      .out(IDEX_aluMuxOut)
  );

  alu_full #(32) ALU (
      .a(IDEX_forwardAOut),
      .b(IDEX_aluMuxOut),
      .control(IDEX_operation),
      .result(IDEX_aluResult),
      .ovf(IDEX_overflow),  // RISC-V arithmetic wraps on overflow, so unused
      .zero(IDEX_zero)      // branches resolve in ID, so unused
  );

  /*================ MEM stage =================*/
  /**Data Memory Interface and Load Word Mux**/
  // Hoisted out for the same reason as the instruction memory, see the IF stage.
  assign dmem_addr        = EXMEM_aluResult;  //word alignment was performed inside data_mem
  assign dmem_wdata       = EXMEM_storeData;
  assign dmem_write       = EXMEM_memWrite;
  assign dmem_read        = EXMEM_memRead;
  assign EXMEM_wordToLoad = dmem_rdata;

  /*================= WB stage =================*/
  // memToReg is 1 for a load and 0 for everything else, and mux_2x1 selects
  // in1 when sel is high, so the LOADED word must be in1.
  mux_2x1 #(32) data_to_write (
      .in0(MEMWB_aluResult),
      .in1(MEMWB_memData),
      .sel(MEMWB_memToReg),
      .out(MEMWB_dataToWrite)
  );
  /*********************************/

  /*------- synthesis observability, see header -------*/
  assign dbg_pc        = IF_pc;
  assign dbg_wb_addr   = MEMWB_rd;
  assign dbg_wb_data   = MEMWB_dataToWrite;
  assign dbg_wb_enable = MEMWB_regWrite;

  /*****************************************************************
   * Sequential logic: the PC and the four pipeline registers
   *
   * Everything above this point is combinational or structural. This
   * is the only place state advances, and it is what makes this a
   * pipeline rather than a single-cycle datapath.
   *
   * Two rules govern the whole section:
   *
   *   HOLD vs BUBBLE. On a stall the FRONT of the pipe holds its
   *   contents, so the PC and IF/ID stop moving, while ID/EX zeroes
   *   its CONTROL fields. Those two behaviors together are what a
   *   bubble is: nothing new enters, and a NOP walks down the back
   *   half of the pipe in place of the instruction that was held.
   *
   *   ONLY THE FRONT EVER HOLDS. EX/MEM and MEM/WB are unconditional
   *   copies. Once an instruction is past ID it always advances;
   *   holding it there would leave two copies of it in flight.
   *****************************************************************/

  /*------------------ PC ------------------*/
  always @(posedge clk or posedge reset) begin
    if (reset) IF_pc <= 32'b0;
    else if (IFID_pcWrite) IF_pc <= IF_branchOrInc4;  // held low by a stall
  end

  /*----------------- IF/ID ----------------*/
  //
  // The asynchronous reset gets a branch of its OWN, and the synchronous flush
  // gets a separate one, even though they assign the same values. Folding them
  // into `if (reset || IFID_flush)` simulates correctly and CANNOT BE
  // SYNTHESIZED: an async-reset flip-flop has exactly one reset input, so a
  // reset branch that also depends on a synchronous signal has no cell to map
  // onto, and yosys stops with "Multiple edge sensitive events found for this
  // signal". Keep reset alone in the first branch.
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      IFID_instr <= 32'b0;
      IFID_pc    <= 32'b0;
    end else if (IFID_flush) begin
      // An all-zero instruction word has opcode 7'b0000000, which falls to
      // the default case in pipelined_cpu_control and leaves every control
      // signal deasserted. A zeroed IF/ID is therefore already a NOP.
      IFID_instr <= 32'b0;
      IFID_pc    <= 32'b0;
    end else if (IFID_write) begin
      IFID_instr <= IF_instr;
      IFID_pc    <= IF_pc;
    end
    // else: hold. This is the stall.
  end

  /*----------------- ID/EX ----------------*/
  // Reset alone in the first branch, bubble in the second. See the note on the
  // IF/ID register above for why these cannot be merged.
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      IDEX_regWrite  <= 1'b0;
      IDEX_memRead   <= 1'b0;
      IDEX_memWrite  <= 1'b0;
      IDEX_memToReg  <= 1'b0;
      IDEX_ALUsrc    <= 1'b0;
      IDEX_operation <= 4'b0010;
      IDEX_rs1       <= 5'b0;
      IDEX_rs2       <= 5'b0;
      IDEX_rd        <= 5'b0;
      IDEX_readData1 <= 32'b0;
      IDEX_readData2 <= 32'b0;
      IDEX_imm       <= 32'b0;
    end else if (IFID_stall || IDEX_flush) begin
      IDEX_regWrite  <= 1'b0;
      IDEX_memRead   <= 1'b0;
      IDEX_memWrite  <= 1'b0;
      IDEX_memToReg  <= 1'b0;
      IDEX_ALUsrc    <= 1'b0;
      IDEX_operation <= 4'b0010;  // add, matching the control unit's idle op
      // The register NUMBERS have to be zeroed too, not just the control
      // bits. The forwarding unit matches on rs/rd, so a bubble carrying a
      // stale rd would forward a result that is not going to be written.
      IDEX_rs1       <= 5'b0;
      IDEX_rs2       <= 5'b0;
      IDEX_rd        <= 5'b0;
      IDEX_readData1 <= 32'b0;
      IDEX_readData2 <= 32'b0;
      IDEX_imm       <= 32'b0;
    end else begin
      IDEX_readData1 <= IFID_readData1;
      IDEX_readData2 <= IFID_readData2;
      IDEX_imm       <= IFID_imm;
      IDEX_rs1       <= IFID_rs1;
      IDEX_rs2       <= IFID_rs2;
      IDEX_rd        <= IFID_rd;
      IDEX_operation <= IFID_operation;  // decoded in ID, consumed in EX
      IDEX_ALUsrc    <= IFID_ALUsrc;
      IDEX_memRead   <= IFID_memRead;
      IDEX_memWrite  <= IFID_memWrite;
      IDEX_memToReg  <= IFID_memToReg;
      IDEX_regWrite  <= IFID_regWrite;
    end
  end

  /*---------------- EX/MEM ----------------*/
  // Reset alone in the first branch, flush in the second. See the note on the
  // IF/ID register above for why these cannot be merged.
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      EXMEM_regWrite  <= 1'b0;
      EXMEM_memRead   <= 1'b0;
      EXMEM_memWrite  <= 1'b0;
      EXMEM_memToReg  <= 1'b0;
      EXMEM_rd        <= 5'b0;
      EXMEM_aluResult <= 32'b0;
      EXMEM_storeData <= 32'b0;
    end else if (EXMEM_flush) begin
      EXMEM_regWrite  <= 1'b0;
      EXMEM_memRead   <= 1'b0;
      EXMEM_memWrite  <= 1'b0;
      EXMEM_memToReg  <= 1'b0;
      EXMEM_rd        <= 5'b0;
      EXMEM_aluResult <= 32'b0;
      EXMEM_storeData <= 32'b0;
    end else begin
      EXMEM_aluResult <= IDEX_aluResult;
      // The FORWARDED operand B, not IDEX_readData2. A store whose value is
      // produced by the instruction just ahead of it would otherwise write a
      // stale word to memory: forwarding fixes the ALU inputs, and the store
      // data path needs the same fix.
      EXMEM_storeData <= IDEX_forwardBOut;
      EXMEM_rd        <= IDEX_rd;
      EXMEM_memRead   <= IDEX_memRead;
      EXMEM_memWrite  <= IDEX_memWrite;
      EXMEM_memToReg  <= IDEX_memToReg;
      EXMEM_regWrite  <= IDEX_regWrite;
    end
  end

  /*---------------- MEM/WB ----------------*/
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      MEMWB_regWrite  <= 1'b0;
      MEMWB_memToReg  <= 1'b0;
      MEMWB_rd        <= 5'b0;
      MEMWB_memData   <= 32'b0;
      MEMWB_aluResult <= 32'b0;
    end else begin
      // data_mem reads combinationally, so the loaded word is already valid
      // this cycle and can be captured at the end of MEM.
      MEMWB_memData   <= EXMEM_wordToLoad;
      MEMWB_aluResult <= EXMEM_aluResult;
      MEMWB_rd        <= EXMEM_rd;
      MEMWB_memToReg  <= EXMEM_memToReg;
      MEMWB_regWrite  <= EXMEM_regWrite;
    end
  end

endmodule
