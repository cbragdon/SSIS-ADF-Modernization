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
| `scripts/test-packages/01_New-SsisTestProject.ps1 -Suite ParityTests` | Builds the SSIS side: `ParityTests` project, P22–P30 |
| `adf/` | ADF side: linked services, datasets and the `pl_parity_*` pipelines |

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
| G22-LOOKUP | G22 | Full-cache Lookup is case- and trailing-space-sensitive, matches NULL to a NULL reference key, and keeps the first duplicate. A SQL join under a CI collation does none of those. |
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
| SQL Server 2025 (Windows, by hand) | 17.0.5015.4 | CU9 | SQL_Latin1_General_CP1_CI_AS | 170 |

The Windows run (Developer edition, Windows authentication, 2026-10-21) also returned 18/18, and on the same
instance the server-mode routing test passed 66/0 with 1 skip (T15) against 26 deployed AssessmentTests packages.

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

## Scenario packages and pipelines

**SSIS: `ParityTests` project, `P22_LookupSemantics` … `P30_EmptyResultSet`.** Built by the same builder as
the assessment packages, with live column metadata from the test database, so every package runs:

```powershell
# Windows PowerShell 5.1 on a machine with SSIS; sql\01-03 applied first.
# Copies tests\parity\data\*.csv to <LandingPath>\parity\in. LandingPath defaults to <repo>\build\landing.
powershell.exe -File .\scripts\test-packages\01_New-SsisTestProject.ps1 -Suite ParityTests -TestDbServer <DevSqlServer> `
    -LandingPath '\\<FileServer>\ssis_landing'
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevSqlServer> -ConfirmDevelopment -ProjectName ParityTests
.\scripts\parity\01_Invoke-ParityTest.ps1 -ServerInstance <DevSqlServer> -ExecuteSsis -LandingPath '\\<FileServer>\ssis_landing'
```

The runner executes without an environment reference unless `-SsisEnvironment` is given, so the
project parameter defaults from the build apply. The SSISDB execution runs as the caller, who needs read
access to `<LandingPath>\parity\in` and write access to `<LandingPath>\parity\G29`.

**ADF: `adf\`.** Linked services, datasets and the nine `pl_parity_*` pipelines, in the layout of an ADF
git repository. Placeholders (`<DevSqlServer>`, `<LandingPath>`, `<KeyVaultName>`, `<Domain>\<ServiceAccount>`)
must be replaced, and the factory needs a self-hosted integration runtime named `ir_SelfHosted` that
reaches the test server and the landing folder. See [adf/README.md](../adf/README.md). The pipelines have not
run in a factory yet; `-ExecuteAdf` is still untested.

### What the SSIS packages actually do (SQL Server 2025 CU9, SSIS 17.0)

First live run on 2026-10-21. All nine packages ended as expected through SSISDB (`-ExecuteSsis`): eight
succeeded, P30 failed at the Execute SQL Task. Several results differ from what the case notes assumed
before the packages existed; the notes in `parity_cases.csv` now record the observed behaviour.

| Gap | Observed SSIS behaviour |
| --- | --- |
| G22 | Full-cache Lookup is byte-exact (case and trailing spaces), keeps the first duplicate, and **matches a NULL input to a NULL reference key**. |
| G23 | `RetainNulls = False`: empty and quoted-empty strings load as `''`, space-only as `' '`, empty integers as `0`. An empty `DT_DBDATE` field **fails the package** at the destination, so P23 reads the date as text and maps blank to NULL. |
| G24 | Over-long text is cut silently when truncation is ignored. `DT_NUMERIC(9,2)` **truncates** (12.345 to 12.34, -0.005 to 0.00). Text outside code page 1252 is best-fit mapped into `varchar` (Ł to L, CJK to `?`). |
| G25 | Sort with remove duplicates kept the **last** row of each key in arrival order in every run. Microsoft documents the survivor as arbitrary. |
| G26 | With commit size 1 and an error output, `CHECK_CONSTRAINTS` rejects only the bad row; `FIRE_TRIGGERS` writes audit rows; KeepNulls off gives the column default. |
| G30 | "Single Row result set is specified, but no rows were returned." The package fails before the next task. |

### ADF rewrite logic, rehearsed in SQL

Until a factory is available, the SQL inside the pipelines (Copy source queries and Script activities)
was run by hand against `out_adf`, with the G23 and G24 stage tables filled with the text the Copy
activity is expected to land. The harness then compared it with the SSIS output: G22–G28, 8 of 8 table cases
PASS. This checks the rewrite rules, not ADF itself: file parsing (G23, G24), file writing (G29) and the
G30 failure path are only proven by an `-ExecuteAdf` run.
