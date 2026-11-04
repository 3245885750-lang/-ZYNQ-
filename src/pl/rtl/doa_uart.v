`timescale 1ns / 1ps
// ============================================================
// doa_uart.v —— 串口打印两路 DOA（DAS 快 + MVDR 精）
//
// 每收到一个脉冲，打印一行（带来源标签）：
//   DAS  （das_done）：            "D=270 P=0012AB34\r\n"（18 字节）
//   MVDR （doa_done，~47.7Hz）：   "M=270 E=0012AB34 V=01\r\n"（23 字节）
//   D = DAS 宽带快速粗测；M = MVDR 窄带精测。角度范围 0..359（3 位数字，-90° 显示为 270°）。
//   V=<v1><v2> 是两条运动判据在这一帧的判决（1=认为在运动，会切短记忆）：
//     v1 = mov_detect_3beam（θp±Δ 波束功率比），v2 = DOA 增量 EMA。
//   两者取并集决定协方差记忆。★ 这是排查"跳变时到底是判据没开、还是开了也没用"
//   的唯一板上证据，0x4C 寄存器在自检版里没有 PS 可读，所以走串口。
//
// 上电复位后先发一行 banner "radar_pl ready\r\n"。
// 波特率 115200、8 数据位、无校验、1 停止位（8N1）。
// 分频 = 50MHz / 115200 ≈ 434（实际 115207 bps，误差可忽略）。
//
// 请求用粘滞标志（das_req / mvdr_req）锁存：发送期间新来的脉冲先挂着，
// 不会打乱正在发送的那一行。MVDR 优先级高于 DAS（精测更稀有不漏）。
// ============================================================
module doa_uart (
    input  wire            clk,
    input  wire            rst_n,
    input  wire signed [8:0] doa_deg,   // MVDR 精测角度（-180..+180）
    input  wire            doa_done,    // MVDR 完成脉冲
    input  wire [31:0]     pwr,         // MVDR 能量（与 doa_done 同拍有效）
    input  wire            mot_v1,      // 运动判据 v1 判决（与 doa_done 同拍有效）
    input  wire            mot_v2,      // 运动判据 v2 判决
    input  wire signed [8:0] das_doa,   // DAS 粗测角度（-180..+180）
    input  wire            das_done,    // DAS 更新脉冲
    input  wire [31:0]     das_pwr,     // DAS max 束功率高 32 位（校准门限用）
    output reg             uart_txd
);

    localparam BAUD_DIV = 16'd434;    // 50e6 / 115200 = 434.03，取 434

    localparam BOOT_LEN = 5'd16;      // "radar_pl ready" + "\r\n"
    localparam DAS_LEN  = 5'd18;      // "D=270 P=0012AB34\r\n"
    localparam MVDR_LEN = 5'd23;      // "M=270 E=0012AB34 V=01\r\n"

    localparam [8*14-1:0] BANNER = "radar_pl ready";   // 14 字符，尾部 \r\n 在 boot_byte 里补

    // ---- 主状态机 ----
    localparam S_IDLE = 2'd0, S_BIT = 2'd1;
    reg [1:0]  state;

    reg [15:0] baud_cnt;
    reg [3:0]  bit_cnt;
    reg [9:0]  shift;        // {stop, data[7:0], start}
    reg [4:0]  idx;          // 当前字节序号
    reg        booting;      // 1=还在发 banner
    reg        pending;      // 1=有消息正在发送
    reg        msg_is_das;   // 1=DAS 短消息，0=MVDR 消息
    reg        das_req;      // DAS 粘滞请求
    reg        mvdr_req;     // MVDR 粘滞请求
    reg signed [8:0] doa_latch;   // 锁存待发角度（DAS 或 MVDR）
    reg        [31:0] pwr_latch;  // 锁存待发能量（仅 MVDR 用）
    reg        [1:0]  mot_latch;  // 锁存 {v1, v2} 运动判决（仅 MVDR 用）

    // ---- 1 个 4bit 半字节 → ASCII 十六进制字符 ----
    function [7:0] hex_asc;
        input [3:0] nib;
        begin
            hex_asc = (nib < 4'd10) ? (8'h30 + nib) : (8'h41 + nib - 4'd10);
        end
    endfunction

    // ---- 消息第 idx 个字节（按 msg_is_das 选格式）----
    // 角度统一转 0..359 无符号显示（-90°→270°，-180°/+180°→180°），3 位数字、无符号位。
    function [7:0] msg_byte;
        input [4:0] idx;
        input        is_das;
        input signed [8:0] doa;
        input [31:0] pwr;
        input [1:0]  mot;          // {v1, v2}
        reg signed [9:0] d10;
        reg [8:0] deg360;
        begin
            d10    = doa;                                     // 符号扩展到 10bit
            deg360 = (d10 < 0) ? (d10 + 10'sd360) : d10[8:0]; // -180..+180 → 0..359
            if (is_das) begin
                case (idx)
                    5'd0:  msg_byte = "D";
                    5'd1:  msg_byte = "=";
                    5'd2:  msg_byte = 8'h30 + (deg360 / 100);
                    5'd3:  msg_byte = 8'h30 + ((deg360 / 10) % 10);
                    5'd4:  msg_byte = 8'h30 + (deg360 % 10);
                    5'd5:  msg_byte = " ";
                    5'd6:  msg_byte = "P";
                    5'd7:  msg_byte = "=";
                    5'd8:  msg_byte = hex_asc(pwr[31:28]);
                    5'd9:  msg_byte = hex_asc(pwr[27:24]);
                    5'd10: msg_byte = hex_asc(pwr[23:20]);
                    5'd11: msg_byte = hex_asc(pwr[19:16]);
                    5'd12: msg_byte = hex_asc(pwr[15:12]);
                    5'd13: msg_byte = hex_asc(pwr[11:8]);
                    5'd14: msg_byte = hex_asc(pwr[7:4]);
                    5'd15: msg_byte = hex_asc(pwr[3:0]);
                    5'd16: msg_byte = 8'h0D;   // \r
                    default: msg_byte = 8'h0A;   // \n
                endcase
            end else begin
                case (idx)
                    5'd0:  msg_byte = "M";
                    5'd1:  msg_byte = "=";
                    5'd2:  msg_byte = 8'h30 + (deg360 / 100);
                    5'd3:  msg_byte = 8'h30 + ((deg360 / 10) % 10);
                    5'd4:  msg_byte = 8'h30 + (deg360 % 10);
                    5'd5:  msg_byte = " ";
                    5'd6:  msg_byte = "E";
                    5'd7:  msg_byte = "=";
                    5'd8:  msg_byte = hex_asc(pwr[31:28]);
                    5'd9:  msg_byte = hex_asc(pwr[27:24]);
                    5'd10: msg_byte = hex_asc(pwr[23:20]);
                    5'd11: msg_byte = hex_asc(pwr[19:16]);
                    5'd12: msg_byte = hex_asc(pwr[15:12]);
                    5'd13: msg_byte = hex_asc(pwr[11:8]);
                    5'd14: msg_byte = hex_asc(pwr[7:4]);
                    5'd15: msg_byte = hex_asc(pwr[3:0]);
                    5'd16: msg_byte = " ";
                    5'd17: msg_byte = "V";
                    5'd18: msg_byte = "=";
                    5'd19: msg_byte = 8'h30 + {7'd0, mot[1]};   // v1
                    5'd20: msg_byte = 8'h30 + {7'd0, mot[0]};   // v2
                    5'd21: msg_byte = 8'h0D;   // \r
                    default: msg_byte = 8'h0A;   // \n
                endcase
            end
        end
    endfunction

    // ---- banner 第 idx 个字节（尾部补 \r\n）----
    function [7:0] boot_byte;
        input [4:0] idx;
        begin
            case (idx)
                5'd14: boot_byte = 8'h0D;   // \r
                5'd15: boot_byte = 8'h0A;   // \n
                default: boot_byte = BANNER[((5'd14 - 1'b1) - idx) * 8 +: 8];
            endcase
        end
    endfunction

    // 当前消息长度（按类型）
    wire [4:0] msg_len = msg_is_das ? DAS_LEN : MVDR_LEN;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            baud_cnt   <= 16'd0;
            bit_cnt    <= 4'd0;
            shift      <= 10'd0;
            idx        <= 5'd0;
            booting    <= 1'b1;    // 复位后先发 banner
            pending    <= 1'b1;
            msg_is_das <= 1'b0;
            das_req    <= 1'b0;
            mvdr_req   <= 1'b0;
            doa_latch  <= 9'd0;
            pwr_latch  <= 32'd0;
            mot_latch  <= 2'd0;
            uart_txd   <= 1'b1;    // 空闲高电平
        end else begin
            // ---- 粘滞锁存请求（发送期间也不丢，先挂着）----
            if (das_done)  das_req  <= 1'b1;
            if (doa_done)  mvdr_req <= 1'b1;

            case (state)
            S_IDLE: begin
                uart_txd <= 1'b1;      // 空闲保持高
                baud_cnt <= 16'd0;
                if (booting) begin
                    if (pending) begin
                        shift <= {1'b1, boot_byte(idx), 1'b0};
                        bit_cnt  <= 4'd0;
                        baud_cnt <= 16'd0;
                        state    <= S_BIT;
                    end
                end else begin
                    // 接受请求（MVDR 优先）；接受后 pending=1，下一拍才载入首字节
                    if (mvdr_req && !pending) begin
                        msg_is_das <= 1'b0;
                        doa_latch  <= doa_deg;
                        pwr_latch  <= pwr;
                        mot_latch  <= {mot_v1, mot_v2};
                        mvdr_req   <= 1'b0;
                        pending    <= 1'b1;
                        idx        <= 5'd0;
                    end else if (das_req && !pending) begin
                        msg_is_das <= 1'b1;
                        doa_latch  <= das_doa;
                        pwr_latch  <= das_pwr;
                        das_req    <= 1'b0;
                        pending    <= 1'b1;
                        idx        <= 5'd0;
                    end
                    if (pending) begin
                        shift <= {1'b1, msg_byte(idx, msg_is_das, doa_latch, pwr_latch, mot_latch), 1'b0};
                        bit_cnt  <= 4'd0;
                        baud_cnt <= 16'd0;
                        state    <= S_BIT;
                    end
                end
            end

            S_BIT: begin
                if (baud_cnt == BAUD_DIV - 16'd1) begin
                    baud_cnt <= 16'd0;
                    uart_txd <= shift[0];               // 移出最低位
                    shift    <= {1'b0, shift[9:1]};
                    if (bit_cnt == 4'd9) begin
                        // 本字节 10 bit 发完
                        bit_cnt <= 4'd0;
                        state   <= S_IDLE;
                        if (booting) begin
                            if (idx == BOOT_LEN - 1'b1) begin
                                booting <= 1'b0;
                                idx     <= 5'd0;
                                pending <= 1'b0;
                            end else
                                idx <= idx + 5'd1;
                        end else begin
                            if (idx == msg_len - 1'b1) begin
                                idx     <= 5'd0;
                                pending <= 1'b0;
                            end else
                                idx <= idx + 5'd1;
                        end
                    end else
                        bit_cnt <= bit_cnt + 4'd1;
                end else
                    baud_cnt <= baud_cnt + 16'd1;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
