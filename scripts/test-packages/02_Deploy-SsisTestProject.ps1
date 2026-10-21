#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotently deploys the AssessmentTests SSIS project to SSISDB on a DEVELOPMENT server, creates
    Dev and Test catalog environments, binds project parameters to environment variables, and
    optionally creates the seed database. -Remove reverses everything this script created.

.DESCRIPTION
    WHAT IT DOES (in order)
    -----------------------
    1. Pre-flight (read-only): connects, reports SQL Server version, confirms SSISDB exists, confirms
       the login is ssis_admin or sysadmin, and refuses to run unless -ConfirmDevelopment is supplied
       (guardrail against pointing it at Production by mistake).
    2. Seed database (optional, -IncludeSeedData): runs sql\01_Create-SsisAssessmentTestDb.sql.
    3. Folder: creates SSISDB folder <FolderName> if missing (catalog.create_folder).
    4. Project: deploys <ProjectName>.ispac with catalog.deploy_project. SSISDB versions projects, so a
       re-deploy creates a new project version; it is not a duplicate. The project binary is passed
       from this machine as a parameter - no file share or OPENROWSET access is needed on the server.
    5. Environments: creates "Dev" and "Test" environments in the folder if missing, then creates or
       updates each variable (catalog.create_environment_variable / set_environment_variable_value).
       The sensitive SqlLoginPassword variable is created as sensitive (encrypted by SSISDB) and only
       when -SqlLoginPassword is supplied; it is never logged.
    6. References: creates a relative environment reference from the project to each environment if
       missing (catalog.create_environment_reference).
    7. Parameter binding: maps every project parameter that has a matching environment variable to
       that variable (catalog.set_object_parameter_value, value_type 'R'), so a package executed with
       the Dev or Test reference picks up that environment's values.
    8. Verification: lists the deployed packages, environments and parameter bindings and writes them
       to the log folder as CSV.

    IDEMPOTENCY AND REVERSIBILITY
    -----------------------------
    Every step checks current state first and only creates or updates what differs. Running the
    script twice produces the same end state. -Remove deletes, in dependency order: environment
    references, the project, environments, the folder (only if empty afterwards), and with
    -RemoveTestDatabase the seed database.

    SAFETY
    ------
    * Supports -WhatIf: shows every change without making it.
    * Refuses to run without -ConfirmDevelopment.
    * Uses parameterised T-SQL for every catalog call; no string-built SQL with user input.
    * Encryption on by default; -TrustServerCertificate for self-signed certificates.

    PERMISSIONS
    -----------
    ssis_admin in SSISDB (or sysadmin). -IncludeSeedData additionally needs CREATE DATABASE.

.PARAMETER ServerInstance
    Development SQL Server instance hosting SSISDB.

.PARAMETER ConfirmDevelopment
    Required acknowledgement that ServerInstance is a development server.

.PARAMETER IspacPath
    Path to the built .ispac. Default: <repo>\build\<ProjectName>.ispac.

.PARAMETER FolderName
    SSISDB folder. Default ZZ_AssessmentTests (sorts last in SSMS, clearly a test folder).

.PARAMETER ProjectName
    Project name; must match the name inside the .ispac. Default AssessmentTests.

.PARAMETER TestDbServer
    Value written to the TestDbServer environment variable in both environments. Default: ServerInstance.

.PARAMETER TestDbName
    Value of TestDbName in both environments. Default SsisAssessmentTest.

.PARAMETER DevLandingPath / TestLandingPath
    Per-environment LandingPath values (the only variable that differs between Dev and Test by default).

.PARAMETER SqlLoginPassword
    Optional SecureString for the sensitive SqlLoginPassword variable used by SQL-authentication packages.

.PARAMETER IncludeSeedData
    Create/refresh the SsisAssessmentTest seed database on TestDbServer.

.PARAMETER Remove
    Remove everything this script created.

.PARAMETER RemoveTestDatabase
    With -Remove, also drop the SsisAssessmentTest database.

.PARAMETER LogRoot
    Root folder for logs. Default C:\Temp\SSIS_TestDeploy.

.EXAMPLE
    # Preview
    .\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevSqlServer> -ConfirmDevelopment -TrustServerCertificate -WhatIf

.EXAMPLE
    # Deploy with seed data
    .\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevSqlServer> -ConfirmDevelopment -TrustServerCertificate -IncludeSeedData

.EXAMPLE
    # Clean up completely
    .\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevSqlServer> -ConfirmDevelopment -Remove -RemoveTestDatabase

