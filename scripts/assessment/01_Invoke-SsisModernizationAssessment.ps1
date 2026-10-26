#Requires -Version 5.1
<#
.SYNOPSIS
    SSIS modernization assessment: classifies every SSIS package into the routing targets defined in the
    "Decision Request: ETL Platform - Azure Data Factory vs. SSIS on SQL Server VM" document.

.DESCRIPTION
    WHAT THIS SCRIPT DOES
    ---------------------
    1. Discovers SSIS packages from up to three sources:
         a. SSISDB catalog (project deployment model)      -> every project exported with catalog.get_project
         b. msdb package store (package deployment model)  -> msdb.dbo.sysssispackages        (-IncludeMsdbPackages)
         c. File system / source control                    -> *.dtsx and *.ispac under folders (-PackageFolder)
    2. Parses the real package XML (.dtsx) and project connection managers (.conmgr). Task types,
       data flow components and connection types exist ONLY in the package XML; the SSISDB catalog views
       (catalog.packages, catalog.executables) do not contain them. catalog.executables is execution-scoped
       and holds task NAMES, not task TYPES, which is why the previous script could not work.
    3. Matches every task, container enumerator, data flow component and connection manager against an
       explicit, editable rule table ($RuleTable below). Every match is written to an evidence CSV, so each
       routing decision can be traced back to the exact XML element that caused it.
    4. Assigns each package a route using a fixed precedence (highest wins):
           5  ReviewRequired    - package could not be parsed (encrypted, legacy format, corrupt)
           4  Remediate2025     - uses a component REMOVED/DISCONTINUED in SQL Server 2025 SSIS
                                  (only when -TargetSsisVersion is 2025; otherwise reported as a future risk)
           3  KeepOnSsisVm      - needs the SSIS runtime: Script Task/Component, third-party/unknown components,
                                  Excel destination, fuzzy/term transforms, WMI, MSMQ, transfer tasks, etc.
           2  AdfNative-Medium  - rebuildable in ADF but needs Mapping Data Flows, a Self-hosted IR
                                  (Windows auth, file shares, ODBC), or orchestration rework
           1  AdfNative-Low     - Copy activity / Script or Stored Procedure activity equivalents only
       Every rule that fired is listed (RouteReasons) - rules accumulate, they never overwrite each other.
       Package properties are evaluated too: distributed transactions, checkpoints, package configurations
       (package deployment model), error-row redirection in data flows, and connection strings whose
       expression resolves to a local or UNC path. Connections used only by log providers are reported
       but never raise the route. Tasks inside a disabled container are treated as disabled.
    5. Rolls child package routes up to parents (Execute Package Task), so a parent cannot look easier
       than the children it runs (EffectiveRoute). A child that cannot be resolved (external file/msdb
       reference) makes the parent's EffectiveRoute ReviewRequired: an unknown child is never assumed easy.
    6. Enriches with run history from catalog.executions (run count, failures, last run, average duration)
       and optionally SQL Agent job steps (which jobs run each package and their schedules, 32-bit /X86
       execution - deprecated in SQL Server 2025).
    7. Writes timestamped CSVs plus a transcript log. Nothing is overwritten between runs.
    8. Writes a sprint backlog for developers and business units: sprint_backlog.csv (all servers) in the run
       folder, plus one workbook per source server, <ServerName>_SSIS_Migration_Assessment_<yyyyMMdd_HHmmss>.xlsx,
       in -WorkbookFolder:
       one row per package with its target platform, the work it implies, a complexity band, the order to
       build it in (children before parents) and blank Owner / Sprint / Status columns. The workbook needs
       neither Excel nor the ImportExcel module on the assessment host.

    ROUTES MAPPED TO THE DECISION DOCUMENT OPTIONS
    ----------------------------------------------
        AdfNative-Low / AdfNative-Medium -> Option C work items (rewrite into ADF native)
        KeepOnSsisVm                     -> Option D legacy path (SSIS on SQL Server VM, orchestrated by ADF)
        Remediate2025                    -> Fix, pin the SSIS host to SQL Server 2022, or move to ADF first
        AzureSsisIrFit column            -> Option B suitability, reported separately for every package

    SQL SERVER VERSION COVERAGE
    ---------------------------
    Source servers SQL Server 2016 - 2025. catalog.get_project, catalog.executions and sysssispackages
    exist in all of these versions. Packages built for SSIS 2016-2025 use PackageFormatVersion 8.
    Format 6 (SSIS 2012/2014) is parsed the same way. Format 3 and earlier (SSIS 2008 R2 and older)
    is flagged ReviewRequired - upgrade those packages first.

    SAFETY / GUARDRAILS
    -------------------
    * READ-ONLY. The script issues SELECT statements and EXEC SSISDB.catalog.get_project only.
      It never deploys, executes, alters or deletes anything on any server.
    * Encryption is ON by default (Encrypt=True). Use -TrustServerCertificate for self-signed certs.
    * Rule matching is pattern-based on documented SSIS type identifiers. Anything unrecognised is NOT
      assumed easy: it is routed KeepOnSsisVm with "Unrecognized - verify", the opposite of the old script.

    REQUIRED PERMISSIONS
    --------------------
    * SSISDB: ssis_admin (recommended) or READ on every project. SSISDB enforces row-level security:
      a login without READ on a project simply does not see it, with NO error. The script warns when the
      login is neither ssis_admin nor sysadmin, because results may then be silently incomplete.
    * msdb (optional switches): db_ssisoperator (or db_ssisadmin) for packages; SQLAgentReaderRole for jobs.

.PARAMETER ServerInstance
    One or more SQL Server instances hosting SSISDB / msdb (e.g. <SsisProdServer>, HOST\INSTANCE, HOST,1433).
    Each server gets its own workbook. A comma-separated string also works (powershell.exe -File passes
    "-ServerInstance A,B" as one string); a number after a comma is read as a port (HOST,1433). A name that
    turns out to be a server already assessed in the run (same @@SERVERNAME) is skipped with a warning.

.PARAMETER Environment
    Label written to every output row for -ServerInstance targets (Development, Testing, Staging, Production).

.PARAMETER ServerListPath
    CSV listing many servers. Columns: ServerInstance (required), Environment, TargetSsisVersion (both optional).
    Example rows:
        ServerInstance,Environment,TargetSsisVersion
        <SsisProdServer>,Production,2025
        <SsisDevServer>,Development,2022

.PARAMETER PackageFolder
    One or more folders scanned recursively for *.dtsx and *.ispac (file-system deployments, source control,
    or exported projects). Can be used with no server at all for fully offline assessment.

.PARAMETER TargetSsisVersion
    SSIS host version the packages are expected to run on: 2016, 2017, 2019, 2022 or 2025 (default 2025).
    Drives whether SQL Server 2025 removals are blockers (2025) or reported as future risk (older).
    A per-server value in -ServerListPath overrides this.

.PARAMETER OutputRoot
    Root folder for output. A timestamped run folder is created beneath it. Default C:\Temp\SSIS_ADF_Assessment.

.PARAMETER WorkbookFolder
    Folder for the per-server workbooks (<ServerName>_SSIS_Migration_Assessment_<yyyyMMdd_HHmmss>.xlsx).
    Created, and the creation logged, if it does not exist. Default: the run folder. <ServerName> is the name
    the server reports (@@SERVERNAME) with '\' and other characters not allowed in file names replaced by '_';
    packages read from -PackageFolder go into one FileSystem_... workbook.

.PARAMETER IncludeMsdbPackages
    Also assess packages stored in msdb (package deployment model). These are additionally flagged as
    depending on the legacy Integration Services Service, which is deprecated in SQL Server 2025.

.PARAMETER IncludeAgentJobs
    Read SQL Agent SSIS job steps to report which jobs run each package (AgentJobs), when those jobs are
    scheduled to run (AgentSchedules, e.g. "DBA ETL: Daily at 01:00"), and detect 32-bit (/X86) execution
    (Uses32BitJobStep).

.PARAMETER HistoryDays
    Days of catalog.executions history to summarise (default 90). Bounded by SSISDB retention settings.

.PARAMETER SqlCredential
    SQL authentication credential. Omit to use Windows integrated authentication (default).

.PARAMETER TrustServerCertificate
    Trust the server certificate without validation (needed for self-signed certificates on VMs).

.PARAMETER DisableEncryption
    Connect with Encrypt=False. Not recommended; provided for legacy instances without TLS configured.

.PARAMETER CommandTimeoutSeconds
    Timeout for each SQL command, including project export (default 300).

.OUTPUTS
    <OutputRoot>\<RunId>\
        package_assessment.csv  - one row per package: route, reasons, counts, run history, Azure-SSIS IR fit
        evidence_items.csv      - one row per task / component / connection / enumerator matched by a rule
        connections.csv         - every connection manager (package and project level) with risk flags
        agent_job_steps.csv     - SSIS Agent job steps (-IncludeAgentJobs)
        errors.csv              - every non-fatal failure (server, project, package, message)
        route_summary.csv       - package counts per environment and route
        sprint_backlog.csv      - one planning row per package: TargetPlatform, WorkType, ComplexityBand, BuildOrder,
                                  DecisionDrivers, usage, and blank BusinessOwner / Developer / Sprint / Status columns
        transcript.log          - full PowerShell transcript of the run, including each server's start and completion time
    <WorkbookFolder>\ (default: the run folder)
        <ServerName>_SSIS_Migration_Assessment_<yyyyMMdd_HHmmss>.xlsx
                                - one per source server: Summary, Backlog, one sheet per platform, Legend

.EXAMPLE
    # Two servers, one workbook each, written to a shared folder (created if missing)
    .\01_Invoke-SsisModernizationAssessment.ps1 -ServerInstance <SsisProdServer>, <SsisDevServer> `
        -WorkbookFolder 'D:\Assessment\Workbooks' -TrustServerCertificate

.EXAMPLE
    # Single Production server, SQL Server 2025 target host, self-signed certificate on the VM
    .\01_Invoke-SsisModernizationAssessment.ps1 -ServerInstance <SsisProdServer> -Environment Production `
        -TrustServerCertificate -IncludeAgentJobs

