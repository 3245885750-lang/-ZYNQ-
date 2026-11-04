# sim —— 仿真与逐位回放

```
sim/
├── tb/        Verilog testbench（模块级）
├── model/     Python 逐位回放模型、向量生成与数据分析脚本
├── vec/       回放向量（本地生成，不入 git）
└── results/   仿真产出的图与汇总
```

## 1. Verilog testbench（`tb/`）

| 文件 | 覆盖模块 | 检查点 |
|---|---|---|
| `i2s_fft_tb.v` / `i2s_fft8_tb.v` | I2S 采集 + FFT 前级 | 帧同步、位序、通道对齐 |
| `fft_512_tb.v` | FFT IP 封装 | 频点位置与幅度 |
| `i2s_to_fft_tb.v` | I2S → AXI-Stream 转换 | TLAST/TVALID 时序 |
| `cov_accum_8x8_tb.v` | 8 路协方差 EMA | 收敛值、`rdone` 节奏 |
| `cov_to_q16_tb.v` | 定点化 | Q16.16 舍入 |
| `complex_div_tb.v` | 复数除法 | 除零保护、精度 |
| `mat_inv_8x8_tb.v` | 8×8 求逆 | 残差、迭代次数 |
| `mvdr_sweep_tb.v` / `mvdr_sweep_wb_tb.v` | 扫角（单 bin / 8 bin） | 峰值角度、`s_min` |
| `mvdr_axi_tb.v` / `mvdr_axi_wb_tb.v` | 整链 + AXI-Lite | 寄存器读回、DOA 输出 |
| `mvdr_chain_tb.v` | 全链路 | 端到端角度 |
| `bf_das_tb.v` / `bf_das_rtl_tb.v` | 时域 DAS | 延时精度、RMS |
| `bf_audio_out_tb.v` | 音频输出 | TLAST 与背压 |
| `bf_music_tb.v` / `bf_mvdr_tb.v` / `bf_mvdr_fxp_tb.v` | 波束形成算法对照 | 增益、零陷 |
| `das_scan_tb.v` | DAS 扫角 | 粗测角度 |
| `steer_rom_tb.v` / `gen_steer_rom_tb.v` | 导向 ROM | 地址-角度映射 |
| `mvdr_axi_wb_tb.v` | 8 bin 宽带 | 融合谱峰位 |
| `tb_tdoa_replay.v` | `transient_tdoa` | 8 方向/任意角/弱拍的角度、`lowconf`、`sw`、`coh_ok` |
| `tb_false_trig.v` | `transient_tdoa` | 5 s 纯噪声误触发计数 |

运行方式（Vivado 2026.1）：

```tcl
# 例：协方差模块
set_property top cov_accum_8x8_tb [get_filesets sim_1]
launch_simulation
run all
```

> 本仓库未附带 xsim 的 `xsim.dir`/波形文件；需要时按上面的方式重新跑。

## 2. 逐位回放模型（`model/`）

这些脚本按 RTL 的整数语义逐帧重放输出级逻辑，不需要综合，秒级完成。

| 脚本 | 作用 |
|---|---|
| `sim_clap_smooth.py` | 输出级三变体 A/B/C 逐帧回放，拍手场景 |
| `sim_big.py` | 大角度转动与静态一致性 |
| `sim_gate.py` | 门控逻辑单独回放 |
| `sim_slew.py` | 限速逻辑单独回放 |
| `sim_evt_int.py` | 能量瞬态检测 |
| `sim_clr_check.py` / `sim_clr_seq.py` | 协方差对角加载与重建 |
| `param_check.py` | 从 RTL 文本抠参数，与模型常量逐项比对 |
| `pwr_stats.py` | 统计 CSV 的能量分布 |
| `analyze_doa_csv.py` | 角度序列统计（跳变量、分布） |
| `plot_circle.py` | 绘制圆周运动轨迹 |
| `doa_view.py` | 角度随时间的可视化 |
| `sim_spectrum_bin_vs_8bin.py` | 单 bin vs 8 bin 空间谱对比 |
| `gen_steer_multibin.py` | 生成 8 个 bin 的导向矢量 `.mem` |
| `sim_tdoa_realistic.py` | 拍手模型（限带噪声、双撞击、反射、通道失配） |
| `gen_vec.py` / `gen_vec_weak.py` | 生成 0/90/180/270、40 dB、45 dB 弱拍向量 |
| `gen_vec_arb.py` / `gen_noise.py` | 生成 37°/217° 与 5 s 纯噪声向量 |

### 常用命令

```bash
python sim/model/param_check.py                 # 改 RTL 后必跑
python sim/model/sim_clap_smooth.py data/clap_log_20261101.csv
python sim/model/analyze_doa_csv.py data/circle_v5.csv
python sim/model/gen_steer_multibin.py          # 重新生成 steering ROM
python sim/model/gen_vec.py                     # 生成 TDOA 回放向量
```

TDOA 回放的完整命令与预期输出见
[`results/tdoa_replay_summary.md`](results/tdoa_replay_summary.md)。

`param_check.py` 里的 RTL 路径是作者机器上的绝对路径；换机器后请改成
`src/pl/rtl/mvdr_axi_top.v`。

## 3. 结果图（`results/`）

| 图 | 说明 |
|---|---|
| `fig_spatial_spectrum_bin_vs_8bin.png` | 单 bin 与 8 bin 融合的空间谱对比（栅瓣被压平） |
| `fig_das_vs_mvdr.png` | DAS 粗测与 MVDR 精测的轨迹对比 |
| `mvdr_spectrum.png` | MVDR 空间谱示例 |
| `tdoa_replay_summary.md` | 瞬态 TDOA 的 8 方向/弱拍/纯噪声回放汇总 |

## 4. 已知限制

- testbench 依赖 Vivado 的 FFT IP 仿真库，不能脱离 Vivado 单独跑；
- 回放模型只覆盖控制逻辑，不覆盖数值通路；
- `param_check.py` 里的 RTL 路径是作者机器上的绝对路径，换机器后改成
  `src/pl/rtl/mvdr_axi_top.v`；新增的 TDOA 向量生成脚本使用相对路径；
- `sim/vec/*.hex` 体积大，不入 git，按 `sim/vec/README.md` 本地生成。
