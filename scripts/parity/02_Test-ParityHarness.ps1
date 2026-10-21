#Requires -Version 5.1
<#
.SYNOPSIS
    Self-test for the data-parity harness: proves on known-answer data that the comparison catches
    the differences an SSIS-to-ADF rebuild typically introduces, and passes what is equivalent.

.DESCRIPTION
    1. Applies sql\01_Create-SsisAssessmentTestDb.sql, sql\02_Create-ParityHarness.sql,
       sql\03_Seed-ParityScenarios.sql and tests\parity\selftest\01_SelfTest-Setup.sql (unless -SkipSetup).
    2. Writes two small file sets under -WorkRoot (one identical, one with a missing final newline,
       a BOM and an extra file) and records run outcomes for the Outcome cases.
    3. Runs 01_Invoke-ParityTest.ps1 on tests\parity\selftest\selftest_cases.csv for one run.
    4. Checks every case's Status against ExpectedStatus, and every '|'-separated ExpectedDetail token
       against the result's Detail / SchemaDiff.

    Exit code 0 when every case matches its expected answer, 1 otherwise. CI runs this against a
    SQL Server container on every push.

.PARAMETER ServerInstance / SqlCredential / TrustServerCertificate
    Disposable SQL Server instance (the self-test creates SsisAssessmentTest if it is missing).

.PARAMETER WorkRoot
    Scratch folder for the file-set cases. Default: a folder under the temp directory.

.PARAMETER SkipSetup
    Do not re-apply the SQL scripts.

.EXAMPLE
    .\02_Test-ParityHarness.ps1 -ServerInstance localhost -SqlCredential (Get-Credential sa) -TrustServerCertificate

.NOTES
    Version : 1.0.0
    Part of : SSIS-ADF-Modernization repository (scripts\parity)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [pscredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [string]$WorkRoot,
    [switch]$SkipSetup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $WorkRoot) { $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'SSIS_ADF_ParitySelfTest' }
$CasesPath = Join-Path $RepoRoot 'tests\parity\selftest\selftest_cases.csv'

function Write-Result {
    param([string]$Status, [string]$Message)
    $c = @{ PASS = 'Green'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    Write-Host ('[{0}] {1}' -f $Status, $Message) -ForegroundColor $c
}

function New-Conn {
    param([string]$Db)
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $ServerInstance; $b['Initial Catalog'] = $Db; $b['Encrypt'] = $true
    $b['TrustServerCertificate'] = [bool]$TrustServerCertificate; $b['Application Name'] = 'SSIS-ADF-ParitySelfTest'
    if ($SqlCredential) {
        $c = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
        $p = $SqlCredential.Password.Copy(); $p.MakeReadOnly()
        $c.Credential = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $p)
        return $c
    }
    $b['Integrated Security'] = $true
    return New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
}

