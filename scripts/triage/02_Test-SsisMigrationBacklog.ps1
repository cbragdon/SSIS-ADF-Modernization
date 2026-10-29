#Requires -Version 5.1
<#
.SYNOPSIS
    Fixture regression test for the SSIS migration triage script.
#>
[CmdletBinding()]
param([string]$OutputRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$assessment = Join-Path $repoRoot 'scripts\assessment\01_Invoke-SsisModernizationAssessment.ps1'
$triage = Join-Path $PSScriptRoot '01_New-SsisMigrationBacklog.ps1'
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) 'SSIS_MigrationTriageTests' }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$assessmentRoot = Join-Path $OutputRoot 'assessment'
$fixtureFolder = Join-Path $repoRoot 'tests\fixtures'
& $assessment -PackageFolder $fixtureFolder -Environment Fixtures -WorkbookFolder (Join-Path $OutputRoot 'workbooks') -OutputRoot $assessmentRoot 6>$null | Out-Null
$run = @(Get-ChildItem -LiteralPath $assessmentRoot -Directory -Filter 'SSISASSESS_*' | Sort-Object LastWriteTime | Select-Object -Last 1)[0].FullName
$triageOutput = Join-Path $OutputRoot 'triage'
& $triage -AssessmentRunFolder $run -OutputFolder $triageOutput | Out-Null

$backlogPath = Join-Path $triageOutput 'migration-backlog.csv'
$summaryPath = Join-Path $triageOutput 'triage-summary.json'
$rows = @(Import-Csv -LiteralPath $backlogPath)
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
Assert-True ($rows.Count -gt 0) 'Triage did not produce backlog rows.'
Assert-True ($rows.Count -eq [int]$summary.Packages) 'Triage summary package count does not match the backlog.'
Assert-True (@($rows | Where-Object { $_.Queue -eq 'First migration wave' }).Count -gt 0) 'Fixture triage has no first-wave package.'
Assert-True (@($rows | Where-Object { $_.Queue -eq 'Retention register' }).Count -gt 0) 'Fixture triage has no retention-register package.'

$firstHash = (Get-FileHash -LiteralPath $backlogPath -Algorithm SHA256).Hash
& $triage -AssessmentRunFolder $run -OutputFolder $triageOutput | Out-Null
$secondHash = (Get-FileHash -LiteralPath $backlogPath -Algorithm SHA256).Hash
Assert-True ($firstHash -eq $secondHash) 'Identical triage input changed migration-backlog.csv.'

$baseline = Join-Path $OutputRoot 'baseline'
New-Item -ItemType Directory -Path $baseline -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $run 'assessment_manifest.json') -Destination (Join-Path $baseline 'assessment_manifest.json')
$baselinePackages = Get-Content -LiteralPath (Join-Path $run 'package_assessment.json') -Raw | ConvertFrom-Json
$baselinePackages[0].EffectiveRoute = 'KeepOnSsisVm'
[IO.File]::WriteAllText((Join-Path $baseline 'package_assessment.json'), ($baselinePackages | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

$comparisonOutput = Join-Path $OutputRoot 'comparison'
& $triage -AssessmentRunFolder $run -BaselineRunFolder $baseline -OutputFolder $comparisonOutput | Out-Null
$comparison = @(Import-Csv -LiteralPath (Join-Path $comparisonOutput 'migration-backlog.csv'))
Assert-True (@($comparison | Where-Object ChangeType -eq 'Route changed').Count -eq 1) 'Expected exactly one route change from the synthetic baseline.'

Write-Host "PASS: migration triage fixture test ($($rows.Count) packages)."