.EXAMPLE
    # All environments from a server list, including legacy msdb packages
    .\01_Invoke-SsisModernizationAssessment.ps1 -ServerListPath C:\Temp\ssis_servers.csv `
        -IncludeMsdbPackages -IncludeAgentJobs -TrustServerCertificate

.EXAMPLE
    # Offline: assess packages straight from a source-control working folder, targeting a 2022 host
    .\01_Invoke-SsisModernizationAssessment.ps1 -PackageFolder 'C:\Repos\ETL\SSIS' -TargetSsisVersion 2022

.NOTES
    Version : 2.6.0
    Purpose : Replaces 01_run_dma_assessment.ps1 (which queried non-existent catalog columns and could not
              determine task types). This script does not use Data Migration Assistant.
    Compat  : Windows PowerShell 5.1 and PowerShell 7.x. No SqlServer module dependency (uses .NET SqlClient).
    Edit the rule table to add organisation-specific third-party components (e.g. KingswaySoft, Task Factory)
    with the route you want them to receive.
#>
[CmdletBinding()]
param(
    [string[]]$ServerInstance,
    [string]$Environment = 'Unspecified',
    [string]$ServerListPath,
    [string[]]$PackageFolder,
    [ValidateSet('2016', '2017', '2019', '2022', '2025')]
    [string]$TargetSsisVersion = '2025',
    [string]$OutputRoot = 'C:\Temp\SSIS_ADF_Assessment',
    [string]$WorkbookFolder,
    [switch]$IncludeMsdbPackages,
    [switch]$IncludeAgentJobs,
    [ValidateRange(1, 3650)]
    [int]$HistoryDays = 90,
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [switch]$DisableEncryption,
    [ValidateRange(30, 7200)]
    [int]$CommandTimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region ============================== 0. RUN SETUP ==============================================

# Validate that at least one package source was supplied.
if (-not $ServerInstance -and -not $ServerListPath -and -not $PackageFolder) {
    throw 'Supply at least one source: -ServerInstance, -ServerListPath or -PackageFolder.'
}

# Every run gets a unique, sortable ID and its own output folder, so runs are comparable and never overwrite.
$RunStart  = Get-Date
$RunStamp  = $RunStart.ToString('yyyyMMdd_HHmmss')
$RunId     = 'SSISASSESS_{0}_{1}' -f $RunStamp, $env:COMPUTERNAME
$RunFolder = Join-Path $OutputRoot $RunId
# Folders that do not exist yet are created and logged (after the transcript starts, so the log records it).
$CreatedFolders = @(foreach ($dir in @($OutputRoot, $WorkbookFolder | Where-Object { $_ })) { if (-not (Test-Path -LiteralPath $dir)) { $dir } })
New-Item -ItemType Directory -Path $RunFolder -Force | Out-Null
if ($WorkbookFolder) { New-Item -ItemType Directory -Path $WorkbookFolder -Force | Out-Null } else { $WorkbookFolder = $RunFolder }
$LogFile   = Join-Path $RunFolder 'transcript.log'
Start-Transcript -Path $LogFile -Force | Out-Null

# Assemblies: ZIP handling for .ispac files (built into PS 7; must be loaded explicitly in 5.1).
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.Data

# The DTS XML namespace used by every .dtsx and .conmgr file since SSIS 2012 (PackageFormatVersion 6+).
$DtsNs = 'www.microsoft.com/SqlServer/Dts'

# Result collections (generic lists: fast appends, PS 5.1 compatible).
$Packages    = New-Object System.Collections.Generic.List[object]   # one object per package
$Evidence    = New-Object System.Collections.Generic.List[object]   # one row per matched XML element
$Connections = New-Object System.Collections.Generic.List[object]   # one row per connection manager
$JobSteps    = New-Object System.Collections.Generic.List[object]   # SSIS Agent job steps
$Errors      = New-Object System.Collections.Generic.List[object]   # non-fatal failures
$SourceServerNames = @{}   # -ServerInstance as given -> @@SERVERNAME reported by that server (read at run time)

function Write-Log {
    <# Structured console + transcript logging. Level drives colour and the prefix used for grepping logs. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )
    $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan' }[$Level]
    Write-Host ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -ForegroundColor $colour
}

function Add-AssessmentError {
    <# Records a non-fatal failure so one bad project or package never stops the whole assessment. #>
    param([string]$Server, [string]$Scope, [string]$Object, [string]$Message)
    $Errors.Add([PSCustomObject]@{
        RunId = $RunId; ServerInstance = $Server; Scope = $Scope; Object = $Object
        Message = $Message; TimeStamp = (Get-Date).ToString('s')
    })
    Write-Log -Level ERROR -Message ('{0} | {1} | {2}: {3}' -f $Server, $Scope, $Object, $Message)
}

Write-Log -Level STEP -Message "SSIS modernization assessment $RunId"
Write-Log -Message "Output folder      : $RunFolder"
Write-Log -Message "Default target host: SQL Server $TargetSsisVersion SSIS"
Write-Log -Message "History window     : $HistoryDays days"
#endregion

#region ============================== 1. ROUTING MODEL AND RULE TABLE ============================

# Route precedence. Higher number wins when several rules fire for one package.
$RouteSeverity = @{
    'AdfNative-Low'    = 1
    'AdfNative-Medium' = 2
    'KeepOnSsisVm'     = 3
    'Remediate2025'    = 4
    'ReviewRequired'   = 5
}
# Human-readable labels tying each route back to the decision document.
$RouteLabel = @{
    'AdfNative-Low'    = 'ADF native - Copy / Script / Stored Procedure activities (Option C, low effort)'
    'AdfNative-Medium' = 'ADF native - Mapping Data Flow, Self-hosted IR or orchestration rework (Option C, medium effort)'
    'KeepOnSsisVm'     = 'Keep on SSIS VM, orchestrated by ADF (Option D legacy path)'
    'Remediate2025'    = 'Remediate before running on a SQL Server 2025 SSIS host'
    'ReviewRequired'   = 'Manual review - package could not be analysed'
}
# Azure-SSIS IR (Option B) fit precedence. Higher wins.
$IrSeverity = @{ 'Compatible' = 1; 'NeedsConfiguration' = 2; 'NeedsCustomSetup' = 3; 'Review' = 4 }

# Sprint backlog (sprint_backlog.csv and the per-server workbooks): the platform each route lands on and the work it implies.
# Order = sort order of the platform sheets in the workbook.
$RoutePlanning = [ordered]@{
    'AdfNative-Low'    = @{ Platform = 'ADF'; Order = 1
                            WorkType = 'Rewrite as an ADF pipeline: Copy, Script and Stored Procedure activities' }
    'AdfNative-Medium' = @{ Platform = 'ADF'; Order = 1
                            WorkType = 'Rewrite as an ADF pipeline: Mapping Data Flow, Self-hosted IR or orchestration rework' }
    'KeepOnSsisVm'     = @{ Platform = 'SSIS VM'; Order = 2
                            WorkType = 'Deploy to the SSIS VM unchanged and orchestrate from ADF' }
    'Remediate2025'    = @{ Platform = 'SSIS VM after remediation'; Order = 3
                            WorkType = 'Replace components removed in SQL Server 2025 (or pin the host to 2022, or rewrite in ADF), then deploy to the SSIS VM' }
    'ReviewRequired'   = @{ Platform = 'Undetermined'; Order = 4
                            WorkType = 'Make the package readable (remove EncryptAll, upgrade the format, resolve the external child), then re-assess' }
}
# ComplexityScore upper bounds per band; above L is XL. The score is a starting point for estimates, not an
# estimate: (enabled tasks) + (data flow components) + 3 x (script tasks + script components) + event handlers
# + error-row redirects + opaque SQL statements + 2 if transactions are required + 2 if checkpoints are on.
$ComplexityBands = [ordered]@{ 'S' = 5; 'M' = 15; 'L' = 40 }
# PackageLocation: where the scan found each package (SourceType -> label shown to readers).
$PackageLocationLabel = [ordered]@{
    'SSISDB'     = 'SSISDB'
    'MSDB'       = 'MSDB'
    'FileSystem' = 'File system'
    'Ispac'      = 'File system (.ispac)'
}
$PackageLocationMeaning = @{
    'SSISDB'     = 'Deployed to the SSIS catalog (SSISDB database) on SourceServerName: project deployment model.'
    'MSDB'       = 'Stored in the msdb database on SourceServerName: legacy package deployment model.'
    'FileSystem' = 'A .dtsx file read from disk (for example a source-control folder) with -Path.'
    'Ispac'      = 'Inside a built project file (.ispac) read from disk with -Path.'
}

<#
    RULE TABLE
    ----------
    Each rule:
      Scope     : Task | Enumerator | Component | Connection - which kind of XML element it applies to
      Pattern   : case-insensitive regex tested against the element's identity string:
                    Task       -> DTS:ExecutableType            e.g. Microsoft.ScriptTask
                    Enumerator -> DTS:ForEachEnumerator CreationName
                    Component  -> componentClassID | UserComponentTypeName (managed components)
                    Connection -> DTS:CreationName | Provider= value from the connection string
                  Type strings may be short (Microsoft.ScriptTask) or assembly-qualified
                  (Microsoft.SqlServer.Dts.Tasks.ScriptTask.ScriptTask, ..., Version=13.0.0.0), so patterns
                  match the distinctive token rather than the full string.
      Name      : canonical name used in reports
      Category  : routing category when the component is usable on the target host
      Lifecycle : '' | Removed2025 | Discontinued2025 | Deprecated2025  (SQL Server 2025 SSIS changes)
      AzureIr   : Compatible | NeedsConfiguration | NeedsCustomSetup | Review - Azure-SSIS IR (Option B) fit
      Note      : explanation written to the evidence file
    FIRST MATCH WINS within a scope, so specific patterns are listed before generic ones.
    Anything matching no rule falls through to the "Unrecognized" defaults in Get-RuleMatch (KeepOnSsisVm).

    SQL Server 2025 SSIS changes encoded below (Microsoft Learn, "What's New in SQL Server 2025 Integration Services"):
      Removed     : Attunity CDC components and CDC Service for Oracle; Microsoft Connector for Oracle;
                    Hadoop Hive / Pig / File System tasks
      Deprecated  : legacy Integration Services Service; 32-bit mode; SqlClient Data Provider (SDS) connection
                    type in maintenance tasks and some Foreach enumerators
      Engine      : Data Quality Services (DQS) discontinued -> DQS Cleansing transformation cannot run
#>
function New-Rule {
    param($Scope, $Pattern, $Name, $Category, $Lifecycle = '', $AzureIr = 'Compatible', $Note = '')
    [PSCustomObject]@{ Scope = $Scope; Pattern = $Pattern; Name = $Name; Category = $Category
                       Lifecycle = $Lifecycle; AzureIr = $AzureIr; Note = $Note }
}

$RuleTable = @(
    # ---------------- Control flow tasks: SQL Server 2025 removals first (most specific) ----------------
    New-Rule Task 'Hadoop.*Hive|HiveTask'              'Hadoop Hive Task'            KeepOnSsisVm 'Removed2025' Review 'Removed in SQL Server 2025 SSIS.'
    New-Rule Task 'Hadoop.*Pig|PigTask'                'Hadoop Pig Task'             KeepOnSsisVm 'Removed2025' Review 'Removed in SQL Server 2025 SSIS.'
    New-Rule Task 'Hadoop.*FileSystem|HDFS'            'Hadoop File System Task'     KeepOnSsisVm 'Removed2025' Review 'Removed in SQL Server 2025 SSIS.'
    New-Rule Task 'CDCControl|Attunity'                'CDC Control Task (Attunity)' KeepOnSsisVm 'Removed2025' Review 'Attunity CDC components removed in SQL Server 2025 SSIS.'
    New-Rule Task 'DbMaint|MaintenancePlan'            'Maintenance Plan Task'       KeepOnSsisVm 'Deprecated2025' NeedsConfiguration 'SDS connection type in maintenance tasks deprecated in SQL Server 2025; verify connection type, move to ADO.NET.'
    # ---------------- Control flow tasks: SSIS-runtime dependent ----------------
    New-Rule Task 'ScriptTask'                         'Script Task'                 KeepOnSsisVm '' Compatible 'Custom .NET code; no ADF equivalent without rewrite (Azure Function / Batch).'
    New-Rule Task 'ExecuteProcess'                     'Execute Process Task'        KeepOnSsisVm '' NeedsCustomSetup 'Runs an executable on the host; executables must be installed on any target runtime.'
    New-Rule Task 'WmiDataReader|WmiEventWatcher|Wmi'  'WMI Task'                    KeepOnSsisVm '' NeedsConfiguration 'Host/OS dependent.'
    New-Rule Task 'MessageQueue|MSMQ'                  'Message Queue Task'          KeepOnSsisVm '' NeedsCustomSetup 'MSMQ dependency.'
    New-Rule Task 'Transfer(Database|Jobs|Logins|ErrorMessages|StoredProcedures|SqlServerObjects|Masterstoredprocedures)' 'Transfer Task' KeepOnSsisVm '' NeedsConfiguration 'SMO-based server object transfer; DBA tooling, not ETL.'
    New-Rule Task 'ASExecuteDDL|DTSProcessingTask|AnalysisServices' 'Analysis Services Task' KeepOnSsisVm '' NeedsConfiguration 'SSAS processing; ADF requires Web activity / Azure Analysis Services REST.'
    New-Rule Task 'DataProfiling'                      'Data Profiling Task'         KeepOnSsisVm '' Compatible 'No direct ADF equivalent.'
    New-Rule Task 'WebServiceTask'                     'Web Service Task'            AdfNative-Medium '' Compatible 'ADF Web activity (SOAP needs payload rework).'
    New-Rule Task 'XMLTask'                            'XML Task'                    KeepOnSsisVm '' Compatible 'XSLT/XPath operations; ADF has no native XSLT.'
    New-Rule Task 'BackupDatabase|CheckDatabaseIntegrity|ShrinkDatabase|ReorganizeIndex|RebuildIndex|UpdateStatistics|HistoryCleanup' 'DBA Maintenance Task' KeepOnSsisVm 'Deprecated2025' NeedsConfiguration 'Maintenance-plan task family; belongs in DBA automation, not ETL.'
    # ---------------- Control flow tasks: ADF-mappable ----------------
    New-Rule Task 'Pipeline'                           'Data Flow Task'              AdfNative-Low '' Compatible 'Route refined by the components inside the data flow.'
    New-Rule Task 'ExecuteSQL'                         'Execute SQL Task'            AdfNative-Low '' Compatible 'ADF Script or Stored Procedure activity.'
    New-Rule Task 'ExecutePackage'                     'Execute Package Task'        AdfNative-Low '' Compatible 'ADF Execute Pipeline; child package route is rolled up separately.'
    New-Rule Task 'ExpressionTask'                     'Expression Task'             AdfNative-Low '' Compatible 'ADF Set Variable activity.'
    New-Rule Task 'BulkInsert'                         'Bulk Insert Task'            AdfNative-Medium '' NeedsConfiguration 'ADF Copy activity; source file path must be reachable (SHIR or storage).'
    New-Rule Task 'FileSystemTask'                     'File System Task'            AdfNative-Medium '' NeedsConfiguration 'ADF Copy/Delete/Get Metadata via Self-hosted IR file system connector.'
    New-Rule Task 'FtpTask'                            'FTP Task'                    AdfNative-Medium '' Compatible 'ADF FTP/SFTP connector.'
    New-Rule Task 'SendMail'                           'Send Mail Task'              AdfNative-Medium '' Compatible 'ADF Web activity to Logic App / Graph API.'
    New-Rule Task 'AzureBlob|AzureDataLake|AzureHD|AzureSqlDW|FlexibleFile|AzureSynapse' 'Azure Feature Pack Task' AdfNative-Low '' Compatible 'Native ADF connector exists.'
    New-Rule Task '^STOCK:SEQUENCE|SequenceContainer|^STOCK:FORLOOP|ForLoop' 'Sequence / For Loop Container' AdfNative-Low '' Compatible 'ADF activity grouping / Until activity.'
    New-Rule Task '^STOCK:FOREACHLOOP|ForEachLoop'     'Foreach Loop Container'      AdfNative-Low '' Compatible 'ADF ForEach; enumerator evaluated separately.'

    # ---------------- Foreach enumerators ----------------
    New-Rule Enumerator 'Hdfs|Hadoop'                  'Foreach HDFS File Enumerator' KeepOnSsisVm 'Removed2025' Review 'Hadoop components removed in SQL Server 2025 SSIS.'
    New-Rule Enumerator 'SMO'                          'Foreach SMO Enumerator'      KeepOnSsisVm 'Deprecated2025' NeedsConfiguration 'SDS connection type in some Foreach enumerators deprecated in SQL Server 2025; verify.'
    New-Rule Enumerator 'File'                         'Foreach File Enumerator'     AdfNative-Medium '' NeedsConfiguration 'ADF Get Metadata + ForEach; Self-hosted IR for file shares.'
    New-Rule Enumerator 'ADO|SchemaRowset|Item|Variable|NodeList|FromVar|AzureBlob|DataLake' 'Foreach ADO/Item/Variable/NodeList Enumerator' AdfNative-Medium '' Compatible 'ADF Lookup + ForEach.'

    # ---------------- Data flow components: SQL Server 2025 removals / discontinued ----------------
    New-Rule Component 'CDCSrc|CdcSource'              'CDC Source (Attunity)'       KeepOnSsisVm 'Removed2025' Review 'Removed in SQL Server 2025 SSIS.'
    New-Rule Component 'CDCSplit|CdcSplitter'          'CDC Splitter (Attunity)'     KeepOnSsisVm 'Removed2025' Review 'Removed in SQL Server 2025 SSIS.'
    New-Rule Component 'Oracle'                        'Oracle Source/Destination (Microsoft Connector for Oracle)' AdfNative-Medium 'Removed2025' Review 'Microsoft Connector for Oracle removed in SQL Server 2025 SSIS; ADF Oracle connector via SHIR is the replacement path.'
    New-Rule Component 'Ssdqs|DataCorrection|DQS'      'DQS Cleansing'               KeepOnSsisVm 'Discontinued2025' Review 'DQS discontinued in SQL Server 2025; no DQS server to call.'
    # ---------------- Data flow components: SSIS-runtime dependent ----------------
    New-Rule Component 'ScriptComponent'               'Script Component'            KeepOnSsisVm '' Compatible 'Custom .NET code inside the data flow.'
    New-Rule Component 'ExcelDestination'              'Excel Destination'           KeepOnSsisVm '' NeedsCustomSetup 'ADF cannot write Excel; ACE driver required on runtime.'
    New-Rule Component 'FuzzyLookup|FuzzyGrouping'     'Fuzzy Lookup/Grouping'       KeepOnSsisVm '' Compatible 'No ADF equivalent.'
    New-Rule Component 'TermExtraction|TermLookup'     'Term Extraction/Lookup'      KeepOnSsisVm '' Compatible 'No ADF equivalent.'
    New-Rule Component 'DataMining|DMQuery'            'Data Mining Query'           KeepOnSsisVm '' Compatible 'SSAS data mining dependency.'
    New-Rule Component 'Extractor|Injector'            'Export/Import Column'        KeepOnSsisVm '' NeedsConfiguration 'Row-level file I/O (BLOBs to files).'
    New-Rule Component 'BalancedDataDistributor'       'Balanced Data Distributor'   KeepOnSsisVm '' Compatible 'Parallelism construct with no ADF equivalent.'
    New-Rule Component 'RecordsetDestination|DataReaderDest' 'Recordset/DataReader Destination' KeepOnSsisVm '' Compatible 'In-memory object variable consumed by later tasks.'
    # ---------------- Data flow components: ADF Mapping Data Flow equivalents ----------------
    New-Rule Component 'OLEDBCommand'                  'OLE DB Command'              AdfNative-Medium '' Compatible 'Row-by-row SQL; redesign as set-based (staging + Stored Procedure activity).'
    New-Rule Component '\.SCD|SlowlyChanging'          'Slowly Changing Dimension'   AdfNative-Medium '' Compatible 'Rebuild with Data Flow Alter Row or set-based MERGE.'
    New-Rule Component 'Lookup|MergeJoin|\.Merge(\||$)|\.Sort|Aggregate|ConditionalSplit|DerivedColumn|Multicast|UnionAll|CharacterMap|CopyMap|Pivot|UnPivot|PctSampling|RowSampling|Lineage|\.Cache|XmlSource' 'Transformation (Data Flow mappable)' AdfNative-Medium '' Compatible 'ADF Mapping Data Flow equivalent, or push down to SQL.'
    New-Rule Component 'RawSource|RawDestination'      'Raw File Source/Destination' AdfNative-Medium '' Compatible 'SSIS-proprietary Raw format; ADF cannot read or write it. Replace the staging hand-off with Parquet/Delta in storage or a staging table.'
    # ---------------- Data flow components: ADF Copy activity equivalents ----------------
    New-Rule Component 'ExcelSource'                   'Excel Source'                AdfNative-Medium '' NeedsCustomSetup 'ADF Excel connector (read-only); file must be reachable.'
    New-Rule Component 'DataConvert|RowCount'          'Data Conversion / Row Count' AdfNative-Low '' Compatible 'Copy activity type mapping / rows copied output.'
    New-Rule Component 'OLEDBSource|OLEDBDestination|ADONETDestination|DataReaderSource|SSISODBC|FlatFile|SQLServerDestination|Azure|FlexibleFile' 'Source/Destination adapter' AdfNative-Low '' Compatible 'ADF Copy activity source/sink.'

    # ---------------- Connection managers ----------------
    New-Rule Connection '^MSORA|^ORACLE'               'Oracle (Microsoft Connector for Oracle)' AdfNative-Medium 'Removed2025' Review 'Microsoft Connector for Oracle removed in SQL Server 2025 SSIS; verify provider.'
    New-Rule Connection '^DQS'                         'DQS'                         KeepOnSsisVm 'Discontinued2025' Review 'DQS discontinued in SQL Server 2025.'
    New-Rule Connection 'Hadoop|HDFS'                  'Hadoop'                      KeepOnSsisVm 'Removed2025' Review 'Hadoop components removed in SQL Server 2025 SSIS.'
    New-Rule Connection 'Microsoft\.ACE|Microsoft\.Jet' 'Access/Excel via ACE/Jet OLE DB' AdfNative-Medium '' NeedsCustomSetup 'ACE/Jet driver must be installed; ADF needs SHIR with the Access driver.'
    New-Rule Connection '^EXCEL'                       'Excel'                       AdfNative-Medium '' NeedsCustomSetup 'ADF Excel connector is read-only.'
    New-Rule Connection '^MSOLAP'                      'Analysis Services'           KeepOnSsisVm '' NeedsConfiguration 'SSAS dependency.'
    New-Rule Connection '^SMOServer|^SQLMOBILE|^WMI|^MSMQ' 'SMO/SQL Mobile/WMI/MSMQ'   KeepOnSsisVm '' NeedsConfiguration 'Host or server-administration dependency.'
    New-Rule Connection '^OLEDB.*(OraOLEDB|MSDAORA)'   'Oracle via OLE DB'           AdfNative-Medium '' NeedsCustomSetup 'Oracle client required on runtime; ADF Oracle connector via SHIR.'
    New-Rule Connection '^OLEDB|^ADO\.NET|^ODBC'       'Relational (OLE DB / ADO.NET / ODBC)' AdfNative-Low '' Compatible 'ADF linked service.'
    New-Rule Connection '^FLATFILE|^MULTIFLATFILE|^FILE|^MULTIFILE' 'File'           AdfNative-Medium '' NeedsConfiguration 'ADF file system connector via SHIR, or move files to Azure Storage.'
    New-Rule Connection '^FTP|^SFTP'                   'FTP'                         AdfNative-Medium '' Compatible 'ADF FTP/SFTP connector.'
    New-Rule Connection '^SMTP|^HTTP'                  'SMTP/HTTP'                   AdfNative-Medium '' Compatible 'ADF Web activity / Logic App.'
    New-Rule Connection 'Azure|FlexibleFile|DataLake'  'Azure Feature Pack'          AdfNative-Low '' Compatible 'Native ADF connector exists.'
    New-Rule Connection '^CACHE'                       'Cache'                       AdfNative-Medium '' Compatible 'Lookup cache; Data Flow cached lookup.'
)

# Findings raised by package, task or data flow PROPERTIES rather than by a type identity. They are evidence
# items like any other, so they route, accumulate and appear in evidence_items.csv.
$PropertyRule = @{
    Transaction   = New-Rule Task '' 'Distributed transaction (TransactionOption=Required)' AdfNative-Medium '' Review 'Uses MSDTC. ADF has no distributed transactions: redesign as idempotent steps or one set-based stored procedure. Azure-SSIS IR needs MSDTC on every participant.'
    Checkpoint    = New-Rule Package '' 'Checkpoint restart' AdfNative-Medium '' NeedsConfiguration 'Checkpoint file restarts the package at the failed task. ADF rerun-from-failure works per activity with no checkpoint file, so restart logic must be re-proven; the checkpoint path must be writable on any SSIS runtime.'
    ErrorRows     = New-Rule Component '' 'Error-row redirection' AdfNative-Medium '' Compatible 'Error/truncation rows are redirected to an error output. ADF Copy can only skip and log incompatible rows; routing them to a table needs a Mapping Data Flow or staging + validation SQL.'
    ExprPath      = New-Rule Connection '' 'Local drive / UNC file path (set by expression)' AdfNative-Medium '' NeedsConfiguration 'The connection string expression resolves to a local or UNC path at run time (literal or variable/parameter default). Same reachability needs as a literal path: Self-hosted IR for ADF; VNet + file share access for Azure-SSIS IR.'
    LoggingOnly   = New-Rule Connection '' 'Logging-only connection' AdfNative-Low '' Compatible 'Used only by a package log provider. Logging plumbing, not a data path, so it does not affect the route.'
    OpaqueSql     = New-Rule Task '' 'SQL statement from variable / file (opaque SQL)' AdfNative-Medium '' Compatible 'SqlStatementSource is a variable or a file connection, so the SQL that runs is not in the package. Capture the statement(s) and confirm they are plain set-based SQL before mapping to an ADF Script / Stored Procedure activity.'
    FullResultSet = New-Rule Task '' 'Execute SQL full result set' AdfNative-Low '' Compatible 'ResultSet=Full result set into an Object variable. ADF Lookup returns at most 5,000 rows / 4 MB; larger sets need a staging table or a ForEach over a query.'
    FixedWidth    = New-Rule Connection '' 'Fixed-width / ragged-right flat file' AdfNative-Medium '' Compatible 'ADF delimited text has no fixed-width format: parse with a Mapping Data Flow (substring derived columns) or load whole lines and split in SQL.'
}
# Plain-language explanation for every rule, shown as DecisionDrivers in the sprint backlog and as Explanation in
# evidence_items.csv. Written for a reader who knows neither SSIS nor ADF internals: what the package does, and
# why that puts it on its platform. Note (above) stays the engineer-facing detail. Keyed by rule Name; every
# static rule must have an entry (checked at start-up). Rules named at run time match $RuleExplanationPattern.
$Shir = 'a Self-hosted Integration Runtime (SHIR, see Legend)'
$RuleExplanation = @{
    # Removed or discontinued in SQL Server 2025
    'Hadoop Hive Task'               = 'Runs a Hive job on a Hadoop cluster. Microsoft removed the Hadoop tasks from SQL Server 2025 SSIS, so this step must be replaced (for example by a Databricks or HDInsight activity in ADF) before the package can run on a SQL Server 2025 host.'
    'Hadoop Pig Task'                = 'Runs a Pig job on a Hadoop cluster. Microsoft removed the Hadoop tasks from SQL Server 2025 SSIS, so this step must be replaced (for example by a Databricks or HDInsight activity in ADF) before the package can run on a SQL Server 2025 host.'
    'Hadoop File System Task'        = 'Copies files to or from a Hadoop cluster. Microsoft removed the Hadoop tasks from SQL Server 2025 SSIS, so this step must be replaced (for example by an ADF Copy activity) before the package can run on a SQL Server 2025 host.'
    'Foreach HDFS File Enumerator'   = 'Loops over files stored on a Hadoop cluster. Microsoft removed the Hadoop components from SQL Server 2025 SSIS, so the loop must be rebuilt before the package can run on a SQL Server 2025 host.'
    'Hadoop'                         = 'Connects to a Hadoop cluster. Microsoft removed the Hadoop components from SQL Server 2025 SSIS, so the connection must be replaced before the package can run on a SQL Server 2025 host.'
    'CDC Control Task (Attunity)'    = 'Manages change data capture (reading only the rows that changed) with the Attunity CDC components. Microsoft removed them from SQL Server 2025 SSIS, so the change-capture logic must be rebuilt, or the package kept on a SQL Server 2022 host.'
    'CDC Source (Attunity)'          = 'Reads only the rows that changed (change data capture) with the Attunity CDC components. Microsoft removed them from SQL Server 2025 SSIS, so the change-capture logic must be rebuilt, or the package kept on a SQL Server 2022 host.'
    'CDC Splitter (Attunity)'        = 'Splits captured changes into inserts, updates and deletes with the Attunity CDC components. Microsoft removed them from SQL Server 2025 SSIS, so the change-capture logic must be rebuilt, or the package kept on a SQL Server 2022 host.'
    'Oracle Source/Destination (Microsoft Connector for Oracle)' = "Reads or writes Oracle through the Microsoft Connector for Oracle, which Microsoft removed from SQL Server 2025 SSIS. The replacement is ADF's own Oracle connector, running through $Shir."
    'Oracle (Microsoft Connector for Oracle)' = "Connects to Oracle through the Microsoft Connector for Oracle, which Microsoft removed from SQL Server 2025 SSIS. The replacement is ADF's own Oracle connector, running through $Shir."
    'DQS Cleansing'                  = 'Cleans data with Data Quality Services (DQS). DQS is discontinued in SQL Server 2025, so there is no DQS server to call and the cleansing rules must be rebuilt elsewhere.'
    'DQS'                            = 'Connects to Data Quality Services (DQS). DQS is discontinued in SQL Server 2025, so there is no DQS server to call and the cleansing rules must be rebuilt elsewhere.'
    # Database administration rather than data movement
    'Maintenance Plan Task'          = 'Runs a SQL Server maintenance plan (backups, index or statistics upkeep). That is database administration, not data movement, and ADF has no equivalent. It belongs in DBA automation such as SQL Agent. Its connection type is also deprecated in SQL Server 2025.'
    'DBA Maintenance Task'           = 'Runs database upkeep (backup, integrity check, index or statistics maintenance). That is database administration, not data movement, and ADF has no equivalent. It belongs in DBA automation such as SQL Agent.'
    'Transfer Task'                  = 'Copies server objects (logins, jobs, stored procedures, whole databases) between SQL Servers. ADF does not do this kind of administration, so the package stays on the SSIS VM or the step moves to DBA tooling.'
    'Foreach SMO Enumerator'         = 'Loops over SQL Server objects (databases, tables) using server-management APIs. ADF has no equivalent, and this connection type is deprecated in SQL Server 2025, so the package stays on the SSIS VM.'
    # Needs the SSIS runtime
    'Script Task'                    = 'Runs custom C# or VB.NET code written inside the package. ADF cannot run that code, so the package stays on the SSIS VM unless the code is rewritten (for example as an Azure Function).'
    'Script Component'               = 'Runs custom C# or VB.NET code on every row inside the data flow. ADF cannot run that code, so the package stays on the SSIS VM unless the logic is rewritten.'
    'Execute Process Task'           = 'Starts a program or batch file on the server. ADF has no server of its own to run it on, so the package stays on the SSIS VM where the program is installed.'
    'WMI Task'                       = 'Reads Windows system information or waits for Windows events on the server (WMI). ADF has no Windows host to query, so the package stays on the SSIS VM.'
    'Message Queue Task'             = 'Sends or receives messages through Microsoft Message Queuing (MSMQ), a Windows server feature that ADF cannot use, so the package stays on the SSIS VM.'
    'Analysis Services Task'         = 'Processes or changes an Analysis Services (SSAS) cube or model. ADF has no built-in activity for this, so the package stays on the SSIS VM (or calls the model through a REST API if it moves to Azure Analysis Services).'
    'Data Profiling Task'            = 'Produces data-profile statistics (null counts, value patterns, key candidates). ADF has no equivalent activity, so the package stays on the SSIS VM.'
    'XML Task'                       = 'Transforms or queries XML files (XSLT or XPath). ADF cannot run XSLT, so the package stays on the SSIS VM.'
    'Excel Destination'              = 'Writes rows into an Excel workbook. ADF can read Excel files but cannot create or write them (Excel is not a supported ADF destination), so the package stays on the SSIS VM, which also needs the Microsoft Access Database Engine (ACE) driver installed. To leave SSIS, write CSV or Parquet instead, or have ADF call custom code that writes the workbook.'
    'Fuzzy Lookup/Grouping'          = 'Matches or groups records that are similar but not identical (fuzzy matching). ADF has no equivalent, so the package stays on the SSIS VM.'
    'Term Extraction/Lookup'         = 'Pulls key terms out of free text or matches text against a term list. ADF has no equivalent, so the package stays on the SSIS VM.'
    'Data Mining Query'              = 'Runs a prediction query against an Analysis Services data-mining model. ADF has no equivalent, so the package stays on the SSIS VM.'
    'Export/Import Column'           = 'Writes column values (such as documents or images) out to individual files, or loads files into a column, one row at a time. ADF has no equivalent, so the package stays on the SSIS VM.'
    'Balanced Data Distributor'      = 'Splits the data flow across parallel threads for speed. ADF manages parallelism itself and has no such component, so the package stays on the SSIS VM until the flow is redesigned.'
    'Recordset/DataReader Destination' = 'Keeps query results in memory so later steps in the same package can loop over them. ADF has no in-memory result set of this kind, so the package stays on the SSIS VM.'
    'Analysis Services'              = 'Connects to Analysis Services (SSAS). ADF has no Analysis Services connector, so the package stays on the SSIS VM.'
    'SMO/SQL Mobile/WMI/MSMQ'        = 'Connects to a server-administration or Windows feature (SMO, SQL Server Mobile, WMI or MSMQ) that ADF cannot use, so the package stays on the SSIS VM.'
    # ADF can do it, with design work
    'Web Service Task'               = "Calls a SOAP web service. ADF's Web activity can make the call, but building the request and reading the response has to be redone."
    'Bulk Insert Task'               = "Loads a file into a SQL table. ADF's Copy activity does this, but the file must be reachable from ADF: in Azure Storage, or through $Shir."
    'File System Task'               = "Copies, moves or deletes files on a file share or local drive. ADF can do this only through $Shir, or after the files move to Azure Storage."
    'FTP Task'                       = 'Sends or receives files over FTP. ADF has FTP and SFTP connectors, so this maps directly, with some redesign of the file steps.'
    'Send Mail Task'                 = 'Sends an email. ADF cannot send email itself, so it calls a Logic App (or Microsoft Graph) from a Web activity.'
    'Foreach File Enumerator'        = "Loops over the files in a folder. ADF does this with Get Metadata plus ForEach, but a file share is reachable only through $Shir."
    'Foreach ADO/Item/Variable/NodeList Enumerator' = 'Loops over rows from a query, a fixed list or a variable. ADF does this with a Lookup activity feeding a ForEach, which needs some redesign.'
    'OLE DB Command'                 = 'Runs a SQL statement once for every row, which is slow at volume. ADF has no row-by-row equivalent: rebuild it as a staging table plus one set-based stored procedure.'
    'Slowly Changing Dimension'      = 'Keeps history in a dimension table using the SSIS wizard component. ADF has no such wizard: rebuild it with a Mapping Data Flow or a set-based SQL MERGE.'
    'Transformation (Data Flow mappable)' = 'Changes data on the way through (lookups, joins, sorts, aggregates, calculated columns). ADF can do this with a Mapping Data Flow, or the logic can move into SQL, so it is a rebuild rather than a simple copy.'
    'Raw File Source/Destination'    = 'Stages data in the SSIS-only Raw file format, which ADF cannot read or write. Replace the staging step with Parquet files in Azure Storage or a staging table.'
    'Excel Source'                   = "Reads an Excel workbook. ADF can read Excel (choosing the worksheet and cell range), but the file must be reachable from ADF: in Azure Storage, or through $Shir."
    'Access/Excel via ACE/Jet OLE DB' = "Connects to an Access database or Excel file through the Microsoft Access Database Engine (ACE/Jet) driver. ADF can reach it only through $Shir on a server with that driver installed. Writing to Excel this way keeps the package on the SSIS VM (see Excel Destination)."
    'Excel'                          = 'Connects to an Excel workbook. ADF can read Excel files but cannot write them, so any step that writes to this connection keeps the package on the SSIS VM.'
    'Oracle via OLE DB'              = "Connects to Oracle through an Oracle OLE DB driver. ADF uses its own Oracle connector instead, running through $Shir, so the connection must be rebuilt."
    'File'                           = "Reads or writes files on a file share or local drive. ADF can reach a file share only through $Shir, or after the files move to Azure Storage."
    'FTP'                            = 'Connects to an FTP or SFTP server. ADF has FTP and SFTP connectors.'
    'SMTP/HTTP'                      = 'Sends email or calls a web address. ADF does this from a Web activity, with a Logic App for email.'
    'Cache'                          = 'Holds lookup data in memory for the data flow. ADF Mapping Data Flows have a cached lookup that does the same job, so it needs rebuilding.'
    'Distributed transaction (TransactionOption=Required)' = 'Wraps several steps in one transaction so they all succeed or all roll back (MSDTC). ADF has no transactions across steps, so the steps must be redesigned to be safe to re-run, or combined into one stored procedure.'
    'Checkpoint restart'             = 'Restarts from the step that failed, using a checkpoint file. ADF can rerun from the failed activity but has no checkpoint file, so the restart behaviour must be re-tested after the rewrite.'
    'Error-row redirection'          = "Sends bad rows to a separate error output instead of failing. ADF's Copy activity can only skip and log bad rows, so keeping them in a table needs a Mapping Data Flow or a stage-and-validate step."
    'Local drive / UNC file path'    = "Reads or writes a file on a server drive or network share (C:\... or \\server\share). ADF can reach it only through $Shir, or after the file moves to Azure Storage."
    'Local drive / UNC file path (set by expression)' = "Reads or writes a file on a server drive or network share, with the path built while the package runs. ADF can reach it only through $Shir, or after the file moves to Azure Storage."
    'SQL statement from variable / file (opaque SQL)' = 'The SQL that runs is held in a variable or a separate file, not in the package, so the scan could not see it. Collect that SQL and confirm it is plain SQL before mapping it to an ADF Script or Stored Procedure activity.'
    'Fixed-width / ragged-right flat file' = 'Reads a text file whose columns are set by character position instead of commas. ADF text files need a delimiter, so the columns must be split in a Mapping Data Flow or in SQL.'
    'Windows authentication'         = "Logs in to the database with a Windows account. ADF can use Windows logins only through $Shir, unless the connection switches to SQL or Microsoft Entra authentication."
    # Direct ADF equivalent
    'Data Flow Task'                 = "Moves data from a source to a destination. On its own that is an ADF Copy activity; the steps inside it decide the final route."
    'Execute SQL Task'               = "Runs a SQL statement or stored procedure. ADF's Script or Stored Procedure activity does the same."
    'Execute Package Task'           = "Runs another package. ADF's Execute Pipeline activity does the same; the child package's own route counts toward this one."
    'Expression Task'                = "Sets a variable from a calculation. ADF's Set Variable activity does the same."
    'Azure Feature Pack Task'        = 'Works with Azure storage or Azure services. ADF has native connectors for these.'
    'Azure Feature Pack'             = 'Connects to Azure storage or Azure services. ADF has native connectors for these.'
    'Sequence / For Loop Container'  = 'Groups steps, or repeats them in a counted loop. ADF has equivalent activities.'
    'Foreach Loop Container'         = "Repeats steps for each item in a list. ADF's ForEach activity does the same; what it loops over is assessed separately."
    'Data Conversion / Row Count'    = "Converts data types or counts rows. ADF's Copy activity handles both."
    'Source/Destination adapter'     = "Reads from or writes to a database or text file. ADF's Copy activity does the same."
    'Relational (OLE DB / ADO.NET / ODBC)' = 'Connects to a relational database. ADF has a matching connection (linked service).'
    'Execute SQL full result set'    = "Loads a whole query result into memory for later steps. ADF's Lookup activity returns at most 5,000 rows, so larger results need a staging table."
    'Logging-only connection'        = 'Used only to write the package log, not to move data, so it does not affect the route.'
}
# What each Script Task / Script Component dependency means for the move (names from $ScriptDependencyRule).
$ScriptDependencyExplanation = @{
    'ADO.NET SqlClient'            = 'The custom code queries SQL Server directly. Any rewrite must repeat those queries, and the connection details must be moved into configuration.'
    'OLE DB (System.Data.OleDb)'   = 'The custom code connects to a database through an OLE DB driver, which must be installed wherever the code runs.'
    'ODBC (System.Data.Odbc)'      = 'The custom code connects to a database through an ODBC driver, which must be installed wherever the code runs.'
    'Zip (System.IO.Compression)'  = 'The custom code zips or unzips files. ADF can compress and decompress files in a Copy activity, so this part can move.'
    'Third-party zip library'      = 'The custom code uses a third-party zip library, which must be installed wherever the code runs.'
    'Network / HTTP / FTP / mail'  = 'The custom code calls web addresses, FTP servers or sends email. Those endpoints must be reachable from wherever the code runs.'
    'Office Interop'               = 'The custom code drives Microsoft Office (for example Excel) on the server. Office must be installed there, and Microsoft does not support Office automation on servers.'
    'Active Directory'             = 'The custom code reads Active Directory, which is only reachable from a domain-joined server.'
    'SFTP library'                 = 'The custom code uses a third-party SFTP library, which must be installed wherever the code runs. ADF has its own SFTP connector.'
    'External process'             = 'The custom code starts another program on the server, which must be installed wherever the code runs.'
    'Registry access'              = 'The custom code reads or writes the Windows registry, which ties it to that particular server.'
    'File system I/O'              = 'The custom code reads or writes files on a server drive or share, which must be reachable wherever the code runs.'
    'Hard-coded connection string' = 'The custom code contains a database connection string. It must be moved into configuration before the package can run anywhere else.'
    'Hard-coded local / UNC path'  = 'The custom code contains a server drive or network share path. It must be moved into configuration before the package can run anywhere else.'
    'Hard-coded URL'               = 'The custom code contains a web address. It must be moved into configuration before the package can run anywhere else.'
}
# Rules named at run time. {0} is the regex group captured from the name.
$RuleExplanationPattern = [ordered]@{
    '^Script dependency: Custom assembly reference \((.+)\)$' = 'The custom code uses an in-house library ({0}). It must be installed on every server that runs the package, and carried into any rewrite.'
    '^Package configuration \((.+)\)$' = 'Takes its settings from an old-style package configuration ({0}). These must become project parameters (SSIS) or pipeline parameters and Key Vault secrets (ADF) before the package can move.'
    '^Log provider \((.+)\)$'        = 'Writes a package log ({0}). Logging maps to SSIS catalog logging or Azure Monitor and does not affect the route.'
    '^Unrecognized (\w+)$'           = 'Uses an SSIS {0} type the scanner does not recognise, usually a third-party or custom add-on. ADF cannot run SSIS add-ons, so the package stays on the SSIS VM until someone identifies the component.'
}

function Get-RuleExplanation {
    <# Plain-language explanation for a rule (see $RuleExplanation). Falls back to the engineer Note, marked as such. #>
    param([Parameter(Mandatory)]$Rule)
    if ($RuleExplanation.ContainsKey($Rule.Name)) { return $RuleExplanation[$Rule.Name] }
    $dep = $Rule.Name -replace '^Script dependency: '
    if ($dep -ne $Rule.Name -and $ScriptDependencyExplanation.ContainsKey($dep)) { return $ScriptDependencyExplanation[$dep] }
    foreach ($p in $RuleExplanationPattern.Keys) {
        $m = [regex]::Match($Rule.Name, $p)
        if ($m.Success) { return ($RuleExplanationPattern[$p] -f $m.Groups[1].Value) }
    }
    '{0} (plain-language text missing)' -f $Rule.Note
}

# Script Task / Script Component code inventory. Each pattern is matched against the script source (comment lines
# removed) and the project file references; a hit becomes a 'Script dependency' evidence item. The route stays
# KeepOnSsisVm (set by the script itself); the value is the dependency list and the Azure-SSIS IR fit.
# Literal values are never written out: only the dependency name and the script file name.
$ScriptDependencyRule = @(
    @{ Name = 'ADO.NET SqlClient';            AzureIr = 'Compatible';         Pattern = 'System\.Data\.SqlClient|Microsoft\.Data\.SqlClient|\bSqlConnection\b' }
    @{ Name = 'OLE DB (System.Data.OleDb)';   AzureIr = 'NeedsConfiguration'; Pattern = 'System\.Data\.OleDb|\bOleDbConnection\b' }
    @{ Name = 'ODBC (System.Data.Odbc)';      AzureIr = 'NeedsCustomSetup';   Pattern = 'System\.Data\.Odbc|\bOdbcConnection\b' }
    @{ Name = 'Zip (System.IO.Compression)';  AzureIr = 'Compatible';         Pattern = 'System\.IO\.Compression|\bZipFile\b' }
    @{ Name = 'Third-party zip library';      AzureIr = 'NeedsCustomSetup';   Pattern = 'Ionic\.Zip|ICSharpCode\.SharpZipLib|SevenZip' }
    @{ Name = 'Network / HTTP / FTP / mail';  AzureIr = 'NeedsConfiguration'; Pattern = 'System\.Net\b|\b(WebClient|HttpClient|WebRequest|FtpWebRequest|SmtpClient)\b' }
    @{ Name = 'Office Interop';               AzureIr = 'NeedsCustomSetup';   Pattern = 'Microsoft\.Office\.Interop' }
    @{ Name = 'Active Directory';             AzureIr = 'NeedsConfiguration'; Pattern = 'System\.DirectoryServices' }
    @{ Name = 'SFTP library';                 AzureIr = 'NeedsCustomSetup';   Pattern = 'WinSCP|Renci\.SshNet' }
    @{ Name = 'External process';             AzureIr = 'NeedsCustomSetup';   Pattern = 'Process\.Start\b|\bnew\s+Process\b|\bShell\s*\(' }
    @{ Name = 'Registry access';              AzureIr = 'Review';             Pattern = 'Microsoft\.Win32|\bRegistry\.(LocalMachine|CurrentUser|GetValue|SetValue)' }
    @{ Name = 'File system I/O';              AzureIr = 'NeedsConfiguration'; Pattern = '\b(File|Directory)\.\w+\s*\(|\b(FileInfo|DirectoryInfo|DriveInfo|StreamReader|StreamWriter|FileStream)\b' }
    @{ Name = 'Hard-coded connection string'; AzureIr = 'NeedsConfiguration'; Pattern = '"[^"\r\n]*(Data Source|Server|Initial Catalog|Provider)\s*=[^"\r\n]*"' }
    @{ Name = 'Hard-coded local / UNC path';  AzureIr = 'NeedsConfiguration'; Pattern = '"@?\\{2,4}[\w$.-]+\\|"[A-Za-z]:\\' }
    @{ Name = 'Hard-coded URL';               AzureIr = 'NeedsConfiguration'; Pattern = '"(https?|ftps?|sftp)://' }
)
# Project file references that ship with .NET Framework or the SSIS runtime. Anything else is a custom assembly
# that has to be in the GAC of every runtime (Azure-SSIS IR: custom setup).
$FrameworkReferencePattern = '^(System|Microsoft\.SqlServer|Microsoft\.CSharp|Microsoft\.VisualBasic|mscorlib|Microsoft\.VisualStudio\.Tools\.Applications|Microsoft\.Office\.Interop)\b'
# Completeness check. A rule without plain-language text does not stop the run (the routes are still right):
# its rows show the engineer Note marked as missing text, and the warning below goes to the transcript.
# The routing test fails on that warning, so the gap is caught in the pull request that adds the rule.
$missing = @(@($RuleTable) + @($PropertyRule.Values) | Where-Object { -not $RuleExplanation.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
$missing += @($ScriptDependencyRule | Where-Object { -not $ScriptDependencyExplanation.ContainsKey($_.Name) } | ForEach-Object { "Script dependency: $($_.Name)" })
if ($missing.Count -gt 0) {
    Write-Log -Level WARN -Message ('RULE-EXPLANATION-MISSING: no plain-language text for {0}. The backlog shows the engineer note for these; add them to $RuleExplanation / $ScriptDependencyExplanation.' -f ($missing -join ', '))
}
$SqlTaskNs = 'www.microsoft.com/sqlserver/dts/tasks/sqltask'
# DTSConfigurationType (Microsoft.SqlServer.Dts.Runtime). I* = indirect: the location is held in an environment variable.
$ConfigurationTypeName = @{
    '0' = 'ParentVariable'; '1' = 'ConfigFile'; '2' = 'EnvVariable'; '3' = 'RegEntry'; '4' = 'IParentVariable'
    '5' = 'IConfigFile'; '6' = 'IRegEntry'; '7' = 'SqlServer'; '8' = 'IniFile'; '9' = 'ISqlServer'; '10' = 'IIniFile'
}
# Literal file path on a drive letter or UNC share, alone or as an OLE DB/ODBC Data Source.
$LocalOrUncPattern = '^\s*\\\\|^\s*[A-Za-z]:\\|Data Source\s*=\s*(\\\\|[A-Za-z]:\\)'

function Get-RuleMatch {
    <# Returns the first rule in $RuleTable matching Scope + identity, or an explicit "Unrecognized" rule. #>
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][AllowEmptyString()][string]$Identity)
    foreach ($rule in $RuleTable) {
        if ($rule.Scope -eq $Scope -and $Identity -match $rule.Pattern) { return $rule }
    }
    # Unknown types are treated conservatively: likely third-party or custom, so they stay on the SSIS runtime.
    New-Rule $Scope '' "Unrecognized $Scope" 'KeepOnSsisVm' '' 'NeedsCustomSetup' "Unrecognized type '$Identity' - likely third-party/custom component; verify and add to the rule table."
}

function Resolve-Category {
    <#
        Converts a rule's Category + Lifecycle into the routing category for a given target host version.
        Removed/Discontinued components block only a SQL Server 2025 host; on older hosts they keep their
        normal category and are reported as a future risk.
    #>
    param([Parameter(Mandatory)]$Rule, [Parameter(Mandatory)][string]$TargetVersion)
    if ($Rule.Lifecycle -in @('Removed2025', 'Discontinued2025') -and $TargetVersion -eq '2025') { return 'Remediate2025' }
    return $Rule.Category
}
#endregion

#region ============================== 2. SQL ACCESS (READ-ONLY) ==================================

function New-SqlConnectionObject {
    <# Builds a SqlConnection with explicit encryption settings. Windows auth unless -SqlCredential given. #>
    param([Parameter(Mandatory)][string]$Server, [string]$Database = 'master')
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source']              = $Server
    $b['Initial Catalog']          = $Database
    $b['Application Name']         = "SSIS-ADF-Assessment ($RunId)"
    $b['Connect Timeout']          = 30
    $b['Encrypt']                  = (-not $DisableEncryption)
    $b['TrustServerCertificate']   = [bool]$TrustServerCertificate
    if ($SqlCredential) {
        $conn = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
        $securePwd = $SqlCredential.Password.Copy(); $securePwd.MakeReadOnly()
        $conn.Credential = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $securePwd)
        return $conn
    }
    $b['Integrated Security'] = $true
    return New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
}

function Format-AgentSchedule {
    <# One msdb.dbo.sysschedules row in words, as SSMS describes it: "Weekly on Wed at 01:00",
       "Daily every 15 minutes from 06:00 to 18:00", "When SQL Server Agent starts". #>
    param([Parameter(Mandatory)]$S)
    $time = { param([int]$t) '{0:00}:{1:00}' -f [math]::Floor($t / 10000), ([math]::Floor($t / 100) % 100) }
    $days = 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
    $every = [int]$S.freq_recurrence_factor
    $interval = [int]$S.freq_interval
    $when = switch ([int]$S.freq_type) {
        1   { 'Once on {0}' -f ([string]$S.active_start_date -replace '^(\d{4})(\d{2})(\d{2})$', '$1-$2-$3') }
        4   { if ($interval -gt 1) { "Every $interval days" } else { 'Daily' } }
        8   { $on = @(0..6 | Where-Object { $interval -band [math]::Pow(2, $_) } | ForEach-Object { $days[$_] }) -join ','
              if ($every -gt 1) { "Every $every weeks on $on" } else { "Weekly on $on" } }
        16  { 'Monthly on day {0}{1}' -f $interval, $(if ($every -gt 1) { " every $every months" } else { '' }) }
        32  { $nth = @{ 1 = 'first'; 2 = 'second'; 4 = 'third'; 8 = 'fourth'; 16 = 'last' }[[int]$S.freq_relative_interval]
              $what = if ($interval -ge 1 -and $interval -le 7) { $days[$interval - 1] } else { @{ 8 = 'day'; 9 = 'weekday'; 10 = 'weekend day' }[$interval] }
              'Monthly on the {0} {1}{2}' -f $nth, $what, $(if ($every -gt 1) { " every $every months" } else { '' }) }
        64  { 'When SQL Server Agent starts' }
        128 { 'When the computer is idle' }
        default { "Schedule type $($S.freq_type)" }
    }
    if ([int]$S.freq_type -in 4, 8, 16, 32) {
        $unit = @{ 2 = 'seconds'; 4 = 'minutes'; 8 = 'hours' }[[int]$S.freq_subday_type]
        $when += if ($unit) { ' every {0} {1} from {2} to {3}' -f $S.freq_subday_interval, $unit, (& $time $S.active_start_time), (& $time $S.active_end_time) }
                 else { ' at {0}' -f (& $time $S.active_start_time) }
    }
    if ([int]$S.freq_type -eq 1) { $when += ' at {0}' -f (& $time $S.active_start_time) }
    if (-not [bool]$S.ScheduleEnabled) { $when += ' (schedule disabled)' }
    $when
}

function Invoke-ReadQuery {
    <# Executes a read-only query and returns rows as PSCustomObjects. Parameters passed as a hashtable. #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{}
    )
    $conn = New-SqlConnectionObject -Server $Server -Database $Database
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $Query
        $cmd.CommandTimeout = $CommandTimeoutSeconds
        foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
        $table = New-Object System.Data.DataTable
        $table.Load($cmd.ExecuteReader())
        foreach ($row in $table.Rows) {
            $o = [ordered]@{}
            foreach ($col in $table.Columns) {
                $v = $row[$col.ColumnName]; if ($v -is [System.DBNull]) { $v = $null }
                $o[$col.ColumnName] = $v
            }
            [PSCustomObject]$o
        }
    }
    finally { $conn.Dispose() }
}

function Get-SsisdbProjectBytes {
    <# Exports one project as .ispac bytes via SSISDB.catalog.get_project (read-only catalog procedure). #>
    param([string]$Server, [string]$Folder, [string]$Project)
    $conn = New-SqlConnectionObject -Server $Server -Database 'SSISDB'
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = 'EXEC [catalog].[get_project] @folder_name = @f, @project_name = @p;'
        $cmd.CommandTimeout = $CommandTimeoutSeconds
        [void]$cmd.Parameters.AddWithValue('@f', $Folder)
        [void]$cmd.Parameters.AddWithValue('@p', $Project)
        return [byte[]]$cmd.ExecuteScalar()
    }
    finally { $conn.Dispose() }
}
#endregion

#region ============================== 3. PACKAGE / PROJECT FILE READERS ==========================

function ConvertFrom-PackageBytes {
    <# Decodes package bytes to text, honouring any byte-order mark (UTF-8 / UTF-16). #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $ms = New-Object System.IO.MemoryStream(, $Bytes)
    $sr = New-Object System.IO.StreamReader($ms, [System.Text.Encoding]::UTF8, $true)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose(); $ms.Dispose() }
}

function Expand-IspacBytes {
    <#
        Reads an .ispac (an OPC/ZIP archive) in memory and returns its packages (.dtsx) and project
        connection managers (.conmgr) as text. OPC part names are percent-encoded, so names are unescaped.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $ms  = New-Object System.IO.MemoryStream(, $Bytes)
    $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $zip.Entries) {
            $name = [Uri]::UnescapeDataString($entry.FullName)
            $kind = switch -regex ($name) { '\.dtsx$' { 'Package' } '\.conmgr$' { 'ConnMgr' } default { $null } }
            if (-not $kind) { continue }
            $es = $entry.Open(); $buf = New-Object System.IO.MemoryStream
            try { $es.CopyTo($buf) } finally { $es.Dispose() }
            [PSCustomObject]@{ Name = $name; Kind = $kind; Text = (ConvertFrom-PackageBytes -Bytes $buf.ToArray()) }
            $buf.Dispose()
        }
    }
    finally { $zip.Dispose(); $ms.Dispose() }
}

function Get-DtsAttr {
    <# Reads a DTS-namespaced attribute; returns '' when missing. #>
    param($Node, [string]$Name)
    if ($null -eq $Node) { return '' }
    $v = $Node.GetAttribute($Name, $DtsNs)
    if ($null -eq $v) { return '' } else { return $v }
}
#endregion

#region ============================== 4. ANALYSIS ================================================

function Get-ConnectionFinding {
    <#
        Evaluates one DTS:ConnectionManager node (from a package or a .conmgr file).
        Produces the rule match plus independent flags that do not depend on the connection type:
          WindowsAuth      - integrated security (ADF needs SHIR + Windows linked service; Azure-SSIS IR needs config)
          LocalOrUncPath   - file path on a drive letter or UNC share (reachability from any cloud runtime)
          ExpressionDriven - connection string set by an expression/parameter; static value may be misleading
          ExpressionLocalOrUncPath - the expression resolves (literal or variable/parameter default) to a local/UNC path
          FixedWidthOrRagged - flat file format FixedWidth or RaggedRight (no ADF delimited-text equivalent)
    #>
    param([Parameter(Mandatory)]$CmNode, [Parameter(Mandatory)]$Ns, [hashtable]$ValueLookup = @{})
    $creation = Get-DtsAttr $CmNode 'CreationName'
    $inner    = $CmNode.SelectSingleNode('DTS:ObjectData/DTS:ConnectionManager', $Ns)
    $connStr  = Get-DtsAttr $inner 'ConnectionString'
    $provider = ''
    if ($connStr -match 'Provider\s*=\s*([^;]+)') { $provider = $Matches[1].Trim() }
    $identity = '{0}|{1}' -f $creation, $provider
    $rule     = Get-RuleMatch -Scope Connection -Identity $identity

    $flags = New-Object System.Collections.Generic.List[string]
    if ($connStr -match 'Integrated Security\s*=\s*(SSPI|True)|Trusted_Connection\s*=\s*(yes|true)') { $flags.Add('WindowsAuth') }
    if ($connStr -match $LocalOrUncPattern) { $flags.Add('LocalOrUncPath') }
    if ((Get-DtsAttr $inner 'Format') -in @('FixedWidth', 'RaggedRight')) { $flags.Add('FixedWidthOrRagged') }
    $connExpr = $CmNode.SelectSingleNode("DTS:PropertyExpression[@DTS:Name='ConnectionString']", $Ns)
    if ($connExpr) {
        $flags.Add('ExpressionDriven')
        # The static value is only the design-time default; check what the expression can evaluate to.
        if (-not ($flags -contains 'LocalOrUncPath')) {
            $candidates = Get-ExpressionCandidate -Expression $connExpr.InnerText -ValueLookup $ValueLookup
            if (@($candidates | Where-Object { $_ -match $LocalOrUncPattern }).Count -gt 0) { $flags.Add('ExpressionLocalOrUncPath') }
        }
    }

    # Mask secrets: never write passwords from connection strings to disk.
    $safeConnStr = $connStr -replace '(?i)(password|pwd)\s*=\s*[^;]*', '$1=********'

    [PSCustomObject]@{
        Name = (Get-DtsAttr $CmNode 'ObjectName'); DtsId = (Get-DtsAttr $CmNode 'DTSID')
        CreationName = $creation; Provider = $provider; Rule = $rule; Flags = $flags
        ConnectionString = $safeConnStr
    }
}

function Get-ExpressionCandidate {
    <#
        Returns the strings an SSIS expression can be built from: its string literals (SSIS escapes a backslash
        as \\) and the default values of the variables/parameters it references, following variables that are
        themselves expressions (EvaluateAsExpression) up to three levels. Values set only at run time (Foreach
        mappings, Script Tasks, SSISDB environments) cannot be seen; their design-time default is the evidence.
    #>
    param([string]$Expression, [hashtable]$ValueLookup = @{}, [int]$Depth = 0)
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $Expression -or $Depth -gt 2) { return , $out.ToArray() }
    foreach ($m in [regex]::Matches($Expression, '"((?:[^"\\]|\\.)*)"')) { $out.Add(($m.Groups[1].Value -replace '\\\\', '\')) }
    foreach ($m in [regex]::Matches($Expression, '@\[([^\]]+)\]')) {
        $v = $ValueLookup[$m.Groups[1].Value]
        if ($null -eq $v) { continue }
        if ($v.Value) { $out.Add($v.Value) }
        if ($v.Expression) { foreach ($c in (Get-ExpressionCandidate -Expression $v.Expression -ValueLookup $ValueLookup -Depth ($Depth + 1))) { $out.Add($c) } }
    }
    return , $out.ToArray()
}

function Get-ScriptDependency {
    <#
        Inventories one script's dependencies. Code is the script source (all source files joined); References are
        the assembly names from the .csproj/.vbproj. Returns one PSCustomObject per dependency: Name, AzureIr.
    #>
    param([string]$Code, [string[]]$References = @())
    # Drop whole-line comments (C# //, VB ') and C# block comments so commented-out code does not count.
    $clean = [regex]::Replace($Code, '(?s)/\*.*?\*/', '')
    $clean = (@($clean -split "`r?`n" | Where-Object { $_ -notmatch "^\s*(//|')" }) -join "`n")
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($d in $ScriptDependencyRule) {
        if ($clean -match $d.Pattern -or @($References | Where-Object { $_ -match $d.Pattern }).Count -gt 0) {
            $found.Add([PSCustomObject]@{ Name = $d.Name; AzureIr = $d.AzureIr })
        }
    }
    foreach ($ref in $References) {
        if ($ref -and $ref -notmatch $FrameworkReferencePattern -and $ref -notmatch 'Ionic\.Zip|ICSharpCode|SevenZip|WinSCP|Renci\.SshNet') {
            $found.Add([PSCustomObject]@{ Name = ('Custom assembly reference ({0})' -f $ref); AzureIr = 'NeedsCustomSetup' })
        }
    }
    return $found
}

