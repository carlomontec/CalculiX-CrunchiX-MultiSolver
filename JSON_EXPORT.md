# Direct In-Memory JSON Export Guide

CalculiX CrunchiX Multi-Solver Edition introduces a **direct in-memory JSON export architecture** designed specifically for modern automated scientific computing, optimization loops, machine learning surrogates, and parametric pipelines in **Python**, **Julia**, and **MATLAB**.

---

## Motivation

Traditionally, CalculiX exports simulation results into fixed-width ASCII text files (`.dat`) and binary/ASCII mesh result files (`.frd`). In automated workflows, extracting key quantities (such as modal frequencies, tip displacements, reaction forces, stress states, and solver wall-clock time) from `.dat` files required fragile regular expression text scraping that was prone to break whenever column formatting or locale changed.

The **JSON Export Feature** resolves this by assembling structured JSON objects directly in C memory during the simulation solve loop and writing `<jobname>.json` atomically upon step completion.

### Key Benefits
- **Zero Parsing Overhead**: Load complete datasets directly with standard libraries (`json.load()`, `JSON3.read()`, `jsondecode()`).
- **Type Safe & Standards Compliant**: Follows strict RFC 8259 JSON standards, including safe handling of numerical divergences (`NaN` / `Inf` are safely encoded as `null`).
- **Rich Metadata**: Includes solver backend used, thread count, internal wall-clock solve times, and mesh topology statistics.
- **Multi-Step & Multi-Increment Support**: Captures linear static, non-linear plasticity, contact dynamics, modal analysis, buckling, and thermal steps.

---

## How to Enable JSON Export

You can activate JSON export either via CLI arguments or environment variables without modifying your input decks (`.inp`).

### 1. Command-Line Flag (`-j` or `--json`)

```bash
# Using the modernized ccx alias
ccx -j beam
ccx --json beam

# Or using the direct executable path
./build_mumps/CalculiX -j beam
```

### 2. Environment Variable (`CCX_JSON=1`)

Useful when launching CalculiX via external subprocesses, MPI wrappers, or cluster schedulers:

```bash
export CCX_JSON=1
ccx beam
```

---

## JSON Schema Overview

When JSON export is active, CalculiX outputs `<jobname>.json` in the current working directory:

```json
{
  "meta": {
    "jobname": "beam",
    "ccx_version": "2.21-multisolver",
    "solver": "MUMPS",
    "num_threads": 4,
    "success": true,
    "exit_code": 0,
    "timings": {
      "total_wall_time_s": 0.082425
    },
    "mesh_statistics": {
      "nodes": 261,
      "elements": 32,
      "equations": 720
    }
  },
  "steps": [
    {
      "step_number": 1,
      "type": "STATIC",
      "converged": true,
      "increments": [
        {
          "increment_number": 1,
          "step_time": 1.0000000000e+00,
          "total_time": 1.0000000000e+00,
          "node_sets": {
            "NALL_U": {
              "set": "NALL",
              "field": "U",
              "nodes": [1, 2, 3],
              "components": ["u1", "u2", "u3"],
              "values": [
                [0.0000000000e+00, 0.0000000000e+00, 0.0000000000e+00],
                [1.2405091245e-04, -5.2014820194e-03, 3.1024501294e-05]
              ]
            },
            "NALL_RF": {
              "set": "NALL",
              "field": "RF",
              "nodes": [1, 2],
              "components": ["fx", "fy", "fz"],
              "values": [
                [0.0000000000e+00, 1.2500000000e+03, 0.0000000000e+00]
              ],
              "total": [0.0000000000e+00, 2.5000000000e+03, 0.0000000000e+00]
            }
          },
          "element_sets": {
            "EALL_S": {
              "set": "EALL",
              "field": "S",
              "components": ["sxx", "syy", "szz", "sxy", "syz", "szx"],
              "values": [
                {
                  "element": 1,
                  "s": [1.4502e+02, -2.3012e+01, 0.0000e+00, 5.4120e+00, 0.0000e+00, 0.0000e+00]
                }
              ]
            }
          },
          "energy": {
            "kinetic": 0.0000000000e+00,
            "internal": 1.2450192401e+02,
            "contact_friction": 0.0000000000e+00,
            "total": 1.2450192401e+02
          }
        }
      ]
    }
  ]
}
```

