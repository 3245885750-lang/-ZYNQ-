# 实板采音进展

任务：八麦经 PL 合成一路 PCM，由 PS DMA 接收，先验证真实音频，再部署分类。

## 已确认

- JTAG 检出 xc7z020 和双 Cortex-A9。
- USB-SERIAL CH340 为 COM9，原 PL 串口为 115200 8N1。
- 原包有八麦采集和 bf_audio_out 音频输出；PS 接收程序不是重写采音。
- 已使用 radar_audio_bringup.xsa 生成独立 standalone BSP，编译 radar_pcm_capture.elf。
- 有限采集设计为 256 × 1024 个 int16 样本，约 5.369 秒；通过 JTAG 导出 DDR，不依赖串口跳帽。

## 首次上板发现的问题

FPGA 配置状态正常，但访问 DMA/PL 寄存器超时。检查实际生成的复位 IP 网表，
reset_50/reset_100 的 C_AUX_RESET_HIGH=0，即辅助复位低有效；集成却将 aux_reset_in 固定接 0。
因此复位会永久有效。此前定向算法/寄存器测试未覆盖厂商复位 IP，此问题未被发现。

修复：将两个复位 IP 的 C_AUX_RESET_HIGH 显式设置为 1，与常量 0 的非激活连接匹配。
修复脚本：F:/FPGA/Vitis_Workspace/radar_ps_audio_v2/fix_reset.tcl。
旧 bit/XSA/BD/报告保存在 capture/known_bad_reset_20261022，禁止继续作为可用上板版本。
新增复位释放仿真 tests/reset_release_tb.sv，检查 50/100 MHz 两域启动释放及再次复位后的释放。

当前还没有有效实板录音，不能将下载成功或离线声音分类成功当成采音成功。
