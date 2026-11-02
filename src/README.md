# src —— 源码

```
src/
├── pl/    PL（Verilog、约束、IP 仓库、Block Design）
├── ps/    PS（standalone ARM 固件、模型、构建脚本、协议测试）
└── pc/    PC（UDP 接收、回放、网页接入）
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

| 文件 | 作用 |
|---|---|
| `receive_results.py` | UDP 9000 接收，写 JSONL |
| `radar_protocol.py` | 协议 v3 解析（DOA / 分类消息） |
| `replay_saved.py` | 回放已保存的记录 |
| `web_receiver.py` | 网页接收端 |
| `existing_page_adapter.py` | 把 v3 解析接入已有页面 |

```bash
cd src/pc
python receive_results.py --port 9000 --log received.jsonl
python replay_saved.py --ip 127.0.0.1 --file received.jsonl --interval 0.5
```
