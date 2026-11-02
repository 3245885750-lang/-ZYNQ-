`timescale 1ns / 1ps
// ============================================================
// fft_512_tb.v  --  Xilinx FFT IP (512点) 仿真测试
//
// 目标：喂一个 1500 Hz 的正弦波（512 点里正好 16 个整周期）
//       -> 频谱应该只在 bin 16 出现一个峰。
//
//   采样率      = 48 kHz
//   频率分辨率   = 48000 / 512 = 93.75 Hz/bin
//   bin 16     -> 16 * 93.75 = 1500 Hz
//
// 接口都是 AXI4-Stream（TVALID/TREADY 握手，两者同时为 1 才传输）：
//   输入  s_axis_data  : {imag[15:0], real[15:0]}  我们只喂 real，imag = 0
//   输出  m_axis_data  : {imag[31:0], real[31:0]}  real 在低 32 位
//   配置  s_axis_config: FWD_INV = 1 -> 正变换(FFT)
// ============================================================
module fft_512_tb;

    // ---------------- 时钟 100 MHz ----------------
    reg clk = 0;
    always #5 clk = ~clk;

    // ---------------- config 通道 ----------------
    reg  [7:0] s_axis_config_tdata;
    reg        s_axis_config_tvalid;
    wire       s_axis_config_tready;

    // ---------------- 数据输入通道 ----------------
    reg  [31:0] s_axis_data_tdata;
    reg         s_axis_data_tvalid;
    wire        s_axis_data_tready;
    reg         s_axis_data_tlast;

    // ---------------- 数据输出通道 ----------------
    wire [63:0] m_axis_data_tdata;
    wire        m_axis_data_tvalid;
    reg         m_axis_data_tready;
    wire        m_axis_data_tlast;

    // ---------------- 事件输出 ----------------
    wire event_frame_started;
    wire event_tlast_unexpected;
    wire event_tlast_missing;
    wire event_status_channel_halt;
    wire event_data_in_channel_halt;
    wire event_data_out_channel_halt;

    // ---------------- 正弦表 512 点 ----------------
    reg [15:0] sine_table [0:511];
    integer    n;
    real       phase;
    initial begin
        for (n = 0; n < 512; n = n + 1) begin
            phase = 2.0 * 3.141592653589793 * 16.0 * n / 512.0; // 16 个整周期
            sine_table[n] = $rtoi(4000.0 * $sin(phase));        // 幅度 4000
        end
    end

    // ---------------- 例化 FFT IP ----------------
    fft_512 u_fft (
        .aclk                        (clk),
        .s_axis_config_tdata         (s_axis_config_tdata),
        .s_axis_config_tvalid        (s_axis_config_tvalid),
        .s_axis_config_tready        (s_axis_config_tready),
        .s_axis_data_tdata           (s_axis_data_tdata),
        .s_axis_data_tvalid          (s_axis_data_tvalid),
        .s_axis_data_tready          (s_axis_data_tready),
        .s_axis_data_tlast           (s_axis_data_tlast),
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
    reg [63:0]       bin0_pow, bin15_pow, bin16_pow, bin17_pow;
    reg signed [63:0] re_s, im_s;
    reg [63:0]       p;

    always @(posedge clk) begin
        if (m_axis_data_tvalid && m_axis_data_tready) begin
            re_s = $signed(m_axis_data_tdata[31:0]);   // real  低 32 位
            im_s = $signed(m_axis_data_tdata[63:32]);  // imag  高 32 位
            p    = re_s * re_s + im_s * im_s;          // 功率 = re^2 + im^2
            if (p > peak_power) begin
                peak_power = p;
                peak_bin   = out_cnt;
            end
            if (out_cnt == 0)  bin0_pow  = p;
            if (out_cnt == 15) bin15_pow = p;
            if (out_cnt == 16) bin16_pow = p;
            if (out_cnt == 17) bin17_pow = p;
            out_cnt = out_cnt + 1;
            if (m_axis_data_tlast) frame_done <= 1;
        end
    end

    // ---------------- 主流程 ----------------
    integer send_cnt;
    initial begin
        // 初值
        s_axis_config_tdata = 0;
        s_axis_config_tvalid = 0;
        s_axis_data_tdata   = 0;
        s_axis_data_tvalid  = 0;
        s_axis_data_tlast   = 0;
        m_axis_data_tready  = 1;   // 一直准备接收输出

        #200;   // 等 IP 稳定

        // ---- 发配置：FWD_INV = 1（正变换）----
        s_axis_config_tdata  = 8'd1;
        s_axis_config_tvalid = 1;
        while (!s_axis_config_tready) @(posedge clk);
        @(posedge clk);
        s_axis_config_tvalid = 0;
        @(posedge clk);
        @(posedge clk);

        $display("start sending 512 samples of 1500 Hz sine ...");

        // ---- 发 512 个采样点 ----
        for (send_cnt = 0; send_cnt < 512; send_cnt = send_cnt + 1) begin
            s_axis_data_tdata  = {16'b0, sine_table[send_cnt]}; // imag=0, real=sample
            s_axis_data_tvalid = 1;
            s_axis_data_tlast  = (send_cnt == 511) ? 1'b1 : 1'b0;
            while (!s_axis_data_tready) @(posedge clk);
            @(posedge clk);
        end
        s_axis_data_tvalid = 0;
        s_axis_data_tlast  = 0;

        $display("all 512 samples sent, waiting for FFT result ...");

        // ---- 等输出（20000 个时钟足够，100MHz 下 = 200 us）----
        repeat (20000) @(posedge clk);

        // ---- 打印结果 ----
        $display("==========================================");
        $display("FFT 512 test finished");
        $display("output samples = %0d", out_cnt);
        if (!frame_done)
            $display("WARNING: output tlast not seen");
        $display("peak bin   = %0d  (expect 16 -> 1500 Hz)", peak_bin);
        $display("peak power = %0d", peak_power);
        $display("bin  0 power = %0d", bin0_pow);
        $display("bin 15 power = %0d", bin15_pow);
        $display("bin 16 power = %0d", bin16_pow);
        $display("bin 17 power = %0d", bin17_pow);
        $display("resolution = 48000 / 512 = 93.75 Hz per bin");
        if (peak_bin == 16)
            $display("RESULT: PASS  (peak exactly at bin 16 = 1500 Hz)");
        else
            $display("RESULT: FAIL  (expected bin 16, got bin %0d)", peak_bin);
        $display("==========================================");

        $finish;
    end

endmodule
