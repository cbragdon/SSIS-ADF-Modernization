# Data-parity harness

A routing test proves that a package is sent to the right place. It does not prove that the ADF
rebuild returns the same data. The parity harness does that: the same seed data goes through the SSIS
package and through its rewrite, and the two outputs are compared in SQL Server, with every comparison
logged so the result can be audited.

It covers the Priority 3 scenarios of the gap analysis (G22–G30): cases where a faithful-looking
rebuild can return different rows.

## Components

| File | Purpose |
| --- | --- |
| `sql/02_Create-ParityHarness.sql` | `parity` schema: case catalogue, runs, results, file manifests, run outcomes, compare procedures |
| `sql/03_Seed-ParityScenarios.sql` | `pty` inputs for G22–G30, empty `out_ssis` / `out_adf` output tables, `pty.usp_ResetOutputs` |
| `tests/parity/parity_cases.csv` | Case catalogue: what to compare for each gap, and which package and pipeline produce it |
| `tests/parity/data/` | Flat-file inputs (exact bytes: code page, BOM, line endings, final newline) |
| `scripts/parity/01_Invoke-ParityTest.ps1` | Runner: optionally runs SSIS (SSISDB) and ADF (REST), compares, writes a CSV report |
| `scripts/parity/02_Test-ParityHarness.ps1` | Self-test on known-answer data; runs in CI against a SQL Server container |
| `tests/parity/selftest/` | Known-answer table pairs and their expected results |

## How the comparison works

**Tables** (`parity.usp_CompareTables`):

1. Every row on each side is serialised column by column into a canonical, length-prefixed string and
   hashed with SHA2_256. NULL is distinct from blank. Floats keep 17 significant digits. Date and time
   types are normalised to `datetime2(7)`, and exact numerics to `decimal(38,10)`, so a type change
   alone (for example `decimal(9,2)` to `decimal(12,4)`) is not a data difference.
2. The two sides are compared as **multisets** of row hashes. Duplicates count, and the comparison is
   binary-exact: case and trailing spaces matter.
3. A collation-aware `EXCEPT` in both directions is reported alongside. `EXCEPT` follows the SSIS column's
   collation (case-insensitive under a CI collation, trailing spaces ignored) and removes duplicates. When
   the hashes differ but `EXCEPT` is clean, the result says the sides differ only in case, trailing spaces
   or duplicate counts. That is the classic Lookup and dedupe trap.
4. Column type and collation differences are listed in `SchemaDiff` (informational).
5. Up to `-SampleRows` differing rows from each side are stored as JSON.

**Files** (`parity.usp_CompareFileManifests`): the runner records each folder's files: the name after
`NameMask` (for example `_\d{8}_\d{6}=_<ts>` removes a time stamp), size, SHA256, line count, header
line, final newline and BOM. Missing files and per-file differences are reported by what changed.

**Outcome** (`parity.usp_CompareOutcome`): both sides must end the same way. G30 expects both to fail.

### Statuses

| Status | Meaning |
| --- | --- |
| `PASS` | Outputs are equivalent |
| `FAIL` | Outputs differ and the case expects a match |
| `KNOWN_DIFF` | Outputs differ and the case is marked `ExpectedOutcome = Differ` (a signed-off divergence) |
| `ERROR` | The case could not be compared: missing object or column, nothing recorded, or **both sides empty** |

Two empty outputs are an `ERROR` unless the case sets `AllowEmpty`. A green result on two empty tables
usually means neither side ran.

The runner exits 0 when no case is `FAIL` or `ERROR`.

## Scenarios

| Case | Gap | What it proves |
| --- | --- | --- |
| G22-LOOKUP | G22 | Full-cache Lookup is case- and trailing-space-sensitive, never matches NULL, and keeps the first duplicate. A SQL join under a CI collation does none of those. |
| G23-BLANKNULL | G23 | Empty, quoted-empty and space-only flat file fields: `RetainNulls` vs ADF `treatEmptyAsNull` |
| G24-TYPES | G24 | Code page 1252 vs UTF-8 with BOM, characters outside 1252 in `varchar`, silent truncation, decimal rounding |
| G25-DEDUPE | G25 | Which duplicate survives when the sort key ties |
| G26-LOADOPT, G26-TRIGGER | G26 | `CHECK_CONSTRAINTS`, `KEEPNULLS` (column default) and `FIRE_TRIGGERS` on fast load |
| G27-PROCSRC | G27 | Stored procedure with a temp table as the source (`WITH RESULT SETS`) |
| G28-SYSVARS | G28 | Date-folder expressions; volatile system variables recorded but not compared |
| G29-FILES | G29 | Output file names, split points, headers and final newline |
| G30-EMPTY | G30 | Single-row result set with no rows: both sides must fail |

