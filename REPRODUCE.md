# 零开始复现说明

本文按“另一台电脑、只有仓库和板卡”来写。每一步都给出预期输出；如果输出对不上，
先看最后一节的排查表。

## 0. 你需要什么

### 硬件

- 正点原子「领航者」ZYNQ-7020 开发板（`xc7z020clg400-2`）；
- 8 × INMP441 MEMS 麦克风，均匀圆阵，半径 50 mm；
- USB-JTAG、USB-UART、网线、5 V 电源；
- 一台 Windows 10/11 PC。

### 软件

| 软件 | 版本 | 用途 |
|---|---|---|
| Vivado | 2026.1 | PL 综合、实现、bitstream |
| Vitis | 2026.1 | PS 裸机 ELF |
| Python | 3.10+ | PC 接收、离线分析 |
| Python 包 | `numpy`、`scipy`、`matplotlib`、`pandas` | 仿真与绘图（`scipy` 供 `sim/model/sim_tdoa_realistic.py` 生成回放向量） |
| PC 依赖 | 见 [`src/pc/requirements.txt`](src/pc/requirements.txt) | 上位机：`torch`、`modelscope`、`pywebview` 等（CAM++ 模型首次运行自动下载） |
| xsdb | Vivado / Vivado Lab 自带 | 烧录与 JTAG 音频桥；不在 PATH 时设 `XSDB` 环境变量 |

## 1. 取得仓库

```powershell
git clone https://github.com/3245885750-lang/-ZYNQ-.git
cd -- -ZYNQ-
```

没有 git 时，用 GitHub Desktop：File → Clone repository → 输入上面的 URL。

预期：根目录能看到 `README.md`、`SUBMISSION.md`、`src/`、`sim/`、`build/`、`board/`、`data/`、`skill/`、`report/`。

## 2. 重建 PL 工程

### 2.1 开发版（单板验证，带 TDOA）

在 Vivado 2026.1 的 Tcl Console：

```tcl
cd <repo>/build
source create_project.tcl
```

脚本会：

1. 新建 `build/vivado/radar_pl_dev/radar_pl_dev.xpr`；
2. 加入 `src/pl/rtl/*.v` 和 `*.mem`；
3. 加入 `src/pl/ip_repo/radar_pl_audio/src/fft_512/fft_512.xci`；
4. 加入 `src/pl/constraints/*.xdc`；
5. 把顶层设为 `radar_pl_bd_verify_top`。

预期：最后打印 `PROJECT_READY: .../radar_pl_dev.xpr`。

然后在 GUI 里：

```text
Run Synthesis → Run Implementation → Generate Bitstream
```

完成后导出报告：

```tcl
cd <repo>/build
source export_reports.tcl
```

预期：`build/reports/` 下出现 `post_route_utilization.rpt`、`timing_summary.rpt`、`power.rpt` 等。

### 2.2 完整系统（BD + PS，发布版）

完整系统不是用 `create_project.tcl` 建的，而是：

1. 用 Vivado 打开 `src/pl/integration/radar_system.bd`；
2. IP Repository 指向 `src/pl/ip_repo`；
3. 若 IP 版本有更新，先按 [`build/update_ip_and_bd.md`](build/update_ip_and_bd.md) 重新打包 `radar_pl_audio`；
4. Validate Design → Generate Output Products → Create HDL Wrapper；
5. 综合 → 实现 → 生成 bitstream；
6. Export Hardware（XSA）给 Vitis。

> 如果只是验证算法，用 2.1 的单板顶层更快；如果要交“完整上板工程”，走 2.2。

## 3. 编译 PS 固件

```powershell
python .\src\ps\build.py --gcc-bin "D:\Workspace\vivado2026.1\2026.1\Vitis\gnu\aarch32\nt\gcc-arm-none-eabi\bin"
```

预期：输出 `ARM_BUILD_PASS`，ELF 在 `src/ps/build/`。

> BSP 头文件与库已随仓库提供（`src/ps/deps/`），不依赖作者机器的工作目录。
> 如果更换了 AXI 寄存器映射（例如新增 `0x50/0x54`），需要同步修改 PS 源码后重编。

## 4. 上板

