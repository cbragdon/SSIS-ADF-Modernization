#Requires -Version 5.1
<#
.SYNOPSIS
    Produces a factual review report from a read-only Query Store evidence folder.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceFolder, [string]$OutputPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $EvidenceFolder 'evidence-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Evidence manifest was not found: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.SchemaVersion -ne '1.0' -or -not $manifest.ReadOnly) { throw 'Evidence manifest is not a supported read-only Query Store bundle.' }
$plans = @(Import-Csv -LiteralPath (Join-Path $EvidenceFolder 'plans.csv'))
$runtime = @(Import-Csv -LiteralPath (Join-Path $EvidenceFolder 'runtime.csv'))
if (-not $OutputPath) { $OutputPath = Join-Path $EvidenceFolder 'investigation-report.md' }
$text = @(
    '# Query Store investigation report'
    ''
    "Procedure: ``$($manifest.Database).$($manifest.Procedure)``"
    "Evidence window (UTC): $($manifest.StartUtc) to $($manifest.EndUtc)"
    ''
    '## Observed evidence'
    ''
    "* Query Store queries: $($manifest.QueryCount)"
    "* Captured plans: $($plans.Count)"
    "* Runtime-stat rows: $($runtime.Count)"
    "* Forced plans: $(@($plans | Where-Object is_forced_plan -eq 'True').Count)"
    ''
    '## Interpretation boundary'
    ''
    'This report records collected evidence only. Use the `query-plan-analysis` skill with the saved `.sqlplan` files before concluding why a procedure is slow. Recommendations must state observed facts, confidence, risk, rollback, validation, and DBA approval requirements.'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($OutputPath, $text + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Investigation report: $OutputPath"
