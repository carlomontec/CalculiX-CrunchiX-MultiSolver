# Parametric 3D NACA Blade Linear Static Benchmark

**Model**: Lofted, Twisted & Tapered NACA 4-Digit Airfoil Blade (Hub `NACA 4415` -> Tip `NACA 2410`)  
**Physics**: Pure Linear Static Aerodynamic Pressure Bending & Torsion (`*STATIC`, `0.5 MPa` on Pressure Face)  
**Element Type**: `C3D20R` (20-node Quadratic Hexahedral with Reduced Integration)  
**Material**: Ti-6Al-4V (`E = 114,000 MPa`, `nu = 0.34`, `rho = 4.43e-9 t/mm^3`)

---

## 1. Purpose and Complementarity

In the cyclic compressor rotor benchmark ([`compressor_rotor/lavffcyc.inp`](../compressor_rotor/lavffcyc.inp)), Step 2 runs a prestressed cyclic-symmetry modal extraction (`*FREQUENCY`). Because ARPACK/Lanczos executes dozens of sequential triangular forward/backward substitutions alongside large `.frd` writes, total runtime includes substantial non-factorization work.

This `naca_blade` case uses a single pure `*STATIC` step (`K u = f`) with **632,316 equations** on a curved, multi-block 3D turbomachinery geometry. It directly isolates sparse direct solver symbolic ordering, numerical factorization memory footprint, and thread scaling without Lanczos iteration overhead.

---

## 2. Parametric Geometry and Structured Hex Topology

The generator script [`remesh.py`](remesh.py) constructs 5 airfoil stations along the span ($z \in [0, 160]\text{ mm}$, segmented into `4` lofted bodies) and writes a clean CGX `.fbd` script (`mesh_<level>.fbd`):

| Geometric Parameter | Hub ($s = 0.0$) | Tip ($s = 1.0$) | Formula |
| :--- | :---: | :---: | :--- |
| **Chord $c(s)$** | `80.0 mm` | `52.0 mm` | $80 - 28 s$ |
| **Twist $\theta(s)$** | `10.0 deg` | `42.0 deg` | $10^\circ + 32^\circ s$ (about quarter-chord) |
| **Max Camber $m(s)$** | `4.0%` | `2.0%` | $0.04 - 0.02 s$ (peak at $p = 0.40$) |
| **Thickness $t(s)$** | `15.0%` | `10.0%` | $0.15 - 0.05 s$ |
| **3D Axial Sweep $\Delta x(s)$** | `0.0 mm` | `12.0 mm` | $12 s^2$ |

To keep all hexahedral elements strictly valid (positive Jacobian, zero pinched corner wedges), each NACA cross-section is built as a **4-sided structured topology** rather than collapsing leading/trailing edges to zero thickness:
- **Suction & Pressure Sides (`l{k}_su`, `l{k}_pr`)**: Cosine-clustered points from $\xi = 0.025$ to $1.0$ joined through CGX point sequences (`seqa` + spline `line`), giving 11 interior control points per side.
- **Leading & Trailing Caps (`l{k}_le`, `l{k}_te`)**: Blunt leading cap at $\xi = 0.025$ and finite trailing-edge thickness (`+ 0.006 * xi` normalized), closing each station into a 4-edge `surf ... blend`.
- **Spanwise Lofting (`b0..b3`)**: Explicit connecting edges, side surfaces (`s{k}_le`, `s{k}_su`, `s{k}_te`, `s{k}_pr`), and `body` blocks so `PRES` directly addresses the 4 pressure-side faces for `send PRES abq pres 0.5`.

Note on CGX quadratic divisions: `he20r` consumes **2 line divisions per element edge**, so `fine` divisions `(n_ch=96, n_th=22, n_sp_seg=46)` produce `(48 x 11 x 92)` elements across the 4 spanwise blocks (`48,576` elements total).

---

## 3. How the `calculix` MCP Server Was Used

This model was designed, debugged, and validated interactively using the **`calculix` MCP server**:

