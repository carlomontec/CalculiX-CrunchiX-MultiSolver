#!/usr/bin/env python3
"""
Multi-Platform CalculiX Solver Benchmark Runner
===============================================
Author: Dr. Carlo Monjaraz-Tec
Base Engine: CalculiX CrunchiX (Dr. Guido Dhondt)

Automated multi-threaded benchmark suite evaluating:
  * Apple Accelerate vs MUMPS vs SPOOLES (macOS Apple Silicon)
  * Intel oneMKL PARDISO vs MUMPS vs SPOOLES (Linux AMD64 / Windows)
  * MUMPS vs SPOOLES (Linux ARM64 Multipass VM)

Collects:
  * Wall-clock execution time
  * Peak Resident Set Size (RSS Memory in MB)
  * Multi-core thread scaling
  * Physical verification: Mode frequencies, effective modal mass, displacements
  * Numerical parity matrix relative to baseline / PARDISO
"""

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

RUNNER_DIR = Path(__file__).resolve().parent
BENCHMARKS_DIR = RUNNER_DIR.parent
REPO_ROOT = BENCHMARKS_DIR.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

ROTOR_DIR = BENCHMARKS_DIR / "compressor_rotor"
BEAM_DIR = BENCHMARKS_DIR / "cantilever_beam"
BLADE_DIR = BENCHMARKS_DIR / "naca_blade"
RESULTS_DIR = BENCHMARKS_DIR / "results"

CASE_CONFIGS = {
    "compressor_rotor": {
        "dir": ROTOR_DIR,
        "default_deck": "lavffcyc",
        "title": "7-Blade Turbocharger Compressor Rotor (Klaus Wittig / CGX)",
        "steps_desc": "Centrifugal Pre-load (110k RPM) -> Prestressed Cyclic Frequency",
        "levels": ["coarse", "fine"],
    },
    "cantilever_beam": {
        "dir": BEAM_DIR,
        "default_deck": "beam_static",
        "title": "3D Steel Cantilever Beam (20x20x200 mm, C3D20R)",
        "steps_desc": "Pure Linear Static Bending (*STATIC, 0.2 MPa Pressure)",
        "levels": ["coarse", "medium", "fine"],
    },
    "naca_blade": {
        "dir": BLADE_DIR,
        "default_deck": "blade_static",
        "title": "3D Twisted & Tapered NACA Airfoil Blade (Ti-6Al-4V, C3D20R)",
        "steps_desc": "Pure Linear Static Aerodynamic Bending & Torsion (*STATIC, 0.5 MPa)",
        "levels": ["coarse", "medium", "fine", "ultra_fine"],
    },
}


def get_system_profile():
    """Extract hardware topology, CPU model, and available RAM."""
    os_name = platform.system()
    arch = platform.machine()
    hostname = platform.node()
    cpu_name = platform.processor() or "Unknown CPU"
    total_ram_gb = 0.0

    p_cores = os.cpu_count() or 1
    total_cores = p_cores

    if os_name == "Darwin":
        try:
            res = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip():
                cpu_name = res.stdout.strip()
            res_mem = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
            if res_mem.returncode == 0 and res_mem.stdout.strip():
                total_ram_gb = round(int(res_mem.stdout.strip()) / (1024**3), 1)
            res_pcore = subprocess.run(["sysctl", "-n", "hw.perflevel0.logicalcpu"], capture_output=True, text=True)
            if res_pcore.returncode == 0 and res_pcore.stdout.strip():
                p_cores = int(res_pcore.stdout.strip())
        except Exception:
            pass

    elif os_name == "Linux":
        try:
            with open("/proc/cpuinfo", "r") as f:
                for line in f:
                    if "model name" in line:
                        cpu_name = line.split(":", 1)[1].strip()
                        break
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    if "MemTotal" in line:
                        kb = int(line.split()[1])
                        total_ram_gb = round(kb / (1024**2), 1)
                        break
        except Exception:
            pass

    return {
        "hostname": hostname,
        "os": os_name,
        "architecture": arch,
        "cpu_name": cpu_name,
        "total_cores": total_cores,
        "p_cores": p_cores,
        "total_ram_gb": total_ram_gb,
    }


