set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build parameter_blob_cache_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv \
    [file join $alexnet_root rtl memory alexnet_parameter_blob_cache.sv] \
    [file join $alexnet_root tb tb_alexnet_parameter_blob_cache.sv]
exec xelab tb_alexnet_parameter_blob_cache -debug typical
exec xsim tb_alexnet_parameter_blob_cache -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_PARAMETER_BLOB_CACHE_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "AlexNet parameter blob cache simulation failed; see $log_path"
}
puts "ALEXNET_PARAMETER_BLOB_CACHE_SIM_PASS"
