`timescale 1ns / 1ps
// ============================================================
// mat_inv_8x8.v —— 8x8 复数矩阵求逆（高斯-约当 + 部分主元），Q16.16
//
// 用途：MVDR 波束成形里求 R^-1（R = 8x8 Hermitian 协方差矩阵）。
//
// 【串行化版】2026-10 重写，解决 LUT 爆炸：
//   旧版把 14 个乘法器 + 12 路 128:1 读 mux 全做成并行组合逻辑，
//   一个 8x8 求逆吃了 28645 LUT（占 xc7z020 的 62%），导致布局卡死。
//   新版只保留 2 个读口 + 1 个复数乘法器，按状态分时复用，
//   资源降到 ~4K LUT，算法和接口完全不变（对外仍输出 R^-1）。
//
// 算法：把 [R | I] 增广成 8x16 的 B，做高斯-约当消元，最后右半就是 R^-1。
//   前向（col = 0..7）：
//     1) 部分主元：在 col..7 行里找 |B[p][col]|^2 最大的行 piv
//     2) 交换 col 行和 piv 行（逐元素 3 拍交换）
//     3) 归一化：r = 1/B[col][col]，然后 B[col][j] *= r（j=0..15）
//     4) 消元：i=col+1..7，f = B[i][col]，B[i][j] -= f*B[col][j]（j=0..15）
//   回代（bcol = 7..1）：i=0..bcol-1，g = B[i][bcol]，B[i][j] -= g*B[bcol][j]
//   结果：Minv[i][j] = B[i][8+j]
//
// 关键定点决策（来自 4c-2a 精度扫描的结论）：
//   - 条目 Q16.16（32bit：16 整数 + 16 小数），必须【四舍五入】不能用截断
//   - 归一化用「一次求倒数 + N 次复数乘」代替 N 次复数除
//   - 舍入：(x + 2^15) >>> 16（算术右移），与 complex_div 一致
//
// 接口（队友对接用 / 上一层的用法）：
//   1) start 拉一拍脉冲启动
//   2) 随后在 din_valid 拉高的 64 拍里，行优先喂入 8x8 矩阵（din_re/din_im，Q16.16）
//      —— 顺序：(0,0),(0,1)...(0,7),(1,0)...(7,7)
//   3) 等待 done（约 3000 拍；具体见 tb 实测）
//   4) done 之前会先有 dout_valid 拉高的 64 拍，行优先输出 R^-1（Q16.16）
//   要求：输入矩阵可逆（R 加了 sigma^2*I 后必然可逆）
// ============================================================
module mat_inv_8x8 #(
    parameter integer N  = 8,     // 矩阵阶数
    parameter integer W  = 32,    // 对外接口位宽 Q16.16（保持 32，与 cov_to_q16/steer_rom 一致）
    parameter integer IW = 28     // 内部存储/数据通路位宽 Q12.16（12 整数 + 16 小数）
                                  //   16 位小数不变 → 精度不变；12 位整数够（对角加载后
                                  //   矩阵中间值 ≤ ~256 << 2^11）。比 Q16.16 省 LUT。
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,        // 一拍脉冲启动
    input  wire                din_valid,    // 输入有效（共 64 拍）
    input  wire signed [W-1:0] din_re,       // 输入实部 (Q16.16)
    input  wire signed [W-1:0] din_im,       // 输入虚部 (Q16.16)
    output reg  signed [W-1:0] dout_re,      // 输出实部 (Q16.16)
    output reg  signed [W-1:0] dout_im,      // 输出虚部 (Q16.16)
    output reg                 dout_valid,   // 输出有效（共 64 拍）
    output reg                 dout_start,   // 输出突发前一拍拉高（给下游当 start 用）
    output reg                 done          // 求逆完成（一拍脉冲）
);

    // ---- 增广矩阵 B = [R | I]，8 行 x 16 列，复数 ----
    reg signed [IW-1:0] Bre [0:N-1][0:2*N-1];
    reg signed [IW-1:0] Bim [0:N-1][0:2*N-1];

    // 1.0 in Q16.16（= 2^16 = 65536），IW=28 位装得下（小数仍 16 位）
    localparam signed [IW-1:0] Q16_ONE = 65536;

    // ---- 状态机 ----
    localparam [3:0] S_IDLE = 4'd0,   // 等启动
                     S_LOAD = 4'd2,   // 载入 R + 置右半单位阵（64 拍，双写口）
                     S_PIV  = 4'd3,   // 选主元（串行扫 col..7 行）
                     S_SWAP = 4'd4,   // 交换行（每元素 3 拍）
                     S_RECIP= 4'd5,   // 启动复数除法器求 r = 1/B[col][col]
                     S_RECIPW=4'd6,   // 等除法器
                     S_NORM = 4'd7,   // B[col][j] *= r
                     S_ELIM_F=4'd8,   // 锁存 f = B[i][col]
                     S_ELIM = 4'd9,   // 前向消元 B[i][j] -= f*B[col][j]
                     S_BCK_F= 4'd10,  // 锁存 g = B[i][bcol]
                     S_BCK  = 4'd11,  // 回代 B[i][j] -= g*B[bcol][j]
                     S_OUTP = 4'd12,  // 输出前一拍
                     S_OUT  = 4'd13;  // 流式输出 R^-1

    reg [3:0] state;

    reg [5:0] li;                 // 载入/置单位阵计数 0..63
    reg [3:0] col;                // 当前列 0..7
    reg [3:0] i, j;               // 消元/回代的行、列
    reg [3:0] p, piv;             // 主元扫描行 / 选中行
    reg [3:0] bcol;               // 回代当前列
    reg [3:0] oi, oj;             // 输出行、列
    reg [1:0] swp;                // 行交换子步

    reg signed [63:0] maxmag;     // 主元扫描：当前最大 |.|^2
    reg signed [IW-1:0] f_re, f_im;   // 消元用 f = B[i][col]
    reg signed [IW-1:0] g_re, g_im;   // 回代用 g = B[i][bcol]
    reg signed [IW-1:0] r_re, r_im;   // 归一化用的倒数 r = 1/B[col][col]
    reg signed [IW-1:0] swa_re, swa_im; // 行交换暂存（读口 A 的值）
    reg signed [IW-1:0] swb_re, swb_im; // 行交换暂存（读口 B 的值）

    // ---- 复数除法器（求倒数）----
    reg                cd_start;
    reg  signed [W-1:0] cd_ar, cd_ai, cd_br, cd_bi;
    wire signed [W-1:0] cd_re, cd_im;
    wire                cd_done;

    complex_div u_cd (
        .clk(clk), .rst_n(rst_n),
        .start(cd_start),
        .ar(cd_ar), .ai(cd_ai), .br(cd_br), .bi(cd_bi),
        .quo_re(cd_re), .quo_im(cd_im), .done(cd_done)
    );

    // ---- 读口 A/B 地址（组合逻辑，由状态机直接驱动，无寄存延迟）----
    reg [3:0] ra_row, ra_col;
    reg [3:0] rb_row, rb_col;
    always @(*) begin
        ra_row = 4'd0; ra_col = 4'd0;
        rb_row = 4'd0; rb_col = 4'd0;
        case (state)
        S_PIV:    begin ra_row = p;    ra_col = col;            end
        S_SWAP:   begin ra_row = col;  ra_col = j; rb_row = piv; rb_col = j; end
        S_RECIP:  begin ra_row = col;  ra_col = col;            end
        S_NORM:   begin ra_row = col;  ra_col = j;              end
        S_ELIM_F: begin                               rb_row = i; rb_col = col;  end
        S_ELIM:   begin ra_row = col;  ra_col = j; rb_row = i;   rb_col = j;    end
        S_BCK_F:  begin                               rb_row = i; rb_col = bcol; end
        S_BCK:    begin ra_row = bcol; ra_col = j; rb_row = i;   rb_col = j;    end
        S_OUT:    begin ra_row = oi;   ra_col = N + oj;         end
        default:  begin end
        endcase
    end

    // ---- 读数据（组合）----
    wire signed [IW-1:0] ard = Bre[ra_row][ra_col];
    wire signed [IW-1:0] aid = Bim[ra_row][ra_col];
    wire signed [IW-1:0] brd = Bre[rb_row][rb_col];
    wire signed [IW-1:0] bid = Bim[rb_row][rb_col];

    // ---- 复数乘法器（唯一一个，分时复用）----
    //   被乘数 A = m，被乘数 B = 读口 A。p = m * B[读口A]
    reg signed [IW-1:0] m_re, m_im;
    always @(*) begin
        case (state)
        S_NORM: begin m_re = r_re; m_im = r_im; end   // 归一化：r * B[col][j]
        S_BCK:  begin m_re = g_re; m_im = g_im; end   // 回代：g * B[bcol][j]
        default:begin m_re = f_re; m_im = f_im; end   // 消元：f * B[col][j]
        endcase
    end

    // ---- Q16.16 四舍五入（舍入方式比位数重要：必须四舍五入，不能截断）----
    function signed [IW-1:0] rnd16;
        input signed [63:0] x;
        begin
            rnd16 = (x + 64'sd32768) >>> 16;   // 加 2^15 再算术右移 16（16 位小数不变）
        end
    endfunction

    wire signed [63:0] p_re = m_re*ard - m_im*aid;
    wire signed [63:0] p_im = m_re*aid + m_im*ard;

    // 乘积先四舍五入到 Q12.16（>>16，对齐二进制点），再加减。
    //   注意：p 是 Q24.32（32 位小数），B 是 Q12.16（16 位小数），直接相减会错位。
    wire signed [IW-1:0] prod_r = rnd16(p_re);
    wire signed [IW-1:0] prod_i = rnd16(p_im);
    wire use_norm = (state == S_NORM);
    wire signed [IW-1:0] res_r = use_norm ? prod_r : (brd - prod_r);   // 归一化 / 消元 / 回代
    wire signed [IW-1:0] res_i = use_norm ? prod_i : (bid - prod_i);

    // 主元扫描用的 |B[p][col]|^2（独立两个乘方，DSP 足够）
    wire signed [63:0] mag = ard*ard + aid*aid;

    integer rr, cc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            li <= 0; col <= 0; i <= 0; j <= 0; p <= 0; piv <= 0;
            bcol <= 0; oi <= 0; oj <= 0; swp <= 0;
            maxmag <= 0;
            f_re <= 0; f_im <= 0; g_re <= 0; g_im <= 0; r_re <= 0; r_im <= 0;
            swa_re <= 0; swa_im <= 0; swb_re <= 0; swb_im <= 0;
            cd_start <= 0; cd_ar <= 0; cd_ai <= 0; cd_br <= 0; cd_bi <= 0;
            dout_re <= 0; dout_im <= 0; dout_valid <= 0; dout_start <= 0; done <= 0;
            for (rr = 0; rr < N; rr = rr + 1)
                for (cc = 0; cc < 2*N; cc = cc + 1) begin
                    Bre[rr][cc] <= 0;
                    Bim[rr][cc] <= 0;
                end
        end else begin
            done       <= 1'b0;
            dout_valid <= 1'b0;
            dout_start <= 1'b0;
            cd_start   <= 1'b0;

            case (state)
            // ---------- 等启动 ----------
            S_IDLE: begin
                if (start) begin
                    li    <= 6'd0;
                    state <= S_LOAD;
                end
            end

            // ---------- 载入 R + 置右半单位阵（同一拍双写，和原版时序一致）----------
            S_LOAD: begin
                if (din_valid) begin
                    Bre[li[5:3]][li[2:0]] <= din_re[IW-1:0];
                    Bim[li[5:3]][li[2:0]] <= din_im[IW-1:0];
                    if (li[5:3] == li[2:0]) begin
                        Bre[li[5:3]][N + li[2:0]] <= Q16_ONE;       // 1.0
                        Bim[li[5:3]][N + li[2:0]] <= {IW{1'b0}};
                    end else begin
                        Bre[li[5:3]][N + li[2:0]] <= {IW{1'b0}};
                        Bim[li[5:3]][N + li[2:0]] <= {IW{1'b0}};
                    end
                    if (li == 6'd63) begin
                        col    <= 4'd0;
                        p      <= 4'd0;
                        piv    <= 4'd0;
                        maxmag <= 64'sd0;
                        state  <= S_PIV;
                    end else begin
                        li <= li + 6'd1;
                    end
                end
            end

            // ---------- 选主元：串行扫 p = col..7，取 |B[p][col]|^2 最大 ----------
            S_PIV: begin
                if (mag > maxmag) begin
                    maxmag <= mag;
                    piv    <= p;
                end
                if (p == N-1) begin
                    j     <= 4'd0;
                    swp   <= 2'd0;
                    state <= S_SWAP;
                end else begin
                    p <= p + 4'd1;
                end
            end

            // ---------- 交换 col 行和 piv 行（每元素 3 拍）----------
            S_SWAP: begin
                if (piv == col) begin
                    // 主元已在当前行，无需交换
                    state <= S_RECIP;
                end else begin
                    case (swp)
                    2'd0: begin
                        swa_re <= ard; swa_im <= aid;   // 读口 A = B[col][j]
                        swb_re <= brd; swb_im <= bid;   // 读口 B = B[piv][j]
                        swp <= 2'd1;
                    end
                    2'd1: begin
                        Bre[col][j] <= swb_re; Bim[col][j] <= swb_im;
                        swp <= 2'd2;
                    end
                    2'd2: begin
                        Bre[piv][j] <= swa_re; Bim[piv][j] <= swa_im;
                        swp <= 2'd0;
                        if (j == 2*N-1) begin
                            state <= S_RECIP;
                        end else begin
                            j <= j + 4'd1;
                        end
                    end
                    endcase
                end
            end

            // ---------- 求倒数 r = 1/B[col][col]（复用 complex_div，a=1.0）----------
            S_RECIP: begin
                cd_ar   <= 32'sd65536;          // 1.0 in Q16.16
                cd_ai   <= 32'sd0;
                cd_br   <= {{(W-IW){ard[IW-1]}}, ard};
                cd_bi   <= {{(W-IW){aid[IW-1]}}, aid};
                cd_start <= 1'b1;
                state   <= S_RECIPW;
            end

            S_RECIPW: begin
                if (cd_done) begin
                    r_re  <= cd_re[IW-1:0];
                    r_im  <= cd_im[IW-1:0];
                    j     <= 4'd0;
                    state <= S_NORM;
                end
            end

            // ---------- 归一化：B[col][j] *= r ----------
            S_NORM: begin
                Bre[col][j] <= res_r;
                Bim[col][j] <= res_i;
                if (j == 2*N-1) begin
                    j <= 4'd0;
                    if (col == N-1) begin
                        // 最后一列，无消元，直接进回代
                        bcol  <= N-1;
                        i     <= 4'd0;
                        state <= S_BCK_F;
                    end else begin
                        i     <= col + 4'd1;
                        state <= S_ELIM_F;
                    end
                end else begin
                    j <= j + 4'd1;
                end
            end

            // ---------- 锁存消元因子 f = B[i][col] ----------
            S_ELIM_F: begin
                f_re  <= brd;
                f_im  <= bid;
                j     <= 4'd0;
                state <= S_ELIM;
            end

            // ---------- 前向消元：i=col+1..7，B[i][j] -= f*B[col][j] ----------
            S_ELIM: begin
                Bre[i][j] <= res_r;
                Bim[i][j] <= res_i;
                if (j == 2*N-1) begin
                    j <= 4'd0;
                    if (i == N-1) begin
                        // 本列消元完，进入下一列
                        col    <= col + 4'd1;
                        p      <= col + 4'd1;
                        piv    <= col + 4'd1;
                        maxmag <= 64'sd0;
                        state  <= S_PIV;
                    end else begin
                        i     <= i + 4'd1;
                        state <= S_ELIM_F;
                    end
                end else begin
                    j <= j + 4'd1;
                end
            end

            // ---------- 锁存回代因子 g = B[i][bcol] ----------
            S_BCK_F: begin
                g_re  <= brd;
                g_im  <= bid;
                j     <= 4'd0;
                state <= S_BCK;
            end

            // ---------- 回代：bcol=7..1，i=0..bcol-1，B[i][j] -= g*B[bcol][j] ----------
            S_BCK: begin
                Bre[i][j] <= res_r;
                Bim[i][j] <= res_i;
                if (j == 2*N-1) begin
                    j <= 4'd0;
                    if (i + 4'd1 >= bcol) begin
                        // 本列所有行处理完
                        if (bcol <= 4'd1) begin
                            oi    <= 4'd0;
                            oj    <= 4'd0;
                            state <= S_OUTP;
                        end else begin
                            bcol  <= bcol - 4'd1;
                            i     <= 4'd0;
                            state <= S_BCK_F;
                        end
                    end else begin
                        i     <= i + 4'd1;
                        state <= S_BCK_F;
                    end
                end else begin
                    j <= j + 4'd1;
                end
            end

            // ---------- 输出前一拍：拉 dout_start，通知下游准备接收 ----------
            S_OUTP: begin
                dout_start <= 1'b1;
                state      <= S_OUT;
            end

            // ---------- 流式输出 R^-1（右半 8x8，行优先 64 拍）----------
            S_OUT: begin
                dout_re    <= {{(W-IW){ard[IW-1]}}, ard};
                dout_im    <= {{(W-IW){aid[IW-1]}}, aid};
                dout_valid <= 1'b1;
                if (oj == N-1) begin
                    oj <= 4'd0;
                    if (oi == N-1) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end else begin
                        oi <= oi + 4'd1;
                    end
                end else begin
                    oj <= oj + 4'd1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
