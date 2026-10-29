#Requires -Version 5.1
<#
.SYNOPSIS
    Converts a versioned SSIS assessment run into a deterministic migration backlog.

.DESCRIPTION
    Reads assessment_manifest.json and package_assessment.json from one assessment run. It writes local
    CSV, Markdown, and JSON triage artifacts only; it does not create tickets, modify assessment results,
    or connect to a server. An optional baseline run identifies package additions, removals, route changes,
    and complexity changes.

.NOTES
    Version : 1.0.0
    Compat  : Windows PowerShell 5.1 and PowerShell 7.x.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssessmentRunFolder,
    [string]$BaselineRunFolder,
    [string]$OutputFolder,
    [ValidateRange(1, 24)][int]$RetentionReviewMonths = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file was not found: $Path" }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Could not read JSON file '$Path': $($_.Exception.Message)" }
}

function Get-JsonArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [array]) { return @($Value) }
    return @($Value)
}

function Assert-AssessmentRun {
    param([Parameter(Mandatory)][string]$Folder)
    $manifestPath = Join-Path $Folder 'assessment_manifest.json'
    $packagesPath = Join-Path $Folder 'package_assessment.json'
    $manifest = Read-JsonFile -Path $manifestPath
    if ($manifest.SchemaVersion -ne '1.0') { throw "Unsupported assessment schema version '$($manifest.SchemaVersion)' in $manifestPath. Expected 1.0." }
    $packages = @(Get-JsonArray (Read-JsonFile -Path $packagesPath))
    foreach ($package in $packages) {
        if (-not $package.PackageKey -or -not $package.EffectiveRoute) {
            throw "Package assessment JSON in '$packagesPath' is missing PackageKey or EffectiveRoute."
        }
    }
    [PSCustomObject]@{ Manifest = $manifest; Packages = $packages }
}

function Get-Complexity {
    param([Parameter(Mandatory)]$Package)
    if ($Package.ParseStatus -ne 'Parsed') { return [PSCustomObject]@{ Score = 'TBD'; Band = 'TBD' } }
    $score = [int]$Package.TaskCount + [int]$Package.DataFlowComponents +
             (3 * ([int]$Package.ScriptTasks + [int]$Package.ScriptComponents)) +
             [int]$Package.EventHandlers + [int]$Package.ErrorRowRedirects + [int]$Package.OpaqueSqlStatements
    if ([bool]$Package.TransactionsRequired) { $score += 2 }
    if ([bool]$Package.CheckpointsEnabled) { $score += 2 }
    $band = if ($score -le 5) { 'S' } elseif ($score -le 15) { 'M' } elseif ($score -le 40) { 'L' } else { 'XL' }
    [PSCustomObject]@{ Score = $score; Band = $band }
}

function Get-MigrationDisposition {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)]$Complexity, [bool]$HasAssessmentError)
    $isMigrating = if ($Package.SourceType -eq 'SSISDB' -and [int]$Package.Executions -eq 0) { 'Review' } else { 'Yes' }
    if ($HasAssessmentError -or $Package.ParseStatus -ne 'Parsed' -or $Package.EffectiveRoute -eq 'ReviewRequired') {
        return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'Investigation'; Priority = 'P1'; ReadyForMigration = $false }
    }
    if ($isMigrating -eq 'Review') {
        return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'Business review'; Priority = 'P1'; ReadyForMigration = $false }
    }
    switch ($Package.EffectiveRoute) {
        'AdfNative-Low'    { return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'First migration wave'; Priority = 'P1'; ReadyForMigration = $true } }
        'AdfNative-Medium' { return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'Design and discovery'; Priority = 'P2'; ReadyForMigration = $true } }
        'KeepOnSsisVm'     { return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'Retention register'; Priority = 'P3'; ReadyForMigration = $false } }
        'Remediate2025'    { return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'Remediation'; Priority = 'P1'; ReadyForMigration = $false } }
        default            { return [PSCustomObject]@{ IsMigrating = $isMigrating; Queue = 'Investigation'; Priority = 'P1'; ReadyForMigration = $false } }
    }
}

$assessment = Assert-AssessmentRun -Folder $AssessmentRunFolder
if (-not $OutputFolder) { $OutputFolder = Join-Path $AssessmentRunFolder 'triage' }
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

$baseline = if ($BaselineRunFolder) { Assert-AssessmentRun -Folder $BaselineRunFolder } else { $null }
$baselineByKey = @{}
if ($baseline) {
    foreach ($package in $baseline.Packages) { $baselineByKey[$package.PackageKey] = $package }
}

