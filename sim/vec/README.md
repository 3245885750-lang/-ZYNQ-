# 回放向量目录

这里的 `.hex` 文件体积较大（单个 0.5–4 MB），**不提交进 git**，由脚本本地生成。
生成后，`tb_tdoa_replay.v` 固定读取 `sim/vec/current.hex`；每次换向量时复制一份。

## 生成

在仓库根目录：

```powershell
python sim\model\gen_vec.py        # 0/90/180/270
python sim\model\gen_vec_weak.py   # 40 dB @0°，45 dB @90°
python sim\model\gen_vec_arb.py    # 37°，217°
python sim\model\gen_noise.py      # 5 s 纯噪声
```

依赖：`numpy`、`scipy`（`sim_tdoa_realistic.py` 用 `scipy.signal`）。

## 格式

每行 128 个十六进制字符，按 `{ch7, ch6, ..., ch0}` 排列，每通道 4 位
（16 bit PCM，补码）。采样率 48.828125 kHz，前 0.56 s 是预热，拍手在
第 27343 个采样点附近。

## 回放

```powershell
Copy-Item sim\vec\vec_090.hex sim\vec\current.hex
xvlog sim\tb\tb_tdoa_replay.v src\pl\rtl\radar_pl_top_bd.v
xelab tb_tdoa_replay -s elab_replay
xsim elab_replay -runall
```

预期输出见 [`../results/tdoa_replay_summary.md`](../results/tdoa_replay_summary.md)。
