# Compare-TableRecords.ps1 - v2.0 (2026-11-15, generic primary keys and connections)
# Windows PowerShell 5.1; PostgreSQL 18 psql; libpq or Azure managed identity authentication.
# DATABASE READ ONLY. All PostgreSQL commands are COPY(SELECT...) TO STDOUT.
# default_transaction_read_only=on is enforced on every PostgreSQL session.
# The only files written are to the local output directory.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [ValidateRange(1, 65535)]
    [int]$Port = 5432,
    [Parameter(Mandatory=$true)]
    [string]$UserName,
    [Parameter(Mandatory=$true)]
    [string]$SourceDatabase,
    [Parameter(Mandatory=$true)]
    [string]$TargetDatabase,

    # Optional Azure user-assigned managed identity; otherwise standard libpq authentication.
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ManagedIdentityClientId,

    [ValidateSet('disable','allow','prefer','require','verify-ca','verify-full')]
    [string]$SslMode = 'require',
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [string]$OutputRoot = (Join-Path (Get-Location -PSProvider FileSystem).ProviderPath 'DatabaseRecordCompare'),

    # Exactly one: -AllTables, or -Tables @('public.customers','public.orders')
    [switch]$AllTables,
    [string[]]$Tables = @(),
    # Optional schema filter for -AllTables, e.g. -Schemas @('public','sales')
    [string[]]$Schemas = @(),

    # Validate generated PostgreSQL queries on both databases with LIMIT 0.
    # No full table scan, hashing or comparison is performed with this option.
    [switch]$PreflightOnly,

    # To resume an interrupted run, reuse its exact directory and original selection.
    [string]$RunDirectory,
    [switch]$Resume,

    # 0 = emit every changed/source-only/target-only key; >0 limits detail export
    # but NOT exact aggregate counters. A limit means incomplete ID-level output.
    [ValidateRange(0, 1000000000)]
    [long]$MaxDetailRowsPerTable = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($AllTables -and $Tables.Count -gt 0) {
    throw 'Choose either -AllTables OR -Tables, not both.'
}
if (-not $AllTables -and $Tables.Count -eq 0) {
    throw 'Specify -AllTables for a full scan, or -Tables for a small pilot.'
}
if ($Schemas.Count -gt 0 -and -not $AllTables) {
    throw '-Schemas filters -AllTables; list schema-qualified names in -Tables instead.'
}
if ($SourceDatabase -ceq $TargetDatabase) {
    throw 'SourceDatabase and TargetDatabase must differ.'
}
foreach ($name in @($Server, $UserName, $SourceDatabase, $TargetDatabase)) {
    if ($name -notmatch '^[a-zA-Z0-9_.@-]+$') {
        throw "Unsafe connection argument: $name"
    }
}
if (-not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) {
    throw "psql.exe not found: $PsqlPath"
}
$helperPath = Join-Path $PSScriptRoot 'SortedFingerprintMerge.cs'
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "Missing required companion file: $helperPath"
}
if (-not ('SortedFingerprintMerge' -as [type])) {
    Add-Type -Path $helperPath -ReferencedAssemblies @('System.dll','System.Core.dll','System.IO.Compression.dll') -ErrorAction Stop
}

function Save-Utf8NoBom([string]$Path,[string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
function Quote-Ident([string]$Identifier) {
    return '"' + $Identifier.Replace('"','""') + '"'
}
# Use a subquery so id_hex is an input column for the outer ORDER BY.
# PostgreSQL cannot use an output SELECT alias within a COLLATE expression.
# ZeroRows validates query resolution without scanning actual table rows.
# The key is the table's single-column primary key, compared by its text form.
function Get-FingerprintExportSql {
    param([string]$QualifiedTable,[string]$KeyColumn,[switch]$ZeroRows)
    $key = Quote-Ident $KeyColumn
    $sql = @"
COPY (
    SELECT fp.id_hex, fp.row_sha256
    FROM (
        SELECT encode(convert_to(t.$key::text, 'UTF8'), 'hex') AS id_hex,
               encode(sha256(convert_to(to_jsonb(t)::text, 'UTF8')), 'hex') AS row_sha256
        FROM $QualifiedTable AS t
    ) AS fp
    ORDER BY fp.id_hex COLLATE "C"
"@
    if ($ZeroRows) { $sql += "`n    LIMIT 0" }
    return ($sql + "`n) TO STDOUT WITH (FORMAT text);")
}

function Get-TableFilename([string]$Table) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Table))
        $hash = [BitConverter]::ToString($bytes).Replace('-','').Substring(0,16).ToLowerInvariant()
        $clean = [regex]::Replace($Table, '[^A-Za-z0-9_-]', '_')
        if ($clean.Length -gt 48) { $clean = $clean.Substring(0,48) }
        return "$clean-$hash"
    }
    finally { $sha.Dispose() }
}

