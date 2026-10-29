#Requires -Version 5.1
<#
.SYNOPSIS
    Collects read-only Query Store evidence for a stored procedure without executing it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$Procedure,
    [Parameter(Mandatory)][datetime]$StartUtc,
    [Parameter(Mandatory)][datetime]$EndUtc,
    [Parameter(Mandatory)][string]$OutputRoot,
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [ValidateRange(30, 7200)][int]$CommandTimeoutSeconds = 300
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($EndUtc -le $StartUtc) { throw '-EndUtc must be later than -StartUtc.' }
$run = Join-Path $OutputRoot ('QUERYSTORE_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$builder.DataSource = $ServerInstance; $builder.InitialCatalog = $Database; $builder.ApplicationIntent = 'ReadOnly'
$builder.ApplicationName = 'SSIS-ADF-QueryStoreEvidence'; $builder.Encrypt = $true; $builder.TrustServerCertificate = [bool]$TrustServerCertificate
if ($SqlCredential) { $builder.UserID = $SqlCredential.UserName; $builder.Password = $SqlCredential.GetNetworkCredential().Password } else { $builder.IntegratedSecurity = $true }
$connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
function Invoke-ReadOnlyQuery {
    param([string]$Query, [hashtable]$Parameters = @())
    $command = $connection.CreateCommand(); $command.CommandText = $Query; $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($name in $Parameters.Keys) { $parameter = $command.Parameters.Add($name, [System.Data.SqlDbType]::NVarChar); $parameter.Value = $Parameters[$name] }
    $table = New-Object System.Data.DataTable; $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command; [void]$adapter.Fill($table); $table
}
try {
    $connection.Open()
    $metadata = Invoke-ReadOnlyQuery -Query @'
SELECT DB_NAME() AS DatabaseName, SERVERPROPERTY('ProductVersion') AS ProductVersion,
       DATABASEPROPERTYEX(DB_NAME(), 'CompatibilityLevel') AS CompatibilityLevel,
       OBJECT_ID(@Procedure) AS ObjectId
'@ -Parameters @{ '@Procedure' = $Procedure }
    if ($metadata.Rows.Count -ne 1 -or $null -eq $metadata.Rows[0].ObjectId) { throw "Procedure '$Procedure' was not found in database '$Database'." }
    $objectId = [int]$metadata.Rows[0].ObjectId
    $queries = Invoke-ReadOnlyQuery -Query @'
SELECT q.query_id, q.object_id, qt.query_sql_text
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE q.object_id = @ObjectId
'@ -Parameters @{ '@ObjectId' = "$objectId" }
    $plans = Invoke-ReadOnlyQuery -Query @'
SELECT q.query_id, p.plan_id, p.is_forced_plan, p.force_failure_count, p.last_force_failure_reason_desc, CONVERT(nvarchar(max), p.query_plan) AS query_plan
FROM sys.query_store_query AS q JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
WHERE q.object_id = @ObjectId
'@ -Parameters @{ '@ObjectId' = "$objectId" }
    $runtime = Invoke-ReadOnlyQuery -Query @'
SELECT q.query_id, p.plan_id, i.start_time, i.end_time, rs.count_executions,
       rs.avg_duration, rs.avg_cpu_time, rs.avg_logical_io_reads, rs.avg_logical_io_writes
FROM sys.query_store_query AS q
JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE q.object_id = @ObjectId AND i.start_time >= @StartUtc AND i.end_time <= @EndUtc
'@ -Parameters @{ '@ObjectId' = "$objectId"; '@StartUtc' = $StartUtc.ToString('o'); '@EndUtc' = $EndUtc.ToString('o') }
    foreach ($item in @(@{Name='metadata';Table=$metadata},@{Name='queries';Table=$queries},@{Name='plans';Table=$plans},@{Name='runtime';Table=$runtime})) {
        $item.Table | Export-Csv -LiteralPath (Join-Path $run ($item.Name + '.csv')) -NoTypeInformation -Encoding UTF8
    }
    foreach ($plan in $plans.Rows) { [IO.File]::WriteAllText((Join-Path $run ("plan_{0}.sqlplan" -f $plan.plan_id)), [string]$plan.query_plan, (New-Object System.Text.UTF8Encoding($false))) }
    $manifest = [PSCustomObject]@{ SchemaVersion='1.0'; ServerInstance=$ServerInstance; Database=$Database; Procedure=$Procedure; StartUtc=$StartUtc.ToString('o'); EndUtc=$EndUtc.ToString('o'); QueryCount=$queries.Rows.Count; PlanCount=$plans.Rows.Count; RuntimeRows=$runtime.Rows.Count; ReadOnly=$true }
    [IO.File]::WriteAllText((Join-Path $run 'evidence-manifest.json'), ($manifest | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Evidence collected: $run"
} finally { if ($connection) { $connection.Dispose() } }
