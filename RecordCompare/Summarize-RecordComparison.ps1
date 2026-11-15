# Offline summarizer of per-table results. Does not connect to or modify PostgreSQL.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunDirectory
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$resultsDir = Join-Path $RunDirectory 'results'
if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
    throw "Results directory not found: $resultsDir"
}
$items = @(
    Get-ChildItem -LiteralPath $resultsDir -Filter '*.json' -File |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
        Sort-Object Table
)
if ($items.Count -eq 0) { throw 'No completed table results found yet.' }
$dest = Join-Path $RunDirectory 'comparison-summary.csv'
$items | Select-Object Table,Status,SourceRows,TargetRows,SourceOnly,Changed,TargetOnly,Unchanged,DetailRowsWritten,DetailsTruncated,Warning,StartedUtc,FinishedUtc,DetailFile |
    Export-Csv -LiteralPath $dest -NoTypeInformation -Encoding UTF8
Write-Host "Summary created from $($items.Count) completed/skipped table results: $dest" -ForegroundColor Green
$items | Group-Object Status | Select-Object Name,Count | Format-Table -AutoSize
