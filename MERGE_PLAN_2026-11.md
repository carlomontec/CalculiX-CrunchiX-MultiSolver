# Upstream Merge Plan - November 2026

Merge of Dr. Guido Dhondt's upstream (`Dhondtguido/CalculiX`, branch `master`) into this fork.
Written as an executable runbook for an implementation agent (Sonnet) or a human.

## 1. Facts (measured, not estimated)

- Branch: `merge/upstream-2026-11` (created from `main` at `7a98183`).
- Remote: `upstream` = `https://github.com/Dhondtguido/CalculiX.git` (already added and fetched locally).
- Merge base: `0787781` (2026-09-28, "corrected an error in rubber.f and hyperfoams.f").
- Upstream ahead: 39 commits (up to `57a4e71`, 2026-11-14). Ours ahead: 89 commits.
- Files touched by both sides: 14. Dry run (`git merge-tree`) gives only 3 textual conflicts:
  - `CMakeLists.txt` (add/add)
  - `INSTALL.md` (add/add)
  - `src/Makefile` (content)
- Auto-merged but touched by both sides (review after merge, must compile):
  `src/CalculiX.c`, `src/CalculiXstep.c`, `src/Makefile.inc`, `src/arpackcs.c`,
  `src/calcstabletimeincvol.f`, `src/electromagnetics.c` (largest: ours +52, theirs +49/-62),
  `src/nonlingeo.c`, `src/radflowload.c`, `src/statics.f`, `src/viscos.f`.

## 2. Hidden (semantic) risk - the important one

Upstream removed `src/date.pl` and added `src/buildinfo.c`, which defines
`const char ccx_compiletime[]` (declared in `CalculiX.h`, used in `CalculiX.c`,
`CalculiXstep.c`, `frd.c`).

`buildinfo.c` is **not** listed in `src/Makefile.inc`. Our `CMakeLists.txt` builds its source
list by parsing `Makefile.inc` (around line 726-758), so after the merge the link fails with
`undefined symbol: ccx_compiletime` unless we add it explicitly. This will not show as a git
conflict.

Other new sources (`densify.c`, `getcond.c`) are in `Makefile.inc` and are picked up automatically.

## 3. Decisions (agreed with Carlo)

| Topic | Decision |
|---|---|
| `CMakeLists.txt` | Keep ours. Port only what upstream needs (`buildinfo.c`). Keep upstream's `cmake/` folder and `CMakePresets.json` in the tree, unused. |
| `INSTALL.md` | Keep ours. Archive theirs as `doc/INSTALL_upstream.md`. Mention this in `README.md` and in our `INSTALL.md`. |
| `src/Makefile` | Keep our macOS flags. Adopt upstream's `buildinfo.o` rule and drop the `./date.pl` call. |
| History | Real merge commit on the branch, then PR to `main`. No squash. |
| `test/` | Upstream-owned: take upstream's version of everything under `test/` (including deletions). |

## 4. Runbook

### Step 0 - Baseline (before merging)
Build current `main` code and record test-suite results so regressions can be told apart
from upstream numerical changes.
```bash
cmake -S . -B build_premerge && cmake --build build_premerge -j
```
Run `test_NewLib/run_official_testsuite.py` against that binary (parallel by process,
`OMP_NUM_THREADS=1 CCX_NPROC_EQUATION_SOLVER=1`). Save the pass/fail list to
`test_NewLib/merge_2026-11/baseline.txt`.

### Step 1 - Start the merge
```bash
git merge --no-ff --no-commit upstream/master
```
Expect 3 conflicts. Do not commit.

### Step 2 - Resolve `CMakeLists.txt`
```bash
git checkout --ours CMakeLists.txt
```
Then edit it: after the `Makefile.inc` parsing block (where `CCX_SOURCES` is built), add:
```cmake
# buildinfo.c (upstream, Nov 2026) holds ccx_compiletime. It is not in Makefile.inc.
list(APPEND CCX_SOURCES "src/buildinfo.c")
set_source_files_properties(src/buildinfo.c PROPERTIES
    OBJECT_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/CalculiX.c")
```
Check that nothing in our CMake, `install.sh`, `install.ps1` or `.github/workflows/ci.yml`
calls `date.pl` (`grep -rn date.pl CMakeLists.txt install.* .github`). Remove any such call.

### Step 3 - Resolve `INSTALL.md`
```bash
git show upstream/master:INSTALL.md > doc/INSTALL_upstream.md
git checkout --ours INSTALL.md
```
Add a short note near the top of our `INSTALL.md` and in `README.md`: upstream now ships its
own CMake build (`cmake/`, `CMakePresets.json`, archived instructions in
`doc/INSTALL_upstream.md`); this fork's supported build is our `CMakeLists.txt` / `install.sh`.
No emoji (project rule).

### Step 4 - Resolve `src/Makefile`
Keep our version (flags, `spooles`, Accelerate, pkg-config ARPACK) and apply upstream's
buildinfo change:
- Link rule: remove `./date.pl; $(CC) $(CFLAGS) -c CalculiX.c;` keep the `$(FC) ...` link.
- `CalculiX.a: $(OCCXF) $(OCCXC) buildinfo.o`
- Add rule `buildinfo.o: $(OCCXMAIN) $(OCCXF) $(OCCXC)` with upstream's comment.

### Step 5 - Review auto-merged overlaps
For each file in section 1 "auto-merged" list, run `git diff main -- <file>` and confirm both
our additions (JSON export hooks, solver dispatch) and upstream's fixes are present.
Spend the most care on `src/electromagnetics.c`. Confirm the hardcoded
"executable made on ..." string in `CalculiX.c` is now `ccx_compiletime`.

### Step 6 - Build
```bash
cmake -S . -B build_merge && cmake --build build_merge -j 2>&1 | tail -30
```
Also build at least one other solver configuration we ship (e.g. MUMPS or Spooles-only) to
confirm the source list change applies to all variants. Also try `make -C src` if still used.

### Step 7 - Test
Run the same suite as Step 0 with the merged binary; save to
`test_NewLib/merge_2026-11/merged.txt`; diff against baseline.
- New failures must be explained by an upstream commit (expected candidates: hyperelastic
  `D_i` defaults `66017d9`/`7c38578`, `umat_abaqusnl*` `ae1e65c`/`2b5c674`/`7109537`,
  C3D8I/C3D8R `e_c3d.f`/`resultstherm.f`, `radflowload.c` `dtheta` `fd58870`,
  `*TEMPERATURE OP=NEW` `537aa81`). Check the upstream `.dat.ref` in `test/` for that deck.
- If upstream's own `.dat.ref` changed, regenerate the matching `originaltest_json/*.json.ref`
  and note it in the log. Anything not explained by upstream = our regression, stop and report.
- New upstream decks without `.json.ref` fall back to Perl checks automatically.

### Step 8 - Document and hand back
- Add an entry to `CHANGES_VS_CCX.md` (merged upstream through `57a4e71`, buildinfo handling).
- Write `test_NewLib/merge_2026-11/REPORT.md`: conflicts resolved, test diff, regenerated refs.
- **Stop. Do not commit.** Ask Carlo to verify locally. Only on "commit and push":
  commit the merge, push the branch, open a PR to `main`.

## 5. Effort estimate

Small merge: 3 textual conflicts, one semantic fix, ~14 overlapping files.
Implementation with Sonnet: roughly 40-80k tokens including builds and test triage; the test
suite itself costs wall time, not tokens, as long as only summaries are read. This fits
comfortably in one standard 5-hour Pro session. The main variable is how many test decks
change because of upstream numerics (Step 7).
