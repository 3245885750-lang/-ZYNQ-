# PL004 + 最新七类识别 + 麦克风实时频谱

使用交接包内配套的 bit、ELF 和 PS 初始化文件。不要只替换 ELF 后继续使用 PL 同学压缩包里的自检 bit；该自检顶层没有本项目的 PS、DDR、DMA 和以太网系统。

## 已有PC网页和UDP接收服务

继续使用原网页和原来的UDP9000接收服务。**不要同时开启包内备用接收服务，否则会占用同一端口。**

将 `pc/radar_protocol.py`、`pc/existing_page_adapter.py`、`pc/event_continuity.py` 一起复制到现有接收服务可导入的目录。在原服务的收包位置接入：

```python
from existing_page_adapter import ExistingPageAdapter
adapter = ExistingPageAdapter(board_ip="192.168.1.10")

# 原来服务里已经存在的UDP接收循环：
data, peer = sock.recvfrom(65535)
try:
    update = adapter.ingest(data, peer[0])
except (ValueError, TypeError, UnicodeError):
    update = None
if update is not None:
    # 调用你现有的 WebSocket/SSE/网页状态更新方法。
    publish_to_existing_page(update)
```

`publish_to_existing_page` 是接入点名称示例，请替换成原服务已有的网页推送函数；本包不替你另外绑定端口。原来的声位、类别分支继续保留，新增一个 `kind == "spectrum"` 分支即可。

- `kind == "doa"`：`angle_deg` 是PL004优化后的MVDR精确角度。无有效角度时为 `None`，不使用DAS角度替代。
- `kind == "classification"`：显示 `display_name`，右侧进度条使用 `scores`。当前仅七类；安静/等待时不显示模型得分条。`holding_gap` 为真时，显示的是3秒范围内暂时保持的上一结果。
- `kind == "spectrum"`：横坐标 `frequency_hz`，纵坐标 `dbfs`，单位 `dBFS`。一包是一条完整曲线，直接替换上一条，不累加。

各类数据独立更新。不要等待分类结果才刷新声位或频谱；不要用收到频谱包代替声位/类别的超时检查。页面可每50～100毫秒绘制一次最新数据，2秒没有某一类新数据时清除该流的实时标记。会话变化时清空其他旧结果，避免显示上次上电的数据。

## 下载到板卡

1. 在PC上解压到普通本地目录，例如 `D:\radar_pl004`。板卡连接电源和JTAG下载线；麦克风阵列按原接法连接。
2. 板卡 **GE_PS** 网口接PC的USB千兆网卡。继续使用原来的网卡设置：PC `192.168.1.100`、掩码 `255.255.255.0`；板卡程序是 `192.168.1.10`。UDP目的端口仍为9000。无需重新配置已经能工作的网卡和防火墙规则。
3. 双击 `download.cmd`。如果没有自动找到Vitis，按提示提供实际的 `Vitis\bin\xsdb.bat` 路径；也可在终端运行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\download.ps1 -XsdbPath "D:\AMD\2026.1\Vitis\bin\xsdb.bat"
   ```

4. 等待 `DOWNLOAD_OK`。如果出现 `NETWORK_NOT_READY`，说明程序已运行，但网口链路没有就绪，查看日志中的网络错误；这不等于PC已收到数据。首次分类需要约2秒音频历史，PL004也有定位冷启动抑制。
5. 启动/继续使用原PC接收服务，打开原网页。此时在麦克风旁发声，网页分别更新声位、类别和实时频谱。

本包是易失性JTAG下载：断电后需要重新下载，不自动改SD卡或Flash启动方式。下载脚本检查配套文件哈希、软件身份、采音/分类计数和音频丢帧；PC收包仍以PC服务实际接收为准。

## 没有原接收服务时的备用界面

只在没有其他程序占用UDP9000时使用：

```powershell
python .\pc\web_receiver.py
```

浏览器打开 `http://127.0.0.1:8768/`。运行接收端只需要Python3标准库，不需要在PC上重新训练模型。若使用 `py -3` 启动Python，也可将命令开头的 `python` 替换成 `py -3`。

## 当前声音类别和行为

拍手、说话、警笛、钟声、狗叫、汽车鸣笛、流水。协议保留九个槽位，玻璃破碎和发动机两个槽位停用；蝉鸣不在模型候选中。类别字典已经随PC接入文件更新，不能继续使用旧版“钢琴/鸟叫/拉链/键盘”的下标表。

声音门槛继续使用PL同一尺度的 `power > 64`。新一轮先观察100毫秒；同一轮中的短暂变弱不重新触发观察。连续低于门槛60秒才重新准备下一轮观察。页面原来的3秒间隙衔接单独保留，3秒后可显示安静，并不意味着立刻重开一轮。

## 本次实时频谱是什么

来自 **PL波束合成的干净单声道音频**，与CNN输入同源；不是七类预存音源的参考图，也不是根据识别标签伪造的曲线。

PS将该音频按原链路重采样到16kHz，取最新256个样本做去直流、Hann窗及FFT，输出129个频点（0～8kHz，间隔62.5Hz）。每5个DMA音频帧更新一次，标称约104.9毫秒。数值是数字满量程对应的dBFS，不是声压级dBSPL，不能用于绝对分贝计量。

本包的实时曲线是一条干净单声道频谱。PL004的八路复数SFP8接口源码保留；**八方位波束频谱不在这一次单声道频谱功能内**，本包没有把它冒充成八路频谱。当前硬件兼容顶层将SFP8输出持续接收并丢弃，避免未启动的FFT DMA反压PL定位链路。

## 版本验证范围

PL004的角度预测、异常值判断和显示限速已分级寄存，修复原先50MHz下的组合路径过长。输出比原算法增加8个时钟周期（160纳秒）；相同原始角度序列在4组参数、1309帧对比中，角度及关键状态一致。PC仍接收MVDR精确输出，不需要为流水线调整协议。

见 `evidence/验证范围.json` 和硬件时序报告。离线测试中的音调、UDP回环数据只用于验证算法和接收程序，不是实际麦克风采集证明。本次整合包的板上采音、分类耗时及远端PC收包，以下载后的联合测试为准。
