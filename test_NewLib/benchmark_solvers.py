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
import json
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
        if not fbl_file.exists():
            print(f"[!] Error: Meshing definition {fbl_file.name} is missing.")
            return False
        if not cgx_bin:
            print(f"[!] Warning: {msh_file.name} missing and cgx binary not found.")
            return False
        print(f"[*] Generating mesh via CGX batch mode ({fbl_file.name})...")
        res = subprocess.run(
            [str(cgx_bin), "-bg", str(fbl_file.name)],
            cwd=TEST_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if res.returncode != 0 or not msh_file.exists():
            print(f"[!] CGX meshing failed:\n{res.stdout}")
            return False
        print("[+] Mesh generated successfully.")
    return True


def parse_json_metrics(json_file, is_modal=False):
    """Read physics and system metrics directly from CalculiX JSON export."""
    if not json_file.exists():
        raise FileNotFoundError(f"Required JSON export file missing: {json_file.name}")

    with open(json_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    meta = data.get("meta", {})
    timings = meta.get("timings", {})
    stats = meta.get("mesh_statistics", {})
    steps = data.get("steps", [])
    step1 = steps[0] if steps else {}

    ccx_time = timings.get("total_wall_time_s", 0.0)
    num_eqs = stats.get("equations")
    num_nodes = stats.get("nodes")
    num_elements = stats.get("elements")

    if is_modal:
        modes = step1.get("modes", [])
        mode1 = modes[0] if modes else None
        return {
            "time": ccx_time,
            "equations": num_eqs,
            "nodes": num_nodes,
            "elements": num_elements,
            "modes": modes,
            "mode_1_freq_hz": mode1["frequency_hz"] if mode1 else None,
            "mode_1_omega": mode1["frequency_rad_s"] if mode1 else None,
            "total_effective_mass": step1.get("total_effective_mass"),
            "fraction_of_totals": step1.get("fraction_of_totals"),
            "max_displacement": None,
            "max_von_mises": None,
        }
    else:
        increments = step1.get("increments", [])
        inc_last = increments[-1] if increments else {}
        node_sets = inc_last.get("node_sets", {})
        elem_sets = inc_last.get("element_sets", {})

        max_displacement = None
        for nset_key, nset_val in node_sets.items():
            if nset_val.get("field") == "U":
                vals = nset_val.get("values", [])
                if vals:
                    disp_norms = [(u1**2 + u2**2 + u3**2)**0.5 for u1, u2, u3 in vals]
                    max_d = max(disp_norms)
                    max_displacement = max(max_displacement or 0.0, max_d)

        max_von_mises = None
        for eset_key, eset_val in elem_sets.items():
            if eset_val.get("field") == "S":
                vals = eset_val.get("values", [])
                for item in vals:
                    s = item.get("s", [])
                    if len(s) >= 6:
                        sxx, syy, szz, sxy, syz, szx = s[:6]
                        vm = (0.5 * ((sxx - syy)**2 + (syy - szz)**2 + (szz - sxx)**2) + 3.0 * (sxy**2 + syz**2 + szx**2))**0.5
                        max_von_mises = max(max_von_mises or 0.0, vm)

        return {
            "time": ccx_time,
            "equations": num_eqs,
            "nodes": num_nodes,
            "elements": num_elements,
            "modes": [],
            "mode_1_freq_hz": None,
            "mode_1_omega": None,
            "max_displacement": max_displacement,
            "max_von_mises": max_von_mises,
        }


def run_solver(solver_name, bin_path, deck_name, is_modal, threads, custom_env):
    """Run a single solver execution and parse metrics directly from JSON export."""
    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = str(threads)
    env["MKL_NUM_THREADS"] = str(threads)
    env["CCX_NPROC_EQUATION_SOLVER"] = str(threads)
    env["VECLIB_MAXIMUM_THREADS"] = str(threads)
    env["CCX_JSON"] = "1"
    env.update(custom_env)

    # Clean previous JSON artifact if present
    json_path = TEST_DIR / f"{deck_name}.json"
    if json_path.exists():
        try:
            json_path.unlink()
        except OSError:
            pass

    cmd = [str(bin_path), "-j", deck_name]
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

    if not json_path.exists():
        return {
            "success": False,
            "error": f"Missing expected JSON export: {json_path.name}",
            "time": None,
            "output": output,
        }

    try:
        metrics = parse_json_metrics(json_path, is_modal=is_modal)
    except Exception as e:
        return {
            "success": False,
            "error": f"JSON parse failure: {e}",
            "time": None,
            "output": output,
        }

    # Clean up generated JSON after successful extraction
    try:
        json_path.unlink()
    except OSError:
        pass

    return {
        "success": True,
        "wall_time": elapsed,
        **metrics,
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
