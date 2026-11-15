# Compare-DatabaseSchemas.ps1
# Windows PowerShell 5.1 + PostgreSQL 18 client tools
# READ-ONLY: Only pg_dump --schema-only and SELECT queries are executed.
# Does not create, alter, insert into, delete from, or drop database objects.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Server,
    [ValidateRange(1, 65535)]
    [int]$Port = 5432,
    [Parameter(Mandatory = $true)]
    [string]$UserName,
    [Parameter(Mandatory = $true)]
    [string]$SourceDatabase,
    [Parameter(Mandatory = $true)]
    [string]$TargetDatabase,

    # Optional Azure user-assigned managed identity client ID. When supplied, an Entra ID
    # access token is used as the password. Otherwise standard libpq authentication applies
    # (PGPASSWORD, pgpass.conf, certificates, ...).
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ManagedIdentityClientId,

    [ValidateSet('disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full')]
    [string]$SslMode = 'require',
    [string]$OutputRoot = (Join-Path (Get-Location -PSProvider FileSystem).ProviderPath 'DatabaseCompare'),
    [string]$PgDumpPath = 'C:\Program Files\PostgreSQL\18\bin\pg_dump.exe',
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',

    # Optional EXACT counts, e.g. -ExactCountTables @('public.customers', 'public.orders')
    # Exact counts require reading entire selected tables on BOTH databases.
    [string[]]$ExactCountTables = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($SourceDatabase -ceq $TargetDatabase) {
    throw 'SourceDatabase and TargetDatabase must be different.'
}
$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)

function Assert-CommandPath {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label executable not found: $Path"
    }
}

