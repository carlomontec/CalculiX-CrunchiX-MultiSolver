# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub instead: open the
[Security tab](https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver/security)
of this repository and click **Report a vulnerability**. Only the maintainer
can see the report, and we can discuss and fix it there before anything is
made public.

Please include what you found, the affected version or commit, and the steps
or input file needed to reproduce it.

## Supported versions

Fixes go into the latest release and `main`.

| Version | Supported |
|---|---|
| `v2.24-multisolver-0.2` (latest) and `main` | yes |
| older releases | no |

## Scope

In scope: the code this fork adds or changes, such as the build system, the
installers (`install.sh`, `install.ps1`), the solver integrations, the JSON
export and the test tooling.

Problems in the upstream CalculiX solver itself, or in third-party libraries
(MUMPS, SPOOLES, PARDISO, Accelerate and others), should go to their own
maintainers. If you are not sure where a problem belongs, report it here and
it will be forwarded.
