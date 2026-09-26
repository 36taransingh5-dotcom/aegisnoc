# -----------------------------------------------------------------------------
# flow_template.tcl — Synopsys IC Compiler II flow for aegis_noc / baseline_noc.
#
#   TOP=aegis_noc    icc2_shell -f pnr/flow_template.tcl | tee pnr/icc2_aegis.log
#   TOP=baseline_noc icc2_shell -f pnr/flow_template.tcl | tee pnr/icc2_baseline.log
#
# Inputs
#   pnr/setup_local.tcl            technology values (copy of setup_template.tcl,
#                                  filled from organizer material) — REQUIRED
#   syn/out/<tag>/<top>.mapped.v   DC netlist   (from syn/synth.tcl)
#   syn/out/<tag>/<top>.mapped.sdc DC constraints
#
# Stages: import -> floorplan -> power plan -> place_opt -> clock_opt (CTS)
#         -> route_auto + route_opt -> fillers -> checks/reports -> outputs
# Knobs (env or Tcl var): CORE_UTIL (0.50), CORE_OFFSET (tech units, 5),
#                         STOP_AFTER (floorplan|place|cts|route; default: all)
# Outputs: reports/<tag>/pnr_*.rpt, pnr/out/<tag>/ (netlist, DEF, GDS, block)
#
# STATUS: written for ICC2 but NOT yet executed (no ICC2 on the development
# machine). Expect to adapt command options to the organizer's ICC2 version and
# reference scripts; keep every change in this file so it stays reproducible.
# -----------------------------------------------------------------------------

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize [file join $SCRIPT_DIR ..]]

# ---- Design selection ------------------------------------------------------------
if {![info exists TOP]} {
  if {[info exists ::env(TOP)]} { set TOP $::env(TOP) } else { set TOP aegis_noc }
}
if {$TOP eq "baseline_noc"} { set TAG baseline } elseif {$TOP eq "aegis_noc"} { set TAG aegis } else {
  puts "ERROR: TOP must be baseline_noc or aegis_noc"; exit 1
}
foreach {v d} {CORE_UTIL 0.50 CORE_OFFSET 5 STOP_AFTER all} {
  if {![info exists $v]} {
    if {[info exists ::env($v)]} { set $v $::env($v) } else { set $v $d }
  }
}

# ---- Technology setup (organizer-provided values only) ------------------------------
set SETUP [file join $SCRIPT_DIR setup_local.tcl]
if {![file exists $SETUP]} {
  puts "ERROR: $SETUP not found. Copy pnr/setup_template.tcl to pnr/setup_local.tcl"
  puts "       and fill it from the organizer's reference scripts / PDK."
  exit 1
}
source $SETUP

set missing {}
foreach v {NDM_REF_LIBS TLUP_MAX TLUP_MIN TLUP_LAYER_MAP PWR_NET GND_NET
           PG_RAIL_LAYER PG_MESH_H PG_MESH_V MIN_ROUTE_LAYER MAX_ROUTE_LAYER PIN_LAYERS
           PG_MESH_WIDTH PG_MESH_PITCH PG_MESH_SPACING} {
  if {![info exists $v] || [llength [set $v]] == 0} { lappend missing $v }
}
if {[llength $missing] > 0} {
  puts "ERROR: fill these in pnr/setup_local.tcl from organizer material: $missing"
  exit 1
}

set NETLIST [file join $ROOT syn out $TAG ${TOP}.mapped.v]
set SDC     [file join $ROOT syn out $TAG ${TOP}.mapped.sdc]
foreach f [list $NETLIST $SDC] {
  if {![file exists $f]} { puts "ERROR: missing $f — run syn/synth.tcl for $TOP first"; exit 1 }
}

set RPT [file join $ROOT reports $TAG]
set OUT [file join $ROOT pnr out $TAG]
file mkdir $RPT
file mkdir $OUT
set LIB [file join $OUT ${TOP}_lib]
if {[file exists $LIB]} { file delete -force $LIB }

proc stage_report {tag} {
  global RPT
  report_qor                                  > [file join $RPT pnr_${tag}_qor.rpt]
  report_timing -max_paths 5 -delay_type max  > [file join $RPT pnr_${tag}_timing_max.rpt]
  report_timing -max_paths 5 -delay_type min  > [file join $RPT pnr_${tag}_timing_min.rpt]
  report_utilization                          > [file join $RPT pnr_${tag}_utilization.rpt]
}
proc maybe_stop {stage} {
  global STOP_AFTER
  if {$STOP_AFTER eq $stage} { puts "INFO: STOP_AFTER=$stage reached"; save_block; save_lib; exit 0 }
}

