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

if ($source -notmatch 'BuildEntityComment\s*\(') {
    $failures.Add("Missing BuildEntityComment helper.")
}

if ($source -notmatch 't\.me/fx_bot_master') {
    $failures.Add("New copied-trade comments are not branded with the full Telegram URL label.")
}

if ($source -notmatch 'ParseCopiedCommentForChannel\s*\(') {
    $failures.Add("Missing a dedicated copied-comment parser for channel-aware matching.")
}

if ($source -notmatch 'TC\|') {
    $failures.Add("Legacy TC comment parsing support appears to be missing.")
}

if ($source -match 'PositionGetString\(POSITION_COMMENT\)\s*!=\s*comment') {
    $failures.Add("Slave position matching still relies on exact full comment equality.")
}

if ($source -match 'OrderGetString\(ORDER_COMMENT\)\s*!=\s*comment') {
    $failures.Add("Slave pending-order matching still relies on exact full comment equality.")
}

if ($source -notmatch 'EncodeTicketToken\s*\(') {
    $failures.Add("Missing compact ticket-token encoding for cleaner visible comments.")
}

if ($failures.Count -gt 0) {
    Write-Host "Comment format regression check failed:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Comment format regression check passed." -ForegroundColor Green
