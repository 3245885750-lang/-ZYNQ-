# -*- coding: utf-8 -*-
"""sim_big.py —— 回放"GATE + 拍手窗口 + 大跨步限速"整条输出链（A 档验证）

与 RTL 逐条对应的规则（mvdr_axi_top.v 的 GATE / CLAP / SLEW 段）：

  GATE   d = wrap(新角 − doa_tgt)
         |d| ≤ GATE(20)                       → 立即接受
         候选连续 N(3) 帧互相在 TOL(10) 内    → 接受
         扣住超过 MAX(8) 帧                   → 强制接受

  CLAP   e_fast += pwr − e_fast>>2 ；e_slow += pwr − e_slow>>6
         事件 = e_slow > 2048 且 (e_fast<<5) > 5·e_slow
         命中 ⇒ evt_cnt = HOLD(24) 帧

  SLEW   每帧最多向目标转 lim 度：
           evt_cnt ≠ 0                       → SLEW_EVT(25)
           big_move 或 本次接受跨 > TRIG(45) → SLEW_BIG(25)
           其它                              → SLEW(8)
         big_move 一直保持到"本帧能一步走到目标"为止

用法：
  python sim_big.py <csv> [...]        回放并统计
  python sim_big.py --jump             合成一次 180° 换向，对比 A 档开/关
"""
import sys

from sim_gate import load, wrap

GATE, TOL, NHOLD, MAXHOLD = 20.0, 10.0, 3, 8
SLEW, SLEW_EVT, SLEW_BIG, TRIG = 8, 6, 25, 45
CLAP_HOLD = 32


def run(t, a, e, use_big=True, use_clap=True):
    """返回 (输出角序列, 每帧限速值, 每帧是否 big_move, 触发重建的帧号)"""
    n = len(a)
    out = [a[0]]
    tgt = a[0]
    init = False
    pend, cnt, pn = None, 0, 0
    evt = 0
    big = False
    ef = es = 0
    lims, bigs, flushes = [], [], []

    for i in range(1, n):
        x = a[i]
        # --- 能量双 EMA / 拍手窗口 ---
        p = e[i]
        ef += p - (ef >> 2)
        es += p - (es >> 6)
        if use_clap and es > 2048 and (ef << 5) > 5 * es:
            evt = CLAP_HOLD
        elif evt > 0:
            evt -= 1

        # --- GATE ---
        d = wrap(x - tgt)
        gp = (not init) or abs(d) <= GATE
        psame = cnt != 0 and pend is not None and abs(wrap(x - pend)) <= TOL
        pready = psame and (pn + 1) >= NHOLD
        pforce = (cnt + 1) >= MAXHOLD
        acc = gp or pready or pforce

        # 能量瞬态期间不进 A 档（与 RTL 的 evt_cnt==0 条件一致）
        accept_big = acc and abs(wrap((x if acc else tgt) - out[-1])) > TRIG and evt == 0
        if use_big and accept_big:
            big = True

        if acc:
            old = tgt
            tgt = x
            init = True
            cnt = pn = 0
            pend = x
            if abs(wrap(tgt - old)) > 30:
                flushes.append(i)
        else:
            cnt += 1
            pn = pn + 1 if psame else 1
            pend = pend if psame else x

        # --- SLEW ---
        lim = SLEW_EVT if evt != 0 else (SLEW_BIG if (use_big and (big or accept_big)) else SLEW)
        d = wrap(tgt - out[-1])
        if abs(d) <= lim:
            out.append(tgt)
            if use_big:
                big = False
        else:
            out.append(wrap(out[-1] + (lim if d > 0 else -lim)))
        lims.append(lim)
        bigs.append(big)

    out[0] = a[0]
    return out, lims, bigs, flushes


def stat(x):
    d = sorted(abs(wrap(x[i] - x[i - 1])) for i in range(1, len(x)))
    return "max %3.0f  p99 %3.0f  中位 %4.2f  >30° %3d" % (
        d[-1], d[int(0.99 * len(d))], d[len(d) // 2], sum(1 for v in d if v > 30))


def jump_test():
    print("合成工况：声源 0° 静止 → 第 30 帧瞬移到 180°（能量恒定，没有拍手瞬态）")
    print("       A 档关（全用 8°/帧） vs  A 档开（>45° 用 25°/帧）\n")
    n = 80
    a = [0] * 30 + [180] * (n - 30)
    e = [4000] * n
    o0, l0, b0, _ = run(None, a, e, use_big=False, use_clap=False)
    o1, l1, b1, _ = run(None, a, e, use_big=True, use_clap=False)

    def frames_to_reach(o, target, start):
        for i in range(start, len(o)):
            if abs(wrap(o[i] - target)) <= 0.5:
                return i - start
        return None

    f0 = frames_to_reach(o0, 180, 30)
    f1 = frames_to_reach(o1, 180, 30)
    print("  A 档关：%2d 帧走完 180°（%5.1f ms），单帧最大 %2.0f°，>30° 帧 %d"
          % (f0, f0 * 21.0, max(l0[29:]), sum(1 for v in (abs(wrap(o0[i] - o0[i - 1]))
                                                          for i in range(1, len(o0))) if v > 30)))
    print("  A 档开：%2d 帧走完 180°（%5.1f ms），单帧最大 %2.0f°，>30° 帧 %d"
          % (f1, f1 * 21.0, max(l1[29:]), sum(1 for v in (abs(wrap(o1[i] - o1[i - 1]))
                                                          for i in range(1, len(o1))) if v > 30)))
    print("\n  A 档开的那一段逐帧：", " ".join("%.0f" % v for v in o1[28:30 + max(f1, 1) + 2]))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--jump":
        jump_test()
        return
    for path in [p for p in sys.argv[1:] if not p.startswith("--")]:
        t, a = load(path)
        # CSV 里没有逐帧能量（E 列是 16 进制），这里用恒定能量 ⇒ 拍手窗口永不触发，
        # 相当于只验证 GATE + 限速 + 大跨步（拍手那一路已由 sim_evt_int.py 单独验过）
        e = [4000] * len(a)
        o0, _, _, _ = run(t, a, e, use_big=False)
        o1, l1, b1, fl = run(t, a, e, use_big=True)
        name = path.split("\\")[-1]
        print("%-22s 输入 %s" % (name, stat(a)))
        print("%-22s A关  %s" % ("", stat(o0)))
        print("%-22s A开  %s   大跨步 %d 帧 / 重建 %d 次  与原序列相同 %d/%d"
              % ("", stat(o1), sum(1 for v in b1 if v),
                 len(fl), sum(1 for x, y in zip(a, o1) if abs(wrap(x - y)) < 0.5), len(a)))
        if "--detail" in sys.argv:
            # 记录里同一批缓冲行共用一个时间戳，所以"距上一帧"要跳过同批的行再看
            def gap_before(i):
                j = i - 1
                while j > 0 and t[j] == t[i]:
                    j -= 1
                return t[i] - t[j]
            st = [i for i in range(1, len(b1)) if b1[i] and not b1[i - 1]]
            print("    大跨步起点（帧号@离它最近的记录空档）：",
                  " ".join("%d@%.2fs" % (i, gap_before(i)) for i in st))
        print()


if __name__ == "__main__":
    main()
