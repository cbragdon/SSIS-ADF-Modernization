# SSIS migration triage

`01_New-SsisMigrationBacklog.ps1` converts a completed assessment run into local, reviewable migration-planning artifacts. It reads the versioned JSON assessment contract; it does not parse workbooks, connect to SQL Server, create tickets, or change package routes.

```powershell
.\scripts\triage\01_New-SsisMigrationBacklog.ps1 `
  -AssessmentRunFolder 'D:\SSIS_To_ADF\AssessmentRuns\Runs\SSISASSESS_20261021_182247_DESKTOP-6BVBI90'
```

Pass `-BaselineRunFolder` to identify added, removed, rerouted, and resized packages. Results are written to the run folder's `triage` subfolder unless `-OutputFolder` is supplied.

| Output | Purpose |
|---|---|
| `migration-backlog.csv` | Machine-readable prioritized package backlog |
| `migration-backlog.md` | Reviewer-facing backlog |
| `triage-summary.json` | Queue and change counts |
| `route-changes.md` | Baseline comparison |
| `retention-register.md` | Quarterly-review register for `KeepOnSsisVm` packages |

Packages with assessment errors, unreadable packages, or `ReviewRequired` routes always enter the Investigation queue. The initial workflow intentionally creates no GitHub Issues or Azure DevOps work items.
