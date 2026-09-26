#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_demo.sh — the live judge demo: deterministic fault injection on AegisNoC.
#
#   scripts/run_demo.sh          # print the demo transcript (~2 s)
#   scripts/run_demo.sh --vcd    # also dump build/aegis_demo.vcd for a waveform viewer
#
# Uses Icarus Verilog (fast compile, 4-state). The transcript is also saved to
# reports/sim/aegis_demo_transcript.txt. Exit code is non-zero if any check fails.
# -----------------------------------------------------------------------------
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build reports/sim

PLUS=""
if [ "${1:-}" = "--vcd" ]; then PLUS="+vcd"; fi

SRC="rtl/aegis_pkg.sv rtl/sync_fifo.sv rtl/xy_route.sv rtl/rr_arbiter.sv rtl/crossbar_5x5.sv
     rtl/router_core.sv rtl/ecc_secded_encoder.sv rtl/ecc_secded_decoder.sv rtl/aegis_noc.sv
     rtl/baseline_noc.sv tb/tb_aegis_fault_injection.sv"

# shellcheck disable=SC2086
iverilog -g2012 -Itb -s tb_aegis_fault_injection -o build/aegis_demo.vvp $SRC
vvp -n build/aegis_demo.vvp $PLUS | grep -v '\$finish called' | tee reports/sim/aegis_demo_transcript.txt

grep -q "TB_AEGIS_FAULT_INJECTION: PASS" reports/sim/aegis_demo_transcript.txt
if [ -n "$PLUS" ]; then echo "waveform: build/aegis_demo.vcd"; fi
