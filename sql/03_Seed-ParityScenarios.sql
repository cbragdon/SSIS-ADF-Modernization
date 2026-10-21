/*
================================================================================
 03_Seed-ParityScenarios.sql
--------------------------------------------------------------------------------
 Purpose : Source data and empty output tables for the data-parity scenarios
           G22-G30 (gap analysis, Priority 3). Each scenario's input is built to
           hit the edge where SSIS and an ADF rebuild are known to disagree.

 Scope   : DEVELOPMENT / TEST SERVERS ONLY. Synthetic data only. Runs in
           SsisAssessmentTest after 01_ and 02_.

 Behaviour
   * Idempotent: tables are created when missing; input tables are re-seeded
     to a fixed state on every run; output tables are created empty and are
     emptied by pty.usp_ResetOutputs before each scenario run.
   * Same shape on both sides: out_ssis.<table> is written by the SSIS package,
     out_adf.<table> by the rewrite. parity.usp_CompareTables compares them.

 Schemas
   pty       scenario inputs and helpers
   out_ssis  outputs written by the SSIS packages
   out_adf   outputs written by the ADF (or other) rewrite

 Scenarios (inputs -> output table)
   G22 Lookup semantics      pty.G22_Input, pty.G22_Reference      -> G22_LookupResult
   G23 Blank vs NULL         tests/parity/data/G23_blanks.csv        -> G23_BlankNull
   G24 Types / code pages    tests/parity/data/G24_*.csv             -> G24_Types
   G25 Dedupe tie-break      pty.G25_Input                         -> G25_Dedupe
   G26 Fast-load options     pty.G26_Input                         -> G26_LoadOptions, G26_TriggerAudit
   G27 Proc as source        pty.usp_G27_Source                    -> G27_ProcSource
   G28 System variables      package/pipeline parameter RunDate    -> G28_SystemVars
   G29 Output file shapes    pty.G29_Input                         -> files under <LandingPath>\parity\G29\...
   G30 Empty result set      pty.G30_Driver (no rows)              -> run outcome (both sides should fail)

 ADF staging (written only by the ADF pipelines in adf\)
   pty.G23_AdfStage, pty.G24_AdfStage   flat-file rows as text before conversion
================================================================================
*/
SET NOCOUNT ON;
GO

USE SsisAssessmentTest;
GO

IF SCHEMA_ID(N'pty')      IS NULL EXEC (N'CREATE SCHEMA pty AUTHORIZATION dbo;');
IF SCHEMA_ID(N'out_ssis') IS NULL EXEC (N'CREATE SCHEMA out_ssis AUTHORIZATION dbo;');
IF SCHEMA_ID(N'out_adf')  IS NULL EXEC (N'CREATE SCHEMA out_adf AUTHORIZATION dbo;');
GO

-------------------------------------------------------------------------------
-- Inputs (created when missing, re-seeded every run)
-------------------------------------------------------------------------------
-- G22: product codes that differ only in case, trailing spaces or NULL, and a
-- reference set with a duplicate key. SSIS full-cache Lookup compares in .NET
-- (case- and space-sensitive, first duplicate wins, NULL never matches); a SQL
-- join or ADF Lookup follows the column collation.
IF OBJECT_ID(N'pty.G22_Input', N'U') IS NULL
CREATE TABLE pty.G22_Input (InputId int NOT NULL PRIMARY KEY, ProductCode varchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL);
IF OBJECT_ID(N'pty.G22_Reference', N'U') IS NULL
CREATE TABLE pty.G22_Reference (RefId int NOT NULL PRIMARY KEY, ProductCode varchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, Category varchar(20) NOT NULL);
GO
TRUNCATE TABLE pty.G22_Input;
TRUNCATE TABLE pty.G22_Reference;
INSERT pty.G22_Input (InputId, ProductCode) VALUES
    (1, 'P-100'), (2, 'p-100'), (3, 'P-100 '), (4, NULL), (5, 'P-200'), (6, 'P-300'), (7, 'P-999');
INSERT pty.G22_Reference (RefId, ProductCode, Category) VALUES
    (10, 'P-100', 'Bikes'), (20, 'P-200', 'Parts'), (21, 'P-200', 'Accessories'), (30, 'P-300 ', 'Clothing'), (40, NULL, 'Unknown');
GO

