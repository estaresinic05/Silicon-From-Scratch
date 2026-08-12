#!/usr/bin/env python3
"""
Parse an Innovus run's reports into one row of quality-of-results numbers.

    python3 scripts/qor.py collect runs/00-baseline --note "first clean pass"
    python3 scripts/qor.py table

`collect` reads the reports out of a run directory, appends one row to
results/qor.csv, copies the small text reports into results/<run>/reports/ so
the evidence is committed alongside the number, and rewrites results/QOR.md.

`table` just rewrites results/QOR.md from the CSV, which is what you want after
hand-editing a note.

Nothing here is Innovus-specific beyond the report formats. Every parser
returns None rather than raising when it cannot find its number, because a run
that died at CTS still has placement reports worth recording, and an
exception here would throw them away.
"""

import argparse
import csv
import gzip
import re
import shutil
import sys
from pathlib import Path

# Reports small enough to be worth committing as evidence. The .enc databases
# and the .def are hundreds of megabytes and stay out of git.
KEEP = [
    "00_check_design.rpt", "01_syn_area.rpt", "02_syn_gates.rpt",
    "03_syn_timing.rpt", "04_syn_unconstrained.rpt", "05_syn_power.rpt",
    "10_place_timing.rpt", "20_cts_setup.rpt", "21_cts_hold.rpt",
    "40_final_setup.rpt", "41_final_hold.rpt", "42_final_area.rpt",
    "43_final_power.rpt", "44_summary.rpt", "49_corner_status.rpt",
    # Timing coverage. 45 and 46 are taken by DRC and connectivity, which are
    # copied in below from the run directory rather than from reports/, so they
    # are not in this list and the numbers still collide if reused.
    "47_check_timing.rpt", "48_analysis_coverage.rpt", "54_antenna.rpt",
]

# The three reporting corners, in the order they are printed. These are the
# tags innovus.tcl uses in its filenames, and RPT_<TAG> is the analysis view
# behind each. Order is slow to fast because that is the order the numbers get
# better, which makes a row readable left to right.
CORNERS = ("slow", "typ", "fast")

KEEP += ["40_setup_%s.rpt" % t for t in CORNERS]
KEEP += ["41_hold_%s.rpt" % t for t in CORNERS]

# Column order in qor.csv. Adding a field here is safe: older rows read back
# with empty strings for it.
#
# The unsuffixed wns_setup/wns_hold columns are the SIGNOFF numbers, taken from
# the views the design was actually optimised against. The per-corner columns
# beside them are reporting only. They are not redundant: on an mmmc run
# wns_setup and wns_setup_slow agree, and on runs 00 through 03 they do not,
# because those were signed off at typical and the slow column is the penalty
# they were never judged by.
FIELDS = [
    "run", "note", "clk_ns", "util", "effort", "target_slack", "derate", "date",
    "wns_place", "wns_cts", "wns_hold_cts", "wns_setup", "wns_hold",
    "n_setup_viol", "n_hold_viol", "tns_setup",
    "cells", "fillers", "flops",
    "logic_um2", "core_um2", "density_pct",
    "wire_um", "wns_place_start",
]

for _t in CORNERS:
    FIELDS += ["wns_setup_%s" % _t, "tns_setup_%s" % _t, "n_setup_viol_%s" % _t,
               "wns_hold_%s" % _t, "n_hold_viol_%s" % _t]


def corner_view(tag):
    """The Innovus analysis view name behind a corner tag."""
    return "RPT_" + tag.upper()


# Where each kind of summary lives. The corner census is written by timeDesign
# into its own directory precisely because it would otherwise land on the
# filename route_opt_design already used, and the two are NOT the same
# measurement: the signoff one is SI-aware and the plain timeDesign one is not.
# On run 06 that difference is 45 violating paths against 28.
SIGNOFF_DIR = "timingReports"
CORNER_DIR = "cornerReports"


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def _read(path):
    """Report files occasionally carry stray bytes from the tool's own log."""
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def _first_slack(path):
    """
    First 'Slack Time' in a report_timing output, which is the worst path.

    Setup reports write '= Slack Time', hold reports write '  Slack Time'.
    One regex covers both.
    """
    text = _read(path)
    if text is None:
        return None
    m = re.search(r"^\s*=?\s*Slack Time\s+(-?[\d.]+)", text, re.M)
    return float(m.group(1)) if m else None


def _count_violated(path, kind):
    text = _read(path)
    if text is None:
        return None
    return len(re.findall(rf"VIOLATED {kind} Check", text))


