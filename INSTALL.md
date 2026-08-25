# Installation and Build Guide

This guide contains the detailed setup instructions for the CalculiX CrunchiX Multi-Solver Edition. For an overview, see [README.md](README.md).

## Requirements

### All platforms

- CMake 3.20 or newer
- A C compiler
- A Fortran compiler with preprocessing support
- ARPACK development files
- OpenMP, when available and desired

### macOS (Apple Silicon only)

The current macOS development target is Apple Silicon (`arm64`). Intel macOS is not supported by this project configuration, and Intel MKL/PARDISO is not used on macOS.

Install the build tools with Homebrew:

```bash
brew install cmake gcc arpack
```

Apple Accelerate is provided by macOS. MUMPS and SPOOLES are built from the pinned archives in `third_party/` when their vendor options are enabled. Homebrew is not required for either solver.

### Linux

Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y build-essential gfortran cmake libopenblas-dev liblapack-dev libarpack2-dev libmumps-seq-dev
```

Fedora/RHEL:

```bash
sudo dnf install -y gcc gcc-gfortran cmake openblas-devel lapack-devel arpack-devel MUMPS-devel
```

Arch Linux:

```bash
sudo pacman -S --needed base-devel gcc-fortran cmake openblas lapack arpack mumps
```

For legacy SPOOLES on Linux, install the distribution package when available, for example `libspooles-dev`, `spooles-devel`, or `spooles`.

### Windows

From an MSYS2 UCRT64 shell:

```bash
pacman -S --needed mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gcc-fortran mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-arpack mingw-w64-ucrt-x86_64-mumps
```

## Automated Installation

Linux and macOS:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1 | iex
```

The scripts detect the platform, configure the selected solver backend, build CalculiX, and install `ccx` into a user-local directory.

## Manual CMake Builds

Use a separate build directory for each solver configuration. This avoids stale cache options and keeps solver binaries unambiguous.

### macOS Apple Silicon Accelerate

```bash
cmake -S . -B build_accelerate \
  -DCCX_USE_ACCELERATE=ON \
  -DCCX_USE_MUMPS=OFF \
  -DCCX_USE_SPOOLES=OFF
cmake --build build_accelerate --parallel
```

### macOS vendored MUMPS

```bash
cmake -S . -B build_mumps \
  -DCCX_USE_ACCELERATE=OFF \
  -DCCX_USE_MUMPS=ON \
  -DCCX_MUMPS_VENDORED=ON \
  -DCCX_USE_SPOOLES=OFF
cmake --build build_mumps --parallel
```

### macOS vendored SPOOLES

```bash
cmake -S . -B build_spooles \
  -DCCX_USE_ACCELERATE=OFF \
  -DCCX_USE_MUMPS=OFF \
  -DCCX_USE_SPOOLES=ON \
  -DCCX_SPOOLES_VENDORED=ON
cmake --build build_spooles --parallel
```

### Linux MUMPS and system SPOOLES

```bash
cmake -S . -B build_mumps -DCCX_USE_MUMPS=ON -DCCX_USE_ACCELERATE=OFF
cmake --build build_mumps --parallel

cmake -S . -B build_spooles -DCCX_USE_SPOOLES=ON -DCCX_USE_ACCELERATE=OFF
cmake --build build_spooles --parallel
```

### Intel oneMKL PARDISO

Install oneMKL using your operating system's supported package or repository, then configure:

```bash
cmake -S . -B build_pardiso -DCCX_USE_PARDISO=ON
cmake --build build_pardiso --parallel
```

The executable is written to `build_<solver>/CalculiX`.

## Selecting a Solver

A deck may select a compiled backend explicitly:

```text
*STATIC, SOLVER=MUMPS
```

Supported values are `MUMPS`, `ACCELERATE`, `SPOOLES`, and `PARDISO` when the corresponding backend was compiled.

If no solver is specified, the compiled default is selected. The current CMake defaults are Apple Accelerate on macOS and MUMPS on Linux and Windows. MUMPS is the current macOS candidate for the primary open-source default; the official suite should be used to validate any default change.

## Verification

The official runner requires a solver-specific binary in each `build_<solver>` directory:

```bash
python3 test_NewLib/run_official_testsuite.py \
  --solvers ACCELERATE MUMPS SPOOLES \
  --threads-per-job 2
```

See all runner options and usage details with:

```bash
python3 test_NewLib/run_official_testsuite.py --help
```

For focused timing experiments, use:

```bash
python3 test_NewLib/benchmark_solvers.py \
  --solvers MUMPS ACCELERATE SPOOLES \
  --threads 1 2 4 6
```

## Troubleshooting

- If CMake reports paths from an old directory, remove and recreate the affected `build_<solver>` directory.
- Do not use one build directory for multiple solver configurations.
- If a solver binary is missing, build the matching directory before running the official suite.
- Use `NO_COLOR=1` when terminal output is being captured by a tool that does not support ANSI colors.
- Check `failure_diagnostics.txt` in the generated results directory for solver runtime output.
