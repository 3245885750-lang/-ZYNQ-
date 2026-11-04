# 综合与实现报告

本目录存放 3.3.5.1 要求的综合/实现原始报告，以及一份便于评审阅读的汇总表。

## 1. 怎么生成

在 Vivado 2026.1 中完成 `synth_1` 与 `impl_1` 后，在 Tcl Console 执行：

```tcl
cd <repo>/build
source export_reports.tcl
```

会得到：

| 文件 | 内容 |
|---|---|
| `post_route_utilization.rpt` | 路由后 LUT / FF / BRAM / DSP / IOB 等资源占用 |
| `post_synth_utilization.rpt` | 综合后资源占用（用于和路由后对照） |
| `timing_summary.rpt` | WNS / TNS / WHS / THS、时钟与失败路径 |
| `power.rpt` | 总功耗、动态/静态功耗 |
| `drc.rpt` | DRC 检查结果 |
| `bus_skew.rpt` | 总线偏斜报告 |
| `tool_version.txt` | Vivado 版本、器件、顶层、导出时间 |

`export_reports.tcl` 生成 `post_route_utilization.rpt`、`timing_summary.rpt`、
`power.rpt`、`drc.rpt`、`clock_utilization.rpt` 与 `tool_version.txt`。
本目录额外保留了 `post_synth_utilization.rpt` 与 `bus_skew.rpt`
（直接从 `synth_1/`、`impl_1/` 复制）。**`clock_utilization.rpt` 本次没有导出**，
时钟信息见 `timing_summary.rpt` 的 Clock Summary；需要独立报告时在工程里重跑
`report_clock_utilization`。

## 2. 汇总表（评审先看这里）

> 两组数字来自两次不同的实现：
> **基线** = 2026-10-22 的 `radar_pl_top`；**TDOA 版** = 2026-11-03 的
> `radar_pl_bd_verify_top`（含 `transient_tdoa`）。
> **两次顶层不同**，差值里含 AXI 接口、UART 等差异，不能全部算作 TDOA 支路的增量。

| 项目 | 基线（2026-10-22） | TDOA 版（2026-11-03） | 变化 |
|---|---:|---:|---:|
| Vivado 版本 | 2026.1 | 2026.1 | — |
| Part | xc7z020clg400-2 | xc7z020clg400-2 | — |
| 顶层 | `radar_pl_top` | `radar_pl_bd_verify_top` | 验证顶层不同 |
| 目标时钟 | 50 MHz | 50 MHz | — |
| LUT | 29 130 (54.8%) | 35 354 (66.45%) | +6 224（+11.65 pt） |
| FF | 37 545 (35.3%) | 40 674 (38.23%) | +3 129（+2.93 pt） |
| BRAM | 60.5 (43.2%) | 62.5 (44.64%) | +2.0（+1.44 pt） |
| DSP | 102 (46.4%) | 114 (51.82%) | +12（+5.42 pt） |
| IOB | 15 (12%) | 15 (12%) | 0 |
| WNS | +0.680 ns | +0.798 ns | +0.118 ns |
| TNS | 0.000 ns | 0.000 ns | 0 |
| WHS | +0.047 ns | +0.055 ns | +0.008 ns |
| THS | 0.000 ns | 0.000 ns | 0 |
| 时序端点 | 115 254 | 121 900 | +6 646 |
| 估计 Fmax | 51.76 MHz | 52.08 MHz | +0.32 MHz |
| 总功耗（PL） | 0.373 W | 0.397 W | +0.024 W |

功耗细分（TDOA 版）：动态 0.283 W，静态 0.114 W，结温 29.6 °C，置信度 Low。
DRC：**0 个 Error**；Warning 以 DSP 流水（DPIP/DPOP）、RAMB36 异步控制
（REQP-1839）和 `ZPS7-1`（验证顶层不带 PS7，属预期）为主。

## 3. 怎么读这些报告

- **WNS**：最差建立时间余量。50 MHz 周期 20 ns，WNS 为正表示时序收敛。
- **Fmax**：`1000 / (20 − WNS)` MHz，只是该时钟域的估计值，不是整芯片上限。
- **BRAM**：Vivado 可能显示 `60.5` 这种小数，表示半个 36Kb BRAM 的占用。
- **功耗**：`power.rpt` 的置信度通常是 Low/Medium，报告里要注明“估算值”。

## 4. 与设计报告的对应

`report/design_report.md` 的 6.3 节和 6.3.1 节应引用本目录的数字。
如果重跑后数字变化，以本目录最新 `.rpt` 为准，并同步更新 README 的资源表。
