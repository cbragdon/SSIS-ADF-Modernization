#Requires -Version 5.1
<#
.SYNOPSIS
    Regression test for the assessment's SQL Agent reading (-IncludeAgentJobs): which jobs run each package
    (AgentJobs), their schedules in words (AgentSchedules) and 32-bit execution (Uses32BitJobStep).

.DESCRIPTION
    Development servers only. Needs the AssessmentTests project deployed (02_Deploy-SsisTestProject.ps1) and,
    for the msdb case, any msdb package (package deployment model); without one that case is reported SKIP.

    1. Creates two DISABLED SQL Agent jobs, so they never run:
         ZZ_AssessmentTest_AgentSteps  - three SSIS steps: T02 from SSISDB with /X86, T04 from SSISDB, and the
                                         first msdb package; four schedules: daily 01:00, every 15 minutes
                                         06:00-18:00 on weekdays, monthly on the last Friday 22:30, and a
                                         disabled daily 12:00 schedule
         ZZ_AssessmentTest_NoSchedule  - one SSIS step (T08), no schedule
    2. Runs 01_Invoke-SsisModernizationAssessment.ps1 -IncludeAgentJobs -IncludeMsdbPackages.
    3. Checks AgentJobs, Uses32BitJobStep, Deprecated2025 and AgentSchedules in package_assessment.csv and
       sprint_backlog.csv, JobSchedules in agent_job_steps.csv, that no other package is tagged, and that an
       SSISDB package with the same name as the msdb one is not tagged by the msdb step.
    4. Deletes both jobs and their schedules (also after a failure) and checks msdb's job and schedule lists
       are as they were.

    Exit code 0 when every check passes, 1 otherwise.

.PARAMETER ServerInstance
    The Development server where AssessmentTests is deployed.

.PARAMETER ConfirmDevelopment
    Required: this test creates (and then deletes) two disabled jobs in msdb.

.PARAMETER FolderName / ProjectName
    SSISDB location of the test project. Defaults ZZ_AssessmentTests / AssessmentTests.

.PARAMETER OutputRoot
    Where the assessment output goes. Default C:\Temp\SSIS_AgentJobTests.

.EXAMPLE
    .\04_Test-AgentJobs.ps1 -ServerInstance <DevSqlServer> -ConfirmDevelopment -TrustServerCertificate

.NOTES
    Version : 1.0.0
    Part of : SSIS-ADF-Modernization repository (scripts\test-packages)
    Compat  : Windows PowerShell 5.1 and PowerShell 7.x (uses .NET SqlClient only). Windows authentication.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [switch]$ConfirmDevelopment,
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$FolderName = 'ZZ_AssessmentTests',
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$ProjectName = 'AssessmentTests',
    [string]$OutputRoot = 'C:\Temp\SSIS_AgentJobTests',
    [switch]$TrustServerCertificate
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $ConfirmDevelopment) { throw 'This test creates two disabled SQL Agent jobs in msdb (and deletes them). Pass -ConfirmDevelopment to confirm the server is a Development server.' }

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Assessment = Join-Path $RepoRoot 'scripts\assessment\01_Invoke-SsisModernizationAssessment.ps1'
$Job1 = 'ZZ_AssessmentTest_AgentSteps'
$Job2 = 'ZZ_AssessmentTest_NoSchedule'
$script:pass = 0; $script:fail = 0; $script:skip = 0

