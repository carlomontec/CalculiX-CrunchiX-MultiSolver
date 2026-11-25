# Validation Guide

This guide describes how to validate CalculiX solver integrations against the official CalculiX test suite. It is intentionally separate from performance benchmarking: a solver can be fast without producing acceptable results, and a solver can pass tests without being the fastest.

## What Is Being Validated

The validation runner executes the same input decks with separate solver-specific binaries and compares generated output against the reference files supplied with the official CalculiX test suite.

The tested backends can include:

- SPOOLES 2.2
- MUMPS 5.x
- Apple Accelerate on Apple Silicon macOS
- Intel oneMKL PARDISO on supported platforms

Results depend on the operating system, processor, compiler, linked libraries, and test-suite revision. A validation report should therefore be kept with its generated timestamp and build configuration.

## Build Separate Solver Binaries

Each backend must be configured in its own build directory. Do not reuse a CMake build directory for different solver options.

Example macOS Apple Silicon builds:

```bash
cmake -S . -B build_accelerate \
  -DCCX_USE_ACCELERATE=ON \
  -DCCX_USE_MUMPS=OFF \
  -DCCX_USE_SPOOLES=OFF
cmake --build build_accelerate --parallel

cmake -S . -B build_mumps \
  -DCCX_USE_ACCELERATE=OFF \
  -DCCX_USE_MUMPS=ON \
  -DCCX_MUMPS_VENDORED=ON \
  -DCCX_USE_SPOOLES=OFF
cmake --build build_mumps --parallel

cmake -S . -B build_spooles \
  -DCCX_USE_ACCELERATE=OFF \
  -DCCX_USE_MUMPS=OFF \
  -DCCX_USE_SPOOLES=ON \
  -DCCX_SPOOLES_VENDORED=ON
cmake --build build_spooles --parallel
```

The validation runner expects these binaries:

```text
build_accelerate/CalculiX
build_mumps/CalculiX
build_spooles/CalculiX
```

See [INSTALL.md](../INSTALL.md) for platform prerequisites and other build configurations.

## Run the Official Suite

Run selected backends explicitly:

```bash
python3 test_NewLib/run_official_testsuite.py \
  --solvers ACCELERATE MUMPS SPOOLES
```

Use the runner help for filtering, worker, timeout, output, and custom-binary options:

```bash
python3 test_NewLib/run_official_testsuite.py --help
```

For a focused check, limit the number of decks:

```bash
python3 test_NewLib/run_official_testsuite.py \
  --solvers ACCELERATE MUMPS SPOOLES \
  --pattern achtel2 beam* \
  --limit 20
```

By default, reports are written to a sibling directory named `<repository>_testsuite_results/`. Use `--output-dir` to select another location.

## Result Categories

The runner reports four main result categories:

- `PASS`: the solver completed, the `.dat` and `.frd` output have the same number of lines as the reference files, and Dr. Dhondt's `datcheck.pl` / `frdcheck.pl` find every value within 0.1 % of the largest value in its block.
- `DIFF`: the solver completed, but an output file is missing, has a different number of lines, or a value is outside that tolerance.
- `FAIL`: the solver process exited unsuccessfully.
- `TIMEOUT`: the deck took longer than `--timeout` seconds.
- `UNVERIFIED`: the solver completed, but a checker failed or the deck has no reference file.

Only the reference files in `test/` decide the result. The JSON references in `test_NewLib/originaltest_json/` were generated from this edition's own output; when present they are compared as well, and a mismatch is noted in the detail column, but it never changes the result.

The line-count check matters: both Perl checkers compare line by line and stop at the end of the generated file, so on their own they accept a truncated output.

A high-quality solver comparison should report all categories. Do not treat `DIFF`, `FAIL`, or `UNVERIFIED` as passes.

## Known Failures and CI

Not every deck matches the reference files, even with plain CalculiX 2.24: on Linux, 14 decks of the 635 differ (for example mode shapes with the opposite sign, or a random field). CI therefore gates on a list instead of a pass rate:

```bash
python3 test_NewLib/run_official_testsuite.py --solvers MUMPS \
  --known-failures test_NewLib/ci_known_failures/upstream.txt \
  --known-failures test_NewLib/ci_known_failures/ubuntu-24.04-mumps.txt
```

The run exits with 0 only if every deck that does not pass is listed with the same status. Each entry needs a reason; `--write-known-failures FILE` writes the non-passing decks of a run in the same format. The file format and the list per CI job are described in [test_NewLib/ci_known_failures/README.md](../test_NewLib/ci_known_failures/README.md).

CI runs every test job with one solver thread (`--threads-per-job 1`, which sets `OMP_NUM_THREADS`, `MKL_NUM_THREADS` and `CCX_NPROC_EQUATION_SOLVER` to 1) and several decks in parallel. With more than one solver thread, MUMPS, PARDISO and SPOOLES do not add up floating-point numbers in the same order from run to run, which can change eigenvalue results of cyclic-symmetry and perturbation decks (`rotor2`, `segmentbeam2`) by more than the 0.1 % tolerance. One thread makes the results reproducible; the multithreaded speed-up is measured separately by the benchmarks.

## Auxiliary Test Files

Some official decks depend on generated or separately supplied files, such as:

- `.vwf` view-factor files used by radiation tests
- `.rin` restart files used by restart tests

The runner excludes decks when these required files are absent and prints the exclusions. This prevents missing external test data from being reported as solver failures. Those decks should be validated separately after their required files are supplied.

## Comparing Solvers

For a fair correctness comparison:

1. Build each solver with the same compiler family and compatible general options.
2. Run the same eligible deck set for every solver.
3. Keep the input decks unchanged.
4. Compare pass, diff, fail, and unverified counts separately.
5. Inspect `failure_diagnostics.txt` for process failures.
6. Record the generated `results.csv` and `summary.md` with the validation run.

The official suite is a correctness check, not a claim that every solver produces bit-identical floating-point output. Numerical differences should be investigated in context, especially for nonlinear, contact, dynamic, radiation, and sensitivity cases.

## Performance Benchmarking

Use the focused benchmark script for timing experiments:

```bash
python3 test_NewLib/benchmark_solvers.py \
  --solvers MUMPS ACCELERATE SPOOLES \
  --threads 1 2 4 6
```

The benchmark also reports maximum displacement and maximum von Mises stress for the benchmark deck. Displacement is evaluated over the `NNTIP` node set; stress is evaluated over the `Eall` element set.

Performance results should be recorded separately from official-suite correctness results. See the benchmark script help for its available options:

```bash
python3 test_NewLib/benchmark_solvers.py --help
```
