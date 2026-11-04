# -*- coding: utf-8 -*-
"""Arbitrary-azimuth vectors: 37 deg and 217 deg, 50 dB, reflections on."""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sim_tdoa_realistic as m

FS, NCH = m.FS, m.NCH
ALPHA, K = m.ALPHA, m.K_SAMP
PRE_S, POST_S = 0.56, 0.12
OUT = os.path.normpath(os.path.join(HERE, "..", "vec"))
os.makedirs(OUT, exist_ok=True)


def frac_delay_fft(x, d, pad=2048):
    xp = np.concatenate([np.zeros(pad), x, np.zeros(pad)])
    n = len(xp)
    f = np.fft.rfftfreq(n)
    y = np.fft.irfft(np.fft.rfft(xp) * np.exp(-2j * np.pi * f * d), n)
    return y[pad:pad + len(x)]


def build(theta_deg, snr_db, seed, amp=3000.0):
    rng = np.random.default_rng(seed * 1000 + int(theta_deg))
    pre = int(PRE_S * FS)
    n = pre + int(POST_S * FS)
    src = m.make_clap(FS, seed=seed)
    sig = np.zeros(n)
    sig[pre:pre + len(src)] = amp * src
    dd = K * np.cos(np.radians(theta_deg) - ALPHA - np.pi)
    d1 = K * np.cos(np.radians(theta_deg + 55.0) - ALPHA - np.pi) + 1.5e-3 * FS
    d2 = K * np.cos(np.radians(theta_deg - 100.0) - ALPHA - np.pi) + 4.0e-3 * FS
    gain = 1.0 + rng.normal(0.0, 0.06, NCH)
    skew = rng.normal(0.0, 0.05, NCH)
    sg = amp / (10.0 ** (snr_db / 20.0))
    raw = np.zeros((NCH, n))
    for i in range(NCH):
        x = frac_delay_fft(sig, dd[i] + skew[i])
        x = x + 0.6 * frac_delay_fft(sig, d1[i] + skew[i])
        x = x + 0.3 * frac_delay_fft(sig, d2[i] + skew[i])
        raw[i] = gain[i] * x + rng.normal(0.0, sg, n)
    return np.clip(np.round(raw), -32768, 32767).astype(np.int16)


for ang in (37, 217):
    sd = build(ang, 50.0, 0)
    path = os.path.join(OUT, "vec_arb_%03d.hex" % ang)
    with open(path, "w") as f:
        for k in range(sd.shape[1]):
            f.write("".join("%04x" % (int(sd[ch, k]) & 0xFFFF)
                            for ch in range(7, -1, -1)) + "\n")
    print("%s  N=%d" % (path, sd.shape[1]))
