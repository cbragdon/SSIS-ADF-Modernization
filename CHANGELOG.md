# Changelog

All notable changes to this repository. Dates are local (America/New_York).

## [Unreleased] — 2026-10-20

### Fixed (2026-10-21) — builder on SQL Server 2025 with T16–T27
- `01_New-SsisTestProject.ps1` preloads every installed SSIS task, enumerator and managed-connection
  assembly instead of a fixed list. The new Execute Process, Bulk Insert and Foreach enumerator packages
  stopped the build with 0x80131401 ("different grant set").

### Verified (2026-10-21) — Windows SQL Server 2025 by hand
- Parity harness self-test 18/18; offline routing test 67/67; 26 of 27 AssessmentTests packages built
  and deployed (T15 skipped); server-mode routing test 66 passed, 0 failed, 1 skipped.
- Known warning: the Cache connection manager in T22 has no `FileName` property on SSIS 17.0.

### Added (2026-10-21) — CI version matrix
- The `parity-harness` CI job is a matrix: SQL Server 2017, 2019, 2022 and 2025 containers, plus 2025
  with the server collation `Latin1_General_100_CS_AS_SC_UTF8`. The `sa` password is generated per job and
  masked. Each job logs `@@VERSION` and uploads its report as `parity-selftest-<version>`.
- The offline routing test (`fixtures` job) runs on `windows-latest` and `ubuntu-latest`.

### Verified (2026-10-21) — version matrix
- Parity self-test 18/18 on 2017 (14.0.3560.2), 2019 (15.0.4500.2), 2022 (16.0.4305.5) and 2025
  (17.0.5015.4, both collations). Routing fixtures 67/67 on PowerShell 7 on Linux.

### Added (2026-10-20) — data-parity harness v1.0.0 (Phase C, gaps G22–G30)
- `sql/02_Create-ParityHarness.sql`: `parity` schema with the case catalogue, runs, results, file
  manifests and run outcomes, and three compare procedures. Tables are compared as binary-exact
  multisets of canonical row hashes (SHA2_256), with a collation-aware `EXCEPT` both ways, a schema diff
  and JSON sample rows. Two empty outputs are an ERROR unless the case allows it.
- `sql/03_Seed-ParityScenarios.sql`: inputs for G22–G30 (lookup case/space/NULL/duplicates, dedupe ties,
  fast-load constraints/defaults/trigger, procedure with a temp table, file split input, empty driver),
  identical `out_ssis` / `out_adf` output tables, and `pty.usp_ResetOutputs`.
- `tests/parity/`: case catalogue `parity_cases.csv` and byte-exact input files for G23/G24.
- `scripts/parity/01_Invoke-ParityTest.ps1`: loads the catalogue, optionally runs the SSIS package
  (SSISDB, synchronized) and the ADF pipeline (REST), compares, writes a CSV report; exit code gates.
- `scripts/parity/02_Test-ParityHarness.ps1` and `tests/parity/selftest/`: 18 known-answer cases.
- CI: a `parity-harness` job runs the self-test against a SQL Server container (see the 2026-10-21 matrix).

### Verified (2026-10-20) — parity harness
- Self-test 18/18 on SQL Server 2022 (Linux container). It catches differences in case only, trailing
  space only, duplicate count, NULL vs blank, a float's 16th digit, Unicode outside code page 1252, a
  missing final newline, a BOM and an extra file. It passes physical row order, type-only changes and
  ignored volatile columns.
- A G22 demonstration (SSIS-style full-cache result vs a plain SQL join under a CI collation) is
  reported as FAIL, 3 rows only in SSIS and 4 only in the candidate, with sample rows.
- Not yet run: `-ExecuteSsis` and `-ExecuteAdf`. The G22–G30 packages and pipelines are still to be built.

### Changed (2026-10-20) — assessment v2.2.0 (G03, G04, G20 from the TechBrothersIT scenario review)
- **Opaque SQL (G04)**: an Execute SQL Task whose statement comes from a variable or a file connection
  (`SqlStmtSourceType` Variable / FileConnection) raises the route to AdfNative-Medium, because the SQL
  that runs is not in the package. A statement set by a property expression is still visible and is not
  flagged. A full result set (`ResultSetType_Rowset`) is reported as an informational Low item (ADF Lookup
  5,000-row / 4 MB limit). New column `OpaqueSqlStatements`.
- **Script dependency inventory (G03)**: Script Task source (`ScriptProject/ProjectItem`) and Script
  Component source (`SourceCode`) are scanned for SqlClient, OLE DB, ODBC, zip libraries, network/HTTP/FTP/
  mail, Office Interop, Active Directory, SFTP libraries, external processes, registry, file I/O, and
  hard-coded connection strings, paths and URLs; `.csproj`/`.vbproj` references outside the framework are
  listed as custom assemblies. Each hit is a `ScriptDependency` evidence item (KeepOnSsisVm, with its own
  Azure-SSIS IR fit). Comment lines and disabled tasks are ignored; literal values are never written out.
  New column `ScriptDependencies`.
- **Fixed-width / ragged-right flat files (G20)** are flagged AdfNative-Medium (no ADF delimited-text
  equivalent).
- The Foreach ADO.NET Schema Rowset Enumerator is matched explicitly by the ADO enumerator rule.

### Added (2026-10-20)
- Fixtures `ProjC/OpaqueSql.dtsx`, `ProjC/ScriptDependencies.dtsx`, `ProjC/FixedWidth.dtsx`.
- `03_Test-AssessmentRouting.ps1` v1.2.0: an `ExpectedReasons` token starting with `!` must be absent.
  `AssessmentTests_expected_routes.csv` gains the optional `ExpectedReasons` column.
- `01_New-SsisTestProject.ps1` v1.1.0: packages T16–T27 for G04 and G10–G21 (opaque SQL, result sets,
  Excel sheet loop, Execute Process, Bulk Insert, Merge Join, Cache Transform, more transforms, Import/
  Export Column, Recordset Destination, flat file formats, dynamic Send Mail), plus `PathTo`,
  `SetTaskEnum`, `AddResultBinding`, `SetEnumerator` and `AddFlatFile` helpers.

### Verified (2026-10-20)
- Fixtures: 67/67 checks pass with v2.2.0; the same fixtures fail 11 checks against v2.1.0.
- The 14 live-built AssessmentTests packages and the DriveSpace C#/VB lab packages keep their routes and
  Azure-SSIS IR fit; DriveSpace now lists its SqlClient and file I/O dependencies.
- T16–T27 builder code passes a C# syntax parse only. It has not been compiled against the SSIS
  assemblies or run; that needs the Windows build machine.

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
