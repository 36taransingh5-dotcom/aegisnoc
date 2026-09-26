#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_all.sh — every check that runs without Synopsys tools, then the results page.
#
#   scripts/run_all.sh           # full (~15 min): lint, sims, mutation, yosys, formal, demo, results
#   scripts/run_all.sh --quick   # skips mutation; formal ECC case splits sampled (~3 min)
#
# Synopsys steps (DC synthesis, ICC2 P&R) are run separately on the organizer
# machine: see syn/README.md and pnr/README.md. Re-run
# `python3 scripts/collect_results.py` afterwards to pull their reports in.
# -----------------------------------------------------------------------------
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

RTL_CORE="rtl/aegis_pkg.sv rtl/sync_fifo.sv rtl/xy_route.sv rtl/rr_arbiter.sv rtl/crossbar_5x5.sv rtl/router_core.sv"
RTL_ECC="rtl/ecc_secded_encoder.sv rtl/ecc_secded_decoder.sv"

status=()
step() {  # $1 = name, rest = command
  local name=$1; shift
  echo
  echo "################ $name ################"
  local t0=$SECONDS
  if "$@"; then status+=("PASS  $name ($((SECONDS - t0))s)"); else status+=("FAIL  $name ($((SECONDS - t0))s)"); fi
}

lint() {
  # shellcheck disable=SC2086
  verilator --lint-only -Wall --top-module baseline_noc $RTL_CORE rtl/baseline_noc.sv &&
  # shellcheck disable=SC2086
  verilator --lint-only -Wall --top-module aegis_noc $RTL_CORE $RTL_ECC rtl/aegis_noc.sv &&
  echo "verilator -Wall: baseline_noc and aegis_noc clean (0 warnings)"
}

step "RTL lint (Verilator -Wall)"          lint
step "Simulation regression"               scripts/run_unit_tests.sh
if [ $QUICK -eq 0 ]; then
  step "Mutation check"                    python3 scripts/mutation_check.py
fi
step "Yosys gate: baseline_noc"            scripts/run_yosys.sh baseline_noc
step "Yosys gate: aegis_noc"               scripts/run_yosys.sh aegis_noc
if [ $QUICK -eq 0 ]; then
  step "Formal (full)"                     python3 scripts/run_formal.py
else
  step "Formal (quick)"                    python3 scripts/run_formal.py --quick
fi
step "Hero demo"                           scripts/run_demo.sh
step "Collect results"                     python3 scripts/collect_results.py

echo
echo "================ run_all summary ================"
fail=0
for s in "${status[@]}"; do echo "  $s"; case "$s" in FAIL*) fail=1 ;; esac; done
[ $fail -eq 0 ] && echo "ALL STEPS PASS" || echo "SOME STEPS FAILED"
exit $fail
