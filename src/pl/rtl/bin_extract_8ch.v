// ============================================================
// bin_extract_8ch.v  ——  从 FFT 输出流抽取 8 个目标 bin 的 8 路复数谱
//
// 作用：FFT 是按通道串行输出的（ch0 的 512 个 bin → ch1 的 512 个 bin
//       → ... → ch7），每帧最后一点 tlast=1。波束成形需要同一个 bin
//       的 8 路值同时拿到，本模块就从流里"抽"出 8 个目标 bin 的 8 路值。
//
// 宽带 MVDR 版：同时抽 BIN0..BIN7 八个 bin，八组谱在同一帧末（ch_cnt==7）
//       同拍给出（8 组 8 路都齐）。
//
// 输出：X_re/X_im 打包，bin b 的第 ch 路 = X_re[(b*8+ch)*XW +: XW]，
//       ready = 1 拍脉冲（八组都抽齐时）。
//
// 数据格式：FFT 的 tdata[63:0] = {imag[31:0], real[31:0]}，
//           real 在低 32 位。这里截取高 XW 位（re 取 [31:8]，im 取 [63:40]），
//           即 24 bit，保留相位信息、丢掉多余的低位。
// ============================================================
module bin_extract_8ch #(
    parameter BIN0 = 5,    // bin 列表：476.9Hz .. 4100.8Hz 分散频段
    parameter BIN1 = 10,
    parameter BIN2 = 15,
    parameter BIN3 = 20,
    parameter BIN4 = 25,
    parameter BIN5 = 31,
    parameter BIN6 = 37,
    parameter BIN7 = 43,
    parameter XW   = 24,   // 每路谱值的位宽
    parameter NB   = 8     // 频点数
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [63:0] s_axis_tdata,   // {im[31:0], re[31:0]}
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tready,  // 上游流推进（= tvalid & 全局 tready），背压时防重复采样
    input  wire        s_axis_tlast,

    output reg  [NB*8*XW-1:0] X_re,    // 8 bin × 8 路 real（打包）
    output reg  [NB*8*XW-1:0] X_im,    // 8 bin × 8 路 imag（打包）
    output reg          ready           // 1 拍脉冲：八组 8 路都齐了
);

    reg [9:0] bin_cnt;   // 当前帧内的 bin 计数 0..511
    reg [2:0] ch_cnt;    // 当前第几路 0..7

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_cnt <= 0;
            ch_cnt  <= 0;
            X_re    <= 0;
            X_im    <= 0;
            ready   <= 1'b0;
        end else begin
            ready <= 1'b0;   // 默认不发
            if (s_axis_tvalid && s_axis_tready) begin
                // 抽目标 bin：各自存进当前路
                if (bin_cnt == BIN0) begin X_re[(0*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(0*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN1) begin X_re[(1*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(1*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN2) begin X_re[(2*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(2*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN3) begin X_re[(3*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(3*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN4) begin X_re[(4*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(4*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN5) begin X_re[(5*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(5*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN6) begin X_re[(6*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(6*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                if (bin_cnt == BIN7) begin X_re[(7*8+ch_cnt)*XW +: XW] <= s_axis_tdata[31:8]; X_im[(7*8+ch_cnt)*XW +: XW] <= s_axis_tdata[63:40]; end
                // 帧推进
                if (s_axis_tlast) begin
                    if (ch_cnt == 3'd7) begin
                        ready  <= 1'b1;   // 第 8 路也结束：八组都齐
                        ch_cnt <= 0;
                    end else begin
                        ch_cnt <= ch_cnt + 1'b1;
                    end
                    bin_cnt <= 0;
                end else begin
                    bin_cnt <= bin_cnt + 1'b1;
                end
            end
        end
    end

endmodule
