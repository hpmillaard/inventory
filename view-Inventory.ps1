$jsFile = Join-Path $PSScriptRoot 'inventory_merged.js'
$files = gci $PSScriptRoot -Filter '*.json' -File -EA 0 | ? { $_.Name -notmatch '^inventory_merged' }
$arr = @()
foreach ($f in $files) {
    try {
        $converted = Get-Content -Path $f.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($converted) { $arr += $converted }
    }
    catch { }
}
if ($arr.Count -eq 0) { $arr = @() }
$json = $arr | ConvertTo-Json -Depth 6 -Compress
$js = "window.INVENTORY_MERGED = $json;"
Set-Content -Path $jsFile -Value $js -Encoding UTF8 -Force

$html = Join-Path $PSScriptRoot 'index.html'
if (Test-Path $html) { Start-Process $html -EA 0 } else { Write-Warning 'index.html niet gevonden in share' }