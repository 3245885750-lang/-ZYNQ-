`timescale 1ns / 1ps
// 5 s noise-only replay: count any doa_valid (false triggers).
//
// Input: sim/vec/noise30_5s.hex
// Run from the repository root:
//   xvlog sim\tb\tb_false_trig.v src\pl\rtl\radar_pl_top_bd.v
//   xelab tb_false_trig -s elab_noise
//   xsim elab_noise -runall
module tb_false_trig;

    localparam integer NSAMP = 244140;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg [127:0] mem [0:NSAMP-1];
    reg [17:0]  tick;
    reg [17:0]  idx;
    reg [127:0] sample_data;
    reg         sample_valid;

    wire signed [8:0] doa_deg;
    wire              doa_valid;
    wire              doa_lowconf;
    wire              busy;

    integer nres;
    integer nlow;

    transient_tdoa dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_data  (sample_data),
        .sample_valid (sample_valid),
        .doa_deg      (doa_deg),
        .doa_valid    (doa_valid),
        .doa_lowconf  (doa_lowconf),
        .busy         (busy)
    );

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            tick         <= 18'd0;
            idx          <= 18'd0;
            sample_data  <= 128'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (tick == 18'd1023) begin
                tick         <= 18'd0;
                sample_data  <= mem[idx];
                sample_valid <= 1'b1;
                if (idx < NSAMP-1)
                    idx <= idx + 18'd1;
            end else begin
                tick <= tick + 18'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (doa_valid) begin
            $display("FALSE_TRIG idx=%0d doa=%0d lowconf=%0d", idx, doa_deg, doa_lowconf);
            nres <= nres + 1;
            if (doa_lowconf) nlow <= nlow + 1;
        end
    end

    initial begin
        nres = 0;
        nlow = 0;
        $readmemh("sim/vec/noise30_5s.hex", mem);
        repeat (20) @(posedge clk);
        rst_n <= 1'b1;
        wait (idx == NSAMP-1);
        repeat (5000) @(posedge clk);
        $display("DONE valids=%0d lowconf=%0d", nres, nlow);
        $finish;
    end

    initial begin
        repeat (6) #1_000_000_000;  // 6 s timeout (6e9 overflows 32-bit)
        $display("TIMEOUT idx=%0d valids=%0d", idx, nres);
        $finish;
    end

endmodule