function Add-ScriptDependencyItems {
    <# Adds one evidence item per script dependency and records the names for the ScriptDependencies column. #>
    param($Result, [string]$Path, [string]$Code, [string[]]$References = @(), [bool]$Disabled)
    foreach ($d in (Get-ScriptDependency -Code $Code -References $References)) {
        if (-not $Disabled) { [void]$Result.ScriptDependencies.Add($d.Name) }
        $Result.Items.Add([PSCustomObject]@{ Scope = 'ScriptDependency'; Path = $Path; Identity = $d.Name; Disabled = $Disabled
            Rule = (New-Rule ScriptDependency '' ('Script dependency: {0}' -f $d.Name) KeepOnSsisVm '' $d.AzureIr 'Found in the script source or project references. Must be available on any runtime that runs this script, and is part of any rewrite (Azure Function / Batch).') })
    }
}

function Test-DisabledInTree {
    <# True when the executable or any container / event handler above it is disabled: SSIS never runs the children of a disabled container. #>
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)]$Root)
    for ($n = $Node; $n -is [System.Xml.XmlElement] -and -not [object]::ReferenceEquals($n, $Root); $n = $n.ParentNode) {
        if ((Get-DtsAttr $n 'Disabled') -eq 'True') { return $true }
    }
    return $false
}

