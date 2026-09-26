# -----------------------------------------------------------------------------
# constraints.sdc — timing constraints for baseline_noc and aegis_noc.
#
# Both tops are constrained IDENTICALLY so the PPA comparison is fair.
# Tunables (set before sourcing, e.g. in synth.tcl or with dc_shell -x):
#   CLK_PERIOD       clock period in library time units (ns for most libs)
#   IN_DELAY_FRAC    input  delay as a fraction of the period
#   OUT_DELAY_FRAC   output delay as a fraction of the period
#   CLK_UNCERT_FRAC  setup uncertainty as a fraction of the period
#   DRIVING_CELL     optional library cell name for input drive (organizer lib)
#   OUTPUT_LOAD      optional output load in library cap units
# No library cell names are hard-coded here: DRIVING_CELL must come from the
# organizer's library documentation if used.
# -----------------------------------------------------------------------------

if {![info exists CLK_PERIOD]}      { set CLK_PERIOD      2.0  }
if {![info exists IN_DELAY_FRAC]}   { set IN_DELAY_FRAC   0.20 }
if {![info exists OUT_DELAY_FRAC]}  { set OUT_DELAY_FRAC  0.20 }
if {![info exists CLK_UNCERT_FRAC]} { set CLK_UNCERT_FRAC 0.05 }

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty -setup [expr {$CLK_UNCERT_FRAC * $CLK_PERIOD}] [get_clocks clk]

# All non-clock inputs (includes the synchronous reset, which is a real
# timing path into every flop's D-side reset mux).
set aegis_in_ports [remove_from_collection [all_inputs] [get_ports clk]]

set_input_delay  [expr {$IN_DELAY_FRAC  * $CLK_PERIOD}] -clock clk $aegis_in_ports
set_output_delay [expr {$OUT_DELAY_FRAC * $CLK_PERIOD}] -clock clk [all_outputs]

if {[info exists DRIVING_CELL] && $DRIVING_CELL ne ""} {
  set_driving_cell -lib_cell $DRIVING_CELL $aegis_in_ports
}
if {[info exists OUTPUT_LOAD] && $OUTPUT_LOAD ne ""} {
  set_load $OUTPUT_LOAD [all_outputs]
}
