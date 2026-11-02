`timescale 1ns / 1ps
// ============================================================
// das_scan_top.v —— 时域延时求和（DAS）粗测核：宽带、快速
//   分数延时版：2 抽头线性插值 + 2° 步长扫角
//
// 作用：对 8 路原始采样做"分数延时求和"——每路延时拆成整数部分
//       （取环形缓冲相邻两级抽头）+ 分数部分（线性插值），串行扫
//       181 个角度（2° 步长，-180..+180），每 WIN 个样本输出一次粗
//       DOA（argmax 束功率）。
//
// 为什么升级分数延时：整数延时量化 1 样本 ≈ 3.6°，靠近 ±90°（端射）
//   sinθ 变平，量化误差被放大到 15°+（实测 D=+75 vs M=+90）。
//   2 抽头线性插值把延时量化降到 1/256 样本，去掉这种系统性偏置，
//   使 DAS 无偏、与 MVDR 接近。但 DAS 仍是延时求和（非超分辨），
//   分辨率受阵列孔径/波束宽度限制，是"粗"通道；精角度以 M 为准。
//
// 数据流：
//   sample_data[127:0]（8×16bit，接 i2s_fft8_top 引出的原始采样）
//     → 8 条环形缓冲（各 64 深）→ 每路读相邻两级抽头 + 线性插值
//     → 束和 → 平方 → 每角度功率累积 acc_pwr[ang] → 窗口满 argmax
//
// 【流水线】2026-10：原来每个角度在 1 拍内把「ROM→地址→RAM读→插值→
//   束和→平方→累加」整条链做掉，组合路径 33 级 ≈ 26ns，50MHz 下
//   WNS=-6.4ns 时序不收敛。现拆成 3 级流水线（每角度 3 拍）：
//     S_SCAN0：锁存延时线读出的 16 个样本（qx）
//     S_SCAN1：锁存 8 路插值结果（qy）
//     S_SCAN2：束和 + 平方 + 累加 acc_pwr
//   181 角 × 3 拍 = 543 拍 < 每样本 1024 拍预算，仍足够。
//
// tap 表（gen_das_taps.py 生成，两张表，每角度 1 行打包 8 通道 → 单读口 ROM）：
//   tap_int[ang][ch*6 +: 6]  = floor(D_i)，tap_frac[ang][ch*8 +: 8] = round(frac*256)
//   D_i = 16 - k·cos(θ-α_i)，k = 0.05m × 48828.125Hz / 343m/s ≈ 7.118，α_i=2πi/8
//   插值 y = x[int] + (frac·(x[int+1] - x[int])) >> 8
//
// 定点：样本 16bit 有符号；插值 y 17bit；束和 Σ8 → 20bit；平方 → 40bit；
//       累积 WIN=1024 → 48bit（值 ≤ 2^36×2^10 = 2^46，不溢出）。
// ============================================================
module das_scan_top #(
    parameter integer NCH     = 8,
    parameter integer NANG    = 181,    // 扫描角度数（2° 步长）
    parameter integer DEPTH   = 64,     // 环形缓冲深度（6bit 索引）
    parameter integer WIN     = 1024,   // 功率累积窗口（样本数）
    parameter integer W       = 16,     // 样本位宽
    parameter [31:0] PWR_TH  = 32'd0,  // 信号门限，与 das_pwr(=best_pwr[47:16]) 同尺度
    parameter TAPFILE_INT  = "das_taps_int.mem",   // 相对路径：.mem 必须 add 进工程（Add Sources）综合才找得到
    parameter TAPFILE_FRAC = "das_taps_frac.mem"
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [NCH*W-1:0]   sample_data,   // 8×16bit，接 i2s_fft8_top 引出端口
    input  wire               sample_valid,  // 48.828kHz 1 拍脉冲
    output reg  signed [8:0]  das_doa,       // 粗 DOA（-180..+180，2° 步长）
    output reg                das_done,      // 每 WIN 样本一拍脉冲（与 das_doa 同拍）
    output reg                das_sig,       // 有无信号（max 束功率 > 门限）
    output wire [31:0]        das_pwr        // 本窗口 max 束功率高 32 位（校准门限用）
);

    // ============ 环形缓冲：8 个独立分布式 RAM（每路读相邻两级 → 双读口）============
    // （复用 i2s_fft8_axis 的教训：8 个独立一维数组，别用二维/三维，避免多写口推断失败）
    (* ram_style = "distributed" *) reg signed [W-1:0] mem0 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem1 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem2 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem3 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem4 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem5 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem6 [0:DEPTH-1];
    (* ram_style = "distributed" *) reg signed [W-1:0] mem7 [0:DEPTH-1];

    reg [5:0] wp;      // 下一笔写地址（DEPTH=64 → 6bit 自然回绕）
    reg [5:0] rbase;   // 最新样本的地址（= 写前的 wp），扫角读参考

    // tap 表 ROM（int + frac 各一张，$readmemh 载入，之后只读 → 综合成 ROM）
    // 打包：一行 = 1 个角度，8 通道拼成 1 个宽字 → 单读口，省掉 8 读口的大 mux 树。
    //   bit[ch*6 +: 6] = 第 ch 通道整数部分；bit[ch*8 +: 8] = 第 ch 通道分数部分。
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
            rbase <= wp;          // 写前 wp = 最新样本地址
            wp    <= wp + 1'b1;   // 自然回绕 0..63
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

    reg [8:0] ang;   // 当前扫角索引 0..NANG-1

    // ---- 当前角度 ang 的抽头：各读 1 个打包字，再按通道切位 ----
    wire [NCH*6-1:0] ti_word = tap_int [ang];
    wire [NCH*8-1:0] tf_word = tap_frac[ang];
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

    // ---- 各通道两级抽头样本（组合，第 0 级流水线的输入）----
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
    // 等价于 y = (1-frac)·x0 + frac·x1，但少一半乘法（每路 1 个乘）。
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

    // ============ 流水线第 1 级：锁存延时线读出的 16 个样本 ============
    // 打断「ROM→地址→RAM 读 mux」与「插值」之间的组合路径。
    reg signed [W-1:0] qx00, qx01, qx10, qx11, qx20, qx21, qx30, qx31,
                       qx40, qx41, qx50, qx51, qx60, qx61, qx70, qx71;

    // ---- 用寄存器里的样本做插值（第 1 级的输出、第 2 级的输入）----
    // tf 由 ang 决定，ang 在 3 级流水线期间不变，故 tf 与锁存 qx 时一致。
    wire signed [16:0] y0 = interp(qx00, qx01, tf0);
    wire signed [16:0] y1 = interp(qx10, qx11, tf1);
    wire signed [16:0] y2 = interp(qx20, qx21, tf2);
    wire signed [16:0] y3 = interp(qx30, qx31, tf3);
    wire signed [16:0] y4 = interp(qx40, qx41, tf4);
    wire signed [16:0] y5 = interp(qx50, qx51, tf5);
    wire signed [16:0] y6 = interp(qx60, qx61, tf6);
    wire signed [16:0] y7 = interp(qx70, qx71, tf7);

    // ============ 流水线第 2 级：锁存 8 路插值结果 ============
    // 打断「插值」与「束和/平方/累加」之间的组合路径。
    reg signed [16:0] qy0, qy1, qy2, qy3, qy4, qy5, qy6, qy7;

    // ---- 束和 + 平方（第 2 级的输出，直接进累加器）----
    // 先符号扩展到 20bit 再相加（避免 Verilog 逐级 + 截断到 16bit 的坑）
    wire signed [19:0] s0 = {{3{qy0[16]}}, qy0};
    wire signed [19:0] s1 = {{3{qy1[16]}}, qy1};
    wire signed [19:0] s2 = {{3{qy2[16]}}, qy2};
    wire signed [19:0] s3 = {{3{qy3[16]}}, qy3};
    wire signed [19:0] s4 = {{3{qy4[16]}}, qy4};
    wire signed [19:0] s5 = {{3{qy5[16]}}, qy5};
    wire signed [19:0] s6 = {{3{qy6[16]}}, qy6};
    wire signed [19:0] s7 = {{3{qy7[16]}}, qy7};
    wire signed [19:0] beam    = s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7;
    wire signed [39:0] beam_sq = beam * beam;

    // ---- 每角度功率累积 + argmax + 状态机 ----
    // acc_pwr 用分布式 RAM 存（181×48bit ≈ 200 LUT），顺序清零（S_CLEAR 每拍清 1 个）。
    // 不能一次性 for 清零：那会逼 Vivado 用 FF + 181:1 大 mux 实现，181 项直接爆 LUT。
    (* ram_style = "distributed" *) reg signed [47:0] acc_pwr [0:NANG-1];
    reg signed [47:0] best_pwr;
    reg signed [8:0]  best_deg;
    reg [9:0] win_cnt;      // 0..WIN-1
    reg [8:0] cmp_cnt;      // argmax 比较计数 0..NANG-1
    reg [8:0] clear_cnt;    // S_CLEAR 顺序清零计数

    localparam [2:0] S_IDLE  = 3'd0,
                     S_SCAN0 = 3'd1,
                     S_SCAN1 = 3'd2,
                     S_SCAN2 = 3'd3,
                     S_DONE  = 3'd4,
                     S_OUT   = 3'd5,
                     S_CLEAR = 3'd6;
    reg [2:0] state;
    integer i;

    // 本窗口 max 束功率高 32 位（与 das_done/das_sig 同拍有效，供串口显示 + 校准门限）
    assign das_pwr = best_pwr[47:16];

    // 180° 安装偏移：ch0 实际装在板子最左（物理 φ=180°），把 DAS DOA 的 0° 参考转到板子最右。
    // best_deg ∈ [-180,180] → +180 → wrap 回 [-180,180]（>180 减 360）。
    wire signed [9:0] deg_shift_raw = {best_deg[8], best_deg} + 10'sd180;
    wire signed [9:0] deg_shift     = (deg_shift_raw > 10'sd180) ? (deg_shift_raw - 10'sd360) : deg_shift_raw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_CLEAR;   // 复位后先顺序清空 acc_pwr，再进第一窗口
            ang       <= 9'd0;
            win_cnt   <= 10'd0;
            cmp_cnt   <= 8'd0;
            clear_cnt <= 8'd0;
            best_pwr  <= 48'sd0;
            best_deg  <= -9'sd180;
            das_doa   <= 9'sd0;
            das_sig   <= 1'b0;
            das_done  <= 1'b0;
        end else begin
            das_done <= 1'b0;   // 默认清，只在 S_OUT 拉高一拍
            case (state)
            S_IDLE: begin
                if (sample_valid) begin
                    ang   <= 9'd0;
                    state <= S_SCAN0;
                end
            end

            // ---- 第 0 级：锁存 16 个延时线样本（打断 ROM/地址/RAM 读路径）----
            S_SCAN0: begin
                qx00 <= x00; qx01 <= x01;
                qx10 <= x10; qx11 <= x11;
                qx20 <= x20; qx21 <= x21;
                qx30 <= x30; qx31 <= x31;
                qx40 <= x40; qx41 <= x41;
                qx50 <= x50; qx51 <= x51;
                qx60 <= x60; qx61 <= x61;
                qx70 <= x70; qx71 <= x71;
                state <= S_SCAN1;
            end

            // ---- 第 1 级：锁存 8 路插值结果（打断插值路径）----
            S_SCAN1: begin
                qy0 <= y0; qy1 <= y1; qy2 <= y2; qy3 <= y3;
                qy4 <= y4; qy5 <= y5; qy6 <= y6; qy7 <= y7;
                state <= S_SCAN2;
            end

            // ---- 第 2 级：束和 + 平方 + 累加当前角度的束功率 ----
            S_SCAN2: begin
                acc_pwr[ang] <= acc_pwr[ang] + beam_sq;
                if (ang == NANG-1) begin
                    win_cnt <= win_cnt + 1'b1;
                    if (win_cnt == WIN-1) begin
                        // 窗口满：进 argmax
                        cmp_cnt  <= 9'd0;
                        best_pwr <= -48'sd1;   // 比任何非负功率都小
                        best_deg <= -9'sd180;
                        state    <= S_DONE;
                    end else begin
                        state <= S_IDLE;   // 回空闲等下一拍采样
                    end
                end else begin
                    ang   <= ang + 1'b1;
                    state <= S_SCAN0;   // 回到第 0 级，锁存新角度的样本
                end
            end

            S_DONE: begin
                if (acc_pwr[cmp_cnt] > best_pwr) begin
                    best_pwr <= acc_pwr[cmp_cnt];
                    best_deg <= ($signed({1'b0, cmp_cnt, 1'b0}) - 10'sd180);   // 2° 步长：deg = cmp_cnt*2 - 180
                end
                if (cmp_cnt == NANG-1)
                    state <= S_OUT;   // 多拍一让 best_deg 稳定后再输出
                else
                    cmp_cnt <= cmp_cnt + 1'b1;
            end

            S_OUT: begin
                das_doa   <= deg_shift[8:0];
                das_sig   <= (best_pwr[47:16] > PWR_TH);
                das_done  <= 1'b1;
                win_cnt   <= 10'd0;
                clear_cnt <= 9'd0;
                state     <= S_CLEAR;
            end

            S_CLEAR: begin
                // 每拍清 1 个角度（181 拍），保持单写口 → 分布式 RAM 推断
                acc_pwr[clear_cnt] <= 48'sd0;
                if (clear_cnt == NANG-1)
                    state <= S_IDLE;
                else
                    clear_cnt <= clear_cnt + 1'b1;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
