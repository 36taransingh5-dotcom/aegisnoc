#!/usr/bin/env python3
"""
mutation_check.py — prove each testbench can fail.

For every mutant: copy one RTL file, apply a single deliberate bug, compile the
testbench against the mutant with Icarus, and require that the run does NOT
print its PASS banner. A mutant that fails to compile or apply is reported as
an ERROR (never silently counted as "killed").

    python3 scripts/mutation_check.py            # all mutants
    python3 scripts/mutation_check.py fifo       # mutants whose name contains "fifo"
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "mut")

# (name, rtl file, testbench, [sources in compile order], old, new)
# For a multi-site mutant, `old` is a list of (old, new) pairs and `new` is None.
MUTANTS = [
    ("fifo_push_ignores_full", "rtl/sync_fifo.sv", "tb_fifo",
     ["rtl/sync_fifo.sv", "tb/tb_fifo.sv"],
     "assign do_push = push && !full;", "assign do_push = push;"),
    ("fifo_pop_ignores_empty", "rtl/sync_fifo.sv", "tb_fifo",
     ["rtl/sync_fifo.sv", "tb/tb_fifo.sv"],
     "assign do_pop  = pop  && !empty;", "assign do_pop  = pop;"),
    ("fifo_pushpop_counts_up", "rtl/sync_fifo.sv", "tb_fifo",
     ["rtl/sync_fifo.sv", "tb/tb_fifo.sv"],
     "default: cnt <= cnt;", "default: cnt <= cnt + {{AW{1'b0}}, (do_push & do_pop)};"),
    ("xy_y_before_x", "rtl/xy_route.sv", "tb_xy_route",
     ["rtl/aegis_pkg.sv", "rtl/xy_route.sv", "tb/tb_xy_route.sv"],
     "if      (dst_x > cur_x) out_port = aegis_pkg::PORT_E;\n"
     "    else if (dst_x < cur_x) out_port = aegis_pkg::PORT_W;\n"
     "    else if (dst_y > cur_y) out_port = aegis_pkg::PORT_N;\n"
     "    else if (dst_y < cur_y) out_port = aegis_pkg::PORT_S;",
     "if      (dst_y > cur_y) out_port = aegis_pkg::PORT_N;\n"
     "    else if (dst_y < cur_y) out_port = aegis_pkg::PORT_S;\n"
     "    else if (dst_x > cur_x) out_port = aegis_pkg::PORT_E;\n"
     "    else if (dst_x < cur_x) out_port = aegis_pkg::PORT_W;"),
    ("xy_swap_north_south", "rtl/xy_route.sv", "tb_xy_route",
     ["rtl/aegis_pkg.sv", "rtl/xy_route.sv", "tb/tb_xy_route.sv"],
     "else if (dst_y > cur_y) out_port = aegis_pkg::PORT_N;",
     "else if (dst_y > cur_y) out_port = aegis_pkg::PORT_S;"),
    ("arb_ignores_accept", "rtl/rr_arbiter.sv", "tb_rr_arbiter",
     ["rtl/rr_arbiter.sv", "tb/tb_rr_arbiter.sv"],
     "end else if (accept && (|req)) begin", "end else if (|req) begin"),
    ("arb_ptr_parks_on_winner", "rtl/rr_arbiter.sv", "tb_rr_arbiter",
     ["rtl/rr_arbiter.sv", "tb/tb_rr_arbiter.sv"],
     "next_ptr = (i == N-1) ? '0 : IW'(i + 1);", "next_ptr = IW'(i);"),
    ("arb_fixed_priority", "rtl/rr_arbiter.sv", "tb_rr_arbiter",
     ["rtl/rr_arbiter.sv", "tb/tb_rr_arbiter.sv"],
     "assign grant    = (|req_hi) ? grant_hi : grant_lo;", "assign grant    = grant_lo;"),
]

CORE = ["rtl/aegis_pkg.sv", "rtl/sync_fifo.sv", "rtl/xy_route.sv", "rtl/rr_arbiter.sv",
        "rtl/crossbar_5x5.sv", "rtl/router_core.sv", "rtl/baseline_noc.sv", "tb/tb_router.sv"]
MUTANTS += [
    ("core_load_ignores_ready", "rtl/router_core.sv", "tb_router", CORE,
     "assign load[o] = !out_valid_q[o] || out_ready[o];", "assign load[o] = 1'b1;"),
    ("core_pop_ignores_load", "rtl/router_core.sv", "tb_router", CORE,
     "fifo_pop[i] = fifo_pop[i] | (grant[o*N + i] & load[o]);",
     "fifo_pop[i] = fifo_pop[i] | grant[o*N + i];"),
    ("core_valid_sticks", "rtl/router_core.sv", "tb_router", CORE,
     "out_valid_q[o] <= |req[o*N +: N];", "out_valid_q[o] <= 1'b1;"),
    ("core_in_ready_always", "rtl/router_core.sv", "tb_router", CORE,
     "assign in_ready[i] = !fifo_full[i];", "assign in_ready[i] = 1'b1;"),
    ("core_swap_xy_fields", "rtl/router_core.sv", "tb_router", CORE,
     ".dst_x    (head[i*W + aegis_pkg::DX_LSB +: CW]),", ".dst_x    (head[i*W + aegis_pkg::DY_LSB +: CW]),"),
]
ECC = ["rtl/aegis_pkg.sv", "rtl/ecc_secded_encoder.sv", "rtl/ecc_secded_decoder.sv", "tb/tb_ecc.sv"]
MUTANTS += [
    ("ecc_mask_bit_wrong", "rtl/aegis_pkg.sv", "tb_ecc", ECC,
     "ECC_M0 = 32'h56AA_AD5B;", "ECC_M0 = 32'h56AA_AD5A;"),
    ("ecc_enc_overall_data_only", "rtl/ecc_secded_encoder.sv", "tb_ecc", ECC,
     "assign p_all = ^{p, data};", "assign p_all = ^data;"),
    ("ecc_dec_wrong_syndrome_mask", "rtl/ecc_secded_decoder.sv", "tb_ecc", ECC,
     "assign syndrome[3] = p_rx[3] ^ (^(d_rx & aegis_pkg::ECC_M3));",
     "assign syndrome[3] = p_rx[3] ^ (^(d_rx & aegis_pkg::ECC_M4));"),
    ("ecc_dec_sec_no_range", "rtl/ecc_secded_decoder.sv", "tb_ecc", ECC,
     "assign single_error_corrected = q && s_in_range;", "assign single_error_corrected = q;"),
    ("ecc_dec_ded_misses_odd", "rtl/ecc_secded_decoder.sv", "tb_ecc", ECC,
     "assign double_error_detected  = (!q && s_nonzero) || (q && !s_in_range);",
     "assign double_error_detected  = (!q && s_nonzero);"),
    ("ecc_dec_no_correction", "rtl/ecc_secded_decoder.sv", "tb_ecc", ECC,
     "assign data                   = d_rx ^ flip;", "assign data                   = d_rx;"),
    ("ecc_dec_range_off_by_one", "rtl/ecc_secded_decoder.sv", "tb_ecc", ECC,
     "assign s_in_range = (syndrome <= PW'(aegis_pkg::ECC_MAX_POS));",
     "assign s_in_range = (syndrome <  PW'(aegis_pkg::ECC_MAX_POS));"),
]
AEG = ["rtl/aegis_pkg.sv", "rtl/sync_fifo.sv", "rtl/xy_route.sv", "rtl/rr_arbiter.sv",
       "rtl/crossbar_5x5.sv", "rtl/router_core.sv", "rtl/ecc_secded_encoder.sv",
       "rtl/ecc_secded_decoder.sv", "rtl/aegis_noc.sv", "rtl/baseline_noc.sv",
       "tb/tb_aegis_fault_injection.sv"]
MUTANTS += [
    ("aegis_routes_uncorrectable", "rtl/aegis_noc.sv", "tb_aegis_fault_injection", AEG,
     "assign core_in_valid[i] = in_valid[i] && !dec_ded[i];", "assign core_in_valid[i] = in_valid[i];"),
    ("aegis_counts_without_handshake", "rtl/aegis_noc.sv", "tb_aegis_fault_injection", AEG,
     "sec_evt_q <= accepted & dec_sec;", "sec_evt_q <= in_valid & dec_sec;"),
    ("aegis_counts_idle_inputs", "rtl/aegis_noc.sv", "tb_aegis_fault_injection", AEG,
     "ded_evt_q <= accepted & dec_ded;", "ded_evt_q <= dec_ded;"),
    ("aegis_counter_by_one", "rtl/aegis_noc.sv", "tb_aegis_fault_injection", AEG,
     "corrected_error_count     <= corrected_error_count     + {29'd0, n_sec};",
     "corrected_error_count     <= corrected_error_count     + {31'd0, |sec_evt_q};"),
    ("aegis_no_output_encode", "rtl/aegis_noc.sv", "tb_aegis_fault_injection", AEG,
     ".codeword (out_data[o*CW +: CW])", ".codeword ()"),
    # Router fed the RAW (uncorrected) flit while flags still work: only the
    # end-to-end data checks can catch this. Two edits -> list of (old, new).
    ("aegis_router_gets_raw_flit", "rtl/aegis_noc.sv", "tb_aegis_fault_injection", AEG,
     [("      .data                   (dec_data[i*W +: W]),", "      .data                   (),"),
      ("    // Uncorrectable flits never enter the router.",
       "    assign dec_data[i*W +: W] = in_data[i*CW +: W];")],
     None),
]
# Deliberately excluded (equivalent mutant): dropping `q &&` from flip[i]
# only alters `data` for uncorrectable words, whose data is unspecified (and
# which aegis_noc drops).
# Deliberately excluded (equivalent mutant): loading out_data_q without the
# |req guard only changes out_data while out_valid is low, which the
# valid/ready protocol defines as don't-care — no testbench can (or should)
# observe it.


def run(cmd):
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=600)
    return p.returncode, p.stdout + p.stderr


def main():
    filt = sys.argv[1] if len(sys.argv) > 1 else ""
    os.makedirs(OUT, exist_ok=True)
    killed = survived = errors = 0
    report_lines = []
    for name, rtl, tb, srcs, old, new in MUTANTS:
        if filt and filt not in name:
            continue
        text = open(os.path.join(ROOT, rtl)).read()
        edits = old if isinstance(old, list) else [(old, new)]
        bad_site = next((o for o, _ in edits if text.count(o) != 1), None)
        if bad_site is not None:
            print(f"ERROR    {name}: mutation site found {text.count(bad_site)} times (expected 1)")
            errors += 1
            continue
        for o, n in edits:
            text = text.replace(o, n)
        mpath = os.path.join(OUT, f"{name}.sv")
        open(mpath, "w").write(text)
        files = [mpath if s == rtl else os.path.join(ROOT, s) for s in srcs]
        vvp = os.path.join(OUT, f"{name}.vvp")
        rc, log = run(["iverilog", "-g2012", "-I" + os.path.join(ROOT, "tb"), "-o", vvp] + files)
        if rc != 0:
            print(f"ERROR    {name}: mutant did not compile\n{log[:400]}")
            errors += 1
            continue
        rc, log = run(["vvp", "-n", vvp])
        banner = f"{tb.upper()}: PASS"
        if banner in log:
            print(f"SURVIVED {name}: {tb} still passes -> testbench too weak")
            report_lines.append(f"SURVIVED {name} ({tb})")
            survived += 1
        else:
            why = next((l.strip() for l in log.splitlines() if "FATAL" in l or "Fatal" in l),
                       f"no PASS banner (rc={rc})")
            print(f"killed   {name}: {why[:120]}")
            report_lines.append(f"killed   {name:<32} by {tb}")
            killed += 1
    print(f"== mutation summary: {killed} killed, {survived} survived, {errors} errors ==")
    if not filt:
        os.makedirs(os.path.join(ROOT, "reports", "sim"), exist_ok=True)
        with open(os.path.join(ROOT, "reports", "sim", "mutation.rpt"), "w") as f:
            f.write("AegisNoC mutation check (deliberate RTL bugs must be caught by the testbenches)\n")
            f.write(f"result: {killed} killed, {survived} survived, {errors} errors "
                    f"out of {killed + survived + errors} mutants\n\n")
            f.writelines(line + "\n" for line in report_lines)
    sys.exit(0 if survived == 0 and errors == 0 else 1)


if __name__ == "__main__":
    main()
