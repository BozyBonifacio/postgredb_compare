# Runs locally on Windows PowerShell 5.1. Does not connect to any database.
$scriptFile = Join-Path $PSScriptRoot 'Compare-ChangedRecordFields.ps1'
if (-not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) { throw "Missing $scriptFile" }
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    foreach ($errorItem in $parseErrors) {
        Write-Host $errorItem.ToString() -ForegroundColor Red
    }
    throw "Syntax check failed: $($parseErrors.Count) errors."
}
Write-Host 'PASS: PowerShell parser found no syntax errors. No database access.' -ForegroundColor Green
