#Requires -Version 5.1
<#
    Audible Remote — full-bleed HD book cover with faint, auto-hiding controls.

    Does NOT play audio or touch DRM. Mirrors/controls whatever media session
    Windows considers active (Audible in a browser, the app, etc.) via System
    Media Transport Controls (SMTC) — like the media keys. Pure PowerShell + WPF
    (Microsoft-signed) so Smart App Control can't block it. Always on top.

    Square window (Audible covers are square). Drag the corner grip to resize —
    everything scales. Controls fade to pure cover when idle. Library button
    opens a cover-wall of the whole library (covers cached by scan-library.ps1).
    Scrubber scopes to the current chapter when chapters.json exists.

    Run:      powershell -STA -ExecutionPolicy Bypass -File AudibleRemote.ps1
    Snapshot: ...same... -Snapshot C:\path\out.png
#>
param([string]$Snapshot)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Give the process its own taskbar identity + let us push the real icon onto the
# window handle, so the taskbar shows our icon instead of the PowerShell host icon.
try {
    Add-Type -Namespace Native -Name U -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr LoadImage(System.IntPtr h, string name, uint type, int cx, int cy, uint fuLoad);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
'@
    [void][Native.U]::SetCurrentProcessExplicitAppUserModelID('SmokeDesigns.AudibleRemote')
} catch {}

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
function Await($op, $resultType) {
    $m = $asTaskGeneric.MakeGenericMethod($resultType)
    $t = $m.Invoke($null, @($op)); [void]$t.Wait(-1); $t.Result
}

[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]

$script:AsStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsStreamForRead' -and $_.GetParameters().Count -eq 1
    } | Select-Object -First 1

$mgrType    = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$script:Mgr = Await ($mgrType::RequestAsync()) ($mgrType)

$script:GlyphPlay  = [char]0xE768
$script:GlyphPause = [char]0xE769

# ---- caches ------------------------------------------------------------------
$script:ChapterCache = @{}
$cachePath = Join-Path $PSScriptRoot 'chapters.json'
if (Test-Path $cachePath) {
    try {
        $raw = Get-Content -Raw $cachePath | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { if ($prop.Value.title) { $script:ChapterCache[("$($prop.Value.title)").Trim().ToLowerInvariant()] = $prop.Value } }
    } catch {}
}
$script:CoverCache = @{}
$coversPath = Join-Path $PSScriptRoot 'covers.json'
if (Test-Path $coversPath) {
    try {
        $raw = Get-Content -Raw $coversPath | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $script:CoverCache[$p.Name.Trim().ToLowerInvariant()] = $p.Value }
    } catch {}
}
$winStatePath = Join-Path $PSScriptRoot 'window.json'

