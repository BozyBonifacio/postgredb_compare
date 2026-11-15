APPROVED INSERT / UPDATE SYNCHRONIZATION - V2.0 (2026-11-15)
============================================================
Script: Sync-ApprovedRecords.ps1

Copies an explicitly approved set of records from a SOURCE database to a TARGET
database on the same PostgreSQL server:
- INSERT records that exist only in the source (SOURCE_ONLY);
- UPDATE records whose full-row fingerprint differs (CHANGED);
- NEVER DELETE: target-only records, tables and indexes are preserved.

The approved set comes from two inputs:
1. A complete RecordCompare run folder (the BASELINE), which lists the key and
   SHA-256 fingerprints of every differing record.
2. An approval manifest CSV stating, per table, which operations are approved.

Every record is re-verified against its baseline fingerprints at deployment
time; a table stops if anything changed since the baseline.

APPROVAL MANIFEST
-----------------
See ApprovedScope.example.csv. One row per table. Columns:
  Table                      schema.table, as in comparison-summary.csv
  SourceOnlyCandidates       SOURCE_ONLY count from the baseline
  ChangedCandidates          CHANGED count from the baseline
  TargetOnlyPreserved        TARGET_ONLY count from the baseline (never deleted)
  InsertApproval             Approved | Deferred | Rejected | Not applicable
  UpdateApproval             Approved | Deferred | Rejected | Not applicable
  DeleteApproval             must be REJECTED
  ApprovedInsertCandidates   SourceOnlyCandidates when Approved, otherwise 0
  ApprovedUpdateCandidates   ChangedCandidates when Approved, otherwise 0
  ApprovedDeleteCandidates   must be 0
Other columns (for example Notes) are ignored.

Rules enforced by the script:
- An Approved operation covers ALL baseline candidates of that operation in
  the table; there is no per-record approval.
- Any other value (Deferred, Rejected, ...) excludes the operation and must
  have an approved count of 0. A table can have its inserts approved and its
  updates deferred.
- Only tables with at least one approved candidate are deployed.
- Duplicate rows, approved deletes, and counts that do not match the baseline
  stop the run. Approval values are case-sensitive.

The manifest's SHA-256 is recorded at Prepare; Validate and Apply refuse a
modified manifest. To change the scope, Prepare again into a NEW RunDirectory.

IMPORTANT WARNINGS
------------------
* Before applying, VERIFY restorable backups and test the approved scope on a
  point-in-time-restored CLONE of the PostgreSQL server.
* On most managed PostgreSQL services (for example Azure Database for
  PostgreSQL Flexible Server), point-in-time restore creates a NEW server; it
  does NOT overwrite an existing database. A targeted rollback is not automatic.
* Prepare reads source rows and writes them to disk; protect the staging
  directory with restricted access and do not upload or commit it.
* Every table is a separate SQL transaction. If one fails, earlier committed
  tables stay committed. Do NOT automatically re-run an interrupted Apply.
* The baseline comparison is historical. A table fails closed if an approved
  record changed in source or target since that baseline.
* Source-only keys that have appeared in the target since the comparison
  cause a STOP.
* If the two databases use different encodings/collations (for example a UTF8
  source and a SQL_ASCII target), inserting text may preserve bytes but does
  NOT convert the target database.
* Full-row UPDATE copies every non-key column of each approved CHANGED record.
  If business rules require retaining selected target-side fields, defer those
  updates (review them with FieldLevelDiff) rather than applying them.
* Source/target database tables are NEVER dropped, truncated, renamed or deleted.

PREREQUISITES
-------------
- Windows PowerShell 5.1; psql.exe (default
  C:\Program Files\PostgreSQL\18\bin\psql.exe, or -PsqlPath).
- A PostgreSQL role with SELECT on the source and TEMP, SELECT, INSERT and
  UPDATE privileges on the target. Authentication options: see the toolkit
  README.txt.
- A complete baseline folder from RecordCompare\Compare-TableRecords.ps1 v2.0
  with untruncated details (the default -MaxDetailRowsPerTable 0), including:
    comparison-summary.csv
    source-catalog.csv / target-catalog.csv
    run-config.json   (must name the same source and target databases)
    record-ids\*.csv.gz
- Deployed tables need a single-column primary key (the same in both
  databases) and identical columns.
- Keys of the records to deploy must be plain text of 1-128 characters from
  A-Z a-z 0-9 _ . : @ - (integers, UUIDs and most codes). Other keys stop
  Prepare for that table.
- Enough local disk space for the extracted approved rows.

0) OFFLINE SYNTAX AND MANIFEST TEST
-----------------------------------
& '.\ApprovedSync\Test-ApprovedSync-Syntax.ps1' -ApprovalManifest 'C:\approvals\ApprovedScope.csv'

Optional tripwires that must match the signed-off scope:
-ExpectedApprovedTableCount <n> -ExpectedInsertCount <n> -ExpectedUpdateCount <n>

COMMON VARIABLES USED BELOW
---------------------------
$Script = '.\ApprovedSync\Sync-ApprovedRecords.ps1'
$Common = @{
    UserName            = 'sync_writer'
    SourceDatabase      = 'app_new'
    TargetDatabase      = 'app'
    ComparisonDirectory = '.\DatabaseRecordCompare\<baseline-run-folder>'
    ApprovalManifest    = 'C:\approvals\ApprovedScope.csv'
}
# Azure managed identity: $Common.ManagedIdentityClientId = '<client-id>'
$ProdServer  = 'pg-prod.example.com'
$PilotTables = @('public.orders','public.customers')

-Server is passed separately because it differs between production and clone.

