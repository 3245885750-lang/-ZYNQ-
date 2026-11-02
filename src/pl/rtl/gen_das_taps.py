# ============================================================
# gen_das_taps.py —— 时域 DAS 分数延时抽头表生成器（跑一次即可）
#
# 生成 NANG=181 个角度 x 8 通道 的"分数延时"抽头，拆成整数 + 分数（Q8），
# 写成两张表（$readmemh 用）：
#   src/das_taps_int.mem   —— 每角度 1 行 = 48bit（12 位十六进制），
#                             打包 8 通道整数部分（6bit/路，0..31）
#   src/das_taps_frac.mem  —— 每角度 1 行 = 64bit（16 位十六进制），
#                             打包 8 通道分数部分（8bit/路，0..255）
# 打包顺序：bit[ch*6 +: 6]（int）/ bit[ch*8 +: 8]（frac）= 第 ch 通道；
#   一行 = 一个角度，硬件一次只读一个角度 → 单读口 ROM，省 ~3000 LUT。
# 索引顺序： ang=0..180 对应角度 deg = ang*2 - 180（2° 步长）
#
# ⚠️ 圆周阵列（UCA，R=0.05m）：
#   D_i(theta) = D0 - k*cos(theta - alpha_i)，D0=16，alpha_i = 2*pi*i/8
#   k = R*Fs/c = 0.05m * 48828.125Hz / 343m/s ≈ 7.118 样本
# 定点拆分： q = round(D_i * 256)； tap_int = q >> 8； tap_frac = q & 0xFF。
#   硬件里 2 抽头线性插值： y = x[int] + (frac * (x[int+1] - x[int])) >> 8
#
# 为什么是"减"：延时求和要 ADVANCE 第 i 路 tau_i（即 delay 负 tau_i），
# 再加公摊 D0=16 把负延时抬正。与 MVDR 的 a_i=e^{-j*kR*cos(theta-alpha_i)} 约定一致。
#
# ⚠️ 若上板发现 DAS 角度符号与 MVDR 相反，把 D0 - k*cos(...) 改成
#    D0 + k*cos(...) 重新生成两张 .mem 再综合（一次定位，两处同步）。
# ============================================================
import math

NANG = 181        # 2° 步长（-180..+180）
NCH  = 8
D0   = 16         # 公摊延时（样本），把负延时抬成正延时
c    = 343.0
R    = 0.05
Fs   = 50000000.0 / 16.0 / 64.0   # 48.828125 kHz（SCK=3.125MHz /64）
k    = R * Fs / c                 # 最大路径延时（样本）≈ 7.118
Q    = 8                          # 分数延时量化位宽
QS   = 2 ** Q
IB   = 6                          # 整数部分位宽（0..31 < 2^6）
FB   = 8                          # 分数部分位宽（Q8）

out_int  = "D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/src/das_taps_int.mem"
out_frac = "D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/src/das_taps_frac.mem"

ti_all, tf_all = [], []
with open(out_int, "w") as fi, open(out_frac, "w") as ff:
    for ang in range(NANG):
        theta = (ang*2 - 180) * math.pi / 180.0
        int_word  = 0
        frac_word = 0
        for ch in range(NCH):
            alpha = ch * 2.0 * math.pi / NCH
            delay = D0 - k * math.cos(theta - alpha)
            q     = int(round(delay * QS))
            ti    = q >> Q
            tf    = q & (QS - 1)
            int_word  |= (ti & (2**IB - 1)) << (ch * IB)
            frac_word |= (tf & (2**FB - 1)) << (ch * FB)
            ti_all.append(ti)
            tf_all.append(tf)
        fi.write("%012x\n" % int_word)     # 48bit = 12 位十六进制
        ff.write("%016x\n" % frac_word)    # 64bit = 16 位十六进制

print("==============================================")
print("das_taps_int.mem / das_taps_frac.mem generated (UCA, R=0.05m)")
print("  angles   = %d (deg -180..+180, step 2)" % NANG)
print("  channels = %d" % NCH)
print("  lines    = %d per file (每行=1 角度打包 8 通道)" % NANG)
print("  tap_int  range [%d, %d]" % (min(ti_all), max(ti_all)))
print("  tap_frac range [%d, %d]" % (min(tf_all), max(tf_all)))
print("  -> src/das_taps_int.mem  (每行 %d hex)" % (NCH * IB // 4))
print("  -> src/das_taps_frac.mem (每行 %d hex)" % (NCH * FB // 4))
print("==============================================")