def find_solver_binaries():
    """Locate available solver binaries across common build locations."""
    solvers = {}
    os_name = platform.system()

    # Candidate search paths per solver
    search_map = {
        "ACCELERATE": [
            REPO_ROOT / "build_accelerate" / "CalculiX",
            REPO_ROOT / "build" / "CalculiX",
        ],
        "MUMPS": [
            REPO_ROOT / "build_mumps" / "CalculiX",
            REPO_ROOT / "build_mumps2" / "CalculiX",
            REPO_ROOT / "build" / "CalculiX",
        ],
        "SPOOLES": [
            REPO_ROOT / "build_spooles" / "CalculiX",
            REPO_ROOT / "build_spooles_archive" / "CalculiX",
            REPO_ROOT / "build_spooles_vendor" / "CalculiX",
            REPO_ROOT / "src" / "CalculiX",
        ],
        "PARDISO": [
            REPO_ROOT / "build_pardiso" / "CalculiX",
            REPO_ROOT / "build_mkl" / "CalculiX",
            Path("C:/PrePoMax/CalculiX/ccx.exe"),
            Path("C:/CalculiX/bin/ccx.exe"),
        ],
    }

    # Don't seek Accelerate on non-Apple, and don't seek PARDISO on Darwin
    if os_name != "Darwin":
        search_map.pop("ACCELERATE", None)
    else:
        search_map.pop("PARDISO", None)

    for solver, paths in search_map.items():
        for p in paths:
            if p.is_file() and os.access(p, os.X_OK):
                solvers[solver] = p.resolve()
                break

    return solvers


