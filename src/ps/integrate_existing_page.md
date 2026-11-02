# 保留PC原网页与原以太网接收服务

板卡已经发送UDP JSON v3至PC 192.168.1.100:9000。原接收服务继续独占UDP9000；无需同时启动本包web_receiver.py。板卡不会向浏览器HTML页面直接发UDP。

数据路径：板卡GE_PS → 原有UDP接收服务 → 原服务已有的WebSocket/SSE/HTTP API → 原网页。
保留原网页的地址、布局和配色，修改原服务对板卡JSON包的解析及前端类别映射。

## Python后端的接入点

将pc/radar_protocol.py和pc/existing_page_adapter.py一起复制到原后端可导入的模块目录。
程序启动时创建一个ExistingPageAdapter实例，必须保留实例，不能每个包重建。
在原有recvfrom收到报文后调用ingest；它不开新端口、不启动网页，也不改变网卡配置。

```python
from existing_page_adapter import ExistingPageAdapter

adapter = ExistingPageAdapter(board_ip='192.168.1.10')

# 在原服务已有的接收循环中：
data, peer = existing_socket.recvfrom(65535)
try:
    update = adapter.ingest(data, peer[0])
except (ValueError, TypeError, UnicodeError) as exc:
    # 通过原服务日志记录该异常，再继续接收下一包。
    update = None
if update is not None:
    # 将update交给原网页已有的推送函数或HTTP状态存储。
    # 这里需按原项目的API实现，不能直接照抄一个不存在的broadcast函数。
    pass
```

原服务若还接收频谱或其他协议：在对应的板卡JSON消息分支中调用适配器，保留其他分支；不要把所有频谱二进制报文都送入JSON解码器。
如果后端不是Python，应按radar_protocol.py或PC接收步骤.md的字段规则实现相同解析。

## 给原网页的字段

- kind=doa：有效时angle_deg为MVDR精确角度；无效时为null并清除箭头。0度是合法值。
- kind=classification：display_name直接用于类型文字；confidence_pct为模型分数百分比（不是已校准的正确概率）。scores为含label/name_zh/score_pct的数组，可以按键绘制条形图。
- state=background：显示安静并隐藏旧得分；state=uncertain：显示不确定；pending/error分别显示等待或错误。具体类别仅在event状态显示。
- reset_other_stream=true：新的板卡会话已开始，应先清除原网页另一种消息的旧显示，再应用本次更新。
- 原后端定时调用adapter.stale('doa')及adapter.stale('classification')，分别超过2秒无新结果再清除对应实时显示。
- 原服务通过现有异步/线程调度向网页推送；不要在UDP线程中做耗时绘图。保留uint64字符串t_us，避免JavaScript数字精度损失。

原始scores_ppm顺序固定为：拍手clap、说话speech、钢琴piano、鸟叫bird、狗叫dog、鸣笛horn、流水water、拉链zipper、敲键盘keyboard。
旧版8项数组、v=2校验、enabled_mask=191都要更新；新版v=3，class_set=radar9_20261028，enabled_mask=511。

当前只发送MVDR方位与分类结果；九类固件当前没有发送八路频谱。保留原页面频谱区域不会自动获得新频谱数据。

本适配器已做本机消息映射测试。由于未取得原网页及后端源码，尚未完成对该网页的实际接入，不应把本文件视为已修改原项目。