-- G25: duplicate customer keys with ties on UpdatedAt, so "which row survives"
-- depends on the engine's sort stability unless the tie-break is explicit.
IF OBJECT_ID(N'pty.G25_Input', N'U') IS NULL
CREATE TABLE pty.G25_Input (RowId int NOT NULL PRIMARY KEY, CustomerKey varchar(10) NOT NULL, Email varchar(100) NULL, UpdatedAt datetime2(0) NOT NULL);
GO
TRUNCATE TABLE pty.G25_Input;
INSERT pty.G25_Input (RowId, CustomerKey, Email, UpdatedAt) VALUES
    (1, 'C001', 'a@example.test',  '2026-01-01T08:00:00'),
    (2, 'C001', 'a2@example.test', '2026-01-02T08:00:00'),
    (3, 'C002', 'b@example.test',  '2026-01-05T08:00:00'),
    (4, 'C002', 'B@example.test',  '2026-01-05T08:00:00'),   -- tie on UpdatedAt, differs only in case
    (5, 'C003', NULL,              '2026-01-03T08:00:00'),
    (6, 'C003', 'c@example.test',  '2026-01-03T08:00:00'),   -- tie, one NULL
    (7, 'C004', 'd@example.test',  '2026-01-04T08:00:00');
GO

-- G26: fast-load options. The target has an IDENTITY, a DEFAULT, a CHECK
-- constraint and an AFTER INSERT trigger, so KEEPIDENTITY, KEEPNULLS,
-- CHECK_CONSTRAINTS and FIRE_TRIGGERS each change the result.
IF OBJECT_ID(N'pty.G26_Input', N'U') IS NULL
CREATE TABLE pty.G26_Input (SourceId int NOT NULL PRIMARY KEY, Amount decimal(9, 2) NOT NULL, Channel varchar(10) NULL);
GO
TRUNCATE TABLE pty.G26_Input;
INSERT pty.G26_Input (SourceId, Amount, Channel) VALUES
    (101, 10.00, 'web'), (102, 25.50, NULL), (103, 0.00, 'store'), (104, 99.99, NULL);
GO

-- G27: a source procedure with a temp table. OLE DB metadata discovery fails
-- without WITH RESULT SETS; ADF schema import may disagree on types.
CREATE OR ALTER PROCEDURE pty.usp_G27_Source
    @Region varchar(10) = 'east'
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #r (CustomerId int NOT NULL, Region varchar(10) NOT NULL, Amount decimal(12, 2) NOT NULL);
    INSERT #r (CustomerId, Region, Amount)
    SELECT CustomerId, Region, Amount FROM src.Customer WHERE Region = @Region;
    SELECT CustomerId, Region, CAST(SUM(Amount) AS decimal(14, 2)) AS TotalAmount, COUNT(*) AS OrderCount
      FROM #r GROUP BY CustomerId, Region;
END;
GO

