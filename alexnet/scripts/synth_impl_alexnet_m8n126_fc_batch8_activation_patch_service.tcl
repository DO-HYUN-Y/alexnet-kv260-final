set part xck26-sfvc784-2LV-c
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build \
    m8n126_fc_batch8_activation_patch_service_ooc 200mhz]
set report_dir [file join $alexnet_root reports \
    m8n126_fc_batch8_activation_patch_service 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

set rtl_source [file join $alexnet_root rtl integration \
    alexnet_m8n126_fc_batch8_activation_patch_service.sv]
set xdc_source [file join $alexnet_root constraints \
    alexnet_m8n126_activation_patch_service.xdc]
read_verilog -sv $rtl_source
read_xdc $xdc_source
synth_design -top alexnet_m8n126_fc_batch8_activation_patch_service \
    -part $part -mode out_of_context -directive PerformanceOptimized

set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]]
set uram_count [llength [get_cells -hierarchical -filter {REF_NAME == URAM288}]]
set bram36_count [llength [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]]
set bram18_count [llength [get_cells -hierarchical -filter {REF_NAME == RAMB18E2}]]
if {$dsp_count != 0} {
  error "batch8 activation service must use zero DSP48E2, got $dsp_count"
}

report_utilization -file [file join $report_dir synth_utilization.rpt]
opt_design -directive ExploreWithRemap
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
set setup_wns [get_property SLACK $setup_path]
set hold_whs [get_property SLACK $hold_path]
set failed_nets [llength [get_nets -hierarchical -filter {
    ROUTE_STATUS == FAILED || ROUTE_STATUS == CONFLICTS ||
    ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIALLY_ROUTED
}]]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir impl_timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
write_checkpoint -force [file join $out_dir post_route.dcp]

set metadata [open [file join $report_dir run_metadata.txt] w]
puts $metadata "design=alexnet_m8n126_fc_batch8_activation_patch_service"
puts $metadata "frequency_mhz=200"
puts $metadata "dsp48e2=$dsp_count"
puts $metadata "uram288=$uram_count"
puts $metadata "ramb36e2=$bram36_count"
puts $metadata "ramb18e2=$bram18_count"
puts $metadata "setup_wns_ns=$setup_wns"
puts $metadata "hold_whs_ns=$hold_whs"
puts $metadata "failed_route_nets=$failed_nets"
close $metadata

if {$setup_wns < 0.0 || $hold_whs < 0.0 || $failed_nets != 0} {
  error "batch8 activation service failed 200 MHz: WNS=$setup_wns WHS=$hold_whs failed_nets=$failed_nets"
}
puts "ALEXNET_M8N126_FC_BATCH8_ACTIVATION_OOC_PASS DSP=$dsp_count URAM=$uram_count BRAM36=$bram36_count BRAM18=$bram18_count WNS=$setup_wns WHS=$hold_whs"