# ---- UI ----------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Audible Remote" Width="380" Height="380"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="100"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="#2EFFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bg" Property="Background" Value="#4DFFFFFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Scrubber" TargetType="Slider">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Minimum" Value="0"/><Setter Property="Height" Value="18"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
              <Border Height="5" CornerRadius="2.5" Background="#26FFFFFF"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="5" CornerRadius="2.5" Background="#D4FFFFFF"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Width="12" Height="12"><Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Width="12" Height="12" Fill="#F2FFFFFF"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" Height="0"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#3DFFFFFF" Margin="2,0"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" Height="0"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Viewbox Stretch="Uniform">
      <Border Width="380" Height="380" CornerRadius="14" ClipToBounds="True" Background="#0A0A0C">
        <Grid>
          <Rectangle x:Name="CoverRect"><Rectangle.Fill><ImageBrush Stretch="UniformToFill"/></Rectangle.Fill></Rectangle>

          <Grid x:Name="Overlay">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="14,10,0,0">
              <Button x:Name="BtnLibrary" Style="{StaticResource IconBtn}" Padding="6,4">
                <StackPanel Orientation="Horizontal">
                  <Grid Width="14" Height="14" VerticalAlignment="Center">
                    <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <Rectangle Grid.Row="0" Grid.Column="0" Fill="White" RadiusX="1.5" RadiusY="1.5" Margin="0,0,2,2"/>
                    <Rectangle Grid.Row="0" Grid.Column="1" Fill="White" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,2"/>
                    <Rectangle Grid.Row="1" Grid.Column="0" Fill="White" RadiusX="1.5" RadiusY="1.5" Margin="0,2,2,0"/>
                    <Rectangle Grid.Row="1" Grid.Column="1" Fill="White" RadiusX="1.5" RadiusY="1.5" Margin="2,2,0,0"/>
                    <Grid.Effect><DropShadowEffect Color="#000000" BlurRadius="5" ShadowDepth="0" Opacity="0.9"/></Grid.Effect>
                  </Grid>
                  <TextBlock Text="Library" Foreground="White" FontSize="12.5" FontFamily="Segoe UI" Margin="8,0,0,0" VerticalAlignment="Center">
                    <TextBlock.Effect><DropShadowEffect Color="#000000" BlurRadius="5" ShadowDepth="0" Opacity="0.9"/></TextBlock.Effect></TextBlock>
                </StackPanel>
              </Button>
            </StackPanel>
            <Button x:Name="BtnClose" Style="{StaticResource IconBtn}" Width="28" Height="28" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,8,0">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8BB;" FontSize="12" Foreground="White">
                <TextBlock.Effect><DropShadowEffect Color="#000000" BlurRadius="5" ShadowDepth="0" Opacity="0.9"/></TextBlock.Effect></TextBlock>
            </Button>

            <StackPanel VerticalAlignment="Bottom" Margin="20,0,20,18">
              <StackPanel.Effect><DropShadowEffect Color="#000000" BlurRadius="5" ShadowDepth="0" Opacity="0.55"/></StackPanel.Effect>
              <TextBlock x:Name="TitleText" Text="Audible Remote" Foreground="White" FontFamily="Segoe UI" FontSize="20" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="ChapterText" Text="Nothing playing" Foreground="#D0FFFFFF" FontFamily="Segoe UI" FontSize="12.5" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
              <Grid Margin="0,13,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="ElapsedText" Grid.Column="0" Text="0:00" Foreground="#EAFFFFFF" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <Slider x:Name="Scrub" Grid.Column="1" Style="{StaticResource Scrubber}" VerticalAlignment="Center"/>
                <TextBlock x:Name="TotalText" Grid.Column="2" Text="0:00" Foreground="#EAFFFFFF" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0"/>
              </Grid>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,15,0,0">
                <Button x:Name="BtnPrev" Style="{StaticResource IconBtn}" Width="44" Height="44" ToolTip="Previous chapter" Margin="0,0,10,0"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE892;" FontSize="19" Foreground="#D4FFFFFF"/></Button>
                <Button x:Name="BtnBack30" Style="{StaticResource IconBtn}" Width="50" Height="50" ToolTip="Back 30 seconds" Margin="0,0,6,0"><Path Stroke="#D4FFFFFF" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Data="M11,3 L5,10 L11,17 M18,3 L12,10 L18,17"/></Button>
                <Button x:Name="BtnPlay" Style="{StaticResource IconBtn}" Width="62" Height="62" ToolTip="Play / Pause"><TextBlock x:Name="PlayPauseGlyph" FontFamily="Segoe MDL2 Assets" Text="&#xE768;" FontSize="34" Foreground="#E6FFFFFF"/></Button>
                <Button x:Name="BtnFwd30" Style="{StaticResource IconBtn}" Width="50" Height="50" ToolTip="Forward 30 seconds" Margin="6,0,0,0"><Path Stroke="#D4FFFFFF" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Data="M7,3 L13,10 L7,17 M0,3 L6,10 L0,17"/></Button>
                <Button x:Name="BtnNext" Style="{StaticResource IconBtn}" Width="44" Height="44" ToolTip="Next chapter" Margin="10,0,0,0"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE893;" FontSize="19" Foreground="#D4FFFFFF"/></Button>
              </StackPanel>
            </StackPanel>
          </Grid>

          <Grid x:Name="LibraryView" Visibility="Collapsed" Background="#F20A0A0C">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="16,12,10,8">
              <TextBlock Text="Library" Foreground="White" FontFamily="Segoe UI" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <Button x:Name="BtnLibClose" Style="{StaticResource IconBtn}" Width="28" Height="28" HorizontalAlignment="Right"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8BB;" FontSize="12" Foreground="White"/></Button>
            </Grid>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="12,0,12,12">
              <WrapPanel x:Name="LibGrid"/>
            </ScrollViewer>
          </Grid>
        </Grid>
      </Border>
    </Viewbox>

    <Thumb x:Name="ResizeGrip" Width="24" Height="24" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE" Opacity="0.55">
      <Thumb.Template><ControlTemplate TargetType="Thumb">
        <Grid Background="#01000000"><Path Stroke="White" StrokeThickness="1.6" Data="M21,9 L9,21 M21,15 L15,21" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,3,3"/></Grid>
      </ControlTemplate></Thumb.Template>
    </Thumb>
  </Grid>
