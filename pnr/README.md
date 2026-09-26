# Physical design (ICC2)

**Status:** the flow is written but has not been run yet. The development machine has no ICC2 and no PDK. Run it on the organizer machine.

Physical design is P0 for this project. Get the **aegis_noc** block routed first; baseline is P1.

## 0. Before you start (about 15 minutes, on the organizer machine)

1. Find the organizer's reference ICC2 script or lab handout. Every technology value comes from there.
2. Run `cp pnr/setup_template.tcl pnr/setup_local.tcl` and fill in every empty variable:

   | Variable | Where to find it |
   |---|---|
   | `NDM_REF_LIBS` | the standard-cell NDM(s) named in the reference script |
   | `TECH_FILE` | `.tf` file (leave empty if the reference flow creates the lib without one) |
   | `TLUP_MAX` / `TLUP_MIN` / `TLUP_LAYER_MAP` | TLU+ files and the layer map in the PDK |
   | `PWR_NET` / `GND_NET` | the PG pin names used by the library cells |
   | layer names | the tech file or the reference script's `set_ignored_layers` / PG section |
   | `FILLER_CELLS`, `TIE_CELLS` | library documentation |
   | PG width, pitch and spacing | the reference script's PG section, or a conservative guess checked with `check_pg_drc` |

   The flow stops with a list of any empty required value.

3. Synthesize first with `syn/synth.tcl`. That writes `syn/out/<tag>/<top>.mapped.{v,sdc}`.

## 1. Run

```bash
TOP=aegis_noc    icc2_shell -f pnr/flow_template.tcl | tee pnr/icc2_aegis.log
TOP=baseline_noc icc2_shell -f pnr/flow_template.tcl | tee pnr/icc2_baseline.log   # P1
```

To debug stage by stage, set `STOP_AFTER=floorplan|place|cts|route`. The block is saved at each stop, so you can open it in the GUI.

| Knob | Default | Notes |
|---|---|---|
| `CORE_UTIL` | 0.50 | Lower it if pin placement or routing is congested (aegis has 478 port bits) |
| `CORE_OFFSET` | 5 | Core-to-die margin, in tech units |

## 2. What to capture

These go into `reports/<tag>/`:
- `pnr_final_timing_{max,min}.rpt`: post-route setup and hold.
- `pnr_final_qor.rpt`: WNS, TNS and violating paths per path group.
- `pnr_final_utilization.rpt`: core utilization.
- `pnr_check_routes.rpt`, `pnr_check_lvs.rpt`, `pnr_pg_*.rpt`: route, LVS and PG quality.
- `pnr_final_power_vectorless.rpt`: a vectorless estimate. Label it as an estimate if you quote it.
- `pnr_clock_qor.rpt`: clock skew and latency after CTS.

**Layout screenshot:** open the saved lib and block in `icc2_shell -gui`, fit the view, and save the image as `docs/images/aegis_layout.png` (and `baseline_layout.png`). The README links to these paths.

Then run `python3 scripts/collect_results.py` to refresh `docs/results.md` from the reports.

## 3. Fallbacks if the clock is short

These are in priority order. A routed simple block beats an unrouted perfect one.

1. If `compile_pg` fails, simplify to rails only by removing `S_mesh` from `compile_pg -strategies`. Rails-only PG is acceptable for a block this small.
2. If `route_opt` has trouble, keep the `route_auto` result and report its timing.
3. If there are hold violations after CTS, run `route_opt` again. Otherwise report them honestly.
4. If pin placement fails, lower `CORE_UTIL` to 0.35–0.40, or add pin layers.
5. Keep every change in `flow_template.tcl` so the final run can be reproduced.
