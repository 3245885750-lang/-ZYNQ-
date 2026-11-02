# -*- coding: utf-8 -*-
"""plot_circle.py —— 环绕 run 的三联图：角度-时间 / 步进-时间 / 能量-时间"""
import csv
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PATH = sys.argv[1] if len(sys.argv) > 1 else "circle_fast.csv"
OUT = sys.argv[2] if len(sys.argv) > 2 else "circle.png"

t, a, p = [], [], []
with open(PATH, newline="", encoding="utf-8-sig") as f:
    rd = csv.reader(f)
    next(rd, None)
    for row in rd:
        if len(row) < 5 or row[1] != "M":
            continue
        try:
            t.append(float(row[0]))
            a.append(int(float(row[2])))
            p.append(int(row[4]) if row[4].strip() else 0)
        except ValueError:
            pass
t = np.array(t); a = np.array(a, float); p = np.array(p, float)
d = np.abs((a[1:] - a[:-1] + 180.0) % 360.0 - 180.0)

# 断线：只在大跳变处断开，模 360 的环绕（359->0 差 1 度）不断
aa = a.copy()
aa[1:][d > 90] = np.nan

fig, ax = plt.subplots(3, 1, figsize=(15, 9), sharex=True)
ax[0].plot(t, aa, ".-", ms=3, lw=0.7, color="#c0392b")
ax[0].set_ylabel(u"角度 / deg")
ax[0].set_ylim(-5, 365)
ax[0].grid(alpha=.3)
ax[0].set_title(PATH)

ax[1].plot(t[1:], d, "-", lw=0.8, color="#2c3e50")
ax[1].plot(t[1:], np.minimum(d, 30), "-", lw=0.8, color="#2980b9", alpha=.6)
ax[1].set_ylabel(u"步进 / deg")
ax[1].grid(alpha=.3)

ax[2].plot(t, p, "-", lw=0.8, color="#27ae60")
ax[2].set_ylabel(u"能量")
ax[2].set_xlabel(u"时间 / s")
ax[2].grid(alpha=.3)
ax[2].set_xlim(0, t[-1])
for x in ax:
    x.axhline(0, lw=0)
fig.tight_layout()
fig.savefig(OUT, dpi=110)
print(OUT)
