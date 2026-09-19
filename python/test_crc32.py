"""Tests for the golden model and, when Icarus Verilog is installed, the RTL.

Run from the repository root:  pytest -v
"""

import binascii
import random
import shutil
import zlib

import pytest

import sim
from crc32_model import (DEFAULT, VARIANTS, byte_step_terms, crc32, crc32_serial, crc_bytes,
                         parse_rtl_equations, residue, serial_bits)

ALL = list(VARIANTS.values())
IDS = [v.name for v in ALL]


# --- golden model ----------------------------------------------------------

@pytest.mark.parametrize("v", ALL, ids=IDS)
def test_catalogue_check_value(v):
    assert crc32(b"123456789", v) == v.check


def test_default_matches_zlib_and_binascii():
    rng = random.Random(0)
    for _ in range(500):
        data = rng.randbytes(rng.randint(0, 300))
        assert crc32(data) == zlib.crc32(data) == binascii.crc32(data)


@pytest.mark.parametrize("v", ALL, ids=IDS)
def test_serial_and_parallel_models_agree(v):
    rng = random.Random(1)
    for _ in range(200):
        data = rng.randbytes(rng.randint(1, 64))
        assert crc32_serial(serial_bits(data, v), v) == crc32(data, v)


@pytest.mark.parametrize("v", ALL, ids=IDS)
def test_codeword_has_constant_residue(v):
    """A receiver running the CRC over message + appended CRC always gets the same value."""
    rng = random.Random(2)
    for _ in range(200):
        data = rng.randbytes(rng.randint(1, 64))
        assert crc32(data + crc_bytes(crc32(data, v), v), v) == residue(v)


def test_ethernet_residue():
    assert residue(DEFAULT) == 0x2144DF1C   # the well-known Ethernet/zlib magic number


@pytest.mark.parametrize("v", ALL, ids=IDS)
def test_single_bit_errors_are_detected(v):
    data = b"CRC-32 detects every single-bit error"
    good = crc32(data, v)
    for bit in range(8 * len(data)):
        corrupted = bytearray(data)
        corrupted[bit // 8] ^= 1 << (bit % 8)
        assert crc32(bytes(corrupted), v) != good


# --- RTL vs model, no simulator needed ------------------------------------

def test_parallel_rtl_equations_match_derivation():
    assert parse_rtl_equations(sim.ROOT / "rtl" / "crc32_parallel.v") == byte_step_terms()


def test_original_modelsim_capture_is_reproduced():
    """The original ModelSim run fed 55 AA x 6 with a zero-initialised register and
    showed DE, 18 as the first CRC bytes on crc_out (docs/images/original_parallel_modelsim.jpg)."""
    assert crc32(bytes([0x55, 0xAA] * 6), VARIANTS["RAW"]) >> 16 == 0xDE18


# --- RTL simulation -------------------------------------------------------

@pytest.mark.skipif(shutil.which("iverilog") is None, reason="Icarus Verilog not installed")
@pytest.mark.parametrize("v", ALL, ids=IDS)
@pytest.mark.parametrize("design", sim.DESIGNS)
def test_rtl_simulation(design, v, tmp_path):
    out = sim.run(design, v, workdir=tmp_path)
    assert "PASS" in out and "FAIL" not in out, out
