# Strict Project Guidelines & Protocols

## 🛑 ABSOLUTE RULE: GIT COMMIT & PUSH PROTOCOL
1. **NEVER run `git push` or `git commit` unless Carlo explicitly gives clear, specific authorization for that specific change in the prompt.**
2. **Always follow the 6-step workflow**:
   - Step 1: Deep Analysis.
   - Step 2: Propose clear Plan.
   - Step 3: Wait for user confirmation or iteration.
   - Step 4: Implement code changes.
   - Step 5: Ask user to test / verify locally.
   - Step 6: ONLY if the user explicitly says "commit and push" or "push now", perform the commit and push.
3. **NEVER bundle commits and pushes together with file creation or edits without prior testing and approval.**

---

## 🧪 TEST SUITE & VERIFICATION GUIDELINES
1. **Directory Isolation**:
   - The upstream `test/` directory contains Dr. Guido Dhondt's baseline files and must remain **100% untouched**.
   - All modernized test scripts, comparator tools, golden JSON references (`originaltest_json/`), and benchmark artifacts must reside strictly in `test_NewLib/`.
2. **Verification Priority (JSON-First)**:
   - Verification runners (`run_official_testsuite.py`) verify against `test_NewLib/originaltest_json/<deck>.json.ref` by default using fast in-memory Python/NumPy checks.
   - Decks without a `.json.ref` automatically fall back to legacy `.dat` / `.frd` Perl checks.
   - Use `--force-dat` to explicitly force legacy Perl checking across all decks.
3. **Concurrency Strategy**:
   - When running test suites over numerous small decks, parallelize by process across multiple CPU cores with `OMP_NUM_THREADS=1` and `CCX_NPROC_EQUATION_SOLVER=1`.
4. **Benchmark Mesh Prerequisites**:
   - Solver benchmarks rely on CGX meshing scripts (`*.fbl`). Always verify `.fbl` existence and confirm generated mesh files (`all.msh`, `*.nam`, `*.dlo`) exist before solver execution.

---

## 📝 DOCUMENTATION & CODE STYLE
1. **Emoji-Free Technical Docs**: Keep all markdown documentation, user guides (e.g. `JSON_EXPORT.md`), and discrepancy logs clean, professional, and completely free of emoji icons.
2. **Concise Status & README**: Keep status sections bulleted and concise, maintaining quick installation instructions early in the document.
