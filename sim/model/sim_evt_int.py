# -*- coding: utf-8 -*-
"""sim_evt_int.py —— 用与 RTL 完全相同的整数逻辑，回放 circle_v4，确认
"能量瞬态（拍手）"判据在圆周里不会误触发。

RTL 逻辑（每个 DOA 帧）：
    e_fast += pwr - (e_fast >> 2)      # 稳态 4×pwr
    e_slow += pwr - (e_slow >> 6)      # 稳态 64×pwr
    evt    = e_slow > 2048 && (e_fast << 5) > (e_slow + (e_slow << 2))   # 比 > 2.5
    命中则 evt_cnt = EVT_HOLD，否则递减
"""
import csv
import sys

EVT_HOLD = 24
path = sys.argv[1]
p = []
with open(path, newline="", encoding="utf-8-sig") as f:
    rd = csv.reader(f)
    next(rd, None)
    for r in rd:
        if len(r) >= 5 and r[1] == "M":
            try:
                p.append(int(float(r[4])))
            except ValueError:
                pass

ef = es = p[0]
cnt = 0
fires = []
for i, x in enumerate(p[1:], 1):
    ef += x - (ef >> 2)
    es += x - (es >> 6)
    evt = (es > 2048) and ((ef << 5) > (es + (es << 2)))
    if evt:
        fires.append(i)
        cnt = EVT_HOLD
    elif cnt:
        cnt -= 1

print("%s：%d 帧，判据触发 %d 次（触发帧 %d 个，占 %.2f%%）"
      % (path.split("\\")[-1], len(p), len(fires), len(fires), 100.0 * len(fires) / len(p)))
print("  触发帧号：%s" % fires)
print("  若 RTL 的 evt 窗口覆盖一次跳变帧，那次跳变就不会被限速——上面这些帧号要和跳变帧对比")
