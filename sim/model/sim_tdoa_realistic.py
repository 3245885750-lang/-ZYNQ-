# -*- coding: utf-8 -*-
"""sim_tdoa_realistic.py —— transient_tdoa.v 在"更接近真实拍手"条件下的误差评估

与 sim_tdoa_onset.py 的区别（那个只验证公式，条件过于理想）：
  1) 拍手不是单点理想阶跃：用 200Hz~16kHz 限带噪声 + 快起音指数衰减 +
     1.2ms 后第二次撞击，模拟真实拍手的多脉冲/宽带结构；
  2) 传播用窗函数 sinc 分数时延（不是线性插值），包含一条 1.5ms、0.6 倍
     和一条 4ms、0.3 倍的一阶反射（反射方向与直达不同）；
  3) 每路独立高斯噪声，按"拍手峰值 / 噪声 sigma"定义 SNR；
  4) 每路有 +-1dB 幅度失配和 +-0.05 样本的静态时延失配（麦克风/PCB 差异）；
  5) 触发/加窗/峰值/阈值/首次穿越/插值/拟合全部按 RTL 的整数逻辑复刻。

同时给出一个"更好的估计器"的参考结果（互相关 + 抛物线插值），用来区分
  "算法原理的上限" 和 "当前首次穿越实现的损失"。

输出全部英文，避免 GBK 控制台乱码。
"""

import math
import numpy as np
from scipy import signal

NCH = 8
FS = 48828.125
C = 343.0
R = 0.05
K_SAMP = FS * R / C                 # 7.118 samples
PRE = 32
POST = 96
WIN = PRE + POST
PMAX_SH = 3
MIN_CH = 5
TH_COH2 = 0.6

ALPHA = np.arange(NCH) * 2.0 * np.pi / NCH


def make_clap(fs, dur=0.03, seed=0):
    """Broadband clap: filtered noise burst, fast attack, double impact."""
    rng = np.random.default_rng(seed)
    n = int(dur * fs)
    t = np.arange(n) / fs
    sos = signal.butter(4, [200.0, 16000.0], btype="bandpass", fs=fs, output="sos")
    x = signal.sosfilt(sos, rng.standard_normal(n))
    # hand-cavity low frequency component
    sos_lo = signal.butter(2, [120.0, 900.0], btype="bandpass", fs=fs, output="sos")
    xlo = signal.sosfilt(sos_lo, rng.standard_normal(n))
    env1 = (1.0 - np.exp(-t / 0.00025)) * np.exp(-t / 0.0035)
    env2 = (1.0 - np.exp(-t / 0.00025)) * np.exp(-t / 0.0060)
    x = x * env1 + 0.45 * xlo * env2
    # second impact 1.2ms later, 0.6 amplitude
    d2 = int(round(1.2e-3 * fs))
    if d2 < n:
        x[d2:] += 0.6 * x[: n - d2] * 0.8
    x /= np.max(np.abs(x))
    return x


