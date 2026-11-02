`timescale 1ns / 1ps
// ============================================================
// i2s_fft_tb.v  ——  测试 "真实 I2S 串行流 -> 接收器 -> CDC -> 打包器 -> FFT"
//
// 用一个 I2S 主机模型（sck / ws / sd）串行发送 512 个 1500Hz 正弦采样点，
// 走 i2s_fft_top 完整链路（i2s_rx -> i2s_cdc -> i2s_to_fft_axis -> fft_512），
// 期望 FFT 频谱峰值落在 bin 16（1500 Hz）。
//
// 这是第一次把"真实 I2S 协议 + 跨时钟域"和 FFT 打通，重点验证：
//   - I2S 串行位流能否被正确还原成样本
//   - SCK 域 -> clk 域的 CDC 会不会丢点 / 错位
// ============================================================
module i2s_fft_tb;

    // ---------------- 系统时钟 100 MHz ----------------
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;

    // ---------------- I2S 三根线（SCK 时钟域） ----------------
    reg sck = 0;      // 位时钟，周期 ~320ns（约 3.125MHz）
    reg ws  = 0;      // 字选择 L/R
    reg sd  = 0;      // 串行数据

    // ---------------- 顶层输出（FFT 频谱 AXI4-Stream） ----------------
    wire [63:0] m_axis_data_tdata;
    wire        m_axis_data_tvalid;
    reg         m_axis_data_tready = 1;   // 一直准备接收
    wire        m_axis_data_tlast;
    wire        busy;
    wire        event_tlast_missing;
    wire        event_data_in_channel_halt;
    wire        event_data_out_channel_halt;

    // ---------------- 正弦表 512 点（16 个整周期 = 1500Hz） ----------------
    reg [15:0] sine_table [0:511];
    integer    n;
    real       phase;
    initial begin
        for (n = 0; n < 512; n = n + 1) begin
            phase = 2.0 * 3.141592653589793 * 16.0 * n / 512.0;
            sine_table[n] = $rtoi(4000.0 * $sin(phase));   // 幅度 4000
        end
    end

    // ---------------- 例化顶层 ----------------
    i2s_fft_top u_top (
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

    // ---------------- I2S 主机：发一个 24bit 样本 ----------------
    // I2S 时序：WS 翻转后，第 1 个 SCK 是"延迟位"（不收数），
    // 接着 24 位 MSB 先发，再补 8 位，共 32 个 SCK / 声道。
    localparam T_SCK = 320;   // SCK 周期，单位 ns

    task send_sample;
        input [23:0] s;
        integer i;
        begin
            ws = ~ws;                    // 翻转 WS，开始新声道
            #(T_SCK/2);                  // WS 建立时间（在第一个 SCK 沿之前）
            for (i = 0; i < 32; i = i + 1) begin
                if (i == 0)       sd = 1'b0;         // 延迟位
                else if (i <= 24) sd = s[24 - i];    // bit23..bit0，MSB 先发
                else              sd = 1'b0;         // 填充位
                #(T_SCK/2); sck = 1'b1;
                #(T_SCK/2); sck = 1'b0;
            end
        end
    endtask

    // ---------------- 输出监测：找功率最大的 bin ----------------
    integer          out_cnt    = 0;
    reg              frame_done = 0;
    integer          peak_bin   = 0;
    reg [63:0]       peak_power = 0;
    reg signed [63:0] re_s, im_s;
    reg [63:0]       p;

    always @(posedge clk) begin
        if (m_axis_data_tvalid && m_axis_data_tready) begin
            re_s = $signed(m_axis_data_tdata[31:0]);   // real 低 32 位
            im_s = $signed(m_axis_data_tdata[63:32]);  // imag 高 32 位
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
        // 复位
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);

        $display("start sending 512 samples over I2S ...");

        // ---- 通过 I2S 串行发送 512 个采样点 ----
        // 24bit 值 = {16bit 正弦, 8'b0}，CDC 截 data[23:8] 正好得到 16bit 正弦
        for (k = 0; k < 512; k = k + 1)
            send_sample({sine_table[k], 8'b0});

        $display("all 512 samples sent over I2S, waiting for FFT result ...");

        // ---- 等打包器突发 + FFT 算完（100MHz 下远足够） ----
        repeat (100000) @(posedge clk);

        // ---- 打印结果 ----
        $display("==========================================");
        $display("i2s -> CDC -> packer -> FFT test finished");
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
