#Requires -Version 5.1
<#
    scan-library.ps1 — cache high-res (1215px) cover art for the whole library.
    Writes covers.json (title -> local cover file) and Covers\{asin}.jpg.
    The remote uses these instead of the tiny 150px SMTC thumbnail.

    Prereq: audible-cli authenticated (audible quickstart). Re-run to refresh.
#>
param(
    [string]$Audible  = (Join-Path $PSScriptRoot '.venv\Scripts\audible.exe'),
    [string]$Out      = (Join-Path $PSScriptRoot 'covers.json'),
    [string]$CoverDir = (Join-Path $PSScriptRoot 'Covers')
)
if (-not (Test-Path $Audible)) { throw "audible-cli not found at $Audible" }
New-Item -ItemType Directory -Force -Path $CoverDir | Out-Null

Write-Host "Fetching library..." -ForegroundColor Cyan
$lib = & $Audible api "1.0/library" -p "num_results=1000" -p "response_groups=product_desc,media" -p "image_sizes=1215,500" | ConvertFrom-Json
$items = @($lib.items)
$map = [ordered]@{}
$n = $items.Count; $i = 0
foreach ($it in $items) {
    $i++
    $asin = $it.asin; $title = $it.title
    if (-not $asin -or -not $title) { continue }
    $imgs = $it.product_images
    $url = $null
    if ($imgs) { if ($imgs.'1215') { $url = $imgs.'1215' } elseif ($imgs.'500') { $url = $imgs.'500' } }
    if (-not $url) { Write-Warning "no image: $title"; continue }
    $dst = Join-Path $CoverDir "$asin.jpg"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 30
        $map[$title] = $dst
        Write-Host ("[{0}/{1}] {2}" -f $i, $n, $title)
    } catch { Write-Warning "  download failed: $title ($($_.Exception.Message))" }
}
$map | ConvertTo-Json | Set-Content -Path $Out -Encoding UTF8
Write-Host ("Wrote {0} covers to {1}" -f $map.Count, $Out) -ForegroundColor Green
