# Technical Reference: Architectural Modernization and Changes vs Upstream CalculiX CrunchiX (CCX)

**Author**: Dr. Carlo Monjaraz-Tec  
**Base Project**: CalculiX CrunchiX (CCX) by Dr. Guido Dhondt  
**Upstream base**: ccx 2.24 (upstream commit `57a4e71`, tag `ccx-2.24-upstream`; see [UPSTREAM_2.24.md](UPSTREAM_2.24.md))  
**Project**: CalculiX CrunchiX Multi-Solver Edition  

---

## 1. Executive Summary & Design Philosophy

CalculiX CrunchiX (CCX) is an established, open-source three-dimensional structural and thermomechanical finite-element solver developed by Dr. Guido Dhondt. Over more than two decades, CCX has accumulated over 470,000 lines of highly specialized, robust Fortran 77 and C code implementing comprehensive element libraries, non-linear kinematic formulations, material constitutive models (UMATs), contact algorithms (penalty and mortar), and multi-physics coupling.

The objective of the **CalculiX CrunchiX Multi-Solver Edition** is not to rewrite or replace Dr. Dhondt's underlying finite element formulations, but to modernize the surrounding software architecture, build infrastructure, linear algebra backends, and scientific data interoperability.

### Guiding Principles

1. **Strict Core Physics Preservation**:
   - 100% mathematical fidelity to Dr. Dhondt's element stiffness assemblies, shape functions, numerical integration schemes, non-linear Newton-Raphson solvers, and material routines.
   - All input deck syntax (`.inp`), macro formats, user subroutines, and legacy output files (`.dat`, `.frd`, `.cvg`) remain fully backward-compatible.

2. **First-Class Cross-Platform Portability**:
   - Provide seamless native builds across Linux (x86_64, aarch64), macOS (Apple Silicon arm64), and Windows (MSYS2 UCRT64 / MinGW-w64).
   - Modern target-based CMake build orchestration replacing platform-specific, hardcoded Makefiles.

3. **Modular Multi-Solver Architecture**:
   - Decouple the element formulation routines from the linear equation solver backends.
   - Support multiple state-of-the-art sparse direct solvers: **MUMPS 5.x**, **Apple Accelerate**, **Intel oneMKL PARDISO**, and legacy **SPOOLES 2.2**.

4. **Modern Eigenvalue Solver Integration**:
   - Upgrade the modal dynamics and buckling extraction engine from unmaintained 1996 ARPACK Fortran routines to community-maintained **`arpack-ng`**.

5. **Direct In-Memory Structured JSON Export**:
   - Provide high-throughput RFC 8259 JSON serialization directly from solver memory, enabling zero-overhead integration with Python, Julia, MATLAB, and optimization pipelines.

6. **Isolated and Automated Verification Framework**:
   - Maintain Dr. Dhondt's official 630+ verification test suite untouched in its upstream directory while providing a parallelized, sandboxed test harness (`test_NewLib`) with automated golden reference comparisons.

---

## 2. High-Level Comparison Matrix

