`timescale 1ns / 1ps
// ============================================================
// bf_mvdr_tb.v  ——  MVDR（Capon）波束成形：算法验证（纯 testbench，无 RTL）
//
// 目的：写 RTL 前，先用 Verilog 浮点验证 MVDR 公式 + 阵列几何 + 求逆，
//       并和 delay-and-sum 对比，确认"波束确实更窄"。
//
// MVDR 要点（窄带，单个目标频率 bin）：
//   导向向量  a(θ)  = [e^{-j·2πf0·τ_i(θ)}]，τ_i=(R/c)·cos(θ-α_i)
//   协方差阵  R     = a(θ_src)·a^H(θ_src) + σ²·I   （声源 + 白噪声）
//   空间谱    P(θ)  = 1 / ( a^H(θ)·R⁻¹·a(θ) )
//   峰值落在 θ_src，且因为 R⁻¹ 把噪声"白化"了，旁瓣被压得很低。
//
// 求逆：8×8 复数高斯-约当消元（带主元选取）。
// 几何：UCA 8 麦、R=5cm、c=343；f0 = bin 43 = 4031.25 Hz（同 3b）。
// ============================================================
module bf_mvdr_tb;

    real    pi     = 3.14159265358979323846;
    integer NCH    = 8;
    real    c      = 343.0;
    real    R      = 0.05;
    real    f0     = 43.0 * 48000.0 / 512.0;   // bin 43 = 4031.25 Hz
    real    sigma2 = 0.01;                     // 噪声功率（SNR = 20 dB）

    real alpha [0:7];              // 麦克风方位角（弧度）

    real a_re [0:7], a_im [0:7];   // 导向向量 a(θ)
    real src_re [0:7], src_im [0:7];   // 声源方向的导向向量 a(θ_src)
    real q_re [0:7], q_im [0:7];   // 临时 q = R⁻¹·a

    // 协方差矩阵 R、它的逆 R⁻¹、消元用的增广矩阵 [R | I]
    real M_re [0:7][0:7], M_im [0:7][0:7];
    real Minv_re [0:7][0:7], Minv_im [0:7][0:7];
    real B_re [0:7][0:15], B_im [0:7][0:15];

    integer i, j, a, fp;

    // ---- 算导向向量 a(θ)（物理约定 e^{-j·2πf0·τ_i(θ)}）----
    task steer;
        input real th_deg;
        real th, tau, ph;
        integer ii;
        begin
            th = th_deg * pi / 180.0;
            for (ii = 0; ii < NCH; ii = ii + 1) begin
                tau      = (R / c) * $cos(th - alpha[ii]);
                ph       = 2.0 * pi * f0 * tau;
                a_re[ii] =  $cos(ph);
                a_im[ii] = -$sin(ph);
            end
        end
    endtask

    // ---- 8×8 复数高斯-约当求逆：M -> Minv（M 会被破坏）----
    task inv8;
        integer i2, j2, col, piv;
        real mag, maxmag, d_re, d_im, denom, f_re, f_im;
        real t_re, t_im, tmp_re, tmp_im;
        begin
            // 1) 增广 [M | I]
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    B_re[i2][j2] = M_re[i2][j2];
                    B_im[i2][j2] = M_im[i2][j2];
                end
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    B_re[i2][8+j2] = (i2 == j2) ? 1.0 : 0.0;
                    B_im[i2][8+j2] = 0.0;
                end

            // 2) 前向消元（带主元选取）
            for (col = 0; col < 8; col = col + 1) begin
                piv = col;
                maxmag = B_re[col][col]*B_re[col][col] + B_im[col][col]*B_im[col][col];
                for (i2 = col+1; i2 < 8; i2 = i2 + 1) begin
                    mag = B_re[i2][col]*B_re[i2][col] + B_im[i2][col]*B_im[i2][col];
                    if (mag > maxmag) begin maxmag = mag; piv = i2; end
                end
                if (piv != col)
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        tmp_re = B_re[col][j2]; tmp_im = B_im[col][j2];
                        B_re[col][j2] = B_re[piv][j2]; B_im[col][j2] = B_im[piv][j2];
                        B_re[piv][j2] = tmp_re;       B_im[piv][j2] = tmp_im;
                    end
                // 主元行归一（除以 B[col][col]）
                d_re  = B_re[col][col]; d_im  = B_im[col][col];
                denom = d_re*d_re + d_im*d_im;
                for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                    t_re = B_re[col][j2]; t_im = B_im[col][j2];
                    B_re[col][j2] = (t_re*d_re + t_im*d_im) / denom;
                    B_im[col][j2] = (t_im*d_re - t_re*d_im) / denom;
                end
                // 消掉本列下方
                for (i2 = col+1; i2 < 8; i2 = i2 + 1) begin
                    f_re = B_re[i2][col]; f_im = B_im[i2][col];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[col][j2] - f_im*B_im[col][j2];
                        t_im = f_re*B_im[col][j2] + f_im*B_re[col][j2];
                        B_re[i2][j2] = B_re[i2][j2] - t_re;
                        B_im[i2][j2] = B_im[i2][j2] - t_im;
                    end
                end
            end

            // 3) 回代消元（消掉本列上方）
            for (col = 7; col >= 0; col = col - 1)
                for (i2 = 0; i2 < col; i2 = i2 + 1) begin
                    f_re = B_re[i2][col]; f_im = B_im[i2][col];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[col][j2] - f_im*B_im[col][j2];
                        t_im = f_re*B_im[col][j2] + f_im*B_re[col][j2];
                        B_re[i2][j2] = B_re[i2][j2] - t_re;
                        B_im[i2][j2] = B_im[i2][j2] - t_im;
                    end
                end

            // 4) 取出逆矩阵（右半块）
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    Minv_re[i2][j2] = B_re[i2][8+j2];
                    Minv_im[i2][j2] = B_im[i2][8+j2];
                end
        end
    endtask

    // ---- MVDR 功率：P(θ) = 1 / (a^H·R⁻¹·a) ----
    task mvdr_pow;
        input  real th_deg;
        output real pw;
        real s_re, s_im;
        integer ii, jj;
        begin
            steer(th_deg);
            // q = R⁻¹ · a
            for (ii = 0; ii < 8; ii = ii + 1) begin
                q_re[ii] = 0.0; q_im[ii] = 0.0;
                for (jj = 0; jj < 8; jj = jj + 1) begin
                    q_re[ii] = q_re[ii] + Minv_re[ii][jj]*a_re[jj] - Minv_im[ii][jj]*a_im[jj];
                    q_im[ii] = q_im[ii] + Minv_re[ii][jj]*a_im[jj] + Minv_im[ii][jj]*a_re[jj];
                end
            end
            // s = a^H · q（实部即功率分母，虚部理论为 0）
            s_re = 0.0;
            for (ii = 0; ii < 8; ii = ii + 1)
                s_re = s_re + a_re[ii]*q_re[ii] + a_im[ii]*q_im[ii];
            pw = 1.0 / s_re;
        end
    endtask

    // ---- DAS 功率：P(θ) = |a^H(θ)·a(θ_src)|²（用来对比波束宽度）----
    task das_pow;
        input  real th_deg;
        output real pw;
        real s_re, s_im;
        integer ii;
        begin
            steer(th_deg);
            s_re = 0.0; s_im = 0.0;
            for (ii = 0; ii < 8; ii = ii + 1) begin
                s_re = s_re + a_re[ii]*src_re[ii] + a_im[ii]*src_im[ii];
                s_im = s_im + a_re[ii]*src_im[ii] - a_im[ii]*src_re[ii];
            end
            pw = s_re*s_re + s_im*s_im;
        end
    endtask

    // ---- 测一个声源角度：算 R、求逆、扫角、找峰 ----
    integer show_table = 1;
    task run_case;
        input  real thsrc_deg;
        output real das_peak_deg, mvdr_peak_deg;
        output real das_pk, mvdr_pk;
        real th, tdas, tmvdr;
        integer aa;
        begin
            // 声源导向向量 src = a(θ_src)
            steer(thsrc_deg);
            for (i = 0; i < 8; i = i + 1) begin
                src_re[i] = a_re[i]; src_im[i] = a_im[i];
            end

            // R = src·src^H + σ²·I
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    M_re[i][j] = src_re[i]*src_re[j] + src_im[i]*src_im[j];
                    M_im[i][j] = src_im[i]*src_re[j] - src_re[i]*src_im[j];
                    if (i == j) M_re[i][j] = M_re[i][j] + sigma2;
                end

            inv8;

            // 扫 -90..+90，找 DAS 和 MVDR 各自的峰
            das_pk = -1.0; das_peak_deg = -999.0;
            mvdr_pk = -1.0; mvdr_peak_deg = -999.0;
            for (aa = 0; aa <= 180; aa = aa + 1) begin
                th = -90.0 + aa;
                das_pow(th, tdas);
                mvdr_pow(th, tmvdr);
                if (tdas > das_pk) begin das_pk = tdas; das_peak_deg = th; end
                if (tmvdr > mvdr_pk) begin mvdr_pk = tmvdr; mvdr_peak_deg = th; end
                if (show_table == 1)
                    $fwrite(fp, "%0d,%.6f,%.6f\n", aa - 90, tdas, tmvdr);
            end

            $display("source %0.0f deg:", thsrc_deg);
            $display("  DAS  peak = %0.2f deg (power %0.2f)", das_peak_deg, das_pk);
            $display("  MVDR peak = %0.2f deg (power %0.2f)", mvdr_peak_deg, mvdr_pk);

            // 只给第一个 case 画一张归一化对比表（波束宽度对比）
            if (show_table == 1) begin
                show_table = 0;
                $display("");
                $display("beamwidth comparison @ %0.0f deg (normalized to peak):", thsrc_deg);
                $display("  angle   DAS      MVDR");
                for (aa = 0; aa <= 180; aa = aa + 10) begin
                    th = -90.0 + aa;
                    das_pow(th, tdas);
                    mvdr_pow(th, tmvdr);
                    $display("  %4.0f   %.3f   %.3f", th, tdas/das_pk, tmvdr/mvdr_pk);
                end
            end
        end
    endtask

    // ---- 主流程 ----
    real d_deg, m_deg, d_pk, m_pk;
    integer ok = 1;

    task check_deg;
        input real expected, got;
        real err;
        begin
            err = got - expected;
            if (err < 0.0) err = -err;
            if (err > 1.0) begin
                $display("     *** MISMATCH (expected %0.0f, got %0.1f)", expected, got);
                ok = 0;
            end
        end
    endtask

    initial begin
        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        $display("==============================================");
        $display("MVDR beamformer: algorithm check");
        $display("array = UCA 8 mics, R=0.05 m, c=343 m/s, f0=4031 Hz");
        $display("SNR = 20 dB (noise power 0.01)");
        $display("==============================================");

        // 导出 30° 空间谱到 CSV，供 Python 画图
        fp = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/sim/mvdr_spectrum.csv", "w");
        if (fp) $fwrite(fp, "angle,das,mvdr\n");

        run_case(30.0,  d_deg, m_deg, d_pk, m_pk);
        check_deg(30.0, m_deg);
        if (fp) $fclose(fp);
        $display("");

        run_case(-45.0, d_deg, m_deg, d_pk, m_pk);
        check_deg(-45.0, m_deg);

        $display("==============================================");
        if (ok)
            $display("RESULT: PASS  (MVDR peak at source angle)");
        else
            $display("RESULT: FAIL  (MVDR peak misplaced)");
        $display("==============================================");

        $finish;
    end

endmodule
