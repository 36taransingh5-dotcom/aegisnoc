# Verification

There are three independent kinds of evidence. Each one is checked for vacuity, meaning I confirmed it can fail.

| Layer | What | Tool | Can it fail? |
|---|---|---|---|
| Simulation | 7 self-checking testbenches in 10 configurations (baseline/Aegis, with/without embedded SVA) | Verilator 5.052 (2-state) + Icarus 13.0 (4-state, catches X) | 26 injected RTL bugs, all caught (`scripts/mutation_check.py`) |
| Formal | Unbounded k-induction proofs + exhaustive ECC proofs | Yosys 0.69 `sat` (MiniSAT) | Reachability goals must be hit; negative controls on broken RTL must fail |
| Assertions in simulation | The same formal properties, compiled into the 16k-flit router regression | Verilator `+define+FORMAL` | An N/S-swapped router trips assertion R5 at 45 ns |

Run everything with `scripts/run_all.sh`. The reports go to `reports/sim/`, `reports/formal/` and `reports/yosys/`.

## 1. Simulation testbenches (all self-checking, `$fatal` on mismatch, explicit PASS banner)

| Testbench | DUT | What it proves | Scale |
|---|---|---|---|
| `tb_fifo` | `sync_fifo` | Reset, single push/pop, fill to full, blocked push when full, push+pop when full (pop only), drain order, blocked pop when empty, push+pop when empty (push only), push+pop at every occupancy, random stress against a queue model | 20,050 cycle checks |
| `tb_xy_route` | `xy_route` | Exhaustive: 4×4 current positions × 4×4 destinations; independent signed-delta golden model; X-before-Y priority | 256/256 cases |
| `tb_rr_arbiter` | `rr_arbiter` | No request, each single requester, all requesters rotating, persistent contention (exactly 10/10/10), grant stable and pointer frozen under backpressure, random against a circular-search model; bounded waiting ≤ N−1 checked every cycle | 20,066 checks; worst wait 4 = bound |
| `tb_crossbar` | `crossbar_5x5` | Every legal select pattern (none, or one of 5, per output) | 7,776 patterns |
| `tb_router` | `baseline_noc` | Each direction with exactly 2-cycle latency; N/S/E/W to LOCAL; all 25 input→output pairs; 3-way contention in strict rotation; 5 outputs busy in parallel; backpressure buffering exactly DEPTH+1 = 5; strict round-robin period at 100% and 50% output ready; 15,000 random flits at 70% valid / 60% ready. Every cycle it also checks stall stability, X-freedom (Icarus) and junk data on invalid inputs. | 16,480 flits in and out |
| `tb_router` (`+define+DUT_AEGIS`) | `aegis_noc` | The **identical** regression, with each output checked to be the exact SECDED codeword of the expected flit, and zero ECC events on clean traffic | 16,480 flits; cycle-for-cycle identical to the baseline |
| `tb_ecc` | encoder + decoder | For 269 data patterns (named, walking 1s and 0s, 200 random): encoder equals an independent positional model; clean decode; **every one of the 39 single-bit flips** is recovered with the syndrome equal to the Hamming position; **every one of the 741 double-bit pairs** is detected; 20,000 triple-bit samples match the model exactly (informational split) | 10,491 single + 199,329 double faults |
| `tb_aegis_fault_injection` | `aegis_noc` (+ `baseline_noc` for comparison) | The hero demo (A, B, B2, C, D) plus: an end-to-end sweep of all 39 bits, 39 end-to-end double faults dropped, 5 ports hit in one cycle (counter +5), a faulty flit held under backpressure counted exactly once, junk on idle inputs never counted, exact final counters | Deterministic |

### Independent reference models

- **ECC:** `tb/ecc_ref_model.svh` is built from the textbook positional definition, where the syndrome is the XOR of the positions of all set bits. It does *not* use the RTL's parity masks, so a wrong mask can't be copied into the checker.
- **Routing:** the golden route uses signed deltas; the RTL uses unsigned compares.
- **Arbitration:** the model does a circular search from the pointer; the RTL uses masked lowest-set-bit logic.
- **FIFO:** the model is a reference queue; the RTL is a circular buffer.

### Mutation check (`reports/sim/mutation.rpt`)

26 single-point bugs were injected, each compiled against the relevant testbench, and every one was caught: FIFO ×3, XY route ×2, arbiter ×3, router core ×5, ECC ×7, Aegis wrapper ×6.

Two mutants were excluded as *equivalent*, with the justification recorded in the script. Both only change `data` when it is architecturally don't-care: output data while `out_valid` is low, and decoder data for uncorrectable words.

