// SPDX-License-Identifier: CERN-OHL-W-2.0
//
// Self-checking testbench for crc32_serial.
//
// Uses the same vector file as tb_crc32_parallel (bytes plus expected CRC) and
// serialises each byte LSB-first when REFOUT = 1, MSB-first otherwise. Frames
// are sent back to back without resets, and every output bit is checked: the
// echoed message, the 32 appended CRC bits and the `crc` result.
//
// Plusargs: +VECTORS=<file> (default vectors.hex), +WAVES=<file.vcd>

`timescale 1ns / 1ps

module tb_crc32_serial;

    parameter [31:0] INIT      = 32'hFFFF_FFFF;
    parameter        REFOUT    = 1;
    parameter [31:0] XOROUT    = 32'hFFFF_FFFF;
    parameter        MAX_WORDS = 1 << 16;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         load = 1'b0;
    reg         d_finish = 1'b0;
    reg         crc_in = 1'b0;
    wire        crc_out;
    wire [31:0] crc;
    wire        crc_valid;

    crc32_serial #(
        .INIT(INIT), .REFOUT(REFOUT), .XOROUT(XOROUT)
    ) dut (
        .clk(clk), .rst(rst), .load(load), .d_finish(d_finish),
        .crc_in(crc_in), .crc_out(crc_out), .crc(crc), .crc_valid(crc_valid)
    );

    always #5 clk = ~clk;

    reg [31:0]    mem [0:MAX_WORDS-1];
    reg [8*256:1] vec_file, wave_file;
    integer       n_frames, frame, ptr, len, i, errors, seed, nbits;
    reg [31:0]    expected;
    reg [7:0]     byte_val;
    reg           bit_val, want;

    initial begin
        errors = 0;
        seed   = 1;
        if (!$value$plusargs("VECTORS=%s", vec_file)) vec_file = "vectors.hex";
        if ($value$plusargs("WAVES=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_crc32_serial);
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
            nbits    = 8 * len;

            load = 1'b1;
            @(negedge clk);
            load = 1'b0;

            for (i = 0; i < nbits; i = i + 1) begin
                byte_val = mem[ptr + i / 8];
                bit_val  = REFOUT ? byte_val[i % 8] : byte_val[7 - i % 8];
                crc_in   = bit_val;
                d_finish = (i == nbits - 1);
                @(negedge clk);
                if (crc_out !== bit_val) begin
                    errors = errors + 1;
                    $display("FAIL frame %0d echo bit %0d: got %b expected %b", frame, i, crc_out, bit_val);
                end
            end
            ptr      = ptr + len;
            d_finish = 1'b0;
            crc_in   = $random(seed);

            if (!crc_valid || crc !== expected) begin
                errors = errors + 1;
                $display("FAIL frame %0d: crc=%08h valid=%b expected %08h", frame, crc, crc_valid, expected);
            end

            for (i = 0; i < 32; i = i + 1) begin
                @(negedge clk);
                want = REFOUT ? expected[i] : expected[31 - i];
                if (crc_out !== want) begin
                    errors = errors + 1;
                    $display("FAIL frame %0d crc bit %0d: got %b expected %b", frame, i, crc_out, want);
                end
            end

            if (dut.state !== dut.IDLE) begin
                errors = errors + 1;
                $display("FAIL frame %0d: not back in IDLE after the CRC", frame);
            end

            repeat ($unsigned($random(seed)) % 4) @(negedge clk);
        end
        repeat (2) @(negedge clk);

        if (errors == 0)
            $display("PASS: %0d frames, crc32_serial INIT=%08h REFOUT=%0d XOROUT=%08h",
                     n_frames, INIT, REFOUT, XOROUT);
        else
            $display("FAIL: %0d errors in %0d frames", errors, n_frames);
        $finish;
    end

endmodule
