# CalculiX CrunchiX Multi-Solver Edition

[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](LICENSE)
[![Platform: Linux (x86_64, ARM64) | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20x86__64%20%2F%20ARM64%20%7C%20macOS%20%7C%20Windows-brightgreen.svg)](#quick-install)
[![Solvers: MUMPS | Accelerate | PARDISO | SPOOLES](https://img.shields.io/badge/Solvers-MUMPS%20%7C%20Accelerate%20%7C%20PARDISO%20%7C%20SPOOLES-orange.svg)](#solver-backends)
[![SPOOLES x64 Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/spooles-x64.json)](#verification)
[![SPOOLES ARM Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/spooles-arm.json)](#verification)
[![MUMPS x64 Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/mumps-x64.json)](#verification)
[![MUMPS ARM Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/mumps-arm.json)](#verification)
[![PARDISO x64 Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/pardiso-x64.json)](#verification)
[![Accelerate Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/accelerate.json)](#verification)

[CalculiX CrunchiX (CCX)](https://www.dhondt.de/) is the open-source three-dimensional finite-element solver written by Dr. Guido Dhondt. This edition is based on the official **CalculiX 2.24** release ([provenance](docs/UPSTREAM_2.24.md)). It keeps his solver code unchanged, apart from one documented fix to the explicit stable time increment ([details](docs/CHANGES_VS_CCX.md#changes-that-can-affect-results)), and makes it easy to build and run fast on Linux, macOS and Windows.

The finite-element formulations, material models, contact algorithms, input syntax (`.inp`) and legacy outputs (`.dat`, `.frd`) are those of upstream CalculiX.

## Highlights

- **Build it yourself in one command, on any OS.** No prebuilt executable to download and trust: the installer fetches the source, installs the dependencies and compiles CalculiX on your machine, linked against the libraries that suit your hardware.
- **A real native Windows build.** The same source and the same CMake build as on Linux and macOS, compiled with MinGW-w64 (MSYS2 UCRT64) against MUMPS and OpenBLAS (or Intel oneMKL). No Cygwin, no virtual machine.
- **x86_64 and ARM.** Linux on x86_64 and ARM64 (aarch64), macOS on Apple Silicon, Windows on x86_64. The Linux ARM64 build is compiled and run against the full test suite in CI with MUMPS and SPOOLES, so it also runs on ARM servers and boards.
- **Hardware-aware linear algebra.** The build picks the fastest BLAS/LAPACK it can find: Apple Accelerate on Apple Silicon, **AMD AOCL-BLIS** on AMD Ryzen, Threadripper and EPYC, OpenBLAS elsewhere, or Intel oneMKL with PARDISO.
- **Modern sparse direct solvers.** MUMPS 5.x, Apple Accelerate and Intel oneMKL PARDISO next to the classic SPOOLES 2.2, selectable per analysis step. `arpack-ng` replaces the unmaintained ARPACK 96 for modal and buckling analyses.
- **Automated verification.** All 635 decks of Dr. Dhondt's official test suite run in parallel and are compared against Dr. Dhondt's reference results (`.dat.ref`, `.frd.ref`, within 0.1 %), in about 3 minutes on an 8-core Apple Silicon machine. Every solver backend and every upstream merge is checked this way.
- **JSON results for automated workflows.** One flag (`-j`) writes displacements, reaction forces, stresses and energies to a structured JSON file, ready for Python, Julia or MATLAB, with no `.dat` or `.frd` parsing ([example below](#json-export)).

## Compared with upstream CalculiX

Upstream CalculiX is the reference implementation, and this edition tracks it closely. The table shows what this edition adds, as of November 2026:

| | Upstream CalculiX | This edition |
|:---|:---|:---|
| **Build** | Makefiles, and an official CMake build since November 2026 (documented for Linux) | One CMake build for Linux (x86_64 and ARM64), macOS and Windows, plus one-line installers |
| **Sparse direct solvers** | SPOOLES, PARDISO, PaStiX | MUMPS, Apple Accelerate, PARDISO, SPOOLES |
| **BLAS/LAPACK** | Chosen by the user | Selected for the hardware (Accelerate, AOCL-BLIS, OpenBLAS, oneMKL) |
| **Windows** | Requires a manual toolchain setup | Installer sets up MSYS2 and builds natively |
| **Test suite** | `test/compare` shell script, decks run one after another, text comparison | Parallel runner, Dhondt's reference files and checkers, CI fails on any result not listed as a known difference, reports in Markdown/CSV/JSON |
| **Results** | `.dat`, `.frd` | `.dat`, `.frd`, and optional JSON |

## Contents

- [Quick install](#quick-install)
- [Solver backends](#solver-backends)
- [JSON export](#json-export)
- [Build system (CMake)](#build-system-cmake)
- [Verification](#verification)
- [Relationship to upstream CalculiX](#relationship-to-upstream-calculix)
- [Companion project: CalculiX GraphiX GLFW](#companion-project-calculix-graphix-glfw)
- [Documentation](#documentation)
- [About this project](#about-this-project)
- [Attribution and license](#attribution-and-license)

## Quick install

### Linux and macOS

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
```

The installer asks its questions first, then installs the required packages, builds with CMake and installs the `ccx` executable (default `~/.local/bin`). If you accept the shell-configuration prompt, that directory is added to your `PATH`.

### Windows (PowerShell)

The installer detects or installs MSYS2 and the MinGW-w64 toolchain. In a Windows PowerShell prompt:

```powershell
irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1 | iex
```

Prerequisites, installer options and manual builds are described in [INSTALL.md](INSTALL.md).

## Solver backends

### Linear equation solvers

| Backend | Linux | macOS (Apple Silicon) | Windows | Notes |
|:---|:---:|:---:|:---:|:---|
| **MUMPS 5.x** | System package (default) | Built from vendored source | MSYS2 package (default) | Recommended open-source solver. Performance depends on the BLAS library (see [INSTALL.md](INSTALL.md#blas-and-lapack-selection)). |
| **Apple Accelerate** | - | System framework (default) | - | Native macOS sparse solver. |
| **Intel oneMKL PARDISO** | Optional | - | Optional | Requires Intel oneMKL. |
| **SPOOLES 2.2** | System package | Built from vendored source | System package when available | Classic CalculiX solver, kept for compatibility. **Not recommended**: use MUMPS, Accelerate or PARDISO. Built multithreaded by default for speed; with more than one thread its results can differ from run to run ([details](INSTALL.md#spooles-and-multithreading)). |

Several backends can be compiled into one executable. A deck selects one explicitly with, for example, `*STATIC, SOLVER=MUMPS`; otherwise the build's default solver is used.

### Eigenvalue solver

Modal, frequency and buckling analyses use [`arpack-ng`](https://github.com/opencollab/arpack-ng), the maintained successor of ARPACK, installed from the system package manager.

## JSON export

Run CalculiX with `-j` (or set `CCX_JSON=1`) and it writes `<job>.json` next to the usual `.dat` and `.frd` files. Every `*NODE PRINT` and `*EL PRINT` request appears as a named array. Abbreviated output of the test deck `tensor_ro_dry`:

```bash
ccx -j tensor_ro_dry
```

```js
{
  "meta": { "jobname": "tensor_ro_dry", "solver": "SPOOLES", "success": true, ... },
  "steps": [{
    "step_number": 1, "type": "STATIC", "converged": true,
    "increments": [{
      "increment_number": 10, "step_time": 1.0,
      "node_sets": {
        "NALLN_U": {
          "field": "U", "nodes": [1, 2, 3, ...], "components": ["u1", "u2", "u3"],
          "values": [[0.0, 0.0, 0.0], [0.010, 0.0, 0.003], [0.028, -0.005, 0.003], ...]
        },
        "NALLN_RF": { "field": "RF", ... }
      },
      "element_sets": {
        "EALLE_S": {
          "field": "S", "components": ["sxx", "syy", "szz", "sxy", "syz", "szx"],
          "values": [{ "element": 1, "s": [1550.47, 895.85, 1201.44, 385.31, ...] }]
        }
      }
    }]
  }]
}
```

Reading it in Python takes three lines:

```python
import json
inc = json.load(open("tensor_ro_dry.json"))["steps"][0]["increments"][-1]
u = inc["node_sets"]["NALLN_U"]["values"]   # list of [u1, u2, u3] per node
```

The full schema and Julia/MATLAB examples are in [docs/JSON_EXPORT.md](docs/JSON_EXPORT.md).

## Build system (CMake)

This edition is built with a single top-level [`CMakeLists.txt`](CMakeLists.txt) on all three platforms. The installers are thin wrappers around it, and it can be used directly:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

What the build does:

- **Reads the source list from upstream's `src/Makefile.inc`**, so new or removed CalculiX source files are picked up automatically after each upstream sync.
- **Selects solvers per platform** through `CCX_USE_MUMPS`, `CCX_USE_ACCELERATE`, `CCX_USE_PARDISO` and `CCX_USE_SPOOLES`, and reports the enabled solvers and the default one at configure time.
- **Builds MUMPS and SPOOLES from pinned, checksum-verified source archives** on macOS, where no suitable system packages exist ([third_party/](third_party/)).
- **Chooses a BLAS/LAPACK library for the hardware** (`CCX_BLAS=AUTO`): Accelerate on Apple Silicon, AMD AOCL-BLIS on AMD Zen, OpenBLAS elsewhere, or oneMKL with PARDISO.

**Upstream CalculiX now has its own CMake build.** Since November 2026, Dr. Dhondt's CalculiX ships an official CMake build (`cmake/`, `CMakePresets.json`) with presets for GCC or Intel compilers, 32- or 64-bit integers, and the SPOOLES, PARDISO and PaStiX solvers. This is an important step for the CalculiX community. The build in this repository was developed independently and earlier, for a different scope (multiple solver backends, macOS and Windows). Both are kept in the tree: this edition's `CMakeLists.txt` is the supported build here, and upstream's `CMakeLists.txt` and `CMakePresets.json` ([cmake/upstream/](cmake/upstream/README.md)) and instructions ([doc/INSTALL_upstream.md](doc/INSTALL_upstream.md)) are preserved unchanged for reference.

All build options are listed in [INSTALL.md](INSTALL.md#building-with-cmake).

## Verification

Every change is checked against Dr. Dhondt's official test suite (the decks in [`test/`](test/)). The runner in [`test_NewLib/`](test_NewLib/) runs the decks in parallel and checks every result against Dr. Dhondt's reference files (`test/<deck>.dat.ref`, `.frd.ref`) with his own `datcheck.pl` / `frdcheck.pl` (within 0.1 % of the largest value in each block, same number of lines). In CI, a job fails if any deck does not pass and is not listed, with a reason, in [`test_NewLib/ci_known_failures/`](test_NewLib/ci_known_failures/README.md). Some decks differ from the reference files in plain CalculiX 2.24 too; they are listed there.

```bash
# Quick check: 20 decks
python3 test_NewLib/run_official_testsuite.py --custom-bin ccx --limit 20

# Full suite
python3 test_NewLib/run_official_testsuite.py --custom-bin ccx
```

Reports (Markdown, CSV, JSON) are written to `test_NewLib/testsuite_results/`. The badges at the top show the share of decks within tolerance of the reference files, per solver and platform, from the latest CI run on `main`. Full details are in [docs/VALIDATION.md](docs/VALIDATION.md).

## Benchmarks and verification reports

Benchmarks live in a separate repository, [CalculiX-CrunchiX-Benchmarks](https://github.com/carlomontec/CalculiX-CrunchiX-Benchmarks): the benchmark models and runner, solver timings and memory on several machines, the reports that show this edition gives the same results as official CalculiX, and longer studies. This repository keeps the code, the build system and the test suite.

## Relationship to upstream CalculiX

This repository is a fork of [Dhondtguido/CalculiX](https://github.com/Dhondtguido/CalculiX) and follows its development. Upstream changes are merged regularly with a real merge (not a copy), so upstream history and authorship are preserved. Each merge is verified against the full test suite and recorded in [docs/CHANGES_VS_CCX.md](docs/CHANGES_VS_CCX.md#10-upstream-synchronization-log). Last synchronized: November 2026 (upstream commit `57a4e71`, which is exactly the official ccx 2.24 release; see [docs/UPSTREAM_2.24.md](docs/UPSTREAM_2.24.md)).

The upstream `test/` directory is never modified; this edition's tests and tools live in `test_NewLib/`.

## Companion project: CalculiX GraphiX GLFW

![CalculiX GraphiX GLFW](pictures/cgx_glfw.png)

[CalculiX GraphiX GLFW](https://github.com/carlomontec/CalculiX-GraphiX-GLFW) is a version of the CalculiX pre- and post-processor (CGX) with a modern GLFW/OpenGL renderer. It also runs on Linux, macOS and Windows, and binaries are available.

## Documentation

| Document | Content |
|:---|:---|
| [INSTALL.md](INSTALL.md) | Prerequisites, installers, CMake options, BLAS selection, troubleshooting |
| [docs/VALIDATION.md](docs/VALIDATION.md) | Running the official test suite and reading the results |
| [docs/JSON_EXPORT.md](docs/JSON_EXPORT.md) | JSON result export and schema |
| [docs/CHANGES_VS_CCX.md](docs/CHANGES_VS_CCX.md) | Technical reference: everything that differs from upstream CCX, and the upstream sync log |
| [docs/MODERNIZATION.md](docs/MODERNIZATION.md) | Architecture and roadmap |
| [CalculiX-CrunchiX-Benchmarks](https://github.com/carlomontec/CalculiX-CrunchiX-Benchmarks) | Benchmark models, runner, results, verification reports and studies (separate repository) |
| [doc/](doc/) | Upstream CalculiX documentation (Dr. Dhondt) |

## About this project

The goal is a CalculiX that is easy to install on any major operating system and runs on modern, maintained numerical libraries, without changing the solver's validated physics.

The project was also developed as a practical exploration of the potential and the limitations of AI-assisted programming in a large scientific code base. AI tools were used for much of the new build, solver-interface and tooling code; every change is reviewed and verified against the official CalculiX test suite before it is merged.

## Attribution and license

CalculiX CrunchiX is free software under the GNU General Public License version 2 ([LICENSE](LICENSE)). CalculiX CrunchiX is written and maintained by Dr. Guido Dhondt; CalculiX GraphiX was created by Klaus Wittig. This edition is maintained by Dr. Carlo Monjaraz-Tec.

- CalculiX: [calculix.de](https://www.calculix.de) and [dhondt.de](https://www.dhondt.de)
- Community: [CalculiX Discourse](https://calculix.discourse.group)
- Theory: G. Dhondt, *The Finite Element Method for Three-Dimensional Thermomechanical Applications*, Wiley, 2004.

The solver libraries keep their own licenses: MUMPS is distributed under CeCILL-C, SPOOLES 2.2 is public domain, and Intel oneMKL and Apple Accelerate are subject to their vendors' license terms.
