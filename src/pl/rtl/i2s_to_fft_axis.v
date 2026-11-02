// ============================================================
// i2s_to_fft_axis.v  ——  慢速采样流 -> AXI4-Stream 帧打包器
//
// 作用：把"慢速采样流"（每来一个 sample_valid 脉冲 = 一个新采样点）
//       打包成 AXI4-Stream 帧（FRAME_LEN 个点一帧，最后一点 tlast=1），
//       供 FFT 核突发读取。
//
// 为什么这么设计：
//   - I2S 采样慢（48kHz，每个点间隔约 20.83us）
//   - FFT 是流式接口，希望一次连续灌满一帧（512 点）
//   - 所以先攒满一帧 mem[0..FRAME_LEN-1]，再在 clk 频率下连续突发送给 FFT
//
// 接口：
//   输入  sample_data / sample_valid ：采样点（慢速，先假定已在 clk 域）
//   输出  m_axis_*                     ：AXI4-Stream 主机口，接 fft_512 的 s_axis_data
//   输出  busy                          ：1 = 正在突发，供上层判断 FFT 是否忙
//
// 注意：本模块用单个 mem，突发期间不再收新采样点。
//       1 路 48kHz 场景下突发极快（512 时钟 << 20.83us），不会丢点；
//       8 路复用时需要改成 ping-pong / 每路独立缓冲（后面再做）。
// ============================================================
module i2s_to_fft_axis #(
    parameter FRAME_LEN = 512,
    parameter DATA_W    = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [DATA_W-1:0] sample_data,
    input  wire        sample_valid,

    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         busy
);

    reg [DATA_W-1:0] mem [0:FRAME_LEN-1];
    reg [9:0] wr_cnt;   // 写指针 0..FRAME_LEN-1
    reg [9:0] rd_cnt;   // 读指针（突发时用）
    reg       state;    // 0 = 采集, 1 = 突发

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= 1'b0;
            wr_cnt        <= 0;
            rd_cnt        <= 0;
            m_axis_tdata  <= 0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            busy          <= 1'b0;
        end else begin
            case (state)

                // ---------- 采集：采样点一个个写进 mem ----------
                1'b0: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (sample_valid) begin
                        mem[wr_cnt] <= sample_data;
                        if (wr_cnt == FRAME_LEN-1) begin
                            // 采满一帧，进入突发
                            state  <= 1'b1;
                            busy   <= 1'b1;
                            wr_cnt <= 0;
                            rd_cnt <= 0;
                        end else begin
                            wr_cnt <= wr_cnt + 1'b1;
                        end
                    end
                end

                // ---------- 突发：在 clk 频率下连续把 mem 灌给 FFT ----------
                1'b1: begin
                    if (rd_cnt == 0) begin
                        // 送出第一个点
                        m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem[0]};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= (FRAME_LEN == 1);
                        rd_cnt        <= 1;
                    end else if (m_axis_tvalid && m_axis_tready) begin
                        // 上一个点已被 FFT 收走，送下一个
                        if (rd_cnt == FRAME_LEN) begin
                            // 全部送完，回到采集
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                            state         <= 1'b0;
                            busy          <= 1'b0;
                            rd_cnt        <= 0;
                        end else begin
                            m_axis_tdata  <= {{(32-DATA_W){1'b0}}, mem[rd_cnt]};
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= (rd_cnt == FRAME_LEN-1);
                            rd_cnt        <= rd_cnt + 1'b1;
                        end
                    end
                end

            endcase
        end
    end

endmodule
