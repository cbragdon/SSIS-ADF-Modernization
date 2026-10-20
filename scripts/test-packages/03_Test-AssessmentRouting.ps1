#Requires -Version 5.1
<#
.SYNOPSIS
    Regression test for 01_Invoke-SsisModernizationAssessment.ps1: runs the assessment against known
    test packages and compares every package's route to the expected route.

.DESCRIPTION
    TWO MODES
    ---------
    Fixtures (default, offline)
        Runs the assessment against tests\fixtures (hand-written XML covering cases that cannot be built
        on a modern SSIS install: encrypted and SSIS 2008 packages, Attunity CDC, third-party tasks,
        percent-encoded .ispac part names). Needs no SQL Server - suitable for a CI job on every commit.
        Each distinct TargetSsisVersion in the expected file is run separately.

    Server
        Runs the assessment against the AssessmentTests project deployed by 02_Deploy-SsisTestProject.ps1
        and compares it with tests\expected\AssessmentTests_expected_routes.csv. Packages that the builder
        skipped (component not installed; see build\build_manifest.csv) are reported SKIP, not FAIL.

    CHECKS
    ------
    * PackageRoute and EffectiveRoute equal the expected values.
    * Every expected package was found (missing = FAIL unless the build manifest says it was skipped).
    * No secret test value appears in any assessment output file (password masking).
    * The assessment reported zero errors (errors.csv empty).

    Exit code 0 when everything passes, 1 otherwise, so the script can gate a pull request.

.PARAMETER Mode
    Fixtures | Server.

.PARAMETER ServerInstance
    Server mode: the Dev server where the test project is deployed.

.PARAMETER FolderName / ProjectName
    Server mode: SSISDB location of the test project. Defaults ZZ_AssessmentTests / AssessmentTests.

.PARAMETER OutputRoot
    Where assessment output and the test report are written. Default C:\Temp\SSIS_AssessmentTests
    (a scratch folder under the system temp path on non-Windows CI runners).

.EXAMPLE
    .\03_Test-AssessmentRouting.ps1                      # offline fixtures
.EXAMPLE
    .\03_Test-AssessmentRouting.ps1 -Mode Server -ServerInstance <DevSqlServer> -TrustServerCertificate

.NOTES
    Version : 1.0.0
    Compat  : Windows PowerShell 5.1 and PowerShell 7.x.
