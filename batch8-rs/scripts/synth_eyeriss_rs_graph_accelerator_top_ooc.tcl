set project_dir [file normalize [file join [file dirname [info script]] ..]]
set external_root [file normalize [file join $project_dir ..]]
if {[info exists ::env(ALEXNET_REPO_ROOT)]} {
  set external_root [file normalize $::env(ALEXNET_REPO_ROOT)]
}
set out_dir [file join $project_dir build synth_eyeriss_rs_graph_accelerator_top]
set report_dir [file join $project_dir reports synth_eyeriss_rs_graph_accelerator_top]
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
  read_verilog -sv [file join $project_dir rtl $source]
}

read_verilog -sv [file join $external_root alexnet rtl integration \
  alexnet_axi_dma_dual_channel_master.sv]
read_verilog -sv [file join $external_root alexnet rtl integration \
  alexnet_axis_byte_counters.sv]
read_verilog -sv [file join $external_root alexnet rtl control \
  alexnet_axi_lite_regs.sv]
read_verilog -sv [file join $external_root rtl axi_dma_simple_master.sv]

synth_design -top alexnet_eyeriss_rs_graph_accelerator_top \
  -part xck26-sfvc784-2LV-c -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name aclk -period 5.405 [get_ports aclk]

write_checkpoint -force [file join $out_dir graph_accelerator_top_synth.dcp]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
  -file [file join $report_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $report_dir timing_summary.rpt]
puts "EYERISS_RS_GRAPH_ACCELERATOR_TOP_SYNTH_DONE"