| Architectural Feature | Upstream CalculiX CCX (Vanilla) | Multi-Solver Modernized CCX |
|:---|:---|:---|
| **Build System** | Makefiles (`Makefile_MT`) and, since 2.24, an official CMake build (Linux, CMake 3.28+, no install rules) | Target-based `CMakeLists.txt` (CMake 3.20+) with auto-discovery and CTest support |
| **Source Discovery** | Static listing in individual Makefiles | Automated parser of upstream `src/Makefile.inc` generating static `CalculiX_lib` |
| **Supported Platforms** | Primarily Linux x86_64; partial manual patches for Windows/macOS | Native out-of-the-box support for Linux (x86_64, ARM64), macOS (Apple Silicon), Windows |
| **Default Linear Solver** | SPOOLES 2.2 (developed in 1999) | MUMPS 5.x (Linux/Win) or Apple Accelerate (macOS); SPOOLES & PARDISO selectable |
| **macOS Solver Engine** | Emulated / unoptimized SPOOLES via Homebrew | Native Apple Accelerate Sparse Solver framework utilizing Apple Silicon hardware P-cores |
| **Eigenvalue Engine** | Vendored legacy ARPACK 96 source archive | System/packageable `arpack-ng` with standard CMake and pkg-config integration |
| **BLAS / LAPACK** | Often Netlib or statically hardcoded paths | Platform-adaptive: AMD AOCL-BLIS, OpenBLAS, Intel oneMKL, or Apple Accelerate |
| **Stack Size Management** | Default system thread stack (frequent crash on macOS with large models) | Embedded 256 MB stack configuration (`-Wl,-stack_size,0x10000000`) on macOS |
| **Data Export** | Fixed-width ASCII `.dat` and binary/ASCII `.frd` | Full `.dat` and `.frd` preserved + direct in-memory RFC 8259 JSON export (`-j` / `--json`) |
| **Test Verification** | Manual sequential shell/Perl scripts modifying working directory in-place | Sandboxed parallel runner (`test_NewLib`), process isolation, in-memory JSON comparisons |
| **Repository Separation** | Single monolithic tree | Upstream `test/` directory strictly untouched; modernized tooling isolated in `test_NewLib/` |

---

## 3. Build System & Compilation Infrastructure

### 3.1 Migration to Target-Based Modern CMake

Upstream CCX historically required users to edit static Makefiles (e.g. `Makefile_MT`) to set paths for SPOOLES, ARPACK, and BLAS. This was brittle across different Linux distributions and prevented clean cross-platform compilation.

The modernized build system (`CMakeLists.txt`) establishes:

- **Target Encapsulation**: A core static library (`CalculiX_lib`) compiles all Fortran and C routines extracted directly from `src/Makefile.inc`. The final executable (`CalculiX`) links against `CalculiX_lib` and selected solver libraries.
- **CLI Alias**: Automatically creates the standard modernized alias `ccx` alongside `CalculiX`.
- **Compiler Compatibility Flags**: Automatically passes `-fallow-argument-mismatch` and `-cpp` to modern GCC/GFortran (versions 10 through 14+) to allow legacy Fortran 77 parameter passing without compiler rejections.
- **macOS Apple Silicon Hardening**:
  - Dynamically queries Xcode SDK paths via `xcrun --show-sdk-path` to link correctly against `libSystem`.
  - Embeds a 256 MB executable stack size (`-Wl,-stack_size,0x10000000`) to eliminate stack overflow crashes during deep recursive contact searching (mortar and node-to-face) and complex material plasticity subroutines.

### 3.2 Platform-Adaptive BLAS/LAPACK Discovery

Rather than forcing a single BLAS implementation, CMake provides prioritized hardware detection (`-DCCX_BLAS=AUTO`):

1. **AMD Zen Architectures (Ryzen / EPYC / Threadripper)**: Detects `AuthenticAMD` via `/proc/cpuinfo` or environment and prioritizes AMD Optimizing CPU Libraries (**AOCL-BLIS** and **libflame**).
2. **Open-Source General High-Performance**: Discovers **OpenBLAS** with full multi-threading support.
3. **Intel Platforms**: Discovers **Intel oneMKL** runtime (`mkl_rt`).
4. **macOS**: Links native **Apple Accelerate Framework** for vector and matrix operations.

### 3.3 Pinned Vendoring for Self-Contained Builds

To solve the historical problem where macOS users could not install legacy SPOOLES or MUMPS via Homebrew, the repository provides pinned source archives in `third_party/`:
- `third_party/mumps/MUMPS_5.9.1.tar.gz`
- `third_party/spooles/SPOOLES_2.2.tar.gz`

When building on macOS with `-DCCX_MUMPS_VENDORED=ON` or `-DCCX_SPOOLES_VENDORED=ON`, CMake unpacks, builds, and links these archives at configure time without requiring system modifications.

---

## 4. Multi-Solver Architecture & Backend Abstraction

Upstream CCX contained hardcoded calls to SPOOLES within its solving routines, with partial hooks for PARDISO. The modernized architecture provides a clean abstraction layer where each solver backend exposes consistent factorization, solve, and cleanup functions.