def execute_run(bin_path, deck_name, threads, cwd_dir):
    """
    Execute CalculiX deck with thread counts, in-memory JSON export, and RSS memory tracking.
    """
    os_name = platform.system()
    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = str(threads)
    env["MKL_NUM_THREADS"] = str(threads)
    env["CCX_NPROC_EQUATION_SOLVER"] = str(threads)
    env["VECLIB_MAXIMUM_THREADS"] = str(threads)
    env["CCX_JSON"] = "1"

    json_file = cwd_dir / f"{deck_name}.json"
    if json_file.exists():
        try:
            json_file.unlink()
        except OSError:
            pass

    # Command wrapping for peak RSS memory tracking
    if os_name == "Darwin":
        # /usr/bin/time -l reports "maximum resident set size" in bytes
        cmd = ["/usr/bin/time", "-l", str(bin_path), "-j", deck_name]
    elif os_name == "Linux":
        # /usr/bin/time -v reports "Maximum resident set size (kbytes)"
        cmd = ["/usr/bin/time", "-v", str(bin_path), "-j", deck_name]
    else:
        cmd = [str(bin_path), "-j", deck_name]

    t0 = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd_dir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=1800,
        )
        elapsed = time.perf_counter() - t0
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timeout (>1800s)", "time": None}
    except Exception as e:
        return {"success": False, "error": str(e), "time": None}

    # Parse Peak RSS Memory
    peak_rss_mb = None
    stderr_out = proc.stderr or ""
    if os_name == "Darwin":
        m = re.search(r"(\d+)\s+maximum resident set size", stderr_out)
        if m:
            peak_rss_mb = round(int(m.group(1)) / (1024 * 1024), 2)
    elif os_name == "Linux":
        m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", stderr_out)
        if m:
            peak_rss_mb = round(int(m.group(1)) / 1024, 2)

    if proc.returncode != 0:
        return {
            "success": False,
            "error": f"Exit code {proc.returncode}",
            "time": elapsed,
            "output": proc.stdout + "\n" + proc.stderr,
        }

    if not json_file.exists():
        return {
            "success": False,
            "error": f"JSON export {json_file.name} missing",
            "time": elapsed,
            "output": proc.stdout,
        }

    # Extract JSON data
    try:
        with open(json_file, "r", encoding="utf-8") as f:
            jdata = json.load(f)
    except Exception as e:
        return {
            "success": False,
            "error": f"JSON parse error: {e}",
            "time": elapsed,
        }

    meta = jdata.get("meta", {})
    timings = meta.get("timings", {})
    stats = meta.get("mesh_statistics", {})
    steps = jdata.get("steps", [])

    ccx_time = timings.get("total_wall_time_s", elapsed)

    # Step 2 frequency metrics (cyclic symmetry modes)
    step2 = steps[1] if len(steps) > 1 else {}
    eff_mass = step2.get("total_effective_mass", {})
    frac_totals = step2.get("fraction_of_totals", {})

    # Optional linear static verification metrics (*STATIC with NNTIP_U)
    static_verif = None
    for st in steps:
        if st.get("type") == "STATIC":
            incs = st.get("increments", [])
            node_sets = incs[0].get("node_sets", {}) if incs else {}
            nntip_u = node_sets.get("NNTIPN_U") or node_sets.get("NNTIP_U", {})
            vals = [row for row in nntip_u.get("values", []) if isinstance(row, list) and len(row) >= 3]
            if vals:
                u1_vals = [row[0] for row in vals]
                u2_vals = [row[1] for row in vals]
                umag_vals = [(row[0] ** 2 + row[1] ** 2 + row[2] ** 2) ** 0.5 for row in vals]
                static_verif = {
                    "converged": bool(st.get("converged", False)),
                    "tip_u1_mean": sum(u1_vals) / len(u1_vals),
                    "tip_u2_min": min(u2_vals),
                    "tip_u2_mean": sum(u2_vals) / len(u2_vals),
                    "tip_u2_max": max(u2_vals),
                    "tip_umag_max": max(umag_vals),
                }
            elif st.get("converged") is not None:
                static_verif = {"converged": bool(st.get("converged", False))}
            break

    result = {
        "success": True,
        "wall_time": round(ccx_time, 4),
        "measured_time": round(elapsed, 4),
        "peak_rss_mb": peak_rss_mb,
        "equations": stats.get("equations"),
        "nodes": stats.get("nodes"),
        "elements": stats.get("elements"),
        "total_effective_mass": eff_mass,
        "fraction_of_totals": frac_totals,
    }
    if static_verif is not None:
        result["static_verification"] = static_verif
    return result


def prepare_case_mesh(case_name, case_dir, level, force_remesh):
    """Ensure required mesh files exist and are valid for the selected case."""
    msh_file = case_dir / "all.msh"

    if case_name == "compressor_rotor":
        cyc1_file = case_dir / "CYC1.nam"
        cyc2_file = case_dir / "CYC2.nam"
        need_remesh = force_remesh or not msh_file.exists() or not cyc1_file.exists() or not cyc2_file.exists()
        if not need_remesh:
            try:
                n1 = sum(1 for line in open(cyc1_file) if line.strip() and not line.startswith("*"))
                n2 = sum(1 for line in open(cyc2_file) if line.strip() and not line.startswith("*"))
                if n1 != n2:
                    print(f"[!] Warning: Cyclic symmetry boundary mismatch (CYC1={n1}, CYC2={n2}). Remeshing...")
                    need_remesh = True
            except Exception:
                need_remesh = True
        if need_remesh:
            print(f"[*] Meshing compressor_rotor via CGX at '{level}' level...")
            from benchmarks.compressor_rotor.remesh import remesh
            remesh(level=level)
    elif case_name == "cantilever_beam":
        req = [msh_file, case_dir / "NFIX.nam", case_dir / "NTIP.nam", case_dir / "TOP.dlo"]
        need_remesh = force_remesh or any(not p.is_file() or p.stat().st_size == 0 for p in req)
        if need_remesh:
            print(f"[*] Meshing cantilever_beam via CGX at '{level}' level...")
            from benchmarks.cantilever_beam.remesh import remesh
            remesh(level=level)
    elif case_name == "naca_blade":
        req = [msh_file, case_dir / "NFIX.nam", case_dir / "NTIP.nam", case_dir / "PRES.dlo"]
        need_remesh = force_remesh or any(not p.is_file() or p.stat().st_size == 0 for p in req)
        if need_remesh:
            print(f"[*] Meshing naca_blade via CGX at '{level}' level...")
            from benchmarks.naca_blade.remesh import remesh
            remesh(level=level)


