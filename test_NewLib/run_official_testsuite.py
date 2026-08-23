#!/usr/bin/env python3
"""
CalculiX Multi-Solver Official Verification Suite Runner
=========================================================
Runs Dr. Guido Dhondt's official test suite against multiple direct solvers
(SPOOLES, Intel MKL PARDISO, MUMPS) in parallel with sandboxing and automated
numerical verification directly calling Dr. Dhondt's official datcheck.pl and frdcheck.pl.
"""

import argparse
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

# Repository Paths
SCRIPT_DIR = Path(__file__).resolve().parent
CCX_DIR = SCRIPT_DIR.parent
TEST_DIR = CCX_DIR / "test"

# Available Solver Binaries
EXE_NAME = "CalculiX.exe" if sys.platform in ("win32", "msys", "cygwin") or os.name == "nt" else "CalculiX"

SOLVER_CONFIGS = {
    "SPOOLES": {
        "bin": CCX_DIR / "build_spooles" / EXE_NAME,
        "alt_bin": CCX_DIR / "build" / EXE_NAME,
        "env": {},
        "description": "SPOOLES 2.2 Direct Solver",
    },
    "PARDISO": {
        "bin": CCX_DIR / "build_pardiso" / EXE_NAME,
        "alt_bin": CCX_DIR / "build" / EXE_NAME,
        "env": {
            "MKL_ENABLE_INSTRUCTIONS": "AVX2",
            "MKL_DYNAMIC": "FALSE",
        },
        "description": "Intel oneMKL PARDISO Solver",
    },
    "MUMPS": {
        "bin": CCX_DIR / "build_mumps" / EXE_NAME,
        "alt_bin": CCX_DIR / "build" / EXE_NAME,
        "env": {
            "MKL_THREADING_LAYER": "GNU",
        },
        "description": "MUMPS 5.x Direct Solver",
    },
    "ACCELERATE": {
        "bin": CCX_DIR / "build_accelerate" / EXE_NAME,
        "alt_bin": CCX_DIR / "build" / EXE_NAME,
        "env": {},
        "description": "Apple Accelerate Sparse Direct Solver",
    },
}

# Decks to exclude (known interactive or optimization scripts)
EXCLUDED_DECKS = {
    "circ10pcent.rfn",
    "circ10p.rfn",
    "circ11p.rfn",
    "segmentsmooth.rfn",
    "segmentsmooth2.rfn",
    "beam10psmooth.rfn",
    "contact4tetrefine.rfn",
    "contact4bad.rfn",
    "contact4badnl.rfn",
}


def find_test_decks(patterns=None):
    """Discover all official .inp decks in test/ directory."""
    if not TEST_DIR.exists():
        return []
    decks = []
    for f in sorted(TEST_DIR.glob("*.inp")):
        deck_name = f.stem
        if deck_name in EXCLUDED_DECKS or f.name.endswith(".rfn.inp"):
            continue
        if patterns:
            matched = any(fnmatch.fnmatch(deck_name, p) or fnmatch.fnmatch(f.name, p) for p in patterns)
            if not matched:
                continue
        decks.append(deck_name)
    return decks


