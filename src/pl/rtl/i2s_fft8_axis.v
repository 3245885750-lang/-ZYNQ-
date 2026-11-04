// Two physical banks, two completed-descriptor slots. Supported: 8 x 512 x 16.
// A physical group always advances frame_id, including whole-group drops.
module i2s_fft8_axis #(
    parameter NCH=8, FRAME_LEN=512, DATA_W=16
)(
    input wire clk, rst_n,
    input wire [NCH*DATA_W-1:0] sample_data,
    input wire sample_valid,
    output wire [31:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast,
    output wire busy,
    output wire [63:0] m_axis_frame_id,
    output wire [2:0] m_axis_channel,
    output wire [63:0] m_axis_dropped_frames,
    output reg [63:0] capture_frames,
    output reg [63:0] dropped_frames,
    output reg [1:0] pending_count
);
    (* ram_style="distributed" *) reg [15:0] mem0[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem1[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem2[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem3[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem4[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem5[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem6[0:1023];
    (* ram_style="distributed" *) reg [15:0] mem7[0:1023];
    reg [1:0] bank_reserved;
    reg [8:0] wr_cnt, rd_cnt;
    reg wr_bank, wr_accept, rd_bank, rd_busy;
    reg [2:0] rd_ch;
    reg [63:0] rd_id, rd_drops;
    reg queue_bank[0:1];
    reg [63:0] queue_id[0:1], queue_drops[0:1];
    reg qwrite, qread;
    wire free_bank = !bank_reserved[0] || !bank_reserved[1];
    wire chosen_bank = bank_reserved[0];
    wire write_bank = wr_cnt==0 ? chosen_bank : wr_bank;
    wire write_sample = rst_n && sample_valid && (wr_cnt==0 ? free_bank : wr_accept);
    wire allocate_bank = sample_valid && wr_cnt==0 && free_bank;
    wire push = sample_valid && wr_cnt==511 && wr_accept;
    wire pop = !rd_busy && pending_count!=0;
    wire transfer = rd_busy && m_axis_tready;
    wire release_bank = transfer && rd_cnt==511 && rd_ch==7;
    wire [1:0] allocate_mask = allocate_bank ? (chosen_bank ? 2'b10 : 2'b01) : 2'b00;
    wire [1:0] release_mask = release_bank ? (rd_bank ? 2'b10 : 2'b01) : 2'b00;
    wire [9:0] address = {rd_bank,rd_cnt};
    reg [15:0] value;
    always @* begin
        case(rd_ch)
            0:value=mem0[address]; 1:value=mem1[address];
            2:value=mem2[address]; 3:value=mem3[address];
            4:value=mem4[address]; 5:value=mem5[address];
            6:value=mem6[address]; default:value=mem7[address];
        endcase
    end
    // Real signed16 occupies low16; imaginary input is zero, as in original IP.
    assign m_axis_tdata={16'd0,value};
    assign m_axis_tvalid=rd_busy;
    assign m_axis_tlast=rd_busy && rd_cnt==511;
    assign busy=rd_busy;
    assign m_axis_frame_id=rd_id;
    assign m_axis_channel=rd_ch;
    assign m_axis_dropped_frames=rd_drops;
    always @(posedge clk) if(write_sample) begin
        mem0[{write_bank,wr_cnt}]<=sample_data[0*16+:16];
        mem1[{write_bank,wr_cnt}]<=sample_data[1*16+:16];
        mem2[{write_bank,wr_cnt}]<=sample_data[2*16+:16];
        mem3[{write_bank,wr_cnt}]<=sample_data[3*16+:16];
        mem4[{write_bank,wr_cnt}]<=sample_data[4*16+:16];
        mem5[{write_bank,wr_cnt}]<=sample_data[5*16+:16];
        mem6[{write_bank,wr_cnt}]<=sample_data[6*16+:16];
        mem7[{write_bank,wr_cnt}]<=sample_data[7*16+:16];
    end
    // Queue storage has no asynchronous reset; occupancy/pointers invalidate
    // stale entries on reset. Keep storage separate from resettable control.
    always @(posedge clk) if(rst_n && push) begin
        queue_bank[qwrite]<=wr_bank;
        queue_id[qwrite]<=capture_frames;
        queue_drops[qwrite]<=dropped_frames;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            bank_reserved<=0; wr_cnt<=0; wr_bank<=0; wr_accept<=0;
            rd_cnt<=0; rd_bank<=0; rd_busy<=0; rd_ch<=0;
            rd_id<=0; rd_drops<=0; qwrite<=0; qread<=0;
            pending_count<=0; capture_frames<=0; dropped_frames<=0;
        end else begin
            // Allocation uses pre-edge ownership. A bank freed on the same edge
            // becomes eligible at the NEXT physical group boundary (conservative).
            bank_reserved <= (bank_reserved | allocate_mask) & ~release_mask;
            if(sample_valid) begin
                if(wr_cnt==0) begin wr_bank<=chosen_bank; wr_accept<=free_bank; end
                if(wr_cnt==511) begin
                    wr_cnt<=0; capture_frames<=capture_frames+1'b1;
                    if(!wr_accept) dropped_frames<=dropped_frames+1'b1;
                end else wr_cnt<=wr_cnt+1'b1;
            end
            case({push,pop})
                2'b10:pending_count<=pending_count+1'b1;
                2'b01:pending_count<=pending_count-1'b1;
                default:pending_count<=pending_count;
            endcase
            if(push) begin
                qwrite<=~qwrite;
            end
            if(pop) begin
                rd_bank<=queue_bank[qread]; rd_id<=queue_id[qread];
                rd_drops<=queue_drops[qread]; qread<=~qread;
                rd_cnt<=0; rd_ch<=0; rd_busy<=1;
            end else if(transfer) begin
                if(rd_cnt==511) begin
                    rd_cnt<=0;
                    if(rd_ch==7) rd_busy<=0;
                    else rd_ch<=rd_ch+1'b1;
                end else rd_cnt<=rd_cnt+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(NCH!=8 || FRAME_LEN!=512 || DATA_W!=16)
        $fatal(1,"Only 8 channels x 512 samples x 16 bits are supported");
    // synthesis translate_on
endmodule
