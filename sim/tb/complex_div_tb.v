`timescale 1ns / 1ps
// ============================================================
// complex_div_tb.v —— Q16.16 复数除法器单元验证
//
// 用几个手算得出来的 q = a/b 用例，逐项比对（容差 ±1 LSB 吸收四舍五入边界）。
// 定点里 a、b 都是 Q16.16（1.0 = 65536）。
//
// ⚠️ 关键教训（上一版踩的坑）：
//   上一版在【上升沿】驱动 ar/ai/br/bi + start，结果 DUT 读到的全是
//   【上一个用例】的组合值（甚至初值 X）。原因：DUT 的 n_re/d_w 是
//   wire 连续赋值，与 tb 的 blocking 赋值在同一个时钟沿竞争 delta 顺序，
//   DUT 的 always 块排在连续赋值更新之前执行 → 读到旧值。
//   【修法】改成【下降沿】驱动：上升沿是 DUT 采样时刻，下降沿改输入，
//   到下一个上升沿时组合逻辑早已稳定。
//
// 采样方式：除法器延迟确定（~131 拍），start 后固定等 300 拍再读，
//   不依赖 done 握手（避免同类竞争）。同时记录 done 出现的拍数做诊断。
// ============================================================
module complex_div_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    reg start = 0;
    reg signed [31:0] ar = 0, ai = 0, br = 0, bi = 0;   // 给初值，避免 X
    wire signed [31:0] quo_re, quo_im;
    wire done;

    complex_div u_div (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .ar(ar), .ai(ai), .br(br), .bi(bi),
        .quo_re(quo_re), .quo_im(quo_im), .done(done)
    );

    // ---- 跑一个用例：下降沿给 a/b，固定等 300 拍，返回商 ----
    task run_case;
        input integer ar_i, ai_i, br_i, bi_i;
        output integer qr, qi;
        integer t, lat;
        begin
            @(negedge clk);                       // ← 下降沿驱动
            ar = ar_i; ai = ai_i; br = br_i; bi = bi_i;
            start = 1'b1;

            @(negedge clk);                       // 下一个下降沿，撤销 start
            start = 1'b0;

            // DUT 已在中间那个上升沿启动，等它跑完（延迟 ~131 拍）
            lat = -1;
            for (t = 0; t < 300; t = t + 1) begin
                @(posedge clk);
                if (done === 1'b1 && lat < 0)
                    lat = t;
            end
            if (lat < 0)
                $display("  [diag] done NOT seen within 300 cycles");
            else
                $display("  [diag] done at cycle %0d", lat);

            qr = quo_re; qi = quo_im;             // 商已稳定，直接读
        end
    endtask

    integer qr, qi, nerr, ncase;

    task check_case;
        input integer ar_i, ai_i, br_i, bi_i;
        input integer er, ei;
        integer d;
        begin
            ncase = ncase + 1;
            run_case(ar_i, ai_i, br_i, bi_i, qr, qi);
            d = qr - er; if (d < 0) d = -d;
            if (d > 1) begin
                $display("  MISMATCH (%0d,%0d)/(%0d,%0d): re got %0d, exp %0d",
                         ar_i, ai_i, br_i, bi_i, qr, er);
                nerr = nerr + 1;
            end
            d = qi - ei; if (d < 0) d = -d;
            if (d > 1) begin
                $display("  MISMATCH (%0d,%0d)/(%0d,%0d): im got %0d, exp %0d",
                         ar_i, ai_i, br_i, bi_i, qi, ei);
                nerr = nerr + 1;
            end
        end
    endtask

    initial begin
        nerr  = 0;
        ncase = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("==============================================");
        $display("complex_div: Q16.16 complex divider check");
        $display("==============================================");

        // (1+0j)/(2+0j) = 0.5          -> (32768, 0)
        check_case(65536, 0, 131072, 0, 32768, 0);
        // (0+1j)/(2+0j) = 0.5j         -> (0, 32768)
        check_case(0, 65536, 131072, 0, 0, 32768);
        // (1+1j)/(2+0j) = 0.5+0.5j     -> (32768, 32768)
        check_case(65536, 65536, 131072, 0, 32768, 32768);
        // (2+0j)/(1+1j) = 1-1j         -> (65536, -65536)
        check_case(131072, 0, 65536, 65536, 65536, -65536);
        // (3+4j)/(1+0j) = 3+4j         -> (196608, 262144)
        check_case(196608, 262144, 65536, 0, 196608, 262144);
        // (1+0j)/(3+0j) = 0.33333      -> (21845, 0)   [round(21845.33)=21845]
        check_case(65536, 0, 196608, 0, 21845, 0);
        // (-1+0j)/(2+0j) = -0.5        -> (-32768, 0)
        check_case(-65536, 0, 131072, 0, -32768, 0);
        // (0-1j)/(2+0j) = -0.5j        -> (0, -32768)
        check_case(0, -65536, 131072, 0, 0, -32768);

        if (nerr == 0) begin
            $display("all %0d cases match", ncase);
            $display("RESULT: PASS  (complex divider correct)");
        end else begin
            $display("RESULT: FAIL  (%0d mismatches)", nerr);
        end
        $finish;
    end

endmodule
