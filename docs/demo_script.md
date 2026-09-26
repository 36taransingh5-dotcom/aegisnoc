# Demo script (about 3 minutes)

The four layers from ENGINEERING_CONTEXT, in order: **functionality → reliability → rigor → implementation.**

## Setup (before judges arrive)

```bash
scripts/run_demo.sh --vcd      # prints the transcript, writes build/aegis_demo.vcd
```

Have these open in tabs:
1. The terminal with the demo transcript.
2. The waveform (`build/aegis_demo.vcd`) in the available viewer, with these signals added: `dut.in_valid`, `dut.in_data`, `dut.g_dec[4].syndrome`, `dut.single_error_corrected`, `dut.double_error_detected`, `dut.out_valid`, `dut.out_data`, `dut.corrected_error_count`.
3. `docs/results.md`, which holds the measured baseline-vs-Aegis PPA.
4. The routed layout screenshot, `docs/images/aegis_layout.png`.

## 1. One-line pitch (10 s)

> "AegisNoC is a 5-port mesh NoC router that repairs single-bit corruption in hardware before the packet is routed. We built the same router twice so we can measure exactly what that resilience costs in silicon."

## 2. Layer 1: it routes (20 s), Demo A

The flit `0xDEADBEEF` has its header set to destination (3,1). From tile (1,1) that means **EAST**.

> "Clean packet in on LOCAL, out on EAST, two-cycle latency, no error flags."

## 3. Layer 2: it heals (60 s), Demos B, B2 and C (the hero moment)

- **B.** "We flip payload bit 12 on the wire." Point at the transcript: the syndrome is `010010`, which is Hamming position 18. Then: *single error corrected: YES*, received `0xDEADBEEF`.
- **B2.** This is the one to linger on. "Now we flip a *header* bit, bit 31. The same corrupted flit goes into a plain router and into AegisNoC." The baseline router sends it out of **LOCAL**, misrouted *and* corrupt. AegisNoC corrects the header before the routing decision, and the flit leaves **EAST** intact.
- **C.** "Two bits flipped. SECDED can't correct that, so AegisNoC **detects** it, drops the flit so a corrupt header is never routed, and counts it."
- Close with the sweep lines: every one of the 39 codeword bits is corrected end to end, and 39 of 39 double faults are dropped.
- Optional, if the waveform is open: show the `single_error_corrected` pulse and the counter stepping.

## 4. Layer 3: it's proven (30 s)

- Show `reports/formal/summary.rpt`, which lists unbounded k-induction proofs for the FIFO, the arbiter (including **starvation freedom**) and the router (**no flit can leave through the wrong port**).
- The ECC proof covers **all 2³² data words** at every single-bit position and every double-bit pair. Simulation checks examples; this proof covers every case.
- "Every proof also has a negative control: we break the RTL on purpose and the proof must fail." The same applies to the 26 mutation tests on the testbenches.
- Demo D (round-robin): `N W L N W L …`, 6/6/6 grants, nobody starved.

## 5. Layer 4: it's real hardware (40 s)

- Open `docs/results.md`. Read the area overhead and the critical-path overhead, per path group, **from the table**.
- Quote only numbers that are in the table. Don't call the overhead "small" unless the table shows it is.
- Show the routed layout.
- "Same router core, same constraints, same compile, so the difference between the two tops is exactly the ECC plus its diagnostics."

## 6. Close (10 s)

> "Detect, correct, keep routing correctly, and measure what it costs. That's AegisNoC."

## Likely questions

| Question | Answer |
|---|---|
| Why is the ECC before the FIFO rather than at the FIFO head? | Routing must never see a corrupt header, and this placement keeps the decoder off the router's internal critical path. FIFO-storage protection is listed as future work. |
| What about 3-bit errors? | They're beyond SECDED's guarantee. `tb_ecc` measures them: about 30% are flagged and about 70% are mis-corrected, which is standard for Hamming+parity. |
| Why drop double-error flits instead of forwarding them? | A double error can hit the header, and forwarding would route on garbage. Dropping plus the counter plus the flag lets software or retransmission handle it; retransmission is out of scope. |
| Is the fairness claim tested or proven? | Both. It's proven: waiting is bounded by N−1 = 4 consumed grants, and a reachable trace shows the bound is tight. It's also tested under 50% output backpressure. |