```
                  +-----------------------------------------+
                  |         CalculiX Core Mechanics         |
                  | (nonlingeo.c / linstatic.c / arpack.c)   |
                  +-----------------------------------------+
                                       |
                 [isolver selection via Deck or CLI Defaults]
                                       |
        +------------------+-----------+-----------+------------------+
        |                  |                       |                  |
        v                  v                       v                  v
+---------------+  +---------------+       +---------------+  +---------------+
|  SPOOLES 2.2  |  |   MUMPS 5.x   |       |   Accelerate  |  | oneMKL PARDISO|
| (Legacy Base) |  |  (Open Source)|       | (Apple macOS) |  | (Intel Linux) |
|  isolver = 0  |  |  isolver = 9  |       | isolver = 11  |  |  isolver = 7  |
+---------------+  +---------------+       +---------------+  +---------------+
```

### 4.1 MUMPS 5.x Backend (`src/mumps.c`, `src/mumps.h`)

- **Role**: Primary recommended open-source multi-threaded direct solver on Linux and Windows.
- **Implementation**:
  - Encapsulates `DMUMPS_STRUC_C` state.
  - Automatically converts CCX column-compressed storage (CCS) into MUMPS 1-based coordinate triplet format (`irn`, `jcn`, `a`).
  - Supports both symmetric (`SYM=2`, positive definite / indefinite) and unsymmetric (`SYM=0`) matrices.
  - Respects `OMP_NUM_THREADS` and `CCX_NPROC_EQUATION_SOLVER`.
  - On Linux, links cleanly against `libmumps-seq-dev` (bundled with `mpiseq` stubs), avoiding MPI daemon prerequisites while delivering multi-threaded OpenMP factorization.
- **Card Selection**: `*STATIC, SOLVER=MUMPS` or `*FREQUENCY, SOLVER=MUMPS`.

### 4.2 Apple Accelerate Sparse Solver Backend (`src/accelerate_solver.c`)

- **Role**: High-performance native direct solver for Apple Silicon (M1/M2/M3/M4) macOS systems.
- **Implementation**:
  - Leverages Apple's native `SparseSolve` and `SparseOpaqueFactorization_Double` APIs.
  - Symmetric systems: Cholesky factorization (`SparseFactor(SparseFactorizationCholesky, ...)`).
  - Unsymmetric systems: QR / LU factorization (`SparseFactor(SparseFactorizationQR, ...)`).
  - **Hardware P-Core Affinity**: To eliminate severe multi-threading latency caused by threads spilling onto low-clocked Efficiency cores (E-cores), the backend queries hardware performance levels via `sysctlbyname("hw.perflevel0.logicalcpu", ...)` and caps worker threads to physical Performance cores (P-cores).
  - Automatically exports `VECLIB_MAXIMUM_THREADS` dynamically.
- **Card Selection**: `*STATIC, SOLVER=ACCELERATE` or `*FREQUENCY, SOLVER=ACCELERATE`.

### 4.3 Intel oneMKL PARDISO Backend (`src/pardiso.c`)

- **Role**: Shared-memory multi-threaded direct sparse solver for x86_64 HPC Linux and Windows environments.
- **Implementation**:
  - Full support for 32-bit (`MKL_LP64`) and 64-bit integer (`MKL_ILP64`) interfaces.
  - Configures `iparm[1] = 2` (METIS nested dissection ordering) to avoid parallel ordering instabilities in modern oneAPI MKL releases.
- **Card Selection**: `*STATIC, SOLVER=PARDISO`.

### 4.4 Unified Keyword Parsing (`src/statics.f`, `src/frequencys.f`, `src/buckles.f`)

The keyword parsing subroutines in Fortran 77 have been cleanly extended to parse `SOLVER=...` across all relevant analysis steps:

```fortran
      if(solver(1:7).eq.'SPOOLES') then
         isolver=0
      elseif(solver(1:7).eq.'PARDISO') then
         isolver=7
      elseif(solver(1:6).eq.'PASTIX') then
         isolver=8
      elseif(solver(1:5).eq.'MUMPS') then
         isolver=9
      elseif(solver(1:10).eq.'ACCELERATE') then
         isolver=11
      endif
```

---

## 5. Eigenvalue Solver Modernization (`arpack-ng`)

### 5.1 Motivation
In upstream CCX, modal frequency analysis (`*FREQUENCY`) and buckling analysis (`*BUCKLE`) relied on legacy FORTRAN 77 ARPACK sources (circa 1996). These routines suffered from:
- Obsolete dummy-argument mismatches rejected by modern Fortran compilers.
- Unhandled 64-bit integer indexing issues on modern large models.
- Upstream abandonment (no security or bug fixes in over 20 years).

### 5.2 Implementation
- CCX now links against the actively maintained **`arpack-ng`** library via standard pkg-config or CMake library discovery (`libarpack2-dev`, `arpack`, `mingw-w64-arpack`).
- The shift-and-invert spectral transformation loop (`src/arpack.c`) has been fully integrated with the multi-solver architecture: MUMPS, Apple Accelerate, PARDISO, and SPOOLES can all serve as the linear factorization engine during Arnoldi iterations.
- Modal mass calculation and effective modal mass extraction (`json_export_modal_mass`) are captured directly in memory.

---

## 6. Direct In-Memory JSON Export (`-j` / `--json`)

### 6.1 Motivation
Scientific workflows in optimization, machine learning surrogate training, and automated verification frequently require programmatic access to FEA results. Previously, users had to parse fixed-width ASCII `.dat` files with brittle regular expressions.

### 6.2 Architecture (`src/json_export.c`, `src/json_export.h`)
- Implemented as a lightweight, memory-efficient C serialization module with dynamic buffering.
- Intercepts output at the end of each step and increment without altering `.dat` or `.frd` generation.
- **RFC 8259 Compliance**: Floating-point exceptions (`NaN`, `Inf`) are safely serialized as JSON `null` rather than generating invalid JSON syntax.
- **Activation**:
  - Command-line flag: `ccx -j <jobname>` or `ccx --json <jobname>`.
  - Environment variable: `export CCX_JSON=1`.

### 6.3 Structured JSON Schema
The resulting `<jobname>.json` provides:
1. **Metadata (`meta`)**: Solver backend name, thread count, exit code, total wall-clock execution time, and model statistics (total nodes, elements, equations).
2. **Analysis Steps (`steps`)**: Step type (`STATIC`, `FREQUENCY`, `BUCKLE`), convergence state, and time increments.
3. **Field Data**:
   - Displacements (`U`) and Reaction Forces (`RF`) organized by node set.
   - Stresses (`S`) and Strains (`E`) organized by element set.
   - Natural frequencies, generalized masses, participation factors, and effective mass fractions for modal dynamic extraction.
   - Buckling load factors.

---

## 7. Verification, Validation & Benchmark Infrastructure

To maintain complete scientific and academic rigor, the test harness is explicitly decoupled from Dr. Guido Dhondt's baseline files.

### 7.1 Upstream Directory Isolation
- The `test/` directory contains Dr. Dhondt's 630+ reference input decks and golden output files. This directory is treated as read-only and **remains 100% untouched**.
- All modernized benchmarking, verification runners, result scrapers, and comparison tools reside strictly in **`test_NewLib/`**.

### 7.2 Automated Test Runner (`test_NewLib/run_official_testsuite.py`)
- **Process Sandboxing**: Every test deck runs inside an isolated temporary directory to prevent file collisions during concurrent execution.
- **Process Parallelism**: Automatically leverages all CPU cores (`OMP_NUM_THREADS=1` per worker) to run hundreds of verification decks in minutes.
- **JSON-First In-Memory Verification**:
  - Compares test outputs directly against pre-computed golden JSON references (`test_NewLib/originaltest_json/<deck>.json.ref`).
  - Utilizes strict relative (`1e-3`) and absolute (`1e-8`) numerical tolerances.
  - Automatically falls back to legacy Perl `.dat` / `.frd` checking for decks without JSON references.
