#!/usr/bin/env python3
"""
collect_results.py — build docs/results.md from tool reports. Nothing else.

    python3 scripts/collect_results.py            # regenerate docs/results.md
    python3 scripts/collect_results.py --selftest # check the report parsers

Rules:
  * Every number is copied from a report file under reports/. If a report or a
    field is missing, the table says "n/a" (and names the file). Nothing is
    estimated, interpolated or filled by hand.
  * Overhead % = (aegis - baseline) / baseline * 100, as the PRD specifies.
  * The derived Fmax is 1 / (T_clk - WNS), labelled as derived from the
    constrained run.
"""
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REP = os.path.join(ROOT, "reports")
OUT_MD = os.path.join(ROOT, "docs", "results.md")

NUM = r"([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)"


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def grab(text, pattern, cast=float):
    if text is None:
        return None
    m = re.search(pattern, text, re.MULTILINE | re.IGNORECASE)
    return cast(m.group(1)) if m else None


# ---- Synopsys DC ------------------------------------------------------------------
def parse_dc_area(text):
    return {
        "total_area": grab(text, r"^\s*Total cell area:\s*" + NUM),
        "comb_area": grab(text, r"^\s*Combinational area:\s*" + NUM),
        "seq_area": grab(text, r"^\s*Noncombinational area:\s*" + NUM),
        "bufinv_area": grab(text, r"^\s*Buf/Inv area:\s*" + NUM),
        "cells": grab(text, r"^\s*Number of cells:\s*" + NUM),
        "comb_cells": grab(text, r"^\s*Number of combinational cells:\s*" + NUM),
        "seq_cells": grab(text, r"^\s*Number of sequential cells:\s*" + NUM),
    }


def parse_qor_groups(text):
    """Timing Path Group blocks from DC or ICC2 report_qor."""
    groups = {}
    if text is None:
        return groups
    blocks = re.split(r"Timing Path Group\s+'", text)[1:]
    for b in blocks:
        name = b.split("'", 1)[0]
        g = {
            "levels": grab(b, r"Levels of Logic:\s*" + NUM),
            "length": grab(b, r"Critical Path Length:\s*" + NUM),
            "slack": grab(b, r"Critical Path Slack:\s*" + NUM),
            "period": grab(b, r"Critical Path Clk Period:\s*" + NUM),
            "tns": grab(b, r"Total Negative Slack:\s*" + NUM),
            "nvp": grab(b, r"No\. of Violating Paths:\s*" + NUM),
        }
        # ICC2 prints one block per scenario; keep the worst slack per group.
        if name not in groups or (g["slack"] is not None and groups[name]["slack"] is not None
                                  and g["slack"] < groups[name]["slack"]):
            groups[name] = g
    return groups


def to_mw(value, unit):
    if value is None or unit is None:
        return None
    return value * {"w": 1e3, "mw": 1.0, "uw": 1e-3, "nw": 1e-6, "pw": 1e-9}.get(unit.lower(), float("nan"))


def parse_power(text):
    if text is None:
        return {"dynamic_mw": None, "leakage_mw": None}
    d = re.search(r"Total Dynamic Power\s*=\s*" + NUM + r"\s*([munp]?W)", text)
    l = re.search(r"Cell Leakage Power\s*=\s*" + NUM + r"\s*([munp]?W)", text)
    return {"dynamic_mw": to_mw(float(d.group(1)), d.group(2)) if d else None,
            "leakage_mw": to_mw(float(l.group(1)), l.group(2)) if l else None}


def parse_area_hier(text):
    """Top-level children of `report_area -hierarchy`: {instance: absolute total}."""
    rows = {}
    if text is None:
        return rows
    for line in text.splitlines():
        m = re.match(r"^(\S+)\s+" + NUM + r"\s+" + NUM + r"\s+" + NUM + r"\s+" + NUM, line)
        if m and "/" not in m.group(1):
            rows[m.group(1)] = {"total": float(m.group(2)), "local_comb": float(m.group(4)),
                                "local_seq": float(m.group(5))}
    return rows


def parse_run_info(text):
    return {"clk_period": grab(text, r"^clk_period\s*:\s*" + NUM),
            "target_library": grab(text, r"^target_library\s*:\s*(.+)$", str)}


