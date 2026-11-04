`timescale 1ns / 1ps
// ============================================================
// radar_pl_top_bd.v —— BD-ready 版顶层（给队友 B 交付用）
//   与 radar_pl_top.v（自检版）唯一区别：顶层引出 s_axi_* AXI4-Lite 从机，
//   供队友 B 在 Block Design 里接 PS M_AXI_GP0 读 DOA/pwr。
//   注意：本文件不能单独 Generate Bitstream（s_axi_* 无引脚，Place 30-374 预期）。
//
// 时钟：全链路只用 50MHz 晶振 sys_clk（U18），无需 MMCM。
//   （已确认 i2s_fft8_axis 由 sample_valid 驱动、无 100MHz 依赖）
//
// 数据流：
//   8×INMP441 --sd[7:0]--> i2s_rx_8ch --i2s_cdc_8ch--> i2s_fft8_axis(乒乓)
//              --> fft_512 --> 8 帧频谱（AXI4-Stream）
// ============================================================
module radar_pl_top_bd (
    input  wire        sys_clk,     // U18, 50MHz
    input  wire        sys_rst_n,   // N16, 低有效
    input  wire [7:0]  sd,          // 8 路麦克风数据（J4 排针）
    output wire        sck,         // 位时钟 → 8 个 INMP441
    output wire        ws,          // 字选择 → 8 个 INMP441
    output wire        led0,        // H15, 心跳灯（~1.5Hz 闪）
    output wire        led1,        // L15, DOA 命中灯（常亮=测向正确）
    output wire        uart_txd,    // J15, 串口打印 DOA（底板 CH340，PL UART）

    // ---- AXI4-Lite 从机（PS M_AXI_GP0 → PL，读 DOA/pwr）----
    // 时钟 = sys_clk（50MHz，单时钟域）；PS 侧 100MHz 由 AXI Interconnect 从口 50MHz 自动跨时钟。
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

    // ---- AXI4-Stream 主口：波束成形干净音频（给 PS 识别用，接 DMA）----
    // 16bit 单声道 有符号 PCM @ 48.828kHz；tlast 每 1024 样本拉一拍（≈21ms 一帧）。
    // 时钟 = sys_clk（50MHz），与 AXI4-Lite 同一时钟域。
    output wire [15:0] m_axis_audio_tdata,
    output wire        m_axis_audio_tvalid,
    input  wire        m_axis_audio_tready,
    output wire        m_axis_audio_tlast,

    // SFP8 v1: 64-byte header + 4096-byte FFT payload per channel.
    // TLAST once per 4160-byte channel packet; 8 packets/group (33280 B).
    // Same 50MHz domain. Backpressure still affects internal FFT/MVDR.
    output wire [63:0] fft_axis_tdata,
    output wire        fft_axis_tvalid,
    output wire        fft_axis_tlast,
    input  wire        fft_axis_tready
);

    // ---- I2S 主机：50MHz → SCK=3.125MHz / WS=48.828kHz ----
    i2s_master u_master (
        .clk   (sys_clk),
        .rst_n (sys_rst_n),
        .sck   (sck),
        .ws    (ws)
    );

    // ---- 8 路 I2S → FFT 频谱（AXI4-Stream 输出）----
    wire [63:0] fft_tdata;
    wire        fft_tvalid;
    wire        fft_tlast;
    wire        fft_busy;
    wire [127:0] ads_data;   // 原始采样 8×16bit，接 DAS
    wire         ads_valid;  // 48.828kHz 脉冲

    wire fft_raw_ready;
    // Internal MVDR sees raw FFT words; only DMA receives packet headers.
    i2s_fft8_tagged_top u_fft8 (
        .clk                          (sys_clk),
        .rst_n                        (sys_rst_n),
        .sck                          (sck),
        .ws                           (ws),
        .sd                           (sd),
        .m_axis_data_tdata            (fft_tdata),
        .m_axis_data_tvalid           (fft_tvalid),
        .raw_fft_tready               (fft_raw_ready),
        .dma_axis_tdata               (fft_axis_tdata),
        .dma_axis_tvalid              (fft_axis_tvalid),
        .dma_axis_tlast               (fft_axis_tlast),
        .dma_axis_tready              (fft_axis_tready),
        .capture_frames              (), .dropped_frames(), .format_errors(),
        .m_axis_data_tlast            (fft_tlast),
        .busy                         (fft_busy),
        .sample_data_o                (ads_data),
        .sample_valid_o               (ads_valid),
        .event_tlast_missing          (),
        .event_data_in_channel_halt   (),
        .event_data_out_channel_halt  ()
    );

    // ---- led0 心跳灯（自由计数，不看复位）----
    reg [24:0] led_cnt = 25'd0;
    always @(posedge sys_clk) begin
        led_cnt <= led_cnt + 25'd1;
    end
    assign led0 = led_cnt[24];

    // ================= MVDR 波束成形：连续测向 + DOA =================
    // AUTO_RUN=1 上电自动连续测向，PS 直接读 DOA 寄存器即可（无需 START）。
    wire signed [8:0] doa_deg;
    wire              doa_done;
    wire [31:0]       pwr;
    wire              mot_v1;    // 运动判据 v1 判决（θp±Δ 波束功率比）
    wire              mot_v2;    // 运动判据 v2 判决（DOA 增量 EMA）

    // DAS 粗测结果（声明必须在 u_mvdr 引用之前）
    wire signed [8:0] doa_das;   // 粗 DOA（-180..+180，2° 步长，分数延时）
    wire              das_done;  // 每 WIN 样本一拍脉冲，与 doa_das 同拍
    wire              das_sig;   // 有无信号（max 束功率 > 门限）
    wire [31:0]       das_pwr;   // DAS max 束功率高 32 位（校准门限用）

    // 拍手 TDOA 保持/状态（声明必须在 u_mvdr 引用之前）
    reg  [24:0]       tdoa_hold_cnt;
    reg  signed [8:0] doa_tdoa_lat;
    reg               tdoa_have;          // 上电后是否收到过可信结果
    reg               tdoa_last_lowconf;  // 最近一次结果是否低置信
    wire              tdoa_hold_active = (tdoa_hold_cnt != 25'd0);
    wire [2:0]        tdoa_status = {tdoa_have, tdoa_last_lowconf, tdoa_hold_active};

    mvdr_axi_top #(
        .AUTO_RUN   (1),
        .BIN0       (5),    //  5  ->  476.9Hz（宽带低频主区，覆盖语音/拍手）
        .BIN1       (10),   // 10  ->  953.7Hz
        .BIN2       (15),   // 15  -> 1430.5Hz
        .BIN3       (20),   // 20  -> 1907.4Hz
        .BIN4       (25),   // 25  -> 2384.3Hz
        .BIN5       (31),   // 31  -> 2956.6Hz
        .BIN6       (37),   // 37  -> 3528.8Hz
        .BIN7       (43),   // 43  -> 4100.8Hz（兼容旧验证频率）
        .S          (7),    // EMA 遗忘因子：α=1/128，等效记忆 ≈ 128 快拍（精度优先；拖尾由自适应记忆解决）
        .K          (2)     // 快拍 2：EMA 已持续平均，K 只管刷新率；M ~30Hz（≈26-36ms/次）
    ) u_mvdr (
        .clk            (sys_clk),
        .rst_n          (sys_rst_n),
        // AXI4-Lite：接到顶层端口（BD-ready），由 PS M_AXI_GP0 读 DOA/pwr
        .s_axi_awaddr   (s_axi_awaddr),   .s_axi_awvalid (s_axi_awvalid), .s_axi_awready (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),    .s_axi_wstrb   (s_axi_wstrb),   .s_axi_wvalid  (s_axi_wvalid),  .s_axi_wready (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),    .s_axi_bvalid  (s_axi_bvalid),  .s_axi_bready  (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),   .s_axi_arvalid (s_axi_arvalid), .s_axi_arready (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),    .s_axi_rresp   (s_axi_rresp),   .s_axi_rvalid  (s_axi_rvalid),  .s_axi_rready (s_axi_rready),
        // AXI4-Stream：接 FFT 输出流
        .s_axis_tdata   (fft_tdata),
        .s_axis_tvalid  (fft_tvalid),
        .s_axis_tready  (fft_raw_ready),
        .s_axis_tlast   (fft_tlast),
        // 调试输出
        .doa_deg        (doa_deg),
        .doa_done       (doa_done),
        .pwr_out        (pwr),
        // 运动判据判决（串口 V= 字段用；BD 版同样可读 0x4C）
        .mot_v1         (mot_v1),
        .mot_v2         (mot_v2),
        // DAS 粗测结果透传（供队友 B 经 AXI 读 0x20/0x24）
        .das_doa        (doa_das),
        .das_sig        (das_sig),
        // 拍手 TDOA 结果透传（PS 读 0x50/0x54）
        .tdoa_doa       (doa_tdoa_lat),
        .tdoa_status    (tdoa_status)
    );

    // ================= DAS 时域延时求和：宽带快速粗测（~21ms/次）=================
    localparam [31:0] DAS_PWR_TH = 32'h8000;   // 信号门限（与 das_pwr 同尺度 = best_pwr[47:16]）

    das_scan_top #(
        .PWR_TH     (DAS_PWR_TH)
    ) u_das (
        .clk          (sys_clk),
        .rst_n        (sys_rst_n),
        .sample_data  (ads_data),
        .sample_valid (ads_valid),
        .das_doa      (doa_das),
        .das_done     (das_done),
        .das_sig      (das_sig),
        .das_pwr      (das_pwr)
    );

    // ---- 能量门限：区分"没信号"和"有信号" ----
    localparam [31:0] PWR_TH = 32'h0040;
    wire sig_present = (pwr > PWR_TH);

    // ================= 瞬时声源（拍手/敲击）前沿 TDOA =================
    // 只读 ads_data / ads_valid，不碰 MVDR 的任何状态。
    // 触发后 ~2.1 ms 出角度；随后 TDOA_HOLD（500 ms）内，串口打印与波束成形的
    // 角度改用 TDOA 结果，其余时间仍是 MVDR。稳态声源/圆周没有任何瞬时触发，
    // 所以那条通路一位都不受影响。
    localparam integer TRANSIENT_EN = 1;
    // 保持时长：拍手的混响尾巴还有 0.3~0.6 s，这段时间 MVDR 本身是被拖走的；
    // 保持 0.5 s 让显示（和送 MLP 的波束音频）都用拍手的正确角度，之后自动交回 MVDR。
    localparam [24:0]  TDOA_HOLD    = 25'd25000000;  // 500 ms @ 50MHz

    wire signed [8:0] doa_tdoa;
    wire              tdoa_valid;
    wire              tdoa_lowconf;
    wire              tdoa_busy;

    transient_tdoa u_tdoa (
        .clk         (sys_clk),
        .rst_n       (sys_rst_n),
        .sample_data (ads_data),
        .sample_valid(ads_valid),
        .doa_deg     (doa_tdoa),
        .doa_valid   (tdoa_valid),
        .doa_lowconf (tdoa_lowconf),
        .busy        (tdoa_busy)
    );

    // tdoa_hold_cnt / doa_tdoa_lat / tdoa_have / tdoa_last_lowconf 已在 u_mvdr 前声明
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tdoa_hold_cnt     <= 25'd0;
            doa_tdoa_lat      <= 9'sd0;
            tdoa_have         <= 1'b0;
            tdoa_last_lowconf <= 1'b0;
        end else begin
            if (tdoa_valid)
                tdoa_last_lowconf <= tdoa_lowconf;
            if (tdoa_valid && !tdoa_lowconf) begin
                doa_tdoa_lat  <= doa_tdoa;
                tdoa_hold_cnt <= TDOA_HOLD;
                tdoa_have     <= 1'b1;
            end else if (tdoa_hold_cnt != 25'd0) begin
                tdoa_hold_cnt <= tdoa_hold_cnt - 25'd1;
            end
        end
    end

    // TDOA 出结果后立刻打一行（不等 MVDR 那一帧）。
    //   tdoa_print 比 doa_tdoa_lat 晚一拍，保证 doa_uart 采样时 doa_show 已经是新角度。
    //   拍手后约 2.1 ms 就能在串口上看到角度；原来要等下一帧 MVDR（≤36 ms），
    //   而且安静房间里 pwr 可能掉到门限以下，那一行干脆不打印——所以必须单独触发。
    reg tdoa_print;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            tdoa_print <= 1'b0;
        else
            tdoa_print <= tdoa_valid && !tdoa_lowconf;
    end

    // 对外用的角度：瞬态窗口内用 TDOA，其余用 MVDR
    wire signed [8:0] doa_show =
        ((TRANSIENT_EN != 0) && (tdoa_hold_cnt != 25'd0)) ? doa_tdoa_lat : doa_deg;

    // ---- led1 DOA 命中灯（DAS 快速粗测驱动）----
    localparam signed [8:0] TARGET_DOA = 9'sd0;    // 期望声源角度，按喇叭摆位改
    localparam signed [8:0] TOL        = 9'sd5;
    wire signed [8:0] doa_lo = TARGET_DOA - TOL;
    wire signed [8:0] doa_hi = TARGET_DOA + TOL;
    wire das_in_range = (doa_das >= doa_lo) && (doa_das <= doa_hi);

    reg das_match;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            das_match <= 1'b0;
        else if (das_done)
            das_match <= das_sig & das_in_range;
    end
    assign led1 = das_sig ? (das_match ? 1'b1 : led_cnt[23]) : 1'b0;

    // ================= 波束成形干净音频：给 PS 做声源识别 =================
    // 按当前 MVDR DOA 做分数延时求和，输出 1 路 48.828kHz/16bit 单声道音频流。
    bf_audio_out u_bfaudio (
        .clk            (sys_clk),
        .rst_n          (sys_rst_n),
        .sample_data    (ads_data),
        .sample_valid   (ads_valid),
        .doa_deg        (doa_show),
        .m_axis_tdata   (m_axis_audio_tdata),
        .m_axis_tvalid  (m_axis_audio_tvalid),
        .m_axis_tready  (m_axis_audio_tready),
        .m_axis_tlast   (m_axis_audio_tlast)
    );

    // ---- 串口打印 DOA（115200 8N1，输出到 uart_txd）----
    // MVDR 有信号才打；瞬时声源那一行由 tdoa_print 单独触发（不看 sig_present）
    wire mvdr_print = (doa_done & sig_present) | ((TRANSIENT_EN != 0) && tdoa_print);
    doa_uart u_uart (
        .clk      (sys_clk),
        .rst_n    (sys_rst_n),
        .doa_deg  (doa_show),
        .doa_done (mvdr_print),
        .pwr      (pwr),
        .mot_v1   (mot_v1),
        .mot_v2   (mot_v2),
        .das_doa  (doa_das),
        .das_done (1'b0),      // 关闭 DAS 打印
        .das_pwr  (das_pwr),
        .uart_txd (uart_txd)
    );

endmodule

// ============================================================
// transient_tdoa.v —— 瞬时声源（拍手/敲击）前沿 TDOA 测向
// ============================================================
// 为什么单独做这条路：
//   MVDR 的协方差是 512 点 / 10.5 ms 一块。拍手的直达声只有 ~1 ms，混响
//   5~25 ms 后才到——不管协方差怎么清，"一块里大部分时间装的是混响和底噪"
//   这个事实改不掉，拍手的 MVDR 测向原理上就容易被拖走。前沿 TDOA 只取最先
//   到的那几个样本，天然不看混响；出结果约 2.1 ms（MVDR 一帧是 21 ms）。
//
// 角度约定（与 steer_rom 逐位一致，因此与 mvdr_sweep 的 doa_deg 同一刻度）：
//   导向矢量 a_i = exp(-j*kR*cos(theta-alpha_i))，alpha_i = i*45deg
//   ⇒ 第 i 路的到达时刻（单位样本）t_i = t0 + (fs*R/c) * cos(theta - alpha_i)
//   ⇒ A = sum_i w_i*d_i*cos(alpha_i)，B = sum_i w_i*d_i*sin(alpha_i)
//      d_i = t_i - tbar，theta = atan2(B, A)
//   8 只咪在圆周上均匀分布 ⇒ sum(cos)=sum(sin)=0，公共时延 t0 自动抵消。
//   展开成只用加减（alpha 是 45 度的整数倍）：
//      A = (d0-d4) + 0.7071*(d1+d7-d3-d5)
//      B = (d2-d6) + 0.7071*(d1+d3-d5-d7)
//
// 处理流程：
//   1) 每样本算 |x[n]-x[n-1]|，再做 7 点滑动平均（>>3，纯加法），8 路打包进环缓
//   2) 快包络绝对下限 + 快/慢包络比触发（e_f tau=4，e_s tau=4096，比值 > 2^TH_SH）
//      上电先预热 0.5 s，避免慢包络还没稳定时误触发
//   3) 触发后再收 POST 个样本，窗口取 [触发-PRE, 触发+POST)
//   4) 只在触发点附近 [PRE-12, PRE+40] 找峰值，阈值 = max(该路峰值/4, 4*慢包络)
//      → 首次穿越 + 线性插值（亚样本）；二次撞击/反射在窗外，不抬阈值
//   5) 峰值不到最大路 1/2^PMAX_SH 的通道剔除（身体/桌面遮挡）
//   6) 加权最小二乘 → A/B → CORDIC 求 atan2 → +180° 安装偏移 → 角度
//   7) 相干度 coh^2 = 2(A^2+B^2)/(sw*sum w*d^2)：理想平面波 = 1，乱时刻 = 0.25
//      coh^2 < 0.75 或可用通道 < MIN_CH ⇒ doa_lowconf=1，顶层不要采用
//      （0.75 是离线模型定的：纯随机时刻误通过约 4%@0.5 → 4%@0.75 → 0%@1.0，
//        0.75 配合"能量必须跳 4 倍"的触发门限，现场基本不会误出角度）
//
// 资源：1 块 BRAM（256×128bit）+ 约 1.2k LUT + 1 个 DSP（A^2+B^2）。
// 不影响稳态/圆周的 MVDR 通路（本模块只读 sample_data / sample_valid）。
// ============================================================

module transient_tdoa #(
    parameter integer NCH      = 8,
    parameter integer PRE      = 32,          // 触发前的历史样本数
    parameter integer POST     = 96,          // 触发后继续收的样本数
    parameter integer TH_SH    = 2,           // 快/慢比门限：e_f/4 > (e_s/4096) << TH_SH
    parameter [16:0]  ABS_MIN  = 17'd16,      // 快包络绝对下限（防静音/低噪误触发）
    parameter integer PMAX_SH  = 3,           // 峰值 < pmax>>PMAX_SH 的通道剔除
    parameter integer MIN_CH   = 5,           // 至少几路可用才出结果
    parameter [31:0]  REFRACT  = 32'd1000000, // 触发后静默 20 ms @50MHz
    parameter integer BUF_AW   = 8,           // 环缓深度 256（须 > PRE+POST）
    parameter integer ARM_N    = 24414,       // 上电预热 0.5 s @48.828kHz
    parameter integer ONSET_LO = PRE - 12,    // 前沿搜索窗（窗内序号，相对触发点）
    parameter integer ONSET_HI = PRE + 40
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [NCH*16-1:0] sample_data,   // 8 路 × 16bit，与 sample_valid 同拍
    input  wire              sample_valid,  // 48.828kHz，1 拍脉冲
    output reg  signed [8:0] doa_deg,       // 与 mvdr_sweep 同一角度约定（-180..180）
    output reg               doa_valid,     // 1 拍脉冲：结果已更新
    output reg               doa_lowconf,   // 与 doa_valid 同拍：1 = 置信不足，别采用
    output wire              busy
);

    localparam integer WIN   = PRE + POST;
    localparam integer WIN1  = WIN + 1;       // 扫描收尾计数
    localparam integer BUF_N = (1 << BUF_AW);

    // ============================================================
    // 1. 一阶差分 + 环形缓冲
    // ============================================================
    reg signed [15:0] x_prev [0:NCH-1];

    wire [15:0] adiff [0:NCH-1];
    genvar g;
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_adf
            wire signed [16:0] df = $signed(sample_data[g*16 +: 16]) - x_prev[g];
            assign adiff[g] = df[16] ? (16'hFFFF - df[15:0] + 16'd1) : df[15:0];
        end
    endgenerate

    // 7 点滑动平均（因果箱型，群延迟 3 样本，8 路相同）：
    // |diff| 的前沿是锯齿状随机包络，直接找"首次穿越"会让各路在不同微峰上
    // 提前穿越，时延散开 5~10 个样本（≈40~80°）。短滑动平均是 LTI，
    // 不改变相对时延，只让前沿单调化。7 点比 5 点更平，弱拍手更稳。
    reg  [15:0] ad_h1 [0:NCH-1];
    reg  [15:0] ad_h2 [0:NCH-1];
    reg  [15:0] ad_h3 [0:NCH-1];
    reg  [15:0] ad_h4 [0:NCH-1];
    reg  [15:0] ad_h5 [0:NCH-1];
    reg  [15:0] ad_h6 [0:NCH-1];
    wire [15:0] sm    [0:NCH-1];

    genvar gsm;
    generate
        for (gsm = 0; gsm < NCH; gsm = gsm + 1) begin : g_sm
            wire [18:0] s7 = {3'd0, adiff[gsm]} + {3'd0, ad_h1[gsm]}
                           + {3'd0, ad_h2[gsm]} + {3'd0, ad_h3[gsm]}
                           + {3'd0, ad_h4[gsm]} + {3'd0, ad_h5[gsm]}
                           + {3'd0, ad_h6[gsm]};
            assign sm[gsm] = s7[18:3];        // (a[n]+...+a[n-6])/8，最大 57343，仍 16bit
        end
    endgenerate

    reg [NCH*16-1:0] abuf [0:BUF_N-1];        // 存 |差分| 的 7 点平滑值（16bit/路）
    reg [BUF_AW-1:0] wp;

    always @(posedge clk) begin
        if (sample_valid)
            abuf[wp] <= {sm[7], sm[6], sm[5], sm[4],
                         sm[3], sm[2], sm[1], sm[0]};
    end

    // 上电预热：慢包络 tau=4096，0.5 s 后才基本稳定；同时保证环缓已写过很多圈
    reg [14:0] warm_cnt;
    reg        warm_ok;

    integer iv;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp       <= {BUF_AW{1'b0}};
            warm_cnt <= 15'd0;
            warm_ok  <= 1'b0;
            for (iv = 0; iv < NCH; iv = iv + 1) begin
                x_prev[iv] <= 16'sd0;
                ad_h1[iv]  <= 16'd0;
                ad_h2[iv]  <= 16'd0;
                ad_h3[iv]  <= 16'd0;
                ad_h4[iv]  <= 16'd0;
                ad_h5[iv]  <= 16'd0;
                ad_h6[iv]  <= 16'd0;
            end
        end else if (sample_valid) begin
            wp <= wp + 1'b1;
            for (iv = 0; iv < NCH; iv = iv + 1) begin
                x_prev[iv] <= $signed(sample_data[iv*16 +: 16]);
                ad_h6[iv]  <= ad_h5[iv];
                ad_h5[iv]  <= ad_h4[iv];
                ad_h4[iv]  <= ad_h3[iv];
                ad_h3[iv]  <= ad_h2[iv];
                ad_h2[iv]  <= ad_h1[iv];
                ad_h1[iv]  <= adiff[iv];
            end
            if (!warm_ok) begin
                if (warm_cnt == ARM_N-1)
                    warm_ok <= 1'b1;
                else
                    warm_cnt <= warm_cnt + 15'd1;
            end
        end
    end

    // ============================================================
    // 2. 快/慢包络 + 触发
    // ============================================================
    function [15:0] max8;
        input [15:0] a0,a1,a2,a3,a4,a5,a6,a7;
        reg   [15:0] m01, m23, m45, m67, m0123, m4567;
        begin
            m01   = (a0 > a1) ? a0 : a1;
            m23   = (a2 > a3) ? a2 : a3;
            m45   = (a4 > a5) ? a4 : a5;
            m67   = (a6 > a7) ? a6 : a7;
            m0123 = (m01 > m23) ? m01 : m23;
            m4567 = (m45 > m67) ? m45 : m67;
            max8  = (m0123 > m4567) ? m0123 : m4567;
        end
    endfunction

    wire [15:0] env = max8(sm[0], sm[1], sm[2], sm[3],
                           sm[4], sm[5], sm[6], sm[7]);

    reg [23:0] e_f;     // tau = 4 样本
    reg [31:0] e_s;     // tau = 4096 样本
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_f <= 24'd0;
            e_s <= 32'd0;
        end else if (sample_valid) begin
            e_f <= e_f - (e_f >> 2)  + {8'd0, env};
            e_s <= e_s - (e_s >> 12) + {16'd0, env};
        end
    end

    wire [23:0] ef_n = e_f >> 2;
    wire [23:0] es_n = e_s >> 12;
    // 绝对下限改看"快"包络：慢包络 tau=84 ms，等它越过绝对门限时，0.25 ms 的
    // 拍手前沿早已过去（安静房间实测会晚 2~3 ms）。快包络在 onset 后几个样本
    // 就升起，下限只负责挡住数字静音/底噪，不再引入延迟。
    wire trig_now = warm_ok && (ef_n > {7'd0, ABS_MIN}) && (ef_n > (es_n << TH_SH));

    // ============================================================
    // 3. 主状态机
    // ============================================================
    localparam [2:0] S_IDLE  = 3'd0,
                     S_WAIT  = 3'd1,
                     S_PEAK  = 3'd2,
                     S_ONSET = 3'd3,
                     S_DIV   = 3'd4,
                     S_FIT   = 3'd5,
                     S_CORD  = 3'd6,
                     S_DONE  = 3'd7;

    reg [2:0]  state;
    reg [7:0]  wait_cnt;
    reg [BUF_AW-1:0] start_idx;
    reg [31:0] refract_cnt;
    reg [23:0] es_trig;                                // 触发瞬间的慢包络
    wire [25:0] es_trig_x4 = {2'd0, es_trig} << 2;     // 4*慢包络，做阈值下限

    reg [BUF_AW-1:0] raddr;
    reg [8:0]        kcnt;
    reg              rd_v;
    reg [NCH*16-1:0] q;
    reg [NCH*16-1:0] q_d;

    wire [15:0] qa [0:NCH-1];
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_qa
            assign qa[g] = q[g*16 +: 16];
        end
    endgenerate

    always @(posedge clk) begin
        if (state == S_PEAK || state == S_ONSET)
            q <= abuf[raddr];
    end

    reg [15:0] peak [0:NCH-1];
    reg [15:0] th   [0:NCH-1];
    reg        hit  [0:NCH-1];
    reg [7:0]  hk   [0:NCH-1];
    reg [15:0] ha_p [0:NCH-1];
    reg [15:0] ha_c [0:NCH-1];
    reg        wsel [0:NCH-1];

    reg [15:0] pmax;
    wire [15:0] peak_max = max8(peak[0], peak[1], peak[2], peak[3],
                                peak[4], peak[5], peak[6], peak[7]);

    reg [3:0]  dv_ch;
    reg [3:0]  dv_it;
    reg [24:0] dv_r;
    reg [16:0] dv_den;
    reg [5:0]  dv_q;
    reg signed [15:0] t_q6 [0:NCH-1];

    reg [2:0]  fit_st;
    reg [3:0]  fit_k;
    // signed：sd2_acc + dval*dval 若为无符号上下文，dval 会被零扩展，
    // 负时延差会变成 ~2^18 的大正数，相干度恒 ≈0、结果永远 lowconf。
    reg signed [39:0] sd2_acc;

    reg signed [17:0] dval [0:NCH-1];
    reg [4:0]  sw;
    reg signed [31:0] tbar;
    reg signed [19:0] Areg, Breg;
    reg        coh_ok;

    reg [4:0]  ci;
    reg signed [20:0] cx, cy;
    reg signed [31:0] cz;

    // 安装偏移：ch0 实际在 180°。atan2 得到的是阵列坐标 θ_code = φ+180，
    // 这里加 180°（Q8=46080）并 wrap 到 [-180,180)，与 mvdr_sweep/DAS 的
    // 物理角约定一致；否则串口角度和 bf_audio_out 的波束都会反 180°。
    wire signed [31:0] cz_p180 = cz + 32'sd46080;
    wire signed [31:0] cz_wrap = (cz_p180 > 32'sd46080)
                               ? (cz_p180 - 32'sd92160) : cz_p180;

    // ---- 组合：加权统计（只有加法，8 输入） ----
    reg [4:0]  sw_c;
    reg signed [31:0] sum_wt_c;
    reg signed [31:0] recip_c;
    integer ic;
    always @* begin
        sw_c     = 5'd0;
        sum_wt_c = 32'sd0;
        for (ic = 0; ic < NCH; ic = ic + 1) begin
            if (wsel[ic]) begin
                sw_c     = sw_c + 5'd1;
                sum_wt_c = sum_wt_c + {{16{t_q6[ic][15]}}, t_q6[ic]};
            end
        end
    end

    // 1/sw 的 Q8 倒数
    always @* begin
        case (sw_c)
            5'd1: recip_c = 32'sd256;
            5'd2: recip_c = 32'sd128;
            5'd3: recip_c = 32'sd85;
            5'd4: recip_c = 32'sd64;
            5'd5: recip_c = 32'sd51;
            5'd6: recip_c = 32'sd43;
            5'd7: recip_c = 32'sd37;
            default: recip_c = 32'sd32;
        endcase
    end

    // A / B（alpha 为 45 度整数倍，只有加减和 0.7071≈181/256）
    reg signed [19:0] A_c, B_c;
    always @* begin
        A_c = $signed(dval[0]) - $signed(dval[4])
            + ((32'sd181 * ($signed(dval[1]) + $signed(dval[7])
                           - $signed(dval[3]) - $signed(dval[5]))) >>> 8);
        B_c = $signed(dval[2]) - $signed(dval[6])
            + ((32'sd181 * ($signed(dval[1]) + $signed(dval[3])
                           - $signed(dval[5]) - $signed(dval[7]))) >>> 8);
    end

    reg signed [39:0] ab2_c;
    always @* begin
        ab2_c = Areg * Areg + Breg * Breg;
    end

    // CORDIC atan 表（Q8 度）
    function [31:0] atan_q8;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  atan_q8 = 32'd11520;   // 45.000
                5'd1:  atan_q8 = 32'd6801;    // 26.565
                5'd2:  atan_q8 = 32'd3593;    // 14.036
                5'd3:  atan_q8 = 32'd1824;    //  7.125
                5'd4:  atan_q8 = 32'd916;     //  3.576
                5'd5:  atan_q8 = 32'd458;     //  1.790
                5'd6:  atan_q8 = 32'd229;     //  0.895
                5'd7:  atan_q8 = 32'd115;     //  0.448
                5'd8:  atan_q8 = 32'd57;      //  0.224
                5'd9:  atan_q8 = 32'd29;      //  0.112
                5'd10: atan_q8 = 32'd14;      //  0.056
                5'd11: atan_q8 = 32'd7;       //  0.028
                5'd12: atan_q8 = 32'd4;       //  0.014
                5'd13: atan_q8 = 32'd2;       //  0.007
                5'd14: atan_q8 = 32'd1;       //  0.004
                default: atan_q8 = 32'd0;
            endcase
        end
    endfunction

    // ============================================================
    // 状态机主体
    // ============================================================
    integer jf;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            wait_cnt    <= 8'd0;
            start_idx   <= {BUF_AW{1'b0}};
            refract_cnt <= 32'd0;
            es_trig     <= 24'd0;
            raddr       <= {BUF_AW{1'b0}};
            kcnt        <= 9'd0;
            rd_v        <= 1'b0;
            q_d         <= {NCH*16{1'b0}};
            pmax        <= 16'd0;
            dv_ch       <= 4'd0;
            dv_it       <= 4'd0;
            dv_r        <= 25'd0;
            dv_den      <= 17'd0;
            dv_q        <= 6'd0;
            fit_st      <= 3'd0;
            fit_k       <= 4'd0;
            sd2_acc     <= 40'd0;
            sw          <= 5'd0;
            tbar        <= 32'sd0;
            Areg        <= 20'sd0;
            Breg        <= 20'sd0;
            coh_ok      <= 1'b0;
            ci          <= 5'd0;
            cx          <= 21'sd0;
            cy          <= 21'sd0;
            cz          <= 32'sd0;
            doa_deg     <= 9'sd0;
            doa_valid   <= 1'b0;
            doa_lowconf <= 1'b0;
            for (jf = 0; jf < NCH; jf = jf + 1) begin
                peak[jf] <= 16'd0;
                th[jf]   <= 16'd0;
                hit[jf]  <= 1'b0;
                hk[jf]   <= 8'd0;
                ha_p[jf] <= 16'd0;
                ha_c[jf] <= 16'd0;
                wsel[jf] <= 1'b0;
                t_q6[jf] <= 16'sd0;
                dval[jf] <= 18'sd0;
            end
        end else begin
            doa_valid   <= 1'b0;
            doa_lowconf <= 1'b0;

            if (refract_cnt != 32'd0)
                refract_cnt <= refract_cnt - 32'd1;

            case (state)

            // ---- 等触发 ----
            S_IDLE: begin
                rd_v <= 1'b0;
                if (sample_valid && trig_now && refract_cnt == 32'd0) begin
                    start_idx   <= wp - PRE;
                    wait_cnt    <= POST + 2;
                    refract_cnt <= REFRACT;
                    es_trig     <= es_n;
                    pmax        <= 16'd0;
                    for (jf = 0; jf < NCH; jf = jf + 1) begin
                        peak[jf] <= 16'd0;
                        hit[jf]  <= 1'b0;
                        wsel[jf] <= 1'b0;
                    end
                    state <= S_WAIT;
                end
            end

            // ---- 等窗口收满 ----
            S_WAIT: begin
                if (sample_valid) begin
                    if (wait_cnt == 8'd0) begin
                        raddr <= start_idx;
                        kcnt  <= 9'd0;
                        rd_v  <= 1'b0;
                        state <= S_PEAK;
                    end else
                        wait_cnt <= wait_cnt - 8'd1;
                end
            end

            // ---- 第一遍：只在触发点附近逐路找峰值 ----
            S_PEAK: begin
                if (kcnt != WIN1) begin
                    if (rd_v) begin
                        // 当前样本窗内序号 = kcnt-1；二次撞击/反射在窗外
                        if ((kcnt >= ONSET_LO+1) && (kcnt <= ONSET_HI+1))
                            for (jf = 0; jf < NCH; jf = jf + 1)
                                if (qa[jf] > peak[jf])
                                    peak[jf] <= qa[jf];
                        raddr <= raddr + 1'b1;
                    end
                    rd_v <= 1'b1;
                    kcnt <= kcnt + 9'd1;
                end else begin
                    // 阈值 = max(峰值/4, 4*触发时的慢包络)：后者防止弱通道在
                    // 噪声微峰上提前穿越
                    for (jf = 0; jf < NCH; jf = jf + 1) begin
                        if (({10'd0, peak[jf]} >> 2) >= es_trig_x4)
                            th[jf] <= peak[jf] >> 2;
                        else if (es_trig_x4 > 26'd65535)
                            th[jf] <= 16'hFFFF;
                        else
                            th[jf] <= es_trig_x4[15:0];
                    end
                    pmax  <= peak_max;
                    raddr <= start_idx;
                    kcnt  <= 9'd0;
                    rd_v  <= 1'b0;
                    state <= S_ONSET;
                end
            end

            // ---- 第二遍：每路在触发点附近首次穿越阈值的样本 ----
            S_ONSET: begin
                if (kcnt != WIN1) begin
                    if (rd_v) begin
                        // 窗内序号 = kcnt-1；只在前沿窗口里找，0 号样本没有 a[k-1]
                        if ((kcnt >= ONSET_LO+1) && (kcnt <= ONSET_HI+1)) begin
                            for (jf = 0; jf < NCH; jf = jf + 1) begin
                                if (!hit[jf] && (th[jf] != 16'd0) && (qa[jf] >= th[jf])) begin
                                    hit[jf]  <= 1'b1;
                                    hk[jf]   <= kcnt[7:0] - 8'd1;
                                    ha_p[jf] <= q_d[jf*16 +: 16];
                                    ha_c[jf] <= qa[jf];
                                end
                            end
                        end
                        q_d   <= q;
                        raddr <= raddr + 1'b1;
                    end
                    rd_v <= 1'b1;
                    kcnt <= kcnt + 9'd1;
                end else begin
                    dv_ch <= 4'd0;
                    dv_it <= 4'd0;
                    state <= S_DIV;
                end
            end

            // ---- 亚样本插值：frac = floor((th-a_p)*64/(a_c-a_p)) ----
            S_DIV: begin
                if (dv_ch >= NCH) begin
                    fit_st <= 3'd0;
                    state  <= S_FIT;
                end else if (!hit[dv_ch] || (ha_c[dv_ch] <= ha_p[dv_ch])
                             || (th[dv_ch] <= ha_p[dv_ch])) begin
                    t_q6[dv_ch] <= $signed({1'b0, hk[dv_ch], 6'b0});
                    dv_ch <= dv_ch + 4'd1;
                    dv_it <= 4'd0;
                end else if (dv_it == 4'd0) begin
                    dv_r   <= {8'd0, (th[dv_ch] - ha_p[dv_ch])};
                    dv_den <= {1'b0, ha_c[dv_ch]} - {1'b0, ha_p[dv_ch]};
                    dv_q   <= 6'd0;
                    dv_it  <= 4'd1;
                end else if (dv_it <= 4'd6) begin
                    if (({1'b0, dv_r[24:0]} << 1) >= {8'd0, dv_den}) begin
                        dv_r <= ({1'b0, dv_r[24:0]} << 1) - {8'd0, dv_den};
                        dv_q <= {dv_q[4:0], 1'b1};
                    end else begin
                        dv_r <= {1'b0, dv_r[24:0]} << 1;
                        dv_q <= {dv_q[4:0], 1'b0};
                    end
                    dv_it <= dv_it + 4'd1;
                end else begin
                    t_q6[dv_ch] <= $signed({1'b0, hk[dv_ch], 6'b0}) + $signed({10'd0, dv_q});
                    dv_ch <= dv_ch + 4'd1;
                    dv_it <= 4'd0;
                end
            end

            // ---- 拟合：权重 → 均值 → d_i → A/B → 相干度 ----
            S_FIT: begin
                if (fit_st == 3'd0) begin
                    for (jf = 0; jf < NCH; jf = jf + 1)
                        wsel[jf] <= hit[jf] && (peak[jf] >= (pmax >> PMAX_SH))
                                    && (ha_c[jf] > ha_p[jf]);
                    fit_st <= 3'd1;
                end else if (fit_st == 3'd1) begin
                    sw   <= sw_c;
                    tbar <= ($signed(sum_wt_c) * recip_c) >>> 8;
                    fit_st <= 3'd2;
                end else if (fit_st == 3'd2) begin
                    for (jf = 0; jf < NCH; jf = jf + 1)
                        dval[jf] <= wsel[jf] ? ($signed(t_q6[jf]) - $signed(tbar[15:0]))
                                             : 18'sd0;
                    sd2_acc <= 40'd0;
                    fit_k   <= 4'd0;
                    fit_st  <= 3'd3;
                end else if (fit_st == 3'd3) begin
                    // 一次一路累加 sum(w*d^2)，避免 8 个乘法器挤在一拍里
                    if (fit_k == NCH) begin
                        Areg   <= A_c;
                        Breg   <= B_c;
                        fit_st <= 3'd4;
                    end else begin
                        if (wsel[fit_k])
                            sd2_acc <= sd2_acc + ($signed(dval[fit_k]) * $signed(dval[fit_k]));
                        fit_k <= fit_k + 4'd1;
                    end
                end else begin
                    // coh^2 = 2(A^2+B^2)/(sw*sum w*d^2) > 0.75
                    // 2*ab2 > 0.75*sw*sd2  ⇔  8*ab2 > 3*sw*sd2
                    coh_ok <= (sw >= MIN_CH) &&
                              ((ab2_c * 50'd8) > (sd2_acc * {45'd0, sw} * 51'd3));
                    ci     <= 5'd0;
                    state  <= S_CORD;
                end
            end

            // ---- CORDIC 向量模式求 atan2(B, A) ----
            S_CORD: begin
                if (ci == 5'd0) begin
                    if (Areg < 20'sd0) begin
                        cx <= -Areg;
                        cy <= -Breg;
                        cz <= (Breg >= 20'sd0) ? 32'sd46080 : -32'sd46080;
                    end else begin
                        cx <= Areg;
                        cy <= Breg;
                        cz <= 32'sd0;
                    end
                    ci <= 5'd1;
                end else if (ci <= 5'd16) begin
                    if (cy > 21'sd0) begin
                        cx <= cx + (cy >>> (ci[3:0] - 4'd1));
                        cy <= cy - (cx >>> (ci[3:0] - 4'd1));
                        cz <= cz + $signed(atan_q8(ci[4:0] - 5'd1));
                    end else begin
                        cx <= cx - (cy >>> (ci[3:0] - 4'd1));
                        cy <= cy + (cx >>> (ci[3:0] - 4'd1));
                        cz <= cz - $signed(atan_q8(ci[4:0] - 5'd1));
                    end
                    ci <= ci + 5'd1;
                end else begin
                    // Q8 度 → 整数度（四舍五入），已含 +180° 安装偏移
                    if (cz_wrap >= 32'sd0)
                        doa_deg <= (cz_wrap + 32'sd128) >>> 8;
                    else
                        doa_deg <= -(((-cz_wrap) + 32'sd128) >>> 8);
                    doa_lowconf <= ~coh_ok;
                    doa_valid   <= 1'b1;
                    state       <= S_DONE;
                end
            end

            // ---- 收尾：等下一次触发 ----
            S_DONE: begin
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    assign busy = (state != S_IDLE);

endmodule