</Window>
'@

$window      = [Windows.Markup.XamlReader]::Parse($xaml)
$CoverRect   = $window.FindName('CoverRect')
$Overlay     = $window.FindName('Overlay')
$TitleText   = $window.FindName('TitleText')
$ChapterText = $window.FindName('ChapterText')
$PlayGlyph   = $window.FindName('PlayPauseGlyph')
$Scrub       = $window.FindName('Scrub')
$ElapsedText = $window.FindName('ElapsedText')
$TotalText   = $window.FindName('TotalText')
$BtnPrev     = $window.FindName('BtnPrev')
$BtnBack30   = $window.FindName('BtnBack30')
$BtnPlay     = $window.FindName('BtnPlay')
$BtnFwd30    = $window.FindName('BtnFwd30')
$BtnNext     = $window.FindName('BtnNext')
$BtnClose    = $window.FindName('BtnClose')
$BtnLibrary  = $window.FindName('BtnLibrary')
$BtnLibClose = $window.FindName('BtnLibClose')
$LibraryView = $window.FindName('LibraryView')
$LibGrid     = $window.FindName('LibGrid')
$ResizeGrip  = $window.FindName('ResizeGrip')
try {
    $ib = New-Object System.Windows.Media.Imaging.BitmapImage
    $ib.BeginInit(); $ib.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $ib.UriSource = New-Object System.Uri((Join-Path $PSScriptRoot 'app.ico')); $ib.EndInit(); $ib.Freeze()
    $window.Icon = $ib   # OnLoad = read fully then release, so it doesn't lock app.ico
} catch {}
# push the real 16/32px icon frames onto the window handle for a crisp taskbar icon
$window.Add_SourceInitialized({
        try {
            $ico = Join-Path $PSScriptRoot 'app.ico'
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
            $big = [Native.U]::LoadImage([IntPtr]::Zero, $ico, 1, 32, 32, 0x10)    # IMAGE_ICON, LR_LOADFROMFILE
            $small = [Native.U]::LoadImage([IntPtr]::Zero, $ico, 1, 16, 16, 0x10)
            if ($big -ne [IntPtr]::Zero) { [void][Native.U]::SendMessage($hwnd, 0x80, [IntPtr]1, $big) }    # WM_SETICON ICON_BIG
            if ($small -ne [IntPtr]::Zero) { [void][Native.U]::SendMessage($hwnd, 0x80, [IntPtr]0, $small) } # WM_SETICON ICON_SMALL
        } catch {}
    })

$script:LastTitle = [object]::new()
$script:Scrubbing = $false
$script:BasePos = 0.0; $script:BaseAt = [DateTimeOffset]::Now
$script:LastRaw = [double]::NaN; $script:LastUpd = [DateTimeOffset]::MinValue
$script:SeekGraceUntil = [DateTimeOffset]::MinValue
$script:ChapMode = $false; $script:ChapStart = 0.0; $script:CurChapters = $null; $script:CurChapIdx = 0
$script:LibBuilt = $false

function Get-Session { try { return $script:Mgr.GetCurrentSession() } catch { return $null } }
function Set-Anchor([double]$pos) { $script:BasePos = $pos; $script:BaseAt = [DateTimeOffset]::Now }

function Format-Time([double]$sec) {
    if ([double]::IsNaN($sec) -or [double]::IsInfinity($sec) -or $sec -gt 359999) { return '--:--' }
    if ($sec -lt 0) { $sec = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Floor($sec)); $h = $ts.Days * 24 + $ts.Hours
    if ($h -ge 1) { '{0}:{1:00}:{2:00}' -f $h, $ts.Minutes, $ts.Seconds } else { '{0}:{1:00}' -f $ts.Minutes, $ts.Seconds }
}

