#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
doa_view.py —— DOA 串口实时可视化（纯 PC 端工具，不碰 PL，不占板上资源）

数据来自 radar_pl/src/doa_uart.v：115200 8N1，每行一条
    M=270 E=0012AB34 V=01 MVDR 精测角度 + 能量 + 运动判据（K=2 约 47.7 Hz）
    D=271 P=0010F3A2      DAS 粗测角度 + 波束功率（约 47.7 Hz）
    V=<v1><v2>：1=该判据本帧认为在运动（协方差切短记忆）。v1=θp±Δ 波束比，
                v2=DOA 增量 EMA。V 段可选，老固件没有也能解析。
上电先发一行 "radar_pl ready"。角度已归一化到 0..359（-90° 打成 270°）。

用法：
    python doa_view.py --list                    # 先看看板子插在哪个 COM
    python doa_view.py --port COM5               # 实时看
    python doa_view.py --port COM5 --csv run.csv # 实时看 + 存 CSV

    # 回放：把串口窗口里的文本另存为 txt，再喂进来（不插板子也能看）
    python doa_view.py --file clap.txt
    # 不开窗口，直接出一张 PNG（给队友/写报告用）
    python doa_view.py --file clap.txt --save clap.png

界面：
    左边  极坐标表盘：0° 在正上方、顺时针增大；粗针 = M，细虚线针 = D；
          外圈是最近几秒的轨迹拖尾（越新越亮），环绕声源会拉出一圈螺线
    右上  角度-时间曲线：M（红粗）和 D（蓝细）叠在一起，跳变一眼可见
    右下  能量-时间（对数纵轴）：拍手/说话的能量包络，看拖尾长度

判读提示：
    · 时间轴上的折线在 359°→0° 处断开（模环绕，不是跳变），真正的跳变保留折线
    · 极坐标上超过 90° 的相邻点不连线（避免画一条横穿圆盘的假弦）
    · 标题栏实时给出：最近 5 秒内 >30° 的跳变次数、最大步进、近 10 秒实际更新率
      （更新率按最近 10 s 算；用"总样本数÷总时长"会被中途断流稀释成假数）
"""

import argparse
import csv
import queue
import re
import sys
import threading
import time
from collections import deque

import numpy as np

# doa_uart 的行格式：单字母类型 + 3 位角度(0..359) + 单字母能量 + 8 位 HEX
#                 + 可选的运动判决 " V=<v1><v2>"（只有 MVDR 行有）
LINE_RE = re.compile(r"^\s*([MD])\s*=\s*(\d{1,3})\s+([PE])\s*=\s*([0-9A-Fa-f]{1,8})"
                     r"(?:\s+V=([01])([01]))?\s*$")

NOMINAL_RATE = 47.7   # K=2 时 M/D 各自的更新率（Hz），回放节拍与兜底时间轴用
WINDOW_S     = 20.0   # 时间轴默认窗口（秒）
TRAIL_S      = 6.0    # 极坐标拖尾默认时长（秒）


# ---------------------------------------------------------------- 数据来源

def serial_reader(ser, q, stop):
    """后台线程：把串口字节流切成行，带接收时间戳塞进队列"""
    buf = b""
    while not stop.is_set():
        try:
            chunk = ser.read(512)
        except Exception as exc:            # 拔线、端口被抢
            q.put((time.time(), "@ERR " + str(exc)))
            return
        if not chunk:
            continue
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            q.put((time.time(), line.decode("ascii", "replace").strip()))


def file_reader(path, q, stop, rate, fast):
    """后台线程：按标称节拍回放文本文件；--fast 时一口气灌完"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    t0 = time.time()
    for n, ln in enumerate(lines):
        if stop.is_set():
            return
        q.put((None, ln))
        if not fast:
            dt = t0 + (n + 1) / rate - time.time()
            if dt > 0:
                time.sleep(dt)


# ---------------------------------------------------------------- 主程序

