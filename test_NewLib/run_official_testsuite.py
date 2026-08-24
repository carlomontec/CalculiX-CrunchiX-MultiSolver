#!/usr/bin/env python3
"""
CalculiX Multi-Solver Official Verification Suite Runner
=========================================================

DESCRIPTION:
    This script automates the execution and verification of Dr. Guido Dhondt's 
    official CalculiX (CCX) test suite against multiple direct sparse solvers.

    Key Features:
      - Automatically downloads the test suite if not found locally.
      - Runs test decks concurrently across multiple CPU threads.
      - Sandboxes every test in an isolated temporary directory to prevent I/O collisions.
      - Forces the requested solver into the `.inp` step definitions to prevent silent fallbacks.
      - Generates clean, emoji-free CSV exports for NumPy/Excel analysis.
      - Produces Markdown reports and Matplotlib charts comparing accuracy and speedup
        (Uses SPOOLES as the baseline if included in the test execution list).

-------------------------------------------------------------------------------
1-LINER USAGE (Downloads script & test suite on the fly):
  Compare SPOOLES vs PARDISO:
    curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/run_verification.py | python3 - --solvers SPOOLES PARDISO

LOCAL USAGE (From inside cloned repository):
  ./run_verification.py --solvers ALL --threads-per-job 4
  ./run_verification.py --pattern "beam*" --solvers MUMPS PARDISO
  ./run_verification.py --custom-bin /usr/local/bin/ccx
-------------------------------------------------------------------------------
"""

import argparse
import csv
import datetime
import fnmatch
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

# Matplotlib integration for reports
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False

# =============================================================================
# Path & Environment Initialization
# =============================================================================

# Always assume the current working directory is the base for build folders
CCX_DIR = Path.cwd()
TEST_DIR = CCX_DIR / "test"

# Available Solver Binaries
EXE_NAME = "CalculiX.exe" if sys.platform in ("win32", "msys", "cygwin") or os.name == "nt" else "CalculiX"

SOLVER_CONFIGS = {
    "SPOOLES": {
        "env": {},
        "description": "SPOOLES 2.2 Direct Solver (Classic Reference Baseline)",
    },
    "PARDISO": {
        "env": {
            "MKL_ENABLE_INSTRUCTIONS": "AVX2",
            "MKL_DYNAMIC": "FALSE",
        },
        "description": "Intel oneMKL PARDISO Solver",
    },
    "MUMPS": {
        "env": {
            "MKL_THREADING_LAYER": "GNU",
        },
        "description": "MUMPS 5.x Direct Solver",
    },
    "ACCELERATE": {
        "env": {},
        "description": "Apple Accelerate Sparse Direct Solver",
    },
}

# Decks to exclude (interactive or optimization scripts)
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

# =============================================================================
# Core Functions
# =============================================================================

def get_viable_solvers():
    """Determine viable solvers based exactly on the OS and architecture rules."""
    sys_os = platform.system()
    arch = platform.machine().lower()

    if sys_os == "Darwin":
        return ["MUMPS", "ACCELERATE"]
    elif sys_os == "Linux":
        if arch in ("x86_64", "amd64"):
            return ["SPOOLES", "MUMPS", "PARDISO"]
        elif arch in ("aarch64", "arm64", "armv7l", "armv8l"):
            return ["SPOOLES", "MUMPS"]
        else:
            return ["SPOOLES", "MUMPS"]
    elif sys_os == "Windows" or os.name == "nt":
        return ["PARDISO", "MUMPS"]
    
    return ["SPOOLES", "MUMPS"]


def check_solver_libraries(solvers, sys_os):
    """Heuristic check for underlying solver libraries. Prints warnings if missing."""
    for solver in solvers:
        found = False
        
        if solver == "ACCELERATE" and sys_os == "Darwin":
            found = True  
            
        elif solver == "MUMPS":
            if sys_os == "Darwin":
                if shutil.which("brew"):
                    try:
                        res = subprocess.run(["brew", "--prefix", "mumps"], capture_output=True, text=True)
                        if res.returncode == 0 and Path(res.stdout.strip()).exists():
                            found = True
                    except Exception:
                        pass
                if not found and (list(Path("/opt/homebrew/lib").glob("*mumps*")) or list(Path("/usr/local/lib").glob("*mumps*"))):
                    found = True
            elif sys_os == "Linux":
                try:
                    res = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True)
                    if "mumps" in res.stdout.lower():
                        found = True
                except Exception:
                    pass
                if not found and (list(Path("/usr/lib").glob("**/*mumps*")) or list(Path("/usr/include").glob("**/*mumps*"))):
                    found = True
                    
        elif solver == "SPOOLES" and sys_os == "Linux":
            try:
                res = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True)
                if "spooles" in res.stdout.lower():
                    found = True
            except Exception:
                pass
            if not found and (list(Path("/usr/lib").glob("**/*spooles*")) or list(Path("/usr/include").glob("**/*spooles*"))):
                found = True
                
        elif solver == "PARDISO" and sys_os == "Linux":
            if os.environ.get("MKLROOT") or Path("/opt/intel/oneapi/mkl").exists():
                found = True
            else:
                try:
                    res = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True)
                    if "mkl" in res.stdout.lower():
                        found = True
                except Exception:
                    pass
        else:
            found = True 

        if not found:
            print(f"[!] Info: System libraries for '{solver}' were not detected. Tests for this solver may fail or fall back to defaults.")


