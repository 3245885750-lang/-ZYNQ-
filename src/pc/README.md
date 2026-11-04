# PC 上位机（声学雷达网页大屏）

本目录是系统的 PC 端：接收板卡经 UDP 9000 发来的 JSON v3 结果与 `AUD3` 音频包，
通过 SSE 推给浏览器，渲染 **360° 方位雷达 / 声音类别 / 实时频谱 / 声纹识别** 四个面板。
PC 不做方位或分类的替代计算；声纹识别是 PC 侧真实的 CAM++ 推理，不是模拟数据。

配套的板端协议见 [`report/pl_ps_interface.md`](../../report/pl_ps_interface.md)，
实测记录见 [`verification/results.md`](verification/results.md)，
零开始步骤见 [`docs/reproduce.md`](docs/reproduce.md)。

## 1. 目录结构

```
src/pc/
├── README.md                       # 本文件
├── requirements.txt                # Python 依赖
├── acoustic-radar.html             # 网页大屏（单文件，四面板，SSE 实时刷新）
├── launcher.py                     # 一键启动：接收服务 + 音频桥 + 全屏窗口
├── pc_rx/
│   ├── network_config.json         # 板卡 IP / UDP 端口 / 协议版本
│   └── pc/
│       ├── web_receiver.py         # UDP 9000 收包 → SSE 8768；声纹线程、录入 API
│       ├── radar_protocol.py       # 板端 JSON v3 解码与状态机（doa/classification/spectrum）
│       └── jtag_audio_bridge.py    # JTAG 读 DDR 环形缓冲(48.8k) → 重采样 16k → AUD3
├── voiceprint/
│   ├── campplus_sv.py              # CAM++ 中文预训练声纹模型封装（192 维嵌入 + 1:N 比对）
│   ├── feature.py                  # 早期 MFCC 自训方案的特征提取（部署链路不导入，见 §6）
│   └── voiceprint_db_campplus.npz  # 声纹库（示例两人；录入后原地更新）
├── docs/reproduce.md                 # 从零复现
└── verification/results.md         # 功能正确性实测数据
```

## 2. 运行环境

- Windows 10/11，Python 3.9+（64 位）；
- `pip install -r requirements.txt`（首次联网自动下载 CAM++ 模型约 100 MB）；
- JTAG 音频桥与烧录需要 Xilinx `xsdb`（Vivado 或 Vivado Lab 自带）；
- PC 有线网卡设为 `192.168.1.100/24`，与板卡 `192.168.1.10` 同网段。

## 3. 运行方式

**方式一（推荐，全屏窗口）**：

```powershell
cd src\pc
python launcher.py
```

`launcher.py` 自动拉起接收服务、JTAG 音频桥和全屏窗口，后台服务使用系统 Python，
因此 Python 依赖必须先装好。本提交未附带预编译 exe；如需单文件启动器，按 §7 自行打包。

**方式二（源码，浏览器查看）**：

```powershell
cd src\pc
python pc_rx\pc\web_receiver.py
python pc_rx\pc\jtag_audio_bridge.py   # 需要 JTAG 在线；不开则没有声纹音频
```

浏览器打开 <http://127.0.0.1:8768>。

### 数据通路

```text
板卡 PS --UDP 9000 JSON v3(doa / classification / spectrum)--> web_receiver
JTAG  -> DDR 环形缓冲 48.8 kHz --xsdb--> jtag_audio_bridge --AUD3--> web_receiver
web_receiver --SSE 8768--> 浏览器四面板
```

`web_receiver.py` 只接受 `network_config.json` 中 `board_ip` 与本机 `127.0.0.1` 的来源：
前者是板卡网口直发，后者是 JTAG 音频桥在本机注入的 `AUD3` 包。

## 4. 配置项

| 位置 | 项 | 说明 |
|---|---|---|
| `pc_rx/network_config.json` | `board_ip` / `udp_port` | 板卡地址与 UDP 端口；换网段时只改这里 |
| 环境变量 `VP_DIR` | 声纹模块目录 | 默认 `src/pc/voiceprint`，`launcher.py` 会自动设置 |
| 环境变量 `XSDB` | xsdb 路径 | 不在 PATH 时用；例如 `set XSDB=D:\Xilinx\Vitis\bin\xsdb.bat` |
| 环境变量 `STR1_HDR` | 固件邮箱地址 | 默认 `0x0023d780`，**随 PS 固件版本变化**，换固件必须同步 |
| 环境变量 `RADAR_UDP_PORT` | 音频桥目的端口 | 默认 9000，需与 `udp_port` 一致 |

命令行参数：`web_receiver.py --port 9000 --http-port 8768 --peer 192.168.1.10 --log received.jsonl`。

## 5. 声纹录入

网页声纹面板 → 录入 → 输入名字 → 距阵列 0.5~1 m、较大音量连续说 **3 段 × 4 秒**。
程序只在有人声时采集，最长等待 60 秒；成功后写入 `voiceprint/voiceprint_db_campplus.npz`。
相似度阈值 0.35（`web_receiver.py` 中设置），实测本人 0.49–0.69、他人 0.03–0.21。

> 录入会改写仓库里的 `.npz`。提交前若要恢复示例库，用版本库中的原文件覆盖即可。

## 6. 已知边界

- **本提交未附带预编译 exe**：原 20 MB 单文件启动器是队友的旧构建，其中的声纹目录名
  与冻结路径假设已不适用于本仓库。`launcher.py` 已修正 frozen 模式（用 `sys.executable`
  定位 `pc_rx/` 与 `voiceprint/`），按 §7 可在本机重新打包。
- **exe 不是免安装包**：它只是 `launcher.py` 的单文件封装，后台服务仍调用系统 Python；
  换机器仍需 `pip install -r requirements.txt`。
- **`/simple` 页面未随包提供**：`web_receiver.py` 保留了该路由，文件不存在时返回 404，
  不影响 `/` 主页面。
- **`feature.py` 不参与部署链路**：它是早期 MFCC + 自训 CNN 方案的特征提取代码，
  依赖未随包提供的 `configs` 模块与 `torchaudio`；当前声纹走 `campplus_sv.py` 的
  Fbank + CAM++ 预训练模型，不导入 `feature.py`。
- **音频桥依赖固件邮箱**：`STR1` 头地址与环形缓冲布局由 PS 固件决定；换固件后
  若 `no STR1 magic`，先核对 `STR1_HDR`，再确认固件确实在采集。
- **声纹需要阵列音频**：不开 `jtag_audio_bridge.py` 时，声纹面板会因音频断流显示
  “未识别到人声”，这是设计行为，不是识别失败。
- **网口防火墙**：Windows 防火墙需放行 UDP 9000 与 TCP 8768，否则网页显示“等待板卡数据”。

## 7. 可复现构建

```powershell
cd src\pc
pip install pyinstaller
pyinstaller --noconsole --onefile --name acoustic-radar-dashboard launcher.py
```

产物在 `dist/acoustic-radar-dashboard.exe`，放到 `src/pc/` 根目录即可（exe 按自身所在目录定位
`pc_rx/` 与 `voiceprint/`）。
