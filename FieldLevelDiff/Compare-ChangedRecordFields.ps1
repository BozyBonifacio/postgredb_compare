# Compare-ChangedRecordFields.ps1 - v2.0 (2026-11-15)
# Read-only field-by-field analysis of one table's CHANGED records, as identified by a
# previous RecordCompare\Compare-TableRecords.ps1 run.
# Windows PowerShell 5.1; PostgreSQL 18 client; libpq or Azure managed identity authentication.
# Does not INSERT, UPDATE, DELETE, ALTER, or create permanent database objects.

[CmdletBinding()]
param(
    # Schema-qualified table name, e.g. 'public.customers'.
    [Parameter(Mandatory = $true)]
    [string]$Table,
    [Parameter(Mandatory = $true)]
    [string]$ComparisonRunDirectory,
    [string]$OutputDirectory,

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

    # Optional Azure user-assigned managed identity; otherwise standard libpq authentication.
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ManagedIdentityClientId,
    [ValidateSet('disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full')]
    [string]$SslMode = 'require',
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',

    # Optional tripwire for the CHANGED count recorded in the comparison run (0 = no check).
    [ValidateRange(0, 1000000)]
    [int]$ExpectedCandidateCount = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Table -cnotmatch '^([^.]+)\.([^.]+)$') { throw "-Table must use schema.table format: $Table" }
