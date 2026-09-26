#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_yosys.sh — technology-independent synthesis with Yosys.
#
#   scripts/run_yosys.sh baseline_noc
#   scripts/run_yosys.sh aegis_noc
#
# Purpose:
#   1. Synthesizability GATE: elaborates the real top, then FAILS if Yosys finds
#      any latch, multiple driver, combinational loop or undriven signal.
#   2. A like-for-like, technology-independent comparison between the two tops:
#      flip-flop count, generic gate count (NAND/NOR/NOT after abc -g cmos2),
#      a CMOS transistor estimate, and logic depth (longest comb. path, levels).
#
# These are NOT area/timing/power results. The only PPA numbers reported by
# this project come from Synopsys DC/ICC2 with the organizer's library.
# -nordff: stops Yosys duplicating FIFO read pointers into RAM read ports, so
# the flip-flop count equals the RTL state bits (DC does not do that either).
# Outputs: reports/yosys/<top>/{yosys.log,summary.rpt}
# -----------------------------------------------------------------------------
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

TOP=${1:-baseline_noc}
RTL_CORE="rtl/aegis_pkg.sv rtl/sync_fifo.sv rtl/xy_route.sv rtl/rr_arbiter.sv rtl/crossbar_5x5.sv rtl/router_core.sv"
case "$TOP" in
  baseline_noc) FILES="$RTL_CORE rtl/baseline_noc.sv" ;;
  aegis_noc)    FILES="$RTL_CORE rtl/ecc_secded_encoder.sv rtl/ecc_secded_decoder.sv rtl/aegis_noc.sv" ;;
  *) echo "unknown top: $TOP" >&2; exit 2 ;;
esac

OUT="reports/yosys/$TOP"
mkdir -p "$OUT" build
LOG="$OUT/yosys.log"

yosys -q -l "$LOG" -p "
  read_verilog -sv $FILES
  hierarchy -check -top $TOP
  proc
  check -assert
  synth -top $TOP -flatten -nordff
  check -assert
  select -assert-none t:\$_DLATCH* t:\$dlatch* t:\$_SR* t:\$sr
  tee -o $OUT/stat_generic.rpt stat
  dfflegalize -cell \$_DFF_P_ 01
  abc -g cmos2
  opt_clean
  tee -o $OUT/stat_cmos.rpt stat -tech cmos
  tee -o $OUT/ltp.rpt ltp -noff
  write_verilog -noattr build/${TOP}_yosys_generic.v
"

# ---- Summary (parsed from Yosys' own reports) --------------------------------
ff=$(awk '/\$_DFF_P_/ {print $1; exit}' "$OUT/stat_cmos.rpt")
gates=$(( $(awk '/\$_NAND_/ {print $1; exit}' "$OUT/stat_cmos.rpt") + $(awk '/\$_NOR_/ {print $1; exit}' "$OUT/stat_cmos.rpt") + $(awk '/\$_NOT_/ {print $1; exit}' "$OUT/stat_cmos.rpt") ))
nand=$(awk '/\$_NAND_/ {print $1; exit}' "$OUT/stat_cmos.rpt")
nor=$(awk '/\$_NOR_/ {print $1; exit}' "$OUT/stat_cmos.rpt")
inv=$(awk '/\$_NOT_/ {print $1; exit}' "$OUT/stat_cmos.rpt")
tr=$(grep -iE "transistors" "$OUT/stat_cmos.rpt" | head -1 | grep -oE "[0-9]+" | head -1)
depth=$(grep -oE "length=[0-9]+" "$OUT/ltp.rpt" | head -1 | cut -d= -f2)

{
  echo "Yosys technology-independent summary for $TOP"
  echo "(NOT a PPA result — generic NAND/NOR/NOT mapping, no library, no timing)"
  echo "yosys_version      : $(yosys -V)"
  echo "flip_flops         : ${ff:-?}"
  echo "comb_gates         : ${gates:-?}   (NAND2+NOR2+INV)"
  echo "nand2 / nor2 / inv : ${nand:-0} / ${nor:-0} / ${inv:-0}"
  echo "cmos_transistors   : ${tr:-?}   (Yosys 'stat -tech cmos' estimate)"
  echo "logic_depth_levels : ${depth:-?}   (Yosys 'ltp -noff', longest reg/port-to-reg/port path in gates)"
  echo "latches            : 0 (asserted)"
  echo "check -assert      : clean (no multi-driver / comb loop / undriven)"
} | tee "$OUT/summary.rpt"
