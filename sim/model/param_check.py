# -*- coding: utf-8 -*-
"""param_check.py —— 把 RTL 里的参数/常数抠出来，和 sim_clap_smooth.py 的模型常量逐项比对。

目的：回放脚本是"逐位同逻辑"的模型，一旦 RTL 参数改了、脚本忘了跟，结论就是假的。
本脚本没有任何仿真，只做文本比对，秒级完成。

用法：python param_check.py
"""
import re
import sys

RTL = r"D:\Engineering_save\FPGA\AMD_ZYNQ\fft_demo\src\mvdr_axi_top.v"

# RTL 参数名 -> 模型里的变量名/期望值（None = 只打印，不比对）
WANT = {
    "GATE_DEG":     "GATE_DEG",
    "GATE_TOL":     "GATE_TOL",
    "GATE_N":       "GATE_N",
    "GATE_MAX":     "GATE_MAX",
    "SLEW_DEG":     "SLEW_DEG",
    "SLEW_BIG_DEG": "SLEW_BIG",
    "BIG_TRIG_DEG": "BIG_TRIG",
    "CLAP_HOLD":    "CLAP_HOLD",
    "SLEW_EVT_DEG": "SLEW_EVT_B",
    "SIG_EN":       None,
    "SIG_DB_SH":    "SIG_DB_SH",
}


def main():
    txt = open(RTL, encoding="utf-8").read()
    rtl = {}
    for m in re.finditer(r"parameter\s+integer\s+(\w+)\s*=\s*([0-9]+)", txt):
        rtl[m.group(1)] = int(m.group(2))

    sys.path.insert(0, r"D:\Engineering_save\FPGA\AMD_ZYNQ\fft_demo\sim")
    import sim_clap_smooth as mod

    bad = []
    print("%-14s %-10s %-10s %s" % ("参数", "RTL", "模型", ""))
    for name, mv in WANT.items():
        r = rtl.get(name, "?")
        m = getattr(mod, mv, "?") if mv else "-"
        ok = (mv is None) or (r == m)
        if not ok:
            bad.append(name)
        print("%-14s %-10s %-10s %s" % (name, r, m, "OK" if ok else "不一致"))

    # 模型里写死的能量判据常数，必须和 RTL 的表达式一致
    checks = [
        ("evt 下限 2048", "44'd2048" in txt or "d2048" in txt),
        ("e_fast 衰减 >>2", "e_fast >> 2" in txt),
        ("e_slow 衰减 >>6", "e_slow >> 6" in txt),
        ("比值判据 <<5 / +3x", "(e_fast << 5)" in txt and "(e_slow << 2)" in txt),
        ("窗口内关 gate_force", "(gate_cnt + 4'd1) >= GATE_MAX) && (evt_cnt == 5'd0)" in txt),
        ("accept_g 门", "accept_any && sig_ok" in txt),
        ("pwr_peak 复位", "pwr_peak   <= 32'd0" in txt),
    ]
    print()
    for nm, ok in checks:
        print("%-24s %s" % (nm, "OK" if ok else "没找到"))
        if not ok:
            bad.append(nm)

    print()
    if bad:
        print("不一致：%s" % ", ".join(bad))
        sys.exit(1)
    print("全部一致")


if __name__ == "__main__":
    main()
