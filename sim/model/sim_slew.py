# -*- coding: utf-8 -*-
"""sim_slew.py —— 输出限速（斜率限制）的效果评估

规则：显示角每帧最多向"已接受角"移动 SLEW 度。
      |真实转角| ≤ 2°/帧（≈95°/s），SLEW=8°/帧（380°/s），正常帧一个比特不动；
      剩下的大步进变成几帧的平滑过渡，不再是跳变。

用法：python sim_slew.py <csv> [SLEW=8]
"""
import sys

from sim_gate import load, wrap

path = sys.argv[1]
slew = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
t, a = load(path)


def slewlim(a, s):
    out = [a[0]]
    for x in a[1:]:
        d = wrap(x - out[-1])
        if abs(d) <= s:
            out.append(x)
        else:
            out.append((out[-1] + s if d > 0 else out[-1] - s) % 360)
    return out


def steps(x):
    return [abs(wrap(x[i] - x[i - 1])) for i in range(1, len(x))]


o = slewlim(a, slew)
d0, d1 = steps(a), steps(o)


def stat(d):
    d = sorted(d)
    return "max %5.0f  p99 %4.0f  中位 %4.2f  >30° %3d" % (
        d[-1], d[int(0.99 * len(d))], d[len(d) // 2], sum(1 for v in d if v > 30))


print("%-18s  原始  %s" % (path.split("\\")[-1], stat(d0)))
print("%-18s  限速%.0f° %s" % ("", slew, stat(d1)))
print("    与原序列逐位相同 %d/%d（%.1f%%）；被限速的帧 %d"
      % (sum(1 for x, y in zip(a, o) if x == round(y) or abs(wrap(x - y)) < 0.5),
         len(a), 100.0 * sum(1 for x, y in zip(a, o)
                             if x == round(y) or abs(wrap(x - y)) < 0.5) / len(a),
         sum(1 for i in range(1, len(o)) if abs(wrap(o[i] - o[i - 1]) - 0) > 1e-9
             and abs(wrap(a[i] - o[i])) > 0.5)))