function Get-LivePosition($s) {
    try {
        $t = $s.GetTimelineProperties(); $total = $t.EndTime.TotalSeconds; $raw = $t.Position.TotalSeconds; $upd = $t.LastUpdatedTime
        $playing = ("$($s.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing')
        if (([DateTimeOffset]::Now -gt $script:SeekGraceUntil) -and ($raw -ne $script:LastRaw -or $upd -ne $script:LastUpd)) { $script:LastRaw = $raw; $script:LastUpd = $upd; Set-Anchor $raw }
        # sanitize: live streams / malformed sessions report NaN/Infinity/huge EndTime
        if ([double]::IsNaN($total) -or [double]::IsInfinity($total) -or $total -gt 359999) { $total = 0 }
        $pos = $script:BasePos; if ($playing) { $pos += ([DateTimeOffset]::Now - $script:BaseAt).TotalSeconds }
        if ([double]::IsNaN($pos) -or [double]::IsInfinity($pos)) { $pos = 0 }
        if ($total -gt 0 -and $pos -gt $total) { $pos = $total }; if ($pos -lt 0) { $pos = 0 }
        return @{ Pos = $pos; Total = $total }
    } catch { return @{ Pos = 0; Total = 0 } }
}

function Get-CachedBook([string]$title, [double]$totalSec) {
    if (-not $title) { return $null }
    $key = $title.Trim().ToLowerInvariant()
    if (-not $script:ChapterCache.ContainsKey($key)) { return $null }
    $e = $script:ChapterCache[$key]
    if (-not $e.chapters -or @($e.chapters).Count -eq 0) { return $null }
    if ($totalSec -gt 0 -and $e.total_ms -gt 0 -and [math]::Abs($e.total_ms / 1000.0 - $totalSec) -gt 90) { return $null }
    return $e
}

function Find-ChapterIndex($chapters, [double]$posMs) {
    $idx = 0; for ($i = 0; $i -lt $chapters.Count; $i++) { if ($posMs -ge [double]$chapters[$i].start_ms) { $idx = $i } else { break } }; return $idx
}

function Get-CoverPath([string]$title) {
    if (-not $title) { return $null }
    $k = $title.Trim().ToLowerInvariant()
    if ($script:CoverCache.ContainsKey($k)) { $p = $script:CoverCache[$k]; if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Set-Cover([byte[]]$bytes) {
    try {
        if (-not $bytes -or $bytes.Length -eq 0) { $CoverRect.Fill.ImageSource = $null; return }
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = New-Object System.IO.MemoryStream (, $bytes); $bmp.EndInit(); $bmp.Freeze()
        $CoverRect.Fill.ImageSource = $bmp
    } catch { $CoverRect.Fill.ImageSource = $null }
}

function Read-Thumb($thumbRef) {
    try {
        if (-not $thumbRef) { return $null }
        $ras = Await ($thumbRef.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType]); if (-not $ras) { return $null }
        $stream = $script:AsStreamForRead.Invoke($null, @($ras)); if (-not $stream) { return $null }
        $ms = New-Object System.IO.MemoryStream; $stream.CopyTo($ms); $stream.Dispose(); return $ms.ToArray()
    } catch { return $null }
}

function Set-SeekControls([bool]$enabled) {
    $Scrub.IsEnabled = $enabled; $BtnBack30.IsEnabled = $enabled; $BtnFwd30.IsEnabled = $enabled
    if (-not $enabled) { $ElapsedText.Text = '--:--'; $TotalText.Text = '--:--' }
}

function Update-Player {
  try {
    $s = Get-Session
    if (-not $s) {
        $TitleText.Text = 'Nothing playing'; $ChapterText.Text = 'Start an audiobook to see it here'
        $PlayGlyph.Text = $script:GlyphPlay; $CoverRect.Fill.ImageSource = $null
        $script:LastTitle = $null; $script:ChapMode = $false; Set-SeekControls $false; return
    }
    try { if ("$($s.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing') { $PlayGlyph.Text = $script:GlyphPause } else { $PlayGlyph.Text = $script:GlyphPlay } } catch {}
    $title = '(unknown title)'
    try {
        $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        $title = if ([string]::IsNullOrWhiteSpace($props.Title)) { '(unknown title)' } else { $props.Title }
        $chapter = if ($props.Artist) { $props.Artist } elseif ($props.AlbumTitle) { $props.AlbumTitle } else { '' }
        $TitleText.Text = $title; $ChapterText.Text = $chapter
        if ($title -ne $script:LastTitle) {
            $script:LastTitle = $title
            $hd = Get-CoverPath $title
            if ($hd) { try { Set-Cover ([System.IO.File]::ReadAllBytes($hd)) } catch { Set-Cover (Read-Thumb $props.Thumbnail) } } else { Set-Cover (Read-Thumb $props.Thumbnail) }
        }
    } catch {}
    $tl = Get-LivePosition $s
    if ($tl.Total -le 0) { Set-SeekControls $false; $script:ChapMode = $false; return }
    Set-SeekControls $true
    # freeze chapter state + slider entirely while the user drags, so the elapsed
    # readout can't jump when playback crosses a chapter boundary mid-drag
    if (-not $script:Scrubbing) {
        $book = Get-CachedBook $title $tl.Total
        if ($book) {
            $chs = @($book.chapters); $idx = Find-ChapterIndex $chs ($tl.Pos * 1000.0); $ch = $chs[$idx]
            $cs = [double]$ch.start_ms / 1000.0; $ce = ([double]$ch.start_ms + [double]$ch.length_ms) / 1000.0; if ($ce -le $cs) { $ce = $cs + 1 }
            $script:ChapMode = $true; $script:ChapStart = $cs; $script:CurChapters = $chs; $script:CurChapIdx = $idx
            $label = if ($ch.title) { "$($ch.title)" } else { "Chapter $($idx + 1)" }
            $dot = [char]0x00B7
            $ChapterText.Text = "{0}  $dot  {1} of {2}" -f $label, ($idx + 1), $chs.Count
            $TotalText.Text = Format-Time ($ce - $cs)
            $Scrub.Minimum = 0; $Scrub.Maximum = [math]::Max($ce, 1); $Scrub.Minimum = $cs
            $v = $tl.Pos; if ($v -lt $cs) { $v = $cs }; if ($v -gt $ce) { $v = $ce }; $Scrub.Value = $v
        }
        else {
            $script:ChapMode = $false; $TotalText.Text = Format-Time $tl.Total
            $Scrub.Minimum = 0; $Scrub.Maximum = $tl.Total; $Scrub.Value = [math]::Min($tl.Pos, $tl.Total)
        }
    }
  }
  catch {}
}

function Seek-To([double]$sec) {
    $s = Get-Session; if (-not $s) { return }
    try { if ($sec -lt 0) { $sec = 0 }
        [void](Await ($s.TryChangePlaybackPositionAsync([long]([TimeSpan]::FromSeconds($sec).Ticks))) ([bool]))
        Set-Anchor $sec; $script:SeekGraceUntil = [DateTimeOffset]::Now.AddSeconds(2)
    } catch {}
}

function Skip-Seconds([double]$delta) {
    $s = Get-Session; if (-not $s) { return }
    $tl = Get-LivePosition $s; $new = $tl.Pos + $delta; if ($new -lt 0) { $new = 0 }; if ($tl.Total -gt 0 -and $new -gt $tl.Total) { $new = $tl.Total }
    Seek-To $new; Update-Player
}

function Chapter-Nav([string]$dir) {
    if (-not $script:ChapMode -or -not $script:CurChapters) { Send-Transport $dir; return }
    $chs = @($script:CurChapters); $idx = $script:CurChapIdx
    if ($dir -eq 'next') { if ($idx -lt $chs.Count - 1) { Seek-To ([double]$chs[$idx + 1].start_ms / 1000.0) } else { Send-Transport 'next'; return } }
    else { $curStart = [double]$chs[$idx].start_ms / 1000.0; $tl = Get-LivePosition (Get-Session)
        if ($idx -eq 0 -or ($tl.Pos - $curStart) -gt 3) { Seek-To $curStart } else { Seek-To ([double]$chs[$idx - 1].start_ms / 1000.0) } }
    Update-Player
}

function Send-Transport([string]$cmd) {
    $s = Get-Session; if (-not $s) { return }
    try { switch ($cmd) {
        'play' { [void](Await ($s.TryTogglePlayPauseAsync()) ([bool])) }
        'next' { [void](Await ($s.TrySkipNextAsync()) ([bool])) }
        'prev' { [void](Await ($s.TrySkipPreviousAsync()) ([bool])) }
    } } catch {}
    Update-Player
}

# ---- auto-hide ---------------------------------------------------------------
$script:IdleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:IdleTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:IdleTimer.Add_Tick({ $script:IdleTimer.Stop(); if (-not $script:Scrubbing -and $LibraryView.Visibility -ne 'Visible') { Hide-Overlay } })
function Show-Overlay {
    $Overlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $Overlay.Opacity = 1
    $script:IdleTimer.Stop(); $script:IdleTimer.Start()
}
function Hide-Overlay {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To = 0.0; $anim.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(450))
    $Overlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
}

# ---- library grid ------------------------------------------------------------
function Populate-Library {
    if ($script:LibBuilt) { return }
    if (-not (Test-Path $coversPath)) { return }
    try { $cov = Get-Content -Raw $coversPath | ConvertFrom-Json } catch { return }  # partial read: don't consume the guard, retry next open
    $script:LibBuilt = $true   # parse OK: commit so we don't build twice
    $mutedBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xD0, 0xFF, 0xFF, 0xFF))
    foreach ($p in $cov.PSObject.Properties) {
        $title = $p.Name; $path = $p.Value
        if (-not $path -or -not (Test-Path $path)) { continue }
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = New-Object System.Uri($path); $bmp.DecodePixelWidth = 110; $bmp.CacheOption = 'OnLoad'; $bmp.EndInit(); $bmp.Freeze()
        } catch { continue }
        $cover = New-Object System.Windows.Controls.Border
        $cover.Width = 88; $cover.Height = 88; $cover.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $ib = New-Object System.Windows.Media.ImageBrush($bmp); $ib.Stretch = [System.Windows.Media.Stretch]::UniformToFill; $cover.Background = $ib
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $title; $txt.FontSize = 10; $txt.FontFamily = 'Segoe UI'; $txt.Foreground = $mutedBrush
        $txt.TextWrapping = [System.Windows.TextWrapping]::Wrap; $txt.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $txt.MaxWidth = 88; $txt.MaxHeight = 28; $txt.TextAlignment = [System.Windows.TextAlignment]::Center
        $txt.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
        $tile = New-Object System.Windows.Controls.StackPanel
        $tile.Width = 96; $tile.Margin = New-Object System.Windows.Thickness(5); $tile.Cursor = [System.Windows.Input.Cursors]::Hand
        $tile.Tag = [System.IO.Path]::GetFileNameWithoutExtension($path)
        [void]$tile.Children.Add($cover); [void]$tile.Children.Add($txt)
        $tile.Add_MouseLeftButtonUp({ param($s, $e) try { Start-Process "https://www.audible.com/webplayer?asin=$($s.Tag)" } catch {}; $LibraryView.Visibility = 'Collapsed' })
        [void]$LibGrid.Children.Add($tile)
    }
}

