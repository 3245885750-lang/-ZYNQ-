`timescale 1ns / 1ps
// Vector replay for transient_tdoa.
//
// Input : sim/vec/current.hex, one 128-bit hex word per line, {ch7,...,ch0}
// Clock : 50 MHz; sample_valid every 1024 clk = 48.828 kHz
// Run   : from the repository root, so the relative path resolves.
//
// Before each run:
//   Copy-Item sim\vec\vec_000.hex sim\vec\current.hex
// Then:
//   xvlog sim\tb\tb_tdoa_replay.v src\pl\rtl\radar_pl_top_bd.v
//   xelab tb_tdoa_replay -s elab_replay
//   xsim elab_replay -runall
module tb_tdoa_replay;

    localparam integer NSAMP = 33202;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg [127:0] mem [0:NSAMP-1];
    reg [15:0]  tick;
    reg [15:0]  idx;
    reg [127:0] sample_data;
    reg         sample_valid;

    wire signed [8:0] doa_deg;
    wire              doa_valid;
    wire              doa_lowconf;
    wire              busy;

    integer nres;

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

    always #10 clk = ~clk;          // 50 MHz

    always @(posedge clk) begin
        if (!rst_n) begin
            tick         <= 16'd0;
            idx          <= 16'd0;
            sample_data  <= 128'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (tick == 16'd1023) begin
                tick         <= 16'd0;
                sample_data  <= mem[idx];
                sample_valid <= 1'b1;
                if (idx < NSAMP-1)
                    idx <= idx + 16'd1;
            end else begin
                tick <= tick + 16'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (doa_valid) begin
            $display("RESULT idx=%0d doa=%0d lowconf=%0d busy=%0d sw=%0d A=%0d B=%0d ab2=%0d sd2=%0d coh_ok=%0d",
                     idx, doa_deg, doa_lowconf, busy,
                     dut.sw, dut.Areg, dut.Breg, dut.ab2_c, dut.sd2_acc, dut.coh_ok);
            nres <= nres + 1;
        end
    end

    initial begin
        nres = 0;
        $readmemh("sim/vec/current.hex", mem);
        $display("loaded sim/vec/current.hex");
        repeat (20) @(posedge clk);
        rst_n <= 1'b1;
        wait (idx == NSAMP-1);
        repeat (5000) @(posedge clk);
        $display("DONE results=%0d", nres);
        $finish;
    end

    initial begin
        #1000000000;                // 1 s sim timeout
        $display("TIMEOUT idx=%0d results=%0d", idx, nres);
        $finish;
    end

endmodule
