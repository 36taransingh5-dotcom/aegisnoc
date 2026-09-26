# -----------------------------------------------------------------------------
# setup_template.tcl — technology inputs for the ICC2 flow.
#
# COPY this file to pnr/setup_local.tcl and fill every value from the
# ORGANIZER-PROVIDED environment (reference scripts, PDK docs, lab handouts).
# Nothing here is guessed: every technology value starts empty, and
# flow_template.tcl refuses to run while a required value is empty.
#
# Typical places to look on the organizer machine (examples of WHAT to find,
# not paths): the reference ICC2 run script / Makefile, the library's NDM
# directory, the tech (.tf) file, TLU+ (*.tluplus) files and their layer map.
# -----------------------------------------------------------------------------

# ---- Libraries (REQUIRED) -------------------------------------------------------
set NDM_REF_LIBS   [list]   ;# standard-cell NDM(s), e.g. from the organizer's lib setup
set TECH_FILE      ""       ;# technology .tf file (leave "" only if the NDM carries the technology)

# ---- Parasitics (REQUIRED) ---------------------------------------------------------
set TLUP_MAX       ""       ;# max/late TLU+ file
set TLUP_MIN       ""       ;# min/early TLU+ file
set TLUP_LAYER_MAP ""       ;# TLU+ layer map (.map)

# ---- Power / ground (REQUIRED) -------------------------------------------------------
set PWR_NET        ""       ;# power net name used by the library cells (e.g. as in the lib)
set GND_NET        ""       ;# ground net name used by the library cells

# ---- Routing layers (REQUIRED, names exactly as in the tech file) --------------------------
set PG_RAIL_LAYER  ""       ;# std-cell rail layer (usually the lowest metal)
set PG_MESH_H      ""       ;# horizontal PG mesh layer
set PG_MESH_V      ""       ;# vertical PG mesh layer
set MIN_ROUTE_LAYER ""      ;# lowest signal routing layer
set MAX_ROUTE_LAYER ""      ;# highest signal routing layer
set PIN_LAYERS     [list]   ;# layers allowed for top-level pins

# ---- Physical-only cells (RECOMMENDED; names from the library) ------------------------------
set FILLER_CELLS   [list]   ;# filler cells, largest first
set TIE_CELLS      [list]   ;# tie-high / tie-low cells (optional)

# ---- PG mesh geometry (tune to the tech; units = tech units, usually um) ----------------------
set PG_MESH_WIDTH   ""
set PG_MESH_PITCH   ""
set PG_MESH_SPACING ""

# ---- Optional GDS export -----------------------------------------------------------------------
set GDS_LAYER_MAP  ""       ;# stream-out layer map; leave "" to skip write_gds