.NOTES
    Version : 1.0.0
    Part of : SSIS-ADF-Modernization repository (scripts\test-packages)
    Compat  : Windows PowerShell 5.1 and PowerShell 7.x (uses .NET SqlClient only).
    Status  : Executed against a SQL Server 2025 SSISDB (deploy, environments, bindings). Run with -WhatIf first.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [switch]$ConfirmDevelopment,
    [string]$IspacPath,
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$FolderName = 'ZZ_AssessmentTests',
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$ProjectName = 'AssessmentTests',
    [string]$TestDbServer,
    [string]$TestDbName = 'SsisAssessmentTest',
    [string]$TestDbProvider = 'MSOLEDBSQL',
    [string]$DevLandingPath = '\\fileserver\ssis_landing\assessment_tests\dev',
    [string]$TestLandingPath = '\\fileserver\ssis_landing\assessment_tests\test',
    [string]$SqlLoginUser = 'ssis_test_reader',
    [Security.SecureString]$SqlLoginPassword,
    [switch]$IncludeSeedData,
    [switch]$Remove,
    [switch]$RemoveTestDatabase,
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [string]$LogRoot = 'C:\Temp\SSIS_TestDeploy',
    [ValidateRange(30, 3600)][int]$CommandTimeoutSeconds = 600
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region ---------------- 0. Setup ----------------
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $IspacPath)    { $IspacPath = Join-Path $RepoRoot ("build\$ProjectName.ispac") }
if (-not $TestDbServer) { $TestDbServer = $ServerInstance }
$RunId     = 'SSISDEPLOY_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $env:COMPUTERNAME
$RunFolder = Join-Path $LogRoot $RunId
New-Item -ItemType Directory -Path $RunFolder -Force | Out-Null
Start-Transcript -Path (Join-Path $RunFolder 'transcript.log') -Force | Out-Null
$Environments = @('Dev', 'Test')

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP', 'PLAN')][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan'; PLAN = 'Magenta' }[$Level]
    Write-Host ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}

function New-SqlConn {
    param([string]$Server = $ServerInstance, [string]$Database = 'master')
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server; $b['Initial Catalog'] = $Database
    $b['Application Name'] = "SSIS-TestDeploy ($RunId)"; $b['Connect Timeout'] = 30
    $b['Encrypt'] = $true; $b['TrustServerCertificate'] = [bool]$TrustServerCertificate
    if ($SqlCredential) {
        $c = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
        $pw = $SqlCredential.Password.Copy(); $pw.MakeReadOnly()
        $c.Credential = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $pw)
        return $c
    }
    $b['Integrated Security'] = $true
    New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
}

function Invoke-Sql {
    <# Parameterised execution. -Scalar returns the first column of the first row; otherwise rows. #>
    param([Parameter(Mandatory)][string]$Query, [string]$Database = 'SSISDB', [hashtable]$Parameters = @{},
          [switch]$Scalar, [switch]$NonQuery, [string]$Server = $ServerInstance)
    $conn = New-SqlConn -Server $Server -Database $Database
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $CommandTimeoutSeconds
        foreach ($k in $Parameters.Keys) {
            $v = $Parameters[$k]
            # No $(if ...) here: a subexpression unrolls byte[] into object[] and the deploy fails.
            if ($null -eq $v) { $v = [DBNull]::Value }
            $p = $cmd.Parameters.AddWithValue($k, $v)
            if ($v -is [byte[]]) { $p.SqlDbType = [System.Data.SqlDbType]::VarBinary; $p.Size = -1 }
        }
        if ($Scalar)   { return $cmd.ExecuteScalar() }
        if ($NonQuery) { [void]$cmd.ExecuteNonQuery(); return }
        $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader())
        foreach ($r in $t.Rows) {
            $o = [ordered]@{}; foreach ($col in $t.Columns) { $o[$col.ColumnName] = $(if ($r[$col] -is [DBNull]) { $null } else { $r[$col] }) }
            [PSCustomObject]$o
        }
    }
    finally { $conn.Dispose() }
}

