# SSIS-ADF-Modernization

Tooling and documentation for deciding, package by package, whether an SSIS workload is rewritten in
Azure Data Factory, kept on SSIS hosted on a SQL Server VM, or remediated first — and for proving
that the routing logic is correct before it is trusted.

> **Status:** working draft. The assessment script and its offline regression test run and pass.
> The test-package builder and deploy script are written against documented Microsoft APIs but
> **have not yet been executed against a live SSIS installation or SSISDB**. Run them first on a
> Development server with `-WhatIf`, then for real. See [Status and known gaps](#status-and-known-gaps).

---

## What problem this solves

The ETL platform decision (ADF as orchestrator and platform for new work; existing SSIS packages kept
on a SQL Server VM until retired — *Option D*) needs a reliable answer to one question per package:
**where does this package go?** That answer has to be:

* **Deterministic** — the same package always gets the same route.
* **Traceable** — every route points at the XML element that caused it.
* **Tested** — routing rules are regression-tested against known packages before the output is used
  to plan work.

## Repository layout

```
SSIS-ADF-Modernization/
├─ README.md                         this file
├─ CHANGELOG.md
├─ docs/
│  ├─ 01_decision-summary.md         ETL platform decision, routes, and how they map to options A-D
│  ├─ 02_test-package-catalog.md     what each test package covers and its expected route
│  ├─ 03_runbook-test-packages.md    build -> deploy -> test -> remove, with troubleshooting
│  ├─ 04_parity-harness.md           data-parity harness: SSIS output vs rewrite output, G22-G30
│  ├─ 05_decision-driver-text.md     plain-language explanation shown for every routing finding
│  └─ plan-review/
│     ├─ README.md                   review of the AI-assisted migration plan
│     ├─ SSIS_ADF_Plan_Review.xlsx   issues, recommended pipeline, next steps (tracking workbook)
│     └─ source/                     the plan and blueprint that were reviewed
├─ scripts/
│  ├─ assessment/
│  │  └─ 01_Invoke-SsisModernizationAssessment.ps1   read-only package assessment and routing
│  └─ test-packages/
│     ├─ 01_New-SsisTestProject.ps1   builds the AssessmentTests or (-Suite) ParityTests SSIS project
│     ├─ 02_Deploy-SsisTestProject.ps1 idempotent deploy to SSISDB (Dev only), -Remove to clean up
│     └─ 03_Test-AssessmentRouting.ps1 regression test: actual vs expected routes
│  └─ parity/
│     ├─ 01_Invoke-ParityTest.ps1     runs SSIS and ADF for each case, compares outputs, logs results
│     └─ 02_Test-ParityHarness.ps1    known-answer self-test of the harness (CI)
├─ sql/
│  ├─ 01_Create-SsisAssessmentTestDb.sql   disposable seed database for runnable test packages
│  ├─ 02_Create-ParityHarness.sql          parity schema: cases, runs, results, compare procedures
│  └─ 03_Seed-ParityScenarios.sql          inputs and output tables for parity scenarios G22-G30
├─ adf/                            ADF rewrites of the parity scenarios: linked services, datasets, pipelines
├─ test-packages/AssessmentTests/    generated .dtsx files (committed for review; regenerate, don't hand-edit)
├─ tests/
│  ├─ fixtures/                      hand-written XML for cases a modern SSIS install cannot build
│  ├─ expected/                      expected routes - the single source of truth for the tests
│  └─ parity/                        parity case catalogue, input files, harness self-test
├─ build/                            build output (.ispac, manifest) - git-ignored
└─ .github/workflows/routing-tests.yml   CI: parse-check, offline routing test, parity self-test
```

## Quick start

All commands run on Windows. Use a **Development** server only.

```powershell
# 0. Offline: prove the routing rules against the fixtures (no SQL Server needed)
.\scripts\test-packages\03_Test-AssessmentRouting.ps1

# 1. Build the test project (Windows PowerShell 5.1 on a machine with SSIS or SSDT installed)
powershell.exe -File .\scripts\test-packages\01_New-SsisTestProject.ps1 -TestDbServer <DevServer>

# 2. Preview, then deploy to SSISDB on the Dev server (with seed database)
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer> -ConfirmDevelopment -TrustServerCertificate -IncludeSeedData -WhatIf
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer> -ConfirmDevelopment -TrustServerCertificate -IncludeSeedData

# 3. Assess the deployed packages and compare with the expected routes
.\scripts\test-packages\03_Test-AssessmentRouting.ps1 -Mode Server -ServerInstance <DevServer> -TrustServerCertificate

# 4. Clean up when finished
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer> -ConfirmDevelopment -Remove -RemoveTestDatabase
```

Full procedure, prerequisites and troubleshooting: [docs/03_runbook-test-packages.md](docs/03_runbook-test-packages.md).

## Routes

| Route | Meaning | Decision-doc option |
| --- | --- | --- |
| `AdfNative-Low` | Copy / Script / Stored Procedure activity equivalents only | C — rewrite, low effort |
| `AdfNative-Medium` | Needs Mapping Data Flows, a Self-hosted IR, or orchestration rework | C — rewrite, medium effort |
| `KeepOnSsisVm` | Needs the SSIS runtime (Script Task/Component, third-party, Excel destination, ...) | D — legacy path on the VM |
| `Remediate2025` | Uses a component removed in SQL Server 2025 SSIS (when targeting a 2025 host) | Fix, pin host to 2022, or move to ADF first |
| `ReviewRequired` | Could not be analysed (encrypted body, SSIS 2008-era format) | Manual review |

`EffectiveRoute` rolls child packages up to their parents (Execute Package Task), so a parent is never
easier than the children it runs. `AzureSsisIrFit` reports Option B suitability separately.

## Sprint backlog (planning workbook)

Every assessment run also writes `sprint_backlog.csv` and `sprint_backlog.xlsx` to its run folder. They
list each package with the platform it is planned for and the work that implies, so developers can plan
sprints and business units can see where each of their packages is going. The workbook is written
directly as Office Open XML, so neither Excel nor the ImportExcel module is needed on the assessment host.

| Route | `TargetPlatform` | `WorkType` |
| --- | --- | --- |
| `AdfNative-Low` | ADF | Rewrite as an ADF pipeline: Copy, Script and Stored Procedure activities |
| `AdfNative-Medium` | ADF | Rewrite as an ADF pipeline: Mapping Data Flow, Self-hosted IR or orchestration rework |
| `KeepOnSsisVm` | SSIS VM | Deploy to the SSIS VM unchanged and orchestrate from ADF |
| `Remediate2025` | SSIS VM after remediation | Replace components removed in SQL Server 2025 (or pin the host to 2022, or rewrite in ADF), then deploy |
| `ReviewRequired` | Undetermined | Make the package readable, then re-assess |

Columns:

* **Identity:** `Environment`, `ServerInstance`, `Folder`, `Project`, `Package`, then `PackageLocation`, which
  says where the scan found the package: `SSISDB` (project deployment model), `MSDB` (legacy package deployment
  model), `File system` (a `.dtsx` read with `-Path`) or `File system (.ispac)`.
* **Scope:** `isMigrating` (right of `PackageLocation`) is a proposed default for the team to confirm. It is
  `Yes` for every package except one that is in SSISDB but has not run in the `-HistoryDays` window (90 days by
  default), which gets `Review`. The assessment never sets `No`; the team sets it for a package being retired.
  MSDB and file-system packages have no run history to judge, so they start at `Yes`.
* **Plan:** `TargetPlatform`, `Route` (the `EffectiveRoute`), `WorkType`.
* **Sizing:** `ComplexityScore` and `ComplexityBand`. `ComplexityScore` = enabled tasks + data flow
  components + 3 × (script tasks + script components) + event handlers + error-row redirects + opaque
  SQL statements, + 2 if transactions are required and + 2 if checkpoints are on. The bands are S ≤ 5,
  M ≤ 15, L ≤ 40, and XL above 40. A package that could not be read is `TBD`. The score is something to
  estimate from, not an estimate. Calibrate `$ComplexityBands` after the first few sprints.
* **Order:** `BuildOrder` is 1 for a package that runs no child package in its project. Otherwise it is
  1 + its deepest child. `DependsOn` lists the children it runs, and `CalledBy` lists the parents that run it.
  Building in ascending `BuildOrder` delivers every child before its parent.
* **Why:** `DecisionDrivers` explains, in plain language, each finding that set the package's route, as
  `finding: explanation` separated by ` | `. A harder child package is listed first because it decides the
  platform. All the explanations are in [docs/05_decision-driver-text.md](docs/05_decision-driver-text.md).
  Engineer-level detail is in `evidence_items.csv` (`Note`, plus the same plain text in `Explanation`).
* **Context:** `AzureSsisIrFit`, `Removed2025`, `Usage` (for example, "not run in the last 90 days, confirm
  it is still needed"), `LastExecutionStart`, `AvgDurationMin`, `AgentJobs`.
* **For the team to fill in:** `BusinessOwner`, `Developer`, `Sprint`, `Status`, `Decision`, `Notes`.
* **Provenance:** `SourceServerName` is the name the source SQL Server reports (`@@SERVERNAME`), read at run
  time next to `ServerInstance`, the name the run connected with. `WorkbookCreatedAt` (last column) is when the
  file was written, in local time with the UTC offset. A generated backlog therefore holds real server names:
  keep it out of source control.

Workbook sheets: **Summary** (package counts per environment and platform, by complexity band),
**Backlog** (all rows), one sheet per platform, and **Legend** (routes, bands, and column meanings).
Each sheet has a frozen header and an AutoFilter.

Each run writes a new file, so copy the workbook somewhere shared before the team edits it. A re-run
does not carry the planning columns forward.

## Engineering conventions

* **Read-only by default.** The assessment never changes a server. The deploy script changes SSISDB
  only on a server you explicitly confirm as Development, supports `-WhatIf`, and has `-Remove`.
* **Idempotent.** Every script can be re-run and converges to the same state.
* **Observable.** Every run writes a timestamped folder under `C:\Temp\...` with a transcript and CSVs.
* **No secrets in output.** Connection-string passwords are masked; sensitive SSISDB variables are
  never logged. The routing test fails if a planted secret appears in any output file.
* **Tests are the contract.** Change a routing rule → update `tests/expected/*.csv` in the same
  commit → CI must pass.

## Status and known gaps

| Component | State |
| --- | --- |
| `01_Invoke-SsisModernizationAssessment.ps1` | v2.3.0. Runs. Offline fixtures pass (134/134 checks, including route-reason, sprint-backlog and plain-language-driver checks). Routes are unchanged by v2.3.0. SSISDB/msdb/Agent queries not yet run against a live server. The sprint workbook was validated with openpyxl, not yet opened in desktop Excel. |
| `03_Test-AssessmentRouting.ps1` | Runs. Fixtures mode verified, including a deliberate failing case. |
| `01_New-SsisTestProject.ps1` | v1.1.0. T01–T15 built and deployed on SQL Server 2025 (14 of 15; T15 needs the removed CDC/Oracle components). **T16–T27 are syntax-checked only, not yet compiled or run on SSIS.** Property names are set defensively and logged as warnings if they differ. |
| `02_Deploy-SsisTestProject.ps1` | Guardrail verified. **Not yet run against SSISDB.** Use `-WhatIf` first. |
| Parity harness (`sql/02_`, `sql/03_`, `scripts/parity/`) | v1.0.0. Comparison verified by the self-test (18 known-answer cases) on SQL Server 2017, 2019, 2022 and 2025; CI runs it against all four. The G22–G30 SSIS packages (`ParityTests`) are built and ran through `-ExecuteSsis` on SQL Server 2025; the ADF pipelines in `adf/` are authored but `-ExecuteAdf` has not been run. See [docs/04_parity-harness.md](docs/04_parity-harness.md). |
| Rule patterns not yet verified | Microsoft Connector for Oracle CreationName (`MSORA`/`ORACLE`), maintenance-task type names, SDS deprecation match. |
| `-ExportRewriteSpec` | Planned — next building block (see plan review). |

## Related

* ETL platform decision request (Claude Docs artifact) — summarised in [docs/01_decision-summary.md](docs/01_decision-summary.md).
* Plan review workbook — [docs/plan-review/SSIS_ADF_Plan_Review.xlsx](docs/plan-review/SSIS_ADF_Plan_Review.xlsx).

## License

MIT. See [LICENSE](LICENSE).