class App:
    def __init__(self, args, plt, LineCollection):
        self.args = args
        self.plt = plt
        self.q = queue.Queue()
        self.stop = threading.Event()

        self.vt = 0.0              # 虚拟时间轴（秒）：实时=相对首行，回放=按节拍累加
        self.t_first = None
        self.last = {"M": None, "D": None}          # (vt, ang, pwr)
        self.samples = {"M": deque(maxlen=8000), "D": deque(maxlen=8000)}
        self.stats = {"M": {"jumps": 0, "maxstep": 0.0, "n": 0,
                            "on": {"v1": 0, "v2": 0}}}
        self.mot_last = ""         # 最近一帧的 {v1, v2}（"1"/"0"，无此字段时为 ""）
        self.events = []           # 非 M/D 的原始行（banner 等），判断板子有没有复位

        self.csvf = None
        self.csv = None
        if args.csv:
            self.csvf = open(args.csv, "w", newline="", encoding="utf-8")
            self.csv = csv.writer(self.csvf)
            self.csv.writerow(["t_s", "type", "deg", "pwr_hex", "pwr_dec", "mot"])

        self._build_figure(LineCollection)

    # ------------------------------------------------------------ 界面

    def _build_figure(self, LineCollection):
        plt = self.plt
        self.fig = plt.figure(figsize=(13.5, 6.8))
        gs = self.fig.add_gridspec(2, 2, width_ratios=[1.0, 1.6],
                                   hspace=0.30, wspace=0.20)
        # 底部留一条空白放状态栏：状态框绝不能压在曲线上（会把跳变挡掉）
        self.fig.subplots_adjust(top=0.88, bottom=0.15, left=0.06, right=0.985)
        self.ax_p = self.fig.add_subplot(gs[:, 0], projection="polar")
        self.ax_a = self.fig.add_subplot(gs[0, 1])
        self.ax_e = self.fig.add_subplot(gs[1, 1], sharex=self.ax_a)

        # ---- 极坐标表盘：0° 正上、顺时针 ----
        ax = self.ax_p
        ax.set_theta_zero_location("N")
        ax.set_theta_direction(-1)
        ax.set_ylim(0, 1.0)
        ax.set_yticks([])                       # 不显示径向刻度
        ax.set_xticks(np.deg2rad([0, 45, 90, 135, 180, 225, 270, 315]))
        ax.set_xticklabels(["0°", "45°", "90°", "135°", "180°", "225°", "270°", "315°"])
        ax.grid(color="0.8", lw=0.6)
        ax.set_title("方位（0° 正上，顺时针）", pad=14, fontsize=10)

        self.cmap = plt.get_cmap("autumn")
        self.trail = LineCollection([], linewidths=2.0, zorder=3)
        ax.add_collection(self.trail)
        self.needle_d, = ax.plot([], [], color="#1f77b4", lw=1.0, ls="--",
                                 alpha=0.75, zorder=4)      # DAS 参考
        self.needle_m, = ax.plot([], [], color="#d62728", lw=2.4, zorder=5)
        self.tip, = ax.plot([], [], "o", color="#d62728", ms=6, zorder=6)

        # ---- 角度-时间 ----
        ax = self.ax_a
        ax.set_ylabel("角度 (°)")
        ax.set_ylim(-8, 368)
        ax.set_yticks([0, 45, 90, 135, 180, 225, 270, 315, 360])
        ax.grid(color="0.85", lw=0.6)
        ax.tick_params(labelbottom=False)
        self.line_m, = ax.plot([], [], color="#d62728", lw=1.8, label="M  MVDR")
        self.line_d, = ax.plot([], [], color="#1f77b4", lw=0.9, alpha=0.65, label="D  DAS")
        ax.legend(loc="lower right", bbox_to_anchor=(1.0, 1.0), ncol=2,
                  fontsize=8, frameon=False)      # 图例放在坐标区外面，不挡数据
        self.status = self.fig.text(0.012, 0.018, "等待数据…", va="bottom",
                                    ha="left", fontsize=9)

        # ---- 能量-时间（对数）----
        ax = self.ax_e
        ax.set_ylabel("能量（对数）")
        ax.set_xlabel("时间 (s)")
        ax.set_yscale("log")
        ax.grid(color="0.85", lw=0.6, which="both")
        self.line_em, = ax.plot([], [], color="#d62728", lw=1.2)
        self.line_ed, = ax.plot([], [], color="#1f77b4", lw=0.8, alpha=0.6)

        self.fig.suptitle("radar_pl DOA 监视", fontsize=12)
        self.fig.canvas.mpl_connect("key_press_event", self.on_key)

    # ------------------------------------------------------------ 数据

    def pump(self):
        """把队列里的行全部解析进缓冲（只在主线程做，避免跨线程碰 matplotlib）"""
        while True:
            try:
                ts, line = self.q.get_nowait()
            except queue.Empty:
                return
            if line.startswith("@ERR"):
                print("[串口错误]", line[5:], file=sys.stderr)
                continue
            m = LINE_RE.match(line)
            if not m:
                txt = line.strip()
                if txt:
                    # doa_uart 每次复位后先发一行 "radar_pl ready"。把这类行记进 CSV
                    # （type=B, deg=0），事后就能确定板子是在哪一刻自己复位的。
                    self.events.append((self.vt, txt))
                    if self.csv:
                        self.csv.writerow([round(self.vt, 4), "B", 0,
                                           "0x00000000", 0, ""])
                    if self.args.verbose:
                        print("[事件 @%.1fs]" % self.vt, txt)
                continue
            kind, ang_s, _, pwr_s, v1_s, v2_s = m.groups()
            ang = int(ang_s) % 360
            pwr = int(pwr_s, 16)
            mot = "" if v1_s is None else v1_s + v2_s

            if ts is None:                    # 回放：按标称节拍推进虚拟时间
                self.vt += 1.0 / self.args.rate
            else:                             # 实时：用接收时间
                if self.t_first is None:
                    self.t_first = ts
                self.vt = ts - self.t_first

            if kind == "M":
                prev = self.last["M"]
                if prev is not None:          # 统计（模距离，359→0 不算跳变）
                    d = abs(((ang - prev[1]) + 180) % 360 - 180)
                    st = self.stats["M"]
                    st["n"] += 1
                    if d > 30:
                        st["jumps"] += 1
                    st["maxstep"] = max(st["maxstep"], d)
                if mot:                       # 板子上报了运动判决才统计
                    self.mot_last = mot
                    if mot[0] == "1":
                        self.stats["M"]["on"]["v1"] += 1
                    if mot[1] == "1":
                        self.stats["M"]["on"]["v2"] += 1
            self.last[kind] = (self.vt, ang, pwr)
            self.samples[kind].append((self.vt, ang, pwr))
            if self.csv:
                self.csv.writerow([round(self.vt, 4), kind, ang,
                                   "0x%08X" % pwr, pwr, mot])
                # 每行落盘：窗口被强杀（Alt+F4 / 关控制台）时不会丢已采的数据
                self.csvf.flush()

            cut = self.vt - max(self.args.window, self.args.trail) - 5.0
            for dq in self.samples.values():
                while dq and dq[0][0] < cut:
                    dq.popleft()

    def as_arrays(self, kind):
        dq = self.samples[kind]
        if not dq:
            return None, None, None
        a = np.array(dq, dtype=float)
        return a[:, 0], a[:, 1], a[:, 2]

    @staticmethod
    def break_wraps(t, a):
        """时间轴折线：359→0 的模环绕断开；真跳变保留（否则看不见）"""
        y = a.astype(float).copy()
        d = np.diff(y)
        modd = np.abs((d + 180.0) % 360.0 - 180.0)
        wrap = (np.abs(d) > 180.0) & (modd < 60.0)   # 跨 0 点的正常回绕
        y[1:][wrap] = np.nan
        return y

    # ------------------------------------------------------------ 刷新

    def update(self, _frame):
        self.pump()
        tM, aM, eM = self.as_arrays("M")
        tD, aD, eD = self.as_arrays("D")

        # ---- 极坐标：针 + 拖尾 ----
        if tM is not None and len(tM):
            th = np.deg2rad(aM[-1])
            self.needle_m.set_data([0, th], [0, 1.0])
            self.tip.set_data([th], [1.0])
        if tD is not None and len(tD):
            th = np.deg2rad(aD[-1])
            self.needle_d.set_data([0, th], [0, 1.0])
        if tM is not None and len(tM) > 1:
            sel = tM >= (self.vt - self.args.trail)
            tt, aa = tM[sel], aM[sel]
            segs, cols = [], []
            for i in range(1, len(tt)):
                dmod = abs(((aa[i] - aa[i - 1]) + 180.0) % 360.0 - 180.0)
                if dmod > 90.0:          # 真跳变：不画横穿圆盘的弦
                    continue
                segs.append([(np.deg2rad(aa[i - 1]), 1.0),
                             (np.deg2rad(aa[i]), 1.0)])
                age = 1.0 - (self.vt - tt[i]) / max(self.args.trail, 1e-3)
                cols.append(self.cmap(float(np.clip(age, 0.0, 1.0))))
            self.trail.set_segments(segs)
            self.trail.set_color(cols)
        else:
            self.trail.set_segments([])

        # ---- 角度-时间 ----
        if tM is not None and len(tM):
            self.line_m.set_data(tM, self.break_wraps(tM, aM))
        if tD is not None and len(tD):
            self.line_d.set_data(tD, self.break_wraps(tD, aD))

        # ---- 能量-时间 ----
        if tM is not None and len(tM):
            self.line_em.set_data(tM, np.maximum(eM, 1.0))
        if tD is not None and len(tD):
            self.line_ed.set_data(tD, np.maximum(eD, 1.0))
        self.ax_e.relim()
        self.ax_e.autoscale_view(scalex=False, scaley=True)

        hi = max(1.0, self.vt)
        lo = max(0.0, hi - self.args.window)
        self.ax_a.set_xlim(lo, hi if hi - lo > 1.0 else lo + 1.0)

        # ---- 状态栏 ----
        self.status.set_text(self.status_text(tM, aM, eM))
        return ()

    def status_text(self, tM, aM, eM):
        if tM is None or len(tM) == 0:
            return "等待数据…\n(检查 COM 口 / 波特率 115200)"
        # 最近 5 秒的跳变统计
        sel = tM >= (self.vt - 5.0)
        recent = aM[sel]
        if len(recent) > 1:
            d = np.abs(((np.diff(recent) + 180.0) % 360.0) - 180.0)
            nj = int((d > 30).sum())
            mx = float(d.max())
        else:
            nj, mx = 0, 0.0
        st = self.stats["M"]
        # 更新率必须按"最近 10 s"算：用 st["n"]/vt 会被中途的静默段（板子断电、
        # 串口断流）稀释成 1.4 Hz 这种假数——真实帧率一直没变。
        n10 = int((tM >= (self.vt - 10.0)).sum())
        rate = n10 / min(10.0, self.vt) if self.vt > 0.5 else 0.0
        nboot = sum(1 for _, s in self.events if "ready" in s)
        boot_s = ("    板子复位 %d 次" % nboot) if nboot else ""
        if self.mot_last:
            mot_s = "  V=%s(v1%s v2%s)" % (self.mot_last,
                                           "开" if self.mot_last[0] == "1" else "关",
                                           "开" if self.mot_last[1] == "1" else "关")
        else:
            mot_s = ""
        return ("M=%3d°  E=0x%08X (%d)      更新率≈%4.1f Hz(近10s)  已运行 %5.1f s%s%s\n"
                "近5s：跳变>30° %d 次，最大步进 %4.1f°        全程：跳变>30° %d 次，"
                "最大步进 %4.1f°"
                % (int(aM[-1]), int(eM[-1]), int(eM[-1]),
                   rate, self.vt, boot_s, mot_s, nj, mx, st["jumps"], st["maxstep"]))

    def on_key(self, ev):
        if ev.key == "c":
            for dq in self.samples.values():
                dq.clear()
            self.last = {"M": None, "D": None}
            self.stats = {"M": {"jumps": 0, "maxstep": 0.0, "n": 0,
                                "on": {"v1": 0, "v2": 0}}}
            print("[清屏]")
        elif ev.key in ("q", "escape"):
            self.plt.close(self.fig)

    # ------------------------------------------------------------ 运行

    def run(self):
        args = self.args
        ser = None
        if args.port:
            import serial
            try:
                ser = serial.Serial(args.port, args.baud, timeout=0.1)
            except Exception as exc:
                print("打不开 %s：%s\n" % (args.port, exc), file=sys.stderr)
                print("用 --list 看当前有哪些串口；被别的终端占用时先关掉它。",
                      file=sys.stderr)
                return 1
            print("已连接 %s @ %d 8N1" % (args.port, args.baud))
            th = threading.Thread(target=serial_reader, args=(ser, self.q, self.stop),
                                  daemon=True)
        else:
            print("回放 %s（%s）" % (args.file,
                                    "尽快" if args.fast else "%.1f 行/秒" % args.rate))
            th = threading.Thread(target=file_reader,
                                  args=(args.file, self.q, self.stop,
                                        args.rate, args.fast), daemon=True)
        th.start()

        if args.save:                      # 无窗口：等回放灌完，画一张 PNG
            while th.is_alive():
                time.sleep(0.05)
            time.sleep(0.2)
            self.update(None)
            self.fig.savefig(args.save, dpi=130, bbox_inches="tight")
            print("已保存", args.save)
        else:
            from matplotlib.animation import FuncAnimation
            self.ani = FuncAnimation(self.fig, self.update, interval=50,
                                     cache_frame_data=False)
            self.plt.show()

        self.stop.set()
        if ser is not None:
            try:
                ser.close()
            except Exception:
                pass
        if self.csvf:
            self.csvf.close()
        return 0


