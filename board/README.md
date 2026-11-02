# board —— 上板运行包

本目录是**已匹配**的一组板卡运行文件，只能成套使用：

| 文件 | 说明 |
|---|---|
| `payload/radar.bit` | PL 位流 |
| `payload/radar.elf` | PS 固件（lwIP + MLP 九分类 + UDP） |
| `payload/ps7_init.tcl` | DDR / MIO 初始化 |
| `download.tcl` | XSDB 下载脚本（加载 PL、初始化 PS、下载 ELF、注入启动标识） |
| `download.ps1` / `download.cmd` | 包装脚本：查找 Vitis、启动 hw_server、校验、下载 |
| `manifest.json` | 版本号、协议号、三个文件的 SHA256、邮箱地址、网络参数 |
| `download_steps.md` | 面向另一台电脑的逐步操作说明 |

版本：`radar9_20261028`，协议 v3，板卡 `192.168.1.10` → PC `192.168.1.100:9000`。

## 快速使用

```powershell
# 只校验文件，不接触板卡
powershell -NoProfile -ExecutionPolicy Bypass -File .\download.ps1 -VerifyOnly

# 实际下载
powershell -NoProfile -ExecutionPolicy Bypass -File .\download.ps1 -XsdbPath "D:\AMD\2026.1\Vitis\bin\xsdb.bat"
```

看到 `DOWNLOAD_OK` 表示下载并启动后的板端检查通过。
PS-LED0 应亮，采音/模型计数应增长。

## 注意

- 这是 **JTAG 临时下载**：断电后需重新运行 `download.cmd`，没有写入 SD/Flash。
- `radar.bit` 与 `radar.elf` 必须成对使用。重新编译 ELF 后不要直接覆盖：
  `download.tcl` 里的诊断变量地址与 `manifest.json` 里的哈希都按这一对固定。
- 发送计数只表示协议栈接受了数据，不证明 PC 网页已收到；PC 侧要单独确认。
- 网页接收脚本不要同时开两份抢 UDP 9000。

## 与源码的对应关系

本 bit 由交付版本的 `radar_pl_audio` IP 与 `radar_system.bd` 生成，
对应 `src/pl/ip_repo/radar_pl_audio/`（基线 RTL），**不包含**
`src/pl/rtl/` 里输出级的 GATE / SLEW / 瞬态窗口优化。差异见
`src/pl/constraints/source_changes.diff` 与根目录 README 第 3 节。