function Invoke-SqlFile {
    <# Runs a script split on GO lines. The scripts switch database with USE themselves. #>
    param([string]$Path)
    $conn = New-Conn -Db 'master'; $conn.Open()
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        foreach ($batch in ([regex]::Split($text, '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() })) {
            $cmd = $conn.CreateCommand(); $cmd.CommandText = $batch; $cmd.CommandTimeout = 300
            [void]$cmd.ExecuteNonQuery()
        }
    }
    finally { $conn.Dispose() }
}

function Write-Bytes { param([string]$Path, [byte[]]$Bytes) New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null; [IO.File]::WriteAllBytes($Path, $Bytes) }

$failures = 0
try {
    if (-not $SkipSetup) {
        foreach ($f in @('sql\01_Create-SsisAssessmentTestDb.sql', 'sql\02_Create-ParityHarness.sql', 'sql\03_Seed-ParityScenarios.sql', 'tests\parity\selftest\01_SelfTest-Setup.sql')) {
            Write-Result INFO "Applying $f"
            Invoke-SqlFile -Path (Join-Path $RepoRoot $f)
        }
    }

    # File sets. Names carry a time stamp that NameMask removes; the second set differs on purpose.
    if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $body = "Region,Amount`r`neast,1.25`r`neast,5.00`r`n"
    Write-Bytes (Join-Path $WorkRoot 'files_ok/ssis/east_part1_20260131_101500.csv') $utf8.GetBytes($body)
    Write-Bytes (Join-Path $WorkRoot 'files_ok/adf/east_part1_20260131_101742.csv')  $utf8.GetBytes($body)
    Write-Bytes (Join-Path $WorkRoot 'files_diff/ssis/east_part1_20260131_101500.csv') $utf8.GetBytes($body)
    Write-Bytes (Join-Path $WorkRoot 'files_diff/adf/east_part1_20260131_101742.csv')  $utf8.GetBytes($body.TrimEnd("`r", "`n"))
    Write-Bytes (Join-Path $WorkRoot 'files_diff/ssis/east_part2_20260131_101500.csv') $utf8.GetBytes($body)
    Write-Bytes (Join-Path $WorkRoot 'files_diff/adf/east_part2_20260131_101742.csv')  ([byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($body))
    Write-Bytes (Join-Path $WorkRoot 'files_diff/adf/east_part3_20260131_101742.csv')  $utf8.GetBytes("Region,Amount`r`n")

    # One run; Outcome cases get their outcomes recorded up front (as a scheduler would).
    $conn = New-Conn -Db 'SsisAssessmentTest'; $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @id int;
EXEC parity.usp_StartRun @Label = N'Harness self-test', @RunId = @id OUTPUT;
INSERT parity.ExecutionOutcome (RunId, CaseId, Side, Outcome, Message) VALUES
    (@id, 'ST30', 'SSIS', 'Failed', N'Single Row result set is specified, but no rows were returned.'),
    (@id, 'ST30', 'Candidate', 'Failed', N'Activity failed: firstRow is not present.'),
    (@id, 'ST31', 'SSIS', 'Failed', N'Single Row result set is specified, but no rows were returned.'),
    (@id, 'ST31', 'Candidate', 'Succeeded', N'');
SELECT @id;
"@
        $runId = [int]$cmd.ExecuteScalar()
    }
    finally { $conn.Dispose() }
    Write-Result INFO "RunId $runId"

    $runner = Join-Path $PSScriptRoot '01_Invoke-ParityTest.ps1'
    $runnerArgs = @{ ServerInstance = $ServerInstance; CasesPath = $CasesPath; RunId = $runId; LandingPath = $WorkRoot; OutputRoot = $WorkRoot }
    if ($SqlCredential) { $runnerArgs.SqlCredential = $SqlCredential }
    if ($TrustServerCertificate) { $runnerArgs.TrustServerCertificate = $true }
    & $runner @runnerArgs | Out-Host   # exit code is expected to be 1: the self-test includes FAIL and ERROR cases

    # Check every case against its known answer.
    $conn = New-Conn -Db 'SsisAssessmentTest'; $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'SELECT CaseId, Status, ISNULL(Detail, N'''') + N'' '' + ISNULL(SchemaDiff, N'''') AS Info FROM parity.Result WHERE RunId = @r'
        [void]$cmd.Parameters.AddWithValue('@r', $runId)
        $t = New-Object System.Data.DataTable; $rd = $cmd.ExecuteReader(); $t.Load($rd); $rd.Dispose()
    }
    finally { $conn.Dispose() }
    $actual = @{}; foreach ($row in $t.Rows) { $actual[[string]$row.CaseId] = $row }

    foreach ($e in (Import-Csv -LiteralPath $CasesPath)) {
        if (-not $actual.ContainsKey($e.CaseId)) { $failures++; Write-Result FAIL "$($e.CaseId) no result recorded"; continue }
        $a = $actual[$e.CaseId]
        $ok = [string]$a.Status -eq $e.ExpectedStatus
        $missing = @(); if ($e.ExpectedDetail) { $missing = @($e.ExpectedDetail -split '\|' | Where-Object { ([string]$a.Info).IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }) }
        if ($ok -and $missing.Count -eq 0) { Write-Result PASS ('{0,-5} {1,-11} {2}' -f $e.CaseId, $a.Status, $e.Title) }
        else {
            $failures++
            Write-Result FAIL ('{0,-5} expected {1}, got {2}. {3} {4}' -f $e.CaseId, $e.ExpectedStatus, $a.Status, $(if ($missing) { 'Missing detail: ' + ($missing -join ' | ') + '.' }), ([string]$a.Info).Trim())
        }
    }
}
catch {
    $failures++
    Write-Result FAIL $_.Exception.Message
}
if ($failures -eq 0) { Write-Result PASS 'Parity harness self-test passed.' } else { Write-Result FAIL "$failures self-test check(s) failed." }
exit $(if ($failures -eq 0) { 0 } else { 1 })
