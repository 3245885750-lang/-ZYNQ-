# build —— 建工程、打包与检查脚本

本目录区分两类脚本：

| 类型 | 文件 | 能不能直接在仓库里跑 |
|---|---|---|
| **可复现** | `create_project.tcl`、`export_reports.tcl`、`check_vivado.ps1` | 可以 |
| **操作说明** | `update_ip_and_bd.md` | 按步骤在 Vivado/Vitis 里执行 |
| **归档记录** | `archive_project.tcl`、`verify_relocated.tcl`、`prepare_source.py`、`finalize_package.py` | 不能，路径是作者机器上的 |

归档记录保留了当时的打包与校验逻辑，供理解交付物是怎么生成的，不做路径改写。

---

## 1. 重建开发版 PL 工程

```tcl
cd <repo>/build
source create_project.tcl
```

脚本做五件事：设 IP 仓库 `src/pl/ip_repo`、加 `src/pl/rtl/*.v` 与
`src/pl/rtl/*.mem`、加 `fft_512.xci`、加约束，顶层设为
**`radar_pl_bd_verify_top`**（单板验证顶层，AXI 接死、UART/LED 输出角度）。

> 顶层为什么不是 `mvdr_axi_top`：TDOA 支路在 `radar_pl_top_bd.v` 内，
> `mvdr_axi_top` 只是 IP 核心；把它设成顶层，`transient_tdoa` 不会被综合进去。
> 给 Block Design 用的顶层是 `radar_pl_top_bd`，也不是这个验证顶层。

`.mem` 必须显式 `add_files`：RTL 里 `$readmemh("steer_re.mem", ...)` 用的是
相对路径，工程没收录这些文件时综合阶段才会报错，且报错信息不直观。

生成 `build/vivado/radar_pl_dev/radar_pl_dev.xpr`。
**脚本不会自动启动综合**——请手动 Run Synthesis / Run Implementation。

综合/实现完成后，导出 3.3.5.1 要求的报告：

```tcl
cd <repo>/build
source export_reports.tcl
```

输出到 `build/reports/`，字段说明见 `build/reports/README.md`。

> 目录 `build/vivado/` 已在 `.gitignore` 中，不会把工程产物提交进仓库。

### 如果 fft_512 解析失败

`fft_512.xci` 在 `src/pl/ip_repo/radar_pl_audio/src/fft_512/`。若 Vivado 报
找不到 IP，执行：

```tcl
update_ip_catalog -rebuild
upgrade_ip [get_ips]
```

仍失败则按以下配置重建：512 点、16 bit 输入、streaming、natural order、
unscaled、truncation（与交付工程一致）。

---

## 2. 完整系统（Block Design）

`src/pl/integration/radar_system.bd` 是交付工程的 Block Design，包含
PS7、AXI 互连、DMA 与自定义 IP。它依赖打包好的 `radar_pl_audio` IP
（`src/pl/ip_repo/`）。

由于 BD 需要与具体 Vivado 版本的 IP 缓存匹配，**推荐直接下载 Release 里的
完整工程包**（`pl_vivado_project.zip`），而不是从 .bd 单文件重建。
若必须重建，流程见 `verify_relocated.tcl` 的归档记录。

---

## 3. 把 TDOA 开发版并入 IP / BD / bit

`src/pl/rtl/` 是最新开发版，`src/pl/ip_repo/radar_pl_audio/` 是与基线 bit
配套的快照。要让完整系统（BD + PS + 网页）也带 TDOA，按
[`update_ip_and_bd.md`](update_ip_and_bd.md) 做一次：

1. 把 `src/pl/rtl/*.v` 同步到 IP 的 `src/`；
2. 重新 Package IP（版本号 +1）；
3. `update_ip_catalog -rebuild`、升级 BD 里的 IP、重新生成 bit；
4. PS 加 `0x50/0x54` 读取与显示切换；
5. 成套替换 `board/payload/` 三个文件并更新 `manifest.json` 的 SHA256。

> 只换 bit 不换 ELF（或反之）会导致版本错配；`download.ps1 -VerifyOnly`
> 会按 `manifest.json` 拒绝不匹配的组合。

---

## 4. Vivado 卡死检查

```powershell
powershell -ExecutionPolicy Bypass -File check_vivado.ps1
```

只读检查进程、CPU 时间、内存、日志时间戳与 run 标记，判断「还在算」还是
「已经死了」。详见 `skill/vivado-synth-hang/SKILL.md`。

---

## 5. 归档脚本说明（不可直接运行）

| 文件 | 当时的用途 |
|---|---|
| `archive_project.tcl` | 用 `archive_project` 打包 Vivado 工程 |
| `verify_relocated.tcl` | 换机器后校验工程文件齐全、BD 可 validate |
| `prepare_source.py` | 从交付源码中抽取与基线 IP 的差异、生成清单 |
| `finalize_package.py` | 校验 bit/ELF 哈希、比对重建 ELF 与部署 ELF 的差异 |

后两个脚本里有一条值得保留的经验：重建的 ELF 与部署的 ELF 只允许在
GNU build-id 的 20 字节上有差异；其余字节必须完全一致，才说明源码与
部署固件真的对应。
