`timescale 1ns / 1ps
// ============================================================
// mvdr_axi_tb.v —— MVDR AXI 外壳验证（模拟 PS 侧行为）
//
// 这个 tb 扮演两个角色：
//   ① AXI4-Lite 主机（模拟队友 B 的 PS 程序）：写 CTRL.START、轮询 STATUS、读 DOA
//   ② AXI4-Stream 主机（模拟 FFT 输出）：连续发 8 通道 FFT 帧
//
// 【仿真长度技巧】真实一帧是 8ch x 512bin = 4096 拍，64 帧 = 26 万拍跑不动。
//   但 bin_extract_8ch 只是"bin_cnt 数到 43 就抓、遇 tlast 归零"，
//   所以每通道只发 44 个 bin 就够，一帧 352 拍，64 帧 = 22528 拍。
//
// 场景：声源 30 度、bin 43，每帧带随机噪声（否则 R 秩 1 不可逆）。
//
// ⚠️ 驱动/采样都在【下降沿】。
// ============================================================
module mvdr_axi_tb;

    localparam integer NCH   = 8;
    localparam integer NBIN  = 44;      // 每通道只发 44 个 bin（只到目标 bin 43）
    localparam integer K     = 64;

    real pi = 3.14159265358979323846;
    real c = 343.0;
    real Rr = 0.05;
    // 采样率 = 48828.125 Hz（50MHz/16/64 整数分频），f0≈4100.8Hz，与 ROM 一致
    real f0 = 43.0 * (50000000.0 / 16.0 / 64.0) / 512.0;
    real th_src = 30.0;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---- AXI4-Lite 信号 ----
    reg  [31:0] awaddr = 0;   reg awvalid = 0;  wire awready;
    reg  [31:0] wdata  = 0;   reg wvalid  = 0;  reg [3:0] wstrb = 4'hF;  wire wready;
    wire [1:0]  bresp;         wire bvalid;      reg bready = 0;
    reg  [31:0] araddr = 0;   reg arvalid = 0;  wire arready;
    wire [31:0] rdata;         wire [1:0] rresp; wire rvalid;             reg rready = 0;

    // ---- AXI4-Stream 信号 ----
    reg  [63:0] tdata  = 0;
    reg         tvalid = 0;
    reg         tready = 1'b1;   // 背压（现在为输入）：恒 ready；要测背压可临时拉低几拍验证不重复采样
    reg         tlast  = 0;

    mvdr_axi_top #(.TARGET_BIN(43), .K(K)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tready(tready), .s_axis_tlast(tlast)
    );

    // ================= AXI4-Lite 主机任务 =================
    task axi_write;
        input [31:0] addr, data;
        begin
            @(negedge clk);
            awaddr = addr; awvalid = 1'b1;
            wdata  = data; wvalid  = 1'b1; wstrb = 4'hF;
            @(negedge clk);            // 经过一个上升沿，AW/W 均被接收
            awvalid = 1'b0; wvalid = 1'b0;
            while (bvalid !== 1'b1) @(negedge clk);
            bready = 1'b1;
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr = addr; arvalid = 1'b1;
            @(negedge clk);
            arvalid = 1'b0;
            while (rvalid !== 1'b1) @(negedge clk);
            data = rdata;
            rready = 1'b1;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    // ================= AXI4-Stream 主机（连续发帧）=================
    real alpha [0:7];
    real ath_re [0:7], ath_im [0:7];
    integer base_re [0:7], base_im [0:7];
    integer seed = 32'h2468_ACE0;
    localparam integer NOISE_A = 700000;
    integer fr, ch, bn, ny;
    reg signed [23:0] tx_re, tx_im;
    real th, tau, ph;

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

    integer sent_frames;

    initial begin
        sent_frames = 0;
        for (ch = 0; ch < NCH; ch = ch + 1)
            alpha[ch] = 2.0 * pi * ch / NCH;
        steer(th_src);
        for (ch = 0; ch < NCH; ch = ch + 1) begin
            base_re[ch] = $rtoi(ath_re[ch] * 4194304.0);
            base_im[ch] = $rtoi(ath_im[ch] * 4194304.0);
        end

        // 等复位释放
        wait (rst_n === 1'b1);
        repeat (5) @(negedge clk);

        // 连续发足够多帧（覆盖 2 次完整测量还多）
        for (fr = 0; fr < 300; fr = fr + 1) begin
            for (ch = 0; ch < NCH; ch = ch + 1) begin
                for (bn = 0; bn < NBIN; bn = bn + 1) begin
                    if (bn == 43) begin
                        // 目标 bin：信号 + 噪声（24bit 有符号）
                        ny = $random(seed) % NOISE_A;
                        tx_re = base_re[ch] + ny;
                        ny = $random(seed) % NOISE_A;
                        tx_im = base_im[ch] + ny;
                    end else begin
                        tx_re = 24'sd0; tx_im = 24'sd0;   // 其它 bin 随便，反正不用
                    end
                    // tdata = {im24, 8'h0, re24, 8'h0}  对应 bin_extract 的取位
                    tdata  = {tx_im, 8'h00, tx_re, 8'h00};
                    tvalid = 1'b1;
                    tlast  = (bn == NBIN-1);
                    @(negedge clk);
                end
            end
            sent_frames = sent_frames + 1;
        end
        tvalid = 1'b0; tlast = 1'b0;
    end

    // ================= 主流程（模拟 PS 程序）=================
    integer poll, doa_i;
    reg [31:0] rd, ver, tbin, snapc, stat, doa_r;

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        $display("==============================================");
        $display("mvdr_axi_top: AXI wrapper check (tb plays the PS)");
        $display("source = %0.0f deg, bin 43, K = %0d snapshots", th_src, K);
        $display("==============================================");

        // --- 先读几个静态寄存器，验证读通道 ---
        axi_read(32'h1C, ver);
        axi_read(32'h18, tbin);
        $display("  VERSION    = 0x%08x", ver);
        $display("  TARGET_BIN = %0d", tbin);

        // --- 写 CTRL.START，启动一次测向 ---
        axi_write(32'h00, 32'h0000_0001);
        $display("  wrote CTRL.START = 1");

        // --- 轮询 STATUS，等 DONE ---
        poll = 0;
        axi_read(32'h04, stat);
        while (stat[1] !== 1'b1 && poll < 400000) begin
            @(negedge clk);
            axi_read(32'h04, stat);
            poll = poll + 1;
        end
        $display("  waited %0d polls, STATUS = 0x%08x (busy=%b done=%b)",
                 poll, stat, stat[0], stat[1]);

        if (stat[1] !== 1'b1) begin
            $display("RESULT: FAIL  (DONE never asserted)");
            $finish;
        end

        // --- 读结果 ---
        axi_read(32'h08, doa_r);
        axi_read(32'h14, snapc);
        axi_read(32'h10, rd);
        doa_i = $signed(doa_r);          // DOA 是有符号度
        $display("  SNAP_CNT   = %0d (expect %0d)", snapc, K);
        $display("  SHIFT_USED = %0d", rd);
        $display("  DOA        = %0d deg (source %0.0f)", doa_i, th_src);

        // --- 判定 ---
        if (snapc !== K) begin
            $display("RESULT: FAIL  (SNAP_CNT = %0d, expect %0d)", snapc, K);
        end else if (doa_i > 31 || doa_i < 29) begin
            $display("RESULT: FAIL  (DOA = %0d, expected 30)", doa_i);
        end else if (ver !== 32'h4D564452 || tbin !== 43) begin
            $display("RESULT: FAIL  (static register readback wrong: ver=0x%08x bin=%0d)", ver, tbin);
        end else begin
            $display("RESULT: PASS  (AXI wrapper works: PS can start it and read DOA)");
        end
        $finish;
    end

endmodule
