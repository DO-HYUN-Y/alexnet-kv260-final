set_param general.maxThreads 8

set build_jobs 4
if {[info exists ::env(ALEXNET_EYERISS_RS_BUILD_JOBS)]} {
    set build_jobs $::env(ALEXNET_EYERISS_RS_BUILD_JOBS)
    if {![string is integer -strict $build_jobs] || $build_jobs < 1} {
        error "Build jobs must be a positive integer"
    }
}

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set stage_dir [file join $project_dir board_pure_rs]
set repo_root [file normalize [file join $project_dir ..]]
if {[info exists ::env(ALEXNET_REPO_ROOT)]} {
    set repo_root [file normalize $::env(ALEXNET_REPO_ROOT)]
}
set alexnet_root [file join $repo_root alexnet]
set replacement_scripts [file join $project_dir board_support]
set system_scripts [file join $alexnet_root stages 01_kv260_m4n8 scripts]

if {![file isdirectory $alexnet_root]} {
    error "AlexNet source tree not found at $alexnet_root; clone the full alexnet-kv260-final repository or set ALEXNET_REPO_ROOT"
}

set pure_rs_sources {}
foreach source {
    alexnet_eyeriss_filter_vector_bank.sv
    alexnet_eyeriss_rs_mac_pe.sv
    alexnet_eyeriss_rs_gin.sv
    alexnet_eyeriss_rs_local_psum_network.sv
    alexnet_eyeriss_rs_cluster.sv
    alexnet_eyeriss_rs_3cluster_core.sv
    alexnet_eyeriss_rs_batch8_pass_scheduler.sv
    alexnet_eyeriss_rs_batch8_pass_executor.sv
    alexnet_eyeriss_rs_batch8_control.sv
    alexnet_eyeriss_rs_filter_load_sequencer.sv
    alexnet_eyeriss_rs_image_op_sequencer.sv
    alexnet_eyeriss_rs_batch8_command_top.sv
    alexnet_eyeriss_rs_batch8_core_top.sv
    alexnet_eyeriss_rs_board_address_gen.sv
    alexnet_eyeriss_rs_dma_line_cache.sv
    alexnet_eyeriss_rs_memory_frontend.sv
    alexnet_eyeriss_rs_batch8_board_frontend_top.sv
    alexnet_eyeriss_rs_channel_accumulator.sv
    alexnet_eyeriss_rs_batch8_board_accum_top.sv
    alexnet_eyeriss_rs_dma_line_reader.sv
    alexnet_eyeriss_rs_dual_dma_line_adapter.sv
    alexnet_eyeriss_rs_batch8_board_dma_top.sv
    alexnet_eyeriss_rs_parameter_cache.sv
    alexnet_eyeriss_rs_requant14.sv
    alexnet_eyeriss_rs_batch8_board_postprocess_top.sv
    alexnet_eyeriss_rs_n8_result_store.sv
    alexnet_eyeriss_rs_batch8_inplace_pool_service.sv
    alexnet_eyeriss_rs_batch8_board_store_top.sv
    alexnet_eyeriss_rs_graph_accelerator_top.sv
} {
    lappend pure_rs_sources [file join $project_dir rtl $source]
}

set ::alexnet_stage_dir_override $stage_dir
set ::alexnet_composite_build 1
set ::alexnet_dir_override $alexnet_root
set ::alexnet_repo_dir_override $repo_root
set ::alexnet_accelerator_top_override \
    alexnet_eyeriss_rs_graph_accelerator_top
set ::alexnet_accelerator_display_name_override \
    {AlexNet pure Eyeriss row-stationary batch-eight accelerator}
set ::alexnet_accelerator_description_override \
    {Pure Eyeriss-style 3x12x14 row-stationary graph engine with batch-eight scheduling, local RF/psum reuse, DMA line caches, in-place pooling and N8 result storage}
set ::alexnet_use_four_hp 1
set ::alexnet_add_weight_dma 1
set ::alexnet_native_batch8 1
set ::alexnet_fabric_clock_mhz 185
set ::alexnet_rtl_sources_add $pure_rs_sources

source [file join $replacement_scripts package_alexnet_m4n8_ip.tcl]
source [file join $replacement_scripts package_camera_adapter_ip.tcl]
source [file join $system_scripts create_kv260_system.tcl]

if {[info exists ::env(ALEXNET_EYERISS_RS_SETUP_ONLY)] &&
    $::env(ALEXNET_EYERISS_RS_SETUP_ONLY) == 1} {
    puts "EYERISS_RS_BATCH8_KV260_BOARD_SETUP_PASS frequency_mhz=185"
    exit
}

set build_dir [file join $stage_dir build]
set vivado_project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set output_dir [file join $build_dir output]
file mkdir $report_dir
file mkdir $output_dir

open_project [file join $vivado_project_dir alexnet_m4n8_kv260.xpr]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]

reset_run synth_1
launch_runs synth_1 -jobs $build_jobs
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

