# -*- coding: utf-8 -*-
"""sim_clr_check.py —— 协方差重建（flush → 对角加载 λ·I）的数值验证

要回答两件事：
  1) 上三角打包里"对角项"的地址对不对（RTL 里 is_diag_p 用的 0,8,15,21,26,30,33,35）
  2) 重建后 R = λ·I + Σ(新快拍) 能不能给出**方向正确**的 MVDR 峰，
     以及 λ 取多大（CLR_LD）合适：太小 → R 秩不足、逆矩阵炸；太大 → 峰被压平

模型与 gen_steer_multibin.py 完全一致：
  a_i(θ) = exp(-j·kR·cos(θ−α_i))，α_i = 2πi/8，R=0.05m，c=343，8 个 bin 同上；
  MVDR 谱 s(θ) = a^H R⁻¹ a（RTL 取 argmin）。
"""
import numpy as np

NCH, NANG = 8, 361
c, R, FS = 343.0, 0.05, 50000000.0 / 16.0 / 64.0
BINS = [5, 10, 15, 20, 25, 31, 37, 43]
TH0 = 137.0            # 声源方向（验证用）
import sys
SNR_DB = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0


def steer(kR, th_deg):
    a = []
    for ch in range(NCH):
        alpha = ch * 2 * np.pi / NCH
        ph = kR * np.cos(np.deg2rad(th_deg) - alpha)
        a.append(np.exp(-1j * ph))
    return np.array(a)


def steering_table():
    tab = []
    for b in BINS:
        kR = 2 * np.pi * (b * FS / 512.0) * R / c
        tab.append([steer(kR, ang - 180) for ang in range(NANG)])
    return tab


TAB = steering_table()


def snapshots(kRn, n):
    rng = np.random.default_rng(12345)
    out = []
    for b, kR in enumerate(kRn):
        s = steer(kR, TH0)
        sig = np.sqrt(10 ** (SNR_DB / 10))
        xs = []
        for _ in range(n):
            noise = (rng.standard_normal(NCH) + 1j * rng.standard_normal(NCH)) / np.sqrt(2)
            xs.append(sig * s + noise)
        out.append(xs)
    return out


def build(xs, lam, n_use=None):
    """R_b = λI + Σ_{k<n} x x^H（float，对应 EMA 起始段 acc≈λ+Σm）"""
    Rs = []
    for xb in xs:
        Rb = lam * np.eye(NCH, dtype=complex)
        for x in (xb if n_use is None else xb[:n_use]):
            Rb += np.outer(x, x.conj())
        Rs.append(Rb)
    return Rs


def mvdr_peak(Rs):
    """宽带非相干融合：Σ_bins a^H R⁻¹ a，取 argmin（与 mvdr_sweep 一致）"""
    tot = np.zeros(NANG)
    for b, Rb in enumerate(Rs):
        try:
            Ri = np.linalg.inv(Rb)
        except np.linalg.LinAlgError:
            return None, None
        for ang in range(NANG):
            a = TAB[b][ang]
            v = (a.conj() @ Ri @ a).real
            tot[ang] += v
    k = int(np.argmin(tot))
    contrast = 10 * np.log10(np.median(tot) / max(tot[k], 1e-30))
    return k - 180, contrast


def conds(Rs):
    return max(np.linalg.cond(Rb) for Rb in Rs)


print("=== 1. 上三角对角项地址（RTL is_diag_p 用的表）===")
p = 0
pack = []
for i in range(NCH):
    for j in range(i, NCH):
        if i == j:
            pack.append(p)
        p += 1
print("  对角项在 36 项里的序号：", pack)
print("  期望                     ： [0, 8, 15, 21, 26, 30, 33, 35]")
print("  一致：", pack == [0, 8, 15, 21, 26, 30, 33, 35])

kRn = [2 * np.pi * (b * FS / 512.0) * R / c for b in BINS]

for n in (2, 4, 8):
    xs = snapshots(kRn, n)
    # λ 只由**一个快拍**的迹决定（RTL 里 clr_ld 在 flush 那一拍取样一次，pwr_acc 是单快拍量级）
    tr = sum(float(np.sum(np.abs(xb[0]) ** 2)) for xb in xs)
    lam1 = tr / 8.0        # = 单快拍的平均每 bin 迹，对应 CLR_LD=3（λ = trace/8）
    print("\n=== 快照数 n=%d（重建后第 %d 帧的处境），λ 基准 = trace/8 = %.1f ===" % (n, n, lam1))
    print("  %-14s %-12s %-14s %s" % ("加载 λ", "R 条件数", "峰方向", "对比度"))
    peak, contrast = mvdr_peak(build(xs, 0.0, None))
    print("  %-14s %-12.3g %-14s %s" % ("0（=清空，秩%d）" % n,
                                        conds(build(xs, 1e-12, None)),
                                        "无解/乱" if peak is None else str(peak),
                                        "—"))
    for ld in (1, 2, 3, 4, 5):
        lam = lam1 * (2 ** (3 - ld))       # ld 对应 RTL 的 CLR_LD：λ = trace >> ld
        Rs = build(xs, lam, None)
        pk, ct = mvdr_peak(Rs)
        print("  %-14s %-12.3g %-14s %+.1f dB"
              % ("trace>>%d = %.1f" % (ld, lam), conds(Rs),
                 "无解" if pk is None else "%d°（真值 %d°）" % (pk, TH0), ct))

print("\n=== 2. 稳态参考（n=128，无加载）===")
xs = snapshots(kRn, 128)
pk, ct = mvdr_peak(build(xs, 0.0, None))
print("  条件数 %.3g   峰 %s°   对比度 %+.1f dB" % (conds(build(xs, 0.0, None)), pk, ct))
