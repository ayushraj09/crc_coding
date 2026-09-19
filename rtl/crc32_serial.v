// SPDX-License-Identifier: CERN-OHL-W-2.0
//
// crc32_serial - bit-serial CRC-32 generator (1 message bit per clock).
//
// Derived from "CRC Coding / CRC_32_serial" in github.com/sudhamshu091/Verilog
// (CERN-OHL-W-2.0). Modified by Ayush Raj, 2026:
//   * feedback taps corrected to the CRC-32 polynomial 0x04C11DB7 (the
//     original tapped bits 0, 2 and 31 only, i.e. x^32+x^31+x^2+1, carried over
//     from the CRC-16 design)
//   * single clocked process with a synchronous active-high reset (the original
//     mixed `negedge rst` with `if (rst)` and drove `state`/`count` from two
//     processes)
//   * FINISH shifts out exactly 32 bits and clears `count` (it produced 33 bits
//     and left `count` at 32, so every later frame was cut short)
//   * INIT / REFOUT / XOROUT parameters and `crc` / `crc_valid` outputs
//
// Protocol
//   1. Pulse `load` for one cycle while idle.
//   2. On each following clock present one bit on `crc_in`; assert `d_finish`
//      together with the last bit.
//   3. `crc`/`crc_valid` update on the clock that takes the last bit, and the
//      next 32 clocks shift the CRC out on `crc_out`.
//   `crc_out` echoes each message bit one clock later, so the output stream is
//   the codeword: message followed by CRC.
//
// Bit order is the sender's choice. For the reflected (Ethernet/zlib) variant
// send each byte LSB-first and keep REFOUT = 1; the CRC then also goes out
// LSB-first. With REFOUT = 0 send MSB-first and the CRC goes out MSB-first.

`timescale 1ns / 1ps

module crc32_serial #(
    parameter [31:0] INIT   = 32'hFFFF_FFFF,
    parameter        REFOUT = 1,
    parameter [31:0] XOROUT = 32'hFFFF_FFFF
) (
    input  wire        clk,
    input  wire        rst,        // synchronous, active-high
    input  wire        load,       // start a new frame
    input  wire        d_finish,   // high with the last bit of the frame
    input  wire        crc_in,     // message bit
    output reg         crc_out,    // codeword stream: message bits, then CRC bits
    output reg  [31:0] crc,        // CRC of the most recent frame
    output reg         crc_valid   // `crc` holds a finished result
);

    // x^32+x^26+x^23+x^22+x^16+x^12+x^11+x^10+x^8+x^7+x^5+x^4+x^2+x+1
    localparam [31:0] POLY = 32'h04C1_1DB7;

    localparam [1:0] IDLE    = 2'd0,
                     COMPUTE = 2'd1,
                     FINISH  = 2'd2;

    reg [1:0]  state;
    reg [4:0]  count;     // CRC bits already shifted out
    reg [31:0] crc_reg;   // running remainder, then the final CRC while shifting out

    function [31:0] reverse32(input [31:0] x);
        integer i;
        for (i = 0; i < 32; i = i + 1) reverse32[i] = x[31 - i];
    endfunction

    // Galois LFSR: shift left and, when the bit leaving the register differs
    // from the incoming message bit, XOR the polynomial taps back in.
    wire        feedback  = crc_reg[31] ^ crc_in;
    wire [31:0] next_crc  = {crc_reg[30:0], 1'b0} ^ (feedback ? POLY : 32'h0);
    wire [31:0] final_crc = (REFOUT ? reverse32(next_crc) : next_crc) ^ XOROUT;

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            count     <= 5'd0;
            crc_reg   <= INIT;
            crc_out   <= 1'b0;
            crc       <= 32'h0;
            crc_valid <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    crc_reg <= INIT;
                    crc_out <= 1'b0;
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
                        count     <= 5'd0;
                        state     <= FINISH;
                    end else begin
                        crc_reg <= next_crc;
                    end
                end

                FINISH: begin
                    if (REFOUT) begin
                        crc_out <= crc_reg[0];
                        crc_reg <= {1'b0, crc_reg[31:1]};
                    end else begin
                        crc_out <= crc_reg[31];
                        crc_reg <= {crc_reg[30:0], 1'b0};
                    end
                    count <= count + 5'd1;
                    if (count == 5'd31)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
