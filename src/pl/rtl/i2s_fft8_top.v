// ============================================================
// i2s_fft8_top.v  ——  8 路 I2S -> 乒乓缓冲 -> FFT 完整链路（顶层）
//
// 数据流：
//   sd[7:0] (串行) --i2s_rx_8ch(SCK域)--> 8×24bit
//       --i2s_cdc_8ch(跨时钟域)--> 8×16bit
//       --i2s_fft8_axis(乒乓 + 分时复用)--> AXI-Stream 8 帧 --> fft_512
//
// FFT 输出：8 帧频谱，帧序固定为 ch0 -> ch1 -> ... -> ch7
//   （本模块按通道顺序灌 FFT），下游按 m_axis_data_tlast 数帧，
//   即可把每帧频谱对齐到麦克风编号，供后续波束成形使用。
//
// 接口（供测试 / 上层 / 队友对接）：
//   输入  clk / rst_n ：系统时钟域（100MHz）
//   输入  sck / ws / sd[7:0] ：8 路 I2S（SCK 域）
//   输出  m_axis_data_* ：FFT 频谱输出（AXI4-Stream）
// ============================================================
module i2s_fft8_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sck,
    input  wire        ws,
    input  wire [7:0]  sd,

    output wire [63:0] m_axis_data_tdata,
    output wire        m_axis_data_tvalid,
    input  wire        m_axis_data_tready,
    output wire        m_axis_data_tlast,

    output wire        busy,
    output wire        event_tlast_missing,
    output wire        event_data_in_channel_halt,
    output wire        event_data_out_channel_halt,

    // ---- 引出原始采样（供 DAS 时域波束成形用，与 FFT 共用同一采样流）----
    output wire [127:0] sample_data_o,   // 8×16bit，clk 域
    output wire         sample_valid_o   // clk 域 1 拍脉冲（48.828kHz）
);

    // ---- I2S 8 路接收（SCK 域）----
    wire [191:0] i2s_data;
    wire [7:0]   i2s_valid;
    i2s_rx_8ch u_i2s_rx_8ch (
        .sck  (sck),
        .ws   (ws),
        .sd   (sd),
        .data (i2s_data),
        .valid(i2s_valid)
    );

    // ---- 跨时钟域 + 24->16（clk 域）----
    wire [127:0] sample_data;
    wire         sample_valid;
    i2s_cdc_8ch u_cdc (
        .clk         (clk),
        .rst_n       (rst_n),
        .i2s_data    (i2s_data),
        .i2s_valid   (i2s_valid),
        .sample_data (sample_data),
        .sample_valid(sample_valid)
    );

    // 引出原始采样给 DAS 粗测通道（顶层接 das_scan_top）
    assign sample_data_o  = sample_data;
    assign sample_valid_o = sample_valid;

    // ---- 8 路乒乓 + 分时复用 -> AXI4-Stream ----
    wire [31:0] s_axis_tdata;
    wire        s_axis_tvalid;
    wire        s_axis_tready;
    wire        s_axis_tlast;
    i2s_fft8_axis #(
        .NCH       (8),
        .FRAME_LEN (512),
        .DATA_W    (16)
    ) u_packer (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_data  (sample_data),
        .sample_valid (sample_valid),
        .m_axis_tdata (s_axis_tdata),
        .m_axis_tvalid(s_axis_tvalid),
        .m_axis_tready(s_axis_tready),
        .m_axis_tlast (s_axis_tlast),
        .busy         (busy)
    );

    // ---- FFT 配置：上电后握手发一次 FWD_INV=1（正变换）----
    wire [7:0] s_axis_config_tdata = 8'd1;   // bit0 = FWD_INV = 1 正变换
    reg        s_axis_config_tvalid;
    reg        cfg_done;
    wire       s_axis_config_tready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axis_config_tvalid <= 1'b0;
            cfg_done             <= 1'b0;
        end else if (s_axis_config_tvalid && s_axis_config_tready) begin
            s_axis_config_tvalid <= 1'b0;   // 配置被 FFT 收下
            cfg_done             <= 1'b1;
        end else if (!cfg_done) begin
            s_axis_config_tvalid <= 1'b1;   // 一直举着 config 直到握手成功
        end
    end

    // ---- FFT IP 核 ----
    wire event_frame_started;
    wire event_tlast_unexpected;
    wire event_status_channel_halt;

    fft_512 u_fft (
        .aclk                        (clk),
        .s_axis_config_tdata         (s_axis_config_tdata),
        .s_axis_config_tvalid        (s_axis_config_tvalid),
        .s_axis_config_tready        (s_axis_config_tready),
        .s_axis_data_tdata           (s_axis_tdata),
        .s_axis_data_tvalid          (s_axis_tvalid),
        .s_axis_data_tready          (s_axis_tready),
        .s_axis_data_tlast           (s_axis_tlast),
        .m_axis_data_tdata           (m_axis_data_tdata),
        .m_axis_data_tvalid          (m_axis_data_tvalid),
        .m_axis_data_tready          (m_axis_data_tready),
        .m_axis_data_tlast           (m_axis_data_tlast),
        .event_frame_started         (event_frame_started),
        .event_tlast_unexpected      (event_tlast_unexpected),
        .event_tlast_missing         (event_tlast_missing),
        .event_status_channel_halt   (event_status_channel_halt),
        .event_data_in_channel_halt  (event_data_in_channel_halt),
        .event_data_out_channel_halt (event_data_out_channel_halt)
    );

endmodule
