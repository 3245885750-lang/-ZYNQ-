`timescale 1ns / 1ps
// ============================================================
// i2s_rx.v —— I2S 单通道接收器（只采左声道，1 样本 / WS 周期）
//
// 为什么只采一个声道（关键，2026-10-01 修正）：
//   INMP441 接 L/R=GND → 只在【左声道】（WS=低）输出数据，
//   右声道（WS=高）是静音（SD=0 或高阻）。
//   旧版在 WS 两个边沿都采 → 每 WS 周期出 2 个样本（1 真 1 零），
//   真实采样率变成 2×48.828=97.656kHz，和 ROM 的 bin=43 对不上。
//   本版只在 WS【下降沿】（进入左声道）开始取数 → 每 WS 周期 1 个样本
//   → 采样率 = WS 频率 = 48.828kHz，正好对上 TARGET_BIN=43。
//
// I2S（Philips）时序：
//   SD 在 SCK 下降沿输出，本模块在 SCK 上升沿采样；
//   WS 翻转后先有 1 个 SCK 的"延迟位"（不取），之后 24 个 SCK
//   依次是 MSB -> LSB。
//
// 若板测发现采到的全是 0（说明 WS 极性接反 / L/R 接反），把下面
// `ws_r1 && !ws`（下降沿）改成 `!ws_r1 && ws`（上升沿）即可。
// ============================================================
module i2s_rx (
    input  wire        sck ,     // 位时钟
    input  wire        ws  ,     // 字选择 L/R
    input  wire        sd  ,     // 串行数据
    output reg  [23:0] data,     // 24 位样本（有符号，2 的补码）
    output reg         valid     // 收满一个样本时拉高 1 个 sck 周期
);

    reg        ws_r1   = 1'b0;   // ws 延迟一拍，用来检测边沿
    reg  [4:0] bit_cnt = 5'd0;   // 位计数，0~24
    reg  [23:0] shift  = 24'd0;  // 移位寄存器（MSB 先入）

    always @(posedge sck) begin
        ws_r1 <= ws;
        valid <= 1'b0;

        if (ws_r1 && !ws) begin
            // WS 下降沿（进入左声道）：这一拍是"延迟位"，不取数，复位
            bit_cnt <= 5'd0;
            shift   <= 24'd0;
        end
        else if (!ws && bit_cnt < 24) begin
            // 左声道数据位：MSB 先入
            shift   <= {shift[22:0], sd};
            bit_cnt <= bit_cnt + 5'd1;
            if (bit_cnt == 5'd23) begin
                data  <= {shift[22:0], sd};   // 凑满 24 位
                valid <= 1'b1;
            end
        end
        // 右声道（WS=高）阶段：!ws=0，不取数，bit_cnt 停在 24，等下一个下降沿
    end

endmodule
