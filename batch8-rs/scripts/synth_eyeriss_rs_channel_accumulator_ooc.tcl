set project_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $project_dir build synth_eyeriss_rs_channel_accumulator]
set report_dir [file join $project_dir reports synth_eyeriss_rs_channel_accumulator]
file mkdir $out_dir
file mkdir $report_dir

read_verilog -sv [file join $project_dir rtl \
  alexnet_eyeriss_rs_channel_accumulator.sv]
synth_design -top alexnet_eyeriss_rs_channel_accumulator \
  -part xck26-sfvc784-2LV-c -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 5.405 [get_ports clk]

write_checkpoint -force [file join $out_dir channel_accumulator_synth.dcp]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
  -file [file join $report_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $report_dir timing_summary.rpt]
puts "EYERISS_RS_CHANNEL_ACCUMULATOR_SYNTH_DONE"
