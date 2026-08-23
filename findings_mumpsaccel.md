# CalculiX Solver Investigation: Apple Accelerate & MUMPS 5.x Root Cause Analysis

This document summarizes the mathematical, architectural, and code-level findings regarding the performance of **Apple Accelerate** (macOS) and **MUMPS 5.x** (Linux/Windows) within CalculiX CCX 2.23 (NewLib), specifically for the Linux agent continuing the MUMPS work.

---

## 1. Executive Summary & Verification Matrix

| Solver | Platform | Status | Pass Rate | Time (21 Decks) | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Intel oneMKL PARDISO** | Linux x64 (zurcachy) | **Verified Baseline** | **100.0%** (21/21) | 1.44 s | Reference solver (0 crashes, 0 diffs) |
| **SPOOLES 2.2** | Linux x64 (zurcachy) | **Verified Baseline** | **100.0%** (21/21) | 1.33 s | Original Dhondt reference solver |
| **Apple Accelerate** | macOS ARM64 (Apple Silicon) | **Working** | **95.2%** (20/21) | 3.92 s | 0 crashes; all dynamic contact decks pass |
| **MUMPS 5.x** | Linux x64 (zurcachy) | **In Progress** | **71.4%** (15/21) | 22.13 s | Linear statics & standard contact PASS; explicit contact fails |

---

## 2. Apple Accelerate Root Cause & Fix (macOS)

### Problems Identified & Solved:
1. **Threshold Filtering (< 1e-12)**:
   - In `src/accelerate_solver.c:147`, an arbitrary filter `if (au[k] > 1e-12 || au[k] < -1e-12)` was dropping minor off-diagonal terms.
   - In contact problems with penalty formulation and friction regularization, dropping small coupling terms deteriorated matrix conditioning.
   - **Fix**: Removed threshold filtering to ensure exact structural and numerical assembly matching SPOOLES and PARDISO.

2. **Adjoint Transpose Solve (nrhs < 0)**:
   - In sensitivity analysis (`contact10`), CCX passes `nrhs = -1` to request the solution of the transposed adjoint system A^T x = b.
   - In `accelerate_solve`, `columnCount` was assigned `-1` (invalid dimension) and `attributes.transpose` was hardcoded to `false`.
   - **Fix**: Set `.columnCount = abs(*nrhs)` and `.attributes.transpose = (*nrhs < 0)`.

3. **macOS Stack Overflow**:
   - Resolved by linking with `-Wl,-stack_size,0x10000000` (256MB stack) and setting `OMP_STACKSIZE=128M`.

---

## 3. MUMPS 5.x Deep-Dive & Root Cause Analysis (Linux/zurcachy)

### What Passes in MUMPS:
- Linear statics (`achtel2`, `achtel29`, `beam8f`, `beam8t`, `spring1`, etc.) -> **100% PASS**.
- Standard penalty contact & MPCs (`beam8p`, `beam8p_mpc`, `contact1`, `contact11`, `contact12`, `contact13`, `contact14`, `contact18`) -> **100% PASS**.

### What Fails in MUMPS:
- Explicit dynamic contact decks: `contact15`, `contact16`, `contact17`, `contact19` (Exit -11 / SIGSEGV).
- Massless linear contact deck: `contact15lin` (DAT DIFF -> NaN divergence).

### Detailed Mathematical Root Cause:
In explicit dynamics (`*DYNAMIC, EXPLICIT` in `src/nonlingeo.c:1250-1350`), the effective system matrix is the lumped diagonal mass matrix divided by time increment:
A = (1 / dt) * M_diag
When contact DOF reduction (`reducematrix`) occurs, contact constraint DOFs are reduced to diagonal 1.0 and off-diagonal 0.0.

#### Step-by-Step Breakdown of `contact15lin`:
- **Increment 1**:
  - b_1 = F_ext.
  - MUMPS calculates x_1 = A^-1 b_1 = -4.807692e-05.
  - **Matches PARDISO and SPOOLES to 7 decimal digits!**
- **Increment 2**:
  - PARDISO outputs x_2 = -1.377589e-04.
  - MUMPS outputs x_2 = -0.1275499 (approx 1000x too large).
- **Increment 3**:
  - PARDISO outputs x_3 = -2.569735e-04.
  - MUMPS outputs x_3 = -338.2672 (exploding).
- **Increment 4**:
  - MUMPS outputs x_4 = NaN -> Node coordinates grow to x_p ~ 2.4e50 -> SIGSEGV in `src/near3d.f:95`.

### Why MUMPS Explodes on Increment 2+:
1. **Scaling Perturbation (ICNTL(8))**:
   - `id.icntl[7] = 77` enables automatic iterative scaling. On purely diagonal or near-singular contact matrices, automatic scaling can introduce numerical drift on unconstrained DOFs.
   - For symmetric positive definite / diagonal mass matrices, scaling should be disabled (`ICNTL(8) = 0`).
2. **Pivoting & Null Pivot Handling (ICNTL(24) & CNTL(1))**:
   - With `id.sym = 2` (symmetric general), MUMPS applies 2x2 Bunch-Kaufman pivoting. If `CNTL(1)` is non-zero, it attempts numerical pivoting which perturbs diagonal ordering.
   - For positive definite or lumped mass matrices, `id.sym = 1` (symmetric positive-definite, LL^T / Cholesky) or `CNTL(1) = 0.0` prevents unnecessary 2x2 pivot swaps.
3. **Persistent Factorization Reuse**:
   - `src/mumps.c` now caches symbolic analysis (`id.job = 1`) across time steps, calling numeric refactorization (`id.job = 2`) only when dimensions change.

---

## 4. Next Steps for the Next Agent on Linux (zurcachy)

1. **Working Directory on `zurcachy`**:
   - `/home/zurdo/MyCode/CalculiX/ccx_fromMac`
   - MUMPS static library location: `/home/zurdo/MyCode/CalculiX/mumps`

2. **Test Command**:
   ```bash
   cd /home/zurdo/MyCode/CalculiX/ccx_fromMac
   cmake --build build_mumps -j$(nproc)
   python3 test_NewLib/run_official_testsuite.py --solvers MUMPS --pattern 'contact15*' 'contact10*'
   ```

3. **Key Parameters to Adjust in `src/mumps.c`**:
   - In `mumps_factor`:
     - Test `id.icntl[7] = 0;` (disable matrix scaling `ICNTL(8) = 0` for dynamic contact).
     - Test `id.cntl[0] = 0.0;` (disable threshold pivoting `CNTL(1) = 0.0`).
     - Test `id.sym = (*symmetryflag == 0) ? 1 : 0;` (symmetric positive definite Cholesky if applicable).
     - Verify `id.icntl[23] = 1;` (null pivot detection `ICNTL(24) = 1`).

4. **Reference Reference Solvers**:
   - PARDISO: `build_pardiso/CalculiX` (100% 21/21 pass)
   - SPOOLES: `build_spooles/CalculiX` (100% 21/21 pass)
