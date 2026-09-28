set_param general.maxThreads 8

set build_clock_mhz 200
if {[info exists ::env(ALEXNET_CLOCK_MHZ)]} {
    set build_clock_mhz [expr {int($::env(ALEXNET_CLOCK_MHZ))}]
}
if {$build_clock_mhz != 200 && $build_clock_mhz != 185} {
    error "ALEXNET_CLOCK_MHZ must be 200 or 185"
}

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set shared_scripts [file normalize [file join $stage_dir .. \
    01_kv260_m4n8 scripts]]
set ::alexnet_stage_dir_override $stage_dir
set ::alexnet_composite_build 1
set ::alexnet_accelerator_top_override \
    alexnet_m8n126_graph_accelerator_top
set ::alexnet_accelerator_display_name_override \
    {AlexNet M8xN126 graph-payload accelerator}
set ::alexnet_accelerator_description_override \
    {KV260 M8xN126 full-graph engine with Conv1 raster and Conv2-FC8 N8-tile-major activation assembly}
set ::alexnet_use_four_hp 1
set ::alexnet_add_weight_dma 1
set ::alexnet_native_batch8 1
set ::alexnet_fabric_clock_mhz $build_clock_mhz

source [file join $shared_scripts package_alexnet_m4n8_ip.tcl]
source [file join $shared_scripts package_camera_adapter_ip.tcl]
source [file join $shared_scripts create_kv260_system.tcl]

set build_dir [file join $stage_dir build]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set output_dir [file join $build_dir output]
file mkdir $report_dir
file mkdir $output_dir

open_project [file join $project_dir alexnet_m4n8_kv260.xpr]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
# The native batch-8 caches occupy 54/64 URAMs beside a dense LUT design.  A
# congestion-oriented placement keeps the scheduler/result control paths from
# being squeezed around the hard-memory columns; the generic performance
# strategy routes successfully but misses 200 MHz in that dense placement.
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}

