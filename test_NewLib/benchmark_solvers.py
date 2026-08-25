#!/usr/bin/env python3
"""
CalculiX Solver Benchmark Suite
===============================
Automated performance comparison between direct sparse solvers (SPOOLES, Intel MKL PARDISO, MUMPS)
in CalculiX CrunchiX (CCX).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Base paths
TEST_DIR = Path(__file__).resolve().parent
CCX_DIR = TEST_DIR.parent
PROJECT_DIR = CCX_DIR.parent

# Solver definitions and environment overrides
DEFAULT_SOLVERS = {
    "SPOOLES": {
        "bin": CCX_DIR / "build_spooles" / "CalculiX",
        "alt_bin": CCX_DIR / "src" / "CalculiX",
        "env": {},
        "description": "SPOOLES 2.2 Direct Sparse Solver (Built-in)",
    },
    "PARDISO": {
        "bin": CCX_DIR / "build_pardiso" / "CalculiX",
        "alt_bin": CCX_DIR / "src" / "CalculiX",
        "env": {
            "MKL_ENABLE_INSTRUCTIONS": "AVX2",
            "MKL_DYNAMIC": "FALSE",
        },
        "description": "Intel oneMKL PARDISO Multi-Threaded Solver",
    },
    "MUMPS": {
        "bin": CCX_DIR / "build_mumps" / "CalculiX",
        "alt_bin": None,
        "env": {},
        "description": "MUMPS Direct Sparse Solver (Phase 2 Target)",
    },
    "ACCELERATE": {
        "bin": CCX_DIR / "build_accelerate" / "CalculiX",
        "alt_bin": CCX_DIR / "build" / "CalculiX",
        "env": {},
        "description": "Apple Accelerate Sparse Direct Solver (macOS Native)",
    },
}


def find_cgx_binary():
    """Locate the CGX binary in workspace or PATH."""
    candidates = [
        PROJECT_DIR / "bin" / "cgx_glfw",
        PROJECT_DIR / "CGX" / "bin" / "cgx_glfw",
        shutil.which("cgx_glfw"),
        shutil.which("cgx"),
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return Path(c)
    return None


def ensure_mesh(deck_name, cgx_bin):
    """Ensure required mesh files exist for the benchmark deck."""
    if deck_name == "beam_benchmark":
        msh_file = TEST_DIR / "all.msh"
        fbl_file = TEST_DIR / "beam_10k.fbl"
        if not msh_file.exists():
            if not cgx_bin:
                print(f"[!] Warning: {msh_file} missing and cgx binary not found.")
                return False
            print(f"[*] Generating mesh via CGX batch mode ({fbl_file.name})...")
            res = subprocess.run(
                [str(cgx_bin), "-bg", str(fbl_file.name)],
                cwd=TEST_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if res.returncode != 0:
                print(f"[!] CGX meshing failed:\n{res.stdout}")
                return False
            print("[+] Mesh generated successfully.")
    return True


def run_solver(solver_name, bin_path, deck_name, threads, custom_env):
    """Run a single solver execution and parse metrics."""
    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = str(threads)
    env["MKL_NUM_THREADS"] = str(threads)
    env["CCX_NPROC_EQUATION_SOLVER"] = str(threads)
    env.update(custom_env)

    cmd = [str(bin_path), deck_name]
    t0 = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            cwd=TEST_DIR,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        )
        elapsed = time.perf_counter() - t0
        output = proc.stdout
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timeout (>300s)", "time": None}
    except Exception as e:
        return {"success": False, "error": str(e), "time": None}

    if proc.returncode != 0:
        return {"success": False, "error": f"Exit code {proc.returncode}", "output": output, "time": None}

    # Parse CCX internal metrics
    eq_match = re.search(r"number of equations\s*\n\s*(\d+)", output)
    nz_match = re.search(r"number of nonzero lower triangular matrix elements\s*\n\s*(\d+)", output)
    time_match = re.search(r"Total CalculiX Time:\s*([\d\.]+)", output)

    ccx_time = float(time_match.group(1)) if time_match else elapsed
    num_eqs = int(eq_match.group(1)) if eq_match else None
    num_nzs = int(nz_match.group(1)) if nz_match else None

    result_metrics = parse_result_metrics(TEST_DIR / f"{deck_name}.dat")

    return {
        "success": True,
        "time": ccx_time,
        "wall_time": elapsed,
        "equations": num_eqs,
        "nonzeros": num_nzs,
        **result_metrics,
        "output": output,
    }


RESULT_NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?"


def parse_dat_table(dat_file, heading, value_count):
    """Read numeric rows from the final CalculiX text-output table."""
    if not dat_file.exists():
        return []
    try:
        lines = dat_file.read_text(errors="ignore").splitlines()
    except OSError:
        return []

    table_start = None
    for index, line in enumerate(lines):
        if heading.lower() in line.lower():
            table_start = index
    if table_start is None:
        return []

    records = []
    for line in lines[table_start + 1:]:
        if line.strip() and not re.match(r"\s*(?:\d+|[-+]?\d)", line):
            if records:
                break
            continue
        numbers = re.findall(RESULT_NUMBER, line)
        if len(numbers) >= value_count + 1:
            records.append([float(value) for value in numbers[1:value_count + 1]])
    return records


def parse_result_metrics(dat_file):
    """Calculate NNTIP maximum displacement and Eall von Mises stress."""
    displacements = parse_dat_table(dat_file, "displacements", 3)
    stresses = parse_dat_table(dat_file, "stresses", 6)
    max_displacement = max(
        (sum(component * component for component in values) ** 0.5 for values in displacements),
        default=None,
    )
    max_von_mises = None
    for sxx, syy, szz, sxy, syz, szx in stresses:
        von_mises = (
            0.5 * ((sxx - syy) ** 2 + (syy - szz) ** 2 + (szz - sxx) ** 2)
            + 3.0 * (sxy ** 2 + syz ** 2 + szx ** 2)
        ) ** 0.5
        max_von_mises = max(max_von_mises or 0.0, von_mises)
    return {"max_displacement": max_displacement, "max_von_mises": max_von_mises}


def main():
    parser = argparse.ArgumentParser(description="CalculiX Solver Benchmark Suite")
    parser.add_argument("--deck", default="beam_benchmark", help="Benchmark input deck name (without .inp)")
    parser.add_argument("--threads", nargs="+", type=int, default=[1, 2, 4, 6, 8], help="Thread counts to evaluate")
    parser.add_argument("--solvers", nargs="+", choices=["SPOOLES", "PARDISO", "MUMPS", "ACCELERATE", "ALL"], default=["SPOOLES", "MUMPS"])
    parser.add_argument("--markdown", action="store_true", help="Output results in Markdown format")
    args = parser.parse_args()

    active_solvers = list(DEFAULT_SOLVERS.keys()) if "ALL" in args.solvers else args.solvers

    print("=" * 70)
    print(" CalculiX CrunchiX (CCX) Solver Benchmark Suite")
    print("=" * 70)
    print(f" Input Deck : {args.deck}.inp")
    print(f" Threads    : {', '.join(map(str, args.threads))}")
    print(f" Solvers    : {', '.join(active_solvers)}")
    print("-" * 70)

    cgx_bin = find_cgx_binary()
    ensure_mesh(args.deck, cgx_bin)

    results = {}
    baseline_time = None

    for sname in active_solvers:
        sinfo = DEFAULT_SOLVERS.get(sname)
        if not sinfo:
            continue

        bin_path = sinfo["bin"]
        if not bin_path or not bin_path.exists():
            if sinfo.get("alt_bin") and Path(sinfo["alt_bin"]).exists():
                bin_path = Path(sinfo["alt_bin"])
            else:
                print(f"[-] Solver '{sname}' binary not found at {sinfo['bin']}. Skipping.")
                continue

        print(f"\n[*] Benchmarking {sname} ({sinfo['description']})...")
        results[sname] = {}

        for t in args.threads:
            print(f"    -> Running with {t:2d} thread(s)... ", end="", flush=True)
            res = run_solver(sname, bin_path, args.deck, t, sinfo["env"])
            if res["success"]:
                results[sname][t] = res
                displacement = res["max_displacement"]
                von_mises = res["max_von_mises"]
                displacement_text = f"max|U|={displacement:.6e}" if displacement is not None else "max|U|=N/A"
                stress_text = f"max VM={von_mises:.6e}" if von_mises is not None else "max VM=N/A"
                print(f"Done: {res['time']:7.4f} s  ({displacement_text}, {stress_text})")
                if baseline_time is None and t == 1:
                    baseline_time = res["time"]
            else:
                results[sname][t] = None
                print(f"FAILED ({res.get('error', 'unknown error')})")

    # Display summary table
    print("\n" + "=" * 70)
    print(f" Benchmark Summary Table: {args.deck}")
    print("=" * 70)

    header = f"{'Threads':<10}" + "".join([f"{s:>15}" for s in results.keys()])
    print(header)
    print("-" * len(header))

    for t in args.threads:
        row = f"{t:<10}"
        for s in results.keys():
            val = results[s].get(t)
            if val is not None:
                row += f"{val['time']:>14.4f}s"
            else:
                row += f"{'N/A':>15}"
        print(row)

    print("-" * len(header))

    # Speedup compared to single-thread SPOOLES
    if "SPOOLES" in results and results["SPOOLES"].get(1):
        spooles_1t = results["SPOOLES"][1]["time"]
        print("\nSpeedup vs Single-Thread SPOOLES Baseline (1.00x):")
        for s in results.keys():
            for t in args.threads:
                val = results[s].get(t)
                if val:
                    spd = spooles_1t / val["time"]
                    print(f"  * {s:<8} ({t:2d}T): {spd:5.2f}x speedup ({val['time']:.4f}s)")

    print("=" * 70)


if __name__ == "__main__":
    main()
