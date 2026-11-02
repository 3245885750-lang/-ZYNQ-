`timescale 1ns / 1ps
// ============================================================
// cov_accum_8x8_tb.v —— 8 bin 协方差 EMA 累积模块验证
//
// 声源：30 度方向，8 个频点（bin 5/10/15/20/25/31/37/43）各自固定谱，
//   没有噪声，连续 K=16 个快拍。
//
// 参考值不是简单的 K*X*X^H 了，而是精确复刻硬件的整数 EMA 递推：
//     acc ← acc - (acc >>> S) + m      （整数运算，逐位可复现）
//   逐快拍在 tb 里用 64 位有符号整数跑同样的递推，最后逐项与 RTL 输出比对
//   （完全相等才算过）。这样既验证 8 套累加器互不串扰，也验证 EMA 数学正确。
// ============================================================
module cov_accum_8x8_tb;

    localparam integer NCH = 8;
    localparam integer XW  = 24;
    localparam integer K   = 16;    // 快拍数（EMA 只需验证递推正确，不必跑到稳态）
    localparam integer AW  = 64;
    localparam integer NT  = 36;
    localparam integer NB  = 8;
    localparam integer S   = 7;     // 遗忘因子 α = 1/128

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg  [NB*NCH*XW-1:0] X_re = 0, X_im = 0;
    reg                  xready = 0;
    reg  [8:0]           rc_addr = 0;
    wire [AW-1:0]        rc_re, rc_im;
    wire [AW-1:0]        pwr_out;
    wire                 rdone;

    // 几何参数
    real pi = 3.14159265358979323846;
    real c  = 343.0;
    real radius = 0.05;
    real fs = 48828.125;            // 50MHz / 16 / 64
    integer binlist [0:NB-1];
    real fbin [0:NB-1];
    real alpha [0:7];
    real th_src = 30.0;
    real tau, ph;

    reg signed [XW-1:0] xs_re [0:NB-1][0:NCH-1];   // 每 bin 每通道的源谱定点
    reg signed [XW-1:0] xs_im [0:NB-1][0:NCH-1];
    reg signed [63:0]   xr [0:NB-1][0:NCH-1];      // 64 位扩展（算参考用）
    reg signed [63:0]   xi [0:NB-1][0:NCH-1];
    reg signed [63:0]   ref_re [0:NB-1][0:NT-1];   // EMA 递推参考值
    reg signed [63:0]   ref_im [0:NB-1][0:NT-1];
    reg signed [63:0]   mref_re, mref_im;

    integer i, j, p, k, b, guard;

    // 上三角行偏移：p(i,j) = row_off(i) + (j - i)
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

    cov_accum_8x8 #(.NCH(NCH), .XW(XW), .K(K), .AW(AW), .NT(NT), .NB(NB), .S(S)) u_cov (
        .clk(clk), .rst_n(rst_n),
        .X_re(X_re), .X_im(X_im), .motion(1'b0), .flush(1'b0), .xready(xready),
        .rc_addr(rc_addr), .rc_re(rc_re), .rc_im(rc_im),
        .pwr_out(pwr_out), .rdone(rdone)
    );

    reg signed [63:0] hw_re, hw_im;
    integer nerr;

    initial begin
        binlist[0] = 5;  binlist[1] = 10; binlist[2] = 15; binlist[3] = 20;
        binlist[4] = 25; binlist[5] = 31; binlist[6] = 37; binlist[7] = 43;

        // 参考数组清零（防止索引写漏时出现 X 被 if 静默跳过）
        for (b = 0; b < NB; b = b + 1)
            for (p = 0; p < NT; p = p + 1) begin
                ref_re[b][p] = 0;
                ref_im[b][p] = 0;
            end

        // 几何
        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        // 每个 bin 的源谱定点（SCALE = 2^22，落在 24 位有符号范围内）
        //   a_i(f) = exp(-j*2*pi*f*R/c*cos(theta - alpha_i))
        X_re = 0; X_im = 0;
        for (b = 0; b < NB; b = b + 1) begin
            fbin[b] = binlist[b] * fs / 512.0;
            for (i = 0; i < NCH; i = i + 1) begin
                tau = (radius / c) * $cos(th_src * pi / 180.0 - alpha[i]);
                ph  = 2.0 * pi * fbin[b] * tau;
                xs_re[b][i] = $rtoi( $cos(ph) * 4194304.0);
                xs_im[b][i] = $rtoi(-$sin(ph) * 4194304.0);
                xr[b][i] = xs_re[b][i];
                xi[b][i] = xs_im[b][i];
                // 打包：bin b 的第 ch 路 = X_re[(b*NCH+ch)*XW +: XW]
                X_re[(b*NCH+i)*XW +: XW] = xs_re[b][i];
                X_im[(b*NCH+i)*XW +: XW] = xs_im[b][i];
            end
        end

        // 复位
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("==============================================");
        $display("cov_accum_8x8: 8-bin EMA accumulation check");
        $display("source = 30 deg, bins = 5/10/15/20/25/31/37/43");
        $display("K = %0d snapshots, S = %0d (alpha = 1/%0d)", K, S, 1<<S);
        $display("==============================================");

        // 发 K 个快拍。每个快拍 EMA 要跑 NB*NT = 288 拍，留 300 拍间隔。
        for (k = 0; k < K; k = k + 1) begin
            @(posedge clk);
            xready = 1'b1;
            @(posedge clk);
            xready = 1'b0;

            // ---- tb 侧精确复刻 EMA 递推 ----
            for (b = 0; b < NB; b = b + 1)
                for (i = 0; i < NCH; i = i + 1)
                    for (j = i; j < NCH; j = j + 1) begin
                        p = row_off(i) + (j - i);
                        mref_re = xr[b][i]*xr[b][j] + xi[b][i]*xi[b][j];
                        mref_im = xi[b][i]*xr[b][j] - xr[b][i]*xi[b][j];
                        ref_re[b][p] = ref_re[b][p] - (ref_re[b][p] >>> S) + mref_re;
                        ref_im[b][p] = ref_im[b][p] - (ref_im[b][p] >>> S) + mref_im;
                    end

            if (k < K-1)
                repeat (300) @(posedge clk);
        end

        // 等 rdone（带超时保护，防死等）
        guard = 0;
        while (rdone != 1'b1 && guard < 20000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (rdone != 1'b1) begin
            $display("RESULT: FAIL  (rdone timeout)");
            $finish;
        end
        @(posedge clk);

        // 逐项比对（8 bin × 36 项），通过随机读口顺序读（BRAM 读 1 拍延迟）
        nerr = 0;
        for (b = 0; b < NB; b = b + 1)
            for (p = 0; p < NT; p = p + 1) begin
                rc_addr = b*NT + p;     // 驱动读地址
                @(posedge clk);         // BRAM 锁存读结果
                @(posedge clk);         // 读结果稳定，采样
                hw_re = $signed(rc_re);
                hw_im = $signed(rc_im);
                if (hw_re != ref_re[b][p] || hw_im != ref_im[b][p]) begin
                    if (nerr < 5)
                        $display("  MISMATCH bin=%0d p=%0d: hw=(%0d,%0d) ref=(%0d,%0d)",
                                 binlist[b], p, hw_re, hw_im, ref_re[b][p], ref_im[b][p]);
                    nerr = nerr + 1;
                end
            end

        if (nerr == 0) begin
            $display("all %0d entries (8 bins) match EMA reference exactly", NB*NT);
            $display("RESULT: PASS  (8-bin covariance EMA correct)");
        end else begin
            $display("RESULT: FAIL  (%0d entries mismatched)", nerr);
        end
        $finish;
    end

endmodule
