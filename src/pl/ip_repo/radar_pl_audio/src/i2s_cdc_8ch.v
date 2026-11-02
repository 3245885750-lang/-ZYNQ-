// ============================================================
// i2s_cdc_8ch.v  ——  8 路 I2S 采样跨时钟域同步 + 24bit -> 16bit
//
// 作用：把 i2s_rx_8ch 的输出（SCK 时钟域，8 路 × 24bit）安全搬到 clk 域。
//
// 关键点：8 路麦克风共用 SCK / WS，8 路 valid 是"同一个 sck 上升沿"
//        同时拉高的，所以只需同步一路 valid[0] 作为全体代表；
//        在这个同步后的脉冲时刻，同时锁 8 路 data。
//
// 输出：sample_data = 8 路 × 16bit（每路取原 24bit 的 [23:8]），
//       sample_valid = clk 域 1 周期脉冲（代表 8 路同时各来了 1 个新点）。
// ============================================================
module i2s_cdc_8ch (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [191:0] i2s_data,     // SCK 域，8 路 × 24bit
    input  wire [7:0]   i2s_valid,    // SCK 域，8 路 valid（同时拉高）

    output reg  [127:0] sample_data,  // clk 域，8 路 × 16bit
    output reg          sample_valid  // clk 域，1 周期脉冲
);

    // ---- 2 级同步器：同步 valid[0] 作为全体代表 ----
    reg q1, q2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= 1'b0;
            q2 <= 1'b0;
        end else begin
            q1 <= i2s_valid[0];   // 第 1 级
            q2 <= q1;             // 第 2 级
        end
    end
    // 上升沿检测：q1 上升、q2 还没跟上时，输出 1 个 clk 周期的脉冲
    wire valid_pulse = q1 & ~q2;

    // ---- 在 valid_pulse 时刻同时锁 8 路数据（24 -> 16，取 [23:8]）----
    integer ch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_data  <= 128'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= valid_pulse;
            if (valid_pulse)
                for (ch = 0; ch < 8; ch = ch + 1)
                    sample_data[ch*16 +: 16] <= i2s_data[ch*24 + 8 +: 16];
        end
    end

endmodule
