set project_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $project_dir build synth_eyeriss_rs_3cluster]
set report_dir [file join $project_dir reports synth_eyeriss_rs_3cluster]
file mkdir $out_dir
file mkdir $report_dir

read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_pe.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_mac_pe.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_filter_vector_bank.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_pe_set_noc.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_gin.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_local_psum_network.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_cluster.sv]
read_verilog -sv [file join $project_dir rtl alexnet_eyeriss_rs_3cluster_core.sv]

synth_design -top alexnet_eyeriss_rs_3cluster_core \
  -part xck26-sfvc784-2LV-c -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 5.405 [get_ports clk]

write_checkpoint -force [file join $out_dir alexnet_eyeriss_rs_3cluster_synth.dcp]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
  -file [file join $report_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $report_dir timing_summary.rpt]

puts "EYERISS_RS_3CLUSTER_SYNTH_DONE"
