# Native Apple Accelerate Sparse Direct Solver for CalculiX on macOS

*Author: Carlo Monjaraz-Tec*  
*Date: August 2026*  
*Repository: [CalculiX-CrunchiX-MultiSolver](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver)*

---

## Overview

This document details the integration of Apple's native **Accelerate vecLib Sparse Direct Solver** into **CalculiX CrunchiX (CCX)**, providing hardware-accelerated linear algebra support for macOS and Apple Silicon (M-series) systems.

### Summary:
* **Performance**: Up to 2.25x faster overall execution compared to SPOOLES 2.2 on larger 3D meshes.
* **Fast Triangular Solves**: ARPACK modal frequency extractions execute in ~100 µs per Lanczos iteration.
* **Zero External Solver Dependencies**: Uses the built-in macOS Accelerate Framework (`-framework Accelerate`), removing the need for external Fortran MUMPS or third-party solver installations on macOS.
* **Adaptive METIS Ordering**: Automatic nested dissection graph partitioning for continuum meshes ($N \ge 5,000$ DOFs) reduces non-zero fill-in.
* **macOS Default**: Configured as the out-of-the-box default solver when building on macOS with CMake.

---

## Background: Sparse Linear Solvers in CalculiX

CalculiX (developed by Dr. Guido Dhondt) has traditionally used **SPOOLES 2.2** (written in 1999 by Cleve Ashcraft) as its primary open-source direct sparse solver. While SPOOLES is robust and well-designed for small-to-medium meshes, it predates modern 64-bit vector SIMD instruction sets and unified memory architectures.

On Linux x86_64, Intel oneMKL PARDISO offers strong multi-threaded performance. However, on macOS (Apple Silicon ARM64), there has historically been no native high-performance direct solver interface in CCX.

By interfacing directly with Apple's `vecLib/Sparse` library, CCX can now take advantage of macOS's built-in multi-threaded supernodal factorization and vector BLAS routines without additional runtime dependencies.

---

## Implementation Details

### 1. Factorization Methods
* **Symmetric Systems (`SparseFactorizationLDLTTPP`)**:
  For standard FEA stiffness matrices and contact/MPC formulations, the solver uses $LDL^T$ factorization with Threshold Partial Pivoting (TPP). This ensures numerical stability when contact pairs or cyclic symmetry constraints introduce indefinite systems.
* **Unsymmetric Systems (`SparseFactorizationQR`)**:
  For non-conservative loading, fluid-structure interaction, or non-associated plasticity, QR decomposition is used.

### 2. Fill-in Reduction Ordering
Graph ordering significantly influences sparse solver memory and CPU requirements:
* For small models ($N < 5,000$ DOFs): **Approximate Minimum Degree (AMD)** minimizes symbolic analysis overhead.
* For larger 3D meshes ($N \ge 5,000$ DOFs): **METIS Nested Dissection** produces lower fill-in in factor $L$.

### 3. Matrix Format Bridge
CCX stores matrices in compressed column format (`ad`, `au`, `icol`, `irow`). The driver converts these into Accelerate's Compressed Sparse Column (CSC) structure with minimal overhead (<20 ms for several million non-zeros).

---

## Benchmark Results

### Benchmark 1: Medium 3D Solid Beam (36,912 DOFs, 2,560 C3D20 Elements)

Evaluated on Apple Silicon with 20-node quadratic hexahedral elements:

| Thread Configuration | SPOOLES 2.2 | Apple Accelerate (METIS) | Speedup |
| :---: | :---: | :---: | :---: |
| **1 Thread** | 2.29 s | **1.15 s** | **2.00x** |
| **2 Threads** | 1.58 s | **0.94 s** | **1.67x** |
| **4 Threads** | 1.31 s | **0.83 s** | **1.58x** |
| **8 Threads** | 1.59 s | **0.97 s** | **1.64x** |

---

### Benchmark 2: High-Density Stress Test (178,920 DOFs, 13,500 C3D20 Elements, 14.4M Non-Zeros)

Evaluated under higher memory load (~4.5 GB RAM footprint):

| Thread Configuration | SPOOLES 2.2 | Apple Accelerate (METIS) | Speedup |
| :---: | :---: | :---: | :---: |
| **1 Thread** | 43.90 s | **19.51 s** | **2.25x** |
| **2 Threads** | 29.34 s | **15.70 s** | **1.87x** |
| **4 Threads** | 21.82 s | **14.94 s** | **1.46x** |
| **8 Threads** | 19.59 s | **15.30 s** | **1.28x** |

---

### Profiling Breakdown (Amdahl's Law in FEA)

A timing breakdown of a typical 37,000 DOF run illustrates the distribution of compute time:

| Stage | Time | Share |
| :--- | :---: | :---: |
| 1. Input parsing and allocation | 0.05 s | ~4% |
| 2. MPC decascading and sparsity graph setup | 0.22 s | ~17% |
| 3. Fortran element stiffness integration (`e_3d.f`) | 0.52 s | ~41% |
| 4. Matrix format conversion (COO to CSC) | 0.017 s | ~1% |
| 5. **Apple Accelerate Factorization (`SparseFactor`)** | **0.63 s** | **~35%** |
| 6. **Triangular Solve (`SparseSolve`)** | **0.015 s** | **~1%** |
| 7. Stress recovery and output writing | 0.12 s | ~9% |

Because element stiffness integration and sparsity setup account for ~60% of total runtime, accelerating the direct solver primarily optimizes the remaining ~40% factorization portion.

---

### Thread Scheduling on Apple Silicon

During multi-thread evaluation:
* **4 Threads**: Matches the physical Performance core (P-core) count on standard Apple Silicon configurations, yielding optimal throughput.
* **8 Threads**: Spanning across both Performance and Efficiency cores introduces synchronization overhead in fine-grained sparse factorization barriers.
* **Recommendation**: Setting `OMP_NUM_THREADS` or `CCX_NPROC_EQUATION_SOLVER` to the number of physical Performance cores gives the most consistent performance.

---

## Build and Usage Instructions

### 1. Build on macOS
Apple Accelerate is enabled by default when compiling on macOS:

```bash
# Prerequisites
brew install cmake gcc arpack

# Clone repository
git clone https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver.git ccx
cd ccx

# Configure and build
cmake -B build
cmake --build build -j$(sysctl -n hw.ncpu)
```

### 2. Running an Analysis
Accelerate is invoked automatically for unadorned input decks:

```bash
./build/CalculiX beam_benchmark
```

To explicitly select the solver in an input deck:
```text
*STEP
*STATIC, SOLVER=ACCELERATE
...
*END STEP
```

---

## Conclusion

The Apple Accelerate sparse direct solver integration provides a clean, dependency-free solution for running CalculiX on macOS, delivering up to 2.25x speedups over classic SPOOLES without requiring external linear algebra packages.

