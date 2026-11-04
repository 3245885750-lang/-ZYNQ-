# -*- coding: utf-8 -*-
"""5 s of noise only (30 dB relative to a 3000-peak clap) for false-trigger test."""
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "vec"))
os.makedirs(OUT, exist_ok=True)

FS, NCH = 48828.125, 8
N = int(5.0 * FS)
rng = np.random.default_rng(1234 + 30)
sg = 3000.0 / (10.0 ** (30.0 / 20.0))
sd = np.clip(np.round(rng.normal(0.0, sg, (NCH, N))), -32768, 32767).astype(np.int16)
path = os.path.join(OUT, "noise30_5s.hex")
with open(path, "w") as f:
    for k in range(N):
        f.write("".join("%04x" % (int(sd[ch, k]) & 0xFFFF)
                        for ch in range(7, -1, -1)) + "\n")
print("%s N=%d sigma=%.1f" % (path, N, sg))
