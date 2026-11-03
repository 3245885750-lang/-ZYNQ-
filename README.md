# 基于ZYNQ的声学雷达

基于 ZYNQ 的声学雷达是一套基于 AMD ZYNQ-7020 与 8 元环形麦克风阵列的声源定位、声源分类和声纹识别系统。项目把 FPGA 宽带 MVDR 测向与波束成形链路、ARM 嵌入式 AI 推理、频谱计算与 PC 端 360° 雷达可视化整合在同一套工程中，适用于智能安防预警与定向拾音演示。

> 本仓库面向全国大学生嵌入式芯片与系统设计竞赛（AMD 赛道）开源提交。

---

## 功能概述
- 声源定位：8麦克风阵列，宽带融合MVDR算法，输出360°方位角。精度±1°~2°，更新率30Hz，PC端360°雷达图同步显示。
- 声音分类：ARM端运行轻量级MLP网络。识别拍手、说话、鸣笛等8类日常声音，结合绝对能量门控过滤底噪。
- 声纹识别： 系统支持提前录入人员语音建立声纹库，在运行中实时比对当前说话人是否为已注册人员。
- 结果联合：PC端将方位与类别绑定，界面实时输出方位角度与声音类别，若声音类别为说话，则识别说话人信息是否为声纹库中人员。
- 频谱显示：PL端进行512点FFT，PC端同步显示输入声源的波束增强后的实时频谱图。

### 硬件

- 开发板：正点原子「领航者」ZYNQ-7020，器件 `xc7z020clg400-2`
- 麦克风：8 × INMP441（I2S，单声道，共用 SCK/WS，8 根 SD）
- 阵列：均匀圆阵，半径 `R = 50 mm`，相邻阵元间距 `38.3 mm`
- 网络：板卡 `192.168.1.10`，PC `192.168.1.100`，UDP 端口 `9000`

### 主要参数

| 项 | 数值 |
|---|---|
| 系统时钟 | 50 MHz（`create_clock -period 20.000`） |
| 采样率 | 48 828.125 Hz |
| FFT | 512 点，矩形窗 |
| 分析频点（bin） | 5 / 10 / 15 / 20 / 25 / 31 / 37 / 43 |
| 对应频率 | 476.9 / 953.7 / 1430.5 / 1907.4 / 2384.3 / 2956.6 / 3528.8 / 4100.8 Hz |
| 空间混叠上限 | 4481 Hz（最高 bin 4100.8 Hz，不混叠） |
| 测向 | 361 个角度，1° 步进，`P(θ)=1/(aᴴR⁻¹a)` |
| 协方差 | 遗忘因子 EMA，`acc ← acc − (acc>>>S) + m`，静止 S=7、运动 S=3 |
| DOA 更新率 | 21 ms / 帧（≈47.7 Hz，K=2 快拍） |
| 波束形成 | 时域 DAS，分数延迟（`das_taps_int.mem` / `das_taps_frac.mem`） |
| 分类 | PS 端 MLP 144→64→32→9，输入 2 s 窗口，目标步进 100 ms |
| 拒识 | top1 ≥ 0.8 且领先第二名 ≥ 0.05，否则输出「不确定」 |

### 资源占用（归档实现 `radar_pl_top`，Vivado 2026.1）

| 资源 | 用量 | 占比 |
|---|---|---|
| LUT | 29 130 | 54.8 % |
| FF | 37 545 | 35.3 % |
| BRAM | 60.5 | 43.2 % |
| DSP | 102 | 46.4 % |
| IOB | 15 | 12 % |

---

## 2. 信号链

```
8× INMP441 ──I2S──> i2s_rx_8ch ──> i2s_fft8_axis ──> FFT 512 (AXI-Stream)
                                                         │
                                             bin_extract_8ch（抽 8 个 bin）
                                                         │
                                             cov_accum_8x8（EMA + 可选对角加载重建）
                                                         │
                                             cov_to_q16 ──> mat_inv_8x8
                                                         │
                                             mvdr_sweep（361 角度 × 8 bin 非相干累加）
                                                         │
                                             GATE → 显示端限速 SLEW → doa_deg
                                                         │
                                    ┌────────────────────┴───────────────────┐
                                    │                                        │
                              AXI-Lite 寄存器                       时域 DAS 波束形成
                              (PS 轮询 DOA/PWR)                    (8 路 → 单路音频)
                                                                           │
                                                                    AXI-Stream → PS
                                                                           │
                                                              MLP 分类 ──> UDP 9000
```

本设计是 PL + standalone ARM 裸机 + lwIP 的部署方式。

---

## 3. 目录结构

```c
| `README.md` | `README.md` | 项目简介 + 复现步骤 |
| `src/` | `src/pl/`、`src/ps/`、`src/pc/` | PL RTL 与约束、PS 固件、PC 接收脚本 |
| `sim/` | `sim/tb/`、`sim/model/`、`sim/results/` | 仿真 testbench、逐位回放模型、结果图 |
| `build/` | `build/` | 建工程/打包/校验脚本 + 资源与时序报告说明 |
| `board/` | `board/` | 上板运行脚本、bit/ELF、下载步骤 |
| `data/` | `data/` | 实测 CSV、测试音频说明、参考结果 |
| `skill/` | `skill/` | 技能包（见 `skill/README.md`） |
| `report/` | `report/` | 设计报告、接口文档、排障记录、大模型协作记录 |
```