# ---- self-updating cache: refresh new books at launch + every 12h ------------
function Reload-Caches {
    # build into locals, swap only on success — a partial read (mid-sync) must never wipe a good cache
    try {
        $ch = @{}
        if (Test-Path $cachePath) { (Get-Content -Raw $cachePath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { if ($_.Value.title) { $ch[("$($_.Value.title)").Trim().ToLowerInvariant()] = $_.Value } } }
        $co = @{}
        if (Test-Path $coversPath) { (Get-Content -Raw $coversPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $co[$_.Name.Trim().ToLowerInvariant()] = $_.Value } }
        $script:ChapterCache = $ch; $script:CoverCache = $co
    } catch {}
}
function Start-Sync {
    try { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $PSScriptRoot 'sync.ps1') } catch {}
}
function Save-WindowState {
    try {
        if ($window.WindowState -ne 'Normal') { return }
        $l = $window.Left; $t = $window.Top; $w = $window.Width
        if ([double]::IsNaN($l) -or [double]::IsNaN($t) -or [double]::IsNaN($w)) { return }
        @{ Left = [int]$l; Top = [int]$t; Width = [int]$w } | ConvertTo-Json | Set-Content -Path $winStatePath -Encoding UTF8
    } catch {}
}
function Toggle-Window {
    if ($window.IsVisible) { $window.Hide() } else { $window.Show(); $window.Activate() }
}

