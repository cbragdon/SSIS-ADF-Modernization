#Requires -Version 5.1
<#
.SYNOPSIS
    Data-parity test runner: runs the SSIS package and its ADF rewrite for each case, then compares
    their outputs in SQL Server and logs every result to the parity schema.

.DESCRIPTION
    WHAT THIS SCRIPT DOES
    ---------------------
    For every case in the case catalogue (tests\parity\parity_cases.csv by default):
      1. Loads the case into parity.TestCase (MERGE, so the CSV in source control is the source of truth).
      2. Optionally resets the outputs (ResetSql column), then optionally runs the SSIS package from
         SSISDB (-ExecuteSsis) and the ADF pipeline (-ExecuteAdf). A package or pipeline shared by
         several cases runs once per harness run.
      3. Compares:
           Table   -> parity.usp_CompareTables     (row-hash multiset + collation-aware EXCEPT)
           Files   -> builds a manifest of both folders (name after NameMask, size, SHA256, lines,
                      header, final newline, BOM) into parity.FileManifest, then
                      parity.usp_CompareFileManifests
           Outcome -> records each side's run outcome in parity.ExecutionOutcome, then
                      parity.usp_CompareOutcome
      4. Writes parity_results_<RunId>.csv and closes the run (parity.usp_EndRun).

    Without -ExecuteSsis / -ExecuteAdf the runner only compares what is already in the output tables
    and folders, which is the normal mode when the two sides are run by their own schedulers.

    Exit code 0 when no case is FAIL or ERROR (KNOWN_DIFF is accepted), 1 otherwise, so the script can
    gate a rebuild's sign-off.

    REQUIREMENTS
    ------------
    * Windows PowerShell 5.1 or PowerShell 7 (System.Data.SqlClient).
    * sql\01_, 02_ and 03_ applied to the test database.
    * -ExecuteSsis: the packages deployed to SSISDB on -SsisServerInstance (default -ServerInstance),
      and a login allowed to run them (ssis_admin or project EXECUTE).
    * -ExecuteAdf: the Az.Accounts module signed in (Connect-AzAccount) or the Azure CLI signed in, and
      the pipelines deployed. The factory is identified by parameters only; nothing is stored in the repo.

    SAFETY
    ------
    Reads the compared objects only. Writes to the parity schema, and runs ResetSql (which empties the
    out_ssis / out_adf scenario tables) only for the selected cases. Never point it at production.

.PARAMETER ServerInstance
    SQL Server hosting the test database (the comparison runs here).

.PARAMETER Database
    Test database. Default SsisAssessmentTest.

.PARAMETER SqlCredential
    SQL authentication. Windows authentication when omitted.

.PARAMETER TrustServerCertificate / DisableEncryption
    TLS options for lab servers with self-signed certificates.

.PARAMETER CasesPath
    Case catalogue CSV. Default tests\parity\parity_cases.csv.

.PARAMETER CaseId / GapId
    Run only these cases or gaps (wildcards allowed).

.PARAMETER RunId
    Attach to an existing parity.Run instead of starting a new one (outcomes or manifests were
    recorded by another process).

.PARAMETER LandingPath
    Replaces <LandingPath> in the SsisPath / CandidatePath columns of Files cases. Default <repo>\build\landing,
    the same default the ParityTests build uses for its LandingPath project parameter.

.PARAMETER ExecuteSsis / SsisServerInstance / SsisEnvironment
    Run each case's SSIS package synchronously through SSISDB before comparing. SsisEnvironment names
    an environment reference of the project (optional).

    ResetSql runs only for the side(s) about to be executed: with -ExecuteSsis alone, @Side = 'both' in the
    ResetSql column is narrowed to 'ssis' (and to 'adf' with -ExecuteAdf alone), so the other side's output,
    produced by its own scheduler, is kept for the comparison.

