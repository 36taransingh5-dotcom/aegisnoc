# -----------------------------------------------------------------------------
# synth.tcl — Synopsys Design Compiler flow for baseline_noc / aegis_noc.
#
# Run from any directory (paths are resolved relative to this script):
#   TOP=baseline_noc AEGIS_LIB_SETUP=/path/from/organizer/setup.tcl dc_shell -f syn/synth.tcl | tee syn/dc_baseline.log
#   TOP=aegis_noc    AEGIS_LIB_SETUP=/path/from/organizer/setup.tcl dc_shell -f syn/synth.tcl | tee syn/dc_aegis.log
#
# Library setup is NEVER guessed. It must come from the organizer, either:
#   (a) a .synopsys_dc.setup already present in the launch directory, or
#   (b) AEGIS_LIB_SETUP pointing to the organizer's setup script,
# which must set search_path, target_library and link_library. The script
# aborts if target_library is still DC's placeholder "your_library.db".
#
# Optional overrides (Tcl vars via `dc_shell -x "set CLK_PERIOD 1.5" -f ...`
# or environment variables of the same name): CLK_PERIOD, IN_DELAY_FRAC,
# OUT_DELAY_FRAC, CLK_UNCERT_FRAC, DRIVING_CELL, OUTPUT_LOAD, COMPILE_CMD.
#
# Outputs
#   reports/<baseline|aegis>/  : area, hierarchical area, QoR, timing, violators,
#                                cell usage, power (vectorless estimate), checks
#   syn/out/<baseline|aegis>/  : mapped netlist (.v), .ddc, .sdc for ICC2
# -----------------------------------------------------------------------------

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize [file join $SCRIPT_DIR ..]]

# ---- Design selection --------------------------------------------------------
if {![info exists TOP]} {
  if {[info exists ::env(TOP)]} { set TOP $::env(TOP) } else { set TOP baseline_noc }
}
if {[lsearch -exact {baseline_noc aegis_noc} $TOP] < 0} {
  puts "ERROR: TOP must be baseline_noc or aegis_noc (got '$TOP')"
  exit 1
}
if {$TOP eq "baseline_noc"} { set TAG baseline } else { set TAG aegis }

foreach v {CLK_PERIOD IN_DELAY_FRAC OUT_DELAY_FRAC CLK_UNCERT_FRAC DRIVING_CELL OUTPUT_LOAD COMPILE_CMD} {
  if {![info exists $v] && [info exists ::env($v)]} { set $v $::env($v) }
}

# ---- Library setup (organizer-provided) ------------------------------------------
if {[info exists ::env(AEGIS_LIB_SETUP)]} {
  puts "INFO: sourcing organizer library setup: $::env(AEGIS_LIB_SETUP)"
  source $::env(AEGIS_LIB_SETUP)
}
set tl [get_app_var target_library]
if {[llength $tl] == 0 || [string match "*your_library*" $tl]} {
  puts "ERROR: target_library is not configured ('$tl')."
  puts "       Provide the organizer's DC setup (.synopsys_dc.setup or AEGIS_LIB_SETUP)."
  exit 1
}
puts "INFO: target_library = $tl"
puts "INFO: link_library   = [get_app_var link_library]"

set RPT [file join $ROOT reports $TAG]
set OUT [file join $ROOT syn out $TAG]
file mkdir $RPT
file mkdir $OUT

# ---- Read RTL ------------------------------------------------------------------------
set rtl_list {aegis_pkg.sv sync_fifo.sv xy_route.sv rr_arbiter.sv crossbar_5x5.sv router_core.sv}
if {$TOP eq "baseline_noc"} {
  lappend rtl_list baseline_noc.sv
} else {
  lappend rtl_list ecc_secded_encoder.sv ecc_secded_decoder.sv aegis_noc.sv
}
set RTL_FILES {}
foreach f $rtl_list { lappend RTL_FILES [file join $ROOT rtl $f] }

