# AegisNoC — Claude Code Master PRD
Version: 1.0
Hackathon: ChipCraft 3.0 — 24 Hour VLSI Hackathon
Project type: Synthesizable SystemVerilog RTL → verification → synthesis → netlist → physical design → final layout

## 1. Product Summary

AegisNoC is a compact, synthesizable, fault-tolerant 5-port Network-on-Chip router for a 2D mesh SoC. It combines deterministic XY routing, small per-input FIFOs, fair round-robin arbitration, a crossbar, and SECDED ECC-based fault resilience.

The project must be suitable for a complete ASIC flow within a 24-hour hackathon. The primary goal is not maximum feature count. The primary goal is a robust, understandable design that:
1. simulates correctly,
2. synthesizes cleanly,
3. is easy to verify,
4. exposes measurable timing/area tradeoffs,
5. reaches physical implementation and final layout,
6. has an excellent live fault-injection demo.

The project must include both:
- `BaselineNoC`: router without ECC protection.
- `AegisNoC`: functionally equivalent router with SECDED ECC protection.

The final engineering story is a measured comparison of the silicon cost of resilience.

---

## 2. Hackathon Context

ChipCraft 3.0 is a 24-hour VLSI challenge centered on the full digital ASIC implementation flow using Synopsys EDA tools. The official challenge flow includes:
- synthesizable RTL,
- functional verification,
- logic synthesis,
- gate-level netlist generation and analysis,
- physical design,
- placement and routing,
- design-quality checks,
- final IC layout.

Therefore every architecture choice in this PRD must optimize for completion of the full flow, not just RTL novelty.

---

## 3. Project Pitch

### Name
AegisNoC

### Tagline
Self-Healing Communication Fabric for Reliable SoCs

### Short pitch
AegisNoC is a 5-port mesh Network-on-Chip router that automatically corrects single-bit packet corruption, detects double-bit corruption, prevents illegal FIFO behavior, and arbitrates competing traffic fairly. The critical behavior is verified through simulation and assertions/formal properties, then synthesized and physically implemented as an ASIC block.

### Core demo sentence
“We deliberately flip a bit inside a packet, the router detects and repairs the corruption in hardware, and the destination still receives the original data.”

---

## 4. Scope Principles

Claude Code MUST follow these rules:

1. Prefer simple, synthesizable, deterministic RTL over clever abstractions.
2. Never add a feature that materially increases risk of missing synthesis/P&R.
3. Avoid vendor-specific constructs in RTL.
4. Use SystemVerilog features supported by mainstream synthesis.
5. Keep all parameterization compile-time and straightforward.
6. No dynamic arrays, classes, DPI, queues, delays, force/release, or unsynthesizable constructs in RTL.
7. Testbench code may use nonsynthesizable SystemVerilog.
8. RTL must have a single synchronous clock domain.
9. Use synchronous active-high reset unless project scripts force another convention.
10. Avoid inferred latches.
11. Avoid combinational loops.
12. Avoid multi-driver signals.
13. Register state explicitly.
14. All widths must be explicit enough to avoid accidental truncation/sign extension.
15. Keep physical implementation in mind: no absurdly wide mux structures unless justified.
16. The baseline and ECC-enabled versions should share as much routing architecture as practical.
17. Do not implement a CPU, cache coherence, AXI, adaptive routing, virtual channels, CDC, or retransmission protocol unless all core deliverables are already complete.

---

## 5. Top-Level Functional Requirements

AegisNoC shall implement a single router tile in a 2D mesh.

### Ports
Five logical ports:
- NORTH
- SOUTH
- EAST
- WEST
- LOCAL

Each port has an input channel and an output channel.

### Traffic unit
The fundamental unit is a fixed-width flit.

Default configuration:
- Data/flit information width before ECC: 32 bits.
- FIFO depth: 4 flits per input.
- Coordinates: compile-time-configurable small integer width, default 2 bits each.

If fitting destination coordinates and payload into exactly 32 bits becomes awkward, use a clean fixed packet field definition and document it. Do not create variable-length packets.

Recommended 32-bit logical flit:
- `[31:30]` destination X
- `[29:28]` destination Y
- `[27:0]` payload

Local router coordinates are parameters:
- `CURRENT_X`
- `CURRENT_Y`

