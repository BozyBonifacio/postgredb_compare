# Offline unit test for the merge engine. No database / network use.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$cs = Join-Path $PSScriptRoot 'SortedFingerprintMerge.cs'
if (-not ('SortedFingerprintMerge' -as [type])) {
    Add-Type -Path $cs -ReferencedAssemblies @('System.dll','System.Core.dll','System.IO.Compression.dll') -ErrorAction Stop
}
$folder = Join-Path $env:TEMP ('RecordCompareTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
try {
    $src = Join-Path $folder 'source.tsv'
    $dst = Join-Path $folder 'target.tsv'
    $out = Join-Path $folder 'changes.csv.gz'
    $hashA = 'a' * 64
    $hashB = 'b' * 64
    $hashC = 'c' * 64
    $hashD = 'd' * 64
    $tab = [char]9
    # A unchanged; B changed; C source-only; D target-only.
    $srcLines = @("41${tab}$hashA", "42${tab}$hashB", "43${tab}$hashC")
    $dstLines = @("41${tab}$hashA", "42${tab}$hashD", "44${tab}$hashC")
    [IO.File]::WriteAllLines($src,$srcLines,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllLines($dst,$dstLines,(New-Object Text.UTF8Encoding($false)))
    $r = [SortedFingerprintMerge]::Merge($src,$dst,$out,-1L)
    if ($r.SourceRows -ne 3 -or $r.TargetRows -ne 3 -or $r.Unchanged -ne 1 -or
        $r.Changed -ne 1 -or $r.OnlyInSource -ne 1 -or $r.OnlyInTarget -ne 1 -or
        $r.DetailRowsWritten -ne 3 -or $r.DetailsTruncated) {
        throw "Local merge test failed: $($r | Out-String)"
    }
    $fs = [IO.File]::OpenRead($out)
    try {
        $gz = [IO.Compression.GZipStream]::new($fs,[IO.Compression.CompressionMode]::Decompress)
        try {
            $reader = [IO.StreamReader]::new($gz)
            try { $lines = @($reader.ReadToEnd() -split "`n" | Where-Object { $_.Trim().Length -gt 0 }) }
            finally { $reader.Dispose() }
        }
        finally { $gz.Dispose() }
    }
    finally { $fs.Dispose() }
    if ($lines.Count -ne 4 -or ($lines -join "`n") -notmatch 'SOURCE_ONLY,"C"' -or
        ($lines -join "`n") -notmatch 'TARGET_ONLY,"D"' -or
        ($lines -join "`n") -notmatch 'CHANGED,"B"') {
        throw 'GZip CSV output was incorrect.'
    }
    # Static query regression check: the former SELECT-alias COLLATE caused
    # PostgreSQL error 42703. Live PostgreSQL syntax validation is performed
    # separately with -PreflightOnly.
    $mainScript = Join-Path $PSScriptRoot 'Compare-TableRecords.ps1'
    $scriptText = [System.IO.File]::ReadAllText($mainScript)
    if ($scriptText -match 'ORDER\s+BY\s+id_hex\s+COLLATE' -or
        $scriptText -notmatch 'ORDER\s+BY\s+fp\.id_hex\s+COLLATE' -or
        $scriptText -notmatch 'FROM\s+\$QualifiedTable\s+AS\s+t') {
        throw 'SQL query regression: expected outer fp.id_hex ORDER BY from a subquery.'
    }
    # The record key is each table's detected primary key, never a fixed column name.
    if ($scriptText -cmatch 't\."Id"' -or $scriptText -cnotmatch 'convert_to\(t\.\$key::text') {
        throw 'SQL query regression: expected the detected primary key column, not a fixed "Id".'
    }
    Write-Host 'PASS: static query regression check (output alias COLLATE bug removed; generic key).' -ForegroundColor Green
    Write-Host 'PASS: local streaming compare, counts, decoding and gzip details.' -ForegroundColor Green
    Write-Host 'No database or network access was used.'
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
