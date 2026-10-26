# Runbook: build, deploy, test and remove the AssessmentTests SSIS project

**Scope:** Development SSIS servers only. **Duration:** about 15 minutes end to end.
**Rollback:** step 6 removes everything the procedure created.

## Prerequisites

| Requirement | Needed for | Check |
| --- | --- | --- |
| Windows PowerShell 5.1 | Build (SSIS assemblies are .NET Framework) | `$PSVersionTable.PSEdition` returns `Desktop` |
| SSIS runtime: Integration Services feature, or SSDT with the SSIS extension | Build | `Microsoft.SqlServer.ManagedDTS` in `C:\Windows\Microsoft.NET\assembly\GAC_MSIL` |
| Microsoft OLE DB Driver for SQL Server (MSOLEDBSQL) | Build with `-ResolveMetadata`; package execution | ODBC/OLE DB driver list, or `Get-OdbcDriver` |
| SSISDB catalog on the Dev server | Deploy | `SELECT DB_ID('SSISDB')` is not NULL |
| `ssis_admin` in SSISDB (or sysadmin) | Deploy, assessment | `SELECT IS_MEMBER('ssis_admin')` in SSISDB returns 1 |
| CREATE DATABASE | `-IncludeSeedData` | |
| PowerShell 5.1 or 7 | Deploy and test scripts | |

The simplest build machine is the Dev SSIS server itself, which already has the SSIS runtime.

## 1. Offline sanity check (no server)

```powershell
.\scripts\test-packages\03_Test-AssessmentRouting.ps1
```
Expect `198 passed, 0 failed`. If this fails, stop: the assessment script or the fixtures changed.

## 2. Build the project

```powershell
powershell.exe -File .\scripts\test-packages\01_New-SsisTestProject.ps1 -TestDbServer <DevServer>
```

Check `build\build_manifest_AssessmentTests.csv` (one manifest per project; the routing test reads it to
report packages the builder skipped as SKIP):

* `Built = True` for T01–T13 and T16–T27. T14/T15 may be `False` when Fuzzy Lookup or the CDC/Oracle components
  are not installed — expected; the fixtures cover those rules.
* `Warnings` should be empty. A warning means a property name differed on this SSIS version; the
  package still builds, but note it for the next revision.

To make T02 executable, create the seed database first (step 3 with `-IncludeSeedData`), then
rebuild with `-ResolveMetadata` and redeploy.

## 3. Deploy

Always preview first:

```powershell
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer> -ConfirmDevelopment -TrustServerCertificate -IncludeSeedData -WhatIf
```

Then deploy:

```powershell
$pw = Read-Host 'Password for ssis_test_reader (optional)' -AsSecureString
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer> -ConfirmDevelopment -TrustServerCertificate `
    -IncludeSeedData -SqlLoginPassword $pw
```

What it creates: SSISDB folder `ZZ_AssessmentTests`, project `AssessmentTests`, environments `Dev`
and `Test` with variables, relative environment references, parameter bindings, and (optionally) the
`SsisAssessmentTest` database. Output: `C:\Temp\SSIS_TestDeploy\<RunId>\` with `transcript.log`,
`deployed_packages.csv`, `parameter_bindings.csv`.

Re-running is safe: the project gets a new version; everything else is created only if missing or
updated only if different.

## 4. Verify in SSMS

```sql
SELECT f.name AS folder, p.name AS project, pk.name AS package, pk.validation_status
FROM SSISDB.catalog.packages pk
JOIN SSISDB.catalog.projects p ON p.project_id = pk.project_id
JOIN SSISDB.catalog.folders  f ON f.folder_id  = p.folder_id
WHERE f.name = N'ZZ_AssessmentTests'
ORDER BY pk.name;
```

## 5. Run the routing test against the server

```powershell
.\scripts\test-packages\03_Test-AssessmentRouting.ps1 -Mode Server -ServerInstance <DevServer> -TrustServerCertificate
```

Expect every built package to PASS; skipped packages (not built) report SKIP. Exit code 1 on any failure.

Optional — execute the runnable package and record a baseline for the ADF comparison:

```sql
DECLARE @exec bigint, @ref bigint =
 (SELECT r.reference_id FROM SSISDB.catalog.environment_references r
  JOIN SSISDB.catalog.projects p ON p.project_id = r.project_id
  WHERE p.name = N'AssessmentTests' AND r.environment_name = N'Dev');
EXEC SSISDB.catalog.create_execution @folder_name = N'ZZ_AssessmentTests', @project_name = N'AssessmentTests',
     @package_name = N'T02_CopyWindowsAuth.dtsx', @reference_id = @ref, @use32bitruntime = 0, @execution_id = @exec OUTPUT;
EXEC SSISDB.catalog.set_execution_parameter_value @exec, @object_type = 50, @parameter_name = N'SYNCHRONIZED', @parameter_value = 1;
EXEC SSISDB.catalog.start_execution @exec;
SELECT COUNT(*) AS RowCnt, CHECKSUM_AGG(BINARY_CHECKSUM(CustomerId, CustomerName, Email, Region, ProductId, Amount, CreatedDate)) AS Chk
FROM SsisAssessmentTest.dst.Customer;
```

## 6. Remove

```powershell
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer> -ConfirmDevelopment -Remove -RemoveTestDatabase
```
The folder is deleted only if it is empty afterwards; anything else in it is left alone.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Run this script in Windows PowerShell 5.1` | Build started in `pwsh` | Use `powershell.exe -File ...` |
| `No SSIS runtime assemblies ... found in the GAC` | SSIS not installed on the build machine | Build on the Dev SSIS server, or install SSDT + SSIS extension |
| `Add-Type` compile error naming an SSIS member | API differs on this SSIS version | Note version (`build_manifest.csv` → `SsisAssemblyVersion`) and the message; open an issue |
| `SKIP Component not installed: ...` | Optional component absent | Expected for CDC/Oracle/Fuzzy; fixtures cover them |
| Deploy: `Login is neither ssis_admin nor sysadmin` | Permissions | Ask for `ssis_admin` in SSISDB on the Dev server |
| Deploy: certificate chain not trusted | Self-signed certificate | Add `-TrustServerCertificate` |
| Deploy: project name does not match | `-ProjectName` differs from the built project | Use the same name for build and deploy |
| Server test: packages missing | Wrong folder, or row-level security hides them | Check `-FolderName`; run as `ssis_admin` |
| T02 fails at execution | Built without `-ResolveMetadata`, or MSOLEDBSQL missing on the SSIS server | Rebuild with `-ResolveMetadata` after seeding; install the driver |