#>
[CmdletBinding()]
param(
    [ValidateSet('Fixtures', 'Server')][string]$Mode = 'Fixtures',
    [string]$ServerInstance,
    [string]$FolderName = 'ZZ_AssessmentTests',
    [string]$ProjectName = 'AssessmentTests',
    [string]$OutputRoot,
    [switch]$TrustServerCertificate,
    [System.Management.Automation.PSCredential]$SqlCredential
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Assessment = Join-Path $RepoRoot 'scripts\assessment\01_Invoke-SsisModernizationAssessment.ps1'
if (-not $OutputRoot) {
    $OutputRoot = if ($env:OS -eq 'Windows_NT') { 'C:\Temp\SSIS_AssessmentTests' } else { Join-Path ([IO.Path]::GetTempPath()) 'SSIS_AssessmentTests' }
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

# Secret values planted in fixtures/test packages. None may appear in assessment output.
$PlantedSecrets = @('Secret123', 'hunter2')

function Write-Result { param([string]$Status, [string]$Text)
    $c = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow'; INFO = 'Gray' }[$Status]
    Write-Host ('[{0}] {1}' -f $Status, $Text) -ForegroundColor $c
}

function Invoke-AssessmentRun {
    <# Runs the assessment in a child scope and returns the run folder it created. #>
    param([hashtable]$Arguments)
    $before = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
    # 6>$null hides the child run's Write-Host console output; errors still surface.
    & $Assessment @Arguments -OutputRoot $OutputRoot 6>$null | Out-Null
    $after = @(Get-ChildItem -LiteralPath $OutputRoot -Directory | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime)
    if ($after.Count -eq 0) { throw 'Assessment did not create a run folder.' }
    return $after[-1].FullName
}

$results = New-Object System.Collections.Generic.List[object]

if ($Mode -eq 'Fixtures') {
    $expected = @(Import-Csv (Join-Path $RepoRoot 'tests\expected\fixtures_expected_routes.csv'))
    $fixtures = Join-Path $RepoRoot 'tests\fixtures'
    $runs = @{}
    foreach ($ver in ($expected | Select-Object -ExpandProperty TargetSsisVersion -Unique)) {
        Write-Result INFO "Running assessment on fixtures, target SQL Server $ver"
        # Run ids are per second; pause so consecutive runs never share a folder name.
        Start-Sleep -Seconds 1
        $runs[$ver] = Invoke-AssessmentRun @{ PackageFolder = $fixtures; TargetSsisVersion = $ver; Environment = 'Fixtures' }
    }
    $manifest = @()
}
else {
    if (-not $ServerInstance) { throw '-ServerInstance is required in Server mode.' }
    $expected = @(Import-Csv (Join-Path $RepoRoot 'tests\expected\AssessmentTests_expected_routes.csv'))
    $runs = @{}
    foreach ($ver in ($expected | Select-Object -ExpandProperty TargetSsisVersion -Unique)) {
        $a = @{ ServerInstance = $ServerInstance; TargetSsisVersion = $ver; Environment = 'Development' }
        if ($TrustServerCertificate) { $a.TrustServerCertificate = $true }
        if ($SqlCredential) { $a.SqlCredential = $SqlCredential }
        Start-Sleep -Seconds 1
        $runs[$ver] = Invoke-AssessmentRun $a
    }
    $mPath = Join-Path $RepoRoot 'build\build_manifest.csv'
    $manifest = if (Test-Path -LiteralPath $mPath) { @(Import-Csv $mPath) } else { @() }
}

foreach ($ver in $runs.Keys) {
    $run = $runs[$ver]
    $actual = @(Import-Csv (Join-Path $run 'package_assessment.csv'))
    if ($Mode -eq 'Server') { $actual = @($actual | Where-Object { $_.Folder -eq $FolderName -and $_.Project -eq $ProjectName }) }

    # Assessment errors
    $errs = @(Import-Csv (Join-Path $run 'errors.csv'))
    $results.Add([PSCustomObject]@{ Target = $ver; Check = 'Assessment errors'; Package = '-'; Expected = '0'; Actual = "$($errs.Count)"; Status = $(if ($errs.Count -eq 0) { 'PASS' } else { 'FAIL' }) })

    # Secret masking: scan every output file
    foreach ($f in Get-ChildItem -LiteralPath $run -File) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        foreach ($s in $PlantedSecrets) {
            if ($text -and $text.Contains($s)) {
                $results.Add([PSCustomObject]@{ Target = $ver; Check = 'Secret masking'; Package = $f.Name; Expected = 'absent'; Actual = "found '$s'"; Status = 'FAIL' })
            }
        }
    }

    foreach ($e in ($expected | Where-Object TargetSsisVersion -eq $ver)) {
        $match = @($actual | Where-Object {
            $_.Package -eq $e.Package -and $_.Project -eq $e.Project -and $_.SourceType -eq $e.Source
        })
        if ($match.Count -eq 0) {
            $m = @($manifest | Where-Object Package -eq $e.Package)
            $status = if ($m.Count -gt 0 -and $m[0].Built -eq 'False') { 'SKIP' } else { 'FAIL' }
            $results.Add([PSCustomObject]@{ Target = $ver; Check = 'Package found'; Package = "$($e.Project)\$($e.Package)"; Expected = 'present'; Actual = 'missing'; Status = $status })
            continue
        }
        $a = $match[0]
        foreach ($pair in @(@('PackageRoute', $e.ExpectedRoute), @('EffectiveRoute', $e.ExpectedEffectiveRoute))) {
            $ok = ($a.($pair[0]) -eq $pair[1])
            $results.Add([PSCustomObject]@{
                Target = $ver; Check = $pair[0]; Package = "$($e.Project)\$($e.Package)"
                Expected = $pair[1]; Actual = $a.($pair[0]); Status = $(if ($ok) { 'PASS' } else { 'FAIL' })
            })
        }
    }
}

foreach ($r in $results) { Write-Result $r.Status ('{0} | {1,-15} | {2,-45} expected {3,-16} actual {4}' -f $r.Target, $r.Check, $r.Package, $r.Expected, $r.Actual) }
$reportPath = Join-Path $OutputRoot ('routing_test_{0}_{1}.csv' -f $Mode, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

$fail = @($results | Where-Object Status -eq 'FAIL').Count
$pass = @($results | Where-Object Status -eq 'PASS').Count
$skip = @($results | Where-Object Status -eq 'SKIP').Count
Write-Host ''
Write-Result $(if ($fail) { 'FAIL' } else { 'PASS' }) ("{0} passed, {1} failed, {2} skipped. Report: {3}" -f $pass, $fail, $skip, $reportPath)
if ($fail) { exit 1 } else { exit 0 }
