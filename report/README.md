# report —— 设计报告与工程记录

| 文件 | 内容 | 读者 |
|---|---|---|
| `design_report.md` | 设计报告正文（九章 + 附录） | 评委 / 复现者 |
| `report_outline.md` | 报告架构、图表清单、写作红线、指标推导 | 写报告的人 |
| `pl_ps_interface.md` | AXI-Lite 寄存器表、AXI-Stream 格式、读取流程 | 做 PS 的人 |
| `spectrum_display_design.md` | 频谱/波束谱可视化的方案与取舍 | 做 PC 的人 |
| `doa_jump_investigation.md` | 「固定方位拍手角度跳变」完整排障记录 | 维护 PL 的人 |
| `ai_collaboration_log.md` | 开发过程中的决策、踩坑与验证记录 | 全体 / 想复用方法的人 |
| `handoff_to_ps.md` | 给 PS 队友的交接说明 | 做 PS 的人 |
| `handoff_tdoa_to_ps.md` | 瞬态 TDOA 的寄存器、显示逻辑与验收步骤 | 做 PS 的人 |

仓库根目录另有两份导航文档：

| 文件 | 内容 |
|---|---|
| `SUBMISSION.md` | 3.3.5 每条要求对应的仓库路径与 3 分钟评审路线 |
| `REPRODUCE.md` | 从零复现的完整步骤（环境、综合、PS、上板、回放） |
| `build/update_ip_and_bd.md` | 把 TDOA 开发版并入 IP/BD/bit 的操作步骤 |

## 阅读顺序

- 想快速了解系统 → `design_report.md`
- 想复现或改 PL → `design_report.md` 第三章 + `doa_jump_investigation.md`
- 想接 PS 或改协议 → `pl_ps_interface.md`
- 想做 PC 上位机 → [`../src/pc/README.md`](../src/pc/README.md) + [`../src/pc/docs/reproduce.md`](../src/pc/docs/reproduce.md)
- 想上板验证拍手 TDOA → `handoff_tdoa_to_ps.md` + `../build/update_ip_and_bd.md`
- 想复用「怎么和 AI 一起做长工程」 → `ai_collaboration_log.md` + `skill/fpga-ai-collaboration/`

## 说明

- 这些文档按**当时的状态**保留，未做追溯性改写；文中的日期、参数与结论
  反映写作时刻的工程状态。与最新代码不一致时，以代码 + `sim/model/param_check.py`
  为准。
- 文中出现的 `D:\...`、`F:\...` 路径是作者机器的原始路径，仅作记录，
  在仓库内请按 `src/`、`sim/`、`data/` 的相对位置查找。
- `design_report.md` 中标注【待补】的位置需要实测数据或队友输出。
