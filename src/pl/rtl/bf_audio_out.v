`timescale 1ns / 1ps
// ============================================================
// bf_audio_out.v —— 波束成形干净音频输出（声源识别子系统给 PS 的输入）
//
// 作用：把 8 路原始采样按当前 DOA（MVDR 精测 doa_deg）做"分数延时求和"，
//   输出 1 路 16bit 单声道 48.828kHz 干净音频（AXI4-Stream），
//   供 PS 端做分类 CNN / 声纹。
//
// 与 das_scan_top 共用同一套 tap 表（das_taps_int.mem / das_taps_frac.mem）
// 和 2 抽头线性插值；区别是：
//   - 不扫 181 个角度，固定指向当前 doa_deg 一个方向（每样本波束成形）；
//   - 输出束和波形（而不是平方功率）。
//
// 定点：样本 16bit；插值 y 17bit；束和 Σ8 → 20bit；>>3 归一化（/8）→ 16bit。
//   （相干声源束和 ≈ 8A，>>3 后回到单麦尺度；噪声非相干和衰减，SNR 提升）
//
// 角度映射（必须与 das_scan_top / mvdr_sweep 的 180° 安装偏移严格反解）：
//   tap 表行 r 对应"表内角度" deg_tab = r*2 - 180（2° 步长，见 gen_das_taps.py）。
//   而 das_scan / mvdr_sweep 汇报给外部的 doa_deg 都做过 180° 安装偏移：
//       doa_deg = wrap(deg_tab + 180)   （>180 减 360）
//   所以要波束指向"汇报的那个方向"，必须先反解回 deg_tab 再查表：
//       doa_deg >= 0 → deg_tab = doa_deg - 180，r = deg_tab/2 + 90 = doa_deg/2
//       doa_deg <  0 → deg_tab = doa_deg + 180，r = deg_tab/2 + 90 = (doa_deg+360)/2
//   例：汇报 doa_deg=150° → deg_tab=-30° → r=75；汇报 0° → deg_tab=-180/180 → r=0/180
//   （r=0 与 r=180 是同一物理方向，抽头表两行完全相同）。
//   ⚠️ 若以后改了那两处 180° 偏移，这里必须同步改，否则声束会指向反方向。
//
// 输出（AXI4-Stream 主口，同步于 clk=50MHz）：
//   tdata[15:0] 单声道 16bit 有符号 PCM；tvalid 有数据；tready 背压；
//   tlast 每 FRAME_LEN 样本拉一拍（帧边界，供 PS 分块切 mel 谱）。
// ============================================================
module bf_audio_out #(
    parameter integer NCH        = 8,
    parameter integer DEPTH      = 64,     // 环形缓冲深度（6bit 索引）
    parameter integer W          = 16,     // 样本位宽
    parameter integer FRAME_LEN  = 1024,   // TLAST 帧长（样本数 ≈ 21ms）
    parameter integer FIFO_DEPTH = 64,     // 输出 FIFO 深度（吸收 DMA 背压）
    parameter TAPFILE_INT  = "das_taps_int.mem",
    parameter TAPFILE_FRAC = "das_taps_frac.mem"
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [NCH*W-1:0]  sample_data,   // 8×16bit，接 i2s_fft8_top 引出
    input  wire              sample_valid,  // 48.828kHz 1 拍脉冲
    input  wire signed [8:0] doa_deg,       // MVDR 精测角度 -180..180
    // ---- AXI4-Stream 主口：干净音频（16bit 单声道 @48.828kHz）----
    output wire [W-1:0]      m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,
    output wire              m_axis_tlast
);

    localparam integer NANG = 181;   // tap 表行数（-180..180，2° 步长）

    // ============ 环形缓冲：8 路独立分布式 RAM（与 das_scan 同款）============
    (* ram_style = "distributed" *) reg signed [W-1:0] mem0 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem1 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem2 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem3 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem4 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem5 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem6 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem7 [0:DEPTH-1];

    reg [5:0] wp;      // 写地址（DEPTH=64 → 6bit 自然回绕）
    reg [5:0] rbase;   // 最新样本地址

    // tap 表 ROM（int + frac，与 das_scan 共用同一套 .mem，只读 → 综合成 ROM）
    reg [NCH*6-1:0] tap_int  [0:NANG-1];
    reg [NCH*8-1:0] tap_frac [0:NANG-1];
    initial begin
        $readmemh(TAPFILE_INT,  tap_int);
        $readmemh(TAPFILE_FRAC, tap_frac);
    end

    // ---- 写侧：sample_valid 把 8 路打进当前 wp（不带复位，才能推断 RAM）----
    always @(posedge clk) begin
        if (sample_valid) begin
            mem0[wp] <= sample_data[0*W +: W];
            mem1[wp] <= sample_data[1*W +: W];
            mem2[wp] <= sample_data[2*W +: W];
            mem3[wp] <= sample_data[3*W +: W];
            mem4[wp] <= sample_data[4*W +: W];
            mem5[wp] <= sample_data[5*W +: W];
            mem6[wp] <= sample_data[6*W +: W];
            mem7[wp] <= sample_data[7*W +: W];
        end
    end

    // ---- wp / rbase 推进（同拍：rbase 锁到"写前的 wp"= 最新样本地址）----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp    <= 6'd0;
            rbase <= 6'd0;
        end else if (sample_valid) begin
            rbase <= wp;
            wp    <= wp + 1'b1;
        end
    end

    // ---- 组合读：按通道 + 地址读环形缓冲（分布式 RAM 异步读）----
    function signed [W-1:0] dl_rd;
        input [2:0] ch_sel;
        input [5:0] addr;
        begin
            case (ch_sel)
                3'd0: dl_rd = mem0[addr];
                3'd1: dl_rd = mem1[addr];
                3'd2: dl_rd = mem2[addr];
                3'd3: dl_rd = mem3[addr];
                3'd4: dl_rd = mem4[addr];
                3'd5: dl_rd = mem5[addr];
                3'd6: dl_rd = mem6[addr];
                default: dl_rd = mem7[addr];
            endcase
        end
    endfunction

    // ---- 当前 DOA：sample_valid 时锁一拍，保证 3 级流水线期间角度不变 ----
    reg signed [8:0] doa_reg;
    // doa_deg ∈ [-180,180] → tap 表行索引 r ∈ [0,180]（见文件头角度映射推导）
    wire signed [9:0] doa10   = {doa_reg[8], doa_reg};
    wire signed [9:0] r_idx10 = doa_reg[8] ? ((doa10 + 10'sd360) >>> 1)   // 负角：(doa+360)/2
                                           : (doa10 >>> 1);               // 非负：doa/2
    wire [8:0] ang_idx = r_idx10[8:0];

    // ---- 当前角度 ang_idx 的抽头：各读 1 个打包字，再按通道切位 ----
    wire [NCH*6-1:0] ti_word = tap_int [ang_idx];
    wire [NCH*8-1:0] tf_word = tap_frac[ang_idx];
    wire [5:0] ti0 = ti_word[0*6 +: 6];
    wire [5:0] ti1 = ti_word[1*6 +: 6];
    wire [5:0] ti2 = ti_word[2*6 +: 6];
    wire [5:0] ti3 = ti_word[3*6 +: 6];
    wire [5:0] ti4 = ti_word[4*6 +: 6];
    wire [5:0] ti5 = ti_word[5*6 +: 6];
    wire [5:0] ti6 = ti_word[6*6 +: 6];
    wire [5:0] ti7 = ti_word[7*6 +: 6];
    wire [7:0] tf0 = tf_word[0*8 +: 8];
    wire [7:0] tf1 = tf_word[1*8 +: 8];
    wire [7:0] tf2 = tf_word[2*8 +: 8];
    wire [7:0] tf3 = tf_word[3*8 +: 8];
    wire [7:0] tf4 = tf_word[4*8 +: 8];
    wire [7:0] tf5 = tf_word[5*8 +: 8];
    wire [7:0] tf6 = tf_word[6*8 +: 8];
    wire [7:0] tf7 = tf_word[7*8 +: 8];

    // ---- 各通道两个读地址：x0=较新（delay=int），x1=较旧（delay=int+1）----
    wire [5:0] a00 = (rbase - ti0)        & (DEPTH-1);
    wire [5:0] a01 = (rbase - ti0 - 1'b1) & (DEPTH-1);
    wire [5:0] a10 = (rbase - ti1)        & (DEPTH-1);
    wire [5:0] a11 = (rbase - ti1 - 1'b1) & (DEPTH-1);
    wire [5:0] a20 = (rbase - ti2)        & (DEPTH-1);
    wire [5:0] a21 = (rbase - ti2 - 1'b1) & (DEPTH-1);
    wire [5:0] a30 = (rbase - ti3)        & (DEPTH-1);
    wire [5:0] a31 = (rbase - ti3 - 1'b1) & (DEPTH-1);
    wire [5:0] a40 = (rbase - ti4)        & (DEPTH-1);
    wire [5:0] a41 = (rbase - ti4 - 1'b1) & (DEPTH-1);
    wire [5:0] a50 = (rbase - ti5)        & (DEPTH-1);
    wire [5:0] a51 = (rbase - ti5 - 1'b1) & (DEPTH-1);
    wire [5:0] a60 = (rbase - ti6)        & (DEPTH-1);
    wire [5:0] a61 = (rbase - ti6 - 1'b1) & (DEPTH-1);
    wire [5:0] a70 = (rbase - ti7)        & (DEPTH-1);
    wire [5:0] a71 = (rbase - ti7 - 1'b1) & (DEPTH-1);

    // ---- 各通道两级抽头样本（组合，第 0 级流水线输入）----
    wire signed [W-1:0] x00 = dl_rd(3'd0, a00);
    wire signed [W-1:0] x01 = dl_rd(3'd0, a01);
    wire signed [W-1:0] x10 = dl_rd(3'd1, a10);
    wire signed [W-1:0] x11 = dl_rd(3'd1, a11);
    wire signed [W-1:0] x20 = dl_rd(3'd2, a20);
    wire signed [W-1:0] x21 = dl_rd(3'd2, a21);
    wire signed [W-1:0] x30 = dl_rd(3'd3, a30);
    wire signed [W-1:0] x31 = dl_rd(3'd3, a31);
    wire signed [W-1:0] x40 = dl_rd(3'd4, a40);
    wire signed [W-1:0] x41 = dl_rd(3'd4, a41);
    wire signed [W-1:0] x50 = dl_rd(3'd5, a50);
    wire signed [W-1:0] x51 = dl_rd(3'd5, a51);
    wire signed [W-1:0] x60 = dl_rd(3'd6, a60);
    wire signed [W-1:0] x61 = dl_rd(3'd6, a61);
    wire signed [W-1:0] x70 = dl_rd(3'd7, a70);
    wire signed [W-1:0] x71 = dl_rd(3'd7, a71);

    // ---- 2 抽头线性插值：y = x0 + (frac·(x1-x0)) >> 8 ----
    function signed [16:0] interp;
        input signed [W-1:0] x0;
        input signed [W-1:0] x1;
        input        [7:0] f;
        reg signed [16:0] diff;
        reg signed [25:0] prod;
        begin
            diff  = {x1[W-1], x1} - {x0[W-1], x0};
            prod  = $signed({1'b0, f}) * diff;
            interp = {x0[W-1], x0} + prod[24:8];
        end
    endfunction

    // ============ 3 级流水线（与 das_scan 相同，打断长组合路径）============
    // S_IDLE 等 sample_valid；S_L0 锁 16 个延时线样本；S_L1 锁 8 路插值；
    // S_L2 束和 + 写 FIFO。每样本 3 拍 << 每样本 1024 拍预算。
    reg signed [W-1:0] qx00, qx01, qx10, qx11, qx20, qx21, qx30, qx31,
                       qx40, qx41, qx50, qx51, qx60, qx61, qx70, qx71;
    reg signed [16:0]  qy0, qy1, qy2, qy3, qy4, qy5, qy6, qy7;

    // 第 1 级输出 → 插值（第 2 级输入）
    wire signed [16:0] y0 = interp(qx00, qx01, tf0);
    wire signed [16:0] y1 = interp(qx10, qx11, tf1);
    wire signed [16:0] y2 = interp(qx20, qx21, tf2);
    wire signed [16:0] y3 = interp(qx30, qx31, tf3);
    wire signed [16:0] y4 = interp(qx40, qx41, tf4);
    wire signed [16:0] y5 = interp(qx50, qx51, tf5);
    wire signed [16:0] y6 = interp(qx60, qx61, tf6);
    wire signed [16:0] y7 = interp(qx70, qx71, tf7);

    // 第 2 级输出 → 束和（第 3 级）
    wire signed [19:0] s0 = {{3{qy0[16]}}, qy0};
    wire signed [19:0] s1 = {{3{qy1[16]}}, qy1};
    wire signed [19:0] s2 = {{3{qy2[16]}}, qy2};
    wire signed [19:0] s3 = {{3{qy3[16]}}, qy3};
    wire signed [19:0] s4 = {{3{qy4[16]}}, qy4};
    wire signed [19:0] s5 = {{3{qy5[16]}}, qy5};
    wire signed [19:0] s6 = {{3{qy6[16]}}, qy6};
    wire signed [19:0] s7 = {{3{qy7[16]}}, qy7};
    wire signed [19:0] beam      = s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7;
    wire signed [15:0] beam_norm = beam >>> 3;   // /8 归一化 → 单麦尺度 16bit

    localparam [1:0] S_IDLE = 2'd0, S_L0 = 2'd1, S_L1 = 2'd2, S_L2 = 2'd3;
    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            doa_reg <= 9'sd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (sample_valid) begin
                    doa_reg <= doa_deg;   // 锁角度，流水线期间不变
                    state   <= S_L0;
                end
            end
            S_L0: begin
                qx00 <= x00; qx01 <= x01;
                qx10 <= x10; qx11 <= x11;
                qx20 <= x20; qx21 <= x21;
                qx30 <= x30; qx31 <= x31;
                qx40 <= x40; qx41 <= x41;
                qx50 <= x50; qx51 <= x51;
                qx60 <= x60; qx61 <= x61;
                qx70 <= x70; qx71 <= x71;
                state <= S_L1;
            end
            S_L1: begin
                qy0 <= y0; qy1 <= y1; qy2 <= y2; qy3 <= y3;
                qy4 <= y4; qy5 <= y5; qy6 <= y6; qy7 <= y7;
                state <= S_L2;
            end
            S_L2: state <= S_IDLE;
            default: state <= S_IDLE;
            endcase
        end
    end

    // ============ 输出 FIFO（组合读分布式 RAM，FWFT）+ AXI4-Stream ============
    localparam integer AW = $clog2(FIFO_DEPTH);
    (* ram_style = "distributed" *) reg [W-1:0] fifo [0:FIFO_DEPTH-1];
    reg [AW:0] wptr, rptr;
    wire full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    wire empty = (wptr == rptr);
    wire beam_valid = (state == S_L2);
    wire wr = beam_valid && !full;
    wire rd = m_axis_tvalid && m_axis_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 0;
            rptr <= 0;
        end else begin
            if (wr) begin
                fifo[wptr[AW-1:0]] <= beam_norm;
                wptr <= wptr + 1'b1;
            end
            if (rd)
                rptr <= rptr + 1'b1;
        end
    end

    assign m_axis_tdata  = fifo[rptr[AW-1:0]];
    assign m_axis_tvalid = !empty;

    // TLAST：每 FRAME_LEN 个样本拉一拍（与该样本 tvalid 同拍）
    reg [$clog2(FRAME_LEN)-1:0] frame_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_cnt <= 0;
        else if (rd) begin
            if (frame_cnt == FRAME_LEN-1)
                frame_cnt <= 0;
            else
                frame_cnt <= frame_cnt + 1'b1;
        end
    end
    assign m_axis_tlast = rd && (frame_cnt == FRAME_LEN-1);

endmodule
