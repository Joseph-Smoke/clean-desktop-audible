#Requires -Version 5.1
<#
    scan-chapters.ps1 — build the chapter cache the remote uses for its
    chapter-scoped scrubber.

    Prerequisite (one time): authenticate audible-cli to your Audible account:

        C:\dev\audible-remote\.venv\Scripts\audible.exe quickstart

    Then run this script. It exports your library, pulls exact chapter data
    (title + start_offset_ms + length_ms) for each book from the Audible API,
    and writes chapters.json next to the app. Re-run any time to pick up new
    books. No browser, no scraping.
#>
param(
    [string]$Audible = (Join-Path $PSScriptRoot '.venv\Scripts\audible.exe'),
    [string]$Out     = (Join-Path $PSScriptRoot 'chapters.json')
)

if (-not (Test-Path $Audible)) { throw "audible-cli not found at $Audible" }

function Flatten-Chapters($chapters) {
    # Audible sometimes nests chapters under "Part" groupings; take the leaves.
    $out = @()
    foreach ($c in $chapters) {
        if ($c.chapters -and $c.chapters.Count -gt 0) { $out += Flatten-Chapters $c.chapters }
        else { $out += $c }
    }
    $out
}

$libFile = Join-Path $env:TEMP 'ar-library.json'
Write-Host "Exporting library..." -ForegroundColor Cyan
& $Audible library export -f json -o $libFile --timeout 60
if (-not (Test-Path $libFile)) { throw "library export failed" }
$lib = Get-Content -Raw $libFile | ConvertFrom-Json

$cache = [ordered]@{}
$n = @($lib).Count
$i = 0
foreach ($item in $lib) {
    $i++
    $asin  = $item.asin
    $title = $item.title
    if (-not $asin -or -not $title) { continue }
    Write-Host ("[{0}/{1}] {2}" -f $i, $n, $title)
    try {
        $json = & $Audible api "1.0/content/$asin/metadata" -p "response_groups=chapter_info" 2>$null
        $md   = $json | ConvertFrom-Json
        $ci   = $md.content_metadata.chapter_info
        if ($ci -and $ci.chapters) {
            $flat = Flatten-Chapters $ci.chapters | Sort-Object { [int64]$_.start_offset_ms }
            $chs  = foreach ($c in $flat) {
                [ordered]@{
                    title     = "$($c.title)"
                    start_ms  = [int64]$c.start_offset_ms
                    length_ms = [int64]$c.length_ms
                }
            }
            $cache[$title] = [ordered]@{
                asin     = $asin
                title    = $title
                total_ms = [int64]$ci.runtime_length_ms
                chapters = @($chs)
            }
        }
        else { Write-Warning "  no chapter_info for $title" }
    }
    catch { Write-Warning "  failed for $title ($asin): $($_.Exception.Message)" }
}

$cache | ConvertTo-Json -Depth 8 | Set-Content -Path $Out -Encoding UTF8
Write-Host ("Wrote {0} books to {1}" -f $cache.Count, $Out) -ForegroundColor Green
