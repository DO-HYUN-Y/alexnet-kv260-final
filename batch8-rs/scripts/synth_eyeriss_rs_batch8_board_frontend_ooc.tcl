set project_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $project_dir build synth_eyeriss_rs_batch8_board_frontend]
set report_dir [file join $project_dir reports synth_eyeriss_rs_batch8_board_frontend]
file mkdir $out_dir
file mkdir $report_dir

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
} {
  read_verilog -sv [file join $project_dir rtl $source]
}

synth_design -top alexnet_eyeriss_rs_batch8_board_frontend_top \
  -part xck26-sfvc784-2LV-c -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 5.405 [get_ports clk]

write_checkpoint -force [file join $out_dir batch8_board_frontend_synth.dcp]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
  -file [file join $report_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $report_dir timing_summary.rpt]
puts "EYERISS_RS_BATCH8_BOARD_FRONTEND_SYNTH_DONE"