## 2. Formal verification (`reports/formal/summary.rpt`)

The engine is Yosys `sat`: k-induction (`-tempinduct`) for sequential blocks, and a direct SAT proof for the combinational ECC. Initial state is all zeros, which equals the design's reset values; every input is otherwise unconstrained.

The properties live in `formal/*.sv`. Each RTL module includes its property file under `` `ifdef FORMAL ``, which gives the properties white-box visibility. Synthesis never defines `FORMAL`.

| File | Properties |
|---|---|
| `fifo_properties.sv` | P1 occupancy ≤ DEPTH · P2 flags agree with occupancy · P3 occupancy matches a shift-register model · P4 `wptr − rptr == count` · P5 head = oldest element · P6 every live entry equals the model · P7 push-when-full and pop-when-empty change nothing · P8 push+pop keeps the count |
| `arbiter_properties.sv` | A1 `$onehot0(grant)` · A2 no grant without request · A3 work-conserving · A4 pointer in range · A5 the winner is the first requester at or after the pointer · A6 rotation to winner+1 only on consume · **A7 starvation freedom:** a waiting requester is passed over at most N−1 times (inductive invariant `wait + dist(ptr,i) ≤ N−1`) |
| `router_properties.sv` | R1 one-hot grants · R2 a grant implies a non-empty input routed there · R3 an input is served by at most one output per cycle · R4 no pop when empty; `in_ready == !full` · R5 XY route legality at every head · R6 the crossbar forwards exactly the granted head, or zero · R7 stalled output held stable · R8 a loaded output equals the granted head · **R9 no flit can be presented on a port other than its XY route** |
| `ecc_properties.sv` | E1 clean codeword · **E2 every single-bit error corrected for all 2³² data words** · **E3 every double-bit error detected for all data** · E4 flags mutually exclusive for any 39-bit word · E5 no flag means a valid codeword with data untouched · E6 a corrected output re-encodes to a codeword exactly one bit from the input |

**Case splits.** MiniSAT times out when a *variable* error position feeds XOR-heavy parity trees. E2, E3 and E6 are therefore case-split **exhaustively**:
- E2: each of the 39 error positions.
- E3: each of the 741 unordered bit pairs. The harness is symmetric in the two positions, so unordered pairs cover every ordered pair.
- E6: each of the 64 syndrome values.

Every case is a full proof over all data, and every case must pass. `--quick` samples the cases for fast iteration and marks its report `QUICK — NOT a complete proof`.

**Non-vacuity (REACH).** A bounded search from reset must *find* each goal:
- FIFO: full; write-pointer wrap; push+pop while full.
- Arbiter: a requester waits exactly N−1 grants, which shows the bound is tight; all five requesting.
- Router: all 5 outputs valid at once; an output stalled with a backlog; two inputs contending.
- ECC: every branch is live under the assumptions.

**Negative controls.** Each proof is re-run on a deliberately broken copy of the RTL and must fail:
- FIFO push ignores full.
- Arbiter pointer parks on the winner, which causes starvation.
- Router output overwritten while stalled.
- Router X/Y header fields swapped.
- ECC with one wrong parity-mask bit. This fails at error bit 33 (p1), whose H-column collides with d0 in the mutant, so no single test pattern would reveal the bug.

## 3. Assertions during simulation

`tb_router_sva` and `tb_router_aegis_sva` run the full 16,480-flit regression with `+define+FORMAL`. Every FIFO, arbiter and router property is then checked on every cycle of real traffic, which is the PRD §13 fallback. It is demonstrated as well as proven: with the N/S directions swapped in `xy_route`, assertion R5 fires at 45 ns, before the misrouted flit can reach an output.

## 4. Synthesizability gate

`scripts/run_yosys.sh` elaborates each real top-level and fails on any latch, multi-driven net, combinational loop or undriven net. Both tops pass. DC's `synth.tcl` repeats the latch check and aborts if it finds one.

## 5. Known gaps

- Formal covers the blocks and `router_core`. The `aegis_noc` wrapper (drop gating and counters) is covered by simulation and mutation, not by formal.
- Nothing has been run on a gate-level (post-synthesis) netlist yet. That needs the organizer's cell library. With VCS on the organizer machine, rerun `tb_router` and `tb_aegis_fault_injection` against `syn/out/*/*.mapped.v` plus the library Verilog models.
- Power numbers, when they arrive, will be vectorless estimates. No SAIF or switching-activity annotation has been done yet.
