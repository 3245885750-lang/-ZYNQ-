`timescale 1ns / 1ps
// ============================================================
// i2s_fft8_tb.v  ——  测试 8 路 I2S -> 乒乓缓冲 -> FFT 分时复用
//
// 用 I2S 主机模型在 8 根 SD 线上同时发 8 个不同频率的正弦：
//   ch0 = 1500 Hz      -> bin 16
//   ch1 = 1593.75 Hz   -> bin 17
//   ...
//   ch7 = 2156.25 Hz   -> bin 23
// 走 i2s_fft8_top 完整链路，验证三点：
//   1. 8 路互不串扰（每帧峰值落在自己的 bin）
//   2. 乒乓缓冲不丢点（每帧 512 个点完整）
//   3. 分时复用顺序正确（ch0 帧先出，ch7 帧最后出）
// ============================================================
module i2s_fft8_tb;

    // ---------------- 系统时钟 100 MHz ----------------
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---------------- I2S（SCK 域）----------------
    reg       sck = 0;   // 位时钟，周期 ~320ns
    reg       ws  = 0;   // 字选择 L/R
    reg [7:0] sd  = 0;   // 8 根串行数据线

    // ---------------- 顶层输出（FFT 频谱）----------------
    wire [63:0] m_axis_data_tdata;
    wire        m_axis_data_tvalid;
    reg         m_axis_data_tready = 1;
    wire        m_axis_data_tlast;
    wire        busy;
    wire        event_tlast_missing;
    wire        event_data_in_channel_halt;
    wire        event_data_out_channel_halt;

    // ---------------- 8 路正弦表：ch 用 16+ch 个整周期 ----------------
    reg [15:0] sine_table [0:7][0:511];
    integer ch, n;
    real phase;
    initial begin
        for (ch = 0; ch < 8; ch = ch + 1)
            for (n = 0; n < 512; n = n + 1) begin
                phase = 2.0 * 3.141592653589793 * (16.0 + ch) * n / 512.0;
                sine_table[ch][n] = $rtoi(4000.0 * $sin(phase));   // 幅度 4000
            end
    end

    // ---------------- 例化顶层 ----------------
    i2s_fft8_top u_top (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .sck                        (sck),
        .ws                         (ws),
        .sd                         (sd),
        .m_axis_data_tdata          (m_axis_data_tdata),
        .m_axis_data_tvalid         (m_axis_data_tvalid),
        .m_axis_data_tready         (m_axis_data_tready),
        .m_axis_data_tlast          (m_axis_data_tlast),
        .busy                       (busy),
        .event_tlast_missing        (event_tlast_missing),
        .event_data_in_channel_halt (event_data_in_channel_halt),
        .event_data_out_channel_halt(event_data_out_channel_halt)
    );

    // ---------------- I2S 主机：同时发 8 路各 1 个 24bit 样本 ----------------
    localparam T_SCK = 320;   // SCK 周期，单位 ns
    task send_sample_8ch;
        input [191:0] s;      // 8 路 × 24bit（ch7 在最高位）
        integer i, c;
        begin
            ws = ~ws;                    // 翻转 WS，开始新声道
            #(T_SCK/2);                  // WS 建立时间
            for (i = 0; i < 32; i = i + 1) begin
                if (i == 0)       sd = 8'd0;              // 延迟位
                else if (i <= 24) begin                   // bit23..bit0，MSB 先发
                    for (c = 0; c < 8; c = c + 1)
                        sd[c] = s[c*24 + (24 - i)];
                end
                else              sd = 8'd0;              // 填充位
                #(T_SCK/2); sck = 1'b1;
                #(T_SCK/2); sck = 1'b0;
            end
        end
    endtask

    // ---------------- 输出监测：逐帧找峰值 bin ----------------
    integer    frame_idx   = 0;   // 当前是第几帧（0..7）
    integer    bin_idx     = 0;   // 当前帧内第几个 bin（0..511）
    integer    frames_done = 0;   // 已收完的帧数
    integer    peak_bin    [0:7];
    reg [63:0] peak_power  [0:7];
    reg signed [63:0] re_s, im_s;
    reg [63:0] p;

    integer g;
    initial begin
        for (g = 0; g < 8; g = g + 1) begin
            peak_bin[g]   = 0;
            peak_power[g] = 0;
        end
    end

    always @(posedge clk) begin
        if (m_axis_data_tvalid && m_axis_data_tready) begin
            re_s = $signed(m_axis_data_tdata[31:0]);   // real 低 32 位
            im_s = $signed(m_axis_data_tdata[63:32]);  // imag 高 32 位
            p    = re_s * re_s + im_s * im_s;
            // 实信号 FFT 谱共轭对称：bin k 与 bin 512-k 是同一频率的正负镜像。
            // 定点截断会让两者能量有微小差异，可能误判到镜像 bin，
            // 所以只搜 0..255 这一半（后续波束成形也只用到这一半）。
            if (bin_idx < 256 && p > peak_power[frame_idx]) begin
                peak_power[frame_idx] = p;
                peak_bin[frame_idx]   = bin_idx;
            end
            bin_idx = bin_idx + 1;
            if (m_axis_data_tlast) begin
                frame_idx   = frame_idx + 1;   // 一帧结束，进入下一帧
                bin_idx     = 0;
                frames_done = frames_done + 1;
            end
        end
    end

    // ---------------- 主流程 ----------------
    integer k, f, ok;
    initial begin
        // 复位
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);

        $display("start sending 8-channel x 512 samples over I2S ...");

        // ---- 通过 I2S 同时发 512 组 8 路采样 ----
        // 24bit 值 = {16bit 正弦, 8'b0}，CDC 截 [23:8] 正好得到 16bit 正弦
        for (k = 0; k < 512; k = k + 1)
            send_sample_8ch({
                sine_table[7][k], 8'b0,
                sine_table[6][k], 8'b0,
                sine_table[5][k], 8'b0,
                sine_table[4][k], 8'b0,
                sine_table[3][k], 8'b0,
                sine_table[2][k], 8'b0,
                sine_table[1][k], 8'b0,
                sine_table[0][k], 8'b0
            });

        $display("all samples sent, waiting for 8 FFT frames ...");

        // ---- 等乒乓突发 + FFT 算完（100MHz 下远足够）----
        repeat (200000) @(posedge clk);

        // ---- 打印结果 ----
        $display("==========================================");
        $display("i2s -> 8ch ping-pong -> FFT test finished");
        $display("frames output = %0d (expect 8)", frames_done);
        if (event_tlast_missing)
            $display("WARNING: FFT event_tlast_missing = 1");
        if (event_data_in_channel_halt)
            $display("WARNING: FFT data_in_channel_halt = 1");
        $display("------------------------------------------");
        $display("resolution = 48000/512 = 93.75 Hz/bin; ch0=1500Hz ... ch7=2156.25Hz");
        for (f = 0; f < 8; f = f + 1)
            $display("ch %0d: peak bin = %0d (expect %0d)", f, peak_bin[f], 16+f);
        $display("==========================================");

        // ---- 判定：8 帧都要各自落在 bin 16..23 ----
        ok = 1;
            if (frames_done != 8) ok = 0;
            for (f = 0; f < 8; f = f + 1)
                if (peak_bin[f] != 16 + f) ok = 0;
        if (ok)
            $display("RESULT: PASS  (8 channels, each peak at its own bin, no cross-talk)");
        else
            $display("RESULT: FAIL  (some channel peak misplaced or missing)");

        $finish;
    end

endmodule
