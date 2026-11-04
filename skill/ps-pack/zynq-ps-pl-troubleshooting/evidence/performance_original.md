# 资源、时钟与关键性能

本表摘自当前整合版原始报告，原件见 `evidence/historical/hardware_reports/`。本次整理没有重跑 PL 综合实现。

## 配套 PL 资源与时序

器件 `xc7z020clg400-2`；Vivado 2026.1，设计状态 Routed。

| 指标 | 结果 | 原始来源 |
| --- | --- | --- |
| Slice LUT | 35,031 / 53,200，65.85% | implementation_utilization.rpt |
| Slice Register | 42,792 / 106,400，40.22% | 同上 |
| Block RAM Tile | 64 / 140，45.71% | 同上 |
| DSP | 111 / 220，50.45% | 同上 |
| WNS / TNS | +0.380ns / 0 | implementation_summary.txt、implementation_timing.rpt |
| WHS / THS | +0.045ns / 0 | 同上 |
| WPWS / TPWS | +3.870ns / 0 | 同上 |
| DRC 错误数 | 0 | implementation_drc.rpt |
| PL 处理时钟 | 50MHz；DMA 系统含100MHz域，详见 clocks.rpt 与 BD 脚本 | implementation_clocks.rpt |
| 角度后处理流水线附加时延 | 8个50MHz周期，即160ns | angle_pipeline_checks.json |

以上是配套 PL 整体资源，不应算作 PS 软件的 LUT/DSP 占用。已约束路径的时序通过不等于麦阵外部电气/采样时序已实测通过。

## PS 静态占用与标称调度

原发布 ELF 的 `arm-none-eabi-size`：text=483,238字节，data=3,672字节，bss=28,334,544字节；共28,821,454字节。BSS 为零初始化地址空间，不等于 ELF 文件大小。来源：`evidence/historical/build_result.json`；本次重编结果另见 `evidence/current/firmware_build_result.json`。

| 项目 | 配置/标称值 | 解释 |
| --- | --- | --- |
| 原始单路 PCM | 50,000,000/1024 = 48,828.125Hz | 单帧1024样本，约20.97152ms；不能按48kHz直接计时 |
| 分类输入 | 16kHz，约2秒上下文 | 首次需要积累音频历史 |
| 分类目标步长 | 100ms | 目标更新间隔；不是识别完成时延或端到端延迟 |
| 频谱 | 256点 FFT，129点，0～8kHz，62.5Hz间隔 | 与CNN同源的干净单声道PCM |
| 频谱目标刷新 | 每5个DMA帧，约104.8576ms | 以实际负载与收包测量为准 |
| UDP 端口与载荷上限 | 9000，1200字节 | 历史频谱极值测试最大941字节 |
| 输出类别 | 9槽、掩码127，前7槽启用 | 七类识别；停用玻璃破碎/发动机 |

实际 PS 分类最坏耗时、稳态丢帧、每秒实收包数、识别准确率、声学起音到网页结果延迟，均需本整合版上板测量。`model/metrics.json` 的历史九槽离线指标不等于当前七类实板指标，也不能用频谱刷新周期推算识别准确率或端到端性能。