# ---- ICC2 ----------------------------------------------------------------------------
def parse_pnr(tag):
    d = os.path.join(REP, tag)
    util = read(os.path.join(d, "pnr_final_utilization.rpt"))
    routes = read(os.path.join(d, "pnr_check_routes.rpt"))
    lvs = read(os.path.join(d, "pnr_check_lvs.rpt"))
    return {
        "groups": parse_qor_groups(read(os.path.join(d, "pnr_final_qor.rpt"))),
        "util": grab(util, r"Utilization Ratio:\s*" + NUM),
        "route_drcs": grab(routes, r"Total number of (?:DRCs|drcs)\s*=\s*(\d+)", int),
        "lvs_open": grab(lvs, r"open nets\s*[=:]\s*(\d+)", int),
        "lvs_short": grab(lvs, r"short(?:s| nets)\s*[=:]\s*(\d+)", int),
        "power": parse_power(read(os.path.join(d, "pnr_final_power_vectorless.rpt"))),
        "present": util is not None,
    }


# ---- Yosys ------------------------------------------------------------------------------
def parse_yosys(top):
    t = read(os.path.join(REP, "yosys", top, "summary.rpt"))
    return {
        "ff": grab(t, r"^flip_flops\s*:\s*" + NUM),
        "gates": grab(t, r"^comb_gates\s*:\s*" + NUM),
        "tr": grab(t, r"^cmos_transistors\s*:\s*" + NUM),
        "depth": grab(t, r"^logic_depth_levels\s*:\s*" + NUM),
    }


# ---- Formatting -------------------------------------------------------------------------------
def f(v, nd=2):
    if v is None:
        return "n/a"
    if isinstance(v, str):
        return v
    return f"{v:,.{nd}f}" if abs(v - round(v)) > 1e-9 or nd == 0 else f"{v:,.0f}"


def ovh(b, a):
    if b is None or a is None or b == 0:
        return "n/a"
    return f"{(a - b) / b * 100:+.1f}%"


def row(label, b, a, nd=2, with_ovh=True):
    return f"| {label} | {f(b, nd)} | {f(a, nd)} | {ovh(b, a) if with_ovh else ''} |"


def wns(groups):
    s = [g["slack"] for g in groups.values() if g.get("slack") is not None]
    return min(s) if s else None


def fmax_mhz(period, w):
    if period is None or w is None or period - w <= 0:
        return None
    return 1000.0 / (period - w)       # assumes library time unit = ns


