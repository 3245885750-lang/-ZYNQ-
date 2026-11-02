`timescale 1ns / 1ps
// ============================================================
// mvdr_axi_top.v —— MVDR 波束成形核的 AXI 外壳（给 PS/队友B 用）
//
// ┌────────────────────────────────────────────────────────────────┐
// │  PS 侧看这个模块只有两个口：                                      │
// │   ① AXI4-Lite 从机 —— 控制/状态寄存器（见下面寄存器映射）          │
// │   ② AXI4-Stream 从机 —— 喂 FFT 输出流（tdata={im[31:0],re[31:0]}）│
// └────────────────────────────────────────────────────────────────┘
//
// 内部数据流（宽带 MVDR · 8 bin 非相干融合 + 协方差遗忘因子 EMA）：
//   S_AXIS ─> bin_extract_8ch(8 bin) ─> cov_accum_8x8(8 套, EMA)
//          ─> cov_to_q16 ×1(复用, 8:1 R mux) ─> mat_inv_8x8 ×1(复用 8 次)
//          ─> mvdr_sweep(8 bin 融合) <─ steer_rom ×8
//
// 后处理分时复用：cov_to_q16 和 mat_inv 都只例化 1 份，串行跑 8 次
//   （bin0 → bin7），sweep 连续收 8 段逆矩阵后做融合扫角。瓶颈在攒快拍
//   （K 帧），串行求逆完全不影响 DOA 更新率。
//
// ============================ 寄存器映射 ============================
//  字地址(字节)  名称        属性   说明
//   0x00 (0)   CTRL        W     bit0=START(自清) 启动一次测向
//                                bit1=SOFT_RST(自清) 复位内部链路
//   0x04 (1)   STATUS      R     bit0=BUSY 忙, bit1=DONE(粘滞, 读 CTRL 启动时清)
//   0x08 (2)   DOA         R     估计角度，**有符号度**（-180..180，32bit 符号扩展）
//   0x0C (3)   S_MIN       R     对应最小 s_total 值（Q16.16 原始值，调试用）
//   0x10 (4)   SHIFT_USED  R     适配层本次右移量（调试用）
//   0x14 (5)   SNAP_CNT    R     已累积快拍数（0..K）
//   0x18 (6)   BIN_LIST    R     {16'd0, BIN0[7:0], BIN1[7:0]} 前两个频率 bin
//   0x1C (7)   VERSION     R     0x4D564452 = "MVDR"
//   0x20 (8)   DAS_DOA     R     DAS 快速粗 DOA（有符号度，~21ms 更新，宽带任意声音）
//   0x24 (9)   DAS_STATUS  R     bit0 = 有无信号（DAS 能量门限）
//   0x28 (10)  BIN_LIST2   R     {16'd0, BIN2[7:0], BIN3[7:0]}
//   0x2C (11)  BIN_LIST3   R     {16'd0, BIN4[7:0], BIN5[7:0]}
//   0x30 (12)  BIN_LIST4   R     {16'd0, BIN6[7:0], BIN7[7:0]}
//   0x34 (13)  PWR         R     MVDR 总能量 E（cov_pwr[47:16]，无信号≈0，门限用）
//
// ============================ PS 用法 ============================
//   1. 让 FFT 链路把 AXI4-Stream 接到本模块的 s_axis_*
//   2. 写 CTRL.START = 1
//   3. 轮询 STATUS.BUSY（约 K 帧后变 0），或等 DONE
//   4. 读 DOA 得到角度
//
// ⚠️ 已知限制（先记录，后续可改）：
//   - BIN0..BIN7 是编译期参数，运行期不可改
//   - AXI 时钟 = 核时钟（单时钟域）。若 PS 走独立时钟需加 CDC
//   - K 帧攒快拍决定 DOA 更新率；EMA 首个 DOA 约 63% 收敛，之后逐步趋稳
// ============================================================
module mvdr_axi_top #(
    parameter integer BIN0       = 5,    // 476.9Hz
    parameter integer BIN1       = 10,   // 953.7Hz
    parameter integer BIN2       = 15,   // 1430.5Hz
    parameter integer BIN3       = 20,   // 1907.4Hz
    parameter integer BIN4       = 25,   // 2384.3Hz
    parameter integer BIN5       = 31,   // 2956.6Hz
    parameter integer BIN6       = 37,   // 3528.8Hz
    parameter integer BIN7       = 43,   // 4100.8Hz
    parameter integer K          = 64,   // 协方差累积快拍数（EMA 下仍每 K 拍出一次 DOA）
    parameter integer NANG       = 361,  // 扫描角度数
    parameter integer XW         = 24,   // 每路谱位宽
    parameter integer NT         = 36,
    parameter integer AW         = 64,
    parameter integer NB         = 8,    // 频点数
    parameter integer S          = 7,    // 协方差遗忘因子：α = 1/2^S
    parameter integer AUTO_RUN   = 0     // 1 = 上电自动连续测向；0 = 等 PS 写 CTRL.START（队友B）
)(
    input  wire        clk,
    input  wire        rst_n,          // 低有效复位（接 AXI 的 aresetn）

    // ---------------- AXI4-Lite 从机：控制/状态 ----------------
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---------------- AXI4-Stream 从机：FFT 输出流 ----------------
    input  wire [63:0] s_axis_tdata,   // {imag[31:0], real[31:0]}
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tready,  // 输入：上游合并后的流 tready（=MVDR_tready & FIFO_tready），门控 bin_extract 采样
    input  wire        s_axis_tlast,

    // ---------------- 调试输出（无 PS/无 AXI 时，顶层用 LED 自检）----------------
    output wire signed [8:0] doa_deg,   // 最新一次 DOA（有符号度 -180..+180）
    output reg               doa_done,  // 一拍脉冲：与 doa_deg 同拍有效
    output wire [31:0]       pwr_out,   // 8 个目标 bin 的 8 路总能量（高 32 位），定门限用

    // ---------------- DAS 粗测结果输入（来自 das_scan_top，经 AXI 透传给 PS）----------------
    input  wire signed [8:0] das_doa,   // DAS 快速粗 DOA（-180..+180，~21ms 更新）
    input  wire [31:0]        das_seq_in, mvdr_seq_in, audio_dropped_in, audio_count_in,
    input  wire              das_sig    // DAS 有无信号
);

    // ================================================================
    // 1) AXI4-Lite 总线适配器
    // ================================================================
    wire        wr_en;
    wire [4:0]  wr_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_strb;
    wire [4:0]  rd_addr;
    reg  [31:0] rd_data;

    axi_lite_regs #(.ADDR_BITS(5)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    // ================================================================
    // 2) 软件复位 / 启动请求
    // ================================================================
    // core_start_ack 提前声明：下面 2) 的 always 块要用它（xvlog 要求先声明后用）
    reg start_req, soft_rst_r, core_start_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_req  <= 1'b0;
            soft_rst_r <= 1'b0;
        end else begin
            soft_rst_r <= 1'b0;                     // 默认自清
            if (wr_en && wr_addr == 5'd0 && wr_strb[0]) begin
                if (wr_data[0]) start_req  <= 1'b1;
                if (wr_data[1]) soft_rst_r <= 1'b1;
            end
            if (core_start_ack) start_req <= 1'b0;  // 控制器接管，清请求
        end
    end

    // 内部链路复位：AXI 复位 或 软件复位脉冲
    wire core_rst_n = rst_n & ~soft_rst_r;

    // ================================================================
    // 3) 控制状态机（累积快拍 → 跑链路 → 收结果）
    // ================================================================
    localparam S_IDLE = 2'd0, S_ACCUM = 2'd1, S_RUN = 2'd2;
    reg [1:0]  state;
    reg        busy, done_sticky;
    reg [7:0]  snap_cnt;
    reg signed [8:0]  doa_reg;
    reg signed [31:0] smin_reg;
    reg [5:0]  shift_reg;

    // 内部链路信号
    wire [NB*8*XW-1:0]  bx_re, bx_im;
    wire             bx_ready;
    wire [AW-1:0]  cov_rc_re, cov_rc_im;   // cov_accum 随机读口数据（64bit）
    wire [AW-1:0]  cov_pwr;                // cov_accum 迹 EMA（总功率，64bit）
    wire [8:0]     cq_rc_addr;             // cov_to_q16 → cov_accum 读地址
    wire             cov_rdone;
    wire signed [31:0] cq_re, cq_im;
    wire cq_valid, cq_start, cq_done;
    wire [5:0] cq_shift;
    wire signed [31:0] mi_re, mi_im;
    wire mi_valid, mi_start, mi_done;
    wire a_req;
    wire [8:0] a_ang;
    wire [NB-1:0] avalid;
    wire signed [NB*32-1:0] av_re, av_im;
    wire signed [31:0] s_out;
    wire s_valid;
    wire signed [8:0]  doa_w;
    wire signed [31:0] smin_w;
    wire mvdr_done;

    assign doa_deg = doa_reg;   // doa_reg 是既有寄存器，直接引出（doa_done 在下面 FSM 里驱动）

    // ================================================================
    // 目标 bin 能量 —— 用于"有无信号"门限
    //   cov_accum 的 pwr_out = 8 bin 对角线迹 Σ|X_i|² 的 EMA（纯实部，64bit）。
    // ================================================================
    reg [31:0] pwr_reg;
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n)
            pwr_reg <= 32'd0;
        else if (cov_rdone)
            pwr_reg <= cov_pwr[47:16];   // 取中间 32 位，噪声/弱信号都有区分度
    end
    assign pwr_out = pwr_reg;

    // 快拍有效：只在 S_ACCUM 阶段放行给协方差累积（S_RUN 期间丢弃，避免重启）
    wire xready_g = (state == S_ACCUM) & bx_ready;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done_sticky<= 1'b0;
            snap_cnt   <= 8'd0;
            doa_reg    <= 9'sd0;
            smin_reg   <= 32'sd0;
            shift_reg  <= 6'd0;
            core_start_ack <= 1'b0;
            doa_done       <= 1'b0;
        end else begin
            core_start_ack <= 1'b0;
            doa_done       <= 1'b0;   // 默认清，只在收结果那拍拉高
            case (state)
            S_IDLE: begin
                if (AUTO_RUN || start_req) begin
                    core_start_ack <= start_req; // 只有真来自 AXI 才回 ack
                    busy           <= 1'b1;
                    done_sticky    <= 1'b0;
                    snap_cnt       <= 8'd0;
                    state          <= S_ACCUM;
                end
            end

            S_ACCUM: begin
                if (xready_g)
                    snap_cnt <= snap_cnt + 8'd1;   // rdone 后离开 S_ACCUM，自然停在 K
                if (cov_rdone)                   // K 个快拍攒够，链路自动往下跑
                    state <= S_RUN;
            end

            S_RUN: begin
                if (mvdr_done) begin
                    doa_reg     <= doa_w;
                    smin_reg    <= smin_w;
                    shift_reg   <= cq_shift;
                    doa_done    <= 1'b1;        // 与 doa_reg 同一拍更新
                    done_sticky <= 1'b1;
                    if (AUTO_RUN) begin
                        snap_cnt <= 8'd0;       // 自动模式：马上开下一轮，从 0 重新累积
                        state    <= S_ACCUM;    // 不停机，连续测向（busy 保持 1）
                    end else begin
                        busy  <= 1'b0;          // AUTO_RUN=0 保持原行为；snap_cnt 保持 K 供 PS 读 0x14
                        state <= S_IDLE;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ================================================================
    // 3.5) 后处理序列 FSM：cov_to_q16/mat_inv 复用 8 次（bin0 → bin7 → sweep）
    //      phase 0..7 = 处理 bin phase（conv + inv），phase 8 = sweep 扫角
    // ================================================================
    reg [3:0] phase;      // 0..7 = 正在处理 bin phase；8 = sweep
    reg [2:0] conv_bin;   // 当前要转换的 bin（R mux 选择），每 conv_start 自增

    // conv_start：bin0 由 cov_rdone 启动；bin1..7 由上一个 inv 完成（mi_done）启动
    // （提前声明：下面 phase FSM 里要用它清 conv_bin，xvlog 要求先声明后用）
    wire conv_start = (cov_rdone && (phase == 4'd0)) || (mi_done && (phase < 4'd7));

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            phase    <= 4'd0;
            conv_bin <= 3'd0;
        end else begin
            case (phase)
            4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 5'd7:
                if (mi_done) phase <= phase + 4'd1;   // 本 bin 求逆完成，进下一个 bin
            5'd8:
                if (mvdr_done) phase <= 4'd0;         // sweep 融合完成，回初始
            default: phase <= 4'd0;
            endcase
            if (conv_start) conv_bin <= conv_bin + 3'd1;   // 8 次后自然绕回 0（3bit）
        end
    end

    // 本 bin 36 项在协方差 BRAM 里的起始地址（conv_bin*36），cov_to_q16 据此顺序读
    wire [8:0] conv_base = conv_bin * 9'd36;

    // 单份 cov_to_q16 → 单份 mat_inv：inv 直接吃 cov 的 cq 流，无需 mux
    wire inv_start     = cq_start;
    wire inv_din_valid = cq_valid;
    wire signed [31:0] inv_din_re = cq_re;
    wire signed [31:0] inv_din_im = cq_im;

    // sweep 在 bin0 求逆输出开始时就启动（连续收 8 段逆矩阵）
    wire sweep_start = mi_start && (phase == 4'd0);

    // ================================================================
    // 4) 内部链路实例化（宽带 8 bin）
    // ================================================================
    bin_extract_8ch #(.BIN0(BIN0), .BIN1(BIN1), .BIN2(BIN2), .BIN3(BIN3),
                      .BIN4(BIN4), .BIN5(BIN5), .BIN6(BIN6), .BIN7(BIN7),
                      .XW(XW), .NB(NB)) u_bin (
        .clk(clk), .rst_n(core_rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .X_re(bx_re), .X_im(bx_im),
        .ready(bx_ready)
    );

    cov_accum_8x8 #(.NCH(8), .XW(XW), .K(K), .AW(AW), .NT(NT), .NB(NB), .S(S)) u_cov (
        .clk(clk), .rst_n(core_rst_n),
        .X_re(bx_re), .X_im(bx_im),
        .xready(xready_g),
        .rc_addr(cq_rc_addr), .rc_re(cov_rc_re), .rc_im(cov_rc_im),
        .pwr_out(cov_pwr),
        .rdone(cov_rdone)
    );

    cov_to_q16 #(.N(8), .NT(NT), .AW(AW)) u_conv (
        .clk(clk), .rst_n(core_rst_n),
        .start(conv_start),
        .base(conv_base),
        .rc_addr(cq_rc_addr), .rc_re(cov_rc_re), .rc_im(cov_rc_im),
        .dout_re(cq_re), .dout_im(cq_im),
        .dout_valid(cq_valid), .dout_start(cq_start), .done(cq_done),
        .shift_used(cq_shift)
    );

    mat_inv_8x8 u_inv (
        .clk(clk), .rst_n(core_rst_n),
        .start(inv_start),
        .din_valid(inv_din_valid), .din_re(inv_din_re), .din_im(inv_din_im),
        .dout_re(mi_re), .dout_im(mi_im),
        .dout_valid(mi_valid), .dout_start(mi_start), .done(mi_done)
    );

    mvdr_sweep #(.N(8), .NANG(NANG), .NB(NB)) u_sweep (
        .clk(clk), .rst_n(core_rst_n),
        .start(sweep_start),
        .din_valid(mi_valid), .din_re(mi_re), .din_im(mi_im),
        .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid), .av_re(av_re), .av_im(av_im),
        .s_out(s_out), .s_valid(s_valid),
        .doa_deg(doa_w), .s_min(smin_w), .done(mvdr_done)
    );

    // ---- 8 份导向 ROM（bin5..bin43），各自 .mem，共享 a_req/a_ang ----
    wire       avalid0, avalid1, avalid2, avalid3, avalid4, avalid5, avalid6, avalid7;
    wire signed [31:0] av_re0, av_im0, av_re1, av_im1, av_re2, av_im2, av_re3, av_im3;
    wire signed [31:0] av_re4, av_im4, av_re5, av_im5, av_re6, av_im6, av_re7, av_im7;

    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin5.mem"), .IMFILE("steer_im_bin5.mem")) u_rom0 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid0), .av_re(av_re0), .av_im(av_im0)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin10.mem"), .IMFILE("steer_im_bin10.mem")) u_rom1 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid1), .av_re(av_re1), .av_im(av_im1)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin15.mem"), .IMFILE("steer_im_bin15.mem")) u_rom2 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid2), .av_re(av_re2), .av_im(av_im2)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin20.mem"), .IMFILE("steer_im_bin20.mem")) u_rom3 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid3), .av_re(av_re3), .av_im(av_im3)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin25.mem"), .IMFILE("steer_im_bin25.mem")) u_rom4 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid4), .av_re(av_re4), .av_im(av_im4)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin31.mem"), .IMFILE("steer_im_bin31.mem")) u_rom5 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid5), .av_re(av_re5), .av_im(av_im5)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin37.mem"), .IMFILE("steer_im_bin37.mem")) u_rom6 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid6), .av_re(av_re6), .av_im(av_im6)
    );
    steer_rom #(.NCH(8), .NANG(NANG),
                .REFILE("steer_re_bin43.mem"), .IMFILE("steer_im_bin43.mem")) u_rom7 (
        .clk(clk), .rst_n(core_rst_n), .a_req(a_req), .a_ang(a_ang),
        .avalid(avalid7), .av_re(av_re7), .av_im(av_im7)
    );

    // 打包成总线给 sweep（[7] = bin7，[0] = bin0）
    assign avalid = {avalid7, avalid6, avalid5, avalid4, avalid3, avalid2, avalid1, avalid0};
    assign av_re  = {av_re7,  av_re6,  av_re5,  av_re4,  av_re3,  av_re2,  av_re1,  av_re0};
    assign av_im  = {av_im7,  av_im6,  av_im5,  av_im4,  av_im3,  av_im2,  av_im1,  av_im0};

    // Commit the PS-visible result on the same edge as mvdr_seq_in advances.
    // The original doa_reg is still used by beamforming without added latency.
    reg signed [8:0] ps_doa;
    reg signed [31:0] ps_smin;
    reg [5:0] ps_shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ps_doa <= 0; ps_smin <= 0; ps_shift <= 0;
        end else if (doa_done) begin
            ps_doa <= doa_reg; ps_smin <= smin_reg; ps_shift <= shift_reg;
        end
    end
    // ================================================================
    // 5) 读数据 mux
    // ================================================================
    always @(*) begin
        case (rd_addr)
        5'd0:    rd_data = 32'd0;                              // 0x00 CTRL：只写，读回 0
        5'd1:    rd_data = {30'd0, done_sticky, busy};         // 0x04 STATUS
        5'd2:    rd_data = {{23{ps_doa[8]}}, ps_doa};          // 0x08 committed DOA
        5'd3:    rd_data = ps_smin;                           // 0x0C committed S_MIN
        5'd4:    rd_data = {26'd0, ps_shift};                  // 0x10 committed SHIFT
        5'd5:    rd_data = {24'd0, snap_cnt};                  // 0x14 SNAP_CNT
        5'd6:    rd_data = {16'd0, BIN0[7:0], BIN1[7:0]};      // 0x18 BIN_LIST
        5'd7:    rd_data = 32'h4D56_4452;                      // 0x1C VERSION "MVDR"
        5'd8:    rd_data = {{23{das_doa[8]}}, das_doa};         // 0x20 DAS_DOA（有符号度，快速粗测）
        5'd9:    rd_data = {31'd0, das_sig};                    // 0x24 DAS_STATUS（bit0=有无信号）
        5'd10:   rd_data = {16'd0, BIN2[7:0], BIN3[7:0]};      // 0x28 BIN_LIST2
        5'd11:   rd_data = {16'd0, BIN4[7:0], BIN5[7:0]};      // 0x2C BIN_LIST3
        5'd12:   rd_data = {16'd0, BIN6[7:0], BIN7[7:0]};      // 0x30 BIN_LIST4
        5'd13:   rd_data = pwr_reg;                           // 0x34 PWR（MVDR 总能量 E，门限用）
        5'd14: rd_data = das_seq_in;          // 0x38 DAS committed result count
        5'd15: rd_data = mvdr_seq_in;         // 0x3C MVDR committed result count
        5'd16: rd_data = audio_dropped_in;    // 0x40 saturating PCM drop count
        5'd17: rd_data = 32'h4155_4432;       // 0x44 interface tag "AUD2"
        5'd18: rd_data = audio_count_in;      // 0x48 PCM transferred to external FIFO
        default: rd_data = 32'd0;
        endcase
    end

endmodule
