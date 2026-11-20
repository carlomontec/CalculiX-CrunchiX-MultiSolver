# Upstream Merge Report - November 2026

- Branch: `merge/upstream-2026-11` (from `main` at `7a98183`)
- Upstream: `Dhondtguido/CalculiX` `master`, range `0787781..57a4e71` (39 commits)
- Merge type: `git merge --no-ff upstream/master` (real merge commit, not yet committed)

## Conflicts and resolution

| File | Resolution |
|:---|:---|
| `CMakeLists.txt` | Kept ours. Added `src/buildinfo.c` to `CCX_SOURCES` after the `Makefile.inc` parse, with `OBJECT_DEPENDS` on all sources so the build date is refreshed (mirrors upstream). |
| `INSTALL.md` | Kept ours. Upstream version archived as `doc/INSTALL_upstream.md`. Note added to `README.md` and `INSTALL.md`. |
| `src/Makefile` | Kept our macOS flags. Removed the `./date.pl` call, added `buildinfo.o` to `CalculiX.a` and upstream's `buildinfo.o` dependency rule. |

Upstream's `cmake/` folder and `CMakePresets.json` are present but unused.

The 11 other files modified on both sides merged automatically. Our solver dispatch (MUMPS `isolver==9`, Accelerate `isolver==11`) in `src/electromagnetics.c` was checked against upstream's `ithermal[0]` refactor and is consistent.

## Case-clash on macOS (`test/sensitivity_I.dat.ref` vs `sensitivity_i.dat.ref`)

Upstream previously tracked both files, which collide on case-insensitive filesystems (macOS default); the local checkout had `skip-worktree` set on the lowercase one as a workaround, and that flag blocked the merge. Upstream now deletes `sensitivity_i.dat.ref`, which resolves the clash. The flag was cleared, the lowercase file is deleted as upstream intends, and `sensitivity_I.dat.ref` was restored from the index (the on-disk file was identical to it, so nothing local was lost).

## Builds

All built cleanly on macOS arm64: `build_merge` (Release, SPOOLES), and rebuilt `build_spooles`, `build_mumps`, `build_accelerate`. Binary reports `You are using an executable made on <compile time>` via `ccx_compiletime`. `make -C src` was not tested.

## Test suite (SPOOLES, `OMP_NUM_THREADS=1`, 8 workers)

| Run | Decks | PASS | DIFF | FAIL |
|:---|---:|---:|---:|---:|
| Baseline (pre-merge, `baseline.csv`) | 630 | 629 | 0 | 1 |
| Merged, before fixes | 635 | 629 | 1 | 5 |
| Merged, final (`merged.csv`) | 635 | 634 | 0 | 1 |

- `mohr1`: fails with exit 201 both before and after the merge. Pre-existing, not caused by the merge.
- `beamabqnl`: 0.87% stress difference against our golden JSON. Explained by upstream `umat_abaqusnl*` changes (`ae1e65c`, `2b5c674`, `7109537`). Passes against Dhondt's `.dat.ref`. JSON reference regenerated.
- New upstream decks `press_expl_c3d8i`, `tensor_elastic_full`, `tensor_elastic_rotated`, `tensor_ro_dry`, `tensor_ro_rotated`: JSON references generated (all clean numerical match).
- The four `tensor_*` decks exposed a pre-existing bug in `src/json_export.c`: when `*EL PRINT` came before `*NODE PRINT`, the `element_sets` object was not closed, giving invalid JSON. Fixed by writing nodal sets first and element sets second, regardless of deck order.

## Tooling note

`test_NewLib/generate_json_references.py --pattern` overwrites `originaltest_json_report.csv` / `.md` with only the processed decks. The full reports were restored and only the six affected rows were updated. Worth fixing in the generator separately.
