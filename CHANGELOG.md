# Changelog

All notable changes to this repository. Dates are local (America/New_York).

## [Unreleased] — 2026-10-20

### Changed (2026-10-20) — assessment v2.1.0 (P1 gaps from the TechBrothersIT scenario review)
- **Raw File Source/Destination** now routes AdfNative-Medium instead of AdfNative-Low: ADF has no SSIS
  Raw format, so it is not a Copy activity source/sink.
- **Disabled containers**: tasks and components inside a disabled container or event handler are now
  treated as disabled. Before, an enabled Script Task inside a disabled Sequence forced KeepOnSsisVm.
- **Package properties are now evaluated**: `TransactionOption=Required` (MSDTC), checkpoint restart,
  package configurations (package deployment model, all `DTSConfigurationType` values) and error-row
  redirection (`errorRowDisposition` / `truncationRowDisposition = RedirectRow`) each raise the route to
  at least AdfNative-Medium and are listed in RouteReasons.
- **Expression-driven paths**: a connection string expression that resolves to a local or UNC path
  (string literals and variable/package parameter defaults, following variable expressions) is flagged
  like a literal path.
- **Log providers**: reported in evidence and a new `LogProviders` column. Connections used only by a
  log provider are marked `LoggingOnly` and no longer raise the route.
- **Unresolved child packages** (Execute Package Task with a file-system or msdb reference) now make the
  parent's EffectiveRoute ReviewRequired instead of leaving it unchanged.
- New `package_assessment.csv` columns: `TransactionsRequired`, `CheckpointsEnabled`, `ErrorRowRedirects`,
  `PackageConfigurations`, `LogProviders`.

### Added (2026-10-20)
- Fixtures `tests/fixtures/ProjC/*` and `tests/fixtures/Loose/LegacyConfig.dtsx` (G01, G02, G05–G09 and a
  logging control case), with expected routes.
- `03_Test-AssessmentRouting.ps1` v1.1.0: optional `ExpectedReasons` column checks RouteReasons.

### Verified (2026-10-20)
- Fixtures: 48/48 checks pass with v2.1.0; the same fixtures fail 20 checks against v2.0.0.
- The 14 AssessmentTests packages built live on SQL Server 2025 (from `AssessmentTests.ispac`) and the
  DriveSpace C#/VB lab packages route exactly as before.

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
