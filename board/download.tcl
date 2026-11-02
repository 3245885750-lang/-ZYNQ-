# Uses relative payload paths. Launch through download.ps1 for a fresh nonce.
set radar_root [file dirname [file normalize [info script]]]
if {![info exists nonce_hi] || ![info exists nonce_lo]} {
    puts stderr "Use download.cmd or download.ps1, not this Tcl file alone."
    exit 1
}
set radar_connected 0
if {[catch {
    connect -url tcp:127.0.0.1:3121
    set radar_connected 1
    targets -set -filter {name == "ARM Cortex-A9 MPCore #0"}
    rst -system -stop
    after 1000
    foreach radar_core {0 1} {
        targets -set -filter "name == \"ARM Cortex-A9 MPCore #$radar_core\""
        if {[catch {stop} radar_stop_error] && ![string match {*Already stopped*} $radar_stop_error]} {error $radar_stop_error}
        rst -processor
    }
    targets -set -filter {name == "xc7z020"}
    fpga -file [file join $radar_root payload radar.bit]
    targets -set -filter {name == "ARM Cortex-A9 MPCore #0"}
    source [file join $radar_root payload ps7_init.tcl]
    configparams force-mem-accesses 1
    try {ps7_init; ps7_post_config} finally {configparams force-mem-accesses 0}
    dow [file join $radar_root payload radar.elf]
    mwr 0x001668a4 [list $nonce_hi $nonce_lo]
    con
    after 15000
    targets -set -filter {name == "APU"}
    set radar_net [mrd -value 0x01a958ec 32]
    set radar_stream [mrd -value 0x00273980 64]
    set radar_class [mrd -value 0x00274280 64]
    puts "g_network_header $radar_net"
    puts "g_stream_header $radar_stream"
    puts "g_classifier_header $radar_class"
    after 3000
    set radar_net2 [mrd -value 0x01a958ec 32]
    set radar_stream2 [mrd -value 0x00273980 64]
    set radar_class2 [mrd -value 0x00274280 64]
    puts "g_network_header_later $radar_net2"
    puts "g_stream_header_later $radar_stream2"
    puts "g_classifier_header_later $radar_class2"
    if {[llength $radar_net2] != 32 || [llength $radar_stream2] != 64 || [llength $radar_class2] != 64} {error "Diagnostic mailbox length mismatch"}
    if {[lindex $radar_stream2 2] != 2 || [lindex $radar_stream2 3] != 0} {error "Audio capture not running or error reported"}
    if {[lindex $radar_class2 1] != 2 || [lindex $radar_class2 49] != 9 || [lindex $radar_class2 43] != 511} {error "Nine-class firmware identity mismatch"}
    if {[lindex $radar_class2 50] != 800000 || [lindex $radar_class2 51] != 50000} {error "Rejection threshold mismatch"}
    if {[lindex $radar_stream2 10] <= [lindex $radar_stream 10] || [lindex $radar_class2 3] <= [lindex $radar_class 3]} {error "Capture/model counters are not advancing"}
    if {[lindex $radar_stream2 15] != [lindex $radar_stream 15] || [lindex $radar_class2 12] != [lindex $radar_class 12]} {error "Audio drop or gap during observation"}
    if {[lindex $radar_net2 1] != 2 || [lindex $radar_net2 2] <= [lindex $radar_net 2] || [lindex $radar_net2 3] != 0 || [lindex $radar_net2 10] != 0 || [lindex $radar_net2 11] != 0} {error "Ethernet sender not ready/advancing, or error reported"}
    puts "DOWNLOAD_OK: audio/model counters advancing; board sender reports no failure. Remote PC receipt is not verified."
} radar_error]} {
    puts stderr "DOWNLOAD_FAILED: $radar_error"
    if {$radar_connected} {catch {disconnect}}
    exit 1
}
disconnect
exit 0
