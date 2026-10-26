#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the "AssessmentTests" SSIS project (.ispac plus individual .dtsx files) using Microsoft's
    SSIS object model, so every package is valid by construction and deploys cleanly to SSISDB.

.DESCRIPTION
    WHY THE OBJECT MODEL INSTEAD OF HAND-WRITTEN XML
    ------------------------------------------------
    Package XML and the .ispac project manifest are internal formats. Hand-written files can parse
    correctly yet fail catalog.deploy_project or refuse to open in SSDT. This script asks the SSIS
    runtime itself (Microsoft.SqlServer.ManagedDTS / DTSPipelineWrap) to create the packages, the
    project parameters, the project connection managers and the .ispac. Component and task type
    identifiers are looked up from the installed SSIS catalogue (Application.TaskInfos,
    PipelineComponentInfos, ForEachEnumeratorInfos), never hard-coded, so the script adapts to the
    installed SSIS version (2016 - 2025).

    WHAT IT BUILDS
    --------------
    With -Suite ParityTests it builds the ParityTests project instead (P22-P30, one per data-parity gap
    G22-G30; see docs\04_parity-harness.md). Otherwise: one project, 27 packages. Each package exercises specific routing rules in
    01_Invoke-SsisModernizationAssessment.ps1, and each has an expected route recorded in
    tests\expected\AssessmentTests_expected_routes.csv so the assessment can be regression-tested.
    See docs\02_test-package-catalog.md for the full coverage matrix.

        T01_CopySqlAuth            Execute SQL + OLE DB copy, SQL authentication        -> AdfNative-Low
        T02_CopyWindowsAuth        Same, Windows authentication (runnable with seed)    -> AdfNative-Medium
        T03_TransformChain         Derived Column/Split/Lookup/Sort/Aggregate/...       -> AdfNative-Medium
        T04_ScriptTask             Script Task                                          -> KeepOnSsisVm
        T05_ScriptComponent        Script Component inside a data flow                  -> KeepOnSsisVm
        T06_ContainersConstraints  Sequence/For/Foreach File, constraints, OnError      -> AdfNative-Medium
        T07_Parent                 Execute Package (project reference) -> T08           -> Low; effective KeepOnSsisVm
        T08_Child                  Script Task + Execute SQL                            -> KeepOnSsisVm
        T09_DisabledScriptTask     Disabled Script Task must be ignored                 -> AdfNative-Low
        T10_FlatFileToExcel        UNC flat file to Excel destination (ACE)             -> KeepOnSsisVm
        T11_ParametersExpressions  Package/project params, sensitive param, expressions -> AdfNative-Low
        T12_OleDbCommandScd        OLE DB Command, Slowly Changing Dimension            -> AdfNative-Medium
        T13_FtpAndSendMail         FTP Task, Send Mail Task                             -> AdfNative-Medium
        T14_FuzzyLookup            Fuzzy Lookup (built only if installed)               -> KeepOnSsisVm
        T15_RemovedIn2025          CDC / Oracle components (built only if installed)    -> Remediate2025
        T16_OpaqueSql              Execute SQL from a variable / file connection (G04)  -> AdfNative-Medium
        T17_ResultSets             Single-row + full result set, Foreach ADO (G10)      -> AdfNative-Medium
        T18_ExcelSheetLoop         Schema Rowset loop over sheets, Excel Source (G11/19)-> AdfNative-Medium
        T19_ExecuteProcess         Execute Process Task (G12)                           -> KeepOnSsisVm
        T20_BulkInsert             Bulk Insert Task from a UNC file (G13)               -> AdfNative-Medium
        T21_MergeJoin              Sort, Merge Join, Merge (G14)                        -> AdfNative-Medium
        T22_CacheTransform         Cache Transform + cache-mode Lookup (G15)            -> AdfNative-Medium
        T23_MoreTransforms         Pivot/Unpivot/Character Map/Sampling/Audit (G16)     -> AdfNative-Medium
        T24_ImportExportColumn     Import Column, Export Column (G17)                   -> KeepOnSsisVm
        T25_RecordsetDestination   Recordset Destination + Foreach ADO (G18)            -> KeepOnSsisVm
        T26_FlatFileFormats        Fixed width, ragged right, pipe UTF-8, multi (G20)   -> AdfNative-Medium
        T27_DynamicMail            Send Mail in OnError, expressions, attachment (G21)  -> AdfNative-Medium

    Components that are not installed on the build machine (for example the Attunity CDC and Oracle
    components, which SQL Server 2025 removed) are skipped and listed in build_manifest_<ProjectName>.csv. Those
    cases are covered instead by the offline XML fixtures in tests\fixtures.

    RUNNABLE VS PARSE-ONLY
    ----------------------
    The primary purpose is assessment and rewrite-spec testing, so most packages only need to deploy
    and parse. T02_CopyWindowsAuth is fully runnable when the seed database exists and the build is
    run with -ResolveMetadata (column metadata is read from the live test database). Script Tasks and
    Script Components are created without code, so packages containing them deploy and parse but
    fail validation if executed - by design.

    REQUIREMENTS
    ------------
    * Windows PowerShell 5.1 (Desktop edition). The SSIS assemblies are .NET Framework and do not load
      in PowerShell 7.
    * SSIS installed on the build machine: the Integration Services feature of SQL Server (the Dev
      SSIS server itself is the simplest choice) or SSDT with the SSIS extension.
    * For -ResolveMetadata: the SsisAssessmentTest database (sql\01_Create-SsisAssessmentTestDb.sql)
      and the OLE DB provider named by -TestDbProvider (default MSOLEDBSQL) installed locally.

    SAFETY
    ------
    Local only. This script writes files under -OutputPath and -SourcePath. It connects to SQL Server
    only when -ResolveMetadata is supplied, and then only reads table metadata.

.PARAMETER OutputPath
    Folder for build output (.ispac, build_manifest_<ProjectName>.csv, build log). Default: <repo>\build.

.PARAMETER SourcePath
    Folder where individual .dtsx files are written for source control review.
    Default: <repo>\test-packages\AssessmentTests.

.PARAMETER Suite
    AssessmentTests (default): the 27 routing packages T01-T27, parse-and-deploy.
    ParityTests: the data-parity packages P22-P30 (gaps G22-G30). They run, so column metadata is always
    read from the live test database (sql\01-03 applied, -ResolveMetadata implied), and the flat-file
    inputs in tests\parity\data are copied to <LandingPath>\parity\in. LandingPath defaults to
    <repo>\build\landing for this suite. See docs\04_parity-harness.md.

.PARAMETER ProjectName
    SSIS project name. Must match the -ProjectName used by the deploy script. Default: the suite name.

.PARAMETER TestDbServer
    Default value of the project parameter TestDbServer (the server hosting SsisAssessmentTest).
    Environments created by the deploy script override it at run time. Default: localhost.

.PARAMETER TestDbName
    Default value of the project parameter TestDbName. Default SsisAssessmentTest.

.PARAMETER TestDbProvider
    OLE DB provider used in the project connection managers. Default MSOLEDBSQL (Microsoft OLE DB
    Driver for SQL Server). SQLNCLI11 is not supported on SQL Server 2022 and later.

.PARAMETER LandingPath
    Default value of the project parameter LandingPath (UNC folder used by file-based packages).

.PARAMETER ResolveMetadata
    Connect to the test database at build time to load column metadata for T02_CopyWindowsAuth so
    it can execute. Requires the seed database and the OLE DB provider.

.PARAMETER SsisAssemblyVersion
    Force a specific SSIS assembly major version (13=2016, 14=2017, 15=2019, 16=2022, 17=2025).
    Default: the highest version found in the GAC.

.OUTPUTS
    <OutputPath>\<ProjectName>.ispac       deployable project
    <OutputPath>\build_manifest_<ProjectName>.csv  one row per package: built, skipped components, expected route.
                                           One file per project, so building ParityTests never overwrites the
                                           AssessmentTests manifest the routing test reads.
    <OutputPath>\build_<timestamp>.log     transcript
    <SourcePath>\*.dtsx                    individual packages for review / source control

.EXAMPLE
    # On the Dev SSIS server (or a workstation with SSDT), parse-and-deploy test set
    powershell.exe -File .\01_New-SsisTestProject.ps1 -TestDbServer <DevSqlServer>

.EXAMPLE
    # Include live metadata so T02 can execute (seed database must exist first)
    powershell.exe -File .\01_New-SsisTestProject.ps1 -TestDbServer <DevSqlServer> -ResolveMetadata

.EXAMPLE
    # Data-parity packages P22-P30 (sql\01-03 applied first)
    powershell.exe -File .\01_New-SsisTestProject.ps1 -Suite ParityTests -TestDbServer <DevSqlServer> -LandingPath '\\<FileServer>\ssis_landing'

.NOTES
    Version : 1.2.2
    Part of : SSIS-ADF-Modernization repository (scripts\test-packages)
    Status  : SQL Server 2025 (SSIS 17.0): AssessmentTests builds 26 of 27 packages with no warnings (T15
              skipped, CDC/Oracle components removed in 2025). ParityTests (v1.2.0) builds all nine packages,
              which deploy and run through SSISDB. Earlier SSIS versions not yet run.
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$SourcePath,
    [ValidateSet('AssessmentTests', 'ParityTests')]
    [string]$Suite = 'AssessmentTests',
    [ValidatePattern('^[A-Za-z0-9_]+$')]
    [string]$ProjectName,
    [string]$TestDbServer = 'localhost',
    [string]$TestDbName = 'SsisAssessmentTest',
    [string]$TestDbProvider = 'MSOLEDBSQL',
    [string]$LandingPath = '\\fileserver\ssis_landing\assessment_tests',
    [switch]$ResolveMetadata,
    [ValidateSet('', '13', '14', '15', '16', '17')]
    [string]$SsisAssemblyVersion = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region ---------------- 0. Paths, logging, preconditions ----------------
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ProjectName) { $ProjectName = $Suite }
if ($Suite -eq 'ParityTests') {
    # The parity packages run, so their column metadata always comes from the live test database.
    $ResolveMetadata = [switch]$true
    if (-not $PSBoundParameters.ContainsKey('LandingPath')) { $LandingPath = Join-Path $RepoRoot 'build\landing' }
}
if (-not $OutputPath) { $OutputPath = Join-Path $RepoRoot 'build' }
if (-not $SourcePath) { $SourcePath = Join-Path $RepoRoot ('test-packages\' + $ProjectName) }
New-Item -ItemType Directory -Path $OutputPath, $SourcePath -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $OutputPath "build_$Stamp.log"
Start-Transcript -Path $LogFile -Force | Out-Null

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan' }[$Level]
    Write-Host ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}

try {
    # The SSIS runtime is .NET Framework only.
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Run this script in Windows PowerShell 5.1 (powershell.exe). The SSIS assemblies do not load in PowerShell 7 (pwsh).'
    }
    Write-Log -Level STEP -Message "Building SSIS test project '$ProjectName'"
    Write-Log -Message "Output : $OutputPath"
    Write-Log -Message "Source : $SourcePath"
#endregion

#region ---------------- 1. Load SSIS assemblies (highest installed version) ----------------
    $versions = if ($SsisAssemblyVersion) { @($SsisAssemblyVersion) } else { @('17', '16', '15', '14', '13') }
    $loaded = $null
    foreach ($v in $versions) {
        try {
            $suffix = ", Version=$v.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
            $dts  = [Reflection.Assembly]::Load('Microsoft.SqlServer.ManagedDTS' + $suffix)
            $pipe = [Reflection.Assembly]::Load('Microsoft.SqlServer.DTSPipelineWrap' + $suffix)
            $rt   = [Reflection.Assembly]::Load('Microsoft.SqlServer.DTSRuntimeWrap' + $suffix)
            $loaded = @{ Version = $v; Dts = $dts; Pipe = $pipe; Rt = $rt }
            break
        }
        catch { continue }
    }
    if (-not $loaded) { throw 'No SSIS runtime assemblies (Microsoft.SqlServer.ManagedDTS 13-17) found in the GAC. Install the Integration Services feature or SSDT with SSIS.' }
    # Preload the managed task and connection assemblies. Inside powershell.exe the SSIS runtime
    # cannot always bind them on demand (0x80131401 "Cannot create a task from XML", unknown SMTP
    # connection type, "different grant set"); once loaded into the AppDomain they resolve. Every
    # installed task, enumerator and managed-connection assembly of this version is preloaded.
    $gac = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL'
    $preload = @(Get-ChildItem -LiteralPath $gac -Directory -Filter 'Microsoft.SqlServer.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Task|Enumerator|ManagedConnections|TxScript|VSTAScriptingLib' -and $_.Name -notmatch '\.resources$|UI$|Design' } |
        Select-Object -ExpandProperty Name)
    foreach ($n in $preload) {
        try { [void][Reflection.Assembly]::Load("$n, Version=$($loaded.Version).0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91") }
        catch { }   # not every assembly exists for every version
    }
    $verName = @{ '13' = '2016'; '14' = '2017'; '15' = '2019'; '16' = '2022'; '17' = '2025' }[$loaded.Version]
    Write-Log -Level OK -Message "Loaded SSIS assemblies version $($loaded.Version).0 (SQL Server $verName)"
#endregion

#region ---------------- 2. Embedded C# builder ----------------
<#
    The package construction runs in C# because the data flow API (MainPipe, IDTSComponentMetaData100,
    CManagedComponentWrapper) is COM interop. C# casts those interfaces reliably; PowerShell's COM
    adapter does not. The code is C# 5 (Windows PowerShell 5.1 Add-Type compiler): no string
    interpolation, no null-conditional operators.
#>
    $builderSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using RtWrapper = Microsoft.SqlServer.Dts.Runtime.Wrapper;

