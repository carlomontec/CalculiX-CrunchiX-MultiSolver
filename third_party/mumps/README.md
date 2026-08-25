# Vendored MUMPS 5.9.1

This directory vendors the official MUMPS 5.9.1 source distribution to enable
a self-contained macOS build linked against Apple Accelerate, without
depending on Homebrew's `brewsci-mumps` tap (which links OpenBLAS instead of
Accelerate, defeating the point of the Accelerate-based solver backend) or
MacPorts (which requires a parallel dev stack).

## Contents

- `MUMPS_5.9.1.tar.gz` -- unmodified upstream source archive
- `MUMPS_5.9.1.tar.gz.sha256` -- official checksum, published at
  https://mumps-solver.org/index.php?page=dwnld
- `Makefile.inc.macos` -- our Accelerate/gfortran build configuration,
  applied on top of the extracted source at build time (not baked into
  the archive itself)

## Source & License

Downloaded from https://mumps-solver.org/index.php?page=dwnld (version 5.9.1,
July 2026 release). Licensed under CeCILL-C (see `LICENSE` inside the
extracted archive), which permits redistribution of unmodified or modified
source. The `PORD` ordering subdirectory inside the archive is public domain
under a separate notice (see `PORD/README` inside the archive).

Per the license's acknowledgment request, publications relying on this
package should cite:

> P. R. Amestoy, I. S. Duff, J. Koster and J.-Y. L'Excellent, A fully
> asynchronous multifrontal solver using distributed dynamic scheduling,
> SIAM Journal on Matrix Analysis and Applications, Vol 23, No 1, pp 15-41
> (2001).
>
> P. R. Amestoy, A. Buttari, J.-Y. L'Excellent and T. Mary, Performance and
> scalability of the block low-rank multifrontal factorization on multicore
> architectures, ACM Transactions on Mathematical Software, Vol 45, Issue 1,
> pp 2:1-2:26 (2019).

## Build configuration notes

- **Sequential (libseq) build, no MPI/ScaLAPACK** -- this fork targets
  single-machine use; MUMPS's bundled `libseq` stub replaces MPI calls.
- **`LAPACK =` is left empty** in `Makefile.inc.macos` -- Apple Accelerate's
  single `-framework Accelerate` link already provides both BLAS and LAPACK
  symbols. Setting `LAPACK = -llapack` alongside it would either fail (no
  system `liblapack.dylib`) or risk linking a second, conflicting LAPACK.
- **`-DAdd_`** matches gfortran's trailing-underscore Fortran symbol mangling
  convention, required for correct linkage against Accelerate.
- **`-fallow-argument-mismatch`** is required because MUMPS's Fortran source
  predates modern strict argument-checking in gfortran 10+.
- **METIS** comes from Homebrew (`brew install metis`), not vendored --
  it's a small, dependency-free C library with no BLAS/LAPACK entanglement,
  so there's no reason to vendor it alongside MUMPS.
- **Gotcha:** the `AR` variable must retain a trailing space
  (`AR = ar vr `) -- without it, macOS's BSD `ar` fails with
  `illegal option -- e` because the archive filename gets concatenated onto
  the flags. This is preserved correctly in `Makefile.inc.macos`; don't
  reformat/trim it.

## Building manually (without CMake)

```bash
tar xzf MUMPS_5.9.1.tar.gz
cp Makefile.inc.macos MUMPS_5.9.1/Makefile.inc
cd MUMPS_5.9.1
make d
```

Produces `lib/libdmumps.a`, `lib/libmumps_common.a`, `PORD/lib/libpord.a`,
and `libseq/libmpiseq.a`.

## Building via CMake

Enabled automatically on macOS via `CCX_MUMPS_VENDORED` (default `ON` on
`APPLE`, `OFF` elsewhere -- Linux/Windows continue using system MUMPS
packages as before). See the top-level `CMakeLists.txt` for the
`FetchContent`-based build step.