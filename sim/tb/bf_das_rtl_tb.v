`timescale 1ns / 1ps
// ============================================================
// bf_das_rtl_tb.v  ——  波束成形 RTL 全链路验证
//
// 把 3a 验证过的 delay-and-sum 算法，塞进真实数据链路里跑一遍：
//   I2S(8根SD) -> i2s_fft8_top(乒乓+FFT) -> bin_extract_8ch(抽bin43)
//       -> bf_das_core(复数加权求和)
// 最后在 testbench 里扫角度、求 |y|^2、找峰值，看是否落在声源角。
//
// 声源：30 度方向、频率 = bin 43 = 43*48000/512 = 4031.25 Hz。
//   麦克风 i 收到的信号比参考点晚 tau_i = (R/c)*cos(th_src - alpha_i)，
//   即相位偏移 2*pi*f0*tau_i。8 路正弦表按此相位错开。
//
// 导向权重（testbench 算，Q1.15）：
//   w_i = e^{-j*2*pi*f0*tau_i(theta)}，tau_i(theta)=(R/c)*cos(theta-alpha_i)
// ============================================================
module bf_das_rtl_tb;

    // ---------------- 系统时钟 100 MHz ----------------
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---------------- I2S（SCK 域）----------------
    reg       sck = 0;
    reg       ws  = 0;
    reg [7:0] sd  = 0;

    // ---------------- 顶层输出（FFT 频谱流）----------------
    wire [63:0] fft_tdata;
    wire        fft_tvalid;
    reg         fft_tready = 1;
    wire        fft_tlast;

    // ---------------- bin_extract 输出（8 路 × 24bit 复数谱）----------------
    wire [191:0] X_re, X_im;
    wire         xready;

    // ---------------- bf_das_core ----------------
    reg  [127:0] W_re, W_im;   // 8 路 × 16bit 权重（testbench 算好送进来）
    wire [47:0]  y_re, y_im;   // 加权和

    // ---------------- 几何参数 ----------------
    real    pi  = 3.14159265358979323846;
    localparam NCH = 8;   // 常量，例化时当参数用
    real    c   = 343.0;
    real    R   = 0.05;
    real    f0  = 43.0 * 48000.0 / 512.0;   // bin 43 = 4031.25 Hz
    real    alpha [0:7];

    // ---------------- 声源 ----------------
    real theta_src_deg = 30.0;
    real theta_src;

    // ---------------- 8 路正弦表（各带不同到达相位）----------------
    reg [15:0] sine_table [0:7][0:511];
    integer ch, n;
    real tau, phase;
    initial begin
        for (ch = 0; ch < NCH; ch = ch + 1)
            alpha[ch] = 2.0 * pi * ch / NCH;
        theta_src = theta_src_deg * pi / 180.0;
        for (ch = 0; ch < NCH; ch = ch + 1) begin
            tau   = (R / c) * $cos(theta_src - alpha[ch]);
            phase = 2.0 * pi * f0 * tau;
            for (n = 0; n < 512; n = n + 1)
                sine_table[ch][n] = $rtoi(4000.0 * $cos(2.0*pi*43.0*n/512.0 + phase));
        end
    end

    // ---------------- 例化：I2S -> 乒乓 -> FFT ----------------
    i2s_fft8_top u_top (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .sck                        (sck),
        .ws                         (ws),
        .sd                         (sd),
        .m_axis_data_tdata          (fft_tdata),
        .m_axis_data_tvalid         (fft_tvalid),
        .m_axis_data_tready         (fft_tready),
        .m_axis_data_tlast          (fft_tlast),
        .busy                       (),
        .event_tlast_missing        (),
        .event_data_in_channel_halt (),
        .event_data_out_channel_halt()
    );

    // ---------------- 例化：抽 bin 43 的 8 路谱 ----------------
    bin_extract_8ch #(.TARGET_BIN(43), .XW(24)) u_ext (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_axis_tdata (fft_tdata),
        .s_axis_tvalid(fft_tvalid),
        .s_axis_tready(fft_tready),
        .s_axis_tlast (fft_tlast),
        .X_re         (X_re),
        .X_im         (X_im),
        .ready        (xready)
    );

    // ---------------- 例化：复数加权求和 ----------------
    bf_das_core #(.NCH(NCH), .XW(24), .WW(16)) u_bf (
        .clk  (clk),
        .rst_n(rst_n),
        .X_re (X_re),
        .X_im (X_im),
        .W_re (W_re),
        .W_im (W_im),
        .y_re (y_re),
        .y_im (y_im)
    );

    // ---------------- I2S 主机：8 根 SD 线同时发 1 个 24bit 样本 ----------------
    localparam T_SCK = 320;
    task send_sample_8ch;
        input [191:0] s;
        integer i, cc;
        begin
            ws = ~ws;
            #(T_SCK/2);
            for (i = 0; i < 32; i = i + 1) begin
                if (i == 0)       sd = 8'd0;
                else if (i <= 24) for (cc = 0; cc < 8; cc = cc + 1)
                                      sd[cc] = s[cc*24 + (24 - i)];
                else              sd = 8'd0;
                #(T_SCK/2); sck = 1'b1;
                #(T_SCK/2); sck = 1'b0;
            end
        end
    endtask

    // ---------------- 算某扫描角度的导向权重（Q1.15）----------------
    task set_weights;
        input real th_deg;
        real th, taw, ph;
        integer i, wr, wi;
        begin
            th = th_deg * pi / 180.0;
            for (i = 0; i < NCH; i = i + 1) begin
                taw = (R / c) * $cos(th - alpha[i]);
                ph  = 2.0 * pi * f0 * taw;
                wr  = $rtoi( $cos(ph) * 32768.0);   // e^{-jφ} 实部
                if (wr >  32767) wr =  32767;
                if (wr < -32768) wr = -32768;
                wi  = $rtoi(-$sin(ph) * 32768.0);   // e^{-jφ} 虚部
                if (wi >  32767) wi =  32767;
                if (wi < -32768) wi = -32768;
                W_re[i*16 +: 16] = wr[15:0];
                W_im[i*16 +: 16] = wi[15:0];
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    integer k, a, err;
    reg [63:0] P [0:180];
    reg signed [63:0] yre_s, yim_s;
    reg [63:0] pow, powmax;
    integer best_deg;
    reg xrdy_seen = 0;

    always @(posedge clk) if (xready) xrdy_seen <= 1'b1;

    initial begin
        // 复位
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);

        $display("==============================================");
        $display("delay-and-sum beamformer: RTL full-chain test");
        $display("source = %0.0f deg, f0 = bin 43 (4031.25 Hz)", theta_src_deg);
        $display("==============================================");

        // ---- 通过 I2S 发 512 组 8 路带相位差的采样 ----
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

        // ---- 等乒乓突发 + FFT 算完 + 抽 bin ----
        repeat (200000) @(posedge clk);

        if (xrdy_seen)
            $display("bin 43 extracted from 8 channels: yes");
        else
            $display("bin 43 extracted from 8 channels: NO (problem!)");

        // ---- 扫角度 -90..+90（1° 步进）----
        powmax   = 0;
        best_deg = 0;
        for (a = 0; a <= 180; a = a + 1) begin
            set_weights(-90.0 + a);   // 更新 W
            @(posedge clk);
            @(posedge clk);           // 等 bf_das_core 寄存输出
            yre_s = $signed(y_re);
            yim_s = $signed(y_im);
            pow   = yre_s * yre_s + yim_s * yim_s;
            P[a]  = pow;
            if (pow > powmax) begin
                powmax   = pow;
                best_deg = a - 90;
            end
        end

        // ---- 打印空间谱（每 10° 一点）----
        $display("");
        $display("spatial spectrum (coarse, every 10 deg):");
        for (a = 0; a <= 180; a = a + 10)
            $display("  %4d deg : %0d", a - 90, P[a]);

        // ---- 判定 ----
        $display("");
        $display("source = %0.0f deg, detected DOA = %0d deg", theta_src_deg, best_deg);
        err = best_deg - $rtoi(theta_src_deg);
        if (err < 0) err = -err;
        if (err <= 2)
            $display("RESULT: PASS  (DOA matches source within 2 deg)");
        else
            $display("RESULT: FAIL  (DOA %0d vs source %0.0f)", best_deg, theta_src_deg);

        $finish;
    end

endmodule
