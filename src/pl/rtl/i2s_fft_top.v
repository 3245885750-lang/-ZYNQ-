// ============================================================
// i2s_fft_top.v  ——  1 路 I2S -> FFT 完整链路（顶层）
//
// 数据流：
//   sd (串行) --i2s_rx(SCK域)--> 24bit --i2s_cdc(跨时钟域)--> 16bit
//             --i2s_to_fft_axis(攒512点突发)--> AXI-Stream --> fft_512
//
// 接口（供测试/上层调用）：
//   输入  clk / rst_n ：系统时钟域（100MHz）
//   输入  sck / ws / sd ：I2S 三根线（SCK 域）
//   输出  m_axis_data_* ：FFT 频谱输出（AXI4-Stream）
//   输出  busy / event_* ：状态，供调试
// ============================================================
module i2s_fft_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sck,
    input  wire        ws,
    input  wire        sd,

    // ---- FFT 频谱输出（AXI4-Stream 从机口）----
    output wire [63:0] m_axis_data_tdata,
    output wire        m_axis_data_tvalid,
    input  wire        m_axis_data_tready,
    output wire        m_axis_data_tlast,

    // ---- 状态 / 调试 ----
    output wire        busy,
    output wire        event_tlast_missing,
    output wire        event_data_in_channel_halt,
    output wire        event_data_out_channel_halt
);

    // ================= I2S 接收（SCK 域）=================
    wire [23:0] i2s_data;
    wire        i2s_valid;
    i2s_rx u_i2s_rx (
        .sck  (sck),
        .ws   (ws),
        .sd   (sd),
        .data (i2s_data),
        .valid(i2s_valid)
    );

    // ================= 跨时钟域 + 24->16（clk 域）=================
    wire [15:0] sample_data;
    wire        sample_valid;
    i2s_cdc u_cdc (
        .clk         (clk),
        .rst_n       (rst_n),
        .i2s_data    (i2s_data),
        .i2s_valid   (i2s_valid),
        .sample_data (sample_data),
        .sample_valid(sample_valid)
    );

    // ================= 打包器：攒 512 点突发（clk 域）=================
    wire [31:0] s_axis_tdata;
    wire        s_axis_tvalid;
    wire        s_axis_tready;
    wire        s_axis_tlast;
    i2s_to_fft_axis u_packer (
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

    // ================= FFT 配置：上电后发一次 FWD_INV=1（正变换）=================
    wire [7:0] s_axis_config_tdata = 8'd1;   // bit0 = FWD_INV = 1 正变换
    reg        s_axis_config_tvalid;
    reg        cfg_done;
    wire       s_axis_config_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axis_config_tvalid <= 1'b0;
            cfg_done             <= 1'b0;
        end else if (s_axis_config_tvalid && s_axis_config_tready) begin
            // 配置被 FFT 收下，撤掉 tvalid
            s_axis_config_tvalid <= 1'b0;
            cfg_done             <= 1'b1;
        end else if (!cfg_done) begin
            // 复位后一直举着 config，直到握手成功
            s_axis_config_tvalid <= 1'b1;
        end
    end

    // ================= FFT IP 核 ==================
    // 事件里帧开始、tlast 异常、status 通道 halt 未引出，先内部悬空
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
