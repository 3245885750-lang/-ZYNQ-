# 在另一台电脑上下载板卡程序

本包是板卡下载包，和PC接收显示包用途不同。包含已匹配的PL位流.bit、PS程序.elf、DDR/MIO初始化脚本、JTAG下载脚本。
适用现有正点原子领航者ZYNQ7020 400-2板卡及已连接的八麦阵列，不适用任意其他ZYNQ板。

## 第一次准备

1. 电脑需要安装AMD Vitis（建议与本项目相同2026.1），安装其JTAG/Cable驱动，提供bin/xsdb.bat和hw_server。只装Python或只接网线不能给板卡下载。
2. 解压到本机文件夹，建议D:\radar_board；不要在压缩包里直接运行。保留payload及所有文件的相对位置。
3. 板卡正常供电，麦克风阵列保持连接，使用JTAG下载器/USB JTAG线连接这台电脑。USB串口CH340仅用于日志，不能代替JTAG。网线连接GE_PS和PC网卡。
4. 保持此前已验证的板卡启动拨码设置。如当前JTAG不能控制芯片，按板卡手册设置JTAG下载模式，再断电重上电；不要凭其他型号板卡的拨码图更改。

## 下载

双击download.cmd。脚本会校验文件、寻找本机Vitis的XSDB、启动本机hw_server、加载PL位流、初始化PS/DDR、下载PS ELF、注入本次启动标识并运行，随后读取运行计数。
第一次找不到工具时，会提示粘贴本机的xsdb.bat完整路径。举例：D:\AMD\2026.1\Vitis\bin\xsdb.bat（只是举例，以电脑实际安装位置为准）。

也可以在解压目录的PowerShell运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\download.ps1 -XsdbPath "D:\AMD\2026.1\Vitis\bin\xsdb.bat"
```

看到DOWNLOAD_OK才表示下载并启动后的板端检查通过。PS-LED0应亮，采音/模型计数增长；发送计数仅表示板端协议栈接受数据，不证明PC网页已收到。
失败时发logs里的download日志。找不到芯片需要检查供电/JTAG/驱动；不要反复只换网线尝试烧录。

## 继续在原网页显示

本次下载不需要在这台电脑重新训练或编译，也不用导入Vivado工程。
PC以太网IPv4仍设192.168.1.100，掩码255.255.255.0；板卡192.168.1.10，发送到UDP9000。
保留原来的以太网接收服务和原网页，按PC交接包中的《接入已有网页》合入v3解析及九类映射。
不要同时启动另一份web_receiver.py抢占UDP9000。独立测试网页和原服务二选一接收。

## 范围

这是JTAG临时下载：断电后需要再次运行download.cmd。没有写入SD卡/Flash启动镜像，不会因为把ZIP复制到SD卡就自动启动。
九类为拍手、说话、钢琴、鸟叫、狗叫、鸣笛、流水、拉链、敲键盘；另有安静和不确定。模型离线文件准确率约68%，仍是待实测改进的候选版。

只检查文件而不接触板卡可运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\download.ps1 -VerifyOnly
```
