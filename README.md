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
│  └─ plan-review/
│     ├─ README.md                   review of the AI-assisted migration plan
│     ├─ SSIS_ADF_Plan_Review.xlsx   issues, recommended pipeline, next steps (tracking workbook)
│     └─ source/                     the plan and blueprint that were reviewed
├─ scripts/
│  ├─ assessment/
│  │  └─ 01_Invoke-SsisModernizationAssessment.ps1   read-only package assessment and routing
│  └─ test-packages/
│     ├─ 01_New-SsisTestProject.ps1   builds the AssessmentTests SSIS project (.ispac)
│     ├─ 02_Deploy-SsisTestProject.ps1 idempotent deploy to SSISDB (Dev only), -Remove to clean up
│     └─ 03_Test-AssessmentRouting.ps1 regression test: actual vs expected routes
│  └─ parity/
│     ├─ 01_Invoke-ParityTest.ps1     runs SSIS and ADF for each case, compares outputs, logs results
│     └─ 02_Test-ParityHarness.ps1    known-answer self-test of the harness (CI)
├─ sql/
│  ├─ 01_Create-SsisAssessmentTestDb.sql   disposable seed database for runnable test packages
│  ├─ 02_Create-ParityHarness.sql          parity schema: cases, runs, results, compare procedures
│  └─ 03_Seed-ParityScenarios.sql          inputs and output tables for parity scenarios G22-G30
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
| `01_Invoke-SsisModernizationAssessment.ps1` | Runs. Offline fixtures pass (67/67 checks, including route-reason checks). Routes for the 14 live-built AssessmentTests packages unchanged by v2.2.0. SSISDB/msdb/Agent queries not yet run against a live server. |
| `03_Test-AssessmentRouting.ps1` | Runs. Fixtures mode verified, including a deliberate failing case. |
| `01_New-SsisTestProject.ps1` | v1.1.0. T01–T15 built and deployed on SQL Server 2025 (14 of 15; T15 needs the removed CDC/Oracle components). **T16–T27 are syntax-checked only, not yet compiled or run on SSIS.** Property names are set defensively and logged as warnings if they differ. |
| `02_Deploy-SsisTestProject.ps1` | Guardrail verified. **Not yet run against SSISDB.** Use `-WhatIf` first. |
| Parity harness (`sql/02_`, `sql/03_`, `scripts/parity/`) | v1.0.0. Comparison verified by the self-test (18 known-answer cases) on SQL Server 2022; runs in CI. The G22–G30 SSIS packages and ADF pipelines are not built yet, and `-ExecuteSsis` / `-ExecuteAdf` have not been run. See [docs/04_parity-harness.md](docs/04_parity-harness.md). |
| Rule patterns not yet verified | Microsoft Connector for Oracle CreationName (`MSORA`/`ORACLE`), maintenance-task type names, SDS deprecation match. |
| `-ExportRewriteSpec` | Planned — next building block (see plan review). |

## Related

* ETL platform decision request (Claude Docs artifact) — summarised in [docs/01_decision-summary.md](docs/01_decision-summary.md).
* Plan review workbook — [docs/plan-review/SSIS_ADF_Plan_Review.xlsx](docs/plan-review/SSIS_ADF_Plan_Review.xlsx).

## License

MIT. See [LICENSE](LICENSE).
