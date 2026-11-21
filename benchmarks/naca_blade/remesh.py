#!/usr/bin/env python3
"""
3D Twisted & Tapered NACA 4-Digit Airfoil Blade Remesher via CGX
==================================================================
Author: Dr. Carlo Monjaraz-Tec
Geometry: Parametric lofted 3D compressor/fan blade (hub NACA 4415 -> tip NACA 2410)
          Span: 160 mm | Hub chord: 80 mm | Tip chord: 52 mm | Twist: 10 deg -> 42 deg

Generates structured quadratic hexahedral (C3D20R) blade geometry and mesh
artifacts (mesh_<level>.fbd, all.msh, NFIX.nam, NTIP.nam, PRES.dlo) via CGX.
"""

import argparse
import math
import subprocess
import sys
from pathlib import Path

BLADE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BLADE_DIR.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from benchmarks.compressor_rotor.remesh import find_cgx_binary

# CGX quadratic hexahedra (he20r) consume 2 line divisions per element edge.
LEVEL_CONFIGS = {
    "coarse": {
        "n_ch": 24,
        "n_th": 6,
        "n_sp_seg": 12,
        "description": "Coarse validation mesh (12x3x24 = 864 C3D20R elements, 4,723 nodes, 13,752 DOFs)",
        "memory_target": "< 256 MB RAM",
    },
    "medium": {
        "n_ch": 48,
        "n_th": 12,
        "n_sp_seg": 24,
        "description": "Medium resolution (24x6x48 = 6,912 C3D20R elements, ~32k nodes, ~95k DOFs)",
        "memory_target": "< 2 GB RAM",
    },
    "fine": {
        "n_ch": 96,
        "n_th": 22,
        "n_sp_seg": 46,
        "description": "Fine resolution (48x11x92 = 48,576 C3D20R elements, 212,475 nodes, 632,316 DOFs)",
        "memory_target": "~7.8-8.0 GB Peak RSS (8-10 GB Mac target)",
    },
    "ultra_fine": {
        "n_ch": 96,
        "n_th": 24,
        "n_sp_seg": 48,
        "description": "Ultra-fine resolution (48x12x96 = 55,296 C3D20R elements, ~715k DOFs, for 32 GB+ workstations)",
        "memory_target": "~13-14 GB RAM",
    },
}

REQUIRED_ARTIFACTS = ("all.msh", "NFIX.nam", "NTIP.nam", "PRES.dlo")
N_SEG = 4
SPAN_MM = 160.0
PRESSURE_MPA = 0.5