.PARAMETER ExecuteAdf / SubscriptionId / ResourceGroupName / DataFactoryName / AdfTimeoutMinutes
    Run each case's pipeline (AdfPipeline column, AdfParameters JSON) and wait for it to finish.

.PARAMETER Label / OutputRoot / SampleRows
    Run label stored in parity.Run, folder for the CSV report, sample rows kept per difference.

.EXAMPLE
    # Compare outputs already produced by both sides
    .\01_Invoke-ParityTest.ps1 -ServerInstance <DevSqlServer> -LandingPath '\\<FileServer>\ssis_landing'

.EXAMPLE
    # Run SSIS and ADF for one gap, then compare
    .\01_Invoke-ParityTest.ps1 -ServerInstance <DevSqlServer> -GapId G22 -ExecuteSsis -ExecuteAdf `
        -SubscriptionId <SubscriptionId> -ResourceGroupName <ResourceGroup> -DataFactoryName <DataFactory>

.NOTES
    Version : 1.1.0
    Part of : SSIS-ADF-Modernization repository (scripts\parity)
    Status  : Comparison path verified by 02_Test-ParityHarness.ps1 against SQL Server 2017-2025.
              -ExecuteSsis run against SQL Server 2025 CU9 (Windows) with the ParityTests packages P22-P30.
              -ExecuteAdf has not been run yet: the pipelines in adf\ are authored but not deployed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [string]$Database = 'SsisAssessmentTest',
    [pscredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [switch]$DisableEncryption,
    [string]$CasesPath,
    [string[]]$CaseId,
    [string[]]$GapId,
    [int]$RunId = 0,
    [string]$LandingPath = '',
    [switch]$ExecuteSsis,
    [string]$SsisServerInstance,
    [string]$SsisEnvironment = '',
    [switch]$ExecuteAdf,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$DataFactoryName,
    [int]$AdfTimeoutMinutes = 60,
    [string]$Label = '',
    [string]$OutputRoot,
    [ValidateRange(0, 1000)][int]$SampleRows = 10
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $CasesPath)  { $CasesPath  = Join-Path $RepoRoot 'tests\parity\parity_cases.csv' }
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) 'SSIS_ADF_Parity' }
if (-not $PSBoundParameters.ContainsKey('LandingPath')) { $LandingPath = Join-Path $RepoRoot 'build\landing' }
if (-not $SsisServerInstance) { $SsisServerInstance = $ServerInstance }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan' }[$Level]
    Write-Host ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}

#region ---------------- SQL helpers ----------------
function New-SqlConnectionObject {
    <# Builds a SqlConnection with explicit encryption settings. Windows auth unless -SqlCredential given. #>
    param([Parameter(Mandatory)][string]$Server, [string]$DatabaseName = 'master')
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source']            = $Server
    $b['Initial Catalog']        = $DatabaseName
    $b['Application Name']       = 'SSIS-ADF-Parity'
    $b['Connect Timeout']        = 30
    $b['Encrypt']                = (-not $DisableEncryption)
    $b['TrustServerCertificate'] = [bool]$TrustServerCertificate
    if ($SqlCredential) {
        $conn = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
        $securePwd = $SqlCredential.Password.Copy(); $securePwd.MakeReadOnly()
        $conn.Credential = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $securePwd)
        return $conn
    }
    $b['Integrated Security'] = $true
    return New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
}

function Invoke-Sql {
    <# Runs one batch with parameters; returns the first result set as objects. Timeout 0 = no limit. #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$Query, [hashtable]$Parameters = @{}, [int]$Timeout = 300)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $Timeout
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]; if ($null -eq $v) { $v = [DBNull]::Value }
        [void]$cmd.Parameters.AddWithValue("@$k", $v)
    }
    $table = New-Object System.Data.DataTable
    $reader = $cmd.ExecuteReader()
    try { $table.Load($reader) } finally { $reader.Dispose() }
    return ,$table
}

function Get-Field { param($Row, [string]$Name) if ($Row.PSObject.Properties[$Name] -and $Row.$Name) { return [string]$Row.$Name } return $null }
#endregion

#region ---------------- Executions ----------------
function Invoke-SsisPackage {
    <# Runs a package synchronously from SSISDB. Returns Outcome (Succeeded/Failed/...), ExecutionRef, Message. #>
    param($Case)
    $conn = New-SqlConnectionObject -Server $SsisServerInstance -DatabaseName 'SSISDB'
    $conn.Open()
    try {
        $q = @'
DECLARE @ref bigint = NULL, @id bigint;
IF @env <> N''
    SELECT @ref = er.reference_id
      FROM catalog.environment_references AS er
      JOIN catalog.projects AS p ON p.project_id = er.project_id
      JOIN catalog.folders  AS f ON f.folder_id  = p.folder_id
     WHERE f.name = @folder AND p.name = @project AND er.environment_name = @env;
EXEC catalog.create_execution @folder_name = @folder, @project_name = @project, @package_name = @package,
     @use32bitruntime = 0, @reference_id = @ref, @execution_id = @id OUTPUT;
EXEC catalog.set_execution_parameter_value @id, @object_type = 50, @parameter_name = N'SYNCHRONIZED', @parameter_value = 1;
EXEC catalog.start_execution @id;
SELECT e.execution_id, e.status,
       (SELECT TOP (3) m.message + N' | ' FROM catalog.event_messages AS m
         WHERE m.operation_id = e.execution_id AND m.message_type = 120 ORDER BY m.event_message_id FOR XML PATH('')) AS errors
  FROM catalog.executions AS e WHERE e.execution_id = @id;
'@
        $r = (Invoke-Sql -Connection $conn -Query $q -Timeout 0 -Parameters @{
                folder = $Case.SsisFolder; project = $Case.SsisProject; package = $Case.SsisPackage; env = $SsisEnvironment }).Rows[0]
        $statusName = @{ 1 = 'Created'; 2 = 'Running'; 3 = 'Canceled'; 4 = 'Failed'; 5 = 'Pending'; 6 = 'EndedUnexpectedly'; 7 = 'Succeeded'; 8 = 'Stopping'; 9 = 'Completed' }[[int]$r.status]
        return [PSCustomObject]@{ Outcome = $statusName; ExecutionRef = [string]$r.execution_id; Message = [string]$r.errors }
    }
    finally { $conn.Dispose() }
}

function Get-ArmToken {
    <# Azure Resource Manager token: Az.Accounts first, then the Azure CLI. #>
    if (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue) {
        $t = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
        if ($t.Token -is [securestring]) { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($t.Token)) }
        return $t.Token
    }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        return (az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
    }
    throw 'No Azure sign-in: install Az.Accounts and run Connect-AzAccount, or sign in with the Azure CLI.'
}

function Invoke-AdfPipeline {
    <# Starts a pipeline run and polls until it finishes. Returns Outcome, ExecutionRef (runId), Message. #>
    param($Case)
    $base = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DataFactory/factories/{2}' -f $SubscriptionId, $ResourceGroupName, $DataFactoryName
    $headers = @{ Authorization = 'Bearer ' + (Get-ArmToken) }
    $body = if (Get-Field $Case 'AdfParameters') { $Case.AdfParameters } else { '{}' }
    $run = Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body $body `
        -Uri ('{0}/pipelines/{1}/createRun?api-version=2018-06-01' -f $base, [uri]::EscapeDataString($Case.AdfPipeline))
    $deadline = (Get-Date).AddMinutes($AdfTimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $s = Invoke-RestMethod -Method Get -Headers $headers -Uri ('{0}/pipelineruns/{1}?api-version=2018-06-01' -f $base, $run.runId)
    } while ($s.status -in @('Queued', 'InProgress', 'Canceling') -and (Get-Date) -lt $deadline)
    $outcome = if ($s.status -eq 'Cancelled') { 'Canceled' } elseif ($s.status -in @('Queued', 'InProgress', 'Canceling')) { 'TimedOut' } else { $s.status }
    return [PSCustomObject]@{ Outcome = $outcome; ExecutionRef = $run.runId; Message = [string]$s.message }
}
#endregion

