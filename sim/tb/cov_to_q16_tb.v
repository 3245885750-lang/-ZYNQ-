`timescale 1ns / 1ps
// ============================================================
// cov_to_q16_tb.v —— 「协方差 → Q16.16」适配层验证
//
// 用和 cov_accum_8x8_tb 一样的真实量级：声源 30 度、bin 43、
// 24bit 谱（scale 2^22）、K=64 快拍。R = K * X*X^H，幅度 ~2^50。
//
// 检查方式是【逐项精确整数比对】：tb 里用 64 位整数复现
//   展开 + 共轭 + MSB 求 shift + 四舍五入右移
// 全过程，和硬件输出完全相等才算过（没有任何容差）。
//
// ⚠️ 驱动/采样都在【下降沿】。
// ============================================================
module cov_to_q16_tb;

    localparam integer NCH = 8;
    localparam integer NT  = 36;
    localparam integer AW  = 64;
    localparam integer K   = 64;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    reg start = 0;
    // 模型 cov_accum 的随机读口：36 深 BRAM + 1 拍读延迟
    reg signed [AW-1:0] bram_re [0:NT-1];
    reg signed [AW-1:0] bram_im [0:NT-1];
    wire [8:0] rc_addr;
    reg  [AW-1:0] rc_re_r, rc_im_r;
    wire [AW-1:0] rc_re = rc_re_r, rc_im = rc_im_r;
    wire signed [31:0] dout_re, dout_im;
    wire dout_valid, done;
    wire [5:0] shift_used;

    // 模型 BRAM 读口（复刻 cov_accum 的随机读：读地址组合跟随 rc_addr，读 1 拍延迟）
    always @(posedge clk) begin
        rc_re_r <= bram_re[rc_addr];
        rc_im_r <= bram_im[rc_addr];
    end

    cov_to_q16 u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .base(9'd0),
        .rc_addr(rc_addr),
        .rc_re(rc_re), .rc_im(rc_im),
        .dout_re(dout_re), .dout_im(dout_im),
        .dout_valid(dout_valid), .done(done),
        .shift_used(shift_used)
    );

    // 几何
    real pi = 3.14159265358979323846;
    real c = 343.0;
    real radius = 0.05;
    real f0 = 43.0 * 48000.0 / 512.0;
    real alpha [0:7];
    real th_src = 30.0;
    real tau, ph;

    reg signed [23:0] xs_re [0:7], xs_im [0:7];      // 24bit 谱
    reg signed [63:0] xr [0:7], xi [0:7];

    reg signed [63:0] ref_re [0:NT-1], ref_im [0:NT-1];   // 上三角参考
    reg signed [63:0] hw_re [0:7][0:7], hw_im [0:7][0:7]; // 硬件输出

    integer i, j, p, k, guard, nerr;
    reg signed [63:0] maxmag, magv, bias, expect_re, expect_im, src_re, src_im;
    integer msb, sh, cnt2;

    // 上三角行偏移（与 cov_accum_8x8 一致）
    function integer row_off(input integer ii);
        case (ii)
            0: row_off = 0;
            1: row_off = 8;
            2: row_off = 15;
            3: row_off = 21;
            4: row_off = 26;
            5: row_off = 30;
            6: row_off = 33;
            7: row_off = 35;
            default: row_off = 0;
        endcase
    endfunction

    function [63:0] abs64f;
        input signed [63:0] x;
        begin
            abs64f = x[63] ? (~x + 64'd1) : x;
        end
    endfunction

    initial begin
        nerr = 0;

        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        // ---- 源谱定点（SCALE = 2^22）----
        for (i = 0; i < NCH; i = i + 1) begin
            tau = (radius / c) * $cos(th_src * pi / 180.0 - alpha[i]);
            ph  = 2.0 * pi * f0 * tau;
            xs_re[i] = $rtoi( $cos(ph) * 4194304.0);
            xs_im[i] = $rtoi(-$sin(ph) * 4194304.0);
            xr[i] = xs_re[i];
            xi[i] = xs_im[i];
        end

        // ---- 参考：R = K * X*X^H（上三角 36 项，64bit 精确）----
        for (p = 0; p < NT; p = p + 1) begin
            ref_re[p] = 0;
            ref_im[p] = 0;
        end
        for (i = 0; i < NCH; i = i + 1)
            for (j = i; j < NCH; j = j + 1) begin
                p = row_off(i) + (j - i);
                ref_re[p] = K * (xr[i]*xr[j] + xi[i]*xi[j]);
                ref_im[p] = K * (xi[i]*xr[j] - xr[i]*xi[j]);
            end

        // ---- 装入模型 BRAM（cov_to_q16 按 base+0..35 顺序读）----
        for (p = 0; p < NT; p = p + 1) begin
            bram_re[p] = ref_re[p];
            bram_im[p] = ref_im[p];
        end

        // ---- tb 侧复现：max|元素| -> shift ----
        maxmag = 0;
        for (p = 0; p < NT; p = p + 1) begin
            magv = abs64f(ref_re[p]);  if (magv > maxmag) maxmag = magv;
            magv = abs64f(ref_im[p]);  if (magv > maxmag) maxmag = magv;
        end
        msb = 0;
        for (i = 0; i < 64; i = i + 1)
            if (maxmag[i]) msb = i;
        if (msb > 16) sh = msb - 16; else sh = 0;

        $display("==============================================");
        $display("cov_to_q16: covariance -> Q16.16 adapter check");
        $display("source = 30 deg, 24bit spectrum, K = %0d snapshots", K);
        $display("  max|R entry| = %0d  (MSB %0d)  -> shift = %0d", maxmag, msb, sh);
        $display("==============================================");

        // ---- 跑 DUT（下降沿驱动）----
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // ---- 收输出（下降沿采样）----
        cnt2 = 0;
        guard = 0;
        while (cnt2 < 64 && guard < 5000) begin
            @(negedge clk);
            guard = guard + 1;
            if (dout_valid === 1'b1) begin
                hw_re[cnt2/8][cnt2%8] = dout_re;
                hw_im[cnt2/8][cnt2%8] = dout_im;
                cnt2 = cnt2 + 1;
            end
        end
        if (cnt2 < 64) begin
            $display("RESULT: FAIL  (only %0d of 64 outputs, guard=%0d)", cnt2, guard);
            $finish;
        end
        $display("  collected 64 outputs after %0d cycles", guard);
        $display("  shift_used from DUT = %0d  (tb expects %0d)", shift_used, sh);

        if (shift_used !== sh[5:0]) begin
            $display("  *** shift mismatch");
            nerr = nerr + 1;
        end

        // ---- 逐项精确比对 ----
        bias = (sh == 0) ? 64'sd0 : (64'sd1 <<< (sh - 1));
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                if (i <= j) begin
                    p = row_off(i) + (j - i);
                    src_re = ref_re[p];
                    src_im = ref_im[p];
                end else begin
                    p = row_off(j) + (i - j);
                    src_re = ref_re[p];
                    src_im = -ref_im[p];       // 共轭
                end
                expect_re = (src_re + bias) >>> sh;
                if (i == j) expect_re = expect_re + 64'sd1024;   // 对角加载 DL=1024（与 DUT 一致）
                expect_im = (src_im + bias) >>> sh;
                if ((hw_re[i][j] & 64'hFFFFFFFF) !== (expect_re & 64'hFFFFFFFF) ||
                    (hw_im[i][j] & 64'hFFFFFFFF) !== (expect_im & 64'hFFFFFFFF)) begin
                    if (nerr < 6)
                        $display("  MISMATCH (%0d,%0d): hw=(%0d,%0d) exp=(%0d,%0d)",
                                 i, j, hw_re[i][j], hw_im[i][j],
                                 $signed(expect_re[31:0]), $signed(expect_im[31:0]));
                    nerr = nerr + 1;
                end
            end

        if (nerr == 0) begin
            $display("all 64 entries match reference exactly");
            $display("  e.g. R[0][0] = %0d  (%.4f in Q16.16)", hw_re[0][0], hw_re[0][0]/65536.0);
            $display("       R[0][1] = (%0d,%0d)", hw_re[0][1], hw_im[0][1]);
            $display("RESULT: PASS  (adapter correct)");
        end else begin
            $display("RESULT: FAIL  (%0d mismatches)", nerr);
        end
        $finish;
    end

endmodule