### Flow control
Use simple valid/ready-style or push/pop-style handshaking.

Whichever convention is selected:
- define it once,
- document it,
- use it consistently,
- ensure data is held stable while stalled if using valid/ready.

---

## 6. Architecture

Data path:

Input Port
→ optional ECC decode/correction
→ Input FIFO
→ Route computation
→ Request generation
→ Per-output round-robin arbiter
→ 5x5 crossbar
→ optional ECC encode/output handling as defined by the selected ECC boundary
→ Output Port

Recommended ECC boundary:
- Treat the stored/transmitted protected flit as `{ecc_bits, logical_flit}`.
- Perform ECC decoding/correction before route computation so routing always sees corrected header bits.
- Forward corrected data.
- Re-encode corrected data at the output if the external channel is ECC-protected.

If schedule pressure is severe, use ECC at the input boundary and produce corrected logical data at output, but keep interfaces clean enough to extend later.

---

## 7. Module Breakdown

Required RTL files:

### `rtl/aegis_pkg.sv`
Contains:
- port enumeration/constants,
- width parameters/constants where appropriate,
- helper definitions safe for synthesis.

### `rtl/sync_fifo.sv`
Parameterized synchronous FIFO.
Required parameters:
- `WIDTH`
- `DEPTH`

Required behavior:
- push when `push && !full`
- pop when `pop && !empty`
- deterministic reset
- `full`
- `empty`
- optional occupancy/count signal for debug

No underflow or overflow state corruption.

### `rtl/xy_route.sv`
Pure combinational deterministic XY route computation.

Inputs:
- current X/Y
- destination X/Y

Output:
- one selected output port

Rules:
1. If destination X > current X → EAST
2. Else if destination X < current X → WEST
3. Else if destination Y > current Y → NORTH
4. Else if destination Y < current Y → SOUTH
5. Else → LOCAL

Use one canonical coordinate orientation and document it.

### `rtl/rr_arbiter.sv`
Parameterized or fixed 5-request round-robin arbiter.

Requirements:
- at most one grant per cycle,
- rotating priority,
- fairness under persistent requests,
- state only advances when a grant is consumed/accepted.

### `rtl/crossbar_5x5.sv`
Connects selected input flit to each output according to grants.

Requirements:
- no output sees more than one input,
- deterministic defaults,
- combinational implementation acceptable.

### `rtl/ecc_secded_encoder.sv`
SECDED encoder for the selected logical flit width.

Requirements:
- clearly documented codeword layout,
- deterministic parity mapping,
- synthesizable combinational logic.

### `rtl/ecc_secded_decoder.sv`
SECDED decoder/corrector.

Outputs:
- corrected logical data
- `single_error_corrected`
- `double_error_detected`
- optional syndrome/debug output

Required behavior:
- no error → data unchanged
- any single-bit error in protected codeword → corrected where SECDED permits and single-error status asserted
- double-bit error → uncorrectable flag asserted
- routing header must never use uncorrected corrupt data when single-error correction is possible.

### `rtl/router_core.sv`
Core router without mandatory ECC logic.
Should be usable by both baseline and Aegis wrappers.

Responsibilities:
- input FIFO integration,
- head-flit route computation,
- request matrix,
- per-output arbitration,
- pop generation,
- crossbar routing,
- output handshake.

### `rtl/baseline_noc.sv`
Top-level baseline design.
No ECC correction logic.

### `rtl/aegis_noc.sv`
Top-level protected design.
Adds ECC encode/decode/status logic around the same router architecture.

Required observability:
- aggregate `single_error_corrected`
- aggregate `double_error_detected`
- `error_count` or two counters if simple enough
- optional per-port debug only if it does not complicate implementation.

---

## 8. Arbitration Behavior

For each output, up to five inputs can request it.

Instantiate one arbiter per output.

Example:
- NORTH input wants EAST
- WEST input wants EAST
- LOCAL input wants EAST

EAST arbiter grants exactly one.

Fairness goal:
If a requester continuously requests an available output and downstream continues accepting data, it must not be permanently starved.

Do not attempt QoS classes or weighted arbitration.

---

## 9. FIFO Requirements

Each of five inputs has a depth-4 FIFO.

