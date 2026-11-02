// ============================================================
// bf_das_core.v  ——  8 路复数加权求和（delay-and-sum 的核心 MAC）
//
// 作用：对某个频率 bin、某个扫描角度 θ，算：
//        y = Σ_i X_i · w_i
//        w_i = e^{-j·2πf0·τ_i(θ)} = cos(φ_i) - j·sin(φ_i)
//  其中 X_i 是第 i 路的复数谱（bin_extract_8ch 的输出），
//        w_i 是导向权重（由外部算好送进来，这里只做乘加）。
//
// 复数乘加（实部/虚部分别算）：
//   y_re = Σ (X_re·W_re - X_im·W_im)
//   y_im = Σ (X_re·W_im + X_im·W_re)
//
// 定点格式：
//   X : XW=24 bit 有符号
//   W : WW=16 bit 有符号，Q1.15（值 = W/32768，范围约 [-1,1]）
//   乘积 24×16=40 bit，累加 8 项放 48 bit，不会溢出。
//
// 延迟：1 个时钟（输出寄存）。
// 注意：功率 |y|² 和扫角度找最大值先放 testbench 做，本模块只算 y。
// ============================================================
module bf_das_core #(
    parameter NCH = 8,
    parameter XW  = 24,   // X 位宽
    parameter WW  = 16    // W 位宽
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [NCH*XW-1:0] X_re,   // 8 路 real
    input  wire [NCH*XW-1:0] X_im,   // 8 路 imag
    input  wire [NCH*WW-1:0] W_re,   // 8 路权重 real
    input  wire [NCH*WW-1:0] W_im,   // 8 路权重 imag

    output reg  [47:0] y_re,   // 加权和实部
    output reg  [47:0] y_im    // 加权和虚部
);

    integer i;
    reg signed [47:0] acc_re, acc_im;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_re <= 48'd0;
            y_im <= 48'd0;
        end else begin
            acc_re = 48'sd0;
            acc_im = 48'sd0;
            for (i = 0; i < NCH; i = i + 1) begin
                acc_re = acc_re
                       + $signed(X_re[i*XW +: XW]) * $signed(W_re[i*WW +: WW])
                       - $signed(X_im[i*XW +: XW]) * $signed(W_im[i*WW +: WW]);
                acc_im = acc_im
                       + $signed(X_re[i*XW +: XW]) * $signed(W_im[i*WW +: WW])
                       + $signed(X_im[i*XW +: XW]) * $signed(W_re[i*WW +: WW]);
            end
            y_re <= acc_re;
            y_im <= acc_im;
        end
    end

endmodule
