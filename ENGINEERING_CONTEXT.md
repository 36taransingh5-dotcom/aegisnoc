# AegisNoC — Engineering Context for Claude Code

Read this file together with `PRD.md`.

## Hackathon facts

ChipCraft 3.0 is a 24-hour VLSI hackathon. The public challenge description says participants should take a synthesizable digital RTL design through:
RTL → functional verification → logic synthesis → gate-level netlist → physical design → placement/routing → final IC layout.

The hackathon uses Synopsys EDA tooling. Treat actual organizer-provided setup files, libraries, reference scripts, PDK data and tool versions as authoritative. Never invent paths or technology files.

The design should therefore be optimized for completing the full flow.

## What judges should remember

AegisNoC is not “just another router.”

The memorable experiment is:

1. send a valid protected packet,
2. deliberately corrupt one physical/codeword bit,
3. AegisNoC diagnoses and corrects it,
4. original logical data still arrives,
5. corrupt two bits,
6. AegisNoC flags the error as uncorrectable,
7. show the exact PPA cost versus an otherwise equivalent baseline router,
8. show the routed physical layout.

The visual proof should be a waveform/log plus layout, not just slides.

## Engineering philosophy

This is a hardware project. Avoid app-style overengineering.

The final submission is stronger with:
- 8 solid modules,
- strong self-checking verification,
- formal assertions,
- two successful syntheses,
- actual area/timing reports,
- a routed block,

than with:
- 20 half-working features.

## Default architectural choices

Unless existing code or supplied environment gives a compelling reason otherwise:
- SystemVerilog
- one clock domain
- synchronous reset
- 5 logical ports
- fixed-width logical flit
- small 2D coordinate fields
- FIFO depth 4
- deterministic XY routing
- per-output round-robin arbitration
- 5x5 crossbar
- SECDED Hamming ECC
- no virtual channels
- no adaptive routing
- no protocol conversion
- no CDC

## Verification standard

Every testbench should be self-checking.

Bad:
“Open waveform and visually inspect.”

Good:
- calculate expected behavior,
- compare automatically,
- `$fatal` on mismatch,
- explicit PASS line.

For ECC specifically, test every possible single-bit position of the protected codeword.

For routing, exhaust the small coordinate space.

For arbitration, stress persistent contention.

## Synthesis/physical design discipline

Never use an RTL construct merely because a simulator accepts it.

Be especially careful with:
- loops with unclear static bounds,
- nonconstant array sizes,
- implicit signed arithmetic,
- modulo/division in datapath,
- reset of large memories,
- inferred huge muxes,
- accidental latch inference,
- uninitialized state,
- multiple always blocks driving one signal.

Run synthesis as early as possible.

The first baseline synthesis should happen before ECC integration is considered “finished.”

## Metrics

Do not fabricate numbers.

Only fill results from actual tool reports.

Prefer recording:
- total area
- sequential area
- combinational area
- cell count
- WNS/TNS
- critical-path delay
- target clock period
- maximum frequency only if derivable legitimately
- core utilization
- post-route timing
- power only if methodology is meaningful

## Demo priority

The project has four demonstration layers:

Layer 1 — functionality:
packet reaches correct port.

Layer 2 — reliability:
single-bit corruption gets corrected.

Layer 3 — rigor:
assertions/formal/self-checking tests prove safety properties.

Layer 4 — implementation:
synthesis reports + physical layout prove the design is real hardware.

Do not sacrifice Layer 4 to add more Layer 2 features.

## If time is running out

Freeze architecture.

Remove optional diagnostics before removing:
- ECC
- arbitration
- FIFO
- synthesis
- P&R

A routed simple design beats a sophisticated RTL design that never reaches layout.
