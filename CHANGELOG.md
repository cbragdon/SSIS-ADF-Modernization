# Changelog

All notable changes to this repository. Dates are local (America/New_York).

## [Unreleased] — 2026-10-20

### Added
- `scripts/assessment/01_Invoke-SsisModernizationAssessment.ps1` v2.0.0 — read-only SSIS assessment
  (SSISDB, msdb, file system/.ispac), rule-table routing aligned to the ETL decision document,
  SQL Server 2016–2025 target handling, child roll-up, evidence/connection/run-history output.
  Replaces `01_run_dma_assessment.ps1`, which queried non-existent catalog columns.
- `scripts/test-packages/01_New-SsisTestProject.ps1` — builds the 15-package AssessmentTests project
  with the SSIS object model.
- `scripts/test-packages/02_Deploy-SsisTestProject.ps1` — idempotent Dev-only SSISDB deployment with
  environments, references, parameter binding, `-WhatIf` and `-Remove`.
- `scripts/test-packages/03_Test-AssessmentRouting.ps1` — routing regression test (fixtures/server).
- `sql/01_Create-SsisAssessmentTestDb.sql` — deterministic seed database.
- `tests/fixtures`, `tests/expected` — offline fixtures and expected routes.
- Documentation: decision summary, test package catalog, runbook, plan review.
- CI workflow: parse-check and offline routing test on every push.

### Fixed (first live run, SQL Server 2025 / SSIS 17.0)
- `01_New-SsisTestProject.ps1`: builder compile error (`DtsContainer` has no `Properties`; use
  `IDTSPropertiesProvider`); managed task, connection and Script Component assemblies are preloaded and
  `STOCK:` monikers preferred (0x80131401 "Cannot create a task from XML", unknown SMTP connection type);
  object names are sanitised (`.` and other reserved characters); T01/T02 link to the data flow's own
  `TaskHost` (a constraint to `Executables[index]` made the save fail with 0x80010105 and
  `project.Save` hang).
- `02_Deploy-SsisTestProject.ps1`: the `.ispac` bytes were unrolled to `object[]` by a subexpression,
  so `catalog.deploy_project` failed.

### Verified
- Live on SQL Server 2025 Developer: 14/15 packages built (T15 skipped: CDC/Oracle removed in 2025),
  deployed with Dev/Test environments, server routing test 29 passed / 0 failed / 1 skipped,
  T02 executed in SSISDB and copied 1,000 rows with a checksum matching the source.
- Assessment + routing test against fixtures: 22/22 pass; deliberate mismatch fails with exit code 1.
- All PowerShell files parse; embedded C# builder compiles as C# 5 against API stubs.

### Not yet verified
- Builder against real SSIS assemblies; deploy script against SSISDB; assessment SQL against a live server.
