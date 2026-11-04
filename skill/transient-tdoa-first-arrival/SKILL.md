---
name: transient-tdoa-first-arrival
description: 用脉冲前沿 TDOA 定位拍手、敲击等瞬态声源；包含 7 点平滑、相干度门控、首达沿插值、定点 signed 陷阱与 RTL 逐位回放方法。适用于连续声源 MVDR 正常、但瞬态角度跳变/不准的阵列工程。
---

# 瞬态 TDOA 前沿定位（Transient TDOA First-Arrival）

连续声源用 MVDR 很稳，但拍手只有约 1 ms，而 FFT 窗通常 10 ms 量级：
一帧里混入了大量到达前/后的噪声与反射，单帧空间谱方差大，角度就会跳。
这条技能把“瞬态”单独做成一条时域支路：先检测首达沿，再用通道间时差做
加权最小二乘，最后用相干度决定要不要接受。

## 适用场景

- 8 元（或更多）圆周/环形阵列，采样率、半径已知；
- 拍手、敲击、玻璃破碎等**短促瞬态**，持续时间远小于 FFT 窗；
- 连续声源已经用 MVDR/DAS 跑通，只是瞬态角度不稳定；
- 希望在**不综合、不上板**的情况下先验证 RTL 行为。

不适用于：连续说话/音乐（用 MVDR）、多声源同时瞬态、声源与阵列不同高度、
强混响且首达沿不可辨的场景。

## 使用方法

### 1. 先算几何常量

以 8 元均匀圆阵、半径 `R`、声速 `c`、采样率 `fs` 为例：

```text
k = fs * R / c            # 采样点 / 单位 cos，本项目 ≈ 7.118
max_tdoa = 2 * k          # 阵列直径对应的最大时差（采样点）
```

本项目：`R=50 mm`、`c=343 m/s`、`fs=48.828125 kHz` → `k≈7.118`，
`max_tdoa≈14.24` 采样点，1 个采样点约 8°。换阵列必须重算，不能照抄。

### 2. 生成回放向量

`sim/model/gen_vec.py`、`gen_vec_weak.py`、`gen_vec_arb.py`、`gen_noise.py`
分别生成：

- 0°/90°/180°/270° 四个基准方向；
- 40 dB 中等信噪比、45 dB 弱拍；
- 37°、217° 任意方位；
- 5 s 纯噪声（误触发测试）。

每个向量是“128 bit/采样”的十六进制文本，8 通道按 `ch7…ch0` 排列。
生成脚本用 FFT 做精确分数延迟，并叠加 1–2 条反射，避免“理想模型太干净”。

### 3. RTL 逐位回放

```powershell
# 以 xsim 为例；路径按本机 Vivado 改
xvlog sim\tb\tb_tdoa_replay.v src\pl\rtl\radar_pl_top_bd.v src\pl\rtl\mvdr_axi_top.v ...
xelab tb_tdoa_replay -s elab_replay
xsim elab_replay -runall
```

`tb_tdoa_replay.v` 每 1024 个时钟给一个 `sample_valid`（50 MHz / 1024 =
48.828 kHz），打印：

```text
RESULT idx=... doa=... lowconf=... sw=... A=... B=... ab2=... sd2=... coh_ok=...
```

### 4. 看四个量，不要只看角度

| 信号 | 正常表现 | 异常含义 |
|---|---|---|
| `sw` | 8（或接近 8） | 通道掩码把太多通道剔掉 |
| `A` / `B` | 与角度对应的量级 | 符号/几何反了 |
| `sd2` | 约 `1e5–1e6` | 若到 `1e11`，多半是 signed 被零扩展 |
| `coh_ok` | 1 | 0 表示相干度门控拒绝 |

### 5. 定点 signed 陷阱（本项目真实踩过）

RTL 里如果写：

```verilog
sd2_acc <= sd2_acc + dval * dval;
```

而 `sd2_acc` 是 unsigned、`dval` 是 signed，`dval` 为负时会被**零扩展**成
接近 `2^18` 的大正数，`sd2` 直接爆炸，相干度恒为 0，结果永远 `lowconf=1`。
正确写法：

```verilog
reg signed [39:0] sd2_acc;
sd2_acc <= sd2_acc + ($signed(dval) * $signed(dval));
```

Python/NumPy 模型通常不会复现这个 bug（会自动提升），所以**必须用 RTL 回放
验证**，不能只信 Python。

### 6. 门控与保持

- 触发：快包络超过慢包络一定倍数，且慢包络超过底噪门限；
- 窗口：`[trig−PRE, trig+POST)`，在前 `PRE−12 … PRE+40` 内找局部峰；
- 阈值：`max(peak/4, 4×slow_at_trigger)`；
- 首达沿：窗口内第一次跨过阈值的位置，6 bit 插值提高分辨率；
- 通道掩码：峰值低于 `pmax/8` 的通道剔除；
- 相干度：`coh² = 2(A²+B²)/(sw·Σw·d²)`，阈值 0.75；
- 保持：接受后保持 500 ms，之后回 MVDR。

### 7. 纯噪声误触发测试

```powershell
# 5 s、30 dB 纯噪声，统计 doa_valid
xsim elab_noise -runall
```

预期：`DONE valids=0 lowconf=0`。如果误触发，先加长预热、提高快/慢包络比，
再考虑提高相干度阈值。

## 已验证效果

本项目 2026-11 的 RTL 回放（50 dB、含反射、0.5 s 预热）：

| 场景 | 结果 |
|---|---|
| 0° / 90° / 180° / 270° | 0° / 90° / 180° / −90°，`lowconf=0`，`sw=8`，`coh_ok=1` |
| 37° | 36°（1° 误差） |
| 217° | −140°（=220°，3° 误差） |
| 40 dB，0° | 0° |
| 45 dB 弱拍，90° | 89°（峰值约 800） |
| 5 s 纯噪声，30 dB | 0 次误触发 |

修复 `sd2_acc` signed bug 前，90° 回放返回 `doa=90 lowconf=1`，`sd2≈3.43e11`；
修复后 `sd2≈6.5e5`、`coh_ok=1`。这是“必须做 RTL 回放”的直接证据。

## 失效条件

- 声源与阵列不在同一平面/高度：时差模型不成立，角度会系统性偏；
- 强混响：首达沿被反射淹没，第一次跨阈值的位置不是直达声；
- 拍手离麦太近：削顶/饱和，前沿变平，插值失效；
- 多个瞬态同时发生：通道掩码与加权 LS 会给出“中间角”；
- 采样率、阵列半径、阵元角度变了：`k`、`max_tdoa`、阈值都要重算；
- 连续声源：不要用这条支路，回 MVDR/DAS；
- 只验证了 RTL 回放，不等于上板精度；上板还要看安装偏移、通道一致性、风噪。

## 来源

- 2026-11 拍手角度跳变排查：固定方位拍手，峰值帧稳定、能量衰减后漂移；
- RTL 回放发现 `sd2_acc` 无符号扩展 bug，相干度恒 0，TDOA 从未被顶层采纳；
- 5 点平滑改 7 点、相干度 0.6 改 0.75，用 8 方向 + 弱拍 + 纯噪声回归；
- 相关记录：`report/doa_jump_investigation.md`、`report/design_report.md` 3.8 节、
  `sim/results/tdoa_replay_summary.md`。
