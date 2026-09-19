"""Simulate crc32_parallel on b"123456789" and draw the waveform as an SVG.

    python python/wave_svg.py [output.svg]

Writes docs/images/parallel_waveform.svg by default. Only the standard library
is used: the VCD is parsed here and the timing diagram is drawn by hand.
"""

from __future__ import annotations

import sys
from pathlib import Path

import sim
from crc32_model import DEFAULT

SIGNALS = [  # (VCD name, label)
    ("clk", "clk"),
    ("rst", "rst"),
    ("load", "load"),
    ("crc_in", "crc_in[7:0]"),
    ("d_finish", "d_finish"),
    ("crc_out", "crc_out[7:0]"),
    ("crc_valid", "crc_valid"),
    ("crc", "crc[31:0]"),
]

INK, MUTED, GRID, SURFACE, UNKNOWN = "#1f2328", "#59636e", "#d8dee4", "#ffffff", "#9aa4ae"
LABEL_W, NS_PX, ROW_H, SIG_H, TOP = 118, 4.2, 34, 18, 34


def parse_vcd(path: Path) -> tuple[dict[str, list[tuple[int, str]]], dict[str, int]]:
    """Return {signal: [(time, value), ...]} and {signal: width} for the testbench scope."""
    ids, widths, changes = {}, {}, {}
    scope: list[str] = []
    time = 0
    tokens = path.read_text().split()
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "$scope":
            scope.append(tokens[i + 2]); i += 4; continue
        if tok == "$upscope":
            scope.pop(); i += 2; continue
        if tok == "$var":
            width, ident, name = int(tokens[i + 2]), tokens[i + 3], tokens[i + 4]
            if len(scope) == 1:  # testbench level only
                ids.setdefault(ident, name)
                widths[name] = width
                changes[name] = []
            i = tokens.index("$end", i) + 1; continue
        if tok.startswith("$"):
            i = tokens.index("$end", i) + 1 if tok != "$dumpvars" else i + 1; continue
        if tok.startswith("#"):
            time = int(tok[1:])
        elif tok[0] in "bB":
            if tokens[i + 1] in ids:
                changes[ids[tokens[i + 1]]].append((time, tok[1:]))
            i += 1
        elif tok[0] in "01xXzZ" and tok[1:] in ids:
            changes[ids[tok[1:]]].append((time, tok[0]))
        i += 1
    return changes, widths


def value_at(trace: list[tuple[int, str]], t: int) -> str:
    v = "x"
    for time, val in trace:
        if time > t:
            break
        v = val
    return v


def to_hex(bits: str, width: int) -> str:
    if any(c in "xXzZ" for c in bits):
        return "x"
    return f"{int(bits, 2):0{(width + 3) // 4}X}"


def render(vcd: Path, out: Path, t0: int, t1: int, timescale_ps: int = 1000) -> None:
    changes, widths = parse_vcd(vcd)
    scale = NS_PX / timescale_ps          # px per VCD time unit
    x = lambda t: LABEL_W + (t - t0) * scale
    width = int(x(t1) + 12)
    height = TOP + ROW_H * len(SIGNALS) + 14
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" '
           f'font-size="11">',
           f'<rect width="100%" height="100%" fill="{SURFACE}"/>']

    # Rising-edge grid and time axis.
    clk_rises = [t for t, v in changes["clk"] if v == "1" and t0 <= t <= t1]
    for t in clk_rises:
        svg.append(f'<line x1="{x(t):.1f}" y1="{TOP - 8}" x2="{x(t):.1f}" y2="{height - 10}" '
                   f'stroke="{GRID}" stroke-width="1"/>')
    for t in clk_rises[::4]:
        svg.append(f'<text x="{x(t):.1f}" y="{TOP - 14}" fill="{MUTED}" text-anchor="middle">'
                   f'{t // timescale_ps} ns</text>')

    for row, (name, label) in enumerate(SIGNALS):
        y_hi = TOP + row * ROW_H + 4
        y_lo = y_hi + SIG_H
        y_mid = (y_hi + y_lo) / 2
        svg.append(f'<text x="8" y="{y_mid + 4:.1f}" fill="{INK}">{label}</text>')
        trace = changes[name]
        # Segments within the window: [(start, end, value)].
        points = [t0] + [t for t, _ in trace if t0 < t < t1] + [t1]
        segs = [(a, b, value_at(trace, a)) for a, b in zip(points, points[1:]) if b > a]

        if widths[name] == 1:
            path = []
            for a, b, v in segs:
                y = y_hi if v == "1" else y_lo if v == "0" else y_mid
                path.append(f"{'M' if not path else 'L'}{x(a):.1f},{y:.1f} L{x(b):.1f},{y:.1f}")
            svg.append(f'<path d="{" ".join(path)}" fill="none" stroke="{INK}" stroke-width="1.5"/>')
            continue

        merged: list[list] = []   # merge equal consecutive bus values
        for a, b, v in segs:
            hv = to_hex(v, widths[name])
            if merged and merged[-1][2] == hv:
                merged[-1][1] = b
            else:
                merged.append([a, b, hv])
        for a, b, hv in merged:
            xa, xb, s = x(a), x(b), 3
            color = UNKNOWN if hv == "x" else INK
            svg.append(f'<path d="M{xa:.1f},{y_mid:.1f} L{xa + s:.1f},{y_hi} L{xb - s:.1f},{y_hi} '
                       f'L{xb:.1f},{y_mid:.1f} L{xb - s:.1f},{y_lo} L{xa + s:.1f},{y_lo} Z" '
                       f'fill="{SURFACE}" stroke="{color}" stroke-width="1.2"/>')
            if hv != "x" and (xb - xa) >= 7 * len(hv) + 6:
                svg.append(f'<text x="{(xa + xb) / 2:.1f}" y="{y_mid + 4:.1f}" fill="{INK}" '
                           f'text-anchor="middle">{hv}</text>')
    svg.append("</svg>")
    out.write_text("\n".join(svg) + "\n")


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else sim.ROOT / "docs" / "images" / "parallel_waveform.svg"
    work = sim.BUILD / "wave"
    output = sim.run("parallel", DEFAULT, frames=[b"123456789"], workdir=work, waves=True)
    assert "PASS" in output, output
    vcd = next(work.glob("*.vcd"))
    end = max(t for trace in parse_vcd(vcd)[0].values() for t, _ in trace)
    render(vcd, out, t0=5_000, t1=end)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