$script:CachedToken = $null
$script:TokenExpiryUtc = [datetime]::MinValue
function Set-IdentityToken {
    # Without a managed identity, libpq resolves the password itself.
    if ([string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) { return }
    if ($null -eq $script:CachedToken -or [datetime]::UtcNow.AddMinutes(5) -ge $script:TokenExpiryUtc) {
        $resource = [uri]::EscapeDataString('https://ossrdbms-aad.database.windows.net')
        $clientId = [uri]::EscapeDataString($ManagedIdentityClientId)
        $uri = 'http://169.254.169.254/metadata/identity/oauth2/token' +
               "?api-version=2018-02-01&resource=$resource&client_id=$clientId"
        $reply = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30
        if ([string]::IsNullOrWhiteSpace([string]$reply.access_token)) {
            throw 'Managed identity token was empty.'
        }
        $script:CachedToken = [string]$reply.access_token
        $seconds = 0
        if (-not [int]::TryParse([string]$reply.expires_in, [ref]$seconds)) { $seconds = 1200 }
        $script:TokenExpiryUtc = [datetime]::UtcNow.AddSeconds([math]::Max(120, $seconds))
    }
    $env:PGPASSWORD = $script:CachedToken
}

# Use a file for SQL to avoid native-process command-line quoting surprises.
# PostgreSQL COPY TO STDOUT emits only the data, never a COPY count in this mode.
function Invoke-CopySelectFile {
    param([string]$Database,[string]$Sql,[string]$Destination,[string]$ErrorLog)
    $sqlFile = Join-Path $script:ScratchDirectory 'readonly-query.sql'
    Save-Utf8NoBom -Path $sqlFile -Content ($Sql + "`n")
    Set-IdentityToken
    $argumentList = @(
        '-X','-w','-q','-v','ON_ERROR_STOP=1',
        '-h',$Server,'-p',$Port,'-U',$UserName,'-d',$Database,
        '-f',('"' + $sqlFile + '"')
    )
    $proc = Start-Process -FilePath $PsqlPath `
        -ArgumentList $argumentList `
        -RedirectStandardOutput $Destination `
        -RedirectStandardError $ErrorLog `
        -PassThru -Wait -NoNewWindow
    $proc.Refresh()
    if ($proc.ExitCode -ne 0) {
        $tail = @()
        if (Test-Path -LiteralPath $ErrorLog) {
            $tail = @(Get-Content -LiteralPath $ErrorLog -Tail 12 -ErrorAction SilentlyContinue)
        }
        throw "Read-only psql export failed ($Database, code $($proc.ExitCode)).`n$($tail -join [Environment]::NewLine)"
    }
}

# Full metadata is checked again before comparing rows. Never compare incompatible schemas.
# Covers ordinary tables in every user schema. primary_key_column is empty unless the
# table has a single-column primary key. Keep identical to ApprovedSync\Sync-ApprovedRecords.ps1.
$catalogSql = @'
COPY (
  SELECT n.nspname AS schema_name,
         c.relname AS table_name,
         COALESCE((
           SELECT string_agg(
             a.attnum::text || ':' || encode(convert_to(a.attname, 'UTF8'),'hex') || ':' ||
             pg_catalog.format_type(a.atttypid, a.atttypmod), '|'
             ORDER BY a.attnum
           )
           FROM pg_catalog.pg_attribute a
           WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
         ), '') AS column_signature,
         COALESCE((
           SELECT a.attname::text
           FROM pg_catalog.pg_index i
           JOIN pg_catalog.pg_attribute a
             ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
           WHERE i.indrelid = c.oid AND i.indisprimary
             AND i.indnkeyatts = 1
         ), '') AS primary_key_column
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
    AND c.relkind = 'r'
  ORDER BY n.nspname COLLATE "C", c.relname COLLATE "C"
) TO STDOUT WITH (FORMAT csv, HEADER true);
'@

$oldEnv = @{}
foreach ($name in @('PGPASSWORD','PGSSLMODE','PGCONNECT_TIMEOUT','PGTZ','PGDATESTYLE','PGCLIENTENCODING','PGOPTIONS','PGAPPNAME')) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    # Client-level read-only guard. Existing DB objects and records cannot be altered.
    $env:PGOPTIONS = '-c default_transaction_read_only=on'
    $env:PGSSLMODE = $SslMode
    $env:PGCONNECT_TIMEOUT = '25'
    $env:PGTZ = 'UTC'
    $env:PGDATESTYLE = 'ISO,MDY'
    $env:PGCLIENTENCODING = 'UTF8'
    $env:PGAPPNAME = 'ReadOnly_Record_Compare'

    if ($Resume) {
        if ([string]::IsNullOrWhiteSpace($RunDirectory) -or -not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
            throw '-Resume requires an existing -RunDirectory.'
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
            $suffix = [guid]::NewGuid().ToString('N').Substring(0,8)
            $RunDirectory = Join-Path $OutputRoot ([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + $suffix)
        }
        if (Test-Path -LiteralPath $RunDirectory) {
            throw "Output folder already exists. Use -Resume to continue it: $RunDirectory"
        }
        New-Item -Path $RunDirectory -ItemType Directory -Force | Out-Null
    }
    # Resolve against the PowerShell location; .NET file APIs use the process directory.
    $RunDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDirectory)
    $script:ScratchDirectory = Join-Path $RunDirectory '_scratch'
    $resultsDir = Join-Path $RunDirectory 'results'
    $detailsDir = Join-Path $RunDirectory 'record-ids'
    $logsDir = Join-Path $RunDirectory 'logs'
    foreach ($path in @($script:ScratchDirectory,$resultsDir,$detailsDir,$logsDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    Write-Host "Read-only record comparison output: $RunDirectory" -ForegroundColor Cyan
    Write-Host "Source: $SourceDatabase  ->  Target: $TargetDatabase" -ForegroundColor Cyan
    $sourceCatalog = Join-Path $RunDirectory 'source-catalog.csv'
    $targetCatalog = Join-Path $RunDirectory 'target-catalog.csv'
    $tmpSourceCat = Join-Path $script:ScratchDirectory 'source-catalog-current.csv'
    $tmpTargetCat = Join-Path $script:ScratchDirectory 'target-catalog-current.csv'
    Invoke-CopySelectFile -Database $SourceDatabase -Sql $catalogSql -Destination $tmpSourceCat -ErrorLog (Join-Path $logsDir 'catalog-source.err.log')
    Invoke-CopySelectFile -Database $TargetDatabase -Sql $catalogSql -Destination $tmpTargetCat -ErrorLog (Join-Path $logsDir 'catalog-target.err.log')
    if ($Resume) {
        foreach ($pair in @(@($tmpSourceCat,$sourceCatalog),@($tmpTargetCat,$targetCatalog))) {
            if (-not (Test-Path -LiteralPath $pair[1])) { throw "Missing saved catalog: $($pair[1])" }
            $currentHash = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash
            $previousHash = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash
            if ($currentHash -cne $previousHash) {
                throw 'Catalog changed since prior run. Start a NEW comparison, not -Resume.'
            }
        }
        Remove-Item -LiteralPath $tmpSourceCat,$tmpTargetCat -Force
    }
    else {
        Move-Item -LiteralPath $tmpSourceCat -Destination $sourceCatalog
        Move-Item -LiteralPath $tmpTargetCat -Destination $targetCatalog
    }

    $sources = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    $targets = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @(Import-Csv -LiteralPath $sourceCatalog -Encoding UTF8)) {
        $key = [string]$r.schema_name + '.' + [string]$r.table_name
        $sources.Add($key,$r)
    }
    foreach ($r in @(Import-Csv -LiteralPath $targetCatalog -Encoding UTF8)) {
        $key = [string]$r.schema_name + '.' + [string]$r.table_name
        $targets.Add($key,$r)
    }
    $selected = @()
    if ($AllTables) {
        $selected = @($sources.Keys |
            Where-Object { $Schemas.Count -eq 0 -or $Schemas -ccontains [string]$sources[$_].schema_name } |
            Sort-Object -CaseSensitive)
    }
    else {
        foreach ($t in $Tables) {
            if (-not $sources.ContainsKey($t)) { throw "Source table not found: $t" }
        }
        $selected = @($Tables | Sort-Object -Unique -CaseSensitive)
    }
    if ($selected.Count -eq 0) { throw 'No tables selected.' }

    $configurationFile = Join-Path $RunDirectory 'run-config.json'
    if ($Resume) {
        $cfg = Get-Content -LiteralPath $configurationFile -Raw | ConvertFrom-Json
        if ($cfg.SourceDatabase -cne $SourceDatabase -or $cfg.TargetDatabase -cne $TargetDatabase -or
            $cfg.Server -cne $Server -or [int]$cfg.Port -ne $Port -or $cfg.SelectedTables.Count -ne $selected.Count -or
            [long]$cfg.MaxDetailRowsPerTable -ne $MaxDetailRowsPerTable) {
            throw 'Run configuration differs. Use the original database selection, table list and detail limit.'
        }
        for ($j=0; $j -lt $selected.Count; $j++) {
            if ($cfg.SelectedTables[$j] -cne $selected[$j]) { throw 'Table selection differs from saved run.' }
        }
    }
    else {
        [PSCustomObject]@{
            CreatedUtc = [datetime]::UtcNow.ToString('o')
            Server = $Server
            Port = $Port
            SourceDatabase = $SourceDatabase
            TargetDatabase = $TargetDatabase
            SelectedTables = $selected
            MaxDetailRowsPerTable = $MaxDetailRowsPerTable
            RecordKey = 'Single-column primary key of each table, compared as text'
            Fingerprint = 'SHA256(UTF8(to_jsonb(table_row)::text)), UTC/ISO normalized'
            Note = 'Two databases are read with separate SELECT snapshots; not one atomic cross-database snapshot.'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configurationFile -Encoding UTF8
    }

    Write-Host "Tables selected: $($selected.Count). This is a full-row scan in each selected database."
    $i = 0
    $preflightPassed = 0
    $preflightSkipped = 0
    foreach ($table in $selected) {
        $i++
        $slug = Get-TableFilename -Table $table
        $completedJson = Join-Path $resultsDir ($slug + '.json')
        $detailPath = Join-Path $detailsDir ($slug + '.csv.gz')
        if ((Test-Path -LiteralPath $completedJson) -and (Test-Path -LiteralPath $detailPath)) {
            Write-Host "[$i/$($selected.Count)] RESUME skip $table" -ForegroundColor DarkGray
            continue
        }
        $startUtc = [datetime]::UtcNow
        Write-Host "[$i/$($selected.Count)] Comparing $table" -ForegroundColor Cyan
        $result = [ordered]@{
            Table = $table
            Status = 'INCOMPATIBLE'
            SourceRows = 0L
            TargetRows = 0L
            SourceOnly = 0L
            Changed = 0L
            TargetOnly = 0L
            Unchanged = 0L
            DetailRowsWritten = 0L
            DetailsTruncated = $false
            StartedUtc = $startUtc.ToString('o')
            FinishedUtc = ''
            Warning = ''
            DetailFile = ''
        }
        if (-not $targets.ContainsKey($table)) {
            $result.Warning = 'Target table does not exist; schema change requires separate approval.'
        }
        elseif ($sources[$table].column_signature -cne $targets[$table].column_signature) {
            $result.Warning = 'Column order/type mismatch; row hash comparison would be misleading.'
        }
        elseif ([string]::IsNullOrEmpty([string]$sources[$table].primary_key_column) -or
                [string]$sources[$table].primary_key_column -cne [string]$targets[$table].primary_key_column) {
            $result.Warning = 'Expected the same single-column primary key in both databases.'
        }
        else {
            $qualified = (Quote-Ident ([string]$sources[$table].schema_name)) + '.' + (Quote-Ident ([string]$sources[$table].table_name))
            $keyColumn = [string]$sources[$table].primary_key_column
            if ($PreflightOnly) {
                $preflightSql = Get-FingerprintExportSql -QualifiedTable $qualified -KeyColumn $keyColumn -ZeroRows
                $preflightSrc = Join-Path $script:ScratchDirectory 'preflight-source.tsv'
                $preflightDst = Join-Path $script:ScratchDirectory 'preflight-target.tsv'
                Invoke-CopySelectFile -Database $SourceDatabase -Sql $preflightSql -Destination $preflightSrc -ErrorLog (Join-Path $logsDir 'preflight-source.err.log')
                Invoke-CopySelectFile -Database $TargetDatabase -Sql $preflightSql -Destination $preflightDst -ErrorLog (Join-Path $logsDir 'preflight-target.err.log')
                if ((Get-Item -LiteralPath $preflightSrc).Length -ne 0 -or (Get-Item -LiteralPath $preflightDst).Length -ne 0) {
                    throw 'A LIMIT 0 preflight unexpectedly returned rows.'
                }
                $preflightPassed++
                Write-Host "    SQL PREFLIGHT PASS: $table (both databases; zero rows read)" -ForegroundColor Green
                continue
            }
            $copySql = Get-FingerprintExportSql -QualifiedTable $qualified -KeyColumn $keyColumn
            $srcFile = Join-Path $script:ScratchDirectory ($slug + '-source.tsv')
            $dstFile = Join-Path $script:ScratchDirectory ($slug + '-target.tsv')
            $partialFile = $detailPath + '.partial'
            # These three files are created ONLY by this script within its own output folder.
            foreach ($path in @($srcFile,$dstFile,$partialFile)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
            try {
                Invoke-CopySelectFile -Database $SourceDatabase -Sql $copySql -Destination $srcFile -ErrorLog (Join-Path $logsDir 'latest-source.err.log')
                Invoke-CopySelectFile -Database $TargetDatabase -Sql $copySql -Destination $dstFile -ErrorLog (Join-Path $logsDir 'latest-target.err.log')
                $limit = -1L
                if ($MaxDetailRowsPerTable -gt 0) { $limit = $MaxDetailRowsPerTable }
                $merged = [SortedFingerprintMerge]::Merge($srcFile,$dstFile,$partialFile,$limit)
                if (Test-Path -LiteralPath $detailPath) { Remove-Item -LiteralPath $detailPath -Force }
                Move-Item -LiteralPath $partialFile -Destination $detailPath
                $result.Status = 'COMPARED'
                $result.SourceRows = [long]$merged.SourceRows
                $result.TargetRows = [long]$merged.TargetRows
                $result.SourceOnly = [long]$merged.OnlyInSource
                $result.Changed = [long]$merged.Changed
                $result.TargetOnly = [long]$merged.OnlyInTarget
                $result.Unchanged = [long]$merged.Unchanged
                $result.DetailRowsWritten = [long]$merged.DetailRowsWritten
                $result.DetailsTruncated = [bool]$merged.DetailsTruncated
                $result.DetailFile = ('record-ids/' + $slug + '.csv.gz')
                Write-Host "    source-only=$($result.SourceOnly); changed=$($result.Changed); target-only=$($result.TargetOnly); unchanged=$($result.Unchanged)" -ForegroundColor Green
            }
            catch {
                Write-Host "FAILED: $table -- $($_.Exception.Message)" -ForegroundColor Red
                throw
            }
            finally {
                # Remove only temporary fingerprint files produced in this run.
                foreach ($path in @($srcFile,$dstFile)) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        if ($result.Status -eq 'INCOMPATIBLE') {
            Write-Warning "$table SKIPPED: $($result.Warning)"
            if ($PreflightOnly) { $preflightSkipped++; continue }
        }
        $result.FinishedUtc = [datetime]::UtcNow.ToString('o')
        $jsonTmp = $completedJson + '.partial'
        [PSCustomObject]$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonTmp -Encoding UTF8
        Move-Item -LiteralPath $jsonTmp -Destination $completedJson -Force
    }

    if ($PreflightOnly) {
        Write-Host "SQL preflight complete: passed=$preflightPassed; incompatible/skipped=$preflightSkipped" -ForegroundColor Green
        Write-Host 'Preflight queried only metadata and validated LIMIT 0 queries. No full records were compared.'
        Write-Host 'Start a NEW run without -PreflightOnly to perform the comparison.'
        return
    }

    $records = @(
        Get-ChildItem -LiteralPath $resultsDir -Filter '*.json' -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
            Sort-Object Table
    )
    $summary = Join-Path $RunDirectory 'comparison-summary.csv'
    $records | Select-Object Table,Status,SourceRows,TargetRows,SourceOnly,Changed,TargetOnly,Unchanged,DetailRowsWritten,DetailsTruncated,Warning,StartedUtc,FinishedUtc,DetailFile |
        Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8
    $completed = @($records | Where-Object { $_.Status -eq 'COMPARED' }).Count
    $skipped = @($records | Where-Object { $_.Status -ne 'COMPARED' }).Count
    Write-Host "`nComparison report: $summary" -ForegroundColor Green
    Write-Host "Compared tables: $completed | Unsupported/skipped: $skipped"
    Write-Host 'No SQL DDL/DML was applied to either database.' -ForegroundColor Green
}
finally {
    foreach ($name in $oldEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], 'Process')
    }
    $script:CachedToken = $null
}
