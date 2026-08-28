#!/usr/bin/env python3
"""
Automated JSON Reference Generator for CalculiX Multi-Solver Edition.
Executes official test decks against verified solvers (SPOOLES / MUMPS),
validates results against Dr. Dhondt's original reference files (.dat.ref / .frd.ref),
and generates clean golden reference files in:
    test_NewLib/originaltest_json/<deck>.json.ref

Leaving the original test/ directory 100% untouched.
Generates comprehensive Markdown and CSV reports tracking verified vs discrepant decks.
"""

import os
import sys
import shutil
import subprocess
import time
import json
import csv
import argparse
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed

SCRIPT_DIR = Path(__file__).resolve().parent
CCX_DIR = SCRIPT_DIR.parent
TEST_DIR = CCX_DIR / "test"
OUT_REF_DIR = SCRIPT_DIR / "originaltest_json"
REPORT_MD = SCRIPT_DIR / "originaltest_json_report.md"
REPORT_CSV = SCRIPT_DIR / "originaltest_json_report.csv"

# Binary paths
EXE_NAME = "CalculiX.exe" if sys.platform == "win32" else "CalculiX"
SPOOLES_BIN = CCX_DIR / "build_spooles" / EXE_NAME
MUMPS_BIN = CCX_DIR / "build_mumps" / EXE_NAME
ACCEL_BIN = CCX_DIR / "build_accelerate" / EXE_NAME


def discover_decks(pattern="*"):
    """Find all valid .inp decks in test/."""
    decks = sorted([
        f.stem for f in TEST_DIR.glob(f"{pattern}.inp")
        if not f.stem.endswith(".rin") and not f.stem.endswith(".ref")
    ])
    return decks


