# CLAUDE.md — 基于 ZYNQ 的声学雷达 · FPGA/PL 端

> 归档说明：本文是开发期间的工程协作记录，按原样保留。文中出现的 `D:\...`
> 等绝对路径、以及旧的中文文档名（如「频谱显示.md」「比赛报告架构.md」）
> 均为当时状态；在仓库内请按 `src/`、`sim/`、`data/`、`report/` 的相对位置查找。
>
> **2026-11-04 补记**：本文截止于 2026-10-22。之后的三次关键协作——
> ① 拍手角度跳变的根因（先取证、再改代码）；② `sd2_acc` 无符号扩展 bug
> （只有 RTL 逐位回放才能发现）；③ Vivado 综合「卡死」的排查——已整理进
> [`design_report.md`](design_report.md) 第 8 章。方法沉淀在
> [`../skill/transient-tdoa-first-arrival/`](../skill/transient-tdoa-first-arrival/)
> 与 [`../skill/fpga-ai-collaboration/`](../skill/fpga-ai-collaboration/)。

## 项目一句话
用一圈 8 个麦克风听声辨位 / 识别，在雷达屏上指给你看。核心是可重构多通道阵列信号处理平台，追求"最精确"的定位精度。

## 协作角色（重要，每次会话先看这里）
- 用户 = 队员 **A，只负责 PL（FPGA 逻辑）**，代码最终交接给队友 **B（PS/ARM + Linux）** 和 **C（PC 上位机 + 声源识别）**。
- 用户是 **Verilog / Vivado 初学者**，用 Vivado 2026.1，需要一步步带、讲清楚原理。
- 交付边界：只写 PL 侧。每个模块的**接口（端口、协议、时序）要注释清楚**，方便队友对接；不越界做 PS/PC 的事。

## 硬性约束
- 只能用 **AMD / Xilinx** 芯片（明确不要国产 FPGA）。
- 板子固定：正点原子 ZYNQ-7020 领航者，芯片 **xc7z020clg400-2**。
- 关键引脚：`sys_clk=U18`(50MHz)、`sys_rst_n=N16`、`led[0]=H15`、`led[1]=L15`，IOSTANDARD LVCMOS33。

## 技术方案
- 麦克风：INMP441（I2S 数字 MEMS）×8，24bit。8 个共用 SCK/WS，各占一根 SD 线。采样率用**整数分频** 50MHz/16(SCK=3.125MHz)/64(WS) = **48.828kHz**（略高于标称 48k +1.7%），导向 ROM 的 f0 已按此重生成（见「关键决策」）。
- 信号链：I2S 采集 → FFT → 波束成形 / MVDR / MUSIC 测向（PL）；声源识别（分类）放 **PC 端（队友 C）**，不走 DPU（见「关键决策」）。
- 定位精度目标 ±1°~2°（MUSIC，受物理孔径限制，1° 是显示粒度非分辨力）。

## 进度清单
- [x] 0 LED 闪烁（LED_TWINKLE，正点原子教程，含 ILA）
- [x] 1 单通道 I2S 接收器 `i2s_rx` —— 仿真通过
- [x] 1b 8 通道 I2S `i2s_rx_8ch` —— 仿真通过（8 路互不串扰）
- [x] 2 FFT —— `fft_demo` 工程 + FFT IP 核 `fft_512`（512点/16bit/streaming/natural order/unscaled/truncation），喂 1500Hz 正弦 → 峰值精确落在 bin 16，仿真 PASS（峰值幅度 ≈ 1,023,700 = 4000×256；杂散底 -62dB，是定点截断的正常噪声地板）
- [x] 2b 采样流→打包器→FFT 链路 —— `i2s_to_fft_axis`（慢速采样流攒满 512 点 → 突发灌 FFT，AXI4-Stream 输出）仿真 PASS，peak bin=16 正确。方案 A（1 核分时复用 8 路）的核心数据通路已验证
- [x] 2c 真实 I2S + CDC 链路 —— `i2s_rx`(SCK域) → `i2s_cdc`(2级同步器+24→16) → `i2s_to_fft_axis` → `fft_512` 整链打通，`i2s_fft_top` 顶层 + `i2s_fft_tb`(I2S主机模型) 仿真 PASS，peak bin=16。首次验证异步时钟域下不丢点
- [x] 2d 8 路分时复用 —— `i2s_cdc_8ch` + `i2s_fft8_axis`(乒乓缓冲2 bank×8路×512 + 通道分时 FSM) + `i2s_fft8_top` + `i2s_fft8_tb`，8 个不同频率同时灌入，各自峰值精确落 bin 16~23，零串扰零丢点，仿真 PASS
- [x] 3a 波束成形算法验证 —— `bf_das_tb`（纯 testbench 浮点，无 RTL）验证 delay-and-sum 导向向量公式 + 圆阵几何（UCA 8 麦、R=5cm、c=343）：峰值精确=声源角度（30°/0°/-45° 全对，功率 64=8²），空间谱关于声源方向严格对称。公式正确
- [x] 3b 波束成形 RTL —— `bin_extract_8ch`(从FFT流抽目标bin的8路谱) + `bf_das_core`(8路复数加权求和 MAC，定点 X=24bit / W=Q1.15 / y=48bit) + `bf_das_rtl_tb`(30°方向4031Hz声源带真实时延差，全链路 I2S→FFT→抽bin→扫角→DOA=30°) 仿真 PASS，空间谱关于声源方向对称
- [x] 4a MVDR 算法验证 —— `bf_mvdr_tb`（纯 testbench 浮点）：8×8 复数协方差矩阵 + 高斯-约当求逆，峰值=声源角（30°/-45° 全对），旁瓣比 DAS 低约 50dB（±10° 处 DAS 0.4 → MVDR 0.002），PASS
- [x] 4b MUSIC 算法验证 —— `bf_music_tb`（纯 testbench 浮点）：特征分解用幂迭代+收缩法（deflation），单声源 30° 峰值精确命中；双声源 30°+40°（相距10°）DAS 糊成一个峰(35°)，MUSIC 分成两峰(31°/41°，±1°=扫描步长) 成功分辨，PASS。幂迭代 80 次收敛，导出 CSV 供画图
- [x] 4c-1 协方差矩阵累积 RTL —— `cov_accum_8x8`（单个复数 MAC 串行算上三角 36 项，64bit 累加器）+ `cov_accum_8x8_tb`（64 位整数逐项精确比对，36 项全等）仿真 PASS
- [x] 4c-2a MVDR 定点精度验证 —— `bf_mvdr_fxp_tb` 扫 FBITS=24→12：**四舍五入**后 16 位小数足够（R⁻¹·R 误差 0.8%），12 位也能过（10%）。关键教训：**舍入方式比位数重要**——原 Q16.16 用 `>>16` 截断（向负无穷）→ R⁻¹ 非正定、s 变负、峰位错；改四舍五入即修好
- [ ] 4c-2 MVDR 矩阵求逆 RTL（32bit Q16.16 + 四舍五入 + 复数除法器 + 高斯-约当 FSM）
  - [x] 4c-2b `complex_div` 复数除法器 —— 恢复余数除法器 64÷64，re/im 串行 ~131 拍，四舍五入 = 被除数先加 d/2。算法 q = a·conj(b)/|b|²。`complex_div_tb` 8 用例全过。**踩坑记录见下面「testbench 竞争」条目**——模块一路都是对的，是 tb 驱动方式错，曾误判为「差一个事务」
  - [x] 4c-2c `mat_inv_8x8` 高斯-约当求逆 FSM —— 仿真 PASS。实测 **2196 拍 @50MHz ≈ 44us**；`max|R⁻¹R − I| = 0.00594`（比 4c-2a 浮点模型的 0.008 还好，因为「求一次倒数再乘」的舍入路径不同），元素相对误差 1.42%。要点：部分主元（串行扫 8 行省乘法器）→ 换行 → **一次求倒数 r=1/B[col][col] + 16 次复数乘**（不做 16 次除法，省 ~1900 拍/列）→ 消元 → 回代 → 流式输出 64 拍。流式接口：`din_valid` 拉 64 拍喂 8×8 行优先，`dout_valid` 拉 64 拍出 R⁻¹。舍入 `(x+2^15)>>>16`。坑：`f=B[i][col]` 必须锁存（j 扫到 j==col 时该元素会被改成 0）。**串行化重写（2026-10-14，Place 拥塞根因）**：原版 16 路复数乘并行展开成巨量 LUT（**28645 = 整芯片 62%**），Place 报 13300 slices 拥塞挂死；改成 **2 读口 + 1 个共享复数乘法器**由 FSM 时分复用 → LUT **28645→6723**（−76%）、DSP 76→45、FF 不变，整设计 LUT 87%→~46%。**Q 格式对齐 bug（串行化首版仿真 108% 相对误差）**：复数乘乘积是 Q24.32（32 位小数），必须先 `rnd16`（>>16 对齐二进制点）成 Q12.16 再与另一 Q12.16 相减，否则把 Q24.32 直接减 Q12.16 尺度错 2^16 倍
  - [x] 4c-2d `cov_to_q16` 适配层 —— 仿真 PASS（65 拍，逐项精确整数比对 64/64 全等）。共轭展开（36 项上三角 → 完整 8×8）+ **自适应归一化**（`shift = MSB(max) - 16`）。注意：归一化后 max 落在 **[1.0, 2.0)**（不是正好 1.0）——MSB 是下标，`[2^49,2^50)` → shift=33 → 结果 `[2^16,2^17)`。实测 max=1125899837105152 恰在 2^50 下方 0.0000062% → 得 131072(=2.0)，吃满量程。**MSB 在临界值附近会抖 1**，属正常，只要 tb 与 DUT 的 shift 一致即可。自检：单声源秩1协方差所有 `|R[i][j]|` 相等（实测 √(1.8655²+0.7211²)=2.0=|R[00]| ✓）。接口：`start`（接 cov_accum 的 rdone）→ 66 拍后 `dout_valid` 拉 64 拍出 Q16.16 行优先，`shift_used` 输出实际移位数
  - [ ] 4c-2e MVDR 扫角 —— 拆两步
    - [x] 4c-2e-1 `mvdr_sweep` —— 仿真 PASS。30°/−45° DOA 精确命中（err 0），**min s = 0.9987 vs 浮点模型 0.9988（差 ~7 LSB）→ 整条定点链路无额外偏差**。`181 spectrum pts` 全收齐 → `a_req` 握手协议可靠，可安全换 ROM。s(θ)=a^H R⁻¹ a 分两步：`q = R⁻¹·a`（8×8 复数 MAC，64 拍）→ `s = Σ(a_re·q_re + a_im·q_im)` 只取实部（Hermitian 二次型虚部恒 0，省一半）。扫 181 角（−90..90）。累加器 64bit 全精度，只在写 q/s 时四舍五入一次。**握手**：模块在 `S_ANG` 拉高 `a_req`，源必须随后 8 拍连续给 avalid+8 通道导向值。约 14700 拍/次（294us@50MHz）
    - [x] 4c-2e-3 全链路集成 tb `mvdr_chain_tb` —— **仿真 PASS，MVDR PL 算法通路端到端打通**。四模块自动串联零漏拍（`181/181` spectrum points → `dout_start` wiring 正确），DOA=30° 精确。**关键**：R 由 cov_accum 真实累加 → 每个快拍必须加真实噪声，否则 R 秩 1 奇异不可逆；噪声 `$random` 均匀 A=700000 → σ²/|s|²≈0.0093。两个数值现象（都不是 bug）：① `shift_used=34` 而非 33——噪声让 R[0][0] 涨 0.93%，恰好把 MSB 从 49 顶到 50；② `min s=1.1646` 而非 0.9988——**有限快拍偏差**，样本协方差估的 MVDR 值偏高约 `K/(K−M+1)=64/57=1.123`（预期 1.121，实测 1.166，余下 3.8% 是单次实现涨落）。**只影响 s 数值，不影响峰位**；真实系统同样存在，加大 K 可改善
    - [x] 4c-2e-2 导向向量 ROM —— **仿真 PASS，MVDR 至此 100% 闭环**。`steer_rom.v`（BRAM 181×8 复数 Q16.16 = 92.7kbit ≈ 3 BRAM，`$readmemh` 初始化）+ `gen_steer_rom_tb.v`（**跑一次**生成 `src/steer_re.mem`/`steer_im.mem`，各 1448 行）+ `steer_rom_tb.v`（mvdr_sweep + steer_rom 对接，tb 不再管导向向量）。`mvdr_sweep` 补了 `a_ang` 输出（ROM 寻址用）。**关键校验**：`min s = 0.9987` 与 tb 手工喂数那次**完全一致** → ROM 数据与浮点导向向量逐位一致。**握手坑**：`a_req` 在收满第 8 拍的**下一拍**才拉低，所以 ROM 吐完 8 拍必须进 `S_WAIT` 等 `a_req` 落下再回 IDLE，否则会误发一整轮多余数据
  - [x] 4c-2e-0 模块串联铺垫：给 `cov_to_q16` / `mat_inv_8x8` 各加 `dout_start` 输出（64 拍数据**前一拍**拉高）——否则下游拿 `done` 当 start 会错过第 1 个数据（done 在最后一拍才拉）。纯新增输出，不影响原 tb
