# Upstream CalculiX 2.24 CMake build (reference copy)

This folder keeps the official CMake build of CalculiX ccx 2.24, as written by
Christoph Wölfle for upstream (`Dhondtguido/CalculiX`, tag
`ccx-2.24-upstream` = commit `57a4e71`). The files are unchanged copies:

| File | Upstream location |
|:---|:---|
| `CMakeLists.txt` | `CMakeLists.txt` (repository root) |
| `CMakePresets.json` | `CMakePresets.json` (repository root) |

Upstream's find modules and flags (`cmake/FLAGS.cmake`, `cmake/Find*.cmake`,
`cmake/compat/`) stay in their original place, one level up, also unchanged.

**These files are not used to build this edition.** The supported build is the
top-level `CMakeLists.txt`. They are kept so that:

1. anyone can see what upstream's build does and compare it with ours;
2. the plain 2.24 reference binary used for result comparisons is built
   exactly the upstream way (see below).

## Why this edition uses its own CMake

Upstream's CMake is a good build for upstream CalculiX. It does not fit this
fork for these reasons:

- **The patch hooks work on whole files.** `CCX_SOURCE_EXCLUDES` /
  `CCX_SOURCE_ADDITIONS` can drop or add complete source files. This edition
  changes code inside 44 upstream source files, so each would have to be
  excluded and shipped again as a full patched copy.
- **No install rules.** There is no `install()`, but the one-line installers
  (`install.sh`, `install.ps1`) run `cmake --install`.
- **The executable is named `CalculiX`**, not `ccx`.
- **It requires CMake 3.28.** Ubuntu 22.04 ships 3.22 and Debian 12 ships 3.25.
  Our build requires 3.20.
- **Solvers.** It has SPOOLES, PARDISO and PaStiX, but no MUMPS, no Apple
  Accelerate, no vendored SPOOLES build and no solver report
  (`ccx_solvers.txt`) for the installers.

## Building plain CalculiX 2.24 with upstream's CMake

Upstream's `CMakeLists.txt` expects to sit at the repository root, so build it
from an export of the reference tag rather than from this folder:

```bash
mkdir -p ../ccx-2.24-ref
git archive ccx-2.24-upstream | tar -x -C ../ccx-2.24-ref
cmake -S ../ccx-2.24-ref -B ../ccx-2.24-ref/build -DCMAKE_BUILD_TYPE=Release
cmake --build ../ccx-2.24-ref/build -j
```

The resulting `../ccx-2.24-ref/build/CalculiX` is the reference binary used in
the [release verification report](https://github.com/carlomontec/CalculiX-CrunchiX-Benchmarks/blob/main/releases/v2.24-multisolver-0.2/equivalence/REPORT.md). Upstream's options are `SPOOLES` (default
ON), `PARDISO`, `PASTIX`, `PASTIX4CALCULIX`, `MKL` and `CALCULIX_INT64`.
SPOOLES and ARPACK must be installed so that `find_package` can find them.
