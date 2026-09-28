set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build result_tile_coalescer_ooc]
file mkdir $out_dir
cd $out_dir
read_verilog -sv [file join $alexnet_root rtl integration \
    alexnet_m8n126_result_tile_coalescer.sv]
synth_design -top alexnet_m8n126_result_tile_coalescer \
    -part xck26-sfvc784-2LV-c -mode out_of_context
set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]]
set uram_count [llength [get_cells -hierarchical -filter {REF_NAME == URAM288}]]
if {$dsp_count != 0} {
  error "result coalescer address generation consumed $dsp_count DSP48E2"
}
puts "ALEXNET_M8N126_RESULT_TILE_COALESCER_OOC_PASS DSP=$dsp_count URAM=$uram_count"
