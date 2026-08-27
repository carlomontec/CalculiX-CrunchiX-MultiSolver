#!/usr/bin/env python3
"""
CalculiX Solver Benchmark Suite
===============================
Automated performance comparison between direct sparse solvers (Apple Accelerate, MUMPS, SPOOLES, Intel MKL PARDISO)
in CalculiX CrunchiX (CCX).
Runs both Static Analysis and Modal Eigenvalue Extraction (10 Modes) with physics control verification.
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
    "ACCELERATE": {
        "bin": CCX_DIR / "build_accelerate" / "CalculiX",
        "alt_bin": CCX_DIR / "build" / "CalculiX",
        "env": {},
        "description": "Apple Accelerate Sparse Direct Solver (macOS Native)",
    },
    "MUMPS": {
        "bin": CCX_DIR / "build_mumps" / "CalculiX",
        "alt_bin": CCX_DIR / "build_mumps2" / "CalculiX",
        "env": {},
        "description": "MUMPS Direct Sparse Solver (High Performance Direct)",
    },
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
}

BENCHMARK_CASES = [
    {
        "id": "static",
        "name": "Static Cantilever Beam",
        "deck": "beam_benchmark",
        "description": "Linear static elasticity under surface pressure load",
    },
    {
        "id": "modal",
        "name": "Modal Eigenvalue Extraction",
        "deck": "beam_modal",
        "description": "Natural frequencies and mode shapes (10 modes, ARPACK shift-and-invert)",
    },
]

RESULT_NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?"


def find_cgx_binary():
    """Locate the CGX binary in workspace or PATH."""
    candidates = [
        PROJECT_DIR / "cgx" / "bin" / "cgx_glfw",
        PROJECT_DIR / "cgx" / "bin" / "cgx",
        PROJECT_DIR / "cgx" / "CalculiX-CGX-New3D" / "bin" / "cgx_glfw",
        PROJECT_DIR / "bin" / "cgx_glfw",
        Path("/Users/carlo/code/CalculiX/cgx/bin/cgx_glfw"),
        Path("/Users/carlo/code/CalculiX/cgx/bin/cgx"),
        Path("/Users/carlo/code/CalculiX/cgx/CalculiX-CGX-New3D/bin/cgx_glfw"),
        Path("/Users/carlo/Library/CloudStorage/OneDrive-Personal/code/CalculiX/cgx/CalculiX-CGX-New3D/bin/cgx_glfw"),
        shutil.which("cgx_glfw"),
        shutil.which("cgx"),
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return Path(c)
    return None


def ensure_mesh(cgx_bin):
    """Ensure required mesh files exist for the cantilever beam benchmarks."""
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


def parse_eigenvalue_table(dat_file):
    """Read eigenvalue records from .dat file."""
    if not dat_file.exists():
        return []
    try:
        lines = dat_file.read_text(errors="ignore").splitlines()
    except OSError:
        return []

    table_start = None
    for index, line in enumerate(lines):
        if "e i g e n v a l u e   o u t p u t" in line.lower():
            table_start = index
            break
    if table_start is None:
        return []

    modes = []
    for line in lines[table_start + 1:]:
        line_clean = line.strip()
        if not line_clean:
            if modes:
                break
            continue
        if any(h in line_clean.lower() for h in ["mode no", "frequency", "rad/time", "cycles/time", "participation"]):
            if "participation" in line_clean.lower() and modes:
                break
            continue
        numbers = re.findall(RESULT_NUMBER, line_clean)
        if len(numbers) >= 4:
            mode_idx = int(float(numbers[0]))
            eigenvalue = float(numbers[1])
            omega = float(numbers[2])
            freq_hz = float(numbers[3])
            modes.append({
                "mode": mode_idx,
                "eigenvalue": eigenvalue,
                "omega": omega,
                "freq_hz": freq_hz,
            })
    return modes


def parse_result_metrics(dat_file, is_modal=False):
    """Extract physics metrics for verification."""
    if is_modal:
        modes = parse_eigenvalue_table(dat_file)
        mode1 = modes[0] if modes else None
        return {
            "modes": modes,
            "mode_1_freq_hz": mode1["freq_hz"] if mode1 else None,
            "mode_1_omega": mode1["omega"] if mode1 else None,
            "max_displacement": None,
            "max_von_mises": None,
        }
    else:
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
        return {
            "modes": [],
            "mode_1_freq_hz": None,
            "mode_1_omega": None,
            "max_displacement": max_displacement,
            "max_von_mises": max_von_mises,
        }


def run_solver(solver_name, bin_path, deck_name, is_modal, threads, custom_env):
    """Run a single solver execution and parse metrics."""
    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = str(threads)
    env["MKL_NUM_THREADS"] = str(threads)
    env["CCX_NPROC_EQUATION_SOLVER"] = str(threads)
    env["VECLIB_MAXIMUM_THREADS"] = str(threads)
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

    result_metrics = parse_result_metrics(TEST_DIR / f"{deck_name}.dat", is_modal=is_modal)

    return {
        "success": True,
        "time": ccx_time,
        "wall_time": elapsed,
        "equations": num_eqs,
        "nonzeros": num_nzs,
        **result_metrics,
        "output": output,
    }


def main():
    parser = argparse.ArgumentParser(description="CalculiX Solver Benchmark Suite (Static & Modal)")
    parser.add_argument("--threads", nargs="+", type=int, default=[1, 2, 4, 6], help="Thread counts to evaluate")
    parser.add_argument("--solvers", nargs="+", choices=["ACCELERATE", "MUMPS", "SPOOLES", "PARDISO", "ALL"], default=["ACCELERATE", "SPOOLES"])
    parser.add_argument("--markdown", action="store_true", help="Output results in Markdown format")
    args = parser.parse_args()

    active_solvers = list(DEFAULT_SOLVERS.keys()) if "ALL" in args.solvers else args.solvers

    print("=" * 78)
    print(" CalculiX CrunchiX (CCX) Solver Benchmark Suite")
    print(" Benchmarking: Static Elasticity & Modal Eigenvalue Extraction (10 Modes)")
    print("=" * 78)
    print(f" Threads : {', '.join(map(str, args.threads))}")
    print(f" Solvers : {', '.join(active_solvers)}")
    print("-" * 78)

    cgx_bin = find_cgx_binary()
    ensure_mesh(cgx_bin)

    all_case_results = {}

    for case in BENCHMARK_CASES:
        case_id = case["id"]
        deck_name = case["deck"]
        is_modal = (case_id == "modal")

        print(f"\n{'#' * 78}")
        print(f" CASE: {case['name']} ({deck_name}.inp)")
        print(f" {case['description']}")
        print(f"{'#' * 78}")

        case_results = {}

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
            case_results[sname] = {}

            for t in args.threads:
                print(f"    -> Running with {t:2d} thread(s)... ", end="", flush=True)
                res = run_solver(sname, bin_path, deck_name, is_modal, t, sinfo["env"])
                if res["success"]:
                    case_results[sname][t] = res
                    if is_modal:
                        f1 = res["mode_1_freq_hz"]
                        ctrl_text = f"Mode 1 f={f1:.4f} Hz" if f1 is not None else "Mode 1=N/A"
                    else:
                        displacement = res["max_displacement"]
                        von_mises = res["max_von_mises"]
                        disp_text = f"max|U|={displacement:.6e}" if displacement is not None else "max|U|=N/A"
                        stress_text = f"max VM={von_mises:.6e}" if von_mises is not None else "max VM=N/A"
                        ctrl_text = f"{disp_text}, {stress_text}"
                    print(f"Done: {res['time']:7.4f} s  ({ctrl_text})")
                else:
                    case_results[sname][t] = None
                    print(f"FAILED ({res.get('error', 'unknown error')})")

        all_case_results[case_id] = case_results

    # Summary Tables
    for case in BENCHMARK_CASES:
        case_id = case["id"]
        case_results = all_case_results.get(case_id, {})
        is_modal = (case_id == "modal")

        print("\n" + "=" * 78)
        print(f" Benchmark Summary Table: {case['name']}")
        print("=" * 78)

        active_in_case = [s for s in case_results.keys() if any(case_results[s].values())]
        if not active_in_case:
            print("No solver results available.")
            continue

        header = f"{'Threads':<10}" + "".join([f"{s:>16}" for s in active_in_case])
        print(header)
        print("-" * len(header))

        for t in args.threads:
            row = f"{t:<10}"
            for s in active_in_case:
                val = case_results[s].get(t)
                if val is not None:
                    row += f"{val['time']:>15.4f}s"
                else:
                    row += f"{'N/A':>16}"
            print(row)

        print("-" * len(header))

        # Control value verification
        print(f"\nPhysics Control Metrics ({case['name']}):")
        for s in active_in_case:
            first_valid = next((case_results[s][t] for t in args.threads if case_results[s].get(t)), None)
            if first_valid:
                if is_modal:
                    print(f"  * {s:<12}: Mode 1 = {first_valid['mode_1_freq_hz']:.4f} Hz (omega = {first_valid['mode_1_omega']:.4f} rad/s)")
                else:
                    print(f"  * {s:<12}: Max |U| = {first_valid['max_displacement']:.6e} mm, Max VM Stress = {first_valid['max_von_mises']:.6e} MPa")

        # Speedup compared to single-thread SPOOLES (if available) or single-thread baseline
        base_solver = "SPOOLES" if ("SPOOLES" in case_results and case_results["SPOOLES"].get(1)) else active_in_case[0]
        if case_results.get(base_solver) and case_results[base_solver].get(1):
            base_time = case_results[base_solver][1]["time"]
            print(f"\nSpeedup vs Single-Thread {base_solver} Baseline (1.00x = {base_time:.4f}s):")
            for s in active_in_case:
                for t in args.threads:
                    val = case_results[s].get(t)
                    if val:
                        spd = base_time / val["time"]
                        print(f"  * {s:<12} ({t:2d}T): {spd:5.2f}x speedup ({val['time']:.4f}s)")

    print("\n" + "=" * 78)


if __name__ == "__main__":
    main()
