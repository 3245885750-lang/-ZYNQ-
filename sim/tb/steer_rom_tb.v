`timescale 1ns / 1ps
// ============================================================
// steer_rom_tb.v —— 导向向量 ROM + mvdr_sweep 对接验证
//
// 和 mvdr_sweep_tb 的区别：tb **不再管导向向量**了，只喂 R^-1 和收结果。
//   角度 a(theta) 由 steer_rom 按 a_req/a_ang 自动供给。
//
// 前置：必须先跑 gen_steer_rom_tb 生成 src/steer_re.mem 和 steer_im.mem。
//
// 场景：声源 30 度 / -45 度，R = a*a^H + 0.01*I（Q16.16），和之前一致。
// ============================================================
module steer_rom_tb;

    localparam integer NANG = 181;

    real pi = 3.14159265358979323846;
    integer NCH = 8;
    real c = 343.0;
    real Rr = 0.05;
    // 采样率 = 48828.125 Hz（50MHz/16/64 整数分频），f0≈4100.8Hz，与 ROM 一致
    real f0 = 43.0 * (50000000.0 / 16.0 / 64.0) / 512.0;
    real sigma2 = 0.01;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg start = 0;
    reg din_valid = 0;
    reg signed [31:0] din_re = 0, din_im = 0;

    wire a_req;
    wire [7:0] a_ang;
    wire avalid;
    wire signed [31:0] av_re, av_im;

    wire signed [31:0] s_out;
    wire s_valid;
    wire signed [8:0] doa_deg;
    wire signed [31:0] s_min;
    wire done;

    // ---- DUT 1: mvdr_sweep ----
    mvdr_sweep #(.N(8), .NANG(NANG)) u_sweep (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din_valid(din_valid), .din_re(din_re), .din_im(din_im),
        .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .s_out(s_out), .s_valid(s_valid),
        .doa_deg(doa_deg), .s_min(s_min), .done(done)
    );

    // ---- DUT 2: steer_rom（自动应答 a_req）----
    steer_rom #(.NCH(8), .NANG(NANG)) u_rom (
        .clk(clk), .rst_n(rst_n),
        .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid), .av_re(av_re), .av_im(av_im)
    );

    real alpha [0:7];
    real ath_re [0:7], ath_im [0:7];
    integer rq_re [0:7][0:7], rq_im [0:7][0:7];
    integer iq_re [0:7][0:7], iq_im [0:7][0:7];

    integer i, j, k, guard, nerr, nspec;
    real th, tau, ph;

    function integer q16;
        input real x;
        begin
            if (x >= 0.0) q16 = $floor(x*65536.0 + 0.5);
            else          q16 = $ceil (x*65536.0 - 0.5);
        end
    endfunction

    task steer;
        input real th_deg;
        real t2;
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

    task run_case;
        input  real src_deg;
        output integer out_deg;
        begin
            steer(src_deg);
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    rq_re[i][j] = q16(ath_re[i]*ath_re[j] + ath_im[i]*ath_im[j]
                                      + ((i==j) ? sigma2 : 0.0));
                    rq_im[i][j] = q16(ath_im[i]*ath_re[j] - ath_re[i]*ath_im[j]);
                end
            inv8_ref;

            nspec = 0;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            repeat (3) @(negedge clk);
            for (k = 0; k < 64; k = k + 1) begin
                din_valid = 1'b1;
                din_re = iq_re[k/8][k%8];
                din_im = iq_im[k/8][k%8];
                @(negedge clk);
            end
            din_valid = 1'b0;

            // 这里不再应答导向向量 —— 全靠 steer_rom
            guard = 0;
            while (done !== 1'b1 && guard < 60000) begin
                @(negedge clk);
                guard = guard + 1;
                if (s_valid === 1'b1) begin
                    if (nspec < NANG) nspec = nspec + 1;
                end
            end
            @(negedge clk);
            out_deg = doa_deg;
            $display("    src %0.0f deg -> estimated %0d deg (min s = %.4f, %0d pts)",
                     src_deg, doa_deg, s_min/65536.0, nspec);
            if (nspec !== NANG) $display("    *** spectrum pts wrong: %0d", nspec);
            repeat (10) @(negedge clk);
        end
    endtask

    integer d1, d2, e1, e2;

    initial begin
        nerr = 0;
        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("==============================================");
        $display("steer_rom + mvdr_sweep: ROM-driven steering");
        $display("(tb no longer supplies a(theta))");
        $display("==============================================");

        run_case(30.0, d1);
        if (d1 < 0) e1 = -d1; else e1 = d1;
        e1 = e1 - 30; if (e1 < 0) e1 = -e1;

        run_case(-45.0, d2);
        e2 = d2 + 45; if (e2 < 0) e2 = -e2;

        $display("----------------------------------------------");
        $display("  src  30 deg -> %0d deg (err %0d)", d1, e1);
        $display("  src -45 deg -> %0d deg (err %0d)", d2, e2);
        if (nspec !== NANG) nerr = nerr + 1;
        if (e1 <= 1 && e2 <= 1 && nerr == 0)
            $display("RESULT: PASS  (steering ROM works)");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