def parse_postroute_summary(path):
    """
    WNS, TNS and the violating-path count out of the post-route summary.

    This is the only place a TRUE violation count exists. _count_violated below
    counts VIOLATED lines in a report_timing output, and that report holds at
    most -max_paths paths, so the moment a run fails badly the count saturates
    at the cap and reports the cap as if it were a measurement. Run 04 showed 50
    setup and 50 hold against a real figure of 362.

    The summary is a fixed-width table, "all" first and then one column per path
    group:

        |           WNS (ns):| -0.968  | -0.968  |  0.295  |
        |           TNS (ns):| -82.769 | -82.769 |  0.000  |
        |    Violating Paths:|   362   |   362   |    0    |

    Only the "all" column is taken. Per-group numbers are worth reading in the
    file itself and are not worth a column each in a table this wide.

    Two shapes, for the same reason parse_flow_qor above carries two. A LIVE run
    has it gzipped in timingReports/ exactly as Innovus wrote it. An ARCHIVED
    run under results/ has it ungzipped to reports/50_postroute_summary.rpt by
    archive_reports. Looking in only one place is how the first version of this
    silently returned nothing at all: parse_run passes run_dir/"reports", and
    archive_reports writes to results/, so the file was never where it looked.
    """
    run_dir = Path(path)

    text = _read(run_dir / "reports" / "50_postroute_summary.rpt")

    if text is None:
        # A live run: take the setup summary, never the _hold one beside it.
        for gz in sorted(run_dir.glob(SIGNOFF_DIR + "/*postRoute*.summary.gz")):
            if "_hold" in gz.name:
                continue
            text = _read_gz(gz)
            break

    return _summary_numbers(text)


def _read_gz(path):
    try:
        with gzip.open(str(path), "rt", errors="replace") as fh:
            return fh.read()
    except (OSError, EOFError):
        return None


def _summary_numbers(text):
    """
    WNS, TNS and the violating count out of a timeDesign summary table.

    Only the "all" column is taken. Per-group numbers are worth reading in the
    file itself and are not worth a column each in a table this wide.
    """
    d = {}
    if text is None:
        return d
    for key, label in (("tns", r"TNS \(ns\):"), ("viol", r"Violating Paths:"),
                       ("wns", r"WNS \(ns\):")):
        m = re.search(r"^\|\s*" + label + r"\|\s*(-?[\d.]+)", text, re.M)
        if m:
            d[key] = float(m.group(1))
    return d


def parse_view_blocks(text):
    """
    The per-view blocks of a `timeDesign -expandedViews` summary.

    -expandedViews does NOT write one file per view, which is what this was
    first built to expect. It writes ONE summary whose merged table is followed
    by a four-line block per active view, and only the first line of each block
    carries the view name:

        |RPT_SLOW            | -0.066  | -0.066  |  0.645  |
        |                    | -0.550  | -0.550  |  0.000  |
        |                    |   28    |   28    |    0    |
        |                    |  3497   |  3299   |   230   |

    The rows are WNS, TNS, violating paths, total paths, in that order, and the
    first data column is "all". Returns {'RPT_SLOW': {'wns':..}, ...}.
    """
    out = {}
    if not text:
        return out
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^\|(RPT_\w+)\s*\|", line)
        if not m:
            continue
        block = {}
        for key, row in zip(("wns", "tns", "viol", "paths"), lines[i:i + 4]):
            cols = row.split("|")
            if len(cols) > 2:
                try:
                    block[key] = float(cols[2].strip())
                except ValueError:
                    pass
        out[m.group(1)] = block
    return out


def parse_corner_census(run_dir, hold=False):
    """
    Every corner's post-route census, keyed by view name.

    Two shapes as usual. An archived run has it ungzipped at
    reports/52_corner_summary.rpt; a live run has it gzipped in cornerReports/.
    """
    run_dir = Path(run_dir)
    stem = "53_corner_hold_summary.rpt" if hold else "52_corner_summary.rpt"
    text = _read(run_dir / "reports" / stem)

    if text is None:
        for gz in sorted(run_dir.glob(CORNER_DIR + "/*postRoute*.summary.gz")):
            if ("_hold" in gz.name) != hold:
                continue
            text = _read_gz(gz)
            break

    return parse_view_blocks(text)


def _gen_date(path):
    text = _read(path)
    if text is None:
        return None
    m = re.search(r"Generated on:\s*(.+)", text)
    return m.group(1).strip() if m else None


# ---------------------------------------------------------------------------
# summaryReport
# ---------------------------------------------------------------------------

