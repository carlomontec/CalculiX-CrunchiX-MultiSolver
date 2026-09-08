# CalculiX Golden JSON Reference Generation Report

- **Generation Timestamp:** 2026-08-28 15:05:36
- **Total Decks Evaluated:** 638
- **JSON References Successfully Created:** 619 / 638 (97.0%)
- **Pending Numerical Discrepancies (DIFF):** 0
- **Pending Solver Errors / Legacy Failures (FAIL):** 19
- **Total Wall Time:** 356.94s across 8 workers

## 📋 Summary Overview

| Metric | Count | Percentage |
| :--- | :---: | :---: |
| **Verified Golden References (`.json.ref`)** | **619** | **97.0%** |
| **Decks with Legacy Numerical Diffs (`DIFF`)** | 0 | 0.0% |
| **Decks with Solver Failures / Missing Files** | 19 | 3.0% |

## ⚠️ Discrepancy & Non-Passing Decks Log

The following test decks could not be automatically converted to golden references because their outputs differ from Dr. Guido Dhondt's historical reference baseline files (`.dat.ref` / `.frd.ref`). These require manual inspection or updated upstream baselines:

| Test Deck | Status | Best Solver Attempted | Discrepancy Details | Solver Attempts |
| :--- | :---: | :---: | :--- | :--- |
| `axrad2` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `beamf3submodel` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 16) | **SPOOLES**: FAIL (Solver crashed (exit code 16))<br>**MUMPS**: FAIL (Solver crashed (exit code 16))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 16)) |
| `beamfsubmodel` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 16) | **SPOOLES**: FAIL (Solver crashed (exit code 16))<br>**MUMPS**: FAIL (Solver crashed (exit code 16))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 16)) |
| `beamfsuper` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `beamhtfc2` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 2) | **SPOOLES**: FAIL (Solver crashed (exit code 2))<br>**MUMPS**: FAIL (Solver crashed (exit code 2))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 2)) |
| `beampsuper` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `beampsuper2` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `beamread` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 2) | **SPOOLES**: FAIL (Solver crashed (exit code 2))<br>**MUMPS**: FAIL (Solver crashed (exit code 2))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 2)) |
| `beamread2` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 2) | **SPOOLES**: FAIL (Solver crashed (exit code 2))<br>**MUMPS**: FAIL (Solver crashed (exit code 2))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 2)) |
| `beamread3` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `beamread4` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 2) | **SPOOLES**: FAIL (Solver crashed (exit code 2))<br>**MUMPS**: FAIL (Solver crashed (exit code 2))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 2)) |
| `circ11p` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `crackIIcumhcf` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 16) | **SPOOLES**: FAIL (Solver crashed (exit code 16))<br>**MUMPS**: FAIL (Solver crashed (exit code 16))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 16)) |
| `crackIIcumhcf2` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 16) | **SPOOLES**: FAIL (Solver crashed (exit code 16))<br>**MUMPS**: FAIL (Solver crashed (exit code 16))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 16)) |
| `mohr1` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `opt3` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `segmentsuper` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 201) | **SPOOLES**: FAIL (Solver crashed (exit code 201))<br>**MUMPS**: FAIL (Solver crashed (exit code 201))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 201)) |
| `submodelbeamp` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 16) | **SPOOLES**: FAIL (Solver crashed (exit code 16))<br>**MUMPS**: FAIL (Solver crashed (exit code 16))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 16)) |
| `submodelbeampdouble` | ❌ **FAIL** | `SPOOLES` | Solver crashed (exit code 16) | **SPOOLES**: FAIL (Solver crashed (exit code 16))<br>**MUMPS**: FAIL (Solver crashed (exit code 16))<br>**ACCELERATE**: FAIL (Solver crashed (exit code 16)) |

## 📁 Generated Reference Artifacts

- Reference Directory : [`test_NewLib/originaltest_json/`](originaltest_json/)
- CSV Discrepancy Log : [`test_NewLib/originaltest_json_report.csv`](originaltest_json_report.csv)
