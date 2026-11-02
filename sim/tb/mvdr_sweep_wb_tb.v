`timescale 1ns / 1ps
// ============================================================
// mvdr_sweep_wb_tb.v —— 宽带 MVDR 扫角（8 bin 非相干融合）验证
//
// 场景：同一几何声源 30°，8 个频率 bin（5/10/15/20/25/31/37/43）各自
//   R_k = a_k(θs)*a_k(θs)^H + 0.01*I（SNR 20dB），Q16.16。
//   tb 用浮点高斯-约当算好 8 个 R_k^-1，按 bin0→bin7 连续 512 拍喂给 DUT，
//   DUT 扫 361 个角度、每个角度收 8 组导向矢量，融合 s_total=Σ s_k 找最小 = DOA。
//
// 注意：DUT 内部有 180° 安装偏移（deg_shift），输出是板子坐标系。
//   几何 30° → 输出 30+180=210 → wrap → -150。
//
// ⚠️ 驱动/采样都在【下降沿】。
// ============================================================
module mvdr_sweep_wb_tb;

    localparam integer NANG = 361;
    localparam integer NB   = 8;

    real pi = 3.14159265358979323846;
    integer NCH = 8;
    real c = 343.0;
    real Rr = 0.05;
    real sigma2 = 0.01;

    // 8 个 bin 编号（与 mvdr_axi_top / radar_pl_top 的 BIN0..BIN7 一致）
    integer binlist [0:NB-1];
    real    fq   [0:NB-1];      // 每个 bin 的频率

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    reg start = 0;
    reg din_valid = 0;
    reg signed [31:0] din_re = 0, din_im = 0;
    wire a_req;
    wire [8:0] a_ang;
    reg  [NB-1:0] avalid = 0;
    reg signed [NB*32-1:0] av_re = 0, av_im = 0;
    wire signed [31:0] s_out;
    wire s_valid;
    wire signed [8:0] doa_deg;
    wire signed [31:0] s_min;
    wire done;

    mvdr_sweep #(.N(8), .NANG(NANG), .NB(NB)) u_sweep (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din_valid(din_valid), .din_re(din_re), .din_im(din_im),
        .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .s_out(s_out), .s_valid(s_valid),
        .doa_deg(doa_deg), .s_min(s_min), .done(done)
    );

    real alpha [0:7];

    // ---- 当前角度的 8 组导向矢量（浮点）----
    real ab_re [0:NB-1][0:7], ab_im [0:NB-1][0:7];

    // ---- 量化矩阵（全局，供 inv8_ref 使用）----
    integer rq_re [0:7][0:7], rq_im [0:7][0:7];       // 量化的 R
    integer iq_re [0:7][0:7], iq_im [0:7][0:7];       // 量化的 R^-1（暂存）
    integer iqb_re [0:NB-1][0:7][0:7];                // 8 个 bin 的 R^-1
    integer iqb_im [0:NB-1][0:7][0:7];

    integer i, j, k, ch, aa, bb, guard, nerr;
    real th, ph, kRn;

    // ---- Q16.16 量化（四舍五入）----
    function integer q16;
        input real x;
        begin
            if (x >= 0.0) q16 = $floor(x*65536.0 + 0.5);
            else          q16 = $ceil (x*65536.0 - 0.5);
        end
    endfunction

    // ---- 同时算 8 个 bin 的导向矢量 a_b(θ) ----
    task steer8;
        input real th_deg;
        integer ii, bt;
        begin
            th = th_deg * pi / 180.0;
            for (bt = 0; bt < NB; bt = bt + 1) begin
                kRn = 2.0 * pi * fq[bt] * Rr / c;
                for (ii = 0; ii < NCH; ii = ii + 1) begin
                    ph = kRn * $cos(th - alpha[ii]);
                    ab_re[bt][ii] = $cos(ph);
                    ab_im[bt][ii] = -$sin(ph);
                end
            end
        end
    endtask

    // ---- 用 ab_*[which] 构造 R = a*a^H + sigma^2*I（量化到全局 rq_*）----
    task make_rq;
        input integer which;
        begin
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    rq_re[i][j] = q16(ab_re[which][i]*ab_re[which][j]
                                     + ab_im[which][i]*ab_im[which][j]
                                     + ((i==j) ? sigma2 : 0.0));
                    rq_im[i][j] = q16(ab_im[which][i]*ab_re[which][j]
                                     - ab_re[which][i]*ab_im[which][j]);
                end
        end
    endtask

    // ---- 浮点高斯-约当求逆（从量化整数矩阵 rq_* 出发，输出 iq_*）----
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

    integer src_geom = 30;
    integer expected_deg;
    integer err;

    initial begin
        nerr = 0;

        binlist[0] = 5;  binlist[1] = 10; binlist[2] = 15; binlist[3] = 20;
        binlist[4] = 25; binlist[5] = 31; binlist[6] = 37; binlist[7] = 43;
        for (bb = 0; bb < NB; bb = bb + 1)
            fq[bb] = binlist[bb] * (50000000.0 / 16.0 / 64.0) / 512.0;

        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        // 期望输出 = 几何角 + 180 偏移，wrap 回 [-180,180]
        expected_deg = src_geom + 180;
        if (expected_deg > 180) expected_deg = expected_deg - 360;

        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("==============================================");
        $display("mvdr_sweep_wb: wideband 8-bin fusion sweep (RTL)");
        $display("UCA 8 mics, R=0.05m, c=343");
        $display("bins = %0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d Hz",
                 fq[0], fq[1], fq[2], fq[3], fq[4], fq[5], fq[6], fq[7]);
        $display("source = %0d deg (geom), expect DUT out = %0d deg (board)", src_geom, expected_deg);
        $display("==============================================");

        // ---- 构造 8 个 bin 的 R^-1 ----
        steer8(src_geom);
        for (bb = 0; bb < NB; bb = bb + 1) begin
            make_rq(bb);
            inv8_ref;
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    iqb_re[bb][i][j] = iq_re[i][j];
                    iqb_im[bb][i][j] = iq_im[i][j];
                end
        end

        // ---- 启动 ----
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // ---- 喂 8 段 R^-1（每段 64 拍 = 一个 bin，行优先）----
        repeat (3) @(negedge clk);
        for (k = 0; k < NB*64; k = k + 1) begin
            din_valid = 1'b1;
            din_re = iqb_re[k/64][(k%64)/8][k%8];
            din_im = iqb_im[k/64][(k%64)/8][k%8];
            @(negedge clk);
        end
        din_valid = 1'b0;

        // ---- 逐角度应答 8 组导向矢量 ----
        for (aa = 0; aa < NANG; aa = aa + 1) begin
            while (a_req !== 1'b1) begin
                @(negedge clk);
                if (done === 1'b1) begin
                    $display("  WARN: done asserted early at ang=%0d", aa);
                end
            end
            steer8(aa - 180);              // 该角度（deg = ang-180）的 8 组导向矢量
            for (ch = 0; ch < 8; ch = ch + 1) begin
                avalid = {NB{1'b1}};
                for (bb = 0; bb < NB; bb = bb + 1) begin
                    av_re[bb*32 +: 32] = q16(ab_re[bb][ch]);
                    av_im[bb*32 +: 32] = q16(ab_im[bb][ch]);
                end
                @(negedge clk);
            end
            avalid = {NB{1'b0}};
        end

        // ---- 收尾（等 done）----
        guard = 0;
        while (done !== 1'b1 && guard < 200000) begin
            @(negedge clk);
            guard = guard + 1;
        end

        err = doa_deg - expected_deg;
        if (err < 0) err = -err;

        $display("----------------------------------------------");
        $display("  src %0d deg (geom) -> DUT %0d deg (board), expected %0d, err %0d",
                 src_geom, doa_deg, expected_deg, err);
        $display("  s_min = %.4f (Q16.16)", s_min/65536.0);
        if (err <= 1)
            $display("RESULT: PASS  (wideband 8-bin fusion finds the source angle)");
        else begin
            $display("RESULT: FAIL  (DOA error too large)");
            nerr = 1;
        end
        $finish;
    end

endmodule
