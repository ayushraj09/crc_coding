# CRC-32 Generator — Serial & Parallel (Verilog)

Two synchronous CRC-style checksum generators in Verilog: a bit-serial version (1 bit/clock) and a byte-parallel version (8 bits/clock). Both are modeled as a 3-state FSM (`idle` → `compute` → `finish`) around a 32-bit shift register, and verified in simulation with dedicated testbenches.

## Files

| File | Description |
|---|---|
| `CRC_32_serial.v` | 1-bit-per-clock CRC generator |
| `CRC_32_serial_tb.v` | Testbench for the serial version |
| `CRC_32_parallel.v` | 8-bit-per-clock (byte-wide) CRC generator |
| `CRC_32_parallel_tb.v` | Testbench for the parallel version |

## Architecture

- **FSM**: `idle` waits for `load`; `compute` absorbs input each clock while `d_finish` is low; `finish` shifts the computed remainder out.
- **Serial**: `crc_in`/`crc_out` are 1 bit wide. The register's low bits and bit 31 update via a feedback tap each clock.
- **Parallel**: `crc_in`/`crc_out` are 8 bits wide. Next-state logic for all 32 register bits is precomputed combinationally (`next_crc_reg`) as a function of the current register and the incoming byte, so one full byte is absorbed per clock instead of one bit.

## Simulation

Both modules were simulated (ISE/ModelSim) with testbenches driving alternating input patterns (`8'h55`/`8'haa` for parallel, toggling bits for serial). Waveforms confirm the FSM transitions through `idle → compute → finish` and that `crc_out` reflects the shifted-out register contents once computation completes.

## Known limitations

- **Parallel FSM stall**: `count` in `CRC_32_parallel.v` is never incremented, so `finish → idle` (`count==2`) is unreachable — the design can't currently process more than one load.
- **Serial polynomial mismatch**: the serial module's feedback taps implement a CRC-16-style recurrence (`x^16+x^15+x^2+1`), not the standard CRC-32/IEEE-802.3 polynomial (`0x04C11DB7`). Needs correcting if this is meant to match real CRC-32 output.
- Two separate `always @(posedge clk)` blocks in the parallel module both reference `state` — works today because only one of them writes it outside reset, but worth consolidating into one process.
- Simulation-only so far; not yet synthesized or deployed on hardware.

## Next steps

- [ ] Fix the parallel FSM's `count` increment so it can return to `idle`.
- [ ] Correct the serial polynomial to the standard CRC-32 recurrence.
- [ ] Verify output against a software reference (e.g. Python `binascii.crc32`), including the standard check value `CRC32("123456789") == 0xCBF43926`.
- [ ] Synthesize and deploy on a Spartan-6 FPGA (Xilinx ISE); validate on real hardware.
- [ ] Add a UART interface to compute CRC on host-supplied data and cross-check against a software-side computation.