def _cell_table(text):
    """
    The 'Standard Cells in Netlist' block, as {cell_name: (count, area)}.

    Rows look like:            AOI22_X1              979        1302.0700
    The block ends at the next '===' banner.
    """
    out = {}
    block = re.search(
        r"Standard Cells in Netlist(.*?)(?:\n\s*={3,}|\Z)", text, re.S)
    if not block:
        return out
    for line in block.group(1).splitlines():
        parts = line.replace("\r", "").split()
        if len(parts) == 3:
            name, count, area = parts
            try:
                out[name] = (int(count), float(area))
            except ValueError:
                continue
    return out


def parse_summary(path):
    """Cells, area, density and wire length out of 44_summary.rpt."""
    d = {}
    text = _read(path)
    if text is None:
        return d

    cells = _cell_table(text)
    if cells:
        real = {k: v for k, v in cells.items() if "FILL" not in k}
        fill = {k: v for k, v in cells.items() if "FILL" in k}
        # A flip-flop in Nangate45 is DFF*, SDFF* and their reset/set variants.
        # Matching on 'DFF' catches every one and nothing else.
        d["cells"] = sum(c for c, _ in real.values())
        d["fillers"] = sum(c for c, _ in fill.values())
        d["flops"] = sum(c for k, (c, _) in real.items() if "DFF" in k)
        # SDFF is a flop with a 2x1 mux built into the cell, which is what an
        # enable-guarded register maps onto. Counting those separately is how
        # a register file shows itself in an area breakdown.
        d["flops_muxed"] = sum(c for k, (c, _) in real.items() if k.startswith("SDFF"))
        d["flops_muxed_um2"] = sum(a for k, (_, a) in real.items() if k.startswith("SDFF"))

    def grab(pattern, cast=float):
        m = re.search(pattern, text)
        return cast(m.group(1)) if m else None

    d["logic_um2"] = grab(
        r"Total area of Standard cells\(Subtracting Physical Cells\):\s*([\d.]+)")
    d["core_um2"] = grab(r"Total area of Core:\s*([\d.]+)")
    d["density_pct"] = grab(r"% Core Density #2\(Subtracting Physical Cells\):\s*([\d.]+)")
    d["wire_um"] = grab(r"Total wire length:\s*([\d.]+)")
    return d


def parse_wire_by_layer(path):
    """{'metal2': 23035.465, ...} for the metal stack figure."""
    text = _read(path)
    if text is None:
        return {}
    return {
        f"metal{n}": float(v)
        for n, v in re.findall(r"Total metal(\d+) wire length:\s*([\d.]+)", text)
    }


# ---------------------------------------------------------------------------
# the optimiser's own QOR table
# ---------------------------------------------------------------------------

def parse_flow_qor(run_dir):
    """
    Starting WNS from the earliest um*/flow_QOR_summary.rpt in the run.

    Columns are pipe-delimited: | snapshot | WNS HEPG | WNS ALL | ...
    so the all-paths WNS is field 3. This is the number the design came in at
    before optimisation, which is how you tell whether the tool had to work.
    """
    # Two shapes. A live run has it nested under reports/um*/ exactly as
    # Innovus wrote it. An archived run under results/ has it flattened to
    # reports/<stage>_flow_QOR_summary.rpt by archive_reports below, so the
    # committed evidence stands on its own and a report can be regenerated
    # from the repo alone.
    trees = sorted(
        list(run_dir.glob("reports/um*/flow_QOR_summary.rpt"))
        + list(run_dir.glob("reports/*flow_QOR_summary.rpt")),
        key=lambda p: p.stat().st_mtime,
    )
    if not trees:
        return None
    text = _read(trees[0])
    if text is None:
        return None
    for line in text.splitlines():
        if "initial_summary" not in line:
            continue
        parts = line.split("|")
        if len(parts) > 3:
            try:
                return float(parts[3].strip())
            except ValueError:
                return None
    return None


def parse_util(run_dir):
    """
    The core utilization the run was floorplanned at, out of RUN.env.

    A sweep table that records the clock but not the density cannot say what it
    swept. Older runs have no CORE_UTIL line and read back as the 0.70 that was
    hardcoded when they were built, which is what they actually used.
    """
    text = _read(Path(run_dir) / "RUN.env")
    if text:
        m = re.search(r"CORE_UTIL=([\d.]+)", text)
        if m:
            return float(m.group(1))
    return 0.70


