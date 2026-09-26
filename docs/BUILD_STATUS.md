# AegisNoC — Build Status

Last updated: 2026-09-25 (session 1)

## Current state (one line)

RTL, verification (simulation + mutation + formal) and the synthesizability gate are complete for both tops. The DC and ICC2 flows are written but **not yet run**, because Synopsys tools are only available on the organizer machine.

## Next highest-priority task (on the organizer machine)

1. Find the organizer's DC library setup, then run `syn/synth.tcl` for `baseline_noc` **and** `aegis_noc`, with the same `CLK_PERIOD` for both.
2. Fill in `pnr/setup_local.tcl` from the organizer's reference ICC2 script, then run `pnr/flow_template.tcl` for `aegis_noc` (P0) and then `baseline_noc` (P1).
3. Capture the layout screenshot into `docs/images/`, run `python3 scripts/collect_results.py`, and update the README results table from `docs/results.md`.

---

## Environment findings (inspected, not assumed)

| Item | Finding |
|---|---|
| Host | macOS 26.5, arm64 (developer laptop, **not** the hackathon EDA server) |
| Synopsys DC / ICC2 / VCS | **Not present on this machine.** Nothing in `syn/` or `pnr/` has been run with Synopsys yet. |
| Organizer scripts / PDK / libs | **None supplied in the repo or pack.** Every library/PDK path is an explicit variable; both flows refuse to run until they're filled. |
| Open-source HDL tools | Installed with Homebrew: **Verilator 5.052** (lint `-Wall` + primary 2-state sim), **Icarus Verilog 13.0** (secondary 4-state sim; catches X), **Yosys 0.69** (synthesizability gate, generic gate counts, formal via built-in `sat`). |
| Formal engine | Yosys built-in `sat` (MiniSAT): k-induction and combinational proofs. No SymbiYosys or external SMT solver needed. |
| Tool quirks found | Yosys 0.69 rejects `import pkg::*`, so RTL uses qualified `aegis_pkg::NAME` (TBs may import). Yosys `sat` can't do `$cover` or `$check` cells, so reachability uses `-prove goal 0` (must FAIL), plus `async2sync` to lower checks. MiniSAT times out on XOR cancellation with a variable error position, so the ECC proofs are exhaustively case-split. Icarus 13 segfaults on an early `return` inside a `for` loop with a block-local variable. BSD `sed` has no `\b`. The Yosys `memory_dff` pass duplicates FIFO read pointers, so the flow uses `-nordff` to keep the flop count equal to the RTL state. |

Consequence: every PPA number in this repo must come from the organizer's Synopsys run. The Yosys results are a synthesizability gate and a structural comparison only, and are always labelled that way.

---

## Architecture decisions (frozen unless a test forces a change)