# ---- events ------------------------------------------------------------------
$Scrub.Add_ValueChanged({ if ($script:ChapMode) { $ElapsedText.Text = Format-Time ($Scrub.Value - $script:ChapStart) } else { $ElapsedText.Text = Format-Time $Scrub.Value } })
$Scrub.Add_PreviewMouseLeftButtonDown({ $script:Scrubbing = $true })
$Scrub.Add_PreviewMouseLeftButtonUp({ $t = $Scrub.Value; $script:Scrubbing = $false; Seek-To $t })
$BtnPrev.Add_Click({ Chapter-Nav 'prev' })
$BtnNext.Add_Click({ Chapter-Nav 'next' })
$BtnBack30.Add_Click({ Skip-Seconds -30 })
$BtnFwd30.Add_Click({ Skip-Seconds 30 })
$BtnPlay.Add_Click({ Send-Transport 'play' })
$BtnClose.Add_Click({ $window.Hide() })   # X hides to the tray; quit from the tray menu
$BtnLibrary.Add_Click({ Populate-Library; $LibraryView.Visibility = 'Visible' })
$BtnLibClose.Add_Click({ $LibraryView.Visibility = 'Collapsed' })
$ResizeGrip.Add_DragDelta({ param($s, $e)
        $d = if ([math]::Abs($e.HorizontalChange) -ge [math]::Abs($e.VerticalChange)) { $e.HorizontalChange } else { $e.VerticalChange }
        $n = $window.Width + $d; if ($n -lt 240) { $n = 240 }; if ($n -gt 1000) { $n = 1000 }
        $window.Width = $n; $window.Height = $n
    })
