# CalculiX CrunchiX (Multi-Solver Edition)

> **A Modernized, High-Performance Multi-Solver & Multi-Platform Edition of CalculiX CrunchiX (CCX).**

[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](COPYING)
[![Platform: Linux | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-brightgreen.svg)](#platform-support--roadmap)
[![Solvers: SPOOLES | PARDISO | MUMPS | Accelerate](https://img.shields.io/badge/Solvers-SPOOLES%20%7C%20PARDISO%20%7C%20MUMPS%20%7C%20Accelerate-orange.svg)](#multi-solver-architecture)
[![Build: Modern CMake](https://img.shields.io/badge/Build-Modern%20CMake-purple.svg)](#build-instructions-cmake)
[![Verification: 600+ Official Tests](https://img.shields.io/badge/Verification-600%2B%20Tests%20Passing-success.svg)](#solver-benchmarks--verification)

![CalculiX CrunchiX FEA Simulation](pictures/turbs.gif)

---

## About This Project

This project is an **academic exercise for learning AI agentic programming** by **Carlo Monjaraz-Tec** using **Google Antigravity and Claude Code Opus**, based on the foundational finite element solver created by **Dr. Guido Dhondt** and pre/post-processing tools by **Klaus Wittig** ([http://www.calculix.de](http://www.calculix.de) / [https://www.dhondt.de](https://www.dhondt.de)).

The objective is to explore agent-assisted scientific software modernization by making CalculiX CrunchiX (CCX) as **flexible, fast, and accessible across all major operating systems** as possible. We intend to update to pluggable state-of-the-art sparse direct solvers (**Intel oneMKL PARDISO**, **MUMPS 5.x**, and **Apple Accelerate**), modern **CMake** build pipelines, and automated multi-solver verification suites; while strictly preserving the original core mechanical computations.

---

## Companion Pre-/Post-Processor 

This project is designed to pair seamlessly with **[CalculiX-GraphiX-GLFW](https://github.com/carlomontec/CalculiX-GraphiX-GLFW)** (`cgx_glfw`), a modernized approach to CalculiX GraphiX in pure GLFW3 / OpenGL 3D, extended with native ParaView VTU/PVD export and some additional eye-candy.

---

## Highlights & Multi-Solver Architecture

* **Pluggable Sparse Direct Solvers**:
  * **SPOOLES 2.2**: Classic embedded sparse direct solver with modernized CMake compilation.
  * **Intel oneMKL PARDISO**: Industry-standard, highly parallel direct sparse solver with AVX2 / AVX-512 CPU acceleration (our recommended default on x86_64).
  * **MUMPS 5.x**: Advanced, robust parallel direct sparse solver with OpenMP, Out-of-Core, and Block Low-Rank (BLR) capabilities—envisioned as a modern open-source candidate substitution/upgrade for SPOOLES.
  * **Apple Accelerate**: Native hardware-accelerated direct sparse solver (`SparseFactorizationLDLTTPP` and `SparseFactorizationQR`) tailored for macOS and Apple Silicon (M-series) unified memory architecture (default on macOS).
* **Unified Cross-Platform CMake Build System**: Full cross-platform build configuration replacing legacy 1990s platform makefiles, with automatic discovery of BLAS/LAPACK (oneMKL, OpenBLAS, Accelerate), OpenMP, ARPACK, and MUMPS.
* **Parallel Automated Verification Suite**: Sandboxed multi-worker test runner that executes 637+ official benchmark decks in parallel, with automatic numerical verification against official `datcheck.pl` and `frdcheck.pl`.
* **Complete Backward Compatibility**: 100% compatible with existing CalculiX input decks, user subroutines, boundary conditions, and solver workflows.

---

## Multi-Solver Selection in Input Decks

You can select your preferred direct solver directly inside your CalculiX input deck (`.inp`) using the `SOLVER` parameter:

```text
*STATIC, SOLVER=ACCELERATE
```

Supported solver keywords:
* `*STATIC, SOLVER=ACCELERATE` (default on macOS builds)
* `*STATIC, SOLVER=PARDISO` (default on x86_64 Linux when built with oneMKL)
* `*STATIC, SOLVER=MUMPS`
* `*STATIC, SOLVER=SPOOLES` (or `SOLVER=DEFAULT`)

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
  sudo apt-get update && sudo apt-get install -y build-essential gfortran cmake libopenblas-dev liblapack-dev libarpack2-dev libmumps-dev
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

---

### 2. Configure and Compile

Clone the repository:
```bash
git clone https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver.git ccx
cd ccx
```

#### Build for macOS (Native Apple Accelerate Direct Solver - Default):
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