namespace SsisTestKit
{
    /// <summary>One row of the build manifest.</summary>
    public class PackageResult
    {
        public string Package;
        public string ExpectedRoute;
        public string ExpectedEffectiveRoute;
        public bool   Built;
        public bool   Runnable;
        public string Purpose;
        public List<string> Skipped = new List<string>();
        public List<string> Warnings = new List<string>();
    }

    /// <summary>Settings passed in from PowerShell.</summary>
    public class BuildSettings
    {
        public string ProjectName;
        public string IspacPath;
        public string SourcePath;
        public string TestDbServer;
        public string TestDbName;
        public string TestDbProvider;
        public string LandingPath;
        public bool   ResolveMetadata;
        public string Suite;           // AssessmentTests | ParityTests
    }

    public class Builder
    {
        private readonly Application app = new Application();
        private readonly BuildSettings s;
        private Project project;
        private ConnectionManager cmWindows;   // project CM, Windows authentication
        private ConnectionManager cmSql;       // project CM, SQL authentication
        private PackageResult current;
        public  List<PackageResult> Results = new List<PackageResult>();
        public  List<string> Log = new List<string>();

        public Builder(BuildSettings settings) { s = settings; }

        // ------------------------------------------------------------------ helpers: logging
        private void Info(string m) { Log.Add("INFO |" + m); }
        private void Warn(string m) { Log.Add("WARN |" + m); if (current != null) current.Warnings.Add(m); }
        private void Skip(string what)
        {
            Log.Add("SKIP |" + (current == null ? "" : current.Package + ": ") + what);
            if (current != null) current.Skipped.Add(what);
        }

        // ------------------------------------------------------------------ helpers: catalogue lookups
        /// <summary>Resolves a task's creation name from the installed catalogue by display name.</summary>
        private string TaskMoniker(string displayName, string fallback)
        {
            foreach (TaskInfo ti in app.TaskInfos)
                if (string.Equals(ti.Name, displayName, StringComparison.OrdinalIgnoreCase)) return ti.CreationName;
            return fallback;
        }

        private PipelineComponentInfo FindComponent(string displayName)
        {
            foreach (PipelineComponentInfo p in app.PipelineComponentInfos)
                if (string.Equals(p.Name, displayName, StringComparison.OrdinalIgnoreCase)) return p;
            return null;
        }

        /// <summary>SSIS object names cannot contain / \ : [ ] . = ; replace them with underscores.</summary>
        private static string SafeName(string name)
        {
            foreach (char ch in "/\\:[].=") name = name.Replace(ch, '_');
            return name;
        }

        // ------------------------------------------------------------------ helpers: control flow
        /// <summary>Adds a task by display name; returns null (and records a skip) if unavailable.</summary>
        private TaskHost AddTask(IDTSSequence container, string displayName, string fallbackMoniker, string name)
        {
            try
            {
                // Prefer the stable STOCK: moniker; the catalogue's CreationName can name an assembly
                // version that fails to load (0x80131401 on SSIS 2025).
                Executable e;
                try { e = container.Executables.Add(fallbackMoniker); }
                catch (Exception) { e = container.Executables.Add(TaskMoniker(displayName, fallbackMoniker)); }
                TaskHost th = (TaskHost)e;
                th.Name = SafeName(name);
                return th;
            }
            catch (Exception ex) { Skip(displayName + " (" + ex.Message + ")"); return null; }
        }

        private void SetProp(DtsContainer c, string prop, object value)
        {
            // DtsContainer itself has no Properties; TaskHost, Package and the containers implement IDTSPropertiesProvider.
            IDTSPropertiesProvider pp = c as IDTSPropertiesProvider;
            if (pp == null) { Warn("Cannot set " + prop + " on " + c.Name + ": no property collection"); return; }
            try { pp.Properties[prop].SetValue(c, value); }
            catch (Exception ex) { Warn("Could not set " + prop + " on " + c.Name + ": " + ex.Message); }
        }

        private TaskHost AddExecuteSql(IDTSSequence container, string name, ConnectionManager cm, string sql)
        {
            TaskHost th = AddTask(container, "Execute SQL Task", "STOCK:SQLTask", name);
            if (th == null) return null;
            SetProp(th, "Connection", cm.ID);
            SetProp(th, "SqlStatementSource", sql);
            return th;
        }

        private TaskHost AddScriptTask(IDTSSequence container, string name)
        {
            // Created without script code: deploys and parses; fails validation if executed (by design).
            TaskHost th = AddTask(container, "Script Task", "STOCK:ScriptTask", name);
            if (th != null) th.Description = "Placeholder Script Task - no code. Exercises the KeepOnSsisVm rule.";
            return th;
        }

        private PrecedenceConstraint Link(IDTSSequence container, Executable from, Executable to,
                                          DTSExecResult result, string expression)
        {
            if (from == null || to == null) return null;
            PrecedenceConstraint pc = container.PrecedenceConstraints.Add(from, to);
            pc.Value = result;
            if (!string.IsNullOrEmpty(expression))
            {
                pc.EvalOp = DTSPrecedenceEvalOp.ExpressionAndConstraint;
                pc.Expression = expression;
            }
            return pc;
        }

        // ------------------------------------------------------------------ helpers: data flow
        private MainPipe AddDataFlow(IDTSSequence container, string name)
        {
            TaskHost th = AddTask(container, "Data Flow Task", "STOCK:PipelineTask", name);
            return th == null ? null : (MainPipe)th.InnerObject;
        }

        /// <summary>
        /// Adds a data flow component by catalogue display name. Native components take their
        /// CreationName as ComponentClassID; managed components fall back to the managed host with
        /// UserComponentTypeName. Missing components are skipped, not fatal.
        /// </summary>
        private IDTSComponentMetaData100 AddComponent(MainPipe mp, string displayName, string name)
        {
            if (mp == null) return null;
            PipelineComponentInfo info = FindComponent(displayName);
            if (info == null) { Skip("Component not installed: " + displayName); return null; }

            IDTSComponentMetaData100 md = mp.ComponentMetaDataCollection.New();
            try
            {
                md.ComponentClassID = info.CreationName;
                CManagedComponentWrapper inst = md.Instantiate();
                inst.ProvideComponentProperties();
            }
            catch (Exception)
            {
                try
                {
                    md.ComponentClassID = "Microsoft.ManagedComponentHost";
                    CManagedComponentWrapper inst = md.Instantiate();
                    inst.ProvideComponentProperties();
                    md.CustomPropertyCollection["UserComponentTypeName"].Value = info.CreationName;
                    inst.ProvideComponentProperties();
                }
                catch (Exception ex2)
                {
                    mp.ComponentMetaDataCollection.RemoveObjectByID(md.ID);
                    Skip(displayName + " (could not instantiate: " + ex2.Message + ")");
                    return null;
                }
            }
            md.Name = SafeName(name);   // ProvideComponentProperties resets the name, so set it last.
            return md;
        }

        private void UseConnection(IDTSComponentMetaData100 md, ConnectionManager cm)
        {
            if (md == null || cm == null) return;
            if (md.RuntimeConnectionCollection.Count == 0) { Warn(md.Name + " has no runtime connection slot"); return; }
            md.RuntimeConnectionCollection[0].ConnectionManagerID = cm.ID;
            md.RuntimeConnectionCollection[0].ConnectionManager = DtsConvert.GetExtendedInterface(cm);
        }

        private void SetCompProp(IDTSComponentMetaData100 md, string prop, object value)
        {
            if (md == null) return;
            try { md.Instantiate().SetComponentProperty(prop, value); }
            catch (Exception ex) { Warn("Could not set " + prop + " on " + md.Name + ": " + ex.Message); }
        }

        /// <summary>Connects output 0 of 'from' to input 0 of 'to'. Missing metadata is tolerated.</summary>
        private void Path(MainPipe mp, IDTSComponentMetaData100 from, IDTSComponentMetaData100 to)
        {
            PathTo(mp, from, 0, to, 0);
        }

        /// <summary>Connects a specific output to a specific input (Merge Join / Merge have two inputs).</summary>
        private void PathTo(MainPipe mp, IDTSComponentMetaData100 from, int outputIndex, IDTSComponentMetaData100 to, int inputIndex)
        {
            if (mp == null || from == null || to == null) return;
            try
            {
                IDTSPath100 p = mp.PathCollection.New();
                p.AttachPathAndPropagateNotifications(from.OutputCollection[outputIndex], to.InputCollection[inputIndex]);
            }
            catch (Exception ex) { Warn("Path " + from.Name + " -> " + to.Name + " not attached: " + ex.Message); }
        }

        /// <summary>Live metadata: refresh from the database (used for the runnable T02 package).</summary>
        private bool Refresh(IDTSComponentMetaData100 md)
        {
            try
            {
                CManagedComponentWrapper inst = md.Instantiate();
                inst.AcquireConnections(null);
                inst.ReinitializeMetaData();
                inst.ReleaseConnections();
                return true;
            }
            catch (Exception ex) { Warn("Metadata refresh failed for " + md.Name + ": " + ex.Message); return false; }
        }

        /// <summary>Selects every upstream column on the destination and maps it by name.</summary>
        private void MapByName(IDTSComponentMetaData100 dest)
        {
            CManagedComponentWrapper inst = dest.Instantiate();
            IDTSInput100 input = dest.InputCollection[0];
            IDTSVirtualInput100 vi = input.GetVirtualInput();
            foreach (IDTSVirtualInputColumn100 vc in vi.VirtualInputColumnCollection)
                inst.SetUsageType(input.ID, vi, vc.LineageID, DTSUsageType.UT_READONLY);
            foreach (IDTSInputColumn100 ic in input.InputColumnCollection)
            {
                foreach (IDTSExternalMetadataColumn100 ext in input.ExternalMetadataColumnCollection)
                {
                    if (string.Equals(ext.Name, ic.Name, StringComparison.OrdinalIgnoreCase))
                    { inst.MapInputColumn(input.ID, ic.ID, ext.ID); break; }
                }
            }
        }

        // ------------------------------------------------------------------ package lifecycle
        private Package NewPackage(string name, string expectedRoute, string expectedEffective, bool runnable, string purpose)
        {
            current = new PackageResult();
            current.Package = name + ".dtsx";
            current.ExpectedRoute = expectedRoute;
            current.ExpectedEffectiveRoute = expectedEffective;
            current.Runnable = runnable;
            current.Purpose = purpose;
            Results.Add(current);

            Package p = new Package();
            p.Name = name;
            p.Description = purpose;
            p.ProtectionLevel = DTSProtectionLevel.DontSaveSensitive;   // must match the project
            Info("Building " + name);
            return p;
        }

        private void FinishPackage(Package p)
        {
            project.PackageItems.Add(p, p.Name + ".dtsx");
            app.SaveToXml(System.IO.Path.Combine(s.SourcePath, p.Name + ".dtsx"), p, null);
            current.Built = true;
            current = null;
        }

        // ------------------------------------------------------------------ project
        public void Build()
        {
            if (File.Exists(s.IspacPath)) File.Delete(s.IspacPath);   // idempotent rebuild
            project = Project.CreateProject(s.IspacPath);
            project.Name = s.ProjectName;
            project.Description = "Synthetic SSIS packages for testing the SSIS-to-ADF assessment and rewrite tooling. Development use only.";
            project.ProtectionLevel = DTSProtectionLevel.DontSaveSensitive;

            // Project parameters: environments created by the deploy script override these defaults.
            AddProjectParam("TestDbServer",   s.TestDbServer,   false, "Server hosting the SsisAssessmentTest database.");
            AddProjectParam("TestDbName",     s.TestDbName,     false, "Test database name.");
            AddProjectParam("TestDbProvider", s.TestDbProvider, false, "OLE DB provider for SQL Server (MSOLEDBSQL).");
            AddProjectParam("LandingPath",    s.LandingPath,    false, "UNC folder used by file-based test packages.");
            AddProjectParam("SqlLoginUser",   "ssis_test_reader", false, "SQL login used by SQL-authentication test packages.");
            AddProjectParam("SqlLoginPassword", "",           true,  "Sensitive: supplied by the SSISDB environment, never stored in the project.");

            // Project connection managers, driven by project parameters through expressions.
            string baseCs = "\"Data Source=\" + @[$Project::TestDbServer] + \";Initial Catalog=\" + @[$Project::TestDbName] + \";Provider=\" + @[$Project::TestDbProvider] + \";Auto Translate=False;";
            cmWindows = AddProjectConnection("TestDb_Windows", "OLEDB",
                "Data Source=" + s.TestDbServer + ";Initial Catalog=" + s.TestDbName + ";Provider=" + s.TestDbProvider + ";Integrated Security=SSPI;Auto Translate=False;",
                baseCs + "Integrated Security=SSPI;\"");
            cmSql = AddProjectConnection("TestDb_Sql", "OLEDB",
                "Data Source=" + s.TestDbServer + ";Initial Catalog=" + s.TestDbName + ";Provider=" + s.TestDbProvider + ";User ID=ssis_test_reader;Auto Translate=False;",
                baseCs + "User ID=\" + @[$Project::SqlLoginUser] + \";\"");
            try { cmSql.SetExpression("Password", "@[$Project::SqlLoginPassword]"); }
            catch (Exception ex) { Warn("Password expression not set on TestDb_Sql: " + ex.Message); }

            if (s.Suite == "ParityTests")
            {
                // Create one Execute SQL Task before any data flow: once the pipeline assemblies are loaded,
                // the first SQLTask creation fails with 0x80131401 inside powershell.exe.
                using (Package warmUp = new Package()) { warmUp.Executables.Add("STOCK:SQLTask"); }
                P22(); P23(); P24(); P25(); P26(); P27(); P28(); P29(); P30();
            }
            else
            {
                T01(); T02(); T03(); T04(); T05(); T06(); T07(); T08(); T09(); T10();
                T11(); T12(); T13(); T14(); T15(); T16(); T17(); T18(); T19(); T20();
                T21(); T22(); T23(); T24(); T25(); T26(); T27();
            }

            project.Save();
            project.Dispose();
            Info("Saved " + s.IspacPath);
        }