# ---------------------------------------------------------------- 入口

def parse_args():
    p = argparse.ArgumentParser(
        description="radar_pl DOA 串口可视化（doa_uart：M=/D= 行，115200 8N1）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--port", help="串口号，如 COM5")
    src.add_argument("--file", help="回放：串口文本另存为 txt 后传进来")
    src.add_argument("--list", action="store_true", help="列出所有串口后退出")
    p.add_argument("--baud", type=int, default=115200, help="波特率")
    p.add_argument("--rate", type=float, default=NOMINAL_RATE,
                   help="回放节拍（行/秒，仅 --file 用）")
    p.add_argument("--fast", action="store_true", help="回放不按节拍（配合 --save）")
    p.add_argument("--save", metavar="PNG", help="不开窗口，回放结束保存图片")
    p.add_argument("--csv", metavar="FILE", help="把解析到的样本另存为 CSV")
    p.add_argument("--window", type=float, default=WINDOW_S, help="时间轴窗口（秒）")
    p.add_argument("--trail", type=float, default=TRAIL_S, help="极坐标拖尾（秒）")
    p.add_argument("--verbose", action="store_true", help="打印无法解析的行")
    return p.parse_args()


def list_ports():
    try:
        from serial.tools import list_ports as lp
    except ImportError:
        print("没装 pyserial：pip install pyserial", file=sys.stderr)
        return 1
    ports = list(lp.comports())
    if not ports:
        print("没找到串口（板子插上了吗？装 CH340 驱动了吗？）")
    for p in ports:
        print("%-8s %s  [%s]" % (p.device, p.description, p.hwid))
    return 0


def main():
    args = parse_args()
    if args.list:
        return list_ports()
    if args.save and not args.file:
        print("--save 只用于回放；实时模式直接看窗口。", file=sys.stderr)
        return 2

    import matplotlib
    if args.save:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import LineCollection
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False

    return App(args, plt, LineCollection).run()


if __name__ == "__main__":
    sys.exit(main())