def parse_effort(run_dir):
    """
    The synthesis effort the run was BUILT at, out of RUN.env.

    Every run before 2026-08-11 was synthesised at medium, which was hardcoded
    in genus.tcl, so an absent line reads back as the medium those runs
    actually used. That is the same convention parse_util follows.

    Without this column two runs at the same period and utilization differing
    only in effort are indistinguishable in the table, and telling them apart
    is the entire point of running the second one.
    """
    text = _read(Path(run_dir) / "RUN.env")
    if text:
        m = re.search(r"SYN_EFFORT=(\w+)", text)
        if m:
            return m.group(1)
    return "medium"


def parse_target_slack(run_dir):
    """
    The optimisation margin the run was BUILT with, out of RUN.env.

    Every run before 2026-08-12 optimised to zero, which was the only
    behaviour there was, so an absent line reads back as 0.0 exactly as
    parse_effort reads an absent line back as medium.

    This column is not decoration. Two runs at the same period, utilization
    and effort that differ only in target slack are otherwise identical in
    the table, and the whole reason for building the second one is that it
    should NOT be identical.
    """
    text = _read(Path(run_dir) / "RUN.env")
    if text:
        m = re.search(r"TARGET_SLACK=([0-9.]+)", text)
        if m:
            try:
                return float(m.group(1))
            except ValueError:
                pass
    return 0.0


def parse_derate(run_dir):
    """
    The on-chip-variation derate the run was JUDGED at, out of RUN.env.

    Every run before 2026-08-12 reads back as 0, which is what they used:
    setAnalysisMode -analysisType onChipVariation was on and there was no
    set_timing_derate anywhere, so the mode carried no margin at all.

    THIS COLUMN IS THE QUALIFIER ON EVERY FREQUENCY IN THE TABLE. A number
    signed off at 0 derate and one signed off at 5% are not comparable, and
    the gap between them is exactly what on-chip variation costs.
    """
    text = _read(Path(run_dir) / "RUN.env")
    if text:
        m = re.search(r"TIMING_DERATE=([0-9.]+)", text)
        if m:
            try:
                return float(m.group(1))
            except ValueError:
                pass
    return 0.0


def parse_clock(run_dir):
    """
    Clock period out of the SDC Genus wrote, which is the one Innovus used.

    Two places, because a run is read from two shapes. A live run has the
    file in out/ exactly where Genus left it. An ARCHIVED run under results/
    has it at the top level, put there by archive_reports, because out/ is
    gitignored and never travels. Looking in only the first place is what
    made a regenerated report print 'not recorded' for its own clock.

    RUN.env is the last resort: run.sh writes CLK_PERIOD into it so a
    resumed run cannot lie about what it was built at.
    """
    for sdc in sorted(run_dir.glob("out/*.sdc")) + sorted(run_dir.glob("*.sdc")):
        text = _read(sdc)
        if text is None:
            continue
        m = re.search(r"create_clock.*?-period\s+([\d.]+)", text, re.S)
        if m:
            return float(m.group(1))

    text = _read(run_dir / "RUN.env")
    if text:
        m = re.search(r"CLK_PERIOD=([\d.]+)", text)
        if m:
            return float(m.group(1))
    return None


# ---------------------------------------------------------------------------
# one run -> one row
# ---------------------------------------------------------------------------