def run_test_deck(deck, solver_bin, solver_name, timeout=60):
    """Run a single test deck in an isolated sandbox with CCX_JSON=1."""
    sandbox = Path(f"/tmp/ccx_genref_{deck}_{solver_name}_{os.getpid()}")
    if sandbox.exists():
        shutil.rmtree(sandbox, ignore_errors=True)
    sandbox.mkdir(parents=True, exist_ok=True)

    try:
        # Copy input deck and auxiliary files
        inp_file = TEST_DIR / f"{deck}.inp"
        shutil.copy2(inp_file, sandbox / f"{deck}.inp")
        for ext in [".rin", ".sur", ".dlo", ".equ", ".nam", ".flm", ".rou", ".frd", ".f", ".py", ".extra", ".mpc", ".sur.ref"]:
            for aux in TEST_DIR.glob(f"{deck}*{ext}"):
                shutil.copy2(aux, sandbox / aux.name)
            for aux in TEST_DIR.glob(f"*{ext}"):
                if not (sandbox / aux.name).exists() and aux.stat().st_size < 5 * 1024 * 1024:
                    try:
                        shutil.copy2(aux, sandbox / aux.name)
                    except Exception:
                        pass

        env = os.environ.copy()
        env["CCX_JSON"] = "1"
        env["OMP_NUM_THREADS"] = "1"
        env["CCX_NPROC_EQUATION_SOLVER"] = "1"

        t0 = time.perf_counter()
        proc = subprocess.run(
            [str(solver_bin), "-j", deck],
            cwd=str(sandbox),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout
        )
        elapsed = time.perf_counter() - t0

        json_file = sandbox / f"{deck}.json"
        has_valid_json = False
        json_content = None
        if json_file.exists():
            try:
                with open(json_file, "r", encoding="utf-8") as jf:
                    json_content = json.load(jf)
                has_valid_json = True
            except Exception as je:
                has_valid_json = False

        # Substructure format conversion for checkers
        if deck in ["substructure", "substructure2", "beammrlin_diff", "beammrlin_same"]:
            mtx_f = sandbox / f"{deck}.mtx"
            dat_f = sandbox / f"{deck}.dat"
            if mtx_f.exists():
                with open(mtx_f, "r") as fin, open(dat_f, "w") as fout:
                    fout.write(fin.read().replace(",", " "))

        dat_ref = TEST_DIR / f"{deck}.dat.ref"
        frd_ref = TEST_DIR / f"{deck}.frd.ref"
        dat_test = sandbox / f"{deck}.dat"
        frd_test = sandbox / f"{deck}.frd"

        status = "PASS"
        detail = "Clean numerical match"
        max_rel_err = 0.0

        if proc.returncode != 0:
            status = "FAIL"
            detail = f"Solver crashed (exit code {proc.returncode})"
        else:
            # Check DAT
            if dat_ref.exists() and dat_test.exists():
                cp = subprocess.run(
                    ["perl", str(TEST_DIR / "datcheck.pl"), deck],
                    cwd=str(sandbox),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30
                )
                res_out = cp.stdout.strip()
                if "deviation in file" in res_out:
                    status = "DIFF"
                    for line in res_out.splitlines():
                        if "relative error" in line:
                            detail = f"DAT {line.strip()}"
                            try:
                                max_rel_err = float(line.split(":")[-1].replace("%", "").strip())
                            except Exception:
                                pass
                            break
                    if not detail.startswith("DAT"):
                        detail = "DAT numerical deviation"

            # Check FRD
            if status == "PASS" and frd_ref.exists() and frd_test.exists():
                cp = subprocess.run(
                    ["perl", str(TEST_DIR / "frdcheck.pl"), deck],
                    cwd=str(sandbox),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30
                )
                res_out = cp.stdout.strip()
                if "deviation in file" in res_out:
                    status = "DIFF"
                    for line in res_out.splitlines():
                        if "relative error" in line:
                            detail = f"FRD {line.strip()}"
                            try:
                                max_rel_err = float(line.split(":")[-1].replace("%", "").strip())
                            except Exception:
                                pass
                            break
                    if not detail.startswith("FRD"):
                        detail = "FRD numerical deviation"

        return {
            "deck": deck,
            "solver": solver_name,
            "status": status,
            "detail": detail,
            "time": elapsed,
            "has_json": has_valid_json,
            "json_data": json_content,
            "max_rel_err": max_rel_err,
            "stdout": proc.stdout
        }

    except subprocess.TimeoutExpired:
        return {"deck": deck, "solver": solver_name, "status": "TIMEOUT", "detail": f"Timeout ({timeout}s)", "time": timeout, "has_json": False, "json_data": None, "max_rel_err": 0.0, "stdout": ""}
    except Exception as e:
        return {"deck": deck, "solver": solver_name, "status": "ERROR", "detail": str(e), "time": 0.0, "has_json": False, "json_data": None, "max_rel_err": 0.0, "stdout": ""}
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def process_deck_pipeline(deck):
    """
    Attempt to capture a verified golden JSON reference.
    1. Try SPOOLES (primary baseline).
    2. If SPOOLES is DIFF/FAIL, try MUMPS.
    3. If MUMPS is DIFF/FAIL, try ACCELERATE (if available).
    """
    solvers_to_try = []
    if SPOOLES_BIN.is_file(): solvers_to_try.append((SPOOLES_BIN, "SPOOLES"))
    if MUMPS_BIN.is_file(): solvers_to_try.append((MUMPS_BIN, "MUMPS"))
    if ACCEL_BIN.is_file(): solvers_to_try.append((ACCEL_BIN, "ACCELERATE"))

    best_result = None
    all_attempts = {}

    for s_bin, s_name in solvers_to_try:
        res = run_test_deck(deck, s_bin, s_name)
        all_attempts[s_name] = res
        if res["status"] == "PASS" and res["has_json"]:
            best_result = res
            break
        if best_result is None or (best_result["status"] != "PASS" and res["status"] == "DIFF"):
            best_result = res

    # If verified pass obtained, write to test_NewLib/originaltest_json/<deck>.json.ref
    generated = False
    if best_result and best_result["status"] == "PASS" and best_result["has_json"] and best_result["json_data"] is not None:
        ref_path = OUT_REF_DIR / f"{deck}.json.ref"
        with open(ref_path, "w", encoding="utf-8") as rf:
            json.dump(best_result["json_data"], rf, indent=2)
        generated = True

    return {
        "deck": deck,
        "generated": generated,
        "best_solver": best_result["solver"] if best_result else "NONE",
        "status": best_result["status"] if best_result else "FAIL",
        "detail": best_result["detail"] if best_result else "No solver available",
        "time": best_result["time"] if best_result else 0.0,
        "max_rel_err": best_result.get("max_rel_err", 0.0) if best_result else 0.0,
        "all_attempts": {k: f"{v['status']} ({v['detail']})" for k, v in all_attempts.items()}
    }


