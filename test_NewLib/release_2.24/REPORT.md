# Release Validation Report: `v2.24-multisolver-0.2`

- Release branch: `release/v2.24-multisolver-0.2` (from `main` at `de52e00`)
- Upstream reference: tag `ccx-2.24-upstream` = `57a4e71` = official ccx 2.24
  (see [docs/UPSTREAM_2.24.md](../../docs/UPSTREAM_2.24.md))
- Date: 2026-11-23

## 1. Linux: this edition vs plain CalculiX 2.24 (the equivalence evidence)

Machine: CachyOS (Linux 7.3), 12 cores, GCC/gfortran 16.2.1, CMake 4.5.1.

| Binary | Build |
|:---|:---|
| **Reference** | `ccx-2.24-upstream` exported with `git archive`, built with **upstream's own CMake** (`CMAKE_BUILD_TYPE=Release`, `-O2` as in the official Makefile) |
| **This edition** | release branch, this edition's CMake, SPOOLES only, `CCX_BLAS=NETLIB` |

Both link the same system libraries: netlib BLAS/LAPACK 3.12.1, arpack 3.9.1,
SPOOLES 2.2 (`/usr/lib/libspooles.so`), libgomp.

Method: `tools/compare_binaries.py` runs all 642 decks of `test/` (the deck
list of upstream's `test/compare`) with both binaries and compares the two
binaries' `.dat` and `.frd` outputs **with each other**. A deck is
*identical* if both files match byte for byte (`.frd` user header lines
`1U...` with version and compile time ignored), and *within tolerance* if
Dhondt's `datcheck.pl` / `frdcheck.pl` accept them (0.1 % of the block maximum).

| Run | Identical | Within tol. | Diff | Exit code differs |
|:---|---:|---:|---:|---:|
| `OMP_NUM_THREADS=1` | **642** | 0 | 0 | 0 |
| `OMP_NUM_THREADS=4`, this edition **with** `USE_MT` (current CMake default) | 328 | 255 | 58 | 1 |
| `OMP_NUM_THREADS=4`, this edition **without** `USE_MT` | **635** | 7 | 0 | 0 |
| `OMP_NUM_THREADS=4`, release build (`USE_MT`) with `CCX_NPROC_EQUATION_SOLVER=1` | **635** | 6 | 1 | 0 |

CSV files: `linux_spooles_omp1.csv`, `linux_spooles_omp4_useMT.csv`,
`linux_spooles_omp4_noMT.csv`, `linux_spooles_omp4_solver1.csv`.

### Findings

1. **Single-threaded, the results are byte-identical to CalculiX 2.24 in all
   642 decks.** This includes the 21 explicit dynamics decks
   (`*DYNAMIC, EXPLICIT`) and the mass-scaling decks (`beamfsms`,
   `beamnldyems`, `segmenttetsms`). The stable time increment fix in
   `calcstabletimeincvol.f` does not change any deck of the official suite.
   18 decks end with a non-zero exit code (e.g. 201, 16) in **both** binaries:
   these are upstream's intentional error-checking decks.

2. **`USE_MT` makes SPOOLES non-deterministic with more than one thread.**
   This edition's `CMakeLists.txt` defines `USE_MT=1`. That enables SPOOLES'
   multithreaded factorization and solve in `src/spooles.c` (the only file that
   uses `USE_MT`). Upstream's default `Makefile` and upstream's CMake do **not**
   define it; only upstream's `Makefile_MT` does. With 4 threads, `beamf3` and
   `mass2` give a different `.dat` on every run, and eigenvalues move by
   several percent. Checks:
   - plain 2.24 built with `USE_MT` (via upstream's own hook
     `CCX_EXTRA_COMPILE_DEFS=USE_MT=1`) shows the same run-to-run variation;
   - this edition built without `USE_MT` gives the same result on every run,
     byte-identical to plain 2.24 at 4 threads;
   - swapping our OpenMP `opmain.c` for upstream's `opmain.c` does not remove
     the variation.

   So this is how SPOOLES behaves in multithreaded mode, not a defect in this
   edition's code.

   **Decision (2026-11-23): `USE_MT` stays on** (multithreaded SPOOLES, as in
   upstream's `Makefile_MT`). It is documented as a known behaviour in
   `INSTALL.md` ("SPOOLES and multithreading"), `README.md` and
   `docs/CHANGES_VS_CCX.md`, together with the note that SPOOLES is not
   recommended in this edition. For reproducible SPOOLES results identical to
   2.24, users set `CCX_NPROC_EQUATION_SOLVER=1`: SPOOLES then runs on one
   thread, and the rest of CalculiX keeps using `OMP_NUM_THREADS`. Checked with
   the release build at `OMP_NUM_THREADS=4`: `beamf3` and `mass2` give the same
   result on three runs each, byte-identical to plain 2.24.

3. **Without `USE_MT`, 4 threads reproduce 2.24 in 635 decks byte for byte.**
   The other 7 (`couette1`, `couette2`, `couette5`, `couseg`, `cousegcomp`,
   `poi2dturb`, `slant`, all CFD) are within Dhondt's tolerance. Plain 2.24
   itself gives a different `.dat` on every 4-thread run of these decks
   (checked for `couette1` and `slant`), so this is upstream behaviour.
   In the last run (`CCX_NPROC_EQUATION_SOLVER=1`), `cousegcomp` went just
   past tolerance (0.16 %). Plain 2.24 alone at 4 threads gave 1.73533,
   1.73570, 1.73618 and 1.73550 for the same value in four runs; this
   edition's 1.73517 is within that spread, and the reference happened to give
   1.73788 in that run.

4. **The OpenMP `opmain.c` gives exactly the same results as upstream's
   pthread version.** It uses the same column split and the same summation
   order, so the 4-thread results are byte-identical (finding 3).

### Notes on the reference build

- **Upstream's CMake does not build on macOS:** it sets
  `ARCH=${CMAKE_SYSTEM_NAME}` (`Darwin`), but `CalculiX.h` only defines the
  `FORTRAN()` macro for `ARCH == Linux`. That's why the reference comparison
  runs on Linux. Worth reporting upstream.
- Upstream's CMake Release builds with CMake's default `-O3`. The reference
  was built with `-O2` (the official `src/Makefile` flags, and this edition's
  flags), so optimisation level is not a variable.

## 2. macOS: release binary against Dhondt's `.dat.ref`

Machine: Apple Silicon (arm64), AppleClang + gfortran 16.2, SPOOLES (vendored),
Apple Accelerate BLAS, `OMP_NUM_THREADS=1`, 8 workers,
`run_official_testsuite.py --force-dat`.

| Run | PASS | DIFF | FAIL | TIMEOUT |
|:---|---:|---:|---:|---:|
| Release binary, all 635 decks | 616 | 17 | 1 | 1 |

All 19 non-passing decks were re-run with the binary built from `main`
before the release changes (`build_spooles`). The results are the same, with
the same reported deviations:

- 17 DIFF (`acou1`, `beamfsh1`, `beammrlin_diff`, `beammrlin_same`,
  `beamprand`, `beamptied5`, `beamptied6`, `beamt6`, `circ10dload`, `circ10p`,
  `induction2`, `segment`, `segmenttemp`, `sens_freq_disp_cyc_explicit`,
  `sens_freq_disp_cyc_implicit`, `sens_modalstress`, `substructure`): the
  macOS results differ from Dhondt's Linux `.dat.ref`/`.frd.ref`. They were
  already there before this release and are not caused by it.
- `mohr1` FAIL (exit 201): already there, as recorded in
  `merge_2026-11/REPORT.md`.
- `anipla_nl_dy_exp` TIMEOUT: load-related. It passes in 4.9 s when run alone
  (and passed in the `main` run).

The macOS release binary prints `This is Version 2.24` and
`MultiSolver edition v2.24-multisolver-0.2`.

## 3. Linux: MUMPS and PARDISO vs plain CalculiX 2.24

Same machine, reference and method as section 1, `OMP_NUM_THREADS=1`. The
release branch is built once per solver: `build_mumps` (MUMPS 5.9.1 sequential,
system package, `CCX_BLAS=NETLIB`) and `build_pardiso` (Intel oneMKL PARDISO,
`CCX_BLAS=MKL`, `MKL_NUM_THREADS=1`). These are different solvers from
SPOOLES, so the expectation is agreement within Dhondt's tolerance, not
identical bytes.

| Solver | Identical | Within tol. | Diff | Exit code differs |
|:---|---:|---:|---:|---:|
| MUMPS | 233 | 388 | 18 | 3 |
| PARDISO | 235 | 392 | 14 | 1 |

CSV files: `linux_mumps_omp1.csv`, `linux_pardiso_omp1.csv`.

Classification of the non-matching decks:

| Kind | MUMPS | PARDISO | Assessment |
|:---|:---|:---|:---|
| Mode shape sign (within tolerance once sign is ignored) | `beam_sens_stress_coord1_implicit`, `circ10dload`, `circ10p`, `induction2`, `poi2dturb`, `segment`, `segmenttemp`, `sens_modalstress` | `circ10dload`, `circ10p`, `induction2`, `segment`, `segmenttemp`, `sens_modalstress`, `shell5a`, `shell5b` | Same result: eigenvectors are only defined up to sign |
| Exported stiffness matrix (`.mtx` compared as `.dat`) | `beammrlin_diff`, `beammrlin_same` | same | Large entries agree within 0.04 %. `datcheck.pl` splits on whitespace, so a leading minus sign versus a leading space shifts the columns and makes it compare unrelated numbers |
| Very small values (1e-7 to 1e-10) | `beamfsh1`, `beamt6` | `beamfsh1`, `beamt6`, `cube2` | Numerical noise near zero |
| Mass moment of inertia (deformed configuration) | | `rotor` (0.15 %) | Just over the 0.1 % tolerance |
| CFD | `cou2d`, `coucylcent2`, `slant` (6 vs 3 increments) | | CFD convergence path depends on the linear solver |
| Random field | `beamprand` (215 vs 233 lines in `.dat`) | | Different number of output lines; not analysed further |
| Mortar contact, displacements of order 1e-6 | `hueeber1_mortar` (same maximum, local differences), `hueeber2_mortar` (maximum 2.8e-6 vs 1.4e-6) | | **Needs a closer look.** Our output also prints `1.419413-158`: Fortran E-format drops the `E` for exponents below −99, so `datcheck.pl` reads it as 1.42 |
| Exit code: plain 2.24 fails, ours completes | `oneel20fi3` | `oneel20fi3` | Plain 2.24 with SPOOLES stops with "increment size smaller than minimum"; MUMPS and PARDISO finish |
| Exit code: ours fails | `couseg`, `couseg2` | | MUMPS: `*ERROR in con2phys: too many iterations` (CFD). Accelerate failed on the same decks in earlier runs. Known limitation of the non-SPOOLES backends on these two decks |

Summary: MUMPS and PARDISO agree with plain 2.24 within the official tolerance
in 621/642 (MUMPS) and 627/642 (PARDISO) decks. Most remaining differences
are mode-shape signs, near-zero values or comparison artifacts.

### Follow-up on the open points (2026-11-23)

**`hueeber1_mortar`/`hueeber2_mortar` (MUMPS): MUMPS scaling.** These decks
use the unsymmetric solver path. `src/mumps.c` sets `ICNTL(8)=0` (no automatic
scaling), introduced in `e518a9f` "to avoid numerical drift on reduced
diagonal contact DOFs". With `CCX_MUMPS_ICNTL8=77` (automatic scaling),
`hueeber2_mortar` reproduces plain 2.24 exactly: 6 Newton iterations instead
of 15, the same residual history, and the same maximum displacement
(1.4358e-6). A full MUMPS run with `CCX_MUMPS_ICNTL8=77`
(`linux_mumps_omp1_icntl8_77.csv`) fixes `hueeber1_mortar` and
`hueeber2_mortar` but makes `rotor2` worse (4.7 % in the frequency step that
follows a geometrically nonlinear static step). It is a trade-off, so the
setting is unchanged for now.

**`couseg`/`couseg2` (MUMPS): missing solver branches, not numerics.**
`src/compfluidfem.c` (FEM CFD) only dispatches to SPOOLES, SGI, TAUCS,
PARDISO and PaStiX. With MUMPS (`isolver=9`) or Accelerate (`isolver=11`), the
factorization and solve of the pressure equation are skipped without any
message, so the CFD iteration diverges ("con2phys: too many iterations"). No
MUMPS setting changes this. The same gap exists in other upstream files that
this edition's solver integration did not reach:

| File | Used for | MUMPS | Accelerate |
|:---|:---|:---:|:---:|
| `compfluidfem.c` | FEM CFD pressure equation | missing | missing |
| `randomfieldmain.c` | `*RANDOM FIELD` (explains `beamprand`) | missing | missing |
| `filterforwardmain.c`, `filterbackwardmain.c` | sensitivity filters | missing | missing |
| `gradientprojection.c` | optimisation (feasible direction) | missing | missing |
| `massless.c` | massless explicit contact | present | missing |

In all of these a missing branch means the solve is skipped silently. These
gaps were already there before the 2.24 sync; the 2.24 release changes did not
introduce them.

### Fix: missing solver branches added (2026-11-23)

- `compfluidfem.c`, `randomfieldmain.c`, `filterforwardmain.c`,
  `filterbackwardmain.c`, `gradientprojection.c`: MUMPS (`isolver=9`) and
  Accelerate (`isolver=11`) branches added next to every PARDISO branch
  (factor, solve, cleanup; 22 places). They use the same main solver instance
  as the PARDISO branches upstream, and the same "library is not linked" error
  when the solver is not compiled in.
- `massless.c`: Accelerate has no second (copy) instance, so it cannot factor
  the contact matrix `Kbb` without destroying the main factorization. With
  Accelerate, massless contact now stops with a clear error ("use
  SOLVER=SPOOLES, PARDISO or MUMPS") instead of skipping the solve. These decks
  (`contact15`, `contact15lin`, `contact16`, `contact17`, `contact19`,
  `changecontacttype2`) already failed with Accelerate before.

**Linux, MUMPS vs plain 2.24 after the fix** (`linux_mumps_omp1_branches.csv`):

| Run | Identical | Within tol. | Diff | Exit code differs | OK |
|:---|---:|---:|---:|---:|---:|
| MUMPS before | 233 | 388 | 18 | 3 | 621 |
| MUMPS after | 238 | 391 | 12 | 1 | **629** |

Fixed, none made worse: `couseg`, `couseg2` and `coucylcent2` are now
byte-identical to 2.24; `cou2d`, `poi2dturb`, `slant`, `beamprand` and
`beam_sens_stress_coord1_implicit` are within tolerance. The 13 remaining decks
are the cases already classified above: mode-shape signs (`circ10dload`,
`circ10p`, `induction2`, `segment`, `segmenttemp`, `sens_modalstress`), the
`beammrlin_*` comparison artifact, near-zero values (`beamfsh1`, `beamt6`),
MUMPS scaling (`hueeber1_mortar`, `hueeber2_mortar`) and `oneel20fi3`, where
plain 2.24 fails. PARDISO is not affected by the fix.

**macOS, the 50 decks that use these routines** (CFD, random field, sensitivity
filters, optimisation, massless contact), against Dhondt's `.dat.ref`:

| Solver | PASS | DIFF | FAIL |
|:---|---:|---:|---:|
| MUMPS | 46 | 4 | 0 |
| Accelerate | 40 | 4 | 6 |

The 4 DIFF (`beamprand`, `sens_freq_disp_cyc_explicit`,
`sens_freq_disp_cyc_implicit`, `sens_modalstress`) are the same decks in which
macOS SPOOLES differs from the Linux reference files (section 2). The 6
Accelerate FAIL are the massless-contact decks with the new error message.
`couseg` and `couseg2` now pass with both MUMPS and Accelerate.

## 4. Not covered yet

- Full macOS suite with Accelerate and MUMPS (only the 50 affected decks were run).
- PaStiX (Linux only, later step).
- Windows (CI fix is the last step).
