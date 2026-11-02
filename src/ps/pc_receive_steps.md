# 九类声音＋安静＋不确定 · PC 接收交接

**本包是候选版：已通过构建、C/Python一致性和本机UDP/网页通信检查，已按用户要求通过JTAG下载到板卡试运行，未验证远端PC与新模型的板上准确率。**
九类离线测试文件准确率约67.6%，说话、鸟叫等仍有混淆。当前拒识也不能可靠覆盖所有未知声音，需用实际板卡采音补充验证，不能把此版本当作已完成实时效果验收。

声音类别顺序：拍手 clap、说话 speech、钢琴 piano、鸟叫 bird、狗叫 dog、鸣笛 horn、流水 water、拉链 zipper、敲键盘 keyboard。
猫叫和吉他已从本版模型输出及界面移除；不要沿用旧版八项数组下标。

## 启动

1. 板端需要下载匹配的九类固件：`radar_nine_class_20261028/build/radar_audio_classifier_ethernet.elf`，搭配原来的 `radar_audio_bringup.bit`。JTAG 下载断电后需要重下。
2. 网线接板卡 GE_PS，另一端接 PC 网卡。PC IPv4 `192.168.1.100`，掩码 `255.255.255.0`；板卡 `192.168.1.10`，目的 UDP 端口 **9000**。
3. 关闭旧接收程序，避免占用 UDP 9000。解压本包，在包根目录打开 PowerShell：

```powershell
py -3 -X utf8 -B .\pc\web_receiver.py
```

4. 浏览器打开 `http://127.0.0.1:8768/`。使用 Python 3 标准库，无需安装训练依赖。网页只显示板端结果。

若 Windows 防火墙尚未放行，请在管理员 PowerShell 添加匹配板卡来源的 UDP 入站规则：

```powershell
New-NetFirewallRule -DisplayName 'Radar UDP 9000 board' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 9000 -RemoteAddress 192.168.1.10 -Profile Any
```

## 协议变更

UDP UTF-8 JSON **v3**，每个 UDP 报文一条 JSON；报文最大1200字节。v2接收器需要替换。九类包携带 `class_set="radar9_20261028"`、`enabled_mask=511`、9项 `scores_ppm`，按上方顺序。接收器严格校验，不能把旧八类分数补零冒充新版。

- `kind="doa"`：仅发布 PL MVDR 精确方位，角度单位 `azimuth_mdeg/1000` 度；DAS 不作为定位角度发送。
- `kind="classification"`, `state="event"`：`label` 为九类之一，`confidence_ppm/10000` 是模型分数百分比，未经概率校准。
- `state="background"`, `label="background"`：显示 **安静**。与 PL 共用 `PWR <= 64` 门槛，原始分数仍供诊断，网页隐藏安静时的得分条。
- `state="uncertain"`, `label=null`, `confidence_ppm=null`：显示 **不确定**。有声音，但模型未通过拒识门限或窗口无效。
- `pending`：等待有效音频窗口；`error`：采集/识别停止。

本版拒识门限：最高分至少 **80%**，且比第二名至少高 **5%**（百分比点），两个条件同时满足才输出具体类别。门限在验证集选择，分数未校准，不能保证所有未知声音都能拒识。

方位和分类有各自递增 `seq`。用 `session` 识别板端重启，分流处理，忽略重复/倒序；没有新包超过2秒再显示超时。分类使用2秒滚动音频，目标步长100ms，实际完成速度取决于ARM负载，不能理解为声音发生100ms后一定识别正确。新模型实际板上时延和九类准确率需要实测。

自有界面集成：调用 `pc/radar_protocol.py` 中 `decode()` 与 `ReceiverState.ingest()`，根据 `kind` 和 `state` 更新UI。不要把uncertain当成quiet，也不要把数值为0的合法方位当无角度。

## 离线协议验证

`examples_v3/protocol_fixtures.jsonl` 是 ARM 编码器生成的人工测试包，**不是板上录音识别结果**。`replay_saved.py` 只用于本机回环协议测试，并明确标记 origin=replay；实时网页默认只接收 board。

训练采用144→64→32→9的轻量MLP，输入Log-Mel/MFCC统计特征，运行在PS Cortex-A9，当前不是CNN或DPU。音频输入仍为PL波束形成后的单路AUD2 PCM，采集、DMA和FIR重采样配置保持原版。
