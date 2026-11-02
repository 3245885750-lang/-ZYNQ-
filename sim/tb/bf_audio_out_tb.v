`timescale 1ns / 1ps
// ============================================================
// bf_audio_out_tb.v —— 波束成形干净音频模块的仿真验证
//
// 信号模型（与 gen_das_taps.py 的圆周阵约定严格一致）：
//   声源在"表内角度" theta（tap 表行 r，theta = r*2 - 180）。
//   第 i 路麦克风收到的样本： x_i(n) = A·sin( w·n - w·k·cos(theta - alpha_i) )
//     k = R·Fs/c ≈ 7.118 样本，alpha_i = i·45°（UCA，R=50mm）
//   表里的延时 D_i = D0 - k·cos(theta - alpha_i)，所以按正确角度读表后
//   8 路相位完全对齐，束和 = 8A（>>3 后回到 A）。
//
// 两个阶段，专门覆盖角度映射的"正/负"两个分支：
//   阶段 1：声源表内 -30° → 汇报 doa_deg = 150（正角分支）
//            DUT_C=150（对） vs DUT_W=60（错，偏 90°）
//   阶段 2：声源表内 +60° → 汇报 doa_deg = -120（负角分支）
//            DUT_C=-120（对） vs DUT_W=150（错，表内 -30°，偏 90°）
//   （注：错角必须选"偏 90°"的对称位置。UCA 在 150° 这种大偏角上仍有栅瓣响应，
//     错角随便选会让压制比不足，那是阵列方向图特性，不是模块 bug。）
//   判据（两阶段都成立才算 PASS）：
//     RMS(对) ≈ A/√2，且 RMS(对) ≥ 3×RMS(错)。
//   若角度映射正负分支写反，对应阶段的"对"会变压制、"错"会变增强 → FAIL。
// ============================================================
module bf_audio_out_tb;

    reg clk = 0;
    reg rst_n = 0;
    reg [127:0] sample_data = 128'd0;
    reg sample_valid = 0;
    reg signed [8:0] doa_c = 9'sd150;
    reg signed [8:0] doa_w = 9'sd60;

    wire [15:0] c_tdata, w_tdata;
    wire        c_tvalid, c_tlast, w_tvalid, w_tlast;

    bf_audio_out #(
        .FRAME_LEN (256)            // 仿真缩短帧长，便于看 tlast
    ) dut_c (
        .clk (clk), .rst_n (rst_n),
        .sample_data (sample_data), .sample_valid (sample_valid),
        .doa_deg (doa_c),
        .m_axis_tdata (c_tdata), .m_axis_tvalid (c_tvalid),
        .m_axis_tready (1'b1), .m_axis_tlast (c_tlast)
    );

    bf_audio_out #(
        .FRAME_LEN (256)
    ) dut_w (
        .clk (clk), .rst_n (rst_n),
        .sample_data (sample_data), .sample_valid (sample_valid),
        .doa_deg (doa_w),
        .m_axis_tdata (w_tdata), .m_axis_tvalid (w_tvalid),
        .m_axis_tready (1'b1), .m_axis_tlast (w_tlast)
    );

    always #10 clk = ~clk;

    // ---- 统计窗口：en=1 时累计（每阶段预热 64 个样本后开 en）----
    reg en = 0;
    integer c_n = 0, w_n = 0;
    real    c_sq = 0.0, w_sq = 0.0;
    integer c_last_cnt = 0;
    integer warm = 0;

    always @(posedge clk) begin
        if (c_tvalid) begin
            if (c_tlast) c_last_cnt = c_last_cnt + 1;
            if (warm >= 64 && en) begin
                c_sq = c_sq + $itor($signed(c_tdata)) * $itor($signed(c_tdata));
                c_n  = c_n + 1;
            end
        end
        if (w_tvalid && warm >= 64 && en) begin
            w_sq = w_sq + $itor($signed(w_tdata)) * $itor($signed(w_tdata));
            w_n  = w_n + 1;
        end
        if (sample_valid) warm = warm + 1;   // 每个 sample_valid 计一个样本（warm 只增不减，够用）
    end

    // ---- 源参数 ----
    real w, k, theta, alpha, ph;
    integer sv, n, i;
    integer sv2, n2;
    localparam integer NSAMP      = 700;
    localparam integer SAMPLE_GAP = 16;     // 模块每样本只需 3 拍流水，16 拍足够
    localparam real    AMP        = 12000.0;
    localparam real    RMS_TH     = 0.85 * 12000.0 / 1.41421356;

    real rms_c1, rms_w1, rms_c2, rms_w2;

    task send_source(input real th_deg, input integer nstart);
        integer j, ch;
        begin
            theta = th_deg * 3.14159265358979 / 180.0;
            for (j = 0; j < NSAMP; j = j + 1) begin
                for (ch = 0; ch < 8; ch = ch + 1) begin
                    alpha = ch * 2.0 * 3.14159265358979 / 8.0;
                    ph = w * ((nstart + j) - k * $cos(theta - alpha));
                    sv2 = $rtoi(AMP * $sin(ph));
                    sample_data[16*ch +: 16] = sv2[15:0];
                end
                sample_valid = 1;
                @(posedge clk);
                sample_valid = 0;
                repeat(SAMPLE_GAP-1) @(posedge clk);
            end
        end
    endtask

    initial begin
        w = 2.0 * 3.14159265358979 * 4000.0 / 48828.125;   // 4kHz
        k = 0.05 * 48828.125 / 343.0;                      // ≈ 7.118

        // ==================== 阶段 1：表内 -30°（汇报 150°）====================
        doa_c = 9'sd150;
        doa_w = 9'sd60;
        rst_n = 0; en = 0;
        repeat(20) @(posedge clk);
        rst_n = 1;
        en = 1;
        repeat(50) @(posedge clk);
        send_source(-30.0, 0);
        repeat(100) @(posedge clk);
        rms_c1 = $sqrt(c_sq / c_n);
        rms_w1 = $sqrt(w_sq / w_n);
        $display("阶段1 表内-30°: correct(150°)=%0.1f  wrong(60°)=%0.1f", rms_c1, rms_w1);

        // ==================== 阶段 2：表内 +60°（汇报 -120°）====================
        c_n = 0; w_n = 0; c_sq = 0.0; w_sq = 0.0; warm = 0; c_last_cnt = 0;
        doa_c = -9'sd120;
        doa_w = 9'sd150;
        rst_n = 0; en = 0;
        repeat(20) @(posedge clk);
        rst_n = 1;
        en = 1;
        repeat(50) @(posedge clk);
        send_source(60.0, 0);
        repeat(100) @(posedge clk);
        rms_c2 = $sqrt(c_sq / c_n);
        rms_w2 = $sqrt(w_sq / w_n);
        $display("阶段2 表内+60°: correct(-120°)=%0.1f  wrong(150°)=%0.1f", rms_c2, rms_w2);

        $display("--------------------------------------------------");
        $display("理论 RMS = A/sqrt2 = %0.1f；tlast 帧数(阶段2) = %0d（期望 ≈ %0d）",
                 AMP / 1.41421356, c_last_cnt, NSAMP / 256);
        $display("--------------------------------------------------");

        if (rms_c1 > RMS_TH && rms_c1 > 3.0*rms_w1 &&
            rms_c2 > RMS_TH && rms_c2 > 3.0*rms_w2)
            $display("PASS: 正/负角度分支都正确——相干增强、错误角度被压制、角度映射无误");
        else
            $display("FAIL: 至少一个阶段区分不足，检查角度映射或延时对齐");
        $finish;
    end

endmodule
