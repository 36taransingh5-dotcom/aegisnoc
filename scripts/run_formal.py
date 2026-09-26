#!/usr/bin/env python3
"""
run_formal.py — formal verification of AegisNoC with Yosys' built-in SAT engine.

    python3 scripts/run_formal.py            # full run (several minutes)
    python3 scripts/run_formal.py --quick    # ECC case splits sampled (for iteration)

Three kinds of checks, all recorded in reports/formal/summary.rpt:

  PROOF      sequential targets: `sat -tempinduct` (k-induction) — an UNBOUNDED
             proof that every assertion holds in every reachable state, starting
             from the reset state (all state zero == the design's reset values).
             ECC: combinational `sat -prove-asserts`, free inputs => all 2^32
             data words. Where MiniSAT struggles with XOR cancellation, the proof
             is case-split EXHAUSTIVELY (every error position / pair / syndrome
             value) and every case must pass.
  REACH      non-vacuity: each named goal must be FOUND by a bounded search from
             reset (sat reports "model found" for the claim "goal is never 1").
  NEGATIVE   the same proof is run on a deliberately broken copy of the RTL and
             MUST fail — evidence the properties have teeth.
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "reports", "formal")
LOGS = os.path.join(OUT, "logs")
WORK = os.path.join(ROOT, "build", "formal")

CORE = ["rtl/aegis_pkg.sv", "rtl/sync_fifo.sv", "rtl/xy_route.sv", "rtl/rr_arbiter.sv",
        "rtl/crossbar_5x5.sv", "rtl/router_core.sv"]
ECC = ["rtl/aegis_pkg.sv", "rtl/ecc_secded_encoder.sv", "rtl/ecc_secded_decoder.sv",
       "formal/ecc_properties.sv"]

SEQ_TARGETS = [
    # name, top, sources, max induction steps, reach goals, reach depth
    ("fifo", "sync_fifo", ["rtl/sync_fifo.sv"], 12,
     ["f_reach_full", "f_reach_wrap", "f_reach_pushpop_full"], 12),
    ("arbiter", "rr_arbiter", ["rtl/rr_arbiter.sv"], 12,
     ["f_reach_max_wait", "f_reach_all_req"], 12),
    ("router", "router_core", CORE, 8,
     ["f_reach_all_out", "f_reach_stall_backlog", "f_reach_contention"], 8),
]

# Negative controls: (label, target, file, old, new)
NEGATIVE = [
    ("fifo: push ignores full", "fifo", "rtl/sync_fifo.sv",
     "assign do_push = push && !full;", "assign do_push = push;"),
    ("arbiter: pointer parks on winner (starvation)", "arbiter", "rtl/rr_arbiter.sv",
     "next_ptr = (i == N-1) ? '0 : IW'(i + 1);", "next_ptr = IW'(i);"),
    ("router: output overwritten while stalled", "router", "rtl/router_core.sv",
     "assign load[o] = !out_valid_q[o] || out_ready[o];", "assign load[o] = 1'b1;"),
    ("router: X/Y header fields swapped", "router", "rtl/router_core.sv",
     ".dst_x    (head[i*W + aegis_pkg::DX_LSB +: CW]),",
     ".dst_x    (head[i*W + aegis_pkg::DY_LSB +: CW]),"),
    ("ecc: one parity-mask bit wrong", "ecc_e2_b0", "rtl/aegis_pkg.sv",
     "ECC_M0 = 32'h56AA_AD5B;", "ECC_M0 = 32'h56AA_AD5A;"),
]

PREP_SEQ = "prep -top {top} -flatten\nmemory_map\nopt_clean\nasync2sync\ndffunmap\n"
PREP_ECC = ("chparam -set GROUP {group} ecc_properties\nprep -top ecc_properties -flatten\n"
            "async2sync\nopt -full\n")

results = []   # (kind, name, verdict, detail, seconds)


def yosys(script_text, tag):
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    ys = os.path.join(WORK, f"{tag}.ys")
    log = os.path.join(LOGS, f"{tag}.log")
    open(ys, "w").write(script_text)
    t0 = time.time()
    p = subprocess.run(["yosys", "-q", "-l", log, "-s", ys], cwd=ROOT,
                       capture_output=True, text=True)
    dt = time.time() - t0
    text = open(log).read() if os.path.exists(log) else p.stdout + p.stderr
    return p.returncode, text, dt


def read_cmd(sources, root_override=None):
    srcs = " ".join(sources)
    inc = f"-I{os.path.join(ROOT, 'formal')}"
    return f"read_verilog -sv -formal -DFORMAL {inc} {srcs}\n"


def seq_proof(name, top, sources, maxsteps, tag=None):
    tag = tag or f"proof_{name}"
    s = read_cmd(sources) + PREP_SEQ.format(top=top)
    s += f"sat -tempinduct -prove-asserts -set-init-zero -maxsteps {maxsteps} -verify\n"
    rc, text, dt = yosys(s, tag)
    ok = rc == 0 and "Induction step proven: SUCCESS!" in text
    depth = 0
    for line in text.splitlines():
        if line.startswith("Base case for induction length") and "proven" in line:
            depth = int(line.split("length")[1].split()[0])
    return ok, depth, dt


def reach(name, top, sources, goal, depth, prep=None, extra=""):
    s = read_cmd(sources) + (prep or PREP_SEQ.format(top=top))
    s += "chformal -assert -remove\n" if prep else "chformal -remove\n"
    s += f"sat -seq {depth} -set-init-zero {extra} -prove {goal} 0\n" if not prep else \
         f"sat -set-assumes -prove {goal} 0\n"
    rc, text, dt = yosys(s, f"reach_{name}_{goal}")
    found = "model found: FAIL!" in text
    return found, dt


def ecc_group(group, cases, tag):
    """cases: list of '-set ...' strings (one sat call each); [''] = no split."""
    s = read_cmd(ECC) + PREP_ECC.format(group=group)
    for c in cases:
        s += f"sat {c} -prove-asserts -set-assumes -timeout 300 -verify\n"
    rc, text, dt = yosys(s, tag)
    n_ok = text.count("no model found: SUCCESS!")
    return rc == 0 and n_ok == len(cases), n_ok, dt


def record(kind, name, ok, detail, dt):
    verdict = {"PROOF": "PROVEN" if ok else "FAILED",
               "REACH": "REACHED" if ok else "NOT REACHED",
               "NEGATIVE": "CAUGHT" if ok else "MISSED"}[kind]
    results.append((kind, name, verdict, detail, dt))
    print(f"  {kind:<8} {name:<52} {verdict:<11} {detail}  ({dt:.1f}s)", flush=True)


def main():
    quick = "--quick" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    print("== AegisNoC formal (Yosys sat, MiniSAT) ==")

    # ---- Sequential targets ----------------------------------------------------------
    for name, top, srcs, maxsteps, goals, rdepth in SEQ_TARGETS:
        ok, depth, dt = seq_proof(name, top, srcs, maxsteps)
        record("PROOF", f"{name} ({top}) all assertions", ok,
               f"k-induction, converged at k={depth}" if ok else "see log", dt)
        for g in goals:
            found, dt = reach(name, top, srcs, g, rdepth)
            record("REACH", f"{name}: {g}", found, f"bounded search depth {rdepth}", dt)

    # ---- ECC ---------------------------------------------------------------------------
    b_all = list(range(39))
    pairs = [(a, b) for a in range(39) for b in range(a + 1, 39)]
    syn_all = list(range(64))
    if quick:
        b_all, pairs, syn_all = [0, 12, 31, 38], pairs[::97], [0, 3, 18, 38, 45]

    ok, n, dt = ecc_group(1, [""], "proof_ecc_e1")
    record("PROOF", "ecc E1 clean codeword (all 2^32 data)", ok, "direct", dt)
    ok, n, dt = ecc_group(2, [f"-set b1 {b} -set b2 {(b + 1) % 39}" for b in b_all], "proof_ecc_e2")
    record("PROOF", "ecc E2 every single-bit error corrected (all data)", ok,
           f"case split: {n}/{len(b_all)} error positions", dt)
    ok, n, dt = ecc_group(3, [f"-set b1 {a} -set b2 {b}" for a, b in pairs], "proof_ecc_e3")
    record("PROOF", "ecc E3 every double-bit error detected (all data)", ok,
           f"case split: {n}/{len(pairs)} bit pairs", dt)
    ok, n, dt = ecc_group(4, [""], "proof_ecc_e4")
    record("PROOF", "ecc E4 flags mutually exclusive (any 39-bit word)", ok, "direct", dt)
    ok, n, dt = ecc_group(5, [""], "proof_ecc_e5")
    record("PROOF", "ecc E5 no flag => valid codeword, data untouched", ok, "direct", dt)
    ok, n, dt = ecc_group(6, [f"-set syn3 {k}" for k in syn_all], "proof_ecc_e6")
    record("PROOF", "ecc E6 corrected => distance-1 valid codeword", ok,
           f"case split: {n}/{len(syn_all)} syndrome values", dt)
    for g in ["f_reach_single", "f_reach_double", "f_reach_any_corrected", "f_reach_any_uncorrectable"]:
        found, dt = reach("ecc", "ecc_properties", ECC, g, 0, prep=PREP_ECC.format(group=0))
        record("REACH", f"ecc: {g}", found, "satisfiable under assumptions", dt)

    # ---- Negative controls -------------------------------------------------------------------
    for label, target, rtl, old, new in NEGATIVE:
        text = open(os.path.join(ROOT, rtl)).read()
        if text.count(old) != 1:
            record("NEGATIVE", label, False, "mutation site not found", 0.0)
            continue
        mut_dir = os.path.join(WORK, "neg")
        os.makedirs(mut_dir, exist_ok=True)
        mpath = os.path.join(mut_dir, os.path.basename(rtl))
        open(mpath, "w").write(text.replace(old, new))
        tag = "neg_" + "".join(c if c.isalnum() else "_" for c in label)[:40]
        if target == "ecc_e2_b0":
            srcs = [mpath if s == rtl else s for s in ECC]
            # Sweep every error position; -verify aborts at the first failing case.
            s = read_cmd(srcs) + PREP_ECC.format(group=2)
            for b in range(39):
                s += f"sat -set b1 {b} -set b2 {(b + 1) % 39} -prove-asserts -set-assumes -timeout 300 -verify\n"
            rc, out, dt = yosys(s, tag)
            caught = rc != 0 and "model found: FAIL!" in out
            neg_detail = (f"proof failed at error bit {out.count('no model found: SUCCESS!')}, as required"
                          if caught else "proof must fail on broken RTL")
        else:
            name, top, srcs, maxsteps, _, _ = next(t for t in SEQ_TARGETS if t[0] == target)
            srcs = [mpath if s == rtl else s for s in srcs]
            ok, depth, dt = seq_proof(name, top, srcs, maxsteps, tag=tag)
            caught = not ok
            neg_detail = "proof failed on broken RTL, as required" if caught else "proof must fail on broken RTL"
        record("NEGATIVE", label, caught, neg_detail, dt)

    # ---- Summary -----------------------------------------------------------------------------------
    n_bad = sum(1 for r in results if r[2] in ("FAILED", "NOT REACHED", "MISSED"))
    ver = subprocess.run(["yosys", "-V"], capture_output=True, text=True).stdout.strip()
    with open(os.path.join(OUT, "summary.rpt"), "w") as f:
        f.write("AegisNoC formal verification summary\n")
        f.write(f"engine : {ver} — built-in `sat` (MiniSAT), no external solver\n")
        f.write(f"mode   : {'QUICK (ECC case splits sampled — NOT a complete proof)' if quick else 'FULL'}\n")
        f.write(f"date   : {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.write(f"{'kind':<9}{'check':<54}{'verdict':<12}{'detail':<44}{'sec':>7}\n")
        for kind, name, verdict, detail, dt in results:
            f.write(f"{kind:<9}{name:<54}{verdict:<12}{detail:<44}{dt:>7.1f}\n")
        f.write(f"\nTOTAL: {len(results)} checks, {n_bad} problems\n")
    print(f"== formal summary: {len(results)} checks, {n_bad} problems "
          f"({'QUICK' if quick else 'FULL'}) -> reports/formal/summary.rpt ==")
    sys.exit(1 if n_bad else 0)


if __name__ == "__main__":
    main()
