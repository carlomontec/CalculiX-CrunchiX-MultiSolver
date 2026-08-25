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

    return {
        "success": True,
        "time": ccx_time,
        "wall_time": elapsed,
        "equations": num_eqs,
        "nonzeros": num_nzs,
        "output": output,
    }


def parse_last_displacements(frd_file):
    """Extract sample displacement values from the end of an FRD file."""
    if not frd_file.exists():
        return {}
    disps = {}
    try:
        with open(frd_file, "r") as f:
            lines = f.readlines()
        # Find DISP block entries near end of file
        for line in reversed(lines[-200:]):
            parts = line.strip().split()
            if len(parts) >= 3 and parts[0] == "-1" and parts[1].isdigit():
                try:
                    nid = int(parts[1])
                    val = float(parts[2])
                    disps[nid] = val
                    if len(disps) >= 5:
                        break
                except ValueError:
                    continue
    except Exception:
        pass
    return disps


def main():
    parser = argparse.ArgumentParser(description="CalculiX Solver Benchmark Suite")
    parser.add_argument("--deck", default="beam_benchmark", help="Benchmark input deck name (without .inp)")
    parser.add_argument("--threads", nargs="+", type=int, default=[1, 2, 4, 6], help="Thread counts to evaluate")
    parser.add_argument("--solvers", nargs="+", choices=["SPOOLES", "PARDISO", "MUMPS", "ACCELERATE", "ALL"], default=["SPOOLES", "ACCELERATE"])
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
                results[sname][t] = res["time"]
                print(f"Done: {res['time']:7.4f} s")
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
                row += f"{val:>14.4f}s"
            else:
                row += f"{'N/A':>15}"
        print(row)

    print("-" * len(header))

    # Speedup compared to single-thread SPOOLES
    if "SPOOLES" in results and results["SPOOLES"].get(1):
        spooles_1t = results["SPOOLES"][1]
        print("\nSpeedup vs Single-Thread SPOOLES Baseline (1.00x):")
        for s in results.keys():
            for t in args.threads:
                val = results[s].get(t)
                if val:
                    spd = spooles_1t / val
                    print(f"  * {s:<8} ({t:2d}T): {spd:5.2f}x speedup ({val:.4f}s)")

    print("=" * 70)


if __name__ == "__main__":
    main()
