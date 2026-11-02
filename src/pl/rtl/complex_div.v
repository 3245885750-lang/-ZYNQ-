`timescale 1ns / 1ps
// ============================================================
// complex_div.v —— Q16.16 定点复数除法 q = a/b
//
// 算法：q = a·conj(b)/|b|²
//   n  = a·conj(b) = (ar·br+ai·bi) + j·(ai·br−ar·bi)   Q32.32 (64bit)
//   d  = |b|² = br²+bi²                                   (64bit 正数)
//   q_re = round(n_re·2^16 / d)  —— 四舍五入（不能截断！）
//   q_im = round(n_im·2^16 / d)
//
// 硬件：恢复余数除法器（64bit÷64bit），re、im 串行，共 ~130 拍。
//   四舍五入做法：被除数先加 d/2 再整除 = round(n·2^16/d)。
//   符号：先对 |n| 做正数除法，最后按 n 的符号取反。
//
// 接口（队友对接用）：
//   start 一拍脉冲启动 → 约 130 拍后 done 一拍脉冲，quo_re/quo_im 有效并保持到下次 start。
//   要求 b≠0（8×8 求逆里主元经部分主元选取，永远不为 0）。
// ============================================================
module complex_div #(
    parameter integer W = 32    // Q16.16：16 整数 + 16 小数
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,       // 一拍脉冲启动
    input  wire signed [W-1:0] ar, ai,   // a = ar + j·ai
    input  wire signed [W-1:0] br, bi,   // b = br + j·bi（b≠0）
    output reg  signed [W-1:0] quo_re, quo_im,   // q = a/b（Q16.16）
    output reg              done         // 一拍脉冲完成
);

    localparam [1:0] S_IDLE = 2'd0, S_DIV = 2'd1, S_CAP = 2'd2;

    reg [1:0]    state;
    reg          ph;               // 0=正在算 re，1=正在算 im
    reg [6:0]    cnt;              // 恢复余数除法计数 0..63
    reg [2*W-1:0] d_r;             // |b|²（锁存）
    reg [2*W-1:0] mag_re, mag_im;  // |n_re|、|n_im|
    reg [2*W-1:0] num;             // 当前被除数（已加舍入偏置 d/2）
    reg [2*W-1:0] rem, quot;       // 恢复余数除法器：余数、商
    reg          s_re, s_im;       // 商符号
    reg signed [W-1:0] q_re;       // re 结果暂存

    // 组合：n = a·conj(b)，d = |b|²
    wire signed [2*W-1:0] n_re = ar*br + ai*bi;
    wire signed [2*W-1:0] n_im = ai*br - ar*bi;
    wire [2*W-1:0]        d_w  = br*br + bi*bi;

    // 恢复余数一步的组合输入：余数左移并移入 num 的当前位（MSB 先）
    wire [2*W-1:0] rem_shift = (rem << 1) | num[2*W-1 - cnt];
    wire           rem_ge    = (rem_shift >= d_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            ph     <= 0;
            cnt    <= 0;
            done   <= 1'b0;
            d_r    <= 0;
            mag_re <= 0; mag_im <= 0;
            num    <= 0;
            rem    <= 0; quot <= 0;
            s_re   <= 0; s_im <= 0;
            q_re   <= 0;
            quo_re <= 0; quo_im <= 0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        d_r    <= d_w;
                        s_re   <= n_re[2*W-1];
                        s_im   <= n_im[2*W-1];
                        mag_re <= n_re[2*W-1] ? (~n_re + 1'b1) : n_re;
                        mag_im <= n_im[2*W-1] ? (~n_im + 1'b1) : n_im;
                        // re 的被除数：|n_re|·2^16 + d/2（四舍五入偏置）
                        num    <= ((n_re[2*W-1] ? (~n_re + 1'b1) : n_re) << 16) + (d_w >> 1);
                        ph     <= 0; cnt <= 0; rem <= 0; quot <= 0;
                        state  <= S_DIV;
                    end
                end

                S_DIV: begin
                    if (rem_ge) begin
                        rem  <= rem_shift - d_r;
                        quot <= (quot << 1) | 1'b1;
                    end else begin
                        rem  <= rem_shift;
                        quot <= (quot << 1);
                    end
                    if (cnt == 63)
                        state <= S_CAP;   // 等一拍让商稳定
                    else
                        cnt <= cnt + 1;
                end

                S_CAP: begin
                    if (ph == 0) begin
                        // re 完成：存结果，准备 im 的被除数
                        q_re <= s_re ? -$signed(quot[W-1:0]) : $signed(quot[W-1:0]);
                        num  <= (mag_im << 16) + (d_r >> 1);
                        ph   <= 1; cnt <= 0; rem <= 0; quot <= 0;
                        state <= S_DIV;
                    end else begin
                        // im 完成：输出结果
                        quo_re <= q_re;
                        quo_im <= s_im ? -$signed(quot[W-1:0]) : $signed(quot[W-1:0]);
                        state  <= S_IDLE;
                        done   <= 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
