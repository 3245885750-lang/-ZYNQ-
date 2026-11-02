`timescale 1ns / 1ps
// ============================================================
// bf_mvdr_fxp_tb.v —— MVDR 定点精度扫描（纯 testbench，无 RTL）
//
// 背景：Q16.16（16 位小数）整数定点求逆失败（R⁻¹ 非正定，s 变负）。
//   本版改成 "float 运算 + 每次存矩阵时量化到 SCALE 位小数"（fxq 四舍五入），
//   用来扫 FBITS = 24,20,18,16,15,14,12，找出最小够用的小数位数。
//   该位数直接决定 RTL 里矩阵条目位宽 + 乘法器/除法器位宽。
// ============================================================
module bf_mvdr_fxp_tb;

    real    pi     = 3.14159265358979323846;
    integer NCH    = 8;
    real    c      = 343.0;
    real    R      = 0.05;
    real    f0     = 43.0 * 48000.0 / 512.0;   // bin 43 = 4031.25 Hz
    real    sigma2 = 0.01;                     // 噪声功率（SNR = 20 dB）

    real alpha [0:7];

    real a_re [0:7], a_im [0:7];       // 导向向量 a(θ)
    real src_re [0:7], src_im [0:7];   // 声源导向向量
    real M_re [0:7][0:7], M_im [0:7][0:7];    // 协方差 R
    real B_re [0:7][0:15], B_im [0:7][0:15];  // 增广矩阵 [R|I]
    real Minv_re [0:7][0:7], Minv_im [0:7][0:7];
    real q_re [0:7], q_im [0:7];

    integer i, j, fp, fk;

    real SCALE;   // 当前定点 scale = 2^FBITS

    // ---- 量化到 SCALE（=2^FBITS）位小数，四舍五入 ----
    function real fxq;
        input real x;
        begin
            if (x >= 0.0)
                fxq = $floor(x*SCALE + 0.5) / SCALE;
            else
                fxq = $ceil(x*SCALE - 0.5) / SCALE;
        end
    endfunction

    // ---- 绝对值 ----
    function real fabs;
        input real x;
        begin
            fabs = (x >= 0.0) ? x : -x;
        end
    endfunction

    // ---- 导向向量 a(θ)（量化到 SCALE 位）----
    task steer;
        input real th_deg;
        real th, tau, ph;
        integer ii;
        begin
            th = th_deg * pi / 180.0;
            for (ii = 0; ii < NCH; ii = ii + 1) begin
                tau      = (R/c) * $cos(th - alpha[ii]);
                ph       = 2.0 * pi * f0 * tau;
                a_re[ii] = fxq( $cos(ph));
                a_im[ii] = fxq(-$sin(ph));
            end
        end
    endtask

    // ---- 8×8 复数高斯-约当求逆：M -> Minv（每次存矩阵都量化）----
    task inv8;
        integer i2, j2, col, piv;
        real mag, maxmag, d_re, d_im, denom, f_re, f_im;
        real t_re, t_im, tmp_re, tmp_im;
        begin
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
                d_re  = B_re[col][col]; d_im  = B_im[col][col];
                denom = d_re*d_re + d_im*d_im;
                for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                    t_re = B_re[col][j2]; t_im = B_im[col][j2];
                    B_re[col][j2] = fxq((t_re*d_re + t_im*d_im) / denom);
                    B_im[col][j2] = fxq((t_im*d_re - t_re*d_im) / denom);
                end
                for (i2 = col+1; i2 < 8; i2 = i2 + 1) begin
                    f_re = B_re[i2][col]; f_im = B_im[i2][col];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[col][j2] - f_im*B_im[col][j2];
                        t_im = f_re*B_im[col][j2] + f_im*B_re[col][j2];
                        B_re[i2][j2] = fxq(B_re[i2][j2] - t_re);
                        B_im[i2][j2] = fxq(B_im[i2][j2] - t_im);
                    end
                end
            end

            for (col = 7; col >= 0; col = col - 1)
                for (i2 = 0; i2 < col; i2 = i2 + 1) begin
                    f_re = B_re[i2][col]; f_im = B_im[i2][col];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[col][j2] - f_im*B_im[col][j2];
                        t_im = f_re*B_im[col][j2] + f_im*B_re[col][j2];
                        B_re[i2][j2] = fxq(B_re[i2][j2] - t_re);
                        B_im[i2][j2] = fxq(B_im[i2][j2] - t_im);
                    end
                end

            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    Minv_re[i2][j2] = B_re[i2][8+j2];
                    Minv_im[i2][j2] = B_im[i2][8+j2];
                end
        end
    endtask

    // ---- 诊断：R⁻¹·R 应≈I，打印最大偏差 ----
    task inv_check;
        real pr_re, pr_im, err, maxerr;
        integer ii, jj, kk;
        begin
            maxerr = 0.0;
            for (ii = 0; ii < 8; ii = ii + 1)
                for (jj = 0; jj < 8; jj = jj + 1) begin
                    pr_re = 0.0; pr_im = 0.0;
                    for (kk = 0; kk < 8; kk = kk + 1) begin
                        pr_re = pr_re + Minv_re[ii][kk]*M_re[kk][jj] - Minv_im[ii][kk]*M_im[kk][jj];
                        pr_im = pr_im + Minv_re[ii][kk]*M_im[kk][jj] + Minv_im[ii][kk]*M_re[kk][jj];
                    end
                    err = fabs(pr_re - ((ii==jj) ? 1.0 : 0.0)) + fabs(pr_im);
                    if (err > maxerr) maxerr = err;
                end
            $display("    inv: max|R^-1*R - I| = %.5f", maxerr);
        end
    endtask

    // ---- MVDR 分母 s(θ) = a^H R⁻¹ a（实部）----
    task mvdr_s;
        input  real th_deg;
        output real s;
        real s_re;
        integer ii, jj;
        begin
            steer(th_deg);
            for (ii = 0; ii < 8; ii = ii + 1) begin
                q_re[ii] = 0.0; q_im[ii] = 0.0;
                for (jj = 0; jj < 8; jj = jj + 1) begin
                    q_re[ii] = q_re[ii] + Minv_re[ii][jj]*a_re[jj] - Minv_im[ii][jj]*a_im[jj];
                    q_im[ii] = q_im[ii] + Minv_re[ii][jj]*a_im[jj] + Minv_im[ii][jj]*a_re[jj];
                end
                q_re[ii] = fxq(q_re[ii]); q_im[ii] = fxq(q_im[ii]);
            end
            s_re = 0.0;
            for (ii = 0; ii < 8; ii = ii + 1)
                s_re = s_re + a_re[ii]*q_re[ii] + a_im[ii]*q_im[ii];
            s = s_re;
        end
    endtask

    // ---- 一个 case：算 R、求逆、扫角、找 s 最小处 ----
    task run_case;
        input  real thsrc_deg;
        output integer mvdr_peak_deg;
        output real s_peak;
        real s, smin, th;
        integer aa;
        begin
            steer(thsrc_deg);
            for (i = 0; i < 8; i = i + 1) begin
                src_re[i] = a_re[i]; src_im[i] = a_im[i];
            end
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    M_re[i][j] = fxq(src_re[i]*src_re[j] + src_im[i]*src_im[j] + ((i==j) ? sigma2 : 0.0));
                    M_im[i][j] = fxq(src_im[i]*src_re[j] - src_re[i]*src_im[j]);
                end

            inv8;
            inv_check;

            smin = 1.0e30;
            mvdr_peak_deg = -999;
            for (aa = 0; aa <= 180; aa = aa + 1) begin
                th = -90.0 + aa;
                mvdr_s(th, s);
                if (s < smin) begin smin = s; mvdr_peak_deg = aa - 90; end
                if (thsrc_deg == 30.0 && fp)
                    $fwrite(fp, "%0d,%.6f\n", aa - 90, 1.0/s);
            end
            s_peak = smin;

            $display("    src %0.0f deg -> peak %0d deg (min s = %.4f)",
                     thsrc_deg, mvdr_peak_deg, smin);
        end
    endtask

    integer ok = 1;
    integer m_deg;
    real s_pk;

    task check_deg;
        input integer expected, got;
        integer err;
        begin
            err = got - expected;
            if (err < 0) err = -err;
            if (err > 1) begin
                $display("       *** MISMATCH (expected %0d, got %0d)", expected, got);
                ok = 0;
            end
        end
    endtask

    // 扫的点位（FBITS 和对应 scale=2^FBITS）
    integer FB[0:6];
    real    SCALES[0:6];

    initial begin
        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        FB[0]=24; SCALES[0]=16777216.0;
        FB[1]=20; SCALES[1]=1048576.0;
        FB[2]=18; SCALES[2]=262144.0;
        FB[3]=16; SCALES[3]=65536.0;
        FB[4]=15; SCALES[4]=32768.0;
        FB[5]=14; SCALES[5]=16384.0;
        FB[6]=12; SCALES[6]=4096.0;

        $display("==============================================");
        $display("MVDR fixed-point precision sweep");
        $display("array = UCA 8 mics, R=0.05 m, c=343 m/s, f0=4031 Hz");
        $display("SNR = 20 dB (noise power 0.01)");
        $display("==============================================");

        // 只对 FBITS=24 导一份谱（画图用）
        fp = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/sim/mvdr_fxp_spectrum.csv", "w");
        if (fp) $fwrite(fp, "angle,p\n");

        for (fk = 0; fk < 7; fk = fk + 1) begin
            SCALE = SCALES[fk];
            ok = 1;
            $display("---- FBITS = %0d ----", FB[fk]);

            run_case(30.0, m_deg, s_pk);
            check_deg(30, m_deg);
            run_case(-45.0, m_deg, s_pk);
            check_deg(-45, m_deg);

            if (fk == 0 && fp) begin   // 只给 FBITS=24 导 CSV，用完就关
                $fclose(fp);
                fp = 0;
            end

            if (ok)
                $display("  FBITS=%0d : PASS", FB[fk]);
            else
                $display("  FBITS=%0d : FAIL", FB[fk]);
            $display("");
        end
        if (fp) $fclose(fp);

        $display("==============================================");
        $display("sweep done");
        $display("==============================================");

        $finish;
    end

endmodule