function ConvertFrom-SecureStringPlain {
    param([Security.SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
#endregion

try {
#region ---------------- 1. Pre-flight (read-only) ----------------
    Write-Log -Level STEP -Message "SSIS test project deployment $RunId"
    if (-not $ConfirmDevelopment) {
        throw 'Refusing to run: add -ConfirmDevelopment to acknowledge that ServerInstance is a DEVELOPMENT server.'
    }
    $info = Invoke-Sql -Database 'master' -Query @"
SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128))        AS Edition,
       CASE WHEN DB_ID('SSISDB') IS NULL THEN 0 ELSE 1 END     AS HasSsisdb,
       ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0)                AS IsSysadmin;
"@
    Write-Log -Message ("Server {0}: SQL Server {1} ({2})" -f $ServerInstance, $info.ProductVersion, $info.Edition)
    if (-not $info.HasSsisdb) { throw 'SSISDB does not exist on this server. Create the Integration Services catalog first.' }
    $isAdmin = Invoke-Sql -Scalar -Query "SELECT ISNULL(IS_MEMBER('ssis_admin'), 0);"
    if (-not $isAdmin -and -not $info.IsSysadmin) { throw 'Login is neither ssis_admin nor sysadmin; catalog changes would fail.' }
    Write-Log -Level OK -Message 'Pre-flight passed (SSISDB present, ssis_admin/sysadmin confirmed).'
#endregion

#region ---------------- 2. Remove path ----------------
    if ($Remove) {
        Write-Log -Level STEP -Message "Removing $FolderName\$ProjectName"
        $folderId = Invoke-Sql -Scalar -Parameters @{ '@f' = $FolderName } -Query 'SELECT folder_id FROM catalog.folders WHERE name = @f;'
        if ($folderId) {
            $refs = @(Invoke-Sql -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName } -Query @"
SELECT r.reference_id FROM catalog.environment_references r
JOIN catalog.projects p ON p.project_id = r.project_id
JOIN catalog.folders  f ON f.folder_id  = p.folder_id
WHERE f.name = @f AND p.name = @p;
"@)
            foreach ($r in $refs) {
                if ($PSCmdlet.ShouldProcess("reference $($r.reference_id)", 'delete environment reference')) {
                    Invoke-Sql -NonQuery -Parameters @{ '@id' = [long]$r.reference_id } -Query 'EXEC catalog.delete_environment_reference @reference_id = @id;'
                    Write-Log -Level OK -Message "Deleted environment reference $($r.reference_id)"
                }
            }
            $projExists = Invoke-Sql -Scalar -Parameters @{ '@id' = [long]$folderId; '@p' = $ProjectName } -Query 'SELECT COUNT(*) FROM catalog.projects WHERE folder_id = @id AND name = @p;'
            if ($projExists -and $PSCmdlet.ShouldProcess("$FolderName\$ProjectName", 'delete project')) {
                Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName } -Query 'EXEC catalog.delete_project @folder_name = @f, @project_name = @p;'
                Write-Log -Level OK -Message "Deleted project $ProjectName"
            }
            foreach ($e in $Environments) {
                $envExists = Invoke-Sql -Scalar -Parameters @{ '@id' = [long]$folderId; '@e' = $e } -Query 'SELECT COUNT(*) FROM catalog.environments WHERE folder_id = @id AND name = @e;'
                if ($envExists -and $PSCmdlet.ShouldProcess("$FolderName\$e", 'delete environment')) {
                    Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@e' = $e } -Query 'EXEC catalog.delete_environment @folder_name = @f, @environment_name = @e;'
                    Write-Log -Level OK -Message "Deleted environment $e"
                }
            }
            # Delete the folder only if nothing else lives in it (never remove other people's objects).
            $remaining = Invoke-Sql -Scalar -Parameters @{ '@id' = [long]$folderId } -Query @"
SELECT (SELECT COUNT(*) FROM catalog.projects WHERE folder_id = @id) + (SELECT COUNT(*) FROM catalog.environments WHERE folder_id = @id);
"@
            if ($remaining -eq 0 -and $PSCmdlet.ShouldProcess($FolderName, 'delete folder')) {
                Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName } -Query 'EXEC catalog.delete_folder @folder_name = @f;'
                Write-Log -Level OK -Message "Deleted folder $FolderName"
            }
            elseif ($remaining -gt 0) { Write-Log -Level WARN -Message "Folder $FolderName kept: it still contains $remaining other object(s)." }
        }
        else { Write-Log -Message "Folder $FolderName does not exist; nothing to remove in SSISDB." }

        if ($RemoveTestDatabase) {
            $dbExists = Invoke-Sql -Server $TestDbServer -Database 'master' -Scalar -Parameters @{ '@d' = $TestDbName } -Query 'SELECT COUNT(*) FROM sys.databases WHERE name = @d;'
            if ($dbExists -and $PSCmdlet.ShouldProcess("$TestDbServer\$TestDbName", 'drop database')) {
                # Database names cannot be parameterised; name is validated against sys.databases above and quoted.
                $q = "ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {0};" -f ('[' + $TestDbName.Replace(']', ']]') + ']')
                Invoke-Sql -Server $TestDbServer -Database 'master' -NonQuery -Query $q
                Write-Log -Level OK -Message "Dropped database $TestDbName"
            }
        }
        Write-Log -Level OK -Message 'Removal complete.'
        return
    }