- **Exclusion Management**: Automatically identifies and tracks auxiliary dependency decks (such as missing radiation view-factor files `.vwf` or restart files `.rin`), preventing false-positive failure reports.

### 7.3 Multi-Solver Performance Benchmarking (`test_NewLib/benchmark_solvers.py`)
- Automated benchmark sweeps measuring wall-clock factorization time, total solve time, and peak Resident Set Size (RSS memory footprint).
- Tests thread scaling (1, 2, 4, 6, 8+ threads) across linear static cantilever beam elasticity and 10-mode modal eigenvalue extraction.
- Cross-verifies physical output invariance across solvers: confirms tip deflection $u_z$ and peak von Mises stress $\sigma_{vM}$ agreement within numerical tolerance across all solver backends.

---

## 8. Summary of Preserved Upstream Physics

### Changes that can affect results

Compared with ccx 2.24, exactly one change can change numerical results: the
stable time increment for explicit dynamics (`src/calcstabletimeincvol.f`, with
the matching `smscale` allocation in `arpack.c`, `arpackcs.c` and `nonlingeo.c`).
See section 9.3 B for the details. It affects only explicit dynamic analyses
(`*DYNAMIC, EXPLICIT`) and mass scaling. This fix will be documented in full and
proposed to upstream separately.

`src/modaldynamics.f` also corrects an upstream typo (`SOLVER=PASTIX` on
`*MODAL DYNAMIC` was compared against `'PARDISO'`). It changes behaviour only
for decks that request PaStiX in that step.

**Build setting: multithreaded SPOOLES (`USE_MT`).** This edition's CMake
defines `USE_MT`, like upstream's `Makefile_MT`. Upstream's default `Makefile`
and CMake don't. With more than one thread, SPOOLES results can then vary
slightly from run to run, mostly in higher eigenvalues (around 1 %,
occasionally more). Plain 2.24 built with `USE_MT` does the same. With
`CCX_NPROC_EQUATION_SOLVER=1` (or `OMP_NUM_THREADS=1`), results are identical
to plain 2.24. SPOOLES is not the recommended solver in this edition. See
`test_NewLib/release_2.24/REPORT.md`.

