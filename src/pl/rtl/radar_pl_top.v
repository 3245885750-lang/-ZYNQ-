`timescale 1ns / 1ps
// ============================================================
// radar_pl_top.v —— 声学雷达 PL 顶层（I2S + FFT + MVDR 精测 + DAS 粗测 + 频谱流输出）
//
// 时钟：全链路只用 50MHz 晶振 sys_clk（U18），无需 MMCM。
//   （已确认 i2s_fft8_axis 由 sample_valid 驱动、无 100MHz 依赖）
//
// 数据流：
//   8×INMP441 --sd[7:0]--> i2s_rx_8ch --i2s_cdc_8ch--> i2s_fft8_axis(乒乓)
//              --> fft_512 --> 8 帧频谱（AXI4-Stream）
//
// 本阶段目的：验证真实麦克风 + I2S + FFT 链路正确（用 ILA 抓频谱）。
// 下一阶段：把 fft_tdata/tvalid/tlast 接到 mvdr_axi_top 做波束成形，
//           再包 AXI 给 PS（队友 B）。
//
// 调试：本文件已去掉全部 mark_debug。之前标 mark_debug 会强制
//       u_master/u_fft8/u_mvdr/u_das 保持层次（keep_hierarchy），
//       禁止跨模块优化、白烧几千 LUT，导致布线拥塞。需要上 ILA 时再加回。
// ============================================================
module radar_pl_top (
    input  wire        sys_clk,     // U18, 50MHz
    input  wire        sys_rst_n,   // N16, 低有效
    input  wire [7:0]  sd,          // 8 路麦克风数据（J4 排针）
    output wire        sck,         // 位时钟 → 8 个 INMP441
    output wire        ws,          // 字选择 → 8 个 INMP441
    output wire        led0,        // H15, 心跳灯（~1.5Hz 闪）
    output wire        led1,        // L15, DOA 命中灯（常亮=测向正确）
    output wire        uart_txd     // J15, 串口打印 DOA（底板 CH340，PL UART）
);

    // ---- I2S 主机：50MHz → SCK=3.125MHz / WS=48.828kHz ----
    i2s_master u_master (
        .clk   (sys_clk),
        .rst_n (sys_rst_n),
        .sck   (sck),
        .ws    (ws)
    );

    // ---- 8 路 I2S → FFT 频谱（AXI4-Stream 输出）----
    // 注意：这些 net 不再标 mark_debug——mark_debug 会强制 u_mvdr/u_fft8/u_das
    //       保持层次（keep_hierarchy），禁止跨模块优化，白白多烧几千 LUT。
    //       需要上 ILA 调试时再临时加回。
    wire [63:0] fft_tdata;
    wire        fft_tvalid;
    wire        fft_tlast;
    wire        fft_busy;
    wire [127:0] ads_data;   // 原始采样 8×16bit，接 DAS
    wire         ads_valid;  // 48.828kHz 脉冲

    // ---- 临时自检版：频谱流不外引（无 DMA），tready 内部拉 1，行为与纯 PL 自检一致 ----
    wire fft_axis_tready = 1'b1;

    i2s_fft8_top u_fft8 (
        .clk                          (sys_clk),
        .rst_n                        (sys_rst_n),
        .sck                          (sck),
        .ws                           (ws),
        .sd                           (sd),
        .m_axis_data_tdata            (fft_tdata),
        .m_axis_data_tvalid           (fft_tvalid),
        .m_axis_data_tready           (fft_axis_tready),   // 由 DMA 背压（纯 PL 阶段固定 1）
        .m_axis_data_tlast            (fft_tlast),
        .busy                         (fft_busy),
        .sample_data_o                (ads_data),
        .sample_valid_o               (ads_valid),
        .event_tlast_missing          (),
        .event_data_in_channel_halt   (),
        .event_data_out_channel_halt  ()
    );

    // ---- led0 心跳灯（自由计数，不看复位）----
    // 只要 50MHz 时钟在跑就闪，永久用来确认"板子活着 / 时钟正常"。
    //   led0 = bit24 → ~1.5Hz
    reg [24:0] led_cnt = 25'd0;
    always @(posedge sys_clk) begin
        led_cnt <= led_cnt + 25'd1;
    end
    assign led0 = led_cnt[24];

    // ================= MVDR 波束成形：连续测向 + DOA 自检 =================
    // AUTO_RUN=1 上电自动连续测向，PS 直接读 DOA 寄存器即可（无需 START）；AXI 端口已引到顶层。
    // 宽带 8 bin 非相干融合（476.9Hz..4100.8Hz 分散频段）+ 协方差遗忘因子 EMA(S=7)：
    //   主瓣在所有频率固定在声源方向、栅瓣/驻波随频率漂移，多 bin 相加主瓣相干增强、
    //   栅瓣互相抵消，消除单频跳变；EMA 去掉块边界阶跃，旋转声源时轨迹更顺滑。
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
        // AXI4-Lite：临时自检版 tie-off（无 PS，AUTO_RUN=1 自跑）；BD-ready 版见 radar_pl_top_bd.v
        .s_axi_awaddr   (32'd0),          .s_axi_awvalid (1'b0),          .s_axi_awready (),
        .s_axi_wdata    (32'd0),          .s_axi_wstrb   (4'd0),          .s_axi_wvalid  (1'b0),          .s_axi_wready (),
        .s_axi_bresp    (),               .s_axi_bvalid  (),               .s_axi_bready  (1'b0),
        .s_axi_araddr   (32'd0),          .s_axi_arvalid (1'b0),          .s_axi_arready (),
        .s_axi_rdata    (),               .s_axi_rresp   (),               .s_axi_rvalid  (),               .s_axi_rready (1'b0),
        // AXI4-Stream：接 FFT 输出流
        .s_axis_tdata   (fft_tdata),
        .s_axis_tvalid  (fft_tvalid),
        .s_axis_tready  (fft_axis_tready),
        .s_axis_tlast   (fft_tlast),
        // 调试输出
        .doa_deg        (doa_deg),
        .doa_done       (doa_done),
        .pwr_out        (pwr),
        // 运动判据判决（串口 V= 字段用，见 doa_uart）
        .mot_v1         (mot_v1),
        .mot_v2         (mot_v2),
        // DAS 粗测结果透传（供队友 B 经 AXI 读 0x20/0x24）
        .das_doa        (doa_das),
        .das_sig        (das_sig),
        // 本自检顶层不含瞬态 TDOA，0x50/0x54 恒为 0
        .tdoa_doa       (9'sd0),
        .tdoa_status    (3'd0)
    );

    // ================= DAS 时域延时求和：宽带快速粗测（~21ms/次）=================
    // 用原始采样做分数延时求和（2 抽头线性插值，1° 步长），任意声音（宽带）
    // 都能快速锁定大致方向；MVDR 继续做宽带精测确认（8 bin 非相干融合 + EMA）。
    // 粗测 doa_das/das_done/das_sig 供 LED + UART。
    // DAS 信号门限（与 das_pwr 同尺度 = best_pwr[47:16]）。
    //   实测没声音时 das_pwr 大多 <0x8000（稳态噪声），拍手/说话等宽带信号 >0x10000。
    //   初始 0x8000 = 32768：滤掉稳态噪声、保住弱信号。
    //   调法：误报（关门/走动也打）→ 往上调（0x10000~0x20000）；
    //         漏报（远处小声不报）→ 往下调（0x4000）。
    //   注意：DAS 是宽带，瞬态大噪声（能量>门限）仍会偶尔误打，属固有局限。
    localparam [31:0] DAS_PWR_TH = 32'h8000;   // 信号门限（与 das_pwr 同尺度 = best_pwr[47:16]）；实测 4.1kHz 纯音 P=0x86xx~0xFxxx，都 >0x8000，能过

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
    //   实测：没声音时 E=0x00000000（噪声落在 [47:16] 切片之外），有声音时 E≥0x15A0。
    //   但 0x15A0 是声源近距离的数据；放远后 |X| 按 1/r 衰减，E 会掉很多。
    //   噪声是严格 0，所以门限可以压很低：0x40 对应 |X|≈90（-51dBFS），
    //   既稳过滤噪声、又能接住远处弱信号。想更灵敏就再往下调（最低 0x01）。
    localparam [31:0] PWR_TH = 32'h0040;
    wire sig_present = (pwr > PWR_TH);

    // ---- led1 DOA 命中灯（改用 DAS 快速粗测驱动，反应快）----
    //   灭          = 没信号（das_sig=0）
    //   常亮        = 有信号，且粗 DOA 命中 TARGET_DOA±TOL → 测向正确
    //   快闪(~3Hz)  = 有信号，但方向不在目标范围
    // DAS 每 ~21ms 更新一次驱动 LED；MVDR 也已提到 ~47.7Hz（K=2），两者同速。
    localparam signed [8:0] TARGET_DOA = 9'sd0;    // 期望声源角度，按喇叭摆位改
    localparam signed [8:0] TOL        = 9'sd5;    // DAS 2° 步长 + 实测 ±2-3° 抖动，容差留 ±5° 防 LED 闪
    wire signed [8:0] doa_lo = TARGET_DOA - TOL;
    wire signed [8:0] doa_hi = TARGET_DOA + TOL;
    wire das_in_range = (doa_das >= doa_lo) && (doa_das <= doa_hi);

    reg das_match;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            das_match <= 1'b0;
        else if (das_done)
            das_match <= das_sig & das_in_range;   // 与 das_doa/das_sig 同拍更新
    end
    assign led1 = das_sig ? (das_match ? 1'b1 : led_cnt[23]) : 1'b0;

    // ================= 波束成形干净音频：给 PS 做声源识别 =================
    // 按当前 MVDR DOA 做分数延时求和，输出 1 路 48.828kHz/16bit 单声道音频。
    // 自检版没有 DMA 消费，tready 拉 1 让它自由流出（FIFO 满就丢样本），不影响测向。
    wire [15:0] aud_tdata;
    wire        aud_tvalid;
    wire        aud_tlast;

    // ---------------------------------------------------------------
    // 【对照实验开关】AUDIO_EN = 1：波束音频模块在此例化（当前默认）
    //                AUDIO_EN = 0：整个模块不例化（综合时被完全优化掉），
    //                               用于 A/B 对比「加音频前后旋转是否一样丝滑」
    //   改完这一个数字重新综合即可，其它都不用动。
    // ---------------------------------------------------------------
    localparam AUDIO_EN = 1;

    generate
    if (AUDIO_EN) begin : g_audio
        bf_audio_out u_bfaudio (
            .clk            (sys_clk),
            .rst_n          (sys_rst_n),
            .sample_data    (ads_data),
            .sample_valid   (ads_valid),
            .doa_deg        (doa_deg),
            .m_axis_tdata   (aud_tdata),
            .m_axis_tvalid  (aud_tvalid),
            .m_axis_tready  (1'b1),        // 自检版无消费者
            .m_axis_tlast   (aud_tlast)
        );
    end else begin : g_no_audio
        assign aud_tdata  = 16'd0;
        assign aud_tvalid = 1'b0;
        assign aud_tlast  = 1'b0;
    end
    endgenerate

    // ---- 串口打印 DOA（115200 8N1，输出到 uart_txd）----
    //   MVDR 行 "M=270 E=0012AB34 V=01\r\n"（~21ms/47.7Hz，宽带精测，有信号才打）
    //   V=<v1><v2>：两条运动判据本帧的判决，1=判为运动（协方差切短记忆）
    // DAS 行已停用：D 是时域宽带粗测，栅瓣让角度乱跳，已被 K=2 的快速 MVDR 取代。
    // 没信号时串口静默。
    // wire das_print  = das_done  & das_sig;      // DAS 有信号才打（已停用）
    wire mvdr_print = doa_done  & sig_present;  // MVDR 有信号才打
    doa_uart u_uart (
        .clk      (sys_clk),
        .rst_n    (sys_rst_n),
        .doa_deg  (doa_deg),
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
