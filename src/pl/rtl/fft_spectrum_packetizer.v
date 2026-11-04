// Channel metadata must be queued at the first FFT INPUT handshake.
// The FFT core and this module MUST share reset and preserve channel order.
// Output: 8 header words + 512 raw FFT words, TLAST on payload only.
module fft_spectrum_packetizer(
    input wire clk, rst_n,
    input wire meta_valid,
    output wire meta_ready,
    input wire [63:0] meta_frame_id, meta_dropped_frames,
    input wire [2:0] meta_channel,
    input wire [63:0] s_fft_tdata,
    input wire s_fft_tvalid, s_fft_tlast,
    output wire s_fft_tready,
    output reg [63:0] m_axis_tdata,
    output wire m_axis_tvalid,
    output wire m_axis_tlast,
    input wire m_axis_tready,
    output reg [63:0] format_errors
);
    reg [63:0] ids[0:15], drops[0:15];
    reg [2:0] channels[0:15];
    reg [3:0] wp,rp;
    reg [4:0] count;
    reg [3:0] header_word;
    reg [9:0] payload_count;
    wire has_meta=count!=0;
    wire payload_phase=header_word==8;
    wire push=meta_valid && meta_ready;
    wire pop=has_meta && payload_phase && s_fft_tvalid && m_axis_tready && s_fft_tlast;
    assign meta_ready=count<16;
    assign s_fft_tready=has_meta && payload_phase && m_axis_tready;
    assign m_axis_tvalid=has_meta && (!payload_phase || s_fft_tvalid);
    assign m_axis_tlast=has_meta && payload_phase && s_fft_tlast;
    always @* begin
        case(header_word)
            0:m_axis_tdata={16'd64,16'd1,32'h38504653}; // bytes S F P 8
            1:m_axis_tdata=ids[rp];
            2:m_axis_tdata=ids[rp]<<9; // sample index, modulo 2^64
            3:m_axis_tdata=drops[rp];
            4:m_axis_tdata={32'd50000000,32'd1024};
            5:m_axis_tdata={16'd26,16'd32,16'd512,8'd8,5'd0,channels[rp]};
            6:m_axis_tdata={32'd4096,32'd15};
            7:m_axis_tdata=64'd0;
            default:m_axis_tdata=s_fft_tdata;
        endcase
    end
    // No reset on FIFO storage: reset count/pointers make all old entries invalid.
    always @(posedge clk) if(rst_n && push) begin
        ids[wp]<=meta_frame_id; drops[wp]<=meta_dropped_frames;
        channels[wp]<=meta_channel;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            wp<=0; rp<=0; count<=0; header_word<=0;
            payload_count<=0; format_errors<=0;
        end else begin
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:count<=count;
            endcase
            if(push) begin
                wp<=wp+1'b1;
            end
            if(m_axis_tvalid && m_axis_tready) begin
                if(!payload_phase) header_word<=header_word+1'b1;
                else if(s_fft_tlast) begin
                    if(payload_count!=511) format_errors<=format_errors+1'b1;
                    rp<=rp+1'b1; header_word<=0; payload_count<=0;
                end else begin
                    if(payload_count!=1023) payload_count<=payload_count+1'b1;
                end
            end
        end
    end
endmodule