- [ ] 4c-3 MUSIC 特征分解 RTL（Jacobi）
- [x] 5a MVDR 的 AXI 外壳 —— **仿真 PASS，队友 B 可以开始联调**。`axi_lite_regs.v`（通用 AXI4-Lite 从机 → `wr_en/wr_addr/wr_data` + `rd_addr/rd_data`）+ `mvdr_axi_top.v`（内部把 `bin_extract_8ch → cov_accum → cov_to_q16 → mat_inv → mvdr_sweep ← steer_rom` 整条接好）+ `mvdr_axi_tb.v`（tb 扮 PS）。实测：VERSION/DOA/SNAP_CNT=64/SHIFT=34 全对，`STATUS=0x02`（**注意：完成后 BUSY=0 DONE=1 → 就是 0x02，不是 0x03**）、DOA=30°，全套 ~50000 拍。**寄存器映射**：0x00 CTRL(W: bit0 START 自清/bit1 SOFT_RST)、0x04 STATUS(R: bit0 BUSY/bit1 DONE 粘滞)、0x08 DOA(R 有符号度)、0x0C S_MIN、0x10 SHIFT_USED、0x14 SNAP_CNT、0x18 TARGET_BIN、0x1C VERSION("MVDR")。**仿真长度技巧**：bin_extract 只是"数到 43 就抓、tlast 归零"，所以 tb 每通道只发 44 bin（不是 512），一帧 352 拍而非 4096 拍，否则 64 帧 26 万拍跑不动
- [x] 5a-1 采样率定案 + ROM 重生成（2026-10-01）—— 定整数分频 50MHz/16/64=48.828kHz（见「关键决策」），`gen_steer_rom_tb` f0 改 4100.8Hz 重跑生成 mem，`steer_rom_tb`（30°/−45° err 0，min s=0.9988）与 `mvdr_axi_tb`（DOA=30，SNAP=64，SHIFT=34）全 PASS → 验证整数分频**零算法损失**（min s 与改前 0.9987 一致）。`mvdr_sweep_tb`/`mvdr_chain_tb` 手动喂向量、自洽未改。
- [ ] 5b AXI 待补：`TARGET_BIN` 目前是编译期参数（要运行期可改需给 `bin_extract_8ch` 加输入口 + 同步改 `bf_das_rtl_tb`）；AXI 时钟=核时钟（PS 独立时钟需加 CDC）
- [ ] 5 交付队友（识别移交 PC，DPU 已放弃——7020 LUT 塞不下，见「关键决策」）
- [ ] 6 上板集成（真实麦克风 + 真实时钟 + 真实 FFT，最后接 AXI 交付）
  - [x] 6a `i2s_master` —— I2S 主机（生成 SCK=3.125MHz / WS=48.828kHz，WS 对齐 SCK 下降沿），`i2s_master_tb` PASS（SCK 周期 320ns、WS 周期 20480ns）。放 `radar_pl\src\`，用 50MHz 晶振（已确认 `i2s_fft8_axis` 由 sample_valid 驱动、无 100MHz 依赖，全链路 50MHz 可跑）
  - [x] 6b `radar_pl_top` 顶层 + 约束 + 上板测试 tb（2026-10-01）—— 例化 i2s_master + i2s_fft8_top，全链路 50MHz。**麦克风引脚定案**（底板 J4 排针 = BANK13，Z7020 专属，3.3V）：`sck=U5`(J4-3)、`ws=T5`(J4-4)、`sd[0]=V7`(J4-5)、`sd[1]=U7`(J4-6)、`sd[2]=W8`(J4-7)、`sd[3]=V8`(J4-8)、`sd[4]=U9`(J4-9)、`sd[5]=U8`(J4-10)、`sd[6]=U10`(J4-11)、`sd[7]=T9`(J4-12)，全 LVCMOS33。`radar_pl/src/radar_pl_top.v` + `radar_pl/src/radar_pl.xdc` + `radar_pl/sim/i2s_fft8_tb.v`（主机模型按真实 INMP441：**只在左声道发数据、右声道静音**，8 路各 16+ch 整周期正弦，验 peak bin 16~23）。fft_tdata/tvalid/tlast + sck/ws/sd 全标 mark_debug，Vivado Setup Debug 可自动插 ILA。led0 心跳 ~1.5Hz、led1 收首帧后常亮。
  - [x] 6c `i2s_rx` 双声道采样率 bug 修正（2026-10-01）—— 旧版在 WS **两个边沿**都采（左+右各出一样本）→ 真实采样率翻倍 97.656kHz、一半样本是 0，和 bin=43 / 48.828kHz 对不上。**已改成只在 WS 下降沿（左声道）采**，1 样本/WS 周期 = 48.828kHz。若板测全 0（WS 极性/L/R 接反），把 `ws_r1 && !ws` 改成 `!ws_r1 && ws`。**注意**：i2s_rx 旧副本还在 `i2s_rx\`、`i2s_rx_8ch\` 两个工程里，`radar_pl\src\i2s_rx.v` 才是修正版（i2s_rx_8ch.v 用 generate 例化它，无副本问题）。
  - [x] 6d **上板硬验证通过（2026-10-01）**—— 真实硬件跑通整条 I2S→FFT 链路。无 ILA（Vivado 2026.1 BASIC license 不支持 create_debug_core），改用两颗底板 LED 验证：led0=自由计数心跳 ~1.5Hz（确认 50MHz 时钟）、led1=每收 128 帧频谱翻转 ~3Hz（确认复位松开 + 8 路采样 + 乒乓缓冲 + FFT 持续出帧）。**底板 LED 是高电平点亮**（引脚→LED→GND，输出 1=亮；曾误判成低电平，见 6e）。**踩坑**：用户第一次"上板"没点 Program Device，FPGA 实际没配置、引脚悬空 → LED 常亮，曾误判为时钟/复位问题；重新烧录后一切正常。
  - [x] 6e **数据自检通过（2026-10-01）**—— 上板放 4kHz 纯音，ch0 帧峰值 bin 正确落在 42（±1），说明真实麦克风接线 + I2S + FFT + 数据全部正确，不只是"链通"。led1 = peak_match ? 1（高电平点亮）：**4kHz 常亮=成功**、闪~6Hz=帧流但峰值错、灭=链路卡住。**踩坑（LED 极性）**：led1 最初按低电平点亮写 `peak_match ? 0`，4kHz 检测成功时输出 0 → 灯反而灭，与原理图核实后确认底板 LED 是**高电平点亮**，反转成 `peak_match ? 1` 后正常。**下一阶段：把 fft_tdata/tvalid/tlast 接到 mvdr_axi_top 做波束成形（MVDR 已在仿真 100% 闭环，见 4c/5a），上板测真实 DOA。**
  - [x] 6f **MVDR 上板测向成功（2026-10-11）**—— 6e 之后把 fft 流接进 `mvdr_axi_top`（AUTO_RUN=1、无 PS，AXI 端口 tie-off），上板放 4.1kHz 纯音：**DOA 稳定且准确跟踪声源角度**（中心实测稳在 ±2~5°，串口输出 `DOA=±XX E=XXXXXXXX`）。**决定性修复 = 协方差对角加载**（见「关键决策」）：`cov_to_q16.v` 输出时给对角线加 `DL=1024`（ε≈1.56%）—— 不加时高信噪比下 R 接近秩 1、噪声特征值≈0，Q16.16 定点求逆把 1/λ_min 放大到溢出 → 「有信号但 DOA 仍随机跳 ±90」。**放弃 2kHz 方案**：2kHz 波长 17cm > 线性阵列 11.2cm（D=0.65λ）、分辨率 ~88° 分不清方向；4kHz 是 1.34λ、~43° 才够用（远场 2D²/λ≈30cm，声源要放 30cm 外）。当前参数（`radar_pl_top.v`）：`TARGET_BIN=43`、`K=128`（更新 ~0.75Hz）、`TARGET_DOA=0`、`TOL=2`、`HOLD=3`、`PWR_TH=0x40`。LED 逻辑：有信号且 |DOA−TARGET|≤TOL 常亮、有信号但偏慢闪、无信号灭。
  - [x] 7 DAS 粗测通道（先粗后精，时间域延时求和）—— 新建 `das_scan_top.v`（8 路分布式 RAM 延时线 + 分数延时 2 抽头线性插值 + 181 角 1° 步进扫角 + argmax，窗口 WIN=1024 ≈21ms）+ `das_scan_tb.v` 仿真 PASS（8kHz 源 θ=+17° → das_doa 收敛 +17°）。**时序修复（2026-10-14）**：原版「ROM 读→插值→平方→累加」33 级组合、WNS −6.4ns；加 3 级流水线（qx 锁存 8 路样本 → qy 锁存插值 → beam_sq 平方）→ 20 级、WNS **+6.78ns** 收敛。**FSM 坑**：扫完一角 ang++ 后必须回 S_SCAN0 重新锁存样本，否则所有角累加同一角度、argmax 恒 −90。
  - [x] 8 频谱通路（第一阶段 · 纯 PL）—— 背压修复 + 接口文档（2026-10-14）。**背压修复**：`bin_extract_8ch` 加 `s_axis_tready` 输入、采样门控 `tvalid` → `tvalid && tready`；`mvdr_axi_top` 的 `s_axis_tready` 由 output 恒 1 改成 input 透传——将来接 DMA/FIFO 后下游满时 FFT 暂停（tvalid 保持），不认 tready 会**重复采样同一拍**、协方差算错。`fft_axis_tready` 纯 PL 阶段暂拉 1（等价原来 m_axis_data_tready=1'b1，行为不变）。`PL_PS接口文档.md` 加 §8 频谱输出：tdata={im[31:0],re[31:0]} 64bit、8 路×512 bin 分时、每路帧末 tlast=1、一轮 4096 字 32KB / ~10.49ms / ~3.1MB/s。**踩坑**：曾把 `fft_axis_tdata/tvalid/tlast` 引出成顶层输出口（无引脚约束）→ Place 报 `[Place 30-374] IO Clock Placer failed`——纯 PL 无 DMA 可接，端口引出去没引脚就放不下。**教训（2026-10-15 定案）：无引脚端口引出后就不能再单独 Generate Bitstream，只能 Run Synthesis 验语法**（见进度 9）。**下一阶段：打包 IP → 交给 B → B 回 DDR 配置 → BD(PS7+DMA)，见进度 9**。
  - [x] 9 交接准备（2026-10-15）—— 纯 PL 阶段**验收通过** + 接口端口正式引出 + 交接文档。① 上板实测：broadside 声源 `D=+01 / M=+03`（都准）；偏角声源 `D=+62 / M=+49`（**M 准且稳，D 粗 ~13° 差是 DAS 线阵孔径的固有粗分辨率，不是 bug**）。② `radar_pl_top.v` 顶层**正式引出** `fft_axis_tdata/tvalid/tlast`（输出）+ `fft_axis_tready`（输入，背压）+ 完整 `s_axi_*` AXI4-Lite 从机端口 → 设计 **BD-ready**，可直接当 BD 子块或打包成 IP。③ `DAS_PWR_TH` 回退 0x8000——之前的「无 D/M 输出」其实是**线松了**，不是门限，勿再动门限。④ 写了 `交接说明_给B.md`（B 的任务 + 要回传的 DDR3 型号 / FCLK_CLK0 / M_AXI_GP0 基地址 + 接口速查）。**注意**：端口引出后**只能 Run Synthesis 验语法，不能单独 Generate Bitstream**（`[Place 30-374]`），BD 阶段这些端口接 DMA/Interconnect 内部网线后才有归属。
  - [x] 10 PS 侧配置定案（B 回传，2026-10-15）—— **DDR**：板上实装 `NT5CC256M16×2`（Nanya DDR3L，1GiB / 32bit / 1.35V），PS7 选 `DDR3 (Low Voltage)` + `MT41K256M16 RE-125`（等价型号）+ 32bit + ECC off + Burst 8 + **DDR 时钟 533.33MHz**，其余时序按该型号默认。**时钟**：PS 输入 33.333MHz；`FCLK_CLK0 = 100MHz`（DMA + PS 互连用）；雷达模块仍 50MHz。**地址**：AXI4-Lite 从机走 `M_AXI_GP0`，基地址 **0x43C00000**，窗口 4KB（`0x43C00000~0x43C00FFF`），BD 的 Address Editor 落实。**⚠️ 跨时钟（新问题）**：`s_axi_*`/`fft_axis_*` 现同步于 50MHz sys_clk，要接 100MHz 的 PS/DMA 侧——AXI4-Lite 靠 AXI Interconnect 从口跑 50MHz（主口 100MHz）自动跨时钟；AXI4-Stream 靠**异步 FIFO 50→100MHz** 接 DMA。两者在 BD 里做，PL 顶层端口不用改。
  - [x] 11 换圆周阵列 UCA（PCB 到货，2026-10-16）—— 线性测试结束，切换最终圆周阵列。**几何**：UCA 8 麦 R=50mm、α_i=i×45°、kR=2πf0R/c≈3.756。**生成脚本**：`gen_steer_4khz.py`/`gen_steer_rom_tb.v`/`gen_das_taps.py` 公式从线性 `sinθ` 改成圆周 `cos(θ−α_i)`（导向矢量 ph=kR·cos(θ−α_i)；DAS 延时 delay=D0−k·cos(θ−α_i)，k=R·Fs/c=7.118），NANG 181→361、角度 −90..+90 → −180..+180，重跑生成 4 个 .mem（steer 2888 行、das 361 行）。**RTL**：`steer_rom.v`/`mvdr_sweep.v`/`mvdr_axi_top.v`/`das_scan_top.v` 角度索引 a_ang/ang/cmp_cnt/clear_cnt 8→9 bit、角度映射 −90→−180；`doa_uart.v` 串口角度打印 2 位→3 位（`D=+030`）、消息 18→19 字节。**关键**：圆周阵列没有麦在中心，ch0 也有相位 a_0(0°)=exp(−j·kR)（不再是 (1,0)）。**上板验证通过（2026-10-16）**：`DAS D=` 四个方向全部 **±1°**（0°→−001、90°→+091、180°→+179、270°→−091，每个值连几十行不动）；`MVDR M=` 同向吻合（−007/+092/±175/−087，抖 ±7° 属正常：单 bin 4.1kHz + 1.34s 更新）。**无镜像、全 360° ✓**。
  - **ch0 安装偏移 +180°（2026-10-16）**：PCB 上 ch0 实际装在**板子最左**，而代码默认 ch0 朝 0°→ 首版上板时「最左出 −001、最右出 ±180」正好反 180°。修法：`mvdr_sweep.v` 的 `doa_deg <= deg_shift[8:0]`、`das_scan_top.v` 的 `das_doa <= deg_shift[8:0]`，其中 `deg_shift = deg_best + 180` 再 wrap 回 [−180,180]（>180 减 360）——在**输出级**统一偏移，串口/LED/AXI 自动一致。0° 参考 = 板子最右，逆时针为正。
  - **⚠️ 测向验证不能用「声源怼在麦孔上」（2026-10-16 踩坑）**：贴着一颗麦 = 极近场（距离≈0 而半径 R=5cm），那颗麦声压强几千倍、其余靠绕射，**平面波导向公式失效** → DOA 恒定偏 ~11°（曾误以为是安装偏移）。改为**半米外、同高度、按量角器摆**后偏差掉到 ±1°。验证一律用**持续声源**（4.1kHz 纯音 / 持续白噪），**别拍手**：拍手是 50ms 瞬态 + 房间混响，DAS 每 21ms 抓一次会抓到直达+反射混合方向、且混响尾巴能量仍过门限会继续打，方向乱跳（拍手只能验「有没有声音」，不能验角度准不准）。
  - [x] 12 宽带 MVDR 2-bin 融合（最小验证版，2026-10-16）—— ⚠️ **已被进度 18 的 8-bin 版本取代，本条保留为历史记录**。MVDR 从单 bin43 窄带扩成 **bin10(953.7Hz)+bin43(4100.8Hz) 非相干融合**：每个 bin 用自己的 R_k⁻¹ 和导向矢量 a_k(θ)（a 随频率变），谱相加 `s_total(θ)=Σ s_k(θ)` 找最小=DOA，能测说话/连续噪声等任意宽带声，不再只认 4.1kHz。**不能把协方差相加**（模型失配，错）。改动：`bin_extract_8ch` 抽 2 bin、`cov_accum_8x8` 2 套累加器、`cov_to_q16`×2、**`mat_inv_8x8` 复用 1 份分 2 次跑**（相位 FSM P_CP0→P_CP1→P_SW，LUT 不翻倍）、`mvdr_sweep` 128 拍装 2 个 R⁻¹（S_LOAD 只在 din_valid 时推进计数，天然支持两段间的空隙）+ 每角度 `s_total=s0+s1`（33bit 防溢出）、`steer_rom`×2（REFILE/IMFILE 指向新 .mem）、`mvdr_axi_top` 参数 `BIN0/BIN1`、寄存器 0x18 读回 `{16'd0,BIN0,BIN1}`。生成脚本 `sim/gen_steer_multibin.py`（BINS=[10,43]）→ 4 个新 .mem（`fft_demo\src\steer_{re,im}_bin{10,43}.mem`）。两个新 tb：`mvdr_sweep_wb_tb`（不依赖 .mem，DOA=-150）＋ `mvdr_axi_wb_tb`（全 AXI 链路）**仿真全 PASS**。**SNAP_CNT 寄存器 bug（已修）**：原在 mvdr_done 那拍把 snap_cnt 清 0（为下一轮准备），非自动模式下 done 后读 0x14 恒 0；修成只在「真正开下一轮」时清（AUTO_RUN 在 mvdr_done 清，非自动留到 S_IDLE 下次 START 清）。**上板前必须把 4 个新 .mem Add Sources 加进 radar_pl**（.mem 相对路径必须进工程综合才找得到，见「关键决策」）。旧窄带 tb（mvdr_sweep_tb/steer_rom_tb/mvdr_chain_tb/cov_accum_8x8_tb/mvdr_axi_tb/bf_das_rtl_tb）接口已对不上新模块，别再跑；跑仿真建议在 radar_pl 工程跑（源是 in-place 引用、干净）。

  - [x] 13 **M 提速（K 128→2）+ 停打串口 `D=`（2026-10-18）**——用户反映 D= 乱跳、M= 准但慢（0.75Hz），问能否上 MUSIC。结论：**单声源 MUSIC ≡ MVDR**（谱 1/(aᴴEₙEₙᴴa) 与 1/(aᴴR⁻¹a) 同形，都等价最大化 |aᴴa_s|²；FPGA 8×8 EVD 又贵又不更强），换 MUSIC 没用。M 慢不是算得慢（整条链 ~4.6ms = cov_to_q16×8 + mat_inv×8 + sweep 211697 拍，只占一帧 10.49ms 一半），是 **K=128 攒 1.34s 快拍才更新一次**。EMA（S=7，α=1/128）本来就持续平均 128 帧，**K 只决定多久算一次 DOA、与估计方差无关**。改法：`radar_pl_top.v` `.K(2)`、串口停打 D（`.das_done(1'b0)`）。M 更新率 0.75Hz→**~39Hz**（周期 = 攒 2 帧 21ms + 算谱 4.6ms ≈ 26ms；非精确 47.7Hz，因 S_RUN 期 `xready_g=0` 暂停攒快拍），和 D 原 21ms 视觉同顺滑、精度不掉。`das_scan_top` 保留驱动 led1。K 再降 1 → ~66Hz 也可（链 4.6ms < 帧 10.49ms，不丢 rdone）。
  - [x] 14 **S 7→5 缩短拍手拖尾（2026-10-18）**——用户测拍手，M 角度对（185/186 稳），但拖尾 ~120 行（2.5s）太长。原因：EMA S=7 时间常数 1.34s，拍完 `m≈0` 后协方差按 ×(127/128)/快拍衰减，E 从峰值掉到门限 0x40 要 ~244 快拍；门限 0x40 贴噪声底，一路打到跌穿才停。改 `S 7→5`（τ 1.34s→0.34s，衰减 ×31/32）：拖尾 ~0.6s（~24 行，4× 短），**拍手峰值不变**（瞬态远短于 τ，都只积 ~m×5）；代价稳态 DOA ±1-2°→±2-3°，但旋转声源滞后 4× 小、更跟手。门限保持 0x40。**→ 用户否决 S=5（不接受 ±2-3° 精度损失），S 已回退 7，改用自适应记忆（见进度 15）。**
  - [x] 15 **自适应记忆（fast-release）上板验证通过（2026-10-18）**——不牺牲精度的拖尾方案：`cov_accum_8x8.v` 加参数 `SF=3`/`TH_FAST=0x40`、新增快速迹 EMA `pwr_fast`（固定 SF、与 pwr_acc 同尺度）测「信号在不在」，`sig_on` 选遗忘因子——**有信号 S=7（与旧代码逐比特一致、精度不变）、信号消失 SF=3（τ≈84ms 快速忘掉）**，协方差与 E（pwr_acc）都用 `shift = sig_on ? S : SF`（常位移位+2:1 mux，不进桶形移位器，时序无负担）。拍手拖尾 2.5s→~0.3s，连续声源稳态精度不变。**上板实测用户反馈「效果很好」：连续声源稳、拍手拖尾短。**
  - [x] 17 **波束成形干净音频（PL 新增物）仿真 PASS（2026-10-19）**——新增 `fft_demo/src/bf_audio_out.v`：复用 `das_scan_top` 的环形缓冲 + tap 表 + 2 抽头分数延时插值，但**不扫角**，固定指向当前 MVDR `doa_deg` 一个方向，每样本做一次束和，输出 **16bit 单声道 48.828kHz AXI4-Stream**（`m_axis_audio_tdata/tvalid/tready/tlast`，tlast 每 `FRAME_LEN=1024` 样本 = 21ms 一帧）。束和后 `>>3` 归一化回单麦尺度。**角度映射（最容易写错，已仿真双向验证）**：`das_scan`/`mvdr_sweep` 汇报的 `doa_deg` 都做过 +180° 安装偏移，查 tap 表前必须反解：`doa≥0 → r=doa/2`；`doa<0 → r=(doa+360)/2`（r = 表行 0..180，表内角度 = r*2−180）。tb `fft_demo/sim/bf_audio_out_tb.v` 两阶段（表内 −30°/汇报 150°、表内 +60°/汇报 −120°）：**RMS 8305 vs 理论 8485（98%），错角 90° 时仅 1165（压制 7.1×），两阶段都 PASS**。两顶层都已例化：自检版 `radar_pl_top.v`（tready 拉 1，无消费者）、BD 版 `radar_pl_top_bd.v`（音频流引到顶层端口给 B 接 DMA）。**顺带修**：`doa_das/das_sig` 等 wire 提前到 `u_mvdr` 之前声明（xvlog 报 implicit declaration）。**A/B 对照（2026-10-19，上板实测）**：用户报「加音频后旋转不如之前丝滑」。`radar_pl_top.v` 加 `localparam AUDIO_EN` 开关（0 = 模块不例化、综合时完全优化掉）。两次同速旋转实测对比：带音频大跳 +125°/+50°，不带音频大跳 +62°/+38°，且两版的快速爬升序列（100→102→111→116→118→119→120）**完全一样**，跳变时 E 都连续 → **音频模块与 DOA 平滑度无关（已排除）**。真实原因 = EMA S=7 记忆 1.34s × 手转声源，协方差是过去 1.3s 多个方向的混合 → 8-bin 融合谱出现两个高度相近的峰 → 谷点在两峰间翻。静止声源不受影响，属算法固有行为。**可选修法（未做）**：运动自适应记忆——检测 DOA 在连续 N 次更新里持续同向移动 → 临时切 S=5（τ 0.34s），停止后回 S=7；静止精度零损失。
  - [x] 16 **下一阶段定案：声源识别全放 PS（脱机）+ PL 加波束音频输出（2026-10-18）**——识别不依赖 PC，链路 PL→PS→PC（PC 只显示）。分工与两个识别任务的难度校准见「## 声源识别子系统」。**PL 唯一新增物**：按 DOA 波束成形输出一路干净音频（DMA 给 PS）。**交付前待办**：`radar_pl_top.v` 的 AXI4-Lite tie-off 恢复为顶层端口（BD-ready），让 PS 读 DOA+pwr。

  - [x] 18 **8-bin 宽带 MVDR 非相干融合（2026-10-17/18）** —— 从 2 bin（bin10+bin43）扩到 **8 bin：5/10/15/20/25/31/37/43 → 476.9 / 953.7 / 1430.5 / 1907.4 / 2384.3 / 2956.6 / 3528.8 / 4100.8 Hz**（kR = 0.437…3.756 拉开，栅瓣随频率错开 → 多 bin 相加主瓣相干增强、栅瓣互相抵消，消除单频跳变）。**省资源的关键（D2）**：`cov_to_q16` 只例化 **1 份**（前面加 8:1 R 选择 mux），`mat_inv_8x8` 也仍 1 份，后处理序列 FSM 串行跑 8 次（`conv_bin` 0..7 → sweep）；否则 8 份 cov_to_q16 ≈ 8×3500 LUT 直接爆。具体改动：`bin_extract_8ch` 参数 `BIN0..BIN7`、`cov_accum_8x8` 8 套累加器（每快拍 288 拍 MAC）、`mvdr_sweep` 装 8 个 R⁻¹（`li` 0..511）+ 每角度 `s_total` 8 项 33bit 累加（S_CMP 取低 32bit 比 `s_best`）、`steer_rom`×8。寄存器 `ADDR_BITS` 4→5，新增 **0x28/0x2C/0x30 = BIN_LIST2/3/4**（0x18 仍是前两个 bin，保持兼容）。导向表 16 个 `.mem`：`fft_demo/src/steer_{re,im}_bin{5,10,15,20,25,31,37,43}.mem`，由 `sim/gen_steer_multibin.py` 的 `BINS` 列表生成（改 bin 只改这一行）。仿真：`mvdr_axi_wb_tb` 已改 8 bin 参数。**注**：进度 13（K=2）、14/15（S=7 + 自适应）、17（旋转 A/B）的各项上板测试全部跑在这一版上（`radar_pl_top.v` 当前就是 `BIN0..BIN7`）。
  - [x] 19 **交付打包 + 完整综合/实现（2026-10-21/22）** —— 给 B 的交付包用 Vivado **Project → Archive** 生成，过程中踩到四个坑，都已解决：
    1. **Archive 只打包"工程登记过"的文件**：`radar_pl_top_bd.v`（BD-ready 顶层）和 bin 5/15/20/25/31/37 的 12 个 `.mem` **不在包内**（工程 Source 列表里没有）。源码是 in-place 引用 `../fft_demo/src/`，所以本机综合没事，但打包后 B 那边缺文件。→ 交付前要 Add Sources 补登记，或让 B 手工加（见 `交接说明_给B.md` 第七节）。**（2026-10-22 已补登记：`radar_pl_top_bd.v` 与全部 16 个 `steer_*_bin*.mem` 现已在 `radar_pl.xpr` 的 Source 列表中，重新 Archive 即可带上。）**
    2. **在 zip 里直接打开** → 52 条 `Could not find the file` + `[IP_Flow 19-993]`（路径是 `AppData\Local\Temp\...zip.403`）。**必须先解压再打开**。
    3. 打包版 `radar_pl_top.v` 曾被人改坏：`localparam AUDIO_EN = 1` **缺分号** → `[Synth 8-2716] syntax error near 'generate'`。已修（源文件本来就是对的）。
    4. 打包工程综合跑到 **Technology Mapping 时工具崩溃**（`TclStackFree: incorrect freePtr`，`hs_err_pid*` EXCEPTION_BREAKPOINT），无 .dcp —— 环境/工具崩溃，不是 RTL 问题。
    **「综合跑了半小时没跑完」的真因（重要）**：不是死循环。10/19 那次崩溃留下 **两个僵尸 `vivado.exe`（各占 3.7 GB 提交内存、工作集仅 0.03 GB）**，系统 commit 可用只剩 1.0 GB → 新的综合 worker 根本起不来。关掉后综合 ~2 分钟出结果。**判别方法**：提交内存大 + 工作集极小 = 卡死；`runme.log` 的 mtime 是否在更新；见诊断脚本。
    **新增诊断脚本 `D:\Engineering_save\FPGA\AMD_ZYNQ\check_vivado.ps1`**（只读）：一条命令看内存、vivado 进程的 commit/工作集、进程树、runme.log 静默秒数、`.dcp`/`hs_err`/`.vivado.*.rst` 标记、最近阶段与结论。用法 `powershell -ExecutionPolicy Bypass -File check_vivado.ps1 [-ProjectDir ...] [-RunName synth_1|impl_1]`。
    **结果（10/22）**：综合 **0 error / 0 critical warning / 95 warning**（00:20:42，`radar_pl_top.dcp` 100 MB）；实现 init 1.5min → opt 1.4min → **place 7.3min** → **route ~4min**，DRC **0 Errors / 21 Warnings**。**资源**：LUT **29130 (54.8%)**、FF 37545 (35.3%)、BRAM **60.5 (43.2%)**、DSP 102 (46.4%)、IOB 15 (12%)。注：`radar_pl_top_bd` 从未单独综合过，B 搭 BD 后要重新跑一遍。

  - [x] 20 **A 档大跨步 + 大变化后重建协方差（2026-11-01，已写进 RTL，未上板）** —— 两个都不碰稳态精度：
    - **A 档**（`mvdr_axi_top` 的 `SLEW_BIG_DEG=25` / `BIG_TRIG_DEG=45`）：CLAP 靠能量瞬态，只覆盖拍手；**搬动一个持续发声的声源没有能量跳变**，180° 换向按 8°/帧 要走 0.47s。改为按**距离**触发——显示角离目标 >45° 就整段用 25°/帧（= `SLEW_BIG_DEG`，单帧仍 <30° 不构成跳变），追到为止才回 8°/帧（`big_move` 寄存器，避免最后几十度又爬）。验证：`sim/sim_big.py --jump` 合成 180° 换向 **504ms → 189ms**、单帧最大 25°、>30° 帧 0；`--detail` 回放真数据，**circle_v5 只在记录空档（≥1.8s）触发、static_v4 触发 0 次**，连续录制的圆周一遍都不触发 ⇒ 8.7.13 的"圆周不跳"不受影响。
    - **协方差重建**（`cov_accum_8x8` 新增 `flush` + CLR/CLR2 状态，`mvdr_axi_top` 的 `CLR_EN`/`CLR_DEG=30`）：GATE 接受一次跨 >30° 的跳变时，288 项一次性重写成 **λ·I（对角加载）**、`k` 归零，从"噪声底 + 新快拍"重新开始，**不能清零**——K=2 时 R 只有秩 2，8 阶逆矩阵不存在，`sim/sim_clr_check.py` 实测清零后条件数 2e15、argmin 落到 −96°（真值 137°），加 λ·I 后条件数 5~17、峰始终 137°。`CLR_LD=4`（λ = 单快拍每 bin 迹/16）是条件数/对比度的折中。**踩坑**：写地址经 `waddr` 寄存一拍，写数据若用当前 `p` 就会比地址早一项（MAC 路径靠 `m_re_d` 对齐），第一版就错了；`sim/sim_clr_seq.py` 逐拍复现写端口语义确认 289 拍/288 写/λ 只落在 64 个对角位置。代价：丢 1 个快拍（21ms）+ 5.8µs 改写，只在确认大变化时一次；稳态 R 里加载占 ~2% 并继续衰减。顺带破"连续 3~8 帧锁错峰"。
    - 时延账（180° 换向）：估计器拐过来 84~170ms（不变）+ 原来被长记忆往回拽 200~700ms（→≈0）+ GATE 63ms + 显示 470→150ms ⇒ **≈0.8~1.4s → ≈0.3~0.4s**。详细推导见 `4100Hz跳变排查_20261031.md` §8.7.15/§8.7.16。

  - [x] 21 **拍手不再提速（2026-11-02，已写进 RTL，未上板）** —— 用户反馈 25°/帧 的拍手仍是"太跳变"。改动只有三处：`SLEW_EVT_DEG` 25→**6**（比普通限速 8 还低一档；先试 8 仍嫌快，2026-11-03 再降到 6）、`CLAP_HOLD` 24→**32**（窗口 0.67 s，够走 192°）、`accept_big` 增加 **`evt_cnt==0`** 条件（瞬态期间不进 A 档；不加这条的话 GATE 一接受 88° 目标 big_move 就会把限速拉回 25，等于白改）。回放（`sim/sim_clap_smooth.py`，与 RTL 逐位同逻辑）：clap_log 单帧最大 25°→**6°**、>8° 帧 **0**、到位 5 帧→**16 帧（336 ms）**；static_v4 **逐位相同**；circle_v5 只有 12/7178 帧不同（0.2%）、circle_fast 只有 6/1991 帧不同（都在记录空档/声源刚打开处）。A 档（持续声源搬移 189 ms）不受影响。详见 `4100Hz跳变排查_20261031.md` §8.7.17。

  - [x] 22 **拍手窗口只信峰值附近（2026-11-03，已写进 RTL，未上板）** —— 用户澄清 21 改的是"怎么走过去"，他要的是"落点别乱"。改动只作用在 `evt_cnt!=0`：①`gate_force` 增加 `evt_cnt==0`（窗口内不做"扣满 8 帧强制放行"）；②新增 `SIG_EN`/`SIG_DB_SH`，窗口内跟踪 `pwr_peak`，只有 `pwr > peak/2`（6 dB）的帧才能更新 `doa_tgt`（`accept_g = accept_any && sig_ok`）。**不用绝对能量门**：static_v4 的 pwr 中位 1243 < 拍手判据 2048。回放：static_v4 **逐位相同**，circle_v5 28/7178、circle_fast 19/1991、circle_slow2 52/6666 不同（全在记录空档/声源爬升段），clap_log 尾巴 147/145 → 保持 144。**未解决的**：若同一方位不同次拍手的峰值帧估计本身差几十度（单帧方差），门限救不了，要换估计方法——需同方位连拍 5 次的数据。**核对时修掉一个隐患**：`gate_force` 关闭后 `gate_cnt` 会涨到 4bit 回绕成 0，导致窗口结束后强制放行永久失效（防卡死失效）；已改为饱和在 `GATE_MAX-1`。核对手段：本机无 Vivado，未跑语法检查，逐行人工核对；新增 `sim/param_check.py` 比对 RTL 参数与回放模型常量（全部一致）；回放同步 4bit 语义后重跑四份记录结论不变。详见 §8.7.18。

## 工程 / 工作流约定
- 每步一个目录：`D:\Engineering_save\FPGA\AMD_ZYNQ\<name>\`，内含 `src\`（设计源）、`sim\`（testbench）、`create_project.tcl`（建工程脚本）。
- 建工程：`source .../create_project.tcl`；源文件用 **import_files（引用不复制）**，改完代码直接重跑仿真即可，不用重建工程。
- ⚠️ **文件副本坑**：经 GUI「Add Sources」且勾了「Copy sources into project」的文件，会在 `fft_demo.srcs\...\imports\` 存副本，**Vivado 编译的是副本不是原文件**。已在 2026-09-23 把 `src\`/`sim\` 原文件与所有副本哈希核对并同步（只剩 bf_mvdr_tb、bf_das_rtl_tb 两处旧副本，已覆盖）。**以后改文件：先查有没有 `.srcs\...\imports\` 副本，两处都改**；新增文件时取消勾 Copy 最好。
- `$display` 一律用**英文**（中文在 GBK 控制台会乱码）。
- 所有 `reg` 给初值，避免仿真出现 X。
- ⚠️ **testbench 竞争（2026-09-23 踩过，`complex_div_tb`）**：tb 在**上升沿**用 blocking 赋值改 DUT 输入，而 DUT 的输入常走 `wire` 连续赋值进组合逻辑 → 同一时钟沿内，DUT 的 `always` 块会排在连续赋值更新**之前**执行，读到**上一拍的旧组合值**（首个用例甚至读到初值 X）。症状：DUT 输出「整体差一个事务」。**修法：tb 一律在【下降沿】驱动输入**（上升沿留给 DUT 采样），或 `@(posedge clk); #1;` 后再改。这条对所有 tb 通用，写新 tb 照做。
- 采样 DUT 输出也避免同拍竞争：本工程用「固定等 N 拍再读」（延迟确定时最简单可靠），不用 `while(done)` 之类在 NBA 区轮询。
- testbench 换数据要在**帧边界**（一帧 = 64 个 sck），否则会切坏数据。
- 待教概念：**AXI4-Stream 接口**（FFT/FIR/DPU 通用流式接口）。

## 模块层次 / 接口归属（重要，易混）
PL 内部是分层的，「接口注释」和「对队友的接口」是两回事：

```
第 5 步  AXI 包装层        ← 队友 B（PS）唯一接触的地方
         │  AXI4-Stream 喂进 8 路频谱 / AXI4-Lite 寄存器读 DOA
第 3 层  bf_mvdr_core      ← 顶层算法（协方差 + 求逆）
         │
第 2 层  mat_inv_8x8       ← 8×8 高斯-约当求逆 FSM
         │
第 1 层  complex_div       ← Q16.16 复数除法器（纯内部零件）
```

- **模块注释里的接口**（如 `start`/`done`）= 给写 RTL 的自己看的「零件说明书」，让上一层知道怎么调用，**不需要队友参与**。
- **队友 B 眼里的 PL 只有两样**：AXI4-Lite 寄存器（配参数 / 读 DOA 结果）+ AXI4-Stream（喂 8 路频谱）。内部的 `complex_div`、`mat_inv_8x8` 她看不到也用不到。
- 「给 B 的接口文档」到**第 5 步**才写，那时才包 AXI 外壳。

## 关键决策（勿再纠结，除非用户主动推翻）
- 项目名：**基于 ZYNQ 的声学雷达**（放弃"顺风耳"等）。
- 芯片：ZYNQ-7020（满足"只用 AMD"）。
- 采集：INMP441 I2S（原生 48k/24bit，不用 ADS131M08）。
- FFT：用 Xilinx FFT IP 核（不手写），512 点 / 16bit / streaming。
- 采样率：**整数分频** 50MHz/16/64 = **48.828kHz**（SCK=3.125MHz），非标称 48k（板子 50MHz 分不出 3.072MHz 整数倍）。f0=43×48828.125/512≈**4100.8Hz**，`gen_steer_rom_tb`/`steer_rom_tb`/`mvdr_axi_tb` 已同步改。MMCM 也做不到：从 50MHz 出 12.288MHz 需 M/D=768/3125，D 超 128 上限。
- 声源识别（CNN 分类）：**放 PC 端（队友 C）做，不走 DPU**。原因：MVDR 上板曾实测 PL 占 **81.6% LUT / 56.8% DSP(125/220)**（大头是当时未串行化的 mat_inv=28645 LUT）；**2026-10-14 mat_inv 串行化后整设计 LUT 从 87% 降到 ~46%**，7020 仍偏紧、DPU 还是塞不下（再加频谱通路/DMA 会吃紧）；且 PC 用 Python 大模型 + 全精度，效果远好于 DPU 的 int8 小模型。PS 只读 DOA + 转发频谱给 PC。
- PS 端（队友 B）：**要装 Linux（Petalinux）**。分类要传频谱（~3.1MB/s），串口（~11KB/s）扛不住、必须走网口；网口 TCP/IP + DMA 驱动 Linux 现成，裸机要 lwIP 很折腾。裸机仅够阶段 1（只传 DOA 走串口）。建议 B 直接上 Petalinux，别走裸机弯路。
- 频谱通路（阶段 2，识别用）：PL 加 `FFT 流 → FIFO(跨 50↔100MHz) → AXI DMA → AXI HP → DDR → PS → 网口 → PC`。估 +3~4K LUT（~6-8%），总利用率 ~88-90%（偏紧，可能要先精简 MVDR 资源）。A 侧第一阶段已做（2026-10-14，见进度 8）：背压修复 + 接口文档；第二阶段（2026-10-15，见进度 9）：`fft_axis_*` + `s_axi_*` 端口正式引出、设计 BD-ready、写了交接文档。剩下的异步 FIFO + BD(PS7+DMA) 等 PS7 配置（DDR 型号）再做。
- PS7 配置（B 回传，2026-10-15，以后搭 BD 照抄）：**DDR3** 选 `DDR3 (Low Voltage)` / `MT41K256M16 RE-125` / 32bit / ECC off / Burst 8 / **533.33MHz**（板上实装 NT5CC256M16×2，1GiB，1.35V）。PS 输入时钟 **33.333MHz**，`FCLK_CLK0 = 100MHz`（DMA + PS 互连）。雷达 AXI4-Lite 基地址 **0x43C00000**（4KB，M_AXI_GP0，`0x43C00000~0x43C00FFF`）。**跨时钟**：PL 50MHz ↔ PS 100MHz——AXI4-Lite 由 AXI Interconnect 从口跑 50MHz 自动跨时钟；AXI4-Stream 用异步 FIFO(50→100MHz)。
- .mem 初始化表用**相对路径**（裸文件名），`.mem` 文件必须 **Add Sources 加进工程**（design source，不勾 Copy）——否则综合报 `[Synth 8-4445]` 找不到文件。2026-10-15 从绝对路径 `D:/...` 改成相对路径，让 IP 可移植到 B 的电脑（B 不用建 D 盘目录）。
- **对角加载（正则化）必须加**：MVDR 求逆前 `R' = R + ε·I`，ε≈1.5%（`cov_to_q16.v` 的 `DL=1024`）。不加时高信噪比下 R 秩 1、定点求逆溢出 → DOA 乱跳（2026-10-11 上板踩坑，修复后 DOA 才稳定准确）。仿真没暴露是因为 tb 加了真实噪声（σ²/|s|²≈0.0093）让 R 满秩；真实纯音噪声更低就触发了。

## 阵列几何（线性测试 → 圆周 PCB，已定）
- **当前（已切换圆周阵列，2026-10-16）**：均匀圆周阵列 UCA（下表参数）。~~之前并排测试用的线性阵列（d=0.016m、τ_i=(x_i/c)·sin(θ)、±90、有左右镜像模糊）已弃用。~~
- **最终（画板子）**：均匀圆周阵列 UCA，8 麦，参数：

| 参数 | 值 |
|---|---|
| 麦克风数 N | 8 |
| 半径 R | **0.05 m = 50 mm** |
| 麦克风角度 α_i | i×45°（i=0..7）= 0/45/90/135/180/225/270/315° |
| 目标频率 f0 | 4100.8 Hz（不变） |
| 声速 c | 343 m/s |
| 波长 λ | 8.36 cm |
| R/λ | 0.598 |
| kR = 2πR/λ | 3.7565 rad |

- **为什么 R=50mm**：防空间混叠 = 相邻麦直线距离 `2R·sin(22.5°)` 须 < 半波长。实测 2×50×sin22.5°=**38.3mm=0.458λ** < λ/2=41.8mm ✓（上限 R_max=λ/(4·sin22.5°)=54.6mm，留 8% 余量）。R 越大分辨率越好，故选"不混叠前提下尽量大"=50mm；布板放不下时最低别低于 35mm。
- **圆周导向矢量公式**（改 `gen_steer_rom_tb.v` 时用）：`a_i(θ) = exp(-j·kR·cos(θ−α_i)) = exp(-j·3.7565·cos(θ−α_i))`（线性阵列是 sin(θ)，两者不同）。
- **换圆周后测向范围扩到全 360°**：`NANG` **181 → 361**，DOA 输出 −90..+90 → **−180..+180**；圆周阵列**无镜像模糊**，相对线性是升级。
- **物理布板**：8 麦共面、朝向一致；INMP441 底进音 → 每麦下面留声孔、声孔附近不走线不放件；丝印标 **0° 箭头**（对应麦 0）。
- **换圆周要重做的**（已完成，2026-10-16）：改 `gen_steer_rom_tb.v` 公式 → 重跑生成 `steer_re.mem`/`steer_im.mem` → `NANG=361` → 重新综合烧录、重验 DOA。I2S/FFT/协方差/求逆/扫描逻辑**全不用动**。（`gen_das_taps.py` 的 DAS 延时表也要同步改圆周公式，见进度 11。）

## DAS 粗测通道（串口 `D=`）当前执行细节（2026-10-18 记）

D = `das_scan_top.v`，**时域延时求和（delay-and-sum）粗测**，和 M（`mvdr_sweep` 频域 MVDR 超分辨）是两条独立通路。D 是粗通道（不超分辨），精角度以 M 为准。**（2026-10-18 起串口停打 `D=`：D 栅瓣乱跳、粗分辨率 ~48°，K=2 让 M 提到 ~39Hz 后 D 冗余；`das_scan_top` 模块仍保留，继续驱动 led1。）**

- **输入**：`sample_data[127:0]` = 8 路 × 16bit **原始时域采样**（不是 FFT 谱），`sample_valid` = 48.828kHz 每样本 1 拍。
- **每来一个样本，串行扫 181 个角度**（NANG=181，**2° 步长**，−180..+180；对比 M 是 361 角 1°）：
  1. 8 条环形缓冲（分布式 RAM，各 64 深）`sample_valid` 时写进 `wp`；`rbase` 锁存最新样本地址。
  2. 抽头表 ROM（`tap_int`/`tap_frac` 各 181 行、8 通道打包成单读口宽字）：`D_i = 16 − k·cos(θ−α_i)`，k = R·Fs/c = 0.05×48828.125/343 ≈ **7.118 样本**，α_i = i×45°，16 是前导偏移（防读负地址）。整数 6bit、分数 8bit（=round(frac×256)）。
  3. **分数延时 2 抽头线性插值**：每通道读 `x[int]`、`x[int+1]`，`y = x[int] + (frac·(x[int+1]−x[int]))>>8` → 延时量化降到 1/256 样本。
  4. 束和（8 路插值符号扩展相加，20bit）→ 平方（40bit）→ 累加 `acc_pwr[ang]`。
  5. **3 级流水线**（S_SCAN0 锁 16 样本 → S_SCAN1 锁 8 路插值 → S_SCAN2 束和+平方+累加），每角度 3 拍 → 每样本 543 拍。
- **窗口/输出**：WIN=1024 样本 ≈ **21ms**（≈ **47.7Hz** 更新，比 M 快一个量级）→ 对 181 个 acc_pwr 做 **argmax** → `best_deg = cmp_cnt×2 − 180` → 加 **180° 安装偏移**（ch0 在板最左，>180 减 360 wrap 回 [−180,180]）→ 输出 `das_doa`(9bit 有符号度，恒为偶数=2° 粒度) / `das_done`(1 拍脉冲) / `das_sig`(best_pwr[47:16]>PWR_TH) / `das_pwr`(best_pwr 高 32 位)。

### D 为什么乱跳（不是 bug，是 DAS 物理极限）
- DAS **不超分辨**：主瓣 ≈ λ/(2R)，4kHz 时 λ≈8.6cm → 主瓣 **~48° 宽**。
- **高频栅瓣**：kR = 2πR·f/c，4kHz ≈3.7，波束图一堆旁瓣；纯音下 argmax 只在几簇固定旁瓣之间跳（板上实测 D 只在 316/306/314、090/078/102、214/224/234、012/010、180 等几簇之间跳）。
- 这是延时求和的固有粗分辨率，**换 MUSIC 修不掉**：单声源下 MUSIC 谱 1/(aᴴEₙEₙᴴa) 退化为和 MVDR 1/(aᴴR⁻¹a) 同形的峰（都等价最大化 |aᴴa_s|²），不比现有 M 强，且 FPGA 上 8×8 EVD 又贵又难。要准角度用 M。

## 架构待决（不急，但会影响 cov_accum 的改法）
- **DOA 更新率瓶颈不在计算，在攒快拍**：一帧 FFT = 512/48828.125 = **10.49ms**；K=128 快拍 = 1.34s → DOA 只有 ~0.75Hz。整条 MVDR 计算链 **~4.6ms**（8-bin×361 角 sweep 211697 拍是大头），仍小于一帧 10.49ms。**EMA（S=7）已平均 128 帧 → K 只决定多久算一次 DOA、与估计方差无关**（旧块平均时代「减 K 增方差」的说法作废）。**已采用（2026-10-18）：K=2 → ~30Hz、S=7（有信号）/SF=3（无信号，自适应 fast-release）→ 拍手拖尾 ~0.3s**；再快可 K=1 → ~66Hz，或把 sweep 与攒快拍流水重叠（S_RUN 期不暂停累积）。

## 声源识别子系统（下一阶段 · PS 端，2026-10-18 定案）
- **架构**：识别放 **PS（脱机，不依赖 PC）**，链路 PL → PS → PC，PC 只显示。
- **分工**：
  - **PL**：DOA 测向（已验收）+ **按 DOA 波束成形输出一路干净音频**（DMA 给 PS）+ DOA 角度。波束成形可复用 DAS 的延时求和；最简可先用 1 路麦克风顶替。
  - **PS**：拿干净音频 → 分类 CNN + 声纹向量 → 结果转发 PC。
  - **PC**：显示（鸟 / 拍手 / 鸣笛 / 说话人 + 角度）。
- **任务① 声源类型识别（鸟叫/拍手/鸣笛…）**：mel 谱 → 小 CNN → 类别。5~8 类、INT8 量化，A9 上几十 ms/次（几百 ms 跑一次就够），精度 90%+，无风险。
- **任务② 声纹识别（是不是录入过的人）**：d-vector 嵌入向量 + 余弦相似度。录入 = 录几秒 → CNN 编码成固定长度向量存；识别 = 新语音编码 → 与存好的向量比相似度 → 超阈值命中。**能做 demo（干净/短句/人数少/近距）；远场/噪声/人多/短语音掉精度，要鲁棒得上大模型（ECAPA）回 PC。** 比对只是点积、算力不是瓶颈，瓶颈在嵌入准不准。
- **PL 额外要做的一件事**：波束成形输出一路干净音频（送 PS）——识别子系统里 PL 唯一的新增物。**已实现（2026-10-19，见进度 17）**：`bf_audio_out.v`，AXI4-Stream 16bit 单声道 @48.828kHz、tlast 每 1024 样本（21ms）一帧，时钟 = sys_clk 50MHz，走 BD 异步 FIFO 50→100MHz 接 DMA。
- **两个顶层（别拿错）**：`radar_pl_top.v` = 自检版（AXI tie-off，能单独 Generate Bitstream 烧板看串口）；`radar_pl_top_bd.v` = BD-ready（`s_axi_*` + `m_axis_audio_*` 引到端口，给 B 接 PS/DMA，不能单独出 bit）。改测向/音频逻辑时两份都要同步。

> **PC 端频谱可视化（2026-10-22 定案）见独立文档 [`频谱显示.md`](spectrum_display_design.md)**：8 方位频谱必须做波束成形（不能直接摆 8 个麦的幅度谱）、两路 DMA、网线选型（Cat5e/Cat6）、静态 IP 配置、PS/PC 分工。**8 方位波束谱放 PS 算**（用户定案：让 PS+PL 两端都承担运算，PL 只做实时硬约束处理，PC 纯绘图）。`fft_axis_*` 4 个端口**已加回** `radar_pl_top_bd.v`（2026-10-22，xvlog 通过）。

> **竞赛报告架构（2026-10-22）见独立文档 [`比赛报告架构.md`](report_outline.md)**：7 部分 + 附录的章节骨架、20 张图表清单（标了优先级和"谁能出"）、关键指标表（值 + 推导链）、三条创新点写法、页数不够时的删减顺序。参照物是国一作品 `便携多功能仪器设计报告2.pdf`（18 页 / 22 图）。**今天不依赖队友就能做的五件：空间谱对比图（图6/7）、功耗报告、架构框图（图1/4）、8 bin 频率分布图（图5）、波束成形对比图（图11）。**

## 已知问题 / TODO
- 仿真时钟比预期慢 1000 倍（`#160` 疑似按 1us 而非 1ns 生效；2026-09-23 又在 `complex_div_tb` 探针里复现：`#5` 时钟实测周期 10us）——已验证不影响逻辑正确性，做 FFT 时再理顺 timescale。
- 下一步（频谱通路）：**打包 `radar_pl_top` 为 IP → 交给 B → Block Design（PS7 + AXI DMA + 异步 FIFO 50→100MHz + AXI Interconnect + Address Editor 配 0x43C00000）**。PS7 配置照「关键决策 · PS7 配置」抄（DDR3 MT41K256M16 RE-125 / 533MHz / FCLK_CLK0=100MHz）。`fft_axis_*` 和 `s_axi_*` 已引出（见进度 9），BD 里直接接网线；跨时钟在 BD 里解决（Interconnect 从口 50MHz + 异步 FIFO），PL 顶层不用改。
- 下一步：**宽带 MVDR 2-bin 已仿真通过（见进度 12），先上板验证**——4.1kHz 纯音 → DOA 应与旧窄带一致（±1°，退化为窄带）；说话/连续噪声（30~50cm、同高度、别怼孔）→ DOA 稳定指向声源；与 DAS `D=` 对照。上板前把 4 个新 .mem 加进 radar_pl。之后 ① **恢复 `radar_pl_top.v` 为 BD-ready 版**（当前是临时自检版，见下条），打包 IP 给 B 搭 BD；② 算法增强：**4c-3 MUSIC**（Jacobi 特征分解 RTL，分辨更近双声源）。（~~宽带 MVDR 扩到 4/8 bin~~ **已完成，见进度 18**）写 tb 时**务必在下降沿驱动输入**（见上面 testbench 竞争条）。
- **上板验证用临时自检版（2026-10-16）**：`radar_pl_top` 已临时去掉 `fft_axis_*`/`s_axi_*` 端口、AXI tie-off、`wire fft_axis_tready=1'b1`，恢复成能直接 Generate Bitstream 的纯串口自检版。**验证完圆周阵列后要恢复 BD-ready 版**——反操作：加回 16 个端口、tie-off 改回接端口、`wire fft_axis_tready=1'b1` 改回 3 个 assign。
- **综合/实现「转圈很久」先看日志区分挂死 vs 睡眠（2026-10-14）**：OOC/实现的 log 里 `elapsed` 是墙钟、`cpu` 是实际 CPU 时间；若 `elapsed=12h` 但 `cpu=8min`，是**笔记本睡了**（跑之前把电源睡眠设成「从不」），不是死循环。真正的挂死两者会一起涨。

---

## 2026-11-04 追加：PC 上位机工程包并入

**提示词**：`C:\Users\32458\Documents\fpga赛\提交_工程包_PC上位机 这是PC端程序,请你帮我一并整理`

**先诊断、后改动**（沿用本项目的习惯）：先逐文件读代码与文档，列出与新仓库不一致的
地方，再动手。发现 5 个“换机器就坏”的点：

- `web_receiver.py` 的声纹目录默认值是作者桌面的绝对路径；
- `campplus_sv.py` 的声纹库路径多了一层 `demo_data/`，实际文件在模块同目录，
  原样运行会静默加载空库；
- `jtag_audio_bridge.py` 把 `xsdb` 写死为 `D:\FPGA\2026.1\Vitis\bin`；
- `requirements.txt` 缺 `scipy`（重采样）与 `pywebview`（启动器）；
- `network_config.json` 的 `protocol_version` 还是 2，与 `radar_protocol.py` 的 v3 不一致。

另有 1 个未随包提供的文件：`/simple` 路由引用的 `acoustic-radar-simple.html`，
访问会抛异常 → 改为文件不存在时返回 404。`feature.py` 依赖未提供的 `configs`
与 `torchaudio`，部署链路不导入 → 保留原样并标注，不假装它能独立运行。

**自我纠错**：最初想直接覆盖 `src/pc/`；检查 `src/ps/tests/verify_*.py` 后发现
PS 测试用的是 `src/ps/pc/` 的旧副本，不受影响；仍把旧 `src/pc/` 备份到
`repo-submit-work\backup_src_pc_20261104\`，再替换。

**验证**：6 个 Python 文件 `py_compile` 通过；`web_receiver` 在 19000/18768 端口
起服务，`/api/state` 200、`/` 200、`/simple` 404；声纹库读出
`names=['小明','小美']`、`embeddings=(2,192)`。