#endregion

#region ---------------- 3. Seed database (optional) ----------------
    if ($IncludeSeedData) {
        $seedFile = Join-Path $RepoRoot 'sql\01_Create-SsisAssessmentTestDb.sql'
        if (-not (Test-Path -LiteralPath $seedFile)) { throw "Seed script not found: $seedFile" }
        if ($TestDbName -ne 'SsisAssessmentTest') { throw "The seed script creates SsisAssessmentTest; -TestDbName '$TestDbName' would not match. Use the default name with -IncludeSeedData." }
        if ($PSCmdlet.ShouldProcess("$TestDbServer\$TestDbName", 'create/refresh seed database')) {
            # Split on GO batch separators (lines containing only GO).
            $batches = [regex]::Split((Get-Content -LiteralPath $seedFile -Raw), '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() }
            $db = 'master'
            foreach ($batch in $batches) {
                if ($batch -match '(?im)^\s*USE\s+\[?(\w+)\]?\s*;?\s*$') { $db = $Matches[1]; continue }
                Invoke-Sql -Server $TestDbServer -Database $db -NonQuery -Query $batch
            }
            $counts = Invoke-Sql -Server $TestDbServer -Database $TestDbName -Query 'SELECT COUNT(*) AS Customers, (SELECT COUNT(*) FROM src.Product) AS Products FROM src.Customer;'
            Write-Log -Level OK -Message ("Seed database ready: {0} customers, {1} products" -f $counts.Customers, $counts.Products)
        }
    }
#endregion

#region ---------------- 4. Folder ----------------
    if (-not (Test-Path -LiteralPath $IspacPath)) { throw "Project file not found: $IspacPath. Build it first with 01_New-SsisTestProject.ps1." }
    $folderId = Invoke-Sql -Scalar -Parameters @{ '@f' = $FolderName } -Query 'SELECT folder_id FROM catalog.folders WHERE name = @f;'
    if (-not $folderId) {
        if ($PSCmdlet.ShouldProcess($FolderName, 'create SSISDB folder')) {
            Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName } -Query 'DECLARE @id bigint; EXEC catalog.create_folder @folder_name = @f, @folder_id = @id OUTPUT;'
            Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@d' = 'Synthetic SSIS packages for assessment/rewrite tooling tests. Safe to delete.' } `
                -Query 'EXEC catalog.set_folder_description @folder_name = @f, @folder_description = @d;'
            Write-Log -Level OK -Message "Created folder $FolderName"
        }
        else { Write-Log -Level PLAN -Message "Would create folder $FolderName" }
    }
    else { Write-Log -Message "Folder $FolderName exists (id $folderId)" }
#endregion

#region ---------------- 5. Project ----------------
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $IspacPath).Path)
    $hash  = (Get-FileHash -LiteralPath $IspacPath -Algorithm SHA256).Hash
    Write-Log -Message ("Project file {0} ({1:N0} bytes, SHA256 {2})" -f $IspacPath, $bytes.Length, $hash.Substring(0, 16))
    if ($PSCmdlet.ShouldProcess("$FolderName\$ProjectName", 'deploy project (creates a new project version)')) {
        Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName; '@s' = $bytes } -Query @"
DECLARE @op bigint;
EXEC catalog.deploy_project @folder_name = @f, @project_name = @p, @project_stream = @s, @operation_id = @op OUTPUT;
"@
        $ver = Invoke-Sql -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName } -Query @"
SELECT p.object_version_lsn, p.last_deployed_time FROM catalog.projects p JOIN catalog.folders f ON f.folder_id = p.folder_id
WHERE f.name = @f AND p.name = @p;
"@
        Write-Log -Level OK -Message ("Deployed {0} (version LSN {1}, {2})" -f $ProjectName, $ver.object_version_lsn, $ver.last_deployed_time)
    }
    else { Write-Log -Level PLAN -Message "Would deploy $ProjectName to $FolderName" }
