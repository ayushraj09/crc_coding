// SPDX-License-Identifier: CERN-OHL-W-2.0
//
// Self-checking testbench for crc32_parallel.
//
// Frames and expected CRCs come from the Python golden model
// (python/sim.py writes the vector file). Frames are sent back to back with a
// random 0-3 cycle gap, without resetting in between, and every output byte is
// checked: the echoed message, the 4 appended CRC bytes and the `crc` result.
//
// Vector file: 32-bit hex words - frame count, then per frame:
//   length, expected CRC, then `length` words holding one byte each.
//
// Plusargs: +VECTORS=<file> (default vectors.hex), +WAVES=<file.vcd>

`timescale 1ns / 1ps

module tb_crc32_parallel;

    parameter [31:0] INIT      = 32'hFFFF_FFFF;
    parameter        REFIN     = 1;
    parameter        REFOUT    = 1;
    parameter [31:0] XOROUT    = 32'hFFFF_FFFF;
    parameter        MAX_WORDS = 1 << 16;

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg        load = 1'b0;
    reg        d_finish = 1'b0;
    reg  [7:0] crc_in = 8'h00;
    wire [7:0] crc_out;
    wire [31:0] crc;
    wire       crc_valid;

    crc32_parallel #(
        .INIT(INIT), .REFIN(REFIN), .REFOUT(REFOUT), .XOROUT(XOROUT)
    ) dut (
        .clk(clk), .rst(rst), .load(load), .d_finish(d_finish),
        .crc_in(crc_in), .crc_out(crc_out), .crc(crc), .crc_valid(crc_valid)
    );

    always #5 clk = ~clk;   // 100 MHz

    reg [31:0]    mem [0:MAX_WORDS-1];
    reg [8*256:1] vec_file, wave_file;
    integer       n_frames, frame, ptr, len, i, errors, seed;
    reg [31:0]    expected;
    reg [7:0]     want;

    task check_byte(input [7:0] got, input [7:0] exp, input [8*16:1] what, input integer idx);
        if (got !== exp) begin
            errors = errors + 1;
            $display("FAIL frame %0d %0s[%0d]: got %02h expected %02h", frame, what, idx, got, exp);
        end
    endtask

    initial begin
        errors = 0;
        seed   = 1;
        if (!$value$plusargs("VECTORS=%s", vec_file)) vec_file = "vectors.hex";
        if ($value$plusargs("WAVES=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_crc32_parallel);
        end
        $readmemh(vec_file, mem);
        n_frames = mem[0];
        ptr      = 1;

        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        for (frame = 0; frame < n_frames; frame = frame + 1) begin
            len      = mem[ptr];
            expected = mem[ptr + 1];
            ptr      = ptr + 2;

            load = 1'b1;
            @(negedge clk);
            load = 1'b0;

            // Message bytes: each is taken on the next rising edge and echoed.
            for (i = 0; i < len; i = i + 1) begin
                crc_in   = mem[ptr + i];
                d_finish = (i == len - 1);
                @(negedge clk);
                check_byte(crc_out, mem[ptr + i], "echo", i);
            end
            ptr      = ptr + len;
            d_finish = 1'b0;
            crc_in   = $random(seed);   // must be ignored from here on

            if (!crc_valid || crc !== expected) begin
                errors = errors + 1;
                $display("FAIL frame %0d: crc=%08h valid=%b expected %08h", frame, crc, crc_valid, expected);
            end

            // Appended CRC bytes.
            for (i = 0; i < 4; i = i + 1) begin
                @(negedge clk);
                want = REFOUT ? expected >> (8 * i) : expected >> (8 * (3 - i));
                check_byte(crc_out, want, "crc", i);
            end

            if (dut.state !== dut.IDLE) begin
                errors = errors + 1;
                $display("FAIL frame %0d: not back in IDLE after the CRC", frame);
            end

            repeat ($unsigned($random(seed)) % 4) @(negedge clk);
        end
        repeat (2) @(negedge clk);

        if (errors == 0)
            $display("PASS: %0d frames, crc32_parallel INIT=%08h REFIN=%0d REFOUT=%0d XOROUT=%08h",
                     n_frames, INIT, REFIN, REFOUT, XOROUT);
        else
            $display("FAIL: %0d errors in %0d frames", errors, n_frames);
        $finish;
    end

endmodule
