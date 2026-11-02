# -*- coding: utf-8 -*-
"""sim_clr_seq.py —— 逐拍复现 cov_accum 的 CLR 序列（非阻塞赋值语义），核对
"写地址"和"写数据"是否对齐，以及 288 项最后是不是 8 个 λ + 224 个 0。

RTL 里写端口是这样用的：
  always @(posedge clk) if (wr_en) accm[waddr] <= wr_data;
即：第 N 拍的 wr_en/waddr/wr_data 决定第 N 拍**结束时**写入的内容，三者都是
上一拍寄存器装好的。所以三个信号必须同时刻装，任何一个早/晚一拍都会错位。
"""
NB, NT = 8, 36
DIAG = [0, 8, 15, 21, 26, 30, 33, 35]      # is_diag_p 的表
LAM = 1000


def is_diag(p):
    return p in DIAG


# --- 寄存器（初值为进入 CLR 那一拍之后的状态）---
state, p, bin_idx = "CLR", 0, 0
wr_en, waddr, wr_is_clr, clr_val = 0, 0, 0, 0
mem = {}
writes = []

for cyc in range(1000):
    # 1) 本拍结束时的写（用本拍**开始时**的寄存器值）
    if wr_en:
        mem[waddr] = clr_val if wr_is_clr else "EMA"
        writes.append(waddr)

    # 2) 算下一拍
    if state == "CLR":
        n_wr_en, n_waddr = 1, bin_idx * 36 + p
        n_is_clr = 1
        n_val = LAM if is_diag(p) else 0
        if p == NT - 1:
            if bin_idx < NB - 1:
                n_bin, n_p, n_state = bin_idx + 1, 0, "CLR"
            else:
                n_bin, n_p, n_state = bin_idx, p, "CLR2"
        else:
            n_bin, n_p, n_state = bin_idx, p + 1, "CLR"
    elif state == "CLR2":
        n_wr_en, n_waddr, n_is_clr, n_val = 0, waddr, 0, 0
        n_bin, n_p, n_state = bin_idx, p, "IDLE"
    else:
        break

    wr_en, waddr, wr_is_clr, clr_val = n_wr_en, n_waddr, n_is_clr, n_val
    bin_idx, p, state = n_bin, n_p, n_state
    if state == "IDLE":
        break

print("CLR 序列用了 %d 拍（拍数 = 288 次写 + 1 拍收尾，应 %d）" % (cyc + 1, NT * NB + 1))
print("写过的地址个数 = %d（应 288）" % len(writes))
print("地址覆盖 0..287 且无重复/无遗漏：", writes == list(range(NB * NT)))
lam_addr = sorted(a for a in writes if mem.get(a) == LAM)
print("写 λ 的地址：", lam_addr[:9], "..." if len(lam_addr) > 9 else "")
diag_abs = sorted(b * 36 + d for b in range(NB) for d in DIAG)
print("应为（每 bin 的 8 个对角项）：", diag_abs[:9], "...")
print("一致：", lam_addr == diag_abs)
zeros = [a for a in writes if mem.get(a) == 0]
print("写 0 的个数 = %d（应 %d）" % (len(zeros), NB * (NT - 8)))
print("有没有被写成 EMA 结果的项：", any(v == "EMA" for v in mem.values()))
