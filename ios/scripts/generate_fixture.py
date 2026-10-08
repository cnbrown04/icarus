#!/usr/bin/env python3
"""Generate ios/Fixtures/resting_day.ndjson.

15 minutes at 1 Hz from 2026-10-07T14:15:00Z of heart-rate-service (0x2A37) frames:
flags 0x16 (UINT8 heart rate, sensor contact detected, R-R present), HR 58-66 bpm,
one R-R interval per frame in 1/1024 s units, little-endian.

Deterministic: fixed seed and an in-file SplitMix64 PRNG, so the output does not depend on
Python's random module. Running it twice writes byte-identical output.

Usage: python3 ios/scripts/generate_fixture.py [output-path]
"""
import json
import math
import sys
from pathlib import Path

SEED = 20261007
START_UNIX = 1791382500  # 2026-10-07T14:15:00Z
DURATION_S = 15 * 60
HR_MIN, HR_MAX = 58, 66
HR_START = 62
FLAGS_RESTING = 0x16
MASK64 = (1 << 64) - 1


class SplitMix64:
    def __init__(self, seed):
        self.state = seed & MASK64

    def next_u64(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def int_in(self, lo, hi):
        return lo + self.next_u64() % (hi - lo + 1)


def build_lines():
    rng = SplitMix64(SEED)
    bpm = HR_START
    lines = []
    for i in range(DURATION_S):
        bpm = min(HR_MAX, max(HR_MIN, bpm + rng.int_in(-1, 1)))
        rr_ms = 60000.0 / bpm + rng.int_in(-25, 25)
        rr_raw = min(0xFFFF, int(math.floor(rr_ms * 1024 / 1000 + 0.5)))
        payload = bytes([FLAGS_RESTING, bpm, rr_raw & 0xFF, rr_raw >> 8])
        lines.append(json.dumps({
            "t": float(START_UNIX + i),
            "char": "2a37",
            "hex": payload.hex(),
        }))
    return lines


def main():
    default_out = Path(__file__).resolve().parent.parent / "Fixtures" / "resting_day.ndjson"
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else default_out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(("\n".join(build_lines()) + "\n").encode("utf-8"))
    print(f"wrote {out} ({DURATION_S} frames)")


if __name__ == "__main__":
    main()