$qualifiedTable = '"' + $Matches[1].Replace('"', '""') + '"."' + $Matches[2].Replace('"', '""') + '"'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$oldEnvironment = @{}
foreach ($name in @('PGPASSWORD', 'PGSSLMODE', 'PGCONNECT_TIMEOUT', 'PGTZ', 'PGDATESTYLE',
                   'PGCLIENTENCODING', 'PGOPTIONS', 'PGAPPNAME')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Write-Utf8File([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Decode-HexUtf8([string]$Hex) {
    if ($null -eq $Hex -or ($Hex.Length % 2) -ne 0 -or $Hex -cnotmatch '^[0-9a-f]*$') {
        throw 'Malformed lower-case hex data returned by psql.'
    }
    $bytes = [byte[]]::new([int]($Hex.Length / 2))
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring(($i * 2), 2), 16)
    }
    return $script:utf8.GetString($bytes)
}

function Invoke-ReadOnlyExport {
    param([string]$Database, [string]$Sql, [string]$OutputFile, [string]$ErrorFile)

    $sqlFile = Join-Path $script:scratchDirectory 'readonly.sql'
    Write-Utf8File -Path $sqlFile -Value ($Sql + "`n")

    # Without a managed identity, libpq resolves the password itself.
    if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
        if ($null -eq $script:accessToken -or [datetime]::UtcNow.AddMinutes(5) -ge $script:tokenExpiresUtc) {
            $resource = [uri]::EscapeDataString('https://ossrdbms-aad.database.windows.net')
            $client = [uri]::EscapeDataString($ManagedIdentityClientId)
            $uri = 'http://169.254.169.254/metadata/identity/oauth2/token' +
                   "?api-version=2018-02-01&resource=$resource&client_id=$client"
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30
            if ([string]::IsNullOrWhiteSpace([string]$response.access_token)) {
                throw 'The managed identity endpoint returned an empty access token.'
            }
            $script:accessToken = [string]$response.access_token
            $seconds = 0
            if (-not [int]::TryParse([string]$response.expires_in, [ref]$seconds)) { $seconds = 1200 }
            $script:tokenExpiresUtc = [datetime]::UtcNow.AddSeconds([math]::Max(120, $seconds))
        }
        $env:PGPASSWORD = $script:accessToken
    }

    $psqlArgs = @(
        '-X', '-w', '-q', '-v', 'ON_ERROR_STOP=1',
        '-h', $Server, '-p', $Port, '-U', $UserName, '-d', $Database,
        '-f', ('"' + $sqlFile + '"')
    )
    $p = Start-Process -FilePath $PsqlPath -ArgumentList $psqlArgs `
        -RedirectStandardOutput $OutputFile -RedirectStandardError $ErrorFile `
        -NoNewWindow -PassThru -Wait
    $p.Refresh()
    if ($p.ExitCode -ne 0) {
        $errorTail = ''
        if (Test-Path -LiteralPath $ErrorFile) {
            $errorTail = (Get-Content -LiteralPath $ErrorFile -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
        }
        throw "Read-only export failed from $Database, exit $($p.ExitCode): $errorTail"
    }
}

# Streams the gzip detail file and keeps only CHANGED keys; SOURCE_ONLY and TARGET_ONLY
# records exist on one side only, so they have no fields to compare.
function Get-ChangedCandidates([string]$Path) {
    $found = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $inputFile = [IO.File]::OpenRead($Path)
    try {
        $compressed = [IO.Compression.GZipStream]::new($inputFile, [IO.Compression.CompressionMode]::Decompress)
        try {
            $reader = [IO.StreamReader]::new($compressed, $script:utf8)
            try {
                if ($reader.ReadLine() -cne 'change_type,record_id,source_sha256,target_sha256') {
                    throw "Unexpected record ID CSV format: $Path"
                }
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($line -cnotmatch '^(SOURCE_ONLY|CHANGED|TARGET_ONLY),"((?:[^"]|"")*)",([0-9a-f]{64}|),([0-9a-f]{64}|)$') {
                        throw "Malformed row in the comparison detail file: $Path"
                    }
                    if ($Matches[1] -cne 'CHANGED') { continue }
                    $id = $Matches[2].Replace('""', '"')
                    $sourceSha = $Matches[3]
                    $targetSha = $Matches[4]
                    # Keys are interpolated as SQL literals, so only plain key text is accepted.
                    if ($id -cnotmatch '^[A-Za-z0-9_.:@-]{1,128}$') {
                        throw 'Unsupported record key format in the comparison detail file.'
                    }
                    if ($sourceSha.Length -eq 0 -or $targetSha.Length -eq 0) {
                        throw "Missing historical SHA-256 for record $id."
                    }
                    if ($found.ContainsKey($id)) { throw "Duplicate candidate record key: $id" }
                    $found.Add($id, [pscustomobject]@{ source_sha256 = $sourceSha; target_sha256 = $targetSha })
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $compressed.Dispose() }
    }
    finally { $inputFile.Dispose() }
    return ,$found
}

function Read-Metadata([string]$Path) {
    $cols = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::ASCII)) {
        if ($line.Length -eq 0) { continue }
        $part = $line.Split([char]9)
        if ($part.Count -ne 4) { throw 'Unexpected metadata result format.' }
        $cols.Add([pscustomobject]@{
            Ordinal = [int]$part[0]
            Name = (Decode-HexUtf8 $part[1])
            DataType = (Decode-HexUtf8 $part[2])
            IsPrimaryKey = ($part[3] -ceq 't')
        })
    }
    return ,$cols
}

function Read-FieldExport([string]$Path, [object]$Candidates, [object]$ColumnNames) {
    $records = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::ASCII)) {
        if ($line.Length -eq 0) { continue }
        $part = $line.Split([char]9)
        if ($part.Count -ne 4) { throw 'Malformed field export row (expected four tab-separated hex values).' }
        $id = Decode-HexUtf8 $part[0]
        $name = Decode-HexUtf8 $part[1]
        $valueJson = Decode-HexUtf8 $part[2]
        $fingerprint = $part[3]
        if (-not $Candidates.ContainsKey($id)) { throw 'Unexpected record key returned by the database.' }
        if (-not $ColumnNames.ContainsKey($name)) { throw 'Unexpected column returned by the database.' }
        if ($fingerprint -cnotmatch '^[0-9a-f]{64}$') { throw 'Malformed row fingerprint.' }

        if (-not $records.ContainsKey($id)) {
            $fields = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $records.Add($id, [pscustomobject]@{ Hash = $fingerprint; Fields = $fields })
        }
        $entry = $records[$id]
        if ($entry.Hash -cne $fingerprint) { throw 'Inconsistent row hash within one database export.' }
        if ($entry.Fields.ContainsKey($name)) { throw "Duplicate field $name for record $id." }
        $entry.Fields.Add($name, $valueJson)
    }
    foreach ($id in $records.Keys) {
        if ($records[$id].Fields.Count -ne $ColumnNames.Count) {
            throw "Incomplete column export for record $id."
        }
    }
    return ,$records
}

