# Contributing to SSIS-ADF-Modernization

This repository is private, so contributions come from its collaborators. Issues and pull requests are welcome. For anything beyond a small fix, open an issue first so the approach can be agreed before you spend time on it.

## Reporting a problem

Include:

- The script and the exact parameters you ran, and the full console output or error text.
- The SQL Server and SSIS versions involved, and whether the package came from SSISDB, msdb or the file system.
- For a wrong route: the package's expected and actual route, and the reasons the assessment gave.

Remove anything private before posting: server, instance, database, login and object names, and data values. Never attach a generated sprint backlog or assessment workbook: they contain real server names.

## Pull requests

- Branch from `main` and keep one change per pull request.
- Say what changed and why, and list every test you ran with its result. A test that was not run is not reported as passed.
- Update the documentation in the same pull request when behaviour changes.
- Keep each file's existing encoding and line endings.

## Rules every change keeps

The engineering conventions in the [README](README.md) apply to every change:

- Read-only by default. The assessment never changes a server; the deploy script changes SSISDB only on a server you confirm as Development, and supports `-WhatIf` and `-Remove`.
- Idempotent: every script can be re-run and converges to the same state.
- No secrets in output. The routing test fails if a planted secret appears in any output file.
- Tests are the contract. A routing-rule change updates `tests/expected/*.csv` in the same commit, and CI must pass.
- Generated backlogs and workbooks (`sprint_backlog_*.xlsx`, `*_SSIS_Migration_Assessment_*.xlsx`) are never committed.

## Tests

CI runs the routing tests on every push and pull request. Run the offline routing test locally first; it needs no SQL Server:

```powershell
./scripts/test-packages/03_Test-AssessmentRouting.ps1 -Mode Fixtures
```

Building and deploying the test packages needs Windows PowerShell 5.1 on a machine with SSIS or SSDT installed; see `docs/03_runbook-test-packages.md`.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE) that covers this project.
