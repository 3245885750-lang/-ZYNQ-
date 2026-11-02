# -*- coding: utf-8 -*-
"""
analyze_doa_csv.py —— 分析 doa_view.py --csv 存下来的串口日志，定位"偶发大跳变"

用法：
    python analyze_doa_csv.py run.csv
    python analyze_doa_csv.py run.csv --thresh 30

CSV 列（doa_view.py 写的）：t_s, type, deg, pwr_hex, pwr_dec
    type = M（MVDR 精测）或 D（DAS 粗测）；deg 已归一化到 0..359

回答的问题：
    1. 跳变到底有多少次、集中在哪个时间段（UI 只显示最近 20 s，看不到全程）
    2. 每次大跳变前后发生了什么：
       · 前后两个样本的时间间隔是不是异常大（PL 停更 / 串口断流 → 显示值长期不变，一更新就是大跳）
       · 当时能量 pwr 是不是很低（声源关了 / 没声 → argmax 在噪声上乱走）
       · 是否是一帧毛刺（几帧后回到原值）还是切过去就不回来了（真简并）
    3. M 跳的时候 D 是不是同时跳（同时跳 → 有声学事件；只 M 跳 → MVDR 专有）
    4. 更新率的时变曲线，有没有掉帧/卡顿的段落
"""
import csv
import sys
import numpy as np


def mdist(a, b):
    return np.abs((np.asarray(a, float) - np.asarray(b, float) + 180.0) % 360.0 - 180.0)


def load(path):
    t, k, a, p = [], [], [], []
    with open(path, "r", newline="", encoding="utf-8-sig") as f:
        rd = csv.reader(f)
        head = next(rd, None)
        for row in rd:
            if len(row) < 5:
                continue
            try:
                t.append(float(row[0]))
                k.append(row[1].strip())
                a.append(int(float(row[2])))
                p.append(int(row[4]) if row[4].strip() else int(row[3], 16))
            except ValueError:
                continue
    return (np.array(t, float), np.array(k, str),
            np.array(a, float), np.array(p, float))


def pct(arr, p):
    return float(np.percentile(arr, p)) if len(arr) else float("nan")


def analyse(kind, t, a, p, thr):
    n = len(t)
    if n < 3:
        print("  [%s] 样本太少（%d），跳过" % (kind, n))
        return None
    dur = float(t[-1] - t[0])
    dt = np.diff(t)
    # 串口是按块到达的（一批几行同一时间戳），所以中位 dt 经常是 0，不能当基准。
    # 用均值间隔 = 总时长/(样本数-1)，它等于真实的帧周期。
    dt_exp = dur / max(n - 1, 1)
    med_dt = dt_exp
    d = mdist(a[1:], a[:-1])
    jidx = np.where(d > thr)[0] + 1          # 跳变落在"后一个样本"上

    print("  [%s] 样本 %d，时长 %.1f s，平均更新率 %.1f Hz，中位帧间隔 %.1f ms"
          % (kind, n, dur, n / dur if dur > 0 else 0.0, med_dt * 1e3))
    print("       步进：中位 %.2f，95%% %.1f，最大 %.1f，>%d 度的 %d 次（%.2f 次/分钟）"
          % (float(np.median(d)), pct(d, 95), float(d.max()),
             thr, len(jidx), 60.0 * len(jidx) / dur if dur > 0 else 0.0))

    # 帧间隔异常：PL 停更 / 串口断流的直接证据。
    # 阈值要避开"分批到达"的正常抖动——正常块间隔可达 0.13 s，所以取 10 帧周期且不低于 0.25 s。
    stall_thr = max(10.0 * dt_exp, 0.25)
    nstall = int((dt > stall_thr).sum())
    if nstall:
        worst = np.argsort(dt)[-5:][::-1]
        print("       帧间隔 > %.0f ms（中位的 5 倍以上）的 %d 处，最长的几处："
              % (stall_thr * 1e3, nstall))
        for i in worst:
            print("         t=%.2f s 间隔 %.0f ms" % (t[i + 1], dt[i] * 1e3))
    else:
        print("       帧间隔无异常（最大 %.0f ms，中位 %.0f ms）—— 没有停更"
              % (dt.max() * 1e3, med_dt * 1e3))

    if not len(jidx):
        return dict(kind=kind, njump=0, n=n, dur=dur)

    pm = float(np.median(p))
    p10 = pct(p, 10)
    print("       能量：中位 %.3g，10%% 分位 %.3g" % (pm, p10))
    nseg = min(12, max(4, int(dur / 10.0)))
    edges = np.linspace(t[0], t[-1], nseg + 1)
    segm = [float(np.median(p[(t >= edges[j]) & (t < edges[j + 1])]))
            if ((t >= edges[j]) & (t < edges[j + 1])).any() else float("nan")
            for j in range(nseg)]
    print("       能量-时间（每段 %.0f s 的中位）：%s"
          % (dur / nseg, " ".join("%.2g" % x for x in segm)))
    print("       %-8s %-9s %-7s %-7s %-8s %-9s %-9s %s"
          % ("t(s)", "前->后", "步进", "帧间隔", "能量", "能量分位", "是否毛刺", "类型"))
    ge = 0      # 低能量
    gs = 0      # 长间隔
    gl = 0      # 一帧毛刺
    rows = []
    SHOW = 20                       # 逐条明细最多打印这么多，其余只进统计
    for cnt, i in enumerate(jidx):
        a0, a1 = a[i - 1], a[i]
        pv = p[i]
        rank = 100.0 * float((p < pv).mean())
        longgap = dt[i - 1] > stall_thr
        # 毛刺判定：其后 3 个样本内回到原值 30 度以内
        back = False
        for j in range(i + 1, min(i + 4, n)):
            if mdist(a[j], a0) <= thr:
                back = True
                break
        low = pv <= p10
        ge += int(low)
        gs += int(longgap)
        gl += int(back)
        typ = ("低能量 " if low else "") + ("间隔异常 " if longgap else "") + \
              ("毛刺" if back else "切换不返回")
        if cnt < SHOW:
            print("       %-8.2f %3d->%3d  %6.1f  %6.0fms  %-8.3g %6.1f%%    %-9s %s"
                  % (t[i], int(a0), int(a1), d[i - 1], dt[i - 1] * 1e3, pv, rank,
                     "毛刺" if back else "切走", typ))
        elif cnt == SHOW:
            print("       …… 其余 %d 次不逐条列，见下面的小计" % (len(jidx) - SHOW))
        rows.append((t[i], a0, a1, longgap, low, back))

    print("       小计：低能量 %d/%d，帧间隔异常 %d/%d，一帧毛刺 %d/%d"
          % (ge, len(jidx), gs, len(jidx), gl, len(jidx)))
    n3 = int(((t[jidx] - t[0]) < 3.0).sum())
    print("       其中开头 3 s 内 %d 次（冷启动：协方差还没填满，能量还在爬）" % n3)

    # 跳变在时间上的聚集度：是不是集中在某几段
    if len(jidx) > 1:
        tj = t[jidx]
        buckets = np.histogram(tj, bins=min(10, max(2, int(dur / 10.0) + 1)),
                               range=(t[0], t[-1]))[0]
        print("       时间分布（每段约 %.0f s）：%s" % (dur / len(buckets),
                                                   " ".join(str(int(x)) for x in buckets)))
    # 稳定段：连续多少帧不出跳变
    runs = np.diff(np.concatenate(([0], jidx, [n]))) - 1
    print("       相邻两次跳变之间至少稳定 %d 帧（约 %.2f s）"
          % (int(np.median(runs)), float(np.median(runs)) * med_dt))
    return dict(kind=kind, njump=len(jidx), n=n, dur=dur,
                low=ge, stall=gs, back=gl)