def naca4_section(s: float, n_interior: int = 11):
    """Return (upper_pts, lower_pts) in global (x, y, z) for normalized span s in [0, 1].

    upper_pts runs from leading-edge upper (xi=0.025) to trailing-edge upper (xi=1.0).
    lower_pts runs from leading-edge lower (xi=0.025) to trailing-edge lower (xi=1.0).
    """
    chord = 80.0 - 28.0 * s          # 80 mm -> 52 mm
    twist_deg = 10.0 + 32.0 * s      # 10 deg -> 42 deg
    m = 0.04 - 0.02 * s              # Camber: 4% -> 2%
    p = 0.40                         # Max camber at 40% chord
    t = 0.15 - 0.05 * s              # Thickness ratio: 15% -> 10%
    dx_sweep = 12.0 * (s ** 2)       # Smooth 3D lean/sweep
    z = s * SPAN_MM

    theta = math.radians(twist_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    x_stack = 0.25 * chord

    # Cosine clustering from xi_min=0.025 (blunt nose cap avoids 0-angle wedge elements) to 1.0
    xi_min = 0.025
    n_pts = n_interior + 2
    xis = [
        xi_min + (1.0 - xi_min) * 0.5 * (1.0 - math.cos(math.pi * i / (n_pts - 1)))
        for i in range(n_pts)
    ]

    upper_pts = []
    lower_pts = []
    for xi in xis:
        if xi < p:
            yc = (m / (p * p)) * (2.0 * p * xi - xi * xi)
            dyc = (2.0 * m / (p * p)) * (p - xi)
        else:
            yc = (m / ((1.0 - p) ** 2)) * ((1.0 - 2.0 * p) + 2.0 * p * xi - xi * xi)
            dyc = (2.0 * m / ((1.0 - p) ** 2)) * (p - xi)

        # Standard NACA thickness + gentle linear finite TE pad (~0.8-1.1 mm full TE thickness)
        yt = 5.0 * t * (
            0.2969 * math.sqrt(xi)
            - 0.1260 * xi
            - 0.3516 * (xi ** 2)
            + 0.2843 * (xi ** 3)
            - 0.1015 * (xi ** 4)
        ) + 0.006 * xi

        ang = math.atan(dyc)
        xu = (xi * chord) - (yt * chord) * math.sin(ang)
        yu = (yc * chord) + (yt * chord) * math.cos(ang)
        xl = (xi * chord) + (yt * chord) * math.sin(ang)
        yl = (yc * chord) - (yt * chord) * math.cos(ang)

        # Rotate about quarter-chord stacking axis and apply spanwise sweep
        def to_global(x_loc, y_loc):
            dx = x_loc - x_stack
            dy = y_loc
            xg = dx * cos_t - dy * sin_t + dx_sweep
            yg = dx * sin_t + dy * cos_t
            return (xg, yg, z)

        upper_pts.append(to_global(xu, yu))
        lower_pts.append(to_global(xl, yl))

    return upper_pts, lower_pts


def generate_fbd_script(level: str = "coarse") -> str:
    """Build complete CGX .fbd geometry + meshing script for the twisted NACA blade."""
    if level not in LEVEL_CONFIGS:
        raise ValueError(f"Unknown level '{level}'. Choose from {list(LEVEL_CONFIGS.keys())}")

    cfg = LEVEL_CONFIGS[level]
    n_ch = cfg["n_ch"]
    n_th = cfg["n_th"]
    n_sp_seg = cfg["n_sp_seg"]

    lines = [
        "# Parametric 3D Twisted & Tapered NACA Airfoil Blade",
        f"# Level: {level} ({cfg['description']})",
        "",
    ]

    # 1. Define airfoil stations k = 0..N_SEG
    for k in range(N_SEG + 1):
        s = k / N_SEG
        upper_pts, lower_pts = naca4_section(s, n_interior=11)
        lines.append(f"# --- Station {k} (s={s:.2f}, z={s * SPAN_MM:.1f} mm) ---")

        # 4 block corner points
        p_lu = f"p{k}_lu"
        p_tu = f"p{k}_tu"
        p_tl = f"p{k}_tl"
        p_ll = f"p{k}_ll"
        lines.append(f"pnt {p_lu} {upper_pts[0][0]:.6f} {upper_pts[0][1]:.6f} {upper_pts[0][2]:.6f}")
        lines.append(f"pnt {p_tu} {upper_pts[-1][0]:.6f} {upper_pts[-1][1]:.6f} {upper_pts[-1][2]:.6f}")
        lines.append(f"pnt {p_tl} {lower_pts[-1][0]:.6f} {lower_pts[-1][1]:.6f} {lower_pts[-1][2]:.6f}")
        lines.append(f"pnt {p_ll} {lower_pts[0][0]:.6f} {lower_pts[0][1]:.6f} {lower_pts[0][2]:.6f}")

        # Interior spline control points
        u_names = [p_lu]
        for j, pt in enumerate(upper_pts[1:-1], start=1):
            nm = f"u{k}_{j:02d}"
            lines.append(f"pnt {nm} {pt[0]:.6f} {pt[1]:.6f} {pt[2]:.6f}")
            u_names.append(nm)
        u_names.append(p_tu)

        l_names = [p_tl]
        l_int_names = []
        for j, pt in enumerate(lower_pts[1:-1], start=1):
            nm = f"l{k}_{j:02d}"
            lines.append(f"pnt {nm} {pt[0]:.6f} {pt[1]:.6f} {pt[2]:.6f}")
            l_int_names.append(nm)
        l_names.extend(reversed(l_int_names))
        l_names.append(p_ll)

        # Sequence sets for splines (all names <= 8 chars)
        lines.append(f"seqa sq{k}_u pnt " + " ".join(u_names))
        lines.append(f"seqa sq{k}_l pnt " + " ".join(l_names))

        # 4 boundary edges of station cross-section
        lines.append(f"line l{k}_le {p_ll} {p_lu} {n_th}")
        lines.append(f"line l{k}_su {p_lu} {p_tu} sq{k}_u {n_ch}")
        lines.append(f"line l{k}_te {p_tu} {p_tl} {n_th}")
        lines.append(f"line l{k}_pr {p_tl} {p_ll} sq{k}_l {n_ch}")
        lines.append(f"surf s{k} blend l{k}_le l{k}_su l{k}_te l{k}_pr")
        lines.append("")

    # 2. Loft 3D bodies between consecutive stations
    lines.append("# --- Lofted Spanwise Blocks ---")
    for k in range(N_SEG):
        lines.append(f"line v{k}_lu p{k}_lu p{k+1}_lu {n_sp_seg}")
        lines.append(f"line v{k}_tu p{k}_tu p{k+1}_tu {n_sp_seg}")
        lines.append(f"line v{k}_tl p{k}_tl p{k+1}_tl {n_sp_seg}")
        lines.append(f"line v{k}_ll p{k}_ll p{k+1}_ll {n_sp_seg}")

        lines.append(f"surf s{k}_le blend l{k}_le v{k}_lu l{k+1}_le v{k}_ll")
        lines.append(f"surf s{k}_su blend l{k}_su v{k}_tu l{k+1}_su v{k}_lu")
        lines.append(f"surf s{k}_te blend l{k}_te v{k}_tl l{k+1}_te v{k}_tu")
        lines.append(f"surf s{k}_pr blend l{k}_pr v{k}_ll l{k+1}_pr v{k}_tl")

        lines.append(f"body b{k} s{k} s{k+1} s{k}_le s{k}_su s{k}_te s{k}_pr")
        lines.append("")

    # 3. Mesh, sets, and CalculiX exports
    pr_surfs = " ".join(f"s{k}_pr" for k in range(N_SEG))
    lines.extend([
        "elty all he20r",
        "mesh all",
        "seta FIX s s0",
        "comp FIX do",
        "seta NFIX n FIX",
        f"seta TIP s s{N_SEG}",
        "comp TIP do",
        "seta NTIP n TIP",
        f"seta PRES s {pr_surfs}",
        "comp PRES do",
        "comp PRES e",
        "comp PRES f",
        "send all abq",
        "send NFIX abq nam",
        "send NTIP abq nam",
        f"send PRES abq pres {PRESSURE_MPA}",
        "quit",
        "",
    ])
    return "\n".join(lines)


def remesh(level="coarse", cgx_bin=None, write_only=False):
    """Generate .fbd geometry script and optionally mesh via CGX batch mode."""
    cfg = LEVEL_CONFIGS[level]
    print(f"[*] Generating NACA Blade geometry/mesh (Level: {level})")
    print(f"    Description: {cfg['description']}")
    print(f"    Target RAM : {cfg['memory_target']}")

    fbd_script = BLADE_DIR / f"mesh_{level}.fbd"
    script_content = generate_fbd_script(level=level)
    fbd_script.write_text(script_content, encoding="utf-8")
    print(f"[+] Wrote CGX script: {fbd_script.name}")

    if write_only:
        return fbd_script

    if not cgx_bin:
        cgx_bin = find_cgx_binary()
    if not cgx_bin:
        print("[!] Error: CGX executable (cgx_glfw or cgx) not found!")
        sys.exit(1)

    print(f"[*] Using CGX binary: {cgx_bin}")
    for fname in REQUIRED_ARTIFACTS:
        p = BLADE_DIR / fname
        if p.exists():
            p.unlink()

    res = subprocess.run(
        [str(cgx_bin), "-bg", fbd_script.name],
        cwd=BLADE_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if res.returncode != 0:
        print(f"[!] CGX failed with exit code {res.returncode}:\n{res.stdout}")
        sys.exit(res.returncode)

    for fname in REQUIRED_ARTIFACTS:
        artifact = BLADE_DIR / fname
        if not artifact.is_file() or artifact.stat().st_size == 0:
            print(f"[!] Error: Required CGX output {artifact.name} missing or empty!")
            if res.stdout:
                print(res.stdout[-2000:])
            sys.exit(1)

    msh_file = BLADE_DIR / "all.msh"
    line_count = sum(1 for _ in open(msh_file, "rb"))
    print("[+] Meshing completed successfully!")
    print(f"    all.msh size: {msh_file.stat().st_size / (1024*1024):.2f} MB ({line_count:,} lines)")
    return fbd_script


def main():
    parser = argparse.ArgumentParser(description="Generate & mesh 3D twisted NACA blade with CGX")
    parser.add_argument(
        "--level",
        choices=list(LEVEL_CONFIGS.keys()),
        default="coarse",
        help="Discretization resolution level",
    )
    parser.add_argument("--cgx", type=Path, default=None, help="Path to CGX binary")
    parser.add_argument("--write-only", action="store_true", help="Only write .fbd script without running CGX")
    args = parser.parse_args()

    remesh(level=args.level, cgx_bin=args.cgx, write_only=args.write_only)


if __name__ == "__main__":
    main()
