# Query Store investigation

`Get-QueryStoreProcedureEvidence.ps1` uses a connection with `ApplicationIntent=ReadOnly` and only submits `SELECT` statements. It never executes the target procedure, changes Query Store, forces plans, or issues DDL. Keep its evidence folders outside source control because query text and plans can contain sensitive operational information.

Use the `query-plan-analysis` skill to interpret saved `.sqlplan` files and distinguish observed evidence from inference.
