# Offline-only syntax and approval manifest check; never connects to Azure or PostgreSQL.
# Without -ApprovalManifest only the PowerShell syntax is checked.
# Expected totals are optional tripwires (-1 = not checked).
[CmdletBinding()]
param(
    [string]$ApprovalManifest,
    [int]$ExpectedApprovedTableCount = -1,
    [long]$ExpectedInsertCount = -1,
    [long]$ExpectedUpdateCount = -1
)
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'Sync-ApprovedRecords.ps1'
$tok = $null
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tok,[ref]$errs) | Out-Null
if ($errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host ($_.Extent.Text + ': ' + $_.Message) -ForegroundColor Red }
    throw "PowerShell syntax validation failed: $($errs.Count) error(s)."
}
if ([string]::IsNullOrWhiteSpace($ApprovalManifest)) {
    Write-Host 'PASS: PowerShell syntax. No manifest supplied; use -ApprovalManifest to check one.' -ForegroundColor Green
    Write-Host 'No network/database access was used.'
    return
}
$rows = @(Import-Csv -LiteralPath $ApprovalManifest -Encoding UTF8)
if ($rows.Count -eq 0) { throw "Approval manifest has no rows: $ApprovalManifest" }
# Same per-row rules as Sync-ApprovedRecords.ps1.
$tables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$ins = [long]0; $upd = [long]0; $del = [long]0; $deferred = 0
foreach($r in $rows) {
    if (-not $tables.Add([string]$r.Table)) { throw "Duplicate approval manifest row: $($r.Table)" }
    if ($r.DeleteApproval -cne 'REJECTED' -or [string]$r.ApprovedDeleteCandidates -cne '0') { throw "DELETE approval is not rejected: $($r.Table)" }
    if ($r.InsertApproval -cne 'Approved' -and [long]$r.ApprovedInsertCandidates -ne 0) { throw "INSERT is not Approved but has approved candidates: $($r.Table)" }
    if ($r.UpdateApproval -cne 'Approved' -and [long]$r.ApprovedUpdateCandidates -ne 0) { throw "UPDATE is not Approved but has approved candidates: $($r.Table)" }
    if ($r.InsertApproval -ceq 'Approved' -and [long]$r.ApprovedInsertCandidates -ne [long]$r.SourceOnlyCandidates) { throw "Approved INSERT count must equal SourceOnlyCandidates: $($r.Table)" }
    if ($r.UpdateApproval -ceq 'Approved' -and [long]$r.ApprovedUpdateCandidates -ne [long]$r.ChangedCandidates) { throw "Approved UPDATE count must equal ChangedCandidates: $($r.Table)" }
    if ($r.InsertApproval -ceq 'Deferred' -or $r.UpdateApproval -ceq 'Deferred') { $deferred++ }
    $ins += [long]$r.ApprovedInsertCandidates
    $upd += [long]$r.ApprovedUpdateCandidates
    $del += [long]$r.ApprovedDeleteCandidates
}
$toApply = @($rows | Where-Object { ([long]$_.ApprovedInsertCandidates+[long]$_.ApprovedUpdateCandidates) -gt 0 })
if (($ExpectedApprovedTableCount -ge 0 -and $toApply.Count -ne $ExpectedApprovedTableCount) -or
    ($ExpectedInsertCount -ge 0 -and $ins -ne $ExpectedInsertCount) -or
    ($ExpectedUpdateCount -ge 0 -and $upd -ne $ExpectedUpdateCount) -or $del -ne 0) {
    throw "Approval totals inconsistent: $($rows.Count) manifest rows, $($toApply.Count) applicable, inserts=$ins, updates=$upd, deletes=$del"
}
Write-Host "PASS: PowerShell syntax and approval manifest. Tables=$($toApply.Count), INSERT=$ins, UPDATE=$upd, DELETE=$del, tables with deferrals=$deferred." -ForegroundColor Green
Write-Host 'No network/database access was used.'