def parse_run(run_dir):
    run_dir = Path(run_dir)
    rpt = run_dir / "reports"

    row = {k: "" for k in FIELDS}
    row["run"] = run_dir.name

    row["wns_place"] = _first_slack(rpt / "10_place_timing.rpt")
    row["wns_cts"] = _first_slack(rpt / "20_cts_setup.rpt")
    row["wns_hold_cts"] = _first_slack(rpt / "21_cts_hold.rpt")
    row["wns_setup"] = _first_slack(rpt / "40_final_setup.rpt")
    row["wns_hold"] = _first_slack(rpt / "41_final_hold.rpt")

    # The capped counts, kept as a fallback for runs archived before the
    # post-route summary was collected (00-baseline and 01-split-uncertainty).
    row["n_setup_viol"] = _count_violated(rpt / "40_final_setup.rpt", "Setup")
    row["n_hold_viol"] = _count_violated(rpt / "41_final_hold.rpt", "Hold")

    # The real numbers, when the run archived a summary to take them from.
    summ = parse_postroute_summary(run_dir)
    if "viol" in summ:
        row["n_setup_viol"] = int(summ["viol"])
    if "tns" in summ:
        row["tns_setup"] = summ["tns"]

    # Per-corner reporting. Absent on every run archived before 10 Aug 2026,
    # which is why each column falls back to "" rather than to the signoff
    # number: a slow-corner column silently filled with a typical-corner value
    # is the exact confusion this table was changed to end.
    census_setup = parse_corner_census(run_dir)
    census_hold = parse_corner_census(run_dir, hold=True)

    for tag in CORNERS:
        setup = census_setup.get(corner_view(tag), {})
        hold = census_hold.get(corner_view(tag), {})

        # report_timing first, then let the census overwrite it. Both are the
        # worst path in the same view, so they agree when both exist; the
        # census is preferred because it is also where the counts come from.
        row["wns_setup_" + tag] = _first_slack(rpt / ("40_setup_%s.rpt" % tag))
        row["wns_hold_" + tag] = _first_slack(rpt / ("41_hold_%s.rpt" % tag))

        if "wns" in setup:
            row["wns_setup_" + tag] = setup["wns"]
        if "tns" in setup:
            row["tns_setup_" + tag] = setup["tns"]
        if "viol" in setup:
            row["n_setup_viol_" + tag] = int(setup["viol"])
        if "wns" in hold:
            row["wns_hold_" + tag] = hold["wns"]
        if "viol" in hold:
            row["n_hold_viol_" + tag] = int(hold["viol"])

    row.update({k: v for k, v in parse_summary(rpt / "44_summary.rpt").items()})

    row["wns_place_start"] = parse_flow_qor(run_dir)
    row["clk_ns"] = parse_clock(run_dir)
    row["util"] = parse_util(run_dir)
    row["effort"] = parse_effort(run_dir)
    row["target_slack"] = parse_target_slack(run_dir)
    row["derate"] = parse_derate(run_dir)
    row["date"] = _gen_date(rpt / "44_summary.rpt") or ""

    return {k: ("" if v is None else v) for k, v in row.items()}


# ---------------------------------------------------------------------------
# results/qor.csv and results/QOR.md
# ---------------------------------------------------------------------------

def load_csv(csv_path):
    if not csv_path.exists():
        return []
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def save_csv(csv_path, rows):
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in FIELDS})


def _fmt(v, places=3):
    if v in ("", None):
        return "-"
    try:
        return f"{float(v):.{places}f}"
    except (TypeError, ValueError):
        return str(v)


def _int(v):
    if v in ("", None):
        return "-"
    try:
        return f"{int(float(v)):,}"
    except (TypeError, ValueError):
        return str(v)


def _viol(v):
    """A violation count. 0 is a result, not a missing value."""
    if v in ("", None):
        return "-"
    try:
        return str(int(float(v)))
    except (TypeError, ValueError):
        return str(v)


def _viol_checked(v, wns):
    """
    A violation count, marked `!` when it contradicts its own WNS.

    route_opt_design's summary counts HOLD checks and not REMOVAL ones. The
    moment reset_sync made the removal checks real, 119 of them failed at the
    fast corner and this column still said 0, beside a WNS of -0.061. A zero
    that cannot be true is worse than a missing number, because a missing
    number reads as missing and a zero reads as a pass.

    The two figures are NOT reconciled here on purpose. The signoff count and
    the corner census are different measurements and this file already refuses
    to mix them elsewhere; the honest move is to flag the contradiction and
    send the reader to the census column, not to quietly substitute one for
    the other.
    """
    s = _viol(v)
    try:
        if float(wns) < 0 and float(v) == 0:
            return s + " !"
    except (TypeError, ValueError):
        pass
    return s


def _one_line(note):
    """
    A note, flattened to one line and stripped of pipes.

    A markdown table row is terminated by its newline, so a note carrying one
    splits the row in half and corrupts every column after it. Notes come off
    a command line typed into a VNC xterm, which is exactly where a stray
    newline gets in.
    """
    return " ".join((note or "").replace("|", "/").split())


