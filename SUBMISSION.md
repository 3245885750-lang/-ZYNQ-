# 提交物导航（3.3.5）

本文件把竞赛 3.3.5 的每一条要求映射到仓库里的具体位置，方便评审在几分钟内找到证据。
完整的“零开始”步骤见 [REPRODUCE.md](REPRODUCE.md)。

## 1. 3.3.5.1 工程包

| 要求 | 位置 | 说明 |
|---|---|---|
| 完整工程文件与源码 | [`src/pl/`](src/pl/)、[`src/ps/`](src/ps/)、[`src/pc/`](src/pc/) | PL RTL/约束/BD、PS 裸机与 BSP、PC 上位机（接收服务、网页大屏、音频桥、声纹） |
| 仿真或验证结果 | [`sim/tb/`](sim/tb/)、[`sim/model/`](sim/model/)、[`sim/results/`](sim/results/)、[`src/pc/verification/`](src/pc/verification/) | 模块级 testbench、逐位回放模型、结果图与汇总；PC 端实测数据 |
| 综合与实现报告 | [`build/reports/`](build/reports/) | 资源、时序、功耗、DRC 原始 `.rpt` + 汇总表 |
| 上板工程与运行脚本 | [`board/`](board/) | bit/ELF、`download.tcl`、`download.ps1`、manifest |
| 实测输出与参考结果比对 | [`data/`](data/) | 定点/圆周/拍手 CSV；TDOA 上板汇总表 |
| 可复现构建脚本 | [`build/create_project.tcl`](build/create_project.tcl)、[`src/ps/build.py`](src/ps/build.py) | 从仓库源码重建 PL 工程与 PS 固件 |

### 关键入口

- **PL 开发版 RTL**：[`src/pl/rtl/`](src/pl/rtl/)（含 7 点平滑、相干度 0.75、瞬态 TDOA、AXI `0x50/0x54`）
- **BD/IP 快照**：[`src/pl/ip_repo/radar_pl_audio/`](src/pl/ip_repo/radar_pl_audio/)、[`src/pl/integration/radar_system.bd`](src/pl/integration/radar_system.bd)
- **构建说明**：[`build/README.md`](build/README.md)
- **上板说明**：[`board/README.md`](board/README.md)、[`board/download_steps.md`](board/download_steps.md)
- **TDOA 并入 IP/BD 与 PS 交接**：[`build/update_ip_and_bd.md`](build/update_ip_and_bd.md)、[`report/handoff_tdoa_to_ps.md`](report/handoff_tdoa_to_ps.md)
- **PC 上位机**：[`src/pc/README.md`](src/pc/README.md)；复现 [`src/pc/docs/reproduce.md`](src/pc/docs/reproduce.md)；实测 [`src/pc/verification/results.md`](src/pc/verification/results.md)

## 2. 3.3.5.2 技能包

| 要求 | 位置 | 说明 |
|---|---|---|
| 技能包目录与索引 | [`skill/README.md`](skill/README.md) | 每个技能按“适用场景/使用方法/已验证效果/失效条件/来源”编写 |
| 逐位回放验证 | [`skill/rtl-bit-exact-replay/`](skill/rtl-bit-exact-replay/) | 不综合验证 RTL 输出级 |
| AXI-Stream 握手 | [`skill/axi-stream-tlast/`](skill/axi-stream-tlast/) | 上板丢数、TLAST 错位 |
| MVDR 协方差 EMA | [`skill/mvdr-covariance-ema/`](skill/mvdr-covariance-ema/) | 秩亏、方向漂移、记忆拖尾 |
| Vivado 卡死排查 | [`skill/vivado-synth-hang/`](skill/vivado-synth-hang/) | 综合/实现长时间无输出 |
| 大模型协作提示词 | [`skill/fpga-ai-collaboration/`](skill/fpga-ai-collaboration/) | 长工程里让 AI 改对文件 |
| 瞬态 TDOA 前沿定位 | [`skill/transient-tdoa-first-arrival/`](skill/transient-tdoa-first-arrival/) | 拍手/敲击的单帧测向与 RTL 回放 |
| PS/PL 集成踩坑清单 | [`skill/ps-pack/`](skill/ps-pack/) | PS 侧整理的复位、DMA 背压、定时器宏、载荷配对等 |

> 技能包评价看“陌生人能否复用”。每个技能都给出可运行脚本/数据的位置、预期结果和失效条件；
> 没有在本项目验证过的内容会明确标成“待验证”，不写成既成事实。

## 3. 3.3.5.3 设计报告

| 要求 | 位置 | 说明 |
|---|---|---|
| 选题背景与创新点 | [`report/design_report.md`](report/design_report.md) 第 1 章 | 需求、现有方案痛点、4 条创新点 |
| 设计原理与功能框图 | 第 2–4 章 | UCA 模型、MVDR、DAS、TDOA、系统框图 |
| 软硬件划分依据与接口设计 | 2.3 节、第 5 章、附录 A | 任务分配理由、AXI 映射、UDP 协议 |
| 优化过程与前后对比 | 3.8 节、6.3.1 节 | 算法指标表 + 资源/时序表 |
| 大模型协作记录 | 第 8 章 + [`report/ai_collaboration_log.md`](report/ai_collaboration_log.md) | 提示词、模型回答、自我纠错、Agent 工作流 |
| 技能包提炼过程 | 第 9 章 | 失败/观察 → 技能 → 验证 → 边界 |
| 复现说明 | 附录 D + [`REPRODUCE.md`](REPRODUCE.md) | 零开始完整步骤 |
| 网页可视化实现 | [`src/pc/README.md`](src/pc/README.md)、[`src/pc/verification/results.md`](src/pc/verification/results.md) | 四面板大屏、SSE 推送、CAM++ 声纹、异常恢复 |

## 4. 评审 3 分钟路线

1. 看 [README.md](README.md) 顶部：功能、指标、系统框图。
2. 看本文件的表格，点进设计报告与实测数据。
3. 看 [`build/reports/README.md`](build/reports/README.md)：资源、时序、功耗。
4. 看 [`sim/results/tdoa_replay_summary.md`](sim/results/tdoa_replay_summary.md)：8 方向、弱拍、纯噪声。
5. 看 [`src/pc/verification/results.md`](src/pc/verification/results.md)：上位机实测数据。
6. 看 [`skill/README.md`](skill/README.md)：技能是否可复用。
7. 按 [`REPRODUCE.md`](REPRODUCE.md) 从零复现。

## 5. 版本对应

| 版本 | 内容 | 位置 |
|---|---|---|
| `radar9_20261028` | 基线 bit + ELF（2026-10-28） | `board/payload/`、`board/manifest.json` |
| TDOA 开发版 | 7 点平滑、相干度 0.75、AXI `0x50/0x54`；已完成综合/实现（2026-11-03） | `src/pl/rtl/`、`build/reports/` |
| TDOA 发布版 | 重打包 IP/BD、重编 bit/ELF 后的版本 | 按 [`build/update_ip_and_bd.md`](build/update_ip_and_bd.md) 生成后替换 `board/payload/` |

> 提交前请确认 `board/manifest.json` 的 SHA256 与实际 `radar.bit`/`radar.elf` 一致；
> 不要把“开发版 RTL”和“基线 bit”混着写成同一个版本。
