# Upstream Base: CalculiX ccx 2.24

This edition (`v2.24-multisolver-0.2`) is built on the official CalculiX ccx
2.24 release by Guido Dhondt. This page records exactly which upstream code it
is based on and how anyone can check that.

## Provenance

| Item | Value |
|:---|:---|
| Official release | `https://www.dhondt.de/ccx_2.24.src.tar.bz2` |
| SHA-256 of the archive | `99fb4f9b0ec19b100a914c3a097ea1e7f0c22f715b96338acc4a66b63306a2e2` |
| Matching upstream commit | `57a4e71` in [Dhondtguido/CalculiX](https://github.com/Dhondtguido/CalculiX), "improved some error and warning messages", 2026-11-14 |
| Tag in this repository | `ccx-2.24-upstream` (annotated, on `57a4e71`) |

Upstream does not tag releases on GitHub, so the commit was identified by
comparing the tarball with every upstream commit. All 1185 `.c`, `.f` and `.h`
files of the tarball are identical to `57a4e71`. The next closest commit differs
in 3 files.

The release tarball is not a plain export of the repository. Packaging changes
the following, and the comparison ignores only these differences:

- copyright years in every file header: `1998-2015` → `1998-2026`;
- the version string: `Version DEVELOPMENT` → `Version 2.24`;
- file names: `CalculiX.c`, `CalculiX.h`, `CalculiXstep.c` → `ccx_2.24.c`,
  `ccx_2.24.h`, `ccx_2.24step.c`;
- build files (Makefiles, CMake, `INSTALL.md`) are placed inside `src/`, and the
  Makefiles use `-O2` and a different SPOOLES path.

## Re-running the check

```bash
curl -LO https://www.dhondt.de/ccx_2.24.src.tar.bz2
shasum -a 256 ccx_2.24.src.tar.bz2        # Linux: sha256sum

# the reference tag must be identical (exit code 0)
python3 tools/verify_upstream_release.py ccx_2.24.src.tar.bz2 --ref ccx-2.24-upstream --expect-identical

# list what this edition changes in the 2.24 sources
python3 tools/verify_upstream_release.py ccx_2.24.src.tar.bz2 --ref v2.24-multisolver-0.2
```

## What this edition changes in the 2.24 sources

Result of the second command: 1141 source files are identical to 2.24,
44 are modified and 7 are added. No upstream source file is removed.

**Added (new solver backends and JSON export):**
`accelerate_solver.c/.h`, `json_export.c/.h`, `mumps.c`, `mumps.h`, `mumps_cp.c`.

**Modified:**

| Purpose | Files |
|:---|:---|
| Version banner (adds the edition line) and JSON export option | `CalculiX.c`, `CalculiXstep.c` |
| Default solver selection and `SOLVER=` keyword for MUMPS and Accelerate | `ini_cal.c`, `buckles.f`, `cfds.f`, `couptempdisps.f`, `dynamics.f`, `electromagneticss.f`, `frequencys.f`, `greens.f`, `heattransfers.f`, `modaldynamics.f`, `statics.f`, `steadystatedynamicss.f`, `substructuregenerates.f`, `uncouptempdisps.f`, `viscos.f` |
| Solver dispatch to MUMPS and Accelerate (new `#ifdef` branches; existing SPOOLES/PARDISO/PaStiX branches kept) | `arpack.c`, `arpackbu.c`, `arpackcs.c`, `compfluidfem.c`, `dudsmain.c`, `dyna.c`, `dynboun.c`, `electromagnetics.c`, `filterbackwardmain.c`, `filterforwardmain.c`, `gradientprojection.c`, `linstatic.c`, `massless.c`, `nonlingeo.c`, `objectivemain_se.c`, `radflowload.c`, `randomfieldmain.c`, `steadystate.c` |
| PARDISO through oneMKL | `pardiso.c`, `pardiso.h`, `pardiso_cp.c` |
| JSON export hooks | `results.c`, `effectivemodalmass.f` (also in `arpack*.c`) |
| OpenMP symmetric sparse matrix-vector product | `opmain.c` |
| Windows portability (CPU count) | `getSystemCPUs.c` |
| Comment only | `spooles.c` |
| Upstream typo fix: `SOLVER=PASTIX` on `*MODAL DYNAMIC` compared against `'PARDISO'`, so PaStiX could never be selected there | `modaldynamics.f` |
| Explicit dynamics stable time increment | `calcstabletimeincvol.f`, plus the size of `smscale` in `arpack.c`, `arpackcs.c`, `nonlingeo.c` |

The details of every change are in [CHANGES_VS_CCX.md](CHANGES_VS_CCX.md).

## Changes that can affect results

Only one change is meant to change numerical results compared with 2.24:
`src/calcstabletimeincvol.f` (stable time increment for explicit dynamics). See
[CHANGES_VS_CCX.md](CHANGES_VS_CCX.md#changes-that-can-affect-results). All
other changes add solver backends or output, or change performance only. With
SPOOLES on one thread, all 642 decks of the official suite give byte-identical
results to plain 2.24 on Linux ([report](../test_NewLib/release_2.24/REPORT.md)).

One build setting differs from upstream's default: SPOOLES is built
multithreaded (`USE_MT`, as in upstream's `Makefile_MT`). With more than one
thread its results can vary slightly between runs. Set
`CCX_NPROC_EQUATION_SOLVER=1` for results identical to 2.24. SPOOLES is not the
recommended solver in this edition. Details:
[INSTALL.md](../INSTALL.md#spooles-and-multithreading).

## Version strings

The version strings are set exactly as in the 2.24 release (`Version 2.24`),
including the `.frd` header (`frd.c`) and restart files (`getversion.f`,
`restartwrite.f`). Result and restart files are therefore interchangeable with
official 2.24. The program banner and `-v` add one line:
`MultiSolver edition v2.24-multisolver-0.2`.

## Upstream's own CMake build

Upstream 2.24 ships its own CMake build. A verbatim copy, and the reasons this
edition keeps its own build, are in [cmake/upstream/README.md](../cmake/upstream/README.md).
