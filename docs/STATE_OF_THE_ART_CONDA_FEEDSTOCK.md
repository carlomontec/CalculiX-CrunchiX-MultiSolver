# State of the Art: Conda-Forge CalculiX Feedstock Analysis and Comparative Study with Multi-Solver CCX

**Author**: Dr. Carlo Monjaraz-Tec  
**Base Project**: CalculiX CrunchiX (CCX) by Dr. Guido Dhondt  
**Focus**: Comparative Technical Study between Conda-Forge Feedstock (`calculix-feedstock`) and CalculiX CrunchiX Multi-Solver Edition  
**Audience**: Finite-element developers and the CalculiX community  

---

## 1. Executive Summary

CalculiX CrunchiX (CCX) remains one of the most prominent open-source implicit 3D structural, thermal, and multi-physics finite element solvers in both industry and academia. For years, deploying CCX across heterogeneous computing environments (Linux x86_64/aarch64, macOS Apple Silicon, Windows) has presented challenges due to platform-specific Makefiles, legacy Fortran 77 parameter conventions, and hardcoded linear algebra dependencies.

Two independent efforts have emerged in the CalculiX ecosystem to modernize and stabilize the codebase:

1. **The Conda-Forge Packaging Initiative (`conda-forge/calculix-feedstock`)**: Driven primarily by downstream packaging engineers and the FreeCAD FEM community (e.g., `oursland`, `looooo`, `Krande`). This initiative focuses on automated binary packaging, compiler standard compliance, input fuzzing, and sanitizer-driven bug fixes for the baseline CalculiX 2.23 distribution on the `conda-forge` channel.
2. **The CalculiX CrunchiX Multi-Solver Project (`CalculiX-CrunchiX-MultiSolver`)**: Led by Dr. Carlo Monjaraz-Tec. This initiative focuses on high-performance solver backend modernization (MUMPS 5.x, Apple Accelerate, Intel oneMKL PARDISO, SPOOLES 2.2), modern `arpack-ng` eigenvalue extraction, target-based CMake orchestration, hardware-level thread affinity, RFC 8259 in-memory JSON export, and sandboxed 630-deck automated validation.

This document provides a systematic review of the Conda-Forge CalculiX recipe, audits its comprehensive patch suite, compares its architectural design with the Multi-Solver edition, and synthesizes key insights for technical presentation at the CalculiX Convention.

---

## 2. Conda-Forge Feedstock Architecture & Packaging Workflow

