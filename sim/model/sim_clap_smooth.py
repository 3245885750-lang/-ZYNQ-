# -*- coding: utf-8 -*-
"""sim_clap_smooth.py —— 用与 mvdr_axi_top 逐位相同的整数逻辑，回放真实 CSV，
比较「拍手档」的两种配置：

  A（现状）: SLEW_EVT_DEG=25，accept_big 不区分瞬态
             ⇒ 拍手 88° 用 3~4 帧走完（63~84 ms），观感是"跳过去"

  B（已采用）: SLEW_EVT_DEG=6（< 普通限速 8），且能量瞬态期间不进入 big_move
             ⇒ 拍手比普通转动更慢地匀速扫过去；持续声源搬移仍走 25°/帧 的大跨步

模型只包含输出端：GATE → PRED(关闭) → SLEW/CLAP/big_move。
PRED 在用拍手跳变数据回放时恒不触发（|d1| > PRED_HI），所以省略不影响结论。

用法：python sim_clap_smooth.py <csv> [<csv> ...]
"""
import csv
import sys

GATE_DEG, GATE_TOL, GATE_N, GATE_MAX = 20, 10, 3, 8
SLEW_DEG, SLEW_BIG, BIG_TRIG, CLAP_HOLD = 8, 25, 45, 32
SLEW_EVT_A = 25
SLEW_EVT_B = 6
SIG_DB_SH = 1      # 窗口内只信峰值 1/2^SIG_DB_SH 以内的帧（1 = 6 dB）


def wrap(x):
    """把角度差绕回 [-180, 180)。"""
    return (x + 180.0) % 360.0 - 180.0


def load(path):
    """读 CSV 的 (角度, 能量) 序列；取 type=='M' 的行。"""
    deg, pwr = [], []
    with open(path, newline="", encoding="utf-8-sig") as f:
        rd = csv.reader(f)
        head = next(rd, [])
        ei = 4
        for i, h in enumerate(head):
            if "pwr_dec" in h:
                ei = i
                break
        for r in rd:
            if len(r) <= ei or r[1] != "M":
                continue
            try:
                d = float(r[2])
                e = int(r[ei], 0)
            except ValueError:
                continue
            deg.append(d)
            pwr.append(e)
    return deg, pwr


def run(deg, pwr, slew_evt, big_ignores_evt, sig_en=False):
    """返回 (显示角序列, 每帧 slew_lim, 每帧 evt_cnt)。

    sig_en=True 时额外模拟 SIG_EN/SIG_DB_SH：事件窗口内只有 pwr 落在峰值
    1/2 以内的帧才能更新目标角，且窗口内不做"扣满 8 帧强制放行"。
    """
    out, lims, cnts = [], [], []
    # 回放的是"录制中间的一段"，初值取第一帧，避免 0→首值 的假跳变
    doa_tgt = deg[0]
    doa_out = deg[0]
    gate_init = True
    gate_pend = deg[0]
    gate_cnt = 0
    gate_pn = 0
    big_move = False
    evt_cnt = 0
    pwr_peak = 0
    ef = es = pwr[0]

    for i, (pw, raw) in enumerate(zip(pwr, deg)):
        pw = int(pw)
        # ---- 能量双 EMA（与 RTL 同序：先用旧值判事件，再更新）----
        evt_now = (es > 2048) and ((ef << 5) > (es + (es << 2)))
        # ---- GATE ----
        gate_ad = abs(wrap(raw - doa_tgt))
        pend_ad = abs(wrap(raw - gate_pend))
        gate_pass = (not gate_init) or gate_ad <= GATE_DEG
        pend_same = (gate_cnt != 0) and pend_ad <= GATE_TOL
        pend_ready = pend_same and ((gate_pn + 1) & 15) >= GATE_N   # RTL 4bit 回绕
        gate_force = ((gate_cnt + 1) >= GATE_MAX) and (evt_cnt == 0)
        accept = gate_pass or pend_ready or gate_force
        # ---- 能量门：窗口内只信峰值附近的帧 ----
        if sig_en:
            peak_now = max(pw, pwr_peak)
            sig_ok = (evt_cnt == 0) or (pw > (peak_now >> SIG_DB_SH))
        else:
            sig_ok = True
        accept_g = accept and sig_ok
        # ---- SLEW ----
        tgt_next = raw if accept_g else doa_tgt
        slew_d = wrap(tgt_next - doa_out)
        slew_ad = abs(slew_d)
        accept_big = accept and (slew_ad > BIG_TRIG)
        if accept_big and (evt_cnt == 0 or big_ignores_evt):
            big_move = True
        elif slew_ad <= (slew_evt if evt_cnt else (SLEW_BIG if big_move else SLEW_DEG)):
            big_move = False
        lim = slew_evt if evt_cnt else (SLEW_BIG if (big_move or accept_big) else SLEW_DEG)
        step = slew_d if slew_ad <= lim else (lim if slew_d > 0 else -lim)
        doa_out = wrap(doa_out + step)
        # ---- 寄存器更新 ----
        if accept_g:
            doa_tgt = raw
            gate_init = True
            gate_cnt = 0
            gate_pn = 0
            gate_pend = raw
        else:
            gate_cnt = min(gate_cnt + 1, GATE_MAX - 1)   # RTL 饱和在 GATE_MAX-1，不回绕
            gate_pn = ((gate_pn + 1) & 15) if pend_same else 1   # RTL 里 4bit，会回绕
            gate_pend = gate_pend if pend_same else raw
        ef += pw - (ef >> 2)
        es += pw - (es >> 6)
        if evt_now:
            evt_cnt = CLAP_HOLD
            pwr_peak = pw
        elif evt_cnt:
            evt_cnt -= 1
            pwr_peak = max(pwr_peak, pw)
        out.append(doa_out)
        lims.append(lim)
        cnts.append(evt_cnt)

    return out, lims, cnts