def _corner_section(rows):
    """
    The same design judged at all three corners, three rows per run.

    THE POINT OF THIS TABLE. 2.8 ns closing at +0.002 and the same design
    missing by -0.968 are not two results, they are one result and its
    qualifier, and for a while they lived in two different runs and had to be
    joined by hand. Every run now reports all three, so the qualifier travels
    with the number.
    """
    labels = {"slow": "slow  SS 0.95V 125C",
              "typ": "typ   TT 1.10V  25C",
              "fast": "fast  FF 1.25V   0C"}

    body = (
        "## By corner\n\n"
        "Every run reports all three corners from the same routed database.\n"
        "**Setup is signed off at slow and hold at fast**; the other cells are\n"
        "reporting only and exist so that a number can never be quoted without\n"
        "the corner it came from.\n\n"
        "**A run with no rows here could not be re-judged.** `--from report`\n"
        "back-fills any run whose database was built under MMMC. Runs saved\n"
        "before MMMC existed have no `Cmin` rc corner and carry a typical\n"
        "library that conflicts with the slow and fast ones, so the corner\n"
        "views cannot be built on them at all and the flow refuses rather than\n"
        "report the two that happen to work. `04-mmmc-analysis` is that\n"
        "experiment done properly: it re-judged the `03-ring-fix` netlist at\n"
        "real corners from synthesis. Read it as run 03's slow-corner result.\n\n"
        "These come from a `timeDesign` **re-analysis** of the routed database,\n"
        "archived as `52_corner_summary.rpt`. The main table above comes from\n"
        "`route_opt_design`'s own final SI summary and is the signoff number.\n"
        "**The two agree on WNS and disagree on TNS and the violation count**:\n"
        "run 06 signs off at -1.344 ns over 45 paths and re-analyses to -0.550\n"
        "over 28. Enabling SI-aware delay calculation does not close the gap.\n"
        "All three corners here are measured identically, so compare a corner\n"
        "column against a corner column and never against the table above.\n\n"
        "| Run | Clk | Corner | Setup WNS | Setup TNS | Setup viol | Hold WNS | Hold viol |\n"
        "|---|---:|---|---:|---:|---:|---:|---:|\n"
    )

    any_rows = False
    for r in rows:
        if not any(r.get("wns_setup_" + t) not in ("", None) for t in CORNERS):
            continue
        any_rows = True
        for i, tag in enumerate(CORNERS):
            body += "| {run} | {clk} | `{corner}` | {ws} | {ts} | {ns} | {wh} | {nh} |\n".format(
                # The run name and clock on the first of its three rows only,
                # so the eye groups them without a rule between blocks.
                run=("`%s`" % r.get("run", "?")) if i == 0 else "",
                clk=_fmt(r.get("clk_ns"), 2) if i == 0 else "",
                corner=labels[tag],
                ws=_fmt(r.get("wns_setup_" + tag)),
                ts=_fmt(r.get("tns_setup_" + tag), 1),
                ns=_viol(r.get("n_setup_viol_" + tag)),
                wh=_fmt(r.get("wns_hold_" + tag)),
                nh=_viol(r.get("n_hold_viol_" + tag)),
            )

    if not any_rows:
        body += "| - | - | - | - | - | - | - | - |\n"

    return body + "\n"


def write_markdown(rows, md_path):
    """
    The iteration table. One row per run, newest last, so the trend reads
    top to bottom in the order the work happened.
    """
    # Setup TNS and Setup viol sit beside Setup WNS, because WNS is one number
    # and it hides the shape. A run can show the same worst slack whether one
    # endpoint fails or four hundred do, and those are different problems.
    #
    # Both come from the post-route summary rather than from counting VIOLATED
    # lines in 40_final_setup.rpt. That report holds at most -max_paths paths,
    # so a badly failing run saturates the count at the cap and the table then
    # prints the cap as though it were a measurement. Run 04 reported exactly
    # 50 setup and exactly 50 hold, which was -max_paths 50 and not a count.
    # The true figure was 362 failing paths and -82.8 ns of TNS.
    head = (
        "| Run | Clk | Util | Effort | TgtSlk | OCV | Setup WNS | Setup TNS | Setup viol | Hold WNS | Hold viol | Cells | Density | Wire | Note |\n"
        "|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|\n"
    )
    lines = []
    for r in rows:
        lines.append(
            "| `{run}` | {clk} | {util} | {eff} | {tgt} | {ocv} | {ws} | {ts} | {ns} | {wh} | {nh} | {cells} | {den} | {wire} | {note} |".format(
                run=r.get("run", "?"),
                clk=_fmt(r.get("clk_ns"), 2),
                util=_fmt(r.get("util"), 2),
                eff=r.get("effort") or "medium",
                # 0 is a result, not missing data: it says this run stopped at
                # zero slack, which is what every run before 2026-08-12 did.
                tgt=_fmt(r.get("target_slack") or 0, 3),
                # 0 is a result: this run was judged with no OCV margin at all.
                ocv=_fmt(r.get("derate") or 0, 3),
                ws=_fmt(r.get("wns_setup")),
                ts=_fmt(r.get("tns_setup"), 1),
                ns=_viol(r.get("n_setup_viol")),
                wh=_fmt(r.get("wns_hold")),
                # NOT `or "-"`: zero is falsy, so a run with no hold
                # violations rendered as "-" and read as missing data. Zero
                # violations is the whole point of a hold fix and it has to
                # show as 0. "-" is reserved for genuinely absent.
                nh=_viol_checked(r.get("n_hold_viol"), r.get("wns_hold")),
                cells=_int(r.get("cells")),
                den=(_fmt(r.get("density_pct"), 1) + "%") if r.get("density_pct") else "-",
                wire=_int(r.get("wire_um")),
                note=_one_line(r.get("note")),
            )
        )

    body = (
        "# Quality of results, by iteration\n\n"
        "**Generated by `scripts/qor.py`. Do not hand-edit** — rerun\n"
        "`python3 scripts/qor.py table` instead.\n\n"
        "Slacks are nanoseconds, worst path, post-route unless the column says\n"
        "otherwise. A negative setup WNS means the run did not make timing at\n"
        "that clock. Frozen reports for every run are in `results/<run>/reports/`.\n"
        "A hold count marked `!` contradicts its own WNS: the signoff summary counts\n"
        "hold checks and not removal ones, so read the per-corner table below for the\n"
        "real figure.\n\n"
        + head + "\n".join(lines) + "\n\n"
        + _corner_section(rows) +
        "## Stage progression\n\n"
        "Where the slack went between stages, which is how you tell whether a\n"
        "problem is in synthesis, in placement, in the clock tree or in the routing.\n\n"
        "| Run | Placed | After CTS | Post-route | CTS cost | Route cost |\n"
        "|---|---:|---:|---:|---:|---:|\n"
    )

    for r in rows:
        try:
            p, c, f = (float(r["wns_place"]), float(r["wns_cts"]), float(r["wns_setup"]))
            cts_cost, route_cost = _fmt(p - c), _fmt(c - f)
        except (TypeError, ValueError, KeyError):
            cts_cost = route_cost = "-"
        body += "| `{}` | {} | {} | {} | {} | {} |\n".format(
            r.get("run", "?"),
            _fmt(r.get("wns_place")), _fmt(r.get("wns_cts")),
            _fmt(r.get("wns_setup")), cts_cost, route_cost,
        )

    md_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.write_text(body, encoding="utf-8")


