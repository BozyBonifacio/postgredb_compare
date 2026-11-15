# Sync-ApprovedRecords.ps1 - v2.0 (2026-11-15)
# Selective approved record synchronization - PowerShell 5.1 / PostgreSQL 18
# Source and target are two databases on the same PostgreSQL server.
# Three explicit modes: Prepare (source SELECT only), Validate (target TEMP tables only, rollback),
# Apply (INSERT and UPDATE target records; never DELETE; per-table transaction).
# Requires a complete RecordCompare\Compare-TableRecords.ps1 run folder with record-ids/*.csv.gz.
# Generated staging data contains source row data: protect the machine and folder ACLs.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Prepare','Validate','Apply')]
    [string]$Mode,
    [Parameter(Mandatory=$true)]
    [string]$RunDirectory,
    [Parameter(Mandatory=$true)]
    [string]$ComparisonDirectory,
    [Parameter(Mandatory=$true)]
    [string]$ApprovalManifest,
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [ValidateRange(1,65535)]
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
    [string[]]$Tables = @(),
    [ValidateRange(25,2000)]
    [int]$BatchSize = 500,
    # Optional tripwire: number of deployable tables expected in the manifest (0 = no check).
    [ValidateRange(0,100000)]
    [int]$ExpectedApprovedTableCount = 0,
    # Production hostname. Apply requires -Server to equal it (Production) or differ from it (Clone).
    [string]$ProductionServer = '',
    [string]$ConfirmTargetDatabase = '',
    [switch]$BackupRestoreVerified,
    [switch]$CloneTestPassed,
    [ValidateSet('Production','Clone')]
    [string]$Environment = 'Production',
    [switch]$CloneTargetServerConfirmed
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path,[string]$Value) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
}
function Quote-Identifier([string]$Value) { return '"' + $Value.Replace('"','""') + '"' }
function Quote-Literal([string]$Value) { return "'" + $Value.Replace("'","''") + "'" }
function Sql-FilePath([string]$Value) {
    if ($Value.Contains("'")) { throw "Unsafe path containing apostrophe: $Value" }
    return $Value.Replace('\','/')
}
function Test-Sha([string]$Value) { return ($Value -cmatch '^[0-9a-f]{64}$') }
# Record keys are interpolated into SQL and CSV, so only plain key text is accepted.
function Test-RecordKey([string]$Value) { return ($Value -cmatch '^[A-Za-z0-9_.:@-]{1,128}$') }
function Parse-SignatureColumns([string]$Signature) {
    $columns = New-Object 'System.Collections.Generic.List[string]'
    foreach ($segment in $Signature.Split('|')) {
        if ($segment -cnotmatch '^[0-9]+:([0-9a-f]+):') { throw "Invalid catalog signature element: $segment" }
        $hex = $Matches[1]
        if (($hex.Length % 2) -ne 0) { throw 'Odd hex length in catalog signature.' }
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i=0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [Convert]::ToByte($hex.Substring($i*2,2),16)
        }
        $columns.Add(([Text.Encoding]::UTF8.GetString($bytes)))
    }
    return $columns.ToArray()
}
function Table-Slug([string]$Table) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Table))).Replace('-','').Substring(0,16).ToLowerInvariant()
        $clean = [regex]::Replace($Table,'[^A-Za-z0-9_-]','_')
        if ($clean.Length -gt 48) { $clean = $clean.Substring(0,48) }
        return "$clean-$hash"
    }
    finally { $sha.Dispose() }
}
function Read-DifferenceFile([string]$Path) {
    $inStream = [IO.File]::OpenRead($Path)
    $gzip = [IO.Compression.GZipStream]::new($inStream,[IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($gzip,[Text.UTF8Encoding]::new($false,$true))
    try {
        if ($reader.ReadLine() -cne 'change_type,record_id,source_sha256,target_sha256') {
            throw "Unexpected record ID CSV format: $Path"
        }
        while ($null -ne ($line = $reader.ReadLine())) {
            # The comparison tool always double-quotes the record key. Keys are checked with
            # Test-RecordKey before use rather than interpolated into SQL unchecked.
            if ($line -cnotmatch '^(SOURCE_ONLY|CHANGED|TARGET_ONLY),"((?:[^"]|"")*)",([0-9a-f]{64}|),([0-9a-f]{64}|)$') {
                throw "Unsupported or malformed record row in $Path (will not execute untrusted SQL)."
            }
            [PSCustomObject]@{ Type=$Matches[1]; Id=$Matches[2].Replace('""','"'); SourceHash=$Matches[3]; TargetHash=$Matches[4] }
        }
    }
    finally {
        $reader.Dispose()
        $gzip.Dispose()
        $inStream.Dispose()
    }
}
# Single pass, so a table or column name that looks like a placeholder is never re-expanded.
function Expand-SqlTemplate([string]$Template,[hashtable]$Values) {
    return [regex]::Replace($Template,'__(TOTAL|INS|UPD|TARGET|KEY)__',{ param($m) [string]$Values[$m.Groups[1].Value] })
}

$script:Token = $null
$script:Expiry = [datetime]::MinValue
function Set-ManagedIdentityPassword {
    # Without a managed identity, libpq resolves the password itself.
    if ([string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) { return }
    if ($null -eq $script:Token -or [datetime]::UtcNow.AddMinutes(5) -ge $script:Expiry) {
        $resource = [Uri]::EscapeDataString('https://ossrdbms-aad.database.windows.net')
        $id = [Uri]::EscapeDataString($ManagedIdentityClientId)
        $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource&client_id=$id"
        $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers @{Metadata='true'} -TimeoutSec 30
        if ([string]::IsNullOrWhiteSpace([string]$resp.access_token)) { throw 'IMDS returned an empty token.' }
        $script:Token = [string]$resp.access_token
        $seconds = 0
        if (-not [int]::TryParse([string]$resp.expires_in,[ref]$seconds)) { $seconds=1200 }
        $script:Expiry = [datetime]::UtcNow.AddSeconds([math]::Max(120,$seconds))
    }
    $env:PGPASSWORD = $script:Token
}
function Run-Psql([string]$Database,[string]$SqlPath,[string]$LogPrefix,[bool]$ReadOnly) {
    Set-ManagedIdentityPassword
    if ($ReadOnly) { $env:PGOPTIONS='-c default_transaction_read_only=on' }
    else { $env:PGOPTIONS='-c default_transaction_read_only=off' }
    $arguments = @('-X','-w','-q','-v','ON_ERROR_STOP=1','-h',$Server,'-p',$Port,'-U',$UserName,'-d',$Database,'-f',('"'+$SqlPath+'"'))
    $out = "$LogPrefix.stdout.log"
    $err = "$LogPrefix.stderr.log"
    $p = Start-Process -FilePath $PsqlPath -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -Wait -NoNewWindow
    $p.Refresh()
    if ($p.ExitCode -ne 0) {
        $tail = @()
        if (Test-Path -LiteralPath $err) { $tail = @(Get-Content -LiteralPath $err -Tail 18 -ErrorAction SilentlyContinue) }
        throw "psql failed in $Database (exit code $($p.ExitCode)). Check $err`n$($tail -join [Environment]::NewLine)"
    }
}

function Get-SourceExportSql([string]$FullTable,[string]$KeyColumn,[string[]]$RecordIds,[string]$FilePath) {
    $items = @($RecordIds | ForEach-Object { Quote-Literal $_ })
    if ($items.Count -eq 0) { throw 'Empty export batch.' }
    $vals = $items -join ','
    $key = 't.' + (Quote-Identifier $KeyColumn)
    $p = Sql-FilePath $FilePath
    # Untyped literals resolve to the key column's type, so the primary key index is used for any key type.
    return '\copy (SELECT t.*, encode(sha256(convert_to(to_jsonb(t)::text, ''UTF8'')), ''hex'') AS "__approved_source_sha256" FROM ' + $FullTable + ' AS t WHERE ' + $key + ' IN (' + $vals + ') ORDER BY ' + $key + '::text COLLATE "C") TO ' + (Quote-Literal $p) + " WITH (FORMAT CSV, NULL '\N', FORCE_QUOTE *)"
}
function Get-TargetSql {
    param([string]$FullTable,[string]$KeyColumn,[string[]]$Columns,[int]$InsertCount,[int]$UpdateCount,[string]$KeyFile,[string[]]$BatchFiles,[bool]$Apply)
    $keyQ = Quote-Identifier $KeyColumn
    $colQ = @($Columns | ForEach-Object { Quote-Identifier $_ })
    $cols = $colQ -join ', '
    $stageCols = ($colQ + @('"__approved_source_sha256"')) -join ', '
    $stageSelect = (@($Columns | ForEach-Object { 's.' + (Quote-Identifier $_) })) -join ', '
    $updates = @($Columns | Where-Object { $_ -cne $KeyColumn } | ForEach-Object { (Quote-Identifier $_) + ' = s.' + (Quote-Identifier $_) }) -join ', '
    if ($UpdateCount -gt 0 -and [string]::IsNullOrWhiteSpace($updates)) { throw 'Cannot UPDATE a table containing only its key column.' }
    $values = @{ TOTAL=[string]($InsertCount+$UpdateCount); INS=[string]$InsertCount; UPD=[string]$UpdateCount; TARGET=$FullTable; KEY=$keyQ }
    $keyPath = Sql-FilePath $KeyFile
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add('\set ON_ERROR_STOP on')
    $parts.Add('BEGIN;')
    $parts.Add("SET LOCAL TIME ZONE 'UTC';")
    $parts.Add("SET LOCAL DateStyle TO 'ISO, MDY';")
    # record_id takes the exact type of the target key column, so key joins are type-safe and indexable.
    $parts.Add((Expand-SqlTemplate 'CREATE TEMP TABLE "__sync_keys" ON COMMIT DROP AS SELECT t.__KEY__ AS record_id, NULL::text AS change_type, NULL::text AS source_sha, NULL::text AS target_sha FROM __TARGET__ AS t WITH NO DATA;' $values))
    $parts.Add('ALTER TABLE "__sync_keys" ADD PRIMARY KEY (record_id), ALTER COLUMN change_type SET NOT NULL, ALTER COLUMN source_sha SET NOT NULL;')
    $parts.Add('\copy "__sync_keys" (record_id, change_type, source_sha, target_sha) FROM ' + (Quote-Literal $keyPath) + " WITH (FORMAT CSV, HEADER true, NULL '')")
    $parts.Add('CREATE TEMP TABLE "__sync_stage" AS SELECT * FROM ' + $FullTable + ' WITH NO DATA;')
    $parts.Add('ALTER TABLE "__sync_stage" ADD COLUMN "__approved_source_sha256" text;')
    foreach ($b in $BatchFiles) {
        $parts.Add('\copy "__sync_stage" (' + $stageCols + ') FROM ' + (Quote-Literal (Sql-FilePath $b)) + " WITH (FORMAT CSV, NULL '\N')")
    }
    $guard = @'
DO $sync_guard$
BEGIN
  IF (SELECT COUNT(*) FROM "__sync_keys") <> __TOTAL__ THEN
    RAISE EXCEPTION 'Approved key count mismatch';
  END IF;
  IF (SELECT COUNT(*) FROM "__sync_keys" WHERE change_type='SOURCE_ONLY') <> __INS__
     OR (SELECT COUNT(*) FROM "__sync_keys" WHERE change_type='CHANGED') <> __UPD__
     OR EXISTS (SELECT 1 FROM "__sync_keys" WHERE change_type NOT IN ('SOURCE_ONLY','CHANGED')) THEN
    RAISE EXCEPTION 'Approved operation counts or types do not match';
  END IF;
  IF (SELECT COUNT(*) FROM "__sync_stage") <> __TOTAL__ OR
     (SELECT COUNT(DISTINCT __KEY__) FROM "__sync_stage") <> __TOTAL__ THEN
    RAISE EXCEPTION 'Source row export missing or duplicated approved keys';
  END IF;
  IF EXISTS (
    SELECT 1 FROM "__sync_keys" k LEFT JOIN "__sync_stage" s ON s.__KEY__=k.record_id
    WHERE s.__KEY__ IS NULL
  ) OR EXISTS (
    SELECT 1 FROM "__sync_stage" s LEFT JOIN "__sync_keys" k ON k.record_id=s.__KEY__
    WHERE k.record_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Exported source keys differ from approved allowlist';
  END IF;
  IF EXISTS (
    SELECT 1 FROM "__sync_stage" s
    JOIN "__sync_keys" k ON k.record_id=s.__KEY__
    WHERE s."__approved_source_sha256" IS DISTINCT FROM k.source_sha
       OR encode(sha256(convert_to((to_jsonb(s) - '__approved_source_sha256')::text, 'UTF8')), 'hex') IS DISTINCT FROM k.source_sha
  ) THEN
    RAISE EXCEPTION 'Source row drift, invalid CSV transfer, or fingerprint mismatch';
  END IF;
  IF EXISTS (
    SELECT 1 FROM "__sync_keys" k JOIN __TARGET__ t ON t.__KEY__=k.record_id
    WHERE k.change_type='SOURCE_ONLY'
  ) THEN
    RAISE EXCEPTION 'Target now contains an originally source-only key; comparison is stale';
  END IF;
  IF EXISTS (
    SELECT 1 FROM "__sync_keys" k LEFT JOIN __TARGET__ t ON t.__KEY__=k.record_id
    WHERE k.change_type='CHANGED'
      AND (t.__KEY__ IS NULL OR encode(sha256(convert_to(to_jsonb(t)::text, 'UTF8')),'hex') IS DISTINCT FROM k.target_sha)
  ) THEN
    RAISE EXCEPTION 'Target row drift or missing UPDATE candidate; stop to avoid overwrite';
  END IF;
END $sync_guard$;
'@
    $parts.Add((Expand-SqlTemplate $guard $values))
    if ($Apply) {
        # Row locks protect changed records between fingerprint guard and UPDATE.
        $lock = @'
DO $sync_lock$
BEGIN
  PERFORM t.__KEY__ FROM __TARGET__ t JOIN "__sync_keys" k ON k.record_id=t.__KEY__
  WHERE k.change_type='CHANGED' FOR UPDATE OF t;
  IF EXISTS (
    SELECT 1 FROM "__sync_keys" k LEFT JOIN __TARGET__ t ON t.__KEY__=k.record_id
    WHERE k.change_type='CHANGED' AND
       (t.__KEY__ IS NULL OR encode(sha256(convert_to(to_jsonb(t)::text,'UTF8')),'hex') IS DISTINCT FROM k.target_sha)
  ) THEN
    RAISE EXCEPTION 'Target row modified while acquiring row locks; refusing UPDATE';
  END IF;
END $sync_lock$;
'@
        $parts.Add((Expand-SqlTemplate $lock $values))
        if ($InsertCount -gt 0) {
            $parts.Add('INSERT INTO ' + $FullTable + ' (' + $cols + ') SELECT ' + $stageSelect + ' FROM "__sync_stage" s JOIN "__sync_keys" k ON k.record_id=s.' + $keyQ + ' WHERE k.change_type=''SOURCE_ONLY'';')
        }
        if ($UpdateCount -gt 0) {
            $parts.Add('UPDATE ' + $FullTable + ' t SET ' + $updates + ' FROM "__sync_stage" s JOIN "__sync_keys" k ON k.record_id=s.' + $keyQ + ' WHERE t.' + $keyQ + '=k.record_id AND k.change_type=''CHANGED'';')
        }
        $post = @'
DO $sync_verify$
BEGIN
  IF EXISTS (
    SELECT 1 FROM "__sync_keys" k LEFT JOIN __TARGET__ t ON t.__KEY__=k.record_id
    WHERE t.__KEY__ IS NULL OR encode(sha256(convert_to(to_jsonb(t)::text,'UTF8')),'hex') IS DISTINCT FROM k.source_sha
  ) THEN
    RAISE EXCEPTION 'Post-write fingerprint verification failed; rolling back table transaction';
  END IF;
END $sync_verify$;
'@
        $parts.Add((Expand-SqlTemplate $post $values))
        $parts.Add('COMMIT;')
    }
    else { $parts.Add('ROLLBACK;') }
    return ($parts -join "`r`n") + "`r`n"
}

# Exact same catalog query as RecordCompare\Compare-TableRecords.ps1.
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
function Assert-LiveCatalogMatchesComparison([string]$MetadataDirectory,[string]$LogsDirectory,[string]$SourceCatalogPath,[string]$TargetCatalogPath) {
    $sqlPath = Join-Path $MetadataDirectory 'live-catalog.sql'
    Write-Utf8NoBom -Path $sqlPath -Value ($catalogSql + "`r`n")
    foreach ($pair in @(@($SourceDatabase,$SourceCatalogPath,'live-source-catalog'),@($TargetDatabase,$TargetCatalogPath,'live-target-catalog'))) {
        $prefix = Join-Path $LogsDirectory ([string]$pair[2])
        Run-Psql -Database ([string]$pair[0]) -SqlPath $sqlPath -LogPrefix $prefix -ReadOnly $true
        $live = "$prefix.stdout.log"
        if ((Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath ([string]$pair[1]) -Algorithm SHA256).Hash) {
            throw "Live schema catalog drifted since the baseline comparison ($($pair[0])). Stop; re-run the record comparison."
        }
    }
}

if (-not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) { throw "psql.exe not found: $PsqlPath" }
if ($SourceDatabase -ceq $TargetDatabase) { throw 'Source and target must be different databases.' }
foreach ($name in @($Server, $UserName, $SourceDatabase, $TargetDatabase)) {
    if ($name -notmatch '^[a-zA-Z0-9_.@-]+$') { throw "Unsafe connection argument: $name" }
}
if ($Mode -eq 'Apply') {
    if ($ConfirmTargetDatabase -cne $TargetDatabase) {
        throw "Apply requires -ConfirmTargetDatabase $TargetDatabase."
    }
    if ([string]::IsNullOrWhiteSpace($ProductionServer)) {
        throw 'Apply requires -ProductionServer (the production hostname) for the server safety guard.'
    }
    # Hostnames are case-insensitive, so they are compared without -c operators.
    if ($Environment -ceq 'Clone') {
        if ($Server -eq $ProductionServer -or -not $CloneTargetServerConfirmed) {
            throw 'Clone Apply requires -Environment Clone, a -Server different from -ProductionServer, and -CloneTargetServerConfirmed.'
        }
    }
    else {
        if ($Server -ne $ProductionServer -or -not $BackupRestoreVerified -or -not $CloneTestPassed) {
            throw 'Production Apply requires -Server equal to -ProductionServer and -BackupRestoreVerified -CloneTestPassed.'
        }
    }
}
# Resolve against the PowerShell location; .NET file APIs use the process directory.
$RunDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDirectory)
$ComparisonDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ComparisonDirectory)
$ApprovalManifest = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ApprovalManifest)
if (-not (Test-Path -LiteralPath $ApprovalManifest -PathType Leaf)) { throw "Missing approval manifest: $ApprovalManifest" }
if (-not (Test-Path -LiteralPath $ComparisonDirectory -PathType Container)) { throw "Missing baseline comparison folder: $ComparisonDirectory" }
$refSummary = Join-Path $ComparisonDirectory 'comparison-summary.csv'
$sourceCatalogPath = Join-Path $ComparisonDirectory 'source-catalog.csv'
$targetCatalogPath = Join-Path $ComparisonDirectory 'target-catalog.csv'
$baselineConfigPath = Join-Path $ComparisonDirectory 'run-config.json'
foreach ($path in @($refSummary,$sourceCatalogPath,$targetCatalogPath,$baselineConfigPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing baseline comparison artifact: $path" }
}
$baselineConfig = Get-Content -LiteralPath $baselineConfigPath -Raw | ConvertFrom-Json
if ([string]$baselineConfig.SourceDatabase -cne $SourceDatabase -or [string]$baselineConfig.TargetDatabase -cne $TargetDatabase) {
    throw "Safety guard: the baseline compared $($baselineConfig.SourceDatabase) -> $($baselineConfig.TargetDatabase); pass the same -SourceDatabase and -TargetDatabase."
}
$originalEnv = @{}
foreach($name in @('PGPASSWORD','PGOPTIONS','PGSSLMODE','PGCONNECT_TIMEOUT','PGCLIENTENCODING','PGTZ','PGDATESTYLE','PGAPPNAME')) {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:PGSSLMODE=$SslMode
    $env:PGCONNECT_TIMEOUT='30'
    $env:PGCLIENTENCODING='UTF8'
    $env:PGTZ='UTC'
    $env:PGDATESTYLE='ISO,MDY'
    $env:PGAPPNAME='Approved_Record_Sync'
    if ($Mode -eq 'Prepare') {
        if (Test-Path -LiteralPath $RunDirectory) { throw "RunDirectory exists; choose a NEW directory: $RunDirectory" }
        New-Item -ItemType Directory -Force -Path $RunDirectory | Out-Null
    }
    elseif (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        throw "Deployment folder missing. Run -Mode Prepare first: $RunDirectory"
    }
    $logsDir = Join-Path $RunDirectory 'logs'
    $metaDir = Join-Path $RunDirectory 'metadata'
    $tableDir = Join-Path $RunDirectory 'tables'
    foreach($d in @($logsDir,$metaDir,$tableDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

    Assert-LiveCatalogMatchesComparison -MetadataDirectory $metaDir -LogsDirectory $logsDir -SourceCatalogPath $sourceCatalogPath -TargetCatalogPath $targetCatalogPath

    # Manifest rules apply to every row, selected or not. Any approval other than 'Approved'
    # (for example 'Deferred') excludes that operation and must carry a zero approved count.
    $scopeRows = @(Import-Csv -LiteralPath $ApprovalManifest -Encoding UTF8)
    $manifestTables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $scopeRows) {
        $table = [string]$r.Table
        if (-not $manifestTables.Add($table)) { throw "Duplicate approval manifest row: $table" }
        if ([string]$r.DeleteApproval -cne 'REJECTED' -or [string]$r.ApprovedDeleteCandidates -cne '0') { throw "DELETE not rejected: $table" }
        if ([string]$r.InsertApproval -cne 'Approved' -and [long]$r.ApprovedInsertCandidates -ne 0) { throw "INSERT is not Approved but has approved candidates: $table" }
        if ([string]$r.UpdateApproval -cne 'Approved' -and [long]$r.ApprovedUpdateCandidates -ne 0) { throw "UPDATE is not Approved but has approved candidates: $table" }
    }
    $approved = @($scopeRows | Where-Object {
        ([long]$_.ApprovedInsertCandidates + [long]$_.ApprovedUpdateCandidates) -gt 0
    })
    if ($ExpectedApprovedTableCount -gt 0 -and $approved.Count -ne $ExpectedApprovedTableCount) {
        throw "Expected $ExpectedApprovedTableCount deployable tables in the manifest; found $($approved.Count)."
    }
    $summaries = @{}
    foreach($r in @(Import-Csv -LiteralPath $refSummary -Encoding UTF8)) { $summaries[[string]$r.Table] = $r }
    $catalog = @{}
    foreach($r in @(Import-Csv -LiteralPath $sourceCatalogPath -Encoding UTF8)) {
        $catalog[([string]$r.schema_name + '.' + [string]$r.table_name)] = $r
    }
    $targetCatalog = @{}
    foreach($r in @(Import-Csv -LiteralPath $targetCatalogPath -Encoding UTF8)) {
        $targetCatalog[([string]$r.schema_name + '.' + [string]$r.table_name)] = $r
    }
    $selected = @($approved)
    if ($Tables.Count -gt 0) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($name in $Tables) { if (-not $wanted.Add($name)) { throw "Duplicate -Tables entry: $name" } }
        $selected = @($approved | Where-Object { $wanted.Contains([string]$_.Table) })
        if ($selected.Count -ne $wanted.Count) { throw 'At least one requested table is absent from the approved change scope.' }
    }
    if ($selected.Count -eq 0) { throw 'No approved tables selected.' }
    $planPath = Join-Path $metaDir 'plan.json'
    $approvalSha = (Get-FileHash -LiteralPath $ApprovalManifest -Algorithm SHA256).Hash
    $baselineSha = (Get-FileHash -LiteralPath $refSummary -Algorithm SHA256).Hash
    if ($Mode -eq 'Prepare') {
        [PSCustomObject]@{
            Server=$Server; Port=$Port; Source=$SourceDatabase; Target=$TargetDatabase; Environment=$Environment
            ApprovedScopeSHA256=$approvalSha; BaselineSummarySHA256=$baselineSha
            SelectedTables=@($selected | ForEach-Object { $_.Table })
            BatchSize=$BatchSize
            CreatedUtc=[datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $planPath -Encoding UTF8
    }
    else {
        $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
        if ($plan.Server -ne $Server -or [int]$plan.Port -ne $Port -or $plan.Environment -cne $Environment -or $plan.Source -cne $SourceDatabase -or $plan.Target -cne $TargetDatabase -or
            $plan.ApprovedScopeSHA256 -cne $approvalSha -or $plan.BaselineSummarySHA256 -cne $baselineSha -or
            [int]$plan.BatchSize -ne $BatchSize -or $plan.SelectedTables.Count -ne $selected.Count) {
            throw 'The server, source, target, manifest, baseline, selection or batch size differs from the prepared plan.'
        }
        for($j=0;$j -lt $selected.Count;$j++) { if ($plan.SelectedTables[$j] -cne $selected[$j].Table) { throw 'Selected table order differs from prepared plan.' } }
    }
    $manifestRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $selected) {
        $table=[string]$r.Table
        if (-not $summaries.ContainsKey($table)) { throw "Unknown baseline table $table" }
        if (-not $catalog.ContainsKey($table) -or -not $targetCatalog.ContainsKey($table)) { throw "Missing catalog table $table" }
        if ([string]$catalog[$table].column_signature -cne [string]$targetCatalog[$table].column_signature) { throw "Source/target schema mismatch: $table" }
        $keyColumn = [string]$catalog[$table].primary_key_column
        if ([string]::IsNullOrEmpty($keyColumn) -or $keyColumn -cne [string]$targetCatalog[$table].primary_key_column) {
            throw "Expected the same single-column primary key in both databases: $table"
        }
        $b = $summaries[$table]
        if ($b.Status -cne 'COMPARED' -or [string]$b.DetailsTruncated -cne 'False' -or
            [long]$b.DetailRowsWritten -ne ([long]$b.SourceOnly+[long]$b.Changed+[long]$b.TargetOnly) -or
            [long]$r.SourceOnlyCandidates -ne [long]$b.SourceOnly -or [long]$r.ChangedCandidates -ne [long]$b.Changed -or
            [long]$r.TargetOnlyPreserved -ne [long]$b.TargetOnly) {
            throw "Unreconciled baseline or truncated detail: $table"
        }
        # An approved operation covers all of its baseline candidates; there is no per-record approval.
        $insertApproved = ([string]$r.InsertApproval -ceq 'Approved')
        $updateApproved = ([string]$r.UpdateApproval -ceq 'Approved')
        if ($insertApproved -and [long]$r.ApprovedInsertCandidates -ne [long]$b.SourceOnly) { throw "Approved INSERT count must equal all SOURCE_ONLY records: $table" }
        if ($updateApproved -and [long]$r.ApprovedUpdateCandidates -ne [long]$b.Changed) { throw "Approved UPDATE count must equal all CHANGED records: $table" }
        $parts = $table.Split('.')
        if ($parts.Length -ne 2 -or $parts[0].Length -eq 0 -or $parts[1].Length -eq 0) { throw "Unsafe table name $table" }
        $fullTable = (Quote-Identifier $parts[0]) + '.' + (Quote-Identifier $parts[1])
        $slug=Table-Slug $table
        $dir=Join-Path $tableDir $slug
        if ($Mode -eq 'Prepare') { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Missing table staging directory $dir" }
        $keys=Join-Path $dir 'keys.csv'
        $sourceSql=Join-Path $dir 'extract-source.sql'
        $validateSql=Join-Path $dir 'validate-target.sql'
        $applySql=Join-Path $dir 'apply-target.sql'
        $cols = @(Parse-SignatureColumns -Signature ([string]$catalog[$table].column_signature))
        if ($cols.Count -eq 0 -or -not ($cols -ccontains $keyColumn) -or $cols -ccontains '__approved_source_sha256') { throw "Unsupported columns in $table" }
        $countInsert=[int]$r.ApprovedInsertCandidates
        $countUpdate=[int]$r.ApprovedUpdateCandidates
        $expected=$countInsert+$countUpdate
        $detailFile=Join-Path $ComparisonDirectory ([string]$b.DetailFile).Replace('/','\')
        if (-not (Test-Path -LiteralPath $detailFile -PathType Leaf)) { throw "Missing saved record IDs: $detailFile" }
        $batchDir=Join-Path $dir 'batches'
        if ($Mode -eq 'Prepare') { New-Item -ItemType Directory -Path $batchDir -Force | Out-Null }
        $batchFiles=@()
        $batchCount=[int][math]::Ceiling([double]$expected / $BatchSize)
        for($i=0; $i -lt $batchCount; $i++) { $batchFiles += (Join-Path $batchDir (('batch-{0:D4}.csv' -f $i))) }
        if ($Mode -eq 'Prepare') {
            Write-Host "Preparing ${table}: INSERT $countInsert / UPDATE $countUpdate (key $keyColumn)" -ForegroundColor Cyan
            $rows = New-Object 'System.Collections.Generic.List[object]'
            $seenInsert=0; $seenUpdate=0; $seenTargetOnly=0
            foreach($entry in (Read-DifferenceFile $detailFile)) {
                if ($entry.Type -ceq 'TARGET_ONLY') { $seenTargetOnly++; continue }
                if (-not (Test-Sha $entry.SourceHash)) { throw "Invalid source fingerprint in $table" }
                if ($entry.Type -ceq 'CHANGED') {
                    if (-not (Test-Sha $entry.TargetHash)) { throw "Invalid target fingerprint in $table" }
                    $seenUpdate++
                    if (-not $updateApproved) { continue }
                }
                elseif ($entry.Type -ceq 'SOURCE_ONLY') {
                    $seenInsert++
                    if (-not $insertApproved) { continue }
                }
                else { throw "Unexpected difference type in $table" }
                if (-not (Test-RecordKey $entry.Id)) { throw "Unsupported record key format in $table (will not interpolate it into SQL)." }
                $rows.Add($entry)
            }
            if ($seenInsert -ne [int]$b.SourceOnly -or $seenUpdate -ne [int]$b.Changed -or $seenTargetOnly -ne [int]$r.TargetOnlyPreserved -or $rows.Count -ne $expected) {
                throw "Difference file counts do not match approved scope: $table"
            }
            $keyLines = New-Object 'System.Collections.Generic.List[string]'
            $keyLines.Add('record_id,change_type,source_sha256,target_sha256')
            foreach($entry in $rows) { $keyLines.Add(($entry.Id + ',' + $entry.Type + ',' + $entry.SourceHash + ',' + $entry.TargetHash)) }
            Write-Utf8NoBom -Path $keys -Value (($keyLines -join "`r`n") + "`r`n")
            $export = New-Object 'System.Collections.Generic.List[string]'
            $export.Add('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;')
            $export.Add("SET LOCAL TIME ZONE 'UTC';")
            $export.Add("SET LOCAL DateStyle TO 'ISO, MDY';")
            for($i=0; $i -lt $batchCount; $i++) {
                $start=$i*$BatchSize
                $end=[math]::Min($start+$BatchSize,$rows.Count)
                $ids = @($rows.GetRange($start,$end-$start) | ForEach-Object { $_.Id })
                $export.Add((Get-SourceExportSql -FullTable $fullTable -KeyColumn $keyColumn -RecordIds $ids -FilePath $batchFiles[$i]))
            }
            $export.Add('COMMIT;')
            Write-Utf8NoBom -Path $sourceSql -Value (($export -join "`r`n") + "`r`n")
            Write-Utf8NoBom -Path $validateSql -Value (Get-TargetSql -FullTable $fullTable -KeyColumn $keyColumn -Columns $cols -InsertCount $countInsert -UpdateCount $countUpdate -KeyFile $keys -BatchFiles $batchFiles -Apply $false)
            Write-Utf8NoBom -Path $applySql -Value (Get-TargetSql -FullTable $fullTable -KeyColumn $keyColumn -Columns $cols -InsertCount $countInsert -UpdateCount $countUpdate -KeyFile $keys -BatchFiles $batchFiles -Apply $true)
            Run-Psql -Database $SourceDatabase -SqlPath $sourceSql -LogPrefix (Join-Path $logsDir "$slug-source-export") -ReadOnly $true
            foreach($p in $batchFiles) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Source export did not create $p" } }
            $hashes = @((@($keys,$validateSql,$applySql,$sourceSql) + $batchFiles) | ForEach-Object {
                [PSCustomObject]@{ Name=[IO.Path]::GetFileName($_); Path=$_; Sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
            })
            $hashes | Export-Csv -LiteralPath (Join-Path $dir 'files.sha256.csv') -NoTypeInformation -Encoding UTF8
        }
        else {
            $hashPath=Join-Path $dir 'files.sha256.csv'
            if (-not (Test-Path -LiteralPath $hashPath)) { throw "Missing file checksums for $table" }
            foreach($entry in @(Import-Csv -LiteralPath $hashPath -Encoding UTF8)) {
                if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -cne $entry.Sha256) {
                    throw "Prepared staging file is missing or was modified: $($entry.Path)"
                }
            }
        }
        $manifestRows.Add([PSCustomObject]@{ Table=$table; KeyColumn=$keyColumn; Insert=$countInsert; Update=$countUpdate; TargetOnlyPreserved=[int]$r.TargetOnlyPreserved; Folder=$dir })
        if ($Mode -eq 'Validate') {
            Write-Host "VALIDATING ${table}: INSERT $countInsert / UPDATE $countUpdate (ROLLBACK)" -ForegroundColor Cyan
            Run-Psql -Database $TargetDatabase -SqlPath $validateSql -LogPrefix (Join-Path $logsDir "$slug-validate-target") -ReadOnly $false
            # Validation creates and drops temporary staging tables. It does not change permanent tables.
            Write-Utf8NoBom -Path (Join-Path $dir 'validated.ok') -Value ([datetime]::UtcNow.ToString('o'))
        }
        elseif ($Mode -eq 'Apply') {
            if (-not (Test-Path -LiteralPath (Join-Path $dir 'validated.ok'))) { throw "Not validated yet: $table" }
            if (Test-Path -LiteralPath (Join-Path $dir 'applied.ok')) { throw "Already marked applied: $table. Stop, verify the state; never rerun blindly." }
            Write-Host "APPLYING ${table}: INSERT $countInsert / UPDATE $countUpdate (NO DELETE)" -ForegroundColor Yellow
            Run-Psql -Database $TargetDatabase -SqlPath $applySql -LogPrefix (Join-Path $logsDir "$slug-apply-target") -ReadOnly $false
            Write-Utf8NoBom -Path (Join-Path $dir 'applied.ok') -Value ([datetime]::UtcNow.ToString('o'))
            Write-Host "COMMITTED AND VERIFIED: $table" -ForegroundColor Green
        }
    }
    if ($Mode -eq 'Prepare') {
        $manifestRows | Export-Csv -LiteralPath (Join-Path $metaDir 'selected-approved-scope.csv') -NoTypeInformation -Encoding UTF8
        Write-Host "PREPARED: $($manifestRows.Count) approved tables. No target database changes." -ForegroundColor Green
    }
    elseif ($Mode -eq 'Validate') {
        Write-Host "VALIDATED: $($manifestRows.Count) approved tables. No permanent target database changes." -ForegroundColor Green
    }
    else {
        Write-Host "APPLY COMPLETE: $($manifestRows.Count) tables committed separately. No DELETE SQL generated." -ForegroundColor Green
    }
}
finally {
    foreach($name in $originalEnv.Keys) { [Environment]::SetEnvironmentVariable($name,$originalEnv[$name],'Process') }
    $script:Token=$null
}
