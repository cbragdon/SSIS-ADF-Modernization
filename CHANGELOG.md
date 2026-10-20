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

### Verified
- Assessment + routing test against fixtures: 22/22 pass; deliberate mismatch fails with exit code 1.
- All PowerShell files parse; embedded C# builder compiles as C# 5 against API stubs.

### Not yet verified
- Builder against real SSIS assemblies; deploy script against SSISDB; assessment SQL against a live server.