def run_single_test(task):
    """Execute a single (deck, solver) job in an isolated sandbox."""
    deck, solver_name, bin_path, threads, custom_env, timeout = task

    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = str(threads)
    env["MKL_NUM_THREADS"] = str(threads)
    env["CCX_NPROC_EQUATION_SOLVER"] = str(threads)
    env["OMP_STACKSIZE"] = "128M"
    env.update(custom_env)

    # Create isolated sandbox directory
    with tempfile.TemporaryDirectory(prefix=f"ccx_{solver_name}_{deck}_") as sandbox:
        sandbox_path = Path(sandbox)

        # Symlink all files from test/ into sandbox so input includes work seamlessly
        for item in TEST_DIR.iterdir():
            if item.is_file():
                dest = sandbox_path / item.name
                try:
                    os.symlink(item, dest)
                except OSError:
                    shutil.copy2(item, dest)

        cmd = [str(bin_path), deck]
        t0 = time.perf_counter()
        try:
            proc = subprocess.run(
                cmd,
                cwd=sandbox_path,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=timeout,
            )
            elapsed = time.perf_counter() - t0
        except subprocess.TimeoutExpired:
            return {
                "deck": deck,
                "solver": solver_name,
                "status": "TIMEOUT",
                "time": timeout,
                "detail": f">{timeout}s",
            }
        except Exception as e:
            return {
                "deck": deck,
                "solver": solver_name,
                "status": "ERROR",
                "time": 0.0,
                "detail": str(e),
            }

        if proc.returncode != 0:
            return {
                "deck": deck,
                "solver": solver_name,
                "status": "FAIL",
                "time": elapsed,
                "detail": f"Exit {proc.returncode}",
                "stdout": proc.stdout,
            }

        # Substructure conversion if applicable
        if deck in ["substructure", "substructure2", "beammrlin_diff", "beammrlin_same"]:
            mtx_f = sandbox_path / f"{deck}.mtx"
            dat_f = sandbox_path / f"{deck}.dat"
            if mtx_f.exists():
                with open(mtx_f, "r") as fin, open(dat_f, "w") as fout:
                    fout.write(fin.read().replace(",", " "))

        # Verify using Dr. Dhondt's official perl scripts
        dat_ref = TEST_DIR / f"{deck}.dat.ref"
        frd_ref = TEST_DIR / f"{deck}.frd.ref"
        dat_test = sandbox_path / f"{deck}.dat"
        frd_test = sandbox_path / f"{deck}.frd"

        dat_res = ""
        if dat_ref.exists() and dat_test.exists():
            cp = subprocess.run(
                ["perl", str(TEST_DIR / "datcheck.pl"), deck],
                cwd=sandbox_path,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            dat_res = cp.stdout.strip()

        frd_res = ""
        if frd_ref.exists() and frd_test.exists():
            cp = subprocess.run(
                ["perl", str(TEST_DIR / "frdcheck.pl"), deck],
                cwd=sandbox_path,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            frd_res = cp.stdout.strip()

        if "deviation in file" in dat_res:
            status = "DIFF"
            err_line = ""
            for l in dat_res.splitlines():
                if "relative error" in l:
                    err_line = l.strip()
                    break
            detail = f"DAT DIFF ({err_line})" if err_line else "DAT DIFF"
        elif "deviation in file" in frd_res:
            status = "DIFF"
            err_line = ""
            for l in frd_res.splitlines():
                if "relative error" in l:
                    err_line = l.strip()
                    break
            detail = f"FRD DIFF ({err_line})" if err_line else "FRD DIFF"
        else:
            status = "PASS"
            detail = "OK"

        return {
            "deck": deck,
            "solver": solver_name,
            "status": status,
            "time": elapsed,
            "detail": detail,
        }


def main():
    parser = argparse.ArgumentParser(description="CalculiX Multi-Solver Official Verification Suite")
    parser.add_argument("--pattern", nargs="+", help="Glob pattern(s) to filter test decks (e.g. 'achtel*' 'beam*')")
    parser.add_argument("--solvers", nargs="+", choices=["SPOOLES", "PARDISO", "MUMPS", "ACCELERATE", "ALL"], default=["ALL"])
    parser.add_argument("--threads-per-job", type=int, default=2, help="OpenMP threads per job (default: 2)")
    parser.add_argument("--max-workers", type=int, default=None, help="Max concurrent workers (default: physical_cores // threads_per_job)")
    parser.add_argument("--timeout", type=int, default=60, help="Per-test timeout in seconds (default: 60s)")
    parser.add_argument("--limit", type=int, default=None, help="Limit total number of decks to test")
    args = parser.parse_args()

    # Discover decks
    decks = find_test_decks(args.pattern)
    if args.limit:
        decks = decks[:args.limit]

    if not decks:
        print("[-] No test decks found matching criteria.")
        sys.exit(1)

    # Determine active solvers
    target_solvers = list(SOLVER_CONFIGS.keys()) if "ALL" in args.solvers else args.solvers
    active_solvers = {}
    for s in target_solvers:
        cfg = SOLVER_CONFIGS[s]
        bpath = cfg["bin"]
        if not bpath.exists() and cfg.get("alt_bin") and cfg["alt_bin"].exists():
            bpath = cfg["alt_bin"]
        if bpath.exists():
            active_solvers[s] = {**cfg, "bin": bpath}
        else:
            print(f"[!] Warning: Solver '{s}' binary not found at {cfg['bin']}. Skipping.")

    if not active_solvers:
        print("[-] No valid solver binaries found. Please build at least one solver target.")
        sys.exit(1)

    # Concurrency calculations
    cpu_count = os.cpu_count() or 4
    threads_per_job = max(1, args.threads_per_job)
    max_workers = args.max_workers or max(1, cpu_count // threads_per_job)

    print("=" * 80)
    print(" CalculiX Multi-Solver Official Verification Suite")
    print("=" * 80)
    print(f" Test Decks       : {len(decks)} discovered in test/")
    print(f" Active Solvers   : {', '.join(active_solvers.keys())}")
    print(f" Threads / Job    : {threads_per_job}")
    print(f" Parallel Workers : {max_workers} concurrent processes")
    print(f" Total Runs       : {len(decks) * len(active_solvers)} test executions")
    print("=" * 80 + "\n")

    # Build task list
    tasks = []
    for d in decks:
        for sname, sinfo in active_solvers.items():
            tasks.append((d, sname, sinfo["bin"], threads_per_job, sinfo["env"], args.timeout))

    results = {d: {} for d in decks}
    completed_count = 0
    total_tasks = len(tasks)
    t_start = time.perf_counter()

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(run_single_test, t): t for t in tasks}

        for fut in as_completed(futures):
            res = fut.result()
            deck = res["deck"]
            sname = res["solver"]
            results[deck][sname] = res
            completed_count += 1

            status_icon = "✓" if res["status"] == "PASS" else "✗"
            print(f"[{completed_count:4d}/{total_tasks:4d}] {sname:<8} {deck:<25} -> {status_icon} {res['status']:<6} ({res['time']:5.2f}s) {res['detail']}")

    total_wall = time.perf_counter() - t_start

    # Summary Report Table
    print("\n" + "=" * 80)
    print(" Official Test Suite Summary Matrix")
    print("=" * 80)

    header = f"{'Test Deck':<28}" + "".join([f"{s:>16}" for s in active_solvers.keys()])
    print(header)
    print("-" * len(header))

    stats = {s: {"PASS": 0, "DIFF": 0, "FAIL": 0, "TIMEOUT": 0, "ERROR": 0, "TOTAL_TIME": 0.0} for s in active_solvers}

    for d in decks:
        row = f"{d:<28}"
        for s in active_solvers.keys():
            res = results[d].get(s)
            if res:
                st = res["status"]
                tm = res["time"]
                stats[s][st] = stats[s].get(st, 0) + 1
                stats[s]["TOTAL_TIME"] += tm
                row += f"{st:>9} ({tm:4.2f}s)"
            else:
                row += f"{'N/A':>16}"
        print(row)

    print("-" * len(header))
    print("\n" + "=" * 80)
    print(" Solver Aggregate Statistics:")
    print("=" * 80)
    any_failures = False
    for s in active_solvers.keys():
        st = stats[s]
        total_runs = len(decks)
        pass_rate = (st["PASS"] / total_runs * 100) if total_runs else 0
        if st["FAIL"] > 0 or st["ERROR"] > 0 or st["TIMEOUT"] > 0:
            any_failures = True
        print(f"  * {s:<8}: {st['PASS']:3d} PASS | {st['DIFF']:2d} DIFF | {st['FAIL']:2d} FAIL | {st['TIMEOUT']:2d} TIMEOUT | Cumul Time: {st['TOTAL_TIME']:6.2f}s | Pass Rate: {pass_rate:5.1f}% ({st['PASS']}/{total_runs})")
    print(f"\nTotal Suite Wall-Clock Time: {total_wall:.2f} s across {max_workers} workers")
    print("=" * 80)

    # Print failure diagnostics
    failures = [(d, s, res) for d in decks for s, res in results[d].items() if res.get("status") in ("FAIL", "ERROR") and res.get("stdout")]
    if failures:
        print("\n" + "=" * 80)
        print(" ❌ Diagnostic Output for Failed Test Executions:")
        print("=" * 80)
        for d, s, res in failures:
            print(f"\n--- [{s}] {d} ({res['detail']}) ---")
            lines = res["stdout"].strip().splitlines()
            tail_lines = lines[-40:] if len(lines) > 40 else lines
            print("\n".join(tail_lines))
        print("=" * 80 + "\n")

    # Write GitHub Step Summary if running in CI
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        try:
            with open(step_summary, "a", encoding="utf-8") as f:
                f.write(f"### 🧪 CalculiX Verification Results ({', '.join(active_solvers.keys())})\n\n")
                f.write("| Solver | Passed | Diff | Failed | Timeout | Total Time | Pass Rate |\n")
                f.write("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |\n")
                for s in active_solvers.keys():
                    st = stats[s]
                    total_runs = len(decks)
                    pass_rate = (st["PASS"] / total_runs * 100) if total_runs else 0
                    badge = "✅" if pass_rate == 100.0 else ("⚠️" if pass_rate >= 90.0 else "❌")
                    f.write(f"| **{s}** | {st['PASS']} | {st['DIFF']} | {st['FAIL']} | {st['TIMEOUT']} | {st['TOTAL_TIME']:.2f}s | **{badge} {pass_rate:.1f}%** ({st['PASS']}/{total_runs}) |\n")
                
                f.write("\n<details><summary><b>Detailed Per-Deck Results</b></summary>\n\n")
                f.write("| Test Deck | " + " | ".join([f"{s} Status" for s in active_solvers.keys()]) + " |\n")
                f.write("| :--- | " + " | ".join([":---:" for _ in active_solvers]) + " |\n")
                for d in decks:
                    deck_row = f"| `{d}` | "
                    for s in active_solvers.keys():
                        res = results[d].get(s)
                        if res:
                            icon = "✅" if res["status"] == "PASS" else "❌"
                            deck_row += f"{icon} {res['status']} ({res['time']:.2f}s) | "
                        else:
                            deck_row += "N/A | "
                    f.write(deck_row + "\n")
                f.write("\n</details>\n\n")
        except Exception as e:
            print(f"[!] Note: Could not write GitHub Step Summary: {e}")

    # Compute overall status across all solvers
    total_fails = sum(st["FAIL"] + st["ERROR"] + st["TIMEOUT"] for st in stats.values())
    total_diffs = sum(st["DIFF"] for st in stats.values())
    total_passes = sum(st["PASS"] for st in stats.values())
    total_all = sum(len(decks) for _ in active_solvers)
    overall_pass_rate = (total_passes / total_all * 100) if total_all else 0

    if total_fails > 0:
        # Exit 2: Execution error / crash (FAIL, TIMEOUT, ERROR)
        fail_details = ", ".join([f"{s}: {stats[s]['FAIL']} fail" for s in active_solvers if stats[s]['FAIL'] > 0])
        print(f"::error title=Test Suite Failure (Crashes)::Overall Pass Rate: {overall_pass_rate:.1f}% ({total_passes}/{total_all}). {total_fails} test(s) failed or crashed ({fail_details}).")
        sys.exit(2)
    elif total_diffs > 0:
        # Exit 1: Numerical differences / assertion failure (DIFF only)
        diff_details = ", ".join([f"{s}: {stats[s]['DIFF']} diff" for s in active_solvers if stats[s]['DIFF'] > 0])
        print(f"::warning title=Test Suite Notice (Numerical Diffs)::Overall Pass Rate: {overall_pass_rate:.1f}% ({total_passes}/{total_all}). {total_diffs} test(s) had numerical differences ({diff_details}).")
        sys.exit(1)
    else:
        # Exit 0: 100% Pass
        print(f"::notice title=Test Suite Success::Overall Pass Rate: 100.0% ({total_passes}/{total_all}). All verification tests passed cleanly!")
        sys.exit(0)


if __name__ == "__main__":
    main()
