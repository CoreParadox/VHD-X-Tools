$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgFile = Join-Path $scriptDir 'winget-packages.txt'

if (-not (Test-Path $pkgFile)) {
    Write-Host "winget package list not found at $pkgFile" -ForegroundColor Yellow
    exit 0
}

$lines = Get-Content $pkgFile | Where-Object {
    $_ -and -not $_.Trim().StartsWith('#')
}

foreach ($line in $lines) {
    Write-Host "Installing via winget: $line" -ForegroundColor Cyan
    winget install --silent --accept-source-agreements --accept-package-agreements $line
}
