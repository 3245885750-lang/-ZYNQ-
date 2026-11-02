# -*- coding: utf-8 -*-
"""sim_gate.py —— 输出端单帧离群剔除（保持/确认）的离线验证

规则（与将写进 RTL 的一致）：
  d = wrap(新角 − 上次接受的角)
  |d| ≤ GATE              → 立刻接受（真运动每帧最多 2~4°，永远走这条）
  否则若候选连续 2 帧落在 PEND_TOL 内 → 接受（真跳变 1 帧后就跟上）
  候选连续超过 MAXHOLD 帧       → 强制接受（防卡死）
  其余情况                      → 保持上一帧输出

GATE=20°、PEND_TOL=10°、MAXHOLD=8、PEND_N=3。真运动 47.7Hz 下 20°/帧 = 954°/s，
人手和转盘都够不着，所以正常帧的输出与未加门时【逐位相同】。

用法：python sim_gate.py [csv ...]
"""
import csv
import sys

GATE, PEND_TOL, MAXHOLD, PEND_N = 20, 10, 8, 3


def wrap(x):
    return (x + 180.0) % 360.0 - 180.0


def gate(a, g=GATE, tol=PEND_TOL, mx=MAXHOLD, n=PEND_N):
    """n = 候选要连续几帧自洽才接受（n=2 即"确认一次"）"""
    out = [a[0]]
    pend, cnt, pn = None, 0, 0
    for x in a[1:]:
        d = wrap(x - out[-1])
        if abs(d) <= g:
            out.append(x); pend, cnt, pn = None, 0, 0
            continue
        if pend is not None and abs(wrap(x - pend)) <= tol:
            pn += 1
        else:
            pend, pn = x, 1
        cnt += 1
        if pn >= n or cnt >= mx:
            out.append(x); pend, cnt, pn = None, 0, 0
        else:
            out.append(out[-1])
    return out


def load(path):
    t, a = [], []
    with open(path, newline="", encoding="utf-8-sig") as f:
        rd = csv.reader(f)
        next(rd, None)
        for row in rd:
            if len(row) < 5 or row[1] != "M":
                continue
            try:
                t.append(float(row[0])); a.append(int(float(row[2])))
            except ValueError:
                continue
    return t, a


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--sweep":
        t, a = load(sys.argv[2])
        dur = t[-1] - t[0]
        j0 = sum(1 for i in range(1, len(a)) if abs(wrap(a[i] - a[i - 1])) > 30)
        print("%s：原始 %d 次（%.1f 次/分）" % (sys.argv[2].split("\\")[-1], j0, 60.0 * j0 / dur))
        print("  %-8s %-8s %-8s %-8s %-12s %s"
              % ("GATE", "PEND_TOL", "MAXHOLD", "PEND_N", "跳变", "保持帧"))
        for g in (20, 30):
            for tol in (5, 10):
                for n in (2, 3, 4):
                    mx = 8
                    o = gate(a, g, tol, mx, n)
                    j = sum(1 for i in range(1, len(o)) if abs(wrap(o[i] - o[i - 1])) > 30)
                    h = sum(1 for i in range(1, len(o)) if o[i] == o[i - 1] and a[i] != a[i - 1])
                    print("  %-8d %-8d %-8d %-8d %-12s %d"
                          % (g, tol, mx, n, "%d 次（%.1f/分）" % (j, 60.0 * j / dur), h))
        return

    for path in sys.argv[1:]:
        t, a = load(path)
        g = gate(a)
        dur = t[-1] - t[0]
        j0 = sum(1 for i in range(1, len(a)) if abs(wrap(a[i] - a[i - 1])) > 30)
        j1 = sum(1 for i in range(1, len(g)) if abs(wrap(g[i] - g[i - 1])) > 30)
        held = sum(1 for i in range(1, len(g)) if g[i] == g[i - 1] and a[i] != a[i - 1])
        same = sum(1 for i in range(len(g)) if g[i] == a[i])
        print("%-16s %5.1f s  跳变 %4d → %4d 次（%.1f → %.1f 次/分）；"
              "保持帧 %d（%.1f%%）；与原始逐位相同 %d/%d"
              % (path.split("\\")[-1], dur, j0, j1,
                 60.0 * j0 / dur, 60.0 * j1 / dur,
                 held, 100.0 * held / len(g), same, len(g)))


if __name__ == "__main__":
    main()
