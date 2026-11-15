FIELD-LEVEL DIFFERENCE REPORT FOR CHANGED RECORDS - READ ONLY
Version 2.0, 2026-11-15

PURPOSE
For one table, compares every column of the records that a previous
RecordCompare run classified as CHANGED, using live data from the SOURCE and
TARGET databases. Use it to decide whether a full-row UPDATE is acceptable
before approving or deferring updates in ApprovedSync.

This is REPORTING ONLY: the script never INSERTs, UPDATEs, DELETEs, or
changes database schema. PGOPTIONS enforces read-only sessions.
It does not use the ApprovedSync script.

REQUIREMENTS
* Windows PowerShell 5.1; psql.exe (default C:\Program Files\PostgreSQL\18\bin,
  or -PsqlPath).
* A PostgreSQL role with SELECT on the table in both databases
  (authentication options: see the toolkit README.txt).
* A complete RecordCompare run folder with comparison-summary.csv and the
  table's record-ids/<schema>_<table>-*.csv.gz. Details must not be
  truncated (the default -MaxDetailRowsPerTable 0).
* The table needs a single-column primary key and the same columns in both
  databases.
* Record keys must be plain text of 1-128 characters from A-Z a-z 0-9 _ . : @ -
  (integers, UUIDs and most codes). Other keys stop the report.

STEP 1: LOCAL SYNTAX CHECK (no network/database access)
& '.\FieldLevelDiff\Test-FieldLevelDiff-Syntax.ps1'

STEP 2: GENERATE FIELD DIFFERENCES
& '.\FieldLevelDiff\Compare-ChangedRecordFields.ps1' `
    -Server 'pg.example.com' -UserName 'compare_reader' `
    -SourceDatabase 'app_new' -TargetDatabase 'app' `
    -Table 'public.customers' `
    -ComparisonRunDirectory '.\DatabaseRecordCompare\<exact-run-folder>'

Optional parameters:
  -OutputDirectory '.\FieldLevelDiffReports\customers-review-01'
      Must not exist yet. Default: FieldLevelDiffReports\<schema_table>-<UTC timestamp>
      under the current directory.
  -ExpectedCandidateCount <n>
      Stops if the comparison run recorded a different number of CHANGED records.
  -Port, -SslMode, -ManagedIdentityClientId: as for the other toolkit scripts.

EXPECTED OUTPUT FILES
* field-differences.csv
   Each differing column of each record: record key, column name,
   data type, SOURCE canonical JSON value, TARGET canonical JSON value,
   and null flags. E.g. string values appear with JSON double quotes;
   SQL NULL appears as null (unquoted).
* record-summary.csv
   One row for each historical CHANGED key, including current
   state (CHANGED/NOW_MATCHING/SOURCE_MISSING/TARGET_MISSING/BOTH_MISSING),
   columns that differ, old/current SHA-256 row hashes, and drift flags.
* column-summary.csv
   Counts of currently changed records per column (including zero counts).
* report-summary.json
   Totals, key column, timestamps, and source/target details.
* logs/*.stderr.log
   PostgreSQL error messages, if any.

NOTES AND SAFETY
1. Only keys listed as CHANGED in the selected comparison run are inspected.
   This avoids a full-table scan but DOES NOT identify new differences among
   previously unchanged keys. For a refreshed key set, rerun
   Compare-TableRecords.ps1 with -Tables @('<schema.table>') to a NEW run
   directory, then point -ComparisonRunDirectory at that directory.
   SOURCE_ONLY and TARGET_ONLY keys exist on one side only and are not part
   of this report.
2. Records may have changed since the comparison. The report flags current
   row hashes that differ from their original source/target fingerprints.
3. SOURCE and TARGET queries are independent read snapshots, not one atomic
   snapshot across databases; avoid concurrent writes for best accuracy.
4. If the databases use different encodings (for example UTF8 and SQL_ASCII),
   conversion to UTF8 may fail on invalid text. The reporter will STOP on error
   rather than silently discard or replace bytes.
5. All CHANGED keys are read in a single query. For many thousands of
   records, expect a long query and a large report.
6. The report contains sensitive row values. Keep it on restricted storage,
   secure its ACL, and do not upload or distribute unredacted values.
7. This package does NOT approve or deploy any updates.
8. If prompted about execution policy, use your organization's approved
   signed-script workflow; do not disable machine-wide security policies.