        private void AddProjectParam(string name, string value, bool sensitive, string description)
        {
            Parameter p = project.Parameters.Add(name, TypeCode.String);
            p.Value = value;
            p.Sensitive = sensitive;
            p.Description = description;
        }

        private ConnectionManager AddProjectConnection(string name, string creationName, string staticCs, string expression)
        {
            ConnectionManagerItem item = project.ConnectionManagerItems.Add(creationName, name + ".conmgr");
            ConnectionManager cm = item.ConnectionManager;
            cm.Name = name;
            cm.ConnectionString = staticCs;
            try { cm.SetExpression("ConnectionString", expression); }
            catch (Exception ex) { Warn("Connection expression not set on " + name + ": " + ex.Message); }
            return cm;
        }

        // ------------------------------------------------------------------ packages
        /// <summary>Shared shape for T01/T02: truncate, then OLE DB source -> Data Conversion -> OLE DB destination.</summary>
        private void BuildCopy(Package p, ConnectionManager cm, bool live)
        {
            TaskHost trunc = AddExecuteSql(p, "Truncate dst.Customer", cm, "TRUNCATE TABLE dst.Customer;");
            // Link to the TaskHost returned by Add: a constraint to an Executable fetched back through
            // p.Executables[index] makes SaveToXml fail with 0x80010105 and project.Save hang.
            TaskHost dfHost = AddTask(p, "Data Flow Task", "STOCK:PipelineTask", "Copy Customer");
            MainPipe mp = dfHost == null ? null : (MainPipe)dfHost.InnerObject;
            Link(p, trunc, dfHost, DTSExecResult.Success, null);

            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read src.Customer");
            UseConnection(src, cm);
            SetCompProp(src, "AccessMode", 2);   // 2 = SQL command
            SetCompProp(src, "SqlCommand", "SELECT CustomerId, CustomerName, Email, Region, ProductId, Amount, CreatedDate FROM src.Customer;");

            IDTSComponentMetaData100 dst = AddComponent(mp, "OLE DB Destination", "Write dst.Customer");
            UseConnection(dst, cm);
            SetCompProp(dst, "AccessMode", 3);   // 3 = table or view - fast load
            SetCompProp(dst, "OpenRowset", "[dst].[Customer]");

            if (live && src != null && dst != null)
            {
                // Runnable variant: direct source -> destination with live column metadata.
                if (Refresh(src)) { Path(mp, src, dst); if (Refresh(dst)) MapByName(dst); }
            }
            else
            {
                IDTSComponentMetaData100 conv = AddComponent(mp, "Data Conversion", "Convert types");
                Path(mp, src, conv);
                Path(mp, conv, dst);
            }
        }

        private void T01()
        {
            Package p = NewPackage("T01_CopySqlAuth", "AdfNative-Low", "AdfNative-Low", false,
                "Execute SQL + OLE DB copy with Data Conversion over SQL authentication. Baseline for the low-effort ADF Copy route.");
            BuildCopy(p, cmSql, false);
            FinishPackage(p);
        }

        private void T02()
        {
            Package p = NewPackage("T02_CopyWindowsAuth", "AdfNative-Medium", "AdfNative-Medium", s.ResolveMetadata,
                "Same copy over Windows authentication: the WindowsAuth flag must raise the route to Medium (Self-hosted IR). Runnable when built with -ResolveMetadata.");
            BuildCopy(p, cmWindows, s.ResolveMetadata);
            FinishPackage(p);
        }

        private void T03()
        {
            Package p = NewPackage("T03_TransformChain", "AdfNative-Medium", "AdfNative-Medium", false,
                "Transformation chain that maps to ADF Mapping Data Flows: Derived Column, Conditional Split, Lookup, Sort, Aggregate, Union All, Multicast, Row Count.");
            p.Variables.Add("RowsProcessed", false, "User", 0);
            MainPipe mp = AddDataFlow(p, "Summarise customers");
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read src.Customer");
            UseConnection(src, cmWindows);
            SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT CustomerId, Region, ProductId, Amount FROM src.Customer;");
            IDTSComponentMetaData100 der   = AddComponent(mp, "Derived Column",    "Add AmountBand");
            IDTSComponentMetaData100 split = AddComponent(mp, "Conditional Split", "Split by Region");
            IDTSComponentMetaData100 look  = AddComponent(mp, "Lookup",            "Lookup Product");
            UseConnection(look, cmWindows);
            IDTSComponentMetaData100 sort  = AddComponent(mp, "Sort",              "Sort by Region");
            IDTSComponentMetaData100 agg   = AddComponent(mp, "Aggregate",         "Sum by Region and Category");
            IDTSComponentMetaData100 union = AddComponent(mp, "Union All",         "Union outputs");
            IDTSComponentMetaData100 multi = AddComponent(mp, "Multicast",         "Fan out");
            IDTSComponentMetaData100 cnt   = AddComponent(mp, "Row Count",         "Count rows");
            SetCompProp(cnt, "VariableName", "User::RowsProcessed");
            IDTSComponentMetaData100 dst   = AddComponent(mp, "OLE DB Destination", "Write dst.CustomerSummary");
            UseConnection(dst, cmWindows);
            SetCompProp(dst, "AccessMode", 3);
            SetCompProp(dst, "OpenRowset", "[dst].[CustomerSummary]");
            Path(mp, src, der); Path(mp, der, split); Path(mp, split, look); Path(mp, look, sort);
            Path(mp, sort, agg); Path(mp, agg, union); Path(mp, union, multi); Path(mp, multi, cnt); Path(mp, cnt, dst);
            FinishPackage(p);
        }

