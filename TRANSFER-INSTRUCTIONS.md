# Transfer and SSIS test-package deployment

This archive contains source scripts, fixtures, and documentation. Run the following only on an approved non-production SQL Server VM.

## Prerequisites

- Windows PowerShell 5.1.
- SQL Server Integration Services or SSDT installed so the package-builder can compile SSIS packages.
- A SQL Server instance with SSISDB enabled.
- An account with permission to deploy projects to SSISDB and, when using seed data, create the disposable test database.

Do not commit generated `.dtsx`, `.ispac`, assessment workbooks, result folders, credentials, or real server-target configuration.

## Build, deploy, and validate

Open Windows PowerShell in the extracted top-level folder and replace `<DevSqlServer>` with the approved development instance.

```powershell
# Optional for this PowerShell window when script execution is restricted.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 1. Generate the AssessmentTests SSIS project and packages.
powershell.exe -File .\scripts\test-packages\01_New-SsisTestProject.ps1 `
    -TestDbServer <DevSqlServer>

# 2. Preview the deployment. This does not change SSISDB.
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 `
    -ServerInstance <DevSqlServer> `
    -ConfirmDevelopment `
    -TrustServerCertificate `
    -IncludeSeedData `
    -WhatIf

# 3. Deploy the test project and disposable seed database after reviewing the preview.
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 `
    -ServerInstance <DevSqlServer> `
    -ConfirmDevelopment `
    -TrustServerCertificate `
    -IncludeSeedData

# 4. Run the server-mode assessment routing regression test.
.\scripts\test-packages\03_Test-AssessmentRouting.ps1 `
    -Mode Server `
    -ServerInstance <DevSqlServer> `
    -TrustServerCertificate

# 5. Optional: validate SQL Agent package/job discovery.
.\scripts\test-packages\04_Test-AgentJobs.ps1 `
    -ServerInstance <DevSqlServer> `
    -ConfirmDevelopment `
    -TrustServerCertificate
```

The test script returns exit code `0` only when expected routes, reason evidence, secret masking, generated workbook, CSV, and JSON outputs pass.

## Cleanup

After testing, remove only the deployment created by these scripts:

```powershell
.\scripts\test-packages\02_Deploy-SsisTestProject.ps1 `
    -ServerInstance <DevSqlServer> `
    -ConfirmDevelopment `
    -TrustServerCertificate `
    -Remove `
    -RemoveTestDatabase
```

For detailed prerequisites, troubleshooting, and expected package coverage, see `docs\03_runbook-test-packages.md`.
