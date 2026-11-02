# create_project.tcl —— 从仓库源码重建 PL 工程（开发版 RTL）
#
# 用法（Vivado 2026.1 Tcl Console）：
#   cd <repo>/build
#   source create_project.tcl
#
# 生成：<repo>/build/vivado/radar_pl_dev/radar_pl_dev.xpr
# 顶层：mvdr_axi_top（8 元阵列测向链，含 GATE / SLEW / 瞬态窗口）
#
# 说明：
# - 本脚本只建工程、加源码、解析 IP，不自动跑综合/实现；
#   综合与实现请在 GUI 里手动 Run Synthesis / Run Implementation。
# - 完整系统（PS + DMA + Block Design）请用 src/pl/integration/radar_system.bd，
#   或直接使用 Release 里的整个 Vivado 工程包。
# - 换机器时若 IP 未自动识别，执行 update_ip_catalog -rebuild 后重试。

set root [file normalize [file join [file dirname [info script]] ..]]
set projdir [file join $root build vivado radar_pl_dev]

if {[file exists $projdir]} {
    puts "WARNING: $projdir 已存在，-force 会覆盖同名工程"
}

create_project radar_pl_dev $projdir -part xc7z020clg400-2 -force

# 1. IP 仓库：打包好的 radar_pl_audio（内含 fft_512）
set iprepo [file join $root src pl ip_repo]
if {[file exists $iprepo]} {
    set_property ip_repo_paths [list $iprepo] [current_project]
    update_ip_catalog -rebuild
} else {
    puts "ERROR: 找不到 IP 仓库 $iprepo"
}

# 2. 开发版 RTL
set rtl_files [glob -nocomplain [file join $root src pl rtl *.v]]
if {[llength $rtl_files] == 0} {
    error "找不到 RTL：$root/src/pl/rtl/*.v"
}
add_files -norecurse $rtl_files

# 3. FFT IP（xci 随 IP 仓库提供）
set xci [file join $iprepo radar_pl_audio src fft_512 fft_512.xci]
if {[file exists $xci]} {
    add_files -norecurse $xci
    catch {generate_target all [get_files $xci]}
} else {
    puts "WARNING: 未找到 $xci；若综合报 fft_512 缺失，请按 build/README.md 重建该 IP"
}

# 4. 约束
set xdc_files [glob -nocomplain [file join $root src pl constraints *.xdc]]
if {[llength $xdc_files]} {
    add_files -fileset constrs_1 -norecurse $xdc_files
}

# 5. 顶层与编译顺序
set_property top mvdr_axi_top [current_fileset]
update_compile_order -fileset sources_1

puts "PROJECT_READY: $projdir/radar_pl_dev.xpr"
puts "NEXT: 在 GUI 中手动 Run Synthesis（本脚本不会自动启动综合）"