function Get-PackageAnalysis {
    <#
        Parses one package's XML and returns:
          ParseStatus, FormatVersion, counts, matched evidence items, connection findings, child package names.
        Disabled tasks are recorded but excluded from routing (they never run), and flagged for clean-up.
    #>
    param(
        [Parameter(Mandatory)][string]$XmlText,
        [object[]]$ProjectConnections = @()   # findings from project-level .conmgr files
    )
    $result = [ordered]@{
        ParseStatus = 'Parsed'; ParseDetail = ''; FormatVersion = ''; ProtectionLevel = ''
        Items = New-Object System.Collections.Generic.List[object]
        ConnFindings = New-Object System.Collections.Generic.List[object]
        Children = New-Object System.Collections.Generic.List[string]
        TaskCount = 0; DisabledTaskCount = 0; DataFlowCount = 0; ComponentCount = 0
        ScriptTaskCount = 0; ScriptComponentCount = 0; ExpressionCount = 0; EventHandlerCount = 0
        TransactionRequiredCount = 0; CheckpointsEnabled = $false; ErrorRowRedirectCount = 0
        Configurations = New-Object System.Collections.Generic.List[string]
        LogProviders = New-Object System.Collections.Generic.List[string]
        ScriptDependencies = New-Object System.Collections.Generic.SortedSet[string]
        OpaqueSqlCount = 0
    }
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null    # never resolve external entities
    try { $xml.LoadXml($XmlText) }
    catch { $result.ParseStatus = 'ReviewRequired'; $result.ParseDetail = "The package file is damaged or is not valid XML, so it could not be read: $($_.Exception.Message)"; return [PSCustomObject]$result }

    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('DTS', $DtsNs)
    $root = $xml.DocumentElement

    # Format: SSIS 2012+ stores PackageFormatVersion as a property element; 2008-era packages (format <= 3) use a
    # different schema (no DTS:ExecutableType attributes) and cannot be analysed reliably.
    $fmtNode = $root.SelectSingleNode("DTS:Property[@DTS:Name='PackageFormatVersion']", $ns)
    if ($fmtNode) { $result.FormatVersion = $fmtNode.InnerText.Trim() }
    if ($root.NamespaceURI -ne $DtsNs -or ($result.FormatVersion -and [int]$result.FormatVersion -lt 6)) {
        $result.ParseStatus = 'ReviewRequired'
        $result.ParseDetail = "Built with SSIS 2008 R2 or earlier (package format '$($result.FormatVersion)'), which this scan cannot read. Open and upgrade it in a current version of Visual Studio, then run the assessment again."
        return [PSCustomObject]$result
    }
    # DTS:ProtectionLevel is numeric and omitted when it is the default (1 = EncryptSensitiveWithUserKey).
    $plMap = @{ '0' = 'DontSaveSensitive'; '1' = 'EncryptSensitiveWithUserKey'; '2' = 'EncryptSensitiveWithPassword'
                '3' = 'EncryptAllWithPassword'; '4' = 'EncryptAllWithUserKey'; '5' = 'ServerStorage' }
    $pl = Get-DtsAttr $root 'ProtectionLevel'; if (-not $pl) { $pl = '1' }
    $result.ProtectionLevel = if ($plMap.ContainsKey($pl)) { $plMap[$pl] } else { $pl }
    # EncryptAllWithPassword / EncryptAllWithUserKey replace the package body with DTS:EncryptedData.
    if ($root.SelectSingleNode('DTS:EncryptedData', $ns)) {
        $result.ParseStatus = 'ReviewRequired'
        $result.ParseDetail = 'The whole package is encrypted (protection level EncryptAll*), so its contents could not be read. Re-save it with EncryptSensitive or DontSaveSensitive, which encrypt only passwords, then run the assessment again.'
        return [PSCustomObject]$result
    }

    $result.ExpressionCount   = $root.SelectNodes('//DTS:PropertyExpression', $ns).Count
    $result.EventHandlerCount = $root.SelectNodes('//DTS:EventHandler', $ns).Count

    # ---- Variable and package parameter defaults, used to resolve connection string expressions ----
    $valueLookup = @{}
    foreach ($v in $root.SelectNodes('//DTS:Variable', $ns)) {
        $vv   = $v.SelectSingleNode('DTS:VariableValue', $ns)
        $expr = if ((Get-DtsAttr $v 'EvaluateAsExpression') -eq 'True') { Get-DtsAttr $v 'Expression' } else { '' }
        $valueLookup[('{0}::{1}' -f (Get-DtsAttr $v 'Namespace'), (Get-DtsAttr $v 'ObjectName'))] = [PSCustomObject]@{ Value = $(if ($vv) { $vv.InnerText } else { '' }); Expression = $expr }
    }
    foreach ($pp in $root.SelectNodes('DTS:PackageParameters/DTS:PackageParameter', $ns)) {
        $pv = $pp.SelectSingleNode("DTS:Property[@DTS:Name='ParameterValue']", $ns)
        $valueLookup['$Package::' + (Get-DtsAttr $pp 'ObjectName')] = [PSCustomObject]@{ Value = $(if ($pv) { $pv.InnerText } else { '' }); Expression = '' }
    }

    # ---- Package properties: checkpoints and package configurations (package deployment model) ----
    $cpUsage = Get-DtsAttr $root 'CheckpointUsage'
    if ($cpUsage -in @('1', '2', 'IfExists', 'Always') -or (Get-DtsAttr $root 'SaveCheckpoints') -eq 'True') {
        $result.CheckpointsEnabled = $true
        $result.Items.Add([PSCustomObject]@{ Scope = 'Package'; Path = 'Package'; Identity = ('CheckpointUsage={0}' -f $cpUsage); Rule = $PropertyRule.Checkpoint; Disabled = $false })
    }
    foreach ($cfg in $root.SelectNodes('DTS:Configurations/DTS:Configuration', $ns)) {
        $cType = Get-DtsAttr $cfg 'ConfigurationType'
        $cName = if ($ConfigurationTypeName.ContainsKey($cType)) { $ConfigurationTypeName[$cType] } else { "Type$cType" }
        $result.Configurations.Add($cName)
        $result.Items.Add([PSCustomObject]@{ Scope = 'Configuration'; Path = ('Configuration[{0}]' -f (Get-DtsAttr $cfg 'ObjectName')); Identity = $cName; Disabled = $false
            Rule = (New-Rule Configuration '' "Package configuration ($cName)" AdfNative-Medium '' NeedsConfiguration 'Package deployment model configuration: convert to project/package parameters and SSISDB environments before SSISDB, Azure-SSIS IR or an ADF rebuild (pipeline/global parameters, Key Vault). Environment-variable and registry configurations also tie the package to its host.') })
    }
    if ((Get-DtsAttr $root 'TransactionOption') -eq '2') {
        $result.TransactionRequiredCount++
        $result.Items.Add([PSCustomObject]@{ Scope = 'Package'; Path = 'Package'; Identity = 'TransactionOption=Required'; Rule = $PropertyRule.Transaction; Disabled = $false })
    }

    # ---- Log providers. A connection used ONLY by a log provider is logging plumbing, not a data path: it is
    #      reported but must not raise the route (it would turn a plain copy into AdfNative-Medium). ----
    $logRefs = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    $logKind = @{ 'TextFile' = 'Text file'; 'XMLFile' = 'XML file'; 'EventLog' = 'Windows Event Log'; 'SQLProfiler' = 'SQL Server Profiler'; 'SQLServer' = 'SQL Server' }
    foreach ($lp in $root.SelectNodes('DTS:LogProviders/DTS:LogProvider', $ns)) {
        $lpType = Get-DtsAttr $lp 'CreationName'
        $kind = 'Other'; foreach ($k in $logKind.Keys) { if ($lpType -match "LogProvider$k") { $kind = $logKind[$k] } }
        $result.LogProviders.Add($kind)
        $cfgStr = Get-DtsAttr $lp 'ConfigString'; if ($cfgStr) { [void]$logRefs.Add($cfgStr) }
        $result.Items.Add([PSCustomObject]@{ Scope = 'LogProvider'; Path = ('LogProvider[{0}]' -f (Get-DtsAttr $lp 'ObjectName')); Identity = $lpType; Disabled = $false
            Rule = (New-Rule LogProvider '' "Log provider ($kind)" AdfNative-Low '' Compatible 'Package logging; maps to SSISDB logging or ADF diagnostic settings / Azure Monitor, not to an ADF activity.') })
    }
    # Everything except the connection and log provider definitions: a connection referenced here is used by real work.
    $refText = (@($root.ChildNodes | Where-Object { $_.LocalName -notin @('ConnectionManagers', 'LogProviders') } | ForEach-Object { $_.OuterXml }) -join '')
    $isLoggingOnly = {
        param($f)
        if (-not ($logRefs.Contains([string]$f.Name) -or ($f.DtsId -and $logRefs.Contains([string]$f.DtsId)))) { return $false }
        $byId   = $f.DtsId -and $refText.IndexOf($f.DtsId, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $byName = $refText.IndexOf("[$($f.Name)]", [StringComparison]::OrdinalIgnoreCase) -ge 0
        return -not ($byId -or $byName)
    }

    # ---- Package-level connection managers ----
    foreach ($cm in $root.SelectNodes('DTS:ConnectionManagers/DTS:ConnectionManager', $ns)) {
        $f = Get-ConnectionFinding -CmNode $cm -Ns $ns -ValueLookup $valueLookup
        $f | Add-Member -NotePropertyName Level -NotePropertyValue 'Package'
        $result.ConnFindings.Add($f)
    }
    # ---- Project-level connection managers actually referenced by this package (matched on DTSID) ----
    foreach ($pc in $ProjectConnections) {
        if ($pc.DtsId -and $XmlText.IndexOf($pc.DtsId, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result.ConnFindings.Add($pc)
        }
    }
    foreach ($f in $result.ConnFindings) {
        if (& $isLoggingOnly $f) {
            # Project connections are shared by every package in the project, so only package-level ones carry the flag.
            if ($f.Level -eq 'Package') { $f.Flags.Add('LoggingOnly') }
            $result.Items.Add([PSCustomObject]@{ Scope = 'Connection'; Path = "Connection[$($f.Name)] ($($f.Level))"; Identity = ('{0}|{1}' -f $f.CreationName, $f.Provider); Rule = $PropertyRule.LoggingOnly; Disabled = $false })
            continue
        }
        $result.Items.Add([PSCustomObject]@{ Scope = 'Connection'; Path = "Connection[$($f.Name)] ($($f.Level))"; Identity = ('{0}|{1}' -f $f.CreationName, $f.Provider); Rule = $f.Rule; Disabled = $false })
        # Independent connection flags become their own evidence items so they participate in routing.
        if ($f.Flags -contains 'WindowsAuth') {
            $result.Items.Add([PSCustomObject]@{ Scope = 'Connection'; Path = "Connection[$($f.Name)]"; Identity = 'WindowsAuth'; Disabled = $false
                Rule = (New-Rule Connection '' 'Windows authentication' AdfNative-Medium '' NeedsConfiguration 'ADF needs a Self-hosted IR with a Windows-auth linked service (or switch to SQL/Entra auth); Azure-SSIS IR needs Windows auth configuration.') })
        }
        if ($f.Flags -contains 'LocalOrUncPath') {
            $result.Items.Add([PSCustomObject]@{ Scope = 'Connection'; Path = "Connection[$($f.Name)]"; Identity = 'LocalOrUncPath'; Disabled = $false
                Rule = (New-Rule Connection '' 'Local drive / UNC file path' AdfNative-Medium '' NeedsConfiguration 'Path must be reachable from the runtime: Self-hosted IR for ADF; VNet + file share access for Azure-SSIS IR.') })
        }
        if ($f.Flags -contains 'ExpressionLocalOrUncPath') {
            $result.Items.Add([PSCustomObject]@{ Scope = 'Connection'; Path = "Connection[$($f.Name)]"; Identity = 'ExpressionLocalOrUncPath'; Rule = $PropertyRule.ExprPath; Disabled = $false })
        }
        if ($f.Flags -contains 'FixedWidthOrRagged') {
            $result.Items.Add([PSCustomObject]@{ Scope = 'Connection'; Path = "Connection[$($f.Name)]"; Identity = 'FixedWidthOrRagged'; Rule = $PropertyRule.FixedWidth; Disabled = $false })
        }
    }

    # ---- Executables: every task and container, including those inside event handlers ----
    foreach ($exe in $root.SelectNodes('//DTS:Executable', $ns)) {
        if ($exe -eq $root) { continue }                                      # the package itself
        $type     = Get-DtsAttr $exe 'ExecutableType'
        $path     = Get-DtsAttr $exe 'refId'; if (-not $path) { $path = Get-DtsAttr $exe 'ObjectName' }
        $disabled = Test-DisabledInTree -Node $exe -Root $root
        $rule     = Get-RuleMatch -Scope Task -Identity $type
        $result.TaskCount++
        if ($disabled) { $result.DisabledTaskCount++ }
        if ($rule.Name -eq 'Script Task') { $result.ScriptTaskCount++ }
        $result.Items.Add([PSCustomObject]@{ Scope = 'Task'; Path = $path; Identity = $type; Rule = $rule; Disabled = $disabled })
        if ((Get-DtsAttr $exe 'TransactionOption') -eq '2') {
            if (-not $disabled) { $result.TransactionRequiredCount++ }
            $result.Items.Add([PSCustomObject]@{ Scope = 'Task'; Path = $path; Identity = 'TransactionOption=Required'; Rule = $PropertyRule.Transaction; Disabled = $disabled })
        }

        # Execute SQL Task: where the statement comes from and what it returns. Defaults (DirectInput, no result
        # set) are omitted from the XML. A statement set by a property expression stays visible in the package and
        # is not flagged here.
        if ($rule.Name -eq 'Execute SQL Task') {
            $sqlData = $exe.SelectSingleNode("DTS:ObjectData/*[local-name()='SqlTaskData']", $ns)
            if ($sqlData) {
                $srcType = $sqlData.GetAttribute('SqlStmtSourceType', $SqlTaskNs)
                if ($srcType -in @('Variable', 'FileConnection')) {
                    if (-not $disabled) { $result.OpaqueSqlCount++ }
                    $result.Items.Add([PSCustomObject]@{ Scope = 'Task'; Path = $path; Identity = ('SqlStmtSourceType={0}' -f $srcType); Rule = $PropertyRule.OpaqueSql; Disabled = $disabled })
                }
                $resType = $sqlData.GetAttribute('ResultType', $SqlTaskNs)
                if ($resType -eq 'ResultSetType_Rowset') {
                    $result.Items.Add([PSCustomObject]@{ Scope = 'Task'; Path = $path; Identity = ('ResultType={0}' -f $resType); Rule = $PropertyRule.FullResultSet; Disabled = $disabled })
                }
            }
        }

        # Script Task: source files and project references are stored in the package (ScriptProject/ProjectItem).
        if ($rule.Name -eq 'Script Task') {
            $sp = $exe.SelectSingleNode("DTS:ObjectData/*[local-name()='ScriptProject']", $ns)
            if ($sp) {
                $code = New-Object System.Text.StringBuilder
                $refs = New-Object System.Collections.Generic.List[string]
                foreach ($pi in $sp.SelectNodes("*[local-name()='ProjectItem']")) {
                    $piName = $pi.GetAttribute('Name')
                    if ($piName -match '\.(cs|vb)$') { [void]$code.AppendLine($pi.InnerText) }
                    elseif ($piName -match '\.(csproj|vbproj)$') {
                        foreach ($m in [regex]::Matches($pi.InnerText, '<Reference\s+Include="([^",]+)')) { $refs.Add($m.Groups[1].Value.Trim()) }
                    }
                }
                Add-ScriptDependencyItems -Result $result -Path $path -Code $code.ToString() -References $refs -Disabled $disabled
            }
        }

        # Foreach Loop enumerator
        $enum = $exe.SelectSingleNode('DTS:ForEachEnumerator', $ns)
        if ($enum) {
            $eType = Get-DtsAttr $enum 'CreationName'
            $result.Items.Add([PSCustomObject]@{ Scope = 'Enumerator'; Path = "$path\Enumerator"; Identity = $eType; Rule = (Get-RuleMatch -Scope Enumerator -Identity $eType); Disabled = $disabled })
        }

        # Execute Package Task: capture child package name for roll-up (project reference or external).
        if ($rule.Name -eq 'Execute Package Task') {
            $ept = $exe.SelectSingleNode('DTS:ObjectData/ExecutePackageTask', $ns)
            if ($ept) {
                $useRef = $ept.SelectSingleNode('UseProjectReference')
                $pkgN   = $ept.SelectSingleNode('PackageName')
                if ($useRef -and $useRef.InnerText -eq 'True' -and $pkgN) { $result.Children.Add($pkgN.InnerText.Trim()) }
                else { $result.Children.Add('EXTERNAL:' + (Get-DtsAttr $exe 'ObjectName')) }
            }
        }

        # Data Flow Task: evaluate every component inside the pipeline.
        if ($rule.Name -eq 'Data Flow Task') {
            $result.DataFlowCount++
            foreach ($comp in $exe.SelectNodes('DTS:ObjectData/pipeline/components/component', $ns)) {
                $classId = $comp.GetAttribute('componentClassID')
                # Managed components (ADO.NET, Script Component, XML Source, DQS, CDC...) share the class
                # Microsoft.ManagedComponentHost; the real type is in the UserComponentTypeName property.
                $userType = ''
                $utNode = $comp.SelectSingleNode("properties/property[@name='UserComponentTypeName']")
                if ($utNode) { $userType = $utNode.InnerText.Trim() }
                $identity = '{0}|{1}' -f $classId, $userType
                $cRule = Get-RuleMatch -Scope Component -Identity $identity
                $result.ComponentCount++
                if ($cRule.Name -eq 'Script Component') {
                    $result.ScriptComponentCount++
                    # SourceCode holds alternating file name / file content array elements.
                    $scCode = New-Object System.Text.StringBuilder
                    $scRefs = New-Object System.Collections.Generic.List[string]
                    foreach ($ae in $comp.SelectNodes("properties/property[@name='SourceCode']/arrayElements/arrayElement")) {
                        [void]$scCode.AppendLine($ae.InnerText)
                        foreach ($m in [regex]::Matches($ae.InnerText, '<Reference\s+Include="([^",]+)')) { $scRefs.Add($m.Groups[1].Value.Trim()) }
                    }
                    Add-ScriptDependencyItems -Result $result -Path ('{0}\{1}' -f $path, $comp.GetAttribute('name')) -Code $scCode.ToString() -References $scRefs -Disabled $disabled
                }
                $result.Items.Add([PSCustomObject]@{ Scope = 'Component'; Path = ('{0}\{1}' -f $path, $comp.GetAttribute('name')); Identity = $identity; Rule = $cRule; Disabled = $disabled })
                # Error outputs: any input/output/column set to redirect failing or truncated rows.
                if ($comp.SelectNodes(".//*[@errorRowDisposition='RedirectRow' or @truncationRowDisposition='RedirectRow']").Count -gt 0) {
                    if (-not $disabled) { $result.ErrorRowRedirectCount++ }
                    $result.Items.Add([PSCustomObject]@{ Scope = 'Component'; Path = ('{0}\{1}' -f $path, $comp.GetAttribute('name')); Identity = 'ErrorRowRedirect'; Rule = $PropertyRule.ErrorRows; Disabled = $disabled })
                }
            }
        }
    }
    return [PSCustomObject]$result
}

function Resolve-PackageRoute {
    <#
        Applies precedence across all enabled evidence items. Returns route, Azure-SSIS IR fit, every reason,
        and the SQL Server 2025 lifecycle flags. Rules ACCUMULATE: nothing a later rule finds can hide an earlier one.
    #>
    param([Parameter(Mandatory)]$Analysis, [Parameter(Mandatory)][string]$TargetVersion, [string[]]$ExtraDeprecated = @())
    if ($Analysis.ParseStatus -ne 'Parsed') {
        return [PSCustomObject]@{ Route = 'ReviewRequired'; AzureIr = 'Review'; Reasons = $Analysis.ParseDetail; Removed = ''; Deprecated = ($ExtraDeprecated -join '; ')
                                  Drivers = @([PSCustomObject]@{ Category = 'ReviewRequired'; Name = 'Could not be read'; Text = $Analysis.ParseDetail }) }
    }
    $route = 'AdfNative-Low'; $ir = 'Compatible'
    $reasons = New-Object System.Collections.Generic.SortedSet[string]
    $drivers = [ordered]@{}                                             # 'Category|Name' -> plain-language driver
    $removed = New-Object System.Collections.Generic.SortedSet[string]
    $deprec  = New-Object System.Collections.Generic.SortedSet[string]
    foreach ($d in $ExtraDeprecated) { [void]$deprec.Add($d) }

    foreach ($it in $Analysis.Items) {
        if ($it.Disabled) { continue }                                  # disabled tasks never execute
        $cat = Resolve-Category -Rule $it.Rule -TargetVersion $TargetVersion
        if ($RouteSeverity[$cat] -gt $RouteSeverity[$route]) { $route = $cat }
        if ($IrSeverity[$it.Rule.AzureIr] -gt $IrSeverity[$ir]) { $ir = $it.Rule.AzureIr }
        if ($cat -ne 'AdfNative-Low') { [void]$reasons.Add(('{0}: {1}' -f $cat, $it.Rule.Name)) }
        $dk = '{0}|{1}' -f $cat, $it.Rule.Name
        if (-not $drivers.Contains($dk)) { $drivers[$dk] = [PSCustomObject]@{ Category = $cat; Name = $it.Rule.Name; Text = (Get-RuleExplanation -Rule $it.Rule) } }
        switch ($it.Rule.Lifecycle) {
            'Removed2025'      { [void]$removed.Add("$($it.Rule.Name) (removed)") }
            'Discontinued2025' { [void]$removed.Add("$($it.Rule.Name) (discontinued)") }
            'Deprecated2025'   { [void]$deprec.Add($it.Rule.Name) }
        }
    }
    if ($removed.Count -gt 0 -and $TargetVersion -ne '2025') {
        [void]$reasons.Add("FutureRisk: SQL Server 2025 removals present - host must stay at SQL Server $TargetVersion or earlier until remediated")
        $drivers['FutureRisk'] = [PSCustomObject]@{ Category = 'FutureRisk'; Name = 'Future risk'
            Text = "Uses components that Microsoft removed in SQL Server 2025 (see Removed2025). The package runs on the planned SQL Server $TargetVersion host, but must be fixed before that host is upgraded to 2025." }
    }
    if ($reasons.Count -eq 0) { [void]$reasons.Add('Only Copy / SQL / orchestration constructs found') }
    [PSCustomObject]@{
        Route = $route; AzureIr = $ir; Reasons = (@($reasons) -join '; ')
        Removed = (@($removed) -join '; '); Deprecated = (@($deprec) -join '; '); Drivers = @($drivers.Values)
    }
}

function Add-PackageResult {
    <#
        Runs analysis + routing for one package and appends the package row, evidence rows and connection rows.
        Context carries source metadata (environment, server, folder, project, source type, target version).
    #>
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$PackageName,
          [Parameter(Mandatory)][string]$XmlText, [object[]]$ProjectConnections = @(), [string[]]$ExtraDeprecated = @())

    $a = Get-PackageAnalysis -XmlText $XmlText -ProjectConnections $ProjectConnections
    $r = Resolve-PackageRoute -Analysis $a -TargetVersion $Context.TargetVersion -ExtraDeprecated $ExtraDeprecated
    $key = '{0}|{1}|{2}|{3}' -f $Context.Server, $Context.Folder, $Context.Project, $PackageName

    foreach ($it in $a.Items) {
        $Evidence.Add([PSCustomObject]@{
            RunId = $RunId; Environment = $Context.Environment; ServerInstance = $Context.Server
            SourceType = $Context.SourceType; Folder = $Context.Folder; Project = $Context.Project; Package = $PackageName
            Scope = $it.Scope; ElementPath = $it.Path; TypeIdentity = $it.Identity; Disabled = $it.Disabled
            RuleName = $it.Rule.Name; Category = (Resolve-Category -Rule $it.Rule -TargetVersion $Context.TargetVersion)
            Lifecycle2025 = $it.Rule.Lifecycle; AzureSsisIr = $it.Rule.AzureIr; Note = $it.Rule.Note
            Explanation = (Get-RuleExplanation -Rule $it.Rule)
        })
    }
    foreach ($f in $a.ConnFindings) {
        $Connections.Add([PSCustomObject]@{
            RunId = $RunId; Environment = $Context.Environment; ServerInstance = $Context.Server
            Folder = $Context.Folder; Project = $Context.Project; Package = $PackageName; Level = $f.Level
            ConnectionName = $f.Name; CreationName = $f.CreationName; Provider = $f.Provider
            RuleName = $f.Rule.Name; Flags = ($f.Flags -join ';'); ConnectionStringMasked = $f.ConnectionString
        })
    }
    $Packages.Add([PSCustomObject]@{
        RunId = $RunId; Key = $key; Environment = $Context.Environment; ServerInstance = $Context.Server
        SourceType = $Context.SourceType; Folder = $Context.Folder; Project = $Context.Project; Package = $PackageName
        TargetSsisVersion = $Context.TargetVersion; ParseStatus = $a.ParseStatus; PackageFormatVersion = $a.FormatVersion
        ProtectionLevel = $a.ProtectionLevel
        PackageRoute = $r.Route; EffectiveRoute = $r.Route; EffectiveRouteLabel = $RouteLabel[$r.Route]
        RouteReasons = $r.Reasons; AzureSsisIrFit = $r.AzureIr
        Removed2025 = $r.Removed; Deprecated2025 = $r.Deprecated
        TaskCount = $a.TaskCount; DisabledTasks = $a.DisabledTaskCount; DataFlowTasks = $a.DataFlowCount
        DataFlowComponents = $a.ComponentCount; ScriptTasks = $a.ScriptTaskCount; ScriptComponents = $a.ScriptComponentCount
        PropertyExpressions = $a.ExpressionCount; EventHandlers = $a.EventHandlerCount
        TransactionsRequired = $a.TransactionRequiredCount; CheckpointsEnabled = $a.CheckpointsEnabled
        ErrorRowRedirects = $a.ErrorRowRedirectCount; PackageConfigurations = ($a.Configurations -join '; ')
        LogProviders = ((@($a.LogProviders) | Sort-Object -Unique) -join '; ')
        OpaqueSqlStatements = $a.OpaqueSqlCount; ScriptDependencies = (@($a.ScriptDependencies) -join '; ')
        ConnectionTypes = ((@($a.ConnFindings | ForEach-Object { $_.Rule.Name }) | Sort-Object -Unique) -join '; ')
        ChildPackages = ($a.Children -join '; '); RolledUpFrom = ''
        Executions = $null; FailedExecutions = $null; LastExecutionStart = $null; AvgDurationMin = $null; MaxDurationMin = $null
        AgentJobs = ''; AgentSchedules = ''; Uses32BitJobStep = $false; Drivers = $r.Drivers
    })
}
#endregion

#region ============================== 5. SOURCE: SSISDB / MSDB / AGENT ===========================

function Invoke-ServerAssessment {
    param([Parameter(Mandatory)][string]$Server, [string]$Env, [string]$Target)
    Write-Log -Level STEP -Message "Server $Server  (Environment=$Env, Target=SQL Server $Target)"

    # ---- Connectivity, version and SSISDB presence ----
    try {
        $info = Invoke-ReadQuery -Server $Server -Database 'master' -Query @"
SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
       CAST(SERVERPROPERTY('ProductMajorVersion') AS int)      AS MajorVersion,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128))        AS Edition,
       CAST(@@SERVERNAME AS nvarchar(128))                     AS ServerName,
       CASE WHEN DB_ID('SSISDB') IS NULL THEN 0 ELSE 1 END     AS HasSsisdb;
"@
    }
    catch { Add-AssessmentError -Server $Server -Scope 'Connect' -Object $Server -Message $_.Exception.Message; return }
    # Two names for one server (alias, IP, '.', listener) would list every package twice: assess it once.
    $already = @($SourceServerNames.Keys | Where-Object { $SourceServerNames[$_] -eq [string]$info.ServerName })
    if ($already.Count -gt 0) {
        Write-Log -Level WARN -Message ("  {0} is the same server ({1}) as {2}, already assessed in this run; skipped so its packages are not listed twice." -f $Server, $info.ServerName, $already[0])
        return
    }
    $SourceServerNames[$Server] = [string]$info.ServerName
    Write-Log -Message ("  SQL Server {0} ({1}), SSISDB present: {2}" -f $info.ProductVersion, $info.Edition, [bool]$info.HasSsisdb)
    if ($info.MajorVersion -lt 13) { Write-Log -Level WARN -Message '  Source is older than SQL Server 2016; outside the validated range but will be attempted.' }

    # ---- SSISDB (project deployment model) ----
    if ($info.HasSsisdb) {
        # Row-level security check: without ssis_admin/sysadmin, projects without READ are silently invisible.
        $perm = Invoke-ReadQuery -Server $Server -Database 'SSISDB' -Query "SELECT ISNULL(IS_MEMBER('ssis_admin'),0) AS IsSsisAdmin, ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) AS IsSysadmin;"
        if (-not $perm.IsSsisAdmin -and -not $perm.IsSysadmin) {
            Write-Log -Level WARN -Message '  Login is neither ssis_admin nor sysadmin: SSISDB row-level security may hide projects. Results can be incomplete.'
            Add-AssessmentError -Server $Server -Scope 'Permissions' -Object 'SSISDB' -Message 'Not ssis_admin/sysadmin; project list may be incomplete (row-level security, no error raised).'
        }

        $projects = @(Invoke-ReadQuery -Server $Server -Database 'SSISDB' -Query @"
SELECT f.name AS FolderName, p.name AS ProjectName, p.project_id AS ProjectId, p.last_deployed_time AS LastDeployed
FROM   [catalog].projects AS p
JOIN   [catalog].folders  AS f ON f.folder_id = p.folder_id
ORDER BY f.name, p.name;
"@)
        Write-Log -Message ("  SSISDB projects visible: {0}" -f $projects.Count)

        # Run history per package (catalog.executions exists in 2012+; status 4 = failed, 7 = succeeded).
        $history = @{}
        try {
            foreach ($h in Invoke-ReadQuery -Server $Server -Database 'SSISDB' -Parameters @{ '@days' = $HistoryDays } -Query @"
SELECT e.folder_name, e.project_name, e.package_name,
       COUNT(*)                                             AS Executions,
       SUM(CASE WHEN e.status = 4 THEN 1 ELSE 0 END)        AS FailedExecutions,
       MAX(e.start_time)                                    AS LastExecutionStart,
       CAST(AVG(DATEDIFF(SECOND, e.start_time, e.end_time) / 60.0) AS decimal(12,2)) AS AvgDurationMin,
       CAST(MAX(DATEDIFF(SECOND, e.start_time, e.end_time) / 60.0) AS decimal(12,2)) AS MaxDurationMin
FROM   [catalog].executions AS e
WHERE  e.start_time >= DATEADD(DAY, -@days, SYSDATETIMEOFFSET())
GROUP BY e.folder_name, e.project_name, e.package_name;
"@) { $history['{0}|{1}|{2}|{3}' -f $Server, $h.folder_name, $h.project_name, $h.package_name] = $h }
        }
        catch { Add-AssessmentError -Server $Server -Scope 'History' -Object 'catalog.executions' -Message $_.Exception.Message }

        foreach ($proj in $projects) {
            $label = '{0}\{1}' -f $proj.FolderName, $proj.ProjectName
            try {
                $bytes = Get-SsisdbProjectBytes -Server $Server -Folder $proj.FolderName -Project $proj.ProjectName
                if (-not $bytes) { throw 'catalog.get_project returned no data.' }
                $parts = @(Expand-IspacBytes -Bytes $bytes)
            }
            catch { Add-AssessmentError -Server $Server -Scope 'ProjectExport' -Object $label -Message $_.Exception.Message; continue }

            $projConns = Get-ProjectConnectionFindings -Parts $parts
            $ctx = @{ Environment = $Env; Server = $Server; SourceType = 'SSISDB'; Folder = $proj.FolderName; Project = $proj.ProjectName; TargetVersion = $Target }
            foreach ($pkg in ($parts | Where-Object Kind -eq 'Package')) {
                try { Add-PackageResult -Context $ctx -PackageName $pkg.Name -XmlText $pkg.Text -ProjectConnections $projConns }
                catch { Add-AssessmentError -Server $Server -Scope 'PackageParse' -Object "$label\$($pkg.Name)" -Message $_.Exception.Message }
            }
            Write-Log -Message ("  {0}: {1} package(s)" -f $label, @($parts | Where-Object Kind -eq 'Package').Count)
        }

        # Attach run history to the package rows for this server.
        foreach ($p in $Packages) {
            if ($p.ServerInstance -ne $Server -or $p.SourceType -ne 'SSISDB') { continue }
            $h = $history[$p.Key]
            if ($h) {
                $p.Executions = $h.Executions; $p.FailedExecutions = $h.FailedExecutions
                $p.LastExecutionStart = $h.LastExecutionStart; $p.AvgDurationMin = $h.AvgDurationMin; $p.MaxDurationMin = $h.MaxDurationMin
            }
            else { $p.Executions = 0; $p.FailedExecutions = 0 }
        }
    }

    # ---- msdb package store (package deployment model; legacy Integration Services Service) ----
    if ($IncludeMsdbPackages) {
        try {
            $msdbPkgs = @(Invoke-ReadQuery -Server $Server -Database 'msdb' -Query @"
-- Root folder has parentfolderid NULL and an empty name; build paths like \Folder\SubFolder beneath it.
WITH folders AS (
    SELECT folderid, CAST(N'' AS nvarchar(4000)) AS FolderPath
    FROM   dbo.sysssispackagefolders WHERE parentfolderid IS NULL
    UNION ALL
    SELECT c.folderid, CAST(f.FolderPath + N'\' + c.foldername AS nvarchar(4000))
    FROM   dbo.sysssispackagefolders AS c JOIN folders AS f ON c.parentfolderid = f.folderid
    WHERE  c.folderid <> f.folderid
)
SELECT ISNULL(NULLIF(f.FolderPath, N''), N'\') AS FolderPath, p.name AS PackageName,
       CAST(p.packagedata AS varbinary(max)) AS PackageData
FROM   dbo.sysssispackages AS p
LEFT JOIN folders AS f ON f.folderid = p.folderid
WHERE  ISNULL(f.FolderPath, N'') NOT LIKE N'\Data Collector%'   -- exclude SQL Server's own Data Collector packages
  AND  ISNULL(f.FolderPath, N'') NOT LIKE N'\Maintenance Plans%'; -- maintenance plans are DBA jobs, not ETL
"@)
            # Say how many msdb packages were left out on purpose, so a short count is never a mystery.
            $msdbTotal = [int](@(Invoke-ReadQuery -Server $Server -Database 'msdb' -Query 'SELECT COUNT(*) AS n FROM dbo.sysssispackages;')[0].n)
            $msdbSkipped = $msdbTotal - $msdbPkgs.Count
            Write-Log -Message ("  msdb packages: {0}{1}" -f $msdbPkgs.Count, $(if ($msdbSkipped -gt 0) { " ($msdbSkipped not assessed: SQL Server's own Data Collector packages and maintenance plans)" } else { '' }))
            foreach ($m in $msdbPkgs) {
                $ctx = @{ Environment = $Env; Server = $Server; SourceType = 'MSDB'; Folder = $m.FolderPath; Project = '(package deployment)'; TargetVersion = $Target }
                try {
                    Add-PackageResult -Context $ctx -PackageName ($m.PackageName + '.dtsx') -XmlText (ConvertFrom-PackageBytes -Bytes ([byte[]]$m.PackageData)) `
                        -ExtraDeprecated @('Package deployment model / legacy Integration Services Service (deprecated in SQL Server 2025)')
                }
                catch { Add-AssessmentError -Server $Server -Scope 'PackageParse' -Object "msdb$($m.FolderPath)\$($m.PackageName)" -Message $_.Exception.Message }
            }
        }
        catch { Add-AssessmentError -Server $Server -Scope 'msdb' -Object 'sysssispackages' -Message $_.Exception.Message }
    }

    # ---- SQL Agent SSIS job steps: schedules and 32-bit execution ----
    if ($IncludeAgentJobs) {
        try {
            $steps = @(Invoke-ReadQuery -Server $Server -Database 'msdb' -Query @"
SELECT j.name AS JobName, j.enabled AS JobEnabled, s.step_id AS StepId, s.step_name AS StepName,
       s.command AS Command,
       CASE WHEN s.command LIKE N'%/X86%' THEN 1 ELSE 0 END AS Uses32Bit
FROM   dbo.sysjobs AS j JOIN dbo.sysjobsteps AS s ON s.job_id = j.job_id
WHERE  s.subsystem = N'SSIS';
"@)
            Write-Log -Message ("  SSIS Agent job steps: {0}" -f $steps.Count)
            # Schedules of the jobs that have SSIS steps, described in words (built here, not with STRING_AGG,
            # so SQL Server 2016 sources work too).
            $schedRows = @(Invoke-ReadQuery -Server $Server -Database 'msdb' -Query @"
SELECT j.name AS JobName, j.enabled AS JobEnabled, s.enabled AS ScheduleEnabled, s.freq_type, s.freq_interval, s.freq_subday_type,
       s.freq_subday_interval, s.freq_relative_interval, s.freq_recurrence_factor, s.active_start_date, s.active_start_time, s.active_end_time
FROM   dbo.sysjobs AS j
LEFT JOIN dbo.sysjobschedules AS js ON js.job_id = j.job_id
LEFT JOIN dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
WHERE  EXISTS (SELECT 1 FROM dbo.sysjobsteps AS st WHERE st.job_id = j.job_id AND st.subsystem = N'SSIS')
ORDER BY j.name, s.schedule_id;
"@)
            $jobSchedules = @{}
            foreach ($g in ($schedRows | Group-Object JobName)) {
                $texts = @($g.Group | Where-Object { $_.freq_type -isnot [DBNull] -and $null -ne $_.freq_type } | ForEach-Object { Format-AgentSchedule $_ })
                $jobText = if ($texts.Count) { $texts -join '; ' } else { 'no schedule (runs only when started by hand or by another job)' }
                if (-not [bool]$g.Group[0].JobEnabled) { $jobText = "job disabled; $jobText" }
                $jobSchedules[$g.Name] = $jobText
            }
            foreach ($s in $steps) {
                $JobSteps.Add([PSCustomObject]@{ RunId = $RunId; Environment = $Env; ServerInstance = $Server; JobName = $s.JobName
                    JobEnabled = [bool]$s.JobEnabled; StepId = $s.StepId; StepName = $s.StepName; Uses32Bit = [bool]$s.Uses32Bit
                    JobSchedules = $(if ($jobSchedules.ContainsKey([string]$s.JobName)) { $jobSchedules[[string]$s.JobName] } else { '' }); Command = $s.Command })
            }
            # Match job steps to packages by catalog path (\SSISDB\folder\project\package.dtsx) or package name.
            foreach ($p in $Packages) {
                if ($p.ServerInstance -ne $Server) { continue }
                $catalogPath = '\SSISDB\{0}\{1}\{2}' -f $p.Folder, $p.Project, $p.Package
                $msdbName    = [IO.Path]::GetFileNameWithoutExtension($p.Package)
                $hits = @($steps | Where-Object {
                    ($p.SourceType -eq 'SSISDB' -and $_.Command.IndexOf($catalogPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                    # msdb step command looks like:  /SQL "\"\Folder\PackageName\"" /SERVER ...
                    ($p.SourceType -eq 'MSDB'   -and $_.Command -match ('/SQL\s+\S*\\' + [regex]::Escape($msdbName) + '\\?"'))
                })
                if ($hits.Count -gt 0) {
                    $jobNames = @(($hits | ForEach-Object { [string]$_.JobName }) | Sort-Object -Unique)
                    $p.AgentJobs = $jobNames -join '; '
                    $p.AgentSchedules = (@($jobNames | ForEach-Object { '{0}: {1}' -f $_, $(if ($jobSchedules.ContainsKey($_)) { $jobSchedules[$_] } else { 'schedule not read' }) })) -join ' | '
                    if (@($hits | Where-Object Uses32Bit).Count -gt 0) {
                        $p.Uses32BitJobStep = $true
                        $p.Deprecated2025 = (@($p.Deprecated2025, '32-bit execution (/X86) in Agent job step') | Where-Object { $_ }) -join '; '
                    }
                }
            }
        }
        catch { Add-AssessmentError -Server $Server -Scope 'AgentJobs' -Object 'msdb.dbo.sysjobsteps' -Message $_.Exception.Message }
    }
}

function Get-ProjectConnectionFindings {
    <# Parses project-level .conmgr parts once per project so packages can be matched to them by DTSID. #>
    param([object[]]$Parts)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($cmPart in ($Parts | Where-Object Kind -eq 'ConnMgr')) {
        try {
            $x = New-Object System.Xml.XmlDocument; $x.XmlResolver = $null; $x.LoadXml($cmPart.Text)
            $n = New-Object System.Xml.XmlNamespaceManager($x.NameTable); $n.AddNamespace('DTS', $DtsNs)
            $f = Get-ConnectionFinding -CmNode $x.DocumentElement -Ns $n
            $f | Add-Member -NotePropertyName Level -NotePropertyValue 'Project'
            $list.Add($f)
        }
        catch { Write-Log -Level WARN -Message "  Could not parse project connection $($cmPart.Name): $($_.Exception.Message)" }
    }
    return , $list.ToArray()
}
#endregion

#region ============================== 6. SOURCE: FILE SYSTEM / SOURCE CONTROL ====================

function Invoke-FolderAssessment {
    param([Parameter(Mandatory)][string]$Path, [string]$Target)
    Write-Log -Level STEP -Message "Folder $Path  (Target=SQL Server $Target)"
    if (-not (Test-Path -LiteralPath $Path)) { Add-AssessmentError -Server '(file)' -Scope 'Folder' -Object $Path -Message 'Path not found.'; return }

    # Exported/built projects (.ispac): treated exactly like SSISDB exports.
    foreach ($isp in Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.ispac') {
        try {
            $parts = @(Expand-IspacBytes -Bytes ([IO.File]::ReadAllBytes($isp.FullName)))
            $projConns = Get-ProjectConnectionFindings -Parts $parts
            $ctx = @{ Environment = $Environment; Server = '(file)'; SourceType = 'Ispac'; Folder = $isp.DirectoryName; Project = $isp.BaseName; TargetVersion = $Target }
            foreach ($pkg in ($parts | Where-Object Kind -eq 'Package')) {
                try { Add-PackageResult -Context $ctx -PackageName $pkg.Name -XmlText $pkg.Text -ProjectConnections $projConns }
                catch { Add-AssessmentError -Server '(file)' -Scope 'PackageParse' -Object "$($isp.FullName)\$($pkg.Name)" -Message $_.Exception.Message }
            }
        }
        catch { Add-AssessmentError -Server '(file)' -Scope 'IspacRead' -Object $isp.FullName -Message $_.Exception.Message }
    }

    # Loose .dtsx files. A folder containing *.conmgr is treated as an SSIS project folder (source control layout),
    # so project-level connections are matched to its packages.
    foreach ($dir in (Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.dtsx' | Group-Object DirectoryName)) {
        $conmgrParts = @(Get-ChildItem -LiteralPath $dir.Name -File -Filter '*.conmgr' | ForEach-Object {
            [PSCustomObject]@{ Name = $_.Name; Kind = 'ConnMgr'; Text = (ConvertFrom-PackageBytes -Bytes ([IO.File]::ReadAllBytes($_.FullName))) } })
        $projConns = Get-ProjectConnectionFindings -Parts $conmgrParts
        $dtproj = Get-ChildItem -LiteralPath $dir.Name -File -Filter '*.dtproj' | Select-Object -First 1
        $projName = if ($dtproj) { $dtproj.BaseName } else { '(file system)' }
        # Without a .dtproj the packages are file-system deployments (package deployment model, deprecated service).
        $extra = if ($dtproj) { @() } else { @('File-system package / package deployment model (legacy Integration Services Service deprecated in SQL Server 2025)') }
        $ctx = @{ Environment = $Environment; Server = '(file)'; SourceType = 'FileSystem'; Folder = $dir.Name; Project = $projName; TargetVersion = $Target }
        foreach ($f in $dir.Group) {
            try { Add-PackageResult -Context $ctx -PackageName $f.Name -XmlText (ConvertFrom-PackageBytes -Bytes ([IO.File]::ReadAllBytes($f.FullName))) -ProjectConnections $projConns -ExtraDeprecated $extra }
            catch { Add-AssessmentError -Server '(file)' -Scope 'PackageParse' -Object $f.FullName -Message $_.Exception.Message }
        }
        Write-Log -Message ("  {0}: {1} package(s)" -f $dir.Name, $dir.Count)
    }
}
#endregion

#region ============================== 7. SPRINT BACKLOG ==========================================

function Get-ComplexityScore {
    <# Size signal for estimation; the formula is documented with $ComplexityBands. #>
    param([Parameter(Mandatory)]$Package)
    $score = ([int]$Package.TaskCount - [int]$Package.DisabledTasks) + [int]$Package.DataFlowComponents +
             3 * ([int]$Package.ScriptTasks + [int]$Package.ScriptComponents) + [int]$Package.EventHandlers +
             [int]$Package.ErrorRowRedirects + [int]$Package.OpaqueSqlStatements
    if ([int]$Package.TransactionsRequired -gt 0) { $score += 2 }
    if ($Package.CheckpointsEnabled) { $score += 2 }
    [Math]::Max(0, $score)
}

function New-SprintBacklog {
    <#
        One planning row per package, after child roll-up: target platform, work type, complexity, build order,
        the rules that decided the route, usage, and blank columns for the team to fill in.
        BuildOrder is 1 for a package that runs no child in its project, otherwise 1 + its deepest child, so
        building in ascending BuildOrder delivers every child before the parent that executes it.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($grp in ($Packages | Group-Object { '{0}|{1}|{2}' -f $_.ServerInstance, $_.Folder, $_.Project })) {
        $lookup = @{}; foreach ($p in $grp.Group) { $lookup[$p.Package] = $p }
        $calledBy = @{}
        foreach ($p in $grp.Group) {
            foreach ($c in @($p.ChildPackages -split '; ' | Where-Object { $_ -and $lookup.ContainsKey($_) })) {
                if (-not $calledBy.ContainsKey($c)) { $calledBy[$c] = New-Object System.Collections.Generic.List[string] }
                $calledBy[$c].Add($p.Package)
            }
        }
        # Depth resolver with cycle protection (visited set), memoised per project.
        $order = @{}
        $depth = $null
        $depth = {
            param($pkg, $visited)
            if ($order.ContainsKey($pkg.Package)) { return $order[$pkg.Package] }
            $d = 1
            foreach ($c in @($pkg.ChildPackages -split '; ' | Where-Object { $_ })) {
                if (-not $lookup.ContainsKey($c) -or $visited.Contains($c)) { continue }
                [void]$visited.Add($c)
                $d = [Math]::Max($d, 1 + (& $depth $lookup[$c] $visited))
                [void]$visited.Remove($c)
            }
            $order[$pkg.Package] = $d
            $d
        }
        foreach ($p in $grp.Group) {
            $plan = $RoutePlanning[$p.EffectiveRoute]
            $visited = New-Object System.Collections.Generic.HashSet[string]
            [void]$visited.Add($p.Package)
            $buildOrder = & $depth $p $visited

            $score = Get-ComplexityScore -Package $p
            $band = 'XL'
            foreach ($b in $ComplexityBands.Keys) { if ($score -le $ComplexityBands[$b]) { $band = $b; break } }
            if ($p.ParseStatus -ne 'Parsed') { $band = 'TBD' }      # nothing was read, so there is nothing to size

            # Decision drivers, in plain language: the findings that set the package's own route (one summary line
            # when that route is AdfNative-Low), the SQL Server 2025 future risk, and any harder child it runs.
            $own = @($p.Drivers | Where-Object { $_.Category -eq $p.PackageRoute -or $_.Category -eq 'FutureRisk' })
            $drivers = @($own | Where-Object { $_.Name -notlike 'Package configuration (*' } | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Text })
            $configs = @($own | Where-Object { $_.Name -like 'Package configuration (*' } | ForEach-Object { $_.Name -replace '^Package configuration \((.+)\)$', '$1' })
            if ($configs.Count -gt 0) {
                $drivers += 'Package configurations ({0}): {1}' -f ($configs -join ', '), ($RuleExplanationPattern['^Package configuration \((.+)\)$'] -f ($configs -join ', '))
            }
            if ($p.PackageRoute -eq 'AdfNative-Low') {
                $drivers = @('Every step has a direct ADF equivalent (Copy, Script or Stored Procedure, Execute Pipeline), so this is a straightforward rewrite.') +
                           @($own | Where-Object Category -eq 'FutureRisk' | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Text })
            }
            # Children that make the route harder come first: they decide the EffectiveRoute.
            $childDrivers = @()
            foreach ($child in @($p.ChildPackages -split '; ' | Where-Object { $_ })) {
                if ($child -like 'EXTERNAL:*') {
                    $childDrivers += 'Runs a child package stored outside this project ({0}) that the scan could not read, so this route cannot be confirmed until that child is assessed.' -f ($child -replace '^EXTERNAL:')
                }
                elseif ($lookup.ContainsKey($child) -and $RouteSeverity[$lookup[$child].EffectiveRoute] -gt $RouteSeverity[$p.PackageRoute]) {
                    $childDrivers += 'Runs child package {0}, which is planned for {1}, so this package cannot move before it.' -f $child, $RoutePlanning[$lookup[$child].EffectiveRoute].Platform
                }
            }
            $drivers = @($childDrivers) + @($drivers)

            $usage = if ($p.SourceType -ne 'SSISDB') { 'No run history (not an SSISDB package)' }
                     elseif ([int]$p.Executions -eq 0) { "Not run in the last $HistoryDays days - confirm it is still needed" }
                     elseif ([int]$p.FailedExecutions -gt 0) { '{0} runs, {1} failed, in the last {2} days' -f $p.Executions, $p.FailedExecutions, $HistoryDays }
                     else { '{0} runs in the last {1} days' -f $p.Executions, $HistoryDays }

            # Proposed default for the team to confirm: 'Review' only when SSISDB history shows no run in the window.
            $isMigrating = if ($p.SourceType -eq 'SSISDB' -and [int]$p.Executions -eq 0) { 'Review' } else { 'Yes' }

            $rows.Add([PSCustomObject]@{
                Environment = $p.Environment; ServerInstance = $p.ServerInstance
                SourceServerName = $(if ($SourceServerNames.ContainsKey([string]$p.ServerInstance)) { $SourceServerNames[[string]$p.ServerInstance] } else { $p.ServerInstance })
                Folder = $p.Folder; Project = $p.Project
                Package = $p.Package; PackageLocation = $PackageLocationLabel[[string]$p.SourceType]; isMigrating = $isMigrating
                TargetPlatform = $plan.Platform; Route = $p.EffectiveRoute; WorkType = $plan.WorkType
                ComplexityBand = $band; ComplexityScore = $score; BuildOrder = $buildOrder
                DependsOn = $p.ChildPackages
                CalledBy = $(if ($calledBy.ContainsKey($p.Package)) { (@($calledBy[$p.Package]) | Sort-Object -Unique) -join '; ' } else { '' })
                DecisionDrivers = ($drivers -join ' | '); AzureSsisIrFit = $p.AzureSsisIrFit; Removed2025 = $p.Removed2025
                Usage = $usage; LastExecutionStart = $p.LastExecutionStart; AvgDurationMin = $p.AvgDurationMin; AgentJobs = $p.AgentJobs
                AgentSchedules = $p.AgentSchedules
                BusinessOwner = ''; Developer = ''; Sprint = ''; Status = ''; Decision = ''; Notes = ''
                PlatformOrder = $plan.Order
            })
        }
    }
    $rows | Sort-Object Environment, PlatformOrder, Project, BuildOrder, Package | Select-Object * -ExcludeProperty PlatformOrder
}

function Get-XlsxColumnName {
    <# 1 -> A, 27 -> AA. #>
    param([Parameter(Mandatory)][int]$Index)
    $name = ''
    while ($Index -gt 0) { $m = ($Index - 1) % 26; $name = [string][char](65 + $m) + $name; $Index = [int][Math]::Floor(($Index - 1) / 26) }
    $name
}

function Write-XlsxWorkbook {
    <#
        Writes a minimal Office Open XML workbook with no module dependency (ImportExcel and Excel are not needed
        on the assessment host). Each sheet: bold header row, frozen header, AutoFilter, column widths sized to
        content. Strings are inline strings, so a value starting with '=' is text, never a formula.
        Sheets: ordered list of @{ Name = '...'; Columns = @('...'); Rows = @(objects) }.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Sheets)
    $main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $rel  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $esc = {
        param($v)
        if ($null -eq $v -or $v -is [DBNull]) { return '' }
        $s = if ($v -is [datetime]) { $v.ToString('yyyy-MM-dd HH:mm:ss') } else { [string]$v }
        [Security.SecurityElement]::Escape([regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''))
    }
    $parts = [ordered]@{}
    $ct = New-Object System.Text.StringBuilder
    [void]$ct.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
    [void]$ct.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>')
    [void]$ct.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    [void]$ct.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
    $wb = New-Object System.Text.StringBuilder
    [void]$wb.Append("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"$main`" xmlns:r=`"$rel`"><sheets>")
    $wbRels = New-Object System.Text.StringBuilder
    [void]$wbRels.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
    $names = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $Sheets.Count; $i++) {
        $sheet = $Sheets[$i]; $n = $i + 1
        # Sheet names: max 31 characters, none of : \ / ? * [ ]
        $sheetName = ([regex]::Replace([string]$sheet.Name, '[:\\/\?\*\[\]]', '-'))
        if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }
        $cols = @($sheet.Columns); $rows = @($sheet.Rows)
        $lastCol = Get-XlsxColumnName -Index $cols.Count
        $ref = 'A1:{0}{1}' -f $lastCol, ($rows.Count + 1)

        $widths = @($cols | ForEach-Object { [Math]::Max(10, $_.Length + 4) })
        $sd = New-Object System.Text.StringBuilder
        [void]$sd.Append('<row r="1">')
        for ($c = 0; $c -lt $cols.Count; $c++) {
            [void]$sd.Append(('<c r="{0}1" t="inlineStr" s="1"><is><t>{1}</t></is></c>' -f (Get-XlsxColumnName -Index ($c + 1)), (& $esc $cols[$c])))
        }
        [void]$sd.Append('</row>')
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $rn = $r + 2
            [void]$sd.Append("<row r=`"$rn`">")
            for ($c = 0; $c -lt $cols.Count; $c++) {
                $v = $rows[$r].($cols[$c]); $cell = '{0}{1}' -f (Get-XlsxColumnName -Index ($c + 1)), $rn
                if ($null -eq $v -or $v -is [DBNull] -or [string]$v -eq '') { continue }
                if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
                    [void]$sd.Append(('<c r="{0}"><v>{1}</v></c>' -f $cell, ([IFormattable]$v).ToString($null, [Globalization.CultureInfo]::InvariantCulture)))
                    $len = ([string]$v).Length
                }
                else {
                    $t = & $esc $v
                    [void]$sd.Append(('<c r="{0}" t="inlineStr"><is><t xml:space="preserve">{1}</t></is></c>' -f $cell, $t))
                    $len = ([string]$v).Length
                }
                if ($len + 2 -gt $widths[$c]) { $widths[$c] = [Math]::Min(80, $len + 2) }
            }
            [void]$sd.Append('</row>')
        }
        $colXml = (0..($cols.Count - 1) | ForEach-Object { '<col min="{0}" max="{0}" width="{1}" customWidth="1"/>' -f ($_ + 1), $widths[$_] }) -join ''
        $parts["xl/worksheets/sheet$n.xml"] = ("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><worksheet xmlns=`"$main`">" +
            '<sheetViews><sheetView workbookViewId="0"' + $(if ($n -eq 1) { ' tabSelected="1"' } else { '' }) + '><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>' +
            "<cols>$colXml</cols><sheetData>$($sd.ToString())</sheetData><autoFilter ref=`"$ref`"/></worksheet>")

        [void]$ct.Append("<Override PartName=`"/xl/worksheets/sheet$n.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>")
        [void]$wb.Append(('<sheet name="{0}" sheetId="{1}" r:id="rId{1}"/>' -f (& $esc $sheetName), $n))
        [void]$wbRels.Append("<Relationship Id=`"rId$n`" Type=`"$rel/worksheet`" Target=`"worksheets/sheet$n.xml`"/>")
        $quoted = "'" + $sheetName.Replace("'", "''") + "'"
        [void]$names.Append(('<definedName name="_xlnm._FilterDatabase" localSheetId="{0}" hidden="1">{1}!$A$1:${2}${3}</definedName>' -f $i, (& $esc $quoted), $lastCol, ($rows.Count + 1)))
    }
    [void]$ct.Append('</Types>')
    [void]$wb.Append("</sheets><definedNames>$($names.ToString())</definedNames></workbook>")
    [void]$wbRels.Append(('<Relationship Id="rId{0}" Type="{1}/styles" Target="styles.xml"/></Relationships>' -f ($Sheets.Count + 1), $rel))

    $parts['[Content_Types].xml'] = $ct.ToString()
    $parts['_rels/.rels'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Id=`"rId1`" Type=`"$rel/officeDocument`" Target=`"xl/workbook.xml`"/></Relationships>"
    $parts['xl/workbook.xml'] = $wb.ToString()
    $parts['xl/_rels/workbook.xml.rels'] = $wbRels.ToString()
    $parts['xl/styles.xml'] = ("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><styleSheet xmlns=`"$main`">" +
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>' +
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill></fills>' +
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs>' +
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>')

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Create)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($k in $parts.Keys) {
                $w = New-Object System.IO.StreamWriter($zip.CreateEntry($k).Open(), $utf8)
                try { $w.Write($parts[$k]) } finally { $w.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }
    finally { $fs.Dispose() }
}

function Export-SprintBacklog {
    <# Writes sprint_backlog.csv (every server) to -Folder and one workbook per source server to -WorkbookFolder:
       <ServerName>_SSIS_Migration_Assessment_<Stamp>.xlsx with Summary, Backlog, one sheet per platform, Legend.
       Returns the workbook paths. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Backlog, [Parameter(Mandatory)][string]$Folder,
          [Parameter(Mandatory)][string]$WorkbookFolder, [Parameter(Mandatory)][string]$Stamp)
    # ServerInstance (the name the run connected with) is left out: SourceServerName identifies the server.
    $columns = @('Environment', 'SourceServerName', 'Folder', 'Project', 'Package', 'PackageLocation', 'isMigrating',
                 'TargetPlatform', 'Route', 'WorkType', 'ComplexityBand', 'ComplexityScore', 'BuildOrder', 'DependsOn', 'CalledBy', 'DecisionDrivers', 'AzureSsisIrFit',
                 'Removed2025', 'Usage', 'LastExecutionStart', 'AvgDurationMin', 'AgentJobs', 'AgentSchedules',
                 'BusinessOwner', 'Developer', 'Sprint', 'Status', 'Decision', 'Notes', 'WorkbookCreatedAt')
    # One creation time for the CSV and every sheet, local time with its UTC offset.
    $createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $Backlog = @($Backlog | Select-Object *, @{ Name = 'WorkbookCreatedAt'; Expression = { $createdAt } })
    $Backlog | Select-Object $columns | Export-Csv -Path (Join-Path $Folder 'sprint_backlog.csv') -NoTypeInformation -Encoding UTF8

    $platforms = @($RoutePlanning.Values | Sort-Object { $_.Order } | ForEach-Object { $_.Platform } | Select-Object -Unique)
    $bandNames = @($ComplexityBands.Keys) + @('XL', 'TBD')

    $legend = New-Object System.Collections.Generic.List[object]
    foreach ($k in $RoutePlanning.Keys) {
        $legend.Add([PSCustomObject]@{ Item = 'Route'; Value = $k; TargetPlatform = $RoutePlanning[$k].Platform; Meaning = $RouteLabel[$k]; WorkType = $RoutePlanning[$k].WorkType })
    }
    $lower = 0
    foreach ($b in $ComplexityBands.Keys) {
        $legend.Add([PSCustomObject]@{ Item = 'ComplexityBand'; Value = $b; TargetPlatform = ''; Meaning = ('ComplexityScore {0} to {1}' -f $lower, $ComplexityBands[$b]); WorkType = '' })
        $lower = $ComplexityBands[$b] + 1
    }
    $legend.Add([PSCustomObject]@{ Item = 'ComplexityBand'; Value = 'XL'; TargetPlatform = ''; Meaning = ('ComplexityScore {0} or more' -f $lower); WorkType = '' })
    $legend.Add([PSCustomObject]@{ Item = 'ComplexityBand'; Value = 'TBD'; TargetPlatform = ''; Meaning = 'Package could not be read, so it was not sized'; WorkType = '' })
    $legend.Add([PSCustomObject]@{ Item = 'ComplexityScore'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = 'Enabled tasks + data flow components + 3 x (script tasks + script components) + event handlers + error-row redirects + opaque SQL statements + 2 if transactions required + 2 if checkpoints on. A sizing signal, not an estimate.' })
    $legend.Add([PSCustomObject]@{ Item = 'BuildOrder'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = '1 = runs no child package in its project. A parent is always higher than every child it executes: build in ascending order.' })
    $legend.Add([PSCustomObject]@{ Item = 'AzureSsisIrFit'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = 'Option B (Azure-SSIS IR) suitability, reported separately from the route.' })
    $legend.Add([PSCustomObject]@{ Item = 'DecisionDrivers'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = 'What the scan found that decided the platform, as "finding: plain-language explanation", separated by " | ". The engineer-level detail for every finding is in evidence_items.csv.' })
    $terms = [ordered]@{
        'ADF'                 = 'Azure Data Factory: the Azure service that runs and schedules data pipelines. Packages planned for ADF are rebuilt as ADF pipelines.'
        'SSIS VM'             = 'The SQL Server virtual machine in Azure that runs Integration Services (SSIS) packages unchanged. ADF starts them on a schedule.'
        'SHIR'                = 'Self-hosted Integration Runtime: an ADF agent installed on a server inside the network. ADF needs one to reach anything Azure cannot see directly, such as file shares, local drives, Windows logins and some database drivers.'
        'Copy activity'       = 'The ADF step that copies data from a source to a destination with little or no transformation.'
        'Mapping Data Flow'   = 'The ADF step for transforming data on the way through (joins, lookups, calculated columns). It is the ADF counterpart of an SSIS data flow.'
        'Azure-SSIS IR'       = 'Option B: an Azure-managed cluster that runs SSIS packages without a VM. AzureSsisIrFit says how well each package would suit it.'
    }
    foreach ($t in $terms.Keys) { $legend.Add([PSCustomObject]@{ Item = 'Term'; Value = $t; TargetPlatform = ''; Meaning = $terms[$t]; WorkType = '' }) }
    foreach ($k in $PackageLocationLabel.Keys) {
        $legend.Add([PSCustomObject]@{ Item = 'PackageLocation'; Value = $PackageLocationLabel[$k]; TargetPlatform = ''; WorkType = ''
            Meaning = $PackageLocationMeaning[$k] })
    }
    $legend.Add([PSCustomObject]@{ Item = 'isMigrating'; Value = 'Yes'; TargetPlatform = ''; WorkType = ''
        Meaning = 'Planned for migration. This is the default; the team confirms it, or sets No for a package being retired.' })
    $legend.Add([PSCustomObject]@{ Item = 'isMigrating'; Value = 'Review'; TargetPlatform = ''; WorkType = ''
        Meaning = ('Deployed to SSISDB but not run in the last {0} days. Confirm with the business owner whether it is still needed, then set Yes or No.' -f $HistoryDays) })
    $legend.Add([PSCustomObject]@{ Item = 'isMigrating'; Value = 'No'; TargetPlatform = ''; WorkType = ''
        Meaning = 'Set by the team: the package will be retired, not migrated. The assessment never sets No on its own.' })
    $legend.Add([PSCustomObject]@{ Item = 'SourceServerName'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = 'Name the source SQL Server reports for itself (@@SERVERNAME), read at run time, whatever alias or address the assessment connected with. (file) for packages read from disk.' })
    $legend.Add([PSCustomObject]@{ Item = 'AgentSchedules'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = 'When the SQL Agent jobs that run this package are scheduled (with -IncludeAgentJobs): "Job: schedule; schedule", jobs separated by |. Tells ADF orchestration what timing to reproduce.' })
    $legend.Add([PSCustomObject]@{ Item = 'WorkbookCreatedAt'; Value = ''; TargetPlatform = ''; WorkType = ''
        Meaning = 'Local date and time (with UTC offset) the CSV and workbook were written.' })

    # One workbook per source server, named by the name the server reports (SourceServerName). Packages read
    # from disk share one 'FileSystem' workbook. Characters not allowed in a file name become '_' (HOST\INST -> HOST_INST).
    $invalid = '[{0}]' -f [regex]::Escape(-join [IO.Path]::GetInvalidFileNameChars())
    $byServer = $Backlog | Group-Object { if ($_.ServerInstance -eq '(file)') { 'FileSystem' } else { $_.SourceServerName -replace $invalid, '_' } }
    foreach ($srv in $byServer) {
        $rowsAll = @($srv.Group)
        $summary = foreach ($g in ($rowsAll | Group-Object Environment, TargetPlatform)) {
            $row = [ordered]@{ Environment = $g.Group[0].Environment; TargetPlatform = $g.Group[0].TargetPlatform; Packages = $g.Count }
            foreach ($b in $bandNames) { $row[$b] = @($g.Group | Where-Object ComplexityBand -eq $b).Count }
            $row['Order'] = [array]::IndexOf($platforms, $g.Group[0].TargetPlatform)
            [PSCustomObject]$row
        }
        $summary = @($summary | Sort-Object Environment, Order)

        $sheets = New-Object System.Collections.Generic.List[object]
        $sheets.Add(@{ Name = 'Summary'; Columns = @('Environment', 'TargetPlatform', 'Packages') + $bandNames; Rows = $summary })
        $sheets.Add(@{ Name = 'Backlog'; Columns = $columns; Rows = $rowsAll })
        foreach ($pf in $platforms) {
            $rows = @($rowsAll | Where-Object TargetPlatform -eq $pf)
            if ($rows.Count -gt 0) { $sheets.Add(@{ Name = $pf; Columns = $columns; Rows = $rows }) }
        }
        $sheets.Add(@{ Name = 'Legend'; Columns = @('Item', 'Value', 'TargetPlatform', 'Meaning', 'WorkType'); Rows = $legend.ToArray() })
        $path = Join-Path $WorkbookFolder ('{0}_SSIS_Migration_Assessment_{1}.xlsx' -f $srv.Name, $Stamp)
        Write-XlsxWorkbook -Path $path -Sheets $sheets.ToArray()
        Write-Log -Level OK -Message ('Workbook for {0} ({1} packages): {2}' -f $srv.Name, $rowsAll.Count, $path)
        $path
    }
}
#endregion

#region ============================== 8. EXECUTION ===============================================

try {
    Write-Log -Level STEP -Message ('Assessment started {0}' -f $RunStart.ToString('yyyy-MM-dd HH:mm:ss zzz'))
    foreach ($dir in $CreatedFolders) { Write-Log -Level INFO -Message "Created folder (did not exist): $dir" }
    Write-Log -Level INFO -Message "Workbook folder: $WorkbookFolder"

    # Build the server work list (explicit servers + server list file).
    $targets = New-Object System.Collections.Generic.List[object]
    # 'powershell.exe -File' passes "-ServerInstance A,B" as one string: split it here. An all-digit piece is a
    # port and stays with the name before it, so HOST,1433 remains one server.
    $serverNames = New-Object System.Collections.Generic.List[string]
    foreach ($piece in @($ServerInstance | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($piece -match '^\d+$' -and $serverNames.Count -gt 0) { $serverNames[$serverNames.Count - 1] += ',' + $piece } else { $serverNames.Add($piece) }
    }
    foreach ($s in $serverNames) {
        $targets.Add([PSCustomObject]@{ ServerInstance = $s; Environment = $Environment; TargetSsisVersion = $TargetSsisVersion })
    }
    if ($ServerListPath) {
        foreach ($row in Import-Csv -LiteralPath $ServerListPath) {
            if (-not $row.ServerInstance) { continue }
            $envLabel = $Environment; $tgt = $TargetSsisVersion
            if ($row.PSObject.Properties['Environment'] -and $row.Environment) { $envLabel = $row.Environment }
            if ($row.PSObject.Properties['TargetSsisVersion'] -and $row.TargetSsisVersion) {
                if ($row.TargetSsisVersion -notin @('2016', '2017', '2019', '2022', '2025')) { throw "Invalid TargetSsisVersion '$($row.TargetSsisVersion)' for $($row.ServerInstance)." }
                $tgt = $row.TargetSsisVersion
            }
            $targets.Add([PSCustomObject]@{ ServerInstance = $row.ServerInstance; Environment = $envLabel; TargetSsisVersion = $tgt })
        }
    }

    # Each source is announced with its start and completion time, so a long multi-server run shows where it is.
    $sources = @($targets | ForEach-Object { @{ Kind = 'Server'; Name = $_.ServerInstance; Target = $_ } }) +
               @($PackageFolder | Where-Object { $_ } | ForEach-Object { @{ Kind = 'Folder'; Name = $_ } })
    $n = 0
    foreach ($src in $sources) {
        $n++
        $start = Get-Date; $pkgBefore = $Packages.Count; $errBefore = $Errors.Count
        Write-Log -Level STEP -Message ('[{0}/{1}] {2} {3}: started {4}' -f $n, $sources.Count, $src.Kind, $src.Name, $start.ToString('yyyy-MM-dd HH:mm:ss'))
        if ($src.Kind -eq 'Server') { Invoke-ServerAssessment -Server $src.Target.ServerInstance -Env $src.Target.Environment -Target $src.Target.TargetSsisVersion }
        else { Invoke-FolderAssessment -Path $src.Name -Target $TargetSsisVersion }
        $end = Get-Date
        Write-Log -Level OK -Message ('[{0}/{1}] {2} {3}: completed {4} (elapsed {5:hh\:mm\:ss}, {6} packages, {7} errors)' -f $n, $sources.Count, $src.Kind, $src.Name,
            $end.ToString('yyyy-MM-dd HH:mm:ss'), ($end - $start), ($Packages.Count - $pkgBefore), ($Errors.Count - $errBefore))
    }

    # ---- Child package roll-up: a parent's EffectiveRoute is at least as hard as every child it executes ----
    Write-Log -Level STEP -Message 'Rolling child package routes up to parents'
    $byProject = $Packages | Group-Object { '{0}|{1}|{2}' -f $_.ServerInstance, $_.Folder, $_.Project }
    foreach ($grp in $byProject) {
        $lookup = @{}; foreach ($p in $grp.Group) { $lookup[$p.Package] = $p }
        # Recursive resolver with cycle protection (visited set) for nested Execute Package chains.
        $resolve = $null
        $resolve = {
            param($pkg, $visited)
            $best = $pkg.PackageRoute; $from = New-Object System.Collections.Generic.List[string]
            foreach ($child in @($pkg.ChildPackages -split '; ' | Where-Object { $_ })) {
                if ($child -like 'EXTERNAL:*') {
                    # File-system / msdb child: its contents are unknown here, so the parent cannot be called easy.
                    $from.Add("$child (not resolved; review)")
                    if ($RouteSeverity['ReviewRequired'] -gt $RouteSeverity[$best]) { $best = 'ReviewRequired' }
                    continue
                }
                if (-not $lookup.ContainsKey($child) -or $visited.Contains($child)) { continue }
                [void]$visited.Add($child)
                $c = & $resolve $lookup[$child] $visited
                if ($RouteSeverity[$c.Route] -gt $RouteSeverity[$best]) { $best = $c.Route; $from.Add($child) }
            }
            [PSCustomObject]@{ Route = $best; From = $from }
        }
        foreach ($p in $grp.Group) {
            $visited = New-Object System.Collections.Generic.HashSet[string]
            [void]$visited.Add($p.Package)
            $res = & $resolve $p $visited
            $p.EffectiveRoute = $res.Route; $p.EffectiveRouteLabel = $RouteLabel[$res.Route]
            $p.RolledUpFrom = ($res.From -join '; ')
        }
    }

    # ---- Output ----
    Write-Log -Level STEP -Message 'Writing output'
    $csv = @{ NoTypeInformation = $true; Encoding = 'UTF8' }
    $Packages | Select-Object * -ExcludeProperty Key, Drivers | Sort-Object Environment, ServerInstance, Folder, Project, Package |
        Export-Csv -Path (Join-Path $RunFolder 'package_assessment.csv') @csv
    $Evidence    | Export-Csv -Path (Join-Path $RunFolder 'evidence_items.csv') @csv
    $Connections | Export-Csv -Path (Join-Path $RunFolder 'connections.csv') @csv
    if ($IncludeAgentJobs) { $JobSteps | Export-Csv -Path (Join-Path $RunFolder 'agent_job_steps.csv') @csv }
    $Errors      | Export-Csv -Path (Join-Path $RunFolder 'errors.csv') @csv

    $summary = $Packages | Group-Object Environment, EffectiveRoute | ForEach-Object {
        [PSCustomObject]@{ RunId = $RunId; Environment = $_.Group[0].Environment; EffectiveRoute = $_.Group[0].EffectiveRoute
                           RouteLabel = $RouteLabel[$_.Group[0].EffectiveRoute]; Packages = $_.Count }
    } | Sort-Object Environment, @{ Expression = { $RouteSeverity[$_.EffectiveRoute] }; Descending = $true }
    $summary | Export-Csv -Path (Join-Path $RunFolder 'route_summary.csv') @csv
    $workbooks = @(Export-SprintBacklog -Backlog @(New-SprintBacklog -Packages $Packages.ToArray()) -Folder $RunFolder -WorkbookFolder $WorkbookFolder -Stamp $RunStamp)

    Write-Log -Level OK -Message ("Packages assessed: {0} | Evidence items: {1} | Errors: {2}" -f $Packages.Count, $Evidence.Count, $Errors.Count)
    # -Width keeps the table readable in headless runs (SQL Agent, scheduled tasks) where console width is undefined.
    $summary | Format-Table Environment, EffectiveRoute, Packages -AutoSize | Out-String -Width 200 | Write-Host
    if ($Errors.Count -gt 0) { Write-Log -Level WARN -Message "Some objects failed; see errors.csv. Results for those objects are missing, not 'easy'." }
    Write-Log -Level OK -Message "Results: $RunFolder"
    foreach ($wb in $workbooks) { Write-Log -Level OK -Message "Workbook: $wb" }
    $runEnd = Get-Date
    Write-Log -Level OK -Message ('Assessment completed {0} (elapsed {1:hh\:mm\:ss})' -f $runEnd.ToString('yyyy-MM-dd HH:mm:ss zzz'), ($runEnd - $RunStart))
}
catch {
    Write-Log -Level ERROR -Message "Fatal: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
#endregion
