set part xck26-sfvc784-2LV-c
set_param general.maxThreads 8
set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build m8n126_graph_top_batch8_ooc]
set report_dir [file join $alexnet_root reports m8n126_graph_top_batch8_ooc]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

set rtl_sources [lsort [glob [file join $alexnet_root rtl * *.sv]]]
lappend rtl_sources [file join $repo_root rtl axi_dma_simple_master.sv]
read_verilog -sv $rtl_sources
synth_design -top alexnet_m8n126_graph_accelerator_top -part $part \
    -mode out_of_context -directive PerformanceOptimized \
    -generic NATIVE_BATCH8=1

set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]]
set uram_count [llength [get_cells -hierarchical -filter {REF_NAME == URAM288}]]
set bram36_count [llength [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]]
set bram18_count [llength [get_cells -hierarchical -filter {REF_NAME == RAMB18E2}]]
set lut_count [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
set ff_count [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]
report_utilization -hierarchical \
    -file [file join $report_dir utilization_hierarchical.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir timing_summary.rpt]
write_checkpoint -force [file join $out_dir post_synth.dcp]

set metadata [open [file join $report_dir run_metadata.txt] w]
puts $metadata "design=alexnet_m8n126_graph_accelerator_top"
puts $metadata "native_batch8=1"
puts $metadata "dsp48e2=$dsp_count"
puts $metadata "uram288=$uram_count"
puts $metadata "ramb36e2=$bram36_count"
puts $metadata "ramb18e2=$bram18_count"
puts $metadata "luts=$lut_count"
puts $metadata "ffs=$ff_count"
close $metadata

if {$dsp_count != 576 || $uram_count > 64} {
  error "batch8 top resource contract failed: DSP=$dsp_count URAM=$uram_count"
}
puts "ALEXNET_M8N126_GRAPH_TOP_BATCH8_OOC_PASS DSP=$dsp_count URAM=$uram_count BRAM36=$bram36_count BRAM18=$bram18_count LUT=$lut_count FF=$ff_count"