$ResizeGrip.Add_DragCompleted({ Save-WindowState })
$window.Add_MouseMove({ Show-Overlay })
$window.Add_MouseEnter({ Show-Overlay })
$window.Add_MouseLeave({ $script:IdleTimer.Stop(); Hide-Overlay })
$window.Add_MouseLeftButtonDown({ if ($LibraryView.Visibility -eq 'Visible') { return }; try { $window.DragMove(); Save-WindowState } catch {} })
$window.Add_Closing({ Save-WindowState })

# ---- snapshot / run ----------------------------------------------------------
if ($Snapshot) {
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.Top = -4000
    $window.Show(); $window.UpdateLayout(); Update-Player; $window.UpdateLayout()
    $w = [int]$window.ActualWidth; $h = [int]$window.ActualHeight
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ($w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32))
    $rtb.Render($window)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close(); $window.Close()
    Write-Output "SNAPSHOT_SAVED=$Snapshot (${w}x${h})"; return
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$timer.Add_Tick({ Update-Player })
$timer.Start()

# keep the cover/chapter cache current without any scheduler (app is always open)
$script:SyncTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SyncTimer.Interval = [TimeSpan]::FromHours(12)
$script:SyncTimer.Add_Tick({ Reload-Caches; Start-Sync })
$script:SyncTimer.Start()
Start-Sync

# restore remembered window position + size (clamped on-screen)
if (Test-Path $winStatePath) {
    try {
        $ws = Get-Content -Raw $winStatePath | ConvertFrom-Json
        if ($ws.Width -ge 240 -and $ws.Width -le 1000) {
            $window.WindowStartupLocation = 'Manual'
            $window.Width = [double]$ws.Width; $window.Height = [double]$ws.Width
            $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
            $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
            $L = [double]$ws.Left; $T = [double]$ws.Top
            if ($L -lt $vl) { $L = $vl }; if ($T -lt $vt) { $T = $vt }
            if ($L -gt ($vl + $vw - $ws.Width)) { $L = $vl + $vw - $ws.Width }
            if ($T -gt ($vt + $vh - $ws.Width)) { $T = $vt + $vh - $ws.Width }
            $window.Left = $L; $window.Top = $T
        }
    } catch {}
}

Update-Player
Show-Overlay
# build the library grid in the background so it opens instantly later
$window.Dispatcher.BeginInvoke([action] { Populate-Library }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null

# ---- system-tray (notification area) icon ------------------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    $h = [Native.U]::LoadImage([IntPtr]::Zero, (Join-Path $PSScriptRoot 'app.ico'), 1, 32, 32, 0x10)
    if ($h -ne [IntPtr]::Zero) { $notify.Icon = [System.Drawing.Icon]::FromHandle($h) }
} catch {}
if (-not $notify.Icon) { try { $notify.Icon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot 'app.ico')) } catch {} }
$notify.Text = 'Audible Remote'
$notify.Visible = $true
$notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Window } })
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Show / hide', $null, [System.EventHandler] { Toggle-Window })
[void]$menu.Items.Add('Exit', $null, [System.EventHandler] { $window.Close() })
$notify.ContextMenuStrip = $menu

# never let a stray exception tear down the widget — swallow and keep running
$window.Dispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true })

[void]$window.ShowDialog()
$notify.Visible = $false; $notify.Dispose()
