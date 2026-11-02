# -*- coding: utf-8 -*-
"""pwr_stats.py —— 看各段录制里 pwr（8 bin 能量）的分布，判断"有无信号"门限能不能用。

用法：python pwr_stats.py <csv> [...]
"""
import csv
import os
import sys


def stats(path):
    vals = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rd = csv.reader(fh)
        head = next(rd, [])
        ei = 4
        for i, h in enumerate(head):
            if "pwr_dec" in h:
                ei = i
                break
        for r in rd:
            if len(r) <= ei:
                continue
            try:
                v = int(r[ei], 0)
            except ValueError:
                continue
            if v > 0:
                vals.append(v)
    if not vals:
        print("%-22s 无数据" % os.path.basename(path))
        return
    vals.sort()
    n = len(vals)
    q = lambda p: vals[min(n - 1, int(p * n))]
    print("%-22s n=%5d  min=%6d  p1=%6d  p10=%6d  中位=%6d  p90=%8d  max=%8d"
          % (os.path.basename(path), n, vals[0], q(.01), q(.10), q(.5), q(.90), vals[-1]))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        stats(p)