#region ---------------- File manifests ----------------
function Get-FileManifest {
    <# One row per file under Root: masked relative name, size, SHA256, lines, header, final newline, BOM. #>
    param([Parameter(Mandatory)][string]$Root, [string]$NameMask)
    $maskFrom = $null; $maskTo = ''
    if ($NameMask) { $parts = $NameMask -split '=', 2; $maskFrom = $parts[0]; if ($parts.Count -gt 1) { $maskTo = $parts[1] } }
    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $rootFull -File -Recurse | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
            $masked = if ($maskFrom) { [regex]::Replace($rel, $maskFrom, $maskTo) } else { $rel }
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $enc = 'NoBOM'; $skip = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = 'UTF8-BOM'; $skip = 3 }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = 'UTF16LE-BOM'; $skip = 2 }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = 'UTF16BE-BOM'; $skip = 2 }
            $textEnc = switch ($enc) { 'UTF16LE-BOM' { [Text.Encoding]::Unicode } 'UTF16BE-BOM' { [Text.Encoding]::BigEndianUnicode } default { [Text.Encoding]::UTF8 } }
            $text = $textEnc.GetString($bytes, $skip, $bytes.Length - $skip)
            $endsNl = $text.EndsWith("`n")
            $lines = if ($text.Length -eq 0) { 0 } else { ([regex]::Matches($text, "`n")).Count + $(if ($endsNl) { 0 } else { 1 }) }
            $header = ($text -split "`r?`n", 2)[0]
            if ($header.Length -gt 4000) { $header = $header.Substring(0, 4000) }
            [PSCustomObject]@{
                RelativePath = $masked; OriginalName = $rel; Bytes = [int64]$bytes.Length
                Sha256 = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
                LineCount = [int64]$lines; HeaderLine = $header; EndsWithNewline = $endsNl; Encoding = $enc
            }
        }
    }
    finally { $sha.Dispose() }
}
#endregion