`src/pl/` 下有两套 RTL，用途不同：

| 路径 | 说明 |
|---|---|
| `src/pl/rtl/` | **最新开发版** RTL，包含输出端的 GATE / SLEW / 瞬态窗口等优化 |
| `src/pl/ip_repo/radar_pl_audio/` | **与已发布 bitstream、PS 固件配套**的 IP 快照（基线，不含输出端优化） |
| `src/pl/integration/radar_system.bd` | Block Design（PS + DMA + AXI 互连 + 自定义 IP） |
| `src/pl/constraints/` | 引脚与时序约束 |

如果只关心「能跑起来的完整系统」，用 `ip_repo` + `radar_system.bd`；
如果关心「测向输出怎么做得不跳变」，看 `src/pl/rtl/` 和 `report/doa_jump_investigation.md`。

---

## 4. 复现步骤

### 4.1 只看 PC 端（最快）

```bash
cd src/pc
python receive_results.py --port 9000 --log received.jsonl
```

需要板卡在线。没有板卡时，可以先用 `receive_results.py` 录一段，再用
`replay_saved.py` 回放（仓库不附带 JSONL 样例，避免伪造数据）：

```bash
python replay_saved.py --ip 127.0.0.1 --file received.jsonl
```

### 4.2 重建 PL 工程（Vivado 2026.1）

```tcl
# 在 Vivado Tcl Console 中
cd build
source create_project.tcl
```

或手工：

1. 新建工程，器件 `xc7z020clg400-2`；
2. 把 `src/pl/ip_repo/radar_pl_audio` 加入 IP Repository；
3. 打开 `src/pl/integration/radar_system.bd` 重建 Block Design；
4. 加入 `src/pl/constraints/*.xdc`；
5. 综合 → 实现 → 生成 bitstream。

> 完整 Vivado 工程（含 FFT IP 生成结果）体积较大，作为 Release 附件提供，
> 见仓库 Releases 页面的 `pl_vivado_project`。仓库里只放可复现的源码与脚本。

### 4.3 编译 PS 固件（Vitis 2026.1）

```powershell
python .\src\ps\build.py --gcc-bin "D:\Workspace\vivado2026.1\2026.1\Vitis\gnu\aarch32\nt\gcc-arm-none-eabi\bin"
```

成功标志：输出 `ARM_BUILD_PASS`，产物在 `src/ps/build/`。
BSP 头文件与库已随仓库提供（`src/ps/deps/`），不依赖其他机器的工作目录。

### 4.4 上板

1. 用 JTAG 下载 `board/payload/radar.bit` + `board/payload/radar.elf`，步骤见 `board/download_steps.md`；
2. 网线直连，PC 设 `192.168.1.100/24`；
3. PC 端启动接收脚本，UDP 9000。

> `radar.bit` 与 `radar.elf` 必须成套使用（哈希见 `board/manifest.json`）。
> 重新编译 ELF 后不要直接覆盖：下载脚本会校验哈希，且诊断变量地址写在 `download.tcl` 里。

---

## 5. 验证方法

| 层次 | 手段 | 位置 |
|---|---|---|
| 模块级 | Verilog testbench（FFT、协方差、求逆、MVDR 扫角、I2S） | `sim/tb/` |
| 输出级 | Python 逐位回放 RTL 的 GATE/SLEW/瞬态逻辑，A/B 对比 | `sim/model/sim_clap_smooth.py` 等 |
| 参数一致性 | 从 RTL 抠参数与回放模型常量比对 | `sim/model/param_check.py` |
| 系统级 | 板上实测 CSV（定点、圆周、拍手） | `data/` |
| PS | UDP 协议与网页接收校验脚本 | `src/ps/tests/` |

回放模型与 RTL 采用相同的整数语义（含 4 bit 计数器的饱和/回绕），
修改 RTL 参数后先跑 `param_check.py`，避免脚本与 RTL 悄悄跑偏。

---

## 6. 已知边界

- 部署 bit 使用基线 RTL；`src/pl/rtl/` 的输出端优化（GATE/SLEW/瞬态窗口）尚未并入发布 bitstream。
- 8 路复数谱的完整网传未实现；当前只传 DOA、能量与分类结果。
- 分类模型为 PS 上的 MLP（非 CNN/DPU），候选集测试准确率约 67.6%，不代表真实环境误识别率。
- 拍手等瞬态声源的测向仍有单帧方差：一次拍手约 1 ms，而 FFT 窗 10.7 ms，
  不同次拍手的最强帧估计可能相差几十度。这是物理与帧对齐问题，显示端平滑不能消除。
- 未做通道幅相校准，测向精度受麦克风一致性限制。

---

## 7. 许可

代码用于竞赛提交与学习交流。第三方依赖（Xilinx BSP、lwIP）遵循其原始许可。