def cross(tm, am, td, ad, thr):
    """M 跳的同一时刻，D 是否也跳"""
    if len(tm) < 3 or len(td) < 3:
        return
    dm = mdist(am[1:], am[:-1])
    jm = np.where(dm > thr)[0] + 1
    if not len(jm):
        return
    both = 0
    for i in jm:
        k = int(np.argmin(np.abs(td - tm[i])))
        if k == 0 or k >= len(td):
            continue
        if abs(td[k] - tm[i]) > 0.15:
            continue
        if mdist(ad[k], ad[k - 1]) > thr:
            both += 1
    print("  [M vs D] M 的 %d 次大跳变里，同时刻（±0.15 s）D 也跳的有 %d 次"
          % (len(jm), both))
    print("           （同时跳 → 有声学事件；只有 M 跳 → MVDR/记忆状态自己的问题）")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if not path:
        print(__doc__)
        return 2
    thr = 30.0
    if "--thresh" in sys.argv:
        thr = float(sys.argv[sys.argv.index("--thresh") + 1])
    t, k, a, p = load(path)
    print("文件：%s   共 %d 行" % (path, len(t)))
    if not len(t):
        return 1
    mk = np.array([x == "M" for x in k])
    dk = np.array([x == "D" for x in k])
    bk = np.array([x == "B" for x in k])
    if bk.any():
        print("  [B] 板子发来的非数据行 %d 条（\"radar_pl ready\" = 复位），时刻：%s"
              % (bk.sum(), ", ".join("%.2f" % x for x in t[bk])))
    else:
        print("  [B] 没有记录到复位 banner（要看这条，run 的时候别加 --verbose 之外的改动；"
              "老版本 doa_view 不记 B 行）")
    out = []
    if mk.any():
        out.append(analyse("M", t[mk], a[mk], p[mk], thr))
    if dk.any():
        out.append(analyse("D", t[dk], a[dk], p[dk], thr))
    if mk.any() and dk.any():
        cross(t[mk], a[mk], t[dk], a[dk], thr)
    print("\n================ 判读 ================")
    m = [o for o in out if o and o["kind"] == "M"]
    if not m:
        print("没有 M 数据。")
        return 0
    m = m[0]
    if m["njump"] == 0:
        print("全程没有 >%d 度的跳变。UI 上看到的次数可能来自别的 run 或阈值不同。" % thr)
        return 0
    print("① 跳变是集中还是均匀：看上面的时间分布行。集中在头尾 → 多半是摆麦/关源。")
    print("② 能量：低能量占 %.0f%%。接近 100%% → 跳变发生在没声时，是\"没源时的 argmax 游走\"，"
          % (100.0 * m["low"] / m["njump"]))
    print("   不是跟踪失败；解法是低能量时锁住上次角度（PC 端或 PL 端都行）。")
    print("③ 帧间隔：异常占 %.0f%%。明显 >0 → 数据通路停了，显示的是旧值，"
          % (100.0 * m["stall"] / m["njump"]))
    print("   一更新就看起来像跳变；要查 tready 背压 / 串口。")
    print("④ 毛刺：%.0f%%。高 → 单帧的协方差/求逆出问题（定点溢出、快拍不完整），"
          % (100.0 * m["back"] / m["njump"]))
    print("   低 → 真简并（两个方向谱峰高度接近，argmax 换峰）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
