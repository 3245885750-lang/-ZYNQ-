`timescale 1ns / 1ps
// ============================================================
// mvdr_chain_tb.v —— MVDR 全链路「总装测试」
//
//   tb 造 X 快拍(带噪声) → cov_accum_8x8 → cov_to_q16 → mat_inv_8x8
//                                                       ↓ 64 项 R^-1
//                                     tb 缓存并复制 8 份 → 512 拍
//                                                       ↓
//                                                  mvdr_sweep → tb 查 DOA
//
// 目的：四块单独都验过了，这一步验【串起来】能不能跑——重点是 dout_start
//   那套 64 拍流式 wiring 有没有错拍，以及 512 拍装载和扫角握手。
//
// 为什么要 8 份复制：mvdr_sweep 的 S_LOAD 固定等 8*64 = 512 拍 din
//   （li 到 511 才进 S_ANG，见 mvdr_sweep.v:175）。本 tb 的链路是单 bin，
//   只产 64 拍，所以 tb 侧把 R^-1 的 64 项缓存后复制进 8 个 bin 槽。
//   NB=1，扫角只用 bin0，其余槽不影响结果。
//
// 关键点：R 由 cov_accum 真实累加，不再手工加 sigma^2*I。
//   所以每个快拍必须加真实噪声，否则 64 个相同快拍 → R 秩 1 奇异 → 不可逆。
//   （实际系统里 FFT 输出天然含噪声，这里用均匀随机数模拟。）
//   噪声幅度取 sigma_n ≈ 0.096*|s| → sigma^2/|s|^2 ≈ 0.0093 ≈ 0.01，和之前一致。
//
// 角度约定：tb 按模型角造源(th_src) 与导向(applied aa-180)，sweep 输出含
//   180° 安装偏移（deg_shift），所以几何 30° 应读回板子坐标 -150°。
//
// ⚠️ 驱动/采样都在【下降沿】。
// ============================================================
module mvdr_chain_tb;

    localparam integer NCH = 8;
    localparam integer XW  = 24;
    localparam integer K   = 64;
    localparam integer AW  = 64;
    localparam integer NT  = 36;
    localparam integer NANG = 361;   // 全周扫描，索引 0..360 对应模型角 -180..180

    real pi = 3.14159265358979323846;
    real c = 343.0;
    real Rr = 0.05;
    real f0 = 43.0 * 48000.0 / 512.0;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---- cov_accum_8x8 ----
    // ⚠ X 口是 NB 个 bin 打包（NB*NCH*XW = 1536 位）。本 tb 只造 bin0 的数据，
    //   其余 bin 必须显式置 0——如果端口位宽不匹配，xsim 会把高位当 X，
    //   而 cov_accum 的对角迹对 8 个 bin 都累加，一个 X 就把 pwr_acc/sig_on/累加器全污染。
    localparam integer NB = 8;
    reg  [NB*NCH*XW-1:0] X_re = 0, X_im = 0;
    reg               xready = 0;
    wire [AW-1:0]     cov_rc_re, cov_rc_im;
    wire [AW-1:0]     cov_pwr;
    wire [8:0]        cq_rc_addr;
    wire              rdone;

    // ---- cov_to_q16 ----
    wire signed [31:0] cq_re, cq_im;
    wire cq_valid, cq_start, cq_done;
    wire [5:0] cq_shift;

    // ---- mat_inv_8x8 ----
    wire signed [31:0] mi_re, mi_im;
    wire mi_valid, mi_start, mi_done;

    // ---- mvdr_sweep ----
    // sweep 的装载状态固定等 8*64 = 512 拍 din（li 到 511 才进 S_ANG），
    // 而单 bin 链路只产 64 拍，所以这里先把 R^-1 的 64 项抓下来，
    // 再复制 8 份灌满 8 个 bin 槽（NB=1，扫角只用 bin0，其余槽不影响结果）。
    wire a_req;
    reg  avalid = 0;
    reg  signed [31:0] av_re = 0, av_im = 0;
    wire signed [31:0] s_out;
    wire s_valid;
    wire signed [8:0] doa_deg;
    wire signed [31:0] s_min;
    wire done;

    reg               sw_start = 0, sw_valid = 0;
    reg signed [31:0] sw_re = 0, sw_im = 0;
    reg signed [31:0] cap_re [0:63];
    reg signed [31:0] cap_im [0:63];
    integer ncap = 0;

    always @(posedge clk) begin
        if (mi_valid && ncap < 64) begin
            cap_re[ncap] <= mi_re;
            cap_im[ncap] <= mi_im;
            ncap <= ncap + 1;
        end
    end

    // ============ 链路实例化（全部靠 dout_start 自动串联）============
    cov_accum_8x8 #(.NCH(NCH), .XW(XW), .K(K), .AW(AW), .NT(NT)) u_cov (
        .clk(clk), .rst_n(rst_n),
        .X_re(X_re), .X_im(X_im), .motion(1'b0), .flush(1'b0), .xready(xready),
        .rc_addr(cq_rc_addr), .rc_re(cov_rc_re), .rc_im(cov_rc_im),
        .pwr_out(cov_pwr), .rdone(rdone)
    );

    cov_to_q16 #(.N(8), .NT(NT), .AW(AW)) u_conv (
        .clk(clk), .rst_n(rst_n),
        .start(rdone),
        .base(9'd0),                       // 单 bin（数据在 bin0 槽），起始地址 0
        .rc_addr(cq_rc_addr), .rc_re(cov_rc_re), .rc_im(cov_rc_im),
        .dout_re(cq_re), .dout_im(cq_im),
        .dout_valid(cq_valid), .dout_start(cq_start), .done(cq_done),
        .shift_used(cq_shift)
    );

    mat_inv_8x8 u_inv (
        .clk(clk), .rst_n(rst_n),
        .start(cq_start),
        .din_valid(cq_valid), .din_re(cq_re), .din_im(cq_im),
        .dout_re(mi_re), .dout_im(mi_im),
        .dout_valid(mi_valid), .dout_start(mi_start), .done(mi_done)
    );

    mvdr_sweep #(.N(8), .NANG(NANG), .NB(1)) u_sweep (
        .clk(clk), .rst_n(rst_n),
        .start(sw_start),
        .din_valid(sw_valid), .din_re(sw_re), .din_im(sw_im),
        .a_req(a_req), .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .s_out(s_out), .s_valid(s_valid),
        .doa_deg(doa_deg), .s_min(s_min), .done(done)
    );

    // ============ tb 侧 ============
    real alpha [0:7];
    real ath_re [0:7], ath_im [0:7];
    real th_src = 30.0;
    real tau, ph;

    reg signed [XW-1:0] xs_re [0:7], xs_im [0:7];

    integer i, k, ch, aa, guard, nspec, nerr, seed, bi, n;
    integer noise;
    integer spec [0:NANG-1];
    integer got_deg;

    // 噪声幅度：sqrt(0.03)*2^22 ≈ 0.173*2^22 → 均匀分布 std ≈ 0.1*|s|
    localparam integer NOISE_A = 700000;

    function integer q16;
        input real x;
        begin
            if (x >= 0.0) q16 = $floor(x*65536.0 + 0.5);
            else          q16 = $ceil (x*65536.0 - 0.5);
        end
    endfunction

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

    initial begin
        nerr = 0;
        seed = 32'h1234_5678;
        for (n = 0; n < 64; n = n + 1) begin
            cap_re[n] = 0; cap_im[n] = 0;
        end

        for (i = 0; i < NCH; i = i + 1)
            alpha[i] = 2.0 * pi * i / NCH;

        $display("==============================================");
        $display("MVDR full chain: cov -> adapt -> inv -> sweep");
        $display("source = %0.0f deg, %0d snapshots + random noise", th_src, K);
        $display("==============================================");

        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ---------- 1) 喂 K 个带噪快拍 ----------
        for (k = 0; k < K; k = k + 1) begin
            steer(th_src);                       // 信号部分固定（相干源）
            for (i = 0; i < NCH; i = i + 1) begin
                // 信号(|.|<=2^22) + 噪声(|.|<7e5)，和 <2^23，24bit 有符号装得下
                xs_re[i] = $rtoi(ath_re[i] * 4194304.0) + ($random(seed) % NOISE_A);
                xs_im[i] = $rtoi(ath_im[i] * 4194304.0) + ($random(seed) % NOISE_A);
            end
            // 打包
            X_re = 0; X_im = 0;
            for (i = 0; i < NCH; i = i + 1) begin
                X_re[i*XW +: XW] = xs_re[i];
                X_im[i*XW +: XW] = xs_im[i];
            end
            @(negedge clk);
            xready = 1'b1;
            @(negedge clk);
            xready = 1'b0;
            repeat (320) @(negedge clk);         // 等 cov MAC 跑完 8×36=288 项（留余量）
        end

        $display("  fed %0d snapshots", K);

        // ---------- 2) 等归一化 + 求逆跑完，拿到 64 项 R^-1 ----------
        guard = 0;
        while (mi_done !== 1'b1 && guard < 20000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (mi_done !== 1'b1) begin
            $display("RESULT: FAIL  (timed out waiting for mat_inv done)");
            $finish;
        end
        repeat (4) @(negedge clk);   // done 比最后一拍 dout_valid 早一拍，等它落地
        $display("  mat_inv done, %0d R^-1 elements captured", ncap);

        // ---------- 3) 把 64 项复制进 8 个 bin 槽，灌满 512 拍装载 ----------
        sw_start = 1'b1;
        @(negedge clk);
        sw_start = 1'b0;
        for (bi = 0; bi < 8; bi = bi + 1) begin
            for (n = 0; n < 64; n = n + 1) begin
                sw_valid = 1'b1;
                sw_re    = cap_re[n];
                sw_im    = cap_im[n];
                @(negedge clk);
            end
        end
        sw_valid = 1'b0;

        // ---------- 4) 应答扫角阶段的导向向量请求 ----------
        nspec = 0;
        for (aa = 0; aa < NANG; aa = aa + 1) begin
            guard = 0;
            while (a_req !== 1'b1 && guard < 30000) begin
                @(negedge clk);
                guard = guard + 1;
                if (s_valid === 1'b1) begin
                    if (nspec < NANG) begin spec[nspec] = s_out; nspec = nspec + 1; end
                end
            end
            if (guard >= 30000) begin
                $display("RESULT: FAIL  (timed out waiting for a_req at angle %0d)", aa);
                $finish;
            end
            steer(aa - 180);   // 与 steer_*.mem 的 (ang-180) 约定一致
            for (ch = 0; ch < 8; ch = ch + 1) begin
                avalid = 1'b1;
                av_re  = q16(ath_re[ch]);
                av_im  = q16(ath_im[ch]);
                @(negedge clk);
                if (s_valid === 1'b1) begin
                    if (nspec < NANG) begin spec[nspec] = s_out; nspec = nspec + 1; end
                end
            end
            avalid = 1'b0;
        end

        // ---------- 3) 等 done ----------
        guard = 0;
        while (done !== 1'b1 && guard < 30000) begin
            @(negedge clk);
            guard = guard + 1;
            if (s_valid === 1'b1) begin spec[nspec] = s_out; nspec = nspec + 1; end
        end
        if (done !== 1'b1) begin
            $display("RESULT: FAIL  (timed out waiting for done)");
            $finish;
        end

        got_deg = doa_deg;

        $display("  adapter shift_used = %0d", cq_shift);
        $display("  spectrum points received = %0d (expect %0d)", nspec, NANG);
        $display("  estimated DOA = %0d deg   (geom source %0.0f deg, board coord expects -150)", got_deg, th_src);
        $display("  min s = %.4f", s_min/65536.0);

        if (nspec !== NANG) begin
            $display("  *** spectrum point count wrong");
            nerr = nerr + 1;
        end
        i = got_deg + 150;  if (i < 0) i = -i;   // 几何 30° → 板子坐标 -150°（sweep 内含 180° 安装偏移）
        if (i > 1) begin
            $display("  *** DOA error = %0d deg", i);
            nerr = nerr + 1;
        end

        if (nerr == 0)
            $display("RESULT: PASS  (full MVDR chain works end-to-end)");
        else
            $display("RESULT: FAIL  (%0d problems)", nerr);
        $finish;
    end

endmodule
