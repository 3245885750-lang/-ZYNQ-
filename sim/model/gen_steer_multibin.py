# gen_steer_multibin.py —— 生成多 bin 版本的导向向量 ROM 数据（圆周阵列 UCA）
# 与 gen_steer_4khz.py 完全同公式，只是把 bin 列表参数化。
# 宽带 MVDR 每个频率 bin 需要自己的导向矢量（kR = 2*pi*f*R/c 随 f 变）。
# 圆周阵列：a_i(theta) = exp(-j*kR*cos(theta-alpha_i))，alpha_i = 2*pi*i/8，R=0.05
import math

NCH  = 8
NANG = 361
c    = 343.0
R    = 0.05
FS   = 50000000.0 / 16.0 / 64.0      # = 48828.125 Hz
BINS = [5, 10, 15, 20, 25, 31, 37, 43]   # 宽带 MVDR 8 bin：476.9Hz .. 4100.8Hz 分散频段

def q16(x):
    if x >= 0.0:
        return math.floor(x * 65536.0 + 0.5)
    else:
        return math.ceil(x * 65536.0 - 0.5)

def to_hex(v):
    if v < 0:
        v += (1 << 32)
    return "%08x" % v

OUT_DIR = r"D:\Engineering_save\FPGA\AMD_ZYNQ\fft_demo\src"

for b in BINS:
    f0 = b * FS / 512.0
    kR = 2.0 * math.pi * f0 * R / c

    re_lines = []
    im_lines = []
    for ang in range(NANG):
        th = (ang - 180) * math.pi / 180.0
        for ch in range(NCH):
            alpha = ch * 2.0 * math.pi / NCH
            ph = kR * math.cos(th - alpha)
            re_lines.append(to_hex(q16( math.cos(ph))))
            im_lines.append(to_hex(q16(-math.sin(ph))))

    assert len(re_lines) == NANG * NCH == 2888

    re_path = OUT_DIR + r"\steer_re_bin%d.mem" % b
    im_path = OUT_DIR + r"\steer_im_bin%d.mem" % b
    with open(re_path, "w") as f:
        f.write("\n".join(re_lines) + "\n")
    with open(im_path, "w") as f:
        f.write("\n".join(im_lines) + "\n")

    print("bin %2d: f0 = %8.2f Hz, kR = %.4f rad -> %s / %s"
          % (b, f0, kR, re_path, im_path))
    # 圆周阵列里没有麦在中心，ch0 也有相位：a_0(0°) = exp(-j*kR) = cos(kR) - j*sin(kR)
    print("        sanity ang=180(0deg) ch0: re=%s im=%s  (expect exp(-j*%.4f))"
          % (re_lines[180*NCH+0], im_lines[180*NCH+0], kR))

print("OK")
