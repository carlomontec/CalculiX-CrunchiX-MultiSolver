# CalculiX CrunchiX Multi-Solver Edition

A solver modernization of [CalculiX CrunchiX](https://www.dhondt.de/), the open-source finite-element solver created by Dr. Guido Dhondt. The project preserves the original CalculiX numerical code with a more options for solver backends, and mult-platform. Singe codebase should run in Linux, MacOS, and Windows (planned).



<!-- [![CI Multi-Solver Matrix](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver/actions/workflows/ci.yml/badge.svg)](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver/actions/workflows/ci.yml) -->
[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](COPYING)
[![Platform: Linux | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-brightgreen.svg)](#platform-support--roadmap)
[![Solvers: SPOOLES | Intel MKL PARDISO | MUMPS | Accelerate](https://img.shields.io/badge/Solvers-SPOOLES%20%7C%20PARDISO%20%7C%20MUMPS%20%7C%20Accelerate-orange.svg)](#multi-solver-architecture)
[![PARDISO x64 Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/pardiso-x64.json)](#solver-benchmarks--verification-pass-rates)
[![SPOOLES x64 Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/spooles-x64.json)](#solver-benchmarks--verification-pass-rates)
[![SPOOLES ARM Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/spooles-arm.json)](#solver-benchmarks--verification-pass-rates)
[![MUMPS x64 Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/mumps-x64.json)](#solver-benchmarks--verification-pass-rates)
[![MUMPS ARM Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/mumps-arm.json)](#solver-benchmarks--verification-pass-rates)
[![Accelerate Pass Rate](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/carlomontec/c3df672908389cd64cb1fb8c1133f507/raw/accelerate.json)](#solver-benchmarks--verification-pass-rates)


## Goal
![CalculiX CrunchiX FEA Simulation](pictures/turbs.gif)

This work is a didactic exploration of agent-assisted scientific-software development by Carlo Monjaraz-Tec. Almost all the code is AI generated. The original CalculiX implementation and its authors remain credited below.

## Project Status

This project now runs CalculiX from a single codebase with four possible sparse solvers:

- **SPOOLES 2.2**, the original CalculiX default solver and compatibility baseline. Outdated and unmantained.
- **Intel oneMKL PARDISO**, available on supported Linux and Windows configurations. Performant, but not open source.
- **Apple Accelerate**, native for Apple Silicon macOS.
- **MUMPS 5.x**, a modern open-source direct solver.

The integrations use packages from relevant repositories, while macOS MUMPS and SPOOLES builds use pinned source archives. A novelty for the modernization of CalculiX: native Apple Accelerate and MUMPS support now coexist with SPOOLES and PARDISO support.

Performance measurements so far show the modern backends improving substantially over SPOOLES, with MUMPS currently providing the strongest overall score. Results can be validated with the official CalculiX test suite.

## Solver Backends

| Backend | Linux | macOS | Windows | Role |
|:---|:---:|:---:|:---:|:---|
| **MUMPS 5.x** | System package | Vendored archive | System/MSYS2 package | Primary modern open-source candidate |
| **Apple Accelerate** | No | Native framework | No | macOS sparse solver |
| **SPOOLES 2.2** | System package | Vendored archive | System package when available | Legacy compatibility and comparison baseline |
| **Intel oneMKL PARDISO** | Optional | No | Optional | High-performance oneMKL backend |

On Apple Silicon macOS, MUMPS and SPOOLES are built from pinned source archives: [MUMPS vendor package](third_party/mumps/README.md),  [SPOOLES vendor package](third_party/spooles/README.md)


## Quick install for Linux and MacOS (Recommended)

Use the automated installer by running this snippet in the terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
```
After installation, the `ccx` executable is ready to use from the directory you selected. If you accept the shell-configuration prompt, that directory is added to your `PATH` and the `CalculiX` alias is created as well.

Or build manually with CMake. Detailed prerequisites, platform instructions, solver configurations, and troubleshooting are in [INSTALL.md](INSTALL.md).

```bash
cmake -S . -B build_mumps -DCCX_USE_MUMPS=ON
cmake --build build_mumps --parallel
```

The resulting executable is `build_mumps/CalculiX`.

## Repository Guide

- [INSTALL.md](INSTALL.md): prerequisites, automated installation, manual CMake builds, and troubleshooting.
- [VALIDATION.md](VALIDATION.md): official test-suite validation and result interpretation.
- [BENCHMARK_ACCELERATE.md](BENCHMARK_ACCELERATE.md): Accelerate design and performance notes.
- [MODERNIZATION.md](MODERNIZATION.md): architecture and roadmap.
- [test_NewLib/run_official_testsuite.py](test_NewLib/run_official_testsuite.py): full correctness comparison runner.
- [test_NewLib/benchmark_solvers.py](test_NewLib/benchmark_solvers.py): focused performance benchmark.
- [third_party/mumps/README.md](third_party/mumps/README.md): vendored MUMPS source and build notes.
- [third_party/spooles/README.md](third_party/spooles/README.md): vendored SPOOLES source and provenance.

## Companion Tools

This project is designed to work with [CalculiX GraphiX GLFW](https://github.com/carlomontec/CalculiX-GraphiX-GLFW), a modernized CalculiX pre/post-processor with OpenGL and ParaView export support.

## Platforms

- Linux x86_64 and ARM64
- macOS on Apple Silicon only
- Windows through MSYS2/MinGW-w64 and portable CMake configurations

## Attribution and License

CalculiX CrunchiX is free software distributed under the GNU General Public License version 2. The original project is maintained by Dr. Guido Dhondt. CalculiX GraphiX was created by Klaus Wittig.

- CalculiX: [calculix.de](https://www.calculix.de) and [dhondt.de](https://www.dhondt.de)
- CalculiX community: [CalculiX Discourse](https://calculix.discourse.group)
- Theory reference: G. Dhondt, *The Finite Element Method for Three-Dimensional Thermomechanical Applications*, Wiley, 2004.

Solver licensing is documented by each upstream project. The vendored MUMPS source is distributed under CeCILL-C; SPOOLES 2.2 is public domain; Intel oneMKL and Apple Accelerate remain subject to their respective upstream license agreements.