function Write-Result([string]$Status, [string]$Message) {
    $c = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow'; INFO = 'Gray' }[$Status]
    switch ($Status) { 'PASS' { $script:pass++ } 'FAIL' { $script:fail++ } 'SKIP' { $script:skip++ } }
    Write-Host ('[{0}] {1}' -f $Status, $Message) -ForegroundColor $c
}
function Invoke-Msdb([string]$Sql) {
    # ADO.NET, not sqlcmd: job-step commands contain embedded quotes that a native command line would mangle.
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $ServerInstance; $b['Initial Catalog'] = 'msdb'; $b['Integrated Security'] = $true
    $b['Encrypt'] = $true; $b['TrustServerCertificate'] = [bool]$TrustServerCertificate; $b['Application Name'] = 'SSIS-ADF-AgentJobTest'
    $cn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    $cn.Open()
    try {
        $cmd = $cn.CreateCommand(); $cmd.CommandText = "SET NOCOUNT ON; $Sql"; $cmd.CommandTimeout = 120
        $r = $cmd.ExecuteReader(); $rows = New-Object System.Collections.Generic.List[string]
        do { while ($r.Read()) { $rows.Add([string]$r.GetValue(0)) } } while ($r.NextResult())
        $r.Close(); , $rows.ToArray()
    }
    finally { $cn.Dispose() }
}
function Get-JobAndScheduleList { Invoke-Msdb "SELECT 'JOB ' + name FROM dbo.sysjobs ORDER BY name; SELECT 'SCHED ' + name FROM dbo.sysschedules ORDER BY name;" }
function Remove-TestJobs {
    foreach ($j in $Job1, $Job2) {
        [void](Invoke-Msdb "IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'$j') EXEC dbo.sp_delete_job @job_name = N'$j', @delete_unused_schedule = 1;")
    }
}