def main():
    parser = argparse.ArgumentParser(
        description="Run CalculiX Multi-Solver Benchmarks"
    )
    parser.add_argument(
        "--case",
        choices=list(CASE_CONFIGS.keys()),
        default="compressor_rotor",
        help="Benchmark model case to execute",
    )
    parser.add_argument(
        "--solvers",
        nargs="+",
        help="Solvers to run (e.g. ACCELERATE MUMPS SPOOLES PARDISO)",
    )
    parser.add_argument(
        "--threads",
        nargs="+",
        type=int,
        default=[1, 2, 4, 8],
        help="Thread counts to benchmark",
    )
    parser.add_argument(
        "--deck",
        default=None,
        help="Deck name inside selected case directory (defaults to case default)",
    )
    parser.add_argument(
        "--level",
        default="fine",
        choices=["coarse", "medium", "fine", "ultra_fine"],
        help="Mesh discretization level name (coarse, medium, fine, or ultra_fine)",
    )
    parser.add_argument(
        "--remesh",
        action="store_true",
        help="Force re-running CGX remesher before executing benchmarks",
    )
    parser.add_argument(
        "--tag",
        default=None,
        help="Custom machine tag for output JSON (default: hostname_os_arch_level)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="Custom output directory for results (default: benchmarks/results)",
    )
    parser.add_argument(
        "--save-frd",
        action="store_true",
        help="Copy one generated .frd file into the output directory for CGX screenshots",
    )
    args = parser.parse_args()

    case_cfg = CASE_CONFIGS[args.case]
    if args.level not in case_cfg["levels"]:
        parser.error(f"Case '{args.case}' supports --level choices {case_cfg['levels']}, got '{args.level}'")

    case_dir = case_cfg["dir"]
    deck_name = args.deck or case_cfg["default_deck"]

    sys_profile = get_system_profile()
    machine_tag = args.tag or f"{sys_profile['hostname']}_{sys_profile['os']}_{sys_profile['architecture']}_{args.level}".lower()

    print("=" * 80)
    print(" CalculiX CrunchiX (CCX) Multi-Solver Benchmark Suite")
    print(f" Case  : {args.case} — {case_cfg['title']}")
    print(f" Steps : {case_cfg['steps_desc']}")
    print("=" * 80)
    print(f" Hostname     : {sys_profile['hostname']}")
    print(f" Platform     : {sys_profile['os']} {sys_profile['architecture']}")
    print(f" CPU Model    : {sys_profile['cpu_name']}")
    print(f" CPU Topology : {sys_profile['total_cores']} cores ({sys_profile['p_cores']} P-cores)")
    print(f" System RAM   : {sys_profile['total_ram_gb']} GB")
    print(f" Mesh Level   : {args.level}")
    print("-" * 80)

    prepare_case_mesh(args.case, case_dir, args.level, args.remesh)

    # Discover binaries
    available_solvers = find_solver_binaries()
    if args.solvers:
        target_solvers = {s.upper(): available_solvers[s.upper()] for s in args.solvers if s.upper() in available_solvers}
    else:
        target_solvers = available_solvers

    if not target_solvers:
        print("[!] Error: No solver binaries found for evaluation!")
        print("    Build CCX with desired solvers or specify --solvers")
        sys.exit(1)

    print(f" Solvers to test : {', '.join(target_solvers.keys())}")
    print(f" Thread sweeps   : {', '.join(map(str, args.threads))}")
    print("=" * 80)

    benchmark_data = {
        "metadata": {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "system_profile": sys_profile,
            "case": args.case,
            "deck": deck_name,
            "discretization": args.level,
            "nodes": None,
            "elements": None,
            "equations": None,
        },
        "results": {},
    }

    # Run Benchmark Matrix
    for sname, sbin in target_solvers.items():
        print(f"\n[*] Benchmarking Solver: {sname} ({sbin.name})")
        solver_results = {}

        for th in args.threads:
            print(f"    -> Running with {th} thread(s)...", end="", flush=True)
            res = execute_run(sbin, deck_name, th, case_dir)

            if res["success"]:
                wall_t = res["wall_time"]
                rss_str = f" | Peak RAM: {res['peak_rss_mb']} MB" if res["peak_rss_mb"] else ""
                print(f" DONE in {wall_t:.2f} s{rss_str}")
                if benchmark_data["metadata"]["nodes"] is None:
                    benchmark_data["metadata"]["nodes"] = res.get("nodes")
                    benchmark_data["metadata"]["elements"] = res.get("elements")
                    benchmark_data["metadata"]["equations"] = res.get("equations")
            else:
                print(f" FAILED ({res['error']})")
                if res.get("output"):
                    err_lines = [l.strip() for l in res["output"].splitlines() if "*ERROR" in l]
                    for el in err_lines[:4]:
                        print(f"       {el}")

            solver_results[str(th)] = res

        benchmark_data["results"][sname] = solver_results

    # Summary Table
    print("\n" + "=" * 80)
    print(f" BENCHMARK SUMMARY TABLE: {deck_name}")
    print("=" * 80)
    header = f"{'Solver':<14} | " + " | ".join([f"{th}T (s)" for th in args.threads]) + " | Peak RAM"
    print(header)
    print("-" * len(header))

    spooles_1t = None
    if "SPOOLES" in benchmark_data["results"]:
        sp_res = benchmark_data["results"]["SPOOLES"].get("1", {})
        if sp_res.get("success"):
            spooles_1t = sp_res["wall_time"]

    for sname in target_solvers.keys():
        row = f"{sname:<14} | "
        max_rss = 0.0
        for th in args.threads:
            entry = benchmark_data["results"][sname].get(str(th), {})
            if entry.get("success"):
                t_val = entry["wall_time"]
                row += f"{t_val:>7.2f}s | "
                if entry.get("peak_rss_mb"):
                    max_rss = max(max_rss, entry["peak_rss_mb"])
            else:
                row += f"{'FAIL':>7} | "
        rss_col = f"{max_rss:>7.1f} MB" if max_rss > 0 else "N/A"
        row += rss_col
        print(row)

    print("=" * 80)

    # Save Results
    out_dir = args.out_dir.resolve() if args.out_dir else RESULTS_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{machine_tag}_{deck_name}.json"
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(benchmark_data, f, indent=2)

    try:
        rel_out = out_file.relative_to(REPO_ROOT)
    except ValueError:
        rel_out = out_file
    print(f"\n[+] Saved complete benchmark metrics to: {rel_out}")

    if args.save_frd:
        frd_src = case_dir / f"{deck_name}.frd"
        if frd_src.exists():
            frd_dst = out_dir / frd_src.name
            shutil.copy2(frd_src, frd_dst)
            print(f"[+] Copied FRD results for screenshots to: {frd_dst.name}")
        else:
            print(f"[!] Warning: {frd_src.name} not found to copy.")


if __name__ == "__main__":
    main()
