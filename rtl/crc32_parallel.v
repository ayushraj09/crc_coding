// SPDX-License-Identifier: CERN-OHL-W-2.0
//
// crc32_parallel - byte-parallel CRC-32 generator (8 message bits per clock).
//
// Derived from "CRC Coding / CRC_32_parallel" in github.com/sudhamshu091/Verilog
// (CERN-OHL-W-2.0). Modified by Ayush Raj, 2026:
//   * single clocked process with a synchronous active-high reset (the original
//     mixed `negedge rst` with `if (rst)` and drove `state` from two processes)
//   * FINISH now counts the 4 CRC bytes and returns to IDLE (`count` was never
//     incremented, so the FSM hung after the first frame)
//   * INIT / REFIN / REFOUT / XOROUT parameters, so the same core produces
//     standard CRC-32 (Ethernet/zlib) as well as the original raw remainder
//   * `crc` / `crc_valid` outputs for the finished 32-bit result
//
// Protocol
//   1. Pulse `load` for one cycle while idle.
//   2. On each following clock present one byte on `crc_in`; assert `d_finish`
//      together with the last byte (frames are 1 byte or longer).
//   3. `crc`/`crc_valid` update on the clock that takes the last byte, and the
//      next 4 clocks shift the CRC out on `crc_out`, after which the core is idle.
//   `crc_out` echoes each message byte one clock after it is taken, so the
//   output stream is the complete codeword: message followed by CRC.
//
// Polynomial x^32+x^26+x^23+x^22+x^16+x^12+x^11+x^10+x^8+x^7+x^5+x^4+x^2+x+1
// (0x04C11DB7). The next-state equations below are eight steps of the serial
// LFSR unrolled; `python/crc32_model.py --equations` regenerates them and the
// test suite checks this file against that derivation.