$before = Get-JobAndScheduleList
if (@($before | Where-Object { $_ -in "JOB $Job1", "JOB $Job2" }).Count) { throw "A test job from an earlier run still exists ($Job1 / $Job2): delete it, then run again." }
$msdbPkg = @(Invoke-Msdb @"
SELECT TOP (1) f.foldername + N'|' + p.name FROM dbo.sysssispackages AS p JOIN dbo.sysssispackagefolders AS f ON f.folderid = p.folderid
WHERE f.foldername NOT LIKE N'Data Collector%' AND f.foldername NOT LIKE N'Maintenance Plans%' ORDER BY f.foldername, p.name;
"@)
$msdbFolder = $null; $msdbName = $null
if ($msdbPkg.Count) { $msdbFolder, $msdbName = $msdbPkg[0] -split '\|', 2 }

$catalog = "\SSISDB\$FolderName\$ProjectName"
$steps = @(
    @{ Name = 'T02 SSISDB 32-bit'; Command = ('/ISSERVER "\"{0}\T02_CopyWindowsAuth.dtsx\"" /SERVER "\"localhost\"" /X86 /Par "\"$ServerOption::SYNCHRONIZED(Boolean)\"";True /CALLERINFO SQLAGENT /REPORTING E' -f $catalog) },
    @{ Name = 'T04 SSISDB 64-bit'; Command = ('/ISSERVER "\"{0}\T04_ScriptTask.dtsx\"" /SERVER "\"localhost\"" /Par "\"$ServerOption::SYNCHRONIZED(Boolean)\"";True /CALLERINFO SQLAGENT /REPORTING E' -f $catalog) }
)
if ($msdbName) { $steps += @{ Name = 'msdb package'; Command = ('/SQL "\"\{0}\{1}\"" /SERVER localhost /CHECKPOINTING OFF /REPORTING E' -f $msdbFolder, $msdbName) } }

try {
    $q = { param($s) $s.Replace("'", "''") }
    $sql = "EXEC dbo.sp_add_job @job_name = N'$Job1', @enabled = 0, @description = N'Temporary: 04_Test-AgentJobs.ps1. Disabled; deleted by the test.';"
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $sql += " EXEC dbo.sp_add_jobstep @job_name = N'$Job1', @step_id = $($i + 1), @step_name = N'$($steps[$i].Name)', @subsystem = N'SSIS', @command = N'$(& $q $steps[$i].Command)', @on_success_action = $(if ($i -lt $steps.Count - 1) { 3 } else { 1 });"
    }
    $sql += " EXEC dbo.sp_add_jobserver @job_name = N'$Job1', @server_name = N'(local)';"
    $sql += " EXEC dbo.sp_add_jobschedule @job_name = N'$Job1', @name = N'ZZ test daily', @enabled = 1, @freq_type = 4, @freq_interval = 1, @active_start_time = 010000;"
    $sql += " EXEC dbo.sp_add_jobschedule @job_name = N'$Job1', @name = N'ZZ test business hours', @enabled = 1, @freq_type = 8, @freq_interval = 62, @freq_recurrence_factor = 1, @freq_subday_type = 4, @freq_subday_interval = 15, @active_start_time = 060000, @active_end_time = 180000;"
    $sql += " EXEC dbo.sp_add_jobschedule @job_name = N'$Job1', @name = N'ZZ test month end', @enabled = 1, @freq_type = 32, @freq_interval = 6, @freq_relative_interval = 16, @freq_recurrence_factor = 1, @active_start_time = 223000;"
    $sql += " EXEC dbo.sp_add_jobschedule @job_name = N'$Job1', @name = N'ZZ test off', @enabled = 0, @freq_type = 4, @freq_interval = 1, @active_start_time = 120000;"
    $t08 = '/ISSERVER "\"{0}\T08_Child.dtsx\"" /SERVER "\"localhost\"" /CALLERINFO SQLAGENT /REPORTING E' -f $catalog
    $sql += " EXEC dbo.sp_add_job @job_name = N'$Job2', @enabled = 0, @description = N'Temporary: 04_Test-AgentJobs.ps1. Disabled; deleted by the test.';"
    $sql += " EXEC dbo.sp_add_jobstep @job_name = N'$Job2', @step_id = 1, @step_name = N'T08', @subsystem = N'SSIS', @command = N'$(& $q $t08)';"
    $sql += " EXEC dbo.sp_add_jobserver @job_name = N'$Job2', @server_name = N'(local)';"
    [void](Invoke-Msdb $sql)
    Write-Result INFO "Created disabled jobs $Job1 ($($steps.Count) SSIS steps, 4 schedules) and $Job2 (1 step, no schedule)"

    $out = Join-Path $OutputRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
    $assessArgs = @{ ServerInstance = $ServerInstance; IncludeAgentJobs = $true; IncludeMsdbPackages = $true; Environment = 'AgentJobTest'; OutputRoot = $out; WorkbookFolder = (Join-Path $out 'workbooks') }
    if ($TrustServerCertificate) { $assessArgs['TrustServerCertificate'] = $true }
    & $Assessment @assessArgs | Out-Null
    $run = (Get-ChildItem $out -Directory -Filter 'SSISASSESS_*' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
    $pa = @(Import-Csv (Join-Path $run 'package_assessment.csv'))
    $sb = @(Import-Csv (Join-Path $run 'sprint_backlog.csv'))
    $js = @(Import-Csv (Join-Path $run 'agent_job_steps.csv'))

    $sched1 = 'job disabled; Daily at 01:00; Weekly on Mon,Tue,Wed,Thu,Fri every 15 minutes from 06:00 to 18:00; Monthly on the last Fri at 22:30; Daily at 12:00 (schedule disabled)'
    $sched2 = 'job disabled; no schedule (runs only when started by hand or by another job)'
    $expect = @(
        @{ Loc = 'SSISDB'; Pkg = 'T02_CopyWindowsAuth.dtsx'; Job = $Job1; X86 = 'True';  Sched = "${Job1}: $sched1" },
        @{ Loc = 'SSISDB'; Pkg = 'T04_ScriptTask.dtsx';      Job = $Job1; X86 = 'False'; Sched = "${Job1}: $sched1" },
        @{ Loc = 'SSISDB'; Pkg = 'T08_Child.dtsx';           Job = $Job2; X86 = 'False'; Sched = "${Job2}: $sched2" },
        @{ Loc = 'SSISDB'; Pkg = 'T07_Parent.dtsx';          Job = '';    X86 = 'False'; Sched = '' }
    )
    if ($msdbName) {
        $expect += @{ Loc = 'MSDB'; Pkg = "$msdbName.dtsx"; Job = $Job1; X86 = 'False'; Sched = "${Job1}: $sched1" }
        # An SSISDB package of the same name must not be tagged by the msdb step.
        if (@($pa | Where-Object { $_.SourceType -eq 'SSISDB' -and $_.Package -eq "$msdbName.dtsx" }).Count) {
            $expect += @{ Loc = 'SSISDB'; Pkg = "$msdbName.dtsx"; Job = ''; X86 = 'False'; Sched = '' }
        }
    }
    else { Write-Result SKIP 'No msdb package on this server: the msdb job-step case was not tested' }

    foreach ($e in $expect) {
        $r = @($pa | Where-Object { $_.SourceType -eq $e.Loc -and $_.Package -eq $e.Pkg })
        $b = @($sb | Where-Object { $_.PackageLocation -eq $e.Loc -and $_.Package -eq $e.Pkg })
        if ($r.Count -ne 1 -or $b.Count -ne 1) { Write-Result FAIL "$($e.Loc) $($e.Pkg): expected one assessment and one backlog row, found $($r.Count) / $($b.Count)"; continue }
        $x86Ok = ($e.X86 -eq 'True') -eq ([string]$r[0].Deprecated2025 -match '32-bit')
        $ok = $r[0].AgentJobs -eq $e.Job -and $b[0].AgentJobs -eq $e.Job -and $r[0].Uses32BitJobStep -eq $e.X86 -and $x86Ok -and
              $r[0].AgentSchedules -eq $e.Sched -and $b[0].AgentSchedules -eq $e.Sched
        Write-Result $(if ($ok) { 'PASS' } else { 'FAIL' }) ("{0} {1}: AgentJobs=[{2}] Uses32Bit={3} AgentSchedules=[{4}]" -f $e.Loc, $e.Pkg, $r[0].AgentJobs, $r[0].Uses32BitJobStep, $r[0].AgentSchedules)
    }
    $tagged = @($pa | Where-Object { $_.AgentJobs -and $_.AgentJobs -notin $Job1, $Job2 -and $_.AgentJobs -notmatch "^ZZ_AssessmentTest_" }).Count
    $ours = @($pa | Where-Object { $_.AgentJobs -match "ZZ_AssessmentTest_" }).Count
    $wantOurs = 3 + $(if ($msdbName) { 1 } else { 0 })
    Write-Result $(if ($ours -eq $wantOurs) { 'PASS' } else { 'FAIL' }) "Exactly the $wantOurs stepped packages carry a test job name (found $ours; packages tagged by other jobs on this server: $tagged)"
    $jsOurs = @($js | Where-Object { $_.JobName -eq $Job1 })
    $jsOk = $jsOurs.Count -eq $steps.Count -and @($jsOurs | Where-Object { $_.JobSchedules -eq $sched1 }).Count -eq $steps.Count
    Write-Result $(if ($jsOk) { 'PASS' } else { 'FAIL' }) "agent_job_steps.csv: $($jsOurs.Count) step row(s) for $Job1, each with its JobSchedules"
}
finally {
    Remove-TestJobs
    $after = Get-JobAndScheduleList
    $diff = @(Compare-Object $before $after)
    Write-Result $(if ($diff.Count -eq 0) { 'PASS' } else { 'FAIL' }) "Cleanup: msdb job and schedule lists are as before ($($diff.Count) difference(s))"
}
Write-Result $(if ($script:fail) { 'FAIL' } else { 'PASS' }) ("{0} passed, {1} failed, {2} skipped." -f $script:pass, $script:fail, $script:skip)
exit $(if ($script:fail) { 1 } else { 0 })
