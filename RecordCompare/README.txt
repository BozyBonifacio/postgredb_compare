POSTGRESQL RECORD-LEVEL COMPARISON - READ ONLY
Version: 2.0, 2026-11-15

PURPOSE
Compares every record of the selected tables between a SOURCE and a TARGET
database on the same server. Records are matched on each table's
single-column primary key and compared using a SHA-256 fingerprint of the
full row.

This package DOES NOT perform a database deployment. It only reads tables and
writes local comparison reports. Do not restore a full source dump over the
target as a way of 'synchronizing' it: a dump can recreate tables.

REQUIREMENTS
* Windows PowerShell 5.1, PostgreSQL 18 psql.exe (or -PsqlPath)
* A PostgreSQL role with SELECT access to the compared tables in BOTH databases
  (authentication options: see the toolkit README.txt)
* Free disk space for two temporary (key + SHA-256) exports of the largest table
* Keep all packaged files together in the RecordCompare folder

WHICH TABLES ARE COMPARED
Ordinary tables in any user schema that have:
  - a single-column primary key (any column name or data type), and the same
    primary key column in both databases;
  - identical column names, order and types in both databases.
Keys are matched by their text form. Other tables are reported with status
INCOMPATIBLE and a warning, and are skipped.

The examples below splat the connection parameters:
  $Conn = @{ Server='pg.example.com'; UserName='compare_reader'; SourceDatabase='app_new'; TargetDatabase='app' }
On an Azure VM with a managed identity, also add ManagedIdentityClientId='<client-id>'.

STEP 1 - LOCAL SELF-TEST (NO DATABASE ACCESS)
  & '.\RecordCompare\Test-RecordCompare-Local.ps1'

STEP 2 - FAST DATABASE SQL PREFLIGHT (READ ONLY, ZERO ROWS)
  & '.\RecordCompare\Compare-TableRecords.ps1' @Conn `
      -Tables @('public.customers', 'public.orders') `
      -PreflightOnly

This validates the generated query in BOTH databases without exporting table rows.
It DOES NOT check whether data is valid for conversion or whether hashes match.
The preflight creates a separate local output folder; no result comparison is made.

STEP 3 - SMALL REAL PILOT (READ ONLY)
  & '.\RecordCompare\Compare-TableRecords.ps1' @Conn `
      -Tables @('public.customers', 'public.orders')

STEP 4 - COMPLETE DATABASE RECORD COMPARISON (READ ONLY)
  & '.\RecordCompare\Compare-TableRecords.ps1' @Conn `
      -AllTables

A complete run compares every eligible table in every user schema of the
SOURCE. Add -Schemas @('public') to limit -AllTables to the listed schemas.
It can take many hours or longer on large datasets, and will do large table
scans and sorts on the PostgreSQL server. Choose a quiet maintenance window,
monitor CPU/IO/temp space on PostgreSQL, and avoid simultaneous DDL.

STEP 5 - RESUME AN INTERRUPTED COMPLETE RUN
  $RunDir = '.\DatabaseRecordCompare\<exact-run-folder>'
  & '.\RecordCompare\Compare-TableRecords.ps1' @Conn `
      -AllTables -RunDirectory $RunDir -Resume

Use the same server, port, databases, table selection and detail limit as the
original run; the script refuses to resume otherwise.

OUTPUT IN EACH RUN FOLDER
Default location: DatabaseRecordCompare\<UTC timestamp>-<id> under the current
directory (change with -OutputRoot or -RunDirectory).
  comparison-summary.csv: One row per table, detailed counts and status
    SOURCE_ONLY:   key exists in source, absent from target (INSERT candidate)
    CHANGED:       key exists in both; SHA-256(row JSON) differs (UPDATE candidate)
    TARGET_ONLY:   key exists in target, absent from source (PRESERVE)
    UNCHANGED:     Matching key and SHA-256(row JSON)
  record-ids/*.csv.gz: Compressed CSVs with the record key and both SHA-256
    fingerprints for SOURCE_ONLY / CHANGED / TARGET_ONLY, one file per table.
  results/*.json: Resumable per-table completion records
  run-config.json: Server, databases and table selection of this run
  source-catalog.csv / target-catalog.csv: Table/column/primary-key safety inventory
  logs/*.err.log: PostgreSQL client diagnostic output

A complete run folder is the baseline for FieldLevelDiff and ApprovedSync.

IMPORTANT LIMITATIONS
1. Record content is compared through SHA256(UTF8(to_jsonb(row)::text)) fingerprints.
   This is a highly reliable change detector, but not a formal byte-for-byte
   proof of equality or a field-level comparison. Normalization of JSON values
   and differing database encodings (for example UTF8 vs SQL_ASCII) may matter
   for some records.
2. The source and target exports use separate statement-level snapshots;
   they are NOT an atomic cross-database snapshot. Active database writes
   can create timing discrepancies. Recheck before approving deployment.
3. The 'CHANGED' classification does not list individual changed columns.
   It lists the key + source and target hashes. For a field-level review, use
   FieldLevelDiff\Compare-ChangedRecordFields.ps1.
4. No schema deployment or data modification is performed, and no DELETEs
   are proposed. Existing target-only records and all target indexes remain.
5. This script explicitly REJECTS write transactions via PostgreSQL session
   parameter default_transaction_read_only=on.
6. If a database contains invalid text bytes (possible in a SQL_ASCII
   database), some fingerprint queries may fail; such tables are NOT marked
   as compared.
7. Details can be large and contain record keys. Restrict folder access and
   transfer/share them only through authorized channels.
8. If the source/target schema changes during a run or between resume passes,
   comparison may fail or report incomplete; review catalogs and rerun.
9. Output is a change REVIEW artifact, not deployment SQL.

DO NOT APPLY CHANGES until comparison, per-field review, backups / point-in-
time restore, target-only retention, and a controlled merge plan are approved.

OPTIONAL - REBUILD SUMMARY EVEN IF A FULL RUN WAS INTERRUPTED
  & '.\RecordCompare\Summarize-RecordComparison.ps1' `
      -RunDirectory '.\DatabaseRecordCompare\<exact-run-folder>'

IMPORTANT: An incomplete run summary covers ONLY tables with saved results.
Do not treat it as a full database comparison. No database query occurs here.

VERSION HISTORY
See CHANGELOG.txt.
