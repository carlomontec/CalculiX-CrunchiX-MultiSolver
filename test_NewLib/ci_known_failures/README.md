# Known failures of the CI test-suite jobs

Each CI job runs the official test suite and checks every deck against
Dhondt's reference files (`test/<deck>.dat.ref`, `test/<deck>.frd.ref`) with
his `datcheck.pl` and `frdcheck.pl`: a value passes if it is within 0.1 % of
the largest value of its block. The output must also have the same number of
lines as the reference, because both checkers compare line by line and would
otherwise accept a truncated file.

A job passes only if every deck either passes or is listed here, with the
same status, in the job's file:

| File | Job |
|:---|:---|
| `macos-accelerate.txt` | macOS, Apple Accelerate |
| `ubuntu-24.04-mumps.txt`, `ubuntu-24.04-pardiso.txt`, `ubuntu-24.04-spooles.txt` | Linux x86_64 |
| `ubuntu-24.04-arm-mumps.txt`, `ubuntu-24.04-arm-spooles.txt` | Linux arm64 |
| `windows-mumps.txt` | Windows, MSYS2 (not yet enforced, see issue #1) |

Format, one deck per line, `#` starts a comment:

```
<deck> <STATUS> <reason>
```

`STATUS` is the status the runner reports: `DIFF` (outside tolerance),
`FAIL` (non-zero exit code), `TIMEOUT`, `ERROR` or `UNVERIFIED` (output or
checker problem). The reason says why the deck is expected not to pass, for
example "mode shape sign differs, eigenvalues identical", or "also differs in
plain CalculiX 2.24 with this solver". A deck without an explanation does not
belong here: investigate it instead.

The runner reports listed decks that now pass, so they can be removed. Every
job uploads a `nonpassing-<job>.txt` artifact in the same format, which helps
when updating a list.