Recommended implementation:
- register array,
- read pointer,
- write pointer,
- occupancy count.

Keep pointer math safe for DEPTH=4.
If generic arbitrary DEPTH makes implementation messy, constrain/document power-of-two depth.

Required invariants:
- occupancy never exceeds DEPTH,
- pop cannot change state when empty,
- push cannot corrupt state when full,
- legal simultaneous push/pop supported.

---

## 10. ECC Requirements

Implement SECDED using Hamming-style parity plus overall parity.

Claude Code should:
1. derive parity locations correctly,
2. isolate the ECC implementation,
3. provide exhaustive single-bit fault tests,
4. provide representative/exhaustive double-bit detection tests as computationally practical.

The implementation must include a comment explaining:
- protected data width,
- number of Hamming parity bits,
- overall parity bit,
- total codeword width,
- syndrome interpretation.

For 32 data bits, choose the correct parity count mathematically rather than hardcoding an unexplained number.

Important:
A testbench must iterate through every bit of the complete protected codeword, flip that one bit, decode it, and verify the recovered logical data equals the original wherever required by the SECDED definition.

Double-bit test:
Flip two distinct codeword bits and confirm `double_error_detected`.

---

## 11. Error Counters

Aegis top-level should maintain simple synthesizable counters.

Recommended:
- `corrected_error_count[31:0]`
- `uncorrectable_error_count[31:0]`

Increment on an error event.
Saturating behavior is optional; wraparound is acceptable if documented.

Do not let diagnostic logic sit on the critical routing path unnecessarily.

---

## 12. Verification Plan

Required testbenches:

### `tb/tb_fifo.sv`
Tests:
- reset
- single push/pop
- fill to full
- drain to empty
- simultaneous push/pop
- blocked push while full
- blocked pop while empty
- ordering preservation

### `tb/tb_xy_route.sv`
Test all meaningful coordinate relations:
- local
- east
- west
- north
- south
- X dimension takes priority over Y when both differ.

Prefer exhaustive coordinate testing for the small coordinate space.

### `tb/tb_rr_arbiter.sv`
Tests:
- no requests
- each individual requester
- all requesters
- persistent contention
- round-robin sequence
- backpressure/accept behavior

### `tb/tb_ecc.sv`
Tests:
- clean data
- multiple payload patterns
- every single codeword bit flipped one at a time
- double-bit corruption
- status outputs

Suggested payload patterns:
- `32'h00000000`
- `32'hFFFFFFFF`
- `32'hDEADBEEF`
- `32'hA5A55A5A`
- randomized patterns

### `tb/tb_router.sv`
Tests routing and arbitration end to end without ECC.

Required scenarios:
- one packet each cardinal direction
- local delivery
- multiple inputs contending for same output
- multiple outputs active simultaneously
- backpressure
- FIFO buildup
- fairness under persistent traffic

### `tb/tb_aegis_fault_injection.sv`
Hero demo.

Sequence:
1. Build a logical flit whose payload visibly contains a known pattern.
2. ECC encode it.
3. Inject one bit flip in the protected flit.
4. Send it into AegisNoC.
5. Confirm correction flag.
6. Confirm destination receives original logical flit.
7. Inject a two-bit error.
8. Confirm double-error flag.

Use `DEADBEEF` as a demo payload if compatible with final packet format; otherwise choose a recognizable payload and clearly print both expected and received values.

All benches must self-check and terminate with explicit PASS/FAIL output.

---

## 13. Assertions / Formal Verification

Create:
- `formal/fifo_properties.sv`
- `formal/router_properties.sv`
- `formal/arbiter_properties.sv`
- `formal/ecc_properties.sv`

Use SVA where supported.

Key properties:

### FIFO
- no logical underflow
- no logical overflow
- occupancy bounds
- pointer/count state consistency where practical

### Arbiter
- `$onehot0(grant)`
- no grant without request
- accepted grant causes correct priority progression

### Router
- every accepted output grant corresponds to exactly one requesting input
- deterministic route output is legal
- if `dest_x > current_x`, requested port is EAST
- if `dest_x < current_x`, requested port is WEST
- when X equal, Y determines NORTH/SOUTH
- same X/Y means LOCAL

### ECC
For single-bit corruption:
- decoded/corrected logical data equals original data
- correction indication asserted appropriately.

