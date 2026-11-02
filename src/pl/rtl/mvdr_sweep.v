`timescale 1ns / 1ps
// ============================================================
// mvdr_sweep.v —— MVDR 扫角（宽带 8 bin 非相干融合版）
//
// 每个频率 bin k 单独算空间谱 s_k(θ) = a_k^H * R_k^-1 * a_k，再把 8 个
// bin 的谱相加：s_total(θ) = Σ_k s_k(θ)，找最小值 = DOA。
// 宽带非相干融合：主瓣在所有频率固定在 θ_source，栅瓣/驻波随频率漂移，
// 多 bin 相加让主瓣相干增强、栅瓣互相抵消，消除单频跳变。
// （每个 bin 用自己的 R^-1 和自己的导向矢量，因为 a(θ,f) 的相位
//   kR·cos(θ-α) 随频率变；绝对不能把协方差相加。）
//
// 输入：R^-1 连续 8 段、共 512 拍（每段 64 拍 = 一个 bin 的 R^-1，行优先），
//       接 mat_inv_8x8 分 8 次求逆的输出（段间有空隙，S_LOAD 只在 din_valid
//       时推进计数，天然支持）。
//       导向矢量 8 组（bin0..bin7），每个角度各 8 个复数，共享 a_req 握手。
// 输出：doa_deg（融合后最佳角度，度）、s_min（对应最小 s_total）、
//       以及逐角度的 s_out 谱。
//
// 每个角度的计算（省两次复数共轭转置）：
//   for bin b: q_b = R_b^-1 * a_b（64 拍），s_b = a_b^H * q_b（8 拍，实部）
//   s_total = Σ_b s_b
// 因为 s 一定是实数（Hermitian 二次型），虚部恒为 0，可以不算。
//
// 时序：装 R^-1 512 拍 + 每角度 (8 收 + 8×(64+8) + 1 比较) = 585 拍，
//       NANG=361 时总计约 512 + 361*585 ≈ 211697 拍（50MHz 约 4.2ms）。
//
// 注意：累加器用 64bit 全精度累加，只在写 q / s 时做一次四舍五入，
//       避免逐步舍入累积误差。
// ============================================================
module mvdr_sweep #(
    parameter integer N    = 8,     // 阵元数
    parameter integer NANG = 361,   // 扫描角度数（-180..180，步长 1 度）
    parameter integer W    = 32,    // 对外接口位宽 Q16.16（保持 32，与 steer_rom/mat_inv 一致）
    parameter integer IW   = 28,    // 内部 R/a/q 存储位宽 Q12.16（省 LUT；s 仍 32bit）
    parameter integer NB   = 8      // 频点数
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,        // 一拍脉冲启动
    // ---- R^-1 输入（连续 8 段共 512 拍行优先：bin0 → bin7）----
    input  wire                din_valid,
    input  wire signed [W-1:0] din_re,
    input  wire signed [W-1:0] din_im,
    // ---- 导向向量输入（每角度 8 拍 × 8 组，配合 a_req）----
    output reg                 a_req,        // 本角度需要导向向量
    output reg  [8:0]          a_ang,        // 当前角度索引 0..NANG-1（给 ROM 寻址）
    input  wire [NB-1:0]       avalid,       // 8 组 ROM 的 valid（打包）
    input  wire signed [NB*W-1:0] av_re,     // 8 组 re（打包，bin b = av_re[b*W +: W]）
    input  wire signed [NB*W-1:0] av_im,     // 8 组 im（打包）
    // ---- 结果 ----
    output reg  signed [W-1:0] s_out,        // 当前角度的 s_total(θ)（逐角度脉冲）
    output reg                 s_valid,
    output reg  signed [8:0]   doa_deg,      // 最佳角度（度，-180..180）
    output reg  signed [W-1:0] s_min,        // 最佳角度的 s 值
    output reg                 done
);

    localparam S_IDLE = 3'd0, S_LOAD = 3'd1, S_ANG = 3'd2, S_Q = 3'd3,
               S_SS   = 3'd4, S_CMP  = 3'd5, S_DONE = 3'd6;
    reg [2:0] state;

    // ---- 8 个 bin 的 R^-1 存储 / 当前角度的 8 组导向向量 / 中间量 q ----
    // 原 Rre/Rim 是三维寄存器数组，运行时下标 Rre[bin][i][j] 会综合成 512:1
    // 组合 mux 树（大量 MUXF7/F8），占光 LUT。改成扁平 BRAM（512 = 8×8×8）+
    // 同步读后，mux 树消失，28672 个寄存器也一起省掉。写端口在 S_LOAD，读在 S_Q。
    (* ram_style = "block" *) reg signed [IW-1:0] Rmem_re [0:NB*N*N-1];
    (* ram_style = "block" *) reg signed [IW-1:0] Rmem_im [0:NB*N*N-1];
    reg [8:0]  raddr;                       // BRAM 读地址（同步读，1 拍延迟）
    reg signed [IW-1:0] Rc_re, Rc_im;       // BRAM 读出的 R[bin][i][j]
    reg [6:0]  cnt;                         // S_Q 读计数 0..64（0 拍预热 + 64 拍 MAC）

    reg signed [IW-1:0] are [0:NB-1][0:N-1];
    reg signed [IW-1:0] aim [0:NB-1][0:N-1];
    reg signed [IW-1:0] qre [0:N-1];
    reg signed [IW-1:0] qim [0:N-1];

    reg [8:0] li;      // 装载计数 0..511（li[8:6] 选 bin，li[5:0] 行优先 0..63）
    reg [2:0] ai;      // 收导向向量的通道计数
    reg [2:0] i, j;    // S_SS 的循环（i 遍历阵元；j 仅占位，S_Q 已改用 cnt）
    reg [8:0] ang;     // 当前角度索引 0..NANG-1
    reg [2:0] bin;     // 当前在算哪个 bin：0..7

    reg signed [63:0] acc_re, acc_im;     // q 的累加器（Q32.32 全精度）
    reg signed [63:0] sacc;               // s 的累加器
    reg signed [39:0] s_total_acc;        // 8 bin 的 s 累加（40bit 防溢出）
    reg signed [W-1:0] s_best;            // 目前最小 s_total
    reg signed [8:0]   deg_best;          // 目前最佳角度

    // 180° 安装偏移：ch0 实际装在板子最左（物理 φ=180°），把 DOA 的 0° 参考转到板子最右。
    // deg_best ∈ [-180,180] → +180 → wrap 回 [-180,180]（>180 减 360）。
    wire signed [9:0] deg_shift_raw = {deg_best[8], deg_best} + 10'sd180;
    wire signed [9:0] deg_shift     = (deg_shift_raw > 10'sd180) ? (deg_shift_raw - 10'sd360) : deg_shift_raw;

    integer b, r1, r2;

    // ---- Q16.16 四舍五入 ----
    function signed [W-1:0] rnd32;
        input signed [63:0] x;
        begin
            rnd32 = (x + 64'sd32768) >>> 16;
        end
    endfunction

    // ---- 步骤 1：q = R^-1 * a（BRAM 同步读给出 Rc，MAC 用延迟对齐的 mi/mj）----
    // cnt-1 是当前 MAC 的元素编号（cnt=0 拍只预热读、不做 MAC）。
    wire [6:0] cntm1 = cnt - 7'd1;
    wire [2:0] mi    = cntm1[5:3];   // 当前元素的行 i
    wire [2:0] mj    = cntm1[2:0];   // 当前元素的列 j
    // ---- 读口合并：S_Q 用 mj（列）读 a、S_SS 用 i（行）读 a，分时复用同一个 64:1 mux ----
    // 原来 are[bin][mj] 和 are[bin][i] 各自生成一个 8x8=64:1 28bit mux（4 个），
    // 合二为一后只剩 2 个，省一半 LUT（时序不变，读地址只是多了个 2:1 选）。
    wire [2:0] aidx = (state == S_Q) ? mj : i;
    wire signed [IW-1:0] ac_re = are[bin][aidx];
    wire signed [IW-1:0] ac_im = aim[bin][aidx];
    wire signed [63:0] pre = Rc_re*ac_re - Rc_im*ac_im;
    wire signed [63:0] pim = Rc_re*ac_im + Rc_im*ac_re;
    wire signed [63:0] sum_re = (mj == 3'd0) ? pre : (acc_re + pre);
    wire signed [63:0] sum_im = (mj == 3'd0) ? pim : (acc_im + pim);

    // ---- 步骤 2：s = a^H * q（实部，按 bin 选 a）----
    wire signed [IW-1:0] as_re = ac_re;
    wire signed [IW-1:0] as_im = ac_im;
    wire signed [63:0] sprod = as_re*qre[i] + as_im*qim[i];
    wire signed [63:0] ssum  = (i == 3'd0) ? sprod : (sacc + sprod);

    // ---- BRAM 读写（单时钟简单双端口：S_LOAD 写 li，S_Q 读 raddr）----
    always @(posedge clk) begin
        if (state == S_LOAD && din_valid) begin
            Rmem_re[li] <= din_re[IW-1:0];
            Rmem_im[li] <= din_im[IW-1:0];
        end
        Rc_re <= Rmem_re[raddr];
        Rc_im <= Rmem_im[raddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            li <= 0; ai <= 0; i <= 0; j <= 0; ang <= 0; bin <= 0;
            raddr <= 0; cnt <= 0;
            a_req <= 0; a_ang <= 0;
            acc_re <= 0; acc_im <= 0; sacc <= 0; s_total_acc <= 0;
            s_best <= 32'sh7FFFFFFF; deg_best <= 0;
            s_out <= 0; s_valid <= 0; doa_deg <= 0; s_min <= 0; done <= 0;
            for (b = 0; b < NB; b = b + 1) begin
                for (r1 = 0; r1 < N; r1 = r1 + 1) begin
                    are[b][r1] <= 0; aim[b][r1] <= 0;
                end
            end
            for (r1 = 0; r1 < N; r1 = r1 + 1) begin qre[r1] <= 0; qim[r1] <= 0; end
        end else begin
            done    <= 1'b0;
            s_valid <= 1'b0;
            a_req   <= 1'b0;
            a_ang   <= ang;      // 始终跟随当前角度，供 ROM 寻址

            case (state)
            S_IDLE: begin
                if (start) begin
                    li       <= 9'd0;
                    ang      <= 9'd0;
                    ai       <= 3'd0;
                    bin      <= 3'd0;
                    s_best   <= 32'sh7FFFFFFF;
                    deg_best <= -9'sd180;
                    state    <= S_LOAD;
                end
            end

            // ---------- 装 R^-1（512 拍行优先：li[8:6] 选 bin，li[5:0] 行优先 0..63）----------
            S_LOAD: begin
                if (din_valid) begin
                    // Rmem_re[li]/Rmem_im[li] 的写在上面的 BRAM always 块里，
                    // 这里只推进装载计数（li 同时也是 BRAM 写地址）。
                    if (li == 9'd511) begin
                        state <= S_ANG;
                    end else begin
                        li <= li + 9'd1;
                    end
                end
            end

            // ---------- 收本角度 8 组导向向量（a_req 拉高，收 8 拍）----------
            S_ANG: begin
                a_req <= 1'b1;
                if (&avalid) begin
                    for (b = 0; b < NB; b = b + 1) begin
                        are[b][ai] <= av_re[b*W +: IW];
                        aim[b][ai] <= av_im[b*W +: IW];
                    end
                    if (ai == N-1) begin
                        ai     <= 3'd0;
                        bin    <= 3'd0;
                        i      <= 3'd0;
                        j      <= 3'd0;
                        acc_re <= 64'sd0;
                        acc_im <= 64'sd0;
                        s_total_acc <= 40'sd0;
                        cnt    <= 7'd0;      // 预热读 R[bin0][0][0]
                        raddr  <= 9'd0;
                        a_req  <= 1'b0;
                        state  <= S_Q;
                    end else begin
                        ai <= ai + 3'd1;
                    end
                end
            end

            // ---------- q = R^-1 * a（8x8 复数 MAC，当前 bin；BRAM 同步读流水）----------
            // cnt 0..64：cnt=0 只预热读 R[bin][0][0]；cnt=1..64 每拍一个 MAC，
            // 元素编号 = cnt-1（mi=行、mj=列）。BRAM 读有 1 拍延迟，raddr 提前 1 拍。
            S_Q: begin
                raddr <= {bin, cnt[5:0] + 6'd1};   // 读下一个元素（cnt+1）
                if (cnt > 7'd0) begin
                    acc_re <= sum_re;
                    acc_im <= sum_im;
                    if (mj == 3'd7) begin
                        qre[mi] <= rnd32(sum_re)[IW-1:0];
                        qim[mi] <= rnd32(sum_im)[IW-1:0];
                    end
                end
                cnt <= cnt + 7'd1;
                if (cnt == 7'd64) begin
                    sacc  <= 64'sd0;
                    state <= S_SS;
                end
            end

            // ---------- s = a^H * q（取实部，当前 bin），累加到总谱 ----------
            S_SS: begin
                sacc <= ssum;
                if (i == N-1) begin
                    // s_total_acc += s_b（bin0 时直接赋初值，避免多一拍清零）
                    s_total_acc <= (bin == 3'd0) ? rnd32(ssum) : (s_total_acc + rnd32(ssum));
                    if (bin == NB-1) begin
                        state <= S_CMP;
                    end else begin
                        bin <= bin + 3'd1;
                        i <= 3'd0; j <= 3'd0; acc_re <= 64'sd0; acc_im <= 64'sd0;
                        cnt   <= 7'd0;                    // 预热读下一个 bin 的 R[bin][0][0]
                        raddr <= {bin, 6'd0} + 9'd64;
                        state <= S_Q;
                    end
                end else begin
                    i <= i + 3'd1;
                end
            end

            // ---------- 融合比较并推进角度 ----------
            S_CMP: begin
                s_out   <= s_total_acc[W-1:0];
                s_valid <= 1'b1;
                if ($signed(s_total_acc) < $signed({{8{s_best[W-1]}}, s_best})) begin
                    s_best   <= s_total_acc[W-1:0];
                    deg_best <= $signed({1'b0, ang}) - 10'sd180;
                end
                if (ang == NANG-1) begin
                    state <= S_DONE;
                end else begin
                    ang   <= ang + 9'd1;
                    ai    <= 3'd0;
                    state <= S_ANG;
                end
            end

            // ---------- 输出结果 ----------
            S_DONE: begin
                doa_deg <= deg_shift[8:0];
                s_min   <= s_best;
                done    <= 1'b1;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
