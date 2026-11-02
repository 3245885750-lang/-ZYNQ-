`timescale 1ns / 1ps
// ============================================================
// i2s_master.v —— I2S 主机：生成 SCK 与 WS（给 8 个 INMP441）
//
// INMP441 是 I2S 从机，SCK / WS 必须由 FPGA 提供。
//   采样率 = 48.828kHz（整数分频方案，见 CLAUDE.md「关键决策」）
//     SCK = 50MHz / 16 = 3.125MHz（INMP441 要求 SCK = 64 × 采样率）
//     WS  = SCK / 64    = 48.828kHz
//
// 相位：WS 在 SCK 下降沿翻转（标准 I2S），SCK / WS 占空比各 50%。
//
// 接口：
//   clk   = 50MHz（板子 sys_clk，U18）
//   rst_n = 低有效复位（sys_rst_n，N16）
//   sck   = 位时钟输出（接 i2s_fft8_top.sck 与 INMP441 的 SCK）
//   ws    = 字选择输出（接 i2s_fft8_top.ws 与 INMP441 的 WS）
// ============================================================
module i2s_master (
    input  wire clk,
    input  wire rst_n,
    output wire sck,
    output wire ws
);

    reg [3:0] clk_cnt = 4'd0;   // 0..15，SCK 分频计数
    reg [5:0] bit_cnt = 6'd0;   // 0..63，WS 分频计数（每个 SCK 周期 +1）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 4'd0;
            bit_cnt <= 6'd0;
        end else begin
            if (clk_cnt == 4'd15) begin
                clk_cnt <= 4'd0;
                bit_cnt <= bit_cnt + 6'd1;   // 6bit 自然回绕 0..63
            end else begin
                clk_cnt <= clk_cnt + 4'd1;
            end
        end
    end

    // SCK：clk_cnt[3] 在 0..7 为 0、8..15 为 1 → 周期 16 clk，占空比 50%
    assign sck = clk_cnt[3];
    // WS：bit_cnt[5] 在 0..31 为 0、32..63 为 1 → 周期 64 SCK，占空比 50%
    assign ws  = bit_cnt[5];

endmodule
