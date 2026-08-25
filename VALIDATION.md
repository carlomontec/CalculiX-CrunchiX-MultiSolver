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

See [INSTALL.md](INSTALL.md) for platform prerequisites and other build configurations.

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

- `PASS`: the solver completed and the generated checked output agrees with the reference within the checker tolerance.
- `DIFF`: the solver completed, but the generated `.dat` or `.frd` output differs from the reference beyond the checker tolerance.
- `FAIL`: the solver process exited unsuccessfully.
- `UNVERIFIED`: the solver completed, but required output or checker evidence was unavailable or invalid.

A high-quality solver comparison should report all categories. Do not treat `DIFF`, `FAIL`, or `UNVERIFIED` as passes.

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