def steps(x):
    return [abs(wrap(x[i] - x[i - 1])) for i in range(1, len(x))]


def reach(a, b, thr=1.0):
    """从 a 第一次跨到 b 附近用了多少帧。"""
    for i, v in enumerate(a):
        if abs(wrap(v - b)) <= thr:
            return i
    return -1


def report(path):
    deg, pwr = load(path)
    if len(deg) < 3:
        print("%s：数据太少，跳过" % path)
        return
    a_out, a_lim, a_cnt = run(deg, pwr, SLEW_EVT_A, True)
    b_out, b_lim, b_cnt = run(deg, pwr, SLEW_EVT_B, False)
    c_out, c_lim, c_cnt = run(deg, pwr, SLEW_EVT_B, False, sig_en=True)

    ds, bs, cs = steps(a_out), steps(b_out), steps(c_out)
    evt_frames = sum(1 for c in a_cnt if c)
    big_frames = sum(1 for l in a_lim if l == SLEW_BIG)
    big_frames_b = sum(1 for l in b_lim if l == SLEW_BIG)

    print("=" * 68)
    print(path.split("\\")[-1], " %d 帧" % len(deg))
    print("  evt 窗口帧数 %d   大跨步帧数 A=%d  B=%d" % (evt_frames, big_frames, big_frames_b))
    for nm, out, st in (("A 旧值25°", a_out, ds), ("B 6°", b_out, bs),
                        ("C 6°+峰值门", c_out, cs)):
        st2 = sorted(st)
        print("  %s：单帧最大 %3.0f°  中位 %4.2f°  >8° 帧 %3d  >30° 帧 %2d"
              % (nm, st2[-1], st2[len(st2) // 2],
                 sum(1 for v in st if v > 8), sum(1 for v in st if v > 30)))
    # 最大一步发生在哪一帧、当时 evt_cnt
    k = max(range(len(ds)), key=lambda i: ds[i])
    print("  A 最大一步 %3.0f° 在第 %d 帧（evt_cnt=%d, lim=%d）"
          % (ds[k], k + 1, a_cnt[k], a_lim[k]))
    if k < len(bs):
        print("  B 同一处实际步进 %3.0f°" % bs[k])
    # 三者输出不一致的帧数
    for nm, other in (("A/B", b_out), ("A/C", c_out)):
        diff = sum(1 for x, y in zip(a_out, other) if abs(wrap(x - y)) > 0.5)
        print("  %s 输出不同的帧：%d / %d（%.1f%%）"
              % (nm, diff, len(a_out), 100.0 * diff / len(a_out)))
    if len(deg) > 60:
        idx = [i for i in range(len(a_out)) if abs(wrap(a_out[i] - b_out[i])) > 0.5]
        print("  不同帧号：%s" % idx[:10])
    if len(deg) <= 60:      # 短记录（拍手）直接打印逐帧对照
        print("  帧  原始   A25°   B6°   C6°+峰值门")
        for i in range(len(deg)):
            print("  %2d  %4.0f   %4.0f  %4.0f   %4.0f"
                  % (i, deg[i], a_out[i], b_out[i], c_out[i]))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        report(p)
