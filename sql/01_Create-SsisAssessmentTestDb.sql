/*
================================================================================
 01_Create-SsisAssessmentTestDb.sql
--------------------------------------------------------------------------------
 Purpose : Creates the small, disposable database that the AssessmentTests SSIS
           project reads from and writes to, so the "runnable" test packages can
           execute and later be compared side by side with their ADF rewrites.

 Scope   : DEVELOPMENT SERVERS ONLY. Contains synthetic data only - no real data.

 Behaviour
   * Idempotent: safe to run repeatedly. Creates objects only when missing and
     re-seeds source data to a known, deterministic state on every run, so
     row-count and checksum comparisons are reproducible.
   * Run by 02_Deploy-SsisTestProject.ps1 when -IncludeSeedData is supplied,
     or manually in SSMS (the batches are separated by GO).

 Objects
   SsisAssessmentTest           database (SIMPLE recovery; disposable)
     src.Customer               1,000 deterministic source rows
     src.Product                50 rows used by the Lookup in T03
     dst.Customer               target for T01/T02 copy packages
     dst.CustomerSummary        target for T03 aggregate output
     etl.RunLog                 rows written by Execute SQL tasks and handlers

 Removal : 02_Deploy-SsisTestProject.ps1 -Remove -RemoveTestDatabase
           (or DROP DATABASE SsisAssessmentTest manually)
================================================================================
*/
SET NOCOUNT ON;
GO

IF DB_ID(N'SsisAssessmentTest') IS NULL
BEGIN
    PRINT 'Creating database SsisAssessmentTest';
    CREATE DATABASE SsisAssessmentTest;
END
ELSE
    PRINT 'Database SsisAssessmentTest already exists';
GO

-- Disposable test database: no point-in-time recovery needed.
ALTER DATABASE SsisAssessmentTest SET RECOVERY SIMPLE;
GO

USE SsisAssessmentTest;
GO

IF SCHEMA_ID(N'src') IS NULL EXEC (N'CREATE SCHEMA src AUTHORIZATION dbo;');
IF SCHEMA_ID(N'dst') IS NULL EXEC (N'CREATE SCHEMA dst AUTHORIZATION dbo;');
IF SCHEMA_ID(N'etl') IS NULL EXEC (N'CREATE SCHEMA etl AUTHORIZATION dbo;');
GO

-------------------------------------------------------------------------------
-- Tables (created only when missing)
-------------------------------------------------------------------------------
IF OBJECT_ID(N'src.Customer', N'U') IS NULL
CREATE TABLE src.Customer
(
    CustomerId    int            NOT NULL CONSTRAINT PK_src_Customer PRIMARY KEY,
    CustomerName  nvarchar(100)  NOT NULL,
    Email         nvarchar(200)  NULL,
    Region        nvarchar(20)   NOT NULL,
    ProductId     int            NOT NULL,
    Amount        decimal(18,2)  NOT NULL,
    CreatedDate   datetime2(0)   NOT NULL
);

IF OBJECT_ID(N'src.Product', N'U') IS NULL
CREATE TABLE src.Product
(
    ProductId     int            NOT NULL CONSTRAINT PK_src_Product PRIMARY KEY,
    ProductName   nvarchar(100)  NOT NULL,
    Category      nvarchar(50)   NOT NULL
);

IF OBJECT_ID(N'dst.Customer', N'U') IS NULL
CREATE TABLE dst.Customer
(
    CustomerId    int            NOT NULL CONSTRAINT PK_dst_Customer PRIMARY KEY,
    CustomerName  nvarchar(100)  NOT NULL,
    Email         nvarchar(200)  NULL,
    Region        nvarchar(20)   NOT NULL,
    ProductId     int            NOT NULL,
    Amount        decimal(18,2)  NOT NULL,
    CreatedDate   datetime2(0)   NOT NULL,
    LoadedAtUtc   datetime2(0)   NOT NULL CONSTRAINT DF_dst_Customer_Loaded DEFAULT (SYSUTCDATETIME())
);

IF OBJECT_ID(N'dst.CustomerSummary', N'U') IS NULL
CREATE TABLE dst.CustomerSummary
(
    Region        nvarchar(20)   NOT NULL,
    Category      nvarchar(50)   NOT NULL,
    CustomerCount int            NOT NULL,
    TotalAmount   decimal(18,2)  NOT NULL,
    CONSTRAINT PK_dst_CustomerSummary PRIMARY KEY (Region, Category)
);

IF OBJECT_ID(N'etl.RunLog', N'U') IS NULL
CREATE TABLE etl.RunLog
(
    RunLogId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_RunLog PRIMARY KEY,
    PackageName   nvarchar(260)  NOT NULL,
    EventName     nvarchar(100)  NOT NULL,
    Detail        nvarchar(4000) NULL,
    LoggedAtUtc   datetime2(3)   NOT NULL CONSTRAINT DF_etl_RunLog_Logged DEFAULT (SYSUTCDATETIME())
);
GO

-------------------------------------------------------------------------------
-- Deterministic seed: same rows every run, so SSIS vs ADF outputs are comparable.
-------------------------------------------------------------------------------
BEGIN TRANSACTION;

TRUNCATE TABLE src.Product;
INSERT INTO src.Product (ProductId, ProductName, Category)
SELECT n,
       CONCAT(N'Product ', RIGHT(CONCAT(N'000', n), 3)),
       CHOOSE((n % 5) + 1, N'Hardware', N'Software', N'Services', N'Support', N'Training')
FROM  (SELECT TOP (50) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS t;

TRUNCATE TABLE src.Customer;
INSERT INTO src.Customer (CustomerId, CustomerName, Email, Region, ProductId, Amount, CreatedDate)
SELECT n,
       CONCAT(N'Customer ', RIGHT(CONCAT(N'0000', n), 4)),
       CASE WHEN n % 10 = 0 THEN NULL                       -- 10% NULL emails exercise NULL handling
            ELSE CONCAT(N'customer', n, N'@example.test') END,
       CHOOSE((n % 4) + 1, N'East', N'West', N'Central', N'South'),
       (n % 50) + 1,
       CAST((n % 997) * 1.37 AS decimal(18,2)),
       DATEADD(DAY, -(n % 365), CAST('2026-01-01' AS datetime2(0)))
FROM  (SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
       FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b) AS t;

COMMIT TRANSACTION;
GO

-------------------------------------------------------------------------------
-- Evidence: row counts and a checksum to record as the source baseline.
-------------------------------------------------------------------------------
SELECT N'src.Customer' AS TableName, COUNT(*) AS RowCnt, CHECKSUM_AGG(BINARY_CHECKSUM(*)) AS TableChecksum FROM src.Customer
UNION ALL
SELECT N'src.Product',  COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM src.Product;
GO
