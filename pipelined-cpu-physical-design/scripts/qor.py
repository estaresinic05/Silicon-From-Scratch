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
    "43_final_power.rpt", "44_summary.rpt",
]

# Column order in qor.csv. Adding a field here is safe: older rows read back
# with empty strings for it.
FIELDS = [
    "run", "note", "clk_ns", "date",
    "wns_place", "wns_cts", "wns_hold_cts", "wns_setup", "wns_hold",
    "n_setup_viol", "n_hold_viol",
    "cells", "fillers", "flops",
    "logic_um2", "core_um2", "density_pct",
    "wire_um", "wns_place_start",
]


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


def parse_clock(run_dir):
    """Clock period out of the SDC Genus wrote, which is the one Innovus used."""
    for sdc in list(run_dir.glob("out/*.sdc")):
        text = _read(sdc)
        if text is None:
            continue
        m = re.search(r"create_clock.*?-period\s+([\d.]+)", text, re.S)
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

    row["n_setup_viol"] = _count_violated(rpt / "40_final_setup.rpt", "Setup")
    row["n_hold_viol"] = _count_violated(rpt / "41_final_hold.rpt", "Hold")

    row.update({k: v for k, v in parse_summary(rpt / "44_summary.rpt").items()})

    row["wns_place_start"] = parse_flow_qor(run_dir)
    row["clk_ns"] = parse_clock(run_dir)
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


def write_markdown(rows, md_path):
    """
    The iteration table. One row per run, newest last, so the trend reads
    top to bottom in the order the work happened.
    """
    head = (
        "| Run | Clk | Setup WNS | Hold WNS | Hold viol | Cells | Density | Wire | Note |\n"
        "|---|---:|---:|---:|---:|---:|---:|---:|---|\n"
    )
    lines = []
    for r in rows:
        lines.append(
            "| `{run}` | {clk} | {ws} | {wh} | {nh} | {cells} | {den} | {wire} | {note} |".format(
                run=r.get("run", "?"),
                clk=_fmt(r.get("clk_ns"), 2),
                ws=_fmt(r.get("wns_setup")),
                wh=_fmt(r.get("wns_hold")),
                nh=r.get("n_hold_viol") or "-",
                cells=_int(r.get("cells")),
                den=(_fmt(r.get("density_pct"), 1) + "%") if r.get("density_pct") else "-",
                wire=_int(r.get("wire_um")),
                note=(r.get("note") or "").replace("|", "/"),
            )
        )

    body = (
        "# Quality of results, by iteration\n\n"
        "**Generated by `scripts/qor.py`. Do not hand-edit** — rerun\n"
        "`python3 scripts/qor.py table` instead.\n\n"
        "Slacks are nanoseconds, worst path, post-route unless the column says\n"
        "otherwise. A negative setup WNS means the run did not make timing at\n"
        "that clock. Frozen reports for every run are in `results/<run>/reports/`.\n\n"
        + head + "\n".join(lines) + "\n\n"
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


def archive_reports(run_dir, results_dir):
    """Copy the small text reports somewhere they can be committed."""
    dest = results_dir / run_dir.name / "reports"
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for name in KEEP:
        src = run_dir / "reports" / name
        if src.exists():
            shutil.copy2(src, dest / name)
            n += 1
    for qor in run_dir.glob("reports/um*/flow_QOR_summary.rpt"):
        shutil.copy2(qor, dest / f"{qor.parent.name}_flow_QOR_summary.rpt")
        n += 1
    return n, dest


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("collect", help="read a run directory, append a row")
    c.add_argument("run_dir")
    c.add_argument("--note", default="", help="what changed in this run")
    c.add_argument("--root", default=None, help="project root (default: parent of scripts/)")

    t = sub.add_parser("table", help="rewrite results/QOR.md from results/qor.csv")
    t.add_argument("--root", default=None)

    args = ap.parse_args()
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
