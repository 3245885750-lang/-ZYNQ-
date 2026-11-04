# 交接说明（队员 A → 队友 B）

> 更新：2026-10-19。此文档以当前状态为准；旧版（窄带单 bin / ±90° / 频谱流交接）已过时作废。
>
> **2026-11-04 补充**：文中「拍手等宽带瞬态也能快速锁定」是当时 MVDR 路径的观察，
> 后续联调发现其跨次稳定性不足。拍手现由独立的瞬态 TDOA 支路处理，寄存器为
> `0x50/0x54`；读取与显示逻辑见 [`handoff_tdoa_to_ps.md`](handoff_tdoa_to_ps.md)。
> 该支路属于 `src/pl/rtl/` 开发版，基线 bit 上没有，需按
> [`../build/update_ip_and_bd.md`](../build/update_ip_and_bd.md) 并入。

---

## 一、现在是什么状态（A 已做完）

- **阵列**：8 麦 UCA 圆周阵列（R=50mm），全 360° 测向，DOA 范围 **-180..+180**（有符号度）。
- **MVDR 宽带精测**：8 个频率 bin 非相干融合（476.9 / 953.7 / 1430.5 / 1907.4 / 2384.3 / 2956.6 / 3528.8 / 4100.8 Hz）+ 协方差自适应 EMA。连续声源 ±1~2°；拍手等宽带瞬态也能快速锁定，拖尾 ~0.3s。
- **更新率 47.7 Hz**（K=2 快拍出一次 DOA；8 bin 扫角 585 拍，一帧 10.49ms 内做完）。`AUTO_RUN=1`，上电自动连续测向，PS 不用写 START，直接轮询读结果。
- **上板验证通过**（连续声源准、拍手拖尾短）；2026-11-01 加了 GATE + 显示限速，圆周不再跳变。
- **串口调试行现在 23 字节**：`M=270 E=0012AB34 V=01\r\n`（`V=<v1><v2>` 是运动判据实时值）。PS 用 AXI 读，不依赖串口。
- **PL 顶层已 BD-ready**：`radar_pl_top_bd.v` 已把 `s_axi_*`（AXI4-Lite 从机）和 `m_axis_audio_*`（波束音频流）引出到顶层端口，等你接 PS（`radar_pl_top.v` 是同功能的自检版，给 A 自己烧板验证用）。
- **波束成形干净音频已实现（2026-10-19，仿真 PASS）**：PL 按当前 DOA 做分数延时求和，输出 1 路干净的 48.828kHz 单声道音频，**就是识别 CNN / 声纹的输入**（见第五节）。
- 串口仍打印 `M=<角度> E=<能量>`（调试用，可不管）。

---

## 二、你要做的（B）

1. **建 Block Design**：PS7 + AXI Interconnect，把 `M_AXI_GP0` 接到 `radar_pl_top_bd` 的 `s_axi_*` 从机，Address Editor 配 **0x43C00000**（4KB）。
2. **跨时钟**：`s_axi_*` 同步于 50MHz sys_clk。Interconnect **从口跑 50MHz、主口 100MHz**，自动跨时钟，PL 顶层不用改。
3. PS 读寄存器（见第四节）。读 DOA 前建议先读 `VERSION`（0x1C）自检连接。
4. **接音频流**（识别用）：`m_axis_audio_*` → **异步 FIFO（50→100MHz）** → **AXI DMA 的 S2MM** → DDR。每次 1024 样本（2KB，tlast 收尾），PS 拿到就是 48.828kHz 单声道 PCM（见第五节）。

> 注：`radar_pl_top_bd` 是**普通 RTL 模块**（未打包成 IP），BD 里用「Add Module」加进来；工程里必须已有 `fft_512` FFT IP 核，否则综合报「fft_512 not found」。
>
> **两个顶层的区别**：
> - `radar_pl_top_bd.v` —— BD-ready，带 `s_axi_*`（**你接 PS 只用这个**）。
> - `radar_pl_top.v` —— 自检版，`s_axi_*` 已 tie-off，能单独 Generate Bitstream、串口打 `M/E`（A 自己烧板验证用，别拿它接 PS）。

> ⚠️ **BD 外部端口必须按原名引出**，否则 `.xdc` 的引脚约束对不上。在 BD 里把 `radar_pl_top_bd` 的这些端口 Make External 时，名字保持：
> ```
> sys_clk  sys_rst_n  sd[7:0]  sck  ws  led0  led1  uart_txd
> ```
> 如果 Vivado 自动命名成 `sd_0[0]`、`sck_0` 之类，把 `.xdc` 里的 `get_ports sd[0]` 同步改成新名字即可（共 13 个引脚约束，见 `src/radar_pl.xdc`）。

