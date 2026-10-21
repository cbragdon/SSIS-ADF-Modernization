/*
================================================================================
 01_SelfTest-Setup.sql
--------------------------------------------------------------------------------
 Purpose : Known-answer table pairs for the parity harness self-test
           (scripts/parity/02_Test-ParityHarness.ps1). Each pair differs in
           exactly one way, so the expected status of every comparison is known.
 Scope   : Any disposable SQL Server 2016 SP1+ instance. Synthetic data only.
 Behaviour: Idempotent; drops and recreates the ptest schema tables each run.
================================================================================
*/
SET NOCOUNT ON;
GO
USE SsisAssessmentTest;
GO
IF SCHEMA_ID(N'ptest') IS NULL EXEC (N'CREATE SCHEMA ptest AUTHORIZATION dbo;');
GO
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'DROP TABLE ptest.' + QUOTENAME(name) + N';' FROM sys.tables WHERE schema_id = SCHEMA_ID(N'ptest');
EXEC sys.sp_executesql @sql;
GO

-- Base shape used by most pairs. Case-insensitive collation on purpose: EXCEPT and = ignore case here.
CREATE TABLE ptest.Base (Id int NOT NULL, Code varchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, Amount decimal(9, 2) NULL, Ratio float NULL, LoadedAt datetime2(3) NULL);
INSERT ptest.Base VALUES (1, 'A1', 10.00, 0.1, '2026-01-01T00:00:00'), (2, 'b2', 20.50, CAST(1 AS float) / 3, '2026-01-01T00:00:00'), (3, NULL, NULL, NULL, NULL), (4, '', 0, 0, '2026-01-01T00:00:00');
GO
-- ST01 identical, different physical order
SELECT * INTO ptest.ST01_S FROM ptest.Base;
SELECT * INTO ptest.ST01_C FROM ptest.Base;
DELETE ptest.ST01_C; INSERT ptest.ST01_C SELECT * FROM ptest.Base ORDER BY Id DESC;
-- ST02 case only
SELECT * INTO ptest.ST02_S FROM ptest.Base;
SELECT * INTO ptest.ST02_C FROM ptest.Base; UPDATE ptest.ST02_C SET Code = 'B2' WHERE Id = 2;
-- ST03 trailing space only
SELECT * INTO ptest.ST03_S FROM ptest.Base;
SELECT * INTO ptest.ST03_C FROM ptest.Base; UPDATE ptest.ST03_C SET Code = 'A1 ' WHERE Id = 1;
-- ST04 duplicate count (row 1 twice in candidate)
SELECT * INTO ptest.ST04_S FROM ptest.Base;
SELECT * INTO ptest.ST04_C FROM ptest.Base; INSERT ptest.ST04_C SELECT * FROM ptest.Base WHERE Id = 1;
-- ST05 NULL vs blank
SELECT * INTO ptest.ST05_S FROM ptest.Base;
SELECT * INTO ptest.ST05_C FROM ptest.Base; UPDATE ptest.ST05_C SET Code = '' WHERE Id = 3;
-- ST06 float last digit
SELECT * INTO ptest.ST06_S FROM ptest.Base;
SELECT * INTO ptest.ST06_C FROM ptest.Base; UPDATE ptest.ST06_C SET Ratio = Ratio + 1E-15 WHERE Id = 2;
-- ST07 same values, different types (varchar(20) CI vs nvarchar(40) BIN2, decimal(9,2) vs decimal(12,4), float vs real-safe value)
SELECT * INTO ptest.ST07_S FROM ptest.Base;
CREATE TABLE ptest.ST07_C (Id bigint NOT NULL, Code nvarchar(40) COLLATE Latin1_General_100_BIN2 NULL, Amount decimal(12, 4) NULL, Ratio float NULL, LoadedAt datetime NULL);
INSERT ptest.ST07_C SELECT Id, Code, Amount, Ratio, LoadedAt FROM ptest.Base;
-- ST08 volatile column differs but is ignored
SELECT * INTO ptest.ST08_S FROM ptest.Base;
SELECT * INTO ptest.ST08_C FROM ptest.Base; UPDATE ptest.ST08_C SET LoadedAt = SYSDATETIME();
-- ST09 documented divergence (ExpectedOutcome = Differ)
SELECT * INTO ptest.ST09_S FROM ptest.Base;
SELECT * INTO ptest.ST09_C FROM ptest.Base WHERE Id <> 4;
-- ST10 compared column missing from candidate
SELECT * INTO ptest.ST10_S FROM ptest.Base;
SELECT Id, Code, Amount, LoadedAt INTO ptest.ST10_C FROM ptest.Base;
-- ST11 empty vs empty
SELECT * INTO ptest.ST11_S FROM ptest.Base WHERE 1 = 0;
SELECT * INTO ptest.ST11_C FROM ptest.Base WHERE 1 = 0;
-- ST12 value change the collation also sees (EXCEPT not clean)
SELECT * INTO ptest.ST12_S FROM ptest.Base;
SELECT * INTO ptest.ST12_C FROM ptest.Base; UPDATE ptest.ST12_C SET Amount = 20.49 WHERE Id = 2;
-- ST13 Unicode outside code page 1252: varchar loses it, nvarchar keeps it
CREATE TABLE ptest.ST13_S (Id int NOT NULL, Name nvarchar(20) NULL);
CREATE TABLE ptest.ST13_C (Id int NOT NULL, Name varchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL);
INSERT ptest.ST13_S VALUES (1, N'Łódź'), (2, N'Cafe');
INSERT ptest.ST13_C VALUES (1, N'Łódź'), (2, N'Cafe');
GO
SELECT COUNT(*) AS SelfTestTables FROM sys.tables WHERE schema_id = SCHEMA_ID(N'ptest');
GO
