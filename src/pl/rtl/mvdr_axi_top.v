`timescale 1ns / 1ps
// ============================================================
// mvdr_axi_top.v —— MVDR 波束成形核的 AXI 外壳（给 PS/队友B 用）
//
// ┌────────────────────────────────────────────────────────────────┐
// │  PS 侧看这个模块只有两个口：                                      │
// │   ① AXI4-Lite 从机 —— 控制/状态寄存器（见下面寄存器映射）          │
// │   ② AXI4-Stream 从机 —— 喂 FFT 输出流（tdata={im[31:0],re[31:0]}）│
// └────────────────────────────────────────────────────────────────┘
//
// 内部数据流（宽带 MVDR · 8 bin 非相干融合 + 协方差遗忘因子 EMA）：
//   S_AXIS ─> bin_extract_8ch(8 bin) ─> cov_accum_8x8(8 套, EMA)
//          ─> cov_to_q16 ×1(复用, 8:1 R mux) ─> mat_inv_8x8 ×1(复用 8 次)
//          ─> mvdr_sweep(8 bin 融合) <─ steer_rom ×8
//
// 后处理分时复用：cov_to_q16 和 mat_inv 都只例化 1 份，串行跑 8 次
//   （bin0 → bin7），sweep 连续收 8 段逆矩阵后做融合扫角。瓶颈在攒快拍
//   （K 帧），串行求逆完全不影响 DOA 更新率。
//
// 运动自适应记忆（2026-10-30，解决"环绕移动时角度猛跳"）：
//   静止时 EMA 用 S=7（1.3s 记忆，精度最高）；判据认为在运动时切 SM=3
//   （8 快拍 ≈84ms 记忆，跟得上移动）。motion=0 时协方差路径与旧版逐位一致，
//   更新率/延迟不变。MOTION_EN=0 可整体关闭（回到旧行为）。
//   ⚠ 8 快拍与阵元数同阶，个别帧的估计会被甩出几十度（2026-10-31 板上实测
//     ≥30° 步进占 2.9%，而中位步进 1.00° 就是真实转角）。这些离群帧由输出端
//     GATE 剔除（见 doa_deg 下面的注释），不靠拉长记忆——SM=5 的 0.34s 记忆
//     在 55°/s 下是 18° 固定滞后，比离群帧更难接受。
//   2026-11-01 板测（circle_v4.csv）：GATE 把 >30° 跳变从 82/分 压到 3.3/分，
//     剩下的几次是"连续 3~8 帧稳定锁在错峰"，GATE 拦不住；再加一级显示端限速
//     SLEW（≤8°/帧 ≈ 381°/s）把这些过渡摊成几帧的平滑移动。
//   限速的副作用是"新声源出现在远处时显示爬得慢"，因此再加 CLAP：
//     能量快/慢 EMA 比 > 2.5（拍手/敲击是瞬态）时开事件窗口。
//     2026-11-02 板测改口：窗口内**不再提速**（25°/帧 时 88° 用 3 帧跨过去，人眼
//     仍是"跳"），改用比普通限速更低的一档（6°/帧）匀速扫过去；窗口的真正
//     作用是**挡住大跨步**（见 accept_big 的 evt_cnt==0 条件），见下面参数注释。
//   2026-11-01 第二版（A 档 + 协方差重建）：
//     · 拍手有能量瞬态可判，但"搬动一个持续发声的声源"没有；180° 换向按 8°/帧
//       要走 0.47s。所以再加一条**按距离**的大跨步：显示角离目标 >45° 时整段
//       用 25°/帧（单帧仍 <30°，不构成视觉跳变），180° 从 504ms → 189ms。
//       实测（sim/sim_big.py 回放 circle_v5）：A 档只在记录空档（≥1.8s）处触发，
//       连续录制的圆周一遍都不触发，所以"圆周不跳"这条不受影响。
//     · 大变化被 GATE 确认后让协方差重建（cov_accum 的 flush）：旧记忆里 128 个
//       快拍全是已经不存在的方向，会把新方向压住 0.2~0.7s；重建后从对角加载
//       矩阵重新开始，第一帧就指对。同一机制也顺手破掉"连续 3~8 帧锁错峰"。
//   判据有两个、取并集（2026-10-31 加 v2）：
//     v1 = mov_detect_3beam：当前快拍在 θp、θp±Δ 三个角度的波束功率比。
//          慢速可靠，但转速一高 θp 被拖后、声源贴在 θp+Δ，比值上不去 ⇒ 快转漏检。
//     v2 = DOA 增量 EMA：m ← m − m/2^SH + d1，稳态 m ≈ 2^SH × 每帧转角，与
//          θp 是否滞后无关。补的正是 v1 的快转盲区（见下面 v2 段的注释）。
//
// 运动角度超前补偿（2026-10-30，解决"匀速环绕时角度恒定落后 7~9°"）：
//   SM=3 的 84ms 记忆对匀速运动等价于 84ms 的固定滞后（90°/s 时 7.6°），这是
//   相位延迟，不是精度问题。输出侧做 θ_out = θ_est + G·Δθ（G=3）把这段滞后
//   补回来，内部 doa_reg 保持原始值，所以运动检测器的行为一字未变。
//   Δθ 只在"连续两帧同号、大小接近、1°~10°/帧"时才被采信（门控），否则不补——
//   否则静止单音的帧间噪声会被放大 3 倍，重现"没动却跳变"。
//   单独缩短记忆 SM 3→2 看起来更直接，但实测拍手拖尾中位数 0.4°→3.2°、
//   最坏 80°，故不动记忆。实测见 sim/sim_gain_final.py。
//
// 冷启动抑制（2026-10-31，解决"上电瞬间角度乱跳"）：
//   EMA 时间常数 = 128 快拍 = 64 帧（K=2）。复位后协方差近空白，argmax 乱走。
//   板测：上电 0~0.11s 内 4 次 115°~169° 跳变，0.13s 后稳定，此后 73s 零跳变。
//   处理：复位后前 WARM_N(=64) 帧只累积不输出（doa_out_reg 保持、doa_done 不发、
//   doa_reg 与增量历史冻结）。只对 AUTO_RUN=1 生效，AUTO_RUN=0 单次模式不抑制。
//   WARM_EN=0 可关闭。验证见 sim/sim_warm_gate.py。
//
// ============================ 寄存器映射 ============================
//  字地址(字节)  名称        属性   说明
//   0x00 (0)   CTRL        W     bit0=START(自清) 启动一次测向
//                                bit1=SOFT_RST(自清) 复位内部链路
//   0x04 (1)   STATUS      R     bit0=BUSY 忙, bit1=DONE(粘滞, 读 CTRL 启动时清)
//   0x08 (2)   DOA         R     估计角度，**有符号度**（-180..180，32bit 符号扩展）
//                                已含门控超前补偿；静止时与未补偿值完全相同
//   0x0C (3)   S_MIN       R     对应最小 s_total 值（Q16.16 原始值，调试用）
//   0x10 (4)   SHIFT_USED  R     适配层本次右移量（调试用）
//   0x14 (5)   SNAP_CNT    R     已累积快拍数（0..K）
//   0x18 (6)   BIN_LIST    R     {16'd0, BIN0[7:0], BIN1[7:0]} 前两个频率 bin
//   0x1C (7)   VERSION     R     0x4D564452 = "MVDR"
//   0x20 (8)   DAS_DOA     R     DAS 快速粗 DOA（有符号度，~21ms 更新，宽带任意声音）
//   0x24 (9)   DAS_STATUS  R     bit0 = 有无信号（DAS 能量门限）
//   0x28 (10)  BIN_LIST2   R     {16'd0, BIN2[7:0], BIN3[7:0]}
//   0x2C (11)  BIN_LIST3   R     {16'd0, BIN4[7:0], BIN5[7:0]}
//   0x30 (12)  BIN_LIST4   R     {16'd0, BIN6[7:0], BIN7[7:0]}
//   0x34 (13)  PWR         R     MVDR 总能量 E（cov_pwr[47:16]，无信号≈0，门限用）
//   0x4C (19)  MOTION      R     bit0=声源运动（已切短记忆 SM），bit1=运动检测忙
//                               （0x38..0x48 留给队友B 的遥测寄存器，见 u_regs 处注释）
//
// ============================ PS 用法 ============================
//   1. 让 FFT 链路把 AXI4-Stream 接到本模块的 s_axis_*
//   2. 写 CTRL.START = 1
//   3. 轮询 STATUS.BUSY（约 K 帧后变 0），或等 DONE
//   4. 读 DOA 得到角度
//
// ⚠️ 已知限制（先记录，后续可改）：
//   - BIN0..BIN7 是编译期参数，运行期不可改
//   - AXI 时钟 = 核时钟（单时钟域）。若 PS 走独立时钟需加 CDC
//   - K 帧攒快拍决定 DOA 更新率；EMA 首个 DOA 约 63% 收敛，之后逐步趋稳
// ============================================================
module mvdr_axi_top #(
    parameter integer BIN0       = 5,    // 476.9Hz
    parameter integer BIN1       = 10,   // 953.7Hz
    parameter integer BIN2       = 15,   // 1430.5Hz
    parameter integer BIN3       = 20,   // 1907.4Hz
    parameter integer BIN4       = 25,   // 2384.3Hz
    parameter integer BIN5       = 31,   // 2956.6Hz
    parameter integer BIN6       = 37,   // 3528.8Hz
    parameter integer BIN7       = 43,   // 4100.8Hz
    parameter integer K          = 64,   // 协方差累积快拍数（EMA 下仍每 K 拍出一次 DOA）
    parameter integer NANG       = 361,  // 扫描角度数
    parameter integer XW         = 24,   // 每路谱位宽
    parameter integer NT         = 36,
    parameter integer AW         = 64,
    parameter integer NB         = 8,    // 频点数
    parameter integer S          = 7,    // 协方差遗忘因子：α = 1/2^S
    parameter integer SM         = 3,    // 运动时遗忘因子：α = 1/2^SM（≈8 快拍 ≈84ms，无滞后）
                                         //   记忆短 ⇒ 个别帧的协方差估计会炸（≥30° 跳变 2.9%），
                                         //   但典型帧精度不变（中位步进 1.0° = 真实转角），
                                         //   所以用 GATE_* 挡掉尾部离群帧，而不是拉长记忆
                                         //   （SM=5 的 0.34s 在 55°/s 下是 18° 固定滞后）

    parameter integer DELTA      = 12,   // 运动检测邻波束偏移（度）
    parameter integer MOTION_EN  = 1,    // 1 = 运动自适应记忆；0 = 关闭（与旧版完全一致）
    parameter integer PRED_EN    = 1,    // 1 = 运动超前补偿（N=4 门控，默认开）；0 = 关闭
    parameter integer MV2_EN     = 1,    // 1 = 运动判据 v2（DOA 增量 EMA）与 v1 并联
    parameter integer MV2_SH     = 3,    // v2 遗忘因子：α = 1/2^3（8 帧 ≈ 0.17s）
    parameter integer MV2_ENTER  = 12,   // v2 置位门限（Q2）：m 稳态到 12 ⇔ 17.9°/s
    parameter integer MV2_EXIT   = 5,    // v2 清位门限（Q2）：m 稳态到 5  ⇔  7.5°/s
    parameter integer MV2_HOLD   = 4,    // v2 清位前需连续保持的帧数（4 帧 ≈ 84ms）
    // ---- 输出端单帧离群剔除（GATE） ----
    //   一帧的估计炸掉（≥30°）时先扣住不发，值要连续 GATE_N 帧自洽才放行；
    //   真运动一帧只走 1~2°（47.7Hz 下 20°/帧 = 954°/s），永远走"直接接受"那条路，
    //   所以正常帧的输出与不加门时逐位相同，不加任何滞后。
    parameter integer GATE_EN    = 1,    // 1 = 开；0 = 关（输出与旧版逐位一致）
    parameter integer GATE_DEG   = 20,   // 单帧偏离超过该度数即视为离群（度）
    parameter integer GATE_TOL   = 10,   // 候选之间允许的自洽误差（度）
    parameter integer GATE_N     = 3,    // 候选需连续自洽多少帧才接受（真跳变延迟 GATE_N-1 帧）
    parameter integer GATE_MAX   = 8,    // 最多扣住多少帧（约 168ms）后强制接受，防卡死
    // ---- 显示端限速（SLEW）：把"稳住几帧再一步跳过去"的过渡摊成几帧的平滑移动 ----
    //   2026-11-01 板测 circle_v4：GATE 把 >30° 跳变从 82/分 压到 3.3/分，剩下的
    //   4 次不是孤立尖峰，而是原始估计连续 3~8 帧稳定地锁在错峰上（GATE 按设计放行）。
    //   限速不改变"接受什么值"，只限制显示角每帧最多转多少度。
    //   角速度上限：SLEW_DEG × 47.7Hz（8 ⇒ 381°/s）。圆周测试的转速只有
    //   28~90°/s，所以正常帧一帧都不受限、逐位不变；只有"被 GATE 扣住过"的
    //   大变化（>SLEW_DEG）才摊成 (Δ/SLEW_DEG) 帧的移动。
    //   ⚠ 这不是精度损失：被摊开的都是原始估计单帧跳了 8° 以上的帧，按转速
    //     物理上不可能，本来就是估计噪声；拍手这类新声源也不提速（见下面 CLAP）。
    parameter integer SLEW_EN    = 1,    // 1 = 开；0 = 关（显示与 GATE 输出逐位一致）
    parameter integer SLEW_DEG   = 8,    // 每帧最多转动的度数（8°/帧 @47.7Hz ≈ 381°/s）
                                         //   2026-11-01 板测 circle5：8°/帧 圆周平滑、用户认可。
    // ---- 拍手/敲击瞬态窗口（CLAP）：瞬态期间只匀速扫掠，不许大跨步 ----
    //   拍手是瞬态：能量在几个帧内抬高好几倍。用两档能量 EMA 的比值判断：
    //       e_fast ← e_fast − e_fast/4  + pwr        （稳态 4×pwr，τ≈4 帧）
    //       e_slow ← e_slow − e_slow/64 + pwr        （稳态 64×pwr，τ≈64 帧）
    //       e_fast << 5  >  5·e_slow  ⇔  快/慢 > 2.5
    //   ⚠ 2026-11-01 板测：完全旁路时拍手一帧跨 88°（M=052→140）；
    //     改成 25°/帧 后是 3 帧（63ms）、单帧 25° < 30° 判跳门限——
    //   ⚠ 2026-11-02 板测：用户反馈 3 帧跨 88° 看上去仍然是"跳"，真的不好。
    //     所以窗口内**不提速，反而比普通限速更低一档**：SLEW_EVT_DEG=6，
    //     88° 摊成 15 帧匀速扫掠（≈0.34s）；同时窗口内禁止进入 big_move，
    //     否则 A 档会在瞬态一开始就把限速拉回 25°/帧，等于白改。
    //   真数据验证（sim_evt_int.py，RTL 逐位同逻辑）：circle_v4/v3/v2 上只在
    //   测试开头能量爬升那 44 帧触发，圆周转动全程 0 次、4 次跳变帧处比值
    //   只有 0.84~1.18，不会被误开。
    parameter integer CLAP_EN    = 1,    // 1 = 开；0 = 关（等于没有瞬态窗口）
    parameter integer CLAP_HOLD  = 32,   // 事件窗口帧数（32 帧 ≈ 0.67s：6°/帧 走完 180° 要 30 帧）
    parameter integer SLEW_EVT_DEG = 6,  // 事件窗口内的限速；< SLEW_DEG ⇒ 比普通转动更慢
    // ---- 事件窗口内的"只信峰值附近"门限（2026-11-03）----
    //   拍手只有 ~1ms，真正的方向信息集中在能量峰那 1~2 帧；峰之后只剩衰减尾巴，
    //   R 里已经没有信号，估计器是拿噪声给的角，却照样被 GATE 放行（±20° 内立即
    //   接受、扣满 8 帧强制接受）——表现就是"拍完手角度还在自己走"。
    //   窗口内只允许 pwr 落在峰值 1/2^SIG_DB_SH 以内的帧更新目标角，尾巴一律保持；
    //   同时窗口内关闭 GATE 的强制放行，只用"连续 3 帧自洽"这一条路改目标。
    //   ⚠ 只用相对峰值，不用绝对能量门：static_v4 的中位 pwr 只有 1243，
    //     比拍手判据的 2048 还低，绝对门会把正常定点声源也挡掉。
    parameter integer SIG_EN     = 1,    // 1 = 开；0 = 关（窗口内不设能量门；强制放行仍关）
    parameter integer SIG_DB_SH  = 1,    // 峰值下降 2^SIG_DB_SH 倍后不再更新（1=6dB）
    // ---- 大跨步限速（A 档，2026-11-01）：没有能量瞬态的"大幅换向" ----
    //   拍手靠能量瞬态开窗（CLAP），但"移动一个持续发声的声源"没有能量跳变，
    //   180° 的换向要 180/8 = 22 帧 = 0.47s，用户看到的就是"慢吞吞爬过去"。
    //   这里按**距离**判断：显示角与目标的差距一旦超过 BIG_TRIG_DEG，本段移动
    //   全程用 SLEW_BIG_DEG（一直用到追上为止，避免最后几十度又爬回 8°/帧）。
    //   ⚠ 门限选 45° 是因为真实转动（圆周转台最快 ~90°/s）的显示滞后只有几度，
    //     差距永远碰不到 45°；能碰到的只有"新声源/换向"这种真跳变。
    //   SLEW_BIG_DEG 取 25：单帧仍 <30°（用户判"跳变"的门限）。它只服务这类
    //     "有意的整段搬移"，拍手走 CLAP 窗口、不吃这一档。
    parameter integer SLEW_BIG_DEG = 25, // 大跨步时的限速（度/帧）；≥181 等于关掉本功能
    parameter integer BIG_TRIG_DEG = 45, // 差距超过该度数即进入大跨步（度）
    // ---- 大变化后重建协方差（2026-11-01）----
    //   GATE 确认"这一次接受跨过了 >CLR_DEG"时，说明旧记忆里那 128 个快拍的方向
    //   已经作废了。此时让 cov_accum 把 R 重写成对角加载矩阵（λ·I），
    //   从"各向同性噪声 + 新快拍"重新开始：原来要 0.2~0.7s 才拐过来的过渡，
    //   第一帧就能给出方向正确的（偏宽的）峰，K 个快拍后恢复正常尖锐度。
    //   同一机制也用来破"连续几帧锁在错峰上"（circle_v3/v4 里剩下的那 4 次）。
    //   稳态不受影响（只在确认大变化的那一帧发生一次）。
    //   门限 CLR_DEG=30：比这小的变化 EMA 自己几十 ms 就追上了，重建反而白丢一个快拍
    parameter integer CLR_EN     = 1,    // 1 = 开；0 = 关（协方差永不重建，与旧版一致）
    parameter integer CLR_DEG    = 30,   // 单次接受的跳变超过该度数才重建（度）
    parameter integer WARM_EN    = 1,    // 1 = 复位后丢弃前 WARM_N 帧 DOA（冷启动抑制）
    parameter integer WARM_N     = 64,   // 丢弃帧数：K=2 时 1 帧=21ms，64 帧=1.34s=1 个 EMA 时间常数
    parameter integer AUTO_RUN   = 0     // 1 = 上电自动连续测向；0 = 等 PS 写 CTRL.START（队友B）
)(
    input  wire        clk,
    input  wire        rst_n,          // 低有效复位（接 AXI 的 aresetn）

    // ---------------- AXI4-Lite 从机：控制/状态 ----------------
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---------------- AXI4-Stream 从机：FFT 输出流 ----------------
    input  wire [63:0] s_axis_tdata,   // {imag[31:0], real[31:0]}
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tready,  // 输入：上游合并后的流 tready（=MVDR_tready & FIFO_tready），门控 bin_extract 采样
    input  wire        s_axis_tlast,

    // ---------------- 调试输出（无 PS/无 AXI 时，顶层用 LED 自检）----------------
    output wire signed [8:0] doa_deg,   // 最新一次 DOA（有符号度 -180..+180）
    output reg               doa_done,  // 一拍脉冲：与 doa_deg 同拍有效
    output wire [31:0]       pwr_out,   // 8 个目标 bin 的 8 路总能量（高 32 位），定门限用
    output wire              mot_v1,    // 运动判据 v1（mov_detect_3beam）当前判决，1=运动
    output wire              mot_v2,    // 运动判据 v2（DOA 增量 EMA）当前判决，1=运动

    // ---------------- DAS 粗测结果输入（来自 das_scan_top，经 AXI 透传给 PS）----------------
    input  wire signed [8:0] das_doa,   // DAS 快速粗 DOA（-180..+180，~21ms 更新）
    input  wire              das_sig    // DAS 有无信号
);

    // ================================================================
    // 1) AXI4-Lite 总线适配器
    // ================================================================
    wire        wr_en;
    wire [4:0]  wr_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_strb;
    wire [4:0]  rd_addr;
    reg  [31:0] rd_data;

    // ADDR_BITS=5：给 0x4C MOTION 留地址。队友B 的版本已扩到 5 位并用掉
    // 0x38/0x3C/0x40/0x44/0x48（DAS/MVDR 计数、PCM 丢帧、tag、PCM 计数），
    // 0x38 已被占用，所以调试寄存器放 0x4C，两边合并不冲突。
    axi_lite_regs #(.ADDR_BITS(5)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    // ================================================================
    // 2) 软件复位 / 启动请求
    // ================================================================
    // core_start_ack 提前声明：下面 2) 的 always 块要用它（xvlog 要求先声明后用）
    reg start_req, soft_rst_r, core_start_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_req  <= 1'b0;
            soft_rst_r <= 1'b0;
        end else begin
            soft_rst_r <= 1'b0;                     // 默认自清
            if (wr_en && wr_addr == 5'd0) begin
                if (wr_data[0]) start_req  <= 1'b1;
                if (wr_data[1]) soft_rst_r <= 1'b1;
            end
            if (core_start_ack) start_req <= 1'b0;  // 控制器接管，清请求
        end
    end

    // 内部链路复位：AXI 复位 或 软件复位脉冲
    wire core_rst_n = rst_n & ~soft_rst_r;

    // ================================================================
    // 3) 控制状态机（累积快拍 → 跑链路 → 收结果）
    // ================================================================
    localparam S_IDLE = 2'd0, S_ACCUM = 2'd1, S_RUN = 2'd2;
    reg [1:0]  state;
    reg        busy, done_sticky;
    reg        run_pending;   // 攒够快拍但运动检测正占用导向 ROM：等它跑完再启动链路
    reg [7:0]  snap_cnt;
    reg signed [8:0]  doa_reg;
    reg signed [31:0] smin_reg;
    reg [5:0]  shift_reg;

    // 内部链路信号
    wire [NB*8*XW-1:0]  bx_re, bx_im;
    wire             bx_ready;
    wire [AW-1:0]  cov_rc_re, cov_rc_im;   // cov_accum 随机读口数据（64bit）
    wire [AW-1:0]  cov_pwr;                // cov_accum 迹 EMA（总功率，64bit）
    wire [8:0]     cq_rc_addr;             // cov_to_q16 → cov_accum 读地址
    wire             cov_rdone;
    wire signed [31:0] cq_re, cq_im;
    wire cq_valid, cq_start, cq_done;
    wire [5:0] cq_shift;
    wire signed [31:0] mi_re, mi_im;
    wire mi_valid, mi_start, mi_done;
    wire a_req;
    wire [8:0] a_ang;
    wire [NB-1:0] avalid;
    wire signed [NB*32-1:0] av_re, av_im;

    // ---- 运动检测（mov_detect_3beam）与 8 份导向 ROM 的分时复用 ----
    // sweep 空闲（S_ACCUM）时运动检测接管 a_req/a_ang；两者不会同时请求。
    wire        det_busy, det_req, det_moving;
    wire [8:0]  det_ang;
    wire        rom_req = (MOTION_EN != 0 && det_busy) ? det_req : a_req;
    wire [8:0]  rom_ang = (MOTION_EN != 0 && det_busy) ? det_ang : a_ang;
    wire signed [31:0] s_out;
    wire s_valid;
    wire signed [8:0]  doa_w;
    wire signed [31:0] smin_w;
    wire mvdr_done;

    // ================================================================
    // 运动角度超前补偿（速度外推）—— 压掉 EMA 记忆造成的固定滞后
    //
    //   滞后的来历：SM 的遗忘因子对匀速变化输入有 ≈2^SM 个快拍的群延迟。
    //   SM=3 ≈ 8 快拍 = 4 帧 = 84 ms，90°/s 环绕时 ≈7.6° 的固定滞后，与算法
    //   精度无关，纯粹是记忆的相位延迟；G=3 把它补回来大半。
    //
    //   补偿：θ_out = θ_est + G·Δθ，Δθ = 本帧与上一帧原始角度之差（环绕展开）。
    //   对匀速运动无偏；静止时 Δθ=0，严格不起作用。
    //
    //   门控（关键）：裸外推会把相邻帧的角度噪声同样放大 G 倍。实测静止单音
    //   bin20 的 RMS 2.1°→4.3°、跳变 1→3，这正是用户报过的"没动却跳变"。
    //   所以只在确实匀速运动时才补：连续两帧增量同号、大小接近
    //   （|Δθ_k − Δθ_{k-1}| ≤ 3°）、且落在 1°~10°/帧
    //   （21 ms 一帧 → 47°/s ~ 476°/s）。噪声符号随机、离群跳变超窗 → 不补，
    //   与改动前完全等价。
    //
    //   实测（sim/sim_gain_final.py，SM=3 不变，3 种子）：
    //     宽带环绕 90°/s  9.3° → 5.9°      宽带环绕 180°/s 11.4° → 6.5°
    //     急停后 150 ms   4.1° → 1.8°      单音环绕/静止/拍手 逐位不变
    //
    //   doa_reg 保持原始值：运动检测器的三个波束全部基于它，检测行为与改动前
    //   逐位一致，所以之前针对误触发做的调参全部继续有效。
    //
    //   ⚠ 上板结果（2026-10-30 那一版，闸门只比两帧）：4100Hz 单音静止时跳变
    //   反而更凶（近 5s 跳>30° 有 55 次）。机理：板上高 bin 的静态估计噪声远
    //   大于模型（模型 σ≈1~2°，板上更大），而两帧闸门在 iid 噪声上的通过率有
    //   3%~13%，放大的帧被放大 3 倍 → 实测 σ_out/σ_raw = 1.5~2.3
    //   （sim/sim_pred_noise.py、sim_pred_nframe.py）。
    //
    //   改法：闸门从"最近两帧一致"扩到"最近 PRED_N 帧全部一致"（同号、都在
    //   1°~10° 窗口内、极差 ≤ PRED_TOL）。匀速运动的增量序列天然满足，静止噪声
    //   做不到。实测（sim_pred_nframe.py，5 种子 × 2 万帧）：
    //     σ_raw=1°  N=2: 1.49°(通过 3%)  N=4: 1.00°(通过 0%)
    //     σ_raw=2°  N=2: 3.72°(11%)      N=4: 2.01°(0%)
    //     σ_raw=3°  N=2: 5.31°(13%)      N=4: 3.02°(0%)
    //     σ_raw=5°  N=2: 7.62°(12%)      N=4: 5.01°(0%)
    //   环绕代价（宽带 8bin，3 种子）：90°/s 不补偿 9.4° → N2 6.1° / N4 6.5°；
    //     180°/s 11.4° → 6.5° / 7.1°；270°/s 14.8° → 10.1° / 12.3°。
    //   即 N=4 在静止噪声上结构性不触发，同时保住大部分滞后补偿。
    //
    //   默认开启（PRED_EN=1）：N=4 闸门在静止噪声上通过率为 0，即"原本就抖的
    //   静止声源不会被放大"，而匀速环绕仍能拿回 2.9°(90°/s)/4.3°(180°/s)。
    //   RTL 与 numpy 参考逐帧比对 0 不一致（sim/sim_pred_rtl_n4.py）。
    //   若要完全关掉，改 PRED_EN=0，输出即为原始 doa_w。
    // ================================================================
    localparam        [3:0] PRED_HI  = 4'd10;   // 单帧增量窗口上限（°）
    localparam        [3:0] PRED_TOL = 4'd3;    // N 帧增量极差上限（°）
    // 连续帧数固定为 4（= 当前帧 + dh0/dh1/dh2）。要改 N 就同步增删历史寄存器。

    // ================================================================
    // 冷启动抑制（WARM_EN）
    //   协方差是 EMA：acc ← acc − acc/128 + m，时间常数 = 128 快拍 = 64 帧（K=2）。
    //   复位后到填满一个时间常数之前，argmax 在近似空白的协方差上乱走。
    //   板测（2026-10-31 17:05 那次）：上电后 0 ~ 0.11 s 内出现 4 次 115°~169° 的跳变，
    //   0.13 s 之后稳定在 91°，此后 73 s 零跳变。
    //   所以复位后前 WARM_N 帧只累积、不对外输出（doa_out_reg 保持、doa_done 不发），
    //   doa_reg / 增量历史也一并冻结，避免第一帧带着历史垃圾触发前导补偿。
    //   ⚠ 只对 AUTO_RUN=1（上电自跑）生效；AUTO_RUN=0 是 PS 逐次 START 的单次模式，
    //     那边丢弃结果会让 PS 读到旧值，所以不抑制。
    //   ⚠ WARM_N 上限 255（warm_cnt 是 8bit）。
    // ================================================================
    reg  [7:0]        warm_cnt;     // 复位后已收到的 mvdr_done 帧数（饱和）
    wire              warm_ok = (WARM_EN == 0) || (AUTO_RUN == 0) ||
                                (warm_cnt >= WARM_N);

    reg signed [8:0] doa_out_reg;   // 补偿后的输出角度（对外）
    reg signed [8:0] dh0, dh1, dh2; // 原始角度增量的历史（最近 3 帧）

    wire signed [9:0] d_full = {doa_w[8], doa_w} - {doa_reg[8], doa_reg};  // -360..360
    wire signed [9:0] d1     = (d_full > 10'sd180)  ? (d_full - 10'sd360) :
                               (d_full < -10'sd180) ? (d_full + 10'sd360) : d_full;

    wire        [9:0] ad1  = d1[9]                        ? (-d1)                        : d1;
    wire        [9:0] a_h0 = dh0[8]                       ? (-{dh0[8], dh0})              : {dh0[8], dh0};
    wire        [9:0] a_h1 = dh1[8]                       ? (-{dh1[8], dh1})              : {dh1[8], dh1};
    wire        [9:0] a_h2 = dh2[8]                       ? (-{dh2[8], dh2})              : {dh2[8], dh2};

    // 四帧都落在 [1, PRED_HI]（=0 表示该帧没历史/增量为 0，直接判否）
    wire inwin = (ad1  != 10'd0) && (ad1  <= {6'd0, PRED_HI}) &&
                 (a_h0 != 10'd0) && (a_h0 <= {6'd0, PRED_HI}) &&
                 (a_h1 != 10'd0) && (a_h1 <= {6'd0, PRED_HI}) &&
                 (a_h2 != 10'd0) && (a_h2 <= {6'd0, PRED_HI});

    wire        same_sign = (d1[9] == dh0[8]) && (dh0[8] == dh1[8]) && (dh1[8] == dh2[8]);

    // 极差 = max(|·|) − min(|·|)，同号前提下等价于 max(d) − min(d) ≤ TOL
    wire [9:0] m_01  = (ad1 > a_h0) ? ad1 : a_h0;
    wire [9:0] m_23  = (a_h1 > a_h2) ? a_h1 : a_h2;
    wire [9:0] amax  = (m_01 > m_23) ? m_01 : m_23;
    wire [9:0] n_01  = (ad1 < a_h0) ? ad1 : a_h0;
    wire [9:0] n_23  = (a_h1 < a_h2) ? a_h1 : a_h2;
    wire [9:0] amin  = (n_01 < n_23) ? n_01 : n_23;
    wire range_ok = ((amax - amin) <= {6'd0, PRED_TOL});

    wire pred_gate = (PRED_EN != 0) && inwin && same_sign && range_ok;

    // 先门控再放大：门控关时增量为 0，|3·d1g| ≤ 30，pred_s 恒在 ±210 内，不会溢出
    wire signed [9:0] d1g    = pred_gate ? d1 : 10'sd0;
    wire signed [9:0] d1x3   = d1g + (d1g <<< 1);                           // G=3
    wire signed [9:0] pred_s = {doa_w[8], doa_w} + d1x3;
    wire signed [9:0] pred_w = (pred_s > 10'sd180)  ? (pred_s - 10'sd360) :
                               (pred_s < -10'sd180) ? (pred_s + 10'sd360) : pred_s;

    assign doa_deg = doa_out_reg;   // 对外是补偿后的实时角度（doa_done 在 FSM 里驱动）

    // ================================================================
    // 输出端单帧离群剔除（GATE）—— 2026-11-01，解决"转动时成片跳变"
    //
    //   板上实测（circle_v3.csv，SM=3 短记忆、v2 全程开）：逐帧步进的中位数
    //   是 1.00°（正好等于真实转角），但 ≥30° 的步进占 2.9% —— 坏的不是整体
    //   精度，是极少数帧的协方差估计炸了（8 快拍估 8 阶 R，个别帧逆矩阵被
    //   噪声特征值主导）。靠拉长记忆去平滑它，代价是 55°/s 下 18° 的固定滞后；
    //   直接挡掉这些帧，则正常帧一个比特都不动。
    //
    //   规则：
    //     |新角 − 上次接受的角| ≤ GATE_DEG  → 立即接受（真运动每帧 1~2°）
    //     否则把该值挂起；同一候选连续 GATE_N 帧互相在 GATE_TOL 内 → 接受
    //     挂起超过 GATE_MAX 帧 → 强制接受（防卡死）
    //   真跳变（拍手换方向、声源瞬移）延迟 GATE_N-1 = 2 帧（42ms）。
    //
    //   离线验证（sim/sim_gate.py，直接回放板上真实 CSV 的角度序列）：
    //     circle_v3.csv  42 → 0 次（30.7s）      扣住 31/1468 帧 = 2.1%
    //     run.csv  静止  27 → 9 次（24.6min）    扣住 0.1%
    //     circle_v2.csv  42 → 12 次              扣住 1.0%
    //     circle_slow2.csv 50 → 14 次            扣住 1.2%
    //   97.9% 的帧与未加门时逐位相同。
    // ================================================================
    reg              gate_init;      // 复位后第一帧直接接受（doa_tgt 还是 0，不该比）
    reg signed [8:0] gate_pend;      // 待确认的候选角度
    reg  [3:0]       gate_cnt;       // 已连续扣住多少帧
    reg  [3:0]       gate_pn;        // 当前候选已自洽多少帧
    reg signed [8:0] doa_tgt;        // GATE 通过的目标角（显示端以 SLEW_DEG 追随它）
    reg              big_move;       // 大跨步进行中：本段移动全程用 SLEW_BIG_DEG
    reg              flush_req;      // 请求协方差重建；保持到下一快拍被 cov_accum 采到

    // 拍手/敲击瞬态检测（见 CLAP_* 参数注释）
    reg  [43:0]      e_fast;         // 快能量 EMA（稳态 4×pwr，τ≈4 帧）
    reg  [43:0]      e_slow;         // 慢能量 EMA（稳态 64×pwr，τ≈64 帧）
    reg  [4:0]       evt_cnt;        // 事件窗口剩余帧数
    reg  [31:0]      pwr_reg;        // 目标 bin 能量（cov_accum 的 EMA 迹，见下方赋值块）
    reg  [31:0]      pwr_peak;        // 本次事件窗口内的能量峰值（运行最大值）

    wire signed [9:0] gate_full = {pred_w[8], pred_w} - {doa_tgt[8], doa_tgt};
    wire signed [9:0] gate_d    = (gate_full > 10'sd180)  ? (gate_full - 10'sd360) :
                                  (gate_full < -10'sd180) ? (gate_full + 10'sd360) : gate_full;
    wire        [9:0] gate_ad   = gate_d[9] ? (-gate_d) : gate_d;

    wire signed [9:0] pend_full = {pred_w[8], pred_w} - {gate_pend[8], gate_pend};
    wire signed [9:0] pend_d    = (pend_full > 10'sd180)  ? (pend_full - 10'sd360) :
                                  (pend_full < -10'sd180) ? (pend_full + 10'sd360) : pend_full;
    wire        [9:0] pend_ad   = pend_d[9] ? (-pend_d) : pend_d;

    wire gate_pass  = (GATE_EN == 0) || !gate_init || (gate_ad <= GATE_DEG);   // 走"立即接受"
    wire pend_same  = (gate_cnt != 4'd0) && (pend_ad <= GATE_TOL);             // 候选还自洽
    wire pend_ready = pend_same && ((gate_pn + 4'd1) >= GATE_N);               // 自洽够帧数
    // 事件窗口内不做"扣满就放行"：拍手尾巴上的噪声值只要扣够 8 帧也会被收下
    wire gate_force = ((gate_cnt + 4'd1) >= GATE_MAX) && (evt_cnt == 5'd0);
    wire accept_any = gate_pass || pend_ready || gate_force;                   // 本帧接受（三条路之一）

    // 能量是否够格更新目标角：窗口内只信峰值 2^SIG_DB_SH 以内的帧（见 SIG_* 参数）
    wire [31:0] peak_now = (pwr_reg > pwr_peak) ? pwr_reg : pwr_peak;
    wire        sig_ok   = (SIG_EN == 0) || (evt_cnt == 5'd0) ||
                           (pwr_reg > (peak_now >> SIG_DB_SH));
    wire        accept_g = accept_any && sig_ok;                                // 真正落到 doa_tgt 的接受

    // 本次接受相对"上一个被接受的值"跨了多少度（协方差重建判据用它，
    // 不用"到显示角的距离"——大跨步途中那个距离一直很大，会反复触发）
    wire signed [9:0] tchg_full = {pred_w[8], pred_w} - {doa_tgt[8], doa_tgt};
    wire signed [9:0] tchg      = (tchg_full > 10'sd180)  ? (tchg_full - 10'sd360) :
                                  (tchg_full < -10'sd180) ? (tchg_full + 10'sd360) : tchg_full;
    wire        [9:0] tchg_ad   = tchg[9] ? (-tchg) : tchg;

    // ---- 显示端限速（SLEW）：doa_out_reg 每帧最多向 doa_tgt 转 SLEW_DEG 度 ----
    //   GATE 决定"目标角"，这里只决定"显示角怎么走过去"：
    //   SLEW_EN=0 时 out_next 恒等于目标角，与上一版输出逐位一致。
    //   能量瞬态（拍手）窗口内把上限换成 SLEW_EVT_DEG（现取 6，比普通限速更低）——
    //   任何情况下单帧变化都不会超过上限，所以"圆周不跳"与"拍手不跳"同时成立。
    wire signed [9:0] tgt_next  = accept_g ? {pred_w[8], pred_w}
                                             : {doa_tgt[8], doa_tgt};
    wire signed [9:0] slew_full = tgt_next - {doa_out_reg[8], doa_out_reg};
    wire signed [9:0] slew_d    = (slew_full > 10'sd180)  ? (slew_full - 10'sd360) :
                                  (slew_full < -10'sd180) ? (slew_full + 10'sd360) : slew_full;
    wire        [9:0] slew_ad   = slew_d[9] ? (-slew_d) : slew_d;
    // 大跨步：本帧接受的目标离显示角太远 ⇒ 进入大跨步态，直到追上为止
    //   ⚠ evt_cnt==0 是 2026-11-02 加的：能量瞬态期间（拍手）一律不走 A 档。
    //     否则拍手第一帧就会置 big_move，限速被拉回 25°/帧，SLEW_EVT_DEG 改小也没用。
    //     持续声源搬移没有能量突变，evt_cnt 恒 0，A 档照旧（180° 仍 ~189ms）。
    wire              accept_big = accept_any && (slew_ad > BIG_TRIG_DEG) &&
                                   (evt_cnt == 5'd0);
    wire signed [9:0] slew_lim  = (evt_cnt != 5'd0)                     ? SLEW_EVT_DEG :
                                  ((big_move || accept_big) ? SLEW_BIG_DEG : SLEW_DEG);
    wire signed [9:0] slew_step = (SLEW_EN == 0 || (slew_ad <= slew_lim)) ? slew_d :
                                  (slew_d[9] ? -slew_lim : slew_lim);
    wire signed [9:0] out_full  = {doa_out_reg[8], doa_out_reg} + slew_step;
    wire signed [8:0] out_next  = (out_full > 10'sd180)  ? (out_full - 10'sd360) :
                                  (out_full < -10'sd180) ? (out_full + 10'sd360) : out_full;

    // ================================================================
    // 运动判据 v2：DOA 增量的符号 EMA（与 v1 并联，任一判动即切短记忆）
    //
    //   v1（mov_detect_3beam）是在 θp±12° 上比波束功率。转速一高 θp 被拖后，
    //   真实声源一直贴在 θp+12° 附近，比值 r 上不去 ⇒ 快转时判据反而看不见
    //   运动（模型：60°/s 命中 37%，100°/s 52%），这正是"越快跳得越多"的根。
    //   v2 直接用前导补偿已经算好的 d1（本帧 DOA 与上帧 DOA 的环绕差）：
    //       m ← m − m/2^MV2_SH + d1        （Q2，1 LSB = 0.25°）
    //   稳态匀速时 m ≈ 2^MV2_SH × 每帧转角，与 θp 是否滞后无关；静止时 d1
    //   零均值，m 只剩抖动；陷波换峰那种单帧大跳只给 m 一个瞬态，几十毫秒
    //   衰减光。判据：|m| ≥ ENTER 置位；|m| < EXIT 连续 MV2_HOLD 帧后清位；
    //   介于两者之间保持原状态（滞回）。
    //   与 v1 取并集：v1 的快转漏检和 v2 的偶发误置位互补。
    //   ⚠ 门限不能按"模型里的静止噪声"定：真实板上 24.6 分钟静止数据
    //     （run.csv，96.8% 步进为 0，另有 3.2% 的 1~2° 单帧抖动）里，|m| 的
    //     中位数就有 3、90% 分位 7 —— 单帧 1° 抖动经 EMA 后足以越过 1.5°/帧 的
    //     门限，加上滞回后会一直卡在"动"上：ENT=6/EXIT=2 在真数据上误判 45.6%。
    //     所以门限必须抬到静止抖动之上：ENT=12（17.9°/s）→ 误判 1.6%，
    //     而 31°/s 时 m≈21、60°/s 时 m≈40，仍有 1.8~3.4 倍余量。
    //   ⚠ 这里用的是原始 doa_w 的增量，不是补偿后的输出角，与 d1 一致。
    //   验证见 sim/sim_mv2_sweep.py（真静止数据扫参数）与 sim/sim_motion_v2.py
    //   （模型：31/60/100°/s、宽带声源都是 0 次/分跳变）。
    //   MV2_EN=0 可单独关掉，回到只用 v1 的行为。
    // ================================================================
    reg  signed [13:0] m_ema;       // 增量 EMA（Q2）
    reg                v2_moving;   // v2 判据结果
    reg                v2_arm;      // 热身后第一帧只建基准、不判
    reg  [3:0]         v2_hold;     // 清位保持计数

    wire signed [11:0] d1_q2 = {d1, 2'b00};                       // 4·d1（Q2）
    wire signed [15:0] m_sum = m_ema - (m_ema >>> MV2_SH) + d1_q2;
    wire signed [13:0] m_sat = (m_sum > 16'sd8191)  ?  14'sd8191 :
                               (m_sum < -16'sd8191) ? -14'sd8191 : m_sum[13:0];
    wire        [13:0] m_abs = m_sat[13] ? (-m_sat) : m_sat;      // |m|（±8191 内）

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            m_ema     <= 14'sd0;
            v2_moving <= 1'b0;
            v2_arm    <= 1'b0;
            v2_hold   <= 4'd0;
        end else if (mvdr_done) begin
            if (!warm_ok) begin             // 冷启动抑制期间不建立增量历史
                m_ema   <= 14'sd0;
                v2_hold <= 4'd0;
                v2_arm  <= 1'b0;
            end else if (!v2_arm) begin     // 热身后第一帧只建基准
                v2_arm  <= 1'b1;
                m_ema   <= 14'sd0;
            end else begin
                m_ema <= m_sat;
                if (m_abs >= MV2_ENTER) begin
                    v2_moving <= 1'b1;
                    v2_hold   <= MV2_HOLD;
                end else if (m_abs < MV2_EXIT) begin
                    if (v2_hold != 4'd0)
                        v2_hold <= v2_hold - 4'd1;
                    else
                        v2_moving <= 1'b0;
                end
                // 介于 EXIT 与 ENTER 之间：滞回，保持原状态
            end
        end
    end

    // v1 ∪ v2；MOTION_EN=0 时整体失效（回到 EMA 固定 S，与旧行为一致）
    wire moving_all = (MOTION_EN != 0) &&
                      (det_moving | ((MV2_EN != 0) ? v2_moving : 1'b0));

    // 两个判据的原始判决单独引出（串口日志用：板上直接看到"哪个判据认出了运动"）
    assign mot_v1 = (MOTION_EN != 0) && det_moving;
    assign mot_v2 = (MOTION_EN != 0) && (MV2_EN != 0) && v2_moving;

    // ================================================================
    // 目标 bin 能量 —— 用于"有无信号"门限
    //   cov_accum 的 pwr_out = 8 bin 对角线迹 Σ|X_i|² 的 EMA（纯实部，64bit）。
    // 用于两处：evt_now 的绝对下限 2048；以及事件窗口内相对峰值的 SIG_* 门限。
    // ================================================================
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n)
            pwr_reg <= 32'd0;
        else if (cov_rdone)
            pwr_reg <= cov_pwr[47:16];   // 取中间 32 位，噪声/弱信号都有区分度
    end
    assign pwr_out = pwr_reg;

    // 能量瞬态（拍手/敲击）判据：快/慢 EMA 比 > 2.5（= e_fast<<5 > 5·e_slow）。
    // 下限 2048 防止静音时 e_slow 太小、比值无意义。
    wire [43:0] pwr_ext = {12'd0, pwr_reg};
    wire        evt_now = (e_slow > 44'd2048) && ((e_fast << 5) > (e_slow + (e_slow << 2)));

    // 快拍有效：只在 S_ACCUM 阶段放行给协方差累积（S_RUN 期间丢弃，避免重启）
    wire xready_g = (state == S_ACCUM) & bx_ready;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done_sticky<= 1'b0;
            snap_cnt   <= 8'd0;
            doa_reg    <= 9'sd0;
            doa_out_reg<= 9'sd0;
            doa_tgt    <= 9'sd0;
            e_fast     <= 44'd0;
            e_slow     <= 44'd0;
            evt_cnt    <= 5'd0;
            pwr_peak   <= 32'd0;
            gate_init  <= 1'b0;
            gate_pend  <= 9'sd0;
            gate_cnt   <= 4'd0;
            gate_pn    <= 4'd0;
            dh0        <= 9'sd0;
            dh1        <= 9'sd0;
            dh2        <= 9'sd0;
            warm_cnt   <= 8'd0;
            smin_reg   <= 32'sd0;
            shift_reg  <= 6'd0;
            core_start_ack <= 1'b0;
            doa_done       <= 1'b0;
            run_pending    <= 1'b0;
            big_move       <= 1'b0;
            flush_req      <= 1'b0;
        end else begin
            core_start_ack <= 1'b0;
            doa_done       <= 1'b0;   // 默认清，只在收结果那拍拉高
            if (xready_g) flush_req <= 1'b0;   // 已被 cov_accum 采走（同拍采样，下一拍清）
            case (state)
            S_IDLE: begin
                if (AUTO_RUN || start_req) begin
                    core_start_ack <= start_req; // 只有真来自 AXI 才回 ack
                    busy           <= 1'b1;
                    done_sticky    <= 1'b0;
                    snap_cnt       <= 8'd0;
                    state          <= S_ACCUM;
                end
            end

            S_ACCUM: begin
                if (xready_g)
                    snap_cnt <= snap_cnt + 8'd1;   // rdone 后离开 S_ACCUM，自然停在 K
                if (cov_rdone)                   // K 个快拍攒够，链路自动往下跑
                    run_pending <= 1'b1;
                // 运动检测若正占用导向 ROM（约 6µs），等它跑完再启动；否则与旧版同拍启动
                if (run_pending && !det_busy) begin
                    run_pending <= 1'b0;
                    state       <= S_RUN;
                end
            end

            S_RUN: begin
                if (mvdr_done) begin
                    warm_cnt    <= (warm_cnt >= WARM_N) ? warm_cnt          // 冷启动抑制计数（饱和）
                                                        : (warm_cnt + 8'd1);
                    doa_reg     <= doa_w;        // 始终跟随：运动检测器 1.34s 内也保持对准
                    // 能量双 EMA + 拍手事件窗口（每帧都更新，冷启动期间也更新）
                    e_fast <= e_fast - (e_fast >> 2) + pwr_ext;
                    e_slow <= e_slow - (e_slow >> 6) + pwr_ext;
                    if ((CLAP_EN != 0) && evt_now) begin
                        evt_cnt  <= CLAP_HOLD;                 // 新事件：开窗口，窗口内走 SLEW_EVT_DEG
                        pwr_peak <= pwr_reg;                   //   峰值从触发帧重新计
                    end else if (evt_cnt != 5'd0) begin
                        evt_cnt  <= evt_cnt - 5'd1;
                        if (pwr_reg > pwr_peak)                // 窗口内跟踪峰值（信号可能晚 1 帧到）
                            pwr_peak <= pwr_reg;
                    end
                    if (warm_ok) begin
                        // 离群剔除：接受（正常帧/候选确认/扣太久）或继续扣住
                        if (accept_g) begin
                            doa_tgt     <= pred_w[8:0];                      // 已含超前补偿，未开时=doa_w
                            gate_init   <= 1'b1;
                            gate_cnt    <= 4'd0;
                            gate_pn     <= 4'd0;
                            gate_pend   <= pred_w[8:0];
                        end else begin
                            // 饱和在 GATE_MAX-1：事件窗口内 gate_force 被关掉，计数会一直涨。
                            // 若涨到 15 再 +1，4bit 会回绕成 0，把"候选自洽"计数清零；
                            // 而且窗口结束后 (15+1)=0 >= GATE_MAX 恒假，强制放行就永久失效。
                            gate_cnt    <= (gate_cnt >= (GATE_MAX - 1)) ? gate_cnt : (gate_cnt + 4'd1);
                            gate_pn     <= pend_same ? (gate_pn + 4'd1) : 4'd1;
                            gate_pend   <= pend_same ? gate_pend : pred_w[8:0];
                        end
                        // 大跨步：接受的目标跳得远就开；本帧能一步走到就算追上了，关掉
                        if (accept_big)
                            big_move <= 1'b1;
                        else if (slew_ad <= slew_lim)
                            big_move <= 1'b0;
                        // 跨过 CLR_DEG 的接受 ⇒ 旧记忆的方向作废，让协方差重建一次
                        if ((CLR_EN != 0) && accept_g && (tchg_ad > CLR_DEG))
                            flush_req <= 1'b1;
                        doa_out_reg <= out_next;    // 显示端限速（SLEW_EN=0 时恒 = 目标角）
                        dh2         <= dh1;                                  // 增量历史移位
                        dh1         <= dh0;                                  //   （给 4 帧门控用）
                        dh0         <= d1[8:0];
                        smin_reg    <= smin_w;
                        shift_reg   <= cq_shift;
                        doa_done    <= 1'b1;    // 与 doa_reg 同一拍更新
                    end
                    done_sticky <= 1'b1;
                    if (AUTO_RUN) begin
                        snap_cnt <= 8'd0;       // 自动模式：马上开下一轮，从 0 重新累积
                        state    <= S_ACCUM;    // 不停机，连续测向（busy 保持 1）
                    end else begin
                        busy  <= 1'b0;          // AUTO_RUN=0 保持原行为；snap_cnt 保持 K 供 PS 读 0x14
                        state <= S_IDLE;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ================================================================
    // 3.5) 后处理序列 FSM：cov_to_q16/mat_inv 复用 8 次（bin0 → bin7 → sweep）
    //      phase 0..7 = 处理 bin phase（conv + inv），phase 8 = sweep 扫角
    // ================================================================
    reg [3:0] phase;      // 0..7 = 正在处理 bin phase；8 = sweep
    reg [2:0] conv_bin;   // 当前要转换的 bin（R mux 选择），每 conv_start 自增

    // conv_start：bin0 由 cov_rdone 启动；bin1..7 由上一个 inv 完成（mi_done）启动
    // （提前声明：下面 phase FSM 里要用它清 conv_bin，xvlog 要求先声明后用）
    wire conv_start = (cov_rdone && (phase == 4'd0)) || (mi_done && (phase < 4'd7));

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            phase    <= 4'd0;
            conv_bin <= 3'd0;
        end else begin
            case (phase)
            4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7:
                if (mi_done) phase <= phase + 4'd1;   // 本 bin 求逆完成，进下一个 bin
            4'd8:
                if (mvdr_done) phase <= 4'd0;         // sweep 融合完成，回初始
            default: phase <= 4'd0;
            endcase
            if (conv_start) conv_bin <= conv_bin + 3'd1;   // 8 次后自然绕回 0（3bit）
        end
    end

    // 本 bin 36 项在协方差 BRAM 里的起始地址（conv_bin*36），cov_to_q16 据此顺序读
    wire [8:0] conv_base = conv_bin * 9'd36;

    // 单份 cov_to_q16 → 单份 mat_inv：inv 直接吃 cov 的 cq 流，无需 mux
    wire inv_start     = cq_start;
    wire inv_din_valid = cq_valid;
    wire signed [31:0] inv_din_re = cq_re;
    wire signed [31:0] inv_din_im = cq_im;

    // sweep 在 bin0 求逆输出开始时就启动（连续收 8 段逆矩阵）
    wire sweep_start = mi_start && (phase == 4'd0);

    // ================================================================
    // 4) 内部链路实例化（宽带 8 bin）
    // ================================================================
    bin_extract_8ch #(.BIN0(BIN0), .BIN1(BIN1), .BIN2(BIN2), .BIN3(BIN3),
                      .BIN4(BIN4), .BIN5(BIN5), .BIN6(BIN6), .BIN7(BIN7),
                      .XW(XW), .NB(NB)) u_bin (
        .clk(clk), .rst_n(core_rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .X_re(bx_re), .X_im(bx_im),
        .ready(bx_ready)
    );

    cov_accum_8x8 #(.NCH(8), .XW(XW), .K(K), .AW(AW), .NT(NT), .NB(NB), .S(S), .SM(SM)) u_cov (
        .clk(clk), .rst_n(core_rst_n),
        .X_re(bx_re), .X_im(bx_im),
        .motion(moving_all),
        .flush(flush_req),
        .xready(xready_g),
        .rc_addr(cq_rc_addr), .rc_re(cov_rc_re), .rc_im(cov_rc_im),
        .pwr_out(cov_pwr),
        .rdone(cov_rdone)
    );

    cov_to_q16 #(.N(8), .NT(NT), .AW(AW)) u_conv (
        .clk(clk), .rst_n(core_rst_n),
        .start(conv_start),
        .base(conv_base),
        .rc_addr(cq_rc_addr), .rc_re(cov_rc_re), .rc_im(cov_rc_im),
        .dout_re(cq_re), .dout_im(cq_im),
        .dout_valid(cq_valid), .dout_start(cq_start), .done(cq_done),
        .shift_used(cq_shift)
    );

    mat_inv_8x8 u_inv (
        .clk(clk), .rst_n(core_rst_n),
        .start(inv_start),
        .din_valid(inv_din_valid), .din_re(inv_din_re), .din_im(inv_din_im),
        .dout_re(mi_re), .dout_im(mi_im),
        .dout_valid(mi_valid), .dout_start(mi_start), .done(mi_done)
    );

    mvdr_sweep #(.N(8), .NANG(NANG), .NB(NB)) u_sweep (
        .clk(clk), .rst_n(core_rst_n),
        .start(sweep_start),
        .din_valid(mi_valid), .din_re(mi_re), .din_im(mi_im),
        .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .s_out(s_out), .s_valid(s_valid),
        .doa_deg(doa_w), .s_min(smin_w), .done(mvdr_done)
    );

    // ---- 运动检测：每个快拍用"当前快拍"在 θp、θp±Δ 三个角度的波束功率比，
    //      判断声源是否已离开上一输出角度 θp。只在 S_ACCUM（sweep 空闲）时接管 ROM。
    wire det_start = (MOTION_EN != 0) && (state == S_ACCUM) && bx_ready && !det_busy;

    mov_detect_3beam #(.NB(NB), .NCH(8), .XW(XW), .DELTA(DELTA)) u_mov (
        .clk(clk), .rst_n(core_rst_n),
        .start(det_start),
        .X_re(bx_re), .X_im(bx_im),
        .doa_deg(doa_reg),
        .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .det_req(det_req), .det_ang(det_ang),
        .moving(det_moving), .busy(det_busy)
    );

    // ---- 8 份导向 ROM（bin5..bin43），各自 .mem，共享 a_req/a_ang ----
    wire       avalid0, avalid1, avalid2, avalid3, avalid4, avalid5, avalid6, avalid7;
    wire signed [31:0] av_re0, av_im0, av_re1, av_im1, av_re2, av_im2, av_re3, av_im3;
    wire signed [31:0] av_re4, av_im4, av_re5, av_im5, av_re6, av_im6, av_re7, av_im7;

    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin5.mem"), .IMFILE("steer_im_bin5.mem")) u_rom0 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid0), .av_re(av_re0), .av_im(av_im0)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin10.mem"), .IMFILE("steer_im_bin10.mem")) u_rom1 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid1), .av_re(av_re1), .av_im(av_im1)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin15.mem"), .IMFILE("steer_im_bin15.mem")) u_rom2 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid2), .av_re(av_re2), .av_im(av_im2)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin20.mem"), .IMFILE("steer_im_bin20.mem")) u_rom3 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid3), .av_re(av_re3), .av_im(av_im3)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin25.mem"), .IMFILE("steer_im_bin25.mem")) u_rom4 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid4), .av_re(av_re4), .av_im(av_im4)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin31.mem"), .IMFILE("steer_im_bin31.mem")) u_rom5 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid5), .av_re(av_re5), .av_im(av_im5)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin37.mem"), .IMFILE("steer_im_bin37.mem")) u_rom6 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid6), .av_re(av_re6), .av_im(av_im6)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin43.mem"), .IMFILE("steer_im_bin43.mem")) u_rom7 (
        .clk(clk), .rst_n(core_rst_n), .a_req(rom_req), .a_ang(rom_ang),
        .avalid(avalid7), .av_re(av_re7), .av_im(av_im7)
    );

    // 打包成总线给 sweep（[7] = bin7，[0] = bin0）
    assign avalid = {avalid7, avalid6, avalid5, avalid4, avalid3, avalid2, avalid1, avalid0};
    assign av_re  = {av_re7,  av_re6,  av_re5,  av_re4,  av_re3,  av_re2,  av_re1,  av_re0};
    assign av_im  = {av_im7,  av_im6,  av_im5,  av_im4,  av_im3,  av_im2,  av_im1,  av_im0};

    // ================================================================
    // 5) 读数据 mux
    // ================================================================
    always @(*) begin
        case (rd_addr)
        4'd0:    rd_data = 32'd0;                              // 0x00 CTRL：只写，读回 0
        4'd1:    rd_data = {30'd0, done_sticky, busy};         // 0x04 STATUS
        4'd2:    rd_data = {{23{doa_out_reg[8]}}, doa_out_reg}; // 0x08 DOA（有符号度，已含门控超前补偿）
        4'd3:    rd_data = smin_reg;                           // 0x0C S_MIN
        4'd4:    rd_data = {26'd0, shift_reg};                 // 0x10 SHIFT_USED
        4'd5:    rd_data = {24'd0, snap_cnt};                  // 0x14 SNAP_CNT
        4'd6:    rd_data = {16'd0, BIN0[7:0], BIN1[7:0]};      // 0x18 BIN_LIST
        4'd7:    rd_data = 32'h4D56_4452;                      // 0x1C VERSION "MVDR"
        4'd8:    rd_data = {{23{das_doa[8]}}, das_doa};         // 0x20 DAS_DOA（有符号度，快速粗测）
        4'd9:    rd_data = {31'd0, das_sig};                    // 0x24 DAS_STATUS（bit0=有无信号）
        4'd10:   rd_data = {16'd0, BIN2[7:0], BIN3[7:0]};      // 0x28 BIN_LIST2
        4'd11:   rd_data = {16'd0, BIN4[7:0], BIN5[7:0]};      // 0x2C BIN_LIST3
        4'd12:   rd_data = {16'd0, BIN6[7:0], BIN7[7:0]};      // 0x30 BIN_LIST4
        4'd13:   rd_data = pwr_reg;                           // 0x34 PWR（MVDR 总能量 E，门限用）
        5'd19:   rd_data = {29'd0, v2_moving, det_busy, det_moving};  // 0x4C MOTION（bit0=v1 运动, bit1=检测忙, bit2=v2 运动）
        default: rd_data = 32'd0;
        endcase
    end

endmodule



// ============================================================
// mov_detect_3beam —— 运动声源检测（3 波束瞬时比较）
//
// 解决的问题：EMA 协方差有 ~1.3s 的记忆（S=7）。声源沿圆弧移动时，R 里混着
//   最近 1.3s 走过的所有方向，MVDR 谱的全局最小点总是落后于真实方向；落后
//   太多时会"跳"到另一个凹陷处（串口上 60°→270° 中间没有任何过渡）。静止
//   声源不存在这个问题，所以静止读数一直很稳。
//
// 判据（波束/移位/平方的定点细节与 sim/doa_adapt_sim3.py 的定点模型逐位
// 对应；判决门限见下面 2026-10-30 的修正说明）：
//   b_b(k) = |Σ_ch conj(a_b(ch,k))·X_b(ch)|²        逐 bin 求波束功率
//   b(k)   = Σ_bins b_b(k)                          8 bin 非相干融合
//   r      = max( b(θp−Δ), b(θp+Δ) ) / b(θp)        θp = 上一轮输出角度
//   声源还在 θp 上时，相邻波束比 θp 低（r < 1）；离开 θp 后 r > 1。判据是
//   比值，与音量无关，不需要另标定门限。
//   运动：r > 1 + 1/16 且连续 CONFIRM 次成立；静止：r < 1 清除；中间保持。
//
// ⚠ 2026-10-30 单音声源误触发修正（sim/sim_detect_cal.py、sim_detect_sweep2.py）：
//   旧判据是 r > 1 立即置位、r < 0.859 才清除。实测（定点模型，4 个随机种子
//   一致）单音声源——也就是蜂鸣器、提示音这种只落 1~2 个 bin 的声源——静止
//   时 r 的均值就在 0.986~1.0 之间（低 kR 的 bin 对 ±12° 本来就没分辨力，
//   bin10 kR=0.87，声源偏 24° 时 r 才 1.05），一半的帧随机越过 1.0；而退出线
//   0.859 在窄带下永远够不着 -> 一旦误置位就永久锁死，协方差每 2^SM 个快拍
//   忘一次，MVDR 谱峰被噪声顶走，静止声源也乱跳（实测短记忆占比 100%）。
//   改成「抬高进入门限 + 连续多帧确认 + 退出线提到 r<1」后，同样的场景短记忆
//   占比 0%，而 90°/s 环绕的 RMS 只从 6.7° 变到 7.4°、跳变仍为 0；拍手拖尾
//   从 60.6° 降到 2.3°。
//   CONFIRM=5（每快拍判一次，10.49ms）对应模型里的"连续 3 个 21ms 帧"，
//   首次命中到切短记忆 42ms；相邻间隔比模型密一倍，同样窗口内样本更多，
//   抗噪比模型更强。相对 S=7 的 1.3s 记忆可忽略。
//
// ⚠ 2026-10-30 定点仿真修正（sim/doa_adapt_sim3.py 取证）：
//   ① 8 bin 必须"先平方再相加"（非相干融合）。若先做跨 bin 复数相干累加
//      再平方，各 bin 源谱相位随机 → 比值方差极大：静止声源误触发率 46%/61%
//      （30/10dB），等于长期锁死在短记忆上，静态精度全失。
//   ② 导向矢量取 Q16.16 的高 24 位（[31:8]，8 位小数）。只取 [31:14] 时
//      只剩 2 位小数（分辨率 0.25），静止误触发率 24%~89%，同样不可用。
//   ③ 平方前的字节对齐移位由"本帧 max|X|"统一决定（扫描 128 个分量，
//      128 拍），不能由各累加值自身决定——那样每个 bin/角度的缩放不同，
//      跨 bin 的功率权重被破坏。
//   改完后定点模型与浮点参考在 30/10dB、4 个输入量程下逐项一致：
//   静止误触发 0%，运动轨迹指标（跳变数/最大步进/RMS）完全相同。
//
// 时序：与 mvdr_sweep 共用 8 份 steer_rom（上层把 a_req/a_ang 二选一）。
//   扫描 128 拍 + 24 次请求（3 角度 × 8 bin，每次 8 通道）≈ 470 拍，50MHz
//   约 9.4µs，远小于快拍间隔 10.5ms；只在 S_ACCUM（sweep 空闲）时运行。
//
// 定点：a 取 Q16.16 高 24 位（>>8，值域 ±256）；x 取 24bit 高 18 位（>>6）；
//   24×18 乘法仍是 1 个 DSP48，每拍 4 乘（一个复数 MAC）。每个 (角度,bin)
//   请求累加 8 通道后立即平方（18×18 复用 1 个乘法器），P_θ 累加 8 个 bin
//   的功率。移位码由 max|X| 的 MSB 决定：<=10→0, <=18→8, <=26→16, 否则 24
//   （|y| <= 8·(√2·2^8)·(√2·(max|X|>>6)) = 2^(msb+6)，右移后 < 2^17 不溢出）。
//   P 48bit，每项 < 2^34、8 项 < 2^37，不溢出。
// ============================================================
module mov_detect_3beam #(
    parameter integer NB    = 8,    // 频点数
    parameter integer NCH   = 8,    // 阵元数
    parameter integer XW    = 24,   // 谱位宽
    parameter integer DELTA = 12,   // 邻波束偏移（度）
    parameter integer CONFIRM = 5   // 连续命中多少次才判运动（每快拍判一次，10.5ms）
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,     // 一拍脉冲：用当前快拍判一次
    input  wire [NB*NCH*XW-1:0]    X_re,      // 当前快拍，bin b 的第 ch 路 = [(b*NCH+ch)*XW +: XW]
    input  wire [NB*NCH*XW-1:0]    X_im,
    input  wire signed [8:0]       doa_deg,   // 上一轮 DOA（-180..180），ROM 索引 = doa_deg（<0 时 +360）
    input  wire [NB-1:0]           avalid,    // 8 份 ROM 的 valid（共享）
    input  wire signed [NB*32-1:0] av_re,     // 8 份 ROM 的导向矢量（Q16.16）
    input  wire signed [NB*32-1:0] av_im,
    output reg                     det_req,   // 导向 ROM 请求
    output reg  [8:0]              det_ang,
    output reg                     moving,    // 1=声源在动（保持到下一次判定）
    output reg                     busy
);

    localparam [9:0] DL10 = DELTA;

    // ---------------- 三个角度索引（0..360；θp 由 doa_deg 换算，±Δ 环绕）----------------
    // mvdr_sweep 的 doa_deg = wrap(ang)（安装偏移与 deg_best 的 -180 抵消），
    // 所以 ROM 索引就是 doa_deg 本身（负数 +360）。0 与 360 是同一物理方向。
    wire [9:0] doa10    = {doa_deg[8], doa_deg};                                      // 10bit 符号扩展
    wire [9:0] idx0_10  = doa_deg[8] ? (doa10 + 10'd360) : doa10;                     // 0..360
    wire [9:0] idxp_10 = (idx0_10 + DL10 > 10'd360) ? (idx0_10 + DL10 - 10'd360) : (idx0_10 + DL10);
    wire [9:0] idxm_10 = (idx0_10 < DL10) ? (idx0_10 + 10'd360 - DL10) : (idx0_10 - DL10);

    reg [8:0] ang_m, ang_0, ang_p;
    function [8:0] ang_of;
        input [1:0] k;
        begin
            ang_of = (k == 2'd0) ? ang_m : ((k == 2'd1) ? ang_0 : ang_p);
        end
    endfunction

    // ---------------- 扫描/请求共用计数器 ----------------
    reg  [2:0]  bsel;      // 当前 bin 0..7（扫描与请求共用）
    reg  [2:0]  ch;        // 当前通道 0..7
    reg  [1:0]  ai;        // 当前角度 0=θp−Δ, 1=θp, 2=θp+Δ
    reg  [23:0] mx;        // max(|X_re|, |X_im|)
    reg         sc_im;     // 扫描相位：0=比实部，1=比虚部

    // ---------------- 当前 (bin, ch) 的谱与导向 ----------------
    // 扫描（求 max|X|）和 MAC 共用这一个 X mux，不额外加 mux。
    wire signed [XW-1:0] x_re_b = X_re[(bsel*NCH + ch)*XW +: XW];
    wire signed [XW-1:0] x_im_b = X_im[(bsel*NCH + ch)*XW +: XW];
    wire signed [17:0]   xe_re  = x_re_b[XW-1:XW-18];     // 24bit -> 高 18 位
    wire signed [17:0]   xe_im  = x_im_b[XW-1:XW-18];

    wire signed [31:0] a_re_b = av_re[bsel*32 +: 32];
    wire signed [31:0] a_im_b = av_im[bsel*32 +: 32];
    wire signed [23:0] ae_re  = a_re_b[31:8];             // Q16.16 -> 8 位小数
    wire signed [23:0] ae_im  = a_im_b[31:8];

    wire signed [42:0] mpr = ae_re*xe_re + ae_im*xe_im;   // conj(a)·x 实部
    wire signed [42:0] mpi = ae_re*xe_im - ae_im*xe_re;   // conj(a)·x 虚部

    wire signed [23:0] ssel = sc_im ? x_im_b : x_re_b;
    wire [23:0]        sabs = ssel[23] ? -ssel : ssel;

    // 字节对齐移位码：|y| <= 2^(msb+6)，右移后 < 2^17
    reg [4:0] msb_x;
    integer t;
    always @(*) begin
        msb_x = 5'd0;
        for (t = 0; t < 24; t = t + 1)
            if (mx[t]) msb_x = t;        // 最高有效位（0..23）
    end
    reg [1:0] sh_sel;
    always @(*) begin
        if      (msb_x <= 5'd10) sh_sel = 2'd0;   // >>0
        else if (msb_x <= 5'd18) sh_sel = 2'd1;   // >>8
        else if (msb_x <= 5'd26) sh_sel = 2'd2;   // >>16
        else                     sh_sel = 2'd3;   // >>24
    end

    // ---------------- 复波束累加（每个 (角度,bin) 请求独立清一次）----------------
    reg signed [31:0] bre, bim;           // 8 通道累加，|值| <= 2^29
    reg signed [42:0] pr_q, pi_q;         // 乘积打一拍再累加，20ns 路径不超
    reg               acc_v;

    // ---------------- 平方（18×18 复用 1 个乘法器，每个请求 2 拍）----------------
    reg         sq_c;                     // 0=实部 1=虚部
    wire signed [31:0] sh_in = sq_c ? bim : bre;
    wire signed [17:0] op0 = sh_in[17:0];                        // >>0
    wire signed [17:0] op1 = sh_in[25:8];                        // >>8
    wire signed [17:0] op2 = {{2{sh_in[31]}},  sh_in[31:16]};    // >>16（符号扩展）
    wire signed [17:0] op3 = {{10{sh_in[31]}}, sh_in[31:24]};    // >>24（符号扩展）
    wire signed [17:0] sq_op = (sh_sel == 2'd0) ? op0 : ((sh_sel == 2'd1) ? op1 :
                               ((sh_sel == 2'd2) ? op2 : op3));
    wire signed [35:0] sq_full = sq_op * sq_op;

    reg signed [35:0] sq_r;
    reg [1:0]         sq_kr;
    reg               sq_v;
    reg [47:0]        P_m, P_0, P_p;      // 各角度 8 个 bin 的功率和
    wire [47:0]       Pm = (P_m > P_p) ? P_m : P_p;

    // ---------------- 判决滞回 ----------------
    //   进入：r = Pm/P0 > 1 + 1/16，且连续 CONFIRM 次成立
    //   退出：r < 1        （中心波束已不弱于两侧 = 声源回到 θp 上）
    //   其余：保持（迟滞带 1.0 ~ 1.0625）
    // 退出线不能再低：窄带下 r 贴着 1 走（均值 0.986），0.859 够不着就锁死。
    wire [47:0]       p_mov = P_0 + (P_0 >> 4);   // 1.0625 · P0
    reg  [3:0]        confirm;                    // 连续命中计数（饱和于 CONFIRM）

    // ---------------- 状态机 ----------------
    localparam D_IDLE = 3'd0, D_SCAN = 3'd1, D_REQ = 3'd2,
               D_DRAIN = 3'd3, D_CALC = 3'd4, D_FIN = 3'd5;
    reg [2:0] dstate;
    reg [1:0] cal;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dstate  <= D_IDLE;
            busy    <= 1'b0;
            moving  <= 1'b0;
            det_req <= 1'b0;
            det_ang <= 9'd0;
            ai <= 2'd0; bsel <= 3'd0; ch <= 3'd0; cal <= 2'd0;
            ang_m <= 9'd0; ang_0 <= 9'd0; ang_p <= 9'd0;
            mx <= 24'd0; sc_im <= 1'b0;
            bre <= 0; bim <= 0; pr_q <= 0; pi_q <= 0; acc_v <= 1'b0;
            sq_c <= 1'b0; sq_r <= 0; sq_kr <= 2'd0; sq_v <= 1'b0;
            P_m <= 0; P_0 <= 0; P_p <= 0;
            confirm <= 4'd0;
        end else begin
            // ---- 复数 MAC 流水（乘积已打一拍）----
            if (acc_v) begin
                bre <= bre + pr_q;
                bim <= bim + pi_q;
                acc_v <= 1'b0;
            end

            // ---- 平方结果流水 ----
            if (sq_v) begin
                case (sq_kr)
                    2'd0: P_m <= P_m + sq_r;
                    2'd1: P_0 <= P_0 + sq_r;
                    default: P_p <= P_p + sq_r;
                endcase
                sq_v <= 1'b0;
            end

            case (dstate)
            D_IDLE: begin
                if (start) begin
                    busy    <= 1'b1;
                    ang_m   <= idxm_10[8:0];
                    ang_0   <= idx0_10[8:0];
                    ang_p   <= idxp_10[8:0];
                    ai      <= 2'd0;
                    bsel    <= 3'd0;
                    ch      <= 3'd0;
                    sc_im   <= 1'b0;
                    mx      <= 24'd0;
                    bre <= 0; bim <= 0;
                    P_m <= 0; P_0 <= 0; P_p <= 0;
                    det_req <= 1'b0;
                    dstate  <= D_SCAN;
                end
            end

            D_SCAN: begin
                // 每 2 拍处理一个 (bin,ch)：先实部后虚部
                if (sabs > mx) mx <= sabs;
                if (sc_im == 1'b0) begin
                    sc_im <= 1'b1;
                end else begin
                    sc_im <= 1'b0;
                    if (ch == NCH-1) begin
                        ch <= 3'd0;
                        if (bsel == NB-1) begin          // 扫描结束，发第一次请求
                            bsel    <= 3'd0;
                            ai      <= 2'd0;
                            det_ang <= ang_m;
                            det_req <= 1'b1;
                            dstate  <= D_REQ;
                        end else
                            bsel <= bsel + 3'd1;
                    end else
                        ch <= ch + 3'd1;
                end
            end

            D_REQ: begin
                if (avalid[bsel]) begin
                    pr_q  <= mpr;
                    pi_q  <= mpi;
                    acc_v <= 1'b1;
                    if (ch == NCH-1) begin
                        ch      <= 3'd0;
                        det_req <= 1'b0;          // 本 bin 收完，请求落下
                        dstate  <= D_DRAIN;
                    end else begin
                        ch <= ch + 3'd1;
                    end
                end
            end

            D_DRAIN: begin
                // 第 8 个通道的乘积本拍进累加器，下一拍 bre/bim 才定
                cal    <= 2'd0;
                dstate <= D_CALC;
            end

            D_CALC: begin
                // 2 拍平方（实部/虚部），第 3 拍 P 加完并推进到下一次请求。
                // 请求落下后 ROM 有 2 拍回 S_IDLE，这里隔了 3 拍，不会撞上。
                case (cal)
                2'd0: begin
                    sq_r  <= sq_full;            // 实部
                    sq_kr <= ai;
                    sq_v  <= 1'b1;
                    sq_c  <= 1'b1;
                    cal   <= 2'd1;
                end
                2'd1: begin
                    sq_r  <= sq_full;            // 虚部
                    sq_kr <= ai;
                    sq_v  <= 1'b1;
                    sq_c  <= 1'b0;
                    cal   <= 2'd2;
                end
                default: begin
                    bre <= 0; bim <= 0;          // 下一个请求从 0 累加
                    if (ai == 2'd2 && bsel == NB-1) begin
                        dstate <= D_FIN;         // 24 个请求全部完成
                    end else begin
                        if (bsel != NB-1) begin
                            bsel    <= bsel + 3'd1;
                            det_ang <= ang_of(ai);
                        end else begin
                            bsel    <= 3'd0;
                            ai      <= ai + 2'd1;
                            det_ang <= ang_of(ai + 2'd1);
                        end
                        det_req <= 1'b1;
                        dstate  <= D_REQ;
                    end
                end
                endcase
            end

            D_FIN: begin
                // 滞回判据（见文件头 2026-10-30 修正说明）
                if ((P_0 == 48'd0) || (Pm < P_0)) begin
                    moving  <= 1'b0;              // 无信号 / 中心波束最强 → 静止
                    confirm <= 4'd0;
                end else if (Pm > p_mov) begin    // 相邻波束明显更强 → 疑似运动
                    if (confirm >= CONFIRM-1) begin
                        moving  <= 1'b1;          // 连续 CONFIRM 次才真正切短记忆
                        confirm <= CONFIRM-1;
                    end else begin
                        confirm <= confirm + 4'd1;
                    end
                end else begin
                    // 迟滞带（P0 <= Pm <= 1.0625·P0）：moving 保持原状态，
                    // 但计数必须清零 —— 与 sim_detect_fix.py 的模型一致。
                    // 若这里保留计数，窄带静止时 r 贴着 1.0 走，零星命中会被
                    // 迟滞带的帧"续上"而攒满，重新变成误触发。
                    confirm <= 4'd0;
                end
                busy   <= 1'b0;
                dstate <= D_IDLE;
            end

            default: dstate <= D_IDLE;
            endcase
        end
    end

endmodule
