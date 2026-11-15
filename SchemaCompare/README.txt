PostgreSQL Database Schema Comparison (READ-ONLY)
=================================================

Script: Compare-DatabaseSchemas.ps1
Supported: Windows PowerShell 5.1; PostgreSQL 18 psql.exe and pg_dump.exe
           (any client version at least as new as the server).

Compares the schema catalogs of a SOURCE and a TARGET database on the same
server and records quick per-table row estimates. Only pg_dump --schema-only
and SELECT queries are executed.

PREREQUISITES
1. A machine with network access to the server and both databases.
2. psql.exe and pg_dump.exe. The default folder is
   C:\Program Files\PostgreSQL\18\bin; override with -PsqlPath / -PgDumpPath.
3. A PostgreSQL role that can CONNECT and read catalogs/definitions in BOTH
   databases. For authentication options (libpq or Azure managed identity),
   see the toolkit README.txt.

RUN - READ-ONLY SCHEMA + QUICK DATA ESTIMATES
& '.\SchemaCompare\Compare-DatabaseSchemas.ps1' `
    -Server 'pg.example.com' -UserName 'compare_reader' `
    -SourceDatabase 'app_new' -TargetDatabase 'app'

Optional: -Port 5433, -SslMode verify-full (default require),
-ManagedIdentityClientId '<client-id>' on an Azure VM.

OPTIONAL - ADD EXACT ROW COUNTS FOR SELECTED TABLES (HEAVY)
Add -ExactCountTables @('public.customers','public.orders') to the command above.

OUTPUT
Each run creates a separate timestamped folder under -OutputRoot
(default: DatabaseCompare in the current directory):
  .\DatabaseCompare\yyyyMMdd-HHmmss-fff\

IMPORTANT REVIEW FILES
- README-review.txt                  instructions and summary
- schema-differences.csv            table, column, index, constraint,
                                    view, function, trigger, sequence,
                                    extension and policy differences
- data-row-estimates.csv            quick, approximate row counts and sizes
- tables-without-primary-keys.csv    data merge key warnings
- data-exact-counts.csv             optional; only if requested
- source-schema-review.sql          source DDL snapshot
- target-schema-review.sql          target DDL snapshot
- source-*.csv / target-*.csv        complete catalog snapshots

OPTIONAL VISUAL DIFF
Open a terminal in the report directory with VS Code in PATH:
  code --diff "target-schema-review.sql" "source-schema-review.sql"

INTERPRETATION
OnlyInSource       Object is in source but missing from target.
OnlyInTarget       Object is in target but missing from source.
DifferentDefinition Object exists in both but definitions differ.

WARNING / LIMITATIONS
- Source data is NOT copied. Target database is NOT changed.
- The generated SQL schema files are reference snapshots, NOT safe
  deployment migrations. DO NOT RUN them on the target database.
- Estimated row counts can be stale and exact counts cannot identify
  inserted, updated, or deleted records. Use RecordCompare for that.
- Before data synchronization, review unique keys and desired behavior:
  insert missing rows, update changed rows, keep/delete target-only rows.
- Source/target comparisons occur sequentially, not in a single global
  snapshot. For reliable data-change reviews, establish a stable data
  cutoff/snapshot or maintenance window.
- No ordinary schema migration changes a database's encoding or default
  collation. README-review.txt warns when source and target differ.
- Ownership and GRANT/REVOKE ACL differences need separate review.
- If authentication or permission errors occur, do not proceed to
  deployment; inspect the failing step first.
