"""Bit-accurate golden model for the CRC-32 RTL in ../rtl.

The hardware implements the CRC-32 polynomial 0x04C11DB7 as an MSB-first
("non-reflected") LFSR. Every standard CRC-32 flavour is that same engine plus
four knobs from the Rocksoft/Williams parameter model:

    init    value loaded into the register at the start of a frame
    refin   feed each input byte LSB-first instead of MSB-first
    refout  bit-reverse the final register
    xorout  XOR applied to the (possibly reversed) register at the end

This module mirrors the RTL structure (a 1-bit step for the serial design and
an 8-bit step for the parallel design) so it can be used to generate expected
values for the testbenches and to re-derive the parallel XOR equations.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

POLY = 0x04C11DB7
MASK = 0xFFFFFFFF


@dataclass(frozen=True)
class Variant:
    name: str
    init: int
    refin: bool
    refout: bool
    xorout: int
    check: int  # CRC of b"123456789", from the reveng CRC catalogue
    note: str = ""


VARIANTS = {
    v.name: v
    for v in [
        Variant("CRC-32/ISO-HDLC", 0xFFFFFFFF, True, True, 0xFFFFFFFF, 0xCBF43926,
                "Ethernet FCS, zlib, PNG, gzip, Python binascii.crc32"),
        Variant("CRC-32/BZIP2", 0xFFFFFFFF, False, False, 0xFFFFFFFF, 0xFC891918,
                "bzip2, AAL5, DECT-B"),
        Variant("CRC-32/MPEG-2", 0xFFFFFFFF, False, False, 0x00000000, 0x0376E6E7,
                "MPEG-2 transport stream PSI tables"),
        Variant("CRC-32/JAMCRC", 0xFFFFFFFF, True, True, 0x00000000, 0x340BC6D9,
                "ISO-HDLC without the final inversion"),
        Variant("RAW", 0x00000000, False, False, 0x00000000, 0x89A1897F,
                "Plain polynomial remainder - what the original design computed"),
    ]
}
DEFAULT = VARIANTS["CRC-32/ISO-HDLC"]


def reflect(value: int, width: int) -> int:
    """Reverse the lowest `width` bits of `value`."""
    out = 0
    for _ in range(width):
        out = (out << 1) | (value & 1)
        value >>= 1
    return out


def step_bit(crc: int, bit: int) -> int:
    """One clock of the serial LFSR: shift left, feed back through POLY."""
    feedback = ((crc >> 31) ^ bit) & 1
    crc = (crc << 1) & MASK
    return crc ^ POLY if feedback else crc


def step_byte(crc: int, byte: int) -> int:
    """One clock of the parallel design: eight serial steps, MSB (bit 7) first."""
    for i in range(7, -1, -1):
        crc = step_bit(crc, (byte >> i) & 1)
    return crc


def finalize(crc: int, v: Variant) -> int:
    if v.refout:
        crc = reflect(crc, 32)
    return crc ^ v.xorout


def crc32(data: bytes, v: Variant = DEFAULT) -> int:
    crc = v.init
    for byte in data:
        crc = step_byte(crc, reflect(byte, 8) if v.refin else byte)
    return finalize(crc, v)


def serial_bits(data: bytes, v: Variant = DEFAULT) -> list[int]:
    """Wire order of `data` for the serial design (LSB-first when refin)."""
    order = range(8) if v.refin else range(7, -1, -1)
    return [(byte >> i) & 1 for byte in data for i in order]


def crc32_serial(bits: list[int], v: Variant = DEFAULT) -> int:
    crc = v.init
    for bit in bits:
        crc = step_bit(crc, bit)
    return finalize(crc, v)


def crc_bytes(crc: int, v: Variant = DEFAULT) -> bytes:
    """The four CRC bytes in the order the RTL appends them to the frame.

    Reflected variants send the least-significant byte first (as Ethernet
    does), so that running the same CRC over message + CRC gives a constant
    residue at the receiver.
    """
    return crc.to_bytes(4, "little" if v.refout else "big")


def residue(v: Variant = DEFAULT) -> int:
    """CRC of any valid codeword (message followed by its crc_bytes)."""
    return crc32(b"\x00" + crc_bytes(crc32(b"\x00", v), v), v)


# --------------------------------------------------------------------------
# Parallel (8 bits per clock) next-state equations
# --------------------------------------------------------------------------

def byte_step_terms() -> list[tuple[list[int], list[int]]]:
    """For each next-state bit, the current-state (c) and data (d) bits it XORs.

    step_byte is linear over GF(2), so feeding one basis vector at a time and
    recording which output bits flip gives the full XOR matrix.
    """
    terms: list[tuple[list[int], list[int]]] = [([], []) for _ in range(32)]
    for k in range(32):
        out = step_byte(1 << k, 0)
        for i in range(32):
            if (out >> i) & 1:
                terms[i][0].append(k)
    for k in range(8):
        out = step_byte(0, 1 << k)
        for i in range(32):
            if (out >> i) & 1:
                terms[i][1].append(k)
    return terms


def verilog_equations() -> str:
    lines = []
    for i, (cs, ds) in enumerate(byte_step_terms()):
        rhs = " ^ ".join([f"c[{k}]" for k in cs] + [f"d[{k}]" for k in ds])
        lines.append(f"    assign next_crc[{i}]{' ' if i < 10 else ''} = {rhs};")
    return "\n".join(lines)


def parse_rtl_equations(path: Path) -> list[tuple[list[int], list[int]]]:
    """Read the `assign next_crc[i] = ...;` equations back out of the RTL."""
    text = Path(path).read_text()
    found = {}
    for m in re.finditer(r"assign\s+next_crc\[(\d+)\]\s*=\s*([^;]+);", text):
        rhs = m.group(2)
        cs = sorted(int(x) for x in re.findall(r"\bc\[(\d+)\]", rhs))
        ds = sorted(int(x) for x in re.findall(r"\bd\[(\d+)\]", rhs))
        found[int(m.group(1))] = (cs, ds)
    return [found.get(i, ([], [])) for i in range(32)]


def main(argv: list[str]) -> None:
    if len(argv) > 1 and argv[1] == "--equations":
        print(verilog_equations())
        return
    data = (argv[1] if len(argv) > 1 else "123456789").encode()
    print(f"message: {data!r}")
    for v in VARIANTS.values():
        print(f"  {v.name:16s} 0x{crc32(data, v):08X}   ({v.note})")


if __name__ == "__main__":
    main(sys.argv)