$errorsPath = Join-Path $AssessmentRunFolder 'errors.csv'
$assessmentErrors = @(
    if (Test-Path -LiteralPath $errorsPath) { Import-Csv -LiteralPath $errorsPath }
)
$seenKeys = New-Object System.Collections.Generic.HashSet[string]
$rows = @(foreach ($package in ($assessment.Packages | Sort-Object PackageKey)) {
    if (-not $seenKeys.Add([string]$package.PackageKey)) { throw "Duplicate PackageKey '$($package.PackageKey)' in $AssessmentRunFolder." }
    $complexity = Get-Complexity -Package $package
    $hasAssessmentError = @($assessmentErrors | Where-Object {
        $_.ServerInstance -eq $package.ServerInstance -and $_.Object -eq $package.Package
    }).Count -gt 0
    $disposition = Get-MigrationDisposition -Package $package -Complexity $complexity -HasAssessmentError $hasAssessmentError
    $baselinePackage = if ($baselineByKey.ContainsKey($package.PackageKey)) { $baselineByKey[$package.PackageKey] } else { $null }
    $changeType = if (-not $baseline) { 'No baseline' }
                  elseif (-not $baselinePackage) { 'Added' }
                  elseif ($baselinePackage.EffectiveRoute -ne $package.EffectiveRoute) { 'Route changed' }
                  elseif ((Get-Complexity -Package $baselinePackage).Band -ne $complexity.Band) { 'Complexity band changed' }
                  else { 'Unchanged' }
    [PSCustomObject][ordered]@{
        PackageKey = $package.PackageKey
        Environment = $package.Environment
        SourceServerName = $package.SourceServerName
        SourceType = $package.SourceType
        Folder = $package.Folder
        Project = $package.Project
        Package = $package.Package
        EffectiveRoute = $package.EffectiveRoute
        ComplexityScore = $complexity.Score
        ComplexityBand = $complexity.Band
        IsMigrating = $disposition.IsMigrating
        Queue = $disposition.Queue
        Priority = $disposition.Priority
        ReadyForMigration = $disposition.ReadyForMigration
        ChangeType = $changeType
        HasAssessmentError = $hasAssessmentError
        DecisionDrivers = $package.RouteReasons
        DependsOn = $package.ChildPackages
        BaselineRoute = $(if ($baselinePackage) { $baselinePackage.EffectiveRoute } else { '' })
        RetentionReviewDue = $(if ($disposition.Queue -eq 'Retention register') { (Get-Date).Date.AddMonths($RetentionReviewMonths).ToString('yyyy-MM-dd') } else { '' })
    }
})

$removed = @()
if ($baseline) {
    $currentKeys = @{}; foreach ($row in $rows) { $currentKeys[$row.PackageKey] = $true }
    $removed = @($baseline.Packages | Where-Object { -not $currentKeys.ContainsKey($_.PackageKey) } | ForEach-Object {
        [PSCustomObject]@{ PackageKey = $_.PackageKey; ChangeType = 'Removed'; BaselineRoute = $_.EffectiveRoute }
    })
}

$backlogPath = Join-Path $OutputFolder 'migration-backlog.csv'
$summaryPath = Join-Path $OutputFolder 'triage-summary.json'
$changesPath = Join-Path $OutputFolder 'route-changes.md'
$retentionPath = Join-Path $OutputFolder 'retention-register.md'
$markdownPath = Join-Path $OutputFolder 'migration-backlog.md'
$rows | Export-Csv -LiteralPath $backlogPath -NoTypeInformation -Encoding UTF8

$routeChanges = @($rows | Where-Object ChangeType -eq 'Route changed')
$addedPackages = @($rows | Where-Object ChangeType -eq 'Added')
$summary = [PSCustomObject][ordered]@{
    SchemaVersion = '1.0'
    AssessmentRunId = $assessment.Manifest.RunId
    BaselineRunId = $(if ($baseline) { $baseline.Manifest.RunId } else { $null })
    Packages = $rows.Count
    AssessmentErrors = $assessmentErrors.Count
    Queues = @($rows | Group-Object Queue | Sort-Object Name | ForEach-Object { [PSCustomObject]@{ Queue = $_.Name; Packages = $_.Count } })
    RouteChanges = $routeChanges.Count
    AddedPackages = $addedPackages.Count
    RemovedPackages = $removed.Count
}
[IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$markdown = @(
    '# SSIS migration backlog'
    ''
    "Assessment run: ``$($assessment.Manifest.RunId)``"
    $(if ($baseline) { "Baseline run: ``$($baseline.Manifest.RunId)``" } else { 'Baseline run: none' })
    ''
    '| Queue | Packages |'
    '|---|---:|'
    @($summary.Queues | ForEach-Object { '| {0} | {1} |' -f $_.Queue, $_.Packages })
    ''
    '| Priority | Package | Route | Complexity | Change |'
    '|---|---|---|---|---|'
    @($rows | Sort-Object Priority, Queue, PackageKey | ForEach-Object { '| {0} | `{1}` | {2} | {3} | {4} |' -f $_.Priority, $_.PackageKey, $_.EffectiveRoute, $_.ComplexityBand, $_.ChangeType })
) -join [Environment]::NewLine
[IO.File]::WriteAllText($markdownPath, $markdown + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

$changes = @(
    '# Assessment changes'
    ''
    '| Change | Package key | Previous route | Current route |'
    '|---|---|---|---|'
    @($rows | Where-Object ChangeType -ne 'Unchanged' | ForEach-Object { '| {0} | `{1}` | {2} | {3} |' -f $_.ChangeType, $_.PackageKey, $_.BaselineRoute, $_.EffectiveRoute })
    @($removed | ForEach-Object { '| Removed | `{0}` | {1} |  |' -f $_.PackageKey, $_.BaselineRoute })
) -join [Environment]::NewLine
[IO.File]::WriteAllText($changesPath, $changes + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

$retention = @(
    '# SSIS retention register'
    ''
    '| Package key | Route | Decision drivers | Review due |'
    '|---|---|---|---|'
    @($rows | Where-Object Queue -eq 'Retention register' | ForEach-Object { '| `{0}` | {1} | {2} | {3} |' -f $_.PackageKey, $_.EffectiveRoute, $_.DecisionDrivers, $_.RetentionReviewDue })
) -join [Environment]::NewLine
[IO.File]::WriteAllText($retentionPath, $retention + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Migration backlog: $backlogPath"
Write-Host "Triage summary: $summaryPath"