All other changes add solver backends or JSON output, or change performance
(OpenMP in `opmain.c`, which keeps upstream's work split and summation order).
On Linux with SPOOLES, all 642 decks of the official suite give byte-identical
results to plain 2.24 on one thread, and with SPOOLES on one thread also when
the rest of CalculiX runs on 4 threads (see the report for the 7 CFD decks that
vary in upstream itself).

### Preserved algorithms

Apart from the change above, the following core CalculiX CrunchiX algorithms remain **100% unaltered**:

1. **Element Formulations**:
   - Linear and quadratic hexahedra (C3D8, C3D8R, C3D20, C3D20R).
   - Linear and quadratic tetrahedra (C3D4, C3D10).
   - Pentahedral wedges (C3D6, C3D15).
   - 1D beams (B31, B31R, B32, B32R) and shell expansions (S4, S4R, S8, S8R).
   - Axisymmetric and plane stress/strain formulations.
2. **Kinematics & Non-Linear Iteration**:
   - Finite strain formulation with polar decomposition of deformation gradient.
   - Non-linear full Newton-Raphson equilibrium iterations with line search (`nonlingeo.c`).
   - Arc-length / Riks method for post-buckling snap-through.
3. **Contact Mechanics**:
   - Node-to-face penalty contact.
   - Face-to-face mortar contact formulations with dual Lagrange multipliers.
4. **Materials & Constitutive Models**:
   - Hyperelasticity (Mooney-Rivlin, Ogden, Neo-Hooke, Arruda-Boyce).
   - Small and large-strain plasticity with isotropic and kinematic hardening.
   - Thermal network flow, radiation, and CFD shallow-water formulations.
   - Standard user material subroutines (`umat.f`, `umat_abaqus.f`, `uexternaldb.f`).

---

## 9. Comprehensive File-by-File Inventory: Added vs. Modified Code

This section provides a detailed audit comparing the repository directly against Dr. Guido Dhondt's upstream CalculiX CrunchiX baseline (`Dhondtguido/CalculiX`).

### 9.1 Summary Statistics
- **Total C/Fortran files in upstream CCX (`src/`)**: ~1,180 files.
- **Files Added in `src/`**: 9 files (4 C source, 3 C headers, 2 standalone Makefiles).
- **Files Modified in `src/`**: 41 files (19 C source/headers, 22 Fortran subroutines/Makefiles).
- **Files Added in Tooling & Build (`test_NewLib/`, root)**: CMake build system, CI/CD, installers, test runner, benchmark suite, and golden JSON references.
- **Core Physics Code Preserved**: > 96% of files in `src/` remain completely untouched.

### 9.2 Newly Added Files in `src/`

| File | Type | Functional Role |
|:---|:---|:---|
| **`src/accelerate_solver.c`** | C Source (446 lines) | Apple Accelerate Sparse Solver backend (macOS native). Implements Cholesky (`SparseFactorizationCholesky`) for symmetric systems and QR/LU for unsymmetric systems. Dynamic P-core affinity binding via `sysctlbyname("hw.perflevel0.logicalcpu")`. |
| **`src/accelerate_solver.h`** | C Header (37 lines) | API interface declaring `accelerate_factor`, `accelerate_solve`, and `accelerate_cleanup`. |
| **`src/mumps.c`** | C Source (324 lines) | MUMPS 5.x interface layer. Translates CCX column-compressed storage (CCS) into coordinate format; manages out-of-core and OpenMP multi-threaded factorization. |
| **`src/mumps.h`** | C Header (47 lines) | API interface declaring `mumps_factor`, `mumps_solve`, and `mumps_cleanup`. |
| **`src/mumps_cp.c`** | C Source (217 lines) | Complex-valued MUMPS backend for cyclic symmetry and harmonic frequency analysis. |
| **`src/json_export.c`** | C Source (516 lines) | High-performance in-memory JSON serializer compliant with RFC 8259. Intercepts step/increment results and outputs `<jobname>.json` with safe `null` serialization for NaN/Inf. |
| **`src/json_export.h`** | C Header (45 lines) | Public lifecycle hooks (`json_init`, `json_start_step`, `json_export_results`, `json_finalize`). |
| **`src/Makefile.mumps`** | Makefile (37 lines) | Standalone fallback Makefile for building CCX with MUMPS. |
| **`src/Makefile.pardiso`** | Makefile (53 lines) | Standalone fallback Makefile for building CCX with Intel oneMKL PARDISO. |

### 9.3 Modified Files in `src/`: Algorithmic & Performance Enhancements

The modifications in existing source files fall into distinct technical categories:

#### A. Critical OpenMP Modernization: Symmetric Sparse Matrix-Vector Multiply
- **`src/opmain.c`**:
  - **Problem in Upstream CCX**: Sparse matrix-vector multiplication $y = A \cdot x$ for lower-triangular symmetric systems previously spawned and joined POSIX threads (`pthread_create` / `pthread_join`) **twice on every single call** (once for partial multiplication `opmt`, and once for vector reduction `opcollect`). In iterative eigenvalue extraction (ARPACK Arnoldi iterations), `opmain` is executed hundreds of times in rapid succession, resulting in severe kernel thread-creation latency and context-switching overhead.
  - **Modernization**:
    1. Replaced dynamic pthread spawning with a persistent OpenMP thread team (`#pragma omp parallel`).
    2. Implemented thread-private accumulation slices (`yy[tid * n]`) with parallel reduction to safely handle off-diagonal symmetric contributions without requiring mutexes or atomic locks.
    3. Implemented a zero-allocation, in-place serial fast path when `num_threads <= 1`, eliminating memory allocation overhead.

#### B. Explicit Dynamics Stability & Portability Fixes
- **`src/calcstabletimeincvol.f`**:
  - Corrected dummy argument dimension for `alpha(*)` (changed from scalar `alpha` to `alpha(*)` and indexed as `alpha(1)`), eliminating modern GFortran array mismatch errors.
  - Initialized previously uninitialized element geometry variables (`nope=8`, `nopes=4`, `nfaces=6`, `weight=8.d0`), preventing undefined behavior in volume calculations.
  - Added string boundary safety (`len_trim(jobnamef(1))`), preventing segmentation faults when jobnames contain no whitespace.
- **`src/getSystemCPUs.c`**:
  - Replaced Linux-only `/sys` filesystem traversal with native, multi-platform CPU detection: `sysctlbyname("hw.logicalcpu")` on macOS, `GetSystemInfo` on Windows, and `sysconf(_SC_NPROCESSORS_ONLN)` on Linux.

#### C. Intel oneMKL PARDISO Stability Modernization
- **`src/pardiso.c` & `src/pardiso_cp.c`**:
  - Modern Intel oneMKL releases suffer from known race conditions and hangs during multi-threaded symbolic factorization when `iparm[1] = 3` (Parallel METIS). Updated to `iparm[1] = 2` (standard sequential METIS nested dissection) across both factorization and solve phases.
  - Added explicit calls to `FORTRAN(pardisoinit,(pt,&mtype,iparm))` to ensure valid internal parameter defaults across different oneMKL runtime versions.

#### D. Structured In-Memory JSON Export Lifecycle Hooks
- **`src/CalculiX.c`**:
  - Added CLI parsing for `-j`, `--json`, and `-json`.
  - Added environment variable detection for `CCX_JSON` and `CCX_EXPORT_JSON`.
  - Integrated `json_init(...)` at startup and `json_finalize(...)` at normal termination.
- **`src/CalculiXstep.c`**:
  - Added step boundary triggers `json_set_meta_stats(...)` and `json_start_step(...)` tracking step type (`STATIC`, `FREQUENCY`, `BUCKLE`, `DYNAMIC`, etc.).
- **`src/results.c`**:
  - Integrated `json_export_results(...)` to capture nodal displacements (`U`), reaction forces (`RF`), element stresses (`S`), and strains (`E`) at print intervals.
- **`src/effectivemodalmass.f`**:
  - Restored missing newline formatting delimiter to ensure valid output parsing.

#### E. Multi-Solver Dispatch in C Analysis Routines (13 files)
The following analysis routines were updated to dispatch matrix factorizations, solves, and memory cleanups to MUMPS (`isolver=9`) and Apple Accelerate (`isolver=11`):
1. **`src/linstatic.c`**: Linear static step factorizations and solves.
2. **`src/nonlingeo.c`**: Non-linear Newton-Raphson equilibrium iterations (plasticity, contact, large deformation).
3. **`src/arpack.c`**: Arnoldi shift-and-invert spectral transformation loop for natural frequency extraction.
4. **`src/arpackbu.c`**: Linear buckling eigenvalue factorizations.
5. **`src/arpackcs.c`**: Cyclic symmetry frequency analysis.
6. **`src/dyna.c`**: Direct integration dynamic analysis.
7. **`src/dynboun.c`**: Boundary acceleration equations.
8. **`src/dudsmain.c`**: Sensitivity analysis displacement derivatives.
9. **`src/electromagnetics.c`**: Electromagnetic potential equations.
10. **`src/massless.c`**: Massless structural dynamic factorizations.
11. **`src/objectivemain_se.c`**: Superelement objective function gradient evaluations.
12. **`src/radflowload.c`**: Cavity radiation and thermal fluid network equations.
13. **`src/steadystate.c`**: Harmonic steady-state dynamics frequency sweeps.

#### F. Multi-Solver Keyword Recognition in Fortran Input Parsers (14 files)
The following card reader subroutines were updated to recognize `SOLVER=MUMPS` (`isolver=9`) and `SOLVER=ACCELERATE` (`isolver=11`) parameters:
1. **`src/statics.f`** (`*STATIC`)
2. **`src/frequencys.f`** (`*FREQUENCY`)
3. **`src/buckles.f`** (`*BUCKLE`)
4. **`src/dynamics.f`** (`*DYNAMIC`)
5. **`src/modaldynamics.f`** (`*MODAL DYNAMIC`)
6. **`src/steadystatedynamicss.f`** (`*STEADY STATE DYNAMICS`)
7. **`src/heattransfers.f`** (`*HEAT TRANSFER`)
8. **`src/couptempdisps.f`** (`*COUPLED TEMPERATURE-DISPLACEMENT`)
9. **`src/uncouptempdisps.f`** (`*UNCOUPLED TEMPERATURE-DISPLACEMENT`)
10. **`src/substructuregenerates.f`** (`*SUBSTRUCTURE GENERATE`)
11. **`src/electromagneticss.f`** (`*ELECTROMAGNETICS`)
12. **`src/cfds.f`** (`*CFD`)
13. **`src/greens.f`** (`*GREEN`)
14. **`src/viscos.f`** (`*VISCO`)

---

### 9.4 Newly Added Tooling, Test & Infrastructure Files

| File / Directory | Category | Functional Purpose |
|:---|:---|:---|
| **`CMakeLists.txt`** | Build | Unified cross-platform CMake build configuration supporting Linux, macOS, and Windows. |
| **`install.sh`** | Installer | Single-command automated installation script for Linux and macOS. |
| **`install.ps1`** | Installer | Single-command automated PowerShell installer for Windows MSYS2 UCRT64. |
| **`.github/workflows/ci.yml`** | CI/CD | GitHub Actions multi-solver testing matrix across Ubuntu x86_64, macOS Apple Silicon, and Windows MSYS2. |
| **`test_NewLib/run_official_testsuite.py`** | Verification | Sandboxed multi-process test runner validating against 630+ official decks. |
| **`test_NewLib/benchmark_solvers.py`** | Benchmarking | Automated thread-scaling benchmark script measuring wall time, peak memory (RSS), and physical accuracy. |
| **`test_NewLib/generate_json_references.py`** | Verification | Tool to generate golden `.json.ref` references from baseline solver runs. |
| **`test_NewLib/json_checker.py`** | Verification | Pure Python in-memory numerical comparator for JSON output validation. |
| **`test_NewLib/originaltest_json/*.json.ref`** | Verification | Pre-computed golden reference JSON files for upstream verification suite. |
| **`third_party/mumps/`** | Vendor Archive | Pinned source archive (`MUMPS_5.9.1.tar.gz`) with SHA-256 integrity check and macOS build rules. |
| **`third_party/spooles/`** | Vendor Archive | Pinned source archive (`SPOOLES_2.2.tar.gz`) with SHA-256 integrity check for macOS. |

---

## 10. Upstream Synchronization Log

| Date | Upstream range | Notes |
|:---|:---|:---|
| 2026-11-20 | `0787781..57a4e71` (39 commits) | Merged into branch `merge/upstream-2026-11`. Upstream's new native CMake build (`cmake/`, `CMakePresets.json`) is kept for reference only; this fork's `CMakeLists.txt` remains the supported build. `src/date.pl` was replaced upstream by `src/buildinfo.c` (`ccx_compiletime`), which is not listed in `Makefile.inc` and is therefore added explicitly in `CMakeLists.txt` and `src/Makefile`. Upstream `INSTALL.md` archived as `doc/INSTALL_upstream.md`. Fixed JSON export for decks that request `*EL PRINT` before `*NODE PRINT`. Details: `test_NewLib/merge_2026-11/REPORT.md`. |
| 2026-11-23 | `57a4e71` = ccx 2.24 | Verified that the official `ccx_2.24.src.tar.bz2` matches `57a4e71` (tag `ccx-2.24-upstream`); `tools/verify_upstream_release.py`. Version strings set to `Version 2.24` as in the release, with an extra `MultiSolver edition` banner line. Upstream's `CMakeLists.txt` and `CMakePresets.json` kept verbatim in `cmake/upstream/`. Release `v2.24-multisolver-0.2`. Details: [UPSTREAM_2.24.md](UPSTREAM_2.24.md). |
