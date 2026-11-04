# 瞬态 TDOA 交接给 PS（队友 B）

> 状态：**RTL 已通过逐位回放，尚未并入 IP/BD，尚未上板。**
> 本文写的是「并入之后 PS 要做什么」，不是「现在板上已经能读到」。
> 并入步骤见 [`../build/update_ip_and_bd.md`](../build/update_ip_and_bd.md)。

## 0. 一句话

拍手等瞬态由 PL 的 `transient_tdoa` 支路单独估计，结果放在 `0x50/0x54`。
PS 只在 `0x54` bit0 = 1（保持期 500 ms）时用 `0x50` 的角度覆盖显示，
其余时间继续显示 MVDR `0x08`。**角度已含 +180° 安装偏移，PS 不要再加。**

## 1. 寄存器

基地址 `RADAR_BASE = 0x43C00000`（以 BD 实际分配为准）。

| 偏移 | 名称 | 属性 | 说明 |
|---|---|---|---|
| `0x08` | DOA | R | 连续声源 MVDR 角度，32 bit 有符号度 |
| `0x50` | TDOA_DOA | R | 瞬态角度，**只有低 9 bit 有效，有符号** |
| `0x54` | TDOA_STATUS | R | 状态位，见下表 |

`0x54` 位定义：

| 位 | 名称 | 含义 |
|---|---|---|
| 0 | HOLD | 1 = 当前处于 TDOA 保持期（触发后 500 ms） |
| 1 | LOWCONF | 1 = 最近一次 TDOA 结果低置信，不建议显示 |
| 2 | HAVE | 1 = 上电以来至少有过一次 TDOA 结果 |

`0x50` 的取值：`−180…+180`，**整数度**。寄存器内部按 9 bit 有符号存储，
`mvdr_axi_top` 读出时已用 `{{23{tdoa_doa[8]}}, tdoa_doa}` 做 32 bit 符号扩展，
所以读到的是标准的 `int32_t` 负数。如果换成本仓库以外的实现、只拿到裸 9 bit，
按第 2 节的移位写法处理同样正确（对已符号扩展的值是幂等的）。

## 2. PS 读取

```c
#include "xil_io.h"

#define RADAR_BASE      0x43C00000u
#define REG_DOA         (RADAR_BASE + 0x08u)
#define REG_TDOA_DOA    (RADAR_BASE + 0x50u)
#define REG_TDOA_STATUS (RADAR_BASE + 0x54u)

typedef struct {
    int32_t  deg;
    uint32_t hold;
    uint32_t lowconf;
    uint32_t have;
} tdoa_t;

static tdoa_t tdoa_read(void)
{
    tdoa_t r;
    uint32_t raw    = Xil_In32(REG_TDOA_DOA);
    uint32_t status = Xil_In32(REG_TDOA_STATUS);

    r.deg     = (int32_t)(raw << 23) >> 23;   /* 对 9 bit 值安全；本 RTL 已扩展，等价直取 */
    r.hold    = status & 0x1u;
    r.lowconf = (status >> 1) & 0x1u;
    r.have    = (status >> 2) & 0x1u;
    return r;
}
```

常见错误（针对只拿到裸 9 bit 的实现；本 RTL 已扩展，直接用 `(int32_t)raw` 也对）：

- 直接 `(int32_t)raw`：`0x1F8`（= −8°）会被当成 504°，显示到错误方向；
- 用 `raw & 0x1FF` 后再减 256：能算对，但不如移位写法直观；
- 把 `0x50` 当无符号 `uint8_t`：同样丢符号。

无论哪种写法，联调时都应在 270° 拍一次，确认读回的是 **−90 而不是 270 的
某种错误展开**——这是符号处理是否正确的快速判据。

## 3. 显示优先级

```c
int32_t display_deg;
tdoa_t t = tdoa_read();

if (t.hold && !t.lowconf) {
    display_deg = t.deg;            /* 瞬态：优先显示 */
    source = "TDOA";
} else if (t.hold && t.lowconf) {
    display_deg = mvdr_deg;         /* 保持期内但不可信：维持 MVDR */
    source = "MVDR(lowconf)";
} else {
    display_deg = mvdr_deg;         /* 平时 */
    source = "MVDR";
}
```

