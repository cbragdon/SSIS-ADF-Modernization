#Requires -Version 5.1
<#
.SYNOPSIS
    Runs isolated SSIS assessments for local private target configuration and consolidates their results.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$BaselineBatchFolder,
    [string]$OutputRoot,
    [switch]$ValidateOnly,
    [switch]$TrustServerCertificate
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$assessment = Join-Path $repoRoot 'scripts\assessment\01_Invoke-SsisModernizationAssessment.ps1'
try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { throw "Cannot read batch configuration '$ConfigPath': $($_.Exception.Message)" }
if (-not $config.targets -or @($config.targets).Count -eq 0) { throw 'Configuration requires at least one target.' }
if (-not $config.workbookFolder -or -not $config.outputRoot) { throw 'Configuration requires workbookFolder and outputRoot.' }
$names = @{}; foreach ($target in @($config.targets)) {
    if (-not $target.name -or -not $target.serverInstance -or -not $target.environment -or -not $target.targetSsisVersion) { throw 'Every target requires name, serverInstance, environment, and targetSsisVersion.' }
    if ($names.ContainsKey($target.name)) { throw "Duplicate target name '$($target.name)'." }; $names[$target.name] = $true
    if ($target.targetSsisVersion -notin @('2016','2017','2019','2022','2025')) { throw "Invalid targetSsisVersion '$($target.targetSsisVersion)'." }
}
if ($ValidateOnly) { Write-Host "Valid configuration: $(@($config.targets).Count) target(s)."; exit 0 }
if (-not $OutputRoot) { $OutputRoot = $config.outputRoot }
$batchFolder = Join-Path $OutputRoot ('SSISBATCH_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $batchFolder -Force | Out-Null
$runs = @()
foreach ($target in @($config.targets)) {
    $targetRoot = Join-Path $batchFolder $target.name
    try {
        $arguments = @{ ServerInstance = $target.serverInstance; Environment = $target.environment; TargetSsisVersion = $target.targetSsisVersion; OutputRoot = $targetRoot; WorkbookFolder = $config.workbookFolder }
        if ($TrustServerCertificate) { $arguments.TrustServerCertificate = $true }
        & $assessment @arguments
        $run = @(Get-ChildItem -LiteralPath $targetRoot -Directory -Filter 'SSISASSESS_*' | Sort-Object LastWriteTime | Select-Object -Last 1)[0]
        if (-not $run -or -not (Test-Path -LiteralPath (Join-Path $run.FullName 'assessment_manifest.json'))) { throw 'Assessment did not produce a validated manifest.' }
        $manifest = Get-Content -LiteralPath (Join-Path $run.FullName 'assessment_manifest.json') -Raw | ConvertFrom-Json
        $runs += [PSCustomObject]@{ Name=$target.name; Environment=$target.environment; Required=[bool]$target.required; Status='Succeeded'; RunFolder=$run.FullName; Packages=$manifest.Counts.Packages; Errors=$manifest.Counts.Errors; Message='' }
    } catch { $runs += [PSCustomObject]@{ Name=$target.name; Environment=$target.environment; Required=[bool]$target.required; Status='Failed'; RunFolder=''; Packages=0; Errors=0; Message=$_.Exception.Message } }
}
$runs | Export-Csv -LiteralPath (Join-Path $batchFolder 'batch-summary.csv') -NoTypeInformation -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $batchFolder 'batch-summary.json'), ($runs | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
$blocking = @($runs | Where-Object { $_.Required -and $_.Environment -eq 'Production' -and ($_.Status -ne 'Succeeded' -or [int]$_.Errors -gt 0) })
$markdown = "# SSIS assessment batch`n`n| Target | Environment | Status | Packages | Errors |`n|---|---|---|---:|---:|`n" + (($runs | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f $_.Name,$_.Environment,$_.Status,$_.Packages,$_.Errors }) -join "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $batchFolder 'batch-summary.md'), $markdown, (New-Object System.Text.UTF8Encoding($false)))
$delta = @()
if ($BaselineBatchFolder) {
    $baselinePath = Join-Path $BaselineBatchFolder 'batch-summary.json'
    if (-not (Test-Path -LiteralPath $baselinePath)) { throw "Baseline batch summary was not found: $baselinePath" }
    $baseline = @(Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json)
    foreach ($result in $runs) {
        $previous = @($baseline | Where-Object Name -eq $result.Name | Select-Object -First 1)
        $delta += [PSCustomObject]@{ Target=$result.Name; PreviousPackages=$(if($previous){$previous[0].Packages}else{0}); CurrentPackages=$result.Packages; PreviousErrors=$(if($previous){$previous[0].Errors}else{0}); CurrentErrors=$result.Errors }
    }
}
$deltaMarkdown = "# SSIS assessment batch delta`n`n| Target | Previous packages | Current packages | Previous errors | Current errors |`n|---|---:|---:|---:|---:|`n" + (($delta | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f $_.Target,$_.PreviousPackages,$_.CurrentPackages,$_.PreviousErrors,$_.CurrentErrors }) -join "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $batchFolder 'batch-delta.md'), $deltaMarkdown, (New-Object System.Text.UTF8Encoding($false)))
if ($blocking.Count) { throw "Batch failed: required Production target(s) had assessment errors or did not complete. See $batchFolder" }
Write-Host "Batch complete: $batchFolder"
