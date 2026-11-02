`timescale 1ns / 1ps
// ============================================================
// cov_accum_8x8.v —— 8x8 复数协方差矩阵累积（MVDR 宽带前端）
//
// R = Σ_k X(k) X(k)^H，X(k) = 8 路复数谱（一个"快拍"）。
// R 是 Hermitian 矩阵（R[i][j] = conj(R[j][i])），只存上三角 36 项。
//
// 复数乘 X_i * conj(X_j)：
//   (Xre_i + j*Xim_i) * (Xre_j - j*Xim_j)
//   = (Xre_i*Xre_j + Xim_i*Xim_j) + j*(Xim_i*Xre_j - Xre_i*Xim_j)
//
// 宽带 MVDR 版：同时累积 8 个频率 bin 的协方差（BIN0..BIN7）。
//
// 遗忘因子滑动平均（EMA，自适应记忆）：
//   acc ← acc - (acc >>> shift) + m
//   有信号（sig_on=1）用慢速 S=7（α=1/128，记忆 ≈ 128 快拍，精度最高）；
//   信号消失（sig_on=0）切快速 SF=3（α=1/8，记忆 ≈ 8 快拍），拖尾快速忘掉。
//   累加器永不归零（只在复位清零），去掉块平均的边界阶跃，DOA 轨迹更顺滑。
//   稳态 acc ≈ m·2^S，与旧 K=128 块平均同尺度，下游 cov_to_q16 归一化不受影响。
//   sig_on 由快速能量 pwr_fast（固定 SF，与 pwr_acc 同尺度）过门限 TH_FAST 决定。
//   rdone 仍每 K 拍发一次（只是"该算一次 DOA"的信号）。
//
// 硬件：单个复数 MAC 串行算，每快拍先算 bin0 的 36 项、再 bin1 … 直到 bin7，
//   共 288 拍。快拍间隔（一帧 FFT 才出一个）远大于 288 拍，串行足够，资源最省。
//
// ⚠️ 资源优化（2026-10-18）：acc 原来是 2D 寄存器数组，MAC 里 acc[bin_idx][p]
//   是 288:1 的 64bit 组合 mux（约 9K LUT），外加一份 36K FF 的输出镜像（~288 个
//   写译码控制集 → slice 碎片化 → Place 30-487 失败）。改成扁平 BRAM（288 深 ×
//   64bit）+ 同步读后 mux 消失、镜像也删掉：
//   1) 输出改走随机读口（rc_addr 进、rc_re/rc_im 出，1 拍延迟），下游 cov_to_q16
//      在读阶段按地址逐项取 36 项，不再要 288:1 mux 也不要全量镜像。
//   2) BRAM 读-改-写有 1 拍延迟：本拍读 elem N，下一拍用延迟的乘积 m_d 和读结果
//      accm_rd 写回 elem N（写地址 waddr = 读地址延迟 1 拍，流水 1 拍）。
//   3) BRAM 无初值，用 warm 标志：首个快拍 acc 按 0 算（acc_eff=0），写回后
//      BRAM 才是有效值，之后 warm=1 正常读。省掉 288 拍清零状态机。
//   4) pwr_out = 8 bin 对角线迹 Σ|X_i|² 的 EMA，直接给门限，不再由下游从 R 对角
//      线求和。
//
// 接口：
//   X_re/X_im : 8 bin × 8 路谱打包，bin b 的第 ch 路 = X_re[(b*NCH+ch)*XW +: XW]
//   xready    : 一拍脉冲，表示 8 组 X 都是有效快拍
//   rc_addr   : 读地址 0..287；rc_re/rc_im = accm[rc_addr]（1 拍延迟，IDLE 时读）
//   pwr_out   : 迹 EMA（64bit）
//   rdone     : 一拍脉冲，K 个快拍累积完成（EMA 不重置累加器）
// ============================================================
module cov_accum_8x8 #(
    parameter integer NCH = 8,   // 通道数
    parameter integer XW  = 24,  // 输入谱位宽（有符号）
    parameter integer K   = 64,  // 累积快拍数（rdone 每 K 拍发一次）
    parameter integer AW  = 64,  // 累加器位宽
    parameter integer NT  = 36,  // 上三角项数 = NCH*(NCH+1)/2
    parameter integer NB  = 8,   // 频点数
    parameter integer S   = 7,   // 遗忘因子（有信号时）：α = 1/2^S
    parameter integer SF  = 3,   // 遗忘因子（无信号时）：α = 1/2^SF，拖尾快忘（须 SF < S）
    parameter [31:0] TH_FAST = 32'h40  // 快速能量门限（pwr_fast[47:16] 切片，与 PWR_TH 同尺度）
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [NB*NCH*XW-1:0]  X_re,   // 8 bin × 8 路谱实部（打包）
    input  wire [NB*NCH*XW-1:0]  X_im,   // 8 bin × 8 路谱虚部（打包）
    input  wire                  xready, // 快拍有效（一拍脉冲）
    // ---- 协方差随机读口（下游 cov_to_q16 在读阶段按地址逐项取 36 项）----
    input  wire [8:0]            rc_addr, // 读地址 0..287（IDLE 时 BRAM 读口跟随它）
    output wire [AW-1:0]         rc_re,   // accm_re[rc_addr]（1 拍延迟）
    output wire [AW-1:0]         rc_im,   // accm_im[rc_addr]（1 拍延迟）
    output wire [AW-1:0]         pwr_out, // 8 bin 总功率（对角线迹的 EMA，信号门限用）
    output reg                   rdone   // K 个快拍累积完成（一拍脉冲）
);

    // ---- 累加器：BRAM（MAC 读-改-写），输出走随机读口 rc（不再留全量镜像，省 ~36K FF）----
    (* ram_style = "block" *) reg signed [AW-1:0] accm_re [0:NB*NT-1];
    (* ram_style = "block" *) reg signed [AW-1:0] accm_im [0:NB*NT-1];
    reg signed [AW-1:0] accm_rd_re, accm_rd_im;   // BRAM 读结果（1 拍延迟）
    reg [8:0]  waddr;                             // 写地址 = 读地址延迟 1 拍
    reg        wr_en;                             // BRAM 写使能
    reg        warm;                              // 首个快拍前 BRAM 无效，acc 按 0 算
    reg signed [2*XW:0] m_re_d, m_im_d;           // 延迟 1 拍的乘积
    reg signed [AW-1:0] trace_sum;                // 本快拍对角线迹（Σ|X_i|²）
    reg signed [AW-1:0] pwr_acc;                  // 迹的 EMA（信号门限，自适应：有信号 S/无信号 SF）
    reg signed [AW-1:0] pwr_fast;                 // 快速迹 EMA（固定 SF，同尺度，测"信号在不在"）
    reg                 sig_on;                   // 1=有信号（慢速 S 保精度）；0=无信号（快速 SF 忘拖尾）
    reg signed [XW-1:0] Xl_re [0:NB-1][0:NCH-1];  // 快拍锁存
    reg signed [XW-1:0] Xl_im [0:NB-1][0:NCH-1];

    localparam [1:0] IDLE = 2'd0, MAC = 2'd1, TAIL = 2'd2;
    reg [1:0] state;
    reg [2:0] bin_idx;   // 当前算哪个 bin：0..7
    reg [3:0] i, j;      // 当前乘积项 (i, j)
    reg [5:0] p;         // 累加器地址 0..35（每 bin 内）
    reg [7:0] k;         // 已累积快拍数 0..K-1

    integer b, r;

    // 当前项乘积（组合逻辑）：X_i * conj(X_j)，按 bin_idx 选输入
    wire signed [XW-1:0] xi_re = Xl_re[bin_idx][i];
    wire signed [XW-1:0] xi_im = Xl_im[bin_idx][i];
    wire signed [XW-1:0] xj_re = Xl_re[bin_idx][j];
    wire signed [XW-1:0] xj_im = Xl_im[bin_idx][j];
    wire signed [2*XW:0] m_re = xi_re*xj_re + xi_im*xj_im;
    wire signed [2*XW:0] m_im = xi_im*xj_re - xi_re*xj_im;

    // BRAM 读地址：MAC 时 = 当前元素；其余状态 = 下游随机读口 rc_addr
    wire [8:0] raddr = (state == MAC) ? (bin_idx * 9'd36 + {3'd0, p}) : rc_addr;

    // EMA：acc ← acc - (acc >>> shift) + m；首个快拍 BRAM 无效，acc 按 0 算。shift 自适应（有信号 S/无信号 SF）。
    wire signed [AW-1:0] acc_eff_re = warm ? accm_rd_re : {AW{1'b0}};
    wire signed [AW-1:0] acc_eff_im = warm ? accm_rd_im : {AW{1'b0}};
    wire signed [AW-1:0] dec_re = sig_on ? (acc_eff_re >>> S) : (acc_eff_re >>> SF);
    wire signed [AW-1:0] dec_im = sig_on ? (acc_eff_im >>> S) : (acc_eff_im >>> SF);
    wire signed [AW-1:0] new_re = acc_eff_re - dec_re + m_re_d;
    wire signed [AW-1:0] new_im = acc_eff_im - dec_im + m_im_d;

    // 快速迹 EMA 下一步（与 pwr_acc 同尺度：输入放大 2^(S-SF)，稳态 = trace·2^S）
    wire signed [AW-1:0] pwr_fast_next = pwr_fast - (pwr_fast >>> SF) + (trace_sum << (S - SF));

    // 随机读口输出（1 拍延迟的 BRAM 读结果）；功率输出
    assign rc_re   = accm_rd_re;
    assign rc_im   = accm_rd_im;
    assign pwr_out = pwr_acc;

    // ---- BRAM 读写（写 waddr、读 raddr，简单双端口，读有 1 拍延迟）----
    always @(posedge clk) begin
        if (wr_en) begin
            accm_re[waddr] <= new_re;
            accm_im[waddr] <= new_im;
        end
        accm_rd_re <= accm_re[raddr];
        accm_rd_im <= accm_im[raddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            k       <= 0;
            rdone   <= 1'b0;
            wr_en   <= 1'b0;
            waddr   <= 0;
            warm    <= 1'b0;
            m_re_d  <= 0; m_im_d <= 0;
            trace_sum <= 0;
            pwr_acc   <= 0;
            pwr_fast  <= 0;
            sig_on    <= 1'b1;   // 复位默认有信号（慢速 S，等同旧行为），首快拍后自校正
            bin_idx <= 0; i <= 0; j <= 0; p <= 0;
            for (b = 0; b < NB; b = b + 1)
                for (r = 0; r < NCH; r = r + 1) begin
                    Xl_re[b][r] <= 0; Xl_im[b][r] <= 0;
                end
        end else begin
            rdone <= 1'b0;
            wr_en <= 1'b0;
            case (state)
                IDLE: begin
                    if (xready) begin
                        // 锁存本快拍的 8 组 8 路谱
                        for (b = 0; b < NB; b = b + 1)
                            for (r = 0; r < NCH; r = r + 1) begin
                                Xl_re[b][r] <= $signed(X_re[(b*NCH+r)*XW +: XW]);
                                Xl_im[b][r] <= $signed(X_im[(b*NCH+r)*XW +: XW]);
                            end
                        // EMA：不清累加器（只在复位清零）
                        trace_sum <= 0;      // 本快拍迹从 0 开始累积
                        bin_idx <= 0;
                        i <= 0; j <= 0; p <= 0;
                        state <= MAC;
                    end
                end
                MAC: begin
                    // 本拍读 elem N（raddr），下一拍写回 elem N（waddr=延迟的 raddr）。
                    // 第 0 拍 wr_en 仍为 0（来自 IDLE），只读不写，恰好省掉流水预热。
                    wr_en  <= 1'b1;
                    waddr  <= raddr;
                    m_re_d <= m_re; m_im_d <= m_im;
                    if (i == j) trace_sum <= trace_sum + m_re;   // 对角线 = |X_i|²，累进迹
                    // 推进 (i,j)：上三角行优先
                    if (j == NCH-1) begin
                        i <= i + 1;
                        j <= i + 1;
                    end else begin
                        j <= j + 1;
                    end
                    p <= p + 1;
                    if (p == NT-1) begin          // 本 bin 36 项算完
                        if (bin_idx < NB-1) begin
                            bin_idx <= bin_idx + 1'b1;   // 接着算下一个 bin
                            i <= 0; j <= 0; p <= 0;
                        end else begin
                            state <= TAIL;              // 最后一个元素下一拍写回
                        end
                    end
                end
                TAIL: begin
                    // 写回最后一个元素（waddr 已 = 287），并标记 BRAM 已有有效值。
                    // 注意：本拍的 BRAM 写使能来自 MAC 最后一拍（wr_en 已 = 1），
                    // 这里必须把 wr_en 拉回 0，否则下一拍 IDLE 会再用脏数据多写一次。
                    warm  <= 1'b1;
                    // 迹 EMA 自适应：有信号慢速 S、无信号快速 SF（拖尾随信号消失快速衰减）
                    pwr_acc  <= pwr_acc - (sig_on ? (pwr_acc >>> S) : (pwr_acc >>> SF)) + trace_sum;
                    // 快速能量（固定 SF）+ 信号检测（门限与 PWR_TH 同尺度）
                    pwr_fast <= pwr_fast_next;
                    sig_on   <= (pwr_fast_next[47:16] > TH_FAST);
                    state <= IDLE;
                    if (k == K-1) begin
                        rdone <= 1'b1;   // 每 K 个快拍发一次（EMA 不重置累加器）
                        k <= 0;
                    end else begin
                        k <= k + 1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
