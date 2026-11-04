# src —— 源码

```
src/
├── pl/    PL（Verilog、约束、IP 仓库、Block Design）
├── ps/    PS（standalone ARM 固件、模型、构建脚本、协议测试）
└── pc/    PC 上位机（UDP/SSE 服务、网页大屏、JTAG 音频桥、声纹）
```

## pl

| 子目录 | 内容 |
|---|---|
| `rtl/` | 开发版 RTL：I2S 采集、FFT 前级、8 bin 协方差、求逆、MVDR 扫角、DAS、波束音频、输出级 |
| `ip_repo/radar_pl_audio/` | 与发布 bitstream 配套的打包 IP（基线，不含输出级优化） |
| `integration/radar_system.bd` | PS7 + AXI 互连 + DMA + 自定义 IP |
| `constraints/` | 引脚、时序、交付版本相对基线的改动 diff |

两套 RTL 的区别见根目录 README 第 3 节。构建方式见 `build/README.md`。

## ps

| 子目录 | 内容 |
|---|---|
| `src/` | 应用源码（lwIP/UDP、组包、MLP 推理） |
| `ps/` | 与 PS 配置相关的源文件 |
| `model/` | MLP 权重与归一化参数 |
| `deps/` | 随仓库提供的 BSP 头文件与库（11.4 MB） |
| `pc/` | PS 侧使用的 PC 辅助文档与脚本 |
| `tests/` | 原生模型校验、网页接收校验、板包校验、线束测试 |
| `build.py` | 独立 ARM 交叉编译脚本（不依赖 Vitis IDE 工程） |

编译：

```powershell
python .\src\ps\build.py --gcc-bin "D:\Workspace\vivado2026.1\2026.1\Vitis\gnu\aarch32\nt\gcc-arm-none-eabi\bin"
```

成功输出 `ARM_BUILD_PASS`。

## pc

PC 上位机的完整说明见 [`pc/README.md`](pc/README.md)，这里只列入口。

| 路径 | 作用 |
|---|---|
| `pc/pc_rx/pc/web_receiver.py` | UDP 9000 接收 → SSE 8768；声纹线程与录入 API |
| `pc/pc_rx/pc/radar_protocol.py` | 板端 JSON v3 解码与状态机（doa / classification / spectrum） |
| `pc/pc_rx/pc/jtag_audio_bridge.py` | JTAG 读 DDR 环形缓冲 → 重采样 16 kHz → `AUD3` 注入 |
| `pc/acoustic-radar.html` | 单文件网页大屏（方位 / 类别 / 频谱 / 声纹） |
| `pc/voiceprint/` | CAM++ 声纹模型封装与声纹库 |
| `pc/launcher.py` | 一键启动（服务 + 音频桥 + 全屏窗口） |
| `pc/verification/results.md` | PC 端实测数据 |

```powershell
cd src\pc
pip install -r requirements.txt
python pc_rx\pc\web_receiver.py
python pc_rx\pc\jtag_audio_bridge.py
```

浏览器打开 <http://127.0.0.1:8768>。烧录与网络配置见
[`pc/docs/reproduce.md`](pc/docs/reproduce.md)。
