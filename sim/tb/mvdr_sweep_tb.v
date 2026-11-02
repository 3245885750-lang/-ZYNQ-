`timescale 1ns / 1ps
// ============================================================
// mvdr_sweep_tb.v —— MVDR 扫角验证
//
// 和 4c-2a 的浮点验证用同样的场景：声源 30 度 / -45 度，bin 43，
// R = a*a^H + 0.01*I（SNR 20dB），Q16.16。
//
// 流程：tb 在浮点算好 R^-1（16 位量化）→ 喂给 DUT → DUT 扫 181 个角度，
//   每要一个角度就把 a(theta) 喂进去 → 检查 doa_deg 是否等于声源角度。
//
// ⚠️ 驱动/采样都在【下降沿】。
// ============================================================
module mvdr_sweep_tb;

    localparam integer NANG = 181;

    real pi = 3.14159265358979323846;
    integer NCH = 8;
    real c = 343.0;
    real Rr = 0.05;
    real f0 = 43.0 * 48000.0 / 512.0;
    real sigma2 = 0.01;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    reg start = 0;
    reg din_valid = 0;
    reg signed [31:0] din_re = 0, din_im = 0;
    wire a_req;
    reg avalid = 0;
    reg signed [31:0] av_re = 0, av_im = 0;
    wire signed [31:0] s_out;
    wire s_valid;
    wire signed [8:0] doa_deg;
    wire signed [31:0] s_min;
    wire done;

    mvdr_sweep u_sweep (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din_valid(din_valid), .din_re(din_re), .din_im(din_im),
        .a_req(a_req), .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .s_out(s_out), .s_valid(s_valid),
        .doa_deg(doa_deg), .s_min(s_min), .done(done)
    );

    real alpha [0:7];

    integer rq_re [0:7][0:7], rq_im [0:7][0:7];   // 量化的 R
    integer iq_re [0:7][0:7], iq_im [0:7][0:7];   // 量化的 R^-1

    integer spec [0:NANG-1];
    integer nspec;

    integer i, j, k, ch, aa, guard, nerr, fp;
    real ths, tau, ph;

    // ---- Q16.16 量化（四舍五入）----
    function integer q16;
        input real x;
        begin
            if (x >= 0.0) q16 = $floor(x*65536.0 + 0.5);
            else          q16 = $ceil (x*65536.0 - 0.5);
        end
    endfunction

    // ---- 导向向量 a(theta)（浮点）----
    real ath_re [0:7], ath_im [0:7];
    task steer;
        input real th_deg;
        real th, t2;
        integer ii;
        begin
            th = th_deg * pi / 180.0;
            for (ii = 0; ii < NCH; ii = ii + 1) begin
                t2 = (Rr/c) * $cos(th - alpha[ii]);
                ph = 2.0 * pi * f0 * t2;
                ath_re[ii] = $cos(ph);
                ath_im[ii] = -$sin(ph);
            end
        end
    endtask

    // ---- 浮点高斯-约当求逆（从量化整数矩阵出发）----
    task inv8_ref;
        real B_re [0:7][0:15], B_im [0:7][0:15];
        integer c2, i2, j2, pv;
        real mg, mx, d_re, d_im, den, f_re, f_im, t_re, t_im, tp;
        begin
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    B_re[i2][j2] = rq_re[i2][j2] / 65536.0;
                    B_im[i2][j2] = rq_im[i2][j2] / 65536.0;
                end
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    B_re[i2][8+j2] = (i2 == j2) ? 1.0 : 0.0;
                    B_im[i2][8+j2] = 0.0;
                end
            for (c2 = 0; c2 < 8; c2 = c2 + 1) begin
                pv = c2;
                mx = B_re[c2][c2]*B_re[c2][c2] + B_im[c2][c2]*B_im[c2][c2];
                for (i2 = c2+1; i2 < 8; i2 = i2 + 1) begin
                    mg = B_re[i2][c2]*B_re[i2][c2] + B_im[i2][c2]*B_im[i2][c2];
                    if (mg > mx) begin mx = mg; pv = i2; end
                end
                if (pv != c2)
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        tp = B_re[c2][j2]; B_re[c2][j2] = B_re[pv][j2]; B_re[pv][j2] = tp;
                        tp = B_im[c2][j2]; B_im[c2][j2] = B_im[pv][j2]; B_im[pv][j2] = tp;
                    end
                d_re = B_re[c2][c2]; d_im = B_im[c2][c2];
                den = d_re*d_re + d_im*d_im;
                for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                    t_re = B_re[c2][j2]; t_im = B_im[c2][j2];
                    B_re[c2][j2] = (t_re*d_re + t_im*d_im) / den;
                    B_im[c2][j2] = (t_im*d_re - t_re*d_im) / den;
                end
                for (i2 = c2+1; i2 < 8; i2 = i2 + 1) begin
                    f_re = B_re[i2][c2]; f_im = B_im[i2][c2];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[c2][j2] - f_im*B_im[c2][j2];
                        t_im = f_re*B_im[c2][j2] + f_im*B_re[c2][j2];
                        B_re[i2][j2] = B_re[i2][j2] - t_re;
                        B_im[i2][j2] = B_im[i2][j2] - t_im;
                    end
                end
            end
            for (c2 = 7; c2 >= 0; c2 = c2 - 1)
                for (i2 = 0; i2 < c2; i2 = i2 + 1) begin
                    f_re = B_re[i2][c2]; f_im = B_im[i2][c2];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[c2][j2] - f_im*B_im[c2][j2];
                        t_im = f_re*B_im[c2][j2] + f_im*B_re[c2][j2];
                        B_re[i2][j2] = B_re[i2][j2] - t_re;
                        B_im[i2][j2] = B_im[i2][j2] - t_im;
                    end
                end
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    iq_re[i2][j2] = q16(B_re[i2][8+j2]);
                    iq_im[i2][j2] = q16(B_im[i2][8+j2]);
                end
        end
    endtask

    integer got_deg;

    // ---- 跑一个声源角度，返回估计出的 DOA ----
    task run_case;
        input  real src_deg;
        input  integer want_csv;
        output integer out_deg;
        begin
            // 构造 R = a*a^H + sigma^2*I 并量化
            steer(src_deg);
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    rq_re[i][j] = q16(ath_re[i]*ath_re[j] + ath_im[i]*ath_im[j]
                                      + ((i==j) ? sigma2 : 0.0));
                    rq_im[i][j] = q16(ath_im[i]*ath_re[j] - ath_re[i]*ath_im[j]);
                end
            inv8_ref;    // 算出 q16 的 R^-1

            nspec = 0;

            // 启动
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            // 喂 R^-1（64 拍行优先）
            repeat (3) @(negedge clk);
            for (k = 0; k < 64; k = k + 1) begin
                din_valid = 1'b1;
                din_re = iq_re[k/8][k%8];
                din_im = iq_im[k/8][k%8];
                @(negedge clk);
            end
            din_valid = 1'b0;

            // 逐角度应答导向向量
            for (aa = 0; aa < NANG; aa = aa + 1) begin
                while (a_req !== 1'b1) begin
                    @(negedge clk);
                    if (s_valid === 1'b1) begin spec[nspec] = s_out; nspec = nspec + 1; end
                end
                steer(aa - 90);                 // 该角度的导向向量
                for (ch = 0; ch < 8; ch = ch + 1) begin
                    avalid = 1'b1;
                    av_re  = q16(ath_re[ch]);
                    av_im  = q16(ath_im[ch]);
                    @(negedge clk);
                    if (s_valid === 1'b1) begin spec[nspec] = s_out; nspec = nspec + 1; end
                end
                avalid = 1'b0;
            end

            // 收尾（等 done，顺便抓最后一个 s）
            guard = 0;
            while (done !== 1'b1 && guard < 20000) begin
                @(negedge clk);
                guard = guard + 1;
                if (s_valid === 1'b1) begin spec[nspec] = s_out; nspec = nspec + 1; end
            end

            out_deg = doa_deg;
            $display("    src %0.0f deg -> estimated %0d deg (min s = %.4f, %0d spectrum pts)",
                     src_deg, doa_deg, s_min/65536.0, nspec);

            if (want_csv && fp) begin
                for (k = 0; k < nspec; k = k + 1)
                    $fwrite(fp, "%0d,%.6f\n", k - 90, 65536.0/spec[k]);
            end

            repeat (10) @(negedge clk);
        end
    endtask

    integer d1, d2, e1, e2;

    initial begin
        nerr = 0;
        fp = 0;

        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("==============================================");
        $display("mvdr_sweep: MVDR spectrum sweep (RTL)");
        $display("UCA 8 mics, R=0.05m, c=343, f0=4031Hz, SNR 20dB");
        $display("==============================================");

        fp = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/sim/mvdr_rtl_spectrum.csv", "w");
        if (fp) $fwrite(fp, "angle,p\n");

        run_case(30.0, 1, d1);
        if (d1 < 0) e1 = -d1; else e1 = d1;
        e1 = e1 - 30;  if (e1 < 0) e1 = -e1;

        run_case(-45.0, 0, d2);
        e2 = d2 + 45;  if (e2 < 0) e2 = -e2;

        if (fp) $fclose(fp);

        $display("----------------------------------------------");
        $display("  src  30 deg -> %0d deg (err %0d)", d1, e1);
        $display("  src -45 deg -> %0d deg (err %0d)", d2, e2);
        if (e1 <= 1 && e2 <= 1)
            $display("RESULT: PASS  (MVDR RTL finds the source angle)");
        else
            $display("RESULT: FAIL  (DOA error too large)");
        $finish;
    end

endmodule
