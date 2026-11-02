`timescale 1ns / 1ps
// ============================================================
// bf_music_tb.v  ——  MUSIC 波束成形：算法验证（纯 testbench，无 RTL）
//
// MUSIC 要点：
//   1. 协方差矩阵 R（8×8）特征分解，特征值从大到小排；
//   2. 前 L 个大特征值对应的特征向量张成"信号子空间"，
//      其余 8-L 个张成"噪声子空间" E_n；
//   3. 谱  P_MUSIC(θ) = 1 / ( a^H(θ) · E_n·E_n^H · a(θ) )
//      = 1 / ( M - Σ_{l=1..L} |a^H(θ)·v_l|² )
//   4. 在真实声源方向，a(θ) 与噪声子空间正交 → 分母→0 → 谱趋向无穷尖峰。
//
// 特征分解：用"幂迭代"找主特征向量（本 testbench 只做 L=1、L=2），
//           两个声源时用"收缩法"(deflation)：找 v1 后从 R 里扣掉 λ1·v1·v1^H，
//           再幂迭代找 v2。
//
// 两个 case：
//   case1 单声源 30°（L=1）：MUSIC 峰值=30°，且比 DAS/MVDR 尖得多
//   case2 双声源 30°+40°（L=2）：DAS 糊成一个包，MUSIC 分成两个尖峰
// 并把空间谱导出 CSV，供 plot_spectrum.py 画图。
// ============================================================
module bf_music_tb;

    real    pi     = 3.14159265358979323846;
    integer NCH    = 8;
    real    c      = 343.0;
    real    R      = 0.05;
    real    f0     = 43.0 * 48000.0 / 512.0;   // bin 43 = 4031.25 Hz
    real    sigma2 = 0.01;                     // 噪声功率（SNR = 20 dB）

    real alpha [0:7];

    // 导向向量 a(θ) / 声源导向向量
    real a_re [0:7], a_im [0:7];
    real src_re [0:7], src_im [0:7];          // 当前声源（case2 用 src1+src2 的和）
    real src1_re [0:7], src1_im [0:7], src2_re [0:7], src2_im [0:7];

    // 协方差矩阵 R（8×8 复数）
    real M_re [0:7][0:7], M_im [0:7][0:7];

    // 幂迭代的工作向量 / 临时向量
    real v_re [0:7], v_im [0:7];
    real w_re [0:7], w_im [0:7];

    // 信号子空间基（最多存 2 个特征向量）
    real sv_re [0:1][0:7], sv_im [0:1][0:7];

    // 空间谱
    real P_das [0:180], P_mus [0:180];

    real det1, det2;      // 检测到的 MUSIC 峰角度
    integer i, j, a, fp, ok;

    // ---- 算导向向量 a(θ) = [e^{-j·2πf0·τ_i(θ)}] ----
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

    // ---- 幂迭代：求 M（模块级）的主特征向量 -> v ----
    task pow_iter;
        integer it, ii, jj;
        real norm, tr, ti;
        begin
            for (ii = 0; ii < 8; ii = ii + 1) begin
                v_re[ii] = (ii == 0) ? 1.0 : 0.0;
                v_im[ii] = 0.0;
            end
            for (it = 0; it < 80; it = it + 1) begin
                // w = M v
                for (ii = 0; ii < 8; ii = ii + 1) begin
                    w_re[ii] = 0.0; w_im[ii] = 0.0;
                    for (jj = 0; jj < 8; jj = jj + 1) begin
                        tr = M_re[ii][jj]*v_re[jj] - M_im[ii][jj]*v_im[jj];
                        ti = M_re[ii][jj]*v_im[jj] + M_im[ii][jj]*v_re[jj];
                        w_re[ii] = w_re[ii] + tr;
                        w_im[ii] = w_im[ii] + ti;
                    end
                end
                norm = 0.0;
                for (ii = 0; ii < 8; ii = ii + 1)
                    norm = norm + w_re[ii]*w_re[ii] + w_im[ii]*w_im[ii];
                norm = $sqrt(norm);
                for (ii = 0; ii < 8; ii = ii + 1) begin
                    v_re[ii] = w_re[ii] / norm;
                    v_im[ii] = w_im[ii] / norm;
                end
            end
        end
    endtask

    // ---- 收缩法：从 M 里扣掉 λ·v·v^H（v 是当前主特征向量）----
    task deflate;
        real lam, tr, ti;
        integer ii, jj;
        begin
            for (ii = 0; ii < 8; ii = ii + 1) begin
                w_re[ii] = 0.0; w_im[ii] = 0.0;
                for (jj = 0; jj < 8; jj = jj + 1) begin
                    tr = M_re[ii][jj]*v_re[jj] - M_im[ii][jj]*v_im[jj];
                    ti = M_re[ii][jj]*v_im[jj] + M_im[ii][jj]*v_re[jj];
                    w_re[ii] = w_re[ii] + tr;
                    w_im[ii] = w_im[ii] + ti;
                end
            end
            lam = 0.0;   // λ = v^H (M v)（Rayleigh 商，应为实数）
            for (ii = 0; ii < 8; ii = ii + 1)
                lam = lam + v_re[ii]*w_re[ii] + v_im[ii]*w_im[ii];
            for (ii = 0; ii < 8; ii = ii + 1)
                for (jj = 0; jj < 8; jj = jj + 1) begin
                    M_re[ii][jj] = M_re[ii][jj] - lam*(v_re[ii]*v_re[jj] + v_im[ii]*v_im[jj]);
                    M_im[ii][jj] = M_im[ii][jj] - lam*(v_im[ii]*v_re[jj] - v_re[ii]*v_im[jj]);
                end
        end
    endtask

    // ---- DAS 功率：|a^H(θ)·src|² ----
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

    // ---- MUSIC 谱：1/(M - Σ_l |a^H·v_l|²) ----
    task music_pow;
        input  real th_deg;
        input  integer L;
        output real pw;
        real denom, s_re, s_im;
        integer ii, l;
        begin
            steer(th_deg);
            denom = 1.0 * NCH;
            for (l = 0; l < L; l = l + 1) begin
                s_re = 0.0; s_im = 0.0;
                for (ii = 0; ii < 8; ii = ii + 1) begin
                    s_re = s_re + a_re[ii]*sv_re[l][ii] + a_im[ii]*sv_im[l][ii];
                    s_im = s_im + a_re[ii]*sv_im[l][ii] - a_im[ii]*sv_re[l][ii];
                end
                denom = denom - (s_re*s_re + s_im*s_im);
            end
            // 极点处分母理论上=0，但浮点舍入可能变成极小负数(-1e-15)。
            // 原来的 +1e-40 太小压不住，导致 pw 变成极大的负值，峰值被跳过一个网格。
            // 把分母钳位到一个小正数，保证谱恒为正、峰落在真实角度上。
            if (denom < 1.0e-9) denom = 1.0e-9;
            pw = 1.0 / denom;
        end
    endtask

    // ---- 扫角度：填谱、导 CSV、找峰 ----
    task run_sweep;
        input integer L, npeaks, fp;
        real th, tdas, tmus, pmax_das, dpeak;
        integer aa, p1, p2, t, best;
        begin
            pmax_das = -1.0; dpeak = -999.0;
            for (aa = 0; aa <= 180; aa = aa + 1) begin
                th = -90.0 + aa;
                das_pow(th, tdas);
                music_pow(th, L, tmus);
                P_das[aa] = tdas;
                P_mus[aa] = tmus;
                if (tdas > pmax_das) begin pmax_das = tdas; dpeak = th; end
                if (fp) $fwrite(fp, "%0d,%.6f,%.6f\n", aa - 90, tdas, tmus);
            end

            $display("  DAS  peak = %0.2f deg", dpeak);

            // MUSIC 全局最大峰
            p1 = 0;
            for (aa = 1; aa <= 180; aa = aa + 1)
                if (P_mus[aa] > P_mus[p1]) p1 = aa;
            det1 = -90.0 + p1;

            if (npeaks >= 2) begin
                // 第二峰：排除 p1 附近 ±8°
                best = -1;
                for (aa = 0; aa <= 180; aa = aa + 1) begin
                    if (aa < p1 - 8 || aa > p1 + 8) begin
                        if (best < 0 || P_mus[aa] > P_mus[best]) best = aa;
                    end
                end
                p2 = best;
                if (p1 > p2) begin t = p1; p1 = p2; p2 = t; end
                det1 = -90.0 + p1;
                det2 = -90.0 + p2;
                $display("  MUSIC peaks = %0.2f and %0.2f deg", det1, det2);
            end else begin
                det2 = -999.0;
                $display("  MUSIC peak = %0.2f deg", det1);
            end
        end
    endtask

    // ---- 检查 ----
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

    // ---- 主流程 ----
    initial begin
        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;
        ok = 1;

        $display("==============================================");
        $display("MUSIC beamformer: algorithm check");
        $display("array = UCA 8 mics, R=0.05 m, c=343 m/s, f0=4031 Hz");
        $display("==============================================");

        // ============ case1：单声源 30°，L=1 ============
        $display("case1: single source at 30 deg");
        steer(30.0);
        for (i = 0; i < 8; i = i + 1) begin src_re[i] = a_re[i]; src_im[i] = a_im[i]; end
        // R = src src^H + σ² I
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                M_re[i][j] = src_re[i]*src_re[j] + src_im[i]*src_im[j];
                M_im[i][j] = src_im[i]*src_re[j] - src_re[i]*src_im[j];
                if (i == j) M_re[i][j] = M_re[i][j] + sigma2;
            end
        pow_iter;
        for (i = 0; i < 8; i = i + 1) begin sv_re[0][i] = v_re[i]; sv_im[0][i] = v_im[i]; end

        fp = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/sim/music_spectrum_1src.csv", "w");
        if (fp) $fwrite(fp, "angle,das,music\n");
        run_sweep(1, 1, fp);
        if (fp) $fclose(fp);
        check_deg(30.0, det1);
        $display("");

        // ============ case2：双声源 30°+40°，L=2 ============
        $display("case2: two sources at 30 deg and 40 deg");
        steer(30.0);
        for (i = 0; i < 8; i = i + 1) begin src1_re[i] = a_re[i]; src1_im[i] = a_im[i]; end
        steer(40.0);
        for (i = 0; i < 8; i = i + 1) begin src2_re[i] = a_re[i]; src2_im[i] = a_im[i]; end
        // DAS 用的合成声源 = src1 + src2
        for (i = 0; i < 8; i = i + 1) begin
            src_re[i] = src1_re[i] + src2_re[i];
            src_im[i] = src1_im[i] + src2_im[i];
        end
        // R = src1 src1^H + src2 src2^H + σ² I
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                M_re[i][j] = src1_re[i]*src1_re[j] + src1_im[i]*src1_im[j]
                           + src2_re[i]*src2_re[j] + src2_im[i]*src2_im[j];
                M_im[i][j] = src1_im[i]*src1_re[j] - src1_re[i]*src1_im[j]
                           + src2_im[i]*src2_re[j] - src2_re[i]*src2_im[j];
                if (i == j) M_re[i][j] = M_re[i][j] + sigma2;
            end
        // 找两个信号特征向量：幂迭代 + 收缩 + 再幂迭代
        pow_iter;
        for (i = 0; i < 8; i = i + 1) begin sv_re[0][i] = v_re[i]; sv_im[0][i] = v_im[i]; end
        deflate;
        pow_iter;
        for (i = 0; i < 8; i = i + 1) begin sv_re[1][i] = v_re[i]; sv_im[1][i] = v_im[i]; end

        fp = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/sim/music_spectrum_2src.csv", "w");
        if (fp) $fwrite(fp, "angle,das,music\n");
        run_sweep(2, 2, fp);
        if (fp) $fclose(fp);
        check_deg(30.0, det1);
        check_deg(40.0, det2);
        $display("");

        $display("==============================================");
        if (ok)
            $display("RESULT: PASS  (MUSIC peak(s) at source angle(s))");
        else
            $display("RESULT: FAIL  (MUSIC peak misplaced)");
        $display("==============================================");

        $finish;
    end

endmodule