The Conda recipe is hosted at [conda-forge/calculix-feedstock](https://github.com/conda-forge/calculix-feedstock) and distributed via Anaconda channels (`conda-forge` and `cf-staging`).

### 2.1 Build Orchestration
- **Recipe Format**: Built using `rattler-build` with modern declarative `recipe.yaml` syntax.
- **Upstream Source**: Fetches the official release tarball (`http://www.dhondt.de/ccx_2.23.src.tar.bz2`, SHA256: `9c88385c10fb...`).
- **Platform Toolchains**:
  - **Linux (x86_64, aarch64)**: Native GCC and GFortran with POSIX OpenMP and `librt`.
  - **macOS (x86_64, arm64)**: Clang C compiler, GFortran compiler, and `llvm-openmp`.
  - **Windows (x86_64)**: MSYS2 MinGW-w64 toolchain (`m2w64_c`, `m2w64_fortran`).
- **Build Scripts**: Maintains customized shell (`build.sh`) and batch (`build.bat`) wrappers that execute a patched Makefile (`recipe/Makefile_MT`).
- **Compiler Compatibility Flags**:
  - `FFLAGS`: Appends `-cpp` (required for macro preprocessing in `move.f`) and `-fallow-argument-mismatch` (to tolerate Fortran 77 parameter mismatches in GCC 10+).
  - `CFLAGS`: Appends `-Wno-error=implicit-function-declaration` on macOS.
- **Binary Timestamp Handling**: Employs a dedicated Perl script (`date.pl`) to stamp build metadata into `frd.c` prior to compilation, ensuring `.frd` headers contain clean reproducible timestamp data.

---

## 3. Systematic Taxonomy of Conda-Forge Patches

The Conda-Forge recipe incorporates over 30 targeted patches applied directly onto CCX 2.23. These patches address six distinct failure modes:

```
+---------------------------------------------------------------------------------------+
|                         Conda-Forge CCX 2.23 Patch Suite                              |
+---------------------------------------------------------------------------------------+
|  1. Portability & Compilers : mingw_time, avoid-ifport, fix-readnewmesh-return        |
|  2. Numerical & Locale     : setlocale(LC_NUMERIC, "C") across 13 core C routines     |
|  3. Memory Bounds (ASan)   : springforc_f2f (3,19) fix, tabular overclosure           |
|  4. Concurrency & Scaling  : compfluidfem 1,000 node threshold, SPOOLES MT race fix   |
|  5. FreeCAD Integration    : 2D rotational DOFs guard (FreeCAD issue #10865)          |
|  6. Fuzzing Robustness     : 71 malformed syntax crash sites turned into exit code 201|
|  7. Upstream Backports     : Dhondt post-2.23 fixes backported (Nov 2025 - Sep 2026)  |
+---------------------------------------------------------------------------------------+
```

### 3.1 Portability and Toolchain Hardening
* **`mingw_time.patch`**:
  - Removes the obsolete MSVC runtime call `_set_output_format(_TWO_DIGIT_EXPONENT)` which fails under MinGW-w64.
  - Comments out `clock_gettime(CLOCK_MONOTONIC)` wall-clock timers in `ccx_2.23.c` and `ccx_2.23step.c` which triggered compilation failures on Windows and older BSD/macOS runtimes.
* **`avoid-ifport.patch`**:
  - In `src/move.f`, upstream included `#if defined(__INTEL_COMPILER) use ifport, only: rename`. When compiled without preprocessor flags, GFortran attempted to compile both the Intel module import and the GNU fallback. The patch strips `ifport` and standardizes on GNU `rename()`.
* **`fix-readnewmesh-return.patch`**:
  - `src/readnewmesh.c` was declared as returning `void`, yet terminated with `return NULL;`. Modern C compilers (Clang on macOS and GCC 14+) treat returning a pointer from a void function as a fatal compilation error. The patch replaces this with `return;`.

### 3.2 Locale and Character Encoding Safeguards
* **`upstream-locale-numeric.patch` & `fix-win-locale.patch`**:
  - **Failure Mode**: When CalculiX runs on operating systems configured with European or Latin American locale settings (where commas `,` serve as decimal points), standard C `printf` and `sscanf` format floating-point values as `0,00000E+00`. Downstream post-processors (FreeCAD FEM, CGX, ParaView converters) expect standard scientific formatting with period separators (`0.00000E+00`), causing silent parsing failures.
  - **Resolution**: Conda-forge inserted `setlocale(LC_NUMERIC, "C");` in `ccx.c`, `ccxstep.c`, and 13 internal computational routines (`frd.c`, `frdvector.c`, `frdgeneralvector.c`, `frdheader.c`, `frdselect.c`, `nonlingeo.c`, `pcgsolver.c`, `printenergy.c`, `radflowload.c`, `randomfieldmain.c`, `sensitivity_out.c`, `complexfreq.c`, and `electromagnetics.c`).

### 3.3 Memory Safety and Array Overrun Fixes (AddressSanitizer)
* **`upstream-f2f-contact-array-bounds.patch`**:
  - **Failure Mode**: In face-to-face contact subroutines (`springforc_f2f.f`, `objective_shapeener_dx.f`, `resultsmech.f`, `resultsmech_se.f`), coordinate and force work arrays were declared with static dimensions of 10 (`xl(3,10)`, `fnl(3,10)`). However, quadratic 20-node brick elements and contact formulations index up to 19 nodes (`pl(3,19)`, `vl(0:mi(2),19)`). Under compiler optimization `-O3`, loop auto-vectorization wrote past array bounds, corrupting adjacent stack data and causing 25+ deck failures.
  - **Resolution**: Dimensions corrected from `(3,10)` to `(3,19)`.
* **`fix-f2f-tabular-overclosure.patch`**:
  - Face-to-face contact with tabular pressure overclosure (`PRESSURE-OVERCLOSURE=TABULAR`) passed an obsolete 82-entry `plconloc` buffer to `materialdata_sp.f`, which writes into indices 801 and 802. This caused memory corruption or divergence in tabular contact models.
* **Uninitialized Memory Poisoning**:
  - Patches `fix-electromagnetics-ithermal-array.patch`, `fix-cd-lab-correction-edges.patch`, and `fix-calinput-cs-guard.patch` fixed uninitialized variable reads exposed by running AddressSanitizer over FreeCAD FEM test models.

### 3.4 Concurrency, Threading, and Data Races
* **SPOOLES ARM64 Synchronization Fix**:
  - In upstream SPOOLES 2.2, multithreaded factorization and forward/backward substitution transferred matrix data between threads via shared memory without memory fences or synchronization primitives. On x86_64 CPUs, total store order (TSO) hardware guarantees masked this bug. On weakly-ordered ARM64 architectures (macOS Apple Silicon, AWS Graviton), threads observed stale data, silently producing incorrect solutions in contact and CFD. Conda-forge resolved this by patching the SPOOLES package itself (`spooles >=2.2, build_number >=1006`).
* **`fix-cfd-threaded-boundary-conditions.patch`**:
  - Resolved race conditions in multithreaded CFD where boundary conditions were applied across threads prior to resolving Single Point Constraints (SPCs).
* **`fix-cfd-small-mesh-threads.patch`**:
  - In `src/compfluidfem.c`, upstream created and destroyed thread teams for every loop of every iteration. On small CFD models (< 1,000 nodes), thread synchronization latency exceeded computation time, rendering multithreaded runs up to 5x slower than single-core runs. The patch introduces a heuristic threshold: `num_cpus = nk / 1000`, guaranteeing each worker thread handles at least 1,000 nodes.

### 3.5 Downstream FreeCAD FEM Interoperability
* **`fix-2d-rotational-dofs.patch` (FreeCAD Issue #10865)**:
  - When users in FreeCAD applied rotational Single Point Constraints (DOFs 4, 5, or 6) or moments onto 2D plane stress, plane strain, or axisymmetric meshes, the boundary conditions entered CCX's 3D mean rotation expansion routines (`gen3dboun.f`, `gen3dforc.f`). Because loop bounds in those routines were only initialized for 1D beams and 2D shells, the code traversed uninitialized stack memory, causing silent hangs on Windows and segmentation faults on macOS. The patch detects 2D continuum elements and gracefully ignores unsupported rotational DOFs.

### 3.6 Deck Fuzzing & Malformed Input Handling
* **`fix-malformed-input-*.patch` (7 patch files)**:
  - The maintainers conducted systematic input deck fuzzing across 518 standard decks under AddressSanitizer. They discovered 71 distinct syntax edge cases (such as elements with node 0, negative degrees of freedom, missing `*STEP` tags, or undefined section assignments) that caused CCX to hang, segfault, or access out-of-bounds memory.
  - The patches ensure that every invalid input triggers a clean `*ERROR` diagnostic and terminates with exit code 201 rather than crashing the host process.

---

## 4. Comprehensive Comparison: Conda-Forge vs. Multi-Solver CCX

The table below contrasts the technical architecture, capabilities, and design goals of the Conda-Forge packaging recipe against the CalculiX CrunchiX Multi-Solver edition:

| Architectural Dimension | Upstream CCX 2.23 (Vanilla) | Conda-Forge Feedstock (`calculix`) | Multi-Solver Modernized CCX (`CalculiX-CrunchiX-MultiSolver`) |
|:---|:---|:---|:---|
| **Primary Project Objective** | Original academic development by Dr. Guido Dhondt. | Binary packaging, stability hardening, and FreeCAD FEM integration. | Algorithmic modernization, multi-solver performance, and modern scientific data interoperability. |
| **Linear Equation Solvers** | SPOOLES 2.2 (hardcoded calls). | SPOOLES 2.2 (statically linked `spoolesMT.a` + `spooles.a`). | **MUMPS 5.x** (default open-source), **Apple Accelerate** (macOS native), **Intel oneMKL PARDISO**, and **SPOOLES 2.2**. |
| **Solver Selection Syntax** | Hardcoded or compile-time flags. | Static compile-time SPOOLES. | Dynamic deck selection (`*STATIC, SOLVER=MUMPS / ACCELERATE / PARDISO / SPOOLES`) or CLI defaults. |
| **Eigenvalue Engine** | Legacy ARPACK 96 source archive (1996). | Legacy ARPACK 96 source archive. | Actively maintained **`arpack-ng`** integrated with multi-solver spectral shift-and-invert. |
| **Build Infrastructure** | Static `Makefile_MT` with manual path editing. | Wrapper scripts (`build.sh` / `build.bat`) invoking patched `Makefile_MT`. | Target-based **CMake 3.20+** (`CMakeLists.txt`), full CTest integration, automatic dependency discovery. |
| **BLAS / LAPACK Integration** | Netlib / hardcoded system BLAS. | Netlib / OpenBLAS via Conda requirements. | Hardware-adaptive: **AMD AOCL-BLIS**, **OpenBLAS**, **Intel oneMKL**, or **Apple Accelerate**. |
| **macOS Native Optimization** | None (unoptimized generic x86_64). | Generic Apple Silicon compilation via `llvm-openmp`. | Native **Apple Accelerate Sparse Solver**, dynamic **P-core hardware binding**, and 256 MB executable stack. |
| **Thread Scaling & Concurrency** | Dynamic `pthread_create` spawning inside SpMV (`opmain.c`). | Retains upstream pthread structure; added node threshold in CFD. | **OpenMP SpMV refactoring** in `opmain.c` (persistent thread teams, zero-allocation fast paths). |
| **Data Interoperability** | Fixed-width ASCII `.dat` and `.frd`. | Fixed-width ASCII `.dat` and `.frd`. | Complete `.dat` and `.frd` preserved + direct in-memory **RFC 8259 JSON Export** (`-j` / `--json`). |
| **Verification & Quality Assurance** | Sequential Perl and shell scripts modifying directories in-place. | `run_test.py` running 5 targeted regression models. | Sandboxed parallel runner (`test_NewLib`), process isolation, in-memory JSON comparisons for 630+ decks. |
| **Error Handling & Fuzzing** | Crashes or hangs on malformed deck syntax. | Hardened with 71 fuzzing patches; exit code 201 on invalid cards. | Standard upstream error handling; prioritized solver convergence diagnostics. |

---

## 5. Synthesis

The Conda-Forge packaging effort and the Multi-Solver edition approach the same code base from different directions and complement each other:

### Key observations

1. **Two Complementary Modernization Vectors**:
   - The **Conda-Forge community** approached CalculiX from an *external software engineering perspective*: packaging, toolchain modernization, compiler standards conformance, and AddressSanitizer testing for GUI users (FreeCAD).
   - The **Multi-Solver project** approached CalculiX from an *algorithmic and high-performance computing perspective*: eliminating the linear solver bottleneck (replacing legacy SPOOLES with MUMPS, Accelerate, and PARDISO), integrating maintained eigenvalue solvers (`arpack-ng`), and establishing modern data interfaces (JSON).

2. **The Shared Problem of Legacy Dependencies**:
   - Both projects independently identified identical structural friction points in upstream CalculiX: the fragility of 1990s Fortran 77 code in modern compilers (requiring `-fallow-argument-mismatch` and `-cpp`), the instability of legacy ARPACK 96, and multithreading synchronisation weaknesses on ARM64 architectures.

3. **High-Value Upstream Contributions**:
   - The Conda-Forge patches represent significant community value that should be folded into the main CalculiX trunk (or maintained within modernized forks). Specifically:
     - The **`setlocale(LC_NUMERIC, "C")`** fix is mandatory for international engineering software reliability.
     - The **`springforc_f2f.f` array dimension correction (`xl(3,19)`)** fixes an active buffer overrun that corrupts high-optimization (`-O3`) builds.
     - The **`compfluidfem.c` node thresholding** prevents severe multithreading degradation on small fluid meshes.

4. **Outlook**:
   - A unified architecture combining the **Multi-Solver engine** (MUMPS, Accelerate, PARDISO, JSON export, modern CMake) with the **Conda-Forge defensive safeguards** (locale locks, AddressSanitizer fixes, and fuzzing-hardened card parsing) delivers the most performant, robust, and portable CalculiX distribution available to the engineering community.

---

## 6. References & Primary Sources

1. **Dhondt, G.** (2004). *The Finite Element Method for Three-Dimensional Thermomechanical Applications*. John Wiley & Sons, Ltd.
2. **Dhondt, G.** *CalculiX CrunchiX User's Manual - Version 2.23*. [http://www.dhondt.de/ccx_2.23.pdf](http://www.dhondt.de/ccx_2.23.pdf).
3. **Conda-Forge CalculiX Feedstock**: [https://github.com/conda-forge/calculix-feedstock](https://github.com/conda-forge/calculix-feedstock).
4. **Anaconda Package Overview (Conda-Forge Staging)**: [https://anaconda.org/channels/cf-staging/packages/calculix/overview](https://anaconda.org/channels/cf-staging/packages/calculix/overview).
5. **FreeCAD Project**: *Issue #10865: Rotational constraints on axisymmetric elements cause crash in CalculiX*. [https://github.com/FreeCAD/FreeCAD/issues/10865](https://github.com/FreeCAD/FreeCAD/issues/10865).
6. **CalculiX CrunchiX Multi-Solver Edition**: [https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver).
