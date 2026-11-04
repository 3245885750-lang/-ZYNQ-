# -*- coding: utf-8 -*-
"""JTAG 音频桥：经 JTAG 直读 ZYNQ PS DDR 里的 8 麦阵列波束成形 PCM 环形缓冲，
重采样到 16kHz 后以 AUD3 包发到本机 UDP9000（与板端 JSON 同通道，web_receiver 自动分流）。
固件邮箱：g_stream_header @ 0x0023d780（'STR1'，PL004-radar7-live-spectrum-20261102），
环形缓冲 8192 帧 x 1024 样本。邮箱地址随固件版本变化，可用环境变量 STR1_HDR 覆盖。
"""
import os, shutil, subprocess, sys, time, socket, struct
import numpy as np
from scipy.signal import resample_poly

def _find_xsdb():
    """xsdb 路径：环境变量 XSDB > PATH 中的 xsdb(.bat)。"""
    p = os.environ.get('XSDB')
    if p:
        return p
    for name in ('xsdb.bat', 'xsdb'):
        p = shutil.which(name)
        if p:
            return p
    raise RuntimeError(
        '未找到 xsdb：请安装 Vivado 或 Vivado Lab，把其 bin 目录加入 PATH，'
        '或设置环境变量 XSDB 指向 xsdb.bat（例：set XSDB=D:\\Xilinx\\Vitis\\bin\\xsdb.bat）')

XSDB = None          # 惰性解析：只在真正连接 JTAG 时查路径
# 固件邮箱地址随 PS 固件版本变化；默认值对应 PL004-radar7-live-spectrum-20261102
HDR = int(os.environ.get('STR1_HDR', '0x0023d780'), 0)
FRAME_SAMPLES = 1024
RING_FRAMES = 8192
IN_RATE = 50000000 / 1024   # 48828.125 Hz（PL 实际音频率）
OUT_RATE = 16000
DST = ("127.0.0.1", int(os.environ.get('RADAR_UDP_PORT', '9000')))
POLL = 0.12                 # 轮询间隔（秒）

class Xsdb:
    def __init__(self):
        self.p = subprocess.Popen(
            [XSDB or _find_xsdb(), "-interactive"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        self._n = 0
        self.cmd("connect")
        self.cmd('targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}')

    def cmd(self, c, timeout=60):
        """发送命令并以唯一行标记同步，保证输出不错位。"""
        self._n += 1
        mark = "__EOS_%d__" % self._n
        self.p.stdin.write(c + "\nputs %s\n" % mark)
        self.p.stdin.flush()
        out, t0 = [], time.time()
        while time.time() - t0 < timeout:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("xsdb exited")
            if mark in line and "puts" not in line:
                break
            out.append(line)
        else:
            raise TimeoutError("xsdb no marker")
        return "".join(out)

    def mrd(self, addr, n):
        """读 n 个 32 位字，返回 list[int]。"""
        out = self.cmd("mrd 0x%08X %d" % (addr, n))
        vals = []
        for line in out.splitlines():
            line = line.strip()
            if ":" in line:
                a, _, v = line.partition(":")
                v = v.strip()
                if len(v) == 8:
                    try: vals.append(int(v, 16))
                    except ValueError: pass
        if len(vals) != n:
            raise RuntimeError("mrd got %d/%d words @0x%08X" % (len(vals), n, addr))
        return vals

def read_header(x):
    w = x.mrd(HDR, 14)
    magic = w[0]
    if magic != 0x53545231:
        raise RuntimeError("no STR1 magic: 0x%08X (固件未在采集？)" % magic)
    return {"total": w[10], "write_pos": w[13], "ring_addr": w[9]}

def read_frames(x, ring_addr, start_idx, count):
    """从环形缓冲读 count 帧（起始为绝对帧号），返回 int16 数组。"""
    pos0 = start_idx % RING_FRAMES
    first = min(count, RING_FRAMES - pos0)
    out = np.empty(count * FRAME_SAMPLES, dtype=np.int16)
    got = 0
    for pos, nfr in ((pos0, first), (0, count - first)):
        if nfr <= 0:
            continue
        words = x.mrd(ring_addr + pos * FRAME_SAMPLES * 2, nfr * FRAME_SAMPLES // 2)
        arr = np.asarray(words, dtype=np.uint32)
        lo = (arr & 0xFFFF).astype(np.int32); hi = (arr >> 16).astype(np.int32)
        lo[lo >= 32768] -= 65536; hi[hi >= 32768] -= 65536
        seg = np.empty(nfr * FRAME_SAMPLES, dtype=np.int16)
        seg[0::2] = lo; seg[1::2] = hi
        out[got:got + seg.size] = seg; got += seg.size
    return out

def main():
    print("JTAG audio bridge: connecting xsdb...", flush=True)
    x = Xsdb()
    h = read_header(x)
    ring = h["ring_addr"]
    print("STR1 alive, ring=0x%08X total=%d" % (ring, h["total"]), flush=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    last_total = h["total"]            # 跳过历史积压，从当前开始
    carry = np.empty(0, dtype=np.float32)  # 重采样残余样本
    seq = 0
    missed = 0
    while True:
        t0 = time.time()
        try:
            h = read_header(x)
        except Exception as e:
            print("hdr read err:", e, flush=True); time.sleep(1); continue
        if h["ring_addr"] != ring or h["total"] < last_total:
            # 固件重启/重烧：环形缓冲搬家，重新同步
            ring = h["ring_addr"]; last_total = h["total"]
            carry = np.empty(0, dtype=np.float32)
            print("resync: ring=0x%08X total=%d" % (ring, last_total), flush=True)
            time.sleep(0.2); continue
        total = h["total"]
        new = total - last_total
        if new > 96:                   # 单次最多追 96 帧（~2s 音频），丢旧保实时
            missed += new - 96
            new = 96
        if new > 0:
            try:
                pcm = read_frames(x, ring, total - new, new)
            except Exception as e:
                print("frame read err:", e, flush=True); time.sleep(0.5); continue
            last_total = total
            f = np.concatenate([carry, pcm.astype(np.float32) / 32768.0])
            # 48828.125 -> 16000：1024/3125 有理重采样
            y = resample_poly(f, 1024, 3125)
            n_out = int(len(y))
            # 保留不足 100ms 的尾巴到下一轮
            n_send = (n_out // 1600) * 1600
            tail_src = int(n_send * 3125 / 1024)
            carry = f[min(tail_src, len(f)):]
            # 波束成形输出电平低（语音 RMS~0.006），数字增益 x6 抬到可用区间，仍远低于削波
            body = (np.clip(y[:n_send] * 6.0, -1, 1) * 32767).astype("<i2")
            for i in range(0, n_send, 1600):
                chunk = body[i:i + 1600]
                sock.sendto(b"AUD3" + struct.pack("<IH", seq, len(chunk)) + chunk.tobytes(), DST)
                seq += 1
        dt = time.time() - t0
        if dt > 0.5:
            print("slow poll %.2fs (new=%d frames, missed=%d)" % (dt, new, missed), flush=True)
        time.sleep(max(0.02, POLL - dt))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