### 4.1 下载

```powershell
cd board
.\download.cmd
```

或按 [`board/download_steps.md`](board/download_steps.md) 用 XSDB 手动下载。

预期：串口打印 `DOWNLOAD_OK`；LED0 心跳；LED1 在检测到声源时亮。

### 4.2 网络

- 板卡：`192.168.1.10/24`
- PC：`192.168.1.100/24`
- UDP：`9000`

### 4.3 PC 上位机

先装依赖（一次性）：

```powershell
cd src\pc
pip install -r requirements.txt
```

启动接收服务与网页：

```powershell
python pc_rx\pc\web_receiver.py
python pc_rx\pc\jtag_audio_bridge.py   # 声纹需要；不开则声纹面板显示“未识别到人声”
```

浏览器打开 <http://127.0.0.1:8768>。也可以进入 `src\pc` 后运行 `python launcher.py`
启动全屏窗口。

预期：连接状态 2 秒内变为“已接收板卡数据”；拍手 0.5 秒内显示“拍手”；
方位雷达指针跟随声源；频谱面板出现 0–8000 Hz 曲线；声纹需先录入。
详细步骤与常见问题见 [`src/pc/docs/reproduce.md`](src/pc/docs/reproduce.md)，
实测数据见 [`src/pc/verification/results.md`](src/pc/verification/results.md)。

## 5. 验证 TDOA 支路

### 5.1 离线（不需要板卡）

```powershell
cd sim\model
python param_check.py
```

预期：RTL 参数与回放模型常量一致。

按 [`sim/results/tdoa_replay_summary.md`](sim/results/tdoa_replay_summary.md) 的描述，
用 `sim/tb/tb_tdoa_replay.v` 回放 8 方向、弱拍和纯噪声向量。预期：

- 0°/90°/180°/270° → 0°/90°/180°/−90°；
- 37° → 36°，217° → −140°（220°）；
- 45 dB 弱拍 90° → 89°；
- 5 s 纯噪声 → 0 次误触发。

### 5.2 上板

按 [`data/tdoa_board_summary.md`](data/tdoa_board_summary.md) 的表头采集：

- 8 个方位 × 每方位 5 次拍手；
- 37°、217° 各 5 次；
- 弱拍 5 次；
- 纯噪声 30 s。

把结果填进 `data/tdoa_board_YYYYMMDD.csv` 和汇总表。

## 6. 常见问题

| 现象 | 优先检查 |
|---|---|
| Vivado 报找不到 `fft_512` | `update_ip_catalog -rebuild`；确认 `src/pl/ip_repo/.../fft_512.xci` 存在 |
| 综合报 `steer_re.mem` 找不到 | 确认 `create_project.tcl` 已把 `src/pl/rtl/*.mem` 加入工程 |
| 综合长时间无输出 | 按 [`skill/vivado-synth-hang/SKILL.md`](skill/vivado-synth-hang/SKILL.md) 取证，不要直接删工程 |
| 下载成功但寄存器读不到 | 检查 BD 复位极性、AXI 地址、PS 侧 `0x43C00000` 基址 |
| 网页收不到 UDP | 防火墙放行 9000；确认 PC 与板卡同网段；不要同时开两个接收脚本 |
| 网页有角度无频谱 | PS 固件是否支持 `kind=spectrum`（协议 v3）；旧固件只发 doa/classification |
| 声纹面板一直“未识别到人声” | `jtag_audio_bridge.py` 是否在跑；`xsdb` 是否可连；`STR1_HDR` 是否匹配固件 |
| 拍手角度不更新 | 确认新 bit 已包含 TDOA；检查 `0x54` 的 bit0/bit1/bit2 |
| 角度差 180° | 检查安装偏移；代码输出已加 +180°，物理 0° 在 ch0 对面 |

## 7. 复现边界

- 本仓库的 `board/payload` 是 2026-10-28 的基线版本；TDOA 版需要按 2.2 重打包 IP/BD、重编 bit/ELF。
- 上板实测数据需要真实板卡；仓库只提供模板与离线回放结果，不伪造板上数据。
- 识别准确率、端到端时延等 PS 侧指标以队友 B 的实测记录为准。
