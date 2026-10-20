# ETL platform decision — summary

The full decision request lives in the Claude Docs artifact
*"Decision Request: ETL Platform — Azure Data Factory vs. SSIS on SQL Server VM"*.
This page summarises it so the repository is readable on its own. If the two disagree, the
decision document wins; update this page in the same pull request.

## Recommendation

**Option D — hybrid.** Azure Data Factory becomes the standard orchestrator and the platform for all
new pipelines. Existing SSIS packages keep running on SSIS hosted on a SQL Server VM, orchestrated by
ADF, until each is retired or rewritten. No new SSIS packages after approval.

## Options considered

| Option | Engine | Existing packages | Why not chosen as the standard |
| --- | --- | --- | --- |
| A. SSIS on SQL Server VM | SSIS | Run unchanged | Shrinking feature set (SQL Server 2025 removals); we own HA and patching |
| B. ADF + Azure-SSIS IR | SSIS runtime hosted by ADF | Little to no change | Two control planes, IR start/stop and cold start; rewrite only deferred |
| C. ADF native | ADF Copy / Data Flows / activities | Rewritten | Right end state, but full rewrite before value |
| **D. Hybrid** | ADF orchestrates; SSIS on VM runs legacy | Unchanged now, rewritten over time | **Recommended** |

## How the assessment routes map to the options

| Assessment route | Work item |
| --- | --- |
| `AdfNative-Low`, `AdfNative-Medium` | Option C rewrite backlog, ordered by run frequency, duration and dependencies |
| `KeepOnSsisVm` | Option D legacy path; orchestrated by ADF via SSISDB `create_execution` / `start_execution` over a Self-hosted IR |
| `Remediate2025` | Fix the component, pin the SSIS host to SQL Server 2022, or move to ADF first |
| `ReviewRequired` | Manual review before any routing |
| `AzureSsisIrFit` column | Evidence for Option B, if a mandate to remove IaaS VMs appears |

## Environments

Development → Testing → Staging → Production. Non-production in **<NonProdSubscription>**, Production in
**<ProdSubscription>**. Code moves only through source control; only configuration differs per environment
(ADF parameter files and global parameters; SSISDB environments for SSIS).

## SQL Server 2025 SSIS changes that affect routing

* **Removed:** Attunity CDC components and CDC Service for Oracle; Microsoft Connector for Oracle;
  Hadoop Hive / Pig / File System tasks.
* **Deprecated:** legacy Integration Services Service (package store); 32-bit mode; SqlClient Data
  Provider (SDS) connection type in maintenance tasks and some Foreach enumerators.
* **Engine:** Data Quality Services discontinued (DQS Cleansing cannot run).

Source: [What's New in SQL Server 2025 Integration Services](https://learn.microsoft.com/sql/integration-services/what-s-new-in-integration-services-in-sql-server-2025?view=sql-server-ver17)

## Gate before Production

A rewritten package is accepted only when it produces identical row counts and checksums to its SSIS
version in Test, and the same artifact promotes Dev → Test → Staging with only parameter files changed.
