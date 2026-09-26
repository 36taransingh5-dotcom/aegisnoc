#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_unit_tests.sh — build and run every self-checking testbench.
#
#   scripts/run_unit_tests.sh                 # all tests, both simulators
#   scripts/run_unit_tests.sh tb_fifo tb_ecc  # selected tests
#   SIM=verilator scripts/run_unit_tests.sh   # one simulator (verilator|icarus|both)
#
# A test passes only if its log contains its "<NAME>: PASS" line and the
# simulator exits cleanly. Logs: build/logs/<tb>.<sim>.log
# Works with the macOS system bash 3.2 (no associative arrays).
# -----------------------------------------------------------------------------
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

SIM=${SIM:-both}
RTL_ECC="rtl/ecc_secded_encoder.sv rtl/ecc_secded_decoder.sv"
RTL_CORE="rtl/aegis_pkg.sv rtl/sync_fifo.sv rtl/xy_route.sv rtl/rr_arbiter.sv rtl/crossbar_5x5.sv rtl/router_core.sv"
ALL_TESTS="tb_fifo tb_xy_route tb_rr_arbiter tb_crossbar tb_router tb_ecc tb_router_aegis tb_aegis_fault_injection tb_router_sva tb_router_aegis_sva"

# Source list per testbench (package first, then leaf modules, then TB).
tb_files() {
  case "$1" in
    tb_fifo)     echo "rtl/sync_fifo.sv tb/tb_fifo.sv" ;;
    tb_xy_route)   echo "rtl/aegis_pkg.sv rtl/xy_route.sv tb/tb_xy_route.sv" ;;
    tb_rr_arbiter) echo "rtl/rr_arbiter.sv tb/tb_rr_arbiter.sv" ;;
    tb_crossbar)   echo "rtl/aegis_pkg.sv rtl/crossbar_5x5.sv tb/tb_crossbar.sv" ;;
    tb_router)     echo "$RTL_CORE rtl/baseline_noc.sv tb/tb_router.sv" ;;
    tb_ecc)        echo "rtl/aegis_pkg.sv $RTL_ECC tb/tb_ecc.sv" ;;
    tb_router_aegis) echo "$RTL_CORE $RTL_ECC rtl/aegis_noc.sv tb/tb_router.sv" ;;
    tb_router_sva)       echo "$RTL_CORE rtl/baseline_noc.sv tb/tb_router.sv" ;;
    tb_router_aegis_sva) echo "$RTL_CORE $RTL_ECC rtl/aegis_noc.sv tb/tb_router.sv" ;;
    tb_aegis_fault_injection) echo "$RTL_CORE $RTL_ECC rtl/aegis_noc.sv rtl/baseline_noc.sv tb/tb_aegis_fault_injection.sv" ;;
    *)             echo "" ;;
  esac
}

# Top-level module and extra defines per test (default: module = test name).
tb_top() {
  case "$1" in
    tb_router_aegis|tb_router_sva|tb_router_aegis_sva) echo "tb_router" ;;
    *)               echo "$1" ;;
  esac
}
tb_defines() {
  case "$1" in
    tb_router_aegis)     echo "DUT_AEGIS" ;;
    tb_router_sva)       echo "FORMAL" ;;
    tb_router_aegis_sva) echo "DUT_AEGIS FORMAL" ;;
    *)               echo "" ;;
  esac
}

# Expected PASS banner per testbench (from its top module name).
tb_banner() {
  tb_top "$1" | tr '[:lower:]' '[:upper:]' | sed 's/$/: PASS/'
}

mkdir -p build/logs
TESTS=${*:-$ALL_TESTS}
n_pass=0
n_fail=0
failed=""

run_one() {  # $1=tb $2=sim
  local tb=$1 sim=$2 files log rc top defs vdef idef
  files=$(tb_files "$tb")
  top=$(tb_top "$tb")
  defs=$(tb_defines "$tb")
  vdef=""; idef=""
  for d in $defs; do vdef="$vdef +define+$d"; idef="$idef -D$d"; done
  log="build/logs/$tb.$sim.log"
  if [ -z "$files" ]; then
    echo "  [$sim] $tb : UNKNOWN TEST"; n_fail=$((n_fail+1)); failed="$failed $tb/$sim"; return
  fi
  if [ "$sim" = verilator ]; then
    # shellcheck disable=SC2086
    verilator --binary --timing --assert -j 0 --timescale 1ns/1ps -Wno-fatal \
      -Itb -Iformal $vdef --top-module "$top" --Mdir "build/vl_$tb" -o "$tb" $files > "$log" 2>&1 \
      && "./build/vl_$tb/$tb" >> "$log" 2>&1
    rc=$?
  else
    # shellcheck disable=SC2086
    iverilog -g2012 -Itb $idef -s "$top" -o "build/iv_$tb.vvp" $files > "$log" 2>&1 \
      && vvp -n "build/iv_$tb.vvp" >> "$log" 2>&1
    rc=$?
  fi
  if [ $rc -eq 0 ] && grep -q "$(tb_banner "$tb")" "$log"; then
    echo "  [$sim] $tb : PASS"
    n_pass=$((n_pass+1))
  else
    echo "  [$sim] $tb : FAIL  (see $log)"
    grep -m3 -E "Fatal|FATAL|Error|error" "$log" | sed 's/^/        /'
    n_fail=$((n_fail+1))
    failed="$failed $tb/$sim"
  fi
}

# Tests that embed the formal properties (FORMAL) use $past: Verilator only.
sims_for() {
  case "$1" in
    *_sva) echo "verilator" ;;
    *)     echo "verilator icarus" ;;
  esac
}

echo "== AegisNoC unit tests (SIM=$SIM) =="
for tb in $TESTS; do
  allowed=$(sims_for "$tb")
  case "$SIM" in
    verilator) run_one "$tb" verilator ;;
    icarus)    case "$allowed" in *icarus*) run_one "$tb" icarus ;; *) echo "  [icarus] $tb : skipped (Verilator-only test)";; esac ;;
    *)         for s in $allowed; do run_one "$tb" "$s"; done ;;
  esac
  continue
  case "$SIM" in
    verilator) run_one "$tb" verilator ;;
    icarus)    run_one "$tb" icarus ;;
    *)         run_one "$tb" verilator; run_one "$tb" icarus ;;
  esac
done

echo "== summary: $n_pass passed, $n_fail failed =="

# Persistent summary for scripts/collect_results.py (only for full runs).
if [ -z "${*:-}" ]; then
  mkdir -p reports/sim
  {
    echo "AegisNoC simulation regression — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "tools: $(verilator --version | head -1) | $(iverilog -V 2>&1 | head -1)"
    echo "result: $n_pass passed, $n_fail failed${failed:+ (FAILED:$failed)}"
    echo
    for f in build/logs/*.log; do
      b=$(basename "$f" .log)
      if grep -q ": PASS" "$f"; then r=PASS; else r=FAIL; fi
      echo "$b : $r"
      grep -hE "^\[tb_[a-z_]+\] (checks=|cases=|select patterns|patterns=|sent=|INFO)" "$f" | sed 's/^/    /'
    done
  } > reports/sim/summary.rpt
fi
if [ $n_fail -ne 0 ]; then
  echo "FAILED:$failed"
  exit 1
fi
echo "ALL UNIT TESTS PASS"