function Refresh-ManagedIdentityToken {
    # Without a managed identity, libpq resolves the password itself.
    if ([string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) { return }
    $resource = [Uri]::EscapeDataString('https://ossrdbms-aad.database.windows.net')
    $identity = [Uri]::EscapeDataString($ManagedIdentityClientId)
    $url = 'http://169.254.169.254/metadata/identity/oauth2/token' +
           "?api-version=2018-02-01&resource=$resource&client_id=$identity"
    $result = Invoke-RestMethod -Method Get -Uri $url `
        -Headers @{ Metadata = 'true' } -TimeoutSec 20
    if ([string]::IsNullOrWhiteSpace($result.access_token)) {
        throw 'Azure Instance Metadata Service returned an empty PostgreSQL token.'
    }
    $env:PGPASSWORD = $result.access_token
}

function Invoke-SchemaDump {
    param([string]$Database, [string]$OutputFile)
    Write-Host "Schema-only snapshot: $Database" -ForegroundColor Cyan
    & $PgDumpPath `
        --schema-only `
        --no-owner `
        --no-privileges `
        --lock-wait-timeout=5000 `
        --no-password `
        -h $Server `
        -p $Port `
        -U $UserName `
        -d $Database `
        -f $OutputFile
    if ($LASTEXITCODE -ne 0) {
        throw "pg_dump failed for '$Database' (exit code $LASTEXITCODE). Comparison not completed."
    }
}

function Invoke-ReadOnlyCsv {
    param([string]$Database, [string]$Sql, [string]$OutputFile)
    & $PsqlPath `
        -X -w --csv `
        -h $Server `
        -p $Port `
        -U $UserName `
        -d $Database `
        -v 'ON_ERROR_STOP=1' `
        -c $Sql `
        -o $OutputFile
    if ($LASTEXITCODE -ne 0) {
        throw "Read-only SQL query failed for '$Database' (exit $LASTEXITCODE). Output: $OutputFile"
    }
}

function Normalize-DumpForReview {
    param([string]$InputFile, [string]$OutputFile)
    # PostgreSQL 17/18 creates random psql restrict/unrestrict keys in schema dumps.
    # Strip those ONLY from the human-review copy; keep the raw dumps intact.
    $inputLines = [System.IO.File]::ReadAllLines($InputFile, [System.Text.Encoding]::UTF8)
    $cleanLines = @($inputLines | Where-Object { $_ -notmatch '^\\(?:un)?restrict(?:\s|$)' })
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($OutputFile, [string[]]$cleanLines, $utf8NoBom)
}

function Read-CsvUtf8 {
    param([string]$Path)
    return @(Import-Csv -LiteralPath $Path -Encoding UTF8)
}

function Get-ObjectKey {
    param($Row, [string[]]$Fields)
    return (@(foreach ($field in $Fields) { [string]$Row.$field }) -join [char]31)
}

function Format-Fields {
    param($Row, [string[]]$FieldNames)
    if ($null -eq $Row) { return '' }
    return (@(foreach ($field in $FieldNames) {
        '{0}={1}' -f $field, [string]$Row.$field
    }) -join ' | ')
}

function Get-CaseSensitiveMap {
    param([object[]]$Rows, [string[]]$KeyFields)
    $map = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $Rows) {
        $key = Get-ObjectKey -Row $row -Fields $KeyFields
        if ($map.ContainsKey($key)) {
            throw "Duplicate object key found in comparison export: $key"
        }
        $map.Add($key, $row)
    }
    return ,$map
}

function Compare-CatalogCsv {
    param(
        [string]$Category,
        [string]$SourceCsv,
        [string]$TargetCsv,
        [string[]]$KeyFields,
        [string[]]$DefinitionFields
    )
    $sourceMap = Get-CaseSensitiveMap -Rows (Read-CsvUtf8 $SourceCsv) -KeyFields $KeyFields
    $targetMap = Get-CaseSensitiveMap -Rows (Read-CsvUtf8 $TargetCsv) -KeyFields $KeyFields
    $keys = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $sourceMap.Keys) { [void]$keys.Add($key) }
    foreach ($key in $targetMap.Keys) { [void]$keys.Add($key) }

    foreach ($key in $keys) {
        $src = $null
        $dst = $null
        [void]$sourceMap.TryGetValue($key, [ref]$src)
        [void]$targetMap.TryGetValue($key, [ref]$dst)
        $srcDef = Format-Fields -Row $src -FieldNames $DefinitionFields
        $dstDef = Format-Fields -Row $dst -FieldNames $DefinitionFields
        $change = $null
        if ($null -eq $dst) { $change = 'OnlyInSource' }
        elseif ($null -eq $src) { $change = 'OnlyInTarget' }
        elseif ($srcDef -cne $dstDef) { $change = 'DifferentDefinition' }
        if ($null -ne $change) {
            [PSCustomObject]@{
                ChangeType       = $change
                Category         = $Category
                ObjectKey        = ($key -split [char]31) -join '.'
                SourceDefinition = $srcDef
                TargetDefinition = $dstDef
            }
        }
    }
}

# These are SELECT-only catalog queries. Object definitions are not executed.
$queries = [ordered]@{}
$queries['database'] = @'
SELECT current_database() AS database_name,
       pg_encoding_to_char(encoding) AS encoding,
       datcollate AS collation,
       datctype AS character_classification,
       current_setting('server_version') AS postgres_version
FROM pg_database WHERE datname = current_database();
'@

$queries['tables'] = @'
SELECT n.nspname AS schema_name, c.relname AS table_name,
       CASE c.relkind WHEN 'r' THEN 'ordinary' WHEN 'p' THEN 'partitioned' END AS kind,
       c.reltuples::bigint AS estimated_rows,
       COALESCE(st.n_live_tup, 0)::bigint AS statistics_live_rows,
       pg_total_relation_size(c.oid)::bigint AS total_bytes,
       st.last_analyze::text AS last_analyze,
       st.last_autoanalyze::text AS last_autoanalyze
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables st ON st.relid = c.oid
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
'@

$queries['columns'] = @'
SELECT n.nspname AS schema_name, c.relname AS table_name,
       a.attname AS column_name, a.attnum AS ordinal_position,
       pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
       a.attnotnull::text AS not_null,
       pg_get_expr(def.adbin, def.adrelid) AS default_expression,
       a.attidentity AS identity_kind,
       a.attgenerated AS generated_kind,
       CASE WHEN a.attcollation <> typ.typcollation
            THEN co.collname ELSE '' END AS explicit_collation
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_type typ ON typ.oid = a.atttypid
LEFT JOIN pg_attrdef def ON def.adrelid = a.attrelid AND def.adnum = a.attnum
LEFT JOIN pg_collation co ON co.oid = a.attcollation
WHERE a.attnum > 0 AND NOT a.attisdropped
  AND c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname, a.attnum;
'@

$queries['indexes'] = @'
SELECT schemaname AS schema_name, tablename AS table_name,
       indexname AS index_name, indexdef AS definition
FROM pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
ORDER BY schemaname, tablename, indexname;
'@

$queries['constraints'] = @'
SELECT n.nspname AS schema_name, c.relname AS table_name,
       con.conname AS constraint_name, con.contype AS constraint_type,
       pg_get_constraintdef(con.oid, true) AS definition,
       con.convalidated::text AS is_validated
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname, con.conname;
'@

$queries['views'] = @'
SELECT n.nspname AS schema_name, c.relname AS view_name,
       c.relkind AS kind, pg_get_viewdef(c.oid, true) AS definition
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
'@

$queries['functions'] = @'
SELECT n.nspname AS schema_name,
       p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS signature,
       p.prokind AS kind, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind IN ('f', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, signature;
'@

$queries['triggers'] = @'
SELECT n.nspname AS schema_name, c.relname AS table_name,
       t.tgname AS trigger_name, pg_get_triggerdef(t.oid, true) AS definition,
       t.tgenabled AS enabled_status
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname, t.tgname;
'@

$queries['sequences'] = @'
SELECT n.nspname AS schema_name, c.relname AS sequence_name,
       pg_catalog.format_type(s.seqtypid, NULL) AS data_type,
       s.seqstart::text AS start_value, s.seqincrement::text AS increment_by,
       s.seqmin::text AS min_value, s.seqmax::text AS max_value,
       s.seqcache::text AS cache_size, s.seqcycle::text AS cycle
FROM pg_sequence s
JOIN pg_class c ON c.oid = s.seqrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
'@

$queries['extensions'] = @'
SELECT e.extname AS extension_name, e.extversion AS version
FROM pg_extension e ORDER BY e.extname;
'@

$queries['policies'] = @'
SELECT schemaname AS schema_name, tablename AS table_name,
       policyname AS policy_name, permissive, roles::text AS roles,
       cmd, qual, with_check
FROM pg_policies
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
ORDER BY schemaname, tablename, policyname;
'@

Assert-CommandPath -Path $PsqlPath -Label 'psql'
Assert-CommandPath -Path $PgDumpPath -Label 'pg_dump'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$reportDir = Join-Path $OutputRoot $stamp
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

$oldPassword = $env:PGPASSWORD
$oldSslMode = $env:PGSSLMODE
$oldConnectTimeout = $env:PGCONNECT_TIMEOUT
$oldOptions = $env:PGOPTIONS
$oldClientEncoding = $env:PGCLIENTENCODING

try {
    $env:PGSSLMODE = $SslMode
    $env:PGCONNECT_TIMEOUT = '15'
    # Restricts only the comparison's NEW connections; never changes DB defaults.
    $env:PGOPTIONS = '-c default_transaction_read_only=on'
    $env:PGCLIENTENCODING = 'UTF8'

    foreach ($item in @(
        [PSCustomObject]@{ Label = 'source'; Database = $SourceDatabase },
        [PSCustomObject]@{ Label = 'target'; Database = $TargetDatabase }
    )) {
        $label = $item.Label
        $db = $item.Database
        Write-Host "`nInspecting $db ($label)" -ForegroundColor Cyan
        Refresh-ManagedIdentityToken
        $rawSchema = Join-Path $reportDir "$label-schema-raw.sql"
        Invoke-SchemaDump -Database $db -OutputFile $rawSchema
        Normalize-DumpForReview -InputFile $rawSchema `
            -OutputFile (Join-Path $reportDir "$label-schema-review.sql")
        foreach ($category in $queries.Keys) {
            Invoke-ReadOnlyCsv -Database $db -Sql $queries[$category] `
                -OutputFile (Join-Path $reportDir "$label-$category.csv")
        }
    }

    $specs = @(
        @{ Name = 'Table'; File = 'tables'; Key = @('schema_name', 'table_name'); Values = @('kind') },
        @{ Name = 'Column'; File = 'columns'; Key = @('schema_name', 'table_name', 'column_name'); Values = @('ordinal_position', 'data_type', 'not_null', 'default_expression', 'identity_kind', 'generated_kind', 'explicit_collation') },
        @{ Name = 'Index'; File = 'indexes'; Key = @('schema_name', 'table_name', 'index_name'); Values = @('definition') },
        @{ Name = 'Constraint'; File = 'constraints'; Key = @('schema_name', 'table_name', 'constraint_name'); Values = @('constraint_type', 'definition', 'is_validated') },
        @{ Name = 'View'; File = 'views'; Key = @('schema_name', 'view_name'); Values = @('kind', 'definition') },
        @{ Name = 'Function'; File = 'functions'; Key = @('schema_name', 'signature'); Values = @('kind', 'definition') },
        @{ Name = 'Trigger'; File = 'triggers'; Key = @('schema_name', 'table_name', 'trigger_name'); Values = @('definition', 'enabled_status') },
        @{ Name = 'Sequence'; File = 'sequences'; Key = @('schema_name', 'sequence_name'); Values = @('data_type', 'start_value', 'increment_by', 'min_value', 'max_value', 'cache_size', 'cycle') },
        @{ Name = 'Extension'; File = 'extensions'; Key = @('extension_name'); Values = @('version') },
        @{ Name = 'Policy'; File = 'policies'; Key = @('schema_name', 'table_name', 'policy_name'); Values = @('permissive', 'roles', 'cmd', 'qual', 'with_check') }
    )

    $changes = @(
        foreach ($spec in $specs) {
            Compare-CatalogCsv -Category $spec.Name `
                -SourceCsv (Join-Path $reportDir "source-$($spec.File).csv") `
                -TargetCsv (Join-Path $reportDir "target-$($spec.File).csv") `
                -KeyFields $spec.Key -DefinitionFields $spec.Values
        }
    )
    $diffFile = Join-Path $reportDir 'schema-differences.csv'
    if ($changes.Count -gt 0) {
        $changes | Export-Csv -LiteralPath $diffFile -NoTypeInformation -Encoding UTF8
    }
    else {
        '"ChangeType","Category","ObjectKey","SourceDefinition","TargetDefinition"' |
            Set-Content -LiteralPath $diffFile -Encoding UTF8
    }

    $sourceTables = @(Read-CsvUtf8 (Join-Path $reportDir 'source-tables.csv'))
    $targetTables = @(Read-CsvUtf8 (Join-Path $reportDir 'target-tables.csv'))
    $sourceTableMap = Get-CaseSensitiveMap -Rows $sourceTables -KeyFields @('schema_name', 'table_name')
    $targetTableMap = Get-CaseSensitiveMap -Rows $targetTables -KeyFields @('schema_name', 'table_name')
    $allTables = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $sourceTableMap.Keys) { [void]$allTables.Add($key) }
    foreach ($key in $targetTableMap.Keys) { [void]$allTables.Add($key) }

    $rowSummary = @(
        foreach ($key in $allTables) {
            $s = $null
            $t = $null
            [void]$sourceTableMap.TryGetValue($key, [ref]$s)
            [void]$targetTableMap.TryGetValue($key, [ref]$t)
            $sourceEstimate = if ($null -ne $s) { [string]$s.estimated_rows } else { '' }
            $targetEstimate = if ($null -ne $t) { [string]$t.estimated_rows } else { '' }
            $delta = ''
            $status = 'BothPresent_EstimateOnly'
            if ($null -eq $t) { $status = 'TableOnlyInSource' }
            elseif ($null -eq $s) { $status = 'TableOnlyInTarget' }
            elseif ([long]$sourceEstimate -lt 0 -or [long]$targetEstimate -lt 0) {
                $status = 'UnknownRowEstimate'
            }
            else {
                $delta = ([long]$sourceEstimate - [long]$targetEstimate).ToString()
                if ($delta -ne '0') { $status = 'DifferentRowEstimate' }
                else { $status = 'SameEstimate_NotProofOfSameData' }
            }
            [PSCustomObject]@{
                Table = ($key -split [char]31) -join '.'
                Status = $status
                SourceEstimatedRows = $sourceEstimate
                TargetEstimatedRows = $targetEstimate
                EstimatedDifference = $delta
                SourceStatsLiveRows = if ($s) { $s.statistics_live_rows } else { '' }
                TargetStatsLiveRows = if ($t) { $t.statistics_live_rows } else { '' }
                SourceTotalBytes = if ($s) { $s.total_bytes } else { '' }
                TargetTotalBytes = if ($t) { $t.total_bytes } else { '' }
                SourceLastAnalyze = if ($s) { $s.last_analyze } else { '' }
                TargetLastAnalyze = if ($t) { $t.last_analyze } else { '' }
            }
        }
    )
    $rowSummary | Export-Csv -LiteralPath (Join-Path $reportDir 'data-row-estimates.csv') `
        -NoTypeInformation -Encoding UTF8

    # A stable unique key is required before any per-row UPDATE/INSERT sync can be designed.
    $sourcePrimaryKeys = @(Read-CsvUtf8 (Join-Path $reportDir 'source-constraints.csv') |
        Where-Object { $_.constraint_type -ceq 'p' })
    $keyMap = Get-CaseSensitiveMap -Rows $sourcePrimaryKeys -KeyFields @('schema_name', 'table_name')
    $missingPrimaryKeys = @(
        foreach ($row in $sourceTables) {
            $key = Get-ObjectKey $row @('schema_name', 'table_name')
            if (-not $keyMap.ContainsKey($key)) {
                [PSCustomObject]@{
                    Table = "$($row.schema_name).$($row.table_name)"
                    Warning = 'No PRIMARY KEY in source; identify a stable unique key before row-level sync'
                }
            }
        }
    )
    $pkWarningsFile = Join-Path $reportDir 'tables-without-primary-keys.csv'
    if ($missingPrimaryKeys.Count -gt 0) {
        $missingPrimaryKeys | Export-Csv -LiteralPath $pkWarningsFile -NoTypeInformation -Encoding UTF8
    }
    else { '"Table","Warning"' | Set-Content -LiteralPath $pkWarningsFile -Encoding UTF8 }

    $exactResults = @()
    if ($ExactCountTables.Count -gt 0) {
        Write-Host "`nExact counts requested. These will scan selected tables and can be expensive." -ForegroundColor Yellow
        foreach ($qualifiedName in $ExactCountTables) {
            if ($qualifiedName -notmatch '^([^.]+)\.(.+)$') {
                throw "ExactCountTables must use schema.table format: $qualifiedName"
            }
            $schemaName = $Matches[1]
            $tableName = $Matches[2]
            $key = ($schemaName, $tableName) -join [char]31
            $quotedName = '"' + $schemaName.Replace('"', '""') + '"."' + $tableName.Replace('"', '""') + '"'
            $counts = @{}
            foreach ($dbItem in @(
                [PSCustomObject]@{ Label='Source'; Database=$SourceDatabase; TableMap=$sourceTableMap },
                [PSCustomObject]@{ Label='Target'; Database=$TargetDatabase; TableMap=$targetTableMap }
            )) {
                if (-not $dbItem.TableMap.ContainsKey($key)) {
                    $counts[$dbItem.Label] = $null
                    continue
                }
                Refresh-ManagedIdentityToken
                $tempCsv = Join-Path $reportDir ("exact-count-{0}-{1}.csv" -f $dbItem.Label.ToLower(), [Guid]::NewGuid().ToString('N'))
                try {
                    Write-Host "Counting rows in $($dbItem.Database).$qualifiedName ..." -ForegroundColor Cyan
                    Invoke-ReadOnlyCsv -Database $dbItem.Database `
                        -Sql "SELECT COUNT(*)::bigint AS exact_rows FROM $quotedName;" `
                        -OutputFile $tempCsv
                    $countResult = @(Read-CsvUtf8 $tempCsv)
                    if ($countResult.Count -ne 1) { throw "Unexpected exact count result for $qualifiedName" }
                    $counts[$dbItem.Label] = [long]$countResult[0].exact_rows
                }
                finally { Remove-Item -LiteralPath $tempCsv -Force -ErrorAction SilentlyContinue }
            }
            $difference = ''
            if ($null -ne $counts['Source'] -and $null -ne $counts['Target']) {
                $difference = ($counts['Source'] - $counts['Target']).ToString()
            }
            $exactResults += [PSCustomObject]@{
                Table = $qualifiedName
                SourceExactRows = if ($null -ne $counts['Source']) { $counts['Source'] } else { 'TABLE MISSING' }
                TargetExactRows = if ($null -ne $counts['Target']) { $counts['Target'] } else { 'TABLE MISSING' }
                ExactRowDifference = $difference
                Caveat = 'Same count does not prove identical data'
            }
        }
        $exactResults | Export-Csv -LiteralPath (Join-Path $reportDir 'data-exact-counts.csv') `
            -NoTypeInformation -Encoding UTF8
    }

    $sourceDbInfo = @(Read-CsvUtf8 (Join-Path $reportDir 'source-database.csv'))[0]
    $targetDbInfo = @(Read-CsvUtf8 (Join-Path $reportDir 'target-database.csv'))[0]
    $encodingDiffers = ($sourceDbInfo.encoding -cne $targetDbInfo.encoding -or
                        $sourceDbInfo.collation -cne $targetDbInfo.collation -or
                        $sourceDbInfo.character_classification -cne $targetDbInfo.character_classification)
    $summaryFile = Join-Path $reportDir 'README-review.txt'
    @(
        'POSTGRESQL DATABASE COMPARISON - READ ONLY'
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Server: ${Server}:$Port"
        "SOURCE (changes from): $SourceDatabase"
        "TARGET (preserve): $TargetDatabase"
        ''
        "SOURCE encoding/collation: $($sourceDbInfo.encoding) / $($sourceDbInfo.collation)"
        "TARGET encoding/collation: $($targetDbInfo.encoding) / $($targetDbInfo.collation)"
        "Source table count: $($sourceTables.Count)"
        "Target table count: $($targetTables.Count)"
        "Catalog schema differences: $($changes.Count)"
        "Source tables without a PRIMARY KEY: $($missingPrimaryKeys.Count)"
        "Exact row-count tables checked: $($ExactCountTables.Count)"
        ''
        'FILES TO REVIEW:'
        '  schema-differences.csv       - only in source / only in target / different definitions'
        '  data-row-estimates.csv       - approximate per-table rows and storage sizes; NOT actual data diff'
        '  tables-without-primary-keys.csv - tables needing a reliable row-match strategy'
        '  data-exact-counts.csv       - only when -ExactCountTables is supplied'
        '  source-schema-review.sql   - schema DDL for visual comparison'
        '  target-schema-review.sql   - schema DDL for visual comparison'
        '  source-schema-raw.sql      - raw pg_dump schema-only export'
        '  target-schema-raw.sql      - raw pg_dump schema-only export'
        '  source-*.csv / target-*.csv - full catalog snapshots'
        ''
        'VISUAL COMPARE FROM VS CODE:'
        '  code --diff "target-schema-review.sql" "source-schema-review.sql"'
        ''
        'INTERPRETATION:'
        '  OnlyInSource = change candidate to add after manual review.'
        '  OnlyInTarget = object not present in source; NEVER automatically delete.'
        '  DifferentDefinition = needs a carefully authored migration, not a blind restore.'
        '  Row counts are estimates that may be stale, particularly after a recent bulk load.'
        '  Even exact equal row counts do NOT mean row content is identical.'
        '  This stage does not compute inserted/updated/deleted rows.'
        '  Missing source PRIMARY KEY may be addressed using a validated UNIQUE business key.'
        '  Schema snapshots exclude ownership and GRANT/REVOKE changes by design.'
        '  Review ownership, permissions, and database roles separately before deployment.'
        '  Source and target are captured sequentially, not as one atomic snapshot.'
        '  Database encoding and default collation are NOT changed by schema migration.'
        if ($encodingDiffers) {
            "  WARNING: target $($targetDbInfo.encoding)/$($targetDbInfo.collation) differs from source $($sourceDbInfo.encoding)/$($sourceDbInfo.collation)."
        }
        '  Do NOT execute schema-only dumps or a full source dump against the target.'
        '  No SQL statements changing either database are executed by this comparison.'
    ) | Set-Content -LiteralPath $summaryFile -Encoding UTF8

    Write-Host "`nCOMPARISON FINISHED - NO CHANGES DEPLOYED" -ForegroundColor Green
    Write-Host "Report directory : $reportDir"
    Write-Host "Schema differences: $($changes.Count)"
    Write-Host "Source tables     : $($sourceTables.Count)"
    Write-Host "Target tables     : $($targetTables.Count)"
    Write-Host "Tables without PK : $($missingPrimaryKeys.Count)"
    if ($encodingDiffers) {
        Write-Host "Encoding/collation: source $($sourceDbInfo.encoding)/$($sourceDbInfo.collation), target $($targetDbInfo.encoding)/$($targetDbInfo.collation)" -ForegroundColor Yellow
    }
    Write-Host "`nREVIEW THESE FILES FIRST:" -ForegroundColor Yellow
    Write-Host (Join-Path $reportDir 'README-review.txt')
    Write-Host (Join-Path $reportDir 'schema-differences.csv')
    Write-Host (Join-Path $reportDir 'data-row-estimates.csv')
    Write-Host "`nVS Code diff command:"
    Write-Host "code --diff `"$(Join-Path $reportDir 'target-schema-review.sql')`" `"$(Join-Path $reportDir 'source-schema-review.sql')`""
}
finally {
    $env:PGPASSWORD = $oldPassword
    $env:PGSSLMODE = $oldSslMode
    $env:PGCONNECT_TIMEOUT = $oldConnectTimeout
    $env:PGOPTIONS = $oldOptions
    $env:PGCLIENTENCODING = $oldClientEncoding
}
