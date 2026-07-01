# Clean Desktop Audible

A tiny Windows **system-tray audiobook widget**: your current book's HD cover as a
frameless, resizable, auto-hiding, always-on-top card with transport controls, a
**chapter-scoped scrubber**, ±30s skip, chapter prev/next, and a **library
cover-wall**. Pure PowerShell + WPF — no compiled binary, nothing to sign.

![screenshot](docs/screenshot.png)

It doesn't play audio or touch DRM. It **mirrors and controls whatever media
session Windows is playing** — Audible in a browser, the Audible app, Spotify,
anything — through the Windows **System Media Transport Controls (SMTC)** API,
exactly like your keyboard's media keys. It optionally enriches the display with
**HD cover art and exact chapter timings** pulled from *your own* Audible account.

> **Disclaimer.** Personal-use tool. The optional enrichment uses
> [`audible-cli`](https://github.com/mkb79/audible-cli) — an unofficial, community
> Audible API client — to read cover/chapter data from **your own** account. It does
> **not** download or decrypt audiobooks. No cover images or library data are included
> in this repo. Not affiliated with, endorsed by, or connected to Audible or Amazon.
> Use at your own risk and in accordance with Audible's Terms.

## Features
- Full-bleed HD cover, faint auto-hiding controls (fade to pure cover when idle)
- Chapter-scoped scrubber (seek within the current chapter) with drag-to-seek
- ±30s skip, chapter previous/next (exact boundary jumps when chapter data is present)
- Library cover-wall of your books
- Resizable (stays square), remembers its position + size
- Lives in the system tray; runs at login; controls anything via SMTC

## Requirements
- Windows 10/11, Windows PowerShell 5.1 (built in)
- (Optional, for HD covers + chapters) Python 3 + [`audible-cli`](https://github.com/mkb79/audible-cli)

## Setup
1. **Run it** (works immediately, using the low-res OS thumbnail + whole-book scrubber):
   ```powershell
   powershell -STA -ExecutionPolicy Bypass -File .\AudibleRemote.ps1
   ```
   or double-click `AudibleRemote.vbs` (launches with no console window).

2. **(Optional) HD covers + per-chapter scrubbing.** Install and authenticate `audible-cli`
   into a local venv, then build the cache:
   ```powershell
   py -m venv .venv
   .\.venv\Scripts\python -m pip install audible-cli
   .\.venv\Scripts\audible quickstart      # one-time: sign in to your Audible account
   powershell -ExecutionPolicy Bypass -File .\sync.ps1   # downloads HD covers + chapter data
   ```
   `sync.ps1` is incremental (only fetches new books) and the app re-runs it automatically
   at launch and every 12h. It writes `covers.json`, `chapters.json`, and `Covers\` — all
   git-ignored (your data stays local).

## Controls
| Control | Action |
|---|---|
| Scrubber | Drag/click to seek (within the chapter, or whole book) |
| ⟲30 / 30⟳ | Back / forward 30 seconds |
| ⏯ | Play / pause |
| ⏮ / ⏭ | Previous / next chapter |
| Drag the cover | Move the window |
| Corner grip | Resize (stays square) |
| Tray icon | Left-click: show/hide · Right-click: Show/hide, Exit |
| ✕ | Hide to tray (quit from the tray menu) |

## Why PowerShell?
Windows **Smart App Control** blocks locally-compiled, unsigned `.exe`/`.dll` files.
This is written in pure PowerShell + WPF using only Microsoft-signed assemblies, so it
runs with no build step and nothing to sign. A reference C#/WPF port lives in `dotnet/`
(builds, but won't run under enforcing SAC without a code-signing cert).

## Utilities
- `sync.ps1` — incremental cover + chapter cache (supersedes `scan-covers`/`scan-chapters`)
- `gen-icon.ps1` — regenerates the multi-size `app.ico`

## License
MIT — see [LICENSE](LICENSE).
