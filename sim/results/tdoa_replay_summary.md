# 瞬态 TDOA RTL 回放结果

本文件记录 `transient_tdoa` 在真实 RTL 上的逐位回放结果（不是 Python 理想模型，
也不是上板数据）。回放向量由 `sim/model/gen_vec*.py` 生成，输入是 8 通道
16 bit PCM，采样率 48.828125 kHz，含 0.5 s 预热、1–2 条反射、通道增益/时延失配。

## 1. 复现命令

```powershell
# 在仓库根目录执行
python sim\model\gen_vec.py
python sim\model\gen_vec_weak.py
python sim\model\gen_vec_arb.py
python sim\model\gen_noise.py

# 每次回放前把目标向量复制成 current.hex
Copy-Item sim\vec\vec_000.hex sim\vec\current.hex

xvlog sim\tb\tb_tdoa_replay.v src\pl\rtl\radar_pl_top_bd.v
xelab tb_tdoa_replay -s elab_replay
xsim elab_replay -runall
```

预期打印：

```text
RESULT idx=... doa=0 lowconf=0 busy=... sw=8 A=... B=... ab2=... sd2=... coh_ok=1
DONE results=1
```

纯噪声：

```powershell
xvlog sim\tb\tb_false_trig.v src\pl\rtl\radar_pl_top_bd.v
xelab tb_false_trig -s elab_noise
xsim elab_noise -runall
```

预期：`DONE valids=0 lowconf=0`。

## 2. 结果

| 向量 | 真实角度 | RTL 输出 | 误差 | lowconf | sw | coh_ok |
|---|---:|---:|---:|---:|---:|---:|
| `vec_000.hex` | 0° | 0° | 0° | 0 | 8 | 1 |
| `vec_090.hex` | 90° | 90° | 0° | 0 | 8 | 1 |
| `vec_180.hex` | 180° | 180° | 0° | 0 | 8 | 1 |
| `vec_270.hex` | 270° | −90°（=270°） | 0° | 0 | 8 | 1 |
| `vec_arb_037.hex` | 37° | 36° | 1° | 0 | 8 | 1 |
| `vec_arb_217.hex` | 217° | −140°（=220°） | 3° | 0 | 8 | 1 |
| `snr40_000.hex` | 0° | 0° | 0° | 0 | 8 | 1 |
| `weak45_090.hex` | 90° | 89° | 1° | 0 | 8 | 1 |
| `noise30_5s.hex` | — | 无触发 | — | — | — | — |

> 输出角度已含 +180° 安装偏移；270° 显示为 −90°，是 signed 9 bit 的等价表示。

## 3. 这次回放抓到的真实 bug

修复前，`vec_090.hex` 返回：

```text
doa=90 lowconf=1 sw=8 A=... B=... ab2=... sd2=343069039807 coh_ok=0
```

`A`/`B` 都正确，但 `sd2` 比预期大约 5×10^5 倍。根因是 RTL 里：

```verilog
sd2_acc <= sd2_acc + dval * dval;   // dval 为负时被零扩展
```

`sd2_acc` 是 unsigned，`dval` 是 signed；负的 `dval` 被当成接近 `2^18` 的
大正数，相干度恒为 0，TDOA 永远 `lowconf=1`，顶层因此从未采纳 TDOA 结果。
改成：

```verilog
reg signed [39:0] sd2_acc;
sd2_acc <= sd2_acc + ($signed(dval) * $signed(dval));
```

后 `sd2≈650000`、`coh_ok=1`、`lowconf=0`。

Python/NumPy 模型不会复现这个 bug（自动提升为有符号），所以只信 Python 模型
会漏掉它。这是“RTL 逐位回放”技能存在的直接理由。

## 4. 2026-11-04 复跑记录

在仓库根目录用 Vivado 2026.1 xsim 复跑，确认表 2 的结论可复现：

```text
# vec_090.hex
RESULT idx=27443 doa=90 lowconf=0 busy=1 sw=8 A=-6 B=-1630 ab2=2656936 sd2=667342 coh_ok=1
DONE results=1

# vec_arb_037.hex
RESULT idx=27444 doa=36 lowconf=0 busy=1 sw=8 A=-1292 B=-954 ab2=2579380 sd2=649505 coh_ok=1
DONE results=1

# noise30_5s.hex
DONE valids=0 lowconf=0
```

`sd2` 在 6.5×10⁵ 量级，与第 3 节修复后的预期一致；90° 与 37° 的角度、`sw=8`、
`coh_ok=1` 均与表 2 相同。

## 5. 边界

- 回放是 RTL 行为验证，不是上板精度；上板还要看安装偏移、通道一致性、风噪；
- 向量含 1–2 条反射，但不是完整房间脉冲响应；强混响下首达沿可能不可辨；
- 5 s 纯噪声只覆盖 30 dB 这一档；更低信噪比需要重新跑；
- 换阵列半径/采样率/阵元数后，`k`、窗口、阈值都要重算，不能直接套结果。
