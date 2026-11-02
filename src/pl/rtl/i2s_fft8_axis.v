// ============================================================
// i2s_fft8_axis.v  ——  8 路乒乓帧缓冲 + 通道分时复用 -> AXI4-Stream
//
// 作用：
//   1. 8 路采样（sample_valid 一个脉冲 = 8 路各来 1 点）同时写进
//      当前写 bank（A 或 B）；
//   2. 攒满 512 点后 A/B 互换，读侧把"刚写满的那个 bank"的 8 帧
//      按 ch0 -> ch1 -> ... -> ch7 顺序连续突发给 FFT；
//   3. 每帧最后一点 tlast=1，FFT 靠它切帧。
//
// 为什么乒乓（ping-pong）：
//   8 帧突发要 8×512 = 4096 个时钟 ≈ 41us，但麦克风每 20.83us 就
//   来一批新点。只用一套缓冲的话，突发期间的 ~2 个新点会丢。
//   两套 bank 轮流用：一边写新帧、一边读旧帧，互不冲突。
//
// 时间预算：写满一个 bank 要 512×20.83us = 10.67ms，
//           读空一个 bank 只要 41us，读侧永远赶得上，不会溢出。
//
// 注意：mem 用 reg 数组，仿真即可；综合时 Vivado 会自动推断成
//       Block RAM（2×8×512×16 = 128Kbit，7020 完全放得下）。
// ============================================================
module i2s_fft8_axis #(
    parameter NCH       = 8,
    parameter FRAME_LEN = 512,
    parameter DATA_W    = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [NCH*DATA_W-1:0] sample_data,   // 8 路 × 16bit
    input  wire        sample_valid,            // 1 脉冲 = 8 路各来 1 点

    output reg  [31:0] m_axis_tdata,   // 低 16 位 real，高 16 位 imag=0
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,   // 每帧（512 点）最后一点拉高
    output reg         busy
);

    // 乒乓缓冲：2 bank × 8 路 × 512 点 × 16bit
    reg [DATA_W-1:0] mem [0:1][0:NCH-1][0:FRAME_LEN-1];

    // ---- 写侧：当前写 bank + 写指针 + 交接信号 ----
    reg       wr_bank;    // 0 = A, 1 = B
    reg [9:0] wr_cnt;     // 0 .. FRAME_LEN-1
    reg       rd_pending; // 1 = 有一整组帧待读
    reg       rd_bank;    // 待读的 bank（刚写满的那个）

    // ---- 读侧：通道选择 + 读指针 ----
    reg       rd_busy;
    reg [2:0] rd_ch;      // 0 .. NCH-1
    reg [9:0] rd_cnt;     // 0 .. FRAME_LEN-1

    integer ch;

    // ================= 写侧 =================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank    <= 1'b0;
            wr_cnt     <= 0;
            rd_pending <= 1'b0;
            rd_bank    <= 1'b0;
        end else if (sample_valid) begin
            // 8 路同时写进当前写 bank
            for (ch = 0; ch < NCH; ch = ch + 1)
                mem[wr_bank][ch][wr_cnt] <= sample_data[ch*DATA_W +: DATA_W];
            if (wr_cnt == FRAME_LEN-1) begin
                // 写满一帧，交接给读侧
                rd_bank    <= wr_bank;
                rd_pending <= 1'b1;
                wr_bank    <= ~wr_bank;   // 换 bank 继续写
                wr_cnt     <= 0;
            end else begin
                wr_cnt <= wr_cnt + 1;
            end
        end
    end

    // ================= 读侧 FSM =================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_busy       <= 1'b0;
            rd_ch         <= 0;
            rd_cnt        <= 0;
            m_axis_tdata  <= 0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            busy          <= 1'b0;
        end else begin
            m_axis_tvalid <= 1'b0;   // 默认不发，下面按需拉高
            m_axis_tlast  <= 1'b0;

            if (!rd_busy) begin
                // 空闲：等一整组帧就绪
                if (rd_pending) begin
                    rd_busy       <= 1'b1;
                    rd_ch         <= 0;
                    rd_cnt        <= 0;
                    rd_pending    <= 1'b0;
                    busy          <= 1'b1;
                    // 立刻送出 ch0 第 0 点
                    m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem[rd_bank][0][0]};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= (FRAME_LEN == 1);
                end else begin
                    busy <= 1'b0;
                end
            end else begin
                // 突发中：上一个点被 FFT 收走，推下一个点
                if (m_axis_tvalid && m_axis_tready) begin
                    if (rd_cnt == FRAME_LEN-1) begin
                        // 本通道最后一帧已送出
                        if (rd_ch == NCH-1) begin
                            // 8 帧全部送完，回空闲
                            rd_busy <= 1'b0;
                            busy    <= 1'b0;
                        end else begin
                            // 换下一个通道，从第 0 点开始
                            rd_ch         <= rd_ch + 1;
                            rd_cnt        <= 0;
                            m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem[rd_bank][rd_ch+1][0]};
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= (FRAME_LEN == 1);
                        end
                    end else begin
                        rd_cnt        <= rd_cnt + 1;
                        m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem[rd_bank][rd_ch][rd_cnt+1]};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= (rd_cnt+1 == FRAME_LEN-1);
                    end
                end
            end
        end
    end

endmodule
