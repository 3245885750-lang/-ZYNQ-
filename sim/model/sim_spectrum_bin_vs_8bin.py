# -*- coding: utf-8 -*-
"""sim_spectrum_bin_vs_8bin.py —— 生成文档用图：八个频点与融合后的 MVDR 空间谱

几何/导向矢量与 RTL 完全一致（同 gen_steer_multibin.py）：
  a_i(θ) = exp(-j·kR·cos(θ − α_i))，α_i = 2πi/8，R = 0.05 m，c = 343
  显示角 = 模型角 + 180°（与 steer_*.mem 的 (ang-180) 约定一致）
  MVDR 谱 P(θ) = 1 / (aᴴ R⁻¹ a)        （RTL 取 aᴴ R⁻¹ a 的 argmin，等价）
  融合   P(θ) = Σ_b P_b(θ)             （八频点非相干相加）

左图：八条单频曲线（细线）+ 融合曲线（粗线）——看各频点的主瓣宽度与旁瓣结构
右图：逐帧估计的时间序列——低信噪比下各频点的单帧估计各自独立抖动、落点分散，
      八频点融合后抖动显著减小

输出：fig_spatial_spectrum_bin_vs_8bin.png
用法：python sim_spectrum_bin_vs_8bin.py
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

NCH, NANG = 8, 361
C, R, FS = 343.0, 0.05, 48828.125
BINS = [5, 10, 15, 20, 25, 31, 37, 43]
TH0 = 137.0
ANGS = np.arange(-180, 181)


def steer(kR, th_disp):
    alpha = np.arange(NCH) * 2 * np.pi / NCH
    return np.exp(-1j * kR * np.cos(np.deg2rad(th_disp - 180.0) - alpha))


def kR_of(bin_idx):
    return 2 * np.pi * (bin_idx * FS / 512.0) * R / C


KR = np.array([kR_of(b) for b in BINS])
A_TAB = np.array([steer(kr, a) for kr in KR for a in ANGS]).reshape(len(BINS), NANG, NCH)


def spectra(rng, snr_db, nsnap, th0=TH0):
    """返回 (nbins, NANG) 的 MVDR 谱。"""
    sig = np.sqrt(10 ** (snr_db / 10))
    sigs = sig * (rng.standard_normal(nsnap) + 1j * rng.standard_normal(nsnap)) / np.sqrt(2)
    noise = (rng.standard_normal((nsnap, NCH)) + 1j * rng.standard_normal((nsnap, NCH))) / np.sqrt(2)
    out = np.empty((len(BINS), NANG))
    for bi in range(len(BINS)):
        X = np.outer(sigs, A_TAB[bi, np.argmin(np.abs(ANGS - th0))]) + noise
        Rm = X.T @ X.conj() / nsnap
        Rm += 1e-6 * np.trace(Rm).real / NCH * np.eye(NCH)
        Rinv = np.linalg.inv(Rm)
        P = np.einsum("ki,ij,kj->k", A_TAB[bi].conj(), Rinv, A_TAB[bi]).real
        out[bi] = 1.0 / P
    return out


# ---------------- 左图：八个频点的空间谱 + 融合 ----------------
rng = np.random.default_rng(20261102)
SP = spectra(rng, 20.0, 128)
FUSED = SP.sum(axis=0)

to_db = lambda p: 10 * np.log10(p / p.max() + 1e-12)

fig, axes = plt.subplots(1, 2, figsize=(13, 4.8), dpi=200)

ax = axes[0]
cmap = plt.get_cmap("viridis")
for bi, b in enumerate(BINS):
    ax.plot(ANGS, to_db(SP[bi]), lw=0.9, alpha=0.75, color=cmap(bi / 7.0),
            label="bin%2d  %.0f Hz  kR=%.2f" % (b, b * FS / 512.0, KR[bi]))
ax.plot(ANGS, to_db(FUSED), lw=2.4, color="#d62728", label="八频点融合")
ax.axvline(TH0, color="0.5", ls=":", lw=1)
ax.set_xlim(-180, 180)
ax.set_ylim(-35, 2)
ax.set_xticks(np.arange(-180, 181, 90))
ax.set_xlabel("方位角 / (°)")
ax.set_ylabel("归一化空间谱 / dB")
ax.set_title("(a) 八个频点的空间谱与融合结果（SNR = 20 dB，128 快拍）", fontsize=10.5)
ax.grid(alpha=0.25, lw=0.5)
ax.legend(fontsize=6.2, loc="lower right", ncol=1, framealpha=0.85, handlelength=1.2)

# ---------------- 右图：逐帧估计的抖动（各频点独立 vs 融合） ----------------
NFRAME, snr_low, nsnap_low = 80, 10.0, 8
rng = np.random.default_rng(7)
per_bin = np.empty((len(BINS), NFRAME))
fused = np.empty(NFRAME)
for k in range(NFRAME):
    sp = spectra(rng, snr_low, nsnap_low)
    for bi in range(len(BINS)):
        d = ANGS[np.argmax(sp[bi])] - TH0
        per_bin[bi, k] = (d + 180) % 360 - 180
    d = ANGS[np.argmax(sp.sum(axis=0))] - TH0
    fused[k] = (d + 180) % 360 - 180

ax = axes[1]
for bi in range(len(BINS)):
    ax.plot(np.arange(NFRAME), per_bin[bi], lw=0.8, alpha=0.55,
            color=cmap(bi / 7.0), label="各频点单独估计" if bi == 0 else None)
ax.plot(np.arange(NFRAME), fused, lw=2.4, color="#d62728", label="八频点融合")
ax.axhline(0, color="0.5", ls=":", lw=1)
rms_bin = np.sqrt(np.mean(per_bin ** 2))
rms_fus = np.sqrt(np.mean(fused ** 2))
ax.text(0.02, 0.06, "RMS：单频 %.1f° → 融合 %.1f°" % (rms_bin, rms_fus),
        transform=ax.transAxes, fontsize=8.5, color="#333333",
        bbox=dict(fc="white", ec="0.7", alpha=0.85, lw=0.6))
ax.set_xlim(0, NFRAME - 1)
ax.set_ylim(-25, 25)
ax.set_xlabel("帧序号")
ax.set_ylabel("估计偏差 / (°)")
ax.set_title("(b) 逐帧估计抖动（SNR = %g dB，%d 快拍/帧）" % (snr_low, nsnap_low), fontsize=10.5)
ax.grid(alpha=0.25, lw=0.5)
ax.legend(fontsize=8, framealpha=0.85, loc="upper right")

fig.tight_layout()
out = r"D:\Engineering_save\FPGA\AMD_ZYNQ\fft_demo\sim\fig_spatial_spectrum_bin_vs_8bin.png"
fig.savefig(out)
print("saved:", out)
print("融合 peak @ %.0f°" % ANGS[np.argmax(FUSED)])
print("逐帧抖动 RMS：单频各 bin 平均 %.2f°，融合 %.2f°"
      % (np.sqrt(np.mean(per_bin ** 2)), np.sqrt(np.mean(fused ** 2))))
print("逐帧抖动 P95：单频各 bin 平均 %.1f°，融合 %.1f°"
      % (np.percentile(np.abs(per_bin), 95), np.percentile(np.abs(fused), 95)))