For a known double-bit corruption:
- uncorrectable indication asserted.

If formal tooling availability becomes a blocker, keep the SVA source and demonstrate assertions in simulation rather than preventing the rest of the project from completing.

---

## 14. Synthesis Requirements

Create:
- `syn/constraints.sdc`
- `syn/synth.tcl`
- `syn/README.md`

Target tools:
- Synopsys Design Compiler or hackathon-provided equivalent flow.

The scripts must:
- read RTL in correct order,
- elaborate chosen top,
- link/check design,
- apply a clock constraint,
- apply reasonable input/output delays if expected,
- compile/optimize,
- write synthesized netlist,
- write reports.

Required reports:
- area
- cell usage/count
- timing
- critical path
- constraint violations
- power if accessible and reliable in available flow

Run synthesis independently for:
1. `baseline_noc`
2. `aegis_noc`

Store outputs separately.

Never fabricate PPA numbers.

---

## 15. Physical Design Requirements

Create a clean `pnr/` area for hackathon-specific ICC2 scripts.

Expected stages:
- import synthesized netlist
- floorplan
- power planning if required by provided environment
- placement
- clock tree synthesis
- routing
- timing/quality checks
- final layout export/screenshot-ready view

Because library paths and technology setup are environment-specific:
- use clearly marked variables/placeholders,
- do not invent PDK file paths,
- adapt to the scripts/examples supplied by organizers.

Deliver:
- final routed view
- post-route timing summary
- area/core utilization if available
- DRC/route quality summary where available.

The physical flow must take priority over optional RTL enhancements.

---

## 16. Baseline vs Aegis Experiment

The final report must compare `baseline_noc` and `aegis_noc`.

At minimum compare:
- total cell area
- combinational area
- sequential area
- cell count
- critical path delay
- slack
- derived maximum frequency if valid
- power if available
- corrected-fault capability
- detected double-bit-fault capability

Calculate:
- area overhead %
- delay overhead %
- optional power overhead %

Formula:
`overhead_percent = (aegis - baseline) / baseline * 100`

Do not claim ECC is “cheap” or “small overhead” unless measured results support it.

---

## 17. Repository Structure

```text
aegisnoc/
├── README.md
├── PRD.md
├── ENGINEERING_CONTEXT.md
├── rtl/
│   ├── aegis_pkg.sv
│   ├── sync_fifo.sv
│   ├── xy_route.sv
│   ├── rr_arbiter.sv
│   ├── crossbar_5x5.sv
│   ├── ecc_secded_encoder.sv
│   ├── ecc_secded_decoder.sv
│   ├── router_core.sv
│   ├── baseline_noc.sv
│   └── aegis_noc.sv
├── tb/
│   ├── tb_fifo.sv
│   ├── tb_xy_route.sv
│   ├── tb_rr_arbiter.sv
│   ├── tb_ecc.sv
│   ├── tb_router.sv
│   └── tb_aegis_fault_injection.sv
├── formal/
│   ├── fifo_properties.sv
│   ├── router_properties.sv
│   ├── arbiter_properties.sv
│   └── ecc_properties.sv
├── scripts/
│   ├── run_unit_tests.sh
│   └── run_all.sh
├── syn/
│   ├── constraints.sdc
│   ├── synth.tcl
│   └── README.md
├── pnr/
│   ├── README.md
│   └── flow_template.tcl
├── reports/
│   ├── baseline/
│   └── aegis/
└── docs/
    ├── architecture.md
    ├── verification.md
    ├── results.md
    └── demo_script.md
```

---

## 18. README Requirements

README must contain:
- one-line pitch
- problem
- architecture
- why NoC reliability matters
- key features
- module diagram in Mermaid or ASCII
- how to run tests
- how to run synthesis
- fault-injection demo
- verification table
- final baseline-vs-Aegis measured results table
- physical-design screenshot placeholders/links
- limitations
- future work

Avoid marketing claims not supported by measurements.

---

## 19. Demo Requirements

Hero demo should make the engineering result obvious in under one minute.

### Demo A: clean packet
Send packet.
Print:
- source
- destination
- original payload
- output payload
- status

Expected: no error.

### Demo B: single-bit corruption
Send a protected packet with one injected bit flip.

