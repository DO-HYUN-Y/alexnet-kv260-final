set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m8n126_result_tile_coalescer_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv \
    [file join $alexnet_root rtl integration \
        alexnet_m8n126_result_tile_coalescer.sv] \
    [file join $alexnet_root tb \
        tb_alexnet_m8n126_result_tile_coalescer.sv]
exec xelab tb_alexnet_m8n126_result_tile_coalescer -debug typical
exec xsim tb_alexnet_m8n126_result_tile_coalescer -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match \
        "*ALEXNET_M8N126_RESULT_TILE_COALESCER_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "AlexNet result tile coalescer simulation failed; see $log_path"
}
puts "ALEXNET_M8N126_RESULT_TILE_COALESCER_SIM_PASS"
