`timescale 1ns / 1ps
// ============================================================
// bf_das_tb.v  ——  delay-and-sum 波束成形：算法验证（纯 testbench，无 RTL）
//
// 目的：在写硬件前，先用 Verilog 浮点运算验证"延时求和"公式和
//       阵列几何对不对，避免一上来就写 RTL 结果调半天找不到错。
//
// 做法：
//   1. 假设一个远场声源在 θ_src 方向、频率 f0；
//   2. 声波到达 8 个麦克风有时延差 τ_i = (R/c)·cos(θ_src − α_i)，
//      等价于每路频谱乘相位 e^{j·2πf0·τ_i}，造出 8 路"复数谱"；
//   3. 扫描 θ，用导向向量 w_i = e^{−j·2πf0·τ_i(θ)} 加权求和；
//   4. 看功率峰值是否落在 θ_src。
//
// 几何：均匀圆阵（UCA），8 麦克风等角距 α_i = 45°×i，半径 R = 5 cm。
// ============================================================
module bf_das_tb;

    real    pi  = 3.14159265358979323846;
    integer NCH = 8;
    real    c   = 343.0;    // 声速 m/s
    real    R   = 0.05;     // 阵列半径 m

    real alpha [0:7];              // 麦克风方位角（弧度）
    real X_re [0:7], X_im [0:7];   // 声源在各麦克风的复数谱
    real P [0:180];                // 空间谱（-90..+90，1° 步进）

    integer i;
    integer ok = 1;   // 所有 case 都匹配则为 1

    // ---- 扫一遍空间谱，返回峰值角度和功率 ----
    task sweep;
        input  real f, thsrc_deg;
        output real th_peak, pmax;
        real thsrc, tau, phase, th_deg, th, w_re, w_im, y_re, y_im, pw;
        integer a;
        begin
            thsrc = thsrc_deg * pi / 180.0;
            // 1) 造 8 路复数谱：X_i = e^{j·2πf·τ_i(θ_src)}
            for (i = 0; i < NCH; i = i + 1) begin
                tau    = (R / c) * $cos(thsrc - alpha[i]);
                phase  = 2.0 * pi * f * tau;
                X_re[i] = $cos(phase);
                X_im[i] = $sin(phase);
            end
            // 2) 扫 θ 求功率 P(θ) = |Σ X_i·w_i|²
            pmax    = -1.0;
            th_peak = -999.0;
            for (a = 0; a <= 180; a = a + 1) begin
                th_deg = -90.0 + a;
                th     = th_deg * pi / 180.0;
                y_re = 0.0; y_im = 0.0;
                for (i = 0; i < NCH; i = i + 1) begin
                    tau   = (R / c) * $cos(th - alpha[i]);
                    phase = 2.0 * pi * f * tau;
                    w_re  = $cos(phase);     // e^{-jφ} 实部
                    w_im  = -$sin(phase);    // e^{-jφ} 虚部
                    // 复数乘法 X_i * w_i，累加
                    y_re = y_re + X_re[i]*w_re - X_im[i]*w_im;
                    y_im = y_im + X_re[i]*w_im + X_im[i]*w_re;
                end
                pw = y_re*y_re + y_im*y_im;
                P[a] = pw;
                if (pw > pmax) begin
                    pmax    = pw;
                    th_peak = th_deg;
                end
            end
        end
    endtask

    // ---- 检查峰值是否等于声源角度 ----
    task check;
        input real expected, got;
        real err;
        begin
            err = got - expected;
            if (err < 0.0) err = -err;
            if (err > 0.5) begin
                $display("     *** MISMATCH (expected %0.1f, got %0.1f)", expected, got);
                ok = 0;
            end
        end
    endtask

    real pk_deg, pk_pow;

    initial begin
        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        $display("==============================================");
        $display("delay-and-sum beamformer: algorithm check");
        $display("array = UCA 8 mics, R=0.05 m, c=343 m/s");
        $display("==============================================");

        // ---- 1500 Hz（= bin 16，和前面 FFT 测试一致）----
        $display("f0 = 1500 Hz (bin 16):");
        sweep(1500.0, 30.0, pk_deg, pk_pow);
        $display("  source %0.1f deg -> peak %0.1f deg (power %0.1f)", 30.0, pk_deg, pk_pow);
        check(30.0, pk_deg);

        sweep(1500.0, 0.0, pk_deg, pk_pow);
        $display("  source %0.1f deg -> peak %0.1f deg (power %0.1f)", 0.0, pk_deg, pk_pow);
        check(0.0, pk_deg);

        sweep(1500.0, -45.0, pk_deg, pk_pow);
        $display("  source %0.1f deg -> peak %0.1f deg (power %0.1f)", -45.0, pk_deg, pk_pow);
        check(-45.0, pk_deg);

        // ---- 画一张 1500Hz / 30° 的空间谱（每 10° 一个点）----
        sweep(1500.0, 30.0, pk_deg, pk_pow);
        $display("");
        $display("spatial spectrum (source +30 deg, f0=1500 Hz):");
        for (i = 0; i <= 180; i = i + 10)
            $display("  %4.0f deg : %0.0f", -90.0 + i, P[i]);

        // ---- 4000 Hz：频率越高，波束越窄（峰值更尖）----
        $display("");
        $display("f0 = 4000 Hz (higher freq -> sharper peak):");
        sweep(4000.0, 30.0, pk_deg, pk_pow);
        $display("  source %0.1f deg -> peak %0.1f deg (power %0.1f)", 30.0, pk_deg, pk_pow);
        check(30.0, pk_deg);

        $display("==============================================");
        if (ok)
            $display("RESULT: PASS  (peak always equals source angle)");
        else
            $display("RESULT: FAIL  (some case peak misplaced)");
        $display("==============================================");

        $finish;
    end

endmodule