function Save-CsvReport([string]$Path, [string]$Header, [object]$Rows) {
    if ($Rows.Count -gt 0) {
        $Rows.ToArray() | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
    else {
        $Header | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

if ($SourceDatabase -ceq $TargetDatabase) { throw 'Source and target databases must differ.' }
foreach ($text in @($Server, $UserName, $SourceDatabase, $TargetDatabase)) {
    if ($text -cnotmatch '^[a-zA-Z0-9_.@-]+$') { throw "Unsafe PostgreSQL connection argument: $text" }
}
if (-not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) { throw "Missing psql.exe: $PsqlPath" }
# Resolve against the PowerShell location; .NET file APIs use the process directory.
$ComparisonRunDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ComparisonRunDirectory)
if (-not (Test-Path -LiteralPath $ComparisonRunDirectory -PathType Container)) {
    throw "Missing comparison run folder: $ComparisonRunDirectory"
}
$summaryCsv = Join-Path $ComparisonRunDirectory 'comparison-summary.csv'
if (-not (Test-Path -LiteralPath $summaryCsv -PathType Leaf)) { throw "Missing comparison summary: $summaryCsv" }
$rows = @(Import-Csv -LiteralPath $summaryCsv -Encoding UTF8 | Where-Object { $_.Table -ceq $Table })
if ($rows.Count -ne 1) { throw "Expected exactly one $Table row in comparison-summary.csv." }
$baseline = $rows[0]
if ($baseline.Status -cne 'COMPARED' -or [string]$baseline.DetailsTruncated -ne 'False' -or
    [long]$baseline.DetailRowsWritten -ne ([long]$baseline.SourceOnly + [long]$baseline.Changed + [long]$baseline.TargetOnly)) {
    throw 'Historical table comparison is not COMPLETE or the record keys were truncated.'
}
if ($ExpectedCandidateCount -gt 0 -and [int]$baseline.Changed -ne $ExpectedCandidateCount) {
    throw "Historical file contains $($baseline.Changed) CHANGED records; expected $ExpectedCandidateCount."
}
$detailRelative = ([string]$baseline.DetailFile).Replace('/', '\')
$detailFile = [IO.Path]::GetFullPath((Join-Path $ComparisonRunDirectory $detailRelative))
$basePath = [IO.Path]::GetFullPath($ComparisonRunDirectory).TrimEnd('\') + '\'
if (-not $detailFile.StartsWith($basePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Detail file resolves outside the historical comparison folder.'
}
if (-not (Test-Path -LiteralPath $detailFile -PathType Leaf)) { throw "Missing changed-record keys file: $detailFile" }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $tableFolder = [regex]::Replace($Table, '[^A-Za-z0-9_-]', '_') + '-' + $stamp
    $OutputDirectory = Join-Path (Join-Path (Get-Location -PSProvider FileSystem).ProviderPath 'FieldLevelDiffReports') $tableFolder
}
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw "Report folder already exists: $OutputDirectory" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$logsDirectory = Join-Path $OutputDirectory 'logs'
$script:scratchDirectory = Join-Path $OutputDirectory '_scratch'
New-Item -ItemType Directory -Path $logsDirectory, $script:scratchDirectory -Force | Out-Null

$script:accessToken = $null
$script:tokenExpiresUtc = [datetime]::MinValue
try {
    # Enforce read-only PostgreSQL sessions; all server commands are COPY(SELECT...) TO STDOUT.
    $env:PGOPTIONS = '-c default_transaction_read_only=on'
    $env:PGSSLMODE = $SslMode
    $env:PGCONNECT_TIMEOUT = '25'
    $env:PGTZ = 'UTC'
    $env:PGDATESTYLE = 'ISO,MDY'
    $env:PGCLIENTENCODING = 'UTF8'
    $env:PGAPPNAME = 'ReadOnly_Field_Diff'

    $candidates = Get-ChangedCandidates -Path $detailFile
    if ($candidates.Count -ne [int]$baseline.Changed) {
        throw "Gzip CHANGED key count ($($candidates.Count)) does not match summary ($($baseline.Changed))."
    }
    if ($candidates.Count -eq 0) { throw 'No CHANGED records to analyze.' }

    Write-Host "Read-only field report: $OutputDirectory" -ForegroundColor Cyan
    Write-Host "Table: $Table; historical changed record keys: $($candidates.Count)"
    Write-Host "Source: $SourceDatabase; target: $TargetDatabase" -ForegroundColor Cyan

    # The last column flags the single-column primary key, so both databases must agree on it.
    $regclassLiteral = "'" + $qualifiedTable.Replace("'", "''") + "'"
    $metadataSql = @"
COPY (
 SELECT a.attnum::text,
        encode(convert_to(a.attname, 'UTF8'), 'hex'),
        encode(convert_to(pg_catalog.format_type(a.atttypid, a.atttypmod), 'UTF8'), 'hex'),
        EXISTS (
          SELECT 1 FROM pg_catalog.pg_index AS i
          WHERE i.indrelid = a.attrelid AND i.indisprimary
            AND i.indnkeyatts = 1 AND i.indkey[0] = a.attnum
        )
 FROM pg_catalog.pg_attribute AS a
 WHERE a.attrelid = ${regclassLiteral}::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum
) TO STDOUT WITH (FORMAT text);
"@
    $sourceMeta = Join-Path $script:scratchDirectory 'metadata-source.tsv'
    $targetMeta = Join-Path $script:scratchDirectory 'metadata-target.tsv'
    Invoke-ReadOnlyExport -Database $SourceDatabase -Sql $metadataSql `
        -OutputFile $sourceMeta -ErrorFile (Join-Path $logsDirectory 'metadata-source.stderr.log')
    Invoke-ReadOnlyExport -Database $TargetDatabase -Sql $metadataSql `
        -OutputFile $targetMeta -ErrorFile (Join-Path $logsDirectory 'metadata-target.stderr.log')
    if ((Get-FileHash -LiteralPath $sourceMeta -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $targetMeta -Algorithm SHA256).Hash) {
        throw 'Source/target column metadata differ. Resolve the schema discrepancy before comparing.'
    }
    $columns = Read-Metadata -Path $sourceMeta
    $keyColumns = @($columns | Where-Object { $_.IsPrimaryKey })
    if ($columns.Count -lt 2 -or $keyColumns.Count -ne 1) {
        throw "$Table needs a single-column primary key and at least one other column."
    }
    $keyColumn = [string]$keyColumns[0].Name
    $key = 't."' + $keyColumn.Replace('"', '""') + '"'
    $columnNames = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($column in $columns) { $columnNames.Add($column.Name, $column) }
    Write-Host "Schema verified: $($columns.Count) identical columns in both databases; key column $keyColumn."

    # Record keys are validated as plain key text before being used as SQL literals.
    $quotedIds = @(foreach ($id in $candidates.Keys) { "'$id'" }) -join ",`n        "
    $fieldSql = @"
COPY (
 SELECT encode(convert_to(${key}::text, 'UTF8'), 'hex') AS id_hex,
        encode(convert_to(pair.key, 'UTF8'), 'hex') AS column_hex,
        encode(convert_to(pair.value::text, 'UTF8'), 'hex') AS value_json_hex,
        encode(sha256(convert_to(to_jsonb(t)::text, 'UTF8')), 'hex') AS row_sha256
 FROM $qualifiedTable AS t
 CROSS JOIN LATERAL jsonb_each(to_jsonb(t)) AS pair(key, value)
 WHERE $key IN (
        $quotedIds
 )
 ORDER BY ${key}::text COLLATE "C", pair.key COLLATE "C"
) TO STDOUT WITH (FORMAT text);
"@
    $sourceData = Join-Path $script:scratchDirectory 'fields-source.tsv'
    $targetData = Join-Path $script:scratchDirectory 'fields-target.tsv'
    Write-Host "Reading $($candidates.Count) selected records from source..."
    Invoke-ReadOnlyExport -Database $SourceDatabase -Sql $fieldSql `
        -OutputFile $sourceData -ErrorFile (Join-Path $logsDirectory 'fields-source.stderr.log')
    Write-Host "Reading $($candidates.Count) selected records from target..."
    Invoke-ReadOnlyExport -Database $TargetDatabase -Sql $fieldSql `
        -OutputFile $targetData -ErrorFile (Join-Path $logsDirectory 'fields-target.stderr.log')

    $source = Read-FieldExport -Path $sourceData -Candidates $candidates -ColumnNames $columnNames
    $target = Read-FieldExport -Path $targetData -Candidates $candidates -ColumnNames $columnNames

    $fieldChanges = [Collections.ArrayList]::new()
    $recordChanges = [Collections.ArrayList]::new()
    $columnCount = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($column in $columns) { $columnCount.Add($column.Name, 0) }
    $counts = [ordered]@{ CHANGED = 0; NOW_MATCHING = 0; SOURCE_MISSING = 0; TARGET_MISSING = 0; BOTH_MISSING = 0 }
    $sourceDrift = 0
    $targetDrift = 0

    foreach ($id in @($candidates.Keys | Sort-Object -CaseSensitive)) {
        $historic = $candidates[$id]
        $s = if ($source.ContainsKey($id)) { $source[$id] } else { $null }
        $t = if ($target.ContainsKey($id)) { $target[$id] } else { $null }
        $sourceHashNow = if ($null -ne $s) { $s.Hash } else { '' }
        $targetHashNow = if ($null -ne $t) { $t.Hash } else { '' }
        $sourceDrifted = ($sourceHashNow -cne [string]$historic.source_sha256)
        $targetDrifted = ($targetHashNow -cne [string]$historic.target_sha256)
        if ($sourceDrifted) { $sourceDrift++ }
        if ($targetDrifted) { $targetDrift++ }

        $fieldChangeCount = 0
        $changedColumnNames = [Collections.Generic.List[string]]::new()
        if ($null -eq $s -and $null -eq $t) { $state = 'BOTH_MISSING' }
        elseif ($null -eq $s) { $state = 'SOURCE_MISSING' }
        elseif ($null -eq $t) { $state = 'TARGET_MISSING' }
        else {
            foreach ($column in $columns) {
                $name = [string]$column.Name
                $sourceJson = [string]$s.Fields[$name]
                $targetJson = [string]$t.Fields[$name]
                if (-not [string]::Equals($sourceJson, $targetJson, [StringComparison]::Ordinal)) {
                    $fieldChangeCount++
                    $changedColumnNames.Add($name)
                    $columnCount[$name] = $columnCount[$name] + 1
                    [void]$fieldChanges.Add([pscustomobject]@{
                        RecordId = $id
                        ColumnName = $name
                        DataType = $column.DataType
                        SourceValueJson = $sourceJson
                        TargetValueJson = $targetJson
                        SourceIsNull = ($sourceJson -ceq 'null')
                        TargetIsNull = ($targetJson -ceq 'null')
                    })
                }
            }
            if ($fieldChangeCount -eq 0) { $state = 'NOW_MATCHING' }
            else { $state = 'CHANGED' }
        }
        $counts[$state] = $counts[$state] + 1
        [void]$recordChanges.Add([pscustomobject]@{
            RecordId = $id
            CurrentStatus = $state
            ChangedFieldCount = $fieldChangeCount
            ChangedColumns = ($changedColumnNames -join '; ')
            SourceHashAtComparison = [string]$historic.source_sha256
            TargetHashAtComparison = [string]$historic.target_sha256
            SourceHashNow = $sourceHashNow
            TargetHashNow = $targetHashNow
            SourceChangedSinceComparison = $sourceDrifted
            TargetChangedSinceComparison = $targetDrifted
        })
    }

    $columnStats = [Collections.ArrayList]::new()
    foreach ($column in $columns) {
        [void]$columnStats.Add([pscustomobject]@{
            ColumnName = $column.Name
            DataType = $column.DataType
            ChangedRecordCount = $columnCount[$column.Name]
        })
    }
    $fieldCsv = Join-Path $OutputDirectory 'field-differences.csv'
    $recordCsv = Join-Path $OutputDirectory 'record-summary.csv'
    $columnCsv = Join-Path $OutputDirectory 'column-summary.csv'
    Save-CsvReport -Path $fieldCsv -Rows $fieldChanges -Header '"RecordId","ColumnName","DataType","SourceValueJson","TargetValueJson","SourceIsNull","TargetIsNull"'
    Save-CsvReport -Path $recordCsv -Rows $recordChanges -Header '"RecordId","CurrentStatus","ChangedFieldCount","ChangedColumns","SourceHashAtComparison","TargetHashAtComparison","SourceHashNow","TargetHashNow","SourceChangedSinceComparison","TargetChangedSinceComparison"'
    Save-CsvReport -Path $columnCsv -Rows $columnStats -Header '"ColumnName","DataType","ChangedRecordCount"'

    $overview = [pscustomobject]@{
        Table = $Table
        KeyColumn = $keyColumn
        SourceDatabase = $SourceDatabase
        TargetDatabase = $TargetDatabase
        Server = $Server
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        OriginalComparedUtc = [string]$baseline.FinishedUtc
        HistoricalChangedIds = $candidates.Count
        CurrentStatuses = $counts
        TotalChangedCells = $fieldChanges.Count
        SourceRowsDriftedSinceComparison = $sourceDrift
        TargetRowsDriftedSinceComparison = $targetDrift
        Columns = $columns.Count
        ReadOnly = $true
        Note = 'Only keys listed as CHANGED in the selected historical run were inspected. Other records were not re-scanned; source and target have separate read snapshots.'
    }
    $overview | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'report-summary.json') -Encoding UTF8

    Write-Host ''
    Write-Host 'REPORT COMPLETE - no database writes.' -ForegroundColor Green
    Write-Host "Historical CHANGED keys: $($candidates.Count)"
    Write-Host "Currently different: $($counts.CHANGED); now matching: $($counts.NOW_MATCHING)"
    Write-Host "Missing source: $($counts.SOURCE_MISSING); missing target: $($counts.TARGET_MISSING); missing both: $($counts.BOTH_MISSING)"
    Write-Host "Differing cells: $($fieldChanges.Count)"
    Write-Host "Drifted since baseline - source: $sourceDrift; target: $targetDrift"
    Write-Host "Field differences: $fieldCsv" -ForegroundColor Green
    Write-Host "Record summary:    $recordCsv" -ForegroundColor Green
    Write-Host "Column summary:    $columnCsv" -ForegroundColor Green
    Write-Host "Run summary:       $(Join-Path $OutputDirectory 'report-summary.json')"
}
finally {
    foreach ($name in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
    }
    $script:accessToken = $null
    if ($null -ne $script:scratchDirectory -and (Test-Path -LiteralPath $script:scratchDirectory)) {
        # Remove intermediate exports, which contain sensitive row-level information.
        Remove-Item -LiteralPath $script:scratchDirectory -Force -Recurse -ErrorAction SilentlyContinue
    }
}
