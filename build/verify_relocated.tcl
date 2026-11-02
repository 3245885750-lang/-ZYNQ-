set radar_root {F:/FPGA/Vitis_Workspace/v1030/radar_ps_audio_v2}
set radar_audit {F:/FPGA/Vitis_Workspace/source_handoff_20261030/audit}
open_project "$radar_root/radar_ps_audio_v2.xpr"
report_ip_status -file "$radar_audit/relocated_ip_status.txt"
set radar_missing {}
foreach radar_file [get_files -all] {
    set radar_path [get_property NAME $radar_file]
    if {![file exists $radar_path]} {lappend radar_missing $radar_path}
}
set radar_out [open "$radar_audit/relocated_project_check.txt" w]
puts $radar_out "PROJECT_OPENED [current_project]"
puts $radar_out "PART [get_property PART [current_project]]"
puts $radar_out "IP_REPO [get_property IP_REPO_PATHS [current_project]]"
puts $radar_out "FILES [llength [get_files -all]]"
puts $radar_out "MISSING [llength $radar_missing]"
foreach radar_path $radar_missing {puts $radar_out $radar_path}
close $radar_out
if {[llength $radar_missing]} {error "Archived project has missing files"}
open_bd_design "$radar_root/radar_ps_audio_v2.srcs/sources_1/bd/radar_system/radar_system.bd"
validate_bd_design
write_bd_tcl -force "$radar_audit/radar_system_recreate.tcl"
write_project_tcl -force -use_bd_files -paths_relative_to $radar_root "$radar_audit/recreate_project.tcl"
puts "RELOCATED_PROJECT_CHECK_PASS"
close_project
exit
