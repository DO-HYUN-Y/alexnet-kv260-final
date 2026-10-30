set project_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $project_dir build synth_eyeriss_rs_memory_frontend]
set report_dir [file join $project_dir reports synth_eyeriss_rs_memory_frontend]
file mkdir $out_dir
file mkdir $report_dir

foreach source {
  alexnet_eyeriss_rs_board_address_gen.sv
  alexnet_eyeriss_rs_dma_line_cache.sv
  alexnet_eyeriss_rs_memory_frontend.sv
} {
  read_verilog -sv [file join $project_dir rtl $source]
}

synth_design -top alexnet_eyeriss_rs_memory_frontend \
  -part xck26-sfvc784-2LV-c -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 5.405 [get_ports clk]

write_checkpoint -force [file join $out_dir memory_frontend_synth.dcp]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
  -file [file join $report_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $report_dir timing_summary.rpt]
puts "EYERISS_RS_MEMORY_FRONTEND_SYNTH_DONE"