1) PILOT PREPARE - SOURCE READS ONLY, NO TARGET CHANGES
-------------------------------------------------------
$PilotRun = '.\DatabaseSync\Pilot-01'
& $Script @Common -Server $ProdServer -Mode Prepare -RunDirectory $PilotRun -Tables $PilotTables

This checks that the live source and target catalogs still match the baseline,
checks the baseline key files and candidate counts against the manifest, then
exports ONLY approved source records to local CSV staging files. No permanent
database objects are touched.

2) PILOT VALIDATE - NO PERMANENT TARGET CHANGES
------------------------------------------------
& $Script @Common -Server $ProdServer -Mode Validate -RunDirectory $PilotRun -Tables $PilotTables

This imports prepared records into TEMPORARY target tables, checks old/new row
SHA256 fingerprints and counts, and ROLLS BACK. No INSERTs or UPDATEs reach the
target tables. It rejects stale candidates, missing rows and schema drift.

3) CLONE TEST - REQUIRED BEFORE PRODUCTION APPLY
------------------------------------------------
Create a point-in-time restored TEST SERVER with both databases. Ensure the
PostgreSQL role can log in there. Use the clone's real hostname.

$CloneServer = 'pg-clone.example.com'
$CloneRun = '.\DatabaseSync\ClonePilot-01'

& $Script @Common -Server $CloneServer -Environment Clone -Mode Prepare -RunDirectory $CloneRun -Tables $PilotTables
& $Script @Common -Server $CloneServer -Environment Clone -Mode Validate -RunDirectory $CloneRun -Tables $PilotTables

After clone Validate passes, and ONLY on the restored server:
& $Script @Common -Server $CloneServer -Environment Clone -Mode Apply -RunDirectory $CloneRun -Tables $PilotTables `
    -ProductionServer $ProdServer -ConfirmTargetDatabase 'app' -CloneTargetServerConfirmed

If the clone data diverges from the baseline, the guard will fail. Do not
bypass it. Obtain a fresh comparison and a corresponding approved scope.
Review post-write counts and application/row behavior on the clone.

IMPORTANT: A pilot does NOT prove the full scope. On the clone, also execute
the complete approved scope using a fresh run directory (no -Tables):

$CloneFull = '.\DatabaseSync\CloneFull-01'
& $Script @Common -Server $CloneServer -Environment Clone -Mode Prepare -RunDirectory $CloneFull
& $Script @Common -Server $CloneServer -Environment Clone -Mode Validate -RunDirectory $CloneFull
& $Script @Common -Server $CloneServer -Environment Clone -Mode Apply -RunDirectory $CloneFull `
    -ProductionServer $ProdServer -ConfirmTargetDatabase 'app' -CloneTargetServerConfirmed

Only declare -CloneTestPassed after every table transaction completes
successfully and the post-apply results and application behavior are checked.

4) PRODUCTION PREPARE / VALIDATE ALL APPROVED TABLES
----------------------------------------------------
$FullRun = '.\DatabaseSync\Full-01'
& $Script @Common -Server $ProdServer -Mode Prepare -RunDirectory $FullRun
& $Script @Common -Server $ProdServer -Mode Validate -RunDirectory $FullRun

These two steps do not write to permanent target tables. Add
-ExpectedApprovedTableCount <n> to stop if the manifest does not contain
exactly the expected number of deployable tables.

5) PRODUCTION APPLY - ONLY WHEN ALL SAFETY GATES ARE SATISFIED
---------------------------------------------------------------
REQUIRE: documented and tested server restore route, confirmed production backup,
verified successful clone Apply, active maintenance/change window, and approved
business rules for full-row UPDATE of the changed records.

& $Script @Common -Server $ProdServer -Mode Apply -RunDirectory $FullRun `
    -ProductionServer $ProdServer -ConfirmTargetDatabase 'app' `
    -BackupRestoreVerified -CloneTestPassed

The script applies ONLY preapproved keys. Each table is BEGIN ... INSERT/UPDATE ...
SHA256 verification ... COMMIT, and writes applied.ok after confirmed exit 0.
There are NO DELETE, TRUNCATE, DROP TABLE or schema-replacement statements.

APPLY SAFETY GUARDS
- -ConfirmTargetDatabase must repeat -TargetDatabase.
- -ProductionServer names the production host. Production Apply requires
  -Server to equal it; Clone Apply requires -Server to differ from it
  (hostnames are compared case-insensitively).
- Production Apply also requires -BackupRestoreVerified and -CloneTestPassed;
  Clone Apply requires -CloneTargetServerConfirmed.
- -SourceDatabase and -TargetDatabase must match the baseline run-config.json.

6) POST-DEPLOYMENT CHECK
-------------------------
- Inspect all logs under <RunDirectory>\logs and per-table applied.ok files.
- Confirm that every table in metadata\selected-approved-scope.csv completed
  before reporting overall success.
- Re-run the record comparison on a fresh baseline and examine remaining diffs.
- Verify that target-only indexes remain present.
- Confirm target-only records were preserved; the script never deletes rows.
- Verify application behavior, text sorting, permissions and write latency.

AUDIT / FAILURE BEHAVIOR
------------------------
- Every generated source CSV, SQL file and key list has SHA256 in files.sha256.csv.
- Mode Validate / Apply refuse modified/missing files.
- Changes to table/column/primary-key catalog signatures abort the run.
- Any SQL error aborts that table's transaction. Earlier tables may already
  be committed and require individual reconciliation.
- Applied tables cannot be run twice in the same RunDirectory.
- DO NOT DELETE applied.ok or try to skip a failed table without investigation.

This tool is not a replacement for change-control approval, validated restores,
and a tested deployment/rollback procedure.
