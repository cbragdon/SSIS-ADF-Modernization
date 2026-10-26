# SSIS Modernization Assessment

`01_Invoke-SsisModernizationAssessment.ps1` looks at your SSIS packages and tells you, package by package,
where each one should end up: rebuilt in **Azure Data Factory (ADF)**, or kept running on the **SSIS VM**.
It also tells you *why*, in plain English, and hands you an Excel workbook your team can plan sprints from.

It only reads. It never deploys, runs, changes or deletes anything on your servers.

## What you need

* Windows PowerShell 5.1 or PowerShell 7. No extra modules and no Excel on the machine running it.
* A login that can see SSISDB. `ssis_admin` or `sysadmin` is best. With less than that, SSISDB quietly hides
  projects you can't read (no error, they just don't show up), and the script warns you about it.
* Network access to the SQL Server instances you point it at.

If PowerShell says scripts are blocked, run this first. It only affects the current window:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Example 1: one server

```powershell
.\scripts\assessment\01_Invoke-SsisModernizationAssessment.ps1 `
    -ServerInstance SQLPRD01 `
    -WorkbookFolder D:\SSIS_Assessment\Workbooks `
    -TrustServerCertificate
```

It connects to `SQLPRD01`, reads every SSIS project in SSISDB and drops one workbook into
`D:\SSIS_Assessment\Workbooks`. If that folder doesn't exist yet, the script creates it and says so in the log.

## Example 2: four servers in one go

```powershell
.\scripts\assessment\01_Invoke-SsisModernizationAssessment.ps1 `
    -ServerInstance SQLPRD01, SQLPRD02, SQLDEV01\ETL, SQLQA01,1433 `
    -WorkbookFolder D:\SSIS_Assessment\Workbooks `
    -OutputRoot     D:\SSIS_Assessment\Runs `
    -IncludeMsdbPackages -IncludeAgentJobs `
    -TrustServerCertificate
```

It works through the servers one at a time and writes **one workbook per server**, so you get four files.
A few things worth knowing:

* `SQLDEV01\ETL` is a named instance and `SQLQA01,1433` is a server on a specific port. Both just work.
* If two of the names turn out to be the same server (say, an alias and the real name), the second one is skipped
  with a warning, so nothing gets counted twice.
* Running it from `powershell.exe -File`? Put the list in quotes: `-ServerInstance "SQLPRD01,SQLPRD02"`. The
  script splits it for you, and it still knows `SQLQA01,1433` is one server with a port.

## What you get

**The workbooks** land in `-WorkbookFolder`, named like this:

```
<ServerName>_SSIS_Migration_Assessment_<yyyyMMdd_HHmmss>.xlsx
SQLPRD01_SSIS_Migration_Assessment_20261021_174209.xlsx
SQLDEV01_ETL_SSIS_Migration_Assessment_20261021_174209.xlsx
```

