param(
    [string]$SourcePath = "fx_trade_copper.mq5"
)

$resolvedSource = $SourcePath
if (-not [System.IO.Path]::IsPathRooted($resolvedSource)) {
    $resolvedSource = Join-Path (Get-Location).Path $resolvedSource
}

if (-not (Test-Path $resolvedSource -PathType Leaf)) {
    throw "Source file not found: $resolvedSource"
}

$source = Get-Content -Path $resolvedSource -Raw
$failures = New-Object System.Collections.Generic.List[string]

if ($source -notmatch 'ResolveBrokerSymbolFromPool\s*\(\s*const\s+string\s+symbol_template\s*,\s*const\s+bool\s+selected_only\s*\)') {
    $failures.Add("Missing a dedicated broker-symbol pool resolver that can search selected and full symbol lists separately.")
}

if ($source -notmatch 'ResolveBrokerSymbolFromPool\s*\(\s*symbol_template\s*,\s*true\s*\)') {
    $failures.Add("ResolveBrokerSymbol does not appear to search Market Watch symbols before all broker symbols.")
}

if ($source -notmatch 'ResolveBrokerSymbolFromPool\s*\(\s*symbol_template\s*,\s*false\s*\)') {
    $failures.Add("ResolveBrokerSymbol does not appear to fall back to the full broker symbol list when Market Watch matching fails.")
}

if ($source -notmatch 'SYMBOL_TRADE_MODE') {
    $failures.Add("Candidate ranking does not inspect SYMBOL_TRADE_MODE, so trade-disabled matches can still win.")
}

if ($source -notmatch 'GetSymbolDecorationPenalty\s*\(') {
    $failures.Add("Candidate ranking does not include a decoration penalty, so dotted aliases like XAUUSD.crp can outrank cleaner matches such as XAUUSD+ or XAUUSD.")
}

if ($failures.Count -gt 0) {
    Write-Host "Symbol auto-resolution regression check failed:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Symbol auto-resolution regression check passed." -ForegroundColor Green