#endregion

#region ---------------- 6. Environments and variables ----------------
    $common = [ordered]@{
        TestDbServer   = $TestDbServer
        TestDbName     = $TestDbName
        TestDbProvider = $TestDbProvider
        SqlLoginUser   = $SqlLoginUser
    }
    $perEnv = @{ Dev = @{ LandingPath = $DevLandingPath }; Test = @{ LandingPath = $TestLandingPath } }

    foreach ($e in $Environments) {
        $exists = Invoke-Sql -Scalar -Parameters @{ '@f' = $FolderName; '@e' = $e } -Query @"
SELECT COUNT(*) FROM catalog.environments en JOIN catalog.folders f ON f.folder_id = en.folder_id WHERE f.name = @f AND en.name = @e;
"@
        if (-not $exists) {
            if ($PSCmdlet.ShouldProcess("$FolderName\$e", 'create environment')) {
                Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@e' = $e; '@d' = "AssessmentTests $e values" } `
                    -Query 'EXEC catalog.create_environment @folder_name = @f, @environment_name = @e, @environment_description = @d;'
                Write-Log -Level OK -Message "Created environment $e"
            }
            else { Write-Log -Level PLAN -Message "Would create environment $e"; continue }
        }

        $vars = [ordered]@{}; foreach ($k in $common.Keys) { $vars[$k] = $common[$k] }; foreach ($k in $perEnv[$e].Keys) { $vars[$k] = $perEnv[$e][$k] }
        $current = @{}
        foreach ($row in @(Invoke-Sql -Parameters @{ '@f' = $FolderName; '@e' = $e } -Query @"
SELECT v.name, v.value, v.sensitive FROM catalog.environment_variables v
JOIN catalog.environments en ON en.environment_id = v.environment_id
JOIN catalog.folders f ON f.folder_id = en.folder_id WHERE f.name = @f AND en.name = @e;
"@)) { $current[$row.name] = $row }

        foreach ($name in $vars.Keys) {
            $val = [string]$vars[$name]
            if (-not $current.ContainsKey($name)) {
                if ($PSCmdlet.ShouldProcess("$e.$name", 'create environment variable')) {
                    Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@e' = $e; '@n' = $name; '@v' = $val } -Query @"
EXEC catalog.create_environment_variable @folder_name = @f, @environment_name = @e, @variable_name = @n,
     @data_type = N'String', @sensitive = 0, @value = @v, @description = N'Managed by 02_Deploy-SsisTestProject.ps1';
"@
                    Write-Log -Level OK -Message "  $e.$name = $val (created)"
                }
            }
            elseif ([string]$current[$name].value -ne $val) {
                if ($PSCmdlet.ShouldProcess("$e.$name", "update value to '$val'")) {
                    Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@e' = $e; '@n' = $name; '@v' = $val } `
                        -Query 'EXEC catalog.set_environment_variable_value @folder_name = @f, @environment_name = @e, @variable_name = @n, @value = @v;'
                    Write-Log -Level OK -Message "  $e.$name = $val (updated)"
                }
            }
            else { Write-Log -Message "  $e.$name unchanged" }
        }

        # Sensitive password: created/updated only when supplied; value never logged.
        if ($SqlLoginPassword) {
            $plain = ConvertFrom-SecureStringPlain -Secure $SqlLoginPassword
            try {
                if ($current.ContainsKey('SqlLoginPassword')) {
                    if ($PSCmdlet.ShouldProcess("$e.SqlLoginPassword", 'update sensitive value')) {
                        Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@e' = $e; '@n' = 'SqlLoginPassword'; '@v' = $plain } `
                            -Query 'EXEC catalog.set_environment_variable_value @folder_name = @f, @environment_name = @e, @variable_name = @n, @value = @v;'
                    }
                }
                elseif ($PSCmdlet.ShouldProcess("$e.SqlLoginPassword", 'create sensitive variable')) {
                    Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@e' = $e; '@n' = 'SqlLoginPassword'; '@v' = $plain } -Query @"
EXEC catalog.create_environment_variable @folder_name = @f, @environment_name = @e, @variable_name = @n,
     @data_type = N'String', @sensitive = 1, @value = @v, @description = N'Sensitive; encrypted by SSISDB';
"@
                }
                Write-Log -Level OK -Message "  $e.SqlLoginPassword set (sensitive, value not logged)"
            }
            finally { $plain = $null }
        }
    }
#endregion

#region ---------------- 7. Environment references ----------------
    foreach ($e in $Environments) {
        $refId = Invoke-Sql -Scalar -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName; '@e' = $e } -Query @"
SELECT r.reference_id FROM catalog.environment_references r
JOIN catalog.projects p ON p.project_id = r.project_id JOIN catalog.folders f ON f.folder_id = p.folder_id
WHERE f.name = @f AND p.name = @p AND r.environment_name = @e AND r.reference_type = 'R';
"@
        if (-not $refId) {
            if ($PSCmdlet.ShouldProcess("$ProjectName -> $e", 'create relative environment reference')) {
                Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName; '@e' = $e } -Query @"
DECLARE @rid bigint;
EXEC catalog.create_environment_reference @folder_name = @f, @project_name = @p, @environment_name = @e,
     @reference_type = 'R', @reference_id = @rid OUTPUT;
"@
                Write-Log -Level OK -Message "Created reference $ProjectName -> $e"
            }
        }
        else { Write-Log -Message "Reference $ProjectName -> $e exists (id $refId)" }
    }
