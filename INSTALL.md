# Installation and Build Guide

This guide covers installing and building the CalculiX CrunchiX Multi-Solver Edition. For an overview of the project, see [README.md](README.md).

- [1. Automated installation](#1-automated-installation)
- [2. Prerequisites](#2-prerequisites)
- [3. Building with CMake](#3-building-with-cmake)
- [4. BLAS and LAPACK selection](#blas-and-lapack-selection)
- [5. Selecting a solver at run time](#5-selecting-a-solver-at-run-time)
- [6. Upstream CMake build (Dr. Dhondt)](#6-upstream-cmake-build-dr-dhondt)
- [7. Verifying a build](#7-verifying-a-build)
- [8. Troubleshooting](#8-troubleshooting)

## 1. Automated installation

The installers ask all questions first, then install the required packages, configure and build with CMake, and install the `ccx` executable. Missing optional solvers produce a warning rather than an error, and the solvers that were actually built are reported at the end.

### Linux and macOS

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
```

Options, when running a local copy of `install.sh`:

| Option | Meaning |
|:---|:---|
| `--prefix <dir>` | Install prefix; the binary goes to `<dir>/bin` (default `~/.local`) |
| `-b`, `--ref <ref>` | Git branch, tag or commit to build (default `main`, or environment variable `CCX_REF`) |
| `-y`, `--yes` | Accept all defaults without prompting (or `NON_INTERACTIVE=1`) |
| `-j`, `--jobs <n>` | Parallel build jobs (default: all cores) |

With the one-line command, set the reference through the environment, e.g. `CCX_REF=<branch-or-tag> /bin/bash -c "$(curl -fsSL ...)"`.

### Windows

In a Windows PowerShell prompt:

```powershell
$script = irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1
$script | Out-File -FilePath install.ps1 -Encoding utf8
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```

Saving the script with UTF-8 encoding before running it avoids parsing errors in Windows PowerShell. The installer detects or installs MSYS2 and the MinGW-w64 UCRT64 toolchain.

## 2. Prerequisites

Only needed for manual builds; the installers take care of this.

All platforms need:

- CMake 3.20 or newer
- C and Fortran compilers (Fortran with preprocessing support), with OpenMP when available
- `arpack-ng` development files
- BLAS/LAPACK and at least one sparse direct solver (see below)

### macOS (Apple Silicon)

The macOS target is Apple Silicon (`arm64`); Intel Macs are not supported.

```bash
brew install cmake gcc arpack
```

Apple Accelerate is part of macOS. MUMPS and SPOOLES are built from the pinned source archives in [`third_party/`](third_party/), so no Homebrew packages are needed for them.

### Linux

Ubuntu / Debian:

```bash
sudo apt-get update
sudo apt-get install -y build-essential gfortran cmake libopenblas-dev liblapack-dev libarpack2-dev libmumps-seq-dev
# Optional, for AMD Zen CPUs (Ryzen / EPYC / Threadripper):
sudo apt-get install -y libblis-openmp-dev libflame-dev
```

Fedora / RHEL:

```bash
sudo dnf install -y gcc gcc-gfortran cmake openblas-devel lapack-devel arpack-devel MUMPS-devel
# Optional, for AMD Zen CPUs:
sudo dnf install -y blis-devel libflame-devel
```

Arch Linux:

```bash
sudo pacman -S --needed base-devel gcc-fortran cmake openblas lapack arpack mumps
```

For SPOOLES, install the distribution package when available (`libspooles-dev`, `spooles-devel` or `spooles`).

### Windows (MSYS2 UCRT64 shell)

```bash
pacman -S --needed mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gcc-fortran \
  mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-arpack mingw-w64-ucrt-x86_64-mumps
```

## 3. Building with CMake

The top-level [`CMakeLists.txt`](CMakeLists.txt) is the build for all platforms. A default build:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

The executable is `build/CalculiX`. At configure time CMake prints the enabled solvers and the default solver (`Enabled direct solvers: ...`, `Default direct solver: ...`).

The C and Fortran source list is read from upstream's `src/Makefile.inc`, so the build follows upstream source changes without edits. Files that upstream builds outside that list (currently `src/buildinfo.c`, which records the compile time) are added explicitly.

### Options

| Option | Default | Meaning |
|:---|:---|:---|
| `CCX_USE_MUMPS` | `ON` on Linux/Windows, `OFF` on macOS | MUMPS sparse direct solver |
| `CCX_USE_ACCELERATE` | `ON` on macOS | Apple Accelerate sparse solver (macOS only) |
| `CCX_USE_PARDISO` | `OFF` | Intel oneMKL PARDISO |
| `CCX_USE_SPOOLES` | `OFF` | Classic SPOOLES 2.2 solver |
| `CCX_MUMPS_VENDORED` | `ON` on macOS | Build MUMPS from `third_party/mumps` |
| `CCX_SPOOLES_VENDORED` | `ON` on macOS | Build SPOOLES from `third_party/spooles` |
| `CCX_USE_ARPACK` | `ON` | `arpack-ng` eigenvalue solver |
| `CCX_USE_OPENMP` | `ON` | OpenMP multithreading |
| `CCX_INT64` | `OFF` | 64-bit integers (only for very large models; all libraries must be 64-bit builds) |
| `CCX_BLAS` | `AUTO` | BLAS/LAPACK: `AUTO`, `BLIS`, `OPENBLAS`, `MKL`, `NETLIB` |
| `CCX_SOLVERS_STRICT` | `ON` | Fail if a requested solver is not found; `OFF` disables it with a warning |

Several solvers can be enabled in one build. The default solver, used when a deck does not name one, is the first enabled in this order: Accelerate, PARDISO, MUMPS, SPOOLES.

### Example configurations

Use a separate build directory for each configuration; this avoids stale cache entries and keeps the binaries apart. The test-suite runner expects these `build_<solver>` names.

macOS, Apple Accelerate (default):

```bash
cmake -S . -B build_accelerate -DCCX_USE_ACCELERATE=ON -DCCX_USE_MUMPS=OFF -DCCX_USE_SPOOLES=OFF
cmake --build build_accelerate --parallel
```

macOS, vendored MUMPS:

```bash
cmake -S . -B build_mumps -DCCX_USE_ACCELERATE=OFF -DCCX_USE_MUMPS=ON -DCCX_MUMPS_VENDORED=ON -DCCX_USE_SPOOLES=OFF
cmake --build build_mumps --parallel
```

macOS, vendored SPOOLES:

```bash
cmake -S . -B build_spooles -DCCX_USE_ACCELERATE=OFF -DCCX_USE_MUMPS=OFF -DCCX_USE_SPOOLES=ON -DCCX_SPOOLES_VENDORED=ON
cmake --build build_spooles --parallel
```

Linux, MUMPS or system SPOOLES:

```bash
cmake -S . -B build_mumps -DCCX_USE_MUMPS=ON
cmake --build build_mumps --parallel

cmake -S . -B build_spooles -DCCX_USE_MUMPS=OFF -DCCX_USE_SPOOLES=ON
cmake --build build_spooles --parallel
```

Intel oneMKL PARDISO (Linux / Windows), after installing oneMKL:

```bash
cmake -S . -B build_pardiso -DCCX_USE_PARDISO=ON
cmake --build build_pardiso --parallel
```

### Makefile

`src/Makefile` is upstream's classic Makefile with local paths for a macOS development setup. It is not maintained as a portable build; use CMake.

<a id="blas-and-lapack-selection"></a>
## 4. BLAS and LAPACK selection

Sparse direct solvers, MUMPS in particular, spend most of the factorization time in dense BLAS level-3 kernels (`DGEMM`, `DSYRK`, `DTRSM`). An unoptimized reference BLAS can make them several times slower, so the build selects an optimized library with `CCX_BLAS` (default `AUTO`):

| Platform | `AUTO` selects |
|:---|:---|
| macOS (Apple Silicon) | Apple Accelerate |
| Linux, AMD Zen CPUs | AMD AOCL-BLIS (fallback: OpenBLAS) |
| Linux, other x86_64 and arm64 | OpenBLAS (fallback: Intel MKL) |
| Windows (MSYS2 UCRT64) | OpenBLAS or BLIS |
| Any platform with `CCX_USE_PARDISO=ON` | Intel oneMKL (for PARDISO and MUMPS) |

To force a library:

```bash
cmake -S . -B build_mumps -DCCX_USE_MUMPS=ON -DCCX_BLAS=BLIS      # or OPENBLAS, MKL
```

On Debian and Ubuntu, the system MUMPS library resolves BLAS through `/etc/alternatives/libblas.so.3-<arch>`. `install.sh` checks that this points to an optimized library (`openblas-pthread` or `blis-openmp`) rather than the reference BLAS.

## 5. Selecting a solver at run time

A deck can request a compiled solver explicitly:

```text
*STATIC, SOLVER=MUMPS
```

Valid values are `MUMPS`, `ACCELERATE`, `PARDISO` and `SPOOLES`, for solvers that were compiled in. Without `SOLVER=`, the build's default solver is used (see [Options](#options)).

## 6. Upstream CMake build (Dr. Dhondt)

Since November 2026, upstream CalculiX includes its own CMake build: `cmake/` (find modules and flags), `CMakePresets.json` (`gnu-lp64`, `gnu-ilp64`, `intel-llvm-lp64`, `intel-llvm-ilp64`) and its own `CMakeLists.txt`. It supports SPOOLES, PARDISO and PaStiX, and is tested upstream on Linux.

In this repository, the top-level `CMakeLists.txt` is this edition's build, which was developed independently and covers more solvers and platforms. Upstream's `cmake/` directory and `CMakePresets.json` are kept unchanged for reference, and upstream's build instructions are preserved in [doc/INSTALL_upstream.md](doc/INSTALL_upstream.md). To build plain upstream CalculiX with its own CMake, use the [upstream repository](https://github.com/Dhondtguido/CalculiX).

## 7. Verifying a build

Run the official test suite against a binary:

```bash
python3 test_NewLib/run_official_testsuite.py --custom-bin build/CalculiX
```

Or compare several solver builds (expects `build_<solver>/CalculiX`):

```bash
python3 test_NewLib/run_official_testsuite.py --solvers ACCELERATE MUMPS SPOOLES --threads-per-job 2
```

When running many small decks, parallelize by process and keep one thread per job (`OMP_NUM_THREADS=1`, `CCX_NPROC_EQUATION_SOLVER=1`). All options: `python3 test_NewLib/run_official_testsuite.py --help`. For timing experiments, use `test_NewLib/benchmark_solvers.py`. See [docs/VALIDATION.md](docs/VALIDATION.md) for details.

## 8. Troubleshooting

- **CMake reports paths from an old directory:** delete and recreate that build directory.
- **Wrong solver in a build:** do not reuse one build directory for different solver configurations.
- **A requested solver is not found:** install its development package, or configure with `-DCCX_SOLVERS_STRICT=OFF` to build without it.
- **Test runner reports a missing binary:** build the matching `build_<solver>` directory first.
- **Garbled colors in captured output:** set `NO_COLOR=1`.
- **Solver runtime errors in the test suite:** see `failure_diagnostics.txt` in the results directory.
