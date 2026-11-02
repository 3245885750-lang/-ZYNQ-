`timescale 1ns / 1ps
// ============================================================
// gen_steer_rom_tb.v —— 导向向量 ROM 数据生成器（跑一次即可）
//
// 生成 361 个角度 x 8 通道 的导向向量 a(theta)（Q16.16），
// 写成两个 $readmemh 用的十六进制文件：
//     src/steer_re.mem   实部
//     src/steer_im.mem   虚部
// 索引顺序： addr = ang*8 + ch，  ang = 0..360 对应角度 deg = ang - 180
//
// a_i(theta) = cos(kR*cos(theta-alpha_i)) - j*sin(kR*cos(theta-alpha_i))
//              alpha_i = 2*pi*i/8       （均匀圆周阵列 UCA，R=0.05m）
//              kR = 2*pi*f0*R/c ≈ 3.7565 rad
//
// ⚠️ 圆周阵列（最终 PCB）。之前并排测试用的是直线阵列（已弃用）：
//     tau_i = (x_i/c)*sin(theta)、x_i = i*d、d=1.6cm。
//   圆周阵列里没有麦在阵列中心，ch0 也有相位（a_0(0°) = exp(-j*kR)）。
//
// 公式必须和 gen_steer_4khz.py / mvdr_sweep_tb / bf_mvdr_tb 里的完全一致。
//
// 用法：把这个 tb 设成仿真顶层，Run Simulation，看输出文件是否生成。
// （也可直接用 sim/gen_steer_4khz.py 生成，公式与本 tb 一致，更快。）
// ============================================================
module gen_steer_rom_tb;

    localparam integer NCH  = 8;
    localparam integer NANG = 361;

    real pi = 3.14159265358979323846;
    real c = 343.0;
    real R = 0.05;    // 圆周阵列半径 5cm
    // 采样率 = 50MHz/16(SCK分频)/64(WS=SCK/64) = 48828.125 Hz
    //   bin=43：f0 ≈ 4100.8Hz，R/λ=0.598，kR=3.7565（无空间混叠）
    real f0 = 43.0 * (50000000.0 / 16.0 / 64.0) / 512.0;
    real kR = 2.0 * pi * f0 * R / c;

    real th, ph, alpha;

    integer ang, ch, total;
    integer fre, fim;              // 文件句柄
    integer v_re, v_im;

    // Q16.16 量化（四舍五入）—— 和运行期 tb 一致
    function integer q16;
        input real x;
        begin
            if (x >= 0.0) q16 = $floor(x*65536.0 + 0.5);
            else          q16 = $ceil (x*65536.0 - 0.5);
        end
    endfunction

    initial begin
        fre = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/src/steer_re.mem", "w");
        fim = $fopen("D:/Engineering_save/FPGA/AMD_ZYNQ/fft_demo/src/steer_im.mem", "w");
        if (fre == 0 || fim == 0) begin
            $display("ERROR: cannot open output files");
            $finish;
        end

        total = 0;
        for (ang = 0; ang < NANG; ang = ang + 1) begin
            th = (ang - 180) * pi / 180.0;         // ang 0 -> -180 度
            for (ch = 0; ch < NCH; ch = ch + 1) begin
                alpha = ch * 2.0 * pi / NCH;       // 第 ch 个麦的角度 α_i
                ph = kR * $cos(th - alpha);        // 圆周：a_i = exp(-j*kR*cos(θ-α_i))
                v_re = q16( $cos(ph));
                v_im = q16(-$sin(ph));
                $fwrite(fre, "%08h\n", v_re[31:0]);
                $fwrite(fim, "%08h\n", v_im[31:0]);
                total = total + 1;
            end
        end
        $fclose(fre);
        $fclose(fim);

        $display("==============================================");
        $display("steer ROM data generated (UCA, R=0.05m)");
        $display("  angles  = %0d (deg -180..180, step 1)", NANG);
        $display("  channels= %0d", NCH);
        $display("  kR      = %.4f rad", kR);
        $display("  entries = %0d per file", total);
        $display("  -> src/steer_re.mem , src/steer_im.mem");
        $display("==============================================");
        $display("now rerun steer_rom_tb (ROM + sweep integration)");
        $finish;
    end

endmodule