        private void T04()
        {
            Package p = NewPackage("T04_ScriptTask", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "A Script Task (custom .NET code) forces the SSIS runtime: KeepOnSsisVm under Option D.");
            TaskHost log = AddExecuteSql(p, "Log start", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T04_ScriptTask', N'Start');");
            TaskHost sc = AddScriptTask(p, "Custom logic");
            Link(p, log, sc, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T05()
        {
            Package p = NewPackage("T05_ScriptComponent", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "A Script Component inside a data flow forces the SSIS runtime.");
            MainPipe mp = AddDataFlow(p, "Transform with script");
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read src.Customer");
            UseConnection(src, cmSql);
            SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT CustomerId, Email FROM src.Customer;");
            IDTSComponentMetaData100 scr = AddComponent(mp, "Script Component", "Clean email");
            IDTSComponentMetaData100 cnt = AddComponent(mp, "Row Count", "Count");
            p.Variables.Add("Rows", false, "User", 0);
            SetCompProp(cnt, "VariableName", "User::Rows");
            Path(mp, src, scr); Path(mp, scr, cnt);
            FinishPackage(p);
        }

        private void T06()
        {
            Package p = NewPackage("T06_ContainersConstraints", "AdfNative-Medium", "AdfNative-Medium", false,
                "Containers and branching: Sequence, For Loop, Foreach File Enumerator with File System Task, success/failure/completion and expression constraints, OnError handler, variables, property expressions.");
            p.Variables.Add("Counter", false, "User", 0);
            p.Variables.Add("RowCount", false, "User", 0);
            p.Variables.Add("CurrentFile", false, "User", "");

            // Sequence with two Execute SQL tasks; the second uses a property expression.
            Sequence seq = (Sequence)p.Executables.Add("STOCK:SEQUENCE");
            seq.Name = "Prepare";
            TaskHost a = AddExecuteSql(seq, "Log start", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T06', N'Start');");
            TaskHost b = AddExecuteSql(seq, "Count source", cmSql, "SELECT COUNT(*) FROM src.Customer;");
            if (b != null) b.SetExpression("SqlStatementSource", "\"SELECT COUNT(*) FROM src.Customer WHERE CustomerId > \" + (DT_WSTR, 10) @[User::Counter]");
            Link(seq, a, b, DTSExecResult.Success, null);

            // For Loop: Counter from 0 to 2.
            ForLoop loop = (ForLoop)p.Executables.Add("STOCK:FORLOOP");
            loop.Name = "Retry loop";
            loop.InitExpression = "@[User::Counter] = 0";
            loop.EvalExpression = "@[User::Counter] < 3";
            loop.AssignExpression = "@[User::Counter] = @[User::Counter] + 1";
            AddExecuteSql(loop, "Log iteration", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T06', N'Iteration');");

            // Foreach File loop over the landing folder, with a File System Task inside.
            ForEachLoop fe = (ForEachLoop)p.Executables.Add("STOCK:FOREACHLOOP");
            fe.Name = "Each landing file";
            ForEachEnumeratorInfo fileEnum = null;
            foreach (ForEachEnumeratorInfo i in app.ForEachEnumeratorInfos)
                if (string.Equals(i.Name, "Foreach File Enumerator", StringComparison.OrdinalIgnoreCase)) { fileEnum = i; break; }
            if (fileEnum != null)
            {
                ForEachEnumeratorHost host = fileEnum.CreateNew();
                // ForEachEnumeratorHost is not a DtsContainer, so its properties are set directly.
                try
                {
                    host.Properties["Directory"].SetValue(host, s.LandingPath);
                    host.Properties["FileSpec"].SetValue(host, "*.csv");
                }
                catch (Exception ex) { Warn("Foreach File Enumerator properties not set: " + ex.Message); }
                fe.ForEachEnumerator = host;
                ForEachVariableMapping map = fe.VariableMappings.Add();
                map.VariableName = "User::CurrentFile";
                map.ValueIndex = 0;
            }
            else Skip("Foreach File Enumerator");
            ConnectionManager archive = p.Connections.Add("FILE");
            archive.Name = "Archive folder";
            archive.ConnectionString = s.LandingPath + "\\archive";
            AddTask(fe, "File System Task", "STOCK:FileSystemTask", "Archive file");

            // Branching between containers.
            Link(p, seq, loop, DTSExecResult.Success, "@[User::RowCount] >= 0");
            Link(p, loop, fe, DTSExecResult.Completion, null);
            TaskHost fail = AddExecuteSql(p, "Log failure", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T06', N'Prepare failed');");
            Link(p, seq, fail, DTSExecResult.Failure, null);

            // OnError event handler.
            DtsEventHandler onError = (DtsEventHandler)p.EventHandlers.Add("OnError");
            AddExecuteSql(onError, "Log error", cmSql, "INSERT etl.RunLog (PackageName, EventName, Detail) VALUES (N'T06', N'OnError', ?);");
            FinishPackage(p);
        }

        private void T07()
        {
            Package p = NewPackage("T07_Parent", "AdfNative-Low", "KeepOnSsisVm", false,
                "Parent that runs T08_Child through a project-reference Execute Package Task. Own route is Low; the child's Script Task must roll up so the EffectiveRoute is KeepOnSsisVm.");
            TaskHost log = AddExecuteSql(p, "Log start", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T07_Parent', N'Start');");
            TaskHost ep = AddTask(p, "Execute Package Task", "STOCK:ExecutePackageTask", "Run T08_Child");
            if (ep != null)
            {
                SetProp(ep, "UseProjectReference", true);
                SetProp(ep, "PackageName", "T08_Child.dtsx");
            }
            Link(p, log, ep, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T08()
        {
            Package p = NewPackage("T08_Child", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "Child package with a Script Task. Executed by T07_Parent.");
            TaskHost log = AddExecuteSql(p, "Log child", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T08_Child', N'Start');");
            TaskHost sc = AddScriptTask(p, "Child custom logic");
            Link(p, log, sc, DTSExecResult.Success, null);
            p.Variables.Add("ParentBatchId", false, "User", 0);
            Parameter batch = p.Parameters.Add("BatchId", TypeCode.Int32);
            batch.Value = 0;
            batch.Description = "Passed from the parent package.";
            FinishPackage(p);
        }

        private void T09()
        {
            Package p = NewPackage("T09_DisabledScriptTask", "AdfNative-Low", "AdfNative-Low", false,
                "Execute SQL plus a DISABLED Script Task. Disabled tasks never run, so the assessment must ignore it and route Low.");
            TaskHost log = AddExecuteSql(p, "Log start", cmSql, "INSERT etl.RunLog (PackageName, EventName) VALUES (N'T09', N'Start');");
            TaskHost sc = AddScriptTask(p, "Retired custom logic");
            if (sc != null) sc.Disable = true;
            Link(p, log, sc, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T10()
        {
            Package p = NewPackage("T10_FlatFileToExcel", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "UNC flat file source to Excel destination via the ACE provider. ADF cannot write Excel, so the package stays on the SSIS runtime.");
            ConnectionManager ff = p.Connections.Add("FLATFILE");
            ff.Name = "Landing customers csv";
            ff.ConnectionString = s.LandingPath + "\\customers.csv";
            ConnectionManager xl = p.Connections.Add("EXCEL");
            xl.Name = "Report workbook";
            xl.ConnectionString = "Provider=Microsoft.ACE.OLEDB.16.0;Data Source=" + s.LandingPath + "\\out\\customers.xlsx;Extended Properties=\"Excel 12.0 XML;HDR=YES\";";
            MainPipe mp = AddDataFlow(p, "CSV to Excel");
            IDTSComponentMetaData100 src = AddComponent(mp, "Flat File Source", "Read CSV");
            UseConnection(src, ff);
            IDTSComponentMetaData100 dst = AddComponent(mp, "Excel Destination", "Write workbook");
            UseConnection(dst, xl);
            Path(mp, src, dst);
            FinishPackage(p);
        }

        private void T11()
        {
            Package p = NewPackage("T11_ParametersExpressions", "AdfNative-Low", "AdfNative-Low", false,
                "Package parameters (required, typed, sensitive), project parameter references, Expression Task and property expressions. Exercises rewrite-spec parameter and expression extraction.");
            Parameter loadDate = p.Parameters.Add("LoadDate", TypeCode.String);
            loadDate.Value = "2026-01-01";
            loadDate.Required = true;
            loadDate.Description = "Business date to load (yyyy-MM-dd).";
            Parameter batchSize = p.Parameters.Add("BatchSize", TypeCode.Int32);
            batchSize.Value = 500;
            Parameter apiKey = p.Parameters.Add("ApiKey", TypeCode.String);
            apiKey.Value = "";
            apiKey.Sensitive = true;
            apiKey.Description = "Sensitive placeholder; must never appear in assessment or spec output.";
            p.Variables.Add("WhereClause", false, "User", "");

            TaskHost expr = AddTask(p, "Expression Task", "Microsoft.ExpressionTask", "Build filter");
            if (expr != null) SetProp(expr, "Expression", "@[User::WhereClause] = \"CreatedDate >= '\" + @[$Package::LoadDate] + \"'\"");
            TaskHost q = AddExecuteSql(p, "Load slice", cmSql, "SELECT TOP (500) * FROM src.Customer;");
            if (q != null) q.SetExpression("SqlStatementSource",
                "\"SELECT TOP (\" + (DT_WSTR, 10) @[$Package::BatchSize] + \") * FROM src.Customer WHERE \" + @[User::WhereClause] + \" /* server: \" + @[$Project::TestDbServer] + \" */\"");
            Link(p, expr, q, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T12()
        {
            Package p = NewPackage("T12_OleDbCommandScd", "AdfNative-Medium", "AdfNative-Medium", false,
                "Row-by-row OLE DB Command and a Slowly Changing Dimension: rebuildable in ADF but needs set-based redesign.");
            MainPipe mp = AddDataFlow(p, "Row by row update");
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read src.Customer");
            UseConnection(src, cmSql);
            SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT CustomerId, Email FROM src.Customer;");
            IDTSComponentMetaData100 cmd = AddComponent(mp, "OLE DB Command", "Update email");
            UseConnection(cmd, cmSql);
            SetCompProp(cmd, "SqlCommand", "UPDATE dst.Customer SET Email = ? WHERE CustomerId = ?;");
            Path(mp, src, cmd);

            MainPipe mp2 = AddDataFlow(p, "Customer dimension");
            IDTSComponentMetaData100 src2 = AddComponent(mp2, "OLE DB Source", "Read src.Customer");
            UseConnection(src2, cmSql);
            SetCompProp(src2, "AccessMode", 2);
            SetCompProp(src2, "SqlCommand", "SELECT CustomerId, CustomerName, Region FROM src.Customer;");
            IDTSComponentMetaData100 scd = AddComponent(mp2, "Slowly Changing Dimension", "Customer SCD");
            UseConnection(scd, cmSql);
            Path(mp2, src2, scd);
            FinishPackage(p);
        }

        private void T13()
        {
            Package p = NewPackage("T13_FtpAndSendMail", "AdfNative-Medium", "AdfNative-Medium", false,
                "FTP Task and Send Mail Task with FTP and SMTP connection managers: ADF FTP connector and Web activity / Logic App.");
            ConnectionManager ftp = p.Connections.Add("FTP");
            ftp.Name = "Partner FTP";
            ftp.ConnectionString = "ftp.example.test:21";
            ConnectionManager smtp = p.Connections.Add("SMTP");
            smtp.Name = "Mail relay";
            smtp.ConnectionString = "SmtpServer=smtp.example.test;UseWindowsAuthentication=False;EnableSsl=True;";
            TaskHost f = AddTask(p, "FTP Task", "STOCK:FtpTask", "Download partner file");
            if (f != null) SetProp(f, "Connection", ftp.ID);
            TaskHost m = AddTask(p, "Send Mail Task", "STOCK:SendMailTask", "Notify team");
            if (m != null)
            {
                SetProp(m, "SmtpConnection", smtp.ID);
                SetProp(m, "ToLine", "etl-team@example.test");
                SetProp(m, "Subject", "AssessmentTests T13 completed");
            }
            Link(p, f, m, DTSExecResult.Completion, null);
            FinishPackage(p);
        }

        private void T14()
        {
            if (FindComponent("Fuzzy Lookup") == null)
            {
                current = new PackageResult();
                current.Package = "T14_FuzzyLookup.dtsx"; current.ExpectedRoute = "KeepOnSsisVm"; current.ExpectedEffectiveRoute = "KeepOnSsisVm";
                current.Purpose = "Fuzzy Lookup (not installed on this build machine)";
                Results.Add(current); Skip("Fuzzy Lookup not installed; package not built"); current = null;
                return;
            }
            Package p = NewPackage("T14_FuzzyLookup", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "Fuzzy Lookup has no ADF equivalent: KeepOnSsisVm.");
            MainPipe mp = AddDataFlow(p, "Fuzzy match");
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read src.Customer");
            UseConnection(src, cmSql);
            SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT CustomerId, CustomerName FROM src.Customer;");
            IDTSComponentMetaData100 fz = AddComponent(mp, "Fuzzy Lookup", "Match names");
            UseConnection(fz, cmSql);
            Path(mp, src, fz);
            FinishPackage(p);
        }

        private void T15()
        {
            string[] removed = new string[] { "CDC Source", "CDC Splitter", "Oracle Source", "Oracle Destination" };
            List<string> present = new List<string>();
            foreach (string r in removed) if (FindComponent(r) != null) present.Add(r);
            if (present.Count == 0)
            {
                current = new PackageResult();
                current.Package = "T15_RemovedIn2025.dtsx"; current.ExpectedRoute = "Remediate2025"; current.ExpectedEffectiveRoute = "Remediate2025";
                current.Purpose = "SQL Server 2025 removed components (none installed here; covered by tests\\fixtures)";
                Results.Add(current); Skip("No CDC/Oracle components installed; package not built"); current = null;
                return;
            }
            Package p = NewPackage("T15_RemovedIn2025", "Remediate2025", "Remediate2025", false,
                "Components removed in SQL Server 2025 SSIS (" + string.Join(", ", present.ToArray()) + "). Remediate2025 when the target host is 2025.");
            MainPipe mp = AddDataFlow(p, "Removed components");
            foreach (string r in present) AddComponent(mp, r, r);
            FinishPackage(p);
        }

        // ------------------------------------------------------------------ packages: P2 gaps (G04, G10-G21)
        private void T16()
        {
            Package p = NewPackage("T16_OpaqueSql", "AdfNative-Medium", "AdfNative-Medium", false,
                "G04: Execute SQL Tasks whose statement comes from a variable and from a .sql file connection. The SQL that runs is not in the package, so the scanner raises it to Medium.");
            p.Variables.Add("MergeSql", false, "User", "EXEC etl.usp_Merge_Customer;");
            TaskHost fromVar = AddExecuteSql(p, "Run statement from variable", cmSql, "User::MergeSql");
            SetTaskEnum(fromVar, "SqlStatementSourceType", "Variable");
            ConnectionManager sqlFile = p.Connections.Add("FILE");
            sqlFile.Name = "Cleanup script";
            sqlFile.ConnectionString = "scripts\\cleanup.sql";   // relative path: only the source type should route
            TaskHost fromFile = AddExecuteSql(p, "Run script file", cmSql, sqlFile.Name);   // FileConnection: the source is the connection name
            SetTaskEnum(fromFile, "SqlStatementSourceType", "FileConnection");
            Link(p, fromVar, fromFile, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T17()
        {
            Package p = NewPackage("T17_ResultSets", "AdfNative-Medium", "AdfNative-Medium", false,
                "G10: Execute SQL single-row and full result sets. The full result set (Object variable) feeds a Foreach ADO Enumerator, which maps to ADF Lookup + ForEach (5,000-row Lookup limit).");
            p.Variables.Add("CustomerCount", false, "User", 0);
            p.Variables.Add("CustomerList", false, "User", new object());
            p.Variables.Add("CustomerId", false, "User", 0);
            TaskHost single = AddExecuteSql(p, "Count customers", cmSql, "SELECT COUNT(*) AS CustomerCount FROM src.Customer;");
            SetTaskEnum(single, "ResultSetType", "ResultSetType_SingleRow");
            AddResultBinding(single, "CustomerCount", "User::CustomerCount");
            TaskHost full = AddExecuteSql(p, "Get customer list", cmSql, "SELECT CustomerId FROM src.Customer;");
            SetTaskEnum(full, "ResultSetType", "ResultSetType_Rowset");
            AddResultBinding(full, "0", "User::CustomerList");
            ForEachLoop fe = (ForEachLoop)p.Executables.Add("STOCK:FOREACHLOOP");
            fe.Name = "Each customer";
            Dictionary<string, object> props = new Dictionary<string, object>();
            props["DataObjectVariable"] = "User::CustomerList";
            if (SetEnumerator(fe, "Foreach ADO Enumerator", props)) MapLoopVariable(fe, "User::CustomerId", 0);
            AddExecuteSql(fe, "Process customer", cmSql, "EXEC etl.usp_Process_Customer ?;");
            Link(p, single, full, DTSExecResult.Success, null);
            Link(p, full, fe, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T18()
        {
            Package p = NewPackage("T18_ExcelSheetLoop", "AdfNative-Medium", "AdfNative-Medium", false,
                "G11 + G19: Foreach ADO.NET Schema Rowset Enumerator over the sheets of a workbook, Excel Source per sheet, and an Execute SQL Task on the Excel connection (ACE provider).");
            p.Variables.Add("SheetName", false, "User", "Sheet1$");
            string wb = s.LandingPath + "\\in\\regions.xlsx";
            ConnectionManager xl = p.Connections.Add("EXCEL");
            xl.Name = "Region workbook";
            xl.ConnectionString = "Provider=Microsoft.ACE.OLEDB.16.0;Data Source=" + wb + ";Extended Properties=\"Excel 12.0 XML;HDR=YES\";";
            ConnectionManager adoXl = null;
            try
            {
                adoXl = p.Connections.Add("ADO.NET:System.Data.OleDb.OleDbConnection, System.Data, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089");
                adoXl.Name = "Region workbook schema";
                adoXl.ConnectionString = "Provider=Microsoft.ACE.OLEDB.16.0;Data Source=" + wb + ";Extended Properties=\"Excel 12.0 XML;HDR=YES\";";
            }
            catch (Exception ex) { Warn("ADO.NET OleDb connection not created: " + ex.Message); }

            TaskHost prep = AddExecuteSql(p, "Create summary sheet", xl, "CREATE TABLE `Summary` (`Region` LongText, `Total` Double);");
            ForEachLoop fe = (ForEachLoop)p.Executables.Add("STOCK:FOREACHLOOP");
            fe.Name = "Each worksheet";
            Dictionary<string, object> props = new Dictionary<string, object>();
            if (adoXl != null) props["Connection"] = adoXl.ID;
            if (SetEnumerator(fe, "Foreach ADO.NET Schema Rowset Enumerator", props)) MapLoopVariable(fe, "User::SheetName", 2);   // 2 = TABLE_NAME
            MainPipe mp = AddDataFlow(fe, "Load worksheet");
            IDTSComponentMetaData100 src = AddComponent(mp, "Excel Source", "Read worksheet");
            UseConnection(src, xl);
            SetCompProp(src, "AccessMode", 1);   // 1 = table name from variable
            SetCompProp(src, "OpenRowsetVariable", "User::SheetName");
            IDTSComponentMetaData100 dst = AddComponent(mp, "OLE DB Destination", "Write stg.RegionSheet");
            UseConnection(dst, cmSql);
            SetCompProp(dst, "AccessMode", 3);
            SetCompProp(dst, "OpenRowset", "[stg].[RegionSheet]");
            Path(mp, src, dst);
            Link(p, prep, fe, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T19()
        {
            Package p = NewPackage("T19_ExecuteProcess", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "G12: Execute Process Task runs an executable on the host (zip/unzip). The executable must exist on every runtime: KeepOnSsisVm.");
            TaskHost ep = AddTask(p, "Execute Process Task", "STOCK:ExecuteProcessTask", "Unzip landing archive");
            if (ep != null)
            {
                SetProp(ep, "Executable", "C:\\Program Files\\7-Zip\\7z.exe");
                SetProp(ep, "Arguments", "x archive.zip -y");
                SetProp(ep, "WorkingDirectory", s.LandingPath);
                ep.SetExpression("Arguments", "\"x \" + @[$Project::LandingPath] + \"\\\\archive.zip -y\"");
            }
            FinishPackage(p);
        }

        private void T20()
        {
            Package p = NewPackage("T20_BulkInsert", "AdfNative-Medium", "AdfNative-Medium", false,
                "G13: Bulk Insert Task from a UNC flat file into a table. Maps to ADF Copy, but the file must be reachable from the SQL Server (BULK INSERT reads it server-side).");
            ConnectionManager ff = p.Connections.Add("FILE");
            ff.Name = "Bulk source file";
            ff.ConnectionString = s.LandingPath + "\\bulk\\customers.dat";
            TaskHost bi = AddTask(p, "Bulk Insert Task", "STOCK:BulkInsertTask", "Bulk load stg.Customer");
            if (bi != null)
            {
                SetProp(bi, "SourceConnection", ff.Name);
                SetProp(bi, "DestinationConnection", cmSql.Name);
                SetProp(bi, "DestinationTableName", "[stg].[Customer]");
                SetProp(bi, "FieldTerminator", "|");
                SetProp(bi, "RowTerminator", "{CR}{LF}");
                SetProp(bi, "BatchSize", 10000);
            }
            FinishPackage(p);
        }

        private void T21()
        {
            Package p = NewPackage("T21_MergeJoin", "AdfNative-Medium", "AdfNative-Medium", false,
                "G14: Sort -> Merge Join (inner) on two sorted inputs, then Merge with a third input. Mapping Data Flow Join/Union, or push the join down to SQL.");
            MainPipe mp = AddDataFlow(p, "Join customers to orders");
            IDTSComponentMetaData100 c = AddComponent(mp, "OLE DB Source", "Read customers");
            UseConnection(c, cmSql); SetCompProp(c, "AccessMode", 2);
            SetCompProp(c, "SqlCommand", "SELECT CustomerId, CustomerName FROM src.Customer;");
            IDTSComponentMetaData100 o = AddComponent(mp, "OLE DB Source", "Read orders");
            UseConnection(o, cmSql); SetCompProp(o, "AccessMode", 2);
            SetCompProp(o, "SqlCommand", "SELECT CustomerId, Amount FROM src.Customer;");
            IDTSComponentMetaData100 sc = AddComponent(mp, "Sort", "Sort customers");
            IDTSComponentMetaData100 so = AddComponent(mp, "Sort", "Sort orders");
            IDTSComponentMetaData100 mj = AddComponent(mp, "Merge Join", "Join on CustomerId");
            SetCompProp(mj, "JoinType", 1);   // 1 = inner join
            IDTSComponentMetaData100 late = AddComponent(mp, "OLE DB Source", "Read late orders");
            UseConnection(late, cmSql); SetCompProp(late, "AccessMode", 2);
            SetCompProp(late, "SqlCommand", "SELECT CustomerId, Amount FROM src.Customer WHERE 1 = 0;");
            IDTSComponentMetaData100 sl = AddComponent(mp, "Sort", "Sort late orders");
            IDTSComponentMetaData100 mg = AddComponent(mp, "Merge", "Merge late orders");
            IDTSComponentMetaData100 dst = AddComponent(mp, "OLE DB Destination", "Write dst.CustomerOrders");
            UseConnection(dst, cmSql); SetCompProp(dst, "AccessMode", 3);
            SetCompProp(dst, "OpenRowset", "[dst].[CustomerOrders]");
            Path(mp, c, sc); Path(mp, o, so); Path(mp, late, sl);
            PathTo(mp, sc, 0, mj, 0); PathTo(mp, so, 0, mj, 1);
            PathTo(mp, mj, 0, mg, 0); PathTo(mp, sl, 0, mg, 1);
            Path(mp, mg, dst);
            FinishPackage(p);
        }

        private void T22()
        {
            Package p = NewPackage("T22_CacheTransform", "AdfNative-Medium", "AdfNative-Medium", false,
                "G15: Cache Transform fills a file-backed Cache connection manager (.caw) in one data flow; a Lookup in cache mode reads it in the next. Mapping Data Flow cached lookup.");
            ConnectionManager cache = p.Connections.Add("CACHE");
            cache.Name = "Product cache";
            SetCmProp(cache, "UseFile", true);
            // The cache file is the connection string: the Cache connection manager has no FileName property.
            cache.ConnectionString = s.LandingPath + "\\cache\\product.caw";
            // Keep the TaskHosts from Add: linking Executables fetched back from p.Executables breaks SaveToXml (see BuildCopy).
            TaskHost fillHost = AddTask(p, "Data Flow Task", "STOCK:PipelineTask", "Fill product cache");
            MainPipe fill = fillHost == null ? null : (MainPipe)fillHost.InnerObject;
            IDTSComponentMetaData100 src = AddComponent(fill, "OLE DB Source", "Read products");
            UseConnection(src, cmSql); SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT ProductId, Category FROM src.Product;");
            IDTSComponentMetaData100 ct = AddComponent(fill, "Cache Transform", "Write cache");
            UseConnection(ct, cache);
            Path(fill, src, ct);

            TaskHost useHost = AddTask(p, "Data Flow Task", "STOCK:PipelineTask", "Use product cache");
            MainPipe use = useHost == null ? null : (MainPipe)useHost.InnerObject;
            IDTSComponentMetaData100 src2 = AddComponent(use, "OLE DB Source", "Read customers");
            UseConnection(src2, cmSql); SetCompProp(src2, "AccessMode", 2);
            SetCompProp(src2, "SqlCommand", "SELECT CustomerId, ProductId FROM src.Customer;");
            IDTSComponentMetaData100 look = AddComponent(use, "Lookup", "Lookup category from cache");
            SetCompProp(look, "ConnectionType", 1);   // 1 = Cache connection manager
            UseConnection(look, cache);
            IDTSComponentMetaData100 dst = AddComponent(use, "OLE DB Destination", "Write dst.CustomerCategory");
            UseConnection(dst, cmSql); SetCompProp(dst, "AccessMode", 3);
            SetCompProp(dst, "OpenRowset", "[dst].[CustomerCategory]");
            Path(use, src2, look); Path(use, look, dst);
            Link(p, fillHost, useHost, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T23()
        {
            Package p = NewPackage("T23_MoreTransforms", "AdfNative-Medium", "AdfNative-Medium", false,
                "G16: Pivot, Unpivot, Character Map, Copy Column, Row Sampling, Percentage Sampling and Audit. All map to Mapping Data Flow transformations.");
            MainPipe mp = AddDataFlow(p, "Reshape sales");
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read sales");
            UseConnection(src, cmSql); SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT CustomerId, Region, Amount FROM src.Customer;");
            IDTSComponentMetaData100 rs  = AddComponent(mp, "Row Sampling", "Sample 1000 rows");
            SetCompProp(rs, "SamplingValue", 1000);
            IDTSComponentMetaData100 ps  = AddComponent(mp, "Percentage Sampling", "Sample 10 percent");
            SetCompProp(ps, "SamplingValue", 10);
            IDTSComponentMetaData100 cm  = AddComponent(mp, "Character Map", "Upper-case region");
            IDTSComponentMetaData100 cc  = AddComponent(mp, "Copy Column", "Copy amount");
            IDTSComponentMetaData100 au  = AddComponent(mp, "Audit", "Add package name");
            IDTSComponentMetaData100 pv  = AddComponent(mp, "Pivot", "Pivot by region");
            IDTSComponentMetaData100 up  = AddComponent(mp, "Unpivot", "Unpivot regions");
            IDTSComponentMetaData100 cnt = AddComponent(mp, "Row Count", "Count");
            p.Variables.Add("Rows", false, "User", 0);
            SetCompProp(cnt, "VariableName", "User::Rows");
            Path(mp, src, rs); Path(mp, rs, ps); Path(mp, ps, cm); Path(mp, cm, cc);
            Path(mp, cc, au); Path(mp, au, pv); Path(mp, pv, up); Path(mp, up, cnt);
            FinishPackage(p);
        }

        private void T24()
        {
            Package p = NewPackage("T24_ImportExportColumn", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "G17: Import Column reads files into a BLOB column and Export Column writes BLOBs back out to files, row by row. No ADF equivalent: KeepOnSsisVm.");
            MainPipe imp = AddDataFlow(p, "Import documents");
            IDTSComponentMetaData100 src = AddComponent(imp, "OLE DB Source", "Read document list");
            UseConnection(src, cmSql); SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT DocumentId, FilePath FROM src.DocumentList;");
            IDTSComponentMetaData100 ic = AddComponent(imp, "Import Column", "Load file contents");
            IDTSComponentMetaData100 dst = AddComponent(imp, "OLE DB Destination", "Write dst.Document");
            UseConnection(dst, cmSql); SetCompProp(dst, "AccessMode", 3);
            SetCompProp(dst, "OpenRowset", "[dst].[Document]");
            Path(imp, src, ic); Path(imp, ic, dst);

            MainPipe exp = AddDataFlow(p, "Export documents");
            IDTSComponentMetaData100 src2 = AddComponent(exp, "OLE DB Source", "Read documents");
            UseConnection(src2, cmSql); SetCompProp(src2, "AccessMode", 2);
            SetCompProp(src2, "SqlCommand", "SELECT FilePath, Content FROM dst.Document;");
            IDTSComponentMetaData100 ec = AddComponent(exp, "Export Column", "Write files");
            Path(exp, src2, ec);
            FinishPackage(p);
        }

        private void T25()
        {
            Package p = NewPackage("T25_RecordsetDestination", "KeepOnSsisVm", "KeepOnSsisVm", false,
                "G18: Recordset Destination fills an Object variable in memory; a Foreach ADO loop then iterates it. In-memory hand-off between tasks has no ADF equivalent: KeepOnSsisVm.");
            p.Variables.Add("Customers", false, "User", new object());
            p.Variables.Add("CustomerId", false, "User", 0);
            TaskHost dfHost = AddTask(p, "Data Flow Task", "STOCK:PipelineTask", "Load customers to recordset");
            MainPipe mp = dfHost == null ? null : (MainPipe)dfHost.InnerObject;
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", "Read customers");
            UseConnection(src, cmSql); SetCompProp(src, "AccessMode", 2);
            SetCompProp(src, "SqlCommand", "SELECT CustomerId FROM src.Customer;");
            IDTSComponentMetaData100 rd = AddComponent(mp, "Recordset Destination", "Hold in User::Customers");
            SetCompProp(rd, "VariableName", "User::Customers");
            Path(mp, src, rd);
            ForEachLoop fe = (ForEachLoop)p.Executables.Add("STOCK:FOREACHLOOP");
            fe.Name = "Each customer in recordset";
            Dictionary<string, object> props = new Dictionary<string, object>();
            props["DataObjectVariable"] = "User::Customers";
            if (SetEnumerator(fe, "Foreach ADO Enumerator", props)) MapLoopVariable(fe, "User::CustomerId", 0);
            AddExecuteSql(fe, "Process customer", cmSql, "EXEC etl.usp_Process_Customer ?;");
            Link(p, dfHost, fe, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void T26()
        {
            Package p = NewPackage("T26_FlatFileFormats", "AdfNative-Medium", "AdfNative-Medium", false,
                "G20: flat file variants - fixed width, ragged right, pipe-delimited UTF-8 (code page 65001) and a Multiple Flat Files connection over a wildcard.");
            ConnectionManager fixedW = AddFlatFile(p, "Mainframe fixed width", s.LandingPath + "\\in\\gl_extract.dat", "FixedWidth", 1252, null);
            ConnectionManager ragged = AddFlatFile(p, "Ragged right feed", s.LandingPath + "\\in\\ragged.txt", "RaggedRight", 1252, null);
            ConnectionManager pipe   = AddFlatFile(p, "Pipe delimited UTF-8", s.LandingPath + "\\in\\customers_pipe.txt", "Delimited", 65001, "|");
            ConnectionManager multi = p.Connections.Add("MULTIFLATFILE");
            multi.Name = "Daily files";
            multi.ConnectionString = s.LandingPath + "\\in\\daily_*.csv";
            ConnectionManager[] sources = new ConnectionManager[] { fixedW, ragged, pipe, multi };
            MainPipe mp = AddDataFlow(p, "Read flat file variants");
            IDTSComponentMetaData100 union = AddComponent(mp, "Union All", "Combine");
            foreach (ConnectionManager ff in sources)
            {
                IDTSComponentMetaData100 src = AddComponent(mp, "Flat File Source", "Read " + ff.Name);
                UseConnection(src, ff);
                if (union != null && src != null && src.OutputCollection.Count > 0)
                {
                    try { IDTSPath100 path = mp.PathCollection.New(); path.AttachPathAndPropagateNotifications(src.OutputCollection[0], union.InputCollection[union.InputCollection.Count - 1]); }
                    catch (Exception ex) { Warn("Path " + src.Name + " -> Union not attached: " + ex.Message); }
                }
            }
            FinishPackage(p);
        }

        private void T27()
        {
            Package p = NewPackage("T27_DynamicMail", "AdfNative-Medium", "AdfNative-Medium", false,
                "G21: Send Mail Task inside an OnError handler with expression-driven subject/body and a local file attachment. ADF: Web activity to a Logic App, and the attachment must move to storage.");
            ConnectionManager smtp = p.Connections.Add("SMTP");
            smtp.Name = "Mail relay";
            smtp.ConnectionString = "SmtpServer=smtp.example.test;UseWindowsAuthentication=False;EnableSsl=True;";
            AddExecuteSql(p, "Load step", cmSql, "EXEC etl.usp_Load_Customer;");
            DtsEventHandler onError = (DtsEventHandler)p.EventHandlers.Add("OnError");
            TaskHost m = AddTask(onError, "Send Mail Task", "STOCK:SendMailTask", "Mail error report");
            if (m != null)
            {
                SetProp(m, "SmtpConnection", smtp.ID);
                SetProp(m, "FromLine", "etl@example.test");
                SetProp(m, "ToLine", "etl-team@example.test");
                SetProp(m, "Subject", "AssessmentTests T27 failed");
                SetProp(m, "MessageSource", "See attachment.");
                SetProp(m, "FileAttachments", "C:\\ETL\\logs\\T27_error_rows.csv");
                m.SetExpression("Subject", "\"Package \" + @[System::PackageName] + \" failed at \" + @[System::SourceName]");
                m.SetExpression("MessageSource", "@[System::ErrorDescription]");
            }
            FinishPackage(p);
        }

        // ------------------------------------------------------------------ helpers used by T16-T27
        /// <summary>Sets an enum property on the task's inner object by enum member name (e.g. SqlStatementSourceType).</summary>
        private void SetTaskEnum(TaskHost th, string prop, string memberName)
        {
            if (th == null) return;
            try
            {
                object inner = th.InnerObject;
                System.Reflection.PropertyInfo pi = inner.GetType().GetProperty(prop);
                if (pi == null) { Warn(th.Name + ": no property " + prop); return; }
                pi.SetValue(inner, Enum.Parse(pi.PropertyType, memberName), null);
            }
            catch (Exception ex) { Warn("Could not set " + prop + "=" + memberName + " on " + th.Name + ": " + ex.Message); }
        }

        /// <summary>Sets a property on the task's inner object (for properties the TaskHost does not expose).</summary>
        private void SetInnerProp(TaskHost th, string prop, object value)
        {
            if (th == null) return;
            try
            {
                object inner = th.InnerObject;
                System.Reflection.PropertyInfo pi = inner.GetType().GetProperty(prop);
                if (pi == null) { Warn(th.Name + ": no property " + prop); return; }
                pi.SetValue(inner, value, null);
            }
            catch (Exception ex) { Warn("Could not set " + prop + " on " + th.Name + ": " + ex.Message); }
        }

        /// <summary>Adds an Execute SQL result binding (result name or ordinal -> variable) through reflection.</summary>
        private void AddResultBinding(TaskHost th, string resultName, string variable)
        {
            if (th == null) return;
            try
            {
                object inner = th.InnerObject;
                object bindings = inner.GetType().GetProperty("ResultSetBindings").GetValue(inner, null);
                object b = bindings.GetType().GetMethod("Add", Type.EmptyTypes).Invoke(bindings, null);
                b.GetType().GetProperty("ResultName").SetValue(b, resultName, null);
                b.GetType().GetProperty("DtsVariableName").SetValue(b, variable, null);
            }
            catch (Exception ex) { Warn("Result binding " + resultName + " -> " + variable + " not added on " + th.Name + ": " + ex.Message); }
        }

        private void SetCmProp(ConnectionManager cm, string prop, object value)
        {
            try { cm.Properties[prop].SetValue(cm, value); }
            catch (Exception ex) { Warn("Could not set " + prop + " on " + cm.Name + ": " + ex.Message); }
        }

        /// <summary>Creates a Foreach enumerator by catalogue display name and sets its properties. False when not installed.</summary>
        private bool SetEnumerator(ForEachLoop fe, string displayName, Dictionary<string, object> props)
        {
            ForEachEnumeratorInfo info = null;
            foreach (ForEachEnumeratorInfo i in app.ForEachEnumeratorInfos)
                if (string.Equals(i.Name, displayName, StringComparison.OrdinalIgnoreCase)) { info = i; break; }
            if (info == null) { Skip(displayName); return false; }
            ForEachEnumeratorHost host = info.CreateNew();
            foreach (KeyValuePair<string, object> kv in props)
            {
                try { host.Properties[kv.Key].SetValue(host, kv.Value); }
                catch (Exception ex) { Warn(displayName + " property " + kv.Key + " not set: " + ex.Message); }
            }
            fe.ForEachEnumerator = host;
            return true;
        }

        private void MapLoopVariable(ForEachLoop fe, string variable, int valueIndex)
        {
            ForEachVariableMapping map = fe.VariableMappings.Add();
            map.VariableName = variable;
            map.ValueIndex = valueIndex;
        }

        /// <summary>Flat file connection with a format, code page and (for Delimited) one column using the given delimiter.</summary>
        private ConnectionManager AddFlatFile(Package p, string name, string path, string format, int codePage, string delimiter)
        {
            ConnectionManager ff = p.Connections.Add("FLATFILE");
            ff.Name = name;
            ff.ConnectionString = path;
            SetCmProp(ff, "Format", format);
            SetCmProp(ff, "CodePage", codePage);
            if (codePage == 65001) SetCmProp(ff, "Unicode", false);
            try
            {
                RtWrapper.IDTSConnectionManagerFlatFile100 ffi = (RtWrapper.IDTSConnectionManagerFlatFile100)ff.InnerObject;
                string[] cols = new string[] { "RecordKey", "Payload" };
                for (int c = 0; c < cols.Length; c++)
                {
                    RtWrapper.IDTSConnectionManagerFlatFileColumn100 col = ffi.Columns.Add();
                    ((RtWrapper.IDTSName100)col).Name = cols[c];
                    col.DataType = RtWrapper.DataType.DT_STR;
                    col.MaximumWidth = 50;
                    bool last = c == cols.Length - 1;
                    if (format == "FixedWidth") { col.ColumnType = "FixedWidth"; col.ColumnWidth = 10; }
                    else if (format == "RaggedRight") { col.ColumnType = last ? "Delimited" : "FixedWidth"; col.ColumnWidth = 10; if (last) col.ColumnDelimiter = "\r\n"; }
                    else { col.ColumnType = "Delimited"; col.ColumnDelimiter = last ? "\r\n" : (delimiter ?? ","); }
                }
            }
            catch (Exception ex) { Warn("Columns not defined on " + name + ": " + ex.Message); }
            return ff;
        }

        // ------------------------------------------------------------------ packages: data parity (G22-G30)
        // These packages run. Column metadata is always read from the live test database (sql\03 must have
        // run), and every input and output is a pty / out_ssis object or a file under <LandingPath>\parity.
        // tests\parity\parity_cases.csv names them; scripts\parity\01_Invoke-ParityTest.ps1 runs them.

        private const string LandingExpr = "@[$Project::LandingPath]";

        private Package NewParityPackage(string name, string purpose)
        {
            Package p = NewPackage(name, "", "", true, purpose);
            return p;
        }

        private IDTSComponentMetaData100 SqlSource(MainPipe mp, string name, string sql)
        {
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", name);
            UseConnection(src, cmWindows);
            SetCompProp(src, "AccessMode", 2);   // SQL command
            SetCompProp(src, "SqlCommand", sql);
            if (src != null) Refresh(src);
            return src;
        }

        private IDTSComponentMetaData100 VariableSource(MainPipe mp, string name, string variable)
        {
            IDTSComponentMetaData100 src = AddComponent(mp, "OLE DB Source", name);
            UseConnection(src, cmWindows);
            SetCompProp(src, "AccessMode", 3);   // SQL command from variable
            SetCompProp(src, "SqlCommandVariable", variable);
            if (src != null) Refresh(src);
            return src;
        }

        /// <summary>OLE DB fast-load destination attached to the given output, mapped by column name.</summary>
        private IDTSComponentMetaData100 TableDest(MainPipe mp, string name, string table, IDTSComponentMetaData100 from, int outputIndex,
                                                   string fastLoadOptions, bool keepNulls)
        {
            IDTSComponentMetaData100 dst = AddComponent(mp, "OLE DB Destination", name);
            UseConnection(dst, cmWindows);
            SetCompProp(dst, "AccessMode", 3);   // table or view - fast load
            SetCompProp(dst, "OpenRowset", table);
            SetCompProp(dst, "FastLoadOptions", fastLoadOptions ?? "");
            SetCompProp(dst, "FastLoadKeepNulls", keepNulls);
            PathTo(mp, from, outputIndex, dst, 0);
            if (dst != null && Refresh(dst)) MapMatching(dst);
            return dst;
        }

        /// <summary>Selects and maps only the upstream columns that have an external column of the same name.</summary>
        private void MapMatching(IDTSComponentMetaData100 dest)
        {
            CManagedComponentWrapper inst = dest.Instantiate();
            IDTSInput100 input = dest.InputCollection[0];
            IDTSVirtualInput100 vi = input.GetVirtualInput();
            foreach (IDTSVirtualInputColumn100 vc in vi.VirtualInputColumnCollection)
            {
                foreach (IDTSExternalMetadataColumn100 ext in input.ExternalMetadataColumnCollection)
                {
                    if (!string.Equals(ext.Name, vc.Name, StringComparison.OrdinalIgnoreCase)) continue;
                    IDTSInputColumn100 ic = inst.SetUsageType(input.ID, vi, vc.LineageID, DTSUsageType.UT_READONLY);
                    inst.MapInputColumn(input.ID, ic.ID, ext.ID);
                    break;
                }
            }
        }

        private int OutputIndex(IDTSComponentMetaData100 md, string nameContains)
        {
            for (int i = 0; i < md.OutputCollection.Count; i++)
                if (md.OutputCollection[i].Name.IndexOf(nameContains, StringComparison.OrdinalIgnoreCase) >= 0) return i;
            Warn(md.Name + ": no output named like '" + nameContains + "'");
            return 0;
        }

        private IDTSVirtualInputColumn100 FindVirtual(IDTSVirtualInput100 vi, string name)
        {
            foreach (IDTSVirtualInputColumn100 vc in vi.VirtualInputColumnCollection)
                if (string.Equals(vc.Name, name, StringComparison.OrdinalIgnoreCase)) return vc;
            throw new InvalidOperationException("No upstream column " + name);
        }

        /// <summary>Adds a Derived Column output column with an SSIS expression.</summary>
        private void Derive(IDTSComponentMetaData100 dc, string name, string expression, RtWrapper.DataType type, int length, int codePage)
        {
            if (dc == null) return;
            try
            {
                CManagedComponentWrapper inst = dc.Instantiate();
                // Column references are written [Name]; the stored Expression uses #LineageID, so each
                // referenced upstream column is selected and substituted.
                string stored = expression;
                IDTSInput100 input = dc.InputCollection[0];
                IDTSVirtualInput100 vi = input.GetVirtualInput();
                foreach (IDTSVirtualInputColumn100 vc in vi.VirtualInputColumnCollection)
                {
                    string token = "[" + vc.Name + "]";
                    if (stored.IndexOf(token, StringComparison.Ordinal) < 0) continue;
                    inst.SetUsageType(input.ID, vi, vc.LineageID, DTSUsageType.UT_READONLY);
                    stored = stored.Replace(token, "#" + vc.LineageID);
                }
                IDTSOutput100 o = dc.OutputCollection[0];
                IDTSOutputColumn100 oc = inst.InsertOutputColumnAt(o.ID, o.OutputColumnCollection.Count, name, "");
                oc.SetDataTypeProperties(type, length, 0, 0, codePage);
                inst.SetOutputColumnProperty(o.ID, oc.ID, "Expression", stored);
                inst.SetOutputColumnProperty(o.ID, oc.ID, "FriendlyExpression", expression);
            }
            catch (Exception ex) { Warn("Derived column " + name + " not added on " + dc.Name + ": " + ex.Message); }
        }

        /// <summary>Adds a Data Conversion output column. ignoreFailure: conversion errors and truncation give NULL instead of failing.</summary>
        private void ConvertColumn(IDTSComponentMetaData100 dc, string inputName, string outputName, RtWrapper.DataType type, int length, int codePage, bool ignoreFailure)
        {
            if (dc == null) return;
            try
            {
                CManagedComponentWrapper inst = dc.Instantiate();
                IDTSInput100 input = dc.InputCollection[0];
                IDTSVirtualInput100 vi = input.GetVirtualInput();
                IDTSVirtualInputColumn100 vc = FindVirtual(vi, inputName);
                inst.SetUsageType(input.ID, vi, vc.LineageID, DTSUsageType.UT_READONLY);
                IDTSOutput100 o = dc.OutputCollection[0];
                IDTSOutputColumn100 oc = inst.InsertOutputColumnAt(o.ID, o.OutputColumnCollection.Count, outputName, "");
                inst.SetOutputColumnProperty(o.ID, oc.ID, "SourceInputColumnLineageID", vc.LineageID);
                inst.SetOutputColumnDataTypeProperties(o.ID, oc.ID, type, length, 0, 0, codePage);
                if (ignoreFailure)
                {
                    oc.ErrorRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
                    oc.TruncationRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
                }
            }
            catch (Exception ex) { Warn("Conversion " + inputName + " -> " + outputName + " not added on " + dc.Name + ": " + ex.Message); }
        }

        private Variable ExprVariable(Package p, string name, string expression)
        {
            Variable v = p.Variables.Add(name, false, "User", "");
            v.EvaluateAsExpression = true;
            v.Expression = expression;
            return v;
        }

        /// <summary>
        /// Delimited flat file connection with typed columns. Header row, comma separated; qualifier '"' or none.
        /// types/widths/precisions/scales are per column; rowDelimiter is "\r\n" or "\n".
        /// </summary>
        private ConnectionManager TypedFlatFile(Package p, string name, string staticPath, string pathExpression, int codePage, string rowDelimiter,
                                                bool qualified, string[] cols, RtWrapper.DataType[] types, int[] widths, int[] precisions, int[] scales)
        {
            ConnectionManager ff = p.Connections.Add("FLATFILE");
            ff.Name = name;
            ff.ConnectionString = staticPath;
            if (pathExpression != null) ff.SetExpression("ConnectionString", pathExpression);
            SetCmProp(ff, "Format", "Delimited");
            SetCmProp(ff, "CodePage", codePage);
            SetCmProp(ff, "Unicode", false);
            SetCmProp(ff, "ColumnNamesInFirstDataRow", true);
            SetCmProp(ff, "HeaderRowDelimiter", rowDelimiter);
            SetCmProp(ff, "RowDelimiter", rowDelimiter);
            if (qualified) SetCmProp(ff, "TextQualifier", "\"");
            RtWrapper.IDTSConnectionManagerFlatFile100 ffi = (RtWrapper.IDTSConnectionManagerFlatFile100)ff.InnerObject;
            for (int c = 0; c < cols.Length; c++)
            {
                RtWrapper.IDTSConnectionManagerFlatFileColumn100 col = ffi.Columns.Add();
                ((RtWrapper.IDTSName100)col).Name = cols[c];
                col.ColumnType = "Delimited";
                col.ColumnDelimiter = c == cols.Length - 1 ? rowDelimiter : ",";
                col.TextQualified = qualified;
                col.DataType = types[c];
                if (types[c] == RtWrapper.DataType.DT_STR || types[c] == RtWrapper.DataType.DT_WSTR) col.MaximumWidth = widths[c];
                if (types[c] == RtWrapper.DataType.DT_NUMERIC) { col.DataPrecision = precisions[c]; col.DataScale = scales[c]; }
            }
            return ff;
        }

        private IDTSComponentMetaData100 FlatFileSource(MainPipe mp, string name, ConnectionManager ff, bool retainNulls)
        {
            IDTSComponentMetaData100 src = AddComponent(mp, "Flat File Source", name);
            UseConnection(src, ff);
            SetCompProp(src, "RetainNulls", retainNulls);
            if (src != null) Refresh(src);
            return src;
        }

        /// <summary>Truncation of the named source output columns is ignored (the value is cut, the row kept).</summary>
        private void IgnoreTruncation(IDTSComponentMetaData100 src, params string[] columns)
        {
            if (src == null) return;
            foreach (IDTSOutputColumn100 oc in src.OutputCollection[0].OutputColumnCollection)
                foreach (string c in columns)
                    if (string.Equals(oc.Name, c, StringComparison.OrdinalIgnoreCase)) oc.TruncationRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
        }

        private ConnectionManager FolderConnection(Package p, string name, string staticPath, string pathExpression, int usageType)
        {
            ConnectionManager f = p.Connections.Add("FILE");
            f.Name = name;
            f.ConnectionString = staticPath;
            SetCmProp(f, "FileUsageType", usageType);   // 2 = existing folder, 3 = create folder
            if (pathExpression != null) f.SetExpression("ConnectionString", pathExpression);
            return f;
        }

        private TaskHost FileSystemTask(IDTSSequence container, string name, string operation, ConnectionManager folder)
        {
            TaskHost th = AddTask(container, "File System Task", "STOCK:FileSystemTask", name);
            if (th == null) return null;
            SetTaskEnum(th, "Operation", operation);
            SetProp(th, "Source", folder.Name);
            if (operation == "CreateDirectory") SetProp(th, "OverwriteDestinationFile", true);   // shown as UseDirectoryIfExists in the designer
            return th;
        }

        private void P22()
        {
            Package p = NewParityPackage("P22_LookupSemantics",
                "G22: full-cache Lookup of pty.G22_Input against pty.G22_Reference (first duplicate wins: ORDER BY RefId). Matches and no-matches are both written to out_ssis.G22_LookupResult with MatchStatus.");
            MainPipe mp = AddDataFlow(p, "Lookup product category");
            IDTSComponentMetaData100 src = SqlSource(mp, "Read pty G22_Input", "SELECT InputId, ProductCode FROM pty.G22_Input;");
            IDTSComponentMetaData100 look = AddComponent(mp, "Lookup", "Lookup ProductCode");
            UseConnection(look, cmWindows);
            SetCompProp(look, "CacheType", 0);          // full cache
            SetCompProp(look, "NoMatchBehavior", 1);    // send rows with no match to the no match output
            SetCompProp(look, "SqlCommand", "SELECT ProductCode, Category FROM pty.G22_Reference ORDER BY RefId;");
            Path(mp, src, look);
            if (look != null)
            {
                try
                {
                    Refresh(look);
                    CManagedComponentWrapper inst = look.Instantiate();
                    IDTSInput100 input = look.InputCollection[0];
                    IDTSVirtualInput100 vi = input.GetVirtualInput();
                    IDTSInputColumn100 key = inst.SetUsageType(input.ID, vi, FindVirtual(vi, "ProductCode").LineageID, DTSUsageType.UT_READONLY);
                    inst.SetInputColumnProperty(input.ID, key.ID, "JoinToReferenceColumn", "ProductCode");
                    IDTSOutput100 match = look.OutputCollection[OutputIndex(look, "Match Output")];
                    IDTSOutputColumn100 cat = inst.InsertOutputColumnAt(match.ID, 0, "Category", "");
                    cat.SetDataTypeProperties(RtWrapper.DataType.DT_STR, 20, 0, 0, 1252);
                    inst.SetOutputColumnProperty(match.ID, cat.ID, "CopyFromReferenceColumn", "Category");
                }
                catch (Exception ex) { Warn("Lookup join not configured: " + ex.Message); }
            }
            IDTSComponentMetaData100 matched = AddComponent(mp, "Derived Column", "Status Match");
            PathTo(mp, look, OutputIndex(look, "Lookup Match Output"), matched, 0);
            Derive(matched, "MatchStatus", "(DT_STR,10,1252)\"Match\"", RtWrapper.DataType.DT_STR, 10, 1252);
            IDTSComponentMetaData100 missed = AddComponent(mp, "Derived Column", "Status NoMatch");
            PathTo(mp, look, OutputIndex(look, "No Match"), missed, 0);
            Derive(missed, "MatchStatus", "(DT_STR,10,1252)\"NoMatch\"", RtWrapper.DataType.DT_STR, 10, 1252);
            // Two destinations instead of a Union All: no TABLOCK, so the two inserts do not block each other.
            TableDest(mp, "Write matches", "[out_ssis].[G22_LookupResult]", matched, 0, "CHECK_CONSTRAINTS", false);
            TableDest(mp, "Write no matches", "[out_ssis].[G22_LookupResult]", missed, 0, "CHECK_CONSTRAINTS", false);
            FinishPackage(p);
        }

        private void P23()
        {
            Package p = NewParityPackage("P23_BlankNull",
                "G23: G23_blanks.csv through a Flat File Source with RetainNulls = False (the designer default) into out_ssis.G23_BlankNull. ShipDate is read as text: an empty DT_DBDATE field with RetainNulls = False fails the destination ('Invalid date format'), so a Derived Column maps blank to NULL.");
            string file = "\\parity\\in\\G23_blanks.csv";
            ConnectionManager ff = TypedFlatFile(p, "G23 blanks csv", s.LandingPath + file, LandingExpr + " + \"\\\\parity\\\\in\\\\G23_blanks.csv\"", 1252, "\r\n", true,
                new string[] { "Id", "Code", "Quantity", "ShipDateText", "Note" },
                new RtWrapper.DataType[] { RtWrapper.DataType.DT_I4, RtWrapper.DataType.DT_STR, RtWrapper.DataType.DT_I4, RtWrapper.DataType.DT_STR, RtWrapper.DataType.DT_STR },
                new int[] { 0, 20, 0, 10, 50 }, new int[5], new int[5]);
            MainPipe mp = AddDataFlow(p, "Load blanks");
            IDTSComponentMetaData100 src = FlatFileSource(mp, "Read G23 blanks", ff, false);
            IDTSComponentMetaData100 dc = AddComponent(mp, "Derived Column", "Blank ShipDate to NULL");
            Path(mp, src, dc);
            Derive(dc, "ShipDate", "TRIM([ShipDateText]) == \"\" ? NULL(DT_DBDATE) : (DT_DBDATE)[ShipDateText]", RtWrapper.DataType.DT_DBDATE, 0, 0);
            TableDest(mp, "Write out_ssis G23", "[out_ssis].[G23_BlankNull]", dc, 0, "TABLOCK,CHECK_CONSTRAINTS", false);
            FinishPackage(p);
        }

        private void P24()
        {
            Package p = NewParityPackage("P24_TypesCodePages",
                "G24: G24_types_1252.csv (code page 1252, CRLF) and G24_types_utf8.csv (UTF-8 with BOM, LF, no final newline) into out_ssis.G24_Types. Names longer than 10 are truncated silently; text outside code page 1252 is converted for the varchar column.");
            RtWrapper.DataType[] types = new RtWrapper.DataType[] { RtWrapper.DataType.DT_I4, RtWrapper.DataType.DT_STR, RtWrapper.DataType.DT_WSTR, RtWrapper.DataType.DT_NUMERIC, RtWrapper.DataType.DT_R8 };
            int[] widths = new int[] { 0, 10, 10, 0, 0 };
            int[] precisions = new int[] { 0, 0, 0, 9, 0 };
            int[] scales = new int[] { 0, 0, 0, 2, 0 };

            ConnectionManager ansi = TypedFlatFile(p, "G24 types 1252", s.LandingPath + "\\parity\\in\\G24_types_1252.csv", LandingExpr + " + \"\\\\parity\\\\in\\\\G24_types_1252.csv\"", 1252, "\r\n", true,
                new string[] { "Id", "NameAnsi", "NameUnicode", "Amount", "Ratio" }, types, widths, precisions, scales);
            // UTF-8 file: the varchar column is read as Unicode and converted to code page 1252 in the flow.
            RtWrapper.DataType[] typesUtf8 = (RtWrapper.DataType[])types.Clone();
            typesUtf8[1] = RtWrapper.DataType.DT_WSTR;
            ConnectionManager utf8 = TypedFlatFile(p, "G24 types utf8", s.LandingPath + "\\parity\\in\\G24_types_utf8.csv", LandingExpr + " + \"\\\\parity\\\\in\\\\G24_types_utf8.csv\"", 65001, "\n", true,
                new string[] { "Id", "NameAnsiText", "NameUnicode", "Amount", "Ratio" }, typesUtf8, widths, precisions, scales);

            TaskHost h1 = AddTask(p, "Data Flow Task", "STOCK:PipelineTask", "Load 1252 file");
            MainPipe mp1 = h1 == null ? null : (MainPipe)h1.InnerObject;
            IDTSComponentMetaData100 src1 = FlatFileSource(mp1, "Read 1252 file", ansi, false);
            IgnoreTruncation(src1, "NameAnsi", "NameUnicode");
            IDTSComponentMetaData100 tag1 = AddComponent(mp1, "Derived Column", "Add SourceFile");
            Path(mp1, src1, tag1);
            Derive(tag1, "SourceFile", "(DT_STR,40,1252)\"G24_types_1252.csv\"", RtWrapper.DataType.DT_STR, 40, 1252);
            TableDest(mp1, "Write out_ssis G24", "[out_ssis].[G24_Types]", tag1, 0, "TABLOCK,CHECK_CONSTRAINTS", false);

            TaskHost h2 = AddTask(p, "Data Flow Task", "STOCK:PipelineTask", "Load UTF-8 file");
            MainPipe mp2 = h2 == null ? null : (MainPipe)h2.InnerObject;
            IDTSComponentMetaData100 src2 = FlatFileSource(mp2, "Read UTF-8 file", utf8, false);
            IgnoreTruncation(src2, "NameAnsiText", "NameUnicode");
            IDTSComponentMetaData100 conv = AddComponent(mp2, "Data Conversion", "To code page 1252");
            Path(mp2, src2, conv);
            ConvertColumn(conv, "NameAnsiText", "NameAnsi", RtWrapper.DataType.DT_STR, 10, 1252, true);
            IDTSComponentMetaData100 tag2 = AddComponent(mp2, "Derived Column", "Add SourceFile");
            Path(mp2, conv, tag2);
            Derive(tag2, "SourceFile", "(DT_STR,40,1252)\"G24_types_utf8.csv\"", RtWrapper.DataType.DT_STR, 40, 1252);
            TableDest(mp2, "Write out_ssis G24", "[out_ssis].[G24_Types]", tag2, 0, "TABLOCK,CHECK_CONSTRAINTS", false);
            Link(p, h1, h2, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private void P25()
        {
            Package p = NewParityPackage("P25_Dedupe",
                "G25: Sort on CustomerKey with remove duplicates. The source is ordered CustomerKey, UpdatedAt DESC, RowId; SSIS 2025 keeps the LAST row of each key in that order (the oldest UpdatedAt, then the highest RowId). Microsoft documents the survivor as arbitrary.");
            MainPipe mp = AddDataFlow(p, "Dedupe customers");
            IDTSComponentMetaData100 src = SqlSource(mp, "Read pty G25_Input",
                "SELECT RowId, CustomerKey, Email, UpdatedAt FROM pty.G25_Input ORDER BY CustomerKey, UpdatedAt DESC, RowId;");
            IDTSComponentMetaData100 sort = AddComponent(mp, "Sort", "Remove duplicate CustomerKey");
            Path(mp, src, sort);
            SetCompProp(sort, "EliminateDuplicates", true);
            if (sort != null)
            {
                try
                {
                    CManagedComponentWrapper inst = sort.Instantiate();
                    IDTSInput100 input = sort.InputCollection[0];
                    IDTSVirtualInput100 vi = input.GetVirtualInput();
                    foreach (IDTSVirtualInputColumn100 vc in vi.VirtualInputColumnCollection)
                    {
                        IDTSInputColumn100 ic = inst.SetUsageType(input.ID, vi, vc.LineageID, DTSUsageType.UT_READONLY);
                        if (vc.Name == "CustomerKey") inst.SetInputColumnProperty(input.ID, ic.ID, "NewSortKeyPosition", 1);
                    }
                }
                catch (Exception ex) { Warn("Sort keys not configured: " + ex.Message); }
            }
            TableDest(mp, "Write out_ssis G25", "[out_ssis].[G25_Dedupe]", sort, 0, "TABLOCK,CHECK_CONSTRAINTS", false);
            FinishPackage(p);
        }

        private void P26()
        {
            Package p = NewParityPackage("P26_LoadOptions",
                "G26: fast load into out_ssis.G26_LoadOptions with CHECK_CONSTRAINTS and FIRE_TRIGGERS, KeepNulls off, one row per commit; rows the constraint rejects go to the error output and are dropped.");
            MainPipe mp = AddDataFlow(p, "Fast load with options");
            IDTSComponentMetaData100 src = SqlSource(mp, "Read pty G26_Input", "SELECT SourceId, Amount, Channel FROM pty.G26_Input ORDER BY SourceId;");
            IDTSComponentMetaData100 dst = TableDest(mp, "Write out_ssis G26", "[out_ssis].[G26_LoadOptions]", src, 0, "CHECK_CONSTRAINTS,FIRE_TRIGGERS", false);
            SetCompProp(dst, "FastLoadMaxInsertCommitSize", 1);
            if (dst != null) dst.InputCollection[0].ErrorRowDisposition = DTSRowDisposition.RD_RedirectRow;
            FinishPackage(p);
        }

        private void P27()
        {
            Package p = NewParityPackage("P27_ProcSource",
                "G27: OLE DB Source runs pty.usp_G27_Source (temp table inside) with WITH RESULT SETS so metadata can be discovered; output to out_ssis.G27_ProcSource.");
            MainPipe mp = AddDataFlow(p, "Load from procedure");
            IDTSComponentMetaData100 src = SqlSource(mp, "Run pty usp_G27_Source",
                "EXEC pty.usp_G27_Source @Region = 'east' WITH RESULT SETS ((CustomerId int NOT NULL, Region varchar(10) NOT NULL, TotalAmount decimal(14, 2) NOT NULL, OrderCount int NOT NULL));");
            TableDest(mp, "Write out_ssis G27", "[out_ssis].[G27_ProcSource]", src, 0, "TABLOCK,CHECK_CONSTRAINTS", false);
            FinishPackage(p);
        }

        private void P28()
        {
            Package p = NewParityPackage("P28_SystemVars",
                "G28: date-folder expressions from the RunDate parameter, plus machine, user, start time and execution GUID, written to out_ssis.G28_SystemVars.");
            Parameter runDate = p.Parameters.Add("RunDate", TypeCode.String);
            runDate.Value = "2026-01-31";
            runDate.Description = "Business date (yyyy-MM-dd). The folder and stamp values derive from it.";
            string d = "(DT_DBDATE)@[$Package::RunDate]";
            string yyyy = "(DT_WSTR,4)YEAR(" + d + ")";
            string mm = "RIGHT(\"0\" + (DT_WSTR,2)MONTH(" + d + "), 2)";
            string dd = "RIGHT(\"0\" + (DT_WSTR,2)DAY(" + d + "), 2)";
            ExprVariable(p, "ArchiveFolder", "\"archive\\\\\" + " + yyyy + " + \"\\\\\" + " + mm + " + \"\\\\\"");
            ExprVariable(p, "MonthFolder", yyyy + " + \"-\" + " + mm);
            ExprVariable(p, "FileStamp", yyyy + " + " + mm + " + " + dd);
            TaskHost ins = AddExecuteSql(p, "Record system variables", cmWindows, "SELECT 1;");
            if (ins != null) ins.SetExpression("SqlStatementSource",
                "\"INSERT out_ssis.G28_SystemVars (RunDate, ArchiveFolder, MonthFolder, FileStamp, MachineName, UserName, StartTime, ExecutionGuid) VALUES ('\" + @[$Package::RunDate]"
                + " + \"', '\" + @[User::ArchiveFolder] + \"', '\" + @[User::MonthFolder] + \"', '\" + @[User::FileStamp]"
                + " + \"', N'\" + REPLACE(@[System::MachineName], \"'\", \"''\") + \"', N'\" + REPLACE(@[System::UserName], \"'\", \"''\")"
                + " + \"', '\" + (DT_WSTR, 30) @[System::StartTime] + \"', N'\" + @[System::ExecutionInstanceGUID] + \"');\"");
            FinishPackage(p);
        }

        private void P29()
        {
            Package p = NewParityPackage("P29_OutputFiles",
                "G29: pty.G29_Input written to <LandingPath>\\parity\\G29\\ssis as one file per Region (region_<Region>_<yyyyMMdd_HHmmss>.csv) and as files of 10 rows (part_<n>_<stamp>.csv). Code page 1252, CRLF, header row, no text qualifier, rows in RowId order.");
            string st = "@[System::StartTime]";
            Func<string, string> two = delegate(string part) { return "RIGHT(\"0\" + (DT_WSTR,2)DATEPART(\"" + part + "\", " + st + "), 2)"; };
            ExprVariable(p, "Stamp", "(DT_WSTR,4)YEAR(" + st + ") + " + two("mm") + " + " + two("dd") + " + \"_\" + " + two("hh") + " + " + two("mi") + " + " + two("ss"));
            p.Variables.Add("Regions", false, "User", new object());
            p.Variables.Add("Region", false, "User", "east");
            p.Variables.Add("PartCount", false, "User", 0);
            p.Variables.Add("Part", false, "User", 1);
            ExprVariable(p, "RegionSql", "\"SELECT RowId, Region, Amount FROM pty.G29_Input WHERE Region = '\" + @[User::Region] + \"' ORDER BY RowId;\"");
            ExprVariable(p, "PartSql", "\"SELECT RowId, Region, Amount FROM (SELECT RowId, Region, Amount, (ROW_NUMBER() OVER (ORDER BY RowId) - 1) / 10 + 1 AS Part FROM pty.G29_Input) AS x WHERE Part = \" + (DT_WSTR, 10) @[User::Part] + \" ORDER BY RowId;\"");

            string outDir = s.LandingPath + "\\parity\\G29\\ssis";
            string outDirExpr = LandingExpr + " + \"\\\\parity\\\\G29\\\\ssis\"";
            ConnectionManager create = FolderConnection(p, "G29 ssis folder (create)", outDir, outDirExpr, 3);
            ConnectionManager clear = FolderConnection(p, "G29 ssis folder", outDir, outDirExpr, 2);
            TaskHost mk = FileSystemTask(p, "Create output folder", "CreateDirectory", create);
            TaskHost rm = FileSystemTask(p, "Empty output folder", "DeleteDirectoryContent", clear);
            Link(p, mk, rm, DTSExecResult.Success, null);

            string[] cols = new string[] { "RowId", "Region", "Amount" };
            RtWrapper.DataType[] types = new RtWrapper.DataType[] { RtWrapper.DataType.DT_I4, RtWrapper.DataType.DT_STR, RtWrapper.DataType.DT_NUMERIC };
            int[] widths = new int[] { 0, 10, 0 }; int[] precisions = new int[] { 0, 0, 9 }; int[] scales = new int[] { 0, 0, 2 };
            ConnectionManager regionFile = TypedFlatFile(p, "Region file", outDir + "\\region_east.csv",
                outDirExpr + " + \"\\\\region_\" + @[User::Region] + \"_\" + @[User::Stamp] + \".csv\"", 1252, "\r\n", false, cols, types, widths, precisions, scales);
            ConnectionManager partFile = TypedFlatFile(p, "Part file", outDir + "\\part_1.csv",
                outDirExpr + " + \"\\\\part_\" + (DT_WSTR, 10) @[User::Part] + \"_\" + @[User::Stamp] + \".csv\"", 1252, "\r\n", false, cols, types, widths, precisions, scales);

            // One file per Region
            TaskHost regions = AddExecuteSql(p, "Get regions", cmWindows, "SELECT DISTINCT Region FROM pty.G29_Input ORDER BY Region;");
            SetTaskEnum(regions, "ResultSetType", "ResultSetType_Rowset");
            AddResultBinding(regions, "0", "User::Regions");
            ForEachLoop fe = (ForEachLoop)p.Executables.Add("STOCK:FOREACHLOOP");
            fe.Name = "Each region";
            Dictionary<string, object> props = new Dictionary<string, object>();
            props["DataObjectVariable"] = "User::Regions";
            if (SetEnumerator(fe, "Foreach ADO Enumerator", props)) MapLoopVariable(fe, "User::Region", 0);
            TaskHost rf = AddTask(fe, "Data Flow Task", "STOCK:PipelineTask", "Write region file");
            rf.DelayValidation = true;
            MainPipe mpr = (MainPipe)rf.InnerObject;
            IDTSComponentMetaData100 srcR = VariableSource(mpr, "Read region rows", "User::RegionSql");
            FlatFileDest(mpr, "Region csv", regionFile, srcR);

            // Files of 10 rows
            TaskHost count = AddExecuteSql(p, "Count parts", cmWindows, "SELECT CAST(CEILING(COUNT(*) / 10.0) AS int) AS PartCount FROM pty.G29_Input;");
            SetTaskEnum(count, "ResultSetType", "ResultSetType_SingleRow");
            AddResultBinding(count, "PartCount", "User::PartCount");
            ForLoop loop = (ForLoop)p.Executables.Add("STOCK:FORLOOP");
            loop.Name = "Each part";
            loop.InitExpression = "@[User::Part] = 1";
            loop.EvalExpression = "@[User::Part] <= @[User::PartCount]";
            loop.AssignExpression = "@[User::Part] = @[User::Part] + 1";
            TaskHost pf = AddTask(loop, "Data Flow Task", "STOCK:PipelineTask", "Write part file");
            pf.DelayValidation = true;
            MainPipe mpp = (MainPipe)pf.InnerObject;
            IDTSComponentMetaData100 srcP = VariableSource(mpp, "Read part rows", "User::PartSql");
            FlatFileDest(mpp, "Part csv", partFile, srcP);

            Link(p, rm, regions, DTSExecResult.Success, null);
            Link(p, regions, fe, DTSExecResult.Success, null);
            Link(p, fe, count, DTSExecResult.Success, null);
            Link(p, count, loop, DTSExecResult.Success, null);
            FinishPackage(p);
        }

        private IDTSComponentMetaData100 FlatFileDest(MainPipe mp, string name, ConnectionManager ff, IDTSComponentMetaData100 from)
        {
            IDTSComponentMetaData100 dst = AddComponent(mp, "Flat File Destination", name);
            UseConnection(dst, ff);
            SetCompProp(dst, "Overwrite", true);
            Path(mp, from, dst);
            if (dst != null && Refresh(dst)) MapMatching(dst);
            return dst;
        }

        private void P30()
        {
            Package p = NewParityPackage("P30_EmptyResultSet",
                "G30: Execute SQL Task with a single-row result set over pty.G30_Driver, which is empty. The task fails, so the package fails before 'Use driver row' runs.");
            p.Variables.Add("BatchId", false, "User", 0);
            p.Variables.Add("FolderPath", false, "User", "");
            TaskHost get = AddExecuteSql(p, "Get driver row", cmWindows, "SELECT BatchId, FolderPath FROM pty.G30_Driver;");
            SetTaskEnum(get, "ResultSetType", "ResultSetType_SingleRow");
            AddResultBinding(get, "BatchId", "User::BatchId");
            AddResultBinding(get, "FolderPath", "User::FolderPath");
            TaskHost use = AddExecuteSql(p, "Use driver row", cmWindows, "SELECT 1 AS Used;");
            Link(p, get, use, DTSExecResult.Success, null);
            FinishPackage(p);
        }
    }
}
'@
    $refs = @($loaded.Dts.Location, $loaded.Pipe.Location, $loaded.Rt.Location)
    Add-Type -TypeDefinition $builderSource -ReferencedAssemblies $refs -Language CSharp
    Write-Log -Level OK -Message 'Compiled embedded builder'
#endregion

#region ---------------- 3. Build ----------------
    $settings = New-Object SsisTestKit.BuildSettings
    $settings.ProjectName     = $ProjectName
    $settings.IspacPath       = Join-Path $OutputPath ($ProjectName + '.ispac')
    $settings.SourcePath      = $SourcePath
    $settings.TestDbServer    = $TestDbServer
    $settings.TestDbName      = $TestDbName
    $settings.TestDbProvider  = $TestDbProvider
    $settings.LandingPath     = $LandingPath
    $settings.ResolveMetadata = [bool]$ResolveMetadata
    $settings.Suite           = $Suite

    if ($Suite -eq 'ParityTests') {
        # Flat-file inputs (exact bytes) go where the packages read them: <LandingPath>\parity\in.
        $inDir = Join-Path $LandingPath 'parity\in'
        New-Item -ItemType Directory -Path $inDir -Force | Out-Null
        Copy-Item -Path (Join-Path $RepoRoot 'tests\parity\data\*.csv') -Destination $inDir -Force
        Write-Log -Message "Parity inputs copied to $inDir"
    }

    $builder = New-Object SsisTestKit.Builder($settings)
    try { $builder.Build() }
    finally { foreach ($line in $builder.Log) { $lvl, $msg = $line -split '\|', 2; Write-Log -Level (@{ 'INFO ' = 'INFO'; 'WARN ' = 'WARN'; 'SKIP ' = 'WARN' }[$lvl]) -Message $msg } }
#endregion

#region ---------------- 4. Manifest ----------------
    $manifest = foreach ($r in $builder.Results) {
        [PSCustomObject]@{
            ProjectName            = $ProjectName
            Package                = $r.Package
            Built                  = $r.Built
            ExpectedRoute          = $r.ExpectedRoute
            ExpectedEffectiveRoute = $r.ExpectedEffectiveRoute
            Runnable               = $r.Runnable
            SkippedItems           = ($r.Skipped -join '; ')
            Warnings               = ($r.Warnings -join '; ')
            Purpose                = $r.Purpose
            SsisAssemblyVersion    = $loaded.Version
        }
    }
    # One manifest per project: a shared file was overwritten by whichever suite was built last.
    $manifestPath = Join-Path $OutputPath ('build_manifest_{0}.csv' -f $ProjectName)
    $manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
    $manifest | Format-Table Package, Built, ExpectedRoute, Runnable, SkippedItems -AutoSize | Out-String -Width 220 | Write-Host

    $built = @($manifest | Where-Object Built).Count
    Write-Log -Level OK -Message ("Built {0} of {1} packages -> {2}" -f $built, @($manifest).Count, $settings.IspacPath)
    if (@($manifest | Where-Object { $_.Warnings }).Count -gt 0) { Write-Log -Level WARN -Message 'Some properties could not be set; see the Warnings column in the build manifest.' }
    Write-Log -Message "Manifest: $manifestPath"
    Write-Log -Message 'Next: .\02_Deploy-SsisTestProject.ps1 -ServerInstance <DevServer>'
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    throw
}
finally {
    Stop-Transcript | Out-Null
}
#endregion
