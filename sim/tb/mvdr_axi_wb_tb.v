`timescale 1ns / 1ps
// ============================================================
// mvdr_axi_wb_tb.v —— 宽带 MVDR AXI 外壳全链路验证（8 bin 融合 + EMA）
//
// 这个 tb 扮演两个角色：
//   ① AXI4-Lite 主机（模拟队友 B 的 PS 程序）：写 CTRL.START、轮询 STATUS、读 DOA
//   ② AXI4-Stream 主机（模拟 FFT 输出）：连续发 8 通道 FFT 帧，8 个目标 bin
//      （5/10/15/20/25/31/37/43）各放一个同源信号（几何 30°），其余 bin 为 0。
//
// 【仿真长度技巧】每通道只发 44 个 bin（覆盖到 bin43），一帧 352 拍。
//   8 bin 版后处理变长（8 次 cov_to_q16+mat_inv + 一次 8 bin 扫角 ≈ 24 万拍），
//   所以发 1000 帧（≈35 万拍）留足余量。
//
// 期望：几何 30° → 板子坐标系 -150°（DUT 内部有 180° 安装偏移）。
//   DOA 寄存器应读回 -150（±1°）。
//
// 注意：本 tb 例化的 mvdr_axi_top 内部 steer_rom 用 $readmemh 读
//   steer_re_bin5/10/15/20/25/31/37/43.mem（共 16 个文件），跑之前必须把
//   这些 .mem 都 add 进 Vivado 仿真文件列表（Add Sources），否则 ROM 全 0、DOA 恒 0。
//
// ⚠️ 驱动/采样都在【下降沿】。
// ============================================================
module mvdr_axi_wb_tb;

    localparam integer NCH   = 8;
    localparam integer NBIN  = 44;      // 每通道只发 44 个 bin（覆盖到 bin43）
    localparam integer K     = 64;
    localparam integer NB    = 8;

    real pi = 3.14159265358979323846;
    real c = 343.0;
    real Rr = 0.05;
    real th_src = 30.0;

    integer binlist [0:NB-1];
    real    fq   [0:NB-1];

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
    reg         tready = 1'b1;
    reg         tlast  = 0;

    mvdr_axi_top #(
        .BIN0(5), .BIN1(10), .BIN2(15), .BIN3(20),
        .BIN4(25), .BIN5(31), .BIN6(37), .BIN7(43),
        .K(K), .S(7)
    ) u_dut (
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
    integer base_re [0:NB-1][0:7], base_im [0:NB-1][0:7];   // 8 个 bin 的信号
    integer seed = 32'h2468_ACE0;
    localparam integer NOISE_A = 700000;
    integer fr, ch, bn, ny, bt;
    integer tx_re, tx_im;
    real th, ph, kRn;

    // binlist[b] 里是否放信号，若是返回 b+1，否则 0
    function integer bin_slot(input integer bnum);
        integer t;
        begin
            bin_slot = 0;
            for (t = 0; t < NB; t = t + 1)
                if (binlist[t] == bnum) bin_slot = t + 1;
        end
    endfunction

    task steer_all;
        input real th_deg;
        integer ii, bb2;
        begin
            th = th_deg * pi / 180.0;
            for (bb2 = 0; bb2 < NB; bb2 = bb2 + 1) begin
                kRn = 2.0 * pi * fq[bb2] * Rr / c;
                for (ii = 0; ii < NCH; ii = ii + 1) begin
                    ph = kRn * $cos(th - alpha[ii]);
                    base_re[bb2][ii] = $rtoi($cos(ph)  * 4194304.0);
                    base_im[bb2][ii] = $rtoi(-$sin(ph) * 4194304.0);
                end
            end
        end
    endtask

    integer slot;

    initial begin
        binlist[0] = 5;  binlist[1] = 10; binlist[2] = 15; binlist[3] = 20;
        binlist[4] = 25; binlist[5] = 31; binlist[6] = 37; binlist[7] = 43;
        for (bt = 0; bt < NB; bt = bt + 1)
            fq[bt] = binlist[bt] * (50000000.0 / 16.0 / 64.0) / 512.0;
        for (ch = 0; ch < NCH; ch = ch + 1)
            alpha[ch] = 2.0 * pi * ch / NCH;
        steer_all(th_src);

        // 等复位释放
        wait (rst_n === 1'b1);
        repeat (5) @(negedge clk);

        // 连续发足够多帧（覆盖累积 + 8 bin 后处理 + 扫角）
        for (fr = 0; fr < 1000; fr = fr + 1) begin
            for (ch = 0; ch < NCH; ch = ch + 1) begin
                for (bn = 0; bn < NBIN; bn = bn + 1) begin
                    slot = bin_slot(bn);
                    if (slot != 0) begin
                        ny = $random(seed) % NOISE_A;
                        tx_re = base_re[slot-1][ch] + ny;
                        ny = $random(seed) % NOISE_A;
                        tx_im = base_im[slot-1][ch] + ny;
                    end else begin
                        tx_re = 0; tx_im = 0;
                    end
                    // tdata = {im24, 8'h0, re24, 8'h0}  对应 bin_extract 的取位
                    tdata  = {tx_im[23:0], 8'h00, tx_re[23:0], 8'h00};
                    tvalid = 1'b1;
                    tlast  = (bn == NBIN-1);
                    @(negedge clk);
                end
            end
        end
        tvalid = 1'b0; tlast = 1'b0;
    end

    // ================= 主流程（模拟 PS 程序）=================
    integer poll, doa_i;
    reg [31:0] rd, ver, bins0, bins1, bins2, bins3, snapc, stat, doa_r;

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        $display("==============================================");
        $display("mvdr_axi_wb: wideband 8-bin MVDR AXI wrapper check");
        $display("source = %0.0f deg (geom), bins = 5/10/15/20/25/31/37/43, K = %0d", th_src, K);
        $display("==============================================");

        // --- 读静态寄存器 ---
        axi_read(32'h1C, ver);
        axi_read(32'h18, bins0);
        axi_read(32'h28, bins1);
        axi_read(32'h2C, bins2);
        axi_read(32'h30, bins3);
        $display("  VERSION    = 0x%08x", ver);
        $display("  BIN_LIST   = 0x%08x (expect 0x0000050A)", bins0);
        $display("  BIN_LIST2  = 0x%08x (expect 0x00000F14)", bins1);
        $display("  BIN_LIST3  = 0x%08x (expect 0x0000191F)", bins2);
        $display("  BIN_LIST4  = 0x%08x (expect 0x0000252B)", bins3);

        // --- 启动 ---
        axi_write(32'h00, 32'h0000_0001);
        $display("  wrote CTRL.START = 1");

        // --- 轮询 DONE ---
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
        doa_i = $signed(doa_r);
        $display("  SNAP_CNT   = %0d (expect %0d)", snapc, K);
        $display("  SHIFT_USED = %0d", rd);
        $display("  DOA        = %0d deg (expect -150 for geom 30)", doa_i);

        // --- 判定 ---
        if (snapc !== K) begin
            $display("RESULT: FAIL  (SNAP_CNT = %0d, expect %0d)", snapc, K);
        end else if (doa_i > -149 || doa_i < -151) begin
            $display("RESULT: FAIL  (DOA = %0d, expected -150)", doa_i);
        end else if (ver !== 32'h4D564452 ||
                     bins0 !== 32'h0000_050A || bins1 !== 32'h0000_0F14 ||
                     bins2 !== 32'h0000_191F || bins3 !== 32'h0000_252B) begin
            $display("RESULT: FAIL  (static register readback wrong)");
        end else begin
            $display("RESULT: PASS  (wideband 8-bin MVDR works through AXI)");
        end
        $finish;
    end

endmodule
