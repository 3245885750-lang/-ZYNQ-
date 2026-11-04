`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 8 通道 I2S 接收器（顶层）
// 作用：8 个麦克风共用 SCK/WS，各用一根 SD 线送数据，
//       本模块把 8 路串行数据同时还原成 8 路 24 位样本
//
// 关键点：复用单通道 i2s_rx 模块，用 generate 循环“复制”8 份
//
// 数据总线 data 的排布（8 路 × 24 位 = 192 位）：
//   data[ 23: 0 ] = 第 0 路
//   data[ 47:24 ] = 第 1 路
//   data[ 71:48 ] = 第 2 路
//   data[ 95:72 ] = 第 3 路
//   data[119:96 ] = 第 4 路
//   data[143:120] = 第 5 路
//   data[167:144] = 第 6 路
//   data[191:168] = 第 7 路
//////////////////////////////////////////////////////////////////////////////////

module i2s_rx_8ch (
    input  wire         sck  ,    // 位时钟（8 路共用）
    input  wire         ws   ,    // 字选择（8 路共用）
    input  wire  [7:0]  sd   ,    // 8 路串行数据
    output wire  [7:0]  valid,    // 8 路收满标志（8 路同时拉高）
    output wire  [191:0] data     // 8 路数据拼成一条总线
);

    // generate 循环：把 i2s_rx 复制 8 份
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : ch
            i2s_rx u_i2s_rx (
                .sck  (sck            ),
                .ws   (ws             ),
                .sd   (sd[i]          ),
                .data (data[i*24 +: 24]),
                .valid(valid[i]       )
            );
        end
    endgenerate

endmodule