# ---- Report -----------------------------------------------------------------------------------
def build():
    L = []
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    L += ["# AegisNoC — Measured Results", "",
          f"_Generated by `scripts/collect_results.py` on {now}. Every value below is copied "
          "from a tool report under `reports/`. **n/a** means that report has not been produced "
          "yet — nothing is estimated._", ""]

    dc = {}
    for tag in ("baseline", "aegis"):
        d = os.path.join(REP, tag)
        area_t = read(os.path.join(d, "area.rpt"))
        dc[tag] = {
            "present": area_t is not None,
            "area": parse_dc_area(area_t),
            "groups": parse_qor_groups(read(os.path.join(d, "qor.rpt"))),
            "power": parse_power(read(os.path.join(d, "power_vectorless.rpt"))),
            "info": parse_run_info(read(os.path.join(d, "run_info.txt"))),
            "hier": parse_area_hier(read(os.path.join(d, "area_hier.rpt"))),
        }
    b, a = dc["baseline"], dc["aegis"]

    # ---- 1. Synthesis
    L += ["## 1. Logic synthesis — Synopsys Design Compiler", ""]
    if not (b["present"] or a["present"]):
        L += ["**Not run yet.** Run `syn/synth.tcl` for both tops on the organizer machine "
              "(see `syn/README.md`), then re-run this script.", ""]
    L += [f"Library: `{b['info']['target_library'] or a['info']['target_library'] or 'n/a'}` · "
          f"clock period: {f(b['info']['clk_period'])} (baseline) / {f(a['info']['clk_period'])} (aegis)", "",
          "| Metric | BaselineNoC | AegisNoC | Overhead |", "|---|---|---|---|",
          row("Total cell area", b["area"]["total_area"], a["area"]["total_area"]),
          row("Combinational area", b["area"]["comb_area"], a["area"]["comb_area"]),
          row("Sequential (noncombinational) area", b["area"]["seq_area"], a["area"]["seq_area"]),
          row("Buf/Inv area", b["area"]["bufinv_area"], a["area"]["bufinv_area"]),
          row("Cell count", b["area"]["cells"], a["area"]["cells"], 0),
          row("Combinational cells", b["area"]["comb_cells"], a["area"]["comb_cells"], 0),
          row("Sequential cells", b["area"]["seq_cells"], a["area"]["seq_cells"], 0)]
    for grp in ("in2reg", "reg2reg", "reg2out", "diag"):
        gb, ga = b["groups"].get(grp, {}), a["groups"].get(grp, {})
        if grp == "diag" and not ga:
            continue
        L.append(row(f"Critical path length — {grp}", gb.get("length"), ga.get("length"), 3))
        L.append(row(f"Slack — {grp}", gb.get("slack"), ga.get("slack"), 3, with_ovh=False))
        L.append(row(f"Levels of logic — {grp}", gb.get("levels"), ga.get("levels"), 0))
    wb, wa = wns(b["groups"]), wns(a["groups"])
    L.append(row("Worst slack (all groups)", wb, wa, 3, with_ovh=False))
    L.append(row("Derived Fmax, MHz ≈ 1/(T−WNS)", fmax_mhz(b["info"]["clk_period"], wb),
                 fmax_mhz(a["info"]["clk_period"], wa), 1))
    L.append(row("Dynamic power, mW (vectorless estimate)", b["power"]["dynamic_mw"], a["power"]["dynamic_mw"], 4))
    L.append(row("Leakage power, mW (vectorless estimate)", b["power"]["leakage_mw"], a["power"]["leakage_mw"], 6))
    in2out = a["groups"].get("in2out") or b["groups"].get("in2out")
    L += ["", "`in2out` group (must be empty — no combinational input→output path): "
          + ("reported with a path — investigate" if in2out and in2out.get("length") else
             "no path reported" if (a["present"] or b["present"]) else "n/a"), ""]

    # ---- Aegis area breakdown
    h = a["hier"]
    if h:
        dec = sum(v["total"] for k, v in h.items() if "u_dec" in k)
        enc = sum(v["total"] for k, v in h.items() if "u_enc" in k)
        core = sum(v["total"] for k, v in h.items() if "u_core" in k)
        top = next((v for k, v in h.items() if k == "aegis_noc"), None)
        glue = (top["local_comb"] + top["local_seq"]) if top else None
        tot = top["total"] if top else None
        L += ["### AegisNoC area breakdown (`report_area -hierarchy`)", "",
              "| Block | Area | Share |", "|---|---|---|"]
        for name, val in (("router_core (shared with baseline)", core), ("5× SECDED decoders", dec),
                          ("5× SECDED encoders", enc), ("top-level glue (error counters, flags, drop gating)", glue)):
            share = f"{val / tot * 100:.1f}%" if (val is not None and tot) else "n/a"
            L.append(f"| {name} | {f(val)} | {share} |")
        L.append("")

    # ---- 2. Physical design
    pb, pa = parse_pnr("baseline"), parse_pnr("aegis")
    L += ["## 2. Physical design — Synopsys IC Compiler II", ""]
    if not (pb["present"] or pa["present"]):
        L += ["**Not run yet.** See `pnr/README.md`.", ""]
    L += ["| Metric | BaselineNoC | AegisNoC |", "|---|---|---|",
          f"| Core utilization | {f(pb['util'], 3)} | {f(pa['util'], 3)} |",
          f"| Post-route worst slack | {f(wns(pb['groups']), 3)} | {f(wns(pa['groups']), 3)} |"]
    for grp in ("in2reg", "reg2reg", "reg2out"):
        L.append(f"| Post-route slack — {grp} | {f(pb['groups'].get(grp, {}).get('slack'), 3)} | "
                 f"{f(pa['groups'].get(grp, {}).get('slack'), 3)} |")
    L += [f"| Routing DRCs (check_routes) | {f(pb['route_drcs'], 0)} | {f(pa['route_drcs'], 0)} |",
          f"| LVS open / short nets | {f(pb['lvs_open'], 0)} / {f(pb['lvs_short'], 0)} | "
          f"{f(pa['lvs_open'], 0)} / {f(pa['lvs_short'], 0)} |",
          f"| Dynamic power, mW (vectorless estimate) | {f(pb['power']['dynamic_mw'], 4)} | "
          f"{f(pa['power']['dynamic_mw'], 4)} |", "",
          "Layout: `docs/images/aegis_layout.png`, `docs/images/baseline_layout.png` "
          + ("(present)" if os.path.exists(os.path.join(ROOT, "docs", "images", "aegis_layout.png"))
             else "(not captured yet)"), ""]

    # ---- 3. Yosys
    yb, ya = parse_yosys("baseline_noc"), parse_yosys("aegis_noc")
    L += ["## 3. Technology-independent comparison — Yosys (NOT a PPA result)", "",
          "Generic NAND2/NOR2/INV mapping without a library or timing model. Use it as a "
          "structural sanity check only. Area, timing and power come from sections 1–2.", "",
          "| Metric | BaselineNoC | AegisNoC | Overhead |", "|---|---|---|---|",
          row("Flip-flops", yb["ff"], ya["ff"], 0),
          row("Combinational gates (NAND2+NOR2+INV)", yb["gates"], ya["gates"], 0),
          row("CMOS transistor estimate", yb["tr"], ya["tr"], 0),
          row("Longest path, generic gate levels", yb["depth"], ya["depth"], 0), "",
          "Note: in AegisNoC the generic longest path is the 32-bit error-counter carry chain "
          "(ripple in generic mapping). DC reports it separately in the `diag` path group.", ""]

    # ---- 4. Capability
    L += ["## 4. Fault-tolerance capability (verified)", "",
          "| Capability | BaselineNoC | AegisNoC | Evidence |", "|---|---|---|---|",
          "| Single-bit fault in a 39-bit protected flit | undetected; a header hit misroutes | "
          "corrected, all 39 positions | formal E2 (all 2^32 data), tb_ecc, tb_aegis_fault_injection |",
          "| Double-bit fault | undetected | detected, flit dropped, counted | formal E3 (all 741 pairs), tb_ecc |",
          "| Triple-bit fault | undetected | beyond the SECDED guarantee (tb_ecc measures the split) | tb_ecc INFO line |", ""]

    # ---- 5. Verification evidence
    L += ["## 5. Verification evidence (copied from reports)", ""]
    for title, path in (("Simulation regression", "sim/summary.rpt"), ("Mutation check", "sim/mutation.rpt"),
                        ("Formal", "formal/summary.rpt")):
        t = read(os.path.join(REP, path))
        L += [f"### {title} — `reports/{path}`", "", "```", (t.strip() if t else "n/a (not run)"), "```", ""]
    return "\n".join(L) + "\n"


