`timescale 1ns / 1ps
// ============================================================
// axi_lite_regs.v —— 通用 AXI4-Lite 从机 → 简单寄存器总线适配器
//
// 把 AXI4-Lite 那套（AW/W/B/AR/R 五个通道）翻译成最朴素的形式：
//   写：wr_en 一拍脉冲 + wr_addr + wr_data + wr_strb
//   读：rd_addr（组合给出，接上层的数据 mux）→ 上层返回 rd_data
//
// 上层要做的就是：
//   1) always @(posedge clk) if (wr_en) case (wr_addr) ... endcase   写寄存器
//   2) assign rd_data = (rd_addr==0) ? r0 : (rd_addr==1) ? r1 : ...  读 mux
//
// 时序（都按 AXI4-Lite 标准握手，支持 AW/W 各自独立到达）：
//   写：wready/awready 空闲时都为 1；两者都收到后一拍产生 wr_en 脉冲并回 B
//   读：arready 空闲时为 1；收到 AR 后下一拍 rvalid=1 并给出 rdata
//
// 地址：用字节地址的 [5:2] 作为字地址（低 6 位 = 64 字节 = 16 个寄存器），
//       高位忽略（由互连决定基地址）。
// ============================================================
module axi_lite_regs #(
    parameter integer ADDR_BITS = 4      // 字地址位宽（默认 16 个 32bit 寄存器）
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---------------- AXI4-Lite 从机接口 ----------------
    input  wire [31:0]         s_axi_awaddr,
    input  wire                s_axi_awvalid,
    output reg                 s_axi_awready,
    input  wire [31:0]         s_axi_wdata,
    input  wire [3:0]          s_axi_wstrb,
    input  wire                s_axi_wvalid,
    output reg                 s_axi_wready,
    output reg  [1:0]          s_axi_bresp,
    output reg                 s_axi_bvalid,
    input  wire                s_axi_bready,
    input  wire [31:0]         s_axi_araddr,
    input  wire                s_axi_arvalid,
    output reg                 s_axi_arready,
    output reg  [31:0]         s_axi_rdata,
    output reg  [1:0]          s_axi_rresp,
    output reg                 s_axi_rvalid,
    input  wire                s_axi_rready,

    // ---------------- 用户侧：写 ----------------
    output reg                 wr_en,     // 一拍脉冲
    output reg  [ADDR_BITS-1:0] wr_addr,
    output reg  [31:0]         wr_data,
    output reg  [3:0]          wr_strb,

    // ---------------- 用户侧：读 ----------------
    output wire [ADDR_BITS-1:0] rd_addr,  // 组合给出，上层据此做 mux
    input  wire [31:0]         rd_data
);

    // ================= 写通道 =================
    reg        aw_en, w_en;          // 各自是否已收到
    reg [31:0] awaddr_r, wdata_r;
    reg [3:0]  wstrb_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_en <= 1'b0;
            w_en  <= 1'b0;
            wr_en <= 1'b0;
            awaddr_r <= 0; wdata_r <= 0; wstrb_r <= 0;
            wr_addr <= 0; wr_data <= 0; wr_strb <= 0;
        end else begin
            wr_en <= 1'b0;                       // 默认不发写脉冲

            // --- 收 AW ---
            if (s_axi_awready && s_axi_awvalid && !aw_en) begin
                awaddr_r      <= s_axi_awaddr;
                aw_en         <= 1'b1;
                s_axi_awready <= 1'b0;
            end
            // --- 收 W ---
            if (s_axi_wready && s_axi_wvalid && !w_en) begin
                wdata_r      <= s_axi_wdata;
                wstrb_r      <= s_axi_wstrb;
                w_en         <= 1'b1;
                s_axi_wready <= 1'b0;
            end
            // --- 两者都到 → 发写脉冲 + 回 B ---
            if (aw_en && w_en && !s_axi_bvalid) begin
                wr_en        <= 1'b1;
                wr_addr      <= awaddr_r[ADDR_BITS+1:2];
                wr_data      <= wdata_r;
                wr_strb      <= wstrb_r;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;           // OKAY
                aw_en        <= 1'b0;
                w_en         <= 1'b0;
            end
            // --- B 握手完成 → 释放 ---
            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid  <= 1'b0;
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
            end
        end
    end

    // ================= 读通道 =================
    // 地址组合给出，上层 mux 立刻稳定；AR 握手那一拍就把数据锁进来（单拍读）
    assign rd_addr = s_axi_araddr[ADDR_BITS+1:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b1;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rdata   <= rd_data;        // 上层 mux 此时已稳定
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                s_axi_arready <= 1'b0;
            end
            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid  <= 1'b0;
                s_axi_arready <= 1'b1;
            end
        end
    end

endmodule
