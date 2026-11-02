`timescale 1ns / 1ps
// ============================================================
// i2s_to_fft_tb.v  ——  测试 "慢速采样流 -> 打包器 -> FFT" 整条链路
//
// 模拟 I2S 出来的 1500 Hz 正弦采样流（每 600 个时钟来一个点，稀疏），
// 经过 i2s_to_fft_axis 打包成 512 点一帧，突发灌给 fft_512，
// 期望频谱峰值落在 bin 16（1500 Hz）。
// ============================================================
module i2s_to_fft_tb;

    // ---------------- 时钟 100 MHz ----------------
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;

    // ---------------- 采样源（模拟 I2S） ----------------
    reg [15:0] sample_data;
    reg        sample_valid = 0;

    // ---------------- 打包器输出 / FFT 输入 ----------------
    wire [31:0] s_axis_tdata;
    wire        s_axis_tvalid;
    wire        s_axis_tready;
    wire        s_axis_tlast;
    wire        busy;

    // ---------------- FFT config 通道 ----------------
    reg  [7:0] s_axis_config_tdata;
    reg        s_axis_config_tvalid;
    wire       s_axis_config_tready;

    // ---------------- FFT 输出 ----------------
    wire [63:0] m_axis_data_tdata;
    wire        m_axis_data_tvalid;
    reg         m_axis_data_tready = 1;
    wire        m_axis_data_tlast;

    // ---------------- FFT 事件输出 ----------------
    wire event_frame_started;
    wire event_tlast_unexpected;
    wire event_tlast_missing;
    wire event_status_channel_halt;
    wire event_data_in_channel_halt;
    wire event_data_out_channel_halt;

    // ---------------- 正弦表 512 点（16 个整周期 = 1500Hz） ----------------
    reg [15:0] sine_table [0:511];
    integer    n;
    real       phase;
    initial begin
        for (n = 0; n < 512; n = n + 1) begin
            phase = 2.0 * 3.141592653589793 * 16.0 * n / 512.0;
            sine_table[n] = $rtoi(4000.0 * $sin(phase));
        end
    end

    // ---------------- 例化打包器 ----------------
    i2s_to_fft_axis #(
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

    // ---------------- 例化 FFT IP ----------------
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

    // ---------------- 输出监测：找功率最大的 bin ----------------
    integer          out_cnt    = 0;
    reg              frame_done = 0;
    integer          peak_bin   = 0;
    reg [63:0]       peak_power = 0;
    reg signed [63:0] re_s, im_s;
    reg [63:0]       p;

    always @(posedge clk) begin
        if (m_axis_data_tvalid && m_axis_data_tready) begin
            re_s = $signed(m_axis_data_tdata[31:0]);
            im_s = $signed(m_axis_data_tdata[63:32]);
            p    = re_s * re_s + im_s * im_s;
            if (p > peak_power) begin
                peak_power = p;
                peak_bin   = out_cnt;
            end
            out_cnt = out_cnt + 1;
            if (m_axis_data_tlast) frame_done <= 1;
        end
    end

    // ---------------- 主流程 ----------------
    integer k;
    initial begin
        // 初值
        sample_data  = 0;
        s_axis_config_tdata  = 0;
        s_axis_config_tvalid = 0;

        // 复位
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5)  @(posedge clk);

        // ---- 发配置：FWD_INV = 1（正变换）----
        s_axis_config_tdata  = 8'd1;
        s_axis_config_tvalid = 1;
        while (!s_axis_config_tready) @(posedge clk);
        @(posedge clk);
        s_axis_config_tvalid = 0;

        $display("start feeding 512 sparse samples of 1500 Hz sine ...");

        // ---- 模拟 I2S：每 600 个时钟来一个采样点 ----
        for (k = 0; k < 512; k = k + 1) begin
            @(posedge clk);
            sample_data  = sine_table[k];
            sample_valid = 1;
            @(posedge clk);
            sample_valid = 0;
            repeat (600) @(posedge clk);
        end

        $display("all 512 samples fed, packer should burst them to FFT ...");

        // ---- 等打包器突发 + FFT 算完 ----
        repeat (50000) @(posedge clk);

        // ---- 打印结果 ----
        $display("==========================================");
        $display("i2s -> packer -> FFT test finished");
        $display("output samples = %0d", out_cnt);
        if (!frame_done)
            $display("WARNING: output tlast not seen");
        if (event_tlast_missing)
            $display("WARNING: FFT event_tlast_missing = 1");
        if (event_data_in_channel_halt)
            $display("WARNING: FFT data_in_channel_halt = 1");
        $display("peak bin   = %0d  (expect 16 -> 1500 Hz)", peak_bin);
        $display("peak power = %0d", peak_power);
        $display("resolution = 48000 / 512 = 93.75 Hz per bin");
        if (peak_bin == 16)
            $display("RESULT: PASS  (peak exactly at bin 16 = 1500 Hz)");
        else
            $display("RESULT: FAIL  (expected bin 16, got bin %0d)", peak_bin);
        $display("==========================================");

        $finish;
    end

endmodule