define_design_lib WORK -path [file join $OUT work]
if {![analyze -format sverilog -library WORK $RTL_FILES]} { puts "ERROR: analyze failed"; exit 1 }
if {![elaborate $TOP -library WORK]}                       { puts "ERROR: elaborate failed"; exit 1 }
current_design $TOP
if {![link]} { puts "ERROR: link failed"; exit 1 }

check_design > [file join $RPT check_design_pre.rpt]

set latches [all_registers -level_sensitive]
if {[sizeof_collection $latches] > 0} {
  puts "ERROR: [sizeof_collection $latches] latch(es) inferred:"
  foreach_in_collection l $latches { puts "   [get_object_name $l]" }
  exit 1
}

# ---- Constraints -----------------------------------------------------------------
source [file join $SCRIPT_DIR constraints.sdc]

# Path groups make the cost of ECC visible per path class. in2out must be
# empty: every input-to-output path goes through a flop by design.
group_path -name in2reg  -from [all_inputs] -to [all_registers -data_pins]
group_path -name reg2reg -from [all_registers -clock_pins] -to [all_registers -data_pins]
group_path -name reg2out -from [all_registers -clock_pins] -to [all_outputs]
group_path -name in2out  -from [all_inputs] -to [all_outputs]
# Aegis only: the 32-bit error counters get their own group so they cannot
# masquerade as (or hide) the router's reg2reg critical path.
if {$TOP eq "aegis_noc"} {
  group_path -name diag -to [get_cells -hierarchical *error_count_reg*]
}

# Netlist hygiene for ICC2: no assign statements / tie constants to ports.
set_fix_multiple_port_nets -all -buffer_constants

# ---- Compile ---------------------------------------------------------------------
# Hierarchy is preserved (-no_autoungroup) so area can be attributed to
# router_core vs. ECC blocks. Both tops use the same command.
if {![info exists COMPILE_CMD]} { set COMPILE_CMD "compile_ultra -no_autoungroup" }
puts "INFO: compile command: $COMPILE_CMD"
eval $COMPILE_CMD

# ---- Reports ----------------------------------------------------------------------
report_qor                                            > [file join $RPT qor.rpt]
report_area                                           > [file join $RPT area.rpt]
report_area -hierarchy                                > [file join $RPT area_hier.rpt]
report_timing -delay_type max -max_paths 1            > [file join $RPT critical_path.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 > [file join $RPT timing_max.rpt]
set groups {in2reg reg2reg reg2out in2out}
if {$TOP eq "aegis_noc"} { lappend groups diag }
foreach g $groups {
  report_timing -delay_type max -max_paths 1 -group $g > [file join $RPT timing_${g}.rpt]
}
report_timing -delay_type min -max_paths 5            > [file join $RPT timing_min.rpt]
report_constraint -all_violators                      > [file join $RPT constraint_violators.rpt]
report_reference                                      > [file join $RPT cell_usage.rpt]
report_clock                                          > [file join $RPT clocks.rpt]
check_design                                          > [file join $RPT check_design_post.rpt]
# Vectorless power with the tool's default switching activity: an estimate
# only, labelled as such wherever it is quoted.
report_power                                          > [file join $RPT power_vectorless.rpt]

set fp [open [file join $RPT run_info.txt] w]
puts $fp "top            : $TOP"
puts $fp "date           : [clock format [clock seconds]]"
puts $fp "target_library : $tl"
puts $fp "clk_period     : $CLK_PERIOD"
puts $fp "in_delay_frac  : $IN_DELAY_FRAC"
puts $fp "out_delay_frac : $OUT_DELAY_FRAC"
puts $fp "uncert_frac    : $CLK_UNCERT_FRAC"
puts $fp "compile_cmd    : $COMPILE_CMD"
close $fp

# ---- Outputs for physical design ---------------------------------------------------
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output [file join $OUT ${TOP}.mapped.v]
write -format ddc     -hierarchy -output [file join $OUT ${TOP}.mapped.ddc]
write_sdc                                [file join $OUT ${TOP}.mapped.sdc]

puts "INFO: synthesis of $TOP complete. Reports in $RPT, netlist in $OUT"
exit