def main():
    parser = argparse.ArgumentParser(description="Generate golden JSON reference suite.")
    parser.add_argument("--pattern", type=str, default="*", help="Pattern of decks to process (default: *)")
    parser.add_argument("--workers", type=int, default=8, help="Parallel worker count (default: 8)")
    parser.add_argument("--limit", type=int, default=None, help="Limit total decks (optional)")
    args = parser.parse_args()

    OUT_REF_DIR.mkdir(parents=True, exist_ok=True)

    decks = discover_decks(args.pattern)
    if args.limit:
        decks = decks[:args.limit]

    print("=" * 80)
    print(" CalculiX Golden JSON Reference Generator")
    print("=" * 80)
    print(f" Test Decks       : {len(decks)} discovered in test/")
    print(f" Output Directory : {OUT_REF_DIR}")
    print(f" Workers          : {args.workers}")
    print("=" * 80)

    t_start = time.perf_counter()
    results = {}
    total = len(decks)
    completed = 0

    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(process_deck_pipeline, d): d for d in decks}
        for future in as_completed(futures):
            res = future.result()
            deck = res["deck"]
            results[deck] = res
            completed += 1

            status_icon = "✓" if res["generated"] else ("~" if res["status"] == "DIFF" else "✗")
            stat_str = "GENERATED" if res["generated"] else res["status"]
            print(f"[{completed:4d}/{total:4d}] {deck:<28} -> {status_icon} {stat_str:<10} ({res['best_solver']}, {res['time']:.2f}s) {res['detail']}")

    total_wall = time.perf_counter() - t_start

    # Summary calculations
    gen_count = sum(1 for r in results.values() if r["generated"])
    diff_count = sum(1 for r in results.values() if not r["generated"] and r["status"] == "DIFF")
    fail_count = sum(1 for r in results.values() if not r["generated"] and r["status"] in ["FAIL", "TIMEOUT", "ERROR"])

    # 1. Write CSV Report
    with open(REPORT_CSV, "w", newline="", encoding="utf-8") as cf:
        writer = csv.writer(cf, delimiter=";")
        writer.writerow(["Deck", "JSON_Reference_Generated", "Verified_Solver", "Status", "Detail", "Max_Rel_Error_Pct", "Time_s", "All_Solver_Statuses"])
        for d in sorted(results.keys()):
            r = results[d]
            writer.writerow([
                d,
                "YES" if r["generated"] else "NO",
                r["best_solver"],
                r["status"],
                r["detail"],
                f"{r['max_rel_err']:.6f}" if r["max_rel_err"] > 0 else "0.0",
                f"{r['time']:.2f}",
                str(r["all_attempts"])
            ])

    # 2. Write Markdown Report
    with open(REPORT_MD, "w", encoding="utf-8") as mf:
        mf.write("# CalculiX Golden JSON Reference Generation Report\n\n")
        mf.write(f"- **Generation Timestamp:** {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        mf.write(f"- **Total Decks Evaluated:** {total}\n")
        mf.write(f"- **JSON References Successfully Created:** {gen_count} / {total} ({(gen_count/total*100):.1f}%)\n")
        mf.write(f"- **Pending Numerical Discrepancies (DIFF):** {diff_count}\n")
        mf.write(f"- **Pending Solver Errors / Legacy Failures (FAIL):** {fail_count}\n")
        mf.write(f"- **Total Wall Time:** {total_wall:.2f}s across {args.workers} workers\n\n")

        mf.write("## 📋 Summary Overview\n\n")
        mf.write("| Metric | Count | Percentage |\n")
        mf.write("| :--- | :---: | :---: |\n")
        mf.write(f"| **Verified Golden References (`.json.ref`)** | **{gen_count}** | **{(gen_count/total*100):.1f}%** |\n")
        mf.write(f"| **Decks with Legacy Numerical Diffs (`DIFF`)** | {diff_count} | {(diff_count/total*100):.1f}% |\n")
        mf.write(f"| **Decks with Solver Failures / Missing Files** | {fail_count} | {(fail_count/total*100):.1f}% |\n\n")

        mf.write("## ⚠️ Discrepancy & Non-Passing Decks Log\n\n")
        mf.write("The following test decks could not be automatically converted to golden references because their outputs differ from Dr. Guido Dhondt's historical reference baseline files (`.dat.ref` / `.frd.ref`). These require manual inspection or updated upstream baselines:\n\n")
        mf.write("| Test Deck | Status | Best Solver Attempted | Discrepancy Details | Solver Attempts |\n")
        mf.write("| :--- | :---: | :---: | :--- | :--- |\n")

        for d in sorted(results.keys()):
            r = results[d]
            if not r["generated"]:
                icon = "⚠️" if r["status"] == "DIFF" else "❌"
                attempts_str = "<br>".join([f"**{k}**: {v}" for k, v in r["all_attempts"].items()])
                mf.write(f"| `{d}` | {icon} **{r['status']}** | `{r['best_solver']}` | {r['detail']} | {attempts_str} |\n")

        mf.write("\n## 📁 Generated Reference Artifacts\n\n")
        mf.write(f"- Reference Directory : [`test_NewLib/originaltest_json/`](originaltest_json/)\n")
        mf.write(f"- CSV Discrepancy Log : [`test_NewLib/originaltest_json_report.csv`](originaltest_json_report.csv)\n")

    print("\n" + "=" * 80)
    print(" Reference Generation Summary")
    print("=" * 80)
    print(f" * Verified JSON References Generated : {gen_count}/{total} ({(gen_count/total*100):.1f}%)")
    print(f" * Numerical Discrepancies (DIFF)     : {diff_count}")
    print(f" * Solver Failures / Exclusions       : {fail_count}")
    print(f" * Total Wall Time                    : {total_wall:.2f}s")
    print(f"\n[+] References saved in : {OUT_REF_DIR}")
    print(f"[+] Markdown report in  : {REPORT_MD}")
    print(f"[+] CSV log in          : {REPORT_CSV}")
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()
