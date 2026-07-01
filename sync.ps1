#Requires -Version 5.1
<#
    sync.ps1 — incremental cache updater for Audible Remote.

    Pulls your Audible library and, for any book NOT already cached, downloads
    the HD (1215px) cover and fetches exact chapter data. Books already cached
    are skipped, so the first run does everything and later runs only touch new
    purchases (fast). Safe to run on a schedule.

    Writes:  covers.json (title -> cover file), Covers\{asin}.jpg,
             chapters.json (title -> {asin,total_ms,chapters})
    Prereq:  audible-cli authenticated (audible quickstart).
#>
param(
    [string]$Audible      = (Join-Path $PSScriptRoot '.venv\Scripts\audible.exe'),
    [string]$CoversJson   = (Join-Path $PSScriptRoot 'covers.json'),
    [string]$ChaptersJson = (Join-Path $PSScriptRoot 'chapters.json'),
    [string]$CoverDir     = (Join-Path $PSScriptRoot 'Covers')
)
if (-not (Test-Path $Audible)) { throw "audible-cli not found at $Audible" }
New-Item -ItemType Directory -Force -Path $CoverDir | Out-Null

# single-instance: if another sync is already running, no-op (prevents overlapping writers)
$mtx = New-Object System.Threading.Mutex($false, 'Local\AudibleRemoteSync')
$acquired = $false
try { $acquired = $mtx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Write-Host 'sync already running; skipping.'; return }

function Load-Map($path) {
    $m = [ordered]@{}
    if (Test-Path $path) {
        try { (Get-Content -Raw $path | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $m[$_.Name] = $_.Value } } catch {}
    }
    return $m
}
function Flatten-Chapters($chapters) {
    $out = @()
    foreach ($c in $chapters) {
        if ($c.chapters -and @($c.chapters).Count -gt 0) { $out += Flatten-Chapters @($c.chapters) } else { $out += $c }
    }
    $out
}

$covers   = Load-Map $CoversJson
$chapters = Load-Map $ChaptersJson

Write-Host "Fetching library..." -ForegroundColor Cyan
$lib = & $Audible api "1.0/library" -p "num_results=1000" -p "response_groups=product_desc,media" -p "image_sizes=1215,500" | ConvertFrom-Json
$items = @($lib.items)
$newCovers = 0; $newChapters = 0; $i = 0; $n = $items.Count

foreach ($it in $items) {
    $i++
    $asin = $it.asin; $title = $it.title
    if (-not $asin -or -not $title) { continue }

    # --- cover (skip if cached + file present) ---
    $coverFile = Join-Path $CoverDir "$asin.jpg"
    if (-not $covers.Contains($title) -or -not (Test-Path $coverFile)) {
        $imgs = $it.product_images; $url = $null
        if ($imgs) { if ($imgs.'1215') { $url = $imgs.'1215' } elseif ($imgs.'500') { $url = $imgs.'500' } }
        if ($url) {
            try { Invoke-WebRequest -Uri $url -OutFile $coverFile -UseBasicParsing -TimeoutSec 30; $covers[$title] = $coverFile; $newCovers++ }
            catch { Write-Warning "cover failed: $title" }
        }
    }

    # --- chapters (skip if cached) ---
    if (-not $chapters.Contains($title)) {
        try {
            $md = & $Audible api "1.0/content/$asin/metadata" -p "response_groups=chapter_info" 2>$null | ConvertFrom-Json
            $ci = $md.content_metadata.chapter_info
            if ($ci -and $ci.chapters) {
                $flat = Flatten-Chapters $ci.chapters | Sort-Object { [int64]$_.start_offset_ms }
                $chs = foreach ($c in $flat) { [ordered]@{ title = "$($c.title)"; start_ms = [int64]$c.start_offset_ms; length_ms = [int64]$c.length_ms } }
                $chapters[$title] = [ordered]@{ asin = $asin; title = $title; total_ms = [int64]$ci.runtime_length_ms; chapters = @($chs) }
                $newChapters++
                Write-Host ("[{0}/{1}] chapters: {2}" -f $i, $n, $title)
            }
        } catch { Write-Warning "chapters failed: $title" }
    }
}

# atomic writes: temp file then rename, so a reader never sees a half-written file
$tmpC = "$CoversJson.tmp";   $covers   | ConvertTo-Json -Depth 8 | Set-Content -Path $tmpC -Encoding UTF8; Move-Item -Force -LiteralPath $tmpC -Destination $CoversJson
$tmpH = "$ChaptersJson.tmp"; $chapters | ConvertTo-Json -Depth 8 | Set-Content -Path $tmpH -Encoding UTF8; Move-Item -Force -LiteralPath $tmpH -Destination $ChaptersJson
Write-Host ("Done. {0} books. +{1} new covers, +{2} new chapter sets." -f $n, $newCovers, $newChapters) -ForegroundColor Green
$mtx.ReleaseMutex(); $mtx.Dispose()
