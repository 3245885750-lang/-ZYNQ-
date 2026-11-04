// ============================================================
// radar_pl_bd_verify_top.v  ——  【仅用于验证】radar_pl_top_bd 的包装顶层
//
// 目的：
//   radar_pl_top_bd 是给 Block Design 用的模块，它带 141 个 AXI 端口。
//   在 BD 里这些端口连的是 AXI Interconnect / DMA，不会变成芯片引脚。
//   但如果把它单独设为综合顶层，Vivado 会尝试把它们全部放到引脚上，
//   而板子上没有这么多空脚 -> [Place 30-58] IO placement is infeasible。
//
//   本模块只把板子上真实存在的引脚引出来（sys_clk / sys_rst_n / sd /
//   sck / ws / led0 / led1 / uart_txd），把 AXI 端口在内部接死，
//   这样就能对 radar_pl_top_bd 做完整的综合 + 实现 + 时序分析。
//
// ⚠️ 这不是交付顶层，不要给队友 B。B 用的是 radar_pl_top_bd 本身。
// ⚠️ 这里的时序结果只反映 PL 内部逻辑，不含 PS 侧 AXI 互联约束，
//    不能替代 BD 工程里的最终时序签核。
//
// 接死策略：
//   - AXI4-Lite 从机输入全部拉 0：BD 里没有 master 时从机就一直空闲。
//   - 从机输出悬空：不引出引脚。
//   - bready / rready 拉 1：万一从机有响应也能收完，避免挂住。
//   - m_axis_audio_tready / fft_axis_tready 拉 1：不做背压。
//     注意这会让 packetizer 的停顿分支不被激励，只验证正常数据通路。
// ============================================================
module radar_pl_bd_verify_top (
    input  wire        sys_clk,     // U18, 50MHz
    input  wire        sys_rst_n,   // N16, 低有效
    input  wire [7:0]  sd,          // 8 路麦克风数据（J4 排针）
    output wire        sck,         // 位时钟
    output wire        ws,          // 字选择
    output wire        led0,        // H15, 心跳灯
    output wire        led1,        // L15, DOA 命中灯
    output wire        uart_txd     // J15, 串口打印 DOA
);

    // ---- AXI4-Stream 主口：不做背压 ----
    wire        fft_axis_tready  = 1'b1;
    wire        audio_tready     = 1'b1;

    radar_pl_top_bd u_dut (
        .sys_clk (sys_clk),
        .sys_rst_n(sys_rst_n),
        .sd      (sd),
        .sck     (sck),
        .ws      (ws),
        .led0    (led0),
        .led1    (led1),
        .uart_txd(uart_txd),

        // ---- AXI4-Lite 从机：无 master，保持空闲 ----
        .s_axi_awaddr (32'd0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),           // 输出悬空
        .s_axi_wdata  (32'd0),
        .s_axi_wstrb  (4'd0),
        .s_axi_wvalid (1'b0),
        .s_axi_wready (),           // 输出悬空
        .s_axi_bresp  (),           // 输出悬空
        .s_axi_bvalid (),           // 输出悬空
        .s_axi_bready (1'b1),
        .s_axi_araddr (32'd0),
        .s_axi_arvalid(1'b0),
        .s_axi_arready(),           // 输出悬空
        .s_axi_rdata  (),           // 输出悬空
        .s_axi_rresp  (),           // 输出悬空
        .s_axi_rvalid (),           // 输出悬空
        .s_axi_rready (1'b1),

        // ---- 波束成形音频流：常收 ----
        .m_axis_audio_tdata (),
        .m_axis_audio_tvalid(),
        .m_axis_audio_tready(audio_tready),
        .m_axis_audio_tlast (),

        // ---- 频谱流（SFP8 v1 包头）：常收 ----
        .fft_axis_tdata (),
        .fft_axis_tvalid(),
        .fft_axis_tlast (),
        .fft_axis_tready(fft_axis_tready)
    );

endmodule
