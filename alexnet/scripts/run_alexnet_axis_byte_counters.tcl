set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build axis_byte_counters_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl integration alexnet_axis_byte_counters.sv] \
    [file join $alexnet_root tb tb_alexnet_axis_byte_counters.sv]
exec xelab tb_alexnet_axis_byte_counters -debug typical
exec xsim tb_alexnet_axis_byte_counters -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_AXIS_BYTE_COUNTERS_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet AXI byte-counter simulation failed; see $log_path"
}
puts "ALEXNET_AXIS_BYTE_COUNTERS_SIM_PASS"
