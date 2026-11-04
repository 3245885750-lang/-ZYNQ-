# PC 上位机从零复现步骤

本文从“另一台 Windows 电脑 + 已烧好固件的板卡”开始。PL/PS 的重建见仓库根目录
[`REPRODUCE.md`](../../../REPRODUCE.md)。

## 1. 环境准备（一次性）

1. 安装 Python 3.9+（64 位，勾选 Add to PATH）；
2. 安装依赖：

   ```powershell
   cd src\pc
   pip install -r requirements.txt
   ```

   首次运行声纹时会联网下载 CAM++ 模型（约 100 MB）；离线演示需提前下载缓存。
3. 安装 Xilinx Vivado 或 Vivado Lab（提供 `xsdb`，用于烧录与 JTAG 音频桥）。
   若 `xsdb` 不在 PATH：

   ```powershell
   set XSDB=D:\Xilinx\Vitis\bin\xsdb.bat
   ```

4. 本机有线网卡设为 `192.168.1.100/24`，与
   [`pc_rx/network_config.json`](../pc_rx/network_config.json) 中的 `board_ip`
   `192.168.1.10` 同网段；
5. Windows 防火墙放行 UDP 9000（收板卡数据）与 TCP 8768（网页 / SSE）。

## 2. 烧录板卡（每次断电后需重烧，volatile JTAG）

在仓库根目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\board\download.ps1
```

看到 `DOWNLOAD_OK` 即成功。烧录细节见 [`board/README.md`](../../../board/README.md)。

## 3. 启动

**推荐**：

```powershell
cd src\pc
python launcher.py
```

`launcher.py` 会拉起接收服务、JTAG 音频桥和全屏窗口；后台仍使用系统 Python。
本提交未附带预编译 exe，如需单文件启动器按 [`../README.md`](../README.md) §7 打包。

**手动**：

```powershell
cd src\pc
python pc_rx\pc\web_receiver.py
python pc_rx\pc\jtag_audio_bridge.py
```

浏览器打开 <http://127.0.0.1:8768>。预期：

- 顶部连接状态在 2 秒内变为“已接收板卡数据”；
- 拍手 0.5 秒内类别面板显示“拍手”；
- 方位雷达指针随声源移动；
- 频谱面板出现 0–8000 Hz 的实时曲线。

## 4. 声纹录入（换环境 / 换人后重录）

网页声纹面板 → 录入 → 输入名字 → 距阵列 0.5~1 米、较大音量连续说 **3 段 × 4 秒**。
程序只在检测到人声时采集，最长等待 60 秒；成功后写入
`voiceprint/voiceprint_db_campplus.npz`。

验证方法：同一人再说话应稳定显示其名字；库外人员应显示“无该人员”；
拍手等非人声应显示“未识别到人声”。打分日志在 `%TEMP%\vp_scores.log`。

## 5. 验证

按 [`verification/results.md`](../verification/results.md) 中各项方法复测即可。
常用日志：

- 原始 UDP 报文：`src/pc/pc_rx/pc/received.jsonl`（每次启动追加）；
- 声纹打分：`%TEMP%\vp_scores.log`。

## 6. 常见问题

| 现象 | 优先检查 |
|---|---|
| 网页一直“等待板卡数据” | 板卡是否已烧录、网线/网段、防火墙 UDP 9000、`board_ip` 是否写对 |
| 有角度无频谱 | PS 固件版本是否支持 `kind=spectrum`（协议 v3）；旧固件只发 doa/classification |
| 声纹面板“未识别到人声” | `jtag_audio_bridge.py` 是否在跑；`xsdb` 是否能连上；固件 `STR1` 邮箱地址 |
| 音频桥报 `no STR1 magic` | 固件未在采集，或 `STR1_HDR` 与固件版本不匹配 |
| 声纹模型下载失败 | 检查网络；或预置 ModelScope 缓存后离线运行 |
| 录入一直超时 | 说话音量太小 / 距阵列太远；确认频谱与类别面板有反应 |