Example from a local run: G22 with an SSIS-style full-cache result against a plain SQL join.

```
G22-LOOKUP  FAIL  ssis=7 candidate=8 onlySsis=3 onlyCandidate=4
  only in SSIS:      p-100 NoMatch, 'P-100 ' NoMatch, P-300 NoMatch
  only in candidate: p-100 Bikes, 'P-100 ' Bikes, P-300 Clothing, P-200 Accessories (second duplicate)
```

## Tested SQL Server versions

The self-test (`02_Test-ParityHarness.ps1`, 18 known-answer cases) runs in CI against every SQL Server
version that has a Linux container image. All five configurations returned 18/18 on 2026-10-21:

| Version | Build | Update | Server collation | DB compat |
| --- | --- | --- | --- | --- |
| SQL Server 2017 | 14.0.3560.2 | RTM-CU31-GDR | SQL_Latin1_General_CP1_CI_AS | 140 |
| SQL Server 2019 | 15.0.4500.2 | RTM-CU32-GDR | SQL_Latin1_General_CP1_CI_AS | 150 |
| SQL Server 2022 | 16.0.4305.5 | RTM-CU27-GDR | SQL_Latin1_General_CP1_CI_AS | 160 |
| SQL Server 2025 | 17.0.5015.4 | RTM-CU9-GDR | SQL_Latin1_General_CP1_CI_AS | 170 |
| SQL Server 2025 | 17.0.5015.4 | RTM-CU9-GDR | Latin1_General_100_CS_AS_SC_UTF8 | 170 |

Notes:

* The images are `mcr.microsoft.com/mssql/server:<version>-latest` (Developer edition), so the build moves
  as Microsoft publishes CUs. Each CI job prints `@@VERSION` and the server collation into its log.
* The UTF-8, case-sensitive row proves the compare does not lean on the server default collation.
* Run one container per host at a time. Four concurrent instances on one small host made the 2025 engine
  exit with errno 11 (EAGAIN); in CI each version is its own job on its own runner.
* SQL Server 2016 SP1 is the documented minimum (`CREATE OR ALTER`, `STRING_SPLIT`, `FOR JSON`) but has no
  Linux image, so it is not in the matrix. Windows instances are tested by hand (step 2 of the runbook).
* The routing tests do not use SQL Server. Fixture mode runs on `windows-latest` and `ubuntu-latest`;
  server mode needs SSISDB, which exists only on Windows.

## Runbook

```powershell
# 1. Once per test server (Dev only): seed database, harness, scenarios
sqlcmd -S <DevSqlServer> -E -i sql\01_Create-SsisAssessmentTestDb.sql
sqlcmd -S <DevSqlServer> -E -i sql\02_Create-ParityHarness.sql
sqlcmd -S <DevSqlServer> -E -i sql\03_Seed-ParityScenarios.sql

# 2. Prove the harness itself (disposable instance; also runs in CI)
.\scripts\parity\02_Test-ParityHarness.ps1 -ServerInstance <DevSqlServer> -TrustServerCertificate

# 3a. Compare outputs that both sides have already written
.\scripts\parity\01_Invoke-ParityTest.ps1 -ServerInstance <DevSqlServer> -LandingPath '\\<FileServer>\ssis_landing'

# 3b. Or run both sides, then compare (one gap)
.\scripts\parity\01_Invoke-ParityTest.ps1 -ServerInstance <DevSqlServer> -GapId G22 -ExecuteSsis -ExecuteAdf `
    -SubscriptionId <SubscriptionId> -ResourceGroupName <ResourceGroup> -DataFactoryName <DataFactory>

# 4. Review
SELECT * FROM parity.vw_LatestResult ORDER BY CaseId;
```

Each run is a row in `parity.Run` with the login, host and git commit, and every comparison is a row in
`parity.Result`. Results are never deleted by the scripts.

## What is not built yet

* **The scenario packages and pipelines.** `parity_cases.csv` names them (`ParityTests` project,
  `P22_LookupSemantics.dtsx` … `P30_EmptyResultSet.dtsx`, and `pl_parity_G22_Lookup` …). Until they exist,
  run the comparison on outputs produced by hand, or let the runner report `ERROR` for the missing sides.
  The SSIS packages need a Windows build machine with SSIS, so they follow in a separate change.
* `-ExecuteSsis` and `-ExecuteAdf` are written against the documented SSISDB catalog procedures and the
  ADF REST API (`createRun`, `pipelineruns`), but have not been run yet.
