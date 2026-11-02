## ============================================================
## radar_pl.xdc —— 正点原子 ZYNQ-7020 领航者
## 芯片：xc7z020clg400-2
## ============================================================

## ---- 系统时钟 / 复位 ----
set_property PACKAGE_PIN U18 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

set_property PACKAGE_PIN N16 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

## ---- LED ----
set_property PACKAGE_PIN H15 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property PACKAGE_PIN L15 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

## ---- INMP441 I2S：8 路 SD（输入）+ SCK/WS（输出）----
## 引脚来自底板 J4（EXT_IO）排针上的 BANK13（Z7020 专属，3.3V）：
##   J4-3 = U5  = sck    J4-4 = T5  = ws
##   J4-5 = V7  = sd[0]  J4-6 = U7  = sd[1]
##   J4-7 = W8  = sd[2]  J4-8 = V8  = sd[3]
##   J4-9 = U9  = sd[4]  J4-10= U8  = sd[5]
##   J4-11= U10 = sd[6]  J4-12= T9  = sd[7]
set_property IOSTANDARD LVCMOS33 [get_ports {sck ws sd[0] sd[1] sd[2] sd[3] sd[4] sd[5] sd[6] sd[7]}]

set_property PACKAGE_PIN U5  [get_ports sck]
set_property PACKAGE_PIN T5  [get_ports ws]
set_property PACKAGE_PIN V7  [get_ports {sd[0]}]
set_property PACKAGE_PIN U7  [get_ports {sd[1]}]
set_property PACKAGE_PIN W8  [get_ports {sd[2]}]
set_property PACKAGE_PIN V8  [get_ports {sd[3]}]
set_property PACKAGE_PIN U9  [get_ports {sd[4]}]
set_property PACKAGE_PIN U8  [get_ports {sd[5]}]
set_property PACKAGE_PIN U10 [get_ports {sd[6]}]
set_property PACKAGE_PIN T9  [get_ports {sd[7]}]

## ---- USB UART（PL 端，底板 Type-C，CH340）----
## 只发不收，用 TX 一根线。底板跳帽 P5 要拨到「PL UART」位置（3&5、4&6），
## 这样 CH340 才接到 PL 的 UART3，而不是 PS 的 UART1。
## 引脚来自正点原子官方例程：uart_txd = J15（uart_rxd = T19，本设计不用）。
set_property PACKAGE_PIN J15 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

## ---- 时序说明 ----
## SCK(3.125MHz)/WS(48.828kHz) 都是低速输出，20ns 主时钟约束已足够，
## 无需额外约束。后续若加 PS 的 AXI（FCLK_CLK0 100MHz）再补跨时钟域约束。
