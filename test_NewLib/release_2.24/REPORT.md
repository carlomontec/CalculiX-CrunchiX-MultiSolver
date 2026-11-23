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

## 3. Not covered yet

- MUMPS, PARDISO and Accelerate backends (separate tolerance runs).
- PaStiX (Linux only, later step).
- Windows (CI fix is the last step).
