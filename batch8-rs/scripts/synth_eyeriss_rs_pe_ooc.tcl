set project_dir [file normalize [file join [file dirname [info script]] ..]]
set report_dir [file join $project_dir reports synth_eyeriss_rs_pe]
file mkdir $report_dir
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_pe.sv]
synth_design -top alexnet_eyeriss_rs_pe -part xck26-sfvc784-2LV-c \
  -mode out_of_context -flatten_hierarchy none
create_clock -name clk -period 5.405 [get_ports clk]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
  -file [file join $report_dir timing_summary.rpt]
puts "EYERISS_RS_PE_SYNTH_DONE"
