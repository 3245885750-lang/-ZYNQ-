# AXI-Stream 握手与 TLAST 自查

## 适用场景

AXI-Stream 数据通路在仿真里正常，上板后 DMA 收到不完整帧、PS 侧音频断断续续、
或者帧边界错位。尤其是自己写的 AXI-Stream 从机（不是 Xilinx IP）把数据送进 DMA 时。

## 使用方法

逐条对照下面五项检查，任何一项不满足都可能导致「仿真过、上板挂」：

1. **TLAST 必须与 TVALID 同时有效，并在握手完成前保持**。
   常见错误：只在产生最后一个数据的那一拍拉高 TLAST，下一拍 TVALID 仍为高
   但 TLAST 已经落下。DMA 看到的是两个不完整帧。
2. **TVALID 一旦拉高，在 TREADY 到来前不得撤销**，数据也必须保持。
3. **TREADY 与 TVALID 同拍**：FIFO 满时读侧和写侧可能在同一拍同时动作，
   判断「满」要用「满且本拍没有读」的组合条件，否则会丢一个数据。
4. **TLAST 的计数基准**：每帧点数是否等于 DMA 配置的 `Length`；
   8 路分时复用时，是每路一个 TLAST 还是整轮一个 TLAST，必须和 DMA 配置一致。
5. **背压传播**：下游停住时，上游是否真的停住；如果上游是 FFT 等有内部状态的
   模块，停住后能否从正确位置继续。

仓库内的相关实现与验证：

```
src/pl/rtl/bf_audio_out.v      # 波束音频输出（TLAST 修复点）
sim/tb/bf_audio_out_tb.v       # 覆盖 TLAST 与背压的 testbench
src/pl/constraints/source_changes.diff  # 交付版本相对基线的改动
```

## 已验证效果

交付版本相对基线 IP 的改动集中在 `bf_audio_out.v` 的 TLAST 时序与
`mvdr_axi_top.v` 的寄存器接口。修复后 PS 侧连续收帧不再出现半帧，
波束音频 97.7 kB/s 稳定。

## 失效条件

- 如果下游不是 AXI DMA 而是自写逻辑，TLAST 语义可能不同，不能照搬。
- 跨时钟域时，TLAST 与数据必须一起过异步 FIFO；单独打拍会错位。
- 本检查不覆盖 AXI4-Lite 的握手（那是另一套规则）。

## 来源

`report/pl_ps_interface.md` 与 `src/pl/constraints/source_changes.diff`。
上板现象是「仿真完全正确、PS 收到的音频每帧少一点」，最终定位到 TLAST
没有跟随 TVALID。