### Modal Analysis (`*FREQUENCY`) & Buckling (`*BUCKLE`)

For eigenvalue frequency extraction or buckling modes, the step contains explicit mode dictionaries:

```json
{
  "step_number": 1,
  "type": "FREQUENCY",
  "converged": true,
  "modes": [
    {
      "mode_number": 1,
      "eigenvalue": 1.4285714285e+06,
      "frequency_rad_s": 1.1952286093e+03,
      "frequency_hz": 1.9022687154e+02
    }
  ],
  "total_effective_mass": {
    "x": 1.520194e+01, "y": 2.450192e+01, "z": 1.849201e+01,
    "rx": 0.0, "ry": 0.0, "rz": 0.0
  },
  "fraction_of_totals": {
    "x": 8.520194e-01, "y": 9.150192e-01, "z": 8.249201e-01,
    "rx": 0.0, "ry": 0.0, "rz": 0.0
  }
}
```

---

## Language Integration Examples

### Python (Standard `json`, NumPy, Pandas)

```python
import json
import subprocess
import numpy as np

# 1. Run CalculiX with JSON export flag
subprocess.run(["ccx", "-j", "beam"], check=True)

# 2. Ingest JSON results
with open("beam.json", "r") as f:
    results = json.load(f)

# 3. Access Metadata & Metrics cleanly
solver = results["meta"]["solver"]
wall_time = results["meta"]["timings"]["total_wall_time_s"]
print(f"Solved with {solver} in {wall_time:.4f} seconds.")

# 4. Extract Nodal Displacements
step1 = results["steps"][0]
last_inc = step1["increments"][-1]
u_data = np.array(last_inc["node_sets"]["NALL_U"]["values"])  # Shape: (num_nodes, 3)

# 5. Extract Total Reaction Force
rf_total = np.array(last_inc["node_sets"]["NALL_RF"]["total"])
print(f"Total Reaction Force (Fx, Fy, Fz): {rf_total}")
```

---

### Julia (`JSON3.jl`)

```julia
using JSON3

# Run CalculiX
run(`ccx -j beam`)

# Load JSON
data = JSON3.read(read("beam.json", String))

println("Solver Used: ", data.meta.solver)
println("Total Equations: ", data.meta.mesh_statistics.equations)

# Extract Eigenvalues / Frequencies (if modal analysis)
if haskey(data.steps[1], :modes)
    for m in data.steps[1].modes
        println("Mode $(m.mode_number): $(m.frequency_hz) Hz")
    end
end
```

---

### MATLAB (`jsondecode`)

```matlab
% Run CalculiX
system('ccx -j beam');

% Decode JSON into MATLAB struct
raw_text = fileread('beam.json');
res = jsondecode(raw_text);

fprintf('Solver: %s | Time: %.3f s\n', res.meta.solver, res.meta.timings.total_wall_time_s);

% Access displacements
u_values = res.steps(1).increments(end).node_sets.NALL_U.values;
disp('First 5 nodal displacements:');
disp(u_values(1:min(5, size(u_values, 1)), :));
```

---

## Implementation Details

The JSON exporter is implemented in `src/json_export.h` and `src/json_export.c`. It hooks cleanly into the CalculiX solve lifecycle:
- `json_init()`: Invoked at solver startup (`src/CalculiX.c`).
- `json_start_step()` / `json_end_step()`: Invoked around each calculation step (`src/CalculiXstep.c`).
- `json_export_results()`: Captures nodal and elemental outputs on each converged increment (`src/results.c`).
- `json_export_eigenvalues()` & `json_export_modal_mass()`: Captures modal extraction results (`src/arpack.c`, `src/effectivemodalmass.f`).
- `json_export_buckling()`: Captures buckling modes (`src/arpackbu.c`).
- `json_finalize()`: Serializes and writes `<jobname>.json` upon calculation finish (`src/CalculiX.c`).
