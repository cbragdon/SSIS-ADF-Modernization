# Test package catalog

Two sets of test inputs exercise the assessment's routing rules. Expected routes for both live in
`tests/expected/` and are the **single source of truth**; `build/build_manifest.csv` repeats them for
convenience only.

| Set | Where | Built by | Runs in | Purpose |
| --- | --- | --- | --- | --- |
| AssessmentTests project | `test-packages/AssessmentTests/`, `build/AssessmentTests.ispac` | `01_New-SsisTestProject.ps1` (SSIS object model) | SSISDB on the Dev server | Real, deployable packages; parameters, environments, run history |
| Fixtures | `tests/fixtures/` | Hand-written XML | Offline / CI | Cases a modern SSIS install cannot build: encrypted and 2008-era packages, Attunity CDC, third-party tasks, odd `.ispac` part names |

## AssessmentTests project (15 packages, target SQL Server 2025)

| Package | Objects and parameters exercised | Expected route | Expected effective route | Runnable |
| --- | --- | --- | --- | --- |
| T01_CopySqlAuth | Execute SQL; OLE DB source → Data Conversion → OLE DB destination; SQL auth; project connection manager with expression | AdfNative-Low | AdfNative-Low | Parse only |
| T02_CopyWindowsAuth | Same copy over Windows auth (raises to Medium) | AdfNative-Medium | AdfNative-Medium | **Yes**, with `-ResolveMetadata` and seed DB |
| T03_TransformChain | Derived Column, Conditional Split, Lookup, Sort, Aggregate, Union All, Multicast, Row Count; user variable | AdfNative-Medium | AdfNative-Medium | Parse only |
| T04_ScriptTask | Script Task (placeholder, no code) | KeepOnSsisVm | KeepOnSsisVm | No (by design) |
| T05_ScriptComponent | Script Component in a data flow | KeepOnSsisVm | KeepOnSsisVm | No (by design) |
| T06_ContainersConstraints | Sequence, For Loop, Foreach File Enumerator + variable mapping, File System Task, UNC path, success/failure/completion/expression constraints, OnError handler, property expression | AdfNative-Medium | AdfNative-Medium | Parse only |
| T07_Parent | Execute Package Task (project reference) → T08 | AdfNative-Low | **KeepOnSsisVm** (roll-up) | Parse only |
| T08_Child | Script Task; package parameter `BatchId` | KeepOnSsisVm | KeepOnSsisVm | No |
| T09_DisabledScriptTask | Disabled Script Task (must be ignored) | AdfNative-Low | AdfNative-Low | Parse only |
| T10_FlatFileToExcel | Flat File source over UNC; Excel destination; ACE provider | KeepOnSsisVm | KeepOnSsisVm | Parse only |
| T11_ParametersExpressions | Required, typed and **sensitive** package parameters; project parameter references; Expression Task; property expression | AdfNative-Low | AdfNative-Low | Parse only |
| T12_OleDbCommandScd | OLE DB Command; Slowly Changing Dimension | AdfNative-Medium | AdfNative-Medium | Parse only |
| T13_FtpAndSendMail | FTP Task; Send Mail Task; FTP and SMTP connection managers | AdfNative-Medium | AdfNative-Medium | Parse only |
| T14_FuzzyLookup | Fuzzy Lookup — built only if installed | KeepOnSsisVm | KeepOnSsisVm | Parse only |
| T15_RemovedIn2025 | CDC / Oracle components — built only if installed (usually absent on 2022+) | Remediate2025 | Remediate2025 | No |

### Project-level objects

| Object | Name | Notes |
| --- | --- | --- |
| Project parameter | `TestDbServer`, `TestDbName`, `TestDbProvider`, `LandingPath`, `SqlLoginUser` | Bound to SSISDB environment variables by the deploy script |
| Project parameter | `SqlLoginPassword` | **Sensitive**; value supplied only through the environment |
| Project connection manager | `TestDb_Windows` | OLE DB, Windows auth, connection string driven by project parameters |
| Project connection manager | `TestDb_Sql` | OLE DB, SQL auth, password from `SqlLoginPassword` |
| SSISDB environments | `Dev`, `Test` | Same variables; `LandingPath` differs; relative references from the project |

## Fixtures (offline, CI)

| Fixture | Covers | Expected (2025) | Expected (2022) |
| --- | --- | --- | --- |
| `ProjA/Parent.dtsx` | Script Task, Script Component, disabled FTP Task, UNC flat file, Windows-auth project connection, child roll-up | KeepOnSsisVm → **Remediate2025** | KeepOnSsisVm |
| `ProjA/Child.dtsx` | Attunity CDC Source (managed component host) | Remediate2025 | KeepOnSsisVm (future risk) |
| `IspacDrop/ProjB.ispac` | Same packages inside an `.ispac`, percent-encoded part name `Parent%20Pkg.dtsx` | as above | — |
| `Loose/SimpleCopy.dtsx` | SQL-auth copy; planted password must be masked | AdfNative-Low | — |
| `Loose/ThirdParty.dtsx` | Unrecognised third-party task; Foreach File Enumerator | KeepOnSsisVm | — |
| `Loose/Encrypted.dtsx` | `EncryptAllWithPassword` body | ReviewRequired | — |
| `Loose/Legacy2008.dtsx` | PackageFormatVersion 3 | ReviewRequired | — |
| `Loose/LegacyConfig.dtsx` | G07: package configurations (file, SQL table, environment variable, parent variable); file-system child package | AdfNative-Medium → **ReviewRequired** (unresolved child) | — |
| `ProjC/ErrorRows.dtsx` | G01: Data Conversion error/truncation rows redirected to an error table | AdfNative-Medium | — |
| `ProjC/RawStage.dtsx` | G02: Raw File Destination and Source staging (no ADF equivalent format) | AdfNative-Medium | — |
| `ProjC/DynamicPaths.dtsx` | G05: flat file path built by expression from a variable expression (UNC); Foreach ADO enumerator | AdfNative-Medium, reason "set by expression" | — |
| `ProjC/DisabledContainer.dtsx` | G06: enabled Script Task inside a disabled Sequence container | AdfNative-Low | — |
| `ProjC/TxnCheckpoint.dtsx` | G08: `TransactionOption=Required` container (MSDTC); checkpoint restart | AdfNative-Medium | — |
| `ProjC/LoggingProviders.dtsx` | G09: five log providers; file and Windows-auth connections used only for logging | AdfNative-Low | — |
| `ProjC/LoggingSharedConn.dtsx` | G09 control: log file connection also used by a File System Task | AdfNative-Medium | — |

`G01`–`G09` refer to the SSIS test package gap analysis (TechBrothersIT scenario review). The `ExpectedReasons`
column in `tests/expected/fixtures_expected_routes.csv` lists `|`-separated text that must appear in the
package's `RouteReasons`, so these cases prove the route is right for the right reason.

## Adding a test case

1. Add the package (builder method or fixture file).
2. Add its row to the matching `tests/expected/*.csv`, with what it covers. In the fixtures file, fill
   `ExpectedReasons` when the route alone cannot prove the rule fired.
3. Run `03_Test-AssessmentRouting.ps1` locally; commit both together. CI runs the fixtures on every push.
