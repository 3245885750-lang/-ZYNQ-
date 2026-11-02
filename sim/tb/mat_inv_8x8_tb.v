`timescale 1ns / 1ps
// ============================================================
// mat_inv_8x8_tb.v —— 8x8 复数矩阵求逆验证
//
// 构造和 MVDR 里一样的 R：声源 30 度、bin 43，R = a*a^H + sigma^2*I
// （sigma^2 = 0.01，SNR 20dB），量化到 Q16.16 喂给 DUT，
// 然后检查两件事：
//   1) 逐元素与 float 参考求逆比对（相对误差）
//   2) 硬件算出的 R^-1 是否满足 R^-1 * R ~= I
//
// ⚠️ 驱动/采样一律在【下降沿】——上升沿留给 DUT 采样，避免 delta 竞争。
// ============================================================
module mat_inv_8x8_tb;

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
    wire signed [31:0] dout_re, dout_im;
    wire dout_valid, done;

    mat_inv_8x8 u_inv (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .din_valid(din_valid), .din_re(din_re), .din_im(din_im),
        .dout_re(dout_re), .dout_im(dout_im),
        .dout_valid(dout_valid), .done(done)
    );

    real alpha [0:7];
    real a_re [0:7], a_im [0:7];

    integer rq_re [0:7][0:7], rq_im [0:7][0:7];   // 量化后的输入 R
    integer hw_re [0:7][0:7], hw_im [0:7][0:7];   // 硬件算出的 R^-1
    real    rf_re [0:7][0:7], rf_im [0:7][0:7];   // float 参考 R^-1

    integer i, j, k, t, guard, nerr;

    // ---- Q16.16 量化（四舍五入到 1/65536）----
    function integer q16;
        input real x;
        begin
            if (x >= 0.0) q16 = $floor(x*65536.0 + 0.5);
            else          q16 = $ceil (x*65536.0 - 0.5);
        end
    endfunction

    function real fabs;
        input real x;
        begin
            fabs = (x >= 0.0) ? x : -x;
        end
    endfunction

    // ---- 导向向量 a(theta) ----
    task steer;
        input real th_deg;
        real th, tau, ph;
        integer ii;
        begin
            th = th_deg * pi / 180.0;
            for (ii = 0; ii < NCH; ii = ii + 1) begin
                tau    = (Rr/c) * $cos(th - alpha[ii]);
                ph     = 2.0 * pi * f0 * tau;
                a_re[ii] = $cos(ph);
                a_im[ii] = -$sin(ph);
            end
        end
    endtask

    // ---- 参考：float 高斯-约当求逆（从量化整数矩阵出发）----
    task inv8_ref;
        real B_re [0:7][0:15], B_im [0:7][0:15];
        integer col2, i2, j2, piv2;
        real mag, maxmag, d_re, d_im, denom, f_re, f_im, t_re, t_im, tmp;
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

            for (col2 = 0; col2 < 8; col2 = col2 + 1) begin
                piv2 = col2;
                maxmag = B_re[col2][col2]*B_re[col2][col2] + B_im[col2][col2]*B_im[col2][col2];
                for (i2 = col2+1; i2 < 8; i2 = i2 + 1) begin
                    mag = B_re[i2][col2]*B_re[i2][col2] + B_im[i2][col2]*B_im[i2][col2];
                    if (mag > maxmag) begin maxmag = mag; piv2 = i2; end
                end
                if (piv2 != col2)
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        tmp = B_re[col2][j2]; B_re[col2][j2] = B_re[piv2][j2]; B_re[piv2][j2] = tmp;
                        tmp = B_im[col2][j2]; B_im[col2][j2] = B_im[piv2][j2]; B_im[piv2][j2] = tmp;
                    end
                d_re  = B_re[col2][col2]; d_im = B_im[col2][col2];
                denom = d_re*d_re + d_im*d_im;
                for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                    t_re = B_re[col2][j2]; t_im = B_im[col2][j2];
                    B_re[col2][j2] = (t_re*d_re + t_im*d_im) / denom;
                    B_im[col2][j2] = (t_im*d_re - t_re*d_im) / denom;
                end
                for (i2 = col2+1; i2 < 8; i2 = i2 + 1) begin
                    f_re = B_re[i2][col2]; f_im = B_im[i2][col2];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[col2][j2] - f_im*B_im[col2][j2];
                        t_im = f_re*B_im[col2][j2] + f_im*B_re[col2][j2];
                        B_re[i2][j2] = B_re[i2][j2] - t_re;
                        B_im[i2][j2] = B_im[i2][j2] - t_im;
                    end
                end
            end
            for (col2 = 7; col2 >= 0; col2 = col2 - 1)
                for (i2 = 0; i2 < col2; i2 = i2 + 1) begin
                    f_re = B_re[i2][col2]; f_im = B_im[i2][col2];
                    for (j2 = 0; j2 < 16; j2 = j2 + 1) begin
                        t_re = f_re*B_re[col2][j2] - f_im*B_im[col2][j2];
                        t_im = f_re*B_im[col2][j2] + f_im*B_re[col2][j2];
                        B_re[i2][j2] = B_re[i2][j2] - t_re;
                        B_im[i2][j2] = B_im[i2][j2] - t_im;
                    end
                end
            for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (j2 = 0; j2 < 8; j2 = j2 + 1) begin
                    rf_re[i2][j2] = B_re[i2][8+j2];
                    rf_im[i2][j2] = B_im[i2][8+j2];
                end
        end
    endtask

    real maxrel, err, magr, maxrtr;
    real pre, pim;
    integer pv;

    initial begin
        nerr = 0;
        maxrel = 0.0;

        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        // ---- 构造 R = a(30)*a(30)^H + sigma^2*I，量化 ----
        steer(30.0);
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                rq_re[i][j] = q16(a_re[i]*a_re[j] + a_im[i]*a_im[j] + ((i==j) ? sigma2 : 0.0));
                rq_im[i][j] = q16(a_im[i]*a_re[j] - a_re[i]*a_im[j]);
            end

        inv8_ref;   // float 参考

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("==============================================");
        $display("mat_inv_8x8: 8x8 complex matrix inversion check");
        $display("R = a(30deg)*a^H + 0.01*I  (Q16.16)");
        $display("==============================================");

        // ---------- 1) 启动 + 喂矩阵（下降沿驱动）----------
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        repeat (5) @(negedge clk);        // 等 DUT 进 S_LOAD

        for (k = 0; k < 64; k = k + 1) begin
            din_valid = 1'b1;
            din_re = rq_re[k/8][k%8];
            din_im = rq_im[k/8][k%8];
            @(negedge clk);
        end
        din_valid = 1'b0;

        // ---------- 2) 收 R^-1（下降沿采样）----------
        k = 0;
        guard = 0;
        while (k < 64 && guard < 20000) begin
            @(negedge clk);
            guard = guard + 1;
            if (dout_valid === 1'b1) begin
                hw_re[k/8][k%8] = dout_re;
                hw_im[k/8][k%8] = dout_im;
                k = k + 1;
            end
        end
        if (k < 64) begin
            $display("RESULT: FAIL  (only %0d of 64 outputs received, guard=%0d)", k, guard);
            $finish;
        end
        $display("  collected 64 outputs after %0d cycles", guard);

        // ---------- 3) 逐元素与 float 参考比对 ----------
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                err  = fabs(hw_re[i][j]/65536.0 - rf_re[i][j]) + fabs(hw_im[i][j]/65536.0 - rf_im[i][j]);
                magr = fabs(rf_re[i][j]) + fabs(rf_im[i][j]);
                if (magr < 1.0) magr = 1.0;          // 小元素用绝对误差
                if (err/magr > maxrel) begin
                    maxrel = err/magr;
                    pv = i*8 + j;
                end
            end
        $display("  max element rel-error vs float ref = %.4f%%  (worst elem %0d)", maxrel*100.0, pv);

        // ---------- 4) 检查 R^-1 * R ~= I ----------
        maxrtr = 0.0;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                pre = 0.0; pim = 0.0;
                for (k = 0; k < 8; k = k + 1) begin
                    pre = pre + (hw_re[i][k]/65536.0)*(rq_re[k][j]/65536.0)
                              - (hw_im[i][k]/65536.0)*(rq_im[k][j]/65536.0);
                    pim = pim + (hw_re[i][k]/65536.0)*(rq_im[k][j]/65536.0)
                              + (hw_im[i][k]/65536.0)*(rq_re[k][j]/65536.0);
                end
                err = fabs(pre - ((i==j) ? 1.0 : 0.0)) + fabs(pim);
                if (err > maxrtr) maxrtr = err;
            end
        $display("  max |R^-1*R - I| = %.5f", maxrtr);

        // ---------- 判定 ----------
        if (maxrel < 0.05 && maxrtr < 0.10) begin
            $display("RESULT: PASS  (8x8 complex inversion correct)");
        end else begin
            $display("RESULT: FAIL  (rel-error %.4f%%, R^-1*R err %.5f)", maxrel*100.0, maxrtr);
        end
        $finish;
    end

endmodule
