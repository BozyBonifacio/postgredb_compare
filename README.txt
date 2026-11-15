POSTGRESQL DATABASE COMPARE AND APPROVED SYNC TOOLKIT
=====================================================
Version 2.0 (2026-11-15)

Windows PowerShell 5.1 scripts for two PostgreSQL databases on the same server:
a SOURCE that holds newer data and a TARGET that must be preserved. The scripts
report schema and record-level differences and can copy an explicitly approved
set of INSERTs and UPDATEs into the target. Nothing is ever deleted from the
target.

COMPONENTS
----------
  SchemaCompare\Compare-DatabaseSchemas.ps1        READ-ONLY
      Schema catalog differences, row estimates, optional exact counts.
  RecordCompare\Compare-TableRecords.ps1           READ-ONLY
      Record-level comparison by primary key using SHA-256 row fingerprints.
  FieldLevelDiff\Compare-ChangedRecordFields.ps1   READ-ONLY
      Column-by-column values for one table's CHANGED records.
  ApprovedSync\Sync-ApprovedRecords.ps1            WRITES TO TARGET (Apply only)
      Prepare / Validate / Apply of approved INSERTs and UPDATEs.

Each folder has its own README.txt with step-by-step instructions.

TYPICAL WORKFLOW
----------------
1. SchemaCompare: find and resolve schema differences first, using separately
   reviewed migrations. Record comparison needs identical table definitions.
2. RecordCompare: run a full comparison (-AllTables) to list SOURCE_ONLY,
   CHANGED and TARGET_ONLY records per table.
3. FieldLevelDiff: review CHANGED records where a full-row UPDATE needs a
   business decision.
4. Write an approval manifest (see ApprovedSync\ApprovedScope.example.csv).
5. ApprovedSync: Prepare -> Validate -> Apply on a restored clone -> Apply on
   production.

REQUIREMENTS
------------
- Windows PowerShell 5.1.
- PostgreSQL client tools: psql.exe for all components, plus pg_dump.exe for
  SchemaCompare. The default path is C:\Program Files\PostgreSQL\18\bin; use
  -PsqlPath / -PgDumpPath for another location. Use a client version at least
  as new as the server.
- Network access to the server and a PostgreSQL role with:
    read-only components: CONNECT and SELECT on both databases
    ApprovedSync: SELECT on the source; TEMP, SELECT, INSERT, UPDATE on the target
- Record-level tools work on tables with a single-column primary key (any
  column name or data type) that is the same in both databases.

COMMON PARAMETERS
-----------------
  -Server                   PostgreSQL host name (required)
  -Port                     default 5432
  -UserName                 PostgreSQL role name (required)
  -SourceDatabase           database with the newer data (required)
  -TargetDatabase           database to preserve (required, must differ)
  -SslMode                  libpq sslmode; default require
  -ManagedIdentityClientId  optional; see AUTHENTICATION

AUTHENTICATION
--------------
Without -ManagedIdentityClientId, standard libpq authentication applies: the
PGPASSWORD environment variable, %APPDATA%\postgresql\pgpass.conf, client
certificates, and so on. psql runs with -w, so it never prompts for a password.

On an Azure VM, pass -ManagedIdentityClientId with the CLIENT ID (GUID) of a
user-assigned managed identity. The scripts then request an Entra ID access token
from the Azure Instance Metadata Service and use it as the password for Azure
Database for PostgreSQL. -UserName is the PostgreSQL role mapped to that
identity. The client ID is neither the role name nor the identity's resource ID.

EXAMPLE
-------
Run from the toolkit folder. The connection parameters are splatted:

  $Conn = @{
      Server         = 'pg.example.com'
      UserName       = 'compare_reader'
      SourceDatabase = 'app_new'
      TargetDatabase = 'app'
  }
  & .\SchemaCompare\Compare-DatabaseSchemas.ps1 @Conn
  & .\RecordCompare\Compare-TableRecords.ps1 @Conn -Tables @('public.customers') -PreflightOnly

SAFETY PRINCIPLES
-----------------
- The read-only components set default_transaction_read_only=on for every
  PostgreSQL session and run only SELECT, COPY (SELECT ...) TO STDOUT and
  pg_dump --schema-only.
- ApprovedSync never generates DELETE, TRUNCATE, DROP or schema changes.
  Target-only records and target-only indexes are preserved.
- Every approved record is re-checked against its baseline fingerprint at
  deployment time. A table stops if anything changed since the comparison.
- Outputs (record keys, staging CSVs, field values) can contain sensitive data.
  Keep them on restricted storage and do not commit them to source control.
  The .gitignore excludes the default output folders.
- Run the offline self-tests first, then pilots, then a clone, before production.

VERIFYING FILES
---------------
SHA256SUMS.txt lists a SHA-256 hash for every toolkit file. To check one file:
  (Get-FileHash -Algorithm SHA256 .\RecordCompare\Compare-TableRecords.ps1).Hash
To check all of them from Git Bash or Linux:
  sha256sum -c SHA256SUMS.txt
