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
    5. Rolls child package routes up to parents (Execute Package Task), so a parent cannot look easier
       than the children it runs (EffectiveRoute).
    6. Enriches with run history from catalog.executions (run count, failures, last run, average duration)
       and optionally SQL Agent job steps (schedules, 32-bit /X86 execution - deprecated in SQL Server 2025).
    7. Writes timestamped CSVs plus a transcript log. Nothing is overwritten between runs.

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
    Version : 2.0.0
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
    New-Rule Enumerator 'ADO|Item|Variable|NodeList|FromVar|AzureBlob|DataLake' 'Foreach ADO/Item/Variable/NodeList Enumerator' AdfNative-Medium '' Compatible 'ADF Lookup + ForEach.'

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
    # ---------------- Data flow components: ADF Copy activity equivalents ----------------
    New-Rule Component 'ExcelSource'                   'Excel Source'                AdfNative-Medium '' NeedsCustomSetup 'ADF Excel connector (read-only); file must be reachable.'
    New-Rule Component 'DataConvert|RowCount'          'Data Conversion / Row Count' AdfNative-Low '' Compatible 'Copy activity type mapping / rows copied output.'
    New-Rule Component 'OLEDBSource|OLEDBDestination|ADONETDestination|DataReaderSource|SSISODBC|FlatFile|RawSource|RawDestination|SQLServerDestination|Azure|FlexibleFile' 'Source/Destination adapter' AdfNative-Low '' Compatible 'ADF Copy activity source/sink.'

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
    #>
    param([Parameter(Mandatory)]$CmNode, [Parameter(Mandatory)]$Ns)
    $creation = Get-DtsAttr $CmNode 'CreationName'
    $inner    = $CmNode.SelectSingleNode('DTS:ObjectData/DTS:ConnectionManager', $Ns)
    $connStr  = Get-DtsAttr $inner 'ConnectionString'
    $provider = ''
    if ($connStr -match 'Provider\s*=\s*([^;]+)') { $provider = $Matches[1].Trim() }
    $identity = '{0}|{1}' -f $creation, $provider
    $rule     = Get-RuleMatch -Scope Connection -Identity $identity

    $flags = New-Object System.Collections.Generic.List[string]
    if ($connStr -match 'Integrated Security\s*=\s*(SSPI|True)|Trusted_Connection\s*=\s*(yes|true)') { $flags.Add('WindowsAuth') }
    if ($connStr -match '^\s*\\\\|^\s*[A-Za-z]:\\|Data Source\s*=\s*(\\\\|[A-Za-z]:\\)')            { $flags.Add('LocalOrUncPath') }
    if ($CmNode.SelectSingleNode("DTS:PropertyExpression[@DTS:Name='ConnectionString']", $Ns))         { $flags.Add('ExpressionDriven') }

    # Mask secrets: never write passwords from connection strings to disk.
    $safeConnStr = $connStr -replace '(?i)(password|pwd)\s*=\s*[^;]*', '$1=********'

    [PSCustomObject]@{
        Name = (Get-DtsAttr $CmNode 'ObjectName'); DtsId = (Get-DtsAttr $CmNode 'DTSID')
        CreationName = $creation; Provider = $provider; Rule = $rule; Flags = $flags
        ConnectionString = $safeConnStr
    }
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

    # ---- Package-level connection managers ----
    foreach ($cm in $root.SelectNodes('DTS:ConnectionManagers/DTS:ConnectionManager', $ns)) {
        $f = Get-ConnectionFinding -CmNode $cm -Ns $ns
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
    }

    # ---- Executables: every task and container, including those inside event handlers ----
    foreach ($exe in $root.SelectNodes('//DTS:Executable', $ns)) {
        if ($exe -eq $root) { continue }                                      # the package itself
        $type     = Get-DtsAttr $exe 'ExecutableType'
        $path     = Get-DtsAttr $exe 'refId'; if (-not $path) { $path = Get-DtsAttr $exe 'ObjectName' }
        $disabled = (Get-DtsAttr $exe 'Disabled') -eq 'True'
        $rule     = Get-RuleMatch -Scope Task -Identity $type
        $result.TaskCount++
        if ($disabled) { $result.DisabledTaskCount++ }
        if ($rule.Name -eq 'Script Task') { $result.ScriptTaskCount++ }
        $result.Items.Add([PSCustomObject]@{ Scope = 'Task'; Path = $path; Identity = $type; Rule = $rule; Disabled = $disabled })

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
                if ($cRule.Name -eq 'Script Component') { $result.ScriptComponentCount++ }
                $result.Items.Add([PSCustomObject]@{ Scope = 'Component'; Path = ('{0}\{1}' -f $path, $comp.GetAttribute('name')); Identity = $identity; Rule = $cRule; Disabled = $disabled })
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

#region ============================== 7. EXECUTION ===============================================

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
                if ($child -like 'EXTERNAL:*') { $from.Add("$child (not resolved; review)"); continue }
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
