`timescale 1ns / 1ps
// ============================================================
// steer_rom.v —— 导向向量 ROM（供 mvdr_sweep 使用）
//
// 存 361 个角度 x 8 通道 的导向向量 a(theta)（Q16.16 复数），
// 共 361*8 = 2888 项 x 2（实/虚）= 184.8 kbit ≈ 6 个 BRAM。
//
// 数据由 gen_steer_rom_tb / gen_steer_4khz.py 生成（跑一次）：
//     src/steer_re.mem / src/steer_im.mem
//   索引 addr = ang*8 + ch， ang=0..360 对应角度 deg = ang-180
//
// 握手（对应 mvdr_sweep）：
//   mvdr_sweep 把 a_req 拉高并给出 a_ang → 本模块在随后 8 拍连续输出
//   该角度的 8 个通道值（avalid=1）。吐完进 S_WAIT 等 a_req 落下
//   ——因为 mvdr_sweep 是在收满第 8 拍的**下一个**时钟沿才拉低 a_req，
//   不等的话会误发一整轮多余数据（虽然不会被消费，但状态机会错一拍）。
//
// 时序：a_req 有效后 2 拍出第 1 个数据，共 8 拍
// ============================================================
module steer_rom #(
    parameter integer NCH  = 8,
    parameter integer NANG = 361,
    parameter integer W    = 32,
    parameter REFILE = "steer_re.mem",   // 相对路径：.mem 必须 add 进工程（Add Sources）综合才找得到
    parameter IMFILE = "steer_im.mem"
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                a_req,        // 来自 mvdr_sweep
    input  wire [8:0]          a_ang,        // 当前角度索引 0..NANG-1
    output reg                 avalid,       // 每角度连续 8 拍
    output reg  signed [W-1:0] av_re,
    output reg  signed [W-1:0] av_im
);

    reg signed [W-1:0] rom_re [0:NANG*NCH-1];
    reg signed [W-1:0] rom_im [0:NANG*NCH-1];

    initial begin
        $readmemh(REFILE, rom_re);
        $readmemh(IMFILE, rom_im);
    end

    localparam S_IDLE = 2'd0, S_SEND = 2'd1, S_WAIT = 2'd2;
    reg [1:0] state;
    reg [3:0] cnt;

    wire [11:0] idx = a_ang*NCH + cnt;      // 最大 360*8+7 = 2887

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            cnt    <= 4'd0;
            avalid <= 1'b0;
            av_re  <= 0;
            av_im  <= 0;
        end else begin
            avalid <= 1'b0;
            case (state)
            S_IDLE: begin
                if (a_req) begin
                    state <= S_SEND;
                    cnt   <= 4'd0;
                end
            end

            S_SEND: begin
                avalid <= 1'b1;
                av_re  <= rom_re[idx];
                av_im  <= rom_im[idx];
                cnt    <= cnt + 4'd1;
                if (cnt == NCH-1)
                    state <= S_WAIT;        // 8 拍发完，等 a_req 落下
            end

            S_WAIT: begin
                if (!a_req)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
