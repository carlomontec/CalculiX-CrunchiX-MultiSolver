#!/usr/bin/env python3
"""
Compressor Rotor Remesher via CalculiX GraphiX (CGX)
====================================================
Author: Dr. Carlo Monjaraz-Tec
Base Model: Klaus Wittig (lavff.fbd - 7-blade compressor rotor)

Generates mesh files (all.msh, SPC_23.bou, CYC1.nam, CYC2.nam) at specified
discretization levels using CGX in batch mode (-bg).
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROTOR_DIR = Path(__file__).resolve().parent
REPO_ROOT = ROTOR_DIR.parent.parent


def find_cgx_binary():
    """Locate the CGX binary in PATH, repository, or standard paths."""
    candidates = [
        REPO_ROOT.parent / "cgx" / "CalculiX-CGX-New3D" / "bin" / "cgx_glfw",
        REPO_ROOT.parent / "cgx" / "CalculiX-CGX-New3D" / "bin" / "cgx",
        REPO_ROOT.parent / "cgx" / "bin" / "cgx_glfw",
        REPO_ROOT.parent / "cgx" / "bin" / "cgx",
        Path("/Users/carlo/code/CalculiX/cgx/CalculiX-CGX-New3D/bin/cgx_glfw"),
        Path("/Users/carlo/code/CalculiX/cgx/CalculiX-CGX-New3D/bin/cgx"),
        Path("/usr/local/bin/cgx_glfw"),
        Path("/usr/local/bin/cgx"),
        Path("/usr/bin/cgx"),
        shutil.which("cgx_glfw"),
        shutil.which("cgx"),
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return Path(c).resolve()
    return None


LEVEL_CONFIGS = {
    "coarse": {
        "div_cmd": "",  # Baseline mesh (1,352 C3D20R elements, ~38.4k equations)
        "description": "Baseline resolution (~38k equations, ~500 MB RAM)",
        "memory_target": "< 2 GB RAM",
    },
    "medium": {
        "div_cmd": "div all auto 2.5\n",  # Adaptive auto element sizing
        "description": "Medium resolution (~100k equations, ~2-4 GB RAM, ideal for 8-10 GB VM)",
        "memory_target": "< 6 GB RAM",
    },
    "fine": {
        "div_cmd": "div all mult 2\n",  # 2x all line divisions (~300k equations)
        "description": "Fine resolution (~300k equations, ~8-12 GB RAM, ideal for 16 GB Mac & 32 GB Linux)",
        "memory_target": "< 14 GB RAM",
    },
}


def remesh(level="coarse", cgx_bin=None):
    if level not in LEVEL_CONFIGS:
        raise ValueError(f"Unknown level '{level}'. Choose from {list(LEVEL_CONFIGS.keys())}")

    cfg = LEVEL_CONFIGS[level]
    print(f"[*] Meshing Compressor Rotor via CGX (Level: {level})")
    print(f"    Description: {cfg['description']}")
    print(f"    Target RAM : {cfg['memory_target']}")

    if not cgx_bin:
        cgx_bin = find_cgx_binary()
    if not cgx_bin:
        print("[!] Error: CGX executable (cgx_glfw or cgx) not found!")
        print("    Please ensure CGX is installed or pass --cgx <path>")
        sys.exit(1)

    print(f"[*] Using CGX binary: {cgx_bin}")

    fbl_script = ROTOR_DIR / f"mesh_{level}.fbl"
    div_cmd = cfg["div_cmd"]

    script_content = f"""read lavff.fbd
del me
{div_cmd}elty all
elty all he20r
mesh all
send SPC abq spc 23
send CYC1 abq nam
send CYC2 abq nam
send all abq
quit
"""

    with open(fbl_script, "w", encoding="utf-8") as f:
        f.write(script_content)

    print(f"[*] Executing CGX batch meshing...")
    res = subprocess.run(
        [str(cgx_bin), "-bg", str(fbl_script.name)],
        cwd=ROTOR_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if res.returncode != 0:
        print(f"[!] CGX failed with exit code {res.returncode}:\n{res.stdout}")
        sys.exit(res.returncode)

    msh_file = ROTOR_DIR / "all.msh"
    if not msh_file.exists():
        print(f"[!] Error: {msh_file} was not generated!")
        sys.exit(1)

    line_count = sum(1 for _ in open(msh_file, "rb"))
    print(f"[+] Meshing completed successfully!")
    print(f"    all.msh size: {msh_file.stat().st_size / (1024*1024):.2f} MB ({line_count:,} lines)")


def main():
    parser = argparse.ArgumentParser(description="Mesh compressor rotor with CGX")
    parser.add_argument(
        "--level",
        choices=list(LEVEL_CONFIGS.keys()),
        default="coarse",
        help="Discretization resolution level",
    )
    parser.add_argument("--cgx", type=Path, default=None, help="Path to CGX binary")
    args = parser.parse_args()

    remesh(level=args.level, cgx_bin=args.cgx)


if __name__ == "__main__":
    main()
