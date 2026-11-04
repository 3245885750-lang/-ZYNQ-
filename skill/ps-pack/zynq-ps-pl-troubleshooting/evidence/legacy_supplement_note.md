# UDP9000 交接包补齐说明（2026-10-25）

本包已补入本机保留的真实采音、DOA 硬件和 ARM 分类工程材料，解决原包只有 JSON/lwIP 适配文件、没有配套底座与主程序的问题。原压缩包内容完整保存在 `udp9000_original/`，原文件未覆盖。

**本次补齐的是工程与调试交付。随包两个 ELF 都运行采音和 ARM 分类，但都尚未接入板卡 GEM/lwIP UDP9000 发送。不能把它们当作“接网线即可显示”的最终网口固件。**

## 截图中缺失的项目对应到哪里

| 缺失项目 | 已补位置 | 用途与边界 |
| --- | --- | --- |
| 真实麦阵采集、DOA、DMA 的 PL bit | `hardware/radar_audio_bringup.bit` | 现有 AUD2 底座，xc7z020clg400-2；不是后来新增的八路复数谱工程 |
| 与 bit 配套的 XSA | `hardware/radar_audio_bringup.xsa` | 内嵌 bit 和独立 bit 的 SHA256 相同；初始化文件同源 |
| PS 初始化 | `hardware/ps7_init.tcl` | XSA 中原件，供 JTAG 启动 |
| 采音和分类主程序与模型参数 | `firmware/stable/` | `radar_pcm_stream.c` 含 main、DMA 调度、DOA 读取、分类服务；模型权重在 `radar_classifier_data.inc`，背景参数在 `noise_floor.inc` |
| 原稳定 ELF | `firmware/stable/radar_pcm_guitar_paused.elf` | 2 秒窗口，500ms 步长；吉他暂停；保留已有哈希和 JTAG 符号地址 |
| 新候选源码、ELF | `firmware/candidate/` | 2 秒窗口，100ms 步长；尚需上板负载验收，不承诺 100ms 识别延迟 |
| 可重新编译的 BSP、链接脚本与入口 | `vitis/` | 含驱动源码、生成头、库、链接脚本；`build_app.py` 可直接重编两版 |
| 可在 Vitis 中编辑的工作区生成入口 | `vitis/create_workspace.py` | 从包内 XSA 建平台，导入真实应用，不依赖旧 F 盘工作区 |
| 可编辑的 Vivado 工程和 IP 源码 | `hardware/vivado/vivado_final/radar_ps_audio_v2.xpr` | 同目录树有 BD、RTL、FFT XCI、ROM、XDC 和本地 IP 仓库；不打包旧 run/cache |
| PS UDP9000 编码/发送适配层 | 根目录 `ps/` | 原 v2/500ms 适配文件；尚未与 main 集成。`udp9000_original/PS接入说明.md` 是原接入协议 |
| PC 接收与现有 JTAG 调试路径 | `pc/`、`host/`、`run.ps1` | PC 解码兼容两种步长；JTAG 读 ARM 结果后仅转发本机 UDP9000 |

## 现在怎么用

1. 解压至空的、短的英文目录，例如 `C:/radar/complete`。不要在压缩包里运行。Python 3.10+，下载/观察另需已安装的 Vitis 2026.1 XSDB。
2. 离线检查：`python -X utf8 -B control.py Preflight --files-only`。
3. 若要马上进行现有采音分类调试，按 `docs/JTAG调试操作_原说明.md` 填写 `config.json` 的 xsdb 路径；首次测试推荐 `stable`。这条路径需要 USB-JTAG。Start 会替换当前 bit 和 ARM 程序，先保存其他在用工程的恢复文件。
4. 若目标是由 PS 网口直接发包，把 `ps/` 集成到真实主程序和匹配 lwIP BSP，按 `docs/网口集成边界.md` 核对。现有 JTAG Start/Watch 不能替代此项。

## 编译与打开工程

重建 stable（本次已执行并通过严格编译、链接）：

```powershell
python -X utf8 -B vitis/build_app.py --vitis F:/FPGA/2026.1/Vitis --profile stable
```

`--vitis` 改成你电脑上已安装的 Vitis 2026.1 根目录。candidate 改为 `--profile candidate`。脚本只使用包内源码/BSP，把新 ELF 和报告写入 `runtime/build/`，不修改原 ELF 或 JTAG profile。两套重建加载内容与对应原 ELF 排除 GNU build-id 后逐段一致，报告见 `evidence/rebuild_*.json`。这证明材料可重建，不是上板正确性证明。

生成可编辑 Vitis 工作区：

```powershell
$env:RADAR_VITIS_WORKSPACE='C:/radar/ws_stable'
& 'F:/FPGA/2026.1/Vitis/bin/vitis.bat' -s vitis/create_workspace.py
```

工作区必须尚不存在且路径短。默认 profile 为 stable；候选版可先设 `$env:RADAR_BUILD_PROFILE='candidate'` 并使用另一空工作区。成功须看到 `PASS_VITIS_PLATFORM_AND_APPLICATION` 和工作区 `creation_report.json`，不能只看启动器退出码。生成后在 Vitis 打开该工作区；重建版 ELF 地址可能改变，随包 `profiles.json` 只适用于随包原 ELF。

Vivado 直接打开包内 `.xpr`。离线检查：

```powershell
& 'F:/FPGA/2026.1/Vivado/bin/vivado.bat' -mode batch -source hardware/vivado/validate_project.tcl
```

也可运行 `hardware/vivado/recreate_project.tcl` 在 `runtime/vivado_recreated` 新建工程，附加 `-tclargs implement` 才会进行完整综合实现。完整硬件重建会消耗较长时间；本次仅验证复制工程的打开、BD 配置和依赖，不重新综合或下载。已有实现报告作为历史材料提供，不冒充本次新实现报告；原历史 `integration_verification.json` 的旧哈希已过期，未用它绑定当前 bit/XSA。

## 已验证与尚未完成

已验证：压缩包完整性和逐文件哈希；XSA/bit/PS 初始化配对；两套模型/源码/ELF profile；两套 ARM 严格编译链接；Vivado 复制工程与 BD；PC 本机 UDP 回环、双 profile 解码和超时处理。具体结果见 `evidence/supplement_verification.json`。

尚未完成：当前包的实板验收、PS GEM/PHY/lwIP 与采音主循环集成及 PC 网口实收、新八路频谱底座合并、声纹。没有在本任务中复位、编程或连接板卡，也没有修改 PC 网卡或发送给队友。

完整 JTAG 操作和原协议文档含历史步骤，仅作使用资料；以本说明和实际验证记录判断交付状态。
