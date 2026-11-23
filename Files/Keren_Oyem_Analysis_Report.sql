/* =====================================================================================================
   KEREN OYEM - ANALYSIS REPORT SQL
   File        : Keren_Oyem_Analysis_Report.sql
   Project     : Task 2 - Retail Sales and Staffing Efficiency Analysis (Mega Supermart, calendar year 2025)
   Author      : Keren Oyem
   Prepared    : 20 November 2026          Due: 23 November 2026
   Database    : Task2_DataWH  (Microsoft SQL Server 2022 / SQL Server Express, run in SSMS)
   -----------------------------------------------------------------------------------------------------
   PURPOSE
     One organised SQL script that builds the database, takes the seven imported CSV tables from raw data
     to dashboard-ready tables, and answers the six business questions with ONE query per question:
       Q1 Net sales and gross profit by store, category, month, weekday and hour
       Q2 Sales per worked labour hour; unusually high labour cost and overtime
       Q3 How well scheduled shifts match footfall at peak periods (hourly coverage, with sensitivity tests)
       Q4 Absence vs overtime, staff availability and sales (associations, not causes)
       Q5 High visitors but few purchases, compared against peers on the same month, weekday and hour
       Q6 Where leadership should investigate first, and what extra data would confirm the case
     It uses joins, aggregations, CTEs and window functions, and it proves that combining the fact
     tables does not double count.

   STARTING POINT
     The seven CSVs are imported into schema [raw] with the SSMS Import Flat File wizard:
     raw.Employees, raw.Products, raw.SalesLineItems, raw.SalesTransactions, raw.StaffShifts,
     raw.StoreFootfall, raw.Stores (about 3.7 million rows). Raw tables are NEVER modified by this file.
     NOTE: the wizard stores many decimal columns (prices, costs, hourly rates, hours) as FLOAT. Part 1 reads
     FLOAT straight into DECIMAL; an earlier version converted it through scientific-notation text, which
     SQL Server cannot read, so every price, rate and hour became NULL and core.products / core.shifts were empty.

   STRUCTURE AND LAYERS  (each part ends with result grids you can screenshot for the report)
     PART 0  Database build and settings               creates Task2_DataWH, the 7 schemas and dq.Assumptions
     PART 1  Data type validation and correction       raw   -> clean   typed copies, every bad value logged in dq
     PART 2  Business-rule data-quality profiling      clean -> dq      80+ checks: sizes, keys, missing values, duplicates,
                                                                      invalid dates, orphans, invalid numbers, return/shift rules
     PART 3  Cleaning decisions                        clean -> core    duplicates removed, invalid rows excluded,
                                                                      net sales / profit / labour measures recalculated; stops if a table is empty
     PART 4  Table relationships                       core             primary and foreign keys enforced; reconciliation to employee totals
     PART 5  Metric marts (no double counting)         core  -> mart    fixed-grain tables: store x date x hour, store x day, store x month ...
     PART 6  Analysis queries Q1 to Q6                 mart             ONE query per business question
     PART 7  Clean-up                                  dq               drops the row-lineage copies (dq.src_*) once exceptions are reviewed

   SCHEMAS
     raw (imported, untouched) | clean (typed) | dq (quality evidence + dq.Assumptions) | stg (read-only views)
     core (analysis-ready tables) | work (temporary, dropped when no longer needed) | mart (dashboard tables)

   KEY METHOD DECISIONS (explained again next to the code that uses them)
     * Raw data is preserved; every change is made in new tables and logged.
     * Exact duplicates (transactions, footfall rows) are reported in Part 1, then removed from core in Part 3.
     * Missing footfall stays NULL (never 0); conversion is measured only on hours with valid footfall.
     * Double counting is prevented by aggregating each fact table (sales lines, shifts, footfall) to its own
       store x date x hour grain BEFORE joining on a calendar spine (Part 5), then reconciling every mart
       total back to the core tables (Part 5, section 11).
     * Hourly staff coverage is an estimate because absence timing within a shift is unknown: regular worked
       time is spread across the scheduled interval, overtime is placed after the scheduled end
       (EndTime includes overtime), and two sensitivity scenarios (absence at the start / at the end of the
       shift) test whether conclusions depend on that assumption.
     * Absence findings are reported as associations only (store-month, within-store, same store and weekday,
       and employee level), never as causes. Staff availability = 1 - absence rate by construction, so it is
       not correlated separately (the correlation would be -1 by definition).
     * Conversion is compared with the other stores at the SAME month, weekday and hour, so a busy Saturday in
       December is never compared with a quiet Tuesday in February.
     * Every threshold (overtime rate 1.5x, peak percentile, z-score cut-off ...) lives in dq.Assumptions.

   METRIC DEFINITIONS (CAD, excluding tax)
     net sales            = SUM(Quantity x UnitPrice - Discount) over Sale and Return lines
     gross profit         = net sales - SUM(Quantity x UnitCostAtSale)       (not net business profit)
     worked hours         = scheduled - absent + overtime
     labour cost          = (scheduled - absent) x rate + overtime hours x 1.5 x rate (absence unpaid; excludes benefits)
     sales per worked hr  = net sales / worked hours          labour cost % = labour cost / net sales
     absence rate         = absent hours / scheduled hours    overtime share = overtime / worked hours
     conversion           = distinct Sale transactions / visitors (valid footfall hours only)
     Rates are always calculated from summed numerators and denominators, never as averages of rates.

   HOW TO RUN
     1. Part 0 first (creates the database and settings). Import the 7 CSVs into schema raw if not already done.
     2. Run ONE part at a time: highlight the part, press F5, read the result grids, then continue.
        Stop and investigate if a part shows a red error: Parts 1, 3 and 5 raise one on purpose when many values fail
        conversion, a core table is empty, a reconciliation fails or a total is zero, so a failure is loud, never silent.
     3. After Part 1 check that dq.ConversionExceptions has very few ERROR rows (SELECT COUNT(*) ... WHERE severity = 'ERROR').
     4. Once every part runs cleanly the whole file can be executed in one go. Re-running is safe.
     SQL Server Express limits a database to 10 GB; this project needs well under 2 GB. Part 8 drops the dq.src_* copies.

   LIMITATIONS TO STATE IN THE REPORT
     Hourly coverage is modelled; footfall has some missing hours; absence reasons and shift-level role
     data are not available; associations cannot prove causes.
   ===================================================================================================== */


/* #####################################################################################################
   PART 0 - DATABASE BUILD AND SETTINGS  (run this first; safe to re-run, never drops anything)
   Creates the database Task2_DataWH if it does not exist, the seven schemas, and the small table
   dq.Assumptions that holds every business assumption in ONE place (read by Parts 2, 3, 5 and 6).
   ##################################################################################################### */
USE master;
GO
IF DB_ID(N'Task2_DataWH') IS NULL
    CREATE DATABASE Task2_DataWH;      -- default data and log locations of your SQL Server instance
GO
/* GREATEST / LEAST (used in Part 5) need SQL Server 2022 and database compatibility level 160 */
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 16
   AND (SELECT compatibility_level FROM sys.databases WHERE name = N'Task2_DataWH') < 160
    ALTER DATABASE Task2_DataWH SET COMPATIBILITY_LEVEL = 160;
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 16
    PRINT N'WARNING: SQL Server 2022 (version 16) or later is needed for GREATEST/LEAST in Part 5.';
GO
USE Task2_DataWH;
GO
SET NOCOUNT ON;
GO

/* ---- Schemas. raw = the seven imported CSV tables (untouched). Everything else is built by this file. ---- */
IF SCHEMA_ID(N'raw')   IS NULL EXEC (N'CREATE SCHEMA raw');     -- imported CSVs (Import Flat File wizard, schema = raw)
IF SCHEMA_ID(N'clean') IS NULL EXEC (N'CREATE SCHEMA clean');   -- typed copies of raw (Part 1)
IF SCHEMA_ID(N'dq')    IS NULL EXEC (N'CREATE SCHEMA dq');      -- all data-quality evidence and settings
IF SCHEMA_ID(N'stg')   IS NULL EXEC (N'CREATE SCHEMA stg');     -- read-only views over clean
IF SCHEMA_ID(N'core')  IS NULL EXEC (N'CREATE SCHEMA core');    -- analysis-ready tables (Part 3)
IF SCHEMA_ID(N'work')  IS NULL EXEC (N'CREATE SCHEMA work');    -- temporary intermediates (dropped at the end of Parts 2 and 5)
IF SCHEMA_ID(N'mart')  IS NULL EXEC (N'CREATE SCHEMA mart');    -- dashboard tables (Part 5)
GO

/* ---- Assumptions: change a value here and re-run Parts 3 to 6; nothing is hard-coded elsewhere ---- */
IF OBJECT_ID(N'dq.Assumptions') IS NULL
CREATE TABLE dq.Assumptions (
    name  VARCHAR(60)    NOT NULL PRIMARY KEY,
    value DECIMAL(18,6)  NOT NULL,
    note  VARCHAR(300)   NULL
);
GO
INSERT INTO dq.Assumptions (name, value, note)
SELECT v.name, v.value, v.note
FROM (VALUES
    ('overtime_multiplier',     1.5,  'Overtime is paid at 1.5 x the hourly rate (confirmed: 258,796 of 258,799 source shifts match this rule)'),
    ('peak_percentile',         0.9,  'A peak hour = visitors at or above the store''s own 90th percentile of valid store-hours'),
    ('busy_hours_count',        4,    'Number of network-busiest hours of the day used to flag busy-hour conversion'),
    ('stretched_percentile',    0.75, 'A peak hour is stretched when visitors per effective staff-hour exceeds the network 75th percentile'),
    ('z_flag',                  1,    'z-score above this = unusually high labour cost %, overtime share or absence rate versus the other stores'),
    ('conversion_index_flag',   0.98, 'Conversion index below this = fewer purchases than peers expect at the same month, weekday and hour'),
    ('top_traffic_rank',        4,    'A store is high-traffic when it ranks in the top N stores by visitors'),
    ('bottom_sales_per_hour_n', 3,    'The N stores with the lowest net sales per worked hour are flagged'),
    ('min_cell_visitors',       200,  'Minimum visitors in a weekday-hour cell before it is shown as a worst cell')
) v(name, value, note)
WHERE NOT EXISTS (SELECT 1 FROM dq.Assumptions a WHERE a.name = v.name);
GO

/* ---- Status: which of the seven raw tables are present? (Part 1 stops loudly if any is missing) ---- */
SELECT e.t AS expected_raw_table,
       CASE WHEN OBJECT_ID(N'raw.' + e.t, N'U') IS NOT NULL THEN 'present' ELSE 'MISSING - import it into schema raw' END AS status
FROM (VALUES (N'Employees'),(N'Products'),(N'SalesLineItems'),(N'SalesTransactions'),(N'StaffShifts'),(N'StoreFootfall'),(N'Stores')) e(t);
SELECT * FROM dq.Assumptions ORDER BY name;

/* ---- Optional: fully re-runnable CSV load (instead of the Import Flat File wizard) ----
   1. Change the folder path, remove the comment markers, and run once per file.
   2. Create the table first with the column list from your data dictionary (use DECIMAL for money and hours).
   Example for one file:
     -- TRUNCATE TABLE raw.Stores;
     -- BULK INSERT raw.Stores FROM 'C:\Task2\Stores.csv'
     --   WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', TABLOCK);
   Never run TRUNCATE or DROP on raw tables once the analysis has started. */
GO


/* #####################################################################################################
   PART 1 - DATA TYPE VALIDATION AND CORRECTION (raw -> clean)
   Inspects the real raw schema, validates every value, logs problems, builds typed [clean] tables, reports duplicates, verifies.
   ##################################################################################################### */
/* =====================================================================================================
   03_Data_Type_Validation_and_Correction.sql
   Project  : Retail Sales and Staffing Efficiency Analysis
   Database : task2_DataWH          Engine : Microsoft SQL Server 2022 (T-SQL) - run in SSMS
   -----------------------------------------------------------------------------------------------------
   WHAT THIS SCRIPT DOES
     1. INSPECT   the real schema of the seven raw tables (nothing is assumed about the Import Wizard types).
     2. PLAN      the target data types in an editable mapping table (dq.ColumnTypeMap) and check it
                  against the real raw columns. The script STOPS LOUDLY if they disagree.
     3. VALIDATE  every value before conversion: NULL vs empty string vs failed conversion, bad dates,
                  non-numeric text, numbers that do not fit the target type, text that is too long.
     4. QUARANTINE every problem value in dq.ConversionExceptions WITH its original text and the row id.
     5. CONVERT   into seven typed tables in schema [clean]. No raw row is dropped; a value that cannot be
                  converted becomes NULL in [clean] AND is logged in the exceptions table (never silent).
     6. DUPLICATES are only REPORTED (dq.ExactDuplicateGroups, dq.KeyDuplicates) - never removed here.
     7. VERIFY    data types, row counts, unexpected NULLs and identifier integrity.

   WHAT IT NEVER DOES
     * It never modifies, truncates, drops or overwrites anything in schema [raw].
     * It never deletes duplicates or invalid records.

   OBJECTS CREATED
     Schemas : clean, dq
     dq      : RawColumnInventory, ColumnTypeMap, PreflightIssue, ColumnValidation, ConversionExceptions,
               ExactDuplicateGroups, KeyDuplicates, ConversionSummary, NullReconciliation, IdentifierCheck,
               vColumnPlan (view), src_<Table> x7 (indexed snapshot copies of raw, used for row lineage)
     clean   : Employees, Products, SalesLineItems, SalesTransactions, StaffShifts, StoreFootfall, Stores
               (each = original columns, converted types, plus SourceRowID and HasConversionIssue)

   HOW TO RUN
     Run the file section by section the first time (highlight from one "SECTION" banner to the next, F5),
     read the result grids, then run the next section. Re-running is safe: all dq results and clean tables
     are rebuilt; the type map (dq.ColumnTypeMap) is kept so your edits survive.
   ===================================================================================================== */

USE Task2_DataWH;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* =====================================================================================================
   SECTION 0 - Schemas and result tables
   ===================================================================================================== */
IF SCHEMA_ID(N'clean') IS NULL EXEC (N'CREATE SCHEMA clean');
IF SCHEMA_ID(N'dq')    IS NULL EXEC (N'CREATE SCHEMA dq');
GO

/* ---- Inventory of the real raw columns (filled in Section 1) ---- */
IF OBJECT_ID(N'dq.RawColumnInventory') IS NULL
CREATE TABLE dq.RawColumnInventory (
    table_name        SYSNAME      NOT NULL,
    column_name       SYSNAME      NOT NULL,
    ordinal           INT          NOT NULL,
    data_type         VARCHAR(30)  NOT NULL,
    max_length_chars  INT          NULL,       -- -1 means MAX
    numeric_precision INT          NULL,
    numeric_scale     INT          NULL,
    datetime_precision INT         NULL,
    is_nullable       BIT          NOT NULL,
    CONSTRAINT PK_RawColumnInventory PRIMARY KEY (table_name, column_name)
);

/* ---- The type plan. kind: TEXT | INT | DEC | DATE | TIME | DATETIME. Edit rows here, then re-run Section 2+ ---- */
IF OBJECT_ID(N'dq.ColumnTypeMap') IS NULL
CREATE TABLE dq.ColumnTypeMap (
    table_name     SYSNAME       NOT NULL,
    column_name    SYSNAME       NOT NULL,
    ordinal        INT           NOT NULL,
    kind           VARCHAR(10)   NOT NULL,
    target_type    VARCHAR(40)   NOT NULL,
    text_len       INT           NULL,        -- only for kind = TEXT (must match the length in target_type)
    is_identifier  BIT           NOT NULL,
    nulls_expected BIT           NOT NULL,    -- 1 = NULL is a legitimate business value for this column
    rationale      VARCHAR(300)  NULL,
    CONSTRAINT PK_ColumnTypeMap PRIMARY KEY (table_name, column_name)
);

DROP TABLE IF EXISTS dq.PreflightIssue;
CREATE TABLE dq.PreflightIssue (issue_type VARCHAR(40), table_name SYSNAME NULL, column_name SYSNAME NULL, detail VARCHAR(400));

DROP TABLE IF EXISTS dq.ColumnValidation;
CREATE TABLE dq.ColumnValidation (
    table_name SYSNAME NOT NULL, column_name SYSNAME NOT NULL, source_type VARCHAR(30) NULL, target_type VARCHAR(40) NULL,
    total_rows BIGINT NULL, genuine_null_rows BIGINT NULL, empty_string_rows BIGINT NULL, max_observed_length INT NULL,
    error_rows BIGINT NULL, warning_rows BIGINT NULL, valid_populated_rows BIGINT NULL,
    CONSTRAINT PK_ColumnValidation PRIMARY KEY (table_name, column_name)
);

