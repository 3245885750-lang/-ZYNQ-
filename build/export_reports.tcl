# export_reports.tcl —— 导出综合/实现报告
#
# 用法（Vivado 2026.1 Tcl Console，工程已打开且 impl_1 已完成）：
#   cd <repo>/build
#   source export_reports.tcl
#
# 输出目录：<repo>/build/reports/
# 说明：这些 .rpt 是 3.3.5.1 要求的“综合与实现报告”的原始依据。
#       不要把整个 build/vivado/ 提交进 git，只提交 build/reports/。

set build_dir [file normalize [file dirname [info script]]]
set rpt_dir   [file join $build_dir reports]
file mkdir $rpt_dir

if {[catch {open_run impl_1} err]} {
    error "请先在 Vivado 中完成 Run Implementation（impl_1），再运行本脚本：$err"
}

report_utilization       -file [file join $rpt_dir post_route_utilization.rpt]
report_timing_summary    -delay_type min_max -report_unconstrained \
                         -check_timing_verbose -max_paths 10 \
                         -file [file join $rpt_dir timing_summary.rpt]
report_power             -file [file join $rpt_dir power.rpt]
report_drc               -file [file join $rpt_dir drc.rpt]
report_clock_utilization -file [file join $rpt_dir clock_utilization.rpt]

set fh [open [file join $rpt_dir tool_version.txt] w]
puts $fh "vivado=[version -short]"
puts $fh "part=[get_property PART [current_project]]"
puts $fh "top=[get_property top [current_fileset]]"
puts $fh "date=[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
close $fh

puts "REPORTS_READY: $rpt_dir"
puts "NEXT: 把关键数字抄到 build/reports/README.md 和 report/design_report.md 6.3 节"
