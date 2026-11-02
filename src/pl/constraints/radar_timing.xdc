# i2s_master.v drives SCK from clk_cnt[3]: 50 MHz / 16 = 3.125 MHz.
# This is a related generated clock, not asynchronous to sys_clk.
# Do not hide SCK -> sys_clk paths with blanket false paths/clock groups.
set radar_sck_pin [get_pins -hierarchical -regexp {^.*/u_master/clk_cnt_reg\[3\]/Q$}]
create_generated_clock -name i2s_sck -source [get_ports sys_clk] -divide_by 16 $radar_sck_pin
# External SD input delays and WS output timing still need the microphone's
# timing specification and board/cable delay budget. They are not invented here.