要点：

- **`lowconf=1` 时不要显示 TDOA 角度**。它多半是噪声误触发或通道不足；
- `have=0` 时 `0x50` 是复位值，**不要显示**；
- 保持期 500 ms 内角度不变，便于人眼读数；不要每 21 ms 用 MVDR 覆盖它；
- 网页/串口建议同时显示 `source`，方便联调时判断走的是哪条支路。

> **PC 端现状**：JSON v3 的 `doa` 消息目前只有 `method=das|mvdr`，没有 TDOA 字段，
> 网页大屏只显示 MVDR。PS 接入 TDOA 后，需要同步扩展 `kind=doa` 的
> `method`（例如 `tdoa`）或新增消息类型，并更新
> [`src/pc/pc_rx/pc/radar_protocol.py`](../src/pc/pc_rx/pc/radar_protocol.py)
> 的校验与 [`src/pc/acoustic-radar.html`](../src/pc/acoustic-radar.html) 的显示逻辑。

## 4. 时序

| 事件 | 延迟 |
|---|---|
| 拍手触发 → `0x50` 有效 | 约 2.1 ms |
| 保持期 | 500 ms（25 000 000 个 50 MHz 周期） |
| 保持结束后 | 显示回 `0x08`，`0x54` bit0 清 0 |
| 两次触发最小间隔 | 20 ms（`REFRACT`），期间不再触发 |

PS 轮询周期建议 ≤ 50 ms，否则可能错过 500 ms 保持窗的首段，但不会丢结果
（保持期内值一直不变）。

## 5. 与现有 ELF 的关系

现有 `board/payload/radar.elf` 是基线版本，**没有** `0x50/0x54` 读取逻辑。
并入 TDOA 后必须：

1. 在 PS 源码里加入第 2、3 节的代码；
2. 重新 Build ELF；
3. 与新的 bit 一起下载，**不要新旧混搭**；
4. 更新 `board/manifest.json`：版本号（如 `radar9_20261105`）、协议号、
   三个文件的 SHA256。

`download.tcl` 里的诊断变量地址按这一对 bit/ELF 固定，换版本要一起改。

## 6. 上板验收

按顺序做，任一步失败先停下排查：

| 步 | 操作 | 预期 |
|---|---|---|
| 1 | 读 `0x1C` | `0x4D564452` |
| 2 | 读 `0x54`，未拍手 | bit0=0，bit2=0，`0x50` 无意义 |
| 3 | 在 0° 拍一次 | 500 ms 内 `0x54` bit0=1，`0x50` 约为 0（含安装偏移后） |
| 4 | 依次在 90°/180°/270° 拍 | `0x50` 分别约为 90/180/−90 |
| 5 | 观察 1 s | 500 ms 后 bit0 回 0，显示回 MVDR |
| 6 | 静默 30 s | 无误触发，bit2 不再增加 |
| 7 | 白噪声/说话 | 不触发 TDOA，MVDR 正常 |

数据按 [`../data/tdoa_board_summary.md`](../data/tdoa_board_summary.md) 记录，
不要用离线回放数字代替。

## 7. 已知边界

- TDOA 只对**短促瞬态**有效，连续声源请继续用 MVDR；
- 声源与阵列不同高、强混响、离麦过近削顶时会失准；
- 安装偏移（+180°）已在 RTL 内加好，PS 不要重复加；
- 换阵列半径/采样率/阵元数后，RTL 内的 `k` 与各级阈值必须重算，
  PS 侧接口不变，但精度结论不能沿用；
- `0x50` 只有整数度，分辨率低于 MVDR 的 Q8 内部精度。

## 8. 相关文件

| 文件 | 内容 |
|---|---|
| `src/pl/rtl/radar_pl_top_bd.v` | `transient_tdoa` 模块与顶层集成 |
| `build/update_ip_and_bd.md` | 并入 IP/BD/bit 的完整步骤 |
| `sim/results/tdoa_replay_summary.md` | RTL 回放结果与复现命令 |
| `sim/tb/tb_tdoa_replay.v` | 8 方向/弱拍回放 testbench |
| `data/tdoa_board_summary.md` | 上板数据模板 |
| `report/pl_ps_interface.md` | 其余寄存器的完整定义 |
