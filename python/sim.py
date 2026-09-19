"""Run the RTL testbenches in Icarus Verilog against the Python golden model.

    python python/sim.py                          # both designs, every variant
    python python/sim.py --design parallel --variant CRC-32/BZIP2
    python python/sim.py --design serial --waves  # also writes build/*.vcd
"""

from __future__ import annotations

import argparse
import random
import shutil
import subprocess
import sys
from pathlib import Path

from crc32_model import DEFAULT, VARIANTS, Variant, crc32

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
DESIGNS = ("parallel", "serial")


def test_frames(seed: int = 2026, n_random: int = 200) -> list[bytes]:
    """Directed corner cases followed by random frames of 1-64 bytes."""
    frames = [
        b"123456789",                 # catalogue check value
        bytes([0x55, 0xAA] * 6),      # stimulus from the original ModelSim run
        b"\x00", b"\xff", b"\x80", b"\x01",
        bytes(32), b"\xff" * 32,
        bytes(range(256)),
        b"The quick brown fox jumps over the lazy dog",
    ]
    rng = random.Random(seed)
    frames += [rng.randbytes(rng.randint(1, 64)) for _ in range(n_random)]
    return frames


def write_vectors(path: Path, frames: list[bytes], v: Variant) -> None:
    words = [len(frames)]
    for frame in frames:
        words += [len(frame), crc32(frame, v), *frame]
    path.write_text("\n".join(f"{w:08x}" for w in words) + "\n")


def parameters(design: str, v: Variant) -> dict[str, int]:
    params = {"INIT": v.init, "REFOUT": int(v.refout), "XOROUT": v.xorout}
    if design == "parallel":
        params["REFIN"] = int(v.refin)
    elif v.refin != v.refout:
        raise ValueError("serial testbench sends bits in REFOUT order")
    return params


def run(design: str, v: Variant = DEFAULT, frames: list[bytes] | None = None,
        workdir: Path = BUILD, waves: bool = False) -> str:
    """Compile and simulate one design/variant; return the simulator output."""
    if shutil.which("iverilog") is None:
        raise RuntimeError("iverilog not found - install Icarus Verilog")
    workdir.mkdir(parents=True, exist_ok=True)
    tag = f"{design}_{v.name.replace('/', '_').replace('-', '_').lower()}"
    vectors = workdir / f"{tag}.hex"
    binary = workdir / f"{tag}.vvp"
    write_vectors(vectors, frames if frames is not None else test_frames(), v)

    top = f"tb_crc32_{design}"
    cmd = ["iverilog", "-g2005", "-Wall", "-s", top, "-o", str(binary)]
    cmd += [f"-P{top}.{k}={val}" for k, val in parameters(design, v).items()]
    cmd += [str(ROOT / "rtl" / f"crc32_{design}.v"), str(ROOT / "tb" / f"{top}.v")]
    subprocess.run(cmd, check=True, capture_output=True, text=True)

    sim = ["vvp", "-n", str(binary), f"+VECTORS={vectors}"]
    if waves:
        sim.append(f"+WAVES={workdir / (tag + '.vcd')}")
    return subprocess.run(sim, check=True, capture_output=True, text=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--design", choices=DESIGNS, action="append")
    ap.add_argument("--variant", choices=VARIANTS, action="append")
    ap.add_argument("--waves", action="store_true", help="dump a VCD per run into build/")
    args = ap.parse_args()

    failed = 0
    for design in args.design or DESIGNS:
        for name in args.variant or VARIANTS:
            out = run(design, VARIANTS[name], waves=args.waves)
            ok = "PASS" in out and "FAIL" not in out
            failed += not ok
            print(f"[{'PASS' if ok else 'FAIL'}] {design:8s} {name}")
            if not ok:
                print(out)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
