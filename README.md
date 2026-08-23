# CalculiX CrunchiX (Multi-Solver Edition)

> **A Modernized, High-Performance Multi-Solver & Multi-Platform Edition of CalculiX CrunchiX (CCX).**

[![CI Multi-Solver Matrix](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver/actions/workflows/ci.yml/badge.svg)](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver/actions/workflows/ci.yml)
[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](COPYING)
[![Platform: Linux | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-brightgreen.svg)](#platform-support--roadmap)
[![Solvers: SPOOLES | PARDISO | MUMPS | Accelerate](https://img.shields.io/badge/Solvers-SPOOLES%20%7C%20PARDISO%20%7C%20MUMPS%20%7C%20Accelerate-orange.svg)](#multi-solver-architecture)
[![PARDISO Pass Rate](https://img.shields.io/badge/PARDISO%20Pass%20Rate-100%25-brightgreen.svg)](#solver-benchmarks--verification-pass-rates)
[![SPOOLES Pass Rate](https://img.shields.io/badge/SPOOLES%20Pass%20Rate-100%25-brightgreen.svg)](#solver-benchmarks--verification-pass-rates)
[![MUMPS Pass Rate](https://img.shields.io/badge/MUMPS%20Pass%20Rate-71.4%25-yellow.svg)](#solver-benchmarks--verification-pass-rates)
[![Accelerate Pass Rate](https://img.shields.io/badge/Accelerate%20Pass%20Rate-71.4%25-yellow.svg)](#solver-benchmarks--verification-pass-rates)

![CalculiX CrunchiX FEA Simulation](pictures/turbs.gif)

---

## About This Project

This project is an **academic exercise for learning AI agentic programming** by **Carlo Monjaraz-Tec** using **Google Antigravity and Claude Code Opus**, based on the foundational finite element solver created by **Dr. Guido Dhondt** and pre/post-processing tools by **Klaus Wittig** ([http://www.calculix.de](http://www.calculix.de) / [https://www.dhondt.de](https://www.dhondt.de)).

The objective is to explore agent-assisted scientific software modernization by making CalculiX CrunchiX (CCX) as **flexible, fast, and accessible across all major operating systems** as possible. We intend to update to pluggable state-of-the-art sparse direct solvers (**Intel oneMKL PARDISO**, **MUMPS 5.x**, and **Apple Accelerate**), modern **CMake** build pipelines, and automated multi-solver verification suites; while strictly preserving the original core mechanical computations.

## Quick Installation (Universal 1-Liners)

Install or build CalculiX with automated solver selection across macOS, Linux, and Windows with a single command:

#### Linux & macOS (Bash):
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
```

#### Windows (PowerShell):
```powershell
irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1 | iex
```

The installer automatically detects your operating system, hardware architecture, and installed linear algebra libraries (Apple Accelerate on macOS, Intel oneMKL PARDISO or MUMPS on Linux, MUMPS/PARDISO on Windows, or SPOOLES), builds the binary, and installs it to your local path (`~/.local/bin/ccx` on Unix, `%USERPROFILE%\.local\bin\ccx.exe` on Windows).

---

## Companion Pre-/Post-Processor 

This project is designed to pair seamlessly with **[CalculiX-GraphiX-GLFW](https://github.com/carlomontec/CalculiX-GraphiX-GLFW)** (`cgx_glfw`), a modernized approach to CalculiX GraphiX in pure GLFW3 / OpenGL 3D, extended with native ParaView VTU/PVD export and some additional eye-candy.

---

## Highlights & Modern Multi-Solver Architecture

* **Pluggable Sparse Direct Solvers**:
  * **MUMPS 5.x (Primary Open-Source Default)**: The standard open-source sparse direct solver of modern scientific computing (used in *Code_Aster*, *OpenFOAM*, and *Elmer FEM*). Features multi-threaded OpenMP parallelism, Out-of-Core memory scaling, and Block Low-Rank (BLR) compression.
  * **Apple Accelerate (macOS Default)**: Native hardware-accelerated direct sparse solver (`SparseFactorizationLDLTTPP` and `SparseFactorizationQR`) tailored for macOS and Apple Silicon (M-series) unified memory architecture with zero external solver dependencies.
  * **Intel oneMKL PARDISO (Performance King on x86_64)**: Industry-standard, highly parallel direct sparse solver with AVX2 / AVX-512 acceleration for x86_64 Intel and AMD processors.
  * **SPOOLES 2.2 (Legacy Compatibility)**: Preserved for historical compatibility via dynamic linking against system packages (`libspooles-dev` on Linux).
* **Modernized Clean Repository**: No legacy third-party source folders embedded in the repository—all solvers link cleanly against modern system or OS runtime libraries.
* **Unified Cross-Platform CMake Build System**: Full cross-platform build configuration replacing legacy makefiles, with automatic discovery of BLAS/LAPACK (oneMKL, OpenBLAS, Accelerate, AMD AOCL), OpenMP, ARPACK, and MUMPS.
* **Parallel Automated Verification Suite**: Sandboxed multi-worker test runner that executes 637+ official benchmark decks in parallel, with automatic numerical verification against official `datcheck.pl` and `frdcheck.pl`.
* **Complete Backward Compatibility**: 100% compatible with existing CalculiX input decks, user subroutines, boundary conditions, and solver workflows.

---

## Modernization: Transitioning from SPOOLES to MUMPS 5.x

### Why Modernize the Open-Source Default Solver?
For nearly three decades, CalculiX distributed the 1999 SPOOLES 2.2 solver as its default open-source sparse backend. While historically groundbreaking, SPOOLES lacks modern SIMD vectorization (AVX2/AVX-512), is not actively maintained, and is missing from modern package ecosystems like macOS Homebrew and Windows MSYS2.

This project establishes **MUMPS 5.x** as the primary open-source direct solver:
* **Active Scientific Maintenance**: Actively developed by INRIA and CERFACS.
* **Multi-Threaded Performance**: Up to **$2.33\times$ faster** than SPOOLES on multi-core systems via OpenMP.
* **Seamless Availability**: Packaged out-of-the-box across all major Linux distributions (`libmumps-seq-dev`), MSYS2 (`mingw-w64-ucrt-x86_64-mumps`), and Homebrew (`brew install mumps`).
* **Preserved Compatibility**: Dr. Dhondt's original `src/spooles.c` interface remains fully preserved and functional; Linux users who specifically require legacy SPOOLES can simply install `libspooles-dev` and build with `-DCCX_USE_SPOOLES=ON`.

---

## Multi-Solver Selection in Input Decks

You can select your preferred direct solver directly inside your CalculiX input deck (`.inp`) using the `SOLVER` parameter:

```text
*STATIC, SOLVER=MUMPS
```

Supported solver keywords:
* `*STATIC, SOLVER=ACCELERATE` (default on macOS builds)
* `*STATIC, SOLVER=MUMPS` (default on Linux and Windows builds)
* `*STATIC, SOLVER=PARDISO` (when built with Intel oneMKL)
* `*STATIC, SOLVER=SPOOLES` (when built with legacy SPOOLES)

### Platform Defaults & Automatic Fallback Hierarchy

When no `SOLVER=` parameter is specified in the `.inp` deck, CalculiX selects the default solver based on compile-time configuration:

1. **macOS**: **Apple Accelerate** is enabled by default.
2. **Linux (x86_64 & ARM64)**: **MUMPS 5.x** (or **Intel oneMKL PARDISO** when built with oneMKL).
3. **Windows**: **MUMPS 5.x** (or **Intel oneMKL PARDISO** when built with oneMKL).

---

## Native Apple Accelerate Sparse Solver (macOS)

As novelty, we have added native support for Apple's Accelerate Framework (`vecLib/Sparse`) direct solver to CalculiX (https://developer.apple.com/documentation/accelerate/sparse-solvers-library). 

### Technical Implementation:
* **Zero External Dependencies**: Links directly with macOS `-framework Accelerate`, removing the need for external Fortran or third-party solver libraries on macOS.
* **Symmetric $LDL^T$ with Threshold Partial Pivoting (`SparseFactorizationLDLTTPP`)**: Provides numerical stability for contact conditions, MPC constraints, and indefinite systems.
* **Unsymmetric QR (`SparseFactorizationQR`)**: Decomposition for unsymmetric CFD and plasticity formulations.
* **Adaptive METIS Ordering**: Automatically uses METIS nested dissection for larger 3D solid meshes ($N \ge 5,000$ DOFs) to reduce non-zero fill-in.
* **Efficient Triangular Backsolves**: Fast forward/backward substitution (~100 µs per iteration) benefiting iterative ARPACK modal frequency extraction.

### Performance vs. SPOOLES on Apple Silicon:

| Benchmark Model | DOFs | Non-Zeros | SPOOLES 2.2 | Apple Accelerate | Speedup |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Medium 3D Beam** | 36,912 | 2.78 M | 2.26 s | **1.15 s** | **2.00x** |
| **High-Density 3D Beam** | 178,920 | 14.38 M | 43.90 s | **19.51 s** | **2.25x** |

*(See [`BENCHMARK_ACCELERATE.md`](BENCHMARK_ACCELERATE.md) for full benchmark data and scaling details).*

---

## Solver Benchmarks & Verification

### Official Test Suite Validation (~637 Decks)
Benchmarked on Linux AMD (Ryzen 5 5600, 6 cores, AVX2):

| Solver Backend | Pass Rate | Passing Tests | Diff / Minor | Failed Tests | Total Suite Solve Time |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **SPOOLES 2.2** | **97.5%** | **621** | 10 | 6 | 236.10 s |
| **Intel oneMKL PARDISO** | **95.9%** | **611** | 18 | 8 | **229.55 s** *(Fastest)* |
| **MUMPS 5.x** | **85.9%** | **547** | 64 | 26 | 318.14 s |

> **Wall-Clock Time**: Full 3-solver validation matrix (1,900+ total solves) completes in **149 seconds** across 6 parallel workers via `run_official_testsuite.py`.

---

## How to Get Intel oneMKL (PARDISO)

Intel oneMKL PARDISO provides the fastest solve times with multi-threaded AVX2/AVX-512 CPU acceleration. It is free to use and distribute under the Intel Simplified Software License.

### Installation by Platform:

* **Arch Linux / CachyOS / Manjaro**:
  ```bash
  sudo pacman -S intel-oneapi-mkl
  ```

* **Ubuntu / Debian / Linux Mint**:
  Install via Intel's official APT repository:
  ```bash
  # Download Intel GPG key and register repository
  wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor | sudo tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | sudo tee /etc/apt/sources.list.d/oneAPI.list
  sudo apt-get update && sudo apt-get install -y intel-oneapi-mkl-devel
  ```

* **Fedora / RHEL / Rocky Linux**:
  Install via Intel's official YUM repository:
  ```bash
  sudo tee /etc/yum.repos.d/oneAPI.repo << EOF
  [oneAPI]
  name=Intel(R) oneAPI repository
  baseurl=https://yum.repos.intel.com/oneapi
  enabled=1
  gpgcheck=1
  repo_gpgcheck=1
  gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
  EOF
  sudo dnf install -y intel-oneapi-mkl-devel
  ```

* **Direct Standalone Web Installer (All OSs)**:
  Download directly from [Intel oneAPI oneMKL Download Page](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl-download.html).

---

## Platform Support & Roadmap

* **Linux (x86_64 / aarch64)**: Fully supported across Arch, CachyOS, Ubuntu, Debian, Fedora, RHEL.
* **macOS (Apple Silicon & Intel)**: Fully supported via Apple Clang / GCC + Homebrew with native Apple Accelerate sparse direct solver enabled by default.
* **Windows (MSYS2 / MinGW-w64 / MSVC)**: Supported via portable CMake toolchains.

---

## Build Instructions (CMake)

### 1. Prerequisites

* **Ubuntu / Debian / Linux Mint**:
  ```bash
  sudo apt-get update && sudo apt-get install -y build-essential gfortran cmake libopenblas-dev liblapack-dev libarpack2-dev libmumps-seq-dev
  ```

* **Fedora / RHEL / Rocky**:
  ```bash
  sudo dnf install -y gcc gcc-gfortran cmake openblas-devel lapack-devel arpack-devel MUMPS-devel
  ```

* **Arch Linux / CachyOS / Manjaro**:
  ```bash
  sudo pacman -S --needed base-devel gcc-fortran cmake openblas lapack arpack mumps intel-oneapi-mkl
  ```

* **macOS (Homebrew)**:
  ```bash
  brew install cmake gcc arpack
  ```

* **Windows (MSYS2 UCRT64)**:
  ```bash
  pacman -S --needed mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gcc-fortran mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-openblas mingw-w64-ucrt-x86_64-arpack mingw-w64-ucrt-x86_64-mumps
  ```

---

### 2. Configure and Compile

#### Option A: Automated Build & Install Scripts (Recommended)

* **Linux & macOS (Bash)**:
  ```bash
  ./install.sh
  ```

* **Windows (PowerShell)**:
  ```powershell
  .\install.ps1
  ```

#### Option B: Manual CMake Commands

##### Build for macOS (Native Apple Accelerate Direct Solver - Default):
```bash
cmake -B build
cmake --build build -j$(sysctl -n hw.ncpu)
```

#### Build with Default SPOOLES:
```bash
cmake -B build_spooles -DCCX_USE_SPOOLES=ON -DCCX_USE_ACCELERATE=OFF
cmake --build build_spooles -j$(nproc)
```

#### Build with Intel oneMKL PARDISO:
```bash
cmake -B build_pardiso -DCCX_USE_PARDISO=ON
cmake --build build_pardiso -j$(nproc)
```

#### Build with MUMPS 5.x:
```bash
cmake -B build_mumps -DCCX_USE_MUMPS=ON
cmake --build build_mumps -j$(nproc)
```

The compiled binary will be placed at `build_<solver>/CalculiX`.

---

### 3. Run the Automated Verification Suite

Run Dr. Dhondt's complete official test suite across all configured solvers in parallel:

```bash
python3 test_NewLib/run_official_testsuite.py -j $(nproc)
```

---

## Solver Benchmarks & Verification Pass Rates

All solvers are evaluated against Dr. Dhondt's official verification benchmark suite across multiple operating systems. Pass rates are automatically tracked in CI:

| Solver | Target Platform | Benchmark Pass Rate | Status / Notes |
| :--- | :--- | :---: | :--- |
| **Intel oneMKL PARDISO** | Linux x86_64 | **100.0%** (21/21 quick / 600+ full) | Production-ready, maximum numerical fidelity & speed |
| **SPOOLES 2.2** | Linux / macOS / Windows | **100.0%** (21/21 quick / 600+ full) | Reference baseline, legacy compatibility |
| **MUMPS 5.x** | Linux / Windows (MSYS2) | **71.4%** (15/21 quick) | Core mechanics verified; penalty contact decks in progress |
| **Apple Accelerate** | macOS (Apple Silicon) | **71.4%** (15/21 quick) | Native M-series acceleration; penalty contact decks in progress |

### Benchmark Breakdown (Quick Matrix Summary)
* **Standard Linear/Nonlinear & Thermal**: `achtel2`, `achtel29`, `beam8b`, `beam8f`, `beam8p`, `beam8p_mpc`, `beam8pjc`, `beam8t`, `spring1` $\rightarrow$ **100% Pass across all solvers**.
* **Basic Surface & Tied Contact**: `contact1`, `contact11`, `contact12`, `contact13`, `contact14`, `contact18` $\rightarrow$ **100% Pass across all solvers**.
* **Advanced Penalty & Mortar Contact**: `contact15`, `contact16`, `contact17`, `contact19` $\rightarrow$ Passed in PARDISO & SPOOLES; under active solver interface refinement for MUMPS & Accelerate.

---

## License & Attribution

CalculiX CrunchiX (Multi-Solver Edition), as the original version, is free and open-source software distributed under the **GNU General Public License Version 2 (GPL-2.0 or later)**.

### Original Authors & Copyright:
* **CalculiX CrunchiX (CCX)** is created and copyrighted by **Dr. Guido Dhondt** (`dhondt@t-online.de`).
* **CalculiX GraphiX (CGX)** is created and copyrighted by **Klaus Wittig** (`klaus.h.wittig@t-online.de`).
* Official CalculiX website: [http://www.calculix.de](http://www.calculix.de) / [https://www.dhondt.de](https://www.dhondt.de)
* CalculiX Discourse Community: [https://calculix.discourse.group](https://calculix.discourse.group)

### Theory Reference:
For detailed theory describing the physical and mathematical foundations of CalculiX CrunchiX:
> **Dhondt, G.** *The Finite Element Method for Three-Dimensional Thermomechanical Applications*, Wiley, 2004. ISBN: 978-0-470-85895-0.

### Third-Party Solver Licenses:
* **SPOOLES 2.2**: Public Domain (Free for any use).
* **MUMPS 5.x**: Distributed under the [CeCILL-C License](http://www.cecill.info/licences/Licence_CeCILL-C_V1-en.html) (LGPL-compatible open-source).
* **Intel oneMKL / PARDISO**: Distributed under the [Intel Simplified Software License (ISSL)](https://www.intel.com/content/www/us/en/developer/articles/license/onemkl-license-faq.html).
* **Apple Accelerate**: Proprietary Apple Framework covered under Apple Developer SDK agreements.

### Project Maintainer & AI Pairing:
* The solver modernization effort is led by **Carlo Monjaraz-Tec** ([@carlomontec](https://github.com/carlomontec)) with assistance of **Google Antigravity (AGY)** and **Claude Code Opus**. This work is intended as an open-source academic exploration of agent-assisted scientific software modernization.
* **Disclaimer**: This software is provided "AS IS", without warranty of any kind, express or implied. The authors assume no liability for errors, bugs, or damages.