Print something similar to:
```text
Original payload       : 0xDEADBEEF
Injected fault bit     : 12
ECC syndrome           : ...
Single error corrected : YES
Received payload       : 0xDEADBEEF
RESULT                  : PASS
```

### Demo C: double-bit corruption
Flip two bits.

Expected:
```text
Double error detected  : YES
RESULT                  : PASS
```

### Demo D: contention
Three input ports repeatedly request one output.
Show round-robin grants rotate and no requester starves.

---

## 20. Definition of Done

P0 — must complete:
- [ ] RTL compiles
- [ ] baseline router works
- [ ] Aegis router works
- [ ] FIFOs work
- [ ] deterministic XY routing works
- [ ] round-robin arbitration works
- [ ] ECC clean case works
- [ ] every single-bit ECC fault test passes
- [ ] double-bit detection test passes
- [ ] end-to-end fault injection test passes
- [ ] self-checking regression passes
- [ ] baseline synthesis succeeds
- [ ] Aegis synthesis succeeds
- [ ] area/timing reports captured
- [ ] at least Aegis reaches the physical-design flow
- [ ] final routed layout captured if environment permits
- [ ] README and demo script complete

P1 — high value:
- [ ] formal/SVA checks demonstrated
- [ ] both baseline and Aegis physically implemented
- [ ] post-route comparison
- [ ] error counters
- [ ] comprehensive arbitration stress test

P2 — only after everything else:
- [ ] additional fault statistics
- [ ] parameter sweep
- [ ] power comparison
- [ ] more extensive random traffic
- [ ] prettier diagrams

---

## 21. Explicit Non-Goals

Do NOT build during the hackathon unless all P0/P1 work is finished:
- full RISC-V CPU
- AXI/ACE protocol
- cache coherence
- adaptive routing
- virtual channels
- wormhole protocol complexity beyond what is necessary
- retransmission engine
- multiple clock domains
- asynchronous FIFOs
- ML-based fault prediction
- web dashboard
- FPGA UI
- software stack
- operating system integration

---

## 22. Claude Code Working Method

Claude Code must execute incrementally.

For every module:
1. inspect existing architecture/contracts,
2. implement the smallest correct version,
3. create/update a self-checking test,
4. run available lint/compile/simulation,
5. fix all errors,
6. only then move on.

Do not generate the whole repository blindly before testing.

Maintain `docs/BUILD_STATUS.md` with:
- completed tasks,
- tests passing,
- known failures,
- next highest-priority task,
- synthesis status,
- P&R status.

When making architectural changes:
- update documentation,
- update tests,
- avoid silently changing interfaces.

Before every major new feature:
- ask internally whether it risks P0 completion,
- if yes, defer it.

---

## 23. Recommended Build Order

1. Repository scaffold.
2. Package/constants and interface definition.
3. `sync_fifo.sv` + tests.
4. `xy_route.sv` + exhaustive tests.
5. `rr_arbiter.sv` + contention/fairness tests.
6. `crossbar_5x5.sv`.
7. `router_core.sv`.
8. Baseline end-to-end router test.
9. Synthesize baseline early.
10. SECDED encoder/decoder.
11. Exhaustive ECC single-bit test.
12. `aegis_noc.sv`.
13. Hero fault-injection test.
14. Synthesize Aegis early.
15. SVA/formal properties.
16. Start/complete P&R.
17. Collect measured reports.
18. Generate comparison tables.
19. Final README/demo polish.
20. Optional enhancements only if time remains.

---

## 24. Engineering Decision Priority

When two designs are both correct, choose in this order:

1. more likely to synthesize and place/route,
2. easier to verify rigorously,
3. lower implementation risk,
4. better timing,
5. lower area,
6. cleaner code,
7. additional flexibility.

This ordering is intentional for a 24-hour ASIC hackathon.

---

## 25. Final Success Narrative

The completed project should allow the team to credibly say:

“We implemented the same 5-port NoC router twice: a baseline version and AegisNoC, a resilient SECDED-protected version. We verified correct routing, FIFO safety, arbitration behavior and fault recovery; deliberately injected corruption to prove recovery; synthesized both implementations; measured the actual area/timing cost of resilience; and carried the protected router through physical implementation to final layout.”

That is the product.