launch_runs impl_1 -to_step write_bitstream -jobs $build_jobs
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

set setup_slack [get_property SLACK \
    [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set hold_slack [get_property SLACK \
    [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
set failed_route_nets [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" || ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]
set drc_errors [get_drc_violations -filter {SEVERITY == "Error"}]
set drc_critical [get_drc_violations \
    -filter {SEVERITY == "Critical Warning"}]
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set bram36_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
set bram18_cells [get_cells -hierarchical -filter {REF_NAME == RAMB18E2}]
set uram_cells [get_cells -hierarchical -filter {REF_NAME == URAM288}]
set accelerator_dsp_cells [get_cells -hierarchical -filter {
    REF_NAME == DSP48E2 && NAME =~ system_i/alexnet_m4n8_0/*
}]
set accelerator_bram36_cells [get_cells -hierarchical -filter {
    REF_NAME == RAMB36E2 && NAME =~ system_i/alexnet_m4n8_0/*
}]
set accelerator_bram18_cells [get_cells -hierarchical -filter {
    REF_NAME == RAMB18E2 && NAME =~ system_i/alexnet_m4n8_0/*
}]
set accelerator_uram_cells [get_cells -hierarchical -filter {
    REF_NAME == URAM288 && NAME =~ system_i/alexnet_m4n8_0/*
}]
set accelerator_bram18_equiv [expr {
    2*[llength $accelerator_bram36_cells] +
    [llength $accelerator_bram18_cells]
}]

set summary_file [open [file join $report_dir build_summary.txt] w]
puts $summary_file "TOP=[get_property TOP [current_fileset]]"
puts $summary_file "PART=[get_property PART [current_project]]"
puts $summary_file "CLOCK_MHZ=185"
puts $summary_file "BATCH=8"
puts $summary_file "DATAFLOW=PURE_EYERISS_ROW_STATIONARY"
puts $summary_file "PHYSICAL_ARRAY=3x12x14"
puts $summary_file "PHYSICAL_MAC_PES=504"
puts $summary_file "PASSES=1185"
puts $summary_file "USEFUL_MACS=5713507840"
puts $summary_file "CONSERVATIVE_DDR_BYTES=73941952"
puts $summary_file "POOL_RAW_READ_BYTES=3014656"
puts $summary_file "POOL_WRITE_BYTES=706560"
puts $summary_file "WNS=$setup_slack"
puts $summary_file "WHS=$hold_slack"
puts $summary_file "FAILED_ROUTE_NETS=[llength $failed_route_nets]"
puts $summary_file "DRC_ERRORS=[llength $drc_errors]"
puts $summary_file "DRC_CRITICAL_WARNINGS=[llength $drc_critical]"
puts $summary_file "TOTAL_DSP48E2=[llength $dsp_cells]"
puts $summary_file "RAMB36E2=[llength $bram36_cells]"
puts $summary_file "RAMB18E2=[llength $bram18_cells]"
puts $summary_file "URAM288=[llength $uram_cells]"
puts $summary_file "ACCELERATOR_DSP48E2=[llength $accelerator_dsp_cells]"
puts $summary_file "ACCELERATOR_RAMB36E2=[llength $accelerator_bram36_cells]"
puts $summary_file "ACCELERATOR_RAMB18E2=[llength $accelerator_bram18_cells]"
puts $summary_file "ACCELERATOR_BRAM18_EQUIV=$accelerator_bram18_equiv"
puts $summary_file "ACCELERATOR_URAM288=[llength $accelerator_uram_cells]"
close $summary_file

if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    error "Timing failed: WNS=$setup_slack WHS=$hold_slack"
}
if {[llength $failed_route_nets] != 0} {
    error "Routing failed for [llength $failed_route_nets] nets"
}
if {[llength $drc_errors] != 0 || [llength $drc_critical] != 0} {
    error "DRC failed: [llength $drc_errors] errors, [llength $drc_critical] critical warnings"
}
if {[llength $accelerator_dsp_cells] != 518 ||
    [llength $accelerator_uram_cells] != 55 ||
    $accelerator_bram18_equiv > 216} {
    error "Resource contract failed: ACCEL_DSP=[llength $accelerator_dsp_cells] ACCEL_URAM=[llength $accelerator_uram_cells] ACCEL_BRAM18_EQ=$accelerator_bram18_equiv"
}

set bit_source [file join $vivado_project_dir \
    alexnet_m4n8_kv260.runs impl_1 system_wrapper.bit]
if {![file exists $bit_source]} {
    error "Bitstream was not generated: $bit_source"
}
file copy -force $bit_source \
    [file join $output_dir alexnet_eyeriss_rs_batch8_kv260.bit]
write_hw_platform -fixed -include_bit -force \
    [file join $output_dir alexnet_eyeriss_rs_batch8_kv260.xsa]

puts "EYERISS_RS_BATCH8_KV260_BITSTREAM_DONE frequency_mhz=185 WNS=$setup_slack WHS=$hold_slack"
close_project
exit
