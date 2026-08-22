# CalculiX CrunchiX (CCX) Modernization Roadmap

## Overview & Architecture

CalculiX CrunchiX (CCX) is a 470,000-line finite element solver developed by Dr. Guido Dhondt. This document outlines the architectural modernization roadmap to preserve Dr. Dhondt's core numerical formulations while modernizing the build system, library integrations, and toolchain.

---

## 1. Core Principles
* **Preserve Core FEA Physics**: Maintain 100% fidelity to Dr. Guido Dhondt's hand-crafted Fortran 77 element formulations, shape functions, material models (UMAT), and numerical integration schemes.
* **First-Class Linux & Cross-Platform Support**: Linux (x86_64 and aarch64) is the primary HPC/production target; macOS and Windows are fully supported via portable CMake configurations.
* **Backward Compatibility**: Preserve all input decks (`.inp`), user subroutines, macro formats, and post-processing files (`.frd`, `.dat`).

---

## 2. Solver Ecosystem & Modernization Strategy

| Solver | Status | Description & Target |
|:---|:---|:---|
| **SPOOLES 2.2** | Active (Default) | Built-in direct sparse solver. CMake subproject replaces legacy 1998 build system. |
| **Intel oneMKL PARDISO** | Active | Multi-threaded direct sparse solver for Linux/Windows (`-DCCX_USE_PARDISO=ON` or `src/Makefile.pardiso`). |
| **MUMPS 5.x** | Active | Modern direct sparse solver with OpenMP, Out-of-Core, and Block Low-Rank (BLR) memory reduction (`-DCCX_USE_MUMPS=ON` or `src/Makefile.mumps`). |
| **PaStiX** | Exists in source | High-performance direct solver with GPU acceleration support (`-DPASTIX_GPU`). |
| **ARPACK** | Active | Arnoldi eigenvalue solver for modal dynamic, frequency, and buckling analysis. |

---

## 3. Modernization Phases

### Phase 1: Foundation (CMake & Multi-Platform Toolchain)
- [x] Unified `CMakeLists.txt` for CCX with platform detection (Linux, macOS, Windows).
- [x] Modern `CMakeLists.txt` for `spooles` static library.
- [x] CTest integration for automated test suite execution against reference files.
- [x] Multi-platform BLAS/LAPACK detection (OpenBLAS, Intel MKL, Apple Accelerate).

### Phase 2: MUMPS & Advanced Solver Integration
- [x] MUMPS direct sparse solver interface (`mumps.c`, `mumps.h`).
- [x] Keyword parsing: `*STATIC, SOLVER=MUMPS` (`isolver=9`).
- [x] Comparative performance benchmarks (SPOOLES vs PARDISO vs MUMPS) via `test/benchmark_solvers.py`.

### Phase 3: Python Bindings (`pyccx`)
- [ ] C-API in-memory wrapper based on `CalculiXstep.c`.
- [ ] Direct NumPy array data exchange for coordinates, loads, boundary conditions, and results.
- [ ] FRD / VTU mesh export pipelines for post-processing in ParaView / PyVista.

### Phase 4: AI & Developer Tooling
- [ ] Input deck validator and error explainer.
- [ ] Convergence monitor and parameter advisor for nonlinear iterations (`.cvg`).
- [ ] UMAT generator and parameter calibration utilities.
