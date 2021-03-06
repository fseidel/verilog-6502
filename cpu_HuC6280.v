`default_nettype none

/*
 * verilog model of HuC6280 CPU.
 *
 * Based on original 6502 "Arlet 6502 Core" by Arlet Ottens + 65C02 extension
 *
 * (C) Arlet Ottens, <arlet@c-scape.nl>
 *
 * Feel free to use this code in any project (commercial or not), as long as you
 * keep this message, and the copyright notice. This code is provided "as is",
 * without any warranties of any kind.
 *
 * Support for 65C02 instructions and addressing modes by David Banks and Ed
 * Spittles
 *
 * (C) 2016 David Banks and Ed Spittles
 *
 * Feel free to use this code in any project (commercial or not), as long as you
 * keep this message, and the copyright notice. This code is provided "as is",
 * without any warranties of any kind.
 *
 * Support for HuC6280 instructions and addressing modes by Ford Seidel and
 * Amolak Nagi
 * (C) 2018 Ford Seidel and Amolak Nagi
 *
 * Feel free to use this code in any project (commercial or not), as long as you
 * keep this message, and the copyright notice. This code is provided "as is",
 * without any warranties of any kind.
 */

/*
 * Note that not all 6502 interface signals are supported (yet).  The goal
 * is to create an Acorn Atom model, and the Atom didn't use all signals on
 * the main board.
 *
 * The data bus is implemented as separate read/write buses. Combine them
 * on the output pads if external memory is required.
 */

/*
 * Two things were needed to correctly implement 65C02 NOPs
 * 1. Ensure the microcode state machine uses an appropriate addressing mode for the opcode length
 * 2. Ensure there are no side-effects (e.g. register updates, memory stores, etc)
 *
 * If IMPLEMENT_NOPS is defined, the state machine is modified accordingly.
 */

`define IMPLEMENT_NOPS

/*
 * Two things were needed to correctly implement 65C02 BCD arithmentic
 * 1. The Z flag needs calculating over the BCD adjusted ALU output
 * 2. The N flag needs calculating over the BCD adjusted ALU output
 *
 * If IMPLEMENT_CORRECT_BCD_FLAGS is defined, this additional logic is added
 */

`define IMPLEMENT_CORRECT_BCD_FLAGS

//set this to get debugging aids
`define SIM

module cpu_HuC6280( clk, reset, AB_21, DO, EXT_out, RE, WE, IRQ1_n, IRQ2_n,
                    NMI, HSM, RDY_n, CE_n, CER_n, CE7_n, CEK_n);

input clk;              // CPU clock
input reset;            // reset signal
output wire [20:0] AB_21; // address bus (post-MMU)
output [7:0] DO;        // data out, write bus
input  [7:0] EXT_out;   // data driven by external peripherals
output RE;              // read enable
output WE;              // write enable
input IRQ1_n;           // interrupt request 1
input IRQ2_n;           // interrupt request 2
input NMI;              // non-maskable interrupt request
output reg HSM;         // high speed mode enabled
input RDY_n;            // Ready signal. Pauses CPU when RDY_n=1
output CE_n;            // ROM enable signal
output CER_n;           // RAM enable signal
output CE7_n;           // VDC enable signal
output CEK_n;           // VCE enable signal

//clocking
wire clk72_en, clk18_en;
clock_divider #(3)  clk72(.clk(clk), .reset(reset), .clk_en(clk72_en));
clock_divider #(12) clk18(.clk(clk), .reset(reset), .clk_en(clk18_en));

wire clk_en;
//assign clk_en = 1; //This line is nice for testing, but BE CAREFUL
assign clk_en = (HSM) ? clk72_en : clk18_en;


wire RDY_preMMU, RDY, MMU_stall;
assign RDY_preMMU = ~RDY_n & clk_en; //cheap hack to do variable clock speed
assign RDY = RDY_preMMU & ~MMU_stall;

wire [7:0] DI;         // data in, read bus  (for RAM)

  
//wire CE7_n;
//wire CEK_n;
wire CEP_n;
wire CET_n;
wire CEIO_n;
wire CECG_n; //Interrupt controller enable

wire TIQ_n;  // timer interrupt request

MAIN_RAM ram(.clock(clk), .address(AB_21[12:0]), .data(DO),
             .wren(WE & ~CER_n), .q(DI));
  

  /* //TODO: enable these
output CE_n;
output CER_n;
output CE7_n;
output CEK_n;
output CEP_n;
output CET_n;
output CEIO_n;
output CECG_n;
   */


/*
 * internal signals
 */
reg  [15:0] AB;         // Address bus (pre-MMU)
reg  [15:0] PC;         // Program Counter
reg  [7:0] ABL;         // Address Bus Register LSB
reg  [7:0] ABH;         // Address Bus Register MSB
wire [7:0] ADD;         // Adder Hold Register (registered in ALU)

reg  [7:0] DIHOLD;      // Hold for Data In
reg  DIHOLD_valid;      //
wire [7:0] DIMUX;       //
reg  DIMUX_IO;          // next cycle should read from internal IO buffer

reg  [7:0] IRHOLD;      // Hold for Instruction register
reg  IRHOLD_valid;      // Valid instruction in IRHOLD

reg  [7:0] AXYS[3:0];   // A, X, Y and S register file

reg  C = 0;             // carry flag (init at zero to avoid X's in ALU sim)
reg  Z = 0;             // zero flag
reg  I = 0;             // interrupt flag
reg  D = 0;             // decimal flag
reg  V = 0;             // overflow flag
reg  T = 0;             // T flag
reg  N = 0;             // negative flag
wire AZ;                // ALU Zero flag
wire AZ1;               // ALU Zero flag (BCD adjusted)
reg  AZ2;               // ALU Second Zero flag, set using TSB/TRB semantics
wire AV;                // ALU overflow flag
wire AN;                // ALU negative flag
wire AN1;               // ALU negative flag (BCD adjusted)
wire HC;                // ALU half carry

reg  [7:0] AI;          // ALU Input A
reg  [7:0] BI;          // ALU Input B
wire [7:0] IR;          // Instruction register
reg  [7:0] DO;          // Data Out
wire [7:0] AO;          // ALU output after BCD adjustment
reg  RE;                // Read Enable
reg  WE;                // Write Enable
reg  CI;                // Carry In
wire CO;                // Carry Out
wire [7:0] PCH       = PC[15:8];
wire [7:0] PCL       = PC[7:0];

reg        bbx_status;    // a cheap hack to make my life easier (fseidel)
reg [7:0]  bbx_disp;      // ditto
reg [7:0]  tst_mask;      // I'm starting to think these aren't hacks
reg [7:0]  bsr_disp;      // hrm...

reg        NMI_edge  = 0;       // captured NMI edge

reg [1:0] regsel;                       // Select A, X, Y or S register
wire [7:0] regfile = AXYS[regsel];      // Selected register output

parameter
        SEL_A    = 2'd0,
        SEL_S    = 2'd1,
        SEL_X    = 2'd2,
        SEL_Y    = 2'd3;

/*
 * define some signals for watching in simulator output
 */


`ifdef SIM
wire [7:0]   A = AXYS[SEL_A];           // Accumulator
wire [7:0]   X = AXYS[SEL_X];           // X register
wire [7:0]   Y = AXYS[SEL_Y];           // Y register
wire [7:0]   S = AXYS[SEL_S];           // Stack pointer
`endif

