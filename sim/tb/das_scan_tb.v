`timescale 1ns / 1ps
// ============================================================
// das_scan_tb.v —— DAS 分数延时（2 抽头线性插值）核的仿真验证
//
// 验证目标：喂一个单频声源，8 路是同一正弦按"分数采样延时"错开的副本。
//   延时 tau_i = k·i·sinθ（k = d·Fs/c ≈ 2.2777，θ=+17°），
//   第 i 路相位 = -w·tau_i（w = 数字角频率）。
//   分数延时 DAS 应在 +17° 上束功率最大，das_doa 收敛到 +17°（±1°）。
//   （整数延时版会把 0.666·i 四舍五入，峰值偏到别的 5° 网格角；
//     分数版无这种偏置，能精确命中 +17°。）
//
// 采样节奏：真实系统 sample_valid 每 1024 拍来一次（48.828kHz @ 50MHz）。
//   这里每 600 拍来一次（> 扫角 181 拍 + 窗口末 argmax 181 拍 + 顺序清零 181 拍
//   ≈ 544 拍，保证每拍采样都被扫到、窗口边界不丢拍）。
// ============================================================
module das_scan_tb;

    reg clk = 0;
    reg rst_n = 0;
    reg [127:0] sample_data = 128'd0;
    reg sample_valid = 0;
    wire signed [8:0] das_doa;
    wire das_done;
    wire das_sig;

    das_scan_top u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_data  (sample_data),
        .sample_valid (sample_valid),
        .das_doa      (das_doa),
        .das_done     (das_done),
        .das_sig      (das_sig)
    );

    // 50MHz 时钟
    always #10 clk = ~clk;

    // 记录每个窗口输出
    reg signed [8:0] last_doa = 9'sd0;
    reg [7:0] win_cnt = 8'd0;
    always @(posedge clk) begin
        if (das_done) begin
            last_doa <= das_doa;
            win_cnt  <= win_cnt + 8'd1;
            $display("[%0t] 窗口 %0d -> das_doa = %0d, das_sig = %0d",
                     $time, win_cnt, $signed(das_doa), das_sig);
        end
    end

    // ---- 源参数 ----
    real w;            // 数字角频率（8kHz）
    real k;            // d*Fs/c ≈ 2.2777
    real sin_th;       // sin(17°)
    real tau_i, phase; // 分数延时 / 相位
    integer sv;        // 采样值（四舍五入到整数）
    integer n, i;

    localparam integer NSAMP      = 1024 * 3;   // 喂 3 个窗口（第 1 窗口填充缓冲，后 2 个干净）
    localparam integer SAMPLE_GAP = 1024;       // 每样本间隔拍数（真实系统 48.828kHz@50MHz=1024 拍；
                                                //   > 906 = 181×3 扫角流水线 + 363 窗口末 argmax+清零）

    initial begin
        // 源：8kHz 单频，θ=+17°（非 5° 整数倍，充分 exercise 分数延时）
        //   第 i 路采样 = 12000·sin(w·n - w·k·i·sinθ)
        w      = 2.0 * 3.14159265358979 * 8000.0 / 48828.125;
        k      = 0.016 * 48828.125 / 343.0;
        sin_th = $sin(17.0 * 3.14159265358979 / 180.0);

        // 复位
        rst_n = 0;
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(200) @(posedge clk);   // 等复位后的顺序清零（181 拍）走完再喂第一拍采样

        // 喂 3 个窗口的采样
        for (n = 0; n < NSAMP; n = n + 1) begin
            for (i = 0; i < 8; i = i + 1) begin
                tau_i = k * i * sin_th;
                phase = w * tau_i;
                sv = $rtoi(12000.0 * $sin(w * n - phase));
                sample_data[16*i +: 16] = sv[15:0];
            end
            sample_valid = 1;
            @(posedge clk);
            sample_valid = 0;
            repeat(SAMPLE_GAP) @(posedge clk);
        end

        // 收尾检查（最后一个窗口收敛到 +17°，容差 ±1°）
        repeat(50) @(posedge clk);
        if (last_doa >= 16 && last_doa <= 18)
            $display("PASS: DAS 收敛到 +17°（实测 %0d°）", $signed(last_doa));
        else
            $display("FAIL: DAS 收敛 %0d°，期望 ~+17°", $signed(last_doa));
        $finish;
    end

endmodule