open_run synth_1
report_utilization -hierarchical -file \
    [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -report_unconstrained -file \
    [file join $report_dir post_synth_timing.rpt]

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation did not complete: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_timing_summary -delay_type min_max -check_timing_verbose \
    -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir utilization_hierarchical.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
check_timing -verbose -file [file join $report_dir check_timing.rpt]
report_power -file [file join $report_dir power.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
set failed_route_nets [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" ||
    ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]
set drc_errors [get_drc_violations -filter {SEVERITY == "Error"}]
set drc_critical [get_drc_violations \
    -filter {SEVERITY == "Critical Warning"}]
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set sa_dsp_cells [get_cells -hierarchical -filter {
    REF_NAME == DSP48E2 && NAME =~ *u_dynamic_sa*
}]
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
set bram18_cells [get_cells -hierarchical -filter {REF_NAME == RAMB18E2}]
set uram_cells [get_cells -hierarchical -filter {REF_NAME == URAM288}]

set summary_file [open [file join $report_dir build_summary.txt] w]
puts $summary_file "TOP=[get_property TOP [current_fileset]]"
puts $summary_file "PART=[get_property PART [current_project]]"
puts $summary_file "SYNTH_STATUS=[get_property STATUS [get_runs synth_1]]"
puts $summary_file "IMPL_STATUS=[get_property STATUS [get_runs impl_1]]"
puts $summary_file "CLOCK_MHZ=$build_clock_mhz"
puts $summary_file "LOGICAL_ARRAY=M8xN126"
puts $summary_file "PHYSICAL_ARRAY=M8xN128"
puts $summary_file "WNS=$setup_slack"
puts $summary_file "WHS=$hold_slack"
puts $summary_file "FAILED_ROUTE_NETS=[llength $failed_route_nets]"
puts $summary_file "DRC_ERRORS=[llength $drc_errors]"
puts $summary_file \
    "DRC_CRITICAL_WARNINGS=[llength $drc_critical]"
puts $summary_file "SA_DSP48E2=[llength $sa_dsp_cells]"
puts $summary_file "TOTAL_DSP48E2=[llength $dsp_cells]"
puts $summary_file "RAMB36E2=[llength $bram_cells]"
puts $summary_file "RAMB18E2=[llength $bram18_cells]"
puts $summary_file "URAM288=[llength $uram_cells]"
puts $summary_file "HP_PORTS_ENABLED=4"
puts $summary_file "HP_PORTS_ACTIVE=4"
puts $summary_file "HP3_WEIGHT_MM2S=1"
puts $summary_file "CONV1_INPUT_LAYOUT=N8_RASTER"
puts $summary_file "CONV1_INPUT_BYTES=401408"
puts $summary_file "CONV1_LEGACY_PATCH_TAPE_BYTES=1103520"
puts $summary_file "CONV1_DDR_READ_REDUCTION_BYTES=702112"
puts $summary_file \
    "LATER_ACTIVATION_LAYOUT=N8_TILE_SPATIAL_N8_LANE"
puts $summary_file "LATER_ACTIVATION_CACHE_MAX_BYTES=64896"
puts $summary_file "CONV_ACTIVATION_CACHE_LOADS_PER_IMAGE=13"
puts $summary_file "FC_BATCH_ACTIVATION_CACHE_LOADS_PER_BATCH=3"
puts $summary_file "LATER_LEGACY_PATCH_TAPE_BYTES=0"
puts $summary_file "ACTIVATION_PATCH_SERVICE_OOC_DSP48E2=0"
puts $summary_file "ACTIVATION_PATCH_SERVICE_OOC_RAMB36E2=16"
puts $summary_file "ACTIVATION_PATCH_SERVICE_OOC_RAMB18E2=0"
puts $summary_file "NATIVE_BATCH_SIZE=8"
puts $summary_file "GRAPH_SCHEDULER_COMMANDS_PER_BATCH=5471"
puts $summary_file "GRAPH_USEFUL_MACS_PER_BATCH=5713507840"
puts $summary_file "GRAPH_PHYSICAL_MAC_SLOTS_PER_BATCH=10487676928"
puts $summary_file "GRAPH_SLOT_UTILIZATION_PERCENT=54.478"
puts $summary_file "GRAPH_LOGICAL_WEIGHT_BYTES=61090496"
puts $summary_file "GRAPH_WEIGHT_TRANSFER_BYTES_PER_BATCH=61123264"
puts $summary_file "PARAMETER_TRANSFER_BYTES_PER_BATCH=165504"
puts $summary_file "EXPECTED_DDR_READ_BYTES_PER_BATCH=72407872"
puts $summary_file "EXPECTED_DDR_WRITE_BYTES_PER_BATCH=4660032"
puts $summary_file "EXPECTED_DDR_TOTAL_BYTES_PER_IMAGE=9633488"
puts $summary_file "RESULT_LAYOUT=N8_TILE_BATCH8_N8_LANE"
puts $summary_file "INPLACE_POOL_LAYERS=1,2,5"
puts $summary_file "POOL_MAX_RAW_TILE_BYTES=24200"
puts $summary_file "POOL_DMA_POLICY=SEQUENTIAL_MM2S_S2MM"
puts $summary_file \
    "BITSTREAM=[file join $output_dir alexnet_m8n126_graph_kv260.bit]"
puts $summary_file \
    "XSA=[file join $output_dir alexnet_m8n126_graph_kv260.xsa]"
close $summary_file

if {$setup_slack < 0.0} {
    error "Setup timing failed with WNS=$setup_slack ns"
}
if {$hold_slack < 0.0} {
    error "Hold timing failed with WHS=$hold_slack ns"
}
if {[llength $failed_route_nets] != 0} {
    error "Routing failed for [llength $failed_route_nets] nets"
}
if {[llength $drc_errors] != 0 || [llength $drc_critical] != 0} {
    error "DRC failed: [llength $drc_errors] errors, \
[llength $drc_critical] critical warnings"
}
if {[llength $sa_dsp_cells] != 512 || [llength $dsp_cells] != 576 ||
    [llength $uram_cells] != 54} {
    error "Resource contract failed: SA_DSP48E2=[llength $sa_dsp_cells], TOTAL_DSP48E2=[llength $dsp_cells], RAMB36E2=[llength $bram_cells], URAM288=[llength $uram_cells]"
}

# Publish only a fully routed, timing-clean graph-payload image.
set bit_source [file join $project_dir \
    alexnet_m4n8_kv260.runs impl_1 system_wrapper.bit]
if {![file exists $bit_source]} {
    error "Bitstream was not generated at $bit_source"
}
file copy -force $bit_source \
    [file join $output_dir alexnet_m8n126_graph_kv260.bit]
write_hw_platform -fixed -include_bit -force \
    [file join $output_dir alexnet_m8n126_graph_kv260.xsa]

puts "ALEXNET_M8N126_GRAPH_KV260_BITSTREAM_DONE frequency_mhz=$build_clock_mhz"
close_project
exit
