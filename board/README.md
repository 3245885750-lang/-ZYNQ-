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

本目录的 `radar.bit` / `radar.elf` 是 **2026-10-28 的基线版本**，
由 `src/pl/ip_repo/radar_pl_audio/`（基线 RTL）+ `radar_system.bd` 生成，
**不包含** `src/pl/rtl/` 里的以下开发内容：

| 未部署内容 | 位置 | 说明 |
|---|---|---|
| 输出级 GATE / SLEW / 瞬态窗口优化 | `src/pl/rtl/mvdr_axi_top.v` | 差异见 `src/pl/constraints/source_changes.diff` |
| 瞬态拍手 TDOA 支路 | `src/pl/rtl/radar_pl_top_bd.v` 内 `transient_tdoa` | AXI `0x50/0x54`，见 `report/handoff_tdoa_to_ps.md` |

因此：

- 按本目录操作，板上跑的是**基线功能**，拍手仍走 MVDR，表现见
  `data/clap_log_20261101.csv`；
- 要上板验证 TDOA，必须先按 `build/update_ip_and_bd.md` 重新打包
  `radar_pl_audio` IP、更新 BD、重新生成 bit，并按该文档给 PS 加
  `0x50/0x54` 读取与显示切换；
- 重新生成 bit/ELF 后，`manifest.json` 里的哈希和版本号必须一起更新，
  否则 `download.ps1 -VerifyOnly` 会拒绝；旧的 `data/*.csv` 也不能再和
  新 bit 混在一起比较。
