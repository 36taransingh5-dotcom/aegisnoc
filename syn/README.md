# Synthesis

Two flows, with different purposes. Only the Synopsys flow produces PPA numbers.

## 1. Synopsys Design Compiler: the PPA flow (organizer machine)

The library and PDK setup comes from the organizers. This repo never guesses paths.

```bash
# Once, on the organizer machine: point at the organizer's DC setup script.
# It must set search_path, target_library and link_library.
export AEGIS_LIB_SETUP=/path/given/by/organizers/dc_setup.tcl

TOP=baseline_noc dc_shell -f syn/synth.tcl | tee syn/dc_baseline.log
TOP=aegis_noc    dc_shell -f syn/synth.tcl | tee syn/dc_aegis.log
```

If the organizers provide a `.synopsys_dc.setup` instead, launch `dc_shell` from that directory and leave `AEGIS_LIB_SETUP` unset.

`synth.tcl` aborts if `target_library` is still DC's `your_library.db` placeholder.

Both tops use **identical** constraints (`constraints.sdc`) and the same compile command. The results are therefore directly comparable.

| Knob | Default | Meaning |
|---|---|---|
| `CLK_PERIOD` | 2.0 | Clock period (library time units) |
| `IN_DELAY_FRAC` / `OUT_DELAY_FRAC` | 0.20 / 0.20 | I/O budget as a fraction of the period |
| `CLK_UNCERT_FRAC` | 0.05 | Setup uncertainty |
| `DRIVING_CELL`, `OUTPUT_LOAD` | unset | Optional; take cell names and loads from the organizer library docs |
| `COMPILE_CMD` | `compile_ultra -no_autoungroup` | Use `compile -map_effort high` if there is no Ultra licence |

Set any knob as an environment variable, or with `dc_shell -x "set CLK_PERIOD 1.5" -f syn/synth.tcl`.

**Choosing the period:** start at 2.0. If both tops meet timing with a lot of slack, tighten the period and re-run both tops with the same value. Only compare runs made at the same period.

### Outputs

The reports go to `reports/baseline/` or `reports/aegis/`:

| File | Content |
|---|---|
| `area.rpt`, `area_hier.rpt` | Total, combinational and sequential area; per-block breakdown |
| `qor.rpt` | Per-path-group critical path, slack, TNS, cell counts |
| `critical_path.rpt`, `timing_max.rpt` | Worst setup paths |
| `timing_{in2reg,reg2reg,reg2out,in2out}.rpt` | Worst path per class. `in2out` must report no paths. |
| `timing_min.rpt` | Hold paths (ideal clock, before CTS) |
| `constraint_violators.rpt` | All violations |
| `cell_usage.rpt` | `report_reference` cell usage |
| `power_vectorless.rpt` | Power estimate with the default switching activity. It is an estimate only and must be labelled as one. |
| `check_design_{pre,post}.rpt`, `clocks.rpt`, `run_info.txt` | Checks and run settings |

The netlists and constraints for ICC2 go to `syn/out/<tag>/<top>.mapped.{v,ddc,sdc}`.

## 2. Yosys: synthesizability gate (any machine)

```bash
scripts/run_yosys.sh baseline_noc
scripts/run_yosys.sh aegis_noc
```

Yosys elaborates the real top and fails on any latch, multiple driver, combinational loop or undriven net. It then maps to generic NAND/NOR/NOT gates.

The script writes flip-flop count, gate count, a CMOS transistor estimate and logic depth to `reports/yosys/<top>/summary.rpt`. These numbers are technology-independent sanity checks, **not** area, timing or power results.
