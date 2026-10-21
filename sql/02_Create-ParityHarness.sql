/*
================================================================================
 02_Create-ParityHarness.sql
--------------------------------------------------------------------------------
 Purpose : Data-parity harness for SSIS-to-ADF rebuilds. The same seed data goes
           through the SSIS package and through its ADF (or other) rewrite; this
           harness compares the two outputs and logs every comparison, so a
           rebuild is accepted on evidence, not on a green pipeline run.

 Scope   : DEVELOPMENT / TEST SERVERS ONLY. Runs in SsisAssessmentTest
           (01_Create-SsisAssessmentTestDb.sql must have run first).
           Requires SQL Server 2016 SP1 or later (CREATE OR ALTER, STRING_SPLIT,
           FOR JSON, unlimited HASHBYTES input). Database compatibility level 130+.

 Behaviour
   * Idempotent: tables are created only when missing; procedures are
     CREATE OR ALTER. Re-running never deletes logged results.
   * Read-only against the compared objects: it only SELECTs from them.
   * Every comparison writes one parity.Result row (PASS, FAIL, KNOWN_DIFF,
     ERROR) with counts, checksums, a schema diff and sample rows.

 How a table comparison works (parity.usp_CompareTables)
   1. Each row of each side is serialised column by column into a canonical,
      length-prefixed string (NULL is distinct from blank; floats keep 17
      digits; date/time types are normalised to datetime2(7); exact numerics
      to decimal(38,10)) and hashed with SHA2_256.
   2. The two sides are compared as MULTISETS of row hashes, so duplicates
      count: two copies of a row on one side and one on the other is a
      difference. This is binary-exact: case and trailing spaces matter.
   3. A collation-aware EXCEPT (both ways) is also reported. EXCEPT follows
      the column collation (case-insensitive under CI collations, trailing
      spaces ignored) and removes duplicates, so "binary differs but EXCEPT is
      clean" means the sides differ only in case, trailing spaces or
      duplicate counts: the classic Lookup / dedupe parity trap.
   4. Column type differences are reported in SchemaDiff (informational).

 Objects (schema parity)
   parity.TestCase         case catalogue (loaded by 01_Invoke-ParityTest.ps1)
   parity.Run              one row per harness run (who, where, which commit)
   parity.Result           one row per case per run
   parity.FileManifest     file-set snapshots for CompareType = Files
   parity.ExecutionOutcome run outcome per side for CompareType = Outcome
   parity.usp_StartRun / usp_EndRun
   parity.usp_CompareTables / usp_CompareFileManifests / usp_CompareOutcome
   parity.vw_LatestResult  latest result per case

 Removal : DROP the parity schema objects, or drop SsisAssessmentTest.
================================================================================
*/
SET NOCOUNT ON;
GO

USE SsisAssessmentTest;
GO

IF SCHEMA_ID(N'parity') IS NULL EXEC (N'CREATE SCHEMA parity AUTHORIZATION dbo;');
GO

-------------------------------------------------------------------------------
-- Tables (created only when missing)
-------------------------------------------------------------------------------
IF OBJECT_ID(N'parity.TestCase', N'U') IS NULL
CREATE TABLE parity.TestCase
(
    CaseId           varchar(20)    NOT NULL CONSTRAINT PK_parity_TestCase PRIMARY KEY,
    GapId            varchar(10)    NULL,
    Title            nvarchar(200)  NOT NULL,
    CompareType      varchar(10)    NOT NULL CONSTRAINT CK_parity_TestCase_Type CHECK (CompareType IN ('Table', 'Files', 'Outcome')),
    SsisObject       nvarchar(256)  NULL,       -- Table: two-part name of the SSIS output
    CandidateObject  nvarchar(256)  NULL,       -- Table: two-part name of the rewrite's output
    KeyColumns       nvarchar(1000) NULL,       -- used to order sample rows only
    CompareColumns   nvarchar(max)  NULL,       -- NULL = every column of SsisObject
    IgnoreColumns    nvarchar(1000) NULL,       -- volatile columns (load time, GUIDs...)
    ExpectedOutcome  varchar(10)    NOT NULL CONSTRAINT DF_parity_TestCase_Expected DEFAULT ('Match')
                                    CONSTRAINT CK_parity_TestCase_Expected CHECK (ExpectedOutcome IN ('Match', 'Differ')),
    Notes            nvarchar(max)  NULL,
    ModifiedAt       datetime2(0)   NOT NULL CONSTRAINT DF_parity_TestCase_Modified DEFAULT (SYSDATETIME())
);
GO
-- AllowEmpty = 0: two empty outputs are an ERROR (neither side may have run), not a PASS.
IF COL_LENGTH(N'parity.TestCase', N'AllowEmpty') IS NULL
    ALTER TABLE parity.TestCase ADD AllowEmpty bit NOT NULL CONSTRAINT DF_parity_TestCase_AllowEmpty DEFAULT (0);