`<ServerName>` is the name the server reports about itself (`@@SERVERNAME`), not whatever alias you typed.
A `\` can't go in a file name, so `SQLDEV01\ETL` becomes `SQLDEV01_ETL`. Every workbook from the same run shares
the same timestamp.

Each workbook has these tabs:

| Tab | What's on it |
| --- | --- |
| **Summary** | How many packages go to each platform, split by size (S, M, L, XL) |
| **Backlog** | Every package, one row each |
| **ADF**, **SSIS VM**, ... | The same rows, one tab per platform, so each team can filter to its own work |
| **Legend** | What every column and value means, including terms like SHIR and Mapping Data Flow |

The columns that matter most for planning:

* **TargetPlatform**: where the package is headed (ADF, SSIS VM, SSIS VM after remediation, or Undetermined).
* **DecisionDrivers**: why, in a sentence or two a non-SSIS person can follow.
* **ComplexityBand**: rough size, S to XL. **BuildOrder**: build lower numbers first, because children come
  before the parents that call them.
* **PackageLocation**: where the package was found (SSISDB, MSDB, or the file system).
* **isMigrating**: `Yes` by default. It's `Review` if the package hasn't run in the last 90 days, so check with
  the business whether it's still needed. Set it to `No` yourself for anything being retired.
* **BusinessOwner, Developer, Sprint, Status, Decision, Notes**: blank, for your team to fill in.

**The run folder** goes under `-OutputRoot`, in a timestamped folder (`SSISASSESS_<date>_<time>_<machine>`).
That's where the detail lives for engineers:

* `package_assessment.csv`: one row per package with every rule that fired.
* `evidence_items.csv`: the exact task, component or connection behind each decision.
* `connections.csv`: every connection manager, with passwords masked.
* `sprint_backlog.csv`: the backlog rows for all servers in one file.
* `errors.csv`, `route_summary.csv`, and `transcript.log`, the full log of the run.

**The console** tells you what it's doing as it goes:

```
[STEP ] Assessment started 2026-10-21 17:39:26 -04:00
[INFO ] Created folder (did not exist): D:\SSIS_Assessment\Workbooks
[STEP ] [1/4] Server SQLPRD01: started 2026-10-21 17:39:26
[OK   ] [1/4] Server SQLPRD01: completed 2026-10-21 17:39:34 (elapsed 00:00:07, 37 packages, 0 errors)
[STEP ] [2/4] Server SQLPRD02: started 2026-10-21 17:39:34
...
[OK   ] Workbook: D:\SSIS_Assessment\Workbooks\SQLPRD01_SSIS_Migration_Assessment_20261021_173926.xlsx
[OK   ] Assessment completed 2026-10-21 17:41:02 -04:00 (elapsed 00:01:36)
```

Heads-up: the workbooks and CSVs contain real server names, so keep them out of source control.

## All the parameters

| Parameter | What it does | Default |
| --- | --- | --- |
| `-ServerInstance` | One or more servers to assess. Each gets its own workbook. | |
| `-ServerListPath` | A CSV of servers, if typing them out gets old. Columns: `ServerInstance` (required), `Environment` and `TargetSsisVersion` (both optional, per server). | |
| `-PackageFolder` | Folders of `.dtsx` / `.ispac` files to assess straight from disk, for example a source-control checkout. No server needed. These go into a `FileSystem_...` workbook. | |
| `-WorkbookFolder` | Where the workbooks go. Created if missing. | the run folder |
| `-OutputRoot` | Where the run folders (CSVs and log) go. Created if missing. | `C:\Temp\SSIS_ADF_Assessment` |
| `-Environment` | A label stamped on every row, such as Production or Development. | `Unspecified` |
| `-TargetSsisVersion` | The SQL Server version the SSIS VM will run: 2016, 2017, 2019, 2022 or 2025. On 2025, components Microsoft removed become blockers. On older versions they're flagged as future risk. | `2025` |
| `-IncludeMsdbPackages` | Also look at old-style packages stored in msdb. | off |
| `-IncludeAgentJobs` | Read SQL Agent job steps to show which jobs run each package (`AgentJobs`), when they are scheduled (`AgentSchedules`, e.g. `Daily at 01:00`), and spot 32-bit runs. | off |
| `-HistoryDays` | How far back to look at run history. Also sets when `isMigrating` says `Review`. | `90` |
| `-TrustServerCertificate` | Accept a self-signed certificate. You'll want this on most VMs and dev boxes. | off |
| `-SqlCredential` | Use a SQL login instead of your Windows login. Pass `(Get-Credential)`. | Windows login |
| `-DisableEncryption` | Connect without TLS. Only for old servers that can't do encryption. | off |
| `-CommandTimeoutSeconds` | How long to wait on each query, including project exports. | `300` |

You need at least one of `-ServerInstance`, `-ServerListPath` or `-PackageFolder`. You can mix them in one run.

## When something looks off

* **A package says Undetermined.** The script couldn't read it. It's usually fully encrypted
  (`EncryptAll...`) or saved in a very old format. `DecisionDrivers` says which, and what to do about it.
* **Fewer packages than you expected.** Check the log for the permissions warning. Your login probably can't see
  every project.
* **`errors.csv` isn't empty.** Something couldn't be read. Those packages are missing from the results, not
  marked as easy.

For the routing rules themselves, see the repository [README](../../README.md) and
[docs/05_decision-driver-text.md](../../docs/05_decision-driver-text.md).