| # | Decision | Rationale |
|---|---|---|
| D1 | Logical flit = 32 b: `[31:30]` dest X, `[29:28]` dest Y, `[27:0]` payload | PRD §5 recommended format |
| D2 | X grows **EAST**, Y grows **NORTH**; `COORD_W = 2` (4x4 mesh) | One canonical orientation (PRD §7) |
| D3 | Port indices: N=0, S=1, E=2, W=3, L=4 | PRD listing order |
| D4 | Valid/ready on every channel; a transfer happens on `valid && ready` | PRD §5 |
| D5 | `in_ready = !fifo_full`, never dependent on `in_valid` or data | No combinational valid→ready loop |
| D6 | Registered output stage per output; arbitration fires when the register is empty or being drained | Stable outputs; no in→out combinational path; clean I/O timing |
| D7 | The round-robin pointer advances **only** when a grant loads the output register | PRD §7 |
| D8 | FIFO: depth 4, power-of-two only; storage array not reset | PRD §9 |
| D9 | Push ignored when full, pop ignored when empty (even when simultaneous) | PRD §7 literal rule |
| D10 | Full 5x5 crossbar (U-turns are legal in hardware) | Simplest |
| D11 | Top-level tile default `CURRENT_X = 1, CURRENT_Y = 1` | All 5 directions reachable |
| D12 | SECDED Hamming(38,32) + overall parity = 39 b, laid out as `{P, p[5:0], data[31:0]}` | PRD §6 `{ecc_bits, logical_flit}` |
| D13 | Decode and correct at each input **before** the FIFO; re-encode after the output register | Routing sees only corrected headers; `router_core` identical in both tops, so the comparison is fair |
| D14 | Uncorrectable flits are consumed, **dropped** and counted | Never route on a corrupt header |
| D15 | Flags and counters come from a registered per-port event vector (1-cycle lag) | Keeps diagnostics off the decode path (PRD §11) |
| D16 | Top-level ports are flat packed vectors | Portable netlists |
| D17 | Formal properties live in `formal/*.sv` and are included into RTL under `` `ifdef FORMAL `` | White-box visibility for k-induction; Yosys has no `bind` |
| D18 | DC: hierarchy preserved (`compile_ultra -no_autoungroup`), path groups in2reg/reg2reg/reg2out/in2out (+ `diag` for the Aegis counters) | Per-block area attribution and per-path-class delay comparison |

---

## Implementation checklist

`[x]` done and verified · `[~]` in progress · `[ ]` not started · `[!]` blocked

### Phase 1 — RTL + unit verification
- [x] Repository scaffold, `scripts/run_unit_tests.sh`, `scripts/mutation_check.py`
- [x] `rtl/aegis_pkg.sv`
- [x] `rtl/sync_fifo.sv` + `tb/tb_fifo.sv`
- [x] `rtl/xy_route.sv` + `tb/tb_xy_route.sv` (exhaustive)
- [x] `rtl/rr_arbiter.sv` + `tb/tb_rr_arbiter.sv`
- [x] `rtl/crossbar_5x5.sv` + `tb/tb_crossbar.sv` (exhaustive)
- [x] `rtl/router_core.sv`, `rtl/baseline_noc.sv` + `tb/tb_router.sv`

### Phase 2 — Early baseline synthesis
- [x] `syn/constraints.sdc`, `syn/synth.tcl` (DC), `syn/README.md`; Tcl parses as complete
- [x] Yosys synthesizability gate for `baseline_noc` (`scripts/run_yosys.sh`)
- [!] DC synthesis of `baseline_noc`: **blocked on the organizer machine and library**

### Phase 3 — ECC + Aegis
- [x] `rtl/ecc_secded_encoder.sv`, `rtl/ecc_secded_decoder.sv` (masks derived by script, documented in the package)
- [x] `tb/tb_ecc.sv` + independent `tb/ecc_ref_model.svh`: all 39 single flips and all 741 double flips × 269 patterns
- [x] `rtl/aegis_noc.sv`
- [x] Aegis passes the identical router regression (`tb_router_aegis`)
- [x] `tb/tb_aegis_fault_injection.sv`: hero demo + sweeps + burst + stall; `scripts/run_demo.sh`
- [x] Yosys gate for `aegis_noc`
- [!] DC synthesis of `aegis_noc`: **blocked on the organizer machine**

### Phase 4 — Assertions / formal
- [x] `formal/fifo_properties.sv`, `arbiter_properties.sv`, `router_properties.sv`, `ecc_properties.sv`
- [x] `scripts/run_formal.py`: proofs, reachability and negative controls, **26/26**
- [x] Assertions also run inside the 16k-flit simulation (`tb_router_sva`, `tb_router_aegis_sva`)

### Phase 5 — Physical design (P0)
- [x] `pnr/flow_template.tcl`, `pnr/setup_template.tcl`, `pnr/README.md`; guard logic tested with `tclsh`
- [!] Aegis routed layout, post-route timing, utilization, DRC: **blocked on the organizer ICC2 and PDK**
- [ ] (P1) Baseline routed as well

### Phase 6 — Results + docs
- [x] `scripts/collect_results.py` (report parsers self-tested; `n/a` for anything missing)
- [x] `docs/architecture.md`, `docs/verification.md`, `docs/demo_script.md`, `README.md`
- [~] `docs/results.md`: generated; the Synopsys sections stay `n/a` until the DC/ICC2 reports exist

---

## Tests passing

| Check | Verilator | Icarus | Notes |
|---|---|---|---|
| tb_fifo | PASS | PASS | 20,050 cycle checks |
| tb_xy_route | PASS | PASS | 256/256 cases |
| tb_rr_arbiter | PASS | PASS | 20,066 checks; worst wait 4 = bound |
| tb_crossbar | PASS | PASS | 7,776 select patterns |
| tb_router (baseline) | PASS | PASS | 16,480/16,480 flits |
| tb_router_aegis | PASS | PASS | Identical regression; cycle-for-cycle equal to the baseline |
| tb_ecc | PASS | PASS | 10,491 single + 199,329 double faults |
| tb_aegis_fault_injection | PASS | PASS | Demo A/B/B2/C/D, sweeps, burst, stall, exact counters |
| tb_router_sva / tb_router_aegis_sva | PASS | n/a (needs `$past`) | All formal properties checked during simulation |

- **Clean end-to-end run** (`scripts/run_all.sh`, from deleted reports, 10 min 53 s): **ALL STEPS PASS**. That covers lint, 18/18 simulation runs, 26/26 mutants, both Yosys gates, full formal 26/26, the demo and the results page.
- Lint: `verilator --lint-only -Wall` on both tops, 0 warnings. (A regression was caught and fixed: after the ECC constants were added to the shared package, the baseline lint flagged them as unused. They are now waived in the ECC section only.)
- Mutation: 26/26 injected bugs caught; 2 equivalent mutants excluded with justification.
- Formal (FULL): 26 checks, 0 problems. That's 4 unbounded proofs (k=2), ECC E1–E6 for all 2³² data (E2 39/39 positions, E3 741/741 pairs, E6 64/64 syndromes), 12 reachability goals and 5 negative controls.

## Known failures / open issues

- None in what can be run locally.
- Neither the DC script nor the ICC2 flow has executed yet. Expect to adapt command options to the organizer's tool versions and reference scripts on the day.
- No gate-level simulation yet (needs library Verilog models).

## Synthesis status

- Yosys (technology-independent): both tops clean. `baseline_noc` has 855 FF; `aegis_noc` has 929 FF (855 + 10 event flops + 64 counter bits). The generic longest path in Aegis is the counter carry chain; DC reports it separately in the `diag` group.
- DC: not run (blocked on the organizer environment).

## P&R status

Flow written; not run (blocked on the organizer ICC2 and PDK).
