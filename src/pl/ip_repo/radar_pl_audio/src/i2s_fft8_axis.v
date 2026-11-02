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
// 注意：mem 是 8 个独立的一维数组（每路 1024×16bit），综合时各自推断成
//       分布式 RAM（LUTRAM，共约 2K LUT）。之前用二维/三维数组会因"8 路
//       同时写 = 多写口"被判定成 incorrect usage，全变成触发器，占满器件。
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

    // 乒乓缓冲：8 路各自独立的一块双 bank RAM，每路 1024×16bit。
    // 用 8 个独立一维数组（不是二维/三维数组），这样每路都是一个单口
    // 分布式 RAM。之前用二维/三维数组会因"8 路同时写 = 多写口"被判定成
    // incorrect usage，全变成触发器，占满 7020 寄存器导致实现失败。
    // 地址 = {bank, 9bit 采样序号}，10bit、范围 0..1023。
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem0 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem1 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem2 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem3 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem4 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem5 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem6 [0:2*FRAME_LEN-1];
    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem7 [0:2*FRAME_LEN-1];

    // ---- 写侧：当前写 bank + 写指针 + 交接信号 ----
    reg       wr_bank;    // 0 = A, 1 = B
    reg [9:0] wr_cnt;     // 0 .. FRAME_LEN-1
    reg       rd_pending; // 1 = 有一整组帧待读
    reg       rd_bank;    // 待读的 bank（刚写满的那个）

    // ---- 读侧：通道选择 + 读指针 ----
    reg       rd_busy;
    reg [2:0] rd_ch;      // 0 .. NCH-1
    reg [9:0] rd_cnt;     // 0 .. FRAME_LEN-1
    reg       rd_start;   // 读侧开始消费时拉 1 拍，通知写侧撤 rd_pending

    // 组合读：按通道选对应的 RAM，返回地址 addr 处的数据（分布式 RAM 异步读）
    function [DATA_W-1:0] mem_rd;
        input [2:0] ch_sel;
        input [9:0] addr;
        begin
            case (ch_sel)
                3'd0: mem_rd = mem0[addr];
                3'd1: mem_rd = mem1[addr];
                3'd2: mem_rd = mem2[addr];
                3'd3: mem_rd = mem3[addr];
                3'd4: mem_rd = mem4[addr];
                3'd5: mem_rd = mem5[addr];
                3'd6: mem_rd = mem6[addr];
                default: mem_rd = mem7[addr];
            endcase
        end
    endfunction

    // ================= 写侧：控制逻辑（带复位）=================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank    <= 1'b0;
            wr_cnt     <= 0;
            rd_pending <= 1'b0;
            rd_bank    <= 1'b0;
        end else begin
            // rd_pending 只在本块驱动（写侧置 1，读侧 rd_start 时撤 0），
            // 避免两个 always 同时驱动同一信号（否则综合报 MDRV-1）
            if (rd_start)
                rd_pending <= 1'b0;
            if (sample_valid) begin
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
    end

    // ================= 写侧：内存写（单独 always，不带复位，才能推断成 RAM）=================
    // 关键：RAM 的写时钟块里不能有异步复位，否则 Vivado 会把 mem 当成带
    // Set/Reset 的触发器，无法推断成 RAM（报 Synth 8-7137）。
    // 这里用当前（旧）wr_bank/wr_cnt 作写地址，与控制块在同一时钟沿，
    // 非阻塞赋值时序一致，行为不变。
    always @(posedge clk) begin
        if (sample_valid) begin
            mem0[{wr_bank, wr_cnt[8:0]}] <= sample_data[0*DATA_W +: DATA_W];
            mem1[{wr_bank, wr_cnt[8:0]}] <= sample_data[1*DATA_W +: DATA_W];
            mem2[{wr_bank, wr_cnt[8:0]}] <= sample_data[2*DATA_W +: DATA_W];
            mem3[{wr_bank, wr_cnt[8:0]}] <= sample_data[3*DATA_W +: DATA_W];
            mem4[{wr_bank, wr_cnt[8:0]}] <= sample_data[4*DATA_W +: DATA_W];
            mem5[{wr_bank, wr_cnt[8:0]}] <= sample_data[5*DATA_W +: DATA_W];
            mem6[{wr_bank, wr_cnt[8:0]}] <= sample_data[6*DATA_W +: DATA_W];
            mem7[{wr_bank, wr_cnt[8:0]}] <= sample_data[7*DATA_W +: DATA_W];
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
            rd_start      <= 1'b0;
        end else begin
            m_axis_tvalid <= 1'b0;   // 默认不发，下面按需拉高
            m_axis_tlast  <= 1'b0;
            rd_start      <= 1'b0;   // 默认清，只在开始消费那 1 拍拉高

            if (!rd_busy) begin
                // 空闲：等一整组帧就绪
                if (rd_pending) begin
                    rd_busy       <= 1'b1;
                    rd_ch         <= 0;
                    rd_cnt        <= 0;
                    rd_start      <= 1'b1;   // 通知写侧撤 rd_pending
                    busy          <= 1'b1;
                    // 立刻送出 ch0 第 0 点
                    m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem_rd(3'd0, {rd_bank, 9'd0})};
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
                            m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem_rd(rd_ch + 3'd1, {rd_bank, 9'd0})};
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= (FRAME_LEN == 1);
                        end
                    end else begin
                        rd_cnt        <= rd_cnt + 1;
                        m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem_rd(rd_ch, {rd_bank, rd_cnt[8:0] + 9'd1})};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= (rd_cnt+1 == FRAME_LEN-1);
                    end
                end
            end
        end
    end

endmodule