#region ---------------- Main ----------------
$exitCode = 1
$conn = $null
try {
    Write-Log -Level STEP -Message "Parity run on $ServerInstance / $Database"
    $cases = @(Import-Csv -LiteralPath $CasesPath)
    if ($CaseId) { $cases = @($cases | Where-Object { $c = $_; @($CaseId | Where-Object { $c.CaseId -like $_ }).Count -gt 0 }) }
    if ($GapId)  { $cases = @($cases | Where-Object { $c = $_; @($GapId  | Where-Object { $c.GapId  -like $_ }).Count -gt 0 }) }
    if ($cases.Count -eq 0) { throw "No cases selected from $CasesPath." }
    Write-Log -Message ("{0} case(s) selected from {1}" -f $cases.Count, $CasesPath)
    if ($ExecuteAdf -and -not ($SubscriptionId -and $ResourceGroupName -and $DataFactoryName)) {
        throw '-ExecuteAdf needs -SubscriptionId, -ResourceGroupName and -DataFactoryName.'
    }

    $conn = New-SqlConnectionObject -Server $ServerInstance -DatabaseName $Database
    $conn.Open()
    # The compare procedures use STRING_SPLIT and FOR JSON: stop with a clear message below level 130.
    $compat = [int](Invoke-Sql -Connection $conn -Query 'SELECT compatibility_level AS c FROM sys.databases WHERE database_id = DB_ID();').Rows[0].c
    if ($compat -lt 130) { throw "Database $Database is at compatibility level $compat; the parity harness needs 130 or higher (STRING_SPLIT, FOR JSON). Raise the level or use another database." }

    # 1. Case catalogue -> parity.TestCase
    $merge = @'
MERGE parity.TestCase AS t
USING (SELECT @CaseId AS CaseId) AS s ON t.CaseId = s.CaseId
WHEN MATCHED THEN UPDATE SET GapId = @GapId, Title = @Title, CompareType = @CompareType, SsisObject = @SsisObject,
     CandidateObject = @CandidateObject, KeyColumns = @KeyColumns, CompareColumns = @CompareColumns,
     IgnoreColumns = @IgnoreColumns, ExpectedOutcome = @ExpectedOutcome, AllowEmpty = @AllowEmpty, Notes = @Notes, ModifiedAt = SYSDATETIME()
WHEN NOT MATCHED THEN INSERT (CaseId, GapId, Title, CompareType, SsisObject, CandidateObject, KeyColumns, CompareColumns, IgnoreColumns, ExpectedOutcome, AllowEmpty, Notes)
     VALUES (@CaseId, @GapId, @Title, @CompareType, @SsisObject, @CandidateObject, @KeyColumns, @CompareColumns, @IgnoreColumns, @ExpectedOutcome, @AllowEmpty, @Notes);
SELECT @@ROWCOUNT AS n;
'@
    foreach ($c in $cases) {
        $expected = if (Get-Field $c 'ExpectedOutcome') { $c.ExpectedOutcome } else { 'Match' }
        [void](Invoke-Sql -Connection $conn -Query $merge -Parameters @{
            CaseId = $c.CaseId; GapId = (Get-Field $c 'GapId'); Title = $c.Title; CompareType = $c.CompareType
            SsisObject = (Get-Field $c 'SsisObject'); CandidateObject = (Get-Field $c 'CandidateObject')
            KeyColumns = (Get-Field $c 'KeyColumns'); CompareColumns = (Get-Field $c 'CompareColumns')
            IgnoreColumns = (Get-Field $c 'IgnoreColumns'); ExpectedOutcome = $expected; Notes = (Get-Field $c 'Notes')
            AllowEmpty = [bool]((Get-Field $c 'AllowEmpty') -in @('1', 'true', 'True', 'yes')) })
    }

    # 2. Run
    if ($RunId -le 0) {
        $commit = $null
        try { if (Get-Command git -ErrorAction SilentlyContinue) { $commit = (& git -C $RepoRoot rev-parse HEAD 2>$null) } } catch { $commit = $null }
        $RunId = [int](Invoke-Sql -Connection $conn -Query 'DECLARE @id int; EXEC parity.usp_StartRun @Label = @Label, @GitCommit = @Commit, @RunId = @id OUTPUT; SELECT @id AS RunId;' `
                        -Parameters @{ Label = $(if ($Label) { $Label } else { $null }); Commit = $(if ($commit) { [string]$commit } else { $null }) }).Rows[0].RunId
    }
    Write-Log -Level OK -Message "RunId $RunId"

    $ranSsis = @{}; $ranAdf = @{}
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cases) {
        Write-Log -Level STEP -Message ("{0} ({1}): {2}" -f $c.CaseId, $c.CompareType, $c.Title)
        try {
            # Reset and execute (once per package / pipeline per run)
            $needSsis = $ExecuteSsis -and (Get-Field $c 'SsisPackage') -and -not $ranSsis.ContainsKey($c.SsisPackage)
            $needAdf  = $ExecuteAdf  -and (Get-Field $c 'AdfPipeline') -and -not $ranAdf.ContainsKey($c.AdfPipeline)
            if (($needSsis -or $needAdf) -and (Get-Field $c 'ResetSql')) {
                # Reset only the side that is about to run, so the other side's existing output is compared, not wiped.
                $reset = $c.ResetSql
                if ($needSsis -xor $needAdf) { $reset = [regex]::Replace($reset, "(?i)(@Side\s*=\s*)'both'", ('$1''{0}''' -f $(if ($needSsis) { 'ssis' } else { 'adf' }))) }
                [void](Invoke-Sql -Connection $conn -Query $reset)
            }
            if ($needSsis) { Write-Log -Message "  SSIS: $($c.SsisFolder)\$($c.SsisProject)\$($c.SsisPackage)"; $ranSsis[$c.SsisPackage] = Invoke-SsisPackage -Case $c; Write-Log -Message "  SSIS outcome: $($ranSsis[$c.SsisPackage].Outcome)" }
            if ($needAdf)  { Write-Log -Message "  ADF : $($c.AdfPipeline)"; $ranAdf[$c.AdfPipeline] = Invoke-AdfPipeline -Case $c; Write-Log -Message "  ADF outcome: $($ranAdf[$c.AdfPipeline].Outcome)" }

            switch ($c.CompareType) {
                'Table' {
                    $r = (Invoke-Sql -Connection $conn -Query 'EXEC parity.usp_CompareTables @RunId = @RunId, @CaseId = @CaseId, @SampleRows = @SampleRows;' -Timeout 0 `
                            -Parameters @{ RunId = $RunId; CaseId = $c.CaseId; SampleRows = $SampleRows }).Rows[0]
                }
                'Files' {
                    $ins = 'INSERT parity.FileManifest (RunId, CaseId, Side, RelativePath, OriginalName, Bytes, Sha256, LineCount, HeaderLine, EndsWithNewline, Encoding) VALUES (@RunId, @CaseId, @Side, @RelativePath, @OriginalName, @Bytes, @Sha256, @LineCount, @HeaderLine, @EndsWithNewline, @Encoding); SELECT 1 AS ok;'
                    [void](Invoke-Sql -Connection $conn -Query 'DELETE parity.FileManifest WHERE RunId = @RunId AND CaseId = @CaseId; SELECT 1 AS ok;' -Parameters @{ RunId = $RunId; CaseId = $c.CaseId })
                    foreach ($side in @(@{ Name = 'SSIS'; Path = $c.SsisPath }, @{ Name = 'Candidate'; Path = $c.CandidatePath })) {
                        $root = ([string]$side.Path).Replace('<LandingPath>', $LandingPath)
                        if (-not $root -or -not (Test-Path -LiteralPath $root)) { Write-Log -Level WARN -Message "  $($side.Name) folder not found: $root"; continue }
                        foreach ($m in (Get-FileManifest -Root $root -NameMask (Get-Field $c 'NameMask'))) {
                            [void](Invoke-Sql -Connection $conn -Query $ins -Parameters @{
                                RunId = $RunId; CaseId = $c.CaseId; Side = $side.Name; RelativePath = $m.RelativePath; OriginalName = $m.OriginalName
                                Bytes = $m.Bytes; Sha256 = $m.Sha256; LineCount = $m.LineCount; HeaderLine = $m.HeaderLine
                                EndsWithNewline = $m.EndsWithNewline; Encoding = $m.Encoding })
                        }
                    }
                    $r = (Invoke-Sql -Connection $conn -Query 'EXEC parity.usp_CompareFileManifests @RunId = @RunId, @CaseId = @CaseId;' -Parameters @{ RunId = $RunId; CaseId = $c.CaseId }).Rows[0]
                }
                'Outcome' {
                    $upsert = 'DELETE parity.ExecutionOutcome WHERE RunId = @RunId AND CaseId = @CaseId AND Side = @Side; INSERT parity.ExecutionOutcome (RunId, CaseId, Side, Outcome, ExecutionRef, Message) VALUES (@RunId, @CaseId, @Side, @Outcome, @Ref, @Msg); SELECT 1 AS ok;'
                    foreach ($pair in @(@{ Side = 'SSIS'; Run = $(if ((Get-Field $c 'SsisPackage') -and $ranSsis.ContainsKey($c.SsisPackage)) { $ranSsis[$c.SsisPackage] }) },
                                        @{ Side = 'Candidate'; Run = $(if ((Get-Field $c 'AdfPipeline') -and $ranAdf.ContainsKey($c.AdfPipeline)) { $ranAdf[$c.AdfPipeline] }) })) {
                        if ($pair.Run) {
                            $msg = [string]$pair.Run.Message; if ($msg.Length -gt 4000) { $msg = $msg.Substring(0, 4000) }
                            [void](Invoke-Sql -Connection $conn -Query $upsert -Parameters @{ RunId = $RunId; CaseId = $c.CaseId; Side = $pair.Side; Outcome = $pair.Run.Outcome; Ref = $pair.Run.ExecutionRef; Msg = $msg })
                        }
                    }
                    $r = (Invoke-Sql -Connection $conn -Query 'EXEC parity.usp_CompareOutcome @RunId = @RunId, @CaseId = @CaseId;' -Parameters @{ RunId = $RunId; CaseId = $c.CaseId }).Rows[0]
                }
                default { throw "Unknown CompareType '$($c.CompareType)'." }
            }
            $row = [PSCustomObject]@{
                RunId = $RunId; CaseId = $c.CaseId; GapId = (Get-Field $c 'GapId'); CompareType = $c.CompareType; Status = [string]$r.Status
                SsisRows = $r.SsisRows; CandidateRows = $r.CandidateRows; OnlyInSsis = $r.OnlyInSsis; OnlyInCandidate = $r.OnlyInCandidate
                ExceptOnlyInSsis = $r.ExceptOnlyInSsis; ExceptOnlyInCandidate = $r.ExceptOnlyInCandidate
                SchemaDiff = [string]$r.SchemaDiff; Detail = [string]$r.Detail
            }
        }
        catch {
            # The case could not be compared at all (execution error, missing folder...): logged as ERROR.
            $msg = $_.Exception.Message
            [void](Invoke-Sql -Connection $conn -Query "INSERT parity.Result (RunId, CaseId, CompareType, Status, Detail) VALUES (@RunId, @CaseId, @Type, 'ERROR', @Detail); SELECT 1 AS ok;" `
                    -Parameters @{ RunId = $RunId; CaseId = $c.CaseId; Type = $c.CompareType; Detail = $msg })
            $row = [PSCustomObject]@{ RunId = $RunId; CaseId = $c.CaseId; GapId = (Get-Field $c 'GapId'); CompareType = $c.CompareType; Status = 'ERROR'
                SsisRows = $null; CandidateRows = $null; OnlyInSsis = $null; OnlyInCandidate = $null; ExceptOnlyInSsis = $null; ExceptOnlyInCandidate = $null
                SchemaDiff = ''; Detail = $msg }
        }
        $lvl = @{ PASS = 'OK'; KNOWN_DIFF = 'WARN'; FAIL = 'ERROR'; ERROR = 'ERROR' }[$row.Status]; if (-not $lvl) { $lvl = 'WARN' }
        Write-Log -Level $lvl -Message ("  {0}  ssis={1} candidate={2} onlySsis={3} onlyCandidate={4} {5}" -f $row.Status, $row.SsisRows, $row.CandidateRows, $row.OnlyInSsis, $row.OnlyInCandidate, $row.Detail)
        $results.Add($row)
    }

    $summary = (Invoke-Sql -Connection $conn -Query 'EXEC parity.usp_EndRun @RunId = @RunId;' -Parameters @{ RunId = $RunId }).Rows[0]
    $report = Join-Path $OutputRoot ('parity_results_{0}.csv' -f $RunId)
    $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
    Write-Log -Level OK -Message ("Run {0}: {1} passed, {2} failed, {3} known differences, {4} errors. Report: {5}" -f $RunId, $summary.Passed, $summary.Failed, $summary.KnownDiff, $summary.Errors, $report)
    $exitCode = if (@($results | Where-Object { $_.Status -in @('FAIL', 'ERROR') }).Count -eq 0) { 0 } else { 1 }
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    $exitCode = 1
}
finally {
    if ($conn) { $conn.Dispose() }
}
exit $exitCode
#endregion