# ---- 1. Import ------------------------------------------------------------------------
if {$TECH_FILE ne ""} {
  create_lib $LIB -technology $TECH_FILE -ref_libs $NDM_REF_LIBS
} else {
  create_lib $LIB -ref_libs $NDM_REF_LIBS
}
read_verilog -top $TOP $NETLIST
current_block $TOP
link_block

read_parasitic_tech -tlup $TLUP_MAX -layermap $TLUP_LAYER_MAP -name tlup_max
read_parasitic_tech -tlup $TLUP_MIN -layermap $TLUP_LAYER_MAP -name tlup_min
set_parasitic_parameters -late_spec tlup_max -early_spec tlup_min

read_sdc $SDC
set_ignored_layers -min_routing_layer $MIN_ROUTE_LAYER -max_routing_layer $MAX_ROUTE_LAYER

# ---- 2. Floorplan -------------------------------------------------------------------------
# Square core. The block is small but has many I/O bits (baseline 342,
# aegis 478 port bits); if pin placement is congested, lower CORE_UTIL.
initialize_floorplan -core_utilization $CORE_UTIL -side_ratio {1 1} -core_offset $CORE_OFFSET
set_block_pin_constraints -self -allowed_layers $PIN_LAYERS
place_pins -self
report_design -floorplan > [file join $RPT pnr_floorplan.rpt]
maybe_stop floorplan

# ---- 3. Power plan ------------------------------------------------------------------------
create_net -power  $PWR_NET
create_net -ground $GND_NET
connect_pg_net -automatic

create_pg_std_cell_conn_pattern P_rail -layers [list $PG_RAIL_LAYER]
set_pg_strategy S_rail -core -pattern [list [list name: P_rail] [list nets: [list $PWR_NET $GND_NET]]]

create_pg_mesh_pattern P_mesh -layers [list \
  [list [list horizontal_layer: $PG_MESH_H] [list width: $PG_MESH_WIDTH] [list pitch: $PG_MESH_PITCH] [list spacing: $PG_MESH_SPACING]] \
  [list [list vertical_layer: $PG_MESH_V]   [list width: $PG_MESH_WIDTH] [list pitch: $PG_MESH_PITCH] [list spacing: $PG_MESH_SPACING]] ]
set_pg_strategy S_mesh -core -pattern [list [list name: P_mesh] [list nets: [list $PWR_NET $GND_NET]]]

compile_pg -strategies [list S_rail S_mesh]
check_pg_connectivity > [file join $RPT pnr_pg_connectivity.rpt]
check_pg_drc          > [file join $RPT pnr_pg_drc.rpt]

# ---- 4. Placement ---------------------------------------------------------------------------
if {[llength $TIE_CELLS] > 0} { set_lib_cell_purpose -include optimization [get_lib_cells $TIE_CELLS] }
place_opt
stage_report place
maybe_stop place

# ---- 5. Clock tree synthesis ---------------------------------------------------------------
clock_opt
report_clock_qor > [file join $RPT pnr_clock_qor.rpt]
stage_report cts
maybe_stop cts

# ---- 6. Routing -------------------------------------------------------------------------------
route_auto
route_opt
stage_report route
maybe_stop route

# ---- 7. Fillers + final checks --------------------------------------------------------------------
if {[llength $FILLER_CELLS] > 0} {
  create_stdcell_fillers -lib_cells $FILLER_CELLS
  connect_pg_net -automatic
  remove_stdcell_fillers_with_violation
}
check_routes > [file join $RPT pnr_check_routes.rpt]
check_lvs    > [file join $RPT pnr_check_lvs.rpt]
report_timing -max_paths 10 -delay_type max > [file join $RPT pnr_final_timing_max.rpt]
report_timing -max_paths 10 -delay_type min > [file join $RPT pnr_final_timing_min.rpt]
report_qor                                  > [file join $RPT pnr_final_qor.rpt]
report_utilization                          > [file join $RPT pnr_final_utilization.rpt]
report_power                                > [file join $RPT pnr_final_power_vectorless.rpt]
report_design -all                          > [file join $RPT pnr_final_design.rpt]

# ---- 8. Outputs ------------------------------------------------------------------------------------
write_verilog [file join $OUT ${TOP}.routed.v]
write_def     [file join $OUT ${TOP}.routed.def]
if {$GDS_LAYER_MAP ne ""} {
  write_gds -layer_map $GDS_LAYER_MAP [file join $OUT ${TOP}.gds]
}
save_block
save_lib

puts "INFO: P&R of $TOP complete. Reports: $RPT  Outputs: $OUT"
puts "INFO: for the layout screenshot: icc2_shell -gui, open_lib $LIB, open_block $TOP,"
puts "      then File > Save Screen Image (or gui_write_window_image) into docs/images/."
exit
