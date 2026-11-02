# report —— 设计报告与工程记录

| 文件 | 内容 | 读者 |
|---|---|---|
| `design_report.md` | 设计报告正文（七章 + 附录） | 评委 / 复现者 |
| `report_outline.md` | 报告架构、图表清单、写作红线、指标推导 | 写报告的人 |
| `pl_ps_interface.md` | AXI-Lite 寄存器表、AXI-Stream 格式、读取流程 | 做 PS 的人 |
| `spectrum_display_design.md` | 频谱/波束谱可视化的方案与取舍 | 做 PC 的人 |
| `doa_jump_investigation.md` | 「固定方位拍手角度跳变」完整排障记录 | 维护 PL 的人 |
| `ai_collaboration_log.md` | 开发过程中的决策、踩坑与验证记录 | 全体 / 想复用方法的人 |
| `handoff_to_ps.md` | 给 PS 队友的交接说明 | 做 PS 的人 |

## 阅读顺序

- 想快速了解系统 → `design_report.md`
- 想复现或改 PL → `design_report.md` 第三章 + `doa_jump_investigation.md`
- 想接 PS 或改协议 → `pl_ps_interface.md`
- 想复用「怎么和 AI 一起做长工程」 → `ai_collaboration_log.md` + `skill/fpga-ai-collaboration/`

## 说明

- 这些文档按**当时的状态**保留，未做追溯性改写；文中的日期、参数与结论
  反映写作时刻的工程状态。与最新代码不一致时，以代码 + `sim/model/param_check.py`
  为准。
- 文中出现的 `D:\...`、`F:\...` 路径是作者机器的原始路径，仅作记录，
  在仓库内请按 `src/`、`sim/`、`data/` 的相对位置查找。
- `design_report.md` 中标注【待补】的位置需要实测数据或队友输出。
