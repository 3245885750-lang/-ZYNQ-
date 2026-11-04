# 把 TDOA 开发版并入 IP / BD / bit 的步骤

`src/pl/rtl/` 是最新开发版（7 点平滑、相干度 0.75、AXI `0x50/0x54`）。
`src/pl/ip_repo/radar_pl_audio/` 是与 2026-10-28 基线 bit 配套的快照。
要让完整系统（BD + PS + 网页）也带 TDOA，按下面做一次。

> 这一步会改变 IP 版本、bit 和 ELF，必须成套替换 `board/payload/` 里的三个文件，
> 并更新 `board/manifest.json` 的 SHA256。不要只换 bit 不换 ELF。

## 1. 同步源码到 IP

在仓库根目录执行（PowerShell）：

```powershell
$ip = ".\src\pl\ip_repo\radar_pl_audio\src"
Copy-Item .\src\pl\rtl\radar_pl_top_bd.v      $ip -Force
Copy-Item .\src\pl\rtl\mvdr_axi_top.v         $ip -Force
Copy-Item .\src\pl\rtl\cov_accum_8x8.v        $ip -Force
Copy-Item .\src\pl\rtl\doa_uart.v             $ip -Force
Copy-Item .\src\pl\rtl\fft_spectrum_packetizer.v $ip -Force
Copy-Item .\src\pl\rtl\i2s_fft8_axis.v        $ip -Force
Copy-Item .\src\pl\rtl\i2s_fft8_tagged_top.v  $ip -Force
Copy-Item .\src\pl\rtl\i2s_fft8_top.v         $ip -Force
Copy-Item .\src\pl\rtl\i2s_cdc_8ch.v          $ip -Force
Copy-Item .\src\pl\rtl\i2s_master.v           $ip -Force
Copy-Item .\src\pl\rtl\i2s_rx.v               $ip -Force
Copy-Item .\src\pl\rtl\i2s_rx_8ch.v           $ip -Force
```

然后检查 `component.xml` 的文件列表是否包含新增文件：

- `src/fft_spectrum_packetizer.v`
- `src/i2s_fft8_tagged_top.v`

如果缺少，在 Vivado 里重新 Package IP 时会自动扫描；不要手工只改 XML。

## 2. 重新打包 IP

### 方式 A：GUI

1. 打开 IP Catalog；
2. 找到 `radar_pl_audio`；
3. 右键 → Package IP；
4. 在 File Groups 里确认 `src/*.v` 都包含；
5. Review → Package；
6. 版本号建议从 `1.0` 升到 `1.1`，避免 BD 继续用缓存。

### 方式 B：Tcl

在 IP 工程目录（含 `component.xml` 的目录）执行：

```tcl
set ipdir [file normalize "./src/pl/ip_repo/radar_pl_audio"]
ipx::package_project -root_dir $ipdir -vendor user -library ip -taxonomy /UserIP
ipx::increment_version [ipx::current_core]
ipx::save_core [ipx::current_core]
```

> `ipx::package_project` 的 `-import_files` 选项因 Vivado 版本而异；
> 如果报参数错误，用 GUI 方式最稳。

## 3. 更新 Block Design

1. 打开 `src/pl/integration/radar_system.bd`；
2. `update_ip_catalog -rebuild`；
3. 如果 IP 版本升级，右键 IP → Upgrade IP；
4. Validate Design；
5. Generate Output Products；
6. Create HDL Wrapper；
7. 综合 → 实现 → Generate Bitstream。

## 4. 更新 PS 读取 TDOA

在 PS 源码里加：

```c
#define RADAR_BASE      0x43C00000u
#define REG_TDOA_DOA    (RADAR_BASE + 0x50u)
#define REG_TDOA_STATUS (RADAR_BASE + 0x54u)

uint32_t tdoa_doa    = Xil_In32(REG_TDOA_DOA);
uint32_t tdoa_status = Xil_In32(REG_TDOA_STATUS);
int32_t  tdoa_deg    = (int32_t)(tdoa_doa << 23) >> 23;  // 9 bit 符号扩展；本 RTL 已扩展，此写法等价
```

显示逻辑：

```c
if (tdoa_status & 0x1) {
    // 保持中：用 TDOA 角度
   显示角度 = tdoa_deg;
} else {
    // 保持结束：回 MVDR 0x08
   显示角度 = mvdr_deg;
}
if (tdoa_status & 0x2) {
    // 上次 TDOA 结果低置信，可显示“不确定”标记
}
```

详细交接见 [`report/handoff_tdoa_to_ps.md`](../report/handoff_tdoa_to_ps.md)。

## 5. 重编 ELF 与 bit

1. Vitis 重新 Build PS 工程；
2. Vivado 重新 Generate Bitstream；
3. 用新 bit + 新 ELF 下载；
4. 按 [`data/tdoa_board_summary.md`](../data/tdoa_board_summary.md) 采集数据。

## 6. 更新发布包

```powershell
# 替换 board/payload 下三个文件
Copy-Item <new>\radar.bit  .\board\payload\radar.bit  -Force
Copy-Item <new>\radar.elf  .\board\payload\radar.elf  -Force
Copy-Item <new>\ps7_init.tcl .\board\payload\ps7_init.tcl -Force

# 重新计算 SHA256，更新 board/manifest.json
Get-FileHash .\board\payload\radar.bit -Algorithm SHA256
Get-FileHash .\board\payload\radar.elf -Algorithm SHA256
Get-FileHash .\board\payload\ps7_init.tcl -Algorithm SHA256
```

同时更新 `board/manifest.json` 里的版本号（例如 `radar9_20261105`）和协议号。

## 7. 验收

- `board/download.cmd` 输出 `DOWNLOAD_OK`；
- PS 能读到 `0x54`，bit2=1 表示已有 TDOA 结果；
- 拍手后 500 ms 内显示 TDOA 角度，之后回 MVDR；
- 5 s 纯噪声无误触发；
- 网页/串口角度与真实方位一致（含 +180° 安装偏移）。
