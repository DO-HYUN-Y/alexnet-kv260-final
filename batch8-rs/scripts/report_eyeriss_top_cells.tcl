set project_dir [file normalize [file join [file dirname [info script]] ..]]
set checkpoint [file join $project_dir build synth_eyeriss_rs_3cluster \
                alexnet_eyeriss_rs_3cluster_synth.dcp]
set report_file [file join $project_dir reports synth_eyeriss_rs_3cluster \
                 top_level_primitive_counts.txt]
set name_file [file join $project_dir reports synth_eyeriss_rs_3cluster \
               top_level_lut6_names.txt]

open_checkpoint $checkpoint
set stream [open $report_file w]
set name_stream [open $name_file w]
set counts [dict create]
foreach cell [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE}] {
  set name [get_property NAME $cell]
  if {[llength [split $name /]] == 1} {
    set ref [get_property REF_NAME $cell]
    dict incr counts $ref
    if {$ref eq "LUT6"} {
      puts $name_stream $name
    }
  }
}
foreach ref [lsort [dict keys $counts]] {
  puts $stream [format "%-20s %8d" $ref [dict get $counts $ref]]
}
close $stream
close $name_stream
puts "EYERISS_TOP_CELL_REPORT_DONE"