DROP TABLE IF EXISTS dq.ConversionExceptions;
CREATE TABLE dq.ConversionExceptions (
    exception_id   BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    table_name     SYSNAME        NOT NULL,
    column_name    SYSNAME        NOT NULL,
    source_row_id  BIGINT         NOT NULL,      -- = SourceRowID in dq.src_<table> and in clean.<table>
    original_value NVARCHAR(4000) NULL,          -- the value exactly as imported
    problem_code   VARCHAR(30)    NOT NULL,
    severity       VARCHAR(10)    NOT NULL,      -- ERROR = value set to NULL in clean; WARNING = value kept (cosmetic fix)
    target_type    VARCHAR(40)    NULL,
    logged_at      DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_ConversionExceptions_row ON dq.ConversionExceptions (table_name, source_row_id) INCLUDE (severity, column_name);

DROP TABLE IF EXISTS dq.ExactDuplicateGroups;
CREATE TABLE dq.ExactDuplicateGroups (table_name SYSNAME, rows_in_group BIGINT, first_source_row_id BIGINT, last_source_row_id BIGINT);

DROP TABLE IF EXISTS dq.KeyDuplicates;
CREATE TABLE dq.KeyDuplicates (table_name SYSNAME, key_definition VARCHAR(200), key_value NVARCHAR(400), occurrences BIGINT, first_source_row_id BIGINT, last_source_row_id BIGINT);

DROP TABLE IF EXISTS dq.ConversionSummary;
CREATE TABLE dq.ConversionSummary (table_name SYSNAME, raw_rows BIGINT, snapshot_rows BIGINT, clean_rows BIGINT, rows_with_error BIGINT, error_exceptions BIGINT, warning_exceptions BIGINT);

DROP TABLE IF EXISTS dq.NullReconciliation;
CREATE TABLE dq.NullReconciliation (table_name SYSNAME, column_name SYSNAME, clean_null_rows BIGINT NULL, expected_null_rows BIGINT NULL, unexpected_nulls BIGINT NULL);

DROP TABLE IF EXISTS dq.IdentifierCheck;
CREATE TABLE dq.IdentifierCheck (table_name SYSNAME, column_name SYSNAME, rows_compared BIGINT, mismatched_rows BIGINT);
GO

/* =====================================================================================================
   SECTION 1 - INSPECT the raw tables (read-only)
   ===================================================================================================== */
TRUNCATE TABLE dq.RawColumnInventory;

INSERT INTO dq.RawColumnInventory (table_name, column_name, ordinal, data_type, max_length_chars, numeric_precision, numeric_scale, datetime_precision, is_nullable)
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.ORDINAL_POSITION, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH,
       c.NUMERIC_PRECISION, c.NUMERIC_SCALE, c.DATETIME_PRECISION, CASE WHEN c.IS_NULLABLE = 'YES' THEN 1 ELSE 0 END
FROM INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.TABLE_SCHEMA = N'raw'
  AND c.TABLE_NAME IN (N'Employees', N'Products', N'SalesLineItems', N'SalesTransactions', N'StaffShifts', N'StoreFootfall', N'Stores');

-- 1a. Every column of the seven raw tables: type, length, precision, scale, nullability
SELECT table_name, ordinal, column_name, data_type, max_length_chars AS max_length_chars_or_minus1_for_MAX,
       numeric_precision, numeric_scale, datetime_precision, CASE is_nullable WHEN 1 THEN 'YES' ELSE 'NO' END AS is_nullable
FROM dq.RawColumnInventory
ORDER BY table_name, ordinal;

-- 1b. Row counts (fast: read from system metadata, no table scan)
SELECT t.name AS raw_table, SUM(p.row_count) AS row_count
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id AND s.name = N'raw'
JOIN sys.dm_db_partition_stats AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY t.name
ORDER BY t.name;
GO

/* =====================================================================================================
   SECTION 2 - PLAN the target types, run pre-flight checks, build the row-lineage snapshots
   -----------------------------------------------------------------------------------------------------
   The types below are PROPOSALS taken from the data dictionary and from your earlier profiling
   (identifiers = text, money = DECIMAL, dates = DATE, timestamps = DATETIME2, whole numbers = INT).
   They are NOT assumed to be right: Section 3 measures the real data against them.
   If Section 3 shows TARGET_TOO_NARROW / PRECISION_LOSS / TEXT_TOO_LONG, edit the row here and re-run.
   Identifiers use NVARCHAR so no character can ever be lost; leading zeros are preserved because they stay text.
   ===================================================================================================== */
IF NOT EXISTS (SELECT 1 FROM dq.ColumnTypeMap)
INSERT INTO dq.ColumnTypeMap (table_name, column_name, ordinal, kind, target_type, text_len, is_identifier, nulls_expected, rationale)
VALUES
 -- Stores
 (N'Stores', N'StoreID',        1, 'TEXT', 'NVARCHAR(30)',  30,  1, 0, 'Business key; text'),
 (N'Stores', N'StoreName',      2, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Stores', N'City',           3, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Stores', N'Province',       4, 'TEXT', 'NVARCHAR(50)',  50,  0, 0, 'Descriptive text'),
 (N'Stores', N'BusinessUnit',   5, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Stores', N'Division',       6, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Stores', N'FloorAreaSqFt',  7, 'INT',  'INT',           NULL,0, 0, 'Whole square feet'),
 (N'Stores', N'OpeningHour',    8, 'INT',  'TINYINT',       NULL,0, 0, 'Hour of day 0-23'),
 (N'Stores', N'ClosingHour',    9, 'INT',  'TINYINT',       NULL,0, 0, 'Hour of day 0-23'),
 -- Products
 (N'Products', N'ProductID',           1, 'TEXT', 'NVARCHAR(30)',  30,  1, 0, 'Business key; text'),
 (N'Products', N'ProductName',         2, 'TEXT', 'NVARCHAR(200)', 200, 0, 0, 'Descriptive text'),
 (N'Products', N'Category',            3, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Products', N'StandardUnitCostCAD', 4, 'DEC',  'DECIMAL(12,4)', NULL,0, 0, 'Money in CAD'),
 (N'Products', N'ListPriceCAD',        5, 'DEC',  'DECIMAL(12,4)', NULL,0, 0, 'Money in CAD'),
 -- Employees
 (N'Employees', N'EmployeeID',              1, 'TEXT', 'NVARCHAR(30)',  30,  1, 0, 'Business key; text'),
 (N'Employees', N'SourceRecordID',          2, 'TEXT', 'NVARCHAR(30)',  30,  1, 0, 'Source system id; kept as text'),
 (N'Employees', N'StoreID',                 3, 'TEXT', 'NVARCHAR(30)',  30,  1, 0, 'Foreign key to Stores'),
 (N'Employees', N'Department',              4, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Employees', N'JobTitle',                5, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 (N'Employees', N'Gender',                  6, 'TEXT', 'NVARCHAR(30)',  30,  0, 1, 'Profiling found 3 missing values'),
 (N'Employees', N'BirthDate',               7, 'DATE', 'DATE',          NULL,0, 0, 'Calendar date'),
 (N'Employees', N'HireDate',                8, 'DATE', 'DATE',          NULL,0, 0, 'Calendar date'),
 (N'Employees', N'AgeYears',                9, 'INT',  'INT',           NULL,0, 0, 'Whole years'),
 (N'Employees', N'LengthOfServiceYears',   10, 'DEC',  'DECIMAL(9,4)',  NULL,0, 0, 'Fractional years'),
 (N'Employees', N'EmploymentType',         11, 'TEXT', 'NVARCHAR(50)',  50,  0, 0, 'Descriptive text'),
 (N'Employees', N'HourlyRateCAD',          12, 'DEC',  'DECIMAL(10,4)', NULL,0, 0, 'Money in CAD'),
 (N'Employees', N'Task1ScheduledHours2025',13, 'DEC',  'DECIMAL(12,4)', NULL,0, 0, 'Hours'),
 (N'Employees', N'Task1AbsentHours',       14, 'DEC',  'DECIMAL(12,4)', NULL,0, 1, 'Profiling found 2 missing values'),
 (N'Employees', N'Task1AbsenceRate',       15, 'DEC',  'DECIMAL(12,8)', NULL,0, 1, 'Profiling found 2 missing values'),
 (N'Employees', N'Task2ScheduledHours2025',16, 'DEC',  'DECIMAL(12,4)', NULL,0, 0, 'Hours'),
 (N'Employees', N'Task2AbsentHours2025',   17, 'DEC',  'DECIMAL(12,4)', NULL,0, 0, 'Hours'),
 (N'Employees', N'AbsenceValueBasis',      18, 'TEXT', 'NVARCHAR(100)', 100, 0, 0, 'Descriptive text'),
 -- SalesTransactions
 (N'SalesTransactions', N'TransactionID',         1, 'TEXT',     'NVARCHAR(30)', 30, 1, 0, 'Business key; text'),
 (N'SalesTransactions', N'StoreID',               2, 'TEXT',     'NVARCHAR(30)', 30, 1, 0, 'Foreign key to Stores'),
 (N'SalesTransactions', N'TransactionDateTime',   3, 'DATETIME', 'DATETIME2(3)', NULL,0, 0, 'Timestamp to the second; ISO yyyy-mm-dd hh:mm:ss expected'),
 (N'SalesTransactions', N'TransactionType',       4, 'TEXT',     'NVARCHAR(30)', 30, 0, 0, 'Sale / Return'),
 (N'SalesTransactions', N'OriginalTransactionID', 5, 'TEXT',     'NVARCHAR(30)', 30, 1, 1, 'Blank for sales, filled for returns'),
 -- SalesLineItems
 (N'SalesLineItems', N'SalesLineID',         1, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Business key; text'),
 (N'SalesLineItems', N'TransactionID',       2, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Foreign key to SalesTransactions'),
 (N'SalesLineItems', N'ProductID',           3, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Foreign key to Products'),
 (N'SalesLineItems', N'Quantity',            4, 'INT',  'INT',          NULL,0, 0, 'Whole units; negative on returns'),
 (N'SalesLineItems', N'UnitPriceCAD',        5, 'DEC',  'DECIMAL(12,4)',NULL,0, 0, 'Money in CAD'),
 (N'SalesLineItems', N'DiscountAmountCAD',   6, 'DEC',  'DECIMAL(12,4)',NULL,0, 0, 'Money in CAD (line amount)'),
 (N'SalesLineItems', N'UnitCostAtSaleCAD',   7, 'DEC',  'DECIMAL(12,4)',NULL,0, 0, 'Money in CAD'),
 (N'SalesLineItems', N'OriginalSalesLineID', 8, 'TEXT', 'NVARCHAR(30)', 30, 1, 1, 'Blank for sales, filled for returns'),
 -- StaffShifts
 (N'StaffShifts', N'ShiftID',        1, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Business key; text'),
 (N'StaffShifts', N'EmployeeID',     2, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Foreign key to Employees'),
 (N'StaffShifts', N'StoreID',        3, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Foreign key to Stores'),
 (N'StaffShifts', N'ShiftDate',      4, 'DATE', 'DATE',         NULL,0, 0, 'Calendar date'),
 (N'StaffShifts', N'StartTime',      5, 'TIME', 'TIME(0)',      NULL,0, 0, 'Time of day hh:mm'),
 (N'StaffShifts', N'EndTime',        6, 'TIME', 'TIME(0)',      NULL,0, 0, 'Time of day; includes overtime per data dictionary'),
 (N'StaffShifts', N'ScheduledHours', 7, 'DEC',  'DECIMAL(9,4)', NULL,0, 0, 'Hours'),
 (N'StaffShifts', N'WorkedHours',    8, 'DEC',  'DECIMAL(9,4)', NULL,0, 0, 'Hours'),
 (N'StaffShifts', N'AbsentHours',    9, 'DEC',  'DECIMAL(9,4)', NULL,0, 0, 'Hours'),
 (N'StaffShifts', N'OvertimeHours', 10, 'DEC',  'DECIMAL(9,4)', NULL,0, 0, 'Hours'),
 (N'StaffShifts', N'LabourCostCAD', 11, 'DEC',  'DECIMAL(14,4)',NULL,0, 0, 'Money in CAD'),
 -- StoreFootfall
 (N'StoreFootfall', N'StoreID',         1, 'TEXT', 'NVARCHAR(30)', 30, 1, 0, 'Foreign key to Stores'),
 (N'StoreFootfall', N'ObservationDate', 2, 'DATE', 'DATE',         NULL,0, 0, 'Calendar date'),
 (N'StoreFootfall', N'HourOfDay',       3, 'INT',  'TINYINT',      NULL,0, 0, 'Trading hour 0-23'),
 (N'StoreFootfall', N'VisitorCount',    4, 'INT',  'INT',          NULL,0, 1, 'Profiling found 12 missing values; missing must stay NULL, never 0');
GO

/* ---- 2a. Pre-flight: the plan must match the real raw tables exactly ---- */
TRUNCATE TABLE dq.PreflightIssue;

-- expected tables that do not exist in schema raw
INSERT INTO dq.PreflightIssue (issue_type, table_name, detail)
SELECT 'MISSING_RAW_TABLE', e.t, 'Table not found in schema raw'
FROM (VALUES (N'Employees'),(N'Products'),(N'SalesLineItems'),(N'SalesTransactions'),(N'StaffShifts'),(N'StoreFootfall'),(N'Stores')) AS e(t)
WHERE NOT EXISTS (SELECT 1 FROM dq.RawColumnInventory i WHERE i.table_name = e.t);

-- columns in the plan that are not in the raw table
INSERT INTO dq.PreflightIssue (issue_type, table_name, column_name, detail)
SELECT 'PLANNED_COLUMN_NOT_IN_RAW', m.table_name, m.column_name, 'Column is in dq.ColumnTypeMap but not in the raw table (check spelling)'
FROM dq.ColumnTypeMap m
WHERE NOT EXISTS (SELECT 1 FROM dq.RawColumnInventory i WHERE i.table_name = m.table_name AND i.column_name = m.column_name);

-- raw columns that have no plan (they would be silently lost from clean)
INSERT INTO dq.PreflightIssue (issue_type, table_name, column_name, detail)
SELECT 'RAW_COLUMN_NOT_PLANNED', i.table_name, i.column_name, 'Raw column has no row in dq.ColumnTypeMap; add one'
FROM dq.RawColumnInventory i
WHERE NOT EXISTS (SELECT 1 FROM dq.ColumnTypeMap m WHERE m.table_name = i.table_name AND m.column_name = i.column_name);

-- source types this script does not know how to read safely
INSERT INTO dq.PreflightIssue (issue_type, table_name, column_name, detail)
SELECT 'UNSUPPORTED_SOURCE_TYPE', i.table_name, i.column_name, 'Source type ' + i.data_type + ' is not supported by this script'
FROM dq.RawColumnInventory i
WHERE i.data_type NOT IN ('char','varchar','nchar','nvarchar','float','real','int','bigint','smallint','tinyint','decimal','numeric',
                          'money','smallmoney','bit','date','datetime','datetime2','smalldatetime','time')
  AND EXISTS (SELECT 1 FROM dq.ColumnTypeMap m WHERE m.table_name = i.table_name AND m.column_name = i.column_name);

-- the plan itself must be consistent
INSERT INTO dq.PreflightIssue (issue_type, table_name, column_name, detail)
SELECT 'BAD_PLAN_ROW', m.table_name, m.column_name, 'TEXT rows need text_len; other kinds must not set it'
FROM dq.ColumnTypeMap m
WHERE (m.kind = 'TEXT' AND m.text_len IS NULL) OR (m.kind <> 'TEXT' AND m.text_len IS NOT NULL)
   OR m.kind NOT IN ('TEXT','INT','DEC','DATE','TIME','DATETIME');

SELECT * FROM dq.PreflightIssue;   -- MUST be empty before you continue
IF EXISTS (SELECT 1 FROM dq.PreflightIssue)
    THROW 50001, N'Pre-flight failed: read dq.PreflightIssue, fix dq.ColumnTypeMap, and re-run from Section 2a.', 1;
GO

/* ---- 2b. View that turns the plan into the SQL fragments used by Sections 3-7 ----
   Run  SELECT * FROM dq.vColumnPlan  to SEE exactly what SQL will be generated for each column.
   Every value is first rendered to text (val_expr) so the same logic works whatever type the wizard created.   */
GO
CREATE OR ALTER VIEW dq.vColumnPlan
AS
SELECT
    m.table_name, m.column_name, m.ordinal, m.kind, m.target_type, m.is_identifier, i.data_type AS source_type,
    b.val  AS val_expr,
    f.profile_tuple, f.exception_tuple, e.clean_expr,
    QUOTENAME(m.column_name) + N' ' + m.target_type + N' NULL' AS col_def,
    QUOTENAME(m.column_name)                                   AS col_list
FROM dq.ColumnTypeMap AS m
JOIN dq.RawColumnInventory AS i ON i.table_name = m.table_name AND i.column_name = m.column_name
CROSS APPLY (SELECT
        N'r.' + QUOTENAME(m.column_name)                                                        AS qc,
        CASE WHEN i.data_type IN ('char','varchar','nchar','nvarchar') THEN 1 ELSE 0 END        AS is_char,
        N'N''' + REPLACE(m.column_name, N'''', N'''''') + N''''                                 AS name_lit
    ) AS a
CROSS APPLY (SELECT CASE
        WHEN a.is_char = 1 THEN N'NULLIF(LTRIM(RTRIM(' + a.qc + N')), N'''')'                   -- trim; empty string -> NULL
        -- FLOAT / REAL (the Import Wizard creates these for many decimal columns). They are read straight into DECIMAL(38,12) text.
        -- The earlier style-3 text ('2.0020000000000000e+001') cannot be converted to DECIMAL by SQL Server: every value became NULL.
        -- Whole-number targets get an integer text when the float is whole, so TRY_CONVERT(INT, ...) works; a fractional value is still reported as TARGET_TOO_NARROW.
        -- The ISNULL fallback keeps a value that does not fit DECIMAL(38,12) visible (it is logged as an exception, never silently NULL).
        WHEN i.data_type IN ('float','real') AND m.kind = 'INT'
                                              THEN N'CASE WHEN ' + a.qc + N' = ROUND(' + a.qc + N', 0) '
                                                 + N'THEN ISNULL(CONVERT(NVARCHAR(64), TRY_CONVERT(DECIMAL(38,0), ' + a.qc + N')), CONVERT(NVARCHAR(64), ' + a.qc + N', 3)) '
                                                 + N'ELSE ISNULL(CONVERT(NVARCHAR(64), TRY_CONVERT(DECIMAL(38,12), ' + a.qc + N')), CONVERT(NVARCHAR(64), ' + a.qc + N', 3)) END'
        WHEN i.data_type IN ('float','real') THEN N'ISNULL(CONVERT(NVARCHAR(64), TRY_CONVERT(DECIMAL(38,12), ' + a.qc + N')), CONVERT(NVARCHAR(64), ' + a.qc + N', 3))'
  WHEN i.data_type IN ('datetime','datetime2','smalldatetime','datetimeoffset') AND m.kind = 'TIME'
                                              THEN N'CONVERT(NVARCHAR(40), ' + a.qc + N', 108)' -- time-of-day only (hh:mi:ss)
        WHEN i.data_type IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
                                              THEN N'CONVERT(NVARCHAR(40), ' + a.qc + N', 126)' -- ISO 8601 text

        WHEN i.data_type = 'time'             THEN N'CONVERT(NVARCHAR(40), ' + a.qc + N', 108)' -- hh:mi:ss
        ELSE N'CONVERT(NVARCHAR(64), ' + a.qc + N')' END AS val
    ) AS b
CROSS APPLY (SELECT CASE m.kind
        WHEN 'DATE'     THEN N'(' + b.val + N') LIKE ''[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]%'''
        WHEN 'DATETIME' THEN N'(' + b.val + N') LIKE ''[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]%'''
        WHEN 'TIME'     THEN N'(' + b.val + N') LIKE ''[0-9][0-9]:[0-9][0-9]%'''
        END AS pat                                    -- strict ISO shape so a dd/mm vs mm/dd date can never be mis-read
    ) AS c
CROSS APPLY (SELECT CASE
        WHEN m.kind = 'TEXT' THEN
              N'CASE WHEN LEN(' + b.val + N') > ' + CAST(m.text_len AS NVARCHAR(10)) + N' THEN ''TEXT_TOO_LONG'' '
            + N'WHEN ' + b.val + N' LIKE N''%'' + NCHAR(13) + N''%'' OR ' + b.val + N' LIKE N''%'' + NCHAR(10) + N''%'' OR '
                       + b.val + N' LIKE N''%'' + NCHAR(9) + N''%'' THEN ''CONTROL_CHARACTER'' '
            + CASE WHEN a.is_char = 1 THEN N'WHEN DATALENGTH(' + a.qc + N') <> DATALENGTH(LTRIM(RTRIM(' + a.qc + N'))) THEN ''WHITESPACE_TRIMMED'' ' ELSE N'' END
            + N'END'
        ELSE
              N'CASE WHEN ' + b.val + N' IS NULL THEN NULL '
            + CASE WHEN c.pat IS NOT NULL THEN N'WHEN NOT ' + c.pat + N' THEN ''INVALID_FORMAT'' ' ELSE N'' END
            + N'WHEN TRY_CONVERT(' + m.target_type + N', ' + b.val + N') IS NULL THEN '
            +     N'CASE WHEN TRY_CONVERT(DECIMAL(38,10), ' + b.val + N') IS NOT NULL THEN ''TARGET_TOO_NARROW'' ELSE ''FAILED_CONVERSION'' END '
            + CASE WHEN m.kind = 'DEC' THEN N'WHEN TRY_CONVERT(DECIMAL(38,10), ' + b.val + N') <> TRY_CONVERT(' + m.target_type + N', ' + b.val + N') THEN ''PRECISION_LOSS'' ' ELSE N'' END
            + N'END'
        END AS problem
    ) AS d
CROSS APPLY (SELECT CASE
        WHEN m.kind = 'TEXT' THEN
              N'CASE WHEN LEN(' + b.val + N') > ' + CAST(m.text_len AS NVARCHAR(10)) + N' THEN NULL ELSE CONVERT(' + m.target_type
            + N', REPLACE(REPLACE(REPLACE(' + b.val + N', NCHAR(13), N''''), NCHAR(10), N''''), NCHAR(9), N''''))  END'
        ELSE  N'CASE WHEN (' + d.problem + N') IS NULL THEN TRY_CONVERT(' + m.target_type + N', ' + b.val + N') END'
        END AS clean_expr
    ) AS e
CROSS APPLY (SELECT
        N'(' + a.name_lit + N', CASE WHEN ' + a.qc + N' IS NULL THEN 1 ELSE 0 END, '
            + CASE WHEN a.is_char = 1 THEN N'CASE WHEN ' + a.qc + N' IS NOT NULL AND ' + b.val + N' IS NULL THEN 1 ELSE 0 END' ELSE N'0' END
            + N', LEN(' + b.val + N'))'                                                          AS profile_tuple,
        N'(' + a.name_lit + N', ' + CASE WHEN a.is_char = 1 THEN N'CONVERT(NVARCHAR(4000), ' + a.qc + N')' ELSE b.val END
            + N', ' + d.problem + N')'                                                           AS exception_tuple
    ) AS f;
GO

/* ---- 2c. Row-lineage snapshots: an exact copy of each raw table + a SourceRowID.
          Raw stays untouched; the snapshot lets every problem be traced back to one original row. ---- */
DROP TABLE IF EXISTS dq.src_Stores;            SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_Stores            FROM raw.Stores            AS r;
DROP TABLE IF EXISTS dq.src_Products;          SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_Products          FROM raw.Products          AS r;
DROP TABLE IF EXISTS dq.src_Employees;         SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_Employees         FROM raw.Employees         AS r;
DROP TABLE IF EXISTS dq.src_SalesTransactions; SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_SalesTransactions FROM raw.SalesTransactions AS r;
DROP TABLE IF EXISTS dq.src_SalesLineItems;    SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_SalesLineItems    FROM raw.SalesLineItems    AS r;
DROP TABLE IF EXISTS dq.src_StaffShifts;       SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_StaffShifts       FROM raw.StaffShifts       AS r;
DROP TABLE IF EXISTS dq.src_StoreFootfall;     SELECT IDENTITY(BIGINT,1,1) AS SourceRowID, r.* INTO dq.src_StoreFootfall     FROM raw.StoreFootfall     AS r;
GO

/* =====================================================================================================
   SECTION 3 - VALIDATE every column before converting (one pass over each table)
   Counts genuine NULLs, empty strings and the longest value. Problems themselves are logged in Section 4.
   ===================================================================================================== */
IF EXISTS (SELECT 1 FROM dq.PreflightIssue) THROW 50001, N'Pre-flight issues exist. Fix Section 2 first.', 1;

TRUNCATE TABLE dq.ColumnValidation;

DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME, @tuples NVARCHAR(MAX), @sql NVARCHAR(MAX);

WHILE @i <= @n   -- loops over the 7 TABLE NAMES only; the data itself is processed set-based
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;

    SELECT @tuples = STRING_AGG(CAST(profile_tuple AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY ordinal)
    FROM dq.vColumnPlan WHERE table_name = @t;

    SET @sql = N'INSERT INTO dq.ColumnValidation (table_name, column_name, source_type, target_type, total_rows, genuine_null_rows, empty_string_rows, max_observed_length)
                 SELECT N''' + @t + N''', v.column_name, MAX(p.source_type), MAX(p.target_type), COUNT_BIG(*), SUM(v.is_null), SUM(v.is_empty), MAX(v.val_len)
                 FROM dq.' + QUOTENAME(N'src_' + @t) + N' AS r
                 CROSS APPLY (VALUES ' + @tuples + N') AS v(column_name, is_null, is_empty, val_len)
                 JOIN dq.vColumnPlan AS p ON p.table_name = N''' + @t + N''' AND p.column_name = v.column_name
                 GROUP BY v.column_name;';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;
GO

/* =====================================================================================================
   SECTION 4 - EXCEPTION HANDLING: quarantine every problem value with its original text
   Problem codes
     FAILED_CONVERSION   text in a numeric/date column, impossible date (e.g. 2025-02-30), wrong characters   -> ERROR
     INVALID_FORMAT      date/time not in ISO shape (yyyy-mm-dd, hh:mi)                                         -> ERROR
     TARGET_TOO_NARROW   a valid number that does not fit the proposed type (too big, or decimals in a whole-number column) -> ERROR
     PRECISION_LOSS      a valid number that would be rounded by the proposed scale                              -> ERROR
     TEXT_TOO_LONG       text longer than the proposed length                                                    -> ERROR
     CONTROL_CHARACTER   line break / tab inside text (removed in clean, original kept here)                     -> WARNING
     WHITESPACE_TRIMMED  leading/trailing spaces (trimmed in clean, original kept here)                          -> WARNING
   ERROR   = the value is set to NULL in [clean]; the full original value is kept here.
   WARNING = the value is kept in [clean] after the cosmetic fix.
   ===================================================================================================== */
IF EXISTS (SELECT 1 FROM dq.PreflightIssue) THROW 50001, N'Pre-flight issues exist. Fix Section 2 first.', 1;

TRUNCATE TABLE dq.ConversionExceptions;

DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME, @tuples NVARCHAR(MAX), @sql NVARCHAR(MAX);

WHILE @i <= @n
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;

    SELECT @tuples = STRING_AGG(CAST(exception_tuple AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY ordinal)
    FROM dq.vColumnPlan WHERE table_name = @t;

    SET @sql = N'INSERT INTO dq.ConversionExceptions (table_name, column_name, source_row_id, original_value, problem_code, severity, target_type)
                 SELECT N''' + @t + N''', v.column_name, r.SourceRowID, v.orig, v.problem,
                        CASE WHEN v.problem IN (''CONTROL_CHARACTER'', ''WHITESPACE_TRIMMED'') THEN ''WARNING'' ELSE ''ERROR'' END,
                        m.target_type
                 FROM dq.' + QUOTENAME(N'src_' + @t) + N' AS r
                 CROSS APPLY (VALUES ' + @tuples + N') AS v(column_name, orig, problem)
                 JOIN dq.ColumnTypeMap AS m ON m.table_name = N''' + @t + N''' AND m.column_name = v.column_name
                 WHERE v.problem IS NOT NULL;';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;

-- add the problem counts to the column validation table
UPDATE v
SET v.error_rows   = ISNULL(x.err, 0),
    v.warning_rows = ISNULL(x.warn, 0),
    v.valid_populated_rows = v.total_rows - v.genuine_null_rows - v.empty_string_rows - ISNULL(x.err, 0)
FROM dq.ColumnValidation AS v
LEFT JOIN (SELECT table_name, column_name,
                  SUM(CASE WHEN severity = 'ERROR'   THEN 1 ELSE 0 END) AS err,
                  SUM(CASE WHEN severity = 'WARNING' THEN 1 ELSE 0 END) AS warn
           FROM dq.ConversionExceptions GROUP BY table_name, column_name) AS x
       ON x.table_name = v.table_name AND x.column_name = v.column_name;
GO

-- 4a. Column-by-column validation result (genuine NULL vs empty string vs failed conversion)
SELECT table_name, column_name, source_type, target_type, total_rows,
       genuine_null_rows, empty_string_rows, error_rows AS failed_or_invalid_rows, warning_rows, valid_populated_rows, max_observed_length
FROM dq.ColumnValidation
ORDER BY (error_rows) DESC, table_name, column_name;

-- 4b. The invalid values themselves: which value, which column, how many records
SELECT table_name, column_name, problem_code, severity, original_value, COUNT(*) AS affected_records, MIN(source_row_id) AS example_source_row_id
FROM dq.ConversionExceptions
GROUP BY table_name, column_name, problem_code, severity, original_value
ORDER BY severity, affected_records DESC;

-- 4c. How to review one problem row in full (replace the table and the id):
--     SELECT * FROM dq.src_SalesTransactions WHERE SourceRowID = 12345;      -- the original row, exactly as imported
--     SELECT * FROM dq.ConversionExceptions WHERE table_name = 'SalesTransactions' AND source_row_id = 12345;
GO

/* =====================================================================================================
   SECTION 5 - CONVERT: build the seven typed tables in schema [clean]
   * Same table and column names as raw, converted types, plus
       SourceRowID         = link back to the original row (dq.src_<table>)
       HasConversionIssue  = 1 when at least one ERROR was logged for that row
   * Every raw row is carried over (row counts must match). Problem values are NULL here AND logged in Section 4.
   * Each table is built inside a transaction: if anything fails, that table is rolled back.
   ===================================================================================================== */
IF EXISTS (SELECT 1 FROM dq.PreflightIssue) THROW 50001, N'Pre-flight issues exist. Fix Section 2 first.', 1;

DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME,
        @coldefs NVARCHAR(MAX), @collist NVARCHAR(MAX), @exprs NVARCHAR(MAX), @sql NVARCHAR(MAX);

WHILE @i <= @n
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;

    SELECT @coldefs = STRING_AGG(CAST(col_def    AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY ordinal),
           @collist = STRING_AGG(CAST(col_list   AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY ordinal),
           @exprs   = STRING_AGG(CAST(clean_expr AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY ordinal)
    FROM dq.vColumnPlan WHERE table_name = @t;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (1) create the typed table (dropping a previous CLEAN copy only; raw is never touched)
        SET @sql = N'DROP TABLE IF EXISTS clean.' + QUOTENAME(@t) + N';
                     CREATE TABLE clean.' + QUOTENAME(@t) + N' (
                         SourceRowID BIGINT NOT NULL, ' + @coldefs + N',
                         HasConversionIssue BIT NOT NULL CONSTRAINT ' + QUOTENAME(N'DF_clean_' + @t + N'_issue') + N' DEFAULT (0),
                         CONSTRAINT ' + QUOTENAME(N'PK_clean_' + @t) + N' PRIMARY KEY CLUSTERED (SourceRowID));';
        EXEC sys.sp_executesql @sql;

        -- (2) set-based load: one INSERT ... SELECT per table
        SET @sql = N'INSERT INTO clean.' + QUOTENAME(@t) + N' WITH (TABLOCK) (SourceRowID, ' + @collist + N')
                     SELECT r.SourceRowID, ' + @exprs + N'
                     FROM dq.' + QUOTENAME(N'src_' + @t) + N' AS r;';
        EXEC sys.sp_executesql @sql;

        -- (3) flag rows that had at least one ERROR
        SET @sql = N'UPDATE c SET HasConversionIssue = 1
                     FROM clean.' + QUOTENAME(@t) + N' AS c
                     WHERE EXISTS (SELECT 1 FROM dq.ConversionExceptions AS e
                                   WHERE e.table_name = N''' + @t + N''' AND e.severity = ''ERROR'' AND e.source_row_id = c.SourceRowID);';
        EXEC sys.sp_executesql @sql;

        COMMIT TRANSACTION;
        PRINT CONCAT(N'clean.', @t, N' built.');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;   -- stop and show the original error
    END CATCH;

    SET @i += 1;
END;
GO

/* =====================================================================================================
   SECTION 6 - DUPLICATES: report only, nothing is deleted
   ===================================================================================================== */
IF EXISTS (SELECT 1 FROM dq.PreflightIssue) THROW 50001, N'Pre-flight issues exist. Fix Section 2 first.', 1;

TRUNCATE TABLE dq.ExactDuplicateGroups;
TRUNCATE TABLE dq.KeyDuplicates;

-- 6a. Exact duplicate rows (every converted column identical). One group-by pass per table.
DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME, @collist NVARCHAR(MAX), @sql NVARCHAR(MAX);

WHILE @i <= @n
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;
    SELECT @collist = STRING_AGG(CAST(col_list AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY ordinal)
    FROM dq.vColumnPlan WHERE table_name = @t;

    SET @sql = N'INSERT INTO dq.ExactDuplicateGroups (table_name, rows_in_group, first_source_row_id, last_source_row_id)
                 SELECT N''' + @t + N''', COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
                 FROM clean.' + QUOTENAME(@t) + N' GROUP BY ' + @collist + N' HAVING COUNT_BIG(*) > 1;';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;

-- 6b. Duplicate business keys (same key more than once, even if other columns differ)
INSERT INTO dq.KeyDuplicates
SELECT N'Stores', 'StoreID', CONVERT(NVARCHAR(400), StoreID), COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.Stores GROUP BY StoreID HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'Products', 'ProductID', CONVERT(NVARCHAR(400), ProductID), COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.Products GROUP BY ProductID HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'Employees', 'EmployeeID', CONVERT(NVARCHAR(400), EmployeeID), COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.Employees GROUP BY EmployeeID HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'SalesTransactions', 'TransactionID', CONVERT(NVARCHAR(400), TransactionID), COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.SalesTransactions GROUP BY TransactionID HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'SalesLineItems', 'SalesLineID', CONVERT(NVARCHAR(400), SalesLineID), COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.SalesLineItems GROUP BY SalesLineID HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'StaffShifts', 'ShiftID', CONVERT(NVARCHAR(400), ShiftID), COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.StaffShifts GROUP BY ShiftID HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'StaffShifts', 'EmployeeID + ShiftDate (one shift per employee per day)', CONCAT_WS(N'|', EmployeeID, CONVERT(NVARCHAR(10), ShiftDate, 23)),
       COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.StaffShifts GROUP BY EmployeeID, ShiftDate HAVING COUNT_BIG(*) > 1;

INSERT INTO dq.KeyDuplicates
SELECT N'StoreFootfall', 'StoreID + ObservationDate + HourOfDay', CONCAT_WS(N'|', StoreID, CONVERT(NVARCHAR(10), ObservationDate, 23), HourOfDay),
       COUNT_BIG(*), MIN(SourceRowID), MAX(SourceRowID)
FROM clean.StoreFootfall GROUP BY StoreID, ObservationDate, HourOfDay HAVING COUNT_BIG(*) > 1;
GO

-- Duplicate summary (for investigation; nothing was removed)
SELECT x.table_name,
       (SELECT COUNT(*) FROM dq.ExactDuplicateGroups g WHERE g.table_name = x.table_name)                 AS exact_duplicate_groups,
       (SELECT ISNULL(SUM(g.rows_in_group - 1), 0) FROM dq.ExactDuplicateGroups g WHERE g.table_name = x.table_name) AS exact_surplus_rows,
       (SELECT COUNT(*) FROM dq.KeyDuplicates k WHERE k.table_name = x.table_name)                        AS duplicated_key_values
FROM (VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall')) AS x(table_name)
ORDER BY x.table_name;

SELECT * FROM dq.KeyDuplicates ORDER BY table_name, key_definition, occurrences DESC;
GO

/* =====================================================================================================
   SECTION 7 - VERIFY the corrected tables
   ===================================================================================================== */
-- 7a. Data types of every column in the seven clean tables
SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH, c.NUMERIC_PRECISION,
       c.NUMERIC_SCALE, c.DATETIME_PRECISION, c.IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.TABLE_SCHEMA = N'clean'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
GO

-- 7b. Row counts raw vs snapshot vs clean, converted rows and rows needing investigation
TRUNCATE TABLE dq.ConversionSummary;

DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME, @sql NVARCHAR(MAX);
WHILE @i <= @n
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;
    SET @sql = N'INSERT INTO dq.ConversionSummary (table_name, raw_rows, snapshot_rows, clean_rows, rows_with_error, error_exceptions, warning_exceptions)
        SELECT N''' + @t + N''',
               (SELECT COUNT_BIG(*) FROM raw.' + QUOTENAME(@t) + N'),
               (SELECT COUNT_BIG(*) FROM dq.' + QUOTENAME(N'src_' + @t) + N'),
               (SELECT COUNT_BIG(*) FROM clean.' + QUOTENAME(@t) + N'),
               (SELECT COUNT_BIG(*) FROM clean.' + QUOTENAME(@t) + N' WHERE HasConversionIssue = 1),
               (SELECT COUNT_BIG(*) FROM dq.ConversionExceptions WHERE table_name = N''' + @t + N''' AND severity = ''ERROR''),
               (SELECT COUNT_BIG(*) FROM dq.ConversionExceptions WHERE table_name = N''' + @t + N''' AND severity = ''WARNING'');';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;

SELECT table_name, raw_rows, snapshot_rows, clean_rows,
       CASE WHEN raw_rows = snapshot_rows AND raw_rows = clean_rows THEN 'PASS' ELSE 'FAIL - rows lost or added' END AS row_count_check,
       clean_rows - rows_with_error AS rows_fully_converted,
       rows_with_error              AS rows_requiring_investigation,
       error_exceptions             AS error_values_nulled_in_clean,
       warning_exceptions           AS warning_values_cosmetically_fixed
FROM dq.ConversionSummary
ORDER BY table_name;
GO

-- 7c. Unexpected NULLs: NULLs in clean must equal (genuine NULLs + empty strings + logged ERROR values). Any difference = a problem.
TRUNCATE TABLE dq.NullReconciliation;

DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME, @tuples NVARCHAR(MAX), @sql NVARCHAR(MAX);
WHILE @i <= @n
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;
    SELECT @tuples = STRING_AGG(CAST(N'(N''' + REPLACE(column_name, N'''', N'''''') + N''', CASE WHEN c.' + QUOTENAME(column_name) + N' IS NULL THEN 1 ELSE 0 END)' AS NVARCHAR(MAX)), N',')
    FROM dq.ColumnTypeMap WHERE table_name = @t;
    SET @sql = N'INSERT INTO dq.NullReconciliation (table_name, column_name, clean_null_rows)
                 SELECT N''' + @t + N''', v.column_name, SUM(v.is_null)
                 FROM clean.' + QUOTENAME(@t) + N' AS c CROSS APPLY (VALUES ' + @tuples + N') AS v(column_name, is_null)
                 GROUP BY v.column_name;';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;

UPDATE n
SET n.expected_null_rows = v.genuine_null_rows + v.empty_string_rows + ISNULL(v.error_rows, 0),
    n.unexpected_nulls   = n.clean_null_rows - (v.genuine_null_rows + v.empty_string_rows + ISNULL(v.error_rows, 0))
FROM dq.NullReconciliation AS n
JOIN dq.ColumnValidation  AS v ON v.table_name = n.table_name AND v.column_name = n.column_name;

SELECT table_name, column_name, clean_null_rows, expected_null_rows, unexpected_nulls,
       CASE WHEN unexpected_nulls = 0 THEN 'PASS' ELSE 'INVESTIGATE' END AS status
FROM dq.NullReconciliation
ORDER BY (CASE WHEN unexpected_nulls = 0 THEN 1 ELSE 0 END), table_name, column_name;
GO

-- 7d. Identifier integrity: clean identifiers must equal the raw identifiers (apart from trimmed spaces) - no truncation, no change
TRUNCATE TABLE dq.IdentifierCheck;

DECLARE @tables TABLE (id INT IDENTITY(1,1), t SYSNAME);
INSERT INTO @tables (t) VALUES (N'Stores'),(N'Products'),(N'Employees'),(N'SalesTransactions'),(N'SalesLineItems'),(N'StaffShifts'),(N'StoreFootfall');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @tables), @t SYSNAME, @tuples NVARCHAR(MAX), @sql NVARCHAR(MAX);
WHILE @i <= @n
BEGIN
    SELECT @t = t FROM @tables WHERE id = @i;
    SELECT @tuples = STRING_AGG(CAST(
             N'(N''' + REPLACE(column_name, N'''', N'''''') + N''', CASE WHEN ISNULL(CONVERT(NVARCHAR(4000), c.' + QUOTENAME(column_name)
           + N'), N'''') COLLATE Latin1_General_BIN2 <> ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(4000), r.' + QUOTENAME(column_name)
           + N'))), N'''') THEN 1 ELSE 0 END)' AS NVARCHAR(MAX)), N',')
    FROM dq.ColumnTypeMap WHERE table_name = @t AND is_identifier = 1;
    IF @tuples IS NULL BEGIN SET @i += 1; CONTINUE; END;

    SET @sql = N'INSERT INTO dq.IdentifierCheck (table_name, column_name, rows_compared, mismatched_rows)
                 SELECT N''' + @t + N''', v.column_name, COUNT_BIG(*), SUM(v.mismatch)
                 FROM clean.' + QUOTENAME(@t) + N' AS c
                 JOIN dq.' + QUOTENAME(N'src_' + @t) + N' AS r ON r.SourceRowID = c.SourceRowID
                 CROSS APPLY (VALUES ' + @tuples + N') AS v(column_name, mismatch)
                 GROUP BY v.column_name;';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;

SELECT table_name, column_name, rows_compared, mismatched_rows,
       CASE WHEN mismatched_rows = 0 THEN 'PASS' ELSE 'INVESTIGATE' END AS status
FROM dq.IdentifierCheck
ORDER BY (CASE WHEN mismatched_rows = 0 THEN 1 ELSE 0 END), table_name, column_name;
GO

-- 7e. Final overview
SELECT 'Raw tables unchanged (row counts, snapshot equals raw)' AS check_item,
       CASE WHEN NOT EXISTS (SELECT 1 FROM dq.ConversionSummary WHERE raw_rows <> snapshot_rows) THEN 'PASS' ELSE 'FAIL' END AS result
UNION ALL SELECT 'Clean row counts equal raw row counts',
       CASE WHEN NOT EXISTS (SELECT 1 FROM dq.ConversionSummary WHERE raw_rows <> clean_rows) THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'No unexpected NULLs introduced by conversion',
       CASE WHEN NOT EXISTS (SELECT 1 FROM dq.NullReconciliation WHERE unexpected_nulls <> 0) THEN 'PASS' ELSE 'INVESTIGATE' END
UNION ALL SELECT 'Identifiers unchanged and untruncated',
       CASE WHEN NOT EXISTS (SELECT 1 FROM dq.IdentifierCheck WHERE mismatched_rows <> 0) THEN 'PASS' ELSE 'INVESTIGATE' END
UNION ALL SELECT 'Values logged as ERROR (need your decision; see dq.ConversionExceptions)',
       CAST((SELECT COUNT(*) FROM dq.ConversionExceptions WHERE severity = 'ERROR') AS VARCHAR(20))
UNION ALL SELECT 'Duplicate groups reported (nothing deleted; see dq.ExactDuplicateGroups / dq.KeyDuplicates)',
       CAST((SELECT COUNT(*) FROM dq.ExactDuplicateGroups) + (SELECT COUNT(*) FROM dq.KeyDuplicates) AS VARCHAR(20));
GO

/* =====================================================================================================
   HOW TO CORRECT FLAGGED VALUES (after you investigate)
     * Look at the original row:       SELECT * FROM dq.src_<Table> WHERE SourceRowID = <id from dq.ConversionExceptions>;
     * If the PLAN was wrong (e.g. TARGET_TOO_NARROW / PRECISION_LOSS / TEXT_TOO_LONG on valid data):
       edit the type in dq.ColumnTypeMap, then re-run Sections 2b to 7. Nothing in raw changes.
     * If the SOURCE value is wrong: decide a business rule (fix, exclude, or leave NULL) and document it in the next
       cleaning step; never edit schema raw.
   ===================================================================================================== */

/* ---- STOP CHECK: if more than 1% of the values in any column failed conversion, something systematic is wrong ---- */
IF EXISTS (SELECT 1 FROM dq.ColumnValidation WHERE total_rows > 0 AND error_rows * 1.0 > 0.01 * total_rows)
    THROW 50020, N'Part 1 stop: more than 1% of the values in at least one column failed conversion. Run SELECT * FROM dq.ColumnValidation ORDER BY error_rows DESC; and SELECT * FROM dq.vColumnPlan; to see why, then fix the type plan before Part 2.', 1;
GO


/* #####################################################################################################
   PART 2 - BUSINESS-RULE DATA-QUALITY PROFILING (clean -> dq)
   Checks keys, missing values, duplicates, invalid dates, unmatched references, invalid numbers and business rules. Changes nothing.
   ##################################################################################################### */
USE Task2_DataWH;
GO
IF SCHEMA_ID(N'stg')  IS NULL EXEC(N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'core') IS NULL EXEC(N'CREATE SCHEMA core');
IF SCHEMA_ID(N'work') IS NULL EXEC(N'CREATE SCHEMA work');
IF SCHEMA_ID(N'mart') IS NULL EXEC(N'CREATE SCHEMA mart');
GO
/* PART 2 reads the typed tables from Part 1 through the stg views below. */

-- Snake_case, typed views over the Part 1 tables. They hide SourceRowID/HasConversionIssue so that
-- DISTINCT can recognise exact duplicate rows, and they let one set of SQL read every table the same way.
CREATE OR ALTER VIEW stg.stores AS
SELECT StoreID AS store_id, StoreName AS store_name, City AS city, Province AS province, BusinessUnit AS business_unit,
       Division AS division, FloorAreaSqFt AS floor_area_sqft, CAST(OpeningHour AS INT) AS opening_hour, CAST(ClosingHour AS INT) AS closing_hour
FROM clean.Stores;
GO
CREATE OR ALTER VIEW stg.products AS
SELECT ProductID AS product_id, ProductName AS product_name, Category AS category,
       StandardUnitCostCAD AS standard_unit_cost, ListPriceCAD AS list_price
FROM clean.Products;
GO
CREATE OR ALTER VIEW stg.employees AS
SELECT EmployeeID AS employee_id, SourceRecordID AS source_record_id, StoreID AS store_id, Department AS department,
       JobTitle AS job_title, Gender AS gender, BirthDate AS birth_date, HireDate AS hire_date, EmploymentType AS employment_type,
       HourlyRateCAD AS hourly_rate_cad, Task1ScheduledHours2025 AS task1_scheduled_hours, Task1AbsentHours AS task1_absent_hours,
       Task2ScheduledHours2025 AS task2_scheduled_hours, Task2AbsentHours2025 AS task2_absent_hours, AbsenceValueBasis AS absence_value_basis
FROM clean.Employees;
GO
CREATE OR ALTER VIEW stg.transactions AS
SELECT TransactionID AS transaction_id, StoreID AS store_id, TransactionDateTime AS txn_ts,
       TransactionType AS txn_type, OriginalTransactionID AS original_transaction_id
FROM clean.SalesTransactions;
GO
CREATE OR ALTER VIEW stg.sales_lines AS
SELECT SalesLineID AS sales_line_id, TransactionID AS transaction_id, ProductID AS product_id, Quantity AS quantity,
       UnitPriceCAD AS unit_price_cad, DiscountAmountCAD AS discount_amount_cad, UnitCostAtSaleCAD AS unit_cost_at_sale_cad,
       OriginalSalesLineID AS original_sales_line_id
FROM clean.SalesLineItems;
GO
CREATE OR ALTER VIEW stg.shifts AS
SELECT ShiftID AS shift_id, EmployeeID AS employee_id, StoreID AS store_id, ShiftDate AS shift_date, StartTime AS start_time,
       EndTime AS end_time, ScheduledHours AS scheduled_hours, WorkedHours AS worked_hours, AbsentHours AS absent_hours,
       OvertimeHours AS overtime_hours, LabourCostCAD AS labour_cost_cad
FROM clean.StaffShifts;
GO
CREATE OR ALTER VIEW stg.footfall AS
SELECT StoreID AS store_id, ObservationDate AS obs_date, CAST(HourOfDay AS INT) AS hour_of_day, VisitorCount AS visitor_count
FROM clean.StoreFootfall;
GO

-- De-duplicated working copies (exact duplicate rows collapsed) used by many checks
DROP TABLE IF EXISTS work.txn_d;
SELECT DISTINCT * INTO work.txn_d FROM stg.transactions;
CREATE CLUSTERED INDEX cx_txn_d ON work.txn_d (transaction_id);

DROP TABLE IF EXISTS work.ff_d;
SELECT DISTINCT * INTO work.ff_d FROM stg.footfall;
CREATE CLUSTERED INDEX cx_ff_d ON work.ff_d (store_id, obs_date, hour_of_day);
GO

DROP TABLE IF EXISTS dq.BusinessRuleChecks;
CREATE TABLE dq.BusinessRuleChecks (table_name VARCHAR(40), check_name VARCHAR(80), issue_rows BIGINT, note VARCHAR(200));
GO
INSERT INTO dq.BusinessRuleChecks SELECT 'stores', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.Stores) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'products', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.Products) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.Employees) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.SalesTransactions) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.SalesLineItems) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.StaffShifts) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'raw_row_count', CAST((SELECT COUNT_BIG(*) FROM raw.StoreFootfall) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'stores', 'duplicate_store_id', CAST((SELECT COUNT(*) - COUNT(DISTINCT store_id) FROM stg.stores) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'stores', 'null_store_id', CAST((SELECT COUNT(*) FROM stg.stores WHERE store_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'stores', 'trading_hours_not_8_to_20', CAST((SELECT COUNT(*) FROM stg.stores WHERE ISNULL(opening_hour,-1) <> 8 OR ISNULL(closing_hour,-1) <> 20) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'products', 'duplicate_product_id', CAST((SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM stg.products) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'products', 'invalid_price_or_cost', CAST((SELECT COUNT(*) FROM stg.products WHERE list_price IS NULL OR list_price <= 0 OR standard_unit_cost IS NULL OR standard_unit_cost <= 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'products', 'null_category', CAST((SELECT COUNT(*) FROM stg.products WHERE category IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'products', 'reference_cost_above_list_price', CAST((SELECT COUNT(*) FROM stg.products WHERE standard_unit_cost > list_price) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'duplicate_employee_id', CAST((SELECT COUNT(*) - COUNT(DISTINCT employee_id) FROM stg.employees) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'orphan_store_id', CAST((SELECT COUNT(*) FROM stg.employees e LEFT JOIN stg.stores s ON s.store_id = e.store_id WHERE s.store_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'unparseable_hire_date', CAST((SELECT COUNT(*) FROM dq.ConversionExceptions WHERE table_name = N'Employees' AND column_name = N'HireDate' AND severity = 'ERROR') AS BIGINT), 'from Part 1 conversion exceptions';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'hire_date_after_2025', CAST((SELECT COUNT(*) FROM stg.employees WHERE hire_date > CAST('2025-12-31' AS date)) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'nonpositive_hourly_rate', CAST((SELECT COUNT(*) FROM stg.employees WHERE hourly_rate_cad IS NULL OR hourly_rate_cad <= 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'task2_scheduled_null_or_nonpositive', CAST((SELECT COUNT(*) FROM stg.employees WHERE task2_scheduled_hours IS NULL OR task2_scheduled_hours <= 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'task2_absent_negative_or_above_scheduled', CAST((SELECT COUNT(*) FROM stg.employees WHERE task2_absent_hours < 0 OR task2_absent_hours > task2_scheduled_hours) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'employees', 'task2_scheduled_not_matching_brief_formula', CAST((SELECT COUNT(*) FROM stg.employees
 WHERE ABS(task2_scheduled_hours - ROUND(task1_scheduled_hours *
       (CASE WHEN hire_date < CAST('2025-01-01' AS date) THEN 365
             ELSE DATEDIFF(day, hire_date, CAST('2025-12-31' AS date)) + 1 END) / 365.0 * 4, 0) / 4) > 0.25) AS BIGINT), 'brief: Task1 hours x eligible days / 365, rounded to quarter hour';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'exact_duplicate_rows', CAST((SELECT (SELECT COUNT(*) FROM stg.transactions) - (SELECT COUNT(*) FROM work.txn_d)) AS BIGINT), 'removed by DISTINCT';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'duplicate_ids_after_exact_dedupe', CAST((SELECT COUNT(*) - COUNT(DISTINCT transaction_id) FROM work.txn_d) AS BIGINT), 'same ID, different content';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'null_transaction_id', CAST((SELECT COUNT(*) FROM work.txn_d WHERE transaction_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'unparseable_datetime', CAST((SELECT COUNT(*) FROM work.txn_d WHERE txn_ts IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'date_outside_2025', CAST((SELECT COUNT(*) FROM work.txn_d WHERE txn_ts IS NOT NULL AND YEAR(txn_ts) <> 2025) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'hour_outside_trading_8_to_19', CAST((SELECT COUNT(*) FROM work.txn_d WHERE txn_ts IS NOT NULL AND DATEPART(hour, txn_ts) NOT BETWEEN 8 AND 19) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'type_not_sale_or_return', CAST((SELECT COUNT(*) FROM work.txn_d WHERE txn_type IS NULL OR txn_type NOT IN ('Sale','Return')) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'orphan_store_id', CAST((SELECT COUNT(*) FROM work.txn_d t LEFT JOIN stg.stores s ON s.store_id = t.store_id WHERE s.store_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'sale_with_original_reference', CAST((SELECT COUNT(*) FROM work.txn_d WHERE txn_type = 'Sale' AND original_transaction_id IS NOT NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'return_without_original_reference', CAST((SELECT COUNT(*) FROM work.txn_d WHERE txn_type = 'Return' AND original_transaction_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'return_original_txn_not_found', CAST((SELECT COUNT(*) FROM work.txn_d t LEFT JOIN work.txn_d o ON o.transaction_id = t.original_transaction_id WHERE t.txn_type = 'Return' AND t.original_transaction_id IS NOT NULL AND o.transaction_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'return_original_not_a_sale', CAST((SELECT COUNT(*) FROM work.txn_d t JOIN work.txn_d o ON o.transaction_id = t.original_transaction_id WHERE t.txn_type = 'Return' AND o.txn_type <> 'Sale') AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'return_store_differs_from_original', CAST((SELECT COUNT(*) FROM work.txn_d t JOIN work.txn_d o ON o.transaction_id = t.original_transaction_id WHERE t.txn_type = 'Return' AND t.store_id <> o.store_id) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'return_gap_not_1_to_28_days', CAST((SELECT COUNT(*) FROM work.txn_d t JOIN work.txn_d o ON o.transaction_id = t.original_transaction_id WHERE t.txn_type = 'Return' AND DATEDIFF(day, CAST(o.txn_ts AS date), CAST(t.txn_ts AS date)) NOT BETWEEN 1 AND 28) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'transactions', 'transactions_without_lines', CAST((SELECT COUNT(*) FROM work.txn_d t WHERE NOT EXISTS (SELECT 1 FROM stg.sales_lines l WHERE l.transaction_id = t.transaction_id)) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'duplicate_line_ids', CAST((SELECT COUNT(*) - COUNT(DISTINCT sales_line_id) FROM stg.sales_lines) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'exact_duplicate_rows', CAST((SELECT (SELECT COUNT(*) FROM stg.sales_lines) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM stg.sales_lines) x)) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'null_numeric_fields', CAST((SELECT COUNT(*) FROM stg.sales_lines WHERE quantity IS NULL OR unit_price_cad IS NULL OR discount_amount_cad IS NULL OR unit_cost_at_sale_cad IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'zero_quantity', CAST((SELECT COUNT(*) FROM stg.sales_lines WHERE quantity = 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'nonpositive_unit_price_or_cost', CAST((SELECT COUNT(*) FROM stg.sales_lines WHERE unit_price_cad <= 0 OR unit_cost_at_sale_cad <= 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'orphan_transaction_id', CAST((SELECT COUNT(*) FROM stg.sales_lines l LEFT JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.transaction_id IS NULL) AS BIGINT), 'lines whose transaction is missing';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'orphan_product_id', CAST((SELECT COUNT(*) FROM stg.sales_lines l LEFT JOIN stg.products p ON p.product_id = l.product_id WHERE p.product_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'sale_line_nonpositive_quantity', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Sale' AND l.quantity <= 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'return_line_nonnegative_quantity', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Return' AND l.quantity >= 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'sale_line_negative_discount', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Sale' AND l.discount_amount_cad < 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'return_line_positive_discount', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Return' AND l.discount_amount_cad > 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'sale_discount_exceeds_gross_amount', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Sale' AND l.discount_amount_cad > l.quantity * l.unit_price_cad) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'sale_baskets_not_1_to_4_lines', CAST((SELECT COUNT(*) FROM (SELECT l.transaction_id FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Sale' GROUP BY l.transaction_id HAVING COUNT(*) NOT BETWEEN 1 AND 4) x) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'sale_baskets_with_repeated_product', CAST((SELECT COUNT(*) FROM (SELECT l.transaction_id FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Sale' GROUP BY l.transaction_id HAVING COUNT(*) > COUNT(DISTINCT l.product_id)) x) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'return_txns_not_exactly_one_line', CAST((SELECT COUNT(*) FROM (SELECT l.transaction_id FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id WHERE t.txn_type = 'Return' GROUP BY l.transaction_id HAVING COUNT(*) <> 1) x) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'return_line_missing_original_line', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN work.txn_d t ON t.transaction_id = l.transaction_id LEFT JOIN stg.sales_lines o ON o.sales_line_id = l.original_sales_line_id WHERE t.txn_type = 'Return' AND o.sales_line_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'original_line_returned_more_than_once', CAST((SELECT COUNT(*) FROM (SELECT original_sales_line_id FROM stg.sales_lines WHERE original_sales_line_id IS NOT NULL GROUP BY original_sales_line_id HAVING COUNT(*) > 1) x) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'sales_lines', 'return_price_or_cost_differs_from_original', CAST((SELECT COUNT(*) FROM stg.sales_lines l JOIN stg.sales_lines o ON o.sales_line_id = l.original_sales_line_id WHERE l.unit_price_cad <> o.unit_price_cad OR l.unit_cost_at_sale_cad <> o.unit_cost_at_sale_cad) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'exact_duplicate_rows', CAST((SELECT (SELECT COUNT(*) FROM stg.footfall) - (SELECT COUNT(*) FROM work.ff_d)) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'duplicate_store_date_hour_after_dedupe', CAST((SELECT COUNT(*) FROM (SELECT 1 AS a FROM work.ff_d GROUP BY store_id, obs_date, hour_of_day HAVING COUNT(*) > 1) x) AS BIGINT), 'same key, different count';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'null_visitor_count', CAST((SELECT COUNT(*) FROM work.ff_d WHERE visitor_count IS NULL) AS BIGINT), 'excluded from conversion, never treated as 0';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'negative_visitor_count', CAST((SELECT COUNT(*) FROM work.ff_d WHERE visitor_count < 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'hour_outside_8_to_19', CAST((SELECT COUNT(*) FROM work.ff_d WHERE hour_of_day IS NULL OR hour_of_day NOT BETWEEN 8 AND 19) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'date_null_or_outside_2025', CAST((SELECT COUNT(*) FROM work.ff_d WHERE obs_date IS NULL OR YEAR(obs_date) <> 2025) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'orphan_store_id', CAST((SELECT COUNT(*) FROM work.ff_d f LEFT JOIN stg.stores s ON s.store_id = f.store_id WHERE s.store_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'footfall', 'missing_store_hours_vs_expected', CAST((SELECT (SELECT COUNT(*) FROM stg.stores) * 365 * 12 - (SELECT COUNT(*) FROM (SELECT DISTINCT store_id, obs_date, hour_of_day FROM work.ff_d WHERE obs_date IS NOT NULL AND hour_of_day BETWEEN 8 AND 19) x)) AS BIGINT), '11 stores x 365 days x 12 trading hours';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'duplicate_shift_id', CAST((SELECT COUNT(*) - COUNT(DISTINCT shift_id) FROM stg.shifts) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'duplicate_employee_day', CAST((SELECT COUNT(*) FROM (SELECT 1 AS a FROM stg.shifts GROUP BY employee_id, shift_date HAVING COUNT(*) > 1) x) AS BIGINT), 'brief: max one shift per employee per day';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'orphan_employee_id', CAST((SELECT COUNT(*) FROM stg.shifts s LEFT JOIN stg.employees e ON e.employee_id = s.employee_id WHERE e.employee_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'orphan_store_id', CAST((SELECT COUNT(*) FROM stg.shifts s LEFT JOIN stg.stores st ON st.store_id = s.store_id WHERE st.store_id IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'shift_store_differs_from_employee_home_store', CAST((SELECT COUNT(*) FROM stg.shifts s JOIN stg.employees e ON e.employee_id = s.employee_id WHERE s.store_id <> e.store_id) AS BIGINT), 'dictionary: shift store must equal employee home store (expect 0)';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'date_null_or_outside_2025', CAST((SELECT COUNT(*) FROM stg.shifts WHERE shift_date IS NULL OR YEAR(shift_date) <> 2025) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'time_unparseable', CAST((SELECT COUNT(*) FROM stg.shifts WHERE start_time IS NULL OR end_time IS NULL) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'shift_before_hire_date', CAST((SELECT COUNT(*) FROM stg.shifts s JOIN stg.employees e ON e.employee_id = s.employee_id WHERE s.shift_date < e.hire_date) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'negative_hours', CAST((SELECT COUNT(*) FROM stg.shifts WHERE scheduled_hours < 0 OR absent_hours < 0 OR overtime_hours < 0 OR worked_hours < 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'scheduled_hours_null_or_zero', CAST((SELECT COUNT(*) FROM stg.shifts WHERE scheduled_hours IS NULL OR scheduled_hours = 0) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'absent_exceeds_scheduled', CAST((SELECT COUNT(*) FROM stg.shifts WHERE absent_hours > scheduled_hours) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'worked_hours_formula_mismatch', CAST((SELECT COUNT(*) FROM stg.shifts WHERE ABS(worked_hours - (scheduled_hours - absent_hours + overtime_hours)) > 0.01) AS BIGINT), 'brief: worked = scheduled - absent + overtime';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'clock_duration_differs_from_scheduled_plus_overtime', CAST((SELECT COUNT(*) FROM stg.shifts WHERE ABS(DATEDIFF(minute, start_time, end_time) / 60.0 - (scheduled_hours + overtime_hours)) > 0.01) AS BIGINT), 'dictionary: EndTime includes overtime';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'shift_outside_8_to_20', CAST((SELECT COUNT(*) FROM stg.shifts WHERE start_time < CAST('08:00' AS time) OR end_time > CAST('20:00' AS time)) AS BIGINT), 'info';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'labour_cost_formula_mismatch', CAST((SELECT COUNT(*) FROM stg.shifts s JOIN stg.employees e ON e.employee_id = s.employee_id WHERE ABS(s.labour_cost_cad - ROUND((s.worked_hours - s.overtime_hours) * e.hourly_rate_cad + s.overtime_hours * (SELECT CAST(value AS DECIMAL(9,4)) FROM dq.Assumptions WHERE name = 'overtime_multiplier') * e.hourly_rate_cad, 2)) > 0.01) AS BIGINT), 'brief: regular x rate + OT x 1.5 x rate';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'employees_scheduled_hours_not_reconciling', CAST((SELECT COUNT(*) FROM stg.employees e LEFT JOIN (SELECT employee_id, SUM(scheduled_hours) AS h FROM stg.shifts GROUP BY employee_id) s ON s.employee_id = e.employee_id WHERE ABS(ISNULL(s.h, 0) - e.task2_scheduled_hours) > 0.01) AS BIGINT), 'raw faults should show here';
INSERT INTO dq.BusinessRuleChecks SELECT 'shifts', 'employees_absent_hours_not_reconciling', CAST((SELECT COUNT(*) FROM stg.employees e LEFT JOIN (SELECT employee_id, SUM(absent_hours) AS h FROM stg.shifts GROUP BY employee_id) s ON s.employee_id = e.employee_id WHERE ABS(ISNULL(s.h, 0) - e.task2_absent_hours) > 0.01) AS BIGINT), '';
INSERT INTO dq.BusinessRuleChecks SELECT 'all', 'part1_conversion_errors_logged', CAST((SELECT COUNT(*) FROM dq.ConversionExceptions WHERE severity = 'ERROR') AS BIGINT), 'Part 1 value-level errors (0 = every value fits its type)';
GO

/* ---- Missing values in key columns ---- */
DROP TABLE IF EXISTS dq.NullProfile;
SELECT 'employees' AS table_name, 'task1_absent_hours' AS column_name, COUNT(*) AS null_rows INTO dq.NullProfile FROM stg.employees WHERE task1_absent_hours IS NULL
UNION ALL SELECT 'employees', 'gender', COUNT(*) FROM stg.employees WHERE gender IS NULL
UNION ALL SELECT 'transactions', 'original_transaction_id (blank for Sale)', COUNT(*) FROM stg.transactions WHERE original_transaction_id IS NULL
UNION ALL SELECT 'sales_lines', 'original_sales_line_id (blank for Sale)', COUNT(*) FROM stg.sales_lines WHERE original_sales_line_id IS NULL
UNION ALL SELECT 'footfall', 'visitor_count', COUNT(*) FROM stg.footfall WHERE visitor_count IS NULL;
GO

/* ---- Value inventories that confirm the cleaning rules ---- */
SELECT txn_type, COUNT(*) AS n FROM stg.transactions GROUP BY txn_type ORDER BY n DESC;
SELECT category, COUNT(*) AS products FROM stg.products GROUP BY category ORDER BY category;
SELECT store_id, store_name, city, province FROM stg.stores ORDER BY store_id;
SELECT absence_value_basis, COUNT(*) AS employees FROM stg.employees GROUP BY absence_value_basis;

/* ---- RESULT: read this table first; any issue_rows > 0 needs a cleaning rule in Part 3 ---- */
SELECT table_name, check_name, issue_rows, note
FROM dq.BusinessRuleChecks
ORDER BY CASE WHEN issue_rows > 0 AND note NOT LIKE 'info%' THEN 0 ELSE 1 END, table_name, check_name;
GO

/* The Part 2 intermediates are no longer needed */
DROP TABLE IF EXISTS work.txn_d;
DROP TABLE IF EXISTS work.ff_d;
GO


/* #####################################################################################################
   PART 3 - CLEANING DECISIONS (clean -> core)
   Builds the analysis-ready [core] tables and documents every cleaning decision in dq.cleaning_decisions.
   ##################################################################################################### */
/* =====================================================================
   Part 3: Cleaning (raw and stg are preserved; results go to core.*)
   Principles
     1. Raw tables are never edited. Cleaning = building new tables.
     2. Exact duplicate rows are removed; same-key conflicts keep one row (logged).
     3. Invalid rows are excluded from clean but COUNTED in dq.cleaning_log.
     4. Missing footfall stays NULL (never 0) and is flagged footfall_valid = 0.
     5. Derived measures follow the Task 2 brief formulas exactly.
   NOTE: rules come from the brief + data dictionary + your profile. After running
         Part 2, review dq.BusinessRuleChecks and adjust any rule that looks wrong.
   ===================================================================== */
USE Task2_DataWH;
GO

/* Re-run safety: drop foreign keys left by Part 4 so the clean tables can be rebuilt */
DECLARE @drop NVARCHAR(MAX) = N'';
SELECT @drop += N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(parent_object_id))
              + N' DROP CONSTRAINT ' + QUOTENAME(name) + N';'
FROM sys.foreign_keys WHERE SCHEMA_NAME(schema_id) = N'core';
IF LEN(@drop) > 0 EXEC(@drop);
GO

/* ---------- Dimensions ---------- */
DROP TABLE IF EXISTS core.stores;
SELECT * INTO core.stores FROM stg.stores WHERE store_id IS NOT NULL;

DROP TABLE IF EXISTS core.products;
WITH p AS (
    SELECT DISTINCT * FROM stg.products
    WHERE product_id IS NOT NULL AND list_price > 0 AND standard_unit_cost > 0
), r AS (
    SELECT p.*, ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY product_name) AS rn FROM p
)
SELECT product_id, product_name, category, standard_unit_cost, list_price
INTO core.products FROM r WHERE rn = 1;

DROP TABLE IF EXISTS core.employees;
WITH e AS (
    SELECT DISTINCT * FROM stg.employees
    WHERE employee_id IS NOT NULL AND store_id IN (SELECT store_id FROM core.stores)
), r AS (
    SELECT e.*, ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY source_record_id) AS rn FROM e
)
SELECT employee_id, source_record_id, store_id, department, job_title, gender, birth_date, hire_date,
       employment_type, hourly_rate_cad, task1_scheduled_hours, task1_absent_hours,
       task2_scheduled_hours, task2_absent_hours, absence_value_basis
INTO core.employees FROM r WHERE rn = 1;
GO

/* ---------- Transactions ----------
   Keep: exact duplicates removed; Sale/Return only (brief: confirmed); valid 2025 timestamp
   inside 08:00-19:59; known store; one row per TransactionID (earliest timestamp wins). */
DROP TABLE IF EXISTS core.transactions;
WITH d AS (SELECT DISTINCT * FROM stg.transactions),
f AS (
    SELECT d.*, ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY txn_ts) AS rn
    FROM d
    WHERE transaction_id IS NOT NULL
      AND txn_ts IS NOT NULL
      AND YEAR(txn_ts) = 2025
      AND DATEPART(hour, txn_ts) BETWEEN 8 AND 19
      AND txn_type IN ('Sale', 'Return')
      AND store_id IN (SELECT store_id FROM core.stores)
)
SELECT f.transaction_id, f.store_id, f.txn_ts,
       CAST(f.txn_ts AS date)        AS txn_date,
       DATEPART(hour, f.txn_ts)      AS txn_hour,
       w.iso_weekday,                                   -- 1 = Monday ... 7 = Sunday
       CHOOSE(w.iso_weekday, 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') AS weekday_name,
       MONTH(f.txn_ts)               AS txn_month,
       f.txn_type, f.original_transaction_id
INTO core.transactions
FROM f
CROSS APPLY (SELECT (DATEDIFF(day, '1900-01-01', CAST(f.txn_ts AS date)) % 7) + 1 AS iso_weekday) w
WHERE f.rn = 1;
GO
ALTER TABLE core.transactions ALTER COLUMN transaction_id NVARCHAR(30) NOT NULL;
CREATE UNIQUE CLUSTERED INDEX ux_clean_txn ON core.transactions (transaction_id);
GO

/* ---------- Sales lines ----------
   Inner joins to core.transactions / core.products remove orphans.
   Sign rules (brief + dictionary): Sale qty > 0 and discount >= 0; Return qty < 0 and discount <= 0;
   unit price and cost positive on both.
   Net line sales = Quantity x UnitPrice - Discount   (discount is a LINE amount)
   Line COGS      = Quantity x UnitCostAtSale          (historical cost, not Products.StandardUnitCost) */
DROP TABLE IF EXISTS core.sales_lines;
WITH l AS (SELECT DISTINCT * FROM stg.sales_lines),
j AS (
    SELECT l.*, ROW_NUMBER() OVER (PARTITION BY l.sales_line_id ORDER BY l.sales_line_id) AS rn,
           t.store_id, t.txn_ts, t.txn_date, t.txn_hour, t.iso_weekday, t.weekday_name, t.txn_month, t.txn_type, p.category
    FROM l
    JOIN core.transactions t ON t.transaction_id = l.transaction_id
    JOIN core.products     p ON p.product_id     = l.product_id
    WHERE l.sales_line_id IS NOT NULL
      AND l.quantity IS NOT NULL AND l.quantity <> 0
      AND l.unit_price_cad > 0 AND l.unit_cost_at_sale_cad > 0
      AND l.discount_amount_cad IS NOT NULL
      AND ( (t.txn_type = 'Sale'   AND l.quantity > 0 AND l.discount_amount_cad >= 0)
         OR (t.txn_type = 'Return' AND l.quantity < 0 AND l.discount_amount_cad <= 0) )
)
SELECT sales_line_id, transaction_id, store_id, txn_ts, txn_date, txn_hour, iso_weekday, weekday_name, txn_month, txn_type,
       product_id, category, quantity, unit_price_cad, discount_amount_cad, unit_cost_at_sale_cad, original_sales_line_id,
       CAST(ROUND(quantity * unit_price_cad - discount_amount_cad, 2) AS DECIMAL(18,2))                                   AS net_sales_cad,
       CAST(ROUND(quantity * unit_cost_at_sale_cad, 2) AS DECIMAL(18,2))                                                  AS cogs_cad,
       CAST(ROUND(quantity * unit_price_cad - discount_amount_cad - quantity * unit_cost_at_sale_cad, 2) AS DECIMAL(18,2)) AS gross_profit_cad
INTO core.sales_lines
FROM j WHERE rn = 1;
GO
ALTER TABLE core.sales_lines ALTER COLUMN sales_line_id NVARCHAR(30) NOT NULL;
CREATE UNIQUE CLUSTERED INDEX ux_clean_lines ON core.sales_lines (sales_line_id);
CREATE INDEX ix_clean_lines_txn ON core.sales_lines (transaction_id);
GO

/* A transaction counts as a purchase only if it has at least one valid line */
-- Guarded so the part can be re-run: the column is added only if it is not already there
IF COL_LENGTH(N'core.transactions', N'has_valid_lines') IS NULL
    ALTER TABLE core.transactions ADD has_valid_lines BIT NOT NULL CONSTRAINT df_txn_hvl DEFAULT (0);
GO
UPDATE t SET has_valid_lines = 1
FROM core.transactions t
WHERE EXISTS (SELECT 1 FROM core.sales_lines l WHERE l.transaction_id = t.transaction_id);
GO

/* ---------- Shifts ----------
   Worked hours and labour cost are RECALCULATED with the brief formulas (source kept in source_* columns):
     worked = scheduled - absent + overtime
     labour = (scheduled - absent) x rate + overtime x 1.5 x rate, rounded to cents per shift
   Data dictionary: EndTime INCLUDES overtime -> scheduled end = EndTime - overtime.
   One shift per employee per day -> keep lowest ShiftID if duplicated. */
DROP TABLE IF EXISTS core.shifts;
WITH s AS (SELECT DISTINCT * FROM stg.shifts),
j AS (
    SELECT s.*, e.hourly_rate_cad, m.ot_mult,
           ROW_NUMBER() OVER (PARTITION BY s.employee_id, s.shift_date ORDER BY s.shift_id) AS rn
    FROM s
    JOIN core.employees e  ON e.employee_id = s.employee_id
    JOIN core.stores    st ON st.store_id   = s.store_id
    CROSS JOIN (SELECT CAST(value AS DECIMAL(9,4)) AS ot_mult FROM dq.Assumptions WHERE name = 'overtime_multiplier') m   -- 1.5 unless changed in Part 0
    WHERE s.shift_id IS NOT NULL
      AND s.shift_date BETWEEN '2025-01-01' AND '2025-12-31'
      AND s.shift_date >= e.hire_date
      AND s.scheduled_hours > 0 AND s.absent_hours >= 0 AND s.overtime_hours >= 0
      AND s.absent_hours <= s.scheduled_hours
      AND s.start_time IS NOT NULL AND s.end_time IS NOT NULL
)
SELECT shift_id, employee_id, store_id, shift_date, start_time, end_time,
       CAST(DATEPART(hour, start_time) + DATEPART(minute, start_time) / 60.0 AS DECIMAL(9,6)) AS start_hr,
       CAST(DATEPART(hour, end_time)   + DATEPART(minute, end_time)   / 60.0 AS DECIMAL(9,6)) AS end_hr,           -- includes overtime
       CAST(DATEPART(hour, end_time)   + DATEPART(minute, end_time)   / 60.0 - overtime_hours AS DECIMAL(9,6)) AS sched_end_hr,
       scheduled_hours, absent_hours, overtime_hours,
       CAST(scheduled_hours - absent_hours + overtime_hours AS DECIMAL(9,4)) AS worked_hours,
       CAST(ROUND((scheduled_hours - absent_hours) * hourly_rate_cad + overtime_hours * ot_mult * hourly_rate_cad, 2) AS DECIMAL(12,2)) AS labour_cost_cad,
       worked_hours AS source_worked_hours, labour_cost_cad AS source_labour_cost_cad
INTO core.shifts
FROM j WHERE rn = 1;
GO
ALTER TABLE core.shifts ALTER COLUMN shift_id NVARCHAR(30) NOT NULL;
CREATE UNIQUE CLUSTERED INDEX ux_clean_shifts ON core.shifts (shift_id);
CREATE INDEX ix_clean_shifts_emp ON core.shifts (employee_id, shift_date);
GO

/* ---------- Footfall ----------
   Exact duplicates removed; remaining same-key conflicts keep the larger valid count.
   NULL / negative visitor counts stay as NULL with footfall_valid = 0 (excluded from conversion). */
DROP TABLE IF EXISTS core.footfall;
SELECT store_id, obs_date, hour_of_day,
       MAX(CASE WHEN visitor_count >= 0 THEN visitor_count END) AS visitor_count,
       CASE WHEN MAX(CASE WHEN visitor_count >= 0 THEN visitor_count END) IS NOT NULL THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS footfall_valid
INTO core.footfall
FROM (SELECT DISTINCT * FROM stg.footfall) d
WHERE obs_date BETWEEN '2025-01-01' AND '2025-12-31'
  AND hour_of_day BETWEEN 8 AND 19
  AND store_id IN (SELECT store_id FROM core.stores)
GROUP BY store_id, obs_date, hour_of_day;
GO

/* ---------- STOP CHECK: no core table may be empty ---------- */
DECLARE @empty NVARCHAR(400) = (
    SELECT STRING_AGG(x.t, N', ') FROM (
        SELECT N'core.stores' AS t WHERE NOT EXISTS (SELECT 1 FROM core.stores)
        UNION ALL SELECT N'core.products'     WHERE NOT EXISTS (SELECT 1 FROM core.products)
        UNION ALL SELECT N'core.employees'    WHERE NOT EXISTS (SELECT 1 FROM core.employees)
        UNION ALL SELECT N'core.transactions' WHERE NOT EXISTS (SELECT 1 FROM core.transactions)
        UNION ALL SELECT N'core.sales_lines'  WHERE NOT EXISTS (SELECT 1 FROM core.sales_lines)
        UNION ALL SELECT N'core.shifts'       WHERE NOT EXISTS (SELECT 1 FROM core.shifts)
        UNION ALL SELECT N'core.footfall'     WHERE NOT EXISTS (SELECT 1 FROM core.footfall)
    ) x);
IF @empty IS NOT NULL
BEGIN
    DECLARE @msg NVARCHAR(600) = CONCAT(N'Part 3 stop: empty core table(s): ', @empty, N'. Values probably became NULL in Part 1: check dq.ConversionExceptions and the stg views.');
    THROW 50010, @msg, 1;
END;
GO

/* ---------- Cleaning log: rows in vs rows kept ---------- */
DROP TABLE IF EXISTS dq.cleaning_log;
SELECT table_name, raw_rows, clean_rows, raw_rows - clean_rows AS rows_removed
INTO dq.cleaning_log
FROM (
    SELECT 'stores' AS table_name,        (SELECT COUNT_BIG(*) FROM raw.Stores) AS raw_rows,            (SELECT COUNT_BIG(*) FROM core.stores) AS clean_rows
    UNION ALL SELECT 'products',          (SELECT COUNT_BIG(*) FROM raw.Products),                      (SELECT COUNT_BIG(*) FROM core.products)
    UNION ALL SELECT 'employees',         (SELECT COUNT_BIG(*) FROM raw.Employees),                     (SELECT COUNT_BIG(*) FROM core.employees)
    UNION ALL SELECT 'transactions',      (SELECT COUNT_BIG(*) FROM raw.SalesTransactions),             (SELECT COUNT_BIG(*) FROM core.transactions)
    UNION ALL SELECT 'sales_lines',       (SELECT COUNT_BIG(*) FROM raw.SalesLineItems),                (SELECT COUNT_BIG(*) FROM core.sales_lines)
    UNION ALL SELECT 'shifts',            (SELECT COUNT_BIG(*) FROM raw.StaffShifts),                   (SELECT COUNT_BIG(*) FROM core.shifts)
    UNION ALL SELECT 'footfall',          (SELECT COUNT_BIG(*) FROM raw.StoreFootfall),                 (SELECT COUNT_BIG(*) FROM core.footfall)
) x;

DROP TABLE IF EXISTS dq.cleaning_detail;
SELECT item, n INTO dq.cleaning_detail FROM (
    SELECT 'transactions: exact duplicate rows removed' AS item,
           (SELECT COUNT_BIG(*) FROM stg.transactions) - (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT * FROM stg.transactions) x) AS n
    UNION ALL SELECT 'footfall: exact duplicate rows removed',
           (SELECT COUNT_BIG(*) FROM stg.footfall) - (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT * FROM stg.footfall) x)
    UNION ALL SELECT 'footfall: store-hours with NULL/invalid visitors (kept, excluded from conversion)',
           (SELECT COUNT_BIG(*) FROM core.footfall WHERE footfall_valid = 0)
    UNION ALL SELECT 'transactions: kept but with no valid lines (excluded from purchase counts)',
           (SELECT COUNT_BIG(*) FROM core.transactions WHERE has_valid_lines = 0)
    UNION ALL SELECT 'shifts: worked hours differ from brief formula in source',
           (SELECT COUNT_BIG(*) FROM core.shifts WHERE ABS(worked_hours - source_worked_hours) > 0.01)
    UNION ALL SELECT 'shifts: labour cost differs from brief formula in source',
           (SELECT COUNT_BIG(*) FROM core.shifts WHERE ABS(labour_cost_cad - source_labour_cost_cad) > 0.01)
) y;

/* ---------- Cleaning decisions (documentation that goes into the report) ---------- */
DROP TABLE IF EXISTS dq.cleaning_decisions;
CREATE TABLE dq.cleaning_decisions (table_name NVARCHAR(30), issue VARCHAR(120), decision VARCHAR(200), rationale VARCHAR(250));
INSERT INTO dq.cleaning_decisions VALUES
 ('all',          'Raw preservation',               'Raw imported by the Import Flat File wizard into schema raw; never modified', 'Auditability; required by brief'),
 ('transactions', 'Exact duplicate rows',           'Removed with DISTINCT',                                                      'Duplicates would double count baskets and conversion'),
 ('transactions', 'Same ID, conflicting content',   'Keep earliest timestamp row; counted in audit',                              'TransactionID must be unique'),
 ('transactions', 'Unparseable / non-2025 timestamps, outside 08-20', 'Excluded and logged',                                      'Cannot be placed in a store-hour or reporting year'),
 ('transactions', 'Types other than Sale/Return',   'Excluded',                                                                   'Brief: only confirmed Sale and Return transactions count'),
 ('sales_lines',  'Orphan transaction / product',   'Excluded via inner join',                                                    'No store, time or category to attribute to'),
 ('sales_lines',  'Wrong sign, zero qty, non-positive price/cost', 'Excluded',                                                    'Violates brief sign rules'),
 ('sales_lines',  'Net sales, COGS',                'Recomputed: qty x price - discount; qty x UnitCostAtSale',                   'One consistent definition; historical cost'),
 ('shifts',       'Duplicate employee-day',         'Keep lowest ShiftID',                                                        'Brief: at most one shift per employee per day'),
 ('shifts',       'Worked hours, labour cost',      'Recalculated from brief formulas; source kept in source_* columns',          'One consistent definition'),
 ('shifts',       'Shifts before hire / outside 2025','Excluded',                                                                  'Brief: no shifts before hire dates'),
 ('shifts',       'EndTime includes overtime',      'Scheduled end = EndTime - OvertimeHours',                                    'Data dictionary; needed for hourly coverage'),
 ('footfall',     'Exact duplicate rows',           'Removed',                                                                    'Visitors would be double counted'),
 ('footfall',     'NULL visitor count',             'Kept as NULL, footfall_valid = 0; hour excluded from conversion',            'Brief: treating missing as zero inflates conversion'),
 ('all',          'Float columns created by the Import Wizard', 'Read FLOAT directly into DECIMAL in Part 1, not through scientific-notation text', 'SQL Server cannot parse that text; every price, rate and hour had become NULL and core tables were empty'),
 ('shifts',       'Overtime rate and unpaid absence', 'Overtime x 1.5 (dq.Assumptions); absent hours unpaid; 258,796 of 258,799 source shifts follow this rule', 'Tested against LabourCostCAD; remaining differences show in dq.BusinessRuleChecks (labour_cost_formula_mismatch)'),
 ('all',          'Empty core table after cleaning', 'Part 3 stops with an error if any core table has 0 rows',                   'A silent empty table made every later total zero');
GO

SELECT * FROM dq.cleaning_log ORDER BY table_name;
SELECT * FROM dq.cleaning_detail;


/* #####################################################################################################
   PART 4 - TABLE RELATIONSHIPS AND RECONCILIATION (core)
   Checks keys and orphans, reconciles shifts to employee totals, then enforces PRIMARY KEY / FOREIGN KEY constraints.
   ##################################################################################################### */
/* =====================================================================
   Part 4: Table relationships and reconciliation checks (clean layer)

   Logical model (grain in brackets)
     stores (1) --< employees (1) --< shifts           [employee x day]
     stores (1) --< shifts / transactions / footfall   [store x date x hour]
     transactions (1) --< sales_lines (many) >-- (1) products
     returns: sales_lines.original_sales_line_id -> sales_lines.sales_line_id
   Every orphan / duplicate count below should be 0 BEFORE the constraints are added.
   Adding PRIMARY KEY / FOREIGN KEY constraints at the end makes SQL Server enforce the model.
   ===================================================================== */
USE Task2_DataWH;
GO

/* ---------- 1 to 4. The relationship checks are VIEWS (no stored copies; they always reflect the current core tables) ---------- */
DROP TABLE IF EXISTS dq.key_checks;               -- tables created by the earlier version
DROP TABLE IF EXISTS dq.fk_checks;
DROP TABLE IF EXISTS dq.basket_profile;
DROP TABLE IF EXISTS dq.reconciliation_employee;
GO

/* ---------- 1. Primary-key uniqueness ---------- */
CREATE OR ALTER VIEW dq.v_key_checks
AS
SELECT check_name, violations FROM (
    SELECT 'core.stores.store_id' AS check_name, COUNT(*) - COUNT(DISTINCT store_id) AS violations FROM core.stores
    UNION ALL SELECT 'core.products.product_id',         COUNT(*) - COUNT(DISTINCT product_id)      FROM core.products
    UNION ALL SELECT 'core.employees.employee_id',       COUNT(*) - COUNT(DISTINCT employee_id)     FROM core.employees
    UNION ALL SELECT 'core.transactions.transaction_id', COUNT(*) - COUNT(DISTINCT transaction_id)  FROM core.transactions
    UNION ALL SELECT 'core.sales_lines.sales_line_id',   COUNT(*) - COUNT(DISTINCT sales_line_id)   FROM core.sales_lines
    UNION ALL SELECT 'core.shifts.shift_id',             COUNT(*) - COUNT(DISTINCT shift_id)        FROM core.shifts
    UNION ALL SELECT 'core.shifts (employee_id, shift_date)',
           (SELECT COUNT(*) FROM core.shifts) - (SELECT COUNT(*) FROM (SELECT DISTINCT employee_id, shift_date FROM core.shifts) a)
    UNION ALL SELECT 'core.footfall (store_id, obs_date, hour_of_day)',
           (SELECT COUNT(*) FROM core.footfall) - (SELECT COUNT(*) FROM (SELECT DISTINCT store_id, obs_date, hour_of_day FROM core.footfall) b)
) k;
GO

/* ---------- 2. Foreign keys (orphans) ---------- */
CREATE OR ALTER VIEW dq.v_fk_checks
AS
SELECT relationship, orphan_rows FROM (
    SELECT 'employees.store_id -> stores' AS relationship, COUNT(*) AS orphan_rows
      FROM core.employees e LEFT JOIN core.stores s ON s.store_id = e.store_id WHERE s.store_id IS NULL
    UNION ALL SELECT 'shifts.employee_id -> employees', COUNT(*)
      FROM core.shifts x LEFT JOIN core.employees e ON e.employee_id = x.employee_id WHERE e.employee_id IS NULL
    UNION ALL SELECT 'shifts.store_id -> stores', COUNT(*)
      FROM core.shifts x LEFT JOIN core.stores s ON s.store_id = x.store_id WHERE s.store_id IS NULL
    UNION ALL SELECT 'transactions.store_id -> stores', COUNT(*)
      FROM core.transactions t LEFT JOIN core.stores s ON s.store_id = t.store_id WHERE s.store_id IS NULL
    UNION ALL SELECT 'sales_lines.transaction_id -> transactions', COUNT(*)
      FROM core.sales_lines l LEFT JOIN core.transactions t ON t.transaction_id = l.transaction_id WHERE t.transaction_id IS NULL
    UNION ALL SELECT 'sales_lines.product_id -> products', COUNT(*)
      FROM core.sales_lines l LEFT JOIN core.products p ON p.product_id = l.product_id WHERE p.product_id IS NULL
    UNION ALL SELECT 'footfall.store_id -> stores', COUNT(*)
      FROM core.footfall f LEFT JOIN core.stores s ON s.store_id = f.store_id WHERE s.store_id IS NULL
    UNION ALL SELECT 'return lines: original_sales_line_id -> sales_lines', COUNT(*)
      FROM core.sales_lines r LEFT JOIN core.sales_lines o ON o.sales_line_id = r.original_sales_line_id
      WHERE r.txn_type = 'Return' AND o.sales_line_id IS NULL
    UNION ALL SELECT 'return txns: original_transaction_id -> sale transactions', COUNT(*)
      FROM core.transactions r LEFT JOIN core.transactions o ON o.transaction_id = r.original_transaction_id AND o.txn_type = 'Sale'
      WHERE r.txn_type = 'Return' AND o.transaction_id IS NULL
    UNION ALL SELECT 'shifts.store_id = employee home store (mismatches)', COUNT(*)
      FROM core.shifts x JOIN core.employees e ON e.employee_id = x.employee_id WHERE x.store_id <> e.store_id
) f;
GO

/* ---------- 3. Cardinality: joins must not fan out ---------- */
CREATE OR ALTER VIEW dq.v_basket_profile
AS
SELECT txn_type, COUNT(*) AS transactions, MIN(n) AS min_lines, MAX(n) AS max_lines, CAST(AVG(n * 1.0) AS DECIMAL(6,2)) AS avg_lines
FROM (SELECT t.transaction_id, t.txn_type, COUNT(*) AS n
      FROM core.transactions t JOIN core.sales_lines l ON l.transaction_id = t.transaction_id
      GROUP BY t.transaction_id, t.txn_type) b
GROUP BY txn_type;
GO

/* ---------- 4. Reconcile shifts to each employee's Task 2 scheduled and absent hours ---------- */
CREATE OR ALTER VIEW dq.v_reconciliation_employee
AS
SELECT e.employee_id, e.store_id, e.hire_date,
       e.task2_scheduled_hours,
       ISNULL(s.sched, 0)                                AS shift_scheduled_hours,
       ISNULL(s.sched, 0) - e.task2_scheduled_hours      AS sched_diff,
       e.task2_absent_hours,
       ISNULL(s.absent, 0)                               AS shift_absent_hours,
       ISNULL(s.absent, 0) - e.task2_absent_hours        AS absent_diff
FROM core.employees e
LEFT JOIN (SELECT employee_id, SUM(scheduled_hours) AS sched, SUM(absent_hours) AS absent
           FROM core.shifts GROUP BY employee_id) s ON s.employee_id = e.employee_id;
GO

SELECT COUNT(*) AS employees,
       SUM(CASE WHEN ABS(sched_diff)  > 0.01 THEN 1 ELSE 0 END) AS scheduled_hours_mismatch,
       SUM(CASE WHEN ABS(absent_diff) > 0.01 THEN 1 ELSE 0 END) AS absent_hours_mismatch,
       SUM(shift_scheduled_hours)  AS total_shift_scheduled,
       SUM(task2_scheduled_hours)  AS total_employee_scheduled
FROM dq.v_reconciliation_employee;

-- Worst offenders (empty if the reconciliation passes)
SELECT TOP (25) * FROM dq.v_reconciliation_employee
WHERE ABS(sched_diff) > 0.01 OR ABS(absent_diff) > 0.01
ORDER BY ABS(sched_diff) + ABS(absent_diff) DESC;

/* ---------- 5. Summary: expect zero violations everywhere ---------- */
SELECT 'key violations' AS check_group, SUM(violations) AS total FROM dq.v_key_checks
UNION ALL SELECT 'orphan / mismatch references', SUM(orphan_rows) FROM dq.v_fk_checks;
SELECT * FROM dq.v_fk_checks ORDER BY orphan_rows DESC;
SELECT * FROM dq.v_basket_profile;
GO

/* ---------- 6. Enforce the relationships in the database (PK / FK constraints) ----------
   RUN THIS SECTION ONLY WHEN SECTION 5 SHOWS ZERO. A failing constraint = an orphan to investigate. */
ALTER TABLE core.stores       ALTER COLUMN store_id    NVARCHAR(30) NOT NULL;
ALTER TABLE core.products     ALTER COLUMN product_id  NVARCHAR(30) NOT NULL;
ALTER TABLE core.employees    ALTER COLUMN employee_id NVARCHAR(30) NOT NULL;
ALTER TABLE core.footfall     ALTER COLUMN store_id    NVARCHAR(30) NOT NULL;
ALTER TABLE core.footfall     ALTER COLUMN obs_date    DATE        NOT NULL;
ALTER TABLE core.footfall     ALTER COLUMN hour_of_day INT         NOT NULL;
GO
ALTER TABLE core.stores       ADD CONSTRAINT pk_stores       PRIMARY KEY (store_id);
ALTER TABLE core.products     ADD CONSTRAINT pk_products     PRIMARY KEY (product_id);
ALTER TABLE core.employees    ADD CONSTRAINT pk_employees    PRIMARY KEY (employee_id);
ALTER TABLE core.footfall     ADD CONSTRAINT pk_footfall     PRIMARY KEY (store_id, obs_date, hour_of_day);
-- transactions, sales_lines, shifts already have unique clustered indexes on their IDs; promote to PKs:
DROP INDEX ux_clean_txn    ON core.transactions;
DROP INDEX ux_clean_lines  ON core.sales_lines;
DROP INDEX ux_clean_shifts ON core.shifts;
ALTER TABLE core.transactions ADD CONSTRAINT pk_transactions PRIMARY KEY CLUSTERED (transaction_id);
ALTER TABLE core.sales_lines  ADD CONSTRAINT pk_sales_lines  PRIMARY KEY CLUSTERED (sales_line_id);
ALTER TABLE core.shifts       ADD CONSTRAINT pk_shifts       PRIMARY KEY CLUSTERED (shift_id);
GO
ALTER TABLE core.employees    WITH CHECK ADD CONSTRAINT fk_emp_store   FOREIGN KEY (store_id)       REFERENCES core.stores (store_id);
ALTER TABLE core.shifts       WITH CHECK ADD CONSTRAINT fk_shift_emp   FOREIGN KEY (employee_id)    REFERENCES core.employees (employee_id);
ALTER TABLE core.shifts       WITH CHECK ADD CONSTRAINT fk_shift_store FOREIGN KEY (store_id)       REFERENCES core.stores (store_id);
ALTER TABLE core.transactions WITH CHECK ADD CONSTRAINT fk_txn_store   FOREIGN KEY (store_id)       REFERENCES core.stores (store_id);
ALTER TABLE core.sales_lines  WITH CHECK ADD CONSTRAINT fk_line_txn    FOREIGN KEY (transaction_id) REFERENCES core.transactions (transaction_id);
ALTER TABLE core.sales_lines  WITH CHECK ADD CONSTRAINT fk_line_prod   FOREIGN KEY (product_id)     REFERENCES core.products (product_id);
ALTER TABLE core.footfall     WITH CHECK ADD CONSTRAINT fk_ff_store    FOREIGN KEY (store_id)       REFERENCES core.stores (store_id);
GO

-- Proof the constraints exist (this list is evidence for the report)
SELECT OBJECT_SCHEMA_NAME(parent_object_id) + '.' + OBJECT_NAME(parent_object_id) AS child_table, name AS foreign_key,
       OBJECT_SCHEMA_NAME(referenced_object_id) + '.' + OBJECT_NAME(referenced_object_id) AS parent_table, is_not_trusted
FROM sys.foreign_keys WHERE SCHEMA_NAME(schema_id) = 'core' ORDER BY child_table;


/* #####################################################################################################
   PART 5 - METRIC MARTS WITH NO DOUBLE COUNTING (core -> mart)
   Aggregates each fact table to its own grain, joins on a calendar spine, calculates consistent measures, proves reconciliation.
   ##################################################################################################### */
/* =====================================================================
   Part 5: Build mart tables (these feed Power BI)

   HOW DOUBLE COUNTING IS PREVENTED
     The fact tables have different grains:
       sales lines -> many per transaction;  shifts -> one per employee per day;
       footfall    -> one per store per hour.
     Joining them directly would multiply rows (a shift would repeat for every sales
     line in its store-day, and so on). Instead:
       1. Aggregate EACH fact table to the common grain  store x date x hour
          (or store x date for labour) in its own step (work.* tables).
       2. Join only those aggregates to a calendar spine (every store x date x hour).
          Each aggregate has at most ONE row per key, so the join cannot fan out.
       3. Prove it: Section 11 reconciles every mart total back to the clean tables.
     Category appears only in an additive money mart. Distinct transaction counts are
     NEVER summed across categories (one basket spans several categories).

   MEASURE DEFINITIONS (from the brief)
     net sales            = SUM(qty x price - discount) over Sale AND Return lines
     gross profit         = net sales - SUM(qty x UnitCostAtSale)
     sales per worked hr  = net sales / worked hours (incl. overtime)
     labour cost %        = labour cost / net sales
     absence rate         = absent hours / scheduled hours
     overtime share       = overtime hours / worked hours
     avg purchase value   = Sale-only revenue / distinct Sale transactions
     conversion           = distinct Sale transactions / visitors, on hours with VALID footfall only
   Aggregate rates are computed from summed numerators and denominators (never averages of rates).
   ===================================================================== */
USE Task2_DataWH;
GO

/* STOP CHECKS: the hourly spine assumes 08:00-20:00 trading in a 365-day year, and the marts need data in the core tables */
IF EXISTS (SELECT 1 FROM core.stores WHERE opening_hour IS NULL OR closing_hour IS NULL OR opening_hour <> 8 OR closing_hour <> 20)
    THROW 50030, N'Part 5 stop: a store does not trade 08:00-20:00. The hourly spine and the hour 8-19 filters assume it; review core.stores first.', 1;
IF NOT EXISTS (SELECT 1 FROM core.sales_lines) OR NOT EXISTS (SELECT 1 FROM core.shifts) OR NOT EXISTS (SELECT 1 FROM core.footfall)
    THROW 50031, N'Part 5 stop: core.sales_lines, core.shifts or core.footfall is empty. Re-run Parts 1 to 3 and check dq.ConversionExceptions.', 1;
GO

/* ---------- 1. Dimensions ---------- */
DROP TABLE IF EXISTS mart.dim_store;
SELECT store_id, store_name, city, province, business_unit, division, floor_area_sqft INTO mart.dim_store FROM core.stores;

-- mart.dim_product was removed: category already sits in the category mart and Power BI does not need a product table
DROP TABLE IF EXISTS mart.dim_product;

DROP TABLE IF EXISTS mart.dim_date;
WITH n AS (
    SELECT TOP (365) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b
), d AS (
    SELECT DATEADD(day, i, CAST('2025-01-01' AS date)) AS date_key FROM n
)
SELECT d.date_key,
       MONTH(d.date_key)                                   AS month_num,
       CHOOSE(MONTH(d.date_key),'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec') AS month_name,
       DATEPART(quarter, d.date_key)                       AS quarter_num,
       w.iso_weekday,                                      -- 1 = Mon ... 7 = Sun
       CHOOSE(w.iso_weekday,'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') AS weekday_name,
       CASE WHEN w.iso_weekday >= 6 THEN 1 ELSE 0 END      AS is_weekend,
       DATEPART(iso_week, d.date_key)                      AS iso_week
INTO mart.dim_date
FROM d CROSS APPLY (SELECT (DATEDIFF(day, '1900-01-01', d.date_key) % 7) + 1 AS iso_weekday) w;
GO

/* ---------- 2. Calendar spine: every store x date x trading hour (11 x 365 x 12) ---------- */
DROP TABLE IF EXISTS work.spine;
SELECT s.store_id, d.date_key AS trade_date, d.month_num, d.iso_weekday, d.weekday_name, h.hour_of_day
INTO work.spine
FROM mart.dim_store s
CROSS JOIN mart.dim_date d
CROSS JOIN (VALUES (8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19)) h(hour_of_day);
GO

/* ---------- 3. Sales aggregated to store x date x hour ----------
   Returns are dated by the RETURN transaction (when the refund happened). */
DROP TABLE IF EXISTS work.sales_h;
SELECT store_id, txn_date AS trade_date, txn_hour AS hour_of_day,
       SUM(net_sales_cad)    AS net_sales_cad,
       SUM(cogs_cad)         AS cogs_cad,
       SUM(gross_profit_cad) AS gross_profit_cad,
       SUM(CASE WHEN txn_type = 'Sale'   THEN net_sales_cad ELSE 0 END) AS sale_revenue_cad,
       SUM(CASE WHEN txn_type = 'Return' THEN net_sales_cad ELSE 0 END) AS return_value_cad,
       SUM(CASE WHEN txn_type = 'Sale'   THEN quantity ELSE 0 END)      AS units_sold,
       COUNT(DISTINCT CASE WHEN txn_type = 'Sale'   THEN transaction_id END) AS sale_txns,
       COUNT(DISTINCT CASE WHEN txn_type = 'Return' THEN transaction_id END) AS return_txns
INTO work.sales_h
FROM core.sales_lines
GROUP BY store_id, txn_date, txn_hour;
GO

/* ---------- 4. Hourly staff coverage (an ESTIMATE: absence timing inside a shift is unknown) ----------
   Base method (brief): spread regular worked time proportionally over the scheduled interval and
   place overtime immediately after the scheduled end.
   Data dictionary: EndTime INCLUDES overtime, so scheduled end = EndTime - OvertimeHours
   (core.shifts.sched_end_hr); overtime occupies [sched end, EndTime).
     overlap(a,b,h) = time inside hour [h, h+1) that falls within [a, b)
     scheduled presence = overlap(start, sched_end, h)
     base regular       = scheduled presence x (scheduled - absent) / scheduled
     overtime           = overlap(sched_end, end, h)
   Sensitivity scenarios for the SAME absent hours:
     front: employee absent at the START of the shift -> present in [start + absent, sched_end)
     back : employee absent at the END of the shift   -> present in [start, sched_end - absent)
   If conclusions hold under all three, they do not depend on the timing assumption.
   Overtime after 20:00 is outside trading hours: it stays in labour totals, not in hourly coverage. */
DROP TABLE IF EXISTS work.cov_h;
WITH hrs AS (SELECT hour_of_day FROM (VALUES (8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19)) v(hour_of_day)),
ov AS (
    SELECT s.store_id, s.shift_date AS trade_date, h.hour_of_day, s.scheduled_hours AS sch, s.absent_hours AS ab,
        GREATEST(0, LEAST(s.sched_end_hr, h.hour_of_day + 1)         - GREATEST(s.start_hr, h.hour_of_day))         AS o_sched,
        GREATEST(0, LEAST(s.sched_end_hr, h.hour_of_day + 1)         - GREATEST(s.start_hr + s.absent_hours, h.hour_of_day)) AS o_front,
        GREATEST(0, LEAST(s.sched_end_hr - s.absent_hours, h.hour_of_day + 1) - GREATEST(s.start_hr, h.hour_of_day)) AS o_back,
        GREATEST(0, LEAST(s.end_hr, h.hour_of_day + 1)               - GREATEST(s.sched_end_hr, h.hour_of_day))     AS o_ot
    FROM core.shifts s CROSS JOIN hrs h
)
SELECT store_id, trade_date, hour_of_day,
       CAST(SUM(o_sched) AS DECIMAL(12,4))                          AS scheduled_staff_hours,     -- as rostered, ignoring absence
       CAST(SUM(o_sched * (sch - ab) / sch) AS DECIMAL(12,4))       AS regular_staff_hours_base,  -- proportional spread
       CAST(SUM(o_front) AS DECIMAL(12,4))                          AS regular_staff_hours_front,
       CAST(SUM(o_back)  AS DECIMAL(12,4))                          AS regular_staff_hours_back,
       CAST(SUM(o_ot)    AS DECIMAL(12,4))                          AS overtime_staff_hours,
       SUM(CASE WHEN o_sched > 0 THEN 1 ELSE 0 END)                 AS rostered_headcount
INTO work.cov_h
FROM ov
GROUP BY store_id, trade_date, hour_of_day;
GO

/* ---------- 5. mart.store_hour (grain: store x date x hour, exactly one row per key) ---------- */
DROP TABLE IF EXISTS work.store_hour_base;
SELECT sp.store_id, sp.trade_date, sp.month_num, sp.iso_weekday, sp.weekday_name, sp.hour_of_day,
       ISNULL(s.net_sales_cad, 0)     AS net_sales_cad,
       ISNULL(s.cogs_cad, 0)          AS cogs_cad,
       ISNULL(s.gross_profit_cad, 0)  AS gross_profit_cad,
       ISNULL(s.sale_revenue_cad, 0)  AS sale_revenue_cad,
       ISNULL(s.return_value_cad, 0)  AS return_value_cad,
       ISNULL(s.units_sold, 0)        AS units_sold,
       ISNULL(s.sale_txns, 0)         AS sale_txns,
       ISNULL(s.return_txns, 0)       AS return_txns,
       f.visitor_count                AS visitors,                       -- NULL = unknown, never zero
       CAST(ISNULL(f.footfall_valid, 0) AS bit) AS footfall_valid,
       ISNULL(c.rostered_headcount, 0)      AS rostered_headcount,
       ISNULL(c.scheduled_staff_hours, 0)   AS scheduled_staff_hours,
       ISNULL(c.regular_staff_hours_base, 0)  + ISNULL(c.overtime_staff_hours, 0) AS effective_staff_base,
       ISNULL(c.regular_staff_hours_front, 0) + ISNULL(c.overtime_staff_hours, 0) AS effective_staff_front_absent,
       ISNULL(c.regular_staff_hours_back, 0)  + ISNULL(c.overtime_staff_hours, 0) AS effective_staff_back_absent,
       ISNULL(c.overtime_staff_hours, 0)    AS overtime_staff_hours
INTO work.store_hour_base
FROM work.spine sp
LEFT JOIN work.sales_h       s ON s.store_id = sp.store_id AND s.trade_date = sp.trade_date AND s.hour_of_day = sp.hour_of_day
LEFT JOIN core.footfall     f ON f.store_id = sp.store_id AND f.obs_date   = sp.trade_date AND f.hour_of_day = sp.hour_of_day
LEFT JOIN work.cov_h         c ON c.store_id = sp.store_id AND c.trade_date = sp.trade_date AND c.hour_of_day = sp.hour_of_day;
GO

-- Peak hour = visitors at or above the store's own peak_percentile (dq.Assumptions, 0.9) of valid store-hours (nearest-rank method)
DECLARE @pk FLOAT = (SELECT CAST(value AS float) FROM dq.Assumptions WHERE name = 'peak_percentile');
DROP TABLE IF EXISTS mart.store_hour;
WITH ranked AS (
    SELECT store_id, visitors,
           ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY visitors) AS rn,
           COUNT(*)     OVER (PARTITION BY store_id)                   AS n
    FROM work.store_hour_base WHERE footfall_valid = 1
), p AS (
    SELECT store_id, MIN(visitors) AS p90_visitors
    FROM ranked WHERE rn >= CEILING(@pk * n) GROUP BY store_id
)
SELECT b.*,
       CASE WHEN b.footfall_valid = 1 AND b.visitors >= p.p90_visitors THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS is_peak_hour,
       CAST(b.visitors AS float) / NULLIF(b.effective_staff_base, 0) AS visitors_per_effective_staff
INTO mart.store_hour
FROM work.store_hour_base b
LEFT JOIN p ON p.store_id = b.store_id;
GO

/* ---------- 6. Category money mart (additive only) ---------- */
DROP TABLE IF EXISTS mart.sales_store_hour_category;
SELECT store_id, txn_date AS trade_date, txn_month AS month_num, iso_weekday, weekday_name, txn_hour AS hour_of_day, category,
       SUM(net_sales_cad)    AS net_sales_cad,
       SUM(cogs_cad)         AS cogs_cad,
       SUM(gross_profit_cad) AS gross_profit_cad,
       SUM(CASE WHEN txn_type = 'Sale' THEN quantity ELSE 0 END) AS units_sold,
       SUM(quantity)                                            AS net_units
INTO mart.sales_store_hour_category
FROM core.sales_lines
GROUP BY store_id, txn_date, txn_month, iso_weekday, weekday_name, txn_hour, category;
GO

/* ---------- 7. Store-day table: labour and sales each aggregated to store x date FIRST, then joined ---------- */
DROP TABLE IF EXISTS mart.store_day;
WITH lab AS (
    SELECT store_id, shift_date AS trade_date, COUNT(*) AS shifts,
           SUM(scheduled_hours) AS scheduled_hours, SUM(absent_hours) AS absent_hours,
           SUM(overtime_hours)  AS overtime_hours,  SUM(worked_hours) AS worked_hours, SUM(labour_cost_cad) AS labour_cost_cad
    FROM core.shifts GROUP BY store_id, shift_date
),
sal AS (
    SELECT store_id, trade_date,
           SUM(net_sales_cad) AS net_sales_cad, SUM(gross_profit_cad) AS gross_profit_cad, SUM(sale_revenue_cad) AS sale_revenue_cad,
           SUM(sale_txns) AS sale_txns,
           SUM(CASE WHEN footfall_valid = 1 THEN sale_txns ELSE 0 END) AS sale_txns_matched,
           SUM(CASE WHEN footfall_valid = 1 THEN visitors  ELSE 0 END) AS visitors_matched,
           SUM(CASE WHEN footfall_valid = 1 THEN 1 ELSE 0 END)         AS valid_footfall_hours
    FROM mart.store_hour GROUP BY store_id, trade_date
)
SELECT d.store_id, d.trade_date, d.month_num, d.iso_weekday, d.weekday_name,
       ISNULL(l.shifts, 0) AS shifts,
       ISNULL(l.scheduled_hours, 0) AS scheduled_hours, ISNULL(l.absent_hours, 0) AS absent_hours,
       ISNULL(l.overtime_hours, 0)  AS overtime_hours,  ISNULL(l.worked_hours, 0) AS worked_hours,
       ISNULL(l.labour_cost_cad, 0) AS labour_cost_cad,
       ISNULL(s.net_sales_cad, 0) AS net_sales_cad, ISNULL(s.gross_profit_cad, 0) AS gross_profit_cad,
       ISNULL(s.sale_revenue_cad, 0) AS sale_revenue_cad, ISNULL(s.sale_txns, 0) AS sale_txns,
       ISNULL(s.sale_txns_matched, 0) AS sale_txns_matched, ISNULL(s.visitors_matched, 0) AS visitors_matched,
       ISNULL(s.valid_footfall_hours, 0) AS valid_footfall_hours
INTO mart.store_day
FROM (SELECT DISTINCT store_id, trade_date, month_num, iso_weekday, weekday_name FROM work.spine) d
LEFT JOIN lab l ON l.store_id = d.store_id AND l.trade_date = d.trade_date
LEFT JOIN sal s ON s.store_id = d.store_id AND s.trade_date = d.trade_date;
GO

/* ---------- 8. Month and annual store tables: rates, ranks, running totals ---------- */
DROP TABLE IF EXISTS mart.store_month;
WITH m AS (
    SELECT store_id, month_num,
           SUM(net_sales_cad) AS net_sales_cad, SUM(gross_profit_cad) AS gross_profit_cad, SUM(sale_revenue_cad) AS sale_revenue_cad,
           SUM(sale_txns) AS sale_txns, SUM(scheduled_hours) AS scheduled_hours, SUM(absent_hours) AS absent_hours,
           SUM(overtime_hours) AS overtime_hours, SUM(worked_hours) AS worked_hours, SUM(labour_cost_cad) AS labour_cost_cad,
           SUM(sale_txns_matched) AS sale_txns_matched, SUM(visitors_matched) AS visitors_matched
    FROM mart.store_day GROUP BY store_id, month_num
)
SELECT m.*,
       m.gross_profit_cad / NULLIF(m.net_sales_cad, 0)                       AS gross_margin,
       m.net_sales_cad    / NULLIF(m.worked_hours, 0)                        AS sales_per_worked_hour,
       m.labour_cost_cad  / NULLIF(m.net_sales_cad, 0)                       AS labour_cost_pct,
       m.absent_hours     / NULLIF(m.scheduled_hours, 0)                     AS absence_rate,
       m.overtime_hours   / NULLIF(m.worked_hours, 0)                        AS overtime_share,
       (m.scheduled_hours - m.absent_hours) / NULLIF(m.scheduled_hours, 0)   AS staff_availability,
       CAST(m.sale_txns_matched AS float) / NULLIF(m.visitors_matched, 0)    AS conversion_rate,
       RANK() OVER (PARTITION BY m.month_num ORDER BY m.net_sales_cad DESC)          AS sales_rank_in_month,
       SUM(m.net_sales_cad) OVER (PARTITION BY m.store_id ORDER BY m.month_num)      AS ytd_net_sales_cad,
       m.net_sales_cad / NULLIF(LAG(m.net_sales_cad) OVER (PARTITION BY m.store_id ORDER BY m.month_num), 0) - 1 AS mom_growth
INTO mart.store_month
FROM m;
GO

DROP TABLE IF EXISTS mart.store_summary;
WITH a AS (
    SELECT store_id,
           SUM(net_sales_cad) AS net_sales_cad, SUM(gross_profit_cad) AS gross_profit_cad, SUM(sale_revenue_cad) AS sale_revenue_cad,
           SUM(sale_txns) AS sale_txns, SUM(scheduled_hours) AS scheduled_hours, SUM(absent_hours) AS absent_hours,
           SUM(overtime_hours) AS overtime_hours, SUM(worked_hours) AS worked_hours, SUM(labour_cost_cad) AS labour_cost_cad,
           SUM(sale_txns_matched) AS sale_txns_matched, SUM(visitors_matched) AS visitors_matched
    FROM mart.store_day GROUP BY store_id
),
r AS (
    SELECT a.*,
           gross_profit_cad / NULLIF(net_sales_cad, 0)               AS gross_margin,
           net_sales_cad    / NULLIF(worked_hours, 0)                AS sales_per_worked_hour,
           labour_cost_cad  / NULLIF(net_sales_cad, 0)               AS labour_cost_pct,
           absent_hours     / NULLIF(scheduled_hours, 0)             AS absence_rate,
           overtime_hours   / NULLIF(worked_hours, 0)                AS overtime_share,
           sale_revenue_cad / NULLIF(sale_txns, 0)                   AS avg_purchase_value_cad,
           CAST(sale_txns_matched AS float) / NULLIF(visitors_matched, 0) AS conversion_rate
    FROM a
)
SELECT r.*, st.store_name, st.city, st.province, st.floor_area_sqft,
       r.net_sales_cad / NULLIF(st.floor_area_sqft, 0)           AS net_sales_per_sqft,
       RANK() OVER (ORDER BY r.net_sales_cad DESC)               AS rank_net_sales,
       RANK() OVER (ORDER BY r.gross_profit_cad DESC)            AS rank_gross_profit,
       RANK() OVER (ORDER BY r.sales_per_worked_hour DESC)       AS rank_sales_per_hour,
       RANK() OVER (ORDER BY r.visitors_matched DESC)            AS rank_visitors,
       RANK() OVER (ORDER BY r.conversion_rate DESC)             AS rank_conversion,
       -- z-scores vs the 11-store network: > 1 means unusually high
       (r.labour_cost_pct - AVG(r.labour_cost_pct) OVER ()) / NULLIF(STDEV(r.labour_cost_pct) OVER (), 0) AS z_labour_cost_pct,
       (r.overtime_share  - AVG(r.overtime_share)  OVER ()) / NULLIF(STDEV(r.overtime_share)  OVER (), 0) AS z_overtime_share,
       (r.absence_rate    - AVG(r.absence_rate)    OVER ()) / NULLIF(STDEV(r.absence_rate)    OVER (), 0) AS z_absence_rate
INTO mart.store_summary
FROM r JOIN mart.dim_store st ON st.store_id = r.store_id;
GO

/* ---------- 9. Employee table (person-level absence vs overtime) ---------- */
DROP TABLE IF EXISTS mart.employee_summary;
SELECT e.employee_id, e.store_id, e.job_title, e.department, e.employment_type, e.hire_date, e.hourly_rate_cad, e.absence_value_basis,
       COUNT(*)               AS shifts,
       SUM(s.scheduled_hours) AS scheduled_hours,
       SUM(s.absent_hours)    AS absent_hours,
       SUM(s.overtime_hours)  AS overtime_hours,
       SUM(s.worked_hours)    AS worked_hours,
       SUM(s.labour_cost_cad) AS labour_cost_cad,
       SUM(s.absent_hours)   / NULLIF(SUM(s.scheduled_hours), 0) AS absence_rate,
       SUM(s.overtime_hours) / NULLIF(SUM(s.worked_hours), 0)    AS overtime_share
INTO mart.employee_summary
FROM core.employees e
JOIN core.shifts s ON s.employee_id = e.employee_id
GROUP BY e.employee_id, e.store_id, e.job_title, e.department, e.employment_type, e.hire_date, e.hourly_rate_cad, e.absence_value_basis;
GO

/* ---------- 10. Conversion vs peers at the SAME month, weekday and hour (Q5) ----------
   Each store is compared with the other stores at the same month x weekday x hour, using only hours with valid footfall,
   so seasonal and weekday demand patterns cannot be mistaken for a store problem. */
DECLARE @busy INT = (SELECT CAST(value AS INT) FROM dq.Assumptions WHERE name = 'busy_hours_count');
DROP TABLE IF EXISTS work.busy_hours;
SELECT TOP (@busy) hour_of_day INTO work.busy_hours
FROM (SELECT hour_of_day, AVG(CAST(visitors AS float)) AS avg_v FROM mart.store_hour WHERE footfall_valid = 1 GROUP BY hour_of_day) a
ORDER BY avg_v DESC;
GO

DROP TABLE IF EXISTS mart.conversion_peer;
WITH base AS (
    SELECT store_id, month_num, iso_weekday, weekday_name, hour_of_day, SUM(visitors) AS visitors, SUM(sale_txns) AS sale_txns
    FROM mart.store_hour WHERE footfall_valid = 1
    GROUP BY store_id, month_num, iso_weekday, weekday_name, hour_of_day
),
net AS (
    SELECT month_num, iso_weekday, hour_of_day, SUM(visitors) AS net_visitors, SUM(sale_txns) AS net_txns
    FROM base GROUP BY month_num, iso_weekday, hour_of_day
)
SELECT b.store_id, b.month_num, b.iso_weekday, b.weekday_name, b.hour_of_day, b.visitors, b.sale_txns,
       CAST(b.sale_txns AS float) / NULLIF(b.visitors, 0)                                               AS conversion_rate,
       CAST(n.net_txns - b.sale_txns AS float) / NULLIF(n.net_visitors - b.visitors, 0)                 AS peer_conversion_rate,
       b.visitors * CAST(n.net_txns - b.sale_txns AS float) / NULLIF(n.net_visitors - b.visitors, 0)    AS expected_txns,
       b.sale_txns - b.visitors * CAST(n.net_txns - b.sale_txns AS float) / NULLIF(n.net_visitors - b.visitors, 0) AS txn_gap,
       CASE WHEN b.hour_of_day IN (SELECT hour_of_day FROM work.busy_hours) THEN 1 ELSE 0 END           AS is_network_busy_hour
INTO mart.conversion_peer
FROM base b JOIN net n ON n.month_num = b.month_num AND n.iso_weekday = b.iso_weekday AND n.hour_of_day = b.hour_of_day;
GO

DROP TABLE IF EXISTS mart.conversion_store;
SELECT c.store_id, st.store_name,
       SUM(c.visitors) AS visitors, SUM(c.sale_txns) AS sale_txns,
       CAST(SUM(c.sale_txns) AS float) / NULLIF(SUM(c.visitors), 0)       AS conversion_rate,
       SUM(c.expected_txns)                                               AS expected_txns_at_peer_rates,
       SUM(c.sale_txns) / NULLIF(SUM(c.expected_txns), 0)                 AS conversion_index,   -- < 1 = below peers at the same weekday-hour
       SUM(c.txn_gap)                                                     AS txn_gap,
       SUM(CASE WHEN c.is_network_busy_hour = 1 THEN c.visitors END)      AS busy_hour_visitors,
       SUM(CASE WHEN c.is_network_busy_hour = 1 THEN c.sale_txns END)
         / NULLIF(SUM(CASE WHEN c.is_network_busy_hour = 1 THEN c.expected_txns END), 0) AS busy_hour_conversion_index
INTO mart.conversion_store
FROM mart.conversion_peer c JOIN mart.dim_store st ON st.store_id = c.store_id
GROUP BY c.store_id, st.store_name;
GO

/* ---------- 11. PROOF of no double counting: every mart total must equal its clean-table source ---------- */
DROP TABLE IF EXISTS dq.mart_reconciliation;
SELECT check_name, source_value, mart_value, mart_value - source_value AS difference,
       CASE WHEN ABS(mart_value - source_value) < 0.05 THEN 'PASS' ELSE 'FAIL' END AS status
INTO dq.mart_reconciliation
FROM (
    SELECT 'net sales: clean lines vs mart.store_hour' AS check_name,
           CAST((SELECT SUM(net_sales_cad) FROM core.sales_lines) AS float) AS source_value,
           CAST((SELECT SUM(net_sales_cad) FROM mart.store_hour) AS float)   AS mart_value
    UNION ALL SELECT 'net sales: clean lines vs mart.sales_store_hour_category',
           CAST((SELECT SUM(net_sales_cad) FROM core.sales_lines) AS float), CAST((SELECT SUM(net_sales_cad) FROM mart.sales_store_hour_category) AS float)
    UNION ALL SELECT 'net sales: clean lines vs mart.store_day',
           CAST((SELECT SUM(net_sales_cad) FROM core.sales_lines) AS float), CAST((SELECT SUM(net_sales_cad) FROM mart.store_day) AS float)
    UNION ALL SELECT 'net sales: clean lines vs mart.store_month',
           CAST((SELECT SUM(net_sales_cad) FROM core.sales_lines) AS float), CAST((SELECT SUM(net_sales_cad) FROM mart.store_month) AS float)
    UNION ALL SELECT 'gross profit: clean lines vs mart.store_summary',
           CAST((SELECT SUM(gross_profit_cad) FROM core.sales_lines) AS float), CAST((SELECT SUM(gross_profit_cad) FROM mart.store_summary) AS float)
    UNION ALL SELECT 'distinct Sale transactions: clean lines vs mart.store_hour',
           CAST((SELECT COUNT(DISTINCT transaction_id) FROM core.sales_lines WHERE txn_type = 'Sale') AS float), CAST((SELECT SUM(sale_txns) FROM mart.store_hour) AS float)
    UNION ALL SELECT 'labour cost: clean shifts vs mart.store_day',
           CAST((SELECT SUM(labour_cost_cad) FROM core.shifts) AS float), CAST((SELECT SUM(labour_cost_cad) FROM mart.store_day) AS float)
    UNION ALL SELECT 'worked hours: clean shifts vs mart.store_summary',
           CAST((SELECT SUM(worked_hours) FROM core.shifts) AS float), CAST((SELECT SUM(worked_hours) FROM mart.store_summary) AS float)
    UNION ALL SELECT 'overtime hours: clean shifts vs mart.employee_summary',
           CAST((SELECT SUM(overtime_hours) FROM core.shifts) AS float), CAST((SELECT SUM(overtime_hours) FROM mart.employee_summary) AS float)
    UNION ALL SELECT 'visitors (valid hours): core.footfall vs mart.store_hour',
           CAST((SELECT SUM(visitor_count) FROM core.footfall WHERE footfall_valid = 1) AS float), CAST((SELECT SUM(visitors) FROM mart.store_hour WHERE footfall_valid = 1) AS float)
    UNION ALL SELECT 'mart.store_hour rows = stores x 365 x 12',
           CAST((SELECT COUNT(*) FROM core.stores) * 365 * 12 AS float), CAST((SELECT COUNT(*) FROM mart.store_hour) AS float)
) x;
GO

SELECT * FROM dq.mart_reconciliation;

-- Informational: scheduled / overtime hours that fall outside the 08-20 hourly coverage window
SELECT (SELECT SUM(scheduled_hours) FROM core.shifts)            AS shift_scheduled_hours,
       (SELECT SUM(scheduled_staff_hours) FROM mart.store_hour)   AS hourly_scheduled_staff_hours,
       (SELECT SUM(overtime_hours) FROM core.shifts)             AS total_overtime_hours,
       (SELECT SUM(overtime_staff_hours) FROM mart.store_hour)    AS overtime_hours_inside_trading;

/* ---------- STOP CHECKS, then drop the work.* intermediates ----------
   THROW ends this batch, so the DROP statements below only run when every check has passed. */
IF EXISTS (SELECT 1 FROM dq.mart_reconciliation WHERE status = 'FAIL')
    THROW 50040, N'Part 5 stop: a mart total does not equal its core source (possible double counting). Read dq.mart_reconciliation.', 1;
IF (SELECT SUM(net_sales_cad) FROM mart.store_day) <= 0 OR (SELECT SUM(labour_cost_cad) FROM mart.store_day) <= 0
   OR (SELECT SUM(overtime_hours) FROM mart.store_day) <= 0 OR (SELECT SUM(visitors_matched) FROM mart.store_day) <= 0
    THROW 50041, N'Part 5 stop: net sales, labour cost, overtime hours or visitors total zero in mart.store_day. Check Parts 1 to 3.', 1;
DROP TABLE IF EXISTS work.spine;
DROP TABLE IF EXISTS work.sales_h;
DROP TABLE IF EXISTS work.cov_h;
DROP TABLE IF EXISTS work.store_hour_base;
DROP TABLE IF EXISTS work.busy_hours;
GO


/* #####################################################################################################
   PART 6 - ANALYSIS QUERIES Q1 TO Q6 (mart)      ONE query per business question
   Answers the six business questions using joins, aggregations, CTEs and window functions.
   ##################################################################################################### */
/* =====================================================================
   Part 6: Analysis queries for business questions Q1-Q6
   Every question is ONE query. Where a question needs several views (store, category, month, weekday, hour)
   the query returns them together in a single result with a view_type column; filter on view_type in
   Excel or Power BI to separate them. Units are in the column names (cad, pct, hours).
   All queries read from the mart layer (already reconciled in Part 5).
   Weekday: Mon ... Sun (ISO). Hours are LOCAL store hours (08:00 = 08:00-08:59).
   Currency: CAD, excluding tax.  Period: calendar year 2025.
   Thresholds come from dq.Assumptions. T-SQL has no CORR() function, so Pearson correlation is calculated from sums.
   ===================================================================== */
USE Task2_DataWH;
GO

/* ================= Q1  Highest net sales / gross profit; how results change by month, weekday and hour =================
   One GROUPING SETS query over the additive category mart (no distinct counts are summed, so nothing is double counted).
   view_type = Store | Category | Month | Weekday | Hour.
   net_sales_per_calendar_day_cad = net sales / calendar days in that group (all stores in the group together),
   which makes weekdays and months of different length comparable.
   Store and Category rows are ordered by rank; Month, Weekday and Hour rows are in calendar order. */
WITH g AS (
    SELECT
        CASE WHEN GROUPING(store_id)    = 0 THEN 'Store'
             WHEN GROUPING(category)    = 0 THEN 'Category'
             WHEN GROUPING(month_num)   = 0 THEN 'Month'
             WHEN GROUPING(iso_weekday) = 0 THEN 'Weekday'
             ELSE 'Hour' END                    AS view_type,
        store_id, category, month_num, iso_weekday, hour_of_day,
        SUM(net_sales_cad)    AS net_sales_cad,
        SUM(gross_profit_cad) AS gross_profit_cad
    FROM mart.sales_store_hour_category
    GROUP BY GROUPING SETS ((store_id), (category), (month_num), (iso_weekday), (hour_of_day))
),
l AS (
    SELECT g.view_type,
           CASE g.view_type
                WHEN 'Store'    THEN CONCAT(g.store_id, ' - ', st.store_name)
                WHEN 'Category' THEN g.category
                WHEN 'Month'    THEN CHOOSE(g.month_num, 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')
                WHEN 'Weekday'  THEN CHOOSE(g.iso_weekday, 'Mon','Tue','Wed','Thu','Fri','Sat','Sun')
                ELSE CONCAT(RIGHT('0' + CAST(g.hour_of_day AS varchar(2)), 2), ':00') END AS item,
           CASE g.view_type WHEN 'Month' THEN g.month_num WHEN 'Weekday' THEN g.iso_weekday WHEN 'Hour' THEN g.hour_of_day END AS chrono_key,
           g.net_sales_cad, g.gross_profit_cad,
           CASE g.view_type
                WHEN 'Weekday' THEN (SELECT COUNT(*) FROM mart.dim_date d WHERE d.iso_weekday = g.iso_weekday)
                WHEN 'Month'   THEN (SELECT COUNT(*) FROM mart.dim_date d WHERE d.month_num   = g.month_num)
                ELSE                (SELECT COUNT(*) FROM mart.dim_date) END AS calendar_days
    FROM g
    LEFT JOIN mart.dim_store st ON st.store_id = g.store_id
),
r AS (
    SELECT l.*,
           RANK() OVER (PARTITION BY view_type ORDER BY net_sales_cad DESC)    AS rank_net_sales,
           RANK() OVER (PARTITION BY view_type ORDER BY gross_profit_cad DESC) AS rank_gross_profit,
           net_sales_cad * 100.0 / SUM(net_sales_cad) OVER (PARTITION BY view_type) AS share_of_net_sales_pct,
           CASE WHEN view_type = 'Month'
                THEN net_sales_cad * 100.0 / NULLIF(LAG(net_sales_cad) OVER (PARTITION BY view_type ORDER BY chrono_key), 0) - 100 END AS mom_growth_pct,
           CASE WHEN view_type = 'Month'
                THEN SUM(net_sales_cad) OVER (PARTITION BY view_type ORDER BY chrono_key ROWS UNBOUNDED PRECEDING) END AS ytd_net_sales_cad
    FROM l
)
SELECT view_type, item,
       ROUND(net_sales_cad, 0)                                  AS net_sales_cad,
       ROUND(gross_profit_cad, 0)                               AS gross_profit_cad,
       ROUND(gross_profit_cad * 100.0 / NULLIF(net_sales_cad, 0), 1) AS gross_margin_pct,
       ROUND(share_of_net_sales_pct, 1)                         AS share_of_net_sales_pct,
       rank_net_sales, rank_gross_profit,
       ROUND(net_sales_cad / NULLIF(calendar_days, 0), 0)       AS net_sales_per_calendar_day_cad,
       ROUND(mom_growth_pct, 1)                                 AS mom_growth_pct,
       ROUND(ytd_net_sales_cad, 0)                              AS ytd_net_sales_cad
FROM r
ORDER BY CASE view_type WHEN 'Store' THEN 1 WHEN 'Category' THEN 2 WHEN 'Month' THEN 3 WHEN 'Weekday' THEN 4 ELSE 5 END,
         CASE WHEN view_type IN ('Store', 'Category') THEN rank_net_sales ELSE chrono_key END;
GO

/* ================= Q2  Sales per worked labour hour; where labour cost and overtime are unusually high =================
   One row per store: efficiency, cost share, overtime share, absence rate, z-scores against the other stores
   (z above dq.Assumptions z_flag = unusually high) and the store's three months with the highest labour cost %. */
DECLARE @z DECIMAL(18,6) = (SELECT value FROM dq.Assumptions WHERE name = 'z_flag');

WITH worst AS (
    SELECT store_id, month_num, labour_cost_pct,
           ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY labour_cost_pct DESC) AS rn
    FROM mart.store_month WHERE labour_cost_pct IS NOT NULL
),
w3 AS (
    SELECT store_id,
           STRING_AGG(CONCAT(CHOOSE(month_num, 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'), ' ',
                             CAST(CAST(ROUND(labour_cost_pct * 100, 1) AS DECIMAL(6,1)) AS varchar(10)), '%'), ', ')
                WITHIN GROUP (ORDER BY rn) AS highest_labour_cost_months
    FROM worst WHERE rn <= 3 GROUP BY store_id
)
SELECT s.rank_sales_per_hour, s.store_id, s.store_name, s.city,
       ROUND(s.net_sales_cad, 0)          AS net_sales_cad,
       ROUND(s.labour_cost_cad, 0)        AS labour_cost_cad,
       ROUND(s.worked_hours, 0)           AS worked_hours,
       ROUND(s.sales_per_worked_hour, 2)  AS net_sales_per_worked_hour_cad,
       ROUND(s.labour_cost_pct * 100, 2)  AS labour_cost_pct_of_sales,
       ROUND(s.overtime_share * 100, 2)   AS overtime_share_pct,
       ROUND(s.absence_rate * 100, 2)     AS absence_rate_pct,
       ROUND(s.z_labour_cost_pct, 2)      AS z_labour_cost_pct,
       ROUND(s.z_overtime_share, 2)       AS z_overtime_share,
       CASE WHEN s.z_labour_cost_pct > @z OR s.z_overtime_share > @z THEN 'REVIEW' ELSE '' END AS flag,
       w3.highest_labour_cost_months
FROM mart.store_summary s
LEFT JOIN w3 ON w3.store_id = s.store_id
ORDER BY s.rank_sales_per_hour;
GO

/* ================= Q3  Do scheduled shifts match footfall at peak periods? (valid-footfall hours only) =================
   Coverage is an ESTIMATE: absence timing inside a shift is unknown (see Part 5 section 4). One GROUPING SETS query:
     view_type 'Hour (network)'        share of visitors vs share of staff-hours for each hour of the day
     view_type 'Store x peak/off-peak' visitors per staff-hour for each store at peak and off-peak hours, with the
                                       share of hours where visitors per effective staff-hour is above the network
                                       stretched_percentile of all valid store-hours ("stretched")
     view_type 'Weekday x hour'        the 15 weekday-hour cells with the most visitors per effective staff-hour
   Staff-hour scenarios for the SAME absent hours (the sensitivity test): rostered (ignores absence), base (proportional spread),
   front (absence at the start of the shift) and back (absence at the end of the shift). If the story is the same
   under all of them, it does not depend on the timing assumption. */
DECLARE @q FLOAT = (SELECT CAST(value AS float) FROM dq.Assumptions WHERE name = 'stretched_percentile');
DECLARE @p75 FLOAT = (
    SELECT MIN(o.v)
    FROM (SELECT visitors_per_effective_staff AS v,
                 ROW_NUMBER() OVER (ORDER BY visitors_per_effective_staff) AS rn,
                 COUNT(*) OVER () AS n
          FROM mart.store_hour
          WHERE footfall_valid = 1 AND effective_staff_base > 0) AS o
    WHERE o.rn >= CEILING(@q * o.n));

WITH g AS (
    SELECT
        CASE WHEN GROUPING(store_id)    = 0 THEN 'Store x peak/off-peak'
             WHEN GROUPING(iso_weekday) = 0 THEN 'Weekday x hour'
             ELSE 'Hour (network)' END                             AS view_type,
        store_id, is_peak_hour, iso_weekday, hour_of_day,
        COUNT(*)                                                   AS store_hours,
        SUM(CAST(visitors AS float))                               AS visitors,
        SUM(CAST(scheduled_staff_hours AS float))                  AS rostered_staff_hours,
        SUM(CAST(effective_staff_base AS float))                   AS effective_staff_hours_base,
        SUM(CAST(effective_staff_front_absent AS float))           AS effective_staff_hours_front,
        SUM(CAST(effective_staff_back_absent AS float))            AS effective_staff_hours_back,
        SUM(CASE WHEN visitors_per_effective_staff > @p75 THEN 1 ELSE 0 END) AS stretched_hours
    FROM mart.store_hour
    WHERE footfall_valid = 1
    GROUP BY GROUPING SETS ((hour_of_day), (store_id, is_peak_hour), (iso_weekday, hour_of_day))
),
r AS (
    SELECT g.*,
           g.visitors / NULLIF(g.store_hours, 0)                   AS avg_visitors_per_store_hour,
           g.visitors / NULLIF(g.rostered_staff_hours, 0)          AS visitors_per_rostered_staff_hour,
           g.visitors / NULLIF(g.effective_staff_hours_base, 0)    AS visitors_per_staff_hour_base,
           g.visitors / NULLIF(g.effective_staff_hours_front, 0)   AS visitors_per_staff_hour_front_absent,
           g.visitors / NULLIF(g.effective_staff_hours_back, 0)    AS visitors_per_staff_hour_back_absent,
           100.0 * g.stretched_hours / NULLIF(g.store_hours, 0)    AS pct_hours_stretched,
           CASE WHEN g.view_type = 'Hour (network)' THEN 100.0 * g.visitors                   / SUM(g.visitors)                   OVER (PARTITION BY g.view_type) END AS pct_of_visitors,
           CASE WHEN g.view_type = 'Hour (network)' THEN 100.0 * g.rostered_staff_hours       / SUM(g.rostered_staff_hours)       OVER (PARTITION BY g.view_type) END AS pct_of_rostered_staff_hours,
           CASE WHEN g.view_type = 'Hour (network)' THEN 100.0 * g.effective_staff_hours_base / SUM(g.effective_staff_hours_base) OVER (PARTITION BY g.view_type) END AS pct_of_effective_staff_hours,
           ROW_NUMBER() OVER (PARTITION BY g.view_type ORDER BY g.visitors / NULLIF(g.effective_staff_hours_base, 0) DESC) AS pressure_rank
    FROM g
)
SELECT r.view_type,
       r.store_id, st.store_name,
       CASE WHEN r.view_type = 'Store x peak/off-peak' THEN CASE WHEN r.is_peak_hour = 1 THEN 'Peak hours' ELSE 'Off-peak hours' END END AS hour_type,
       CHOOSE(r.iso_weekday, 'Mon','Tue','Wed','Thu','Fri','Sat','Sun') AS weekday,
       CASE WHEN r.hour_of_day IS NOT NULL THEN CONCAT(RIGHT('0' + CAST(r.hour_of_day AS varchar(2)), 2), ':00') END AS hour_of_day,
       r.store_hours,
       ROUND(r.avg_visitors_per_store_hour, 1)              AS avg_visitors_per_store_hour,
       ROUND(r.pct_of_visitors, 1)                          AS pct_of_visitors,
       ROUND(r.pct_of_rostered_staff_hours, 1)              AS pct_of_rostered_staff_hours,
       ROUND(r.pct_of_effective_staff_hours, 1)             AS pct_of_effective_staff_hours,
       ROUND(r.visitors_per_rostered_staff_hour, 1)         AS visitors_per_rostered_staff_hour,
       ROUND(r.visitors_per_staff_hour_base, 1)             AS visitors_per_staff_hour_base,
       ROUND(r.visitors_per_staff_hour_front_absent, 1)     AS visitors_per_staff_hour_front_absent,
       ROUND(r.visitors_per_staff_hour_back_absent, 1)      AS visitors_per_staff_hour_back_absent,
       ROUND(r.pct_hours_stretched, 1)                      AS pct_hours_stretched
FROM r
LEFT JOIN mart.dim_store st ON st.store_id = r.store_id
WHERE r.view_type <> 'Weekday x hour' OR r.pressure_rank <= 15
ORDER BY CASE r.view_type WHEN 'Hour (network)' THEN 1 WHEN 'Store x peak/off-peak' THEN 2 ELSE 3 END,
         CASE WHEN r.view_type = 'Weekday x hour' THEN r.pressure_rank END,
         r.hour_of_day, r.store_id, r.is_peak_hour DESC;
GO

/* ================= Q4  Absence vs overtime and sales (ASSOCIATIONS ONLY, not causal) =================
   One query. Pearson correlations are calculated at four levels so one confounder cannot explain everything:
     A store-month panel (11 stores x 12 months), raw
     B the same panel WITHIN store (each store's own average removed, so permanent store differences cannot drive it)
     C store-days compared within the same store AND weekday (removes weekday demand effects)
     D employees (do people with more absence log more overtime?)
   Rows E show outcomes by absence quartile of store-days within each store (easy to chart).
   Staff availability is 1 - absence rate by construction, so it is not correlated separately (r would be -1 by definition).
   Strength labels: |r| < 0.1 negligible, < 0.3 weak, < 0.5 moderate, otherwise strong.
   A correlation shows co-movement, not cause. Confounders include season and illness months, store size,
   promotions, schedule design, and unmeasured absence reasons. */
WITH smo AS (
    SELECT store_id, CAST(absence_rate AS float) AS a, CAST(overtime_share AS float) AS o, CAST(sales_per_worked_hour AS float) AS s
    FROM mart.store_month
    WHERE absence_rate IS NOT NULL AND overtime_share IS NOT NULL AND sales_per_worked_hour IS NOT NULL
),
sd AS (
    SELECT store_id, iso_weekday,
           CAST(absent_hours AS float)   / NULLIF(scheduled_hours, 0) AS a,
           CAST(overtime_hours AS float) / NULLIF(worked_hours, 0)    AS o,
           CAST(net_sales_cad AS float)  / NULLIF(worked_hours, 0)    AS s
    FROM mart.store_day
    WHERE scheduled_hours > 0 AND worked_hours > 0
),
pairs AS (
    SELECT CAST('A. Store-month (raw)' AS varchar(60)) AS analysis, CAST('Absence rate vs overtime share' AS varchar(60)) AS relationship, a AS x, o AS y FROM smo
    UNION ALL SELECT 'A. Store-month (raw)', 'Absence rate vs sales per worked hour', a, s FROM smo
    UNION ALL SELECT 'B. Store-month, within store', 'Absence rate vs overtime share',
                     a - AVG(a) OVER (PARTITION BY store_id), o - AVG(o) OVER (PARTITION BY store_id) FROM smo
    UNION ALL SELECT 'B. Store-month, within store', 'Absence rate vs sales per worked hour',
                     a - AVG(a) OVER (PARTITION BY store_id), s - AVG(s) OVER (PARTITION BY store_id) FROM smo
    UNION ALL SELECT 'C. Store-day, same store and weekday', 'Absence rate vs overtime share',
                     a - AVG(a) OVER (PARTITION BY store_id, iso_weekday), o - AVG(o) OVER (PARTITION BY store_id, iso_weekday) FROM sd
    UNION ALL SELECT 'C. Store-day, same store and weekday', 'Absence rate vs sales per worked hour',
                     a - AVG(a) OVER (PARTITION BY store_id, iso_weekday), s - AVG(s) OVER (PARTITION BY store_id, iso_weekday) FROM sd
    UNION ALL SELECT 'D. Employee', 'Absence rate vs overtime share', CAST(absence_rate AS float), CAST(overtime_share AS float)
              FROM mart.employee_summary WHERE absence_rate IS NOT NULL AND overtime_share IS NOT NULL
),
c AS (
    SELECT analysis, relationship, COUNT(*) AS observations,
           (COUNT(*) * SUM(x*y) - SUM(x) * SUM(y))
             / NULLIF(SQRT((COUNT(*) * SUM(x*x) - SUM(x)*SUM(x)) * (COUNT(*) * SUM(y*y) - SUM(y)*SUM(y))), 0) AS r
    FROM pairs
    GROUP BY analysis, relationship
),
qd AS (
    SELECT a, o, s, NTILE(4) OVER (PARTITION BY store_id ORDER BY a) AS q FROM sd
),
quart AS (
    SELECT CAST('E. Store-day absence quartile (within store)' AS varchar(60)) AS analysis,
           CAST(CONCAT('Quartile ', q, CASE q WHEN 1 THEN ' (lowest absence)' WHEN 4 THEN ' (highest absence)' ELSE '' END) AS varchar(60)) AS relationship,
           COUNT(*) AS observations,
           ROUND(AVG(a) * 100, 2) AS avg_absence_rate_pct,
           ROUND(AVG(o) * 100, 2) AS avg_overtime_share_pct,
           ROUND(AVG(s), 2)       AS avg_sales_per_worked_hour_cad
    FROM qd GROUP BY q
)
SELECT analysis, relationship, observations,
       ROUND(r, 3) AS pearson_r,
       CASE WHEN r IS NULL THEN NULL WHEN ABS(r) < 0.1 THEN 'negligible' WHEN ABS(r) < 0.3 THEN 'weak'
            WHEN ABS(r) < 0.5 THEN 'moderate' ELSE 'strong' END AS strength_of_association,
       CAST(NULL AS float) AS avg_absence_rate_pct, CAST(NULL AS float) AS avg_overtime_share_pct, CAST(NULL AS float) AS avg_sales_per_worked_hour_cad
FROM c
UNION ALL
SELECT analysis, relationship, observations, CAST(NULL AS float), CAST(NULL AS varchar(12)),
       avg_absence_rate_pct, avg_overtime_share_pct, avg_sales_per_worked_hour_cad
FROM quart
ORDER BY analysis, relationship;
GO

/* ================= Q5  High visitors but relatively few purchases (compare like with like) =================
   One row per store. The comparison group is the OTHER stores at the SAME month, weekday and hour (Part 5 section 10),
   so a busy Saturday in December is never compared with a quiet Tuesday in February. Only hours with valid footfall count.
     conversion_index_vs_peers  < 1 = fewer purchases than peers would have at the same visitors, month, weekday and hour
     purchases_vs_peer_expectation = actual purchases minus the number peers' rates would predict (negative = shortfall)
     busy_hour_conversion_index = the same index, only in the network's busiest hours
     three_largest_purchase_gaps = the three weekday-hour cells (all months) where the store falls furthest short,
                                   among cells with at least min_cell_visitors visitors */
DECLARE @top  INT   = (SELECT CAST(value AS INT)   FROM dq.Assumptions WHERE name = 'top_traffic_rank');
DECLARE @cut  FLOAT = (SELECT CAST(value AS float) FROM dq.Assumptions WHERE name = 'conversion_index_flag');
DECLARE @minv INT   = (SELECT CAST(value AS INT)   FROM dq.Assumptions WHERE name = 'min_cell_visitors');

WITH cell AS (
    SELECT store_id, iso_weekday, weekday_name, hour_of_day,
           SUM(visitors) AS visitors, SUM(sale_txns) AS sale_txns, SUM(txn_gap) AS txn_gap
    FROM mart.conversion_peer
    GROUP BY store_id, iso_weekday, weekday_name, hour_of_day
),
worst AS (
    SELECT cell.*, ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY txn_gap ASC) AS rn
    FROM cell WHERE visitors >= @minv AND txn_gap IS NOT NULL
)
SELECT c.store_id, c.store_name, c.visitors, c.sale_txns,
       ROUND(c.conversion_rate * 100, 2)        AS conversion_pct,
       ROUND(c.conversion_index, 3)             AS conversion_index_vs_peers,
       ROUND(c.txn_gap, 0)                      AS purchases_vs_peer_expectation,
       ROUND(c.busy_hour_conversion_index, 3)   AS busy_hour_conversion_index,
       s.rank_visitors, s.rank_conversion,
       CASE WHEN s.rank_visitors <= @top AND c.conversion_index < @cut THEN 'HIGH TRAFFIC / LOW CONVERSION' ELSE '' END AS flag,
       (SELECT STRING_AGG(CONCAT(w.weekday_name, ' ', RIGHT('0' + CAST(w.hour_of_day AS varchar(2)), 2), ':00 (',
                                 CAST(CAST(ROUND(w.txn_gap, 0) AS int) AS varchar(10)), ')'), '; ') WITHIN GROUP (ORDER BY w.rn)
        FROM worst w WHERE w.store_id = c.store_id AND w.rn <= 3) AS three_largest_purchase_gaps
FROM mart.conversion_store c
JOIN mart.store_summary s ON s.store_id = c.store_id
ORDER BY c.conversion_index;
GO

/* ================= Q6  Where should leadership investigate first, and what data would confirm the case? =================
   The shortlist is a VIEW (mart.investigation_shortlist) that raises one flag per signal from Q2 to Q5:
     high labour cost % | high overtime share | high absence rate (z above z_flag) | one of the bottom N stores for sales per worked hour |
     high traffic with conversion below peers.   More flags = look at that store first.
   Flags are prompts to investigate, not findings of cause. */
IF OBJECT_ID(N'mart.investigation_shortlist', N'U') IS NOT NULL DROP TABLE mart.investigation_shortlist;   -- it was a table in the earlier version
GO
CREATE OR ALTER VIEW mart.investigation_shortlist
AS
WITH a AS (
    SELECT MAX(CASE WHEN name = 'z_flag'                  THEN value END) AS z,
           MAX(CASE WHEN name = 'conversion_index_flag'   THEN value END) AS cut,
           MAX(CASE WHEN name = 'top_traffic_rank'        THEN value END) AS top_rank,
           MAX(CASE WHEN name = 'bottom_sales_per_hour_n' THEN value END) AS bottom_n
    FROM dq.Assumptions
)
SELECT x.*,
       x.high_labour_cost_pct + x.high_overtime + x.high_absence + x.bottom_sales_per_hour + x.high_traffic_low_conversion AS flags_raised
FROM (
    SELECT s.store_id, s.store_name,
           CASE WHEN s.z_labour_cost_pct > a.z THEN 1 ELSE 0 END AS high_labour_cost_pct,
           CASE WHEN s.z_overtime_share  > a.z THEN 1 ELSE 0 END AS high_overtime,
           CASE WHEN s.z_absence_rate    > a.z THEN 1 ELSE 0 END AS high_absence,
           CASE WHEN s.rank_sales_per_hour > (SELECT COUNT(*) FROM mart.store_summary) - a.bottom_n THEN 1 ELSE 0 END AS bottom_sales_per_hour,
           CASE WHEN c.conversion_index < a.cut AND s.rank_visitors <= a.top_rank THEN 1 ELSE 0 END AS high_traffic_low_conversion,
           ROUND(s.net_sales_cad, 0)          AS net_sales_cad,
           ROUND(s.sales_per_worked_hour, 2)  AS sales_per_worked_hour,
           ROUND(c.conversion_index, 3)       AS conversion_index
    FROM mart.store_summary s
    JOIN mart.conversion_store c ON c.store_id = s.store_id
    CROSS JOIN a
) x;
GO
SELECT store_id, store_name, flags_raised,
       high_labour_cost_pct, high_overtime, high_absence, bottom_sales_per_hour, high_traffic_low_conversion,
       net_sales_cad, sales_per_worked_hour, conversion_index,
       CONCAT_WS('; ',
            CASE WHEN high_labour_cost_pct = 1          THEN 'labour cost % of sales' END,
            CASE WHEN high_overtime = 1                 THEN 'overtime share' END,
            CASE WHEN high_absence = 1                  THEN 'absence rate' END,
            CASE WHEN bottom_sales_per_hour = 1         THEN 'sales per worked hour' END,
            CASE WHEN high_traffic_low_conversion = 1   THEN 'purchases below peers at high traffic' END) AS investigate_first
FROM mart.investigation_shortlist
ORDER BY flags_raised DESC, net_sales_cad DESC;
GO

/*   ===================================================================== */
USE Task2_DataWH;
GO
/* The ten mart objects to import, and their sizes */
SELECT 'mart.dim_store' AS mart_object, COUNT(*) AS row_count FROM mart.dim_store
UNION ALL SELECT 'mart.dim_date', COUNT(*) FROM mart.dim_date
UNION ALL SELECT 'mart.store_hour', COUNT(*) FROM mart.store_hour
UNION ALL SELECT 'mart.sales_store_hour_category', COUNT(*) FROM mart.sales_store_hour_category
UNION ALL SELECT 'mart.store_day', COUNT(*) FROM mart.store_day
UNION ALL SELECT 'mart.store_month', COUNT(*) FROM mart.store_month
UNION ALL SELECT 'mart.store_summary', COUNT(*) FROM mart.store_summary
UNION ALL SELECT 'mart.conversion_peer', COUNT(*) FROM mart.conversion_peer
UNION ALL SELECT 'mart.conversion_store', COUNT(*) FROM mart.conversion_store
UNION ALL SELECT 'mart.investigation_shortlist (view)', COUNT(*) FROM mart.investigation_shortlist;

/* Audit evidence for the report appendix: copy results to Excel, or screenshot */
SELECT * FROM dq.BusinessRuleChecks WHERE issue_rows > 0 AND note NOT LIKE 'info%' ORDER BY table_name, check_name;
SELECT * FROM dq.cleaning_log;
SELECT * FROM dq.cleaning_detail;
SELECT * FROM dq.cleaning_decisions;
SELECT * FROM dq.mart_reconciliation;
SELECT table_name, column_name, problem_code, severity, COUNT(*) AS affected_records
FROM dq.ConversionExceptions GROUP BY table_name, column_name, problem_code, severity ORDER BY severity, affected_records DESC;
GO


/* #####################################################################################################
   PART 8 - CLEAN-UP (run last)
   Drops the seven dq.src_* row-lineage copies of the raw tables (about 3.7 million rows). They were only needed to trace a
   problem value back to its original row; dq.ConversionExceptions already keeps every original value as text.
   Raw tables, clean, core and mart are NOT touched. Re-running Part 1 recreates the copies.
   ##################################################################################################### */
USE Task2_DataWH;
GO
DROP TABLE IF EXISTS dq.src_Stores;
DROP TABLE IF EXISTS dq.src_Products;
DROP TABLE IF EXISTS dq.src_Employees;
DROP TABLE IF EXISTS dq.src_SalesTransactions;
DROP TABLE IF EXISTS dq.src_SalesLineItems;
DROP TABLE IF EXISTS dq.src_StaffShifts;
DROP TABLE IF EXISTS dq.src_StoreFootfall;
GO
/* What is left, by schema and type */
SELECT s.name AS schema_name,
       SUM(CASE WHEN o.type = 'U' THEN 1 ELSE 0 END) AS tables,
       SUM(CASE WHEN o.type = 'V' THEN 1 ELSE 0 END) AS views
FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V') AND s.name IN (N'raw', N'clean', N'dq', N'stg', N'core', N'work', N'mart')
GROUP BY s.name ORDER BY s.name;
GO