def frac_delay_sinc(x, d, taps=63):
    """Delay x by d samples (positive = later), windowed-sinc FIR."""
    m = np.arange(-(taps // 2), taps // 2 + 1)
    h = np.sinc(m - d) * np.hamming(taps)
    h /= np.sum(h)
    return signal.fftconvolve(x, h, mode="same")


def adiff_int16(sd):
    """RTL: adiff[g] = |sample[n] - sample[n-1]|, 16-bit unsigned."""
    d = np.diff(sd.astype(np.int64), axis=1, prepend=sd[:, :1].astype(np.int64))
    return np.minimum(np.abs(d), 65535).astype(np.int64)


def rtl_trigger(env, abs_min=64, th_sh=2):
    """Exact integer fast/slow envelope trigger. Returns trigger index or -1."""
    e_f = 0
    e_s = 0
    for n in range(len(env)):
        e_f = e_f - (e_f >> 2) + int(env[n])
        e_s = e_s - (e_s >> 12) + int(env[n])
        if (e_s >> 12) > abs_min and (e_f >> 2) > ((e_s >> 12) << th_sh):
            return n
    return -1


def rtl_onset_estimate(ad, trig):
    """Exact RTL angle path on 8xN adiff matrix (ad[ch, n])."""
    st = trig - PRE
    if st < 0 or st + WIN > ad.shape[1]:
        return None, None, None
    w = ad[:, st: st + WIN]
    peak = np.max(w, axis=1)
    th = peak >> 2
    pmax = int(np.max(peak))
    t_q6 = np.full(NCH, -1, dtype=np.int64)
    ha_p = np.zeros(NCH, dtype=np.int64)
    ha_c = np.zeros(NCH, dtype=np.int64)
    hit = np.zeros(NCH, dtype=bool)
    for ch in range(NCH):
        if th[ch] == 0:
            continue
        # k is window index; RTL skips k=0 and uses a[k-1]
        for k in range(1, WIN):
            if w[ch, k] >= th[ch]:
                hit[ch] = True
                ap, ac = int(w[ch, k - 1]), int(w[ch, k])
                if ac > ap:
                    frac6 = int(math.floor((th[ch] - ap) * 64.0 / (ac - ap)))
                    frac6 = min(frac6, 63)       # 6-bit quotient; 64 wraps in RTL
                else:
                    frac6 = 0
                t_q6[ch] = k * 64 + frac6
                ha_p[ch], ha_c[ch] = ap, ac
                break
    wsel = hit & (peak >= (pmax >> PMAX_SH)) & (ha_c > ha_p)
    sw = int(np.sum(wsel))
    if sw == 0:
        return None, None, None
    sumwt = int(np.sum(t_q6[wsel]))
    tbar = (sumwt * int(round(256.0 / sw))) >> 8
    d = np.zeros(NCH, dtype=np.int64)
    d[wsel] = t_q6[wsel] - tbar
    A = int(d[0] - d[4] + ((181 * (d[1] + d[7] - d[3] - d[5])) >> 8))
    B = int(d[2] - d[6] + ((181 * (d[1] + d[3] - d[5] - d[7])) >> 8))
    err_deg = math.degrees(math.atan2(B, A))
    sd2 = int(np.sum(d[wsel] ** 2))
    coh2 = 2.0 * (A * A + B * B) / (sw * sd2) if sd2 else 0.0
    return err_deg, sw, coh2


def xcorr_refine(raw, trig, k_samp=K_SAMP):
    """Reference 'better estimator': GCC (plain, first-difference aligned)
    between the strongest channel and the others, parabolic interpolation.
    Returns angle in degrees."""
    st = max(0, trig - 8)
    n = 80
    seg = raw[:, st: st + n]
    ref = int(np.argmax(np.max(np.abs(np.diff(seg, axis=1)), axis=1)))
    lags = np.arange(-12, 13)
    rel = np.zeros(NCH)
    for ch in range(NCH):
        if ch == ref:
            continue
        best, best_lag = -1e18, 0
        for L in lags:
            a = seg[ref, 4:]
            b = seg[ch, 4 + L:]
            m = min(len(a), len(b))
            c = float(np.dot(a[:m], b[:m]))
            if c > best:
                best, best_lag = c, L
        # parabolic interpolation around best lag
        def cc(L):
            a = seg[ref, 4:]
            b = seg[ch, 4 + L:]
            m = min(len(a), len(b))
            return float(np.dot(a[:m], b[:m]))
        if -11 <= best_lag <= 11:
            cm, c0, cp = cc(best_lag - 1), cc(best_lag), cc(best_lag + 1)
            den = cm - 2 * c0 + cp
            frac = 0.5 * (cm - cp) / den if den != 0 else 0.0
            frac = max(-1.0, min(1.0, frac))
        else:
            frac = 0.0
        rel[ch] = best_lag + frac
    rel -= np.mean(rel)
    A = float(np.sum(rel * np.cos(ALPHA)))
    B = float(np.sum(rel * np.sin(ALPHA)))
    return math.degrees(math.atan2(B, A))


def simulate(theta_deg, snr_db, seed, refl=True):
    rng = np.random.default_rng(seed * 1000 + int(theta_deg))
    pre = int(0.30 * FS)                  # 0.3 s pre-roll for envelope convergence
    n = pre + int(0.05 * FS)
    src = make_clap(FS, seed=seed)
    sig = np.zeros(n)
    sig[pre: pre + len(src)] = 3000.0 * src

    th = math.radians(theta_deg)
    thr1 = math.radians(theta_deg + 55.0)
    thr2 = math.radians(theta_deg - 100.0)
    # direct delays
    dd = K_SAMP * np.cos(th - ALPHA)
    if refl:
        d1 = K_SAMP * np.cos(thr1 - ALPHA) + 1.5e-3 * FS
        d2 = K_SAMP * np.cos(thr2 - ALPHA) + 4.0e-3 * FS
    gain = 1.0 + rng.normal(0.0, 0.06, NCH)               # +-0.5 dB-ish
    skew = rng.normal(0.0, 0.05, NCH)                     # +-0.05 sample static
    noise_sigma = 3000.0 / (10.0 ** (snr_db / 20.0))

    raw = np.zeros((NCH, n))
    for i in range(NCH):
        x = frac_delay_sinc(sig, dd[i] + skew[i])
        if refl:
            x = x + 0.6 * frac_delay_sinc(sig, d1[i] + skew[i])
            x = x + 0.3 * frac_delay_sinc(sig, d2[i] + skew[i])
        x = gain[i] * x + rng.normal(0.0, noise_sigma, n)
        raw[i] = x

    sd = np.clip(np.round(raw), -32768, 32767).astype(np.int16)   # 16-bit PCM
    ad = adiff_int16(sd)
    env = np.max(ad, axis=0)
    trig = rtl_trigger(env)
    if trig < 0:
        return None
    raw_ang = rtl_onset_estimate(ad, trig)
    ref_ang = xcorr_refine(raw, trig)
    return raw_ang[0], raw_ang[2], sw_of(raw_ang), ref_ang


def sw_of(t):
    return t[1] if t is not None else None


def angdiff(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


if __name__ == "__main__":
    np.seterr(all="ignore")
    print("fs=%.1f  k=%.3f samples  WIN=%d (%.2f ms)"
          % (FS, K_SAMP, WIN, WIN / FS * 1000))
    print("clap: 200-16k band, 3.5ms decay, second impact at 1.2ms")
    print("mic: +-0.5dB gain, +-0.05 sample static skew")
    print("room: reflections 1.5ms x0.6 and 4ms x0.3 from other directions\n")

    angles = list(range(0, 360, 15))
    for refl in (False, True):
        print("=" * 76)
        print("reflections: %s" % ("on" if refl else "off"))
        for snr in (40, 30, 20):
            raw_e, ref_e, rej, sws = [], [], 0, []
            for th in angles:
                for seed in range(8):
                    r = simulate(th, snr, seed, refl)
                    if r is None:
                        rej += 1
                        continue
                    a_raw, coh2, sw, a_ref = r
                    if a_raw is None:
                        rej += 1
                        continue
                    raw_e.append(angdiff(a_raw, th))
                    ref_e.append(angdiff(a_ref, th))
                    sws.append(sw)
            raw_e = np.array(raw_e)
            ref_e = np.array(ref_e)
            print(" SNR(peak) %2d dB | first-crossing: mean %5.2f  median %5.2f  "
                  "p90 %5.2f  max %6.2f  reject %d | xcorr: mean %5.2f  p90 %5.2f"
                  % (snr, raw_e.mean(), np.median(raw_e), np.percentile(raw_e, 90),
                     raw_e.max(), rej, ref_e.mean(), np.percentile(ref_e, 90)))
        print()
