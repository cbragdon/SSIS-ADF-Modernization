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
       and optionally SQL Agent job steps (schedules, 32-bit /X86 execution - deprecated in SQL Server 2025).
    7. Writes timestamped CSVs plus a transcript log. Nothing is overwritten between runs.
    8. Writes a sprint backlog (sprint_backlog.csv and sprint_backlog.xlsx) for developers and business units:
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

.PARAMETER IncludeMsdbPackages
    Also assess packages stored in msdb (package deployment model). These are additionally flagged as
    depending on the legacy Integration Services Service, which is deprecated in SQL Server 2025.

.PARAMETER IncludeAgentJobs
    Read SQL Agent SSIS job steps to report schedules per package and detect 32-bit (/X86) execution.

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
        sprint_backlog.xlsx     - the same rows as a workbook: Summary, Backlog, one sheet per platform, Legend
        transcript.log          - full PowerShell transcript of the run

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
    Version : 2.3.0
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
$RunId     = 'SSISASSESS_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $env:COMPUTERNAME
$RunFolder = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $RunFolder -Force | Out-Null
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

# Sprint backlog (sprint_backlog.csv / .xlsx): the platform each route lands on and the work it implies.
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
    catch { $result.ParseStatus = 'ReviewRequired'; $result.ParseDetail = "Invalid XML: $($_.Exception.Message)"; return [PSCustomObject]$result }

    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('DTS', $DtsNs)
    $root = $xml.DocumentElement

    # Format: SSIS 2012+ stores PackageFormatVersion as a property element; 2008-era packages (format <= 3) use a
    # different schema (no DTS:ExecutableType attributes) and cannot be analysed reliably.
    $fmtNode = $root.SelectSingleNode("DTS:Property[@DTS:Name='PackageFormatVersion']", $ns)
    if ($fmtNode) { $result.FormatVersion = $fmtNode.InnerText.Trim() }
    if ($root.NamespaceURI -ne $DtsNs -or ($result.FormatVersion -and [int]$result.FormatVersion -lt 6)) {
        $result.ParseStatus = 'ReviewRequired'
        $result.ParseDetail = "Legacy package format '$($result.FormatVersion)' (SSIS 2008 R2 or earlier). Upgrade the package, then re-assess."
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
        $result.ParseDetail = 'Package body is encrypted (EncryptAll*). Re-save with EncryptSensitive or DontSaveSensitive to assess.'
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
        return [PSCustomObject]@{ Route = 'ReviewRequired'; AzureIr = 'Review'; Reasons = $Analysis.ParseDetail; Removed = ''; Deprecated = ($ExtraDeprecated -join '; ') }
    }
    $route = 'AdfNative-Low'; $ir = 'Compatible'
    $reasons = New-Object System.Collections.Generic.SortedSet[string]
    $removed = New-Object System.Collections.Generic.SortedSet[string]
    $deprec  = New-Object System.Collections.Generic.SortedSet[string]
    foreach ($d in $ExtraDeprecated) { [void]$deprec.Add($d) }

    foreach ($it in $Analysis.Items) {
        if ($it.Disabled) { continue }                                  # disabled tasks never execute
        $cat = Resolve-Category -Rule $it.Rule -TargetVersion $TargetVersion
        if ($RouteSeverity[$cat] -gt $RouteSeverity[$route]) { $route = $cat }
        if ($IrSeverity[$it.Rule.AzureIr] -gt $IrSeverity[$ir]) { $ir = $it.Rule.AzureIr }
        if ($cat -ne 'AdfNative-Low') { [void]$reasons.Add(('{0}: {1}' -f $cat, $it.Rule.Name)) }
        switch ($it.Rule.Lifecycle) {
            'Removed2025'      { [void]$removed.Add("$($it.Rule.Name) (removed)") }
            'Discontinued2025' { [void]$removed.Add("$($it.Rule.Name) (discontinued)") }
            'Deprecated2025'   { [void]$deprec.Add($it.Rule.Name) }
        }
    }
    if ($removed.Count -gt 0 -and $TargetVersion -ne '2025') {
        [void]$reasons.Add("FutureRisk: SQL Server 2025 removals present - host must stay at SQL Server $TargetVersion or earlier until remediated")
    }
    if ($reasons.Count -eq 0) { [void]$reasons.Add('Only Copy / SQL / orchestration constructs found') }
    [PSCustomObject]@{
        Route = $route; AzureIr = $ir; Reasons = (@($reasons) -join '; ')
        Removed = (@($removed) -join '; '); Deprecated = (@($deprec) -join '; ')
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
        AgentJobs = ''; Uses32BitJobStep = $false
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
       CASE WHEN DB_ID('SSISDB') IS NULL THEN 0 ELSE 1 END     AS HasSsisdb;
"@
    }
    catch { Add-AssessmentError -Server $Server -Scope 'Connect' -Object $Server -Message $_.Exception.Message; return }
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
            Write-Log -Message ("  msdb packages: {0}" -f $msdbPkgs.Count)
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
            foreach ($s in $steps) {
                $JobSteps.Add([PSCustomObject]@{ RunId = $RunId; Environment = $Env; ServerInstance = $Server; JobName = $s.JobName
                    JobEnabled = [bool]$s.JobEnabled; StepId = $s.StepId; StepName = $s.StepName; Uses32Bit = [bool]$s.Uses32Bit; Command = $s.Command })
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
                    $p.AgentJobs = (($hits | ForEach-Object { $_.JobName }) | Sort-Object -Unique) -join '; '
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

            # Decision drivers: only the rules that set the package's own route, plus any harder child it runs.
            $all = @($p.RouteReasons -split '; ' | Where-Object { $_ })
            $drivers = @($all | Where-Object { $_ -like "$($p.PackageRoute): *" } | ForEach-Object { $_.Substring($p.PackageRoute.Length + 2) })
            $drivers += @($all | Where-Object { $_ -like 'FutureRisk: *' })
            if ($drivers.Count -eq 0) { $drivers = $all }
            if ($p.RolledUpFrom) { $drivers += "Runs child package(s) with a harder route: $($p.RolledUpFrom)" }

            $usage = if ($p.SourceType -ne 'SSISDB') { 'No run history (not an SSISDB package)' }
                     elseif ([int]$p.Executions -eq 0) { "Not run in the last $HistoryDays days - confirm it is still needed" }
                     elseif ([int]$p.FailedExecutions -gt 0) { '{0} runs, {1} failed, in the last {2} days' -f $p.Executions, $p.FailedExecutions, $HistoryDays }
                     else { '{0} runs in the last {1} days' -f $p.Executions, $HistoryDays }

            $rows.Add([PSCustomObject]@{
                Environment = $p.Environment; ServerInstance = $p.ServerInstance; Folder = $p.Folder; Project = $p.Project
                Package = $p.Package; TargetPlatform = $plan.Platform; Route = $p.EffectiveRoute; WorkType = $plan.WorkType
                ComplexityBand = $band; ComplexityScore = $score; BuildOrder = $buildOrder
                DependsOn = $p.ChildPackages
                CalledBy = $(if ($calledBy.ContainsKey($p.Package)) { (@($calledBy[$p.Package]) | Sort-Object -Unique) -join '; ' } else { '' })
                DecisionDrivers = ($drivers -join '; '); AzureSsisIrFit = $p.AzureSsisIrFit; Removed2025 = $p.Removed2025
                Usage = $usage; LastExecutionStart = $p.LastExecutionStart; AvgDurationMin = $p.AvgDurationMin; AgentJobs = $p.AgentJobs
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
    <# Writes sprint_backlog.csv and sprint_backlog.xlsx (Summary, Backlog, one sheet per platform, Legend). #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Backlog, [Parameter(Mandatory)][string]$Folder)
    $columns = @('Environment', 'ServerInstance', 'Folder', 'Project', 'Package', 'TargetPlatform', 'Route', 'WorkType',
                 'ComplexityBand', 'ComplexityScore', 'BuildOrder', 'DependsOn', 'CalledBy', 'DecisionDrivers', 'AzureSsisIrFit',
                 'Removed2025', 'Usage', 'LastExecutionStart', 'AvgDurationMin', 'AgentJobs',
                 'BusinessOwner', 'Developer', 'Sprint', 'Status', 'Decision', 'Notes')
    $Backlog | Select-Object $columns | Export-Csv -Path (Join-Path $Folder 'sprint_backlog.csv') -NoTypeInformation -Encoding UTF8

    $platforms = @($RoutePlanning.Values | Sort-Object { $_.Order } | ForEach-Object { $_.Platform } | Select-Object -Unique)
    $bandNames = @($ComplexityBands.Keys) + @('XL', 'TBD')
    $summary = foreach ($g in ($Backlog | Group-Object Environment, TargetPlatform)) {
        $row = [ordered]@{ Environment = $g.Group[0].Environment; TargetPlatform = $g.Group[0].TargetPlatform; Packages = $g.Count }
        foreach ($b in $bandNames) { $row[$b] = @($g.Group | Where-Object ComplexityBand -eq $b).Count }
        $row['Order'] = [array]::IndexOf($platforms, $g.Group[0].TargetPlatform)
        [PSCustomObject]$row
    }
    $summary = @($summary | Sort-Object Environment, Order)

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

    $sheets = New-Object System.Collections.Generic.List[object]
    $sheets.Add(@{ Name = 'Summary'; Columns = @('Environment', 'TargetPlatform', 'Packages') + $bandNames; Rows = $summary })
    $sheets.Add(@{ Name = 'Backlog'; Columns = $columns; Rows = @($Backlog) })
    foreach ($pf in $platforms) {
        $rows = @($Backlog | Where-Object TargetPlatform -eq $pf)
        if ($rows.Count -gt 0) { $sheets.Add(@{ Name = $pf; Columns = $columns; Rows = $rows }) }
    }
    $sheets.Add(@{ Name = 'Legend'; Columns = @('Item', 'Value', 'TargetPlatform', 'Meaning', 'WorkType'); Rows = $legend.ToArray() })
    Write-XlsxWorkbook -Path (Join-Path $Folder 'sprint_backlog.xlsx') -Sheets $sheets.ToArray()
}
#endregion

#region ============================== 8. EXECUTION ===============================================

try {
    # Build the server work list (explicit servers + server list file).
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($ServerInstance | Where-Object { $_ })) {
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

    foreach ($t in $targets) { Invoke-ServerAssessment -Server $t.ServerInstance -Env $t.Environment -Target $t.TargetSsisVersion }
    foreach ($pf in @($PackageFolder | Where-Object { $_ })) { Invoke-FolderAssessment -Path $pf -Target $TargetSsisVersion }

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
    $Packages | Select-Object * -ExcludeProperty Key | Sort-Object Environment, ServerInstance, Folder, Project, Package |
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
    Export-SprintBacklog -Backlog @(New-SprintBacklog -Packages $Packages.ToArray()) -Folder $RunFolder

    Write-Log -Level OK -Message ("Packages assessed: {0} | Evidence items: {1} | Errors: {2}" -f $Packages.Count, $Evidence.Count, $Errors.Count)
    # -Width keeps the table readable in headless runs (SQL Agent, scheduled tasks) where console width is undefined.
    $summary | Format-Table Environment, EffectiveRoute, Packages -AutoSize | Out-String -Width 200 | Write-Host
    if ($Errors.Count -gt 0) { Write-Log -Level WARN -Message "Some objects failed; see errors.csv. Results for those objects are missing, not 'easy'." }
    Write-Log -Level OK -Message "Results: $RunFolder"
}
catch {
    Write-Log -Level ERROR -Message "Fatal: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
#endregion