wire [7:0] P = { N, V, T, 1'b1, D, I, Z, C };

/*
 * instruction decoder/sequencer
 */

reg [6:0] state;

/*
 * control signals
 */

reg PC_inc;             // Increment PC
reg [15:0] PC_temp;     // intermediate value of PC

reg [1:0] src_reg;      // source register index
reg [1:0] dst_reg;      // destination register index

reg index_y;            // if set, then Y is index reg rather than X
reg load_reg;           // loading a register (A, X, Y, S) in this instruction
reg inc;                // increment
reg write_back;         // set if memory is read/modified/written
reg load_only;          // LDA/LDX/LDY instruction
reg store;              // doing store (STA/STX/STY)
reg adc_sbc;            // doing ADC/SBC
reg compare;            // doing CMP/CPY/CPX
reg shift;              // doing shift/rotate instruction
reg rotate;             // doing rotate (no shift)
reg backwards;          // backwards branch
reg cond_true;          // branch condition is true
reg [3:0] cond_code;    // condition code bits from instruction
reg shift_right;        // Instruction ALU shift/rotate right
reg alu_shift_right;    // Current cycle shift right enable
reg [3:0] op;           // Main ALU operation for instruction
reg [3:0] alu_op;       // Current cycle ALU operation
reg [2:0] mask_shift;    // bit select for RMB/SMB instructions
reg adc_bcd;            // ALU should do BCD style carry
reg adj_bcd;            // results should be BCD adjusted

/*
 * some flip flops to remember we're doing special instructions. These
 * get loaded at the DECODE state, and used later
 */
reg store_zero;         // doing STZ instruction
reg trb_ins;            // doing TRB instruction
reg txb_ins;            // doing TSB/TRB instruction
reg rmb_ins;            // doing RMB instruction
reg xmb_ins;            // doing SMB/RMB instruction
reg bbx_ins;            // doing BBS/BBR instruction
reg bbr_ins;            // doing BBR instruction
reg bit_ins;            // doing BIT instruction
reg bit_ins_nv;         // doing BIT instruction that will update the n and v
                        // flags (i.e. not BIT imm)
reg txx_ins;            // doing transfer instruction (COMBINATIONAL!)
reg tii_ins;            // doing TII instruction
reg tdd_ins;            // doing TDD instruction
reg tin_ins;            // doing TIN instruction
reg tia_ins;            // doing TIA instruction
reg tai_ins;            // doing TAI instruction
reg swp_ins;            // doing SXY, SAX, SAY instruction
reg sax_ins;            // doing SAX instruction
reg clr_ins;            // doing CLA/CLX/CLY instruction
reg tst_ins;            // doing TST instruction
reg tst_x;              // TST instruction is x-relative
reg [1:0] stx_dst;      // destination of an ST{0,1,2} instruction
  
reg plp;                // doing PLP instruction
reg php;                // doing PHP instruction
reg clc;                // clear carry
reg sec;                // set carry
reg cld;                // clear decimal
reg sed;                // set decimal
reg cli;                // clear interrupt
reg sei;                // set interrupt
reg clv;                // clear overflow
reg brk;                // doing BRK

reg res;                // in reset

wire IRQ, IRQ1, IRQ2, TIQ;
assign IRQ = IRQ1 | IRQ2 | TIQ; //global signal to indicate presence of IRQ

  /*
//IRQ debug
always @(posedge IRQ) begin
  if(IRQ) begin
    $stop;
  end
end
*/  
always @(posedge IRQ) begin
  $display("IRQ triggered!");
  //$stop;
end


  
/*
 * DIMUX handling
 * TODO: handle cases where I/O buffer is not written
 */
wire [7:0] INT_out, TIMER_out, cur_read;
reg [7:0] IO_out, latched_read;
reg     read_delay; //selects whether or not we go for a real read on next clock

/*
always @(posedge clk) begin
  if(reset)
    read_delay <= 0;
  else if(RDY)
    read_delay <= 0;
  else
    read_delay <= 1;
end
*/
  
assign cur_read = (DIMUX_IO) ? IO_out : DI;

//assign DIMUX = (read_delay) ? latched_read : cur_read;
assign DIMUX = latched_read;
  
//only latch reads when we are mid-cycle
always @(posedge clk) begin
  if( RDY )
    latched_read <= cur_read;
end

wire [7:0] PAD_out;
assign PAD_out = 8'b1011_1111; // Region bit == Japan

wire IO_sel; //will be set by MMU
always @* begin
  IO_out  = 8'hxx;
  DIMUX_IO = 0;
  if(RE) begin
    if(~CECG_n) begin //interrupt controller
      IO_out   = INT_out;
      DIMUX_IO = 1;
    end
    else if (~CET_n) begin //timer
      IO_out   = TIMER_out;
      DIMUX_IO = 1;
    end
    else if(~CEIO_n) begin //controller/IO port
      IO_out   = PAD_out;
      DIMUX_IO = 1;
    end
    else if(~CE_n) begin //ROM
      IO_out   = EXT_out;
      DIMUX_IO = 1;
    end
    else if(IO_sel) begin //external peripherals
      IO_out   = EXT_out;
      DIMUX_IO = 1;
    end
  end
end


/*
 * Interrupt controller
 */
wire TIQ_ack;

INT_ctrl ictrl(.clk(clk), .reset(reset), .RDY(RDY), .re(RE), .we(WE),
	       .CECG_n(CECG_n), .addr(AB_21[1:0]),
               .dIn(DO), .dOut(INT_out),
               .TIQ_n(TIQ_n), .IRQ1_n(IRQ1_n), .IRQ2_n(IRQ2_n),
               .TIQ(TIQ), .IRQ1(IRQ1), .IRQ2(IRQ2),
               .TIQ_ack(TIQ_ack));
/*
 * Timer
 */
TIMER itimer(.clk(clk), .reset(reset), //stupid name because of keywords
             .re(RE), .we(WE),
             .clk_en(clk72_en), .dIn(DO), .dOut(TIMER_out),
             .CET_n(CET_n), .addr(AB_21[0]), .TIQ_ack(TIQ_ack), .TIQ_n(TIQ_n));


/*
 * Block transfer bookkeeping
 */
reg [15:0] txx_src;
reg [15:0] txx_dst;
reg [15:0] txx_len;
reg        txx_alt;


/*
 * ALU operations
 */

parameter
        OP_OR  = 4'b1100,
        OP_AND = 4'b1101,
        OP_EOR = 4'b1110,
        OP_ADD = 4'b0011,
        OP_SUB = 4'b0111,
        OP_ROL = 4'b1011,
        OP_A   = 4'b1111;

/*
 * Microcode state machine. Basically, every addressing mode has its own
 * path through the state machine. Additional information, such as the
 * operation, source and destination registers are decoded in parallel, and
 * kept in separate flops.
 */

parameter
  ABS0    = 7'd0,  // ABS     - fetch LSB
  ABS1    = 7'd1,  // ABS     - fetch MSB
  ABSX0   = 7'd2,  // ABS, X  - fetch LSB and send to ALU (+X)
  ABSX1   = 7'd3,  // ABS, X  - fetch MSB and send to ALU (+Carry)
  ABSX2   = 7'd4,  // ABS, X  - Wait for ALU (only if needed)
  BRA0    = 7'd5,  // Branch  - fetch offset and send to ALU (+PC[7:0])
  BRA1    = 7'd6,  // Branch  - fetch opcode, and send PC[15:8] to ALU
  BRA2    = 7'd7,  // Branch  - fetch opcode (if page boundary crossed)
  BRK0    = 7'd8,  // BRK/IRQ - push PCH, send S to ALU (-1)
  BRK1    = 7'd9,  // BRK/IRQ - push PCL, send S to ALU (-1)
  BRK2    = 7'd10, // BRK/IRQ - push P, send S to ALU (-1)
  BRK3    = 7'd11, // BRK/IRQ - write S, and fetch @ fffe
  DECODE  = 7'd12, // IR is valid, decode instruction, and write prev reg
  FETCH   = 7'd13, // fetch next opcode, and perform prev ALU op
  INDX0   = 7'd14, // (ZP,X)  - fetch ZP address, and send to ALU (+X)
  INDX1   = 7'd15, // (ZP,X)  - fetch LSB at ZP+X, calculate ZP+X+1
  INDX2   = 7'd16, // (ZP,X)  - fetch MSB at ZP+X+1
  INDX3   = 7'd17, // (ZP,X)  - fetch data
  INDY0   = 7'd18, // (ZP),Y  - fetch ZP address, and send ZP to ALU (+1)
  INDY1   = 7'd19, // (ZP),Y  - fetch at ZP+1, and send LSB to ALU (+Y)
  INDY2   = 7'd20, // (ZP),Y  - fetch data, and send MSB to ALU (+Carry)
  INDY3   = 7'd21, // (ZP),Y) - fetch data (if page boundary crossed)
  JMP0    = 7'd22, // JMP     - fetch PCL and hold
  JMP1    = 7'd23, // JMP     - fetch PCH
  JMPI0   = 7'd24, // JMP IND - fetch LSB and send to ALU for delay (+0)
  JMPI1   = 7'd25, // JMP IND - fetch MSB, proceed with JMP0 state
  JSR0    = 7'd26, // JSR     - push PCH, save LSB, send S to ALU (-1)
  JSR1    = 7'd27, // JSR     - push PCL, send S to ALU (-1)
  JSR2    = 7'd28, // JSR     - write S
  JSR3    = 7'd29, // JSR     - fetch MSB
  PULL0   = 7'd30, // PLP/PLA/PLX/PLY - save next op in IRHOLD, send S to ALU (+1)
  PULL1   = 7'd31, // PLP/PLA/PLX/PLY - fetch data from stack, write S
  PULL2   = 7'd32, // PLP/PLA/PLX/PLY - prefetch op, but don't increment PC
  PUSH0   = 7'd33, // PHP/PHA/PHX/PHY - send A to ALU (+0)
  PUSH1   = 7'd34, // PHP/PHA/PHX/PHY - write A/P, send S to ALU (-1)
  READ    = 7'd35, // Read memory for read/modify/write (INC, DEC, shift)
  REG     = 7'd36, // Read register for reg-reg transfers
  RTI0    = 7'd37, // RTI     - send S to ALU (+1)
  RTI1    = 7'd38, // RTI     - read P from stack
  RTI2    = 7'd39, // RTI     - read PCL from stack
  RTI3    = 7'd40, // RTI     - read PCH from stack
  RTI4    = 7'd41, // RTI     - read PCH from stack
  RTS0    = 7'd42, // RTS     - send S to ALU (+1)
  RTS1    = 7'd43, // RTS     - read PCL from stack
  RTS2    = 7'd44, // RTS     - write PCL to ALU, read PCH
  RTS3    = 7'd45, // RTS     - load PC and increment
  WRITE   = 7'd46, // Write memory for read/modify/write
  ZP0     = 7'd47, // Z-page  - fetch ZP address
  ZPX0    = 7'd48, // ZP, X   - fetch ZP, and send to ALU (+X)
  ZPX1    = 7'd49, // ZP, X   - load from memory
  IND0    = 7'd50, // (ZP)    - fetch ZP address, and send to ALU (+0)
  JMPIX0  = 7'd51, // JMP (,X)- fetch LSB and send to ALU (+X)
  JMPIX1  = 7'd52, // JMP (,X)- fetch MSB and send to ALU (+Carry)
  JMPIX2  = 7'd53, // JMP (,X)- Wait for ALU (only if needed)
         /**
    BBX0   = 7'd54, // BB{R,S} - increment PC
    BBX1   = 7'd55, // BB{R,S} - fetch ZP data and send to ALU, test
    BBX2   = 7'd56, // BB{R,S} - do nothing
    BBX3   = 7'd57, // BB{R,S} - fetch displacement, possibly goto fetch
    BBX4   = 7'd58, // BB{R,S} - add displacement to PC[7:0] (PC++????)
    BBX5   = 7'd59; // BB{R,S} - add carry to PC[15:8], goto fetch
         */
         //going to take liberties with bus cycles for now
  BBX0    = 7'd54, // BB{R,S} - fetch ZP data
  BBX1    = 7'd55, // BB{R,S} - test, fetch displacement
  BBX2    = 7'd56, // BB{R,S} - write displacement to temp, PC++
  BBX3    = 7'd57, // BB{R,S} - add displacement to PC[7:0]
  BBX4    = 7'd58, // BB{R,S} - add carry to PC[15:8]
  BBX5    = 7'd59, // BB{R,S} - set up address bus

         //TXX - transfer instructions
  TXX0    = 7'd60, //SP->ALU
  TXX1    = 7'd61, //PUSH Y
  TXX2    = 7'd62, //PUSH A
  TXX3    = 7'd63, //PUSH X
  TXX4    = 7'd64, //SRC[7:0],  PC++
  TXX5    = 7'd65, //SRC[15:8], PC++
  TXX6    = 7'd66, //DST[7:0],  PC++
  TXX7    = 7'd67, //DST[15:0], PC++
  TXX8    = 7'd68, //LEN[7:0],  PC++
  TXX9    = 7'd69, //LEN[15:0]
  TXXA    = 7'd70, //(read finishes), txx_alt = 0
  TXXB    = 7'd71, //setup SRC address
  TXXC    = 7'd72, //read SRC byte
  TXXD    = 7'd73, //setup DST address, write back read DATA to X
  TXXE    = 7'd74, //write x to DST
  TXXF    = 7'd75, //modify SRC, LEN--
  TXXG    = 7'd76, //modify DST, compare LEN to 0, txx_alt = ~alt
  TXXH    = 7'd77, //SP->ALU, PC++
  TXXI    = 7'd78, //POP X
  TXXJ    = 7'd79, //POP A
  TXXK    = 7'd80, //POP Y
  TAM0    = 7'd81, //issue load request to MMU
  TAM1    = 7'd82, //wait for MMU update
  TAM2    = 7'd83, //keep waiting
  TMA0    = 7'd84, //issue store request to MMU
  TMA1    = 7'd85, //get result

  SWP     = 7'd86, //S{AX,AY,XY}
  IMZP0   = 7'd87, //fetch zp offset
  IMZP1   = 7'd88, //add offset to X or 0
  IMZP2   = 7'd89, //wait
  IMZP3   = 7'd90, //wait (this and next line are SWAPPED on real CPU)
  IMZP4   = 7'd91, //read zp byte
  IMAB0   = 7'd92, //read low address byte
  IMAB1   = 7'd93, //read high address byte, DIMUX->ALU (+0/X)
  IMAB2   = 7'd94, //ADD->ABL, DIMUX->ALU (+0+CO)
  IMAB3   = 7'd95, //ADD->ABH
  IMAB4   = 7'd96, //NOP
  IMAB5   = 7'd97, //read
  CSX     = 7'd98, //NOP cycle for CSL/CSH
  BSR0    = 7'd99, //store offset to internal buffer, S->ALU
  BSR1    = 7'd100,//push PCH, S--
  BSR2    = 7'd101,//push PCL S--
  BSR3    = 7'd102,//add offset to PCL, write S
  BSR4    = 7'd103,//carry to PCH
  BSR5    = 7'd104,//present PC to bus
  STX0    = 7'd105,//fetch immediate
  STX1    = 7'd106,//write to VDC
  TFL0    = 7'd107,//read from zeropage
  TFL1    = 7'd108,//do math
  TFL2    = 7'd109,//bcd adjust
  TFL3    = 7'd110;//write back to zeropage
`ifdef SIM

/*
 * easy to read names in simulator output
 */
reg [8*7-1:0] statename;

always @*
    case( state )
      DECODE: statename  = "DECODE";
      REG:    statename  = "REG";
      ZP0:    statename  = "ZP0";
      ZPX0:   statename  = "ZPX0";
      ZPX1:   statename  = "ZPX1";
      ABS0:   statename  = "ABS0";
      ABS1:   statename  = "ABS1";
      ABSX0:  statename  = "ABSX0";
      ABSX1:  statename  = "ABSX1";
      ABSX2:  statename  = "ABSX2";
      IND0:   statename  = "IND0";
      INDX0:  statename  = "INDX0";
      INDX1:  statename  = "INDX1";
      INDX2:  statename  = "INDX2";
      INDX3:  statename  = "INDX3";
      INDY0:  statename  = "INDY0";
      INDY1:  statename  = "INDY1";
      INDY2:  statename  = "INDY2";
      INDY3:  statename  = "INDY3";
      READ:   statename  = "READ";
      WRITE:  statename  = "WRITE";
      FETCH:  statename  = "FETCH";
      PUSH0:  statename  = "PUSH0";
      PUSH1:  statename  = "PUSH1";
      PULL0:  statename  = "PULL0";
      PULL1:  statename  = "PULL1";
      PULL2:  statename  = "PULL2";
      JSR0:   statename  = "JSR0";
      JSR1:   statename  = "JSR1";
      JSR2:   statename  = "JSR2";
      JSR3:   statename  = "JSR3";
      RTI0:   statename  = "RTI0";
      RTI1:   statename  = "RTI1";
      RTI2:   statename  = "RTI2";
      RTI3:   statename  = "RTI3";
      RTI4:   statename  = "RTI4";
      RTS0:   statename  = "RTS0";
      RTS1:   statename  = "RTS1";
      RTS2:   statename  = "RTS2";
      RTS3:   statename  = "RTS3";
      BRK0:   statename  = "BRK0";
      BRK1:   statename  = "BRK1";
      BRK2:   statename  = "BRK2";
      BRK3:   statename  = "BRK3";
      BRA0:   statename  = "BRA0";
      BRA1:   statename  = "BRA1";
      BRA2:   statename  = "BRA2";
      JMP0:   statename  = "JMP0";
      JMP1:   statename  = "JMP1";
      JMPI0:  statename  = "JMPI0";
      JMPI1:  statename  = "JMPI1";
      JMPIX0: statename  = "JMPIX0";
      JMPIX1: statename  = "JMPIX1";
      JMPIX2: statename  = "JMPIX2";
      BBX0:   statename  = "BBX0";
      BBX1:   statename  = "BBX1";
      BBX2:   statename  = "BBX2";
      BBX3:   statename  = "BBX3";
      BBX4:   statename  = "BBX4";
      BBX5:   statename  = "BBX5";
      TXX0:   statename  = "TXX0";
      TXX1:   statename  = "TXX1";
      TXX2:   statename  = "TXX2";
      TXX3:   statename  = "TXX3";
      TXX4:   statename  = "TXX4";
      TXX5:   statename  = "TXX5";
      TXX6:   statename  = "TXX6";
      TXX7:   statename  = "TXX7";
      TXX8:   statename  = "TXX8";
      TXX9:   statename  = "TXX9";
      TXXA:   statename  = "TXXA";
      TXXB:   statename  = "TXXB";
      TXXC:   statename  = "TXXC";
      TXXD:   statename  = "TXXD";
      TXXE:   statename  = "TXXE";
      TXXF:   statename  = "TXXF";
      TXXG:   statename  = "TXXG";
      TXXH:   statename  = "TXXH";
      TXXI:   statename  = "TXXI";
      TXXJ:   statename  = "TXXJ";
      TXXK:   statename  = "TXXK";
      TAM0:   statename  = "TAM0";
      TAM1:   statename  = "TAM1";
      TAM2:   statename  = "TAM2";
      TMA0:   statename  = "TMA0";
      TMA1:   statename  = "TMA1";
      SWP:    statename  = "SWP";
      IMZP0:  statename  = "IMZP0";
      IMZP1:  statename  = "IMZP1";
      IMZP2:  statename  = "IMZP2";
      IMZP3:  statename  = "IMZP3";
      IMZP4:  statename  = "IMZP4";
      IMAB0:  statename  = "IMAB0";
      IMAB1:  statename  = "IMAB1";
      IMAB2:  statename  = "IMAB2";
      IMAB3:  statename  = "IMAB3";
      IMAB4:  statename  = "IMAB4";
      IMAB5:  statename  = "IMAB5";
      CSX:    statename  = "CSX";
      BSR0:   statename  = "BSR0";
      BSR1:   statename  = "BSR1";
      BSR2:   statename  = "BSR2";
      BSR3:   statename  = "BSR3";
      BSR4:   statename  = "BSR4";
      BSR5:   statename  = "BSR5";
      STX0:   statename  = "STX0";
      STX1:   statename  = "STX1";
      TFL0:   statename  = "TFL0";
      TFL1:   statename  = "TFL1";
      TFL2:   statename  = "TFL2";
      TFL3:   statename  = "TFL3";
      default: statename = "ILLEGAL";
    endcase

//always @( PC )
//      $display( "%t, PC:%04x IR:%02x A:%02x X:%02x Y:%02x S:%02x C:%d Z:%d V:%d N:%d P:%02x", $time, PC, IR, A, X, Y, S, C, Z, V, N, P );

`endif

/*
 * Program Counter Increment/Load. First calculate the base value in
 * PC_temp.
 */
always @*
    case( state )
        DECODE:         if( (~I & IRQ) | NMI_edge )
                            PC_temp = { ABH, ABL };
                        else
                            PC_temp = PC;


        JMP1,
        JMPI1,
        JMPIX1,
        JSR3,
        RTS3,
        RTI4:           PC_temp = { DIMUX, ADD };

        BRA1,
        BBX4,
        BSR4:           PC_temp = { ABH, ADD };

        JMPIX2,
        BRA2,
        BBX5,
        BSR5:           PC_temp = { ADD, PCL };

        BSR0:           PC_temp = { ABH, ABL };


        BRK2:           PC_temp = res      ? 16'hfffe : //IRQ2 and BRK
                                  NMI_edge ? 16'hfffc : //share a vector
                                  TIQ      ? 16'hfffa :
                                  IRQ1     ? 16'hfff8 : 16'hfff6;

        default:        PC_temp = PC;
    endcase

/*
 * Determine wether we need PC_temp, or PC_temp + 1
 */
always @*
    case( state ) //TODO: do txx crap with AB, not PC (maybe this is okay?)
        DECODE:         if( (~I & IRQ) | NMI_edge | txx_ins)
                            PC_inc = 0;
                        else
                            PC_inc = 1;

        ABS0,
        JMPIX0,
        JMPIX2,
        ABSX0,
        FETCH,
        BRA0,
        BRA2,
        BRK3,
        JMPI1,
        JMP1,
        RTI4,
        RTS3,
        BBX2,
        TXX4,
        TXX5,
        TXX6,
        TXX7,
        TXX8,
        TXXH,
        IMZP0,
        IMAB0,
        IMAB1,
        BSR2:           PC_inc = 1;

        JMPIX1:         PC_inc = ~CO;       // Don't increment PC if we are
                                            // going to go through JMPIX2

        BRA1:           PC_inc = CO ^~ backwards;

        default:        PC_inc = 0;
    endcase

/*
 * Set new PC
 */
always @(posedge clk)
    if( RDY )
        PC <= PC_temp + PC_inc;

  /*
   * MMU
   */
  reg  MMU_tam, MMU_tma;
  wire  STx_override;
  wire [7:0] MMU_out;

  assign STx_override = (state == STX1);

  MMU mmu(.clk(clk), .reset(reset), 
	  .RDY(RDY_preMMU), .load_en(MMU_tam), .store_en(MMU_tma),
          .RE(RE), .WE(WE), .MMU_stall(MMU_stall),
          .MPR_mask(DIMUX), .d_in(regfile), .VADDR(AB),
	  .STx_override(STx_override),
          .PADDR(AB_21), .d_out(MMU_out),
          .CE7_n(CE7_n), .CEK_n(CEK_n), .CEP_n(CEP_n), .CET_n(CET_n),
	  .CEIO_n(CEIO_n), .CECG_n(CECG_n), .CE_n(CE_n), .CER_n(CER_n),
          .IO_sel(IO_sel));

  always @* begin
    MMU_tam = 0;
    MMU_tma = 0;
    case( state )
      TAM0: MMU_tam = 1;
      TMA0: MMU_tma = 1;
      default: begin
	MMU_tam = 0;
        MMU_tma = 0;
      end
    endcase
  end



/*
 * Address Generator
 */

parameter
        ZEROPAGE  = 8'h20,
        STACKPAGE = 8'h21;

always @*
    case( state )
        JMPIX1,
        ABSX1,
        INDX3,
        INDY2,
        JMP1,
        JMPI1,
        RTI4,
        ABS1:           AB = { DIMUX, ADD };

        BRA2,
        INDY3,
        JMPIX2,
        ABSX2,
        IMAB3:          AB = { ADD, ABL };

        BRA1,
        BBX4,
        IMAB2:          AB = { ABH, ADD };

        JSR0,
        PUSH1,
        RTS0,
        RTI0,
        BRK0:           AB = { STACKPAGE, regfile };

        BRK1,
        JSR1,
        PULL1,
        RTS1,
        RTS2,
        RTI1,
        RTI2,
        RTI3,
        BRK2,
        TXX1,
        TXX2,
        TXX3,
        TXXI,
        TXXJ,
        TXXK,
        BSR1,
        BSR2:           AB = { STACKPAGE, ADD };

        INDY1,
        INDX1,
        ZPX1,
        INDX2,
        IMZP4:          AB = { ZEROPAGE, ADD };

        ZP0,
        INDY0,
        BBX0:           AB = { ZEROPAGE, DIMUX };

        REG,
        READ,
        WRITE,
        SWP,
        CSX,
        BSR0,
        IMAB4,
        IMAB5:          AB = { ABH, ABL };

        TXXB,
        TXXC:           AB = txx_src;

        TXXD,
        TXXE:           AB = txx_dst;

        STX1:           AB = {8'h00, 2'b00, stx_dst};

        TFL0,
        TFL3:           AB = { ZEROPAGE, regfile };

      
      default:          AB = PC;
    endcase

/*
 * ABH/ABL pair is used for registering previous address bus state.
 * This can be used to keep the current address, freeing up the original
 * source of the address, such as the ALU or DI.
 */
always @(posedge clk)
    if( state != PUSH0 && state != PUSH1 && RDY &&
        state != PULL0 && state != PULL1 && state != PULL2 )
    begin
        ABL <= AB[7:0];
        ABH <= AB[15:8];
    end

/*
 * Data Out MUX
 */
always @*
    case( state )
        WRITE,
        STX1,
        TFL3:    DO = ADD;

        JSR0,
        BRK0,
        BSR1:    DO = PCH;

        JSR1,
        BRK1,
        BSR2:    DO = PCL;

        PUSH1:   DO = php ? P : ADD;

        BRK2:    DO = (IRQ | NMI_edge) ? (P & 8'b1110_1111) : P;

        TXX1,
        TXX2,
        TXX3,
        TXXE:    DO = regfile;

      
        default: DO = store_zero ? 0 : regfile;
    endcase


/*
 * Read Enable Generator. Any MMIO issues should be resolved here
 */
always @* begin
  case( state )
    TXXB,
    TXXD,
    TXXH,
    IMAB3,
    IMAB4: RE = 0;
    default: RE = ~WE;
  endcase

  /*
  case( state )

    INDX3,
    INDY3,
    //ABSX2,
    ABS1,
    ZPX1,
    ZP0:    WE   = ~store;

    ABS0,
    //ABS1,
    ABSX0,
    ABSX1,
    BRA0,
    BRA1,
    BRA2,
    BRK3,
    DECODE,
    FETCH,
    INDX0,
    INDX1,
    INDX2,
    //INDX3,
    INDY0,
    INDY1,
    INDY2,
    //INDY3,
    JMP0, //investigate
    JMP1,
    JMPI0,
    JMPI1,
    JSR2,
    JSR3,
    PULL0,
    PULL1,
    PULL2,
    READ,
    RTI1,
    RTI2,
    RTI3,
    RTI4,
    RTS1,
    RTS2,
    ZP0,
    ZPX0,
    //ZPX1,
    IND0,
    JMPIX0,
    JMPIX1,
    JMPIX2,
    BBX0,
    BBX1,
    BBX2,
    TXX4,
    TXX5,
    TXX6,
    TXX7,
    TXX8,
    TXX9,
    TXXC,
    TXXI,
    TXXJ,
    TXXK: RE     = 1;

    default: RE  = 0;
  endcase
   */
end

/*
 * Write Enable Generator
 */

always @*
    case( state )
        BRK0,   // writing to stack or memory
        BRK1,
        BRK2,
        JSR0,
        JSR1,
        PUSH1,
        WRITE,
        TXX1,
        TXX2,
        TXX3,
        TXXE,
        BSR1,
        BSR2,
        STX1,
        TFL3:    WE = 1;

        INDX3,  // only if doing a STA, STX or STY
        INDY3,
        ABSX2,
        ABS1,
        ZPX1,
        ZP0:     WE = store;

        default: WE = 0;
    endcase

/*
 * register file, contains A, X, Y and S (stack pointer) registers. At each
 * cycle only 1 of those registers needs to be accessed, so they combined
 * in a small memory, saving resources.
 */

reg write_register;             // set when register file is written

always @*
    case( state )
        DECODE: write_register = load_reg & ~plp;

        PULL1,
         RTS2,
         RTI3,
         BRK3,
         JSR0,
         JSR2,
         TXX4,
         TXXD,
         TXXJ,
         TXXK,
         TMA1,
         BSR3:  write_register  = 1;

         REG:   write_register  = swp_ins; //write back if we're swapping

      default: write_register   = 0;
    endcase

/*
 * BCD adjust logic
 */

always @(posedge clk)
    adj_bcd <= adc_sbc & D;     // '1' when doing a BCD instruction

reg [3:0] ADJL;
reg [3:0] ADJH;

// adjustment term to be added to ADD[3:0] based on the following
// adj_bcd: '1' if doing ADC/SBC with D=1
// adc_bcd: '1' if doing ADC with D=1
// HC     : half carry bit from ALU
always @* begin
    casex( {adj_bcd, adc_bcd, HC} )
         3'b0xx: ADJL = 4'd0;   // no BCD instruction
         3'b100: ADJL = 4'd10;  // SBC, and digital borrow
         3'b101: ADJL = 4'd0;   // SBC, but no borrow
         3'b110: ADJL = 4'd0;   // ADC, but no carry
         3'b111: ADJL = 4'd6;   // ADC, and decimal/digital carry
    endcase
end

// adjustment term to be added to ADD[7:4] based on the following
// adj_bcd: '1' if doing ADC/SBC with D=1
// adc_bcd: '1' if doing ADC with D=1
// CO     : carry out bit from ALU
always @* begin
    casex( {adj_bcd, adc_bcd, CO} )
         3'b0xx: ADJH = 4'd0;   // no BCD instruction
         3'b100: ADJH = 4'd10;  // SBC, and digital borrow
         3'b101: ADJH = 4'd0;   // SBC, but no borrow
         3'b110: ADJH = 4'd0;   // ADC, but no carry
         3'b111: ADJH = 4'd6;   // ADC, and decimal/digital carry
    endcase
end

assign AO = { ADD[7:4] + ADJH, ADD[3:0] + ADJL };

`ifdef IMPLEMENT_CORRECT_BCD_FLAGS

assign AN1 = AO[7];
assign AZ1 = ~|AO;

`else

assign AN1 = AN;
assign AZ1 = AZ;

`endif

/*
 * write to a register. Usually this is the (BCD corrected) output of the
 * ALU, but in case of the JSR0 we use the S register to temporarily store
 * the PCL. This is possible, because the S register itself is stored in
 * the ALU during those cycles.
 *
 * Reading directly from the bus can also occur during a transfer
 */
always @(posedge clk) begin
    if(reset) begin
      AXYS[0] <= 0;
      AXYS[1] <= 0;
      AXYS[2] <= 0;
      AXYS[3] <= 0;
    end
    else if( write_register & RDY )
      case ( state )
        JSR0,
        TXXD,
        TXXJ: AXYS[regsel]    <= DIMUX;
        TMA1: AXYS[regsel]    <= MMU_out;
        default: AXYS[regsel] <= AO;
      endcase
        //AXYS[regsel] <= (state == JSR0 || state == TXXC || state) ? DIMUX : AO;
end

/*
 * register select logic. This determines which of the A, X, Y or
 * S registers will be accessed.
 */

always @*
    case( state )
        INDY1,
        INDX0,
        ZPX0,
        JMPIX0,
        ABSX0  : regsel = index_y ? SEL_Y : SEL_X;


        DECODE : regsel = dst_reg;

        BRK0,
        BRK3,
        JSR0,
        JSR2,
        PULL0,
        PULL1,
        PUSH1,
        RTI0,
        RTI3,
        RTS0,
        RTS2,
        TXX0,
        TXX4,
        TXXH,
        TXXK,
        BSR0,
        BSR3   : regsel = SEL_S;

        TXX1   : regsel = SEL_Y;

        TXX2   : regsel = SEL_A;

        TXX3,
        TXXD,
        TXXE,
        TXXJ,
        IMZP1,
        TFL0,
        TFL3   : regsel = SEL_X;

        SWP    : regsel = (sax_ins) ? SEL_X : SEL_Y;
        default: regsel = src_reg;
    endcase

/*
 * ALU
 */

ALU ALU( .clk(clk),
         .op(alu_op),
         .right(alu_shift_right),
         .AI(AI),
         .BI(BI),
         .CI(CI),
         .BCD(adc_bcd & (state == FETCH)),
         .CO(CO),
         .OUT(ADD),
         .V(AV),
         .Z(AZ),
         .N(AN),
         .HC(HC),
         .RDY(RDY) );

/*
 * Select current ALU operation
 */

always @*
    case( state )
        READ:   alu_op = op;

        BRA1:   alu_op = backwards ? OP_SUB : OP_ADD;
        BBX4:   alu_op = (bbx_disp[7]) ? OP_SUB : OP_ADD;
        BSR4:   alu_op = (bsr_disp[7]) ? OP_SUB : OP_ADD;

        FETCH,
        REG,
        TFL1:   alu_op = op;

        DECODE,
        ABS1:   alu_op = 1'bx;

        PUSH1,
        BRK0,
        BRK1,
        BRK2,
        JSR0,
        JSR1,
        TXX1,
        TXX2,
        TXX3,
        BSR1,
        BSR2:   alu_op = OP_SUB;

        BBX1:   alu_op = OP_AND;

     default:   alu_op = OP_ADD;
    endcase

/*
 * Determine shift right signal to ALU
 */

always @*
    if( state == FETCH || state == REG || state == READ )
        alu_shift_right = shift_right;
    else
        alu_shift_right = 0;

/*
 * Sign extend branch offset.
 */

always @(posedge clk)
    if( RDY )
        backwards <= DIMUX[7];

/*
 * ALU A Input MUX
 */

always @*
    case( state )
        JSR1,
        RTS1,
        RTI1,
        RTI2,
        BRK1,
        BRK2,
        INDX1,
        TFL1:  AI = ADD;

        ZPX0,
        INDX0,
        JMPIX0,
        ABSX0,
        RTI0,
        RTS0,
        JSR0,
        JSR2,
        BRK0,
        PULL0,
        INDY1,
        PUSH0,
        PUSH1,
        TXX0,
        TXXH,
        SWP,
        BSR0:  AI  = regfile;

        TXX1,
        TXX2,
        TXX3,
        TXXI,
        TXXJ,
        IMZP2,
        IMZP3,
        IMZP4,
        BSR1,
        BSR2:   AI  = ADD;


        BRA0,
        READ,
        BBX1:   AI  = DIMUX;


        BRA1:   AI  = ABH;       // don't use PCH in case we're

        FETCH:  AI  = load_only ? 0 : tst_ins ? tst_mask : regfile;

        DECODE,
        ABS1:   AI = 8'hxx;     // don't care

        BBX3:   AI = bbx_disp;

        BSR3:   AI = bsr_disp;

        BBX4,
        BSR4:   AI = PCH;

        REG:    AI = clr_ins ? 0 : regfile;

        IMZP1,
        IMAB1:  AI = tst_x ? regfile : 0;

        default:  AI = 0;
    endcase


/*
 * ALU B Input mux
 */

  wire [7:0] BI_txb, BI_xmb, single_bitmask;

  assign BI_txb  = (trb_ins) ? ~regfile : regfile;
  assign BI_xmb  = (rmb_ins) ? ~single_bitmask : single_bitmask;
  assign single_bitmask = 8'b1 << mask_shift;

always @*
    case( state )
         BRA1,
         RTS1,
         RTI0,
         RTI1,
         RTI2,
         INDX1,
         REG,
         JSR0,
         JSR1,
         JSR2,
         BRK0,
         BRK1,
         BRK2,
         PUSH0,
         PUSH1,
         PULL0,
         RTS0,
         BBX4,
         TXX0,
         TXX1,
         TXX2,
         TXX3,
         TXXH,
         TXXI,
         TXXJ,
         TXXK,
         SWP,
         IMZP2,
         IMZP3,
         IMZP4,
         BSR0,
         BSR1,
         BSR2,
         BSR4:  BI = 8'h00;

         READ: begin
           if(txb_ins) BI  = BI_txb;
           else if(xmb_ins) BI = BI_xmb;
           else BI = 8'h00;
           end

         BRA0,
         BBX3,
         BSR3:  BI  = PCL;

         DECODE,
         ABS1:  BI  = 8'hxx;

         BBX1:  BI  = BI_xmb;

         default:       BI = DIMUX;
    endcase

/*
 * ALU CI (carry in) mux
 */
always @*
    case( state )
        INDY2,
        BRA1,
        JMPIX1,
        ABSX1,
        BBX4,
        BSR4,
        IMAB2:  CI = CO;

        DECODE,
        ABS1:   CI = 1'bx;

        READ,
        REG:    CI = rotate ? C :
                     shift ? 0 : inc;

        FETCH,
        TFL1:   CI = rotate  ? C :
                     compare ? 1 :
                     (shift | load_only) ? 0 : C;

        PULL0,
        RTI0,
        RTI1,
        RTI2,
        RTS0,
        RTS1,
        INDY0,
        INDX1,
        TXXH,
        TXXI,
        TXXJ:  CI = 1;

        default:        CI = 0;
    endcase

/*
 * Processor Status Register update
 *
 */

/*
 * Update C flag when doing ADC/SBC, shift/rotate, compare
 */
always @(posedge clk )
    if( shift && state == WRITE )
        C <= CO;
    else if( state == RTI2 )
        C <= DIMUX[0];
    else if( ~write_back && state == DECODE ) begin
        if( adc_sbc | shift | compare )
            C <= CO;
        else if( plp )
            C <= ADD[0];
        else begin
            if( sec ) C <= 1;
            if( clc ) C <= 0;
        end
    end

/*
 * Special Z flag got TRB/TSB
 */
always @(posedge clk)
    AZ2 <= ~|(AI & regfile);

/*
 * Update Z, N flags when writing A, X, Y, Memory, or when doing compare
 */

always @(posedge clk)
    if( state == WRITE)
        Z <= txb_ins ? AZ2 : AZ1;
    else if( state == RTI2 )
        Z <= DIMUX[1];
    else if( state == DECODE ) begin
        if( plp )
            Z <= ADD[1];
        else if( (load_reg & (regsel != SEL_S)) | compare | bit_ins )
            Z <= AZ1;
    end

always @(posedge clk)
    if( state == WRITE && ~txb_ins)
        N <= AN1;
    else if( state == RTI2 )
        N <= DIMUX[7];
    else if( state == DECODE ) begin
        if( plp )
            N <= ADD[7];
        else if( (load_reg & (regsel != SEL_S)) | compare )
            N <= AN1;
    end else if( state == FETCH && bit_ins_nv )
        N <= DIMUX[7];

/*
 * Update I flag
 */

always @(posedge clk)
    if( state == BRK3 )
        I <= 1;
    else if( state == RTI2 )
        I <= DIMUX[2];
    else if( state == REG ) begin
        if( sei ) I <= 1;
        if( cli ) I <= 0;
    end else if( state == DECODE )
        if( plp ) I <= ADD[2];

/*
 * Update D flag
 */
always @(posedge clk )
    if( state == RTI2 )
        D <= DIMUX[3];
    else if( state == DECODE ) begin
        if( sed ) D <= 1;
        if( cld ) D <= 0;
        if( plp ) D <= ADD[3];
    end

/*
 * Update V flag
 */
always @(posedge clk )
    if( state == RTI2 )
        V <= DIMUX[6];
    else if( state == DECODE ) begin
        if( adc_sbc ) V <= AV;
        if( clv )     V <= 0;
        if( plp )     V <= ADD[6];
    end else if( state == FETCH && bit_ins_nv )
        V <= DIMUX[6];

/*
 * Instruction decoder
 */

/*
 * IR register/mux. Hold previous DI value in IRHOLD in PULL0 and PUSH0
 * states. In these states, the IR has been prefetched, and there is no
 * time to read the IR again before the next decode.
 */

//reg RDY1 = 1;

//always @(posedge clk )
//    RDY1 <= RDY;

//always @(posedge clk )
//    if( ~RDY && RDY1 )
//        DIHOLD <= DI;

always @(posedge clk )
    if( reset )
        IRHOLD_valid <= 0;
    else if( RDY ) begin
        if( state == PULL0 || state == PUSH0 ) begin
            IRHOLD <= DIMUX;
            IRHOLD_valid <= 1;
        end else if( state == DECODE )
            IRHOLD_valid <= 0;
    end

assign IR = (IRQ & ~I) | NMI_edge ? 8'h00 :
                     IRHOLD_valid ? IRHOLD : DIMUX;

//assign DIMUX = ~RDY1 ? DIHOLD : DI;

//fseidel: DIMUX is being repurposed for handling on-chip MMIO
//assign DIMUX = DI;

/*
 * Microcode state machine
 */
always @(posedge clk or posedge reset)
    if( reset )
        state <= BRK0;
    else if( RDY ) case( state )
        DECODE  :
            casex ( IR )
                // TODO Review for simplifications as in verilog the first matching case has priority
                8'b0000_0000:   state <= BRK0;
                8'b0010_0000:   state <= JSR0;
                8'b0010_1100:   state <= ABS0;  // BIT abs
                8'b1001_1100:   state <= ABS0;  // STZ abs
                8'b000x_1100:   state <= ABS0;  // TSB/TRB
                8'b0100_0000:   state <= RTI0;  //
                8'b0100_1100:   state <= JMP0;
                8'b0110_0000:   state <= RTS0;
                8'b0110_1100:   state <= JMPI0;
                8'b0111_1100:   state <= JMPIX0;
                8'bxxxx_0111:   state <= ZP0;   //RMB/SMB
                8'bxxxx_1111:   state <= BBX0;

                //7 column is now RMB/SMB
                //F column is now BBR/BBS
                //3 column is many things
                8'b0100_0011:   state <= TMA0;
                8'b0101_0011:   state <= TAM0;
                8'b0111_0011,                   // TII
                8'b11xx_0011:   state <= TXX0;  // TDD, TIN, TIA, TAI
                8'b0x00_0010,
                8'b0010_0010:   state <= SWP;
                8'b0110_0010,                   // CLA
                8'b1x00_0010:   state <= REG;   // CLX, CLY
                8'b10x0_0011:   state <= IMZP0; // TST imzp, imzpx
                8'b10x1_0011:   state <= IMAB0; // TST imab, imabx
                8'bx101_0100:   state <= CSX;   // CSL, CSH
                8'b0100_0100:   state <= BSR0;  // BSR
                8'b000x_0011,
                8'b0010_0011:   state <= STX0;  // ST{0,1,2}
                8'b1111_0100:   state <= REG;   // SET
`ifdef IMPLEMENT_NOPS
                8'bxxxx_1011,                   // (NOP1: B column)
                8'b0011_0011,                   // (NOP1: 3B)
                8'b0110_0011:   state <= REG;   // (NOP1: 6B)
                8'b1110_0010:   state <= FETCH; // (NOP2: E2)
                8'b0101_1100,                   // (NOP3: C column)
                8'b11x1_1100:   state <= ABS0;  // (NOP3: C column)
`endif
                8'b0x00_1000:   state <= PUSH0;
                8'b0x10_1000:   state <= PULL0;
                8'b0xx1_1000:   state <= REG;   // CLC, SEC, CLI, SEI
                8'b11x0_00x0:   state <= FETCH; // IMM
                8'b1x10_00x0:   state <= FETCH; // IMM
                8'b1xx0_1100:   state <= ABS0;  // X/Y abs
                8'b1xxx_1000:   state <= REG;   // DEY, TYA, ...
                8'bxxx0_0001:   state <= INDX0;
                8'bxxx1_0010:   state <= IND0;  // (ZP) odd 2 column
                8'b000x_0100:   state <= ZP0;   // TSB/TRB
                8'bxxx0_01xx:   state <= ZP0;
                8'bxxx0_1001:   state <= (T) ? TFL0 : FETCH; // IMM
                8'bxxx0_1101:   state <= ABS0;  // even D column
                8'bxxx0_1110:   state <= ABS0;  // even E column
                8'bxxx1_0000:   state <= BRA0;  // odd 0 column (Branches)
                8'b1000_0000:   state <= BRA0;  // BRA
                8'bxxx1_0001:   state <= INDY0; // odd 1 column
                8'bxxx1_01xx:   state <= ZPX0;  // odd 4,5,6,7 columns
                8'bxxx1_1001:   state <= ABSX0; // odd 9 column
                8'bx011_1100:   state <= ABSX0; // C column BIT (3C), LDY (BC)
                8'bxxx1_11x1:   state <= ABSX0; // odd D, F columns
                8'bxxx1_111x:   state <= ABSX0; // odd E, F columns
                8'bx101_1010:   state <= PUSH0; // PHX/PHY
                8'bx111_1010:   state <= PULL0; // PLX/PLY
                8'bx0xx_1010:   state <= REG;   // <shift> A, TXA, ...  NOP
                8'bxxx0_1010:   state <= REG;   // <shift> A, TXA, ...  NOP
            endcase

        ZP0     : state <= write_back ? READ : FETCH;

        ZPX0    : state <= ZPX1;
        ZPX1    : state <= write_back ? READ : FETCH;

        ABS0    : state <= ABS1;
        ABS1    : state <= write_back ? READ : FETCH;

        ABSX0   : state <= ABSX1;
        ABSX1   : state <= (CO | store | write_back) ? ABSX2 : FETCH;
        ABSX2   : state <= write_back ? READ : FETCH;

        JMPIX0  : state <= JMPIX1;
        JMPIX1  : state <= CO ? JMPIX2 : JMP0;
        JMPIX2  : state <= JMP0;

        IND0    : state <= INDX1;

        INDX0   : state <= INDX1;
        INDX1   : state <= INDX2;
        INDX2   : state <= INDX3;
        INDX3   : state <= FETCH;

        INDY0   : state <= INDY1;
        INDY1   : state <= INDY2;
        INDY2   : state <= (CO | store) ? INDY3 : FETCH;
        INDY3   : state <= FETCH;

        READ    : state <= WRITE;
        WRITE   : state <= FETCH;
        FETCH   : state <= DECODE;

        REG     : state <= DECODE;

        PUSH0   : state <= PUSH1;
        PUSH1   : state <= DECODE;

        PULL0   : state <= PULL1;
        PULL1   : state <= PULL2;
        PULL2   : state <= DECODE;

        JSR0    : state <= JSR1;
        JSR1    : state <= JSR2;
        JSR2    : state <= JSR3;
        JSR3    : state <= FETCH;

        RTI0    : state <= RTI1;
        RTI1    : state <= RTI2;
        RTI2    : state <= RTI3;
        RTI3    : state <= RTI4;
        RTI4    : state <= DECODE;

        RTS0    : state <= RTS1;
        RTS1    : state <= RTS2;
        RTS2    : state <= RTS3;
        RTS3    : state <= FETCH;

        BRA0    : state <= cond_true ? BRA1 : DECODE;
        BRA1    : state <= (CO ^ backwards) ? BRA2 : DECODE;
        BRA2    : state <= DECODE;

        JMP0    : state <= JMP1;
        JMP1    : state <= DECODE;

        JMPI0   : state <= JMPI1;
        JMPI1   : state <= JMP0;

        BRK0    : state <= BRK1;
        BRK1    : state <= BRK2;
        BRK2    : state <= BRK3;
        BRK3    : state <= JMP0;

        BBX0    : state <= BBX1;
        BBX1    : state <= BBX2;
        BBX2    : state <= BBX3;
        BBX3    : state <= (bbx_status) ? BBX4 : FETCH;
        BBX4    : state <= BBX5;
        BBX5    : state <= FETCH;

        TXX0    : state <= TXX1;
        TXX1    : state <= TXX2;
        TXX2    : state <= TXX3;
        TXX3    : state <= TXX4;
        TXX4    : state <= TXX5;
        TXX5    : state <= TXX6;
        TXX6    : state <= TXX7;
        TXX7    : state <= TXX8;
        TXX8    : state <= TXX9;
        TXX9    : state <= TXXA;
        TXXA    : state <= TXXB;
        TXXB    : state <= TXXC;
        TXXC    : state <= TXXD;
        TXXD    : state <= TXXE;
        TXXE    : state <= TXXF;
        TXXF    : state <= TXXG;
        TXXG    : state <= (txx_len == 0) ? TXXH : TXXB;
        TXXH    : state <= TXXI;
        TXXI    : state <= TXXJ;
        TXXJ    : state <= TXXK;
        TXXK    : state <= FETCH;
        TAM0    : state <= TAM1;
        TAM1    : state <= TAM2;
        TAM2    : state <= FETCH;
        TMA0    : state <= TMA1;
        TMA1    : state <= FETCH;

        SWP     : state <= REG;

        IMZP0   : state <= IMZP1;
        IMZP1   : state <= IMZP2;
        IMZP2   : state <= IMZP3;
        IMZP3   : state <= IMZP4;
        IMZP4   : state <= FETCH;

        IMAB0   : state <= IMAB1;
        IMAB1   : state <= IMAB2;
        IMAB2   : state <= IMAB3;
        IMAB3   : state <= IMAB4;
        IMAB4   : state <= IMAB5;
        IMAB5   : state <= FETCH;

        CSX     : state <= REG;

        BSR0    : state <= BSR1;
        BSR1    : state <= BSR2;
        BSR2    : state <= BSR3;
        BSR3    : state <= BSR4;
        BSR4    : state <= BSR5;
        BSR5    : state <= FETCH;

        STX0    : state <= STX1;
        STX1    : state <= FETCH;

        TFL0    : state <= TFL1;
        //TFL1    : state <= (D) ? TFL2 : TFL3;
        TFL1    : state <= TFL3;
        TFL2    : state <= TFL3; //unused until BCD timing fixed
        TFL3    : state <= FETCH;       
    endcase

/*
 * Additional control signals
 */

always @(posedge clk)
     if( reset )
         res <= 1;
     else if( state == DECODE )
         res <= 0;

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )             // DMB: Checked for 65C02 NOP collisions
                8'b0xx1_0010,   // ORA, AND, EOR, ADC (zp)
                8'b1x11_0010,   // LDA, SBC (zp)
                8'b0xxx_1010,   // ASLA, INCA, ROLA, DECA, LSRA, PHY, RORA, PLY
                8'b0xx0_xx01,   // ORA, AND, EOR, ADC (not imm)
                8'b100x_10x0,   // DEY, TYA, TXA, TXS
                8'b1010_xxx0,   // LDA/LDX/LDY
                8'b1011_1010,   // TSX
                8'b1011_x1x0,   // LDX/LDY
                8'b1100_1010,   // DEX
                8'b11x1_1010,   // PHX, PLX
                8'b1x1x_xx01,   // LDA, SBC
                8'bxxx0_1000,   // PHP, PLP, PHA, PLA, DEY, TAY, INY, INX
                8'b0x00_0010,   // SXY, SAY
                8'b0010_0010,   // SAX
                8'b0110_0010,   // CLA
                8'b1x00_0010:   // CLX, CLY
                                load_reg <= 1;

                8'b0xx1_xx01:   // ORA, AND, EOR, ADC (imm)
                                load_reg <= ~T;
          
                default:        load_reg <= 0;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b1110_1000,   // INX
                8'b1100_1010,   // DEX
                8'b1111_1010,   // PLX
                8'b1010_0010,   // LDX imm
                8'b101x_x110,   // LDX
                8'b101x_1x10,   // LDX, TAX, TSX
                8'b0010_0010,   // SAX
                8'b1000_0010:   // CLX
                                dst_reg <= SEL_X;

                8'b0x00_1000,   // PHP, PHA
                8'bx101_1010,   // PHX, PHY
                8'b1001_1010:   // TXS
                                dst_reg <= SEL_S;

                8'b1x00_1000,   // DEY, DEX
                8'b0111_1010,   // PLY
                8'b101x_x100,   // LDY
                8'b1010_x000,   // LDY #imm, TAY
                8'b0x00_0010,   // SXY, SAY
                8'b1100_0010:   // CLY
                                dst_reg <= SEL_Y;

                default:        dst_reg <= SEL_A;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'b1011_1010:   // TSX
                                src_reg <= SEL_S;

                8'b100x_x110,   // STX
                8'b100x_1x10,   // TXA, TXS
                8'b1110_xx00,   // INX, CPX
                8'b1101_1010,   // PHX
                8'b1100_1010,   // DEX
                8'b0000_0010:   // SXY
                                src_reg <= SEL_X;

                8'b100x_x100,   // STY
                8'b1001_1000,   // TYA
                8'b1100_xx00,   // CPY
                8'b0101_1010,   // PHY
                8'b1x00_1000:   // DEY, INY
                                src_reg <= SEL_Y;

                default:        src_reg <= SEL_A;
        endcase

always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )
                8'bxxx1_0001,   // INDY
                8'b10x1_0110,   // LDX zp,Y / STX zp,Y
                8'b1011_1110,   // LDX abs,Y
                8'bxxxx_1001:   // abs, Y
                                index_y <= 1;

                default:        index_y <= 0;
        endcase


always @(posedge clk)
     if( state == DECODE && RDY )
        casex( IR )             // DMB: Checked for 65C02 NOP collisions
                8'b1001_0010,   // STA (zp)
                8'b100x_x1x0,   // STX, STY, STZ abs, STZ abs,x
                8'b011x_0100,   // STZ zp, STZ zp,x
                8'b100x_xx01:   // STA
                                store <= 1;

                default:        store <= 0;

        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )             // DMB: Checked for 65C02 NOP collisions
                8'b0xxx_x110,   // ASL, ROL, LSR, ROR
                8'b000x_x100,   // TSB/TRB
                8'b11xx_x110,   // DEC/INC
                8'bxxxx_0111:   // RMB/SMB
                                write_back <= 1;

                default:        write_back <= 0;
        endcase


always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b10xx_0011:   load_only <= 0; //TST
                8'b101x_xxxx:   // LDA, LDX, LDY
                                load_only <= 1;
                default:        load_only <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0001_1010,   // INCA
                8'b111x_x110,   // INC
                8'b11x0_1000:   // INX, INY
                                inc <= 1;

                default:        inc <= 0;
        endcase

always @(posedge clk )
     if( (state == DECODE || state == BRK0) && RDY )
        casex( IR )
                8'bx111_0010,   // SBC (zp), ADC (zp)
                8'bx11x_xx01:   // SBC, ADC
                                adc_sbc <= 1;

                default:        adc_sbc <= 0;
        endcase

always @(posedge clk )
     if( (state == DECODE || state == BRK0) && RDY )
        casex( IR )
                8'b0111_0010,   // ADC (zp)
                8'b011x_xx01:   // ADC
                                adc_bcd <= D;

                default:        adc_bcd <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0xxx_x110,   // ASL, ROL, LSR, ROR (abs, absx, zpg, zpgx)
                8'b0xx0_1010:   // ASL, ROL, LSR, ROR (acc)
                                shift <= 1;

                default:        shift <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b1101_0010,   // CMP (zp)
                8'b11x0_0x00,   // CPX, CPY (imm/zp)
                8'b11x0_1100,   // CPX, CPY (abs)
                8'b110x_xx01:   // CMP
                                compare <= 1;

                default:        compare <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b01xx_x110,   // ROR, LSR
                8'b01xx_1x10:   // ROR, LSR
                                shift_right <= 1;

                default:        shift_right <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0x10_1010,   // ROL A, ROR A
                8'b0x1x_x110:   // ROR, ROL
                                rotate <= 1;

                default:        rotate <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b1xxx_0111,   // SMB
                8'b0000_x100:   // TSB
                                op <= OP_OR;

                8'b0xxx_0111,   // RMB
                8'b0001_x100,   // TRB
                8'bxxxx_1111:   // BBR/BBS
                                op <= OP_AND;

                8'b00xx_x110,   // ROL, ASL
                8'b00x0_1010:   // ROL, ASL
                                op <= OP_ROL;

                8'b1000_1001,   // BIT imm
                8'b001x_x100,   // BIT zp/abs/zpx/absx
                8'b10xx_0011:   // TST imzp/imzpx/imab/imabx
                                op <= OP_AND;

                8'b01xx_x110,   // ROR, LSR
                8'b01xx_1x10:   // ROR, LSR
                                op <= OP_A;

                8'b11x1_0010,   // CMP, SBC (zp)
                8'b0011_1010,   // DEC A
                8'b1000_1000,   // DEY
                8'b1100_1010,   // DEX
                8'b110x_x110,   // DEC
                8'b11xx_xx01,   // CMP, SBC
                8'b11x0_0x00,   // CPX, CPY (imm, zpg)
                8'b11x0_1100:   op <= OP_SUB;

                8'b00x1_0010,   // ORA, AND (zp)
                8'b0x01_0010,   // ORA, EOR (zp)
                8'b010x_xx01,   // EOR
                8'b00xx_xx01:   // ORA, AND
                                op <= { 2'b11, IR[6:5] };

                default:        op <= OP_ADD;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b001x_x100,   // BIT zp/abs/zpx/absx (update N,V,Z)
                8'b10xx_0011:   // TST imzp/imzpx/imab/imabx
                                {bit_ins, bit_ins_nv}  <= 2'b11;

                8'b1000_1001:   // BIT imm (update Z)
                                {bit_ins, bit_ins_nv}  <= 2'b10;

                default:        // not a BIT instruction
                                {bit_ins, bit_ins_nv}  <= 2'b00;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b000x_x100:   // TRB/TSB
                                txb_ins <= 1;

                default:        txb_ins <= 0;
        endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0001_x100:   // TRB
                                trb_ins <= 1;

                default:        trb_ins <= 0;
        endcase

always @(posedge clk )
  if( state == DECODE && RDY )
    casex( IR )
      8'bxxxx_0111: begin     // RMB/SMB
        xmb_ins    <= 1;
      end
      8'bxxxx_1111: begin
        bbx_ins    <= 1;
      end
      default:      begin
        xmb_ins <= 0;
        bbx_ins <= 0;
      end
    endcase

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b0xxx_0111:   // RMB
                                rmb_ins <= 1;

                default:        rmb_ins <= 0;
        endcase

always @(posedge clk )
  if( state == DECODE && RDY )
    casex( IR )
      8'bxxxx_1111:   begin     // BBR/BBS
        bbx_ins                 <= 1;
      end
      default:        bbx_ins <= 0;
    endcase

always @(posedge clk)
  if( state == DECODE && RDY )
    mask_shift              <= IR[6:4];

always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
          8'b0xxx_1111:   // BBR
                  bbr_ins <= 1;

          default: bbr_ins <= 0;
        endcase

always @(posedge clk ) // Transfer instructions
     if( state == DECODE && RDY ) begin
        {tii_ins, tdd_ins, tin_ins, tia_ins, tai_ins} <= 0;
        casex( IR )
          8'b0111_0011: tii_ins <= 1; //TII
          8'b1100_0011: tdd_ins <= 1; //TDD
          8'b1101_0011: tin_ins <= 1; //TIN
          8'b1110_0011: tia_ins <= 1; //TIA
          8'b1111_0011: tai_ins <= 1; //TAI
        endcase
     end

always @(posedge clk ) // Swap instructions
     if( state == DECODE && RDY )
        casex( IR )
          8'b0x00_0010: {sax_ins, swp_ins} <= 2'b01; //SXY, SAY
          8'b0010_0010: {sax_ins, swp_ins} <= 2'b11;
          default: {swp_ins, sax_ins} <= 0;
        endcase

always @(posedge clk ) //Clear instructions
     if( state == DECODE && RDY )
        casex( IR )
                8'b0110_0010,   // CLA
                8'b1x00_0010:   // CLX, CLY
                                clr_ins <= 1;
                default:        clr_ins <= 0;
        endcase

always @(posedge clk ) //TST instructions
     if( state == DECODE && RDY )
        casex( IR )
                8'b100x_0011: {tst_x, tst_ins} <= 2'b01; // TST im{zp,ab}
                8'b101x_0011: {tst_x, tst_ins} <= 2'b11; // TST im{zp,ab}x
                default:      {tst_x, tst_ins} <= 2'b00;
        endcase

always @(posedge clk) //CSL/CSH
     if( reset ) HSM <= 0;
     else if( state == DECODE && RDY )
        casex( IR )
                8'b0101_0100: HSM <= 0;
                8'b1101_0100: HSM <= 1;
        endcase



always @(posedge clk) //ST0, ST1, ST2
     if( reset ) stx_dst <= 0;
     else if( state == DECODE && RDY )
        casex( IR )
          8'b0000_0011: stx_dst <= 0;
          8'b0001_0011: stx_dst <= 2;
          8'b0010_0011: stx_dst <= 3;
        endcase


  
always @(posedge clk )
     if( state == BSR0 && RDY )
                bsr_disp <= DIMUX;


always @* begin
  txx_ins = 0;
  if( state == DECODE ) // fseidel: RDY shouldn't be necessary here
    casex( IR )
      8'b0111_0011,
      8'b11xx_0011: txx_ins = 1;
      default: txx_ins = 0;
    endcase
end
  /* TODO: WTF
always @* begin //TODO: actually implement this
  STx_override = 3'b000;
  casex( IR )
    //8'b000x_0011,    //ST0, ST1
    //8'b0010_0011: STx_override = 1; //ST2;
    //default:      STx_override = 3'b000;
  endcase
end
   */


always @(posedge clk )
     if( state == DECODE && RDY )
        casex( IR )
                8'b1001_11x0,   // STZ abs, STZ abs,x
                8'b011x_0100:   // STZ zp, STZ zp,x
                                store_zero <= 1;

                default:        store_zero <= 0;
        endcase

/*
 * special instructions
 */

always @(posedge clk )
     if( state == DECODE && RDY ) begin
        php <= (IR == 8'h08);
        clc <= (IR == 8'h18);
        plp <= (IR == 8'h28);
        sec <= (IR == 8'h38);
        cli <= (IR == 8'h58);
        sei <= (IR == 8'h78);
        clv <= (IR == 8'hb8);
        cld <= (IR == 8'hd8);
        sed <= (IR == 8'hf8);
        brk <= (IR == 8'h00);
     end

always @(posedge clk)
    if( RDY )
        cond_code <= IR[7:4];

//fseidel: logic for handling storage of BBX compare result
always @(posedge clk)
  if( state == BBX2 && RDY ) begin
    bbx_status <= (bbr_ins) ? AZ : ~AZ;
  end

//fseidel: logic for handling storage of displacement for bbx
always @(posedge clk)
  if( state == BBX2 && RDY ) begin
    bbx_disp <= DIMUX;
  end

//fseidel: logic for handling txx state (minus alt bit)
always @(posedge clk)
  if( RDY ) begin
    case( state )
      TXX5: txx_src[7:0]  <= DIMUX;
      TXX6: txx_src[15:8] <= DIMUX;
      TXX7: txx_dst[7:0]  <= DIMUX;
      TXX8: txx_dst[15:8] <= DIMUX;
      TXX9: txx_len[7:0]  <= DIMUX;
      TXXA: txx_len[15:8] <= DIMUX;
      TXXF: begin
        txx_len <= txx_len - 1; //always decrement the length counter
        if( tii_ins | tin_ins | tia_ins | (tai_ins & ~txx_alt) )
          txx_src <= txx_src + 1;
        else if( tdd_ins | (tai_ins & txx_alt) )
          txx_src <= txx_src - 1;
      end
      TXXG: begin
        if( tii_ins | tai_ins | (tia_ins & ~txx_alt) )
          txx_dst <= txx_dst + 1;
        else if ( tdd_ins | (tia_ins & txx_alt) )
          txx_dst <= txx_dst - 1;
        //do nothing for TIN
      end
      default:; //do nothing
    endcase
  end

always @(posedge clk) // Transfer alternation management
  if( RDY )
    casex ( state )
      TXXA: txx_alt <= 0;
      TXXG: txx_alt <= (tia_ins | tai_ins) ? ~txx_alt : 0;
    endcase

always @(posedge clk) // TST mask storage
  if( RDY )
    casex ( state )
      IMZP0,
      IMAB0: tst_mask <= DIMUX;
    endcase

always @(posedge clk) //T flag management
  if( state == DECODE && RDY ) begin
    if( IR == 8'b1111_0100 ) begin //SET
      T <= 1;
    end
    else if( IR != 8'b0000_0000 ) //don't clear on BRK so T will get pushed
      T <= 0;
    else if( plp ) //retrieve flag on PLP
      T <= ADD[5];
  end
  else if( state == BRK2 && RDY ) //clear T when pushing P
    T <= 0;
  else if( state == RTI2 && RDY ) //retrieve T flag on RTI
    T <= DIMUX[5];

  
always @*
  case( cond_code )
    4'b0001: cond_true = ~N;
    4'b0011: cond_true = N;
    4'b0101: cond_true = ~V;
    4'b0111: cond_true = V;
    4'b1001: cond_true = ~C;
    4'b1011: cond_true = C;
    4'b1101: cond_true = ~Z;
    4'b1111: cond_true = Z;
    default: cond_true = 1; // BRA is 80
  endcase // case ( cond_code )


reg NMI_1 = 0;          // delayed NMI signal

always @(posedge clk)
    NMI_1 <= NMI;

always @(posedge clk )
    if( NMI_edge && state == BRK3 )
        NMI_edge <= 0;
    else if( NMI & ~NMI_1 )
        NMI_edge <= 1;

endmodule
