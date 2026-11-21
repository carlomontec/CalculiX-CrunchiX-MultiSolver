#!/usr/bin/env python3
"""
3D Cantilever Beam Remesher via CalculiX GraphiX (CGX)
======================================================
Author: Dr. Carlo Monjaraz-Tec
Geometry: 20 x 20 x 200 mm solid steel cantilever beam (L/h = 10), C3D20R

Generates mesh files (all.msh, NFIX.nam, NTIP.nam, TOP.dlo) at specified
discretization levels using CGX in batch mode (-bg).
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

BEAM_DIR = Path(__file__).resolve().parent
REPO_ROOT = BEAM_DIR.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from benchmarks.compressor_rotor.remesh import find_cgx_binary

# Note: CGX quadratic hexahedra (he20r) consume 2 line divisions per element edge.
LEVEL_CONFIGS = {
    "coarse": {
        "nx": 16,
        "ny": 16,
        "nz": 64,
        "description": "Coarse resolution (8x8x32 = 2,048 C3D20R elements, ~29k DOFs, < 1 GB RAM)",
        "memory_target": "< 1 GB RAM",
    },
    "medium": {
        "nx": 32,
        "ny": 32,
        "nz": 128,
        "description": "Medium resolution (16x16x64 = 16,384 C3D20R elements, ~210k DOFs, ~2-4 GB RAM, ideal for 8-10 GB VM)",
        "memory_target": "< 5 GB RAM",
    },
    "fine": {
        "nx": 40,
        "ny": 40,
        "nz": 160,
        "description": "Fine resolution (20x20x80 = 32,000 C3D20R elements, ~405k DOFs, ~6-10 GB RAM, ideal for 16 GB Mac & 32 GB Linux)",
        "memory_target": "< 12 GB RAM",
    },
}

REQUIRED_ARTIFACTS = ("all.msh", "NFIX.nam", "NTIP.nam", "TOP.dlo")


def remesh(level="fine", cgx_bin=None):
    """Generate structured C3D20R cantilever beam mesh and sets via CGX."""
    if level not in LEVEL_CONFIGS:
        raise ValueError(f"Unknown level '{level}'. Choose from {list(LEVEL_CONFIGS.keys())}")

    cfg = LEVEL_CONFIGS[level]
    nx, ny, nz = cfg["nx"], cfg["ny"], cfg["nz"]
    print(f"[*] Meshing Cantilever Beam via CGX (Level: {level}, {nx}x{ny}x{nz})")
    print(f"    Description: {cfg['description']}")
    print(f"    Target RAM : {cfg['memory_target']}")

    if not cgx_bin:
        cgx_bin = find_cgx_binary()
    if not cgx_bin:
        print("[!] Error: CGX executable (cgx_glfw or cgx) not found!")
        print("    Please ensure CGX is installed or pass --cgx <path>")
        sys.exit(1)

    print(f"[*] Using CGX binary: {cgx_bin}")

    fbl_script = BEAM_DIR / f"mesh_{level}.fbl"
    script_content = f"""pnt p1 0 0 0
pnt p2 20 0 0
pnt p3 20 20 0
pnt p4 0 20 0
line l1 p1 p2 {nx}
line l2 p2 p3 {ny}
line l3 p3 p4 {nx}
line l4 p4 p1 {ny}
surf s0 blend l1 l2 l3 l4
seta src s s0
swep src swp tra 0 0 200 {nz}
elty all he20r
mesh all
seta FIX s s0
comp FIX do
seta NFIX n FIX
seta TIP s A001
comp TIP do
seta NTIP n TIP
seta TOP s A004
comp TOP do
comp TOP e
comp TOP f
send all abq
send NFIX abq nam
send NTIP abq nam
send TOP abq pres 0.2
quit
"""

    with open(fbl_script, "w", encoding="utf-8") as f:
        f.write(script_content)

    # Remove stale artifacts so non-empty checks reflect the current CGX run
    for fname in REQUIRED_ARTIFACTS:
        p = BEAM_DIR / fname
        if p.exists():
            p.unlink()

    print("[*] Executing CGX batch meshing...")
    res = subprocess.run(
        [str(cgx_bin), "-bg", str(fbl_script.name)],
        cwd=BEAM_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if res.returncode != 0:
        print(f"[!] CGX failed with exit code {res.returncode}:\n{res.stdout}")
        sys.exit(res.returncode)

    for fname in REQUIRED_ARTIFACTS:
        artifact = BEAM_DIR / fname
        if not artifact.is_file() or artifact.stat().st_size == 0:
            print(f"[!] Error: Required CGX output {artifact.name} missing or empty!")
            if res.stdout:
                print(res.stdout[-2000:])
            sys.exit(1)

    msh_file = BEAM_DIR / "all.msh"
    line_count = sum(1 for _ in open(msh_file, "rb"))
    print("[+] Meshing completed successfully!")
    print(f"    all.msh size: {msh_file.stat().st_size / (1024*1024):.2f} MB ({line_count:,} lines)")


def main():
    parser = argparse.ArgumentParser(description="Mesh 3D cantilever beam with CGX")
    parser.add_argument(
        "--level",
        choices=list(LEVEL_CONFIGS.keys()),
        default="fine",
        help="Discretization resolution level",
    )
    parser.add_argument("--cgx", type=Path, default=None, help="Path to CGX binary")
    args = parser.parse_args()

    remesh(level=args.level, cgx_bin=args.cgx)


if __name__ == "__main__":
    main()