def _copy(src, dst):
    """
    Copy one file, returning 1 if it was copied and 0 if there was nothing
    to do.

    Re-collecting an ARCHIVED run points src and dst at the same file, and
    shutil raises SameFileError. Re-parsing an archived run is a legitimate
    thing to do — it is how a run picks up a parser fix without the tools —
    so it has to be a no-op rather than a crash.
    """
    if not src.exists():
        return 0
    if dst.exists() and src.resolve() == dst.resolve():
        return 0
    shutil.copy2(src, dst)
    return 1


def archive_reports(run_dir, results_dir):
    """Copy the small text reports somewhere they can be committed."""
    dest = results_dir / run_dir.name / "reports"
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for name in KEEP:
        n += _copy(run_dir / "reports" / name, dest / name)
    for qor in run_dir.glob("reports/um*/flow_QOR_summary.rpt"):
        n += _copy(qor, dest / f"{qor.parent.name}_flow_QOR_summary.rpt")

    # DRC and connectivity.
    #
    # These two are the only checks in the flow that innovus.tcl does not
    # redirect, which for a long time was read as "they print to stdout only"
    # and cost a hand extraction out of innovus.log every run. They do not.
    # verify_drc and verify_connectivity each write a default-named report
    # into the run directory rather than into reports/, which is the only
    # reason they were missed: <design>.geom.rpt and <design>.conn.rpt. They
    # are about 1 KB together against 36 KB for the log dump, and unlike the
    # log they carry the violating coordinates.
    for geom in run_dir.glob("*.geom.rpt"):
        n += _copy(geom, dest / "45_drc.rpt")
    for conn in run_dir.glob("*.conn.rpt"):
        n += _copy(conn, dest / "46_connectivity.rpt")

    # The post-route timing summary, which is the report a PD engineer reads
    # first and the one this project went longest without.
    #
    # report_timing shows N paths and answers "what is the worst one". This
    # answers "how many are there", per path group: WNS, TNS, violating paths,
    # total paths, and the max_cap/max_tran/max_fanout design rule violations
    # beside them. WNS alone cannot tell one failing endpoint from four hundred.
    #
    # Innovus writes these gzipped into timingReports/, so they are ungzipped
    # on the way out. A .gz in the repo is a file nobody opens on GitHub, and
    # these are two or three kilobytes of text.
    for gz in sorted(run_dir.glob(SIGNOFF_DIR + "/*postRoute*.summary.gz")):
        stem = ("51_postroute_hold_summary.rpt" if "_hold" in gz.name
                else "50_postroute_summary.rpt")
        text = _read_gz(gz)
        if text is not None:
            (dest / stem).write_text(text)
            n += 1

    # The corner census, from its own directory and under its own names. 50 and
    # 51 are the SI-aware signoff summaries route_opt_design wrote and are not
    # this measurement; keeping them apart is the whole reason cornerReports
    # exists. See the note on SIGNOFF_DIR.
    for gz in sorted(run_dir.glob(CORNER_DIR + "/*postRoute*.summary.gz")):
        stem = ("53_corner_hold_summary.rpt" if "_hold" in gz.name
                else "52_corner_summary.rpt")
        text = _read_gz(gz)
        if text is not None:
            (dest / stem).write_text(text)
            n += 1

    # The elaborated SDC, beside the reports rather than under reports/.
    #
    # This is what makes an archived run self-describing. parse_clock reads
    # the period out of the SDC Genus WROTE, because the source constraint
    # file holds '-period $CLK_PERIOD', a Tcl variable that no regex for
    # digits can match. That file lives in the run's out/, which is
    # gitignored and disposable, so a report regenerated from results/ used
    # to have no clock at all and printed 'not recorded' on its cover. It is
    # 27 KB of text and it is the definition of what the run was asked to do.
    for sdc in sorted(run_dir.glob("out/*.sdc")):
        n += _copy(sdc, results_dir / run_dir.name / sdc.name)
    n += _copy(run_dir / "RUN.env", results_dir / run_dir.name / "RUN.env")
    return n, dest


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # dest= plus the explicit check below, NOT add_subparsers(required=True),
    # which argparse only accepts from Python 3.7. nanoHUB runs 3.6, and this
    # file has to run there: it is what turns a finished run into a row of the
    # results table. Nothing else in this script needs anything newer.
    sub = ap.add_subparsers(dest="cmd")

    c = sub.add_parser("collect", help="read a run directory, append a row")
    c.add_argument("run_dir")
    c.add_argument("--note", default="", help="what changed in this run")
    c.add_argument("--root", default=None, help="project root (default: parent of scripts/)")

    t = sub.add_parser("table", help="rewrite results/QOR.md from results/qor.csv")
    t.add_argument("--root", default=None)

    args = ap.parse_args()
    if not args.cmd:
        ap.error("a subcommand is required: collect or table")
    root = Path(args.root) if args.root else Path(__file__).resolve().parent.parent
    results = root / "results"
    csv_path = results / "qor.csv"

    if args.cmd == "collect":
        run_dir = Path(args.run_dir)
        if not run_dir.is_absolute():
            run_dir = (root / run_dir).resolve()
        if not (run_dir / "reports").is_dir():
            sys.exit(f"no reports/ under {run_dir}")

        row = parse_run(run_dir)
        row["note"] = args.note

        rows = [r for r in load_csv(csv_path) if r.get("run") != row["run"]]
        rows.append(row)
        save_csv(csv_path, rows)
        write_markdown(rows, results / "QOR.md")
        n, dest = archive_reports(run_dir, results)

        print(f"run          {row['run']}")
        print(f"clock        {_fmt(row['clk_ns'], 2)} ns")
        print(f"setup WNS    {_fmt(row['wns_setup'])} ns   ({row['n_setup_viol']} violated)")
        print(f"hold  WNS    {_fmt(row['wns_hold'])} ns   ({row['n_hold_viol']} violated)")
        for tag in CORNERS:
            if row["wns_setup_" + tag] == "":
                continue
            print("  {:<5} setup {:>8} ns  ({} violated)   hold {:>8} ns".format(
                tag, _fmt(row["wns_setup_" + tag]), _viol(row["n_setup_viol_" + tag]),
                _fmt(row["wns_hold_" + tag])))
        if all(row["wns_setup_" + t] == "" for t in CORNERS):
            print("  (no per-corner reports; see reports/49_corner_status.rpt)")
        print(f"cells        {_int(row['cells'])} + {_int(row['fillers'])} fillers")
        print(f"density      {_fmt(row['density_pct'], 1)}%")
        print(f"archived     {n} reports -> {dest}")
        print(f"table        {results / 'QOR.md'}")

    elif args.cmd == "table":
        rows = load_csv(csv_path)
        if not rows:
            sys.exit(f"no rows in {csv_path}")
        write_markdown(rows, results / "QOR.md")
        print(f"{len(rows)} runs -> {results / 'QOR.md'}")


if __name__ == "__main__":
    main()
