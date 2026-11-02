`timescale 1ns / 1ps
// ============================================================
// cov_to_q16.v —— 「协方差 → 求逆」适配层
//
// 把 cov_accum_8x8 的输出（上三角 36 项、64bit 整数、幅度 ~2^52）
// 变成 mat_inv_8x8 要的（完整 8x8 Hermitian、Q16.16、行优先流式）。
//
// 做两件事：
//   1) 共轭展开：上三角 36 项 → 完整 8x8（R[j][i] = conj(R[i][j])）
//   2) 自适应归一化：扫出 max|元素|，把它右移到 ~1.0（Q16.16 的 65536）
//         shift = MSB(max) - 16
//      为什么可以随便缩放：MVDR 的 s(θ) = a^H R⁻¹ a 对 R 的整体尺度不敏感
//      （R → cR 时 R⁻¹ → R⁻¹/c，峰位不变），所以把最大值归一到 1 是免费的，
//      且任何音量下都不丢精度、不溢出。
//
// ⚠️ 资源优化（2026-10-01）：原来 max|元素| 用 always @(*) 对 72 个 64bit
//   值全并行求最大，综合成 ~24K LUT。改成串行扫描（每拍 1 项、共 NT 拍），
//   同一份 abs64 / 比较器逐拍复用，降到 ~1K LUT。
//
// 接口（接 cov_accum_8x8）：
//   start      ：一拍脉冲，表示协方差已就绪（接 cov_accum 的 rdone）
//   base       ：本 bin 36 项在协方差数组里的起始地址（bin*36），start 时需有效
//   rc_addr    ：读地址，接 cov_accum 的 rc_addr；S_LATCH 阶段按 base+0..35 逐项读
//   rc_re/rc_im：读数据（1 拍延迟），接 cov_accum 的 rc_re/rc_im
//   dout_*     ：Q16.16 输出，dout_valid 拉高 64 拍，行优先 (0,0)...(7,7)
//   shift_used ：本次实际右移位数（调试用；max 元素 ≈ 2^(16) 即 1.0）
//
// 延迟：约 NT+2(读 36 项) + NT(扫描) + 1(锁 shift) + 1(dout_start) + 64(输出) 拍
// ============================================================
module cov_to_q16 #(
    parameter integer N  = 8,    // 矩阵阶数
    parameter integer NT = 36,   // 上三角项数
    parameter integer AW = 64    // 输入位宽
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,
    input  wire [8:0]         base,      // 本 bin 36 项在协方差数组里的起始地址（bin*36）
    output reg  [8:0]         rc_addr,   // 读地址（S_LATCH 阶段驱动，接 cov_accum 的 rc_addr）
    input  wire [AW-1:0]      rc_re,     // 读数据实部（1 拍延迟）
    input  wire [AW-1:0]      rc_im,     // 读数据虚部（1 拍延迟）
    output reg  signed [31:0] dout_re,   // Q16.16 实部
    output reg  signed [31:0] dout_im,   // Q16.16 虚部
    output reg                dout_valid,
    output reg                dout_start,   // 数据突发前一拍拉高（给下游当 start 用）
    output reg                done,
    output reg  [5:0]         shift_used
);

    localparam S_IDLE = 3'd0, S_LATCH = 3'd1, S_MAX = 3'd2, S_SHIFT = 3'd3, S_OUTP = 3'd4, S_OUT = 3'd5;
    reg [2:0] state;

    // ---- 锁存的上三角（避免依赖输入保持）----
    reg signed [AW-1:0] up_re [0:NT-1];
    reg signed [AW-1:0] up_im [0:NT-1];

    reg [5:0] cnt;         // 输出计数 0..63
    reg [5:0] mp;          // 扫描计数 0..NT-1
    reg [5:0] lc;          // S_LATCH 读计数 0..NT
    reg [AW-1:0] maxmag_r; // 串行扫描出的最大绝对值

    integer p;

    // ---- 绝对值 ----
    function [AW-1:0] abs64;
        input signed [AW-1:0] x;
        begin
            abs64 = x[AW-1] ? (~x + 1'b1) : x;
        end
    endfunction

    // ---- 最高有效位（优先编码器）----
    function [5:0] msb64;
        input [AW-1:0] v;
        integer bi2;
        begin
            msb64 = 6'd0;
            for (bi2 = 0; bi2 < AW; bi2 = bi2 + 1)
                if (v[bi2]) msb64 = bi2[5:0];
        end
    endfunction

    // ---- 上三角行偏移（与 cov_accum_8x8 一致）----
    function [5:0] roff;
        input [2:0] ii;
        begin
            case (ii)
                3'd0: roff = 6'd0;
                3'd1: roff = 6'd8;
                3'd2: roff = 6'd15;
                3'd3: roff = 6'd21;
                3'd4: roff = 6'd26;
                3'd5: roff = 6'd30;
                3'd6: roff = 6'd33;
                3'd7: roff = 6'd35;
                default: roff = 6'd0;
            endcase
        end
    endfunction

    // ---- 组合：第 cnt 个输出元素的上三角索引 ----
    wire [2:0] oi    = cnt[5:3];
    wire [2:0] oj    = cnt[2:0];
    wire       upper = (oi <= oj);                       // 取上三角还是共轭
    wire [5:0] pidx  = upper ? (roff(oi) + {3'd0, oj - oi})
                             : (roff(oj) + {3'd0, oi - oj});

    // ---- 读口合并：S_MAX 扫 mp、S_OUT 输出 pidx，两者分时复用同一个 36:1 mux ----
    // 原来 up_re[mp] 和 up_re[pidx] 各自生成一个 36:1 64bit mux（4 个），
    // 合二为一后只剩 2 个，省一半 LUT（时序不变，只是读地址多了个 2:1 选）。
    wire [5:0] rdidx = (state == S_MAX) ? mp : pidx;
    wire signed [AW-1:0] up_r = up_re[rdidx];
    wire signed [AW-1:0] up_i = up_im[rdidx];
    wire signed [AW-1:0] src_re = up_r;
    wire signed [AW-1:0] src_im = upper ? up_i : -up_i;

    // ---- 串行扫描：当前第 mp 项的绝对值，取 re/im 较大者 ----
    wire [AW-1:0] cand_re   = abs64(up_r);
    wire [AW-1:0] cand_im   = abs64(up_i);
    wire [AW-1:0] cand_best = (cand_re > cand_im) ? cand_re : cand_im;

    // ---- 组合：maxmag_r 对应的右移量 = MSB(max) - 16（<16 则不移动）----
    wire [5:0] msb_v   = msb64(maxmag_r);
    wire [5:0] shift_c = (msb_v > 6'd16) ? (msb_v - 6'd16) : 6'd0;

    // ---- 四舍五入右移 ----
    wire signed [AW-1:0] bias  = (shift_used == 6'd0) ? {AW{1'b0}}
                                                     : (64'sd1 <<< (shift_used - 6'd1));
    wire signed [AW-1:0] sh_re = (src_re + bias) >>> shift_used;
    wire signed [AW-1:0] sh_im = (src_im + bias) >>> shift_used;

    // ---- 对角加载（正则化）：R' = R + ε·I ----
    // 高信噪比时 R 接近秩 1（噪声特征值 λ≈0），定点求逆会把 1/λ 放大到
    // 溢出/发散 → DOA 乱跳。加 ε·I 把最小特征值抬到 ε，1/ε 就有限了。
    // ε 取主对角线（归一化后 ~1.0）的 ~1.5%：既远大于噪声特征值、又远小于
    // 信号特征值（~8），不影响 MVDR 零陷位置。想更稳就调大，想零陷更深就调小。
    localparam signed [31:0] DL = 32'sd1024;   // ε = 1024/65536 ≈ 0.015625
    wire signed [31:0] dout_re_c = (oi == oj) ? (sh_re[31:0] + DL) : sh_re[31:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cnt        <= 6'd0;
            mp         <= 6'd0;
            lc         <= 6'd0;
            rc_addr    <= 9'd0;
            maxmag_r   <= {AW{1'b0}};
            shift_used <= 6'd0;
            dout_re <= 0; dout_im <= 0;
            dout_valid <= 1'b0; dout_start <= 1'b0; done <= 1'b0;
            for (p = 0; p < NT; p = p + 1) begin
                up_re[p] <= {AW{1'b0}};
                up_im[p] <= {AW{1'b0}};
            end
        end else begin
            done       <= 1'b0;
            dout_valid <= 1'b0;
            dout_start <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    maxmag_r <= {AW{1'b0}};
                    mp       <= 6'd0;
                    lc       <= 6'd0;
                    rc_addr  <= base;      // 预热读 base+0
                    state    <= S_LATCH;
                end
            end

            // ---- 从 cov_accum 的 BRAM 顺序读 36 项（rc 口 1 拍延迟）----
            // lc=0 只预热（rc_addr=base 已由 S_IDLE 驱动）；lc=1..NT 每拍锁存
            // 一项 up_re[lc-1]（rc_re 正是上一拍 raddr 的读结果，天然对齐）。
            S_LATCH: begin
                if (lc > 0) begin
                    up_re[lc-1] <= $signed(rc_re);
                    up_im[lc-1] <= $signed(rc_im);
                end
                if (lc == NT) begin
                    state <= S_MAX;
                end else begin
                    // 下一拍读 base+lc+1，最后一步钳到 base+35 防越界（NT=36）
                    rc_addr <= base + {3'd0, (lc < NT-1) ? (lc + 6'd1) : 6'd35};
                    lc      <= lc + 6'd1;
                end
            end

            // ---- 串行扫 NT 项，逐拍更新 maxmag_r ----
            S_MAX: begin
                if (cand_best > maxmag_r)
                    maxmag_r <= cand_best;
                if (mp == NT-1)
                    state <= S_SHIFT;
                else
                    mp <= mp + 6'd1;
            end

            // ---- 扫描完，锁存右移量（此刻 maxmag_r 已含全部 NT 项）----
            S_SHIFT: begin
                shift_used <= shift_c;
                cnt        <= 6'd0;
                state      <= S_OUTP;
            end

            S_OUTP: begin
                dout_start <= 1'b1;        // 提前一拍通知下游（下游接 start）
                state      <= S_OUT;
            end

            S_OUT: begin
                dout_re    <= dout_re_c;
                dout_im    <= sh_im[31:0];
                dout_valid <= 1'b1;
                if (cnt == 6'd63) begin
                    state <= S_IDLE;
                    done  <= 1'b1;
                end else begin
                    cnt <= cnt + 6'd1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