GO

IF OBJECT_ID(N'parity.Run', N'U') IS NULL
CREATE TABLE parity.Run
(
    RunId        int            IDENTITY(1, 1) NOT NULL CONSTRAINT PK_parity_Run PRIMARY KEY,
    Label        nvarchar(200)  NULL,
    GitCommit    varchar(40)    NULL,
    StartedAt    datetime2(3)   NOT NULL CONSTRAINT DF_parity_Run_Started DEFAULT (SYSDATETIME()),
    EndedAt      datetime2(3)   NULL,
    StartedBy    sysname        NOT NULL CONSTRAINT DF_parity_Run_By DEFAULT (ORIGINAL_LOGIN()),
    HostName     nvarchar(128)  NULL CONSTRAINT DF_parity_Run_Host DEFAULT (HOST_NAME()),
    Passed       int            NULL,
    Failed       int            NULL,
    KnownDiff    int            NULL,
    Errors       int            NULL
);
GO

IF OBJECT_ID(N'parity.Result', N'U') IS NULL
CREATE TABLE parity.Result
(
    ResultId              bigint         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_parity_Result PRIMARY KEY,
    RunId                 int            NOT NULL CONSTRAINT FK_parity_Result_Run REFERENCES parity.Run (RunId),
    CaseId                varchar(20)    NOT NULL,
    CompareType           varchar(10)    NOT NULL,
    Status                varchar(12)    NOT NULL,   -- PASS | FAIL | KNOWN_DIFF | ERROR
    SsisRows              bigint         NULL,
    CandidateRows         bigint         NULL,
    OnlyInSsis            bigint         NULL,       -- binary-exact multiset difference
    OnlyInCandidate       bigint         NULL,
    ExceptOnlyInSsis      bigint         NULL,       -- collation-aware EXCEPT (distinct rows)
    ExceptOnlyInCandidate bigint         NULL,
    SsisChecksum          varchar(64)    NULL,       -- SHA2_256 over the sorted row-hash multiset
    CandidateChecksum     varchar(64)    NULL,
    ComparedColumns       nvarchar(max)  NULL,
    SchemaDiff            nvarchar(max)  NULL,
    Detail                nvarchar(max)  NULL,
    SampleOnlyInSsis      nvarchar(max)  NULL,       -- JSON, up to @SampleRows rows
    SampleOnlyInCandidate nvarchar(max)  NULL,
    ComparedAt            datetime2(3)   NOT NULL CONSTRAINT DF_parity_Result_At DEFAULT (SYSDATETIME()),
    DurationMs            int            NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_parity_Result_Case' AND object_id = OBJECT_ID(N'parity.Result'))
    CREATE INDEX IX_parity_Result_Case ON parity.Result (CaseId, RunId);
GO

IF OBJECT_ID(N'parity.FileManifest', N'U') IS NULL
CREATE TABLE parity.FileManifest
(
    RunId            int             NOT NULL,
    CaseId           varchar(20)     NOT NULL,
    Side             varchar(10)     NOT NULL CONSTRAINT CK_parity_FileManifest_Side CHECK (Side IN ('SSIS', 'Candidate')),
    RelativePath     nvarchar(400)   NOT NULL,       -- after the case's NameMask is applied
    OriginalName     nvarchar(400)   NOT NULL,
    Bytes            bigint          NOT NULL,
    Sha256           char(64)        NOT NULL,
    LineCount        bigint          NULL,
    HeaderLine       nvarchar(4000)  NULL,
    EndsWithNewline  bit             NULL,
    Encoding         varchar(20)     NULL,           -- UTF8-BOM | UTF16LE-BOM | UTF16BE-BOM | NoBOM
    CONSTRAINT PK_parity_FileManifest PRIMARY KEY (RunId, CaseId, Side, RelativePath)
);
GO

IF OBJECT_ID(N'parity.ExecutionOutcome', N'U') IS NULL
CREATE TABLE parity.ExecutionOutcome
(
    RunId        int             NOT NULL,
    CaseId       varchar(20)     NOT NULL,
    Side         varchar(10)     NOT NULL CONSTRAINT CK_parity_ExecutionOutcome_Side CHECK (Side IN ('SSIS', 'Candidate')),
    Outcome      varchar(20)     NOT NULL,           -- Succeeded | Failed | Canceled | ...
    ExecutionRef nvarchar(200)   NULL,               -- SSISDB execution_id or ADF runId
    Message      nvarchar(4000)  NULL,
    CONSTRAINT PK_parity_ExecutionOutcome PRIMARY KEY (RunId, CaseId, Side)
);
GO

-------------------------------------------------------------------------------
-- Runs
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE parity.usp_StartRun
    @Label     nvarchar(200) = NULL,
    @GitCommit varchar(40)   = NULL,
    @RunId     int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT parity.Run (Label, GitCommit) VALUES (@Label, @GitCommit);
    SET @RunId = CONVERT(int, SCOPE_IDENTITY());
END;
GO

CREATE OR ALTER PROCEDURE parity.usp_EndRun
    @RunId int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE r
       SET EndedAt   = SYSDATETIME(),
           Passed    = s.Passed,
           Failed    = s.Failed,
           KnownDiff = s.KnownDiff,
           Errors    = s.Errors
      FROM parity.Run AS r
     CROSS APPLY (SELECT SUM(CASE WHEN x.Status = 'PASS'       THEN 1 ELSE 0 END) AS Passed,
                         SUM(CASE WHEN x.Status = 'FAIL'       THEN 1 ELSE 0 END) AS Failed,
                         SUM(CASE WHEN x.Status = 'KNOWN_DIFF' THEN 1 ELSE 0 END) AS KnownDiff,
                         SUM(CASE WHEN x.Status = 'ERROR'      THEN 1 ELSE 0 END) AS Errors
                    FROM parity.Result AS x WHERE x.RunId = r.RunId) AS s
     WHERE r.RunId = @RunId;
    SELECT RunId, Label, StartedAt, EndedAt, Passed, Failed, KnownDiff, Errors FROM parity.Run WHERE RunId = @RunId;
END;
GO

-------------------------------------------------------------------------------
-- Table comparison
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE parity.usp_CompareTables
    @RunId      int,
    @CaseId     varchar(20),
    @SampleRows int = 10
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;    -- errors are caught and logged as ERROR, never thrown to the caller

    DECLARE @t0 datetime2(3) = SYSDATETIME();
    DECLARE @ssis nvarchar(256), @cand nvarchar(256), @keys nvarchar(1000), @cols nvarchar(max),
            @ignore nvarchar(1000), @expected varchar(10), @allowEmpty bit;
    DECLARE @status varchar(12), @detail nvarchar(max) = N'', @schemaDiff nvarchar(max) = NULL;
    DECLARE @ssisRows bigint, @candRows bigint, @onlyS bigint, @onlyC bigint, @exS bigint, @exC bigint;
    DECLARE @sumS varchar(64), @sumC varchar(64), @sampleS nvarchar(max), @sampleC nvarchar(max);
    DECLARE @colList nvarchar(max), @hashS nvarchar(max), @hashC nvarchar(max), @exceptS nvarchar(max), @exceptC nvarchar(max);
    DECLARE @sql nvarchar(max), @ssisId int, @candId int;

    SELECT @ssis = SsisObject, @cand = CandidateObject, @keys = KeyColumns, @cols = CompareColumns,
           @ignore = IgnoreColumns, @expected = ExpectedOutcome, @allowEmpty = AllowEmpty
      FROM parity.TestCase WHERE CaseId = @CaseId AND CompareType = 'Table';

    CREATE TABLE #c (ColumnName sysname NOT NULL, ColumnOrder int NOT NULL, SsisType nvarchar(200) NOT NULL,
                     CandType nvarchar(200) NULL, TypeName sysname NOT NULL, CandTypeName sysname NULL, SsisCollation sysname NULL);

    BEGIN TRY
        IF @ssis IS NULL THROW 50001, N'Case not found, or it is not a Table case.', 1;
        SET @ssisId = OBJECT_ID(@ssis);
        SET @candId = OBJECT_ID(@cand);
        IF @ssisId IS NULL THROW 50002, N'SSIS output object not found.', 1;
        IF @candId IS NULL THROW 50003, N'Candidate output object not found.', 1;

        -- Columns to compare: CompareColumns (or every SSIS column) minus IgnoreColumns.
        INSERT #c (ColumnName, ColumnOrder, SsisType, CandType, TypeName, CandTypeName, SsisCollation)
        SELECT s.name, s.column_id,
               CONCAT(ts.name, CASE WHEN ts.name IN (N'varchar', N'char', N'varbinary', N'binary') THEN CONCAT(N'(', CASE WHEN s.max_length = -1 THEN N'max' ELSE CONVERT(nvarchar(10), s.max_length) END, N')')
                                    WHEN ts.name IN (N'nvarchar', N'nchar') THEN CONCAT(N'(', CASE WHEN s.max_length = -1 THEN N'max' ELSE CONVERT(nvarchar(10), s.max_length / 2) END, N')')
                                    WHEN ts.name IN (N'decimal', N'numeric') THEN CONCAT(N'(', s.precision, N',', s.scale, N')')
                                    WHEN ts.name IN (N'datetime2', N'time', N'datetimeoffset') THEN CONCAT(N'(', s.scale, N')') ELSE N'' END,
                      CASE WHEN s.collation_name IS NOT NULL THEN N' ' + s.collation_name ELSE N'' END),
               CASE WHEN c.name IS NULL THEN NULL ELSE
               CONCAT(tc.name, CASE WHEN tc.name IN (N'varchar', N'char', N'varbinary', N'binary') THEN CONCAT(N'(', CASE WHEN c.max_length = -1 THEN N'max' ELSE CONVERT(nvarchar(10), c.max_length) END, N')')
                                    WHEN tc.name IN (N'nvarchar', N'nchar') THEN CONCAT(N'(', CASE WHEN c.max_length = -1 THEN N'max' ELSE CONVERT(nvarchar(10), c.max_length / 2) END, N')')
                                    WHEN tc.name IN (N'decimal', N'numeric') THEN CONCAT(N'(', c.precision, N',', c.scale, N')')
                                    WHEN tc.name IN (N'datetime2', N'time', N'datetimeoffset') THEN CONCAT(N'(', c.scale, N')') ELSE N'' END,
                      CASE WHEN c.collation_name IS NOT NULL THEN N' ' + c.collation_name ELSE N'' END) END,
               ts.name, tc.name, s.collation_name
          FROM sys.columns AS s
          JOIN sys.types   AS ts ON ts.user_type_id = s.user_type_id
          LEFT JOIN sys.columns AS c  ON c.object_id = @candId AND c.name = s.name
          LEFT JOIN sys.types   AS tc ON tc.user_type_id = c.user_type_id
         WHERE s.object_id = @ssisId
           AND (@cols IS NULL OR s.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@cols, ',')))
           AND (@ignore IS NULL OR s.name NOT IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ignore, ',')));

        IF NOT EXISTS (SELECT 1 FROM #c) THROW 50004, N'No columns to compare (check CompareColumns / IgnoreColumns).', 1;
        IF @cols IS NOT NULL AND EXISTS (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@cols, ',') EXCEPT SELECT ColumnName FROM #c)
            SET @detail += N'Some CompareColumns are not in the SSIS output and were skipped. ';
        IF EXISTS (SELECT 1 FROM #c WHERE CandType IS NULL)
        BEGIN
            SELECT @detail = @detail + N'Missing in candidate: ' + STUFF((SELECT N', ' + ColumnName FROM #c WHERE CandType IS NULL ORDER BY ColumnOrder FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N'. ';
            THROW 50005, N'Compared columns are missing from the candidate output.', 1;
        END;
        SELECT @schemaDiff = STUFF((SELECT N'; ' + ColumnName + N': ' + SsisType + N' vs ' + CandType
                                      FROM #c WHERE SsisType <> CandType ORDER BY ColumnOrder FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

        -- Canonical value per column; each value is length-prefixed so no delimiter can collide.
        DECLARE @canonS nvarchar(max), @canonC nvarchar(max);
        WITH e AS
        (
            SELECT ColumnOrder, ColumnName,
                   CASE
                       WHEN TypeName IN (N'float', N'real') THEN N'CONVERT(nvarchar(64), CONVERT(float, {c}), 3)'
                       WHEN TypeName IN (N'datetime', N'datetime2', N'smalldatetime', N'date') THEN N'CONVERT(nvarchar(64), CONVERT(datetime2(7), {c}), 126)'
                       WHEN TypeName = N'time' THEN N'CONVERT(nvarchar(64), CONVERT(time(7), {c}), 114)'
                       WHEN TypeName = N'datetimeoffset' THEN N'CONVERT(nvarchar(64), CONVERT(datetimeoffset(7), {c}), 127)'
                       WHEN TypeName IN (N'decimal', N'numeric', N'money', N'smallmoney') THEN N'CONVERT(nvarchar(64), CONVERT(decimal(38, 10), {c}))'
                       WHEN TypeName IN (N'binary', N'varbinary', N'image', N'timestamp', N'rowversion') THEN N'CONVERT(nvarchar(max), CONVERT(varbinary(max), {c}), 1)'
                       WHEN TypeName IN (N'geography', N'geometry', N'hierarchyid') THEN N'{c}.ToString()'
                       ELSE N'CONVERT(nvarchar(max), {c})'
                   END AS Template,
                   -- EXCEPT uses the SSIS column's collation on both sides, so a collation change alone
                   -- is reported in SchemaDiff instead of failing the statement.
                   CASE
                       WHEN TypeName IN (N'text', N'ntext') THEN N'CONVERT(nvarchar(max), {c}) COLLATE ' + SsisCollation
                       WHEN TypeName = N'xml' THEN N'CONVERT(nvarchar(max), {c}) COLLATE DATABASE_DEFAULT'
                       WHEN TypeName = N'sql_variant' THEN N'CONVERT(nvarchar(max), {c}) COLLATE DATABASE_DEFAULT'
                       WHEN TypeName = N'image' THEN N'CONVERT(varbinary(max), {c})'
                       WHEN TypeName IN (N'geography', N'geometry', N'hierarchyid') THEN N'{c}.ToString()'
                       WHEN SsisCollation IS NOT NULL THEN N'{c} COLLATE ' + SsisCollation
                       ELSE N'{c}'
                   END AS ExceptTemplate
              FROM #c
        )
        SELECT @canonS = STUFF((SELECT N' + ' + N'CASE WHEN ' + QUOTENAME(ColumnName) + N' IS NULL THEN N''n;'' ELSE N''v'' + CONVERT(nvarchar(20), LEN(' + REPLACE(Template, N'{c}', QUOTENAME(ColumnName)) + N' + N''x'') - 1) + N'':'' + ' + REPLACE(Template, N'{c}', QUOTENAME(ColumnName)) + N' END'
                                  FROM e ORDER BY ColumnOrder FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N''),
               @colList = STUFF((SELECT N', ' + REPLACE(ExceptTemplate, N'{c}', QUOTENAME(ColumnName)) + N' AS ' + QUOTENAME(ColumnName)
                                  FROM e ORDER BY ColumnOrder FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

        -- Row hashes as multisets (hash, count) for each side.
        CREATE TABLE #s (h varbinary(32) NOT NULL PRIMARY KEY, n bigint NOT NULL);
        CREATE TABLE #t (h varbinary(32) NOT NULL PRIMARY KEY, n bigint NOT NULL);
        SET @sql = N'INSERT #s (h, n) SELECT h, COUNT_BIG(*) FROM (SELECT HASHBYTES(''SHA2_256'', CONVERT(nvarchar(max), N'''') + ' + @canonS + N') AS h FROM ' + @ssis + N') AS x GROUP BY h;
                     INSERT #t (h, n) SELECT h, COUNT_BIG(*) FROM (SELECT HASHBYTES(''SHA2_256'', CONVERT(nvarchar(max), N'''') + ' + @canonS + N') AS h FROM ' + @cand + N') AS x GROUP BY h;';
        EXEC sys.sp_executesql @sql;

        SELECT @ssisRows = ISNULL(SUM(n), 0) FROM #s;
        SELECT @candRows = ISNULL(SUM(n), 0) FROM #t;
        SELECT @onlyS = ISNULL(SUM(s.n - ISNULL(t.n, 0)), 0) FROM #s AS s LEFT JOIN #t AS t ON t.h = s.h WHERE s.n > ISNULL(t.n, 0);
        SELECT @onlyC = ISNULL(SUM(t.n - ISNULL(s.n, 0)), 0) FROM #t AS t LEFT JOIN #s AS s ON s.h = t.h WHERE t.n > ISNULL(s.n, 0);
        SELECT @sumS = CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(nvarchar(max), N'') + ISNULL((SELECT CONVERT(varchar(64), h, 2) + ':' + CONVERT(varchar(20), n) + ';' FROM #s ORDER BY h FOR XML PATH('')), '')), 2);
        SELECT @sumC = CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(nvarchar(max), N'') + ISNULL((SELECT CONVERT(varchar(64), h, 2) + ':' + CONVERT(varchar(20), n) + ';' FROM #t ORDER BY h FOR XML PATH('')), '')), 2);

        -- Collation-aware EXCEPT, both ways. Can fail on incompatible types: logged, not fatal.
        BEGIN TRY
            SET @sql = N'SELECT @a = COUNT_BIG(*) FROM (SELECT ' + @colList + N' FROM ' + @ssis + N' EXCEPT SELECT ' + @colList + N' FROM ' + @cand + N') AS x;
                         SELECT @b = COUNT_BIG(*) FROM (SELECT ' + @colList + N' FROM ' + @cand + N' EXCEPT SELECT ' + @colList + N' FROM ' + @ssis + N') AS x;';
            EXEC sys.sp_executesql @sql, N'@a bigint OUTPUT, @b bigint OUTPUT', @a = @exS OUTPUT, @b = @exC OUTPUT;
        END TRY
        BEGIN CATCH
            SET @detail += N'EXCEPT not evaluated: ' + ERROR_MESSAGE() + N' ';
        END CATCH;

        -- Sample differing rows (JSON), ordered by KeyColumns when given.
        IF @onlyS > 0 OR @onlyC > 0
        BEGIN
            DECLARE @orderBy nvarchar(max) = N'';
            IF @keys IS NOT NULL
                SELECT @orderBy = N' ORDER BY ' + STUFF((SELECT N', ' + QUOTENAME(LTRIM(RTRIM(value))) FROM STRING_SPLIT(@keys, ',') FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
            BEGIN TRY
                SET @sql = N'SELECT @j = (SELECT TOP (@n) ' + @colList + N' FROM ' + @ssis + N' WHERE HASHBYTES(''SHA2_256'', CONVERT(nvarchar(max), N'''') + ' + @canonS + N') IN
                                 (SELECT s.h FROM #s AS s LEFT JOIN #t AS t ON t.h = s.h WHERE s.n > ISNULL(t.n, 0))' + @orderBy + N' FOR JSON PATH, INCLUDE_NULL_VALUES);
                             SELECT @k = (SELECT TOP (@n) ' + @colList + N' FROM ' + @cand + N' WHERE HASHBYTES(''SHA2_256'', CONVERT(nvarchar(max), N'''') + ' + @canonS + N') IN
                                 (SELECT t.h FROM #t AS t LEFT JOIN #s AS s ON s.h = t.h WHERE t.n > ISNULL(s.n, 0))' + @orderBy + N' FOR JSON PATH, INCLUDE_NULL_VALUES);';
                EXEC sys.sp_executesql @sql, N'@n int, @j nvarchar(max) OUTPUT, @k nvarchar(max) OUTPUT', @n = @SampleRows, @j = @sampleS OUTPUT, @k = @sampleC OUTPUT;
            END TRY
            BEGIN CATCH
                SET @detail += N'Samples not captured: ' + ERROR_MESSAGE() + N' ';
            END CATCH;
        END;

        IF @ssisRows = 0 AND @candRows = 0 AND @allowEmpty = 0
        BEGIN
            SET @status = 'ERROR';
            SET @detail += N'Both sides are empty: check that both runs wrote output (set AllowEmpty for cases where empty is the right answer). ';
        END
        ELSE IF @onlyS = 0 AND @onlyC = 0
            SET @status = 'PASS';
        ELSE
        BEGIN
            SET @status = CASE WHEN @expected = 'Differ' THEN 'KNOWN_DIFF' ELSE 'FAIL' END;
            IF @exS = 0 AND @exC = 0
                SET @detail += N'Rows differ only in case, trailing spaces or duplicate counts (collation-aware EXCEPT is clean). ';
        END;
        IF @schemaDiff IS NOT NULL SET @detail += N'Column types differ (see SchemaDiff). ';
    END TRY
    BEGIN CATCH
        SET @status = 'ERROR';
        SET @detail += ERROR_MESSAGE();
    END CATCH;

    INSERT parity.Result (RunId, CaseId, CompareType, Status, SsisRows, CandidateRows, OnlyInSsis, OnlyInCandidate,
                          ExceptOnlyInSsis, ExceptOnlyInCandidate, SsisChecksum, CandidateChecksum, ComparedColumns,
                          SchemaDiff, Detail, SampleOnlyInSsis, SampleOnlyInCandidate, DurationMs)
    SELECT @RunId, @CaseId, 'Table', @status, @ssisRows, @candRows, @onlyS, @onlyC, @exS, @exC, @sumS, @sumC,
           STUFF((SELECT N', ' + ColumnName FROM #c ORDER BY ColumnOrder FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
           @schemaDiff, NULLIF(LTRIM(RTRIM(@detail)), N''), @sampleS, @sampleC, DATEDIFF(millisecond, @t0, SYSDATETIME());

    SELECT * FROM parity.Result WHERE ResultId = SCOPE_IDENTITY();
END;
GO

-------------------------------------------------------------------------------
-- File-set comparison (manifests loaded by 01_Invoke-ParityTest.ps1)
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE parity.usp_CompareFileManifests
    @RunId  int,
    @CaseId varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2(3) = SYSDATETIME(), @expected varchar(10), @status varchar(12), @detail nvarchar(max);
    DECLARE @nS bigint, @nC bigint, @onlyS bigint, @onlyC bigint, @changed bigint, @sumS varchar(64), @sumC varchar(64);

    SELECT @expected = ExpectedOutcome FROM parity.TestCase WHERE CaseId = @CaseId AND CompareType = 'Files';

    SELECT @nS = COUNT_BIG(*) FROM parity.FileManifest WHERE RunId = @RunId AND CaseId = @CaseId AND Side = 'SSIS';
    SELECT @nC = COUNT_BIG(*) FROM parity.FileManifest WHERE RunId = @RunId AND CaseId = @CaseId AND Side = 'Candidate';
    SELECT @onlyS = COUNT_BIG(*) FROM parity.FileManifest AS s
     WHERE s.RunId = @RunId AND s.CaseId = @CaseId AND s.Side = 'SSIS'
       AND NOT EXISTS (SELECT 1 FROM parity.FileManifest AS c WHERE c.RunId = s.RunId AND c.CaseId = s.CaseId AND c.Side = 'Candidate' AND c.RelativePath = s.RelativePath);
    SELECT @onlyC = COUNT_BIG(*) FROM parity.FileManifest AS c
     WHERE c.RunId = @RunId AND c.CaseId = @CaseId AND c.Side = 'Candidate'
       AND NOT EXISTS (SELECT 1 FROM parity.FileManifest AS s WHERE s.RunId = c.RunId AND s.CaseId = c.CaseId AND s.Side = 'SSIS' AND s.RelativePath = c.RelativePath);

    -- Per-file differences, described by what changed (content, lines, header, final newline, encoding).
    SELECT @changed = COUNT_BIG(*),
           @detail = STUFF((SELECT N'; ' + s.RelativePath + N': '
                                  + N'content'
                                  + CASE WHEN ISNULL(s.LineCount, -1) <> ISNULL(c.LineCount, -1) THEN CONCAT(N', lines ', s.LineCount, N' vs ', c.LineCount) ELSE N'' END
                                  + CASE WHEN ISNULL(s.HeaderLine, N'') COLLATE Latin1_General_100_BIN2 <> ISNULL(c.HeaderLine, N'') COLLATE Latin1_General_100_BIN2 THEN N', header' ELSE N'' END
                                  + CASE WHEN ISNULL(s.EndsWithNewline, 0) <> ISNULL(c.EndsWithNewline, 0) THEN N', final newline' ELSE N'' END
                                  + CASE WHEN ISNULL(s.Encoding, '') <> ISNULL(c.Encoding, '') THEN CONCAT(N', encoding ', s.Encoding, N' vs ', c.Encoding) ELSE N'' END
                              FROM parity.FileManifest AS s
                              JOIN parity.FileManifest AS c ON c.RunId = s.RunId AND c.CaseId = s.CaseId AND c.Side = 'Candidate' AND c.RelativePath = s.RelativePath
                             WHERE s.RunId = @RunId AND s.CaseId = @CaseId AND s.Side = 'SSIS' AND s.Sha256 <> c.Sha256
                             ORDER BY s.RelativePath FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
      FROM parity.FileManifest AS s
      JOIN parity.FileManifest AS c ON c.RunId = s.RunId AND c.CaseId = s.CaseId AND c.Side = 'Candidate' AND c.RelativePath = s.RelativePath
     WHERE s.RunId = @RunId AND s.CaseId = @CaseId AND s.Side = 'SSIS' AND s.Sha256 <> c.Sha256;

    SELECT @sumS = CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(nvarchar(max), N'') + ISNULL((SELECT RelativePath + N'=' + Sha256 + N';' FROM parity.FileManifest WHERE RunId = @RunId AND CaseId = @CaseId AND Side = 'SSIS' ORDER BY RelativePath FOR XML PATH('')), N'')), 2);
    SELECT @sumC = CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(nvarchar(max), N'') + ISNULL((SELECT RelativePath + N'=' + Sha256 + N';' FROM parity.FileManifest WHERE RunId = @RunId AND CaseId = @CaseId AND Side = 'Candidate' ORDER BY RelativePath FOR XML PATH('')), N'')), 2);

    SET @status = CASE WHEN @expected IS NULL THEN 'ERROR'
                       WHEN @nS = 0 AND @nC = 0 THEN 'ERROR'
                       WHEN @onlyS = 0 AND @onlyC = 0 AND @changed = 0 THEN 'PASS'
                       WHEN @expected = 'Differ' THEN 'KNOWN_DIFF' ELSE 'FAIL' END;
    IF @expected IS NULL SET @detail = N'Case not found, or it is not a Files case.';
    ELSE IF @nS = 0 AND @nC = 0 SET @detail = N'No files recorded for either side.';
    ELSE IF @onlyS > 0 OR @onlyC > 0
        SET @detail = CONCAT(@detail + N' ', N'Missing files: ',
                      STUFF((SELECT N', ' + Side + N' only: ' + RelativePath FROM parity.FileManifest AS m
                              WHERE m.RunId = @RunId AND m.CaseId = @CaseId
                                AND NOT EXISTS (SELECT 1 FROM parity.FileManifest AS o WHERE o.RunId = m.RunId AND o.CaseId = m.CaseId AND o.Side <> m.Side AND o.RelativePath = m.RelativePath)
                              ORDER BY Side, RelativePath FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''));

    INSERT parity.Result (RunId, CaseId, CompareType, Status, SsisRows, CandidateRows, OnlyInSsis, OnlyInCandidate,
                          SsisChecksum, CandidateChecksum, Detail, DurationMs)
    VALUES (@RunId, @CaseId, 'Files', @status, @nS, @nC, @onlyS + ISNULL(@changed, 0), @onlyC + ISNULL(@changed, 0),
            @sumS, @sumC, @detail, DATEDIFF(millisecond, @t0, SYSDATETIME()));

    SELECT * FROM parity.Result WHERE ResultId = SCOPE_IDENTITY();
END;
GO

-------------------------------------------------------------------------------
-- Outcome comparison: both sides must end the same way (e.g. both fail on an
-- empty single-row result set).
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE parity.usp_CompareOutcome
    @RunId  int,
    @CaseId varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @expected varchar(10), @s varchar(20), @c varchar(20), @sm nvarchar(4000), @cm nvarchar(4000), @status varchar(12), @detail nvarchar(max);
    SELECT @expected = ExpectedOutcome FROM parity.TestCase WHERE CaseId = @CaseId AND CompareType = 'Outcome';
    SELECT @s = Outcome, @sm = Message FROM parity.ExecutionOutcome WHERE RunId = @RunId AND CaseId = @CaseId AND Side = 'SSIS';
    SELECT @c = Outcome, @cm = Message FROM parity.ExecutionOutcome WHERE RunId = @RunId AND CaseId = @CaseId AND Side = 'Candidate';

    SET @status = CASE WHEN @expected IS NULL OR @s IS NULL OR @c IS NULL THEN 'ERROR'
                       WHEN @s = @c THEN 'PASS'
                       WHEN @expected = 'Differ' THEN 'KNOWN_DIFF' ELSE 'FAIL' END;
    SET @detail = CASE WHEN @expected IS NULL THEN N'Case not found, or it is not an Outcome case.'
                       WHEN @s IS NULL OR @c IS NULL THEN N'Outcome not recorded for both sides.'
                       ELSE CONCAT(N'SSIS ', @s, N' / candidate ', @c, CASE WHEN @s <> @c THEN CONCAT(N'. SSIS: ', LEFT(@sm, 1000), N' | Candidate: ', LEFT(@cm, 1000)) END) END;

    INSERT parity.Result (RunId, CaseId, CompareType, Status, Detail) VALUES (@RunId, @CaseId, 'Outcome', @status, @detail);
    SELECT * FROM parity.Result WHERE ResultId = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER VIEW parity.vw_LatestResult
AS
SELECT r.CaseId, tc.GapId, tc.Title, r.CompareType, r.Status, r.RunId, r.ComparedAt, r.SsisRows, r.CandidateRows,
       r.OnlyInSsis, r.OnlyInCandidate, r.ExceptOnlyInSsis, r.ExceptOnlyInCandidate, r.SchemaDiff, r.Detail
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY CaseId ORDER BY ResultId DESC) AS rn FROM parity.Result) AS r
  LEFT JOIN parity.TestCase AS tc ON tc.CaseId = r.CaseId
 WHERE r.rn = 1;
GO

PRINT 'Parity harness ready (schema parity).';
GO
