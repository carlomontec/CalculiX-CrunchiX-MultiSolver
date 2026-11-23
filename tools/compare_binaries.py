#!/usr/bin/env python3
"""Run the official CalculiX test suite with two binaries and compare their results.

Used to show that this edition gives the same results as plain upstream
CalculiX (e.g. the 2.24 reference built with upstream's own CMake). Unlike the
normal test runner, which compares one binary against the stored .dat.ref
files, this compares the two binaries' outputs with each other.

For every deck in test/ (same deck list and order as upstream's test/compare):
  * each binary runs in its own copy of test/ (decks are split into contiguous
    alphabetical chunks, so decks that depend on earlier decks still see them);
  * the .dat files are compared: byte-identical, otherwise Dhondt's
    datcheck.pl with the reference binary's output as .dat.ref (0.1 % of the
    block maximum), and the largest relative difference is reported;
  * the .frd files are compared the same way with frdcheck.pl, ignoring the
    user header lines (1U...) that carry date, compile time and version.

Usage:
  python3 tools/compare_binaries.py --ref-bin REF/CalculiX --test-bin build/CalculiX \
      --work /tmp/cmp --jobs 5 --threads 1 --out report.csv
"""

import argparse
import concurrent.futures as cf
import csv
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SKIP = {"circ10pcent.rfn.inp", "circ10p.rfn.inp", "circ11p.rfn.inp", "segmentsmooth.rfn.inp",
        "segmentsmooth2.rfn.inp", "contact4tetrefine.rfn.inp", "contact4bad.rfn.inp",
        "contact4badnl.rfn.inp", "beam10psmooth.rfn.inp", "circ10dload.rfn.inp",
        "circ10pnl.rfn.inp", "segmentsmooth3.rfn.inp"}
MTX_DECKS = {"substructure", "substructure2", "beammrlin_diff", "beammrlin_same"}
FRD_HEADER = re.compile(r"^\s*1U[A-Z]")
NUM = re.compile(r"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eEdD][-+]?\d+)?")