-- G29: rows to split into files by distinct Region and by row count.
IF OBJECT_ID(N'pty.G29_Input', N'U') IS NULL
CREATE TABLE pty.G29_Input (RowId int NOT NULL PRIMARY KEY, Region varchar(10) NOT NULL, Amount decimal(9, 2) NOT NULL);
GO
TRUNCATE TABLE pty.G29_Input;
INSERT pty.G29_Input (RowId, Region, Amount)
SELECT n, CASE n % 3 WHEN 0 THEN 'east' WHEN 1 THEN 'west' ELSE 'north' END, CAST(n * 1.25 AS decimal(9, 2))
  FROM (SELECT TOP (25) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS x;
GO

-- G30: a driver query that returns no rows. SSIS Single Row result set fails
-- the task; ADF Lookup firstRowOnly succeeds with no firstRow and may fail later.
IF OBJECT_ID(N'pty.G30_Driver', N'U') IS NULL
CREATE TABLE pty.G30_Driver (BatchId int NOT NULL PRIMARY KEY, FolderPath varchar(260) NOT NULL);
GO
TRUNCATE TABLE pty.G30_Driver;
GO

-------------------------------------------------------------------------------
-- Outputs: the same table in out_ssis and out_adf
-------------------------------------------------------------------------------
DECLARE @schema sysname, @sql nvarchar(max);
DECLARE s CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM (VALUES (N'out_ssis'), (N'out_adf')) AS v(name);
OPEN s;
FETCH NEXT FROM s INTO @schema;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
IF OBJECT_ID(N''{s}.G22_LookupResult'', N''U'') IS NULL
CREATE TABLE {s}.G22_LookupResult (InputId int NOT NULL, ProductCode varchar(20) NULL, Category varchar(20) NULL, MatchStatus varchar(10) NOT NULL);
IF OBJECT_ID(N''{s}.G23_BlankNull'', N''U'') IS NULL
CREATE TABLE {s}.G23_BlankNull (Id int NOT NULL, Code varchar(20) NULL, Quantity int NULL, ShipDate date NULL, Note varchar(50) NULL);
IF OBJECT_ID(N''{s}.G24_Types'', N''U'') IS NULL
CREATE TABLE {s}.G24_Types (Id int NOT NULL, SourceFile varchar(40) NOT NULL, NameAnsi varchar(10) NULL, NameUnicode nvarchar(10) NULL, Amount decimal(9, 2) NULL, Ratio float NULL);
IF OBJECT_ID(N''{s}.G25_Dedupe'', N''U'') IS NULL
CREATE TABLE {s}.G25_Dedupe (CustomerKey varchar(10) NOT NULL, Email varchar(100) NULL, UpdatedAt datetime2(0) NOT NULL);
IF OBJECT_ID(N''{s}.G26_LoadOptions'', N''U'') IS NULL
CREATE TABLE {s}.G26_LoadOptions
(
    LoadId   int IDENTITY(1000, 1) NOT NULL PRIMARY KEY,
    SourceId int NOT NULL,
    Amount   decimal(9, 2) NOT NULL CONSTRAINT CK_{s}_G26_Amount CHECK (Amount > 0),
    Channel  varchar(10) NULL CONSTRAINT DF_{s}_G26_Channel DEFAULT (''unknown'')
);
IF OBJECT_ID(N''{s}.G26_TriggerAudit'', N''U'') IS NULL
CREATE TABLE {s}.G26_TriggerAudit (SourceId int NOT NULL, Action varchar(10) NOT NULL);
IF OBJECT_ID(N''{s}.G27_ProcSource'', N''U'') IS NULL
CREATE TABLE {s}.G27_ProcSource (CustomerId int NOT NULL, Region varchar(10) NOT NULL, TotalAmount decimal(14, 2) NOT NULL, OrderCount int NOT NULL);
IF OBJECT_ID(N''{s}.G28_SystemVars'', N''U'') IS NULL
CREATE TABLE {s}.G28_SystemVars
(
    RunDate        date          NOT NULL,
    ArchiveFolder  varchar(260)  NOT NULL,   -- e.g. archive\2026\01\  (deterministic from RunDate)
    MonthFolder    varchar(20)   NOT NULL,   -- e.g. 2026-01
    FileStamp      varchar(20)   NOT NULL,   -- e.g. 20260131      (deterministic from RunDate)
    MachineName    nvarchar(128) NULL,       -- volatile: ignored by the comparison
    UserName       nvarchar(128) NULL,       -- volatile
    StartTime      datetime2(3)  NULL,       -- volatile
    ExecutionGuid  nvarchar(64)  NULL        -- volatile
);';
    SET @sql = REPLACE(@sql, N'{s}', @schema);
    EXEC sys.sp_executesql @sql;
    -- G26 audit trigger: fires only when the load honours FIRE_TRIGGERS.
    SET @sql = REPLACE(N'CREATE OR ALTER TRIGGER {s}.trg_G26_LoadOptions_Insert ON {s}.G26_LoadOptions AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT {s}.G26_TriggerAudit (SourceId, Action) SELECT SourceId, ''insert'' FROM inserted;
END;', N'{s}', @schema);
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM s INTO @schema;
END;
CLOSE s; DEALLOCATE s;
GO

-------------------------------------------------------------------------------
-- ADF staging: the G23 / G24 pipelines copy each file here as text (Copy activity,
-- no type conversion), then a Script activity converts it into out_adf with the
-- same rules the SSIS package applied. Emptied by the pipelines before each copy.
-------------------------------------------------------------------------------
IF OBJECT_ID(N'pty.G23_AdfStage', N'U') IS NULL
CREATE TABLE pty.G23_AdfStage (Id nvarchar(50) NULL, Code nvarchar(100) NULL, Quantity nvarchar(50) NULL, ShipDate nvarchar(50) NULL, Note nvarchar(200) NULL);
IF OBJECT_ID(N'pty.G24_AdfStage', N'U') IS NULL
CREATE TABLE pty.G24_AdfStage (SourceFile nvarchar(260) NULL, Id nvarchar(50) NULL, NameAnsi nvarchar(100) NULL, NameUnicode nvarchar(100) NULL, Amount nvarchar(50) NULL, Ratio nvarchar(50) NULL);
GO

-------------------------------------------------------------------------------
-- Reset: empty one side's outputs before a scenario run (identity reseeded).
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE pty.usp_ResetOutputs
    @Side  varchar(10),            -- 'ssis' | 'adf' | 'both'
    @GapId varchar(10) = NULL      -- NULL = every scenario
AS
BEGIN
    SET NOCOUNT ON;
    IF @Side NOT IN ('ssis', 'adf', 'both') THROW 50010, N'@Side must be ssis, adf or both.', 1;
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'TRUNCATE TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N';' + NCHAR(10)
      FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id
     WHERE s.name IN (CASE WHEN @Side IN ('ssis', 'both') THEN N'out_ssis' END, CASE WHEN @Side IN ('adf', 'both') THEN N'out_adf' END)
       AND (@GapId IS NULL OR t.name LIKE @GapId + N'[_]%');
    EXEC sys.sp_executesql @sql;   -- TRUNCATE also reseeds the G26 IDENTITY to 1000
END;
GO

EXEC pty.usp_ResetOutputs @Side = 'both';
GO

SELECT s.name + N'.' + t.name AS TableName, SUM(p.rows) AS RowCnt
  FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id
  JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
 WHERE s.name IN (N'pty', N'out_ssis', N'out_adf')
 GROUP BY s.name, t.name ORDER BY s.name, t.name;
GO
