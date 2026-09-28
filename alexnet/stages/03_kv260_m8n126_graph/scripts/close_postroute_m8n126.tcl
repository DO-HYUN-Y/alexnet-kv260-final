set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set stage_dir [file normalize [file join $script_dir ".."]]
set build_dir [file join $stage_dir "build"]
set run_dir [file join $build_dir "vivado" "alexnet_m4n8_kv260.runs" "impl_1"]
set report_dir [file join $build_dir "reports"]
set output_dir [file join $build_dir "output"]
set routed_dcp [file join $run_dir "system_wrapper_routed.dcp"]
set optimized_dcp [file join $run_dir "system_wrapper_postroute_physopt.dcp"]

if {![file exists $routed_dcp]} {
  error "Routed checkpoint not found: $routed_dcp"
}
file mkdir $report_dir
file mkdir $output_dir

puts "POSTROUTE_CLOSE: opening $routed_dcp"
open_checkpoint $routed_dcp

# The routed design is only 83 ps short at 200 MHz.  Run a focused
# post-route physical optimization without restarting implementation.
phys_opt_design -directive AggressiveExplore

report_timing_summary -delay_type min_max -max_paths 50 -report_unconstrained \
  -file [file join $report_dir "timing_summary_postroute_physopt.rpt"]
report_route_status -file [file join $report_dir "route_status_postroute_physopt.rpt"]

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
set setup_slack [get_property SLACK $setup_paths]
set hold_slack [get_property SLACK $hold_paths]
set failed_routes [llength [get_nets -hierarchical -filter {ROUTE_STATUS == "CONFLICTS" || ROUTE_STATUS == "UNROUTED" || ROUTE_STATUS == "PARTIAL"}]]

puts "POSTROUTE_CLOSE: setup_slack_ns=$setup_slack"
puts "POSTROUTE_CLOSE: hold_slack_ns=$hold_slack"
puts "POSTROUTE_CLOSE: failed_routes=$failed_routes"

write_checkpoint -force $optimized_dcp

if {$setup_slack < 0.0 || $hold_slack < 0.0 || $failed_routes != 0} {
  error "Post-route timing/route checks failed"
}

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force [file join $output_dir "alexnet_m8n126_graph_kv260.bit"]
puts "POSTROUTE_CLOSE: timing closed and fresh bitstream written"