def ensure_test_suite():
    """Ensures the test suite exists AND has .inp files. Prompts the user to clone if missing."""
    global TEST_DIR
    
    if not TEST_DIR.exists() or not list(TEST_DIR.glob("*.inp")):
        print(f"[*] Official test directory (.inp decks) not found locally at {TEST_DIR}.")
        
        # Interactively ask the user if they are in a real terminal
        if sys.stdin.isatty():
            ans = input("[?] Would you like to clone the official test suite to a temporary folder now? [Y/n]: ").strip().lower()
            if ans not in ('', 'y', 'yes'):
                print("[-] Cannot proceed without test decks. Exiting.")
                sys.exit(1)
        else:
            print("[*] Non-interactive mode detected. Automatically cloning test suite to a temporary folder...")

        print("[*] Cloning CalculiX-CrunchiX-MultiSolver repository to fetch test suite...")
        temp_repo = Path(tempfile.mkdtemp(prefix="ccx_repo_"))
        try:
            subprocess.run(
                ["git", "clone", "--depth", "1", "https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver.git", str(temp_repo)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            TEST_DIR = temp_repo / "test"
            print(f"[+] Test suite loaded successfully in {TEST_DIR}\n")
        except subprocess.CalledProcessError:
            print("[-] Failed to clone repository. Cannot run tests.")
            sys.exit(1)


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

    with tempfile.TemporaryDirectory(prefix=f"ccx_{solver_name}_{deck}_") as sandbox:
        sandbox_path = Path(sandbox)

        # 1. Symlink all files from test/ into sandbox so inputs/includes work seamlessly
        for item in TEST_DIR.iterdir():
            if item.is_file():
                dest = sandbox_path / item.name
                try:
                    os.symlink(item, dest)
                except OSError:
                    shutil.copy2(item, dest)

        # 2. Force the solver selection via string injection in the .inp file
        inp_file = sandbox_path / f"{deck}.inp"
        if inp_file.exists():
            if inp_file.is_symlink():
                inp_file.unlink()
                shutil.copy2(TEST_DIR / f"{deck}.inp", inp_file)
            
            with open(inp_file, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.readlines()
            
            step_cards = ["*STATIC", "*FREQUENCY", "*DYNAMIC", "*BUCKLE", "*HEAT TRANSFER", "*COUPLED TEMPERATURE-DISPLACEMENT"]
            
            with open(inp_file, "w", encoding="utf-8") as f:
                for line in lines:
                    upper_line = line.upper().strip()
                    matched_card = next((card for card in step_cards if upper_line.startswith(card)), None)
                    
                    if matched_card:
                        parts = [p.strip() for p in line.split(",") if not p.upper().strip().startswith("SOLVER")]
                        parts.append(f"SOLVER={solver_name}")
                        line = ", ".join(parts) + "\n"
                        
                    f.write(line)

        # 3. Execute the binary
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
                "detail": str(e).split("]")[1].strip() if "]" in str(e) else str(e),
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

        # Substructure format conversion
        if deck in ["substructure", "substructure2", "beammrlin_diff", "beammrlin_same"]:
            mtx_f = sandbox_path / f"{deck}.mtx"
            dat_f = sandbox_path / f"{deck}.dat"
            if mtx_f.exists():
                with open(mtx_f, "r") as fin, open(dat_f, "w") as fout:
                    fout.write(fin.read().replace(",", " "))

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

# =============================================================================
# Reporting & Visualization
# =============================================================================

def generate_plots(stats, solvers, output_dir, timestamp_str, baseline_solver):
    """Generate visual comparative benchmark dashboard with timestamps and baseline delta."""
    if not HAS_MATPLOTLIB:
        return None

    plot_file = output_dir / "solver_comparison.png"
    solver_names = list(solvers)
    has_baseline = baseline_solver is not None

    total_runs = {
        s: sum(stats[s][k] for k in ["PASS", "DIFF", "FAIL", "TIMEOUT", "ERROR"])
        for s in solver_names
    }
    pass_rates = [
        (stats[s]["PASS"] / max(1, total_runs[s])) * 100.0 for s in solver_names
    ]
    total_times = [stats[s]["TOTAL_TIME"] for s in solver_names]

    # Grid layout: 3 subplots if a baseline is present, 2 otherwise
    cols = 3 if has_baseline else 2
    fig, axes = plt.subplots(1, cols, figsize=(6 * cols, 5.2))
    fig.suptitle(
        f"CalculiX Multi-Solver Verification Benchmark\nRun Date: {timestamp_str}",
        fontsize=13,
        fontweight="bold",
        y=0.98,
    )

    # 1. Absolute Pass Rate (%)
    ax1 = axes[0]
    colors1 = ["#2ecc71" if pr >= 98 else "#f39c12" if pr >= 90 else "#e74c3c" for pr in pass_rates]
    bars1 = ax1.bar(solver_names, pass_rates, color=colors1, edgecolor="#2c3e50", width=0.5)
    ax1.set_title("Verification Pass Rate (%)", fontsize=11, pad=10, fontweight="semibold")
    ax1.set_ylabel("Pass Rate (%)")
    ax1.set_ylim(0, 110)
    ax1.grid(axis="y", linestyle="--", alpha=0.5)
    for bar, val in zip(bars1, pass_rates):
        ax1.text(bar.get_x() + bar.get_width() / 2, val + 1.5, f"{val:.1f}%", ha="center", va="bottom", fontweight="bold")

    # 2. Relative Pass Rate vs Baseline
    next_ax_idx = 1
    if has_baseline:
        ax_rel = axes[1]
        base_idx = solver_names.index(baseline_solver)
        base_pr = pass_rates[base_idx]
        deltas = [pr - base_pr for pr in pass_rates]
        rel_colors = ["#34495e" if s == baseline_solver else "#27ae60" if d >= 0 else "#e74c3c" for s, d in zip(solver_names, deltas)]

        bars_rel = ax_rel.bar(solver_names, deltas, color=rel_colors, edgecolor="#2c3e50", width=0.5)
        ax_rel.axhline(0, color="black", linewidth=1.2, linestyle="--")
        ax_rel.set_title(f"Pass Rate Δ vs {baseline_solver} Baseline", fontsize=11, pad=10, fontweight="semibold")
        ax_rel.set_ylabel("Percentage Points (Δ %)")
        ax_rel.grid(axis="y", linestyle="--", alpha=0.5)

        max_abs = max(abs(d) for d in deltas) if deltas else 5.0
        ylim = max(5.0, max_abs * 1.3)
        ax_rel.set_ylim(-ylim, ylim)

        for bar, d, s in zip(bars_rel, deltas, solver_names):
            label = "Baseline" if s == baseline_solver else f"{d:+.1f}%"
            y_pos = d + (ylim * 0.05 if d >= 0 else -ylim * 0.12)
            ax_rel.text(bar.get_x() + bar.get_width() / 2, y_pos, label, ha="center", va="bottom", fontweight="bold")
        next_ax_idx = 2

    # 3. Cumulative Execution Time & Speedup
    ax_time = axes[next_ax_idx]
    bars_time = ax_time.bar(solver_names, total_times, color="#3498db", edgecolor="#2c3e50", width=0.5)
    ax_time.set_title("Cumulative Suite Wall Time (s)", fontsize=11, pad=10, fontweight="semibold")
    ax_time.set_ylabel("Total Time (s)")
    ax_time.grid(axis="y", linestyle="--", alpha=0.5)

    base_time = stats.get(baseline_solver, {}).get("TOTAL_TIME", 0.0) if has_baseline else 0.0
    for bar, t, s in zip(bars_time, total_times, solver_names):
        speedup_label = ""
        if has_baseline and base_time > 0 and t > 0:
            speedup = base_time / t
            speedup_label = f"\n({speedup:.2f}x)" if s != baseline_solver else "\n(1.0x)"
        ax_time.text(
            bar.get_x() + bar.get_width() / 2,
            t + max(total_times) * 0.02,
            f"{t:.1f}s{speedup_label}",
            ha="center",
            va="bottom",
            fontweight="bold",
        )

    plt.tight_layout(rect=[0, 0.03, 1, 0.95])
    plt.savefig(plot_file, dpi=180)
    plt.close()
    return plot_file


def save_reports(decks, active_solvers, results, stats, output_dir, timestamp_formatted, baseline_solver):
    """Write CSV, Markdown summary reports with baseline comparisons, and plot files."""
    output_dir.mkdir(parents=True, exist_ok=True)
    csv_file = output_dir / "results.csv"
    md_file = output_dir / "summary.md"

    # 1. Write Semicolon-Delimited CSV (Strict text, no emojis)
    fieldnames = ["Deck"]
    for s in active_solvers:
        fieldnames.extend([f"{s}_Status", f"{s}_Time_s", f"{s}_Detail"])

    with open(csv_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, delimiter=";")
        writer.writerow(fieldnames)
        for d in decks:
            row = [d]
            for s in active_solvers:
                res = results[d].get(s, {})
                row.append(res.get("status", "N/A"))
                row.append(f"{res.get('time', 0.0):.2f}" if "time" in res else "N/A")
                row.append(res.get("detail", ""))
            writer.writerow(row)

    total_decks = len(decks)
    has_baseline = baseline_solver is not None
    base_pass_rate = (stats[baseline_solver]["PASS"] / total_decks * 100.0) if (has_baseline and total_decks > 0) else None
    base_time = stats.get(baseline_solver, {}).get("TOTAL_TIME", 0.0) if has_baseline else 0.0

    # 2. Compute Progression / Regression Stats vs Baseline
    solver_comparisons = {}
    if has_baseline:
        for s in active_solvers:
            if s == baseline_solver:
                continue
            fixes = 0
            regressions = 0
            for d in decks:
                base_st = results[d].get(baseline_solver, {}).get("status", "N/A")
                cur_st = results[d].get(s, {}).get("status", "N/A")
                if base_st != "PASS" and cur_st == "PASS":
                    fixes += 1
                elif base_st == "PASS" and cur_st != "PASS":
                    regressions += 1
            solver_comparisons[s] = {"fixes": fixes, "regressions": regressions}

    # 3. Write Markdown Summary
    with open(md_file, "w", encoding="utf-8") as f:
        f.write("# CalculiX Multi-Solver Verification Report\n\n")
        f.write(f"- **Execution Timestamp:** {timestamp_formatted}\n")
        f.write(f"- **Total Test Decks:** {total_decks}\n")
        f.write(f"- **Reference Baseline:** `{baseline_solver if has_baseline else 'None (SPOOLES not selected)'}`\n\n")

        # Visual Plot Section
        if HAS_MATPLOTLIB:
            f.write("## 📊 Performance & Accuracy Overview\n\n")
            f.write("![Benchmark Overview](./solver_comparison.png)\n\n")

        # Overall Status Matrix
        f.write("## 📋 Solver Aggregate Matrix\n\n")
        f.write("| Solver | Pass | Diff | Fail | Timeout | Error | Pass Rate (%) | Total Time (s) |\n")
        f.write("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |\n")

        for s in active_solvers:
            st = stats[s]
            pass_rate = (st["PASS"] / total_decks * 100.0) if total_decks > 0 else 0.0
            badge = "🟢" if pass_rate >= 98.0 else ("🟡" if pass_rate >= 90.0 else "🔴")
            f.write(
                f"| **{s}** | {st['PASS']} | {st['DIFF']} | {st['FAIL']} | {st['TIMEOUT']} | "
                f"{st['ERROR']} | {badge} **{pass_rate:.1f}%** | {st['TOTAL_TIME']:.2f}s |\n"
            )

        # Baseline Comparison Breakdown
        if has_baseline:
            f.write(f"\n## 🔍 Solver Progression vs {baseline_solver} Baseline\n\n")
            f.write("| Solver | Pass Rate Δ | Speedup Factor | Time Saved (s) | Fixes | Regressions |\n")
            f.write("| :--- | :---: | :---: | :---: | :---: | :---: |\n")

            for s in active_solvers:
                st = stats[s]
                pass_rate = (st["PASS"] / total_decks * 100.0) if total_decks > 0 else 0.0

                if s == baseline_solver:
                    f.write(f"| **{s}** *(Ref)* | `Baseline` (0.0%) | 1.00x | 0.00s | — | — |\n")
                else:
                    diff_val = pass_rate - base_pass_rate
                    if diff_val > 0:
                        delta_str = f"📈 **+{diff_val:.1f}%**"
                    elif diff_val < 0:
                        delta_str = f"📉 **{diff_val:.1f}%**"
                    else:
                        delta_str = "⚖️ **0.0%**"

                    speedup = (base_time / st["TOTAL_TIME"]) if st["TOTAL_TIME"] > 0 else 0.0
                    time_saved = base_time - st["TOTAL_TIME"]
                    saved_str = f"+{time_saved:.2f}s" if time_saved >= 0 else f"{time_saved:.2f}s"

                    comp = solver_comparisons[s]
                    f.write(
                        f"| **{s}** | {delta_str} | **{speedup:.2f}x** | {saved_str} | "
                        f"✅ {comp['fixes']} | ❌ {comp['regressions']} |\n"
                    )

        # Detailed Test Deck Table
        f.write("\n## 🧪 Detailed Test Deck Matrix\n\n")
        f.write("| Test Deck | " + " | ".join([f"{s} Status" for s in active_solvers]) + " |\n")
        f.write("| :--- | " + " | ".join([":---:" for _ in active_solvers]) + " |\n")

        for d in decks:
            deck_row = f"| `{d}` | "
            for s in active_solvers:
                res = results[d].get(s)
                if res:
                    icon = "✅" if res["status"] == "PASS" else ("⚠️" if res["status"] == "DIFF" else "❌")
                    deck_row += f"{icon} {res['status']} ({res['time']:.2f}s) | "
                else:
                    deck_row += "N/A | "
            f.write(deck_row + "\n")

    plot_file = generate_plots(stats, active_solvers, output_dir, timestamp_formatted, baseline_solver)
    return csv_file, md_file, plot_file


# =============================================================================
# Main Execution
# =============================================================================

def generate_plots(stats, solvers, output_dir, timestamp_str):
    """Generate visual comparative benchmark dashboard with timestamps and SPOOLES delta."""
    if not HAS_MATPLOTLIB:
        return None

    plot_file = output_dir / "solver_comparison.png"
    solver_names = list(solvers)
    has_spooles = "SPOOLES" in solver_names

    total_runs = {
        s: sum(stats[s][k] for k in ["PASS", "DIFF", "FAIL", "TIMEOUT", "ERROR"])
        for s in solver_names
    }
    pass_rates = [
        (stats[s]["PASS"] / max(1, total_runs[s])) * 100.0 for s in solver_names
    ]
    total_times = [stats[s]["TOTAL_TIME"] for s in solver_names]

    # Grid layout: 3 subplots if SPOOLES is present, 2 otherwise
    cols = 3 if has_spooles else 2
    fig, axes = plt.subplots(1, cols, figsize=(6 * cols, 5.2))
    fig.suptitle(
        f"CalculiX Multi-Solver Verification Benchmark\nRun Date: {timestamp_str}",
        fontsize=13,
        fontweight="bold",
        y=0.98,
    )

    # 1. Absolute Pass Rate (%)
    ax1 = axes[0]
    colors1 = ["#2ecc71" if pr >= 98 else "#f39c12" if pr >= 90 else "#e74c3c" for pr in pass_rates]
    bars1 = ax1.bar(solver_names, pass_rates, color=colors1, edgecolor="#2c3e50", width=0.5)
    ax1.set_title("Verification Pass Rate (%)", fontsize=11, pad=10, fontweight="semibold")
    ax1.set_ylabel("Pass Rate (%)")
    ax1.set_ylim(0, 110)
    ax1.grid(axis="y", linestyle="--", alpha=0.5)
    for bar, val in zip(bars1, pass_rates):
        ax1.text(bar.get_x() + bar.get_width() / 2, val + 1.5, f"{val:.1f}%", ha="center", va="bottom", fontweight="bold")

    # 2. Relative Pass Rate vs SPOOLES Baseline
    next_ax_idx = 1
    if has_spooles:
        ax_rel = axes[1]
        spooles_idx = solver_names.index("SPOOLES")
        spooles_pr = pass_rates[spooles_idx]
        deltas = [pr - spooles_pr for pr in pass_rates]
        rel_colors = ["#34495e" if s == "SPOOLES" else "#27ae60" if d >= 0 else "#e74c3c" for s, d in zip(solver_names, deltas)]

        bars_rel = ax_rel.bar(solver_names, deltas, color=rel_colors, edgecolor="#2c3e50", width=0.5)
        ax_rel.axhline(0, color="black", linewidth=1.2, linestyle="--")
        ax_rel.set_title("Pass Rate Δ vs SPOOLES Baseline", fontsize=11, pad=10, fontweight="semibold")
        ax_rel.set_ylabel("Percentage Points (Δ %)")
        ax_rel.grid(axis="y", linestyle="--", alpha=0.5)

        max_abs = max(abs(d) for d in deltas) if deltas else 5.0
        ylim = max(5.0, max_abs * 1.3)
        ax_rel.set_ylim(-ylim, ylim)

        for bar, d, s in zip(bars_rel, deltas, solver_names):
            label = "Baseline" if s == "SPOOLES" else f"{d:+.1f}%"
            y_pos = d + (ylim * 0.05 if d >= 0 else -ylim * 0.12)
            ax_rel.text(bar.get_x() + bar.get_width() / 2, y_pos, label, ha="center", va="bottom", fontweight="bold")
        next_ax_idx = 2

    # 3. Cumulative Execution Time & Speedup
    ax_time = axes[next_ax_idx]
    bars_time = ax_time.bar(solver_names, total_times, color="#3498db", edgecolor="#2c3e50", width=0.5)
    ax_time.set_title("Cumulative Suite Wall Time (s)", fontsize=11, pad=10, fontweight="semibold")
    ax_time.set_ylabel("Total Time (s)")
    ax_time.grid(axis="y", linestyle="--", alpha=0.5)

    spooles_time = stats.get("SPOOLES", {}).get("TOTAL_TIME", 0.0) if has_spooles else 0.0
    for bar, t, s in zip(bars_time, total_times, solver_names):
        speedup_label = ""
        if has_spooles and spooles_time > 0 and t > 0:
            speedup = spooles_time / t
            speedup_label = f"\n({speedup:.2f}x)" if s != "SPOOLES" else "\n(1.0x)"
        ax_time.text(
            bar.get_x() + bar.get_width() / 2,
            t + max(total_times) * 0.02,
            f"{t:.1f}s{speedup_label}",
            ha="center",
            va="bottom",
            fontweight="bold",
        )

    plt.tight_layout(rect=[0, 0.03, 1, 0.95])
    plt.savefig(plot_file, dpi=180)
    plt.close()
    return plot_file


def save_reports(decks, active_solvers, results, stats, output_dir, timestamp_formatted):
    """Write CSV, Markdown summary reports with baseline comparisons, and plot files."""
    output_dir.mkdir(parents=True, exist_ok=True)
    csv_file = output_dir / "results.csv"
    md_file = output_dir / "summary.md"

    # 1. Write Semicolon-Delimited CSV
    fieldnames = ["Deck"]
    for s in active_solvers:
        fieldnames.extend([f"{s}_Status", f"{s}_Time_s", f"{s}_Detail"])

    with open(csv_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, delimiter=";")
        writer.writerow(fieldnames)
        for d in decks:
            row = [d]
            for s in active_solvers:
                res = results[d].get(s, {})
                row.append(res.get("status", "N/A"))
                row.append(f"{res.get('time', 0.0):.2f}" if "time" in res else "N/A")
                row.append(res.get("detail", ""))
            writer.writerow(row)

    total_decks = len(decks)
    has_spooles = "SPOOLES" in active_solvers
    spooles_pass_rate = (stats["SPOOLES"]["PASS"] / total_decks * 100.0) if (has_spooles and total_decks > 0) else None
    spooles_time = stats.get("SPOOLES", {}).get("TOTAL_TIME", 0.0) if has_spooles else 0.0

    # 2. Compute Progression / Regression Stats vs SPOOLES
    solver_comparisons = {}
    if has_spooles:
        for s in active_solvers:
            if s == "SPOOLES":
                continue
            fixes = 0
            regressions = 0
            for d in decks:
                sp_st = results[d].get("SPOOLES", {}).get("status", "N/A")
                cur_st = results[d].get(s, {}).get("status", "N/A")
                if sp_st != "PASS" and cur_st == "PASS":
                    fixes += 1
                elif sp_st == "PASS" and cur_st != "PASS":
                    regressions += 1
            solver_comparisons[s] = {"fixes": fixes, "regressions": regressions}

    # 3. Write Markdown Summary
    with open(md_file, "w", encoding="utf-8") as f:
        f.write("# CalculiX Multi-Solver Verification Report\n\n")
        f.write(f"- **Execution Timestamp:** {timestamp_formatted}\n")
        f.write(f"- **Total Test Decks:** {total_decks}\n")
        f.write(f"- **Reference Solver:** `{'SPOOLES' if has_spooles else 'None (SPOOLES not selected)'}`\n\n")

        # Visual Plot Section
        if HAS_MATPLOTLIB:
            f.write("## 📊 Performance & Accuracy Overview\n\n")
            f.write("![Benchmark Overview](./solver_comparison.png)\n\n")

        # Overall Status Matrix
        f.write("## 📋 Solver Aggregate Matrix\n\n")
        f.write("| Solver | Pass | Diff | Fail | Timeout | Error | Pass Rate (%) | Total Time (s) |\n")
        f.write("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |\n")

        for s in active_solvers:
            st = stats[s]
            pass_rate = (st["PASS"] / total_decks * 100.0) if total_decks > 0 else 0.0
            badge = "🟢" if pass_rate >= 98.0 else ("🟡" if pass_rate >= 90.0 else "🔴")
            f.write(
                f"| **{s}** | {st['PASS']} | {st['DIFF']} | {st['FAIL']} | {st['TIMEOUT']} | "
                f"{st['ERROR']} | {badge} **{pass_rate:.1f}%** | {st['TOTAL_TIME']:.2f}s |\n"
            )

        # Baseline Comparison Breakdown (if SPOOLES was run)
        if has_spooles:
            f.write("\n## 🔍 Solver Progression vs SPOOLES Baseline\n\n")
            f.write("| Solver | Pass Rate Δ | Speedup Factor | Time Saved (s) | Fixes (vs SPOOLES Fail) | Regressions (vs SPOOLES Pass) |\n")
            f.write("| :--- | :---: | :---: | :---: | :---: | :---: |\n")

            for s in active_solvers:
                st = stats[s]
                pass_rate = (st["PASS"] / total_decks * 100.0) if total_decks > 0 else 0.0

                if s == "SPOOLES":
                    f.write(f"| **SPOOLES** *(Ref)* | `Baseline` (0.0%) | 1.00x | 0.00s | — | — |\n")
                else:
                    diff_val = pass_rate - spooles_pass_rate
                    if diff_val > 0:
                        delta_str = f"📈 **+{diff_val:.1f}%**"
                    elif diff_val < 0:
                        delta_str = f"📉 **{diff_val:.1f}%**"
                    else:
                        delta_str = "⚖️ **0.0%**"

                    speedup = (spooles_time / st["TOTAL_TIME"]) if st["TOTAL_TIME"] > 0 else 0.0
                    time_saved = spooles_time - st["TOTAL_TIME"]
                    saved_str = f"+{time_saved:.2f}s" if time_saved >= 0 else f"{time_saved:.2f}s"

                    comp = solver_comparisons[s]
                    f.write(
                        f"| **{s}** | {delta_str} | **{speedup:.2f}x** | {saved_str} | "
                        f"✅ {comp['fixes']} tests | ❌ {comp['regressions']} tests |\n"
                    )

        # Detailed Test Deck Table
        f.write("\n## 🧪 Detailed Test Deck Matrix\n\n")
        f.write("| Test Deck | " + " | ".join([f"{s} Status" for s in active_solvers]) + " |\n")
        f.write("| :--- | " + " | ".join([":---:" for _ in active_solvers]) + " |\n")

        for d in decks:
            deck_row = f"| `{d}` | "
            for s in active_solvers:
                res = results[d].get(s)
                if res:
                    icon = "✅" if res["status"] == "PASS" else ("⚠️" if res["status"] == "DIFF" else "❌")
                    deck_row += f"{icon} {res['status']} ({res['time']:.2f}s) | "
                else:
                    deck_row += "N/A | "
            f.write(deck_row + "\n")

    plot_file = generate_plots(stats, active_solvers, output_dir, timestamp_formatted)
    return csv_file, md_file, plot_file


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--pattern", nargs="+", help="Glob pattern(s) to filter test decks (e.g. 'achtel*' 'beam*')")
    parser.add_argument("--solvers", nargs="+", choices=["SPOOLES", "PARDISO", "MUMPS", "ACCELERATE", "ALL"], default=["ALL"])
    parser.add_argument("--threads-per-job", type=int, default=2, help="OpenMP threads per job (default: 2)")
    parser.add_argument("--max-workers", type=int, default=None, help="Max concurrent workers (default: physical_cores // threads_per_job)")
    parser.add_argument("--timeout", type=int, default=60, help="Per-test timeout in seconds (default: 60s)")
    parser.add_argument("--limit", type=int, default=None, help="Limit total number of decks to test")
    parser.add_argument("--output-dir", type=str, default=None, help="Custom output directory base (default: ./testsuite_results)")
    parser.add_argument("--custom-bin", type=str, default=None, help="Path to a specific CCX binary to test (overrides solver-specific builds)")
    args = parser.parse_args()

    ensure_test_suite()

    decks = find_test_decks(args.pattern)
    if args.limit:
        decks = decks[:args.limit]

    if not decks:
        print("[-] No test decks found matching criteria.")
        sys.exit(1)

    # 1. Filter solvers based on OS capabilities
    viable_solvers = get_viable_solvers()
    
    if "ALL" in args.solvers:
        target_solvers = viable_solvers
    else:
        target_solvers = []
        for s in args.solvers:
            if s in viable_solvers:
                target_solvers.append(s)
            else:
                print(f"[!] Warning: Solver '{s}' is not supported on this platform ({platform.system()} {platform.machine()}). Dropping from run.")
    
    if not target_solvers:
        print("[-] No viable solvers selected for this OS/Architecture. Exiting.")
        sys.exit(1)

    # 2. Check underlying OS libraries (Warnings only)
    check_solver_libraries(target_solvers, platform.system())

    # 3. Strict binary assignment
    active_solvers = {}
    for s in target_solvers:
        cfg = SOLVER_CONFIGS[s]
        
        if args.custom_bin:
            strict_bin_path = Path(args.custom_bin)
            if not strict_bin_path.is_absolute() and shutil.which(args.custom_bin):
                strict_bin_path = Path(shutil.which(args.custom_bin))
        else:
            strict_bin_path = CCX_DIR / f"build_{s.lower()}" / EXE_NAME
            
        active_solvers[s] = {**cfg, "bin": strict_bin_path}

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

    # Console Summary Table
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
    for s in active_solvers.keys():
        st = stats[s]
        total_runs = len(decks)
        pass_rate = (st["PASS"] / total_runs * 100) if total_runs else 0
        print(f"  * {s:<8}: {st['PASS']:3d} PASS | {st['DIFF']:2d} DIFF | {st['FAIL']:2d} FAIL | {st['TIMEOUT']:2d} TIMEOUT | Cumul Time: {st['TOTAL_TIME']:6.2f}s | Pass Rate: {pass_rate:5.1f}% ({st['PASS']}/{total_runs})")
    print(f"\nTotal Suite Wall-Clock Time: {total_wall:.2f} s across {max_workers} workers")
    print("=" * 80)

    # -------------------------------------------------------------------------
    # Save Artifacts & Reports (CSV, MD, Plots)
    # -------------------------------------------------------------------------
    now = datetime.datetime.now()
    timestamp_folder = now.strftime("%Y_%m_%d_%H_%M")
    timestamp_formatted = now.strftime("%Y-%m-%d %H:%M:%S")

    base_results_dir = Path(args.output_dir) if args.output_dir else (CCX_DIR / "testsuite_results")
    run_output_dir = base_results_dir / timestamp_folder

    # Explicitly set SPOOLES as the baseline if it's in the run
    baseline_solver = "SPOOLES" if "SPOOLES" in active_solvers else None

    csv_path, md_path, plot_path = save_reports(
        decks, active_solvers.keys(), results, stats, run_output_dir, timestamp_formatted, baseline_solver
    )

    print(f"\n[+] Results generated successfully in {run_output_dir}:")
    print(f"    - CSV     : {csv_path.name}")
    print(f"    - MD      : {md_path.name}")
    if plot_path:
        print(f"    - Chart   : {plot_path.name}")
    print("")

    # Diagnostics for failures
    failures = [(d, s, res) for d in decks for s, res in results[d].items() if res.get("status") == "FAIL" and res.get("stdout")]
    if failures:
        print("=" * 80)
        print(" ❌ Diagnostic Output for Failed Test Executions:")
        print("=" * 80)
        for d, s, res in failures:
            print(f"\n--- [{s}] {d} ({res['detail']}) ---")
            lines = res["stdout"].strip().splitlines()
            tail_lines = lines[-40:] if len(lines) > 40 else lines
            print("\n".join(tail_lines))
        print("=" * 80 + "\n")

    # GitHub CI Step Summary integration
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        try:
            with open(step_summary, "a", encoding="utf-8") as f:
                with open(md_path, "r", encoding="utf-8") as mdf:
                    f.write(mdf.read())
        except Exception as e:
            print(f"[!] Note: Could not write GitHub Step Summary: {e}")

    # Exit code determination
    total_fails = sum(st["FAIL"] + st["ERROR"] + st["TIMEOUT"] for st in stats.values())
    total_diffs = sum(st["DIFF"] for st in stats.values())
    total_passes = sum(st["PASS"] for st in stats.values())
    total_all = sum(len(decks) for _ in active_solvers)
    overall_pass_rate = (total_passes / total_all * 100) if total_all else 0

    if total_fails > 0:
        fail_details = ", ".join([f"{s}: {stats[s]['FAIL']+stats[s]['ERROR']+stats[s]['TIMEOUT']} failures" for s in active_solvers if (stats[s]['FAIL'] + stats[s]['ERROR'] + stats[s]['TIMEOUT']) > 0])
        print(f"::error title=Test Suite Failure (Crashes/Missing Binaries)::Overall Pass Rate: {overall_pass_rate:.1f}% ({total_passes}/{total_all}). Tests failed, crashed, or binaries were missing ({fail_details}).")
        sys.exit(2)
    elif total_diffs > 0:
        diff_details = ", ".join([f"{s}: {stats[s]['DIFF']} diff" for s in active_solvers if stats[s]['DIFF'] > 0])
        print(f"::warning title=Test Suite Notice (Numerical Diffs)::Overall Pass Rate: {overall_pass_rate:.1f}% ({total_passes}/{total_all}). {total_diffs} test(s) had numerical differences ({diff_details}).")
        sys.exit(1)
    else:
        print(f"::notice title=Test Suite Success::Overall Pass Rate: 100.0% ({total_passes}/{total_all}). All verification tests passed cleanly!")
        sys.exit(0)

if __name__ == "__main__":
    main()