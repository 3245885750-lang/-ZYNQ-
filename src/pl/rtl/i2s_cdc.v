// ============================================================
// i2s_cdc.v  ——  I2S 采样跨时钟域同步 + 24bit -> 16bit
//
// 作用：把 i2s_rx 的输出（SCK 时钟域）安全地搬到系统时钟 clk 域。
//
// 为什么要同步：
//   i2s_rx 的 valid/data 由 sck 触发，而打包器和 FFT 跑在 clk，
//   两个时钟异步，直接连线会采到亚稳态/毛刺，导致数据错乱。
//
// 方法（经典 2 级同步器，适用于"慢脉冲"）：
//   - valid 是 1 个 sck 周期的宽脉冲（~325ns，比 clk 周期 10ns 宽 32 倍），
//     用两级触发器把它同步到 clk 域，再取上升沿，得到 1 个 clk 周期的脉冲；
//   - data 在 valid 之后稳定一整帧（~20.83us），在同步后的 valid 脉冲
//     时刻去采样 data，采到的一定是稳定值。
//
// 输出：sample_data = data[23:8]（24bit 截成 16bit，丢低 8 位），
//       sample_valid = clk 域 1 个周期脉冲。
// ============================================================
module i2s_cdc (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [23:0] i2s_data,    // SCK 域，24bit 有符号样本
    input  wire        i2s_valid,   // SCK 域，1 个 sck 周期宽脉冲

    output reg  [15:0] sample_data, // clk 域，16bit
    output reg         sample_valid // clk 域，1 个 clk 周期宽脉冲
);

    // ---- 2 级同步器：把 i2s_valid 同步到 clk 域 ----
    reg q1, q2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= 1'b0;
            q2 <= 1'b0;
        end else begin
            q1 <= i2s_valid;   // 第 1 级
            q2 <= q1;          // 第 2 级
        end
    end
    // 上升沿检测：q1 上升、q2 还没跟上时，输出 1 个 clk 周期的脉冲
    wire valid_pulse = q1 & ~q2;

    // ---- 在 valid 脉冲时刻采样 data（此时 data 已稳定）----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_data  <= 16'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= valid_pulse;
            if (valid_pulse)
                sample_data <= i2s_data[23:8];   // 24 -> 16，取高 16 位
        end
    end

endmodule
