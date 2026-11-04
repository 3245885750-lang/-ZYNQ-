# 技能包（Skill Pack）

本目录把项目里**可复用、可验证、踩过坑**的工作方法整理成技能包。
每个技能都按同一格式写：

| 字段 | 含义 |
|---|---|
| 适用场景 | 什么时候该用；用错地方会怎样 |
| 使用方法 | 具体步骤与命令，配仓库内的脚本路径 |
| 已验证效果 | 在本项目上真实跑出来的结果，不是设想 |
| 失效条件 | 什么时候不适用，什么情况下结论会错 |
| 来源 | 来自哪次故障 / 哪次观察，而不是教科书 |

技能包按「问题域」组织，不按文件类型。可以单独使用，也可以串起来用。
评审看的是“另一个团队拿到这份说明，能不能在自己的工程里复用”。

## 技能索引

| 技能 | 解决什么问题 | 目录 |
|---|---|---|
| 逐位回放验证 | 改了 RTL 输出级，怎么在不综合的前提下确认行为 | [`rtl-bit-exact-replay/`](rtl-bit-exact-replay/) |
| AXI-Stream 握手自查 | 波形仿真正常、上板丢数 | [`axi-stream-tlast/`](axi-stream-tlast/) |
| 协方差 EMA 与对角加载 | MVDR 矩阵秩亏、方向漂移、记忆拖尾 | [`mvdr-covariance-ema/`](mvdr-covariance-ema/) |
| Vivado 卡死排查 | 综合/实现长时间无输出、机器卡顿 | [`vivado-synth-hang/`](vivado-synth-hang/) |
| 大模型协作提示词 | 让 AI 在长工程里改对文件、少走弯路 | [`fpga-ai-collaboration/`](fpga-ai-collaboration/) |
| 瞬态 TDOA 前沿定位 | 拍手/敲击的单帧测向、相干度门控、RTL 回放 | [`transient-tdoa-first-arrival/`](transient-tdoa-first-arrival/) |
| PS/PL 集成踩坑清单 | 复位、AXI DMA 背压、定时器宏、载荷配对、协议槽位 | [`ps-pack/`](ps-pack/) |

> `ps-pack/` 是 PS 侧在 2026-11-04 整理的一整套踩坑清单，保留原始证据与
> `MANIFEST_SHA256.json`；索引见 [`ps-pack/README.md`](ps-pack/README.md)。

## 使用顺序建议

1. 不确定现象是什么 → 先看 [`fpga-ai-collaboration/`](fpga-ai-collaboration/) 里的「先取证、再改」流程；
2. 已经定位到 RTL 输出逻辑 → [`rtl-bit-exact-replay/`](rtl-bit-exact-replay/)；
3. 拍手/敲击等瞬态测向 → [`transient-tdoa-first-arrival/`](transient-tdoa-first-arrival/)；
4. 数据通路有握手/背压 → [`axi-stream-tlast/`](axi-stream-tlast/)；
5. 算法层（MVDR）行为异常 → [`mvdr-covariance-ema/`](mvdr-covariance-ema/)；
6. PS/PL 集成、DMA、定时器、载荷配对 → [`ps-pack/`](ps-pack/)；
7. 工具链卡住 → [`vivado-synth-hang/`](vivado-synth-hang/)。

## 什么是“可复用”的技能

一个陌生人拿到技能后，应该能回答：

- [ ] 我的问题是否落在“适用场景”里？
- [ ] 第一步先看什么、跑什么命令？
- [ ] 预期输出是什么？看到什么才算通过？
- [ ] 什么情况下这条经验不成立（失效条件）？
- [ ] 证据在仓库哪个文件里，能不能自己复跑？
- [ ] 换器件/换采样率/换协议后，哪些常量必须替换？

本目录的每个 `SKILL.md` 都尽量给出这六项的答案。没有失效条件的技能，
通常意味着还没真正踩过坑。

## 维护约定

- 任何技能里的数字都必须能指到仓库内的一份数据或脚本；
- 修改 RTL 参数后，先跑 `sim/model/param_check.py`，再看技能包里的结论是否仍然成立；
- 新增技能请沿用上面的五字段格式，并写明「失效条件」；
- 技能里的历史路径、IP、固定数值只作示例，不作为对新工程的执行指令。