#endregion

#region ---------------- 8. Bind project parameters to environment variables ----------------
    $bindable = @($common.Keys) + @('LandingPath') + $(if ($SqlLoginPassword) { @('SqlLoginPassword') } else { @() })
    $params = @(Invoke-Sql -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName } -Query @"
SELECT op.parameter_name, op.value_type, CAST(op.referenced_variable_name AS nvarchar(128)) AS referenced_variable_name
FROM catalog.object_parameters op JOIN catalog.projects p ON p.project_id = op.project_id JOIN catalog.folders f ON f.folder_id = p.folder_id
WHERE f.name = @f AND p.name = @p AND op.object_type = 20;   -- 20 = project-level parameter
"@)
    foreach ($pp in $params) {
        if ($pp.parameter_name -notin $bindable) { continue }
        if ($pp.value_type -eq 'R' -and $pp.referenced_variable_name -eq $pp.parameter_name) { Write-Log -Message "  $($pp.parameter_name) already bound"; continue }
        if ($PSCmdlet.ShouldProcess($pp.parameter_name, 'bind to environment variable')) {
            Invoke-Sql -NonQuery -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName; '@n' = $pp.parameter_name } -Query @"
EXEC catalog.set_object_parameter_value @object_type = 20, @folder_name = @f, @project_name = @p,
     @parameter_name = @n, @parameter_value = @n, @value_type = 'R';
"@
            Write-Log -Level OK -Message "  $($pp.parameter_name) -> environment variable $($pp.parameter_name)"
        }
    }
#endregion

#region ---------------- 9. Verification ----------------
    if (-not $WhatIfPreference) {
        $pkgs = @(Invoke-Sql -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName } -Query @"
SELECT pk.name AS PackageName, pk.entry_point, pk.validation_status FROM catalog.packages pk
JOIN catalog.projects p ON p.project_id = pk.project_id JOIN catalog.folders f ON f.folder_id = p.folder_id
WHERE f.name = @f AND p.name = @p ORDER BY pk.name;
"@)
        $bind = @(Invoke-Sql -Parameters @{ '@f' = $FolderName; '@p' = $ProjectName } -Query @"
SELECT op.object_name, op.parameter_name, op.value_type, CAST(op.referenced_variable_name AS nvarchar(128)) AS referenced_variable_name, op.sensitive
FROM catalog.object_parameters op JOIN catalog.projects p ON p.project_id = op.project_id JOIN catalog.folders f ON f.folder_id = p.folder_id
WHERE f.name = @f AND p.name = @p ORDER BY op.object_type, op.object_name, op.parameter_name;
"@)
        $pkgs | Export-Csv (Join-Path $RunFolder 'deployed_packages.csv') -NoTypeInformation -Encoding UTF8
        $bind | Export-Csv (Join-Path $RunFolder 'parameter_bindings.csv') -NoTypeInformation -Encoding UTF8
        Write-Log -Level OK -Message ("Verified: {0} packages deployed in {1}\{2}" -f $pkgs.Count, $FolderName, $ProjectName)
        $pkgs | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        Write-Log -Message 'Next: run 03_Test-AssessmentRouting.ps1 against this server to confirm the assessment routes every package as expected.'
    }
    Write-Log -Level OK -Message "Log folder: $RunFolder"
#endregion
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    throw
}
finally {
    Stop-Transcript | Out-Null
}
