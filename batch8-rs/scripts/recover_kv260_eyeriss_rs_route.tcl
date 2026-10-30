set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set impl_dir [file join $project_dir board_pure_rs build vivado \
    alexnet_m4n8_kv260.runs impl_1]
set report_dir [file join $project_dir board_pure_rs build reports \
    route_recovery_default]
set output_dir [file join $project_dir board_pure_rs build output]
file mkdir $report_dir
file mkdir $output_dir

set input_dcp [file join $impl_dir system_wrapper_physopt.dcp]
if {![file exists $input_dcp]} {
    error "Physical-optimization checkpoint is missing: $input_dcp"
}

open_checkpoint $input_dcp

# The first project-mode attempt used AlternateCLBRouting.  On this design it
# increased node overlap during global iterations.  Restart from the clean
# post-physopt checkpoint and use the balanced default cost model instead.
route_design -directive Default

set failed_route_nets [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" || ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]
set setup_slack [get_property SLACK \
    [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set hold_slack [get_property SLACK \
    [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]

write_checkpoint -force [file join $impl_dir \
    system_wrapper_routed_default.dcp]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir utilization_hierarchical.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]

set summary_file [open [file join $report_dir route_summary.txt] w]
puts $summary_file "ROUTE_DIRECTIVE=Default"
puts $summary_file "CLOCK_MHZ=185"
puts $summary_file "WNS=$setup_slack"
puts $summary_file "WHS=$hold_slack"
puts $summary_file "FAILED_ROUTE_NETS=[llength $failed_route_nets]"
close $summary_file

if {[llength $failed_route_nets] != 0} {
    error "Default route left [llength $failed_route_nets] failed nets"
}

# Keep a legal routed artifact even if a later timing-recovery pass is needed.
write_bitstream -force [file join $output_dir \
    alexnet_eyeriss_rs_batch8_kv260_routed_default.bit]
puts "EYERISS_RS_DEFAULT_ROUTE_DONE WNS=$setup_slack WHS=$hold_slack"
exit