def run_chunk(binary, label, chunk_id, decks, test_dir, work, threads, timeout):
    sandbox = work / label / f"chunk{chunk_id:02d}"
    if sandbox.exists():
        shutil.rmtree(sandbox)
    shutil.copytree(test_dir, sandbox, ignore=shutil.ignore_patterns("*.dat", "*.frd", "*.sta", "*.cvg"))
    env = dict(os.environ, OMP_NUM_THREADS=str(threads))
    out = {}
    for deck in decks:
        name = deck[:-4]
        t0 = time.time()
        try:
            with open(sandbox / f"{name}.log", "w") as log:
                rc = subprocess.run([binary, name], cwd=sandbox, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
        if name in MTX_DECKS and (sandbox / f"{name}.mtx").exists():
            data = (sandbox / f"{name}.mtx").read_text().replace(",", " ")
            (sandbox / f"{name}.dat").write_text(data)
        out[name] = (rc, time.time() - t0, sandbox)
    return out


def max_rel_diff(a_lines, b_lines):
    """Largest |a-b| / max(|a|,|b|) over numeric tokens; None if structure differs."""
    worst = 0.0
    for la, lb in zip(a_lines, b_lines):
        na, nb = NUM.findall(la), NUM.findall(lb)
        if len(na) != len(nb):
            return None
        for x, y in zip(na, nb):
            fx, fy = float(x.replace("D", "E").replace("d", "e")), float(y.replace("D", "E").replace("d", "e"))
            den = max(abs(fx), abs(fy))
            if den > 1e-30:
                worst = max(worst, abs(fx - fy) / den)
    return worst


def compare_file(ref_file, test_file, kind, scripts_dir, scratch):
    """Return (status, max_rel_diff, detail)."""
    if not ref_file.exists() and not test_file.exists():
        return "none", None, ""
    if not ref_file.exists() or not test_file.exists():
        return "MISSING", None, "ref" if not ref_file.exists() else "test"
    ra = ref_file.read_text(errors="replace").splitlines()
    ta = test_file.read_text(errors="replace").splitlines()
    if kind == "frd":
        ra = [l for l in ra if not FRD_HEADER.match(l)]
        ta = [l for l in ta if not FRD_HEADER.match(l)]
    if ra == ta:
        return "IDENTICAL", 0.0, ""
    if len(ra) != len(ta):
        return "DIFF", None, f"line count {len(ra)} vs {len(ta)}"
    mrd = max_rel_diff(ra, ta)
    scratch.mkdir(parents=True, exist_ok=True)
    (scratch / f"x.{kind}.ref").write_text("\n".join(ra) + "\n")
    (scratch / f"x.{kind}").write_text("\n".join(ta) + "\n")
    chk = subprocess.run(["perl", str(scripts_dir / f"{kind}check.pl"), "x"], cwd=scratch,
                         capture_output=True, text=True).stdout.strip()
    if chk:
        return "DIFF", mrd, " ".join(chk.split())[:300]
    return "WITHIN_TOL", mrd, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ref-bin", required=True)
    ap.add_argument("--test-bin", required=True)
    ap.add_argument("--test-dir", default=str(Path(__file__).resolve().parent.parent / "test"))
    ap.add_argument("--work", required=True, help="scratch directory for the sandboxes")
    ap.add_argument("--jobs", type=int, default=4, help="chunks per binary (both binaries run at once)")
    ap.add_argument("--threads", type=int, default=1, help="OMP_NUM_THREADS for every run")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--pattern", default="*.inp")
    ap.add_argument("--out", required=True, help="CSV report")
    args = ap.parse_args()

    test_dir, work = Path(args.test_dir).resolve(), Path(args.work).resolve()
    decks = sorted(p.name for p in test_dir.glob(args.pattern) if p.name not in SKIP)
    n = max(1, args.jobs)
    size = -(-len(decks) // n)
    chunks = [decks[i:i + size] for i in range(0, len(decks), size)]
    print(f"{len(decks)} decks, {len(chunks)} chunks per binary, OMP_NUM_THREADS={args.threads}", flush=True)

    runs = {"ref": {}, "test": {}}
    with cf.ProcessPoolExecutor(max_workers=2 * len(chunks)) as pool:
        futs = {}
        for label, binary in (("ref", os.path.abspath(args.ref_bin)), ("test", os.path.abspath(args.test_bin))):
            for i, ch in enumerate(chunks):
                f = pool.submit(run_chunk, binary, label, i, ch, test_dir, work, args.threads, args.timeout)
                futs[f] = label
        for f in cf.as_completed(futs):
            runs[futs[f]].update(f.result())
            print(f"  chunk done ({futs[f]})", flush=True)

    rows, counts = [], {}
    for deck in decks:
        name = deck[:-4]
        rrc, rt, rdir = runs["ref"][name]
        trc, tt, tdir = runs["test"][name]
        scratch = work / "cmp" / name
        dat = compare_file(rdir / f"{name}.dat", tdir / f"{name}.dat", "dat", test_dir, scratch)
        frd = compare_file(rdir / f"{name}.frd", tdir / f"{name}.frd", "frd", test_dir, scratch)
        statuses = [s for s, _, _ in (dat, frd) if s != "none"]
        if rrc != trc:
            overall = "EXIT_DIFF"
        elif any(s in ("DIFF", "MISSING") for s in statuses):
            overall = "DIFF"
        elif any(s == "WITHIN_TOL" for s in statuses):
            overall = "WITHIN_TOL"
        elif statuses:
            overall = "IDENTICAL"
        else:
            overall = "NO_OUTPUT"
        counts[overall] = counts.get(overall, 0) + 1
        fmt = lambda v: "" if v is None else f"{v:.3e}"
        rows.append([name, overall, rrc, trc, f"{rt:.1f}", f"{tt:.1f}", dat[0], fmt(dat[1]), dat[2],
                     frd[0], fmt(frd[1]), frd[2]])

    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh, delimiter=";")
        w.writerow(["deck", "overall", "ref_exit", "test_exit", "ref_s", "test_s", "dat", "dat_max_rel",
                    "dat_detail", "frd", "frd_max_rel", "frd_detail"])
        w.writerows(rows)

    print("\nSummary:")
    for k in ("IDENTICAL", "WITHIN_TOL", "DIFF", "EXIT_DIFF", "NO_OUTPUT"):
        print(f"  {k:<11} {counts.get(k, 0)}")
    for r in rows:
        if r[1] in ("DIFF", "EXIT_DIFF"):
            print(f"  {r[1]:<10} {r[0]}: exit {r[2]}/{r[3]} dat={r[6]} {r[8][:120]} frd={r[9]} {r[11][:120]}")
    print(f"\nCSV: {args.out}")


if __name__ == "__main__":
    sys.exit(main())