1. **Syntax Verification via `cgx_help`**:
   - Queried `line`, `body`, `Sets`, `Surfaces`, and `Rules of the batch run` topics before writing the generator.
   - Confirmed critical CGX constraints upfront: 8-character entity name limit, `SEQA <seq> pnt <p_start> ... <p_end>` spline sequence ordering for curved airfoil lines, explicit `surf ... blend`, and `comp <set> do` / `comp <set> e` / `comp <set> f` completion so `send NFIX abq nam` and `send PRES abq pres 0.5` capture all corner, midside, and boundary face entities.

2. **Headless Mesh Generation Check (`cgx_run_batch` note)**:
   - Tested calling `cgx_run_batch` on `mesh_coarse.fbd`. In this local environment the MCP server was launched without `--cgx <abs_path>`, returning `TOOL_DISABLED` (`no CalculiX GraphiX binary is configured`). Passing `--cgx /path/to/cgx_glfw` at MCP server startup enables full in-sandbox batch meshing via `cgx_run_batch`; `remesh.py --write-only` generates standalone `.fbd` scripts ready for direct `cgx_run_batch` execution.

3. **Pre-Solve Topology & Quality Gate via `mesh_check`**:
   - Ran `mesh_check` on `blade_static.inp` at both `coarse` (`864` elements) and calibrated `fine` (`48,576` elements) before any full benchmark sweep.
   - Verified on `fine`:
     - `verdict: "OK"`, `problems.total = 0`
     - `1` connected part, `0` free nodes, `0` unassigned elements
     - `0` non-positive volume (inverted) elements (`max_aspect: 26.16` at the thin trailing-edge tip)
     - Volume `65,867.21 mm^3`, mass `2.918e-4 t` (`0.292 kg`)

4. **Post-Solve Envelope Verification via `frd_summary`**:
   - After solving with `build_accelerate/CalculiX` and `build_mumps/CalculiX`, queried `blade_static.frd` directly via `frd_summary`:
     - Exact peak displacement: `u_max = 5.7097 mm` (node `161663`)
     - Exact peak von Mises stress: `vm_max = 460.54 MPa` (node `34214`)

---

## 4. Discretization Levels

| Level | CGX Divisions `(n_ch, n_th, n_sp_seg)` | `C3D20R` Elements | Nodes | Static Equations (DOFs) | Measured Peak RSS (4T on M3 16 GB) |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **`coarse`** | `24, 6, 12` | `864` | `4,723` | `13,752` | `< 256 MB` (`0.19 s` Accelerate) |
| **`medium`** | `48, 12, 24` | `6,912` | `~32k` | `~95k` | `< 2 GB` (target for 8-10 GB ARM VM) |
| **`fine`** *(cross-platform standard)* | `96, 22, 46` | `48,576` | `212,475` | `632,316` | `7,777 MB` (Accelerate, `116.1 s`) / `7,995 MB` (MUMPS, `55.2 s`) |
| **`ultra_fine`** *(32 GB+ workstations)* | `96, 24, 48` | `55,296` | `~241k` | `~715k` | `~13-14 GB` (exceeds comfortable 16 GB Mac headroom) |

*(Calibration note: `fine` with `48,576` elements is the unified cross-platform benchmark level used across all machines—keeping both Accelerate and MUMPS 4T centered at `~7.8-8.0 GB` Peak RSS—while `ultra_fine` preserves the `55,296`-element configuration for 32 GB+ Linux and Windows workstations.)*

---

## 5. Quick Start

Generate mesh only (or `--write-only` for `cgx_run_batch`):
```bash
python3 benchmarks/naca_blade/remesh.py --level fine
```

Run the multi-solver `*STATIC` benchmark (saves JSON and one `.frd` in a datetime folder under `benchmarks/results/`):
```bash
python3 benchmarks/runner/run_benchmark.py --case naca_blade --level fine --threads 1 2 4 8 --out-dir benchmarks/results/$(date +%Y-%m-%d_%H-%M)_naca --save-frd
```

Visualize deformed shape and von Mises stress contours in CalculiX GraphiX:
```bash
cgx_glfw benchmarks/naca_blade/blade_static.frd
```