`timescale 1ns / 1ps

module crc32_parallel #(
    parameter [31:0] INIT   = 32'hFFFF_FFFF,
    parameter        REFIN  = 1,             // take input bytes LSB-first
    parameter        REFOUT = 1,             // bit-reverse the result, send LSB byte first
    parameter [31:0] XOROUT = 32'hFFFF_FFFF
) (
    input  wire        clk,
    input  wire        rst,        // synchronous, active-high
    input  wire        load,       // start a new frame
    input  wire        d_finish,   // high with the last byte of the frame
    input  wire [7:0]  crc_in,     // message byte
    output reg  [7:0]  crc_out,    // codeword stream: message bytes, then CRC bytes
    output reg  [31:0] crc,        // CRC of the most recent frame
    output reg         crc_valid   // `crc` holds a finished result
);

    localparam [1:0] IDLE    = 2'd0,
                     COMPUTE = 2'd1,
                     FINISH  = 2'd2;

    reg [1:0]  state;
    reg [1:0]  count;     // CRC bytes already shifted out
    reg [31:0] crc_reg;   // running remainder, then the final CRC while shifting out

    function [31:0] reverse32(input [31:0] x);
        integer i;
        for (i = 0; i < 32; i = i + 1) reverse32[i] = x[31 - i];
    endfunction

    function [7:0] reverse8(input [7:0] x);
        integer i;
        for (i = 0; i < 8; i = i + 1) reverse8[i] = x[7 - i];
    endfunction

    wire [31:0] c = crc_reg;
    wire [7:0]  d = REFIN ? reverse8(crc_in) : crc_in;
    wire [31:0] next_crc;

    assign next_crc[0]  = c[24] ^ c[30] ^ d[0] ^ d[6];
    assign next_crc[1]  = c[24] ^ c[25] ^ c[30] ^ c[31] ^ d[0] ^ d[1] ^ d[6] ^ d[7];
    assign next_crc[2]  = c[24] ^ c[25] ^ c[26] ^ c[30] ^ c[31] ^ d[0] ^ d[1] ^ d[2] ^ d[6] ^ d[7];
    assign next_crc[3]  = c[25] ^ c[26] ^ c[27] ^ c[31] ^ d[1] ^ d[2] ^ d[3] ^ d[7];
    assign next_crc[4]  = c[24] ^ c[26] ^ c[27] ^ c[28] ^ c[30] ^ d[0] ^ d[2] ^ d[3] ^ d[4] ^ d[6];
    assign next_crc[5]  = c[24] ^ c[25] ^ c[27] ^ c[28] ^ c[29] ^ c[30] ^ c[31] ^ d[0] ^ d[1] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ d[7];
    assign next_crc[6]  = c[25] ^ c[26] ^ c[28] ^ c[29] ^ c[30] ^ c[31] ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[6] ^ d[7];
    assign next_crc[7]  = c[24] ^ c[26] ^ c[27] ^ c[29] ^ c[31] ^ d[0] ^ d[2] ^ d[3] ^ d[5] ^ d[7];
    assign next_crc[8]  = c[0] ^ c[24] ^ c[25] ^ c[27] ^ c[28] ^ d[0] ^ d[1] ^ d[3] ^ d[4];
    assign next_crc[9]  = c[1] ^ c[25] ^ c[26] ^ c[28] ^ c[29] ^ d[1] ^ d[2] ^ d[4] ^ d[5];
    assign next_crc[10] = c[2] ^ c[24] ^ c[26] ^ c[27] ^ c[29] ^ d[0] ^ d[2] ^ d[3] ^ d[5];
    assign next_crc[11] = c[3] ^ c[24] ^ c[25] ^ c[27] ^ c[28] ^ d[0] ^ d[1] ^ d[3] ^ d[4];
    assign next_crc[12] = c[4] ^ c[24] ^ c[25] ^ c[26] ^ c[28] ^ c[29] ^ c[30] ^ d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[6];
    assign next_crc[13] = c[5] ^ c[25] ^ c[26] ^ c[27] ^ c[29] ^ c[30] ^ c[31] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[6] ^ d[7];
    assign next_crc[14] = c[6] ^ c[26] ^ c[27] ^ c[28] ^ c[30] ^ c[31] ^ d[2] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
    assign next_crc[15] = c[7] ^ c[27] ^ c[28] ^ c[29] ^ c[31] ^ d[3] ^ d[4] ^ d[5] ^ d[7];
    assign next_crc[16] = c[8] ^ c[24] ^ c[28] ^ c[29] ^ d[0] ^ d[4] ^ d[5];
    assign next_crc[17] = c[9] ^ c[25] ^ c[29] ^ c[30] ^ d[1] ^ d[5] ^ d[6];
    assign next_crc[18] = c[10] ^ c[26] ^ c[30] ^ c[31] ^ d[2] ^ d[6] ^ d[7];
    assign next_crc[19] = c[11] ^ c[27] ^ c[31] ^ d[3] ^ d[7];
    assign next_crc[20] = c[12] ^ c[28] ^ d[4];
    assign next_crc[21] = c[13] ^ c[29] ^ d[5];
    assign next_crc[22] = c[14] ^ c[24] ^ d[0];
    assign next_crc[23] = c[15] ^ c[24] ^ c[25] ^ c[30] ^ d[0] ^ d[1] ^ d[6];
    assign next_crc[24] = c[16] ^ c[25] ^ c[26] ^ c[31] ^ d[1] ^ d[2] ^ d[7];
    assign next_crc[25] = c[17] ^ c[26] ^ c[27] ^ d[2] ^ d[3];
    assign next_crc[26] = c[18] ^ c[24] ^ c[27] ^ c[28] ^ c[30] ^ d[0] ^ d[3] ^ d[4] ^ d[6];
    assign next_crc[27] = c[19] ^ c[25] ^ c[28] ^ c[29] ^ c[31] ^ d[1] ^ d[4] ^ d[5] ^ d[7];
    assign next_crc[28] = c[20] ^ c[26] ^ c[29] ^ c[30] ^ d[2] ^ d[5] ^ d[6];
    assign next_crc[29] = c[21] ^ c[27] ^ c[30] ^ c[31] ^ d[3] ^ d[6] ^ d[7];
    assign next_crc[30] = c[22] ^ c[28] ^ c[31] ^ d[4] ^ d[7];
    assign next_crc[31] = c[23] ^ c[29] ^ d[5];

    wire [31:0] final_crc = (REFOUT ? reverse32(next_crc) : next_crc) ^ XOROUT;

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            count     <= 2'd0;
            crc_reg   <= INIT;
            crc_out   <= 8'h00;
            crc       <= 32'h0;
            crc_valid <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    crc_reg <= INIT;
                    crc_out <= 8'h00;
                    if (load) begin
                        crc_valid <= 1'b0;
                        state     <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    crc_out <= crc_in;
                    if (d_finish) begin
                        crc_reg   <= final_crc;
                        crc       <= final_crc;
                        crc_valid <= 1'b1;
                        count     <= 2'd0;
                        state     <= FINISH;
                    end else begin
                        crc_reg <= next_crc;
                    end
                end

                FINISH: begin
                    // Reflected CRCs go out least-significant byte first (as in
                    // Ethernet); non-reflected ones most-significant byte first.
                    if (REFOUT) begin
                        crc_out <= crc_reg[7:0];
                        crc_reg <= {8'h00, crc_reg[31:8]};
                    end else begin
                        crc_out <= crc_reg[31:24];
                        crc_reg <= {crc_reg[23:0], 8'h00};
                    end
                    count <= count + 2'd1;
                    if (count == 2'd3)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
