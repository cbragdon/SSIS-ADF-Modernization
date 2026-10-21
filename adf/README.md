# ADF rewrites of the parity scenarios (G22–G30)

The ADF side of the data-parity harness ([docs/04_parity-harness.md](../docs/04_parity-harness.md)). Each
pipeline rebuilds one `ParityTests` SSIS package and writes to `out_adf` (or `<LandingPath>\parity\G29\adf`),
so `scripts/parity/01_Invoke-ParityTest.ps1` can compare it with the SSIS output.

The folders follow the layout of an ADF git repository (`linkedService/`, `dataset/`, `pipeline/`), so they
can be copied into a factory's collaboration branch or imported one by one in ADF Studio.

**Status:** authored, not yet run in a factory. The SQL inside the pipelines was rehearsed against the local
test database (see the doc); the Copy activity file handling (G23, G24, G29) and the G30 failure path still
need an `-ExecuteAdf` run.

## Before deploying

| Placeholder | Where | Replace with |
| --- | --- | --- |
| `<DevSqlServer>` | `ls_SsisAssessmentTest` | The Dev SQL Server hosting `SsisAssessmentTest` |
| `<Domain>\<ServiceAccount>` | `ls_SsisAssessmentTest`, `ls_ParityLanding` | The Windows account the self-hosted IR uses |
| `<LandingPath>` | `ls_ParityLanding` | The same UNC path as the `ParityTests` `LandingPath` parameter |
| `<KeyVaultName>` | `ls_KeyVault` | A Key Vault with secrets `parity-sql-password` and `parity-landing-password` |

The factory also needs a self-hosted integration runtime named `ir_SelfHosted` (or rename the reference in
the two linked services) that can reach the SQL Server and the landing share. Run `sql/03_Seed-ParityScenarios.sql`
first: it creates the `pty.G23_AdfStage` and `pty.G24_AdfStage` tables these pipelines load.

## Pipelines

| Pipeline | SSIS package | How it keeps SSIS semantics |
| --- | --- | --- |
| `pl_parity_G22_Lookup` | P22_LookupSemantics | Copy with a byte-exact join (`varbinary`), first duplicate by `RefId`, NULL matches NULL |
| `pl_parity_G23_BlankNull` | P23_BlankNull | Copy the CSV as text with `nullValue` set to a marker, then convert: empty string stays `''`, empty integer `0`, empty date NULL |
| `pl_parity_G24_Types` | P24_TypesCodePages | Copy both files as text (1252 + CRLF, UTF-8 + LF), then truncate to 10 characters and truncate decimals to 2 places |
| `pl_parity_G25_Dedupe` | P25_Dedupe | Explicit survivor: earliest `UpdatedAt`, then highest `RowId` (what the SSIS Sort kept) |
| `pl_parity_G26_LoadOptions` | P26_LoadOptions | Script activity `INSERT ... SELECT`: triggers fire and defaults apply, which a Copy bulk insert never does; the CHECK constraint becomes a filter |
| `pl_parity_G27_ProcSource` | P27_ProcSource | Same `EXEC ... WITH RESULT SETS` source query |
| `pl_parity_G28_SystemVars` | P28_SystemVars | `formatDateTime` on `RunDate` for the folder and stamp values; factory, trigger and run id for the volatile ones |
| `pl_parity_G29_OutputFiles` | P29_OutputFiles | ForEach over regions and 10-row parts with SSIS-style file names; 1252, CRLF, header, no quoting |
| `pl_parity_G30_EmptyResultSet` | P30_EmptyResultSet | Lookup, then a Fail activity when there is no `firstRow` |

## Run

```powershell
.\scripts\parity\01_Invoke-ParityTest.ps1 -ServerInstance <DevSqlServer> -ExecuteSsis -ExecuteAdf `
    -LandingPath '\\<FileServer>\ssis_landing' `
    -SubscriptionId <SubscriptionId> -ResourceGroupName <ResourceGroup> -DataFactoryName <DataFactory>
```
