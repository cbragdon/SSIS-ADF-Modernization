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
    One project, 15 packages. Each package exercises specific routing rules in
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

    Components that are not installed on the build machine (for example the Attunity CDC and Oracle
    components, which SQL Server 2025 removed) are skipped and listed in build_manifest.csv. Those
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
    Folder for build output (.ispac, build_manifest.csv, build log). Default: <repo>\build.

.PARAMETER SourcePath
    Folder where individual .dtsx files are written for source control review.
    Default: <repo>\test-packages\AssessmentTests.

.PARAMETER ProjectName
    SSIS project name. Must match the -ProjectName used by the deploy script. Default AssessmentTests.

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
    <OutputPath>\build_manifest.csv        one row per package: built, skipped components, expected route
    <OutputPath>\build_<timestamp>.log     transcript
    <SourcePath>\*.dtsx                    individual packages for review / source control

.EXAMPLE
    # On the Dev SSIS server (or a workstation with SSDT), parse-and-deploy test set
    powershell.exe -File .\01_New-SsisTestProject.ps1 -TestDbServer <DevSqlServer>

.EXAMPLE
    # Include live metadata so T02 can execute (seed database must exist first)
    powershell.exe -File .\01_New-SsisTestProject.ps1 -TestDbServer <DevSqlServer> -ResolveMetadata

.NOTES
    Version : 1.0.0
    Part of : SSIS-ADF-Modernization repository (scripts\test-packages)
    Status  : Executed against SQL Server 2025 (SSIS 17.0): 14 of 15 packages build (T15 skipped, CDC/Oracle
              components removed in 2025). Earlier SSIS versions not yet run; review build_manifest.csv
              and the build log after the first run on them.
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$SourcePath,
    [ValidatePattern('^[A-Za-z0-9_]+$')]
    [string]$ProjectName = 'AssessmentTests',
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
    # connection type); once loaded into the AppDomain they resolve.
    foreach ($n in 'SQLTask', 'ScriptTask', 'FileSystemTask', 'ExpressionTask', 'SendMailTask', 'TxScript',
                   'FtpTask', 'ManagedConnections', 'VSTAScriptingLib') {
        try { [void][Reflection.Assembly]::Load("Microsoft.SqlServer.$n, Version=$($loaded.Version).0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91") }
        catch { Write-Log -Level WARN -Message "Could not preload Microsoft.SqlServer.$n" }
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

namespace SsisTestKit
{
    /// <summary>One row of build_manifest.csv.</summary>
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
            if (mp == null || from == null || to == null) return;
            try
            {
                IDTSPath100 p = mp.PathCollection.New();
                p.AttachPathAndPropagateNotifications(from.OutputCollection[0], to.InputCollection[0]);
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

            T01(); T02(); T03(); T04(); T05(); T06(); T07(); T08(); T09(); T10();
            T11(); T12(); T13(); T14(); T15();

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

    $builder = New-Object SsisTestKit.Builder($settings)
    try { $builder.Build() }
    finally { foreach ($line in $builder.Log) { $lvl, $msg = $line -split '\|', 2; Write-Log -Level (@{ 'INFO ' = 'INFO'; 'WARN ' = 'WARN'; 'SKIP ' = 'WARN' }[$lvl]) -Message $msg } }
#endregion

#region ---------------- 4. Manifest ----------------
    $manifest = foreach ($r in $builder.Results) {
        [PSCustomObject]@{
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
    $manifestPath = Join-Path $OutputPath 'build_manifest.csv'
    $manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
    $manifest | Format-Table Package, Built, ExpectedRoute, Runnable, SkippedItems -AutoSize | Out-String -Width 220 | Write-Host

    $built = @($manifest | Where-Object Built).Count
    Write-Log -Level OK -Message ("Built {0} of {1} packages -> {2}" -f $built, @($manifest).Count, $settings.IspacPath)
    if (@($manifest | Where-Object { $_.Warnings }).Count -gt 0) { Write-Log -Level WARN -Message 'Some properties could not be set; see the Warnings column in build_manifest.csv.' }
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
