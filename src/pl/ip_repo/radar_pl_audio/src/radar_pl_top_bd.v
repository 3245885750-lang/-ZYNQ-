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
    output wire        m_axis_audio_tlast
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

    // ---- 频谱流不外引（识别阶段的波束音频流是下一步再加）----
    wire fft_axis_tready = 1'b1;

    i2s_fft8_top u_fft8 (
        .clk                          (sys_clk),
        .rst_n                        (sys_rst_n),
        .sck                          (sck),
        .ws                           (ws),
        .sd                           (sd),
        .m_axis_data_tdata            (fft_tdata),
        .m_axis_data_tvalid           (fft_tvalid),
        .m_axis_data_tready           (fft_axis_tready),
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

    // DAS 粗测结果（声明必须在 u_mvdr 引用之前）
    wire signed [8:0] doa_das;   // 粗 DOA（-180..+180，2° 步长，分数延时）
    wire              das_done;  // 每 WIN 样本一拍脉冲，与 doa_das 同拍
    wire              das_sig;   // 有无信号（max 束功率 > 门限）
    wire [31:0]       das_pwr;   // DAS max 束功率高 32 位（校准门限用）

    // Integration telemetry; all signals remain in the 50 MHz domain.
    wire [31:0] audio_dropped;
    reg [31:0] das_seq, mvdr_seq, audio_count;
    reg signed [8:0] das_doa_ps;
    reg das_sig_ps;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            das_seq <= 0; mvdr_seq <= 0; audio_count <= 0;
            das_doa_ps <= 0; das_sig_ps <= 0;
        end else begin
            if (das_done) begin
                das_seq <= das_seq + 1'b1;
                das_doa_ps <= doa_das;
                das_sig_ps <= das_sig;
            end
            if (doa_done) mvdr_seq <= mvdr_seq + 1'b1;
            if (m_axis_audio_tvalid && m_axis_audio_tready)
                audio_count <= audio_count + 1'b1;
        end
    end

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
        .s_axis_tready  (fft_axis_tready),
        .s_axis_tlast   (fft_tlast),
        // 调试输出
        .doa_deg        (doa_deg),
        .doa_done       (doa_done),
        .pwr_out        (pwr),
        // DAS 粗测结果透传（供队友 B 经 AXI 读 0x20/0x24）
        .das_doa        (das_doa_ps),
        .das_sig        (das_sig_ps),
        .das_seq_in     (das_seq),
        .mvdr_seq_in    (mvdr_seq),
        .audio_dropped_in(audio_dropped),
        .audio_count_in (audio_count)
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
        .doa_deg        (doa_deg),
        .m_axis_tdata   (m_axis_audio_tdata),
        .m_axis_tvalid  (m_axis_audio_tvalid),
        .m_axis_tready  (m_axis_audio_tready),
        .m_axis_tlast   (m_axis_audio_tlast),
        .dropped_samples(audio_dropped)
    );

    // ---- 串口打印 DOA（115200 8N1，输出到 uart_txd）----
    wire mvdr_print = doa_done  & sig_present;  // MVDR 有信号才打
    doa_uart u_uart (
        .clk      (sys_clk),
        .rst_n    (sys_rst_n),
        .doa_deg  (doa_deg),
        .doa_done (mvdr_print),
        .pwr      (pwr),
        .das_doa  (doa_das),
        .das_done (1'b0),      // 关闭 DAS 打印
        .das_pwr  (das_pwr),
        .uart_txd (uart_txd)
    );

endmodule