---

## 三、PS7 配置（B 已回传，2026-10-15 确认）

| 项目 | 值 |
|---|---|
| DDR3 板上实装 | NT5CC256M16×2，1GiB，32bit，1.35V |
| PS7 Memory Part | DDR3 (Low Voltage) / MT41K256M16 RE-125 |
| DRAM 总线 | 32 Bit，ECC Disabled，Burst 8 |
| DDR 时钟 | 533.333 MHz |
| PS 输入时钟 | 33.333 MHz |
| FCLK_CLK0 | 100 MHz（DMA + PS 互连用） |
| 雷达模块时钟 | 50 MHz（不变，sys_clk） |
| AXI4-Lite 基地址 | 0x43C00000，4KB，走 M_AXI_GP0 |

---

## 四、寄存器表（当前）

| 字节地址 | 名称 | 属性 | 说明 |
|---|---|---|---|
| 0x00 | CTRL | W | bit0=START，bit1=SOFT_RST（AUTO_RUN=1 时不必用） |
| 0x04 | STATUS | R | bit0=BUSY，bit1=DONE |
| 0x08 | DOA | R | **MVDR 精测角度，有符号度 -180..+180**（32bit 符号扩展）；含运动超前补偿（静止声源与未补偿值相同） |
| 0x0C | S_MIN | R | Q16.16 原始值（调试） |
| 0x10 | SHIFT_USED | R | 调试 |
| 0x14 | SNAP_CNT | R | 已累积快拍数 |
| 0x18 | BIN_LIST | R | {16'd0, BIN0, BIN1} |
| 0x1C | VERSION | R | `0x4D564452` = "MVDR"（先读它自检连接） |
| 0x20 | DAS_DOA | R | DAS 粗 DOA（有符号度） |
| 0x24 | DAS_STATUS | R | bit0 = 有无信号（DAS 能量门限） |
| 0x28 / 0x2C / 0x30 | BIN_LIST2/3/4 | R | 其余 6 个 bin |
| 0x34 | PWR | R | **MVDR 总能量 E（无信号≈0，判断有没有声）** |

---

## 五、顶层端口

```
input   sys_clk      // 50MHz（U18）
input   sys_rst_n    // 低有效复位（N16）
input   sd[7:0]      // 8 路麦克风数据
output  sck, ws      // I2S 位时钟/字选择 → 8 个 INMP441
output  led0, led1   // 心跳灯 / DOA 命中灯
output  uart_txd     // 调试串口（可不用）
// AXI4-Lite 从机（16 根，时钟=sys_clk 50MHz）：
input   s_axi_awaddr[31:0], s_axi_awvalid, s_axi_wdata[31:0], s_axi_wstrb[3:0],
        s_axi_wvalid, s_axi_bready, s_axi_araddr[31:0], s_axi_arvalid, s_axi_rready
output  s_axi_awready, s_axi_wready, s_axi_bresp[1:0], s_axi_bvalid,
        s_axi_arready, s_axi_rdata[31:0], s_axi_rresp[1:0], s_axi_rvalid
// AXI4-Stream 主口（波束音频，时钟=sys_clk 50MHz）：
input   m_axis_audio_tready
output  m_axis_audio_tdata[15:0], m_axis_audio_tvalid, m_axis_audio_tlast
// AXI4-Stream 主口（8 路 FFT 频谱，时钟=sys_clk 50MHz）：
input   fft_axis_tready
output  fft_axis_tdata[63:0], fft_axis_tvalid, fft_axis_tlast
```

### 频谱流（PC 画频谱用，2026-10-22 新增）

| 项目 | 值 |
|---|---|
| 格式 | `tdata = {imag[31:0], real[31:0]}`，64 bit，**real 在低 32 位** |
| 内容 | 8 路 × 512 bin 分时，每路第 512 点 `tlast` 拉高 |
| 一轮 | 4096 字 = **32 KB**，**每 10.49 ms 一轮**（8 路谱来自同一时刻） |
| 速率 | 平均 **3.1 MB/s**；**突发**集中在 ~82 µs 内吐完 32 KB |
| 时钟 | 50 MHz，与 AXI4-Lite、波束音频同一时钟域 |
| 背压 | `fft_axis_tready` **与内部 MVDR 共用**（同一路流、同一握手）。DMA 停 → MVDR 也暂停，不丢数据 |

> ⚠️ **FIFO 深度要按 32 KB 突发估**，不能按 3.1 MB/s 平均值估，否则会丢帧。
> 若要两路独立背压，在 BD 里加 **AXI4-Stream Broadcaster**。
>
> 用途：PS 把 8 路复数谱转发给 PC，PC 画「实时频谱 / 8 方位频谱 / 语谱图」。
> 8 方位谱需要**波束成形**（不能直接拿 8 个麦的幅度谱当 8 个方位，幅度几乎一样、方向信息在相位里），
> 算法与角度映射见根目录 `频谱显示.md` 第三、九节。

### 波束音频流（识别输入）

| 项目 | 值 |
|---|---|
| 方向 | PL 主口 → PS 从口（DMA S2MM 搬进 DDR） |
| 数据 | `tdata[15:0]`，**有符号 16bit 单声道 PCM**（高位符号扩展，低 16 位有效） |
| 采样率 | **48.828 kHz**（= 50MHz/16/64，与 I2S 同步） |
| 数据率 | 16bit × 48.828k ≈ **97.7 kB/s**（很小，DMA 随便跑） |
| 帧边界 | `tlast` 每 **1024 样本**拉一拍 = **21.0ms 一帧**（≈ 声音分块长度，可直接切 mel 谱） |
| 指向性 | 已按当前 MVDR DOA 做分数延时求和 → **主瓣对准声源、非相干噪声被压制**（仿真相干增益 ≈ 7×） |
| 静音行为 | DOA 仍在跟随时持续输出；**没声音时输出的是波束内的噪声**，不含门控（要不要门控由 PS 用 0x34 PWR 判断） |
| 跨时钟 | 流同步于 **50MHz**；接 100MHz 的 DMA 需在 BD 里加**异步 FIFO（50→100MHz）**，与 AXI4-Lite 一样在 BD 解决，PL 不改编 |

> 建议 BD 结构：`m_axis_audio_*` → AXI4-Stream Data FIFO（异步，50→100MHz）→ AXI DMA 的 `S_AXIS_S2MM` → `M_AXI_S2MM` 写 DDR；DMA 每次搬一帧（1024 样本 = 2KB，tlast 自动收尾）。PS 侧拿到数组就是 48.828kHz 单声道 PCM，可直接送 CNN。

---

## 六、注意（重要）

- ⚠️ **现在不能单独 Generate Bitstream**：`s_axi_*` 引出后没有物理引脚，会报 `[Place 30-374]`。这是预期的——设计是 BD-only，必须走 Block Design 挂 PS。
- **FFT 频谱流已引出**（2026-10-22 新增，`fft_axis_*` 4 个端口）。**识别仍用「波束成形干净音频」那一路**，频谱流只是给 PC 做可视化（实时频谱、8 方位频谱、语谱图）。两路各接一个 AXI DMA 的 S2MM。
- 音频模块的算法已仿真验证（`fft_demo/sim/bf_audio_out_tb.v`：正确角度 RMS 8305 vs 理论 8485，错角压制 7.1×），但**还没上板听过**——第一版如果有杂音/断续，先查 DMA 的 tready 背压和跨时钟 FIFO。
- ~~旋转声源时 DOA 会跳变~~ **2026-11-01 已解决**：MVDR 输出端加了 GATE（剔单帧离群）＋显示限速（≤8°/帧；能量瞬态期间、以及一次跨过 >45° 的大换向，都放宽到 25°/帧）。圆周实测 7171 个连续帧对里 ≥9° 的变化 0 次，所以 **PS/PC 端不用再做任何平滑**，直接用 `0x08` 的角度画图即可。
  - 任何情况下**相邻两帧的角度差都有界**（≤25°）：180° 的换向约 150 ms 走完（8 帧），拍手约 100 ms。所以 PC 端如果要做插值，按 21 ms 均匀采样就行，不会出现需要特殊处理的长跳跃。
  - 注意：PC 端绘图**遇到时间戳断层（>0.5 s）要断开折线**，否则断流期间的角度差会在图上画成一条跳变线（我们这边 240 s 的记录里 6 次"跳变"全是这种记录空档）。

---

## 七、交付包说明

- 交付包由 Vivado **Project → Archive** 生成，里面是所有 RTL 源文件、`.mem` 初始化文件、约束、FFT IP（`fft_512.xci`）和仿真文件，**不含** `.runs`/`.cache`/bit 等构建产物。
- 解压后直接打开 `radar_pl.xpr`。Vivado 会提示重新生成 IP（`fft_512`），点 OK 等它跑完即可。
- 工程默认 top 是自检版 `radar_pl_top`。你做 BD 时：把 `radar_pl_top_bd.v` 用 **Add Sources** 加进工程 → 在 Block Design 里 **Add Module** 选 `radar_pl_top_bd` → 把 BD wrapper 设为 top。完成后 `radar_pl_top` 不会再被综合。