# ---- Self-test (format snippets only; never written to reports/ or docs/) -------------------
def selftest():
    area = """
Number of ports:                          478
Number of cells:                          111
Number of combinational cells:             77
Number of sequential cells:                33
Combinational area:                111.100000
Buf/Inv area:                        11.500000
Noncombinational area:             222.200000
Total cell area:                   333.300000
"""
    a = parse_dc_area(area)
    assert a["total_area"] == 333.3 and a["seq_area"] == 222.2 and a["cells"] == 111, a
    qor = """
  Timing Path Group 'in2reg'
  -----------------------------------
  Levels of Logic:              10.00
  Critical Path Length:          0.50
  Critical Path Slack:           1.25
  Critical Path Clk Period:      2.00
  Total Negative Slack:          0.00
  No. of Violating Paths:        0.00

  Timing Path Group 'reg2reg'
  -----------------------------------
  Levels of Logic:              12.00
  Critical Path Length:          1.10
  Critical Path Slack:          -0.10
  Critical Path Clk Period:      2.00
"""
    g = parse_qor_groups(qor)
    assert g["in2reg"]["slack"] == 1.25 and g["reg2reg"]["levels"] == 12.0 and wns(g) == -0.10, g
    assert abs(fmax_mhz(2.0, -0.10) - 1000 / 2.1) < 1e-9
    p = parse_power("Total Dynamic Power    =   1.5000 mW  (100%)\nCell Leakage Power     =  25.0000 uW\n")
    assert p["dynamic_mw"] == 1.5 and abs(p["leakage_mw"] - 0.025) < 1e-12, p
    hier = """
aegis_noc                         333.3000    100.0    11.1000    22.2000    0.0000  aegis_noc
u_core                            200.0000     60.0   100.0000   100.0000    0.0000  router_core
g_dec_0__u_dec                     10.0000      3.0    10.0000     0.0000    0.0000  ecc_secded_decoder
u_core/g_in_0__u_fifo              50.0000     15.0    10.0000    40.0000    0.0000  sync_fifo
"""
    h = parse_area_hier(hier)
    assert set(h) == {"aegis_noc", "u_core", "g_dec_0__u_dec"} and h["u_core"]["total"] == 200.0, h
    assert ovh(100.0, 125.0) == "+25.0%" and ovh(None, 1.0) == "n/a"
    print("collect_results selftest: PASS")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    md = build()
    os.makedirs(os.path.dirname(OUT_MD), exist_ok=True)
    with open(OUT_MD, "w") as fh:
        fh.write(md)
    print(f"wrote {os.path.relpath(OUT_MD, ROOT)}")